---
title: Analytics DB
layer: 2
owner_area: analytics-db
last_verified: 2026-09-28
---
# Analytics DB

> **Layer 2 · Subsystems** — what the new stack's TimescaleDB database (`packiot_analytics`)
> owns, how it is laid out, who writes and reads each part, and how tenants are fenced.
> For engineers and DBAs. Up: [Architecture overview](../architecture/overview.md)

## Purpose

`packiot_analytics` is the one application database of the new stack. Every service that
writes telemetry, production orders, operator actions or configuration writes here, and every
dashboard, API and report reads from here. It is not a passive store: TimescaleDB
hypertables and continuous aggregates turn the raw per-second signal into minute and hour
buckets, and the `stream-engine` rollups turn those into OEE grains. Separation is by
**schema**, not by database (ADR-0056): coupling between facts, dimensions and read views
lives in joins, and a split would only move those joins across databases.

!!! note "Staging vs production"
    Everything on this page was read from the **staging** cluster on 2026-09-28
    (`packiot_analytics` on the DB host `10.10.10.89`). Production runs the same F3 schema,
    but in a database named `packiot` whose objects live in `public` (see
    `compose.production.yml`, which points `DB_NAME_F3` at `${POSTGRES_DB}`), and it has no
    historian gateway. The medallion schema split (`t231-medallion-schema-separation`) was
    executed on staging; do not assume production has `bronze`/`silver`/`gold`.

## Boundaries

**Owns**

- The medallion telemetry path: `bronze` (immutable landing), `silver` (cleaned facts,
  continuous aggregates, current-state snapshots), `gold` (OEE grains, PO runtimes).
- The domain tables: `core` (tenant hierarchy, equipment, shifts, POs, products),
  `config` (targets, labels, i18n), `identity` (users, roles, audit log), `ops`
  (retention catalog, replication cursors, repair backups).
- The read contracts: `serving` (views and functions read by `read-api`) and `bi` (views
  read by Superset).
- Tenant isolation at the database layer (row-level security keyed on `app.tenant_id`).
- Hot retention: raw telemetry 90 days, hourly grains 13 months, business grains forever.

**Does not own**

- OEE arithmetic. The rollups run in `stream-engine` and write `gold.*`
  (see [Compute](compute.md)). The database only stores and aggregates.
- Deep raw history. Raw rows older than 90 days live in the historian's S3 Parquet archive
  (see [Historian](historian.md)).
- Superset's own metadata (users, dashboards) — that is the separate `superset` database on
  the same cluster.
