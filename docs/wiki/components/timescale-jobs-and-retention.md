---
title: Timescale jobs and retention
layer: 3
owner_area: analytics-db
last_verified: 2026-09-28
---
# Timescale jobs and retention

> **Layer 3 · Components** — every hypertable, continuous aggregate, background job,
> compression policy and retention rule in `packiot_analytics`, with the intervals read from
> the live staging catalog on 2026-09-28, and the retention catalog that drives them.
> For DBAs and anyone changing how long data lives. Up: [Analytics DB](../subsystems/analytics-db.md)

## Responsibility

TimescaleDB's background scheduler does four jobs for the analytics DB: keep the continuous
aggregates materialized, compress old chunks into columnar form, drop chunks older than the
retention horizon, and run two user-defined procedures (the catalog-driven purge of plain
tables and the downtime-resolved refresh). The retention catalog `ops.retention_policy`
decides every horizon; this page lists what is actually configured.

## At a glance

| | |
|---|---|
| Engine | TimescaleDB 2.27.0 on PostgreSQL 15.17 |
| Scheduler | Timescale background workers (`timescaledb.max_background_workers = 12`); `pg_cron` is preloaded but not installed in `packiot_analytics` |
| Jobs | 29 (27 scheduled policies, 2 user-defined actions); telemetry reporter disabled |
| Status on 2026-09-28 | every scheduled job's last run = Success |
| Source of truth for horizons | `ops.retention_policy` (migration `db/migrations/t-retention-catalog`) |
| Host (staging) | DB EC2 `i-064bb36d1c454d861` |

## Inputs & outputs

| Reads | Writes |
|---|---|
| `silver.equipment_values`, `silver.equipment_events`, `bronze.*_raw` | the 7 materialization hypertables, compressed chunks |
| `ops.retention_policy` | drops chunks; deletes from plain tables; logs to `ops.retention_run` |
| `silver.equipment_events`, `core.*`, `gold.equipment_oee_shift`, … | `serving.downtime_events_resolved` |

## Internal design

### Hypertables

| Hypertable | Time column | Chunk interval | Chunks (compressed) | Size | Coverage from |
|---|---|---|---|---|---|
| `silver.equipment_values` | `ts_value` | 1 day | 87 (79) | 1.56 GB | 2026-07-01 |
| `silver.equipment_events` | `ts_event` | 1 day, `compress_chunk_time_interval` 30 days | 155 (140) | 900 MB | 2021-12-15 |
| `bronze.equipment_values_raw` | `ts_value` | 7 days | 3 (1) | 2.0 GB | 2026-09-10 |
| `bronze.equipment_events_raw` | `ts_event` | 7 days | 0 | 24 kB | — |

`silver.equipment_events` was consolidated from 1,483 to 156 chunks on 2026-09-24 with
`merge_chunks` (`scripts/consolidate-event-chunks.sh`) after the CPACK history backfill; the
30-day `compress_chunk_time_interval` makes compression keep merging old one-day chunks into
monthly ones. It is stored in `_timescaledb_catalog.dimension.compress_interval_length`, not
in `reloptions`.

### Continuous aggregates

All seven are real-time (`materialized_only = false`). Materialization hypertables use
10-day chunks.

| Cagg | Bucket | Source | Mat. hypertable | Refresh job: every, window | Compress | Retention | Size |
|---|---|---|---|---|---|---|---|
| `silver.agg_equipment_values_1min` | 1 min | `silver.equipment_values` | 12 | 1003: 1 min, `[now-30 min, now-1 min]` | 1036: after 7 d | 1048: 90 d | 600 MB |
| `silver.agg_equipment_values_1hour` | 1 h | `silver.equipment_values` | 14 | 1005: 30 min, `[now-3 d, now-1 h]` | 1038: after 7 d | 1090: 13 months | 42 MB |
| `silver.ca_discrete_changes_1s` | 1 s | `silver.equipment_values` | 22 | 1013: 15 min, `[now-30 min, now-1 min]` | 1034: after 7 d | 1046: 90 d | 3.5 GB |
| `silver.ca_equipment_boxes_1s` | 1 s | `silver.equipment_values` | 23 | 1014: 15 min, `[now-6 h, now-1 min]` | none | 1091: 90 d | 56 kB |
| `silver.equipment_metrics_1min` | 1 min (`bucket`) | `silver.equipment_values` | 53 | 1057: 1 min, `[now-3 h, now-1 min]` | none | 1095: 90 d | 1.19 GB |
| `silver.equipment_categorical_1min` | 1 min | `silver.equipment_values` | 60 | 1064: 2 min, `[now-3 h, now-2 min]` | none | 1093: 90 d | 2.4 GB |
| `silver.equipment_categorical_1hour` | 1 h | `silver.equipment_categorical_1min` (hierarchical) | 64 | 1068: 30 min, `[now-1 d, now-1 h]` | none | 1092: 13 months | 70 MB |

