---
title: Historian gateway
layer: 3
owner_area: historian
last_verified: 2026-09-28
---
# Historian gateway

> **Layer 3 · Components** — the `hist-gateway` container: a Postgres instance with
> `pg_duckdb` and `postgres_fdw` that serves hot + cold history through plain SQL, plus the
> scripts that feed and check its S3 archive. For whoever operates it or writes queries
> against it. Up: [Historian](../subsystems/historian.md)

## Responsibility

`hist-gateway` answers one question correctly: "give me tenant T's production, downtime or
production orders between two instants", whether those instants are yesterday or 2021. It
must never count a row twice across the hot/cold seam, never return another tenant's legacy
data, and never take the shared app host down while doing it. It stores no rows itself: the
hot side is a foreign table onto the analytics DB and the cold side is Parquet on S3.

## At a glance

| | |
|---|---|
| Runtime | PostgreSQL 16 with `pg_duckdb` (embedded DuckDB) and `postgres_fdw` |
| Image | `pgduckdb/pgduckdb:16-main` (glibc; cannot be loaded into the Alpine/musl TimescaleDB image) |
| Compose | `compose.historian-gateway.yml`, project `packiot`, network `stack_packiot-net` (external) |
| Container / service | `hist-gateway` / `historian-gateway` |
| Database | `packiot_historian` (renamed from `postgres` in #274) |
| Host (staging) | app host `i-06c9547a2c7091ab7`; reached in-stack as `hist-gateway:5432`; no host port |
| Volume | `hist_gateway_data` (the init script runs only on a fresh volume) |
| Limits | `mem_limit: 2560m`; DuckDB 1024 MB and 2 threads per backend |
| Depends on | analytics DB at 10.10.10.89 (role `histgw_ro`), S3 bucket `packiot-staging-historian-<account>` (IAM user `svc-historian-gateway`) |
| Depended on by | read-api `/v1/historian/*`, Superset database `historian_union`, CloudBeaver (browse), the nightly job's boundary refresh |
| Deploy | **by hand**; the staging deploy workflow does not manage this container |
| Production | not deployed |

## Inputs & outputs

| Kind | Object | Direction | Notes |
|---|---|---|---|
| Foreign table | `live.equipment_values` → analytics `silver.equipment_values` | read | pinned 8 columns: `ts_value, id_enterprise, id_site, id_area, id_equipment, gross_production_incr, net_production_incr, speed` |
| Foreign table | `live.equipment_events` → `silver.equipment_events` | read | pinned 12 columns (times, status, planned flag, category/subcategory, notes) |
| Foreign table | `live.equipment_values_1hour` → `silver.equipment_categorical_1hour` | read | hourly gross/net, 13 months hot; needs `t-historian-serving-guards/01` grant |
| Foreign table | `live.production_orders` → `core.production_orders` | read | PO header fields incl. OEE and times |
| Parquet | `s3://<bucket>/equipment_values/*/*/*/*-legacy.parquet` | read | via `cold.equipment_values` |
| Parquet | `s3://<bucket>/equipment_values_daily/*/*/*/*.parquet` | read | via `cold.equipment_values_daily` |
| Parquet | `s3://<bucket>/equipment_events/…` and `equipment_events_legacy_unpromoted/…` | read | via `cold.equipment_events` |
| Parquet | `s3://<bucket>/production_orders/*/*/*/*-legacy.parquet` | read | via `cold.production_orders` |
| Views served | `silver.equipment_values`, `silver.equipment_events`, `silver.production_orders`, `cold.equipment_values_daily` | serve | the query surface |
| Tables written | `cold.ev_union_boundary`, `cold.ee_union_boundary`, `cold.po_union_boundary`, `cold.cold_append_watermark`, `cold.ev_daily_watermark` | write | only by the refresh/stamp SQL and the daily rollup script |

The foreign server `live_pg` uses `use_remote_estimate 'true'`, `fetch_size '50000'`,
`async_capable 'true'`. Tables are **declared**, not `IMPORT FOREIGN SCHEMA`: postgres_fdw
ships only declared columns, so dropping an unused column on the analytics side cannot break
the gateway.

## Internal design

### Schemas

| Schema | Holds |
|---|---|
| `live` | the four foreign tables (hot) |
| `cold` | Parquet source views, the allow-list, boundary and watermark tables (`search_path = cold, public` is the database default, so gateway scripts use bare names) |
| `silver` | the hot ∪ cold union views, named like the analytics DB (ADR-0057) |
| `gold` | created empty by the init script |
| `public` | extension objects only (`read_parquet`, `duckdb.*`) |

!!! warning "Unverified: live-only `gold.equipment_oee_shift`"
    The Superset database asset and `scripts/historian-oee-shift-backfill.sh` refer to a
    cold-only view `gold.equipment_oee_shift` on the gateway over the `equipment_oee_shift/`
    prefix. It is **not** created by `10-historian-gateway.sh`, so a fresh volume will not
    have it. Check with `\dv gold.*` before relying on it, and codify it if it exists.

### Storage layout

Hive partitioning: `<table>/enterprise=<F3 id>/year=<Y>/month=<M>/<file>.parquet`, one
file per tenant-month (`data-YYYY-MM-legacy.parquet`, `daily-YYYY-MM.parquet`). The
`enterprise` value **is** the F3 tenant id for promoted partitions; non-promoted partitions
keep legacy ids and are never served. DuckDB prunes only on `enterprise`, `year`, `month`.

### The union views

```sql
-- silver.equipment_values  (cold-anchored)
SELECT … FROM live.equipment_values lv
  LEFT JOIN ev_union_boundary c ON c.id_enterprise = lv.id_enterprise
 WHERE c.cutover_ts IS NULL OR lv.ts_value > c.cutover_ts          -- hot tail only
UNION ALL
SELECT … FROM cold.equipment_values h
  JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ev_promoted;

-- silver.equipment_events  (hot-anchored: all hot rows, cold only before min(hot))
SELECT … FROM live.equipment_events lv
UNION ALL
SELECT … FROM cold.equipment_events h
  JOIN promoted_enterprise p ON … AND p.ee_promoted
  LEFT JOIN ee_union_boundary c ON c.id_enterprise = h.id_enterprise
 WHERE c.cutover_ts IS NULL OR h.ts_event < c.cutover_ts;
```

`silver.production_orders` follows the EV (cold-anchored) shape on `ts_start` with
`po_union_boundary` and `po_promoted`. The hot side exposes `year`/`month` via `EXTRACT`, the
cold side via the partition columns.

### Cold spike guard

`cold.equipment_values` (and the daily rollup, with the same rule) returns NULL for an
increment that is physically impossible: negative; above 10,000 and at least half the
machine's lifetime totalizer (legacy stored the totalizer in the increment column, POLYTYPE
2022-10..2023-09); above 10,000 with no matching totalizer movement since the previous row
(the 2024-07-22 replay); or above 1,000 at more than 5,000 units/min when the machine has three
or more such rows in the same hour. Window functions are partitioned by
`(enterprise, year, month, equipment)`, so year/month pruning still works (~20 s per month
scanned). The Parquet files are untouched. 2022-08 is a known gap: legacy itself has NULL
gross/net/speed for that month.

