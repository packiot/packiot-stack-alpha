---
title: Database reference
layer: 4
owner_area: analytics-db
last_verified: 2026-09-28
---
# Database reference

> **Layer 4 · Reference** — one line per table: grain, writer, main reader, retention.
> Staging `packiot_analytics` and the historian gateway, read from the live catalog on
> 2026-09-28. For lookups; explanations are in the linked pages.
> Up: [Analytics DB](../subsystems/analytics-db.md)

Abbreviations: **SE** = `stream-engine` (oeecloud-worker), **EA** = `edge-api`,
**RA** = `read-api`, **AS** = `analytics-sync` / `legacy-replicator`, **BS** =
`barcode-service`, **SS** = Superset, **HG** = historian gateway. "∞" = kept forever.
"RLS" = FORCE row-level security on `app.tenant_id`.

## Analytics DB — facts and aggregates

| Relation | Kind | Grain / key | Writer | Main readers | Retention |
|---|---|---|---|---|---|
| `bronze.equipment_values_raw` | hypertable (7 d chunks) | per message `(id_equipment, ts_value, source_seq)` | SE (`BRONZE_RAW_APPEND`) | replay/repair | 90 d |
| `bronze.equipment_events_raw` | hypertable (7 d) | per event message | SE (same flag) | — (empty) | 90 d |
| `bronze.box_scans` | table | per scan `box_scan_id` | BS | `bi.scanned_boxes` | ∞ |
| `bronze.scanned_boxes`, `bronze.sample_boxes` | tables | per box | EA (Samples) | EA | not in catalog |
| `silver.equipment_values` | hypertable (1 d) | `(id_equipment, ts_value)` second | SE | caggs, rollups, RA, `bi.*`, HG | 90 d |
| `silver.equipment_events` | hypertable (1 d) | `(id_equipment, ts_event)` | SE, AS, EA | rollups, RA, `bi.downtimes`, HG | 5 y |
| `silver.equipment_events_man` | table | `(id_equipment, ts_event)` | SE pocontrol, AS | `serving.v_events_2` | ∞ |
| `silver.equipment_events_low_speed` | table | event | SE | `serving.v_events_2` | not in catalog |
| `silver.equipment_events_cpac_shadow` | table | `(id_equipment, ts_event)` | SE (dark deriver) | debug | 90 d |
| `silver.data_quality_event` | table | violation | SE | DQ alerts | not in catalog |
| `silver.equipment_categorical_1min` | cagg | 1 min × equipment × dims | Timescale 1064 | rollups | 90 d |
| `silver.equipment_categorical_1hour` | cagg (on `_1min`) | 1 h | Timescale 1068 | `gold.equipment_oee_hourly`, HG | 13 mo |
| `silver.equipment_metrics_1min` | cagg | 1 min (`bucket`) | Timescale 1057 | Mission Control | 90 d |
| `silver.agg_equipment_values_1min` | cagg | 1 min, wide | Timescale 1003 | RA composer | 90 d |
| `silver.agg_equipment_values_1hour` | cagg | 1 h, wide | Timescale 1005 | legacy-shaped reads | 13 mo |
| `silver.ca_discrete_changes_1s` | cagg | 1 s | Timescale 1013 | CPAC deriver | 90 d |
| `silver.ca_equipment_boxes_1s` | cagg | 1 s × PO | Timescale 1014 | box counting | 90 d |
| `silver.equipment_live_{metrics,shift,day,month,job}`, `silver.area_live_{shift,day}` | tables | one row per equipment/area | SE (`internal/uns`) | RA, `serving.production_information` | overwritten |
| `gold.equipment_oee_hourly` | table, RLS | `(id_equipment, ts_value)` hour, `tp_equipment > 1` | SE `rollup/hour.go` | `bi.oee_hourly`, RA | 13 mo (job 1033) |
| `gold.equipment_oee_shift` | table, RLS | `(id_equipment, ts_value)` shift | SE `rollup/shift.go` | `bi.oee_shift`, RA | ∞ |
| `gold.equipment_oee_daily` | table | `(id_equipment, ts_value)` day | SE rollup | RA | ∞ |
| `gold.equipment_oee_weekly` / `_monthly` | tables | week / month | SE `rollup/grains.go` | RA | ∞ |
| `gold.equipment_oee_shift_weekly` / `_monthly` | tables | equipment × shift × week/month | DB procs (dormant) | legacy | ∞ |
| `gold.area_oee_shift` / `_daily` | tables | `(id_area, ts_value)` | SE `rollup/entity_grains.go` | RA | ∞ |
| `gold.site_oee_shift` | table | `(id_site, ts_value)` | SE `entity_grains.go` | `serving.oee_progress` | ∞ |
| `gold.production_orders_runtime` | table, RLS | PO run; no overlap per equipment | SE pocontrol + `rollup/compute.go`, AS | `bi.production_order_runtime`, RA | ∞ |
| `gold.po_box_counter` | table | one row per PO | BS | `bi.po_box_counter` | ∞ |
| `serving.downtime_events_resolved` | table, RLS | resolved downtime row | Timescale 1072 (every 2 min, last 3 days) | RA downtime datasets | not in catalog |

