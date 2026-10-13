---
title: Historian
layer: 2
owner_area: historian
last_verified: 2026-10-13
---
# Historian

> **Layer 2 · Subsystems** — how Packiot keeps years of raw telemetry, downtime events,
> production orders and shift OEE outside the hot database, and how consumers query "now"
> and "three years ago" through one SQL surface. For engineers, DBAs and anyone building a
> long-range chart. Up: [Architecture overview](../architecture/overview.md)

## Purpose

The [analytics DB](analytics-db.md) keeps raw telemetry for 90 days, because raw rows
dominate storage while clients mostly read small aggregates. The historian is the **archive
of record** for everything older: monthly Parquet files on S3, partitioned by tenant, year and
month. A small Postgres instance with `pg_duckdb` and `postgres_fdw` — the **historian
gateway** — exposes `silver.*` union views that glue the live tail (foreign tables in schema
`live`, read from the analytics DB) to the cold archive (`read_parquet` views in schema
`cold`), so a consumer writes plain SQL and never has to know where a row lives.

The historian **serves on staging only**. `compose.production.yml` has no gateway; a production
bucket (`packiot-production-historian-<account>`) exists, and the promotion branch (draft
PR #1653) carries an opt-in gateway, but production has not been promoted.

## Boundaries

**Owns**

- The S3 cold archive (`equipment_values/`, `equipment_values_daily/`, `equipment_events/`,
  `production_orders/`, `equipment_oee_shift/` prefixes).
- The gateway database `packiot_historian` (container `hist-gateway`) and its views.
- The per-tenant **promotion allow-list** and **cutover boundaries** that keep hot and cold
  disjoint and keep tenants apart.
- The nightly job that extends the archive, the integrity monitor, and the historian backup.

**Does not own**

- Hot data. The gateway stores no telemetry rows; `live.*` are foreign tables onto
  `packiot_analytics`.
- Client-facing aggregates. Gold OEE grains, POs and events are kept long **in the analytics
  DB** (grain-tiered retention), so `serving.*` functions and `bi.*` views need no historian.
- Tenant authentication. The gateway has no RLS; the caller must pass the tenant as a literal.

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| `hist-gateway` | Postgres 16 + `pg_duckdb` + `postgres_fdw`; `silver.*` union views over `live.*` (FDW) and `cold.*` (Parquet) | app host, `pgduckdb/pgduckdb:16-main`, `compose.historian-gateway.yml` (not managed by the deploy workflow) | [Historian gateway](../components/historian-gateway.md) |
| S3 bucket | Hive-partitioned Parquet `<table>/enterprise=E/year=Y/month=M/*.parquet` | `packiot-staging-historian-<account>` (`terraform/staging/historian.tf`) | [Storage layout](../components/historian-gateway.md#storage-layout) |
| Nightly append | `historian-staging-append.timer` 02:30 UTC → `historian-staging-run-append.sh` | app host systemd, DuckDB CLI in a capped cgroup | [Nightly pipeline](../components/historian-gateway.md#nightly-pipeline-staging) |
| Integrity monitor | `historian-integrity-monitor.timer` 04:00 UTC: cutover coverage (hard), staleness (hard), EE coverage (soft) | app host systemd | [Observability](../components/historian-gateway.md#observability) |
| Backup | `packiot-historian-backup.timer` 04:30 UTC → `backup-historian.sh`: `pg_dump` of `packiot_historian` + server-side mirror of the bucket (no `--delete`) | app host systemd | [DBA guide](../../build/operate/dba-guide.md#backups) |
| read-api historian pool | `POST /v1/historian/production-series`, `/downtime-series` | `read-api`, 4-connection pool as `historian_svc` | [read-api](../components/read-api.md), [API](../../reference/api/read-api.md) |
| Superset `historian_union` | database + one virtual dataset on `silver.equipment_values` | Superset (`configs/superset/assets/databases/historian_union.yaml`) | [Superset](../components/superset.md) |

## How it works

```text
                   historian gateway  (hist-gateway, db packiot_historian)
                   ┌──────────────────────────────────────────────────────────────┐
  Superset ───────▶│ silver.equipment_values   = live tail  ∪  promoted cold      │
                   │ silver.equipment_events   = all hot    ∪  cold before cutover │
                   │ silver.production_orders  = live tail  ∪  promoted cold      │
  read-api ───────▶│ cold.equipment_values_daily · live.equipment_values_1hour    │
  (historian_svc,  │ cold.equipment_events · live.equipment_events  (split reads) │
   split hot/cold) │                                                              │
                   │  live.*  ── postgres_fdw (histgw_ro) ──▶ packiot_analytics   │
                   │  cold.*  ── pg_duckdb read_parquet ────▶ s3://…/*.parquet    │
                   │  cold.promoted_enterprise, *_union_boundary, watermarks      │
                   └──────────────────────────────────────────────────────────────┘
                                  ▲ stamp watermark, refresh boundaries (psql)
  02:30 UTC  historian-staging-run-append.sh
     legacy packiot40 ──DuckDB CLI──▶ S3  (EV, PO, shift OEE: current + previous month)
     then stamp watermark → refresh EV/EE/PO boundaries → daily EV rollup
  04:00 UTC  historian-integrity-monitor.sh   04:30 UTC  backup-historian.sh
```

### Grain-tiered retention

The plan `docs/plans/unified-hot-cold-serving-grain-tiered-retention.md` splits data by
**grain**, the way Prometheus + Thanos or RRDtool do: resolution decays with age.

| Tier | Data | Lives in | Kept | Served by |
|---|---|---|---|---|
| hot aggregates | gold OEE shift/day/week/month, POs, PO runtimes; events | analytics DB | forever; events 5 y | `serving.*`, `bi.*`, full RLS |
| hourly | hourly caggs, `gold.equipment_oee_hourly` | analytics DB | 13 months | same |
| hot raw | `silver.equipment_values`, bronze, 1 s / 1 min caggs | analytics DB | 90 days | same |
| archive | raw EV, EE, POs, shift OEE, 2021 → now | historian S3 | forever (a staging cap script exists) | gateway, for long ranges and raw deep dives |

Delivered as workstreams T0–T5, all **live on staging only**:

| Workstream | What it delivered |
|---|---|
| T0 | `ops.retention_policy` catalog + `ops.apply_retention()`; gold shift/hourly no longer purged at 90 days; DB disk 64 → 128 GB |
| T1 | CPACK legacy history (2021 →) backfilled into analytics gold, POs and events |
| T2 | read-api coverage headers (`X-Data-Hot-Floor`, `X-Data-Truncated`, `Warning: 299`) instead of silent truncation |
| T3 | gateway hardening: NOSUPERUSER `historian_svc`, `duckdb.postgres_role=historian_readers`, remote `histgw_ro` |
| T4 | Superset `historian_union` connection synced by `sync_databases.py` |
| T5 | env-templated Superset URI, `historian-prune-by-data-age.sh` for a future staging cap |

### Hot/cold disjointness per tenant

A naive `hot UNION ALL cold` double-counts wherever both sides hold the same period. Each
union view therefore has a per-tenant **cutover**:

| Union view | Anchor | Cold owns | Hot owns | Boundary table / refresh |
|---|---|---|---|---|
| `silver.equipment_values` | cold: `max(cold ts_value)` | `ts ≤ cutover` | `ts > cutover` | `cold.ev_union_boundary` / `refresh-equipment_values-cutover.sql` |
| `silver.production_orders` | cold: `max(cold ts_start)` | `ts_start ≤ cutover` | `ts_start > cutover` | `cold.po_union_boundary` / `refresh-po-cutover.sql` |
| `silver.equipment_events` | **hot**: `min(hot ts_event)` | `ts < cutover` | all hot rows | `cold.ee_union_boundary` / `refresh-ee-cutover.sql` |

Events are hot-anchored because the CPACK "phase C" backfill loaded pre-cutover events, with
irreplaceable operator notes, **into** the analytics DB. The boundaries must be refreshed after
every archive extension (the nightly job does it); a stale EV boundary serves the newly
archived window twice.

Boundary refreshes and union queries run as **top-level statements**: pg_duckdb cannot run
`read_parquet` inside a SQL or PL/pgSQL function. That is why the old helpers
`refresh_ev_union_boundary()` and `ev_between()` were dropped (`ev_between` in t269).

### Promotion (the tenant fence on the cold side)

The archive was written with **legacy** enterprise ids, and some collide with F3 tenant ids
(legacy partition `enterprise=6` is a different company from F3 tenant 6). A query for id 6
once returned 16.7 M rows of another company's data (2026-09-14). The fix is an explicit
allow-list, `cold.promoted_enterprise`, which every union view **inner joins** on the cold
side:

| Tenant | `ev_promoted` | `ee_promoted` | `po_promoted` | Why (init-script seed) |
|---|---|---|---|---|
| 3 CPACK | yes | yes | yes | cold `id_equipment` {47..108} equals `core.equipments` of tenant 3 (legacy 1 → 3 remap) |
| 4 Incoplast | yes | no | no | cold EV {990015..990018} equals tenant 4's equipment; EE still in legacy id space |
| 5 Bispharma and 24 other ids | no | no | no | documentary rows (native, collision or passthrough); never served |

To promote a tenant: prove cold `id_equipment ⊆ core.equipments(id)`, re-key the partition to
the F3 id on disk if needed (`scripts/historian-events-reunload.sh`), set the flag, refresh the
boundary, run the coverage check. Never hand-add an unverified id.

### Pruning and the serving rules

DuckDB prunes Parquet files only on partition columns. A one-day query filtered on `ts_value`
alone read 59 files in 171 s; adding `year = 2026 AND month = 9` read 1 file in 0.57 s. So
every union view surfaces `year` and `month`, and **every query must carry a year/month
predicate and an `id_enterprise = <literal>`**. Queries touching `cold.*` must use the
**simple query protocol** (pg_duckdb does not apply the S3 secret on the prepared-statement
path); read-api's pool is configured that way.

Since the 2026-09-28 audit (PR #1474, migration `t-historian-serving-guards`) read-api does not
use the mixed union. It runs hot and cold as separate statements and merges in Go
(`services/read-api/cmd/refdata-api/historian_split.go`):

| Endpoint | Cold (pure DuckDB) | Hot (pure FDW) |
|---|---|---|
| `production-series` | `cold.equipment_values_daily`, days before `cold.ev_daily_watermark.covered_until` (EV-promoted tenants) | `live.equipment_values_1hour` (= analytics `silver.equipment_categorical_1hour`), days after |
| `downtime-series` | `cold.equipment_events`, EE-promoted tenants only, before `cold.ee_union_boundary` | `live.equipment_events` aggregated per UTC day |

Measured after the change: 1 year in 2.3 s, 5 years in 8.6 s (was about 25 s per 30 days).
Two rules came out of that audit: **never bound a `live.*` query with `now()`** (postgres_fdw
does not ship it, so the whole remote table is pulled: 173 s vs 59 ms), and **long windows
read daily rollups, never per-second rows**. The cold views also apply a spike guard that NULLs
physically impossible legacy increments (the Parquet files stay untouched).

## Interfaces

| Direction | Peer | Protocol | Object |
|---|---|---|---|
| in | analytics DB | `postgres_fdw` server `live_pg`, remote role `histgw_ro` | `silver.equipment_values`, `silver.equipment_events`, `silver.equipment_categorical_1hour`, `core.production_orders` (pinned column lists) |
| in | S3 | `pg_duckdb` `read_parquet` with an S3 secret (IAM user `svc-historian-gateway`, read-only) | `s3://<bucket>/<table>/enterprise=/year=/month=/` |
| in | legacy `packiot40` | DuckDB CLI `postgres` attach, read-only | nightly copy of the current and previous month |
| out | read-api | Postgres wire, simple query protocol, `historian_svc`, pool of 4 | `POST /v1/historian/production-series`, `/v1/historian/downtime-series` ([API](../../reference/api/read-api.md)) |
| out | Superset | Postgres wire, `historian_svc@hist-gateway:5432/packiot_historian` | virtual dataset on `silver.equipment_values` (Jinja injects year/month); keep it out of SQL Lab |
| out | CloudBeaver | role `cloudbeaver_histro` (hot browsing; cannot run `read_parquet`) | schema browsing |

## Data it owns

| S3 prefix | Content | Coverage (staging) | Writer |
|---|---|---|---|
| `equipment_values/` | raw production series, `*-legacy.parquet` | CPACK 2021-11 → yesterday | `historian-legacy-copy.sh` nightly; earlier one-shot backfill |
| `equipment_values_daily/` | one row per (UTC day, equipment), spike-guarded | whole days before the EV cutover | `historian-ev-daily-rollup.sh` nightly (`FULL=1` rebuild) |
| `equipment_events/` (+ `equipment_events_legacy_unpromoted/`) | downtime/status events | CPACK back to 2021 | `historian-events-backfill.sh`, `historian-events-reunload.sh` |
| `production_orders/` | PO headers with OEE | CPACK 2021-12 → yesterday | `historian-po-backfill.sh` (nightly: last month) |
| `equipment_oee_shift/` | legacy shift OEE | CPACK 2021 → yesterday | `historian-oee-shift-backfill.sh` (nightly: last month) |

The nightly job is a **legacy copy**: it reads the still-live legacy `packiot40` and remaps
legacy → F3 ids, so the archive holds complete history even for machines whose cloud feed was
lossy. `scripts/historian-append.sh` (analytics → S3) exists for after the legacy cutover but
is not what the timer runs.

Bucket safety: versioning is **Enabled** (Terraform since the 2026-09-30 backup audit; confirmed
live 2026-10-13) with noncurrent versions expired after 30 days; `equipment_values/` and
`equipment_events/` move to Intelligent-Tiering at 30 days; no data prefix expires by
lifecycle (object age is not data age; the data-age cap is `historian-prune-by-data-age.sh`).

The gateway's own catalog (boundaries, allow-list, watermarks, views) is small but hand-built;
it is dumped nightly by `backup-historian.sh`.

## Configuration that matters

| Knob | Where | Value | Effect |
|---|---|---|---|
| `mem_limit` | `compose.historian-gateway.yml` | 2560m | the kernel kills the gateway, never the shared host |
| `duckdb.memory_limit` / `max_memory` / `threads` / `max_temp_directory_size` | gateway `command:` `-c` flags | 1024 MB / 1024 MB / 2 / 8 GB | DuckDB spills or fails on its own (default was 4 GB per backend) |
| `duckdb.postgres_role` | gateway `ALTER SYSTEM` | `historian_readers` | lets NOSUPERUSER `historian_svc` run `read_parquet` |
| systemd `MemoryHigh` / `MemoryMax` / `CPUQuota` | `systemd/historian-staging-append.service` | 1400M / 1800M / 60 % | contains the nightly DuckDB job |
| `DUCKDB_MEMORY_LIMIT` | copy scripts | 1200MB (1000MB for the rollup) | in-engine bound |
| `HIST_GW_SVC_PASSWORD` | `/opt/packiot/.env` → read-api `HIST_GW_PASSWORD` | set | read-api historian endpoints answer 503 when unset |
| `promoted_enterprise` flags | gateway table | see above | the cold-side tenant fence |

## Failure modes & signals

| Symptom | Cause | Where to look |
|---|---|---|
| Totals doubled for a recent window | an EV/PO boundary not refreshed after an append | integrity monitor (staleness check); `cold.cold_append_watermark` vs `cold.ev_union_boundary.refreshed_at` |
| Another tenant's legacy data served | a non-verified id promoted | coverage check; `SELECT * FROM cold.promoted_enterprise` |
| Downtime history has gaps for some machines | EE hot-anchored boundary with partial hot coverage | `historian-ee-coverage-check.sh` (soft) |
| read-api historian returns 503 | password unset, or the gateway was down when read-api booted (the pool is built once) | read-api log `historian: … disabled`; restart read-api after the gateway is up |
| `HistorianGatewayDown` | blackbox probe of `hist-gateway:5432` failing for 5 min | `docker ps`; recreate per [Historian gateway](../components/historian-gateway.md#operating-it) |
| Cold query 403 "No credentials" | a role without its own S3 secret mapping, or a key rotation not re-cloned | [Historian gateway](../components/historian-gateway.md#failure-modes) |
| Cold query errors "only works with DuckDB execution" | `read_parquet` called inside a function, or over the extended protocol | run it top-level, simple protocol |
| App host thrashing at 02:30 UTC | unbounded DuckDB in the nightly job (2026-09-25) | fixed by cgroup + in-engine limits (#1448) |
| Hot query takes minutes | `now()` in a `live.*` filter | `EXPLAIN (VERBOSE)`: the `Remote SQL:` line must show the time filter |
| Absurd production in old months | legacy garbage (totalizer written as increment 2022-10..2023-09; the 2024-07-22 replay) | spike guard in `cold.equipment_values` and the daily rollup |

## History & decisions

- **ADR-0057** — historian storage architecture and medallion naming.
- **2026-09-04** — double-count found (a day returned 352,136 rows instead of 196,671); per-tenant cutover introduced.
- **2026-09-08** — PL/pgSQL `refresh_ev_union_boundary()` found broken (pg_duckdb cannot scan Parquet inside a function) and dropped; `ev_between()` later dropped for the same reason (t269).
- **2026-09-14** — cross-tenant id collision found; promotion allow-list (t271); gateway objects moved from `public` to `cold` (t287), then renamed to the medallion names.
- **2026-09-24** — grain-tiered retention T0–T5 live on staging; `historian_svc` least-privilege login.
- **2026-09-25** — nightly job exhausted the app host; cgroup and DuckDB limits (#1448).
- **2026-09-28** — serving audit: gateway memory caps, hot/cold split, daily rollup, cold spike guard, no `now()` through FDW (#1474).
- **2026-09-30** — historian backup added; bucket versioning codified.

ADRs: [ADR index](../../reference/adr-index.md).

## Go deeper

- [Historian gateway](../components/historian-gateway.md) — env, SQL objects, recreate procedure, query patterns.
- [read-api](../components/read-api.md) and its [API reference](../../reference/api/read-api.md) — the historian endpoints.
- [Analytics DB](analytics-db.md) — the hot side and its retention.
- [Timescale jobs & retention](../components/timescale-jobs-and-retention.md) — when rows leave the hot DB.
- [Service catalog](../../reference/service-catalog.md) — historian-gateway row.
- [DBA guide](../../build/operate/dba-guide.md#read-only-access) — how to query both safely.

!!! warning "Backups"
    The Parquet archive is the only copy of raw data older than the hot window. Bucket
    versioning is on, but there is no copy outside the bucket. See
    [Backups & restore → Known gaps](../../build/operate/backups-and-restore.md#known-gaps).