### Roles

| Role | Login | Purpose | Cold (`read_parquet`) | Hot (FDW mapping) |
|---|---|---|---|---|
| `postgres` | yes | superuser; scripts and boundary refresh | yes | remote `postgres` (superuser) |
| `historian_svc` | yes | read-api and Superset | yes, via `duckdb.postgres_role = historian_readers` | remote `histgw_ro` |
| `historian_readers` | no | group allowed to run DuckDB | — | — |
| `cloudbeaver_histro` | yes | CloudBeaver browsing | **no** (deliberately not in `historian_readers`) | remote `histgw_ro` |

pg_duckdb keeps S3 credentials as a **per-role user mapping** on server `simple_s3_secret`;
group membership does not inherit it. Each login that reads cold data needs its own mapping,
cloned server-side by `apply-hardening.sh`. On the analytics side `histgw_ro` has
`app.tenant_id = -1` as a role default, so the FDW sees all tenants and the tenant literal
in the gateway query is the only fence.

### Nightly pipeline (staging)

`historian-staging-append.timer` (02:30 UTC) runs `/opt/packiot/historian/historian-staging-run-append.sh`:

1. `historian-legacy-copy.sh` — legacy `packiot40` `equipment_values` → S3, current + previous
   month, legacy → F3 id remap via the packml-topic join, lag 1 day.