Compressed caggs and hypertables segment by `id_equipment` and order by the time column
descending (bronze also orders by `source_seq DESC`), with min/max sparse indexes on the
order-by columns.

Why small refresh windows matter: a refresh over a range whose raw rows were already dropped
**deletes** the aggregated buckets for that range. Every `start_offset` here is at most 3
days, far inside the 90-day raw horizon, so the hourly caggs keep their 13 months.

### All jobs

| Job | Kind | Target | Schedule | Config |
|---|---|---|---|---|
| 1 | telemetry reporter | — | 24 h | **not scheduled** |
| 3 | job-history retention | Timescale internal | 6 h | drop after 1 month, max 1000 failures/successes per job |
| 1003 | cagg refresh | `agg_equipment_values_1min` | 1 min | start 30 min, end 1 min |
| 1005 | cagg refresh | `agg_equipment_values_1hour` | 30 min | start 3 days, end 1 h |
| 1013 | cagg refresh | `ca_discrete_changes_1s` | 15 min | start 30 min, end 1 min |
| 1014 | cagg refresh | `ca_equipment_boxes_1s` | 15 min | start 6 h, end 1 min |
| 1057 | cagg refresh | `equipment_metrics_1min` | 1 min | start 3 h, end 1 min |
| 1064 | cagg refresh | `equipment_categorical_1min` | 2 min | start 3 h, end 2 min |
| 1068 | cagg refresh | `equipment_categorical_1hour` | 30 min | start 1 day, end 1 h |
| 1019 | compression | `silver.equipment_events` | 12 h | after 14 days |
| 1027 | compression | `bronze.equipment_values_raw` | 12 h | after 7 days |
| 1028 | compression | `bronze.equipment_events_raw` | 12 h | after 7 days |
| 1031 | compression | `silver.equipment_values` | 12 h | after 7 days |
| 1034 | compression | `ca_discrete_changes_1s` | 12 h | after 7 days |
| 1036 | compression | `agg_equipment_values_1min` | 12 h | after 7 days |
| 1038 | compression | `agg_equipment_values_1hour` | 12 h | after 7 days |
| 1032 | retention | `silver.equipment_values` | 1 day | drop after 90 days |
| 1046 | retention | `ca_discrete_changes_1s` | 1 day | 90 days |
| 1048 | retention | `agg_equipment_values_1min` | 1 day | 90 days |
| 1088 | retention | `bronze.equipment_events_raw` | 1 day | 90 days |
| 1089 | retention | `bronze.equipment_values_raw` | 1 day | 90 days |
| 1090 | retention | `agg_equipment_values_1hour` | 1 day | 1 year 1 month |
| 1091 | retention | `ca_equipment_boxes_1s` | 1 day | 90 days |
| 1092 | retention | `equipment_categorical_1hour` | 1 day | 1 year 1 month |
| 1093 | retention | `equipment_categorical_1min` | 1 day | 90 days |
| 1094 | retention | `silver.equipment_events` | 1 day | 5 years |
| 1095 | retention | `equipment_metrics_1min` | 1 day | 90 days |
| 1033 | user-defined | `public.purge_analytics_plain` | 1 day | reads `ops.retention_policy` (kind `plain`) |
| 1072 | user-defined | `serving.job_refresh_downtime_events_resolved` | 2 min | `refresh_downtime_events_resolved(now() - 3 days, now())` |

The retention jobs 1088–1095 were (re)created by `ops.apply_retention()` on 2026-09-23;
their low run counts (5) reflect that, not failures. Cagg refresh jobs 1003, 1057, 1064 and
1068 show a few historical failures but their last run succeeded.

### The retention catalog

`ops.retention_policy` has one row per time-series relation:

