-- transplant phase: Timescale background jobs = staging's, EXCEPT retention and purge_analytics_plain (deletes data).
-- RAW RETENTION: decided 2026-10-09 = OFF on prod (no cold tier; staging's 90-day raw drop would delete prod history
-- from ~2026-11-05). Governed by build.py PROD_RAW_RETENTION (default off), which keeps tier='hot_raw' at keep=NULL in
-- ops.retention_policy during phase D. This file never adds a retention policy; the check at the end proves none exists
-- on a raw relation. Compression policies below STAY (they delete nothing). Enable raw retention only when a prod cold
-- tier exists: PROD_RAW_RETENTION=on, or re-apply db/retention/profiles/production.sql afterwards.
\set ON_ERROR_STOP 0
-- compression settings (staging's)
ALTER TABLE silver.equipment_values      SET (timescaledb.compress, timescaledb.compress_segmentby = 'id_equipment', timescaledb.compress_orderby = 'ts_value DESC');
ALTER TABLE silver.equipment_events      SET (timescaledb.compress, timescaledb.compress_segmentby = 'id_equipment', timescaledb.compress_orderby = 'ts_event DESC');
ALTER TABLE bronze.equipment_values_raw  SET (timescaledb.compress, timescaledb.compress_segmentby = 'id_equipment', timescaledb.compress_orderby = 'ts_value DESC, source_seq DESC');
ALTER TABLE bronze.equipment_events_raw  SET (timescaledb.compress, timescaledb.compress_segmentby = 'id_equipment', timescaledb.compress_orderby = 'ts_event DESC, source_seq DESC');
ALTER MATERIALIZED VIEW silver.agg_equipment_values_1min  SET (timescaledb.compress = true, timescaledb.compress_segmentby = 'id_equipment', timescaledb.compress_orderby = 'ts_value DESC');
ALTER MATERIALIZED VIEW silver.agg_equipment_values_1hour SET (timescaledb.compress = true, timescaledb.compress_segmentby = 'id_equipment', timescaledb.compress_orderby = 'ts_value DESC');
ALTER MATERIALIZED VIEW silver.ca_discrete_changes_1s     SET (timescaledb.compress = true, timescaledb.compress_segmentby = 'id_equipment', timescaledb.compress_orderby = 'ts_value DESC');
-- refresh policies (staging's offsets + schedules)
SELECT add_continuous_aggregate_policy('silver.agg_equipment_values_1min',  start_offset => '30 minutes', end_offset => '1 minute', schedule_interval => '1 minute',   if_not_exists => true);
SELECT add_continuous_aggregate_policy('silver.agg_equipment_values_1hour', start_offset => '3 days',     end_offset => '1 hour',   schedule_interval => '30 minutes', if_not_exists => true);
SELECT add_continuous_aggregate_policy('silver.ca_discrete_changes_1s',     start_offset => '30 minutes', end_offset => '1 minute', schedule_interval => '15 minutes', if_not_exists => true);
SELECT add_continuous_aggregate_policy('silver.ca_equipment_boxes_1s',      start_offset => '6 hours',    end_offset => '1 minute', schedule_interval => '15 minutes', if_not_exists => true);
SELECT add_continuous_aggregate_policy('silver.equipment_categorical_1min', start_offset => '3 hours',    end_offset => '2 minutes',schedule_interval => '2 minutes',  if_not_exists => true);
SELECT add_continuous_aggregate_policy('silver.equipment_categorical_1hour',start_offset => '1 day',      end_offset => '1 hour',   schedule_interval => '30 minutes', if_not_exists => true);
SELECT add_continuous_aggregate_policy('silver.equipment_metrics_1min',     start_offset => '3 hours',    end_offset => '1 minute', schedule_interval => '1 minute',   if_not_exists => true);
-- compression policies (staging's)
SELECT add_compression_policy(c, compress_after => i, if_not_exists => true) FROM (VALUES
  ('silver.equipment_values'::regclass, interval '7 days'), ('silver.equipment_events', interval '14 days'),
  ('bronze.equipment_values_raw', interval '7 days'), ('bronze.equipment_events_raw', interval '7 days'),
  ('silver.agg_equipment_values_1min', interval '7 days'), ('silver.agg_equipment_values_1hour', interval '7 days'),
  ('silver.ca_discrete_changes_1s', interval '7 days')) v(c, i);
-- compute jobs (staging's)
SELECT add_job('serving.job_refresh_downtime_events_resolved', schedule_interval => interval '2 minutes')
 WHERE NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'job_refresh_downtime_events_resolved');
SELECT add_job('ops.job_data_invariants', schedule_interval => interval '30 minutes')
 WHERE NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name = 'job_data_invariants');
SELECT 'jobs', count(*) FROM timescaledb_information.jobs WHERE proc_schema NOT LIKE '\_timescaledb%';
-- guard: no drop_chunks policy on raw relations (PROD_RAW_RETENTION=off) — want 0
SELECT 'raw retention policies (want 0)', count(*)
  FROM timescaledb_information.jobs j
 WHERE j.proc_name = 'policy_retention'
   AND j.hypertable_schema || '.' || j.hypertable_name IN (
       'silver.equipment_values', 'bronze.equipment_values_raw', 'bronze.equipment_events_raw',
       'silver.ca_discrete_changes_1s', 'silver.ca_equipment_boxes_1s', 'silver.agg_equipment_values_1min',
       'silver.equipment_metrics_1min', 'silver.equipment_categorical_1min');