2. `historian-po-backfill.sh` with `PO_COPY_MONTHS_BACK=1`.
3. `historian-oee-shift-backfill.sh` with `SHIFT_COPY_MONTHS_BACK=1`.
4. Post-run hook, in order, each `docker exec -i hist-gateway psql -d packiot_historian -f`:
   `stamp-equipment_values-meta.sql` (stamps `cold_append_watermark`), then
   `refresh-equipment_values-cutover.sql`, `refresh-ee-cutover.sql`, `refresh-po-cutover.sql`.
5. `historian-ev-daily-rollup.sh` — rewrites the daily rollup for current + previous month
   (whole UTC days before `date(ev cutover)`) and updates `cold.ev_daily_watermark`.

`set -e` makes any failed step fail the unit. Each DuckDB step sets `memory_limit` (1200 MB,
1000 MB for the rollup), `threads=1` and a spill `temp_directory` under
`/var/tmp/historian-duckdb`; the unit adds `MemoryHigh=1400M`, `MemoryMax=1800M`,
`MemorySwapMax=0`, `CPUQuota=60%`, `Nice=10`, `TimeoutStartSec=2h`.

`historian-integrity-monitor.timer` (04:00 UTC) runs three checks and fails the unit if a hard
one fails:

| Check | Severity | Asserts |
|---|---|---|
| `historian-cutover-coverage-check.sh` | hard | the set of `ev_union_boundary` rows equals the `ev_promoted` allow-list (missing ⇒ double-count; extra ⇒ clipped hot history) |
| `historian-staleness-monitor.sh` | hard | `cold_append_watermark.last_append_at ≤ ev_union_boundary.refreshed_at`, and cold `max(ts)` over the last two month partitions ≤ `cutover_ts` |
| `historian-ee-coverage-check.sh` | soft | every equipment in recent cold EE also appears in hot EE (else downtime is under-covered) |

Both units and scripts are installed by `sudo scripts/install-historian-pipeline.sh`, which
nothing calls automatically; re-run it after changing any of these files.

### Query patterns

Every query must carry **`id_enterprise = <literal>`** and a **year/month range**. Use the
simple query protocol (pg_duckdb does not apply the S3 secret on the prepared-statement path).

```sql
-- Good: one tenant, one month partition, literal bounds
SELECT date_trunc('day', ts_value) AS day, id_equipment,
       sum(gross_production_incr), sum(net_production_incr)
  FROM silver.equipment_values
 WHERE id_enterprise = 3
   AND year = 2024 AND month = 3
   AND ts_value >= '2024-03-01' AND ts_value < '2024-03-08'
 GROUP BY 1, 2;

-- Long windows: read the daily rollup (cold) + the hourly foreign table (hot) separately
SELECT day, id_equipment, sum(gross_production), sum(net_production)
  FROM cold.equipment_values_daily
 WHERE id_enterprise = 3 AND year BETWEEN 2022 AND 2025 AND day < '2025-12-01'
 GROUP BY 1, 2;

SELECT date_trunc('day', ts_value AT TIME ZONE 'UTC')::date, id_equipment, sum(gross_production_incr)
  FROM live.equipment_values_1hour
 WHERE id_enterprise = 3 AND ts_value >= '2026-09-01 00:00+00' AND ts_value < '2026-09-28 00:00+00'
 GROUP BY 1, 2;
```

