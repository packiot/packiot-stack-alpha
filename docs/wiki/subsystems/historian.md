---
title: Historian
layer: 2
owner_area: historian
last_verified: 2026-09-28
---
# Historian

> **Layer 2 · Subsystems** — how Packiot keeps years of raw telemetry, downtime events,
> production orders and shift OEE outside the hot database, and how consumers query "now"
> and "three years ago" through one SQL surface. For engineers, DBAs and anyone building a
> long-range chart. Up: [Architecture overview](../architecture/overview.md)

## Purpose

The [analytics DB](analytics-db.md) keeps raw telemetry for only 90 days, because raw rows
dominate storage cost (about 1.3 GB per 90 days) while clients mostly read small aggregates.
The historian is the **archive of record** for everything older: monthly Parquet files on S3,
partitioned by tenant, year and month. A small Postgres instance with the `pg_duckdb` and
`postgres_fdw` extensions — the **historian gateway** — exposes union views that glue the
live tail (read through a foreign table from the analytics DB) to the cold archive, so a
consumer writes plain SQL and never has to know where a row lives. The historian exists on
**staging only**; production has no gateway yet.

## Boundaries

**Owns**

- The S3 cold archive (`equipment_values`, `equipment_events`, `production_orders`,
  `equipment_oee_shift`, `equipment_values_daily` prefixes).
- The gateway database `packiot_historian` (container `hist-gateway`) and its serving views.
- The per-tenant **promotion allow-list** and **cutover boundaries** that keep hot and cold
  disjoint and keep tenants apart.
- The nightly job that extends the archive, and the integrity monitor that checks it.

**Does not own**

- Hot data. The gateway never stores rows; `live.*` are foreign tables onto
  `packiot_analytics`.
- Client-facing aggregates. Gold OEE grains, POs and events are kept long **in the analytics
  DB** (grain-tiered retention), so `serving.*` functions and `bi.*` views need no historian.