## Analytics DB — dimensions, config, identity, ops

| Relation | Key | Writer | Main readers | Retention |
|---|---|---|---|---|
| `core.enterprises` / `sites` / `areas` | id | EA (CS Admin) | everyone | ∞ |
| `core.equipments` (RLS) | `id_equipment` | EA | everyone; RLS anchor for `bi.*` | ∞ |
| `core.topic_routing` (+ view `core.packml_register`) | `id_topic_route` | EA | decoder, SE | ∞ |
| `core.shifts` / `core.shift_hours` | id | EA (runtime fields: SE) | shift resolver | ∞ |
| `core.production_orders` (RLS) | `id_production_order` | EA, SE pocontrol/recalc, AS | `bi.production_orders`, RA, HG | ∞ |
| `core.products`, `product_families`, `clients`, `teams` | id | EA, AS | RA, SE | ∞ |
| `core.downtime_reason`, `equipment_downtime_reason` | id / pair | EA | operator | ∞ |
| `core.client_descriptors` | `id_enterprise` | EA onboarding | decoder, SE reports | ∞ |
| `config.production_targets` (RLS) | scope tuple | EA, trigger on `core.equipments` | `bi.production_targets`, RA | ∞ |
| `config.scrap_targets`, `oee_targets` | scope tuple | EA / none | RA | ∞ |
| `config.labels`, `label_formats`, `translations`, `tenant_translations`, `language_packs`, `pages`, `dashboard_config` | various | EA / migrations | EA, RA, SE | ∞ |
| `identity.users` | linked to Cognito by `id_user_cognito` | EA | RA, operator | ∞ |
| `identity.user_roles` | id | EA | RA | ∞ |
| `identity.user_logs` | log row | EA logger | audit | ∞ |
| `identity.user_screen_config` | `(id_enterprise, id_user, screen)` | RA | RA | ∞ |
| `ops.retention_policy` / `retention_run` | relation / run | DBA / job 1033 | job 1033, exporter | run log 13 mo |
| `ops.mirror_replay_cursor` / `_dlq` | stream | AS | AS | ∞ |
| `ops.capture_observations` | topic × index | sparkplug-decoder agent | EA | ∞ |
| `ops.idempotency_keys` | key | EA | EA | ∞ |
| `ops._bkp_*` | copy of repaired rows | DBA | DBA | manual |
| `customer_reports.*` | report row | SE `internal/reports` | customer integrations | ∞ |

## Historian gateway (`packiot_historian`)

| Relation | Kind | Source | Grain | Tenant gate | Kept |
|---|---|---|---|---|---|
| `silver.equipment_values` | view | `live.equipment_values` ∪ `cold.equipment_values` | second | caller literal + `ev_promoted` | 2021 → now (CPACK) |
| `silver.equipment_events` | view | `live.equipment_events` ∪ `cold.equipment_events` | event | caller literal + `ee_promoted` | 2021 → now |
| `silver.production_orders` | view | `live.production_orders` ∪ `cold.production_orders` | PO | caller literal + `po_promoted` | 2021-12 → now |
| `cold.equipment_values_daily` | view | S3 `equipment_values_daily/` | UTC day × equipment | caller literal | days < `ev_daily_watermark` |
| `cold.equipment_values` / `equipment_events` / `production_orders` | views | S3 `read_parquet` | raw | **none** (reference only) | forever |
| `live.equipment_values` / `equipment_events` / `production_orders` / `equipment_values_1hour` | foreign tables | analytics DB via `histgw_ro` | as source | caller literal | as source |
| `cold.promoted_enterprise` | table | hand-curated | tenant | — | — |
| `cold.ev_union_boundary` / `ee_union_boundary` / `po_union_boundary` | tables | refresh SQL | tenant | — | — |
| `cold.cold_append_watermark`, `cold.ev_daily_watermark` | tables | nightly job | tenant | — | — |