**Never bound a `live.*` query with `now()`.** postgres_fdw ships only immutable
expressions; `now()` is stable, so `ts_value > now() - interval '2 hours'` is evaluated
locally after pulling the whole remote table (173 s vs 59 ms with a literal, 2026-09-28).
Check with `EXPLAIN (VERBOSE)`: the `Remote SQL:` line must contain the time filter.

Other rules: never wrap a Parquet read in a SQL or PL/pgSQL function ("DuckDB execution is not
supported inside functions"; `ev_between()` and a live-only `refresh_ev_union_boundary()` were
removed for this); pass equipment filters as an inline integer list, not an `int[]` parameter
(pg_duckdb cannot cast a Postgres array literal); avoid mixing a Parquet scan and an FDW scan
in one heavy plan (the FDW side loses pushdown).

## Configuration

Variables come from `/opt/packiot/.env.historian-gateway` on the app host, **not** the main
`.env`. Secret values live in Secrets Manager; names only here.

| Variable (compose) | Default | Staging | Effect |
|---|---|---|---|
| `HIST_GW_PASSWORD` | required | set | `postgres` password of the gateway |
| `DB_HOST` → `FDW_HOST` | `10.10.10.89` | 10.10.10.89 | analytics DB host for `live_pg` |
| `DB_PORT` → `FDW_PORT` | `5432` | 5432 | |
| `DB_NAME` → `FDW_DB` | `packiot_analytics` | packiot_analytics | |
| `DB_USER` / `DB_PASSWORD` → `FDW_USER` / `FDW_PASS` | `postgres` / required | set | the superuser mapping used by `postgres` |
| `HISTORIAN_BUCKET` | required | `packiot-staging-historian-<account>` | baked into the view definitions at init |
| `AWS_REGION` | `us-east-1` | us-east-1 | |
| `HIST_AWS_KEY` / `HIST_AWS_SECRET` | required | set (Secrets Manager `packiot/staging/historian-gateway-s3`) | seeds the DuckDB S3 secret at init only |
| `CLOUDBEAVER_HISTRO_PASSWORD` | empty | set | creates `cloudbeaver_histro` at init |
| `HISTGW_RO_PASS` | empty | set | FDW mapping to remote `histgw_ro` for non-superuser roles |
| `HIST_GW_SVC_PASSWORD` | empty | set (Secrets Manager `packiot/staging/historian-svc`) | creates `historian_svc` at init |

Server settings (`command:` `-c` flags, which override both config files):
`duckdb.memory_limit=1024`, `duckdb.max_memory=1024`, `duckdb.threads=2`,
`duckdb.max_temp_directory_size=8GB`. `duckdb.postgres_role=historian_readers` is set with
`ALTER SYSTEM` (lives in `postgresql.auto.conf` on the volume).

Consumers:

| Consumer | Variables | Values |
|---|---|---|
| read-api | `HIST_GW_HOST`, `HIST_GW_PORT`, `HIST_GW_USER`, `HIST_GW_DB`, `HIST_GW_PASSWORD` | `hist-gateway`, `5432`, `historian_svc`, `packiot_historian`, from `.env` (deploy writes it from `packiot/staging/historian-svc`) |
| Superset | `configs/superset/assets/databases/historian_union.yaml` | `historian_svc@hist-gateway:5432/packiot_historian`, `expose_in_sqllab: false`, DML/CTAS off |

## Data & invariants

- **No double count.** Every `ev_promoted` tenant has exactly one `ev_union_boundary` row equal
  to `max(cold ts_value)`; same for PO. EE boundary = `min(hot ts_event)`. Refresh after every
  archive change, as top-level statements.
- **Tenant fence.** The cold side is served only for tenants in `cold.promoted_enterprise`
  with the matching flag. There is no Postgres RLS; the caller supplies `id_enterprise`. read-api
  injects it from the authenticated tenant; Superset from the guest-token RLS clause.
- **Read-only.** The gateway writes only its own boundary and watermark tables; archive files
  are written by the DuckDB CLI scripts, never through `pg_duckdb`.
