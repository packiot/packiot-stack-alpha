---
title: Analytics DB
layer: 2
owner_area: analytics-db
last_verified: 2026-10-14
---
# Analytics DB

> **Layer 2 · Subsystems** — what the new stack's TimescaleDB database (`packiot_analytics`)
> owns, how it is laid out, who writes and reads each part, and how tenants are fenced.
> For engineers and DBAs. Up: [Architecture overview](../architecture/overview.md)

## Purpose

`packiot_analytics` is the one application database of the new stack. Every service that
writes telemetry, production orders, operator actions or configuration writes here, and every
dashboard, API and report reads from here. TimescaleDB hypertables and continuous aggregates
turn the raw per-second signal into minute and hour buckets; the `stream-engine` rollups turn
those into OEE grains. Separation is by **schema**, not by database (ADR-0056): facts,
dimensions and read views are joined constantly, and a split would only move those joins
across databases.

!!! note "Staging vs production"
    Everything here describes **staging** (`packiot_analytics` in the `timescaledb` container
    on the DB host `packiot-staging-db`). Production clients still run on the legacy platform.
    The new-stack production box today runs the `production` branch: one database `packiot`
    whose `public` schema holds a 2026-09-07 snapshot of the F3 schema
    (`compose.production.yml`: `db-schema-f3`, `DB_NAME_F3: ${POSTGRES_DB}`), no medallion
    schemas and no historian gateway. The planned promotion (draft PR #1653,
    `release/prod-promotion-2026-10`) **transplants** staging's `packiot_analytics` into prod
    instead; it has not happened yet. Do not assume production has `bronze`/`silver`/`gold`.

## Boundaries

**Owns**

- The medallion telemetry path: `bronze` (immutable landing), `silver` (cleaned facts,
  continuous aggregates, current-state snapshots), `gold` (OEE grains, PO runtimes).
- The domain tables: `core` (tenant hierarchy, equipment, routing and device bindings,
  shifts, POs, products), `config` (targets, out-of-service windows, labels, i18n),
  `identity` (users, roles, audit log), `ops` (retention catalog, replication cursors,
  data invariants, repair backups).
- The read contracts: `serving` (views and functions read by `read-api`) and `bi` (views
  read by Superset).
- Tenant isolation at the database layer (row-level security keyed on `app.tenant_id`).
- Hot retention, driven by the `ops.retention_policy` catalog.

**Does not own**

- OEE arithmetic. The rollups run in `stream-engine` and write `gold.*`
  (see [Compute](compute.md)). The database stores, aggregates and constrains.
- Deep raw history. Raw rows older than 90 days live in the historian's S3 Parquet archive
  (see [Historian](historian.md)).
- Superset's own metadata (users, dashboards): the separate `superset` database on the same
  cluster.
- The legacy platform's data (`packiot40`). A frozen F1 database named `packiot` still sits on
  the same staging cluster; nothing in the pipeline writes it.

## Components

