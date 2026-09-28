# historian-gateway

A thin Postgres **query gateway** that unifies hot (live) and cold (S3 Parquet
historian) equipment data behind one relation, so **front4, Superset, and any
SQL tool can query old timestamps with plain SQL** — no per-tool Athena driver,
no query rewrites.

```
consumer ──SQL──► historian-gateway (Postgres)
                     │
                     ├─ live.equipment_values   ─postgres_fdw─► timescaledb hypertable   (HOT, recent)
                     └─ hist                     ─pg_duckdb──► s3://…/*-legacy.parquet    (COLD, legacy)
                     └─ ev_all = live ∪ hist     ← query THIS
```

**Serving surface (canonical, narrow):** `{ts_value, id_enterprise, year, month,
id_equipment, gross_production_incr, net_production_incr, speed}`. This is a
production-series server, not a raw mirror — widen only on demand.

**Prune-proof FDW import:** `live.equipment_values` is a **pinned** foreign table
declaring ONLY those served columns, not `IMPORT FOREIGN SCHEMA` (which pulls all
~58). The analytics clean-schema cutover prunes the dead columns off the remote
`equipment_values`; a pinned import can never break when that happens (postgres_fdw
only ships referenced columns).

## Why a gateway (not pg_duckdb in the timescaledb instance)

- The operational DB image is **Alpine/musl** (`timescale/timescaledb:*-pg15`);
  pg_duckdb ships **glibc** + bundles DuckDB — it won't drop into that image.
- A separate gateway keeps heavy historian scans **off the OLTP instance**.
- Consumers change **one connection host**; SQL and schema are unchanged.

## How queries stay cheap (T3 — needs a year/month predicate)

The historian is partitioned `enterprise=/year=/month=`. DuckDB prunes ONLY on the
partition columns, **not on `ts_value`** — hardproof via `EXPLAIN ANALYZE` on
staging:

| Predicate | Files read | Time |
|---|---|---|
| `ts_value BETWEEN <one day>` (only) | **59 / 836** | 170.76 s |
| `year=2026 AND month=9 AND ts_value ...` | **1 / 836** | 0.57 s |
| compound year/month RANGE + `ts_value ...` (Jinja) | **1 / 836** | 0.74 s |

So a bounded query prunes the cold side **only if it carries a year/month
predicate**. `ev_all` therefore surfaces `year`/`month`, and consumers add the
predicate: Superset via the `ev_all` virtual-dataset Jinja (`{{ from_dttm }}`),
read-api/tools via `ev_between(p_start, p_end)`. DuckDB's pushdown survives through
the Postgres view (`Custom Scan (DuckDBScan)`).

## Correctness invariants (each caught by hardproof)