## Timescale objects at a glance

| Object | Chunk | Compress after | Retention | Refresh (every / window) |
|---|---|---|---|---|
| `silver.equipment_values` | 1 d | 7 d | 90 d | — |
| `silver.equipment_events` | 1 d (compress interval 30 d) | 14 d | 5 y | — |
| `bronze.equipment_values_raw` / `_events_raw` | 7 d | 7 d | 90 d | — |
| `agg_equipment_values_1min` | 10 d | 7 d | 90 d | 1 min / 30 min |
| `agg_equipment_values_1hour` | 10 d | 7 d | 13 mo | 30 min / 3 d |
| `ca_discrete_changes_1s` | 10 d | 7 d | 90 d | 15 min / 30 min |
| `ca_equipment_boxes_1s` | 10 d | — | 90 d | 15 min / 6 h |
| `equipment_metrics_1min` | 10 d | — | 90 d | 1 min / 3 h |
| `equipment_categorical_1min` | 10 d | — | 90 d | 2 min / 3 h |
| `equipment_categorical_1hour` | 10 d | — | 13 mo | 30 min / 1 d |

## Roles

| Role | Where | Super | BYPASSRLS | Used by |
|---|---|---|---|---|
| `postgres` | analytics, gateway | yes | yes | SE, EA, AS, DDL, scripts |
| `dev@packiot.com` | analytics (staging) | yes | yes | humans (staging only) |
| `readapi_ro` | analytics | no | no | RA |
| `superset_ro` | analytics | no | no | SS |
| `bi_owner` | analytics (NOLOGIN) | no | no | owns `bi.*` |
| `histgw_ro` | analytics | no | no (`app.tenant_id=-1`) | HG FDW |
| `cloudbeaver_ro` / `cloudbeaver_rw` | analytics | no | yes | CloudBeaver |
| `superset` | `superset` DB | no | no | Superset metadata |
| `historian_svc` | gateway | no | — | RA, SS |
| `historian_readers` | gateway (NOLOGIN) | no | — | `duckdb.postgres_role` |
| `cloudbeaver_histro` | gateway | no | — | CloudBeaver (hot only) |

## Session settings

| GUC | Meaning |
|---|---|
| `app.tenant_id` | tenant for RLS; unset = deny, `-1` = all tenants |
| `timescaledb.max_tuples_decompressed_per_dml_transaction` | DML cap on compressed chunks (100000; `0` = unlimited, use `SET LOCAL`) |
| `timescaledb.enable_chunkwise_aggregation` | turn `off` for wide ad-hoc aggregates over many chunks |
| `statement_timeout`, `lock_timeout` | set both for any manual session on the shared DB |

## Endpoints and hosts (staging)

| What | Address |
|---|---|
| Analytics DB | `timescaledb` container on `i-064bb36d1c454d861`, 10.10.10.89:5432, db `packiot_analytics` |
| pgbouncer | `pgbouncer:5432` (172.18.0.10) on the app host, pools `${POSTGRES_DB}` and `packiot_analytics` |
| Historian gateway | `hist-gateway:5432`, db `packiot_historian`, app host `i-06c9547a2c7091ab7` |
| Historian bucket | `packiot-staging-historian-<account>` |
| DB browser | CloudBeaver at `db.staging.packiot.app` (cs-admin gate) |
| Superset | `bi.staging.packiot.app` |
| Nightly dump bucket | `packiot-staging-db-backups-<account>` |

See also: [Analytics DB schemas](../components/analytics-db-schemas.md) ·
[Timescale jobs & retention](../components/timescale-jobs-and-retention.md) ·
[Historian gateway](../components/historian-gateway.md) · [DBA guide](../operations/dba-guide.md)