| Component | What it does | Runtime | Layer-3 page |
|---|---|---|---|
| `timescaledb` container | PostgreSQL 15 + TimescaleDB (image `packiot-postgres:local`, built from `db/Dockerfile` on `timescale/timescaledb:2.27.0-pg15`, pinned by digest since 2026-10-14, arm64). The dev seed and the CI golden fixtures use the same pinned image: PG 15.17 / TimescaleDB 2.27.0 | DB host `packiot-staging-db`, port 5432 (started by `terraform/staging/user_data/db_init.sh`) | [Schemas](../components/analytics-db-schemas.md) |
| Timescale background jobs | cagg refresh, compression, retention, the catalog-driven purge, `serving.downtime_events_resolved` refresh, the data-invariant battery | inside Postgres | [Timescale jobs & retention](../components/timescale-jobs-and-retention.md) |
| `pgbouncer` | transaction-mode pooler for stateless clients | app host, `edoburu/pgbouncer:1.22.1-p0` | this page, [Interfaces](#interfaces) |
| `bi` schema + `superset_ro` | curated, RLS-fenced views for Superset | inside Postgres + Superset | [Superset](../components/superset.md) |
| `histgw_ro` role | least-privilege login the historian gateway uses over `postgres_fdw` | inside Postgres | [Historian gateway](../components/historian-gateway.md) |
| Nightly `pg_dump` | `terraform/staging/scripts/backup-db.sh` → S3 (`packiot`, `packiot_analytics`, `superset`); daily 14 d, weekly 4 w, monthly 3 m | DB host, `packiot-db-backup.timer` 02:00 UTC | [Backups & restore](../../build/operate/backups-and-restore.md) · [DBA guide](../../build/operate/dba-guide.md#backups) |

Every service and its README, API page and dashboard: [Service catalog](../../reference/service-catalog.md).

## How it works

```text
 sparkplug-decoder ──RabbitMQ──▶ stream-engine (direct connection)
                          │ UPSERT per sample         ┌─────────────────────────┐
                          ├─────────────────────────▶ │ silver.equipment_values │ 90 d
                          │ append (BRONZE_RAW_APPEND)│ bronze.*_raw            │ 90 d
                          │ mint / close events       │ silver.equipment_events │ 5 y
                          │                           └────────────┬────────────┘
                          │                 continuous aggregates  │ (Timescale jobs)
                          │                                        ▼
                          │        silver.equipment_categorical_1min ─▶ _1hour
                          │        silver.agg_equipment_values_*, ca_*_1s
                          │ rollup ticks read caggs + events       │
                          └──────────────────────────────▶ gold.equipment_oee_hourly
                                     ─▶ _shift ─▶ _daily ─▶ _weekly / _monthly
                                     gold.area_* / site_*, gold.production_orders_runtime

 edge-api ──pgbouncer──▶ core.*, config.*, identity.*, silver.equipment_events_man
 legacy-replicator(-sbx) ──direct──▶ core.production_orders, gold.production_orders_runtime,
                                     silver.equipment_events, silver.equipment_events_man
 barcode-service ──pgbouncer──▶ bronze.box_scans, gold.po_box_counter

 read-api (readapi_ro, RLS) ──pgbouncer──▶ serving.* ──▶ front4, operator
 Superset (superset_ro, RLS) ──direct──▶ bi.* views
 hist-gateway (histgw_ro, FDW) ──direct──▶ silver.equipment_values, silver.equipment_events,
                                           silver.equipment_categorical_1hour, core.production_orders
```

1. **Land.** `stream-engine` upserts each decoded sample into `silver.equipment_values`
   (`ON CONFLICT (ts_value, id_equipment)`, latest wins). On staging it also appends the raw
   row to `bronze.equipment_values_raw` (`BRONZE_RAW_APPEND=true`).
2. **Bucket.** Timescale refresh jobs materialize the continuous aggregates. They are
   real-time (`materialized_only = false`): a query sees the materialized buckets plus the
   not-yet-materialized tail computed from raw.
3. **Roll up.** `stream-engine` rollup ticks read the caggs and `silver.equipment_events`,
   compute OEE and write the `gold` grains; late data re-flags rows with `recalc_needed`.
   See [stream-engine rollup internals](../components/stream-engine-rollup-internals.md).
4. **Serve.** `read-api` calls `serving.*` as `readapi_ro` with `app.tenant_id` set per query;
   Superset reads `bi.*` as `superset_ro` with the GUC stamped per connection.
5. **Age out.** Compression after 7–14 days; retention drops raw rows after 90 days; the
   historian keeps the deep copy (see [Timescale jobs & retention](../components/timescale-jobs-and-retention.md)).
6. **Guard.** `ops.job_data_invariants` (Timescale job, every 30 min) runs the data-invariant
   checks into `ops.data_invariant_result`; `postgres-exporter` exposes
   `ops.data_invariant_latest` to Prometheus (alerts `DataInvariantCritical` / `DataInvariantWarn`).
   Checks against the legacy oracle are written into the same table by
   `scripts/ops/data-oracle-check.sh` (`systemd/data-oracle-check.timer`, hourly).

### The schema map

The database `search_path` is
`"$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public`,
so bare names resolve to their real home. Schemas are cut along three axes: telemetry by
**lifecycle** (bronze → silver → gold), entities by **domain** (core, config, identity, ops),
and views by **consumer** (serving, bi).

| Schema | Axis | Holds (examples) |
|---|---|---|
| `bronze` | lifecycle: raw | `equipment_values_raw`, `equipment_events_raw` (append-only, `no_mutate` triggers), `box_scans` (barcode ledger), `scanned_boxes`, `sample_boxes` |
| `silver` | lifecycle: clean | `equipment_values`, `equipment_events` (hypertables), continuous aggregates, current-state snapshots `equipment_live_*` / `area_live_*`, `equipment_events_man`, `plc_link_minutes`, `data_quality_event` |
| `gold` | lifecycle: business | `equipment_oee_{hourly,shift,daily,weekly,monthly}`, `area_oee_{shift,daily}`, `site_oee_shift`, legacy `equipment_oee_shift_{weekly,monthly}`, `production_orders_runtime`, `po_box_counter` |
| `core` | domain | `enterprises → sites → areas → equipments`, `topic_routing` (+ the `packml_register` view), `device_bindings` (ADR-0061), `shifts`, `shift_hours`, `production_orders`, `products`, `clients`, reason dimensions, `client_descriptors` |
| `config` | domain | `production_targets`, `scrap_targets`, `oee_targets`, `equipment_out_of_service`, `labels`, `label_formats`, `translations`, `pages`, `dashboard_config` |
| `identity` | domain | `users` (keyed by `id_user_cognito`), `user_roles`, `user_logs` (audit), `user_screen_config` |
| `ops` | domain | `retention_policy` / `retention_run` / `retention_drift`, `mirror_replay_cursor` / `_dlq`, `legacy_manual_event_link`, `data_invariant_*`, `capture_observations`, `idempotency_keys`, repair backups `_bkp_*` |
| `serving` | consumer: apps | read-api contract (views + functions); `downtime_events_resolved` (materialized by a Timescale job) |
| `bi` | consumer: BI | Superset contract, owned by `bi_owner` |
| `customer_reports` | consumer: exports | per-customer report pools written by `stream-engine` report jobs |
| `public` | extensions + helpers | `knex_migrations*`, legacy `piot_*` shift-calendar procedures called by `stream-engine`, `current_tenant()`, `is_all_tenant()` |

Every table and column that matters is in
[Analytics DB schemas](../components/analytics-db-schemas.md); a one-line-per-table lookup is
the [Database reference](../../reference/database-reference.md).

### Tenant isolation (RLS)

Two helper functions in `public` read the session GUC:

```sql
current_tenant()  = NULLIF(current_setting('app.tenant_id', true), '')::int
is_all_tenant()   = current_tenant() = -1
```

These tables have `ENABLE` + `FORCE ROW LEVEL SECURITY` and a policy named `tenant_isolation`
(source: `db/superset/02-tenant-rls.sql` and the migrations named below):

| Table | Policy predicate |
|---|---|
| `core.equipments`, `core.production_orders`, `config.production_targets`, `serving.downtime_events_resolved`, `core.topic_routing` (`t-topic-routing-guards`), `core.device_bindings` (`t-device-bindings`), `config.equipment_out_of_service` (`t-availability-exclusions`), `silver.plc_link_minutes` (`t-plc-link-health-rls`) | `(SELECT is_all_tenant()) OR id_enterprise = (SELECT current_tenant())` |
| `gold.equipment_oee_hourly`, `gold.equipment_oee_shift`, `gold.production_orders_runtime` | `(SELECT is_all_tenant()) OR id_equipment = ANY (ARRAY(SELECT id_equipment FROM equipments WHERE id_enterprise = (SELECT current_tenant())))` |

With the GUC unset, `current_tenant()` is NULL and every policy denies (fail-closed); `-1` is
the all-tenant sentinel. The `(SELECT fn())` wrapping makes the helpers InitPlans, evaluated
once per query instead of once per row (`t-rls-initplan-policies`, 2026-09-24).
Both helpers are `STABLE PARALLEL SAFE LEAKPROOF` (`t-rls-helpers-parallel-safe`, 2026-10-14):
while they were `PARALLEL UNSAFE` (the `CREATE FUNCTION` default), no query a NOBYPASSRLS role ran
over an RLS table could get a parallel plan.

| Role | Superuser | BYPASSRLS | Fence |
|---|---|---|---|
| `postgres` (and a staging-only human superuser) | yes | yes | none |
| `readapi_ro` | no | no | read-api stamps `app.tenant_id` per query and also filters `WHERE id_enterprise = $1` (`t276`) |
| `superset_ro` | no | no | reads only `bi.*`; Superset stamps `app.tenant_id` per connection |
| `bi_owner` (NOLOGIN) | no | no | owns the `bi.*` views, so base-table RLS applies inside them |
| `histgw_ro` | no | no | role default `app.tenant_id = -1` (all tenants); the gateway's caller adds the tenant literal (`t-historian-svc-hardening`) |
| `cloudbeaver_ro`, `cloudbeaver_rw` | no | **yes** | staff browsing via CloudBeaver (`t267`, `t271`); see all tenants |

Tables without RLS (notably `silver.equipment_values` and `silver.equipment_events`) are
fenced by the app-layer `WHERE id_enterprise = $1` and, inside `bi.*`, by the inner join to
RLS-protected `core.equipments`. Details and pitfalls:
[Tenancy & security](../architecture/tenancy-and-security.md) and
[DBA guide — RLS](../../build/operate/dba-guide.md#rls-and-definer-views).

## Interfaces

| Direction | Peer | Path | Objects |
|---|---|---|---|
| in | `stream-engine` | **direct** to the DB host (session advisory locks and per-connection `SET` rule out transaction pooling) | `bronze.*`, `silver.*`, `gold.*`, `customer_reports.*`; PO lifecycle in `core.production_orders` |
| in | `edge-api` | `pgbouncer:5432/packiot_analytics` (`POSTGRES_ANALYTICS_URL`) | CS Admin CRUD on `core` / `config`, operator actions, audit rows in `identity.user_logs` ([API](../../reference/api/edge-api.md)) |
| in | `barcode-service` | pgbouncer | `bronze.box_scans`, `gold.po_box_counter` ([API](../../reference/api/barcode-service.md)) |
| in | `legacy-replicator`, `legacy-replicator-sbx` | direct | CPACK legacy replay into `core`, `silver.equipment_events*`, `gold.production_orders_runtime`; cursors in `ops.mirror_replay_*` ([Legacy bridge](legacy-bridge.md)) |
| in | `sparkplug-agent` (capture mode) | direct | `ops.capture_observations` |
| out | `sparkplug-decoder`, `operator-gateway` | direct, read-only | `packml_register`, `equipments`, `areas`, `sites`, `client_descriptors` |
| out | `read-api` | pgbouncer, role `readapi_ro`, `DB_NAME_F3=packiot_analytics` (`REFDATA_FLOW=f3`) | `serving.*`, `core`, `gold`, `config`, `identity`; writes only `identity.user_screen_config` ([API](../../reference/api/read-api.md)) |
| out | Superset | direct (the per-connection GUC stamp would break under transaction pooling) | `bi.*` as `superset_ro` |
| out | historian gateway | direct `postgres_fdw`, role `histgw_ro` | `silver.equipment_values`, `silver.equipment_events`, `silver.equipment_categorical_1hour`, `core.production_orders` |
| out | CloudBeaver (`db.staging.packiot.app`, oauth2 gate) | direct, `cloudbeaver_ro` | staff browsing |
| out | `postgres-exporter`, `alloy-db` | direct / DB host | metrics, backup and disk textfile metrics (see [Observability](../components/observability.md)) |

**pgbouncer** (`compose.staging.yml`): `POOL_MODE=transaction`, `DEFAULT_POOL_SIZE=20`,
`MAX_CLIENT_CONN=200`, `QUERY_TIMEOUT=60`, `SERVER_IDLE_TIMEOUT=120`,
`SERVER_RESET_QUERY=ROLLBACK`. The generated config only knows the `${POSTGRES_DB}` pool; the
container `command:` injects a `[databases]` line for `packiot_analytics` with `sed` before
starting. Transaction pooling means no session state survives between statements: no
session advisory locks, no `SET` without `LOCAL`, no prepared statements across transactions.

## Data it owns

| Tier | Relations | Kept | After that |
|---|---|---|---|
| hot raw | `silver.equipment_values`, `bronze.*_raw`, 1-second and 1-minute caggs | 90 days | historian S3 archive (raw values, events) |
| hot aggregate | `silver.agg_equipment_values_1hour`, `silver.equipment_categorical_1hour`, `gold.equipment_oee_hourly` | 13 months | gone (derivable) |
| client-facing | `gold` shift/daily/weekly/monthly, area/site grains | forever | — |
| events | `silver.equipment_events` | 5 years | historian `equipment_events/` |
| business | `core.production_orders`, `gold.production_orders_runtime`, `bronze.box_scans`, `gold.po_box_counter`, `silver.equipment_events_man` | forever | — |

The single source of truth is `ops.retention_policy` (migration `t-retention-catalog`); change
it through a profile in `db/retention/profiles/` (`production.sql`, `staging-capped.sql`) and
`CALL ops.apply_retention()`. `silver.equipment_events` reaches back to 2021 for CPACK
(legacy history backfill, 2026-09-24).

## Configuration that matters

| Knob | Where | Value (staging) | Effect |
|---|---|---|---|
| `max_connections` | `db_init.sh` `-c` flag | 200 | raised from 50 on 2026-09-22 after the pool hit 49/50 |
| `shared_preload_libraries` | `db_init.sh` | `timescaledb,pg_cron,pg_stat_statements,auto_explain` | `pg_cron` is loaded but scheduling is done by Timescale jobs |
| `auto_explain.log_min_duration`, `log_min_duration_statement` | `db_init.sh` | 3000 ms | slow statements (including inside procedures) reach the PG log |
| `timescaledb.max_tuples_decompressed_per_dml_transaction` | Postgres | 100000 (default) | DML on compressed chunks aborts past this; raise with `SET LOCAL` in repairs |
| `work_mem` | Postgres | — | bounds each hash node, not the query (the 2026-09-24 OOM) |
| `BRONZE_RAW_APPEND` | `stream-engine` env | `true` | enables the bronze dual-write |
| `ops.retention_policy.keep` | table | production profile | drives Timescale retention and the catalog purge |
| `db_volume_size_gb` | `terraform/staging/variables.tf` | 128 GB gp3 | grown 64 → 128 GB on 2026-09-23; EBS cannot shrink |

## Failure modes & signals

| Symptom | Likely cause | Where to look |
|---|---|---|
| Mission Control zeros while hourly data is fresh | shift rollup transaction timing out and rolling back every tick (2026-09-22) | `gold.equipment_oee_shift` current row `computed_at IS NULL`; `pg_stat_statements` |
| One query kills every session | chunk-wise aggregation over many chunks exhausts memory; the kernel OOM-kills a backend and Postgres restarts all sessions (2026-09-24) | PG log `terminated by signal 9` |
| Repair `UPDATE`/`DELETE` fails "tuple decompression limit exceeded" | DML on compressed chunks over 100k tuples | [DBA guide](../../build/operate/dba-guide.md#timescale-gotchas) |
| Repair on compressed chunks reports `UPDATE 0` | the bound used a stable expression (`now()`, `date + 1`), which Timescale cannot use to pick compressed chunks; use literal timestamp bounds and read the rows back (2026-10-09) | compare the `UPDATE n` count with a `SELECT count(*)` of the same predicate |
| Operator / API 500s after a repair | `decompress_chunk` on the shared DB took locks the live writers needed (2026-09-30); never `decompress_chunk` on the shared DB, use row-wise DML instead | `pg_locks`, app 500s in Loki |
| Endpoint fast as superuser, slow for the app | RLS with non-leakproof predicates (2026-09-24) | reproduce as `readapi_ro` with the GUC set |
| Superset charts empty for everyone | GUC not stamped, so RLS denies | [Superset](../components/superset.md#failure-modes) |
| `DataInvariantCritical` / `DataInvariantWarn` | a standing data check failed | `SELECT * FROM ops.data_invariant_latest WHERE NOT ok` |
| `RetentionPolicyDrift` / `RetentionPurgeErrors` | catalog vs live disagree, or a purge failed | `ops.retention_drift`, `ops.retention_run` |
| `AnalyticsTimescaleJobFailing` | a Timescale job is erroring | `timescaledb_information.job_errors` |
| `BackupStale` / `BackupShrank` / `BackupMetricsMissing` | nightly dump failed, shrank, or its metrics are not reaching Prometheus | DB host journal `packiot-db-backup.service` |
| Disk filling | a relation without retention, or log growth | `HostDiskHigh` / `HostDiskFilling` |

Alerts are evaluated by Prometheus on staging; Alertmanager runs only under the compose profile
`alerting`, so check Grafana/Prometheus rather than waiting for a page.

## History & decisions

- **ADR-0056** — one application database, schemas not a control-plane split.
- **ADR-0036** — medallion data architecture (bronze/silver/gold).
- **ADR-0057** — historian storage and medallion naming (the gateway mirrors these names).
- **ADR-0061** — remove PackML names from the cloud; `core.device_bindings` replaces
  `core.topic_routing` client by client.
- **2026-09-08** — medallion separation executed on staging (`t231`): facts moved to `silver`
  with `ALTER TABLE … SET SCHEMA`.
- **2026-09-22** — `max_connections` 50 → 200; shift rollup timeout incident.
- **2026-09-23/24** — grain-tiered retention: retention catalog, CPACK history backfilled to
  2021; RLS policies rewritten as InitPlans; self-inflicted OOM from an ad-hoc whole-history
  aggregate.
- **2026-09-28/30** — `packiot_analytics` and `superset` added to the nightly backup; restore drill.
- **2026-10-01** — data invariants (`t-data-invariants`, later `-v2` … `-v10`).
- **2026-10-07** — RLS on `core.topic_routing` (`t-topic-routing-guards`).
- **2026-10-14** — [ADR-0063](../../adr/0063-timescaledb-necessity.md) (Proposed): is TimescaleDB still
  needed? Partially: keep it through production promotion, remove the waste first (summary in
  [Timescale jobs & retention](../components/timescale-jobs-and-retention.md#is-timescaledb-still-needed)).

ADRs are listed in the [ADR index](../../reference/adr-index.md).

## Go deeper

- [Analytics DB schemas](../components/analytics-db-schemas.md) — every important table, view and function.
- [Timescale jobs & retention](../components/timescale-jobs-and-retention.md) — every cagg, policy and job.
- [Superset](../components/superset.md) — the `bi` contract and the embed flow.
- [Historian](historian.md) — where raw history goes after 90 days.
- [Database reference](../../reference/database-reference.md) — table → grain → writer → retention.
- [Service catalog](../../reference/service-catalog.md) — every service that touches the DB.
- [DBA guide](../../build/operate/dba-guide.md) — safe queries, repairs, backups, access.
