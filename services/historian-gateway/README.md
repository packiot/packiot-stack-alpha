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

## Why a gateway (not pg_duckdb in the timescaledb instance)

- The operational DB image is **Alpine/musl** (`timescale/timescaledb:*-pg15`);
  pg_duckdb ships **glibc** + bundles DuckDB — it won't drop into that image.
- A separate gateway keeps heavy historian scans **off the OLTP instance**.
- Consumers change **one connection host**; SQL and schema are unchanged.

## How queries stay cheap

The historian is partitioned `enterprise=/year=/month=`. A timestamp predicate
prunes to the exact file — **hardproof: an old-timestamp lookup scanned 1 of 181
files** (`Total Files Read: 1`). DuckDB's pushdown survives through the Postgres
view (`Custom Scan (DuckDBScan)`).

## Correctness invariants (each caught by hardproof)

1. **No double-count.** The historian bucket also holds the append-job's
   *post-cutover* daily files (`data-YYYY-MM-DD.parquet`). The `hist` view reads
   **only `*-legacy.parquet`** (the deep-remapped legacy backfill, pre-cutover by
   construction), so `live ∪ hist` is disjoint — no boundary table needed.
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

## Deploy

Set in `.env`: `HIST_GW_PASSWORD`, `DB_HOST/PORT/NAME/USER/DB_PASSWORD`,
`HISTORIAN_BUCKET`, `HIST_AWS_KEY`, `HIST_AWS_SECRET`, `AWS_REGION`. Then:

```
docker compose -f compose.historian-gateway.yml up -d
```

Register in Superset as database `historian_union`
(`postgresql://postgres:<HIST_GW_PASSWORD>@hist-gateway:5432/postgres`), then
build datasets on `ev_all` with per-tenant RLS.