- The legacy platform's data (`packiot40` on the legacy host). A frozen F1 database named
  `packiot` (3.8 GB) still exists on the same staging cluster; it is out of the pipeline.

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| `timescaledb` container | PostgreSQL 15.17 + TimescaleDB 2.27.0 (Alpine/musl, aarch64), 14 GB database | DB host `i-064bb36d1c454d861`, 10.10.10.89:5432 | [Schemas](../components/analytics-db-schemas.md) |
| Timescale background jobs | 29 jobs: cagg refresh, compression, retention, the catalog-driven purge, the downtime-resolved refresh | inside Postgres | [Timescale jobs & retention](../components/timescale-jobs-and-retention.md) |
| `pgbouncer` | transaction-mode pooler in front of the DB for stateless clients | app host, `edoburu/pgbouncer:1.22.1-p0`, 172.18.0.10 | this page, [Interfaces](#interfaces) |
| `bi` schema + `superset_ro` | curated, RLS-fenced views for Superset | inside Postgres + Superset containers | [Superset](../components/superset.md) |
| `histgw_ro` role | least-privilege login the historian gateway uses over `postgres_fdw` | inside Postgres | [Historian gateway](../components/historian-gateway.md) |
| Nightly `pg_dump` | `terraform/staging/scripts/backup-db.sh` → S3 | DB host systemd timer 02:00 UTC | [DBA guide](../operations/dba-guide.md#backups) |

## How it works

```text
 sparkplug-decoder ──RabbitMQ──▶ stream-engine (oeecloud-worker)
                          │ UPSERT per sample         ┌─────────────────────────┐
                          ├─────────────────────────▶ │ silver.equipment_values │ 1-day chunks, 90 d
                          │ append (BRONZE_RAW_APPEND)│ bronze.*_raw            │ 90 d
                          │ mint / close events       │ silver.equipment_events │ 5 y
                          │                           └────────────┬────────────┘
                          │                 continuous aggregates  │ (Timescale jobs)
                          │                                        ▼
                          │        silver.equipment_categorical_1min ─▶ _1hour
                          │        silver.equipment_metrics_1min, agg_*, ca_*_1s
                          │ rollup ticks read caggs + events       │
                          └──────────────────────────────▶ gold.equipment_oee_hourly
                                     ─▶ _shift ─▶ _daily ─▶ _weekly / _monthly
                                     gold.area_* / site_*, gold.production_orders_runtime

 edge-api ──pgbouncer──▶ core.*, config.*, identity.*, silver.equipment_events_man
 analytics-sync, legacy-replicator ──direct──▶ core.production_orders, silver.equipment_events
 barcode-service ──pgbouncer──▶ bronze.box_scans, gold.po_box_counter

 read-api (readapi_ro, RLS) ──▶ serving.* functions/views ──▶ front4, operator
 Superset (superset_ro, RLS) ──▶ bi.* views
 hist-gateway (histgw_ro, FDW) ──▶ silver.equipment_values, silver.equipment_events,
                                   silver.equipment_categorical_1hour, core.production_orders
```

The main flow, in words:

1. **Land.** `stream-engine` upserts each decoded sample into `silver.equipment_values`
   (primary key `(id_equipment, ts_value)`, latest wins). On staging it also appends the raw
   row to `bronze.equipment_values_raw` (flag `BRONZE_RAW_APPEND=true`, `compose.staging.yml`).
2. **Bucket.** Timescale refresh jobs materialize the continuous aggregates every 1–30 minutes.
   All of them are real-time (`materialized_only = false`): a query sees the materialized buckets
   plus the not-yet-materialized tail computed from raw.
3. **Roll up.** `stream-engine` rollup ticks read the caggs and `silver.equipment_events`,
   compute OEE and write the `gold` grains, flagging rows with `recalc_needed` when late data
   arrives. See [stream-engine rollup internals](../components/stream-engine-rollup-internals.md).
4. **Serve.** `read-api` calls `serving.*` functions as `readapi_ro` with `app.tenant_id` set
   per query; Superset reads `bi.*` as `superset_ro` with the GUC stamped per connection.
5. **Age out.** Compression after 7–14 days, retention drops raw after 90 days, and the
   historian keeps the deep copy (see [Timescale jobs & retention](../components/timescale-jobs-and-retention.md)).

### The schema map

The database `search_path` is
`"$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public`,
so bare names resolve to their real home. Schemas are cut along three axes: telemetry by
**lifecycle** (bronze → silver → gold), entities by **domain** (core, config, identity, ops),
and views by **consumer** (serving, bi).

| Schema | Axis | Tables / views (2026-09-28) | Holds |
|---|---|---|---|
| `bronze` | lifecycle: raw | 5 tables | `equipment_values_raw`, `equipment_events_raw` (append-only, `no_mutate` triggers), `box_scans` (barcode ledger), `scanned_boxes`, `sample_boxes` |
| `silver` | lifecycle: clean | 14 tables, 9 views | `equipment_values`, `equipment_events` (hypertables), 7 continuous aggregates, current-state snapshots `equipment_live_*`/`area_live_*`, event side-planes, `data_quality_event`, `machine_state` |
| `gold` | lifecycle: business | 12 tables | `equipment_oee_{hourly,shift,daily,weekly,monthly}`, `area_oee_{shift,daily}`, `site_oee_shift`, legacy `equipment_oee_shift_{weekly,monthly}`, `production_orders_runtime`, `po_box_counter` |
| `core` | domain | 20 tables, 1 view | `enterprises → sites → areas → equipments`, `topic_routing` (+ `packml_register` shim view), `shifts`, `shift_hours`, `production_orders`, `products`, `clients`, reason dimensions, `client_descriptors` |
| `config` | domain | 10 tables | `production_targets`, `scrap_targets`, `oee_targets`, `labels`, `label_formats`, `translations`, `pages`, `dashboard_config` |
| `identity` | domain | 4 tables | `users` (keyed by `id_user_cognito`), `user_roles`, `user_logs` (audit), `user_screen_config` |
| `ops` | domain | 25 tables, 1 view | `retention_policy` / `retention_run` / `retention_drift`, `mirror_replay_cursor` / `_dlq`, `capture_observations`, `idempotency_keys`, repair backups `_bkp_*` |
| `serving` | consumer: apps | 2 tables, 9 views, 48 functions | read-api contract; `downtime_events_resolved` (materialized by a Timescale job) |
| `bi` | consumer: BI | 12 views | Superset contract, owned by `bi_owner` |
| `customer_reports` | consumer: customer exports | 4 tables | per-customer report pools written by `stream-engine` reports |
| `public` | extensions + legacy functions | 2 tables | `knex_migrations*`, 33 non-extension functions (legacy `piot_*` shift-calendar provisioning procs called by `stream-engine`, `current_tenant()`, `is_all_tenant()`, `purge_analytics_plain`) |

Every table and column that matters is described in
[Analytics DB schemas](../components/analytics-db-schemas.md); a one-line-per-table lookup is
in the [Database reference](../reference/database-reference.md).

### Tenant isolation (RLS)

Two helper functions in `public` read the session GUC:

```sql
current_tenant()  = NULLIF(current_setting('app.tenant_id', true), '')::int
is_all_tenant()   = current_tenant() = -1
```

Seven tables have `ENABLE` + `FORCE ROW LEVEL SECURITY` and a policy named `tenant_isolation`:

| Table | Policy predicate |
|---|---|
| `core.equipments`, `core.production_orders`, `config.production_targets`, `serving.downtime_events_resolved` | `(SELECT is_all_tenant()) OR id_enterprise = (SELECT current_tenant())` |
| `gold.equipment_oee_hourly`, `gold.equipment_oee_shift`, `gold.production_orders_runtime` | `(SELECT is_all_tenant()) OR id_equipment = ANY (ARRAY(SELECT id_equipment FROM equipments WHERE id_enterprise = (SELECT current_tenant())))` |

With the GUC unset, `current_tenant()` is NULL and every policy denies (fail-closed). `-1` is
the all-tenant sentinel. The `(SELECT fn())` wrapping makes the helpers InitPlans evaluated
once per query instead of once per row (migration `t-rls-initplan-policies`, 2026-09-24).

Who is fenced, and how:

| Role | Superuser | BYPASSRLS | Login | Fence |
|---|---|---|---|---|
| `postgres`, `dev@packiot.com` | yes | yes | yes | none (staging-only human superuser exists) |
| `readapi_ro` | no | no | yes | read-api stamps `app.tenant_id` per query; also filters `WHERE id_enterprise = $1` (migration `t276`) |
| `superset_ro` | no | no | yes | reads only `bi.*`; Superset stamps `-c app.tenant_id=<n>` per connection |
| `bi_owner` | no | no | no | owns the `bi.*` views, so the base-table RLS applies inside them |
| `histgw_ro` | no | no | yes | role default `app.tenant_id=-1` (all tenants); the tenant literal is added by the gateway's caller |
| `cloudbeaver_ro`, `cloudbeaver_rw` | no | **yes** | yes | staff browsing via CloudBeaver; see all tenants |

Tables without RLS (notably `silver.equipment_values` and `silver.equipment_events`) are
fenced by the app-layer `WHERE id_enterprise = $1` and, inside `bi.*`, by the inner join to
RLS-protected `core.equipments`. Details and pitfalls:
[Tenancy & security](../architecture/tenancy-and-security.md) and
[DBA guide — RLS](../operations/dba-guide.md#rls-and-definer-views).

## Interfaces

| Direction | Peer | Path | Protocol / object |
|---|---|---|---|
| in | `stream-engine` (oeecloud-worker) | **direct** to 10.10.10.89 (session advisory locks and per-connection `SET` rule out transaction pooling) | UPSERT `silver.*`, rollups into `gold.*`, `core.production_orders` via pocontrol |
| in | `edge-api` | `pgbouncer:5432/packiot_analytics` (`POSTGRES_ANALYTICS_URL`) | CS Admin CRUD on `core`/`config`, operator actions, audit rows in `identity.user_logs` |
| in | `barcode-service` | pgbouncer | `bronze.box_scans`, `gold.po_box_counter` (advisory-lock counter) |
| in | `analytics-sync`, `legacy-replicator` | direct | CPACK legacy replay into `core`, `silver.equipment_events`, `gold.production_orders_runtime`; cursors in `ops.mirror_replay_*` |
| in | `sparkplug-decoder` agent | direct | `ops.capture_observations` |
| out | `read-api` | pgbouncer, role `readapi_ro`, `DB_NAME_F3=packiot_analytics`, `REFDATA_FLOW=f3` | `serving.*` functions/views, `core`, `gold`, `config`, `identity` |
| out | Superset | direct (the per-connection GUC stamp would break under transaction pooling) | `bi.*` as `superset_ro` |
| out | historian gateway | direct `postgres_fdw`, role `histgw_ro` | `silver.equipment_values`, `silver.equipment_events`, `silver.equipment_categorical_1hour`, `core.production_orders` |
| out | CloudBeaver (`db.staging.packiot.app`, cs-admin gate) | direct, `cloudbeaver_ro` | read-only browsing |
| out | `postgres-exporter`, `alloy-db` | direct | metrics (see [Observability](../components/observability.md)) |

**pgbouncer** (`compose.staging.yml`): `POOL_MODE=transaction`, `DEFAULT_POOL_SIZE=20`,
`MAX_CLIENT_CONN=200`, `QUERY_TIMEOUT=60`, `SERVER_IDLE_TIMEOUT=120`,
`SERVER_RESET_QUERY=ROLLBACK`. The generated config only knows the `${POSTGRES_DB}` pool; the
container `command:` injects a second `[databases]` line for `packiot_analytics` with `sed`
before starting. Older comments in the compose file saying pgbouncer "doesn't include
packiot_analytics" predate that line. Transaction pooling means no session state survives
between statements: no session advisory locks, no `SET` without `LOCAL`, no prepared
statements across transactions.

## Data it owns

| Tier | Relations | Kept | After that |
|---|---|---|---|
| hot raw | `silver.equipment_values`, `bronze.*_raw`, 1-second and 1-minute caggs | 90 days | historian S3 archive (raw values, events) |
| hot aggregate | `silver.agg_equipment_values_1hour`, `silver.equipment_categorical_1hour`, `gold.equipment_oee_hourly` | 13 months | gone (derivable) |
| client-facing | `gold` shift/daily/weekly/monthly, area/site grains | forever | — |
| events | `silver.equipment_events` | 5 years | historian `equipment_events` |
| business | `core.production_orders`, `gold.production_orders_runtime`, `bronze.box_scans`, `gold.po_box_counter`, `silver.equipment_events_man` | forever | historian `production_orders` |

The single source of truth is the table `ops.retention_policy`
(migration `db/migrations/t-retention-catalog`); change it through a profile in
`db/retention/profiles/` and `CALL ops.apply_retention()`. Coverage on 2026-09-28:
`silver.equipment_values` chunks from 2026-07-01, `silver.equipment_events` from 2021-12-15
(the CPACK legacy history backfill of 2026-09-24).

## Configuration that matters

| Knob | Where | Value (staging) | Effect |
|---|---|---|---|
| `max_connections` | Postgres | 200 | raised from 50 on 2026-09-22 after the pool hit 49/50 |
| `shared_buffers` / `work_mem` / `hash_mem_multiplier` | Postgres | 4 GB / 64 MB / 2 | `work_mem` bounds each hash node, not the query (see the 2026-09-24 OOM) |
| `timescaledb.max_tuples_decompressed_per_dml_transaction` | Postgres | 100000 (default) | DML touching compressed chunks aborts past this; raise with `SET LOCAL` in repairs |
| `timescaledb.max_background_workers` | Postgres | 12 | caps concurrent Timescale jobs |
| `shared_preload_libraries` | Postgres | `timescaledb,pg_cron,pg_stat_statements,auto_explain` | `pg_cron` is loaded but not installed in `packiot_analytics`; scheduling is Timescale jobs |
| `BRONZE_RAW_APPEND` | `stream-engine` env | `true` | enables the bronze dual-write |
| `ops.retention_policy.keep` | table | production profile | drives Timescale retention and job 1033 |
| DB EBS volume | `terraform/staging/variables.tf` | 128 GB gp3 | grown 64→128 GB on 2026-09-23; EBS cannot shrink |

## Failure modes & signals

| Symptom | Likely cause | Where to look |
|---|---|---|
| Mission Control or dashboards show zeros while hourly data is fresh | shift rollup transaction timing out and rolling back every tick (2026-09-22) | `gold.equipment_oee_shift` current-shift row `computed_at IS NULL`, `pg_stat_statements` mean time |
| A query on `silver.equipment_events` kills the whole cluster | chunk-wise partial aggregation over many chunks exhausts memory; kernel OOM kills a backend and Postgres restarts all sessions (2026-09-24) | PG log `terminated by signal 9` + `Failed process was running:` |
| Repair `UPDATE`/`DELETE` fails "tuple decompression limit exceeded" | DML on compressed chunks over 100k tuples | [DBA guide](../operations/dba-guide.md#timescale-gotchas) |
| Endpoint is fast as superuser, slow for the app | RLS with non-leakproof predicates (2026-09-24) | reproduce as `readapi_ro` with the GUC |
| Superset charts empty for everyone | GUC not stamped, so RLS denies | [Superset](../components/superset.md#failure-modes) |
| Retention alert `RetentionPolicyDrift` / `RetentionPurgeErrors` | catalog vs live disagree, or a purge failed | `SELECT * FROM ops.retention_drift`, `ops.retention_run` |
| Disk filling | a cagg without retention, Docker log growth on the DB host | `HostDiskHigh` alert (80 %) |

## History & decisions

- **ADR-0056** — one application database, schemas not a control-plane split.
- **ADR-0036** — medallion data architecture (bronze/silver/gold).
- **ADR-0057** — historian storage and medallion naming (the gateway mirrors these names).
- **2026-09-08** — medallion separation executed on staging: facts moved to `silver` with
  `ALTER TABLE … SET SCHEMA` (catalog-only for hypertables).
- **2026-09-09** — the last `public` compat shims dropped (de-shim epic #251).
- **2026-09-22** — `max_connections` 50 → 200; shift rollup timeout incident.
- **2026-09-23/24** — grain-tiered retention (T0–T5): retention catalog, CPACK history
  backfilled to 2021, chunk merge of `silver.equipment_events` (1,483 → 156 chunks).
- **2026-09-24** — RLS policies rewritten as InitPlans; self-inflicted OOM crash from an
  ad-hoc whole-history aggregate.

ADRs are listed in the [ADR index](../reference/adr-index.md).

## Go deeper

- [Analytics DB schemas](../components/analytics-db-schemas.md) — every important table, view and function.
- [Timescale jobs & retention](../components/timescale-jobs-and-retention.md) — every cagg, policy and job.
- [Superset](../components/superset.md) — the `bi` contract and the embed flow.
- [Historian](historian.md) — where raw history goes after 90 days.
- [Database reference](../reference/database-reference.md) — table → grain → writer → retention.
- [DBA guide](../operations/dba-guide.md) — safe queries, repairs, backups, access.