- **Day alignment.** The daily rollup covers whole UTC days strictly before the EV cutover day,
  so read-api's split at `covered_until` never cuts a day in two.

## Observability

- Integrity monitor unit status: `systemctl status historian-integrity-monitor.service`, logs
  via `journalctl -u historian-integrity-monitor`.
- Append job: `journalctl -u historian-staging-append` (lines prefixed `[historian-append]`,
  `[oee-shift-backfill]`, `[ev-daily-rollup]`).
- read-api logs `historian: gateway pool ready` or `historian: … disabled` at boot.
- Container health: `pg_isready` every 15 s, `start_period: 20m` (the first boot on a fresh
  volume scans the whole CPACK partition to seed the boundaries).
- Memory: cAdvisor container metrics for `hist-gateway`; host `node_memory_MemAvailable`.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Double count after an append | recent window totals doubled | boundary refresh skipped | run the three `refresh-*-cutover.sql`; the staleness check flags it |
| Cross-tenant leak (2026-09-14) | tenant 6 query returned 16.7 M legacy rows | legacy id collision, no allow-list | allow-list (t271); never promote an unverified id |
| Refresh inside a function (2026-09-08) | boundary silently stale | pg_duckdb cannot scan Parquet in a function | keep refreshes top-level SQL |
| `read_parquet` 403 "No credentials" | cold reads fail for one role | that role lacks its own `simple_s3_secret` mapping, or the key rotated | re-run `apply-hardening.sh`; after rotation use `scripts/rotate-historian-s3-key.sh` |
| "permission denied for schema core" then 0 PO rows (2026-09-24) | `silver.production_orders` hot side empty for `historian_svc` | `histgw_ro` lacked USAGE, then FORCE RLS with no GUC | `GRANT USAGE`, `ALTER ROLE histgw_ro SET app.tenant_id='-1'` (`t-historian-svc-hardening`) |
| Host memory exhaustion (audit 2026-09-28) | risk of app-host OOM | pg_duckdb default 4 GB per backend × 4 read-api connections, no container limit | `mem_limit` and DuckDB limits (#1474) |
| Minutes-long hot query | `live.*` scan pulls everything | `now()` in the filter | literal bounds |
| Long read-api windows 500 | 30 days took ~25 s at query time | re-aggregating per-second cold rows | daily rollup + hot/cold split (#1474) |
| Stale config after edit | new env not applied | `docker restart` keeps creation-time env | recreate with `up -d` and the env file (below) |

## Operating it

**Recreate** (after changing `compose.historian-gateway.yml` or the env file) on the app host:

```sh
cd /opt/packiot && docker compose -p packiot \
  --env-file .env.historian-gateway \
  -f compose.historian-gateway.yml up -d historian-gateway
```

Without `--env-file .env.historian-gateway` the `:?` guards fail or wrong values are used.
Recreating keeps the volume, so the init script does **not** re-run; objects, roles and the
`ALTER SYSTEM` setting survive.

**Bring a running gateway to the hardened state** (idempotent; restarts once if
`duckdb.postgres_role` changes):

```sh
HIST_GW_SVC_PASSWORD=… /opt/packiot/historian/apply-hardening.sh
```

**Apply a gateway migration** (`db/migrations/t2xx-historian-*/`, `t-historian-*`):

```sh
docker exec -i hist-gateway psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -f - < 02-gateway-guards.sql
```

Some migration READMEs still say `-d postgres`; the database is `packiot_historian` since #274.

**Refresh boundaries by hand** (after any backfill, reunload or prune):

```sh
for f in refresh-equipment_values-cutover refresh-ee-cutover refresh-po-cutover; do
  docker exec -i hist-gateway psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 \
    -f - < /opt/packiot/historian/$f.sql
done
/opt/packiot/historian/historian-integrity-monitor.sh
```

**Rebuild the daily rollup** (new bucket, or after a spike-guard change):
`FULL=1 /opt/packiot/historian/historian-ev-daily-rollup.sh`.

**Rotate the S3 key**: `scripts/rotate-historian-s3-key.sh` from a workstation. It writes the
new key to Secrets Manager, updates the box env file and the live user mappings for `postgres`
and `historian_svc`, verifies, then recycles backends (pg_duckdb loads the secret once per
backend). Never print `pg_user_mappings` options; a masking filter that only hid `password=`
leaked the key once (2026-09-24).

**Cap staging history** (only after production promotion):
`scripts/historian-prune-by-data-age.sh` (dry run by default; `APPLY=1
CONFIRM=delete-staging-history` to delete; refuses buckets without "staging"). S3 lifecycle
rules cannot do this: they count object age, not data age.

**Unsafe**: heavy Docker operations on the shared app host; `docker restart` to apply env;
running a Parquet scan in a function; adding a promoted id without the ownership proof;
un-bounded (no year/month) queries on the union views.

## Tests

| Test | What it proves | Run |
|---|---|---|
| `services/read-api/cmd/refdata-api/historian_split_test.go` | split exactly at the watermark, whole-day resolution, EE cold predicate mirrors the view, every split SQL is tenant-fenced and never uses `now()` | `cd services/read-api && go test ./cmd/refdata-api -run 'PlanEVDaily|EEColdWindow|MergeDaily|SplitSQL'` |
| `services/read-api/cmd/refdata-api/historian_test.go` | method guard, tenant required | `go test ./cmd/refdata-api -run Historian` |
| `scripts/historian-append-verify.sh` | the F3 appender end-to-end against a throwaway TimescaleDB and local Parquet; idempotency; spike zeroing | needs Docker + DuckDB CLI |
| integrity monitor | live invariants | nightly timer, or by hand as above |

## Source map

| Path | What's there |
|---|---|
| `compose.historian-gateway.yml` | service, limits, env, volume |
| `services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh` | fresh-volume init: extensions, FDW, views, allow-list, boundaries, roles, comments |
| `services/historian-gateway/apply-hardening.sh` | `historian_svc` / `historian_readers` on a running gateway |
| `services/historian-gateway/refresh-*-cutover.sql` | boundary refreshes (EV, EE, PO) |
| `services/historian-gateway/README.md` | design notes and serving rules (its Superset URI example is stale) |
| `scripts/historian-staging-run-append.sh` | nightly wrapper |
| `scripts/historian-legacy-copy.sh`, `historian-po-backfill.sh`, `historian-oee-shift-backfill.sh`, `historian-events-backfill.sh`, `historian-events-reunload.sh` | archive writers (DuckDB CLI) |
| `scripts/historian-ev-daily-rollup.sh` | daily cold rollup + watermark |
| `scripts/historian-append.sh`, `historian-append-verify.sh` | the post-legacy F3 appender and its local proof |
| `scripts/historian-integrity-monitor.sh`, `historian-cutover-coverage-check.sh`, `historian-staleness-monitor.sh`, `historian-ee-coverage-check.sh` | checks |
| `scripts/stamp-equipment_values-meta.sql` | append watermark stamp |
| `scripts/install-historian-pipeline.sh` | installs scripts, SQL and units to `/opt/packiot/historian` |
| `scripts/rotate-historian-s3-key.sh`, `scripts/historian-prune-by-data-age.sh` | key rotation, staging cap |
| `systemd/historian-*.service`, `systemd/historian-*.timer` | schedules and cgroup limits |
| `db/migrations/t271-historian-promoted-allowlist`, `t282-historian-gateway-glue`, `t287-historian-cold-schema`, `t-historian-svc-hardening`, `t-historian-serving-guards`, `t-histdb-object-docs` | gateway and analytics-side migrations |
| `services/read-api/cmd/refdata-api/historian.go`, `historian_split.go` | the read-api client |
| `configs/superset/assets/databases/historian_union.yaml`, `datasets/historian_union/ev_all.yaml` | Superset connection and dataset |
| `terraform/staging/historian.tf`, `historian-gateway.tf` | bucket and IAM |
| `docs/plans/unified-hot-cold-serving-grain-tiered-retention.md` | the T0–T5 plan and pinned items |