1. **No double-count — via a per-enterprise cutover (T2b, corrected 2026-09-04).**
   The `hist` view reads only `*-legacy.parquet`, but that is NOT pre-cutover:
   hardproof showed the staging `*-legacy.parquet` for ent3 spans 2021→**today**
   (it is the deep-remap of the still-live legacy packiot40 source), and live also
   holds ent3 from its F3 cutover (2026-07-23) onward — so on 2026-09-03 BOTH sides
   had ent3 rows (hist 196,671 / live 155,465) and a plain `UNION ALL` returned
   352,136 == **double-count**. Fixed with `ev_union_boundary(id_enterprise, cutover_ts =
   max(hist.ts_value))`: COLD owns `ts <= cutover`, HOT owns `ts > cutover` (disjoint;
   live fills forward from the archive's end). Hardproof of the fix: the same day now
   returns **196,671** (HOT 0 + COLD 196,671), 1 parquet file. **Operational
   invariant:** the cutover refresh (top-level `refresh-equipment_values-cutover.sql`) MUST be
   re-run after every historian backfill/append, and every in-historian enterprise
   MUST have a `ev_union_boundary` row, or the double-count returns. **Never** wrap this
   refresh in a PL/pgSQL function — pg_duckdb cannot scan the `hist` parquet inside a
   function body, so it throws and leaves the cutover silently stale (a broken
   `refresh_ev_union_boundary()` fn of exactly this shape was found live on staging and
   dropped 2026-09-08).
   *(A naïve `live ∪ all-historian` double-counted 2026 and surfaced 99e9 gross.)*
2. **Tenant RLS must be a LITERAL.** pg_duckdb pushes predicates into DuckDB,
   which has **no PG session context** — `current_setting('app.tenant_id')` and a
   STABLE `current_tenant()` both fail on the cold path. So the tenant must arrive
   as a literal/param: **Superset native RLS** injects it; **read-api** adds
   `id_enterprise = <id>` from its known tenant. Never rely on a GUC policy here.
3. **Cutover is per-enterprise.** Each tenant left legacy at a different time;
   the `*-legacy.parquet` scoping encodes that per file, so the union is uniform.

## Credentials

- **Cold (S3):** scoped read-only IAM user `svc-historian-gateway`
  (`s3:GetObject`/`ListBucket` on the historian bucket only). Instance-role
  `credential_chain` is **not** usable — the DB enforces **IMDSv2** and DuckDB's
  aws extension can't fetch v2 creds through the docker hop. Manage this key via
  Terraform for prod (the staging key was minted manually for the PoC).
- **Hot (FDW):** the `packiot_analytics` Postgres credential.

## Proven on staging (CPACK, ent 1→3, 328M rows, lossless deep-remap)

| Check | Result |
|---|---|
| pg_duckdb + postgres_fdw coexist | ✅ |
| live hypertable via FDW | 3.14M CPACK post-cutover rows |
| `ev_all` spanning 2022→2026 | unified, no double-count |
| old-timestamp lookup | 1/181 files scanned |
| via Superset (SQL Lab + engine) | `2022→242 (cold)`, `2026→17281 (hot)` |

## Serving rules (2026-09-28 audit: t-historian-serving-guards)

**1. Never bound a `live.*` query with `now()`.** postgres_fdw only ships immutable
expressions to the remote, and `now()` is stable, so a `ts_value > now() - interval '2h'`
filter is evaluated locally after pulling the WHOLE remote table: measured 173 s vs 59 ms
with a literal timestamp. Pass literal bounds (read-api binds literals through the simple
protocol). Check with `EXPLAIN (VERBOSE)`: the `Remote SQL:` line must carry the time filter.

**2. Long windows read daily rollups, never per-second rows.** Re-aggregating the cold
archive at query time costs about 25 s per 30 days (a CPACK month is 6-8 M rows), and a
mixed pg_duckdb + FDW plan loses the FDW pushdown. read-api (`historian_split.go`) runs
hot and cold as separate statements and merges them:

| Endpoint | Cold (pure DuckDB) | Hot (pure Postgres/FDW) |
|---|---|---|
| production-series, > 31 days | `cold.equipment_values_daily`, days < `ev_daily_watermark.covered_until` | `live.equipment_values_1hour` (analytics hourly rollup), days ≥ watermark |
| production-series, ≤ 31 days | unchanged: the `silver.equipment_values` union (exact window edges) | |
| downtime-series, any window | `cold.equipment_events`, only for EE-promoted tenants and only before `ee_union_boundary` | `live.equipment_events`, aggregated per UTC day |

The daily rollup is written by `scripts/historian-ev-daily-rollup.sh` (nightly, from the
append job, current + previous month; `FULL=1` rebuilds everything and is required once on a
new bucket).

**3. Cold increments are spike-guarded.** `cold.equipment_values` (and the daily rollup)
NULL an increment that is negative, or at least half the machine's lifetime totalizer AND
above 10,000 in one row: legacy stored the totalizer in the increment column in places
(POLYTYPE net 2022-10..2023-09, the 2024-07-22 counter replay, 2026-08). Clean months are
byte-identical. 2022-08 is a known gap: legacy itself has NULL gross/net/speed for the
whole month.

**4. Memory.** The container is capped at 2560 MB and DuckDB at 1024 MB / 2 threads per
backend (`command:` in `compose.historian-gateway.yml`; `-c` settings override both config
files). pg_duckdb's defaults (4 GB per backend, one thread per core) let a few wide cold
scans ask for more than the whole shared app host.

## Deploy

Set in `.env`: `HIST_GW_PASSWORD`, `DB_HOST/PORT/NAME/USER/DB_PASSWORD`,
`HISTORIAN_BUCKET`, `HIST_AWS_KEY`, `HIST_AWS_SECRET`, `AWS_REGION`. Then:

```
docker compose -f compose.historian-gateway.yml up -d
```

Register in Superset as database `historian_union`
(`postgresql://postgres:<HIST_GW_PASSWORD>@hist-gateway:5432/postgres`), then
build datasets on `ev_all` with per-tenant RLS.