| Column | Meaning |
|---|---|
| `relation` | schema-qualified name (PK) |
| `kind` | `hypertable`, `cagg` or `plain` |
| `time_expr` | column or expression compared with `now() - keep` (e.g. `lower(runtime_timerange)`) |
| `keep` | interval, NULL = forever |
| `tier` | `hot_raw`, `hot_agg`, `business`, `ops` |
| `purge_order` | plain tables: FK children before parents |
| `cold_copy` | where older rows live, if anywhere |
| `rationale` | why |

Mechanics:

- `CALL ops.apply_retention()` validates every `time_expr`, then for hypertables and caggs
  removes and re-adds the Timescale retention policy only where `keep` differs from live.
- Job 1033 `public.purge_analytics_plain` runs, for each `plain` row with a non-NULL `keep`,
  `DELETE FROM <relation> WHERE <time_expr> < now() - keep`, each in its own subtransaction,
  logging `rows_deleted` or the error to `ops.retention_run`.
- `ops.retention_drift` lists catalog-vs-live disagreements; it should return 0 rows.

**Production profile** (seeded by the migration; also `db/retention/profiles/production.sql`,
live on staging today):

| Tier | Relations | Kind | Keep | Cold copy |
|---|---|---|---|---|
| hot_raw | `silver.equipment_values` | hypertable | 90 days | historian `equipment_values` |
| hot_raw | `bronze.equipment_values_raw`, `bronze.equipment_events_raw` | hypertable | 90 days | — |
| hot_raw | `ca_discrete_changes_1s`, `ca_equipment_boxes_1s`, `agg_equipment_values_1min`, `equipment_metrics_1min`, `equipment_categorical_1min` | cagg | 90 days | derivable |
| hot_agg | `agg_equipment_values_1hour`, `equipment_categorical_1hour` | cagg | 13 months | — |
| hot_agg | `gold.equipment_oee_hourly` | plain (job 1033) | 13 months | — |
| hot_agg | `gold.equipment_oee_{shift,daily,weekly,monthly,shift_weekly,shift_monthly}`, `gold.area_oee_{shift,daily}`, `gold.site_oee_shift` | plain | forever | historian `equipment_oee_shift` (shift) |
| hot_agg | `silver.equipment_events` | hypertable | 5 years | historian `equipment_events` |
| business | `bronze.box_scans`, `gold.po_box_counter`, `gold.production_orders_runtime`, `core.production_orders`, `silver.equipment_events_man` | plain | forever | historian `production_orders` (POs) |
| ops | `silver.equipment_events_cpac_shadow` | plain | 90 days | — |
| ops | `ops.retention_run` | plain | 13 months | — |

**Staging-capped profile** (`db/retention/profiles/staging-capped.sql`): every relation except
`ops.retention_run` → 3 months. Apply only after production is promoted; it deletes business
records on the next purge. The historian half of that cap is
`scripts/historian-prune-by-data-age.sh`.

### What is not in the catalog

- `serving.downtime_events_resolved` is rebuilt for a rolling 3-day window by job 1072; rows
  older than that stay until a manual refresh. Its served floor is
  `serving.downtime_events_resolved_meta.coverage_from`.
- Current-state tables (`silver.*_live_*`) are overwritten in place.
- `ops._bkp_*` backups are never purged automatically.

## Configuration

| Knob | Value | Effect |
|---|---|---|
| `timescaledb.max_background_workers` | 12 | concurrent jobs |
| `timescaledb.enable_chunkwise_aggregation` | on | partial aggregation per chunk; see the memory warning below |
| `timescaledb.max_tuples_decompressed_per_dml_transaction` | 100000 (the frozen `packiot` DB has 5,000,000 as a database setting) | DML touching compressed chunks aborts past it |
| `timescaledb.bgw_log_level` | warning | |

## Data & invariants

- Raw and minute grains never exceed 90 days hot; anything older must be read from the
  historian.
- Client-facing gold grains are never purged; hourly OEE and hourly caggs keep 13 months for
  year-over-year comparisons.
- Refresh windows never reach past raw retention.
- Catalog and live agree (`ops.retention_drift` empty).

## Observability