- Tenant authentication. The gateway has no RLS; the caller must pass the tenant as a literal.

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| `hist-gateway` | Postgres 16 + `pg_duckdb` + `postgres_fdw`; union views over hot FDW and cold Parquet | app host, `pgduckdb/pgduckdb:16-main`, `compose.historian-gateway.yml` | [Historian gateway](../components/historian-gateway.md) |
| S3 bucket | Hive-partitioned Parquet `<table>/enterprise=E/year=Y/month=M/*.parquet` | `packiot-staging-historian-<account>` (Terraform `terraform/staging/historian.tf`) | [Historian gateway](../components/historian-gateway.md#storage-layout) |
| Nightly append | `historian-staging-append.timer` 02:30 UTC → `historian-staging-run-append.sh` | app host systemd, DuckDB CLI in a capped cgroup | [Historian gateway](../components/historian-gateway.md#operating-it) |
| Integrity monitor | `historian-integrity-monitor.timer` 04:00 UTC; cutover coverage, staleness, EE coverage | app host systemd | [Historian gateway](../components/historian-gateway.md#observability) |
| read-api historian pool | `POST /v1/historian/production-series`, `/downtime-series` | `read-api`, 4-connection pool as `historian_svc` | [read-api](../components/read-api.md) |
| Superset `historian_union` | one virtual dataset on `silver.equipment_values` | Superset | [Superset](../components/superset.md) |

## How it works

```text
                    historian gateway  (hist-gateway, db packiot_historian)
                    ┌──────────────────────────────────────────────────────────────┐
  read-api ────────▶│ silver.equipment_values   = live tail  ∪  promoted cold       │
  (historian_svc)   │ silver.equipment_events   = all hot   ∪  cold before cutover  │
  Superset ────────▶│ silver.production_orders  = live tail  ∪  promoted cold       │
                    │ cold.equipment_values_daily (pre-aggregated, read-api only)   │
                    │                                                              │
                    │  live.*  ── postgres_fdw (histgw_ro) ──▶ packiot_analytics    │
                    │  cold.*  ── pg_duckdb read_parquet ────▶ s3://…/ *.parquet    │
                    │  cold.promoted_enterprise, *_union_boundary, watermarks       │
                    └──────────────────────────────────────────────────────────────┘
                                   ▲ refresh boundaries (psql)
  02:30 UTC  historian-staging-run-append.sh
     legacy packiot40 ──DuckDB CLI──▶ S3  (EV, PO, shift OEE: current + previous month)
     then stamp watermark → refresh EV/EE/PO boundaries → daily EV rollup
  04:00 UTC  historian-integrity-monitor.sh  (coverage, staleness, EE coverage)
```

### Grain-tiered retention (the design this subsystem is part of)

The plan `docs/plans/unified-hot-cold-serving-grain-tiered-retention.md` (proposed ADR-0060)
splits data by **grain**, the way Prometheus + Thanos or RRDtool do: resolution decays with age.

| Tier | Data | Lives in | Kept | Served by |
|---|---|---|---|---|
| 1 hot aggregates | gold OEE shift/day/week/month, POs, PO runtimes, events | analytics DB | forever / 5 y | `serving.*`, `bi.*` unchanged, full RLS |
| 1 hourly | hourly caggs, `gold.equipment_oee_hourly` | analytics DB | 13 months | same |
| 2 hot raw | `silver.equipment_values`, bronze, 1 s / 1 min caggs | analytics DB | 90 days | same |
| 3 archive | raw EV, EE, POs, shift OEE, 2021 → now | historian S3 | forever (staging may be capped) | gateway, only for raw deep dives |

The work was delivered as six workstreams, all live on staging and **not promoted to
production** (user decision, 2026-09-24):

| Workstream | What it delivered |
|---|---|
| T0 | `ops.retention_policy` catalog + `ops.apply_retention()`; gold shift/hourly no longer purged at 90 days; DB disk 64 → 128 GB |
| T1 | CPACK legacy history (2021 →) backfilled into analytics gold, POs and events |
| T2 | read-api coverage headers (`X-Data-Hot-Floor`, `Warning: 299`) instead of silent truncation |
| T3 | gateway hardening: NOSUPERUSER `historian_svc`, `duckdb.postgres_role=historian_readers`, remote `histgw_ro` |
| T4 | Superset `historian_union` connection synced by `sync_databases.py` |
| T5 | env-templated Superset URI, `historian-prune-by-data-age.sh` for a future staging cap |

### Hot/cold disjointness per tenant

A naive `hot UNION ALL cold` double-counts wherever both sides hold the same period. Each
table therefore has a per-tenant **cutover**:

| Union view | Anchor | Cold owns | Hot owns | Boundary table / refresh |
|---|---|---|---|---|
| `silver.equipment_values` | cold: `max(cold ts_value)` | `ts ≤ cutover` | `ts > cutover` | `cold.ev_union_boundary` / `refresh-equipment_values-cutover.sql` |
| `silver.production_orders` | cold: `max(cold ts_start)` | `ts_start ≤ cutover` | `ts_start > cutover` | `cold.po_union_boundary` / `refresh-po-cutover.sql` |
| `silver.equipment_events` | **hot**: `min(hot ts_event)` | `ts < cutover` | all hot rows | `cold.ee_union_boundary` / `refresh-ee-cutover.sql` |

Events are hot-anchored because the CPACK "phase C" backfill loaded pre-cutover events,
with irreplaceable operator notes, **into** the analytics DB. The boundaries must be refreshed
after every archive extension; a stale EV boundary serves the newly archived window twice.

### Promotion (the tenant fence on the cold side)

The archive was written with **legacy** enterprise ids, and some collide with F3 tenant ids
(legacy partition `enterprise=6` is a different company from F3 tenant 6). A query for id 6
once returned 16.7 M rows of another company's data (2026-09-14). The fix is an explicit,
audited allow-list, `cold.promoted_enterprise`, which the union views **inner join** on the
cold side:

| Tenant | `ev_promoted` | `ee_promoted` | `po_promoted` | Why (init-script seed) |
|---|---|---|---|---|
| 3 CPACK | yes | yes | yes | cold `id_equipment` {47..108} equals `core.equipments` of tenant 3 (legacy 1 → 3 remap) |
| 4 Incoplast | yes | no | no | cold EV {990015..990018} equals tenant 4's equipment; EE still in legacy id space |
| 5 Bispharma and 20 other ids | no | no | no | documentary rows: native, collision, or passthrough; never served |

To promote a tenant: prove cold `id_equipment ⊆ core.equipments(id)`, re-key the partition to
the F3 id on disk if needed (`scripts/historian-events-reunload.sh`), set the flag, refresh the
boundary, run the coverage check. Never hand-add an unverified id.

### Pruning and the two serving rules

DuckDB prunes Parquet files only on partition columns. A one-day query filtered on
`ts_value` alone read 59 of 836 files in 171 s; adding `year = 2026 AND month = 9` read 1
file in 0.57 s. So every union view surfaces `year` and `month`, and **every query must carry
a year/month predicate and an `id_enterprise = <literal>`**.

Since the 2026-09-28 audit (PR #1474, migration `t-historian-serving-guards`) read-api no
longer uses the mixed union for its endpoints. It runs hot and cold as separate statements
and merges in Go (`services/read-api/cmd/refdata-api/historian_split.go`):

| Endpoint | Cold (pure DuckDB) | Hot (pure FDW) |
|---|---|---|
| `production-series` | `cold.equipment_values_daily`, days before `cold.ev_daily_watermark.covered_until` | `live.equipment_values_1hour` (= analytics `silver.equipment_categorical_1hour`), days after |
| `downtime-series` | `cold.equipment_events`, EE-promoted tenants only, before `ee_union_boundary` | `live.equipment_events` aggregated per UTC day |

Measured after the change: 1 year in 2.3 s, 5 years in 8.6 s (was about 25 s per 30 days).
Two rules came out of that audit: **never bound a `live.*` query with `now()`** (postgres_fdw
does not ship it, so the whole remote table is pulled: 173 s vs 59 ms), and **long windows
read daily rollups, never per-second rows**.

## Interfaces

| Direction | Peer | Protocol | Object |
|---|---|---|---|
| in | analytics DB | `postgres_fdw` server `live_pg` → 10.10.10.89, remote role `histgw_ro` | `silver.equipment_values`, `silver.equipment_events`, `silver.equipment_categorical_1hour`, `core.production_orders` |
| in | S3 | `pg_duckdb` `read_parquet` with a per-role S3 secret (IAM user `svc-historian-gateway`, read-only) | `s3://<bucket>/<table>/enterprise=/year=/month=/` |
| in | legacy `packiot40` | DuckDB CLI `postgres` attach, read-only | nightly copy of the last two months |
| out | read-api | Postgres wire, **simple query protocol**, `historian_svc`, pool of 4 | `/v1/historian/production-series`, `/v1/historian/downtime-series` |
| out | Superset | Postgres wire, `historian_svc@hist-gateway:5432/packiot_historian` | dataset on `silver.equipment_values`, SQL Lab disabled |
| out | CloudBeaver | `cloudbeaver_histro` (hot browsing only; cannot run `read_parquet`) | schema browsing |

## Data it owns

| S3 prefix | Content | Coverage (staging) | Writer |
|---|---|---|---|
| `equipment_values/` | raw production series, `*-legacy.parquet` | CPACK 2021-11 → yesterday (about 336 M rows) | `historian-legacy-copy.sh` nightly; earlier one-shot backfill |
| `equipment_values_daily/` | one row per (UTC day, equipment), spike-guarded | whole days before the EV cutover | `historian-ev-daily-rollup.sh` nightly (`FULL=1` rebuild) |
| `equipment_events/` (+ `equipment_events_legacy_unpromoted/`) | downtime/status events | CPACK back to 2021 | `historian-events-backfill.sh`, `historian-events-reunload.sh` |
| `production_orders/` | PO headers with OEE | CPACK 2021-12 → yesterday | `historian-po-backfill.sh` (nightly: last month) |
| `equipment_oee_shift/` | legacy shift OEE | CPACK 2021 → yesterday | `historian-oee-shift-backfill.sh` (nightly: last month) |

The nightly job is currently a **legacy copy**: it reads the still-live legacy `packiot40`
and remaps legacy → F3 ids, so the archive holds complete history even for machines whose
cloud feed was lossy. `scripts/historian-append.sh` (new-stack F3 → S3) exists for after the
legacy cutover but is not what the timer runs. S3 versioning is off on this bucket.

## Configuration that matters

| Knob | Where | Value | Effect |
|---|---|---|---|
| `mem_limit` | `compose.historian-gateway.yml` | 2560m | the kernel kills the gateway, never the shared host |
| `duckdb.memory_limit` / `max_memory` / `threads` | gateway `command:` `-c` flags | 1024 MB / 1024 MB / 2 per backend | DuckDB spills or fails on its own (default was 4 GB per backend) |
| `duckdb.postgres_role` | `ALTER SYSTEM` (postgresql.auto.conf) | `historian_readers` | lets NOSUPERUSER `historian_svc` run `read_parquet` |
| systemd `MemoryHigh` / `MemoryMax` / `CPUQuota` | `systemd/historian-staging-append.service` | 1400M / 1800M / 60 % | contains the nightly DuckDB job |
| `DUCKDB_MEMORY_LIMIT` | copy scripts | 1200MB (1000MB for the rollup) | in-engine bound |
| `HIST_GW_PASSWORD` | `/opt/packiot/.env` | set | read-api historian pool is disabled (503) when unset |
| `promoted_enterprise` flags | gateway table | see above | the cold-side tenant fence |

## Failure modes & signals

| Symptom | Cause | Where to look |
|---|---|---|
| Totals doubled for a recent window | an EV/PO boundary not refreshed after an append | integrity monitor (staleness check), `cold.cold_append_watermark` vs `ev_union_boundary.refreshed_at` |
| Another tenant's legacy data served | a non-verified id promoted | coverage check; `SELECT * FROM cold.promoted_enterprise` |
| Downtime history has gaps for some machines | EE hot-anchored boundary with partial hot coverage | `historian-ee-coverage-check.sh` (soft alert) |
| read-api historian returns 503 | `HIST_GW_PASSWORD` unset or gateway down at read-api boot | read-api log `historian: … disabled` |
| Cold query 403 "No credentials" | a role without its own `simple_s3_secret` user mapping, or a key rotation not re-cloned | [Historian gateway](../components/historian-gateway.md#failure-modes) |
| App host thrashing at 02:30 UTC | unbounded DuckDB in the nightly job (incident 2026-09-25) | fixed by cgroup + in-engine limits (#1448) |
| Hot query takes minutes | `now()` in a `live.*` filter | `EXPLAIN (VERBOSE)`, the `Remote SQL:` line must show the time filter |
| Absurd production numbers in old months | legacy garbage (totalizer written as increment 2022-10..2023-09, 2024-07-22 replay) | spike guard in `cold.equipment_values` and the daily rollup |

## History & decisions

- **ADR-0057** — historian storage architecture and medallion naming.
- **2026-09-04** — double-count found (a day returned 352,136 rows instead of 196,671); per-tenant cutover introduced.
- **2026-09-08** — a live-only PL/pgSQL `refresh_ev_union_boundary()` found broken (pg_duckdb cannot scan Parquet inside a function) and dropped.
- **2026-09-14** — cross-tenant id collision found; promotion allow-list (t271); objects moved from `public` to `cold` (t287).
- **2026-09-24** — grain-tiered retention T0–T5 live on staging; `historian_svc` least-privilege login.
- **2026-09-25** — nightly job exhausted the 8 GB app host; cgroup and DuckDB limits (#1448).
- **2026-09-28** — serving audit: gateway memory caps, hot/cold split, daily rollup, cold spike guard, no `now()` through FDW (#1474).

ADRs: [ADR index](../reference/adr-index.md).

## Go deeper

- [Historian gateway](../components/historian-gateway.md) — env, SQL objects, recreate procedure, query patterns.
- [Analytics DB](analytics-db.md) — the hot side and its retention.
- [Timescale jobs & retention](../components/timescale-jobs-and-retention.md) — when rows leave the hot DB.
- [DBA guide](../operations/dba-guide.md#read-only-access) — how to query both safely.
