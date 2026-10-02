---
title: Analytics DB schemas
layer: 3
owner_area: analytics-db
last_verified: 2026-09-28
---
# Analytics DB schemas

> **Layer 3 · Components** — schema by schema, every table, view and function in
> `packiot_analytics` that matters: what it is for, its grain and key columns, who writes it
> and who reads it. Read from the staging catalog on 2026-09-28 and cross-checked against the
> Go code and migrations. Up: [Analytics DB](../subsystems/analytics-db.md)

## Responsibility

The schema is the contract between the writers (`stream-engine`, `edge-api`,
`barcode-service`, `analytics-sync`) and the readers (`read-api`, Superset, the historian
gateway). This page is the map of that contract. Every table also carries a `COMMENT ON`
in the database; `\d+ schema.table` shows it, and those comments are kept current by
migrations such as `t278e-serving-bi-public-object-docs`.

## At a glance

| | |
|---|---|
| Engine | PostgreSQL 15.17 + TimescaleDB 2.27.0 (container `timescaledb`, image built from `db/Dockerfile`) |
| Database | `packiot_analytics`, 14 GB (staging) |
| Host (staging) | DB EC2 `i-064bb36d1c454d861`, 10.10.10.89:5432 |
| Extensions | `timescaledb`, `pg_stat_statements`, `btree_gist`, `dblink`, `plpgsql` |
| `search_path` (database default) | `"$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public` |
| Schema source of truth | the live catalog + `db/migrations/*`; greenfield production DDL in `db/init-f3/snapshot/` |
| Depended on by | every backend service; see the [Analytics DB](../subsystems/analytics-db.md#interfaces) interface table |

Sizes below are `pg_total_relation_size` or, for hypertables and caggs, `hypertable_size`.

## Inputs & outputs

See the per-table *Writer* and *Reader* columns below. Services not named as writers must not
write the table. `stream-engine` writes through a `search_path`, so most of its SQL uses bare
table names; grep for the bare name, not only the qualified one, when auditing writers.

## Internal design

### bronze — immutable landing

| Object | Kind | Grain / key | Writer | Reader | Notes |
|---|---|---|---|---|---|
| `bronze.equipment_values_raw` | hypertable, 7-day chunks, 2.0 GB | one row per message; PK `(id_equipment, ts_value, source_seq)` | `stream-engine` `writers.BuildRawAppend` when `BRONZE_RAW_APPEND=true` (on in staging) | replay/repair tooling | no UPSERT or dedup; raw pre-clamp values; `trg_equipment_values_raw_no_mutate` blocks UPDATE/DELETE; chunks from 2026-09-10 |
| `bronze.equipment_events_raw` | hypertable, 7-day chunks | PK `(id_equipment, ts_event, source_seq)` | `stream-engine` event mint path, same flag | — | 0 chunks on 2026-09-28; no-mutate trigger |
| `bronze.box_scans` | table, 26 MB | one row per physical scan; PK `box_scan_id` | `barcode-service` (`cmd/barcode-service/scans.go`) | `bi.scanned_boxes`, box totals | append-only (`trg_box_scans_no_mutate`); a void is a new negating row via `voids_box_scan_id`; `label_seq` server-assigned |
| `bronze.scanned_boxes` | table | PK `id`, unique `(box_order_number, id_production_order)` | `edge-api` Samples feature | edge-api | `increment` accumulates; `box_order_number != 0` = valid scan |
| `bronze.sample_boxes` | table | PK `id_box` | `edge-api` Samples | edge-api | |

### silver — cleaned facts, buckets and current state

**Facts**

| Object | Kind | Grain / key | Writer | Reader | Notes |
|---|---|---|---|---|---|
| `silver.equipment_values` | hypertable, 1-day chunks, 1.56 GB, 58 columns | one row per (equipment, second); PK `(id_equipment, ts_value)` | `stream-engine` `internal/writers/equipment_values.go` (latest-wins UPSERT, increment-sanity clamp) | caggs, rollups, `serving.*`, `bi.equipment_speed`/`live_status`/`production_by_team`, gateway FDW | key columns: `gross/net/scrap_production_incr` and `_val` (totalizer), `speed`, `state`, `mode`, `id_production_order`, `id_shift`, `id_team`, `ts_value_production`, `analogs` (jsonb), `*_quality`; no RLS |
| `silver.equipment_events` | hypertable, 1-day chunks, 900 MB | one row per (equipment, event start); PK `(id_equipment, ts_event)` | `stream-engine` events (mint, close, CPAC deriver live for ent 5), `analytics-sync` (CPACK legacy replay), `edge-api` split/justify | rollups (Availability), `serving.*` downtime functions, `bi.downtimes`, gateway FDW | `status`, `ts_end`/`duration` (NULL while open), `planned_downtime`, `change_over`, `cd_category`/`cd_subcategory`, `txt_downtime_notes`; `id_equipment_event` is **not unique across tenants**; no RLS; coverage from 2021-12-15 |
| `silver.equipment_events_man` | table, 35 MB | manual events; PK `id_equipment_event`, unique `(id_equipment, ts_event)` | `stream-engine` pocontrol (operator justification from edge-api), `analytics-sync` | `serving.v_events_2`, `v_report_downtimes` | kept forever (business record) |
| `silver.equipment_events_low_speed` | table | derived low-speed events | `stream-engine` events | `serving.v_events_2` | |
| `silver.equipment_events_cpac_shadow` | table, 217 MB | PK `(id_equipment, ts_event)` | `stream-engine` CPAC deriver (dark/shadow mode, ADR-0010) | debugging only | 90-day purge |
| `silver.data_quality_event` | table, 39 MB | one row per detected violation | `stream-engine` DQ scan and silver clamp | DQ dashboards/alerts | instrumentation only; never changes a served value |
| `silver.machine_state` | table | PackML state code → label | migration | `*_labeled` views | state 6 = running; 5, 10, 11 = stopped |

**Continuous aggregates** (all real-time, i.e. `materialized_only = false`). Policies and sizes
are in [Timescale jobs & retention](timescale-jobs-and-retention.md#continuous-aggregates).

| Object | Bucket | Source | Shape | Main readers |
|---|---|---|---|---|
| `silver.equipment_categorical_1min` | 1 min | `silver.equipment_values` | keeps discrete dims (`state`, `mode`, `id_order`, `id_production_order`, `id_shift`, `id_team`) + increment sums + `sum_speed`/`cnt_speed` | rollups (categorical/shift-aware OEE) |
| `silver.equipment_categorical_1hour` | 1 h | **hierarchical** on `_1min` | same shape per hour | `gold.equipment_oee_hourly` (phase V), gateway `live.equipment_values_1hour` |
| `silver.equipment_metrics_1min` | 1 min (time column `bucket`) | `silver.equipment_values` | numeric-only per equipment + hierarchy + `tp_equipment` | Mission Control |
| `silver.agg_equipment_values_1min` | 1 min | `silver.equipment_values` | wide legacy-shaped layout | read-api composer (1-min windows capped at 7 days), legacy-shaped consumers |
| `silver.agg_equipment_values_1hour` | 1 h | `silver.equipment_values` | wide; carries integer `id_production_order`, no `state` | legacy-shaped consumers |
| `silver.ca_discrete_changes_1s` | 1 s | `silver.equipment_values` | per-second categorical values | CPAC downtime deriver (transition detection) |
| `silver.ca_equipment_boxes_1s` | 1 s | `silver.equipment_values` (`analogs->'Label'`) | per-second box counts by PO | box/PO counting surface |

**Current-state snapshots** — one row per equipment (or area), overwritten in place by
`stream-engine` `internal/uns`: `equipment_live_metrics` (latest values),
`equipment_live_shift` (current shift + `prev1..prev3` trailing shifts, 86 columns),
`equipment_live_day`, `equipment_live_month`, `equipment_live_job` (running PO),
`area_live_shift`, `area_live_day`. Read by `serving.production_information`,
`bi.live_status`-style screens, and read-api Mission Control/overview datasets.

**Readable projections** — `silver.equipment_values_labeled`, `silver.equipment_events_labeled`
join `silver.machine_state` to add `state_label` / `is_running` / `is_stopped`.

### gold — OEE grains and production-order runs

All OEE grains share the metric columns `oee, oee_a, oee_p, oee_q` (CHECK-bounded to [0,1],
`oee = oee_a·oee_p·oee_q`), `available_time, running_time, stopped_time, planned_downtime,
idle_*, downtime, changeover_time, ideal_production, gross, net, scrap, speed, target`, and the
bookkeeping columns `recalc_needed`, `computed_at`, `source_watermark`.

| Object | Kind, size | Grain / PK | Writer | Reader | Notes |
|---|---|---|---|---|---|
| `gold.equipment_oee_hourly` | table, 462 MB, FORCE RLS | `(id_equipment, ts_value)` hour | `stream-engine` `internal/rollup/hour.go` | `bi.oee_hourly`, serving fns | **lines/sectors only** (`tp_equipment > 1`); gross/net from the 1h categorical cagg, A/Q from event overlaps; 13-month purge |
| `gold.equipment_oee_shift` | table, 290 MB, FORCE RLS | `(id_equipment, ts_value)` shift start | `stream-engine` `internal/rollup/shift.go`; calendar columns seeded by `public.piot_create_equipment_oee_shift*` procs | `bi.oee_shift`, `serving.*`, `v_events_2`, `v_report_downtimes` | covers lines/sectors plus machines of machine-level tenants; `id_shift`, `id_shift_hour`, `id_team`, `cd_shift`, `ts_range`, `ts_end`; kept forever |
| `gold.equipment_oee_daily` | table, 41 MB | `(id_equipment, ts_value)` production day | `stream-engine` rollup (hour cascade flags it) | serving fns | forever |
| `gold.equipment_oee_weekly` / `_monthly` | tables, 41 MB / 9.5 MB | `(id_equipment, ts_value)` week / month start | `stream-engine` `internal/rollup/grains.go` (sum of daily) | serving fns | BIGINT time/count columns |
| `gold.area_oee_shift` / `area_oee_daily` | tables | `(id_area, ts_value)` | `stream-engine` `internal/rollup/entity_grains.go` | serving fns | area day = sum of its **lines'** daily rows |
| `gold.site_oee_shift` | table | `(id_site, ts_value)` | `entity_grains.go` | `serving.oee_progress` | site day grain was dropped (t273) |
| `gold.equipment_oee_shift_weekly` / `_monthly` | tables | equipment × shift × week/month | skeletons seeded by DB procs; metrics largely dormant | legacy reads | treat as dormant |
| `gold.production_orders_runtime` | table, 23 MB, FORCE RLS | one row per PO run on an equipment; PK `id_production_order_runtime`; GiST EXCLUDE `(id_equipment WITH =, runtime_timerange WITH &&)` | row opened/closed by `stream-engine` `internal/pocontrol/pocontrol.go`; metrics by `internal/rollup/compute.go`; CPACK replay by `analytics-sync` | `bi.production_order_runtime`, `serving.production_orders_with_runtimes`, `recalc.go` (writes PO totals back to `core.production_orders`) | no two runs overlap on one equipment |
| `gold.po_box_counter` | table | one row per PO | `barcode-service` under `pg_advisory_xact_lock(id_production_order)` | `bi.po_box_counter`, label assignment | fast gapless counter; authoritative totals are recomputable from `bronze.box_scans` |

### core — tenant hierarchy and business dimensions

| Object | Key | Writer | Reader | Notes |
|---|---|---|---|---|
| `core.enterprises` | `id_enterprise` | `edge-api` CS Admin | everyone | tenant root; `api_key` authenticates edge ingest; default calendar `week_begin`/`day_begin`/`week_size` |
| `core.sites` | `id_site` | CS Admin | rollups, serving | owns the calendar and timezone actually used for bucketing |
| `core.areas` | `id_area` | CS Admin | rollups, serving | finest calendar override; shifts scoped here first |
| `core.equipments` | `id_equipment`; FORCE RLS | CS Admin (`edge-api`), onboarding descriptors | almost every join; the RLS anchor for `bi.*` | 59 columns: `tp_equipment` (1 machine, 2 sector, 3 line), `id_parentequipment`, `lead_machine`, speeds, thresholds, counter-role wiring, state-code mapping; trigger `trg_seed_line_default_target` seeds `config.production_targets` |
| `core.topic_routing` | `id_topic_route` | CS Admin | `sparkplug-decoder` resolver, `stream-engine` topology | maps `packml_topic` / `device_key` → equipment + hierarchy; `active`; last-value cache |
| `core.packml_register` | view over `topic_routing` | (auto-updatable) | legacy consumers | compat shim for the #243 rename; do not drop until every consumer is repointed |
| `core.shifts` | `id_shift` | CS Admin | shift resolver | `begin_time`/`end_time` are **clock times** |
| `core.shift_hours` | `id_shift_hour` | CS Admin; runtime fields by the engine | shift resolver, rollups | `begin_time`/`end_time` are **integer seconds from `week_begin`** |
| `core.shifts_exception_period` | `(id_equipment, ts_begin)` | none yet | shift provisioning | holidays/shutdowns; empty |
| `core.production_orders` | `id_production_order`; FORCE RLS | `edge-api` (create/control), `stream-engine` pocontrol + recalc, `analytics-sync` (CPACK replay) | `bi.production_orders`, `serving.production_orders*`, operator views, gateway FDW | status 1 available, 2 running, 3 finished, 4 paused; PO-level OEE columns written by the engine; 36 MB |
| `core.products`, `core.product_families`, `core.clients` | ids; unique names per tenant | CS Admin, `analytics-sync` | PO screens, `stream-engine` | |
| `core.teams` | `id_team` | CS Admin | `serving.total_production_by_team`, `bi.production_by_team` | |
| `core.downtime_reason`, `core.equipment_downtime_reason` | `id`; `(id_equipment, id_reason)` | CS Admin | operator justification | hierarchical reasons |
| `core.scrap_reason`, `core.equipment_scrap_reason` | | none | none | forward schema, empty |
| `core.equipment_validation_shift` | | none yet | `serving.data_sync`, `report_shift` | empty, enterprise-06 workflow |
| `core.box_production_bridges` | `(id_enterprise, source_cd, target_cd)` | migration/CS | `stream-engine` boxes bridge | box scans → net production of a child equipment |
| `core.client_descriptors` | unique `id_enterprise` | `edge-api` onboarding | `sparkplug-decoder`, `stream-engine` reports | config-as-data JSONB (ADR-0045) |

### config — targets, labels, i18n

| Object | Writer | Reader | Notes |
|---|---|---|---|
| `config.production_targets` (FORCE RLS) | `edge-api` set-target (UPDATE-only), trigger on `core.equipments` | `bi.production_targets`, `serving.targets` | scope tuple `(id_enterprise, id_site, id_area, id_equipment)`, 0 = wildcard; `vl_hour/shift/day/week/month` |
| `config.scrap_targets` | `edge-api` set-scrap-target | serving | |
| `config.oee_targets` | none | `serving.mission_control_area` | half-built: no writer |
| `config.labels`, `config.label_formats` | CS Admin / migrations | edge-api label print, `stream-engine` boxes adapter | |
| `config.translations`, `config.tenant_translations`, `config.language_packs` | edge-api | edge-api i18n | `language_packs` is the legacy blob form |
| `config.pages`, `config.dashboard_config` | CS Admin / migrations | `serving.v_menu_per_user_role`, read-api `/v1/dashboard-config` | |

Functions: `config.piot_line_default_target_hour`, `config.piot_seed_line_default_target`
(seed a line's default target from nameplate speed × 0.85).

### identity — application users (authorization, not authentication)

| Object | Writer | Reader |
|---|---|---|
| `identity.users` (`id_user_cognito`) | `edge-api` | read-api tenant resolution, operator login (`user_name` = email) |
| `identity.user_roles` | `edge-api` | read-api authorization, `serving.v_*_per_user_role` |
| `identity.user_logs` (14 MB) | `edge-api` `logger.middleware` (one row per mutating request) | audit, mirror replay |
| `identity.user_screen_config` | `read-api` `/v1/screen-config` | read-api `/v1/dashboard-config` |

### ops — plumbing, retention, repair backups

| Object | Purpose |
|---|---|
| `ops.retention_policy`, `ops.retention_run`, `ops.retention_drift` (view) | retention catalog, purge log, catalog-vs-live check (see [Timescale jobs & retention](timescale-jobs-and-retention.md#the-retention-catalog)) |
| `ops.mirror_replay_cursor`, `ops.mirror_replay_dlq` | legacy replay high-water mark and dead letters (`analytics-sync`) |
| `ops.capture_observations` | which count indices/topics actually arrive (`sparkplug-decoder` agent) |
| `ops.idempotency_keys` | edge-api idempotent POST cache (ADR-0007) |
| `ops._bkp_*`, `ops._ev_reconcile_leg` | row backups taken before data repairs; see [DBA guide](../operations/dba-guide.md#backups) |

Procedures/functions: `ops.apply_retention()` (reconcile Timescale retention to the catalog),
`ops.bf_merge(...)` (legacy history merge, dry/apply), `ops.sandbox_reflect(...)`,
`ops.sbx_upsert(...)`, `ops.sbx_remap_descriptor(...)` (sandbox twin 2000003 reflection).

### serving — the read-api contract

All nine views have `security_invoker = on` (the caller's RLS applies) and all 48 functions
are `SECURITY INVOKER`. read-api calls them as `readapi_ro` after
`set_config('app.tenant_id', <tenant>, true)` and adds `WHERE id_enterprise = $1`.

| Object | Kind | Purpose |
|---|---|---|
| `serving.downtime_events_resolved` (+ `_meta`) | table, 546 MB, FORCE RLS | pre-resolved downtime rows (line/sector/shift/PO attribution); refreshed every 2 min for the last 3 days by job 1072; `_meta.coverage_from` is the served floor |
| `serving.v_events_2` | view | unified event timeline (downtime + PO/PLC events) |
| `serving.v_report_downtimes` | view | downtime report keyed by **shift begin**, not event time |
| `serving.production_information` | view | current-shift production/OEE per equipment from `silver.equipment_live_shift` |
| `serving.v_entities_per_user_role(_operator)`, `v_menu_per_user_role`, `v_operator_entities_2`, `v_operator_po_details_3`, `v_operator_po_list_setup_4` | views | front4/operator bootstrap and operator PO screens |
| Downtime functions | fn | `downtime_events` (v1/v2/v3), `downtime_by_category`, `downtime_duration_by_category`, `downtime_summary`, `pending_downtime`, `events_timeline*`, `overview_events*`, `refresh_downtime_events_resolved` |
| OEE/production functions | fn | `oee_score`, `oee_score_by_team`, `oee_progress`, `production_chart*`, `production_flow`, `production_health`, `total_production_by_team`, `single_period_by_team(_v4)`, `targets`, `machine_speed`, `home` |
| Mission Control | fn | `mission_control`, `mission_control_area`, `mission_control_timeline` |
| PO functions | fn | `production_orders`, `production_orders_with_runtimes`, `overview_job_info`, `overview_takt`, `overview_scrap_rate` |
| Report functions | fn | `report_*`, `data_sync`, `downtime_sync`, `production_data_sync`, `sap_report_data_sync`, `sap_site_report` |

Some functions return composite types in `serving` (30 of them). When a column is widened,
widen the composite type too (the 2026-09-24 `serving.production_orders` "returned type bigint
does not match integer" failure).

### bi — the Superset contract

Twelve views owned by `bi_owner` (NOLOGIN, NOSUPERUSER, NOBYPASSRLS), readable by
`superset_ro`. They are ordinary (definer-rights) views, so base-table access runs as
`bi_owner` and the base tables' FORCE RLS applies; the tenant comes from `app.tenant_id`.

| View | Base tables |
|---|---|
| `bi.oee_shift`, `bi.oee_hourly` | `gold.equipment_oee_shift` / `_hourly` + `core.equipments` |
| `bi.production_order_runtime`, `bi.production_orders` | `gold.production_orders_runtime` / `core.production_orders` + `core.equipments` |
| `bi.downtimes` | `silver.equipment_events` + `core.equipments` |
| `bi.equipment_speed`, `bi.live_status`, `bi.production_by_team` | `silver.equipment_values` + `core.equipments` |
| `bi.equipments` | `core.equipments` |
| `bi.production_targets` | `config.production_targets` + `core.equipments` |
| `bi.scanned_boxes`, `bi.po_box_counter` | `bronze.box_scans` / `gold.po_box_counter` + `core.{sites,areas,equipments,production_orders}` |

Views over tables without RLS (`silver.*`, `bronze.box_scans`) are fenced by the inner join to
`core.equipments`. See [Superset](superset.md).

### customer_reports — per-customer export pools

`customer_reports.production_data_sync` (Montebello/Incoplast, customer 6),
`customer_reports.sap_data_sync` (Neopac SAP, customer 13), `customer_reports.shift`,
`customer_reports.boxes`. Written by `stream-engine` `internal/reports`; pulled by the
customers' integrations. External contracts: do not change columns without the customer.

### public — extensions and legacy procedures

Two tables (`knex_migrations`, `knex_migrations_lock`) and 33 non-extension functions:
`piot_create_*` / `piot_get_*` (shift-calendar provisioning called by `stream-engine`
`internal/rollup/provision.go`), `h_piot_*` (legacy helpers), `current_tenant()`,
`is_all_tenant()`, `purge_analytics_plain` (job 1033), `set_updated_at`, `bronze_raw_no_mutate`,
`box_scans_no_mutate`. The caggs and dimension shims that used to live here were moved or
dropped in 2026-09 (t239, t251, t252, t261).

## Configuration

Schema-level settings: the database `search_path` above and `track_functions = pl`. Role-level:
`histgw_ro` has `app.tenant_id = -1`. Everything else is in
[Analytics DB — configuration](../subsystems/analytics-db.md#configuration-that-matters).

## Data & invariants

- `silver.equipment_values` is unique per `(id_equipment, ts_value)`; `silver.equipment_events`
  per `(id_equipment, ts_event)`. Address event rows by that key, never by
  `id_equipment_event` alone: the sandbox twin shares event ids with CPACK (2026-09-21
  cross-tenant write).
- Gold OEE factors are clamped to [0,1] by CHECK constraints and satisfy `oee = a·p·q`.
- No two PO runs overlap on one equipment (GiST exclusion).
- Bronze tables are append-only (triggers), including against superusers.
- `gold.equipment_oee_hourly` exists only for `tp_equipment > 1`; downtime and OEE are line
  concepts, so filter `tp_equipment = 3` and never average across machines and lines.
- NULL counters mean "no reading", not zero.

## Observability

- `pg_stat_statements` is installed; `auto_explain` is preloaded.
- `silver.data_quality_event` records clamp and DQ violations.
- `recalc_needed` backlog on the gold grains is the rollup freshness signal (see
  [DBA guide](../operations/dba-guide.md#health-checks)).

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Composite type drift (2026-09-24) | every call of a serving function fails | column widened, `serving.*_row` type not | `ALTER TYPE`; grep `pg_class.relkind='c'` when widening |
| Serial sequence left behind (2026-09-24) | `null value in column id_runtime_shift` | sequence stayed in `public` after the schema move and is not `OWNED BY` the column | name the sequence explicitly; read the column default |
| Definer view recreated as superuser | `bi.*` returns all tenants or none | owner flipped to `postgres` | `ALTER VIEW … OWNER TO bi_owner` |
| Cross-tenant event write (2026-09-21) | sandbox action changed CPACK rows | UPDATE by non-unique `id_equipment_event` | scope by `(id_equipment, ts_event)` and tenant |

## Operating it

Schema changes go through `db/migrations/<task>/01-up.sql` + `rollback.sql`, applied by hand
or by `db-migrate` (direct connection, not pgbouncer). Safe patterns are in the
[DBA guide](../operations/dba-guide.md).

## Tests

- `tests/superset/run.sh` — applies `db/superset/*.sql` to an ephemeral Postgres and asserts
  per-tenant isolation of `bi.*` (CI workflow `superset-rls-isolation.yml`).
- `stream-engine` golden tests pin the rollup SQL that writes `gold.*`.
- `read-api` `TestEveryDatasetIsTenantScoped` checks every dataset carries the tenant fence.

## Source map

| Path | What's there |
|---|---|
| `db/migrations/` | every schema change since the medallion split (`t231-*`, `t237-*`, `t261*`, `t-retention-catalog`, `t-rls-initplan-policies`, …) |
| `db/init-f3/snapshot/` | greenfield production F3 DDL |
| `db/superset/` | `bi` views, `superset_ro`/`bi_owner`, tenant RLS |
| `db/retention/profiles/` | retention profiles |
| `db/design/analytics-v2-target-schema.md` | target-schema design notes |
| `services/stream-engine/internal/writers/` | `silver.equipment_values` and bronze writers |
| `services/stream-engine/internal/rollup/` | `gold.*` rollups and provisioning calls |
| `services/stream-engine/internal/pocontrol/` | PO lifecycle, `production_orders_runtime` |
| `services/stream-engine/internal/uns/` | `silver.*_live_*` snapshots |
| `services/barcode-service/cmd/barcode-service/scans.go` | `bronze.box_scans`, `gold.po_box_counter` |
| `services/analytics-sync/internal/replicate/` | CPACK legacy replay |
| `services/read-api/cmd/refdata-api/` | readers of `serving.*` |