| Signal | Where |
|---|---|
| job status | `SELECT * FROM timescaledb_information.job_stats` (`last_run_status`, `total_failures`) and `timescaledb_information.job_errors` |
| cagg lag | `_timescaledb_functions.to_timestamp(_timescaledb_functions.cagg_watermark(mat_hypertable_id))` from `_timescaledb_catalog.continuous_agg`; alert compares lag with `clamp_min(2 × schedule, 900 s)` (#1417). On 2026-09-28 every watermark was within one refresh window of now, except `ca_equipment_boxes_1s`, whose watermark is `-infinity` (shown as 4714 BC): it has never materialized a bucket because no source row carries `analogs->'Label'` yet. That is empty, not stalled. |
| retention | alerts `RetentionPolicyDrift` (drift rows) and `RetentionPurgeErrors` (errors in `ops.retention_run`), from the `pg_retention_*` exporter queries |
| disk | `HostDiskHigh` at 80 % on the DB host |

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Cagg without a refresh policy (CPACK #196) | a rollup query slowly degrades to the statement timeout; OEE stale for days | real-time cagg with a frozen watermark re-aggregates all raw on every read | check the watermark first; full-gap `refresh_continuous_aggregate`, then add the policy |
| Nightly purge deleting client history (before 2026-09-23) | shift and hourly OEE older than 90 days vanished | hard-coded 90-day DELETE in `purge_analytics_plain` | catalog-driven purge (T0) |
| Unbounded caggs (before 2026-09-23) | disk growth (~7.5 GB/yr from `equipment_categorical_1min` alone) | no retention policy | now 90 days / 13 months |
| Refresh over dropped raw | aggregated history disappears | `refresh_continuous_aggregate(..., NULL, NULL)` or a wide window after retention | refresh only inside the raw horizon |
| Cagg DDL blocks | `DROP MATERIALIZED VIEW` of a cagg times out even with policies paused | ingest's invalidation trigger on the source hypertable holds the lock | quiesce `stream-engine` (RabbitMQ buffers), then DDL |
| Whole-history aggregate crashes the cluster (2026-09-24) | kernel OOM kill, all sessions reset | chunk-wise partial aggregation builds thousands of hash nodes (1,599 chunks) | merge chunks; `SET timescaledb.enable_chunkwise_aggregation = off` and narrow windows |

## Operating it

Change a horizon (never call `add_retention_policy` / `remove_retention_policy` by hand):

```sql
BEGIN;
UPDATE ops.retention_policy SET keep = interval '6 months', updated_at = now()
 WHERE relation = 'silver.equipment_categorical_1hour';
CALL ops.apply_retention();
SELECT * FROM ops.retention_drift;          -- expect 0 rows
COMMIT;
```

Re-apply a whole profile: `psql -d packiot_analytics -f db/retention/profiles/production.sql`.

Refresh a cagg over a window after a raw repair (keep it inside the last 90 days):

```sql
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-09-20', '2026-09-27');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1hour', '2026-09-20', '2026-09-27');
```

Refresh the categorical 1-minute cagg before the 1-hour one: the hourly cagg is built on it.

Pause and resume a job: `SELECT alter_job(<id>, scheduled => false)` … `=> true`. Run one now:
`CALL run_job(<id>)`.

Recent purge results:

```sql
SELECT relation, ran_at, rows_deleted, error FROM ops.retention_run ORDER BY ran_at DESC LIMIT 40;
```

## Tests

- `ops.apply_retention()` validates every `time_expr` with `SELECT … LIMIT 0` before touching
  a policy, so a typo fails loudly.
- The T0 rollout was proven by a dry run inside `BEGIN … ROLLBACK` showing 0 deletions.

## Source map

| Path | What's there |
|---|---|
| `db/migrations/t-retention-catalog/01-up.sql`, `rollback.sql` | catalog, drift view, `apply_retention`, purge procedure |
| `db/retention/profiles/production.sql`, `staging-capped.sql` | environment profiles |
| `db/migrations/analytics-cagg-refresh-policies/` | cagg refresh policies |
| `db/migrations/t261b-caggs-to-silver/`, `t239-*`, `t258a-*`, `t261a-*` | cagg moves and drops |
| `db/init-f3/snapshot/05-f3-cagg-agg.sql`, `10-f3-timescale-supplement.sql` | greenfield hypertable/cagg DDL |
| `scripts/consolidate-event-chunks.sh` | chunk merge for `silver.equipment_events` |
| `monitoring/postgres-exporter/queries.yaml`, `monitoring/prometheus/rules.yml` | `pg_retention_*` metrics and the retention/cagg-lag alerts |
| `docs/plans/unified-hot-cold-serving-grain-tiered-retention.md` | the design and execution log |
