\pset pager off
\set ON_ERROR_STOP off
SELECT add_continuous_aggregate_policy('silver.equipment_metrics_1min',
  start_offset => INTERVAL '3 hours', end_offset => INTERVAL '1 minute', schedule_interval => INTERVAL '1 minute');
SELECT add_continuous_aggregate_policy('silver.equipment_metrics_10min',
  start_offset => INTERVAL '6 hours', end_offset => INTERVAL '10 minutes', schedule_interval => INTERVAL '10 minutes');
SELECT add_continuous_aggregate_policy('silver.equipment_metrics_1hour',
  start_offset => INTERVAL '2 days', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '1 hour');
SELECT add_continuous_aggregate_policy('silver.equipment_metrics_1day',
  start_offset => INTERVAL '30 days', end_offset => INTERVAL '1 day', schedule_interval => INTERVAL '1 hour');
\echo === ASSERTION: every silver cagg has a refresh policy (expect 4/4) ===
-- jobs.hypertable_name is the USER view name (not the materialization hypertable) in TSDB 2.x,
-- so join on the user view, not materialization_hypertable_name.
SELECT ca.view_name,
  (SELECT count(*) FROM timescaledb_information.jobs j
    WHERE j.hypertable_schema = ca.view_schema
      AND j.hypertable_name = ca.view_name
      AND j.proc_name='policy_refresh_continuous_aggregate') AS policies
FROM timescaledb_information.continuous_aggregates ca
WHERE ca.view_schema='silver' ORDER BY 1;
