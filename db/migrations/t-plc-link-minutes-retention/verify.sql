-- verify for t-plc-link-minutes-retention. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 catalog row (hypertable, ts_minute, 90 days, hot_raw): t',
       EXISTS (SELECT 1 FROM ops.retention_policy WHERE relation = 'silver.plc_link_minutes' AND kind = 'hypertable'
                 AND time_expr = 'ts_minute' AND keep = interval '90 days' AND tier = 'hot_raw');
SELECT 'V2 live retention policy drop_after: 90 days', (config->>'drop_after')::interval
  FROM timescaledb_information.jobs
 WHERE proc_name = 'policy_retention' AND hypertable_schema = 'silver' AND hypertable_name = 'plc_link_minutes';
SELECT 'V3 exactly one retention job on the table: 1', count(*)
  FROM timescaledb_information.jobs
 WHERE proc_name = 'policy_retention' AND hypertable_schema = 'silver' AND hypertable_name = 'plc_link_minutes';
SELECT 'V4 drift rows for silver.plc_link_minutes: 0', count(*) FROM ops.retention_drift WHERE relation = 'silver.plc_link_minutes';
SELECT 'I1 drift rows, all relations (informational; pre-existing drift is not this migration''s)', count(*) FROM ops.retention_drift;
SELECT 'I2 oldest row (informational; the policy drops whole 7-day chunks older than 90 days)', min(ts_minute) FROM silver.plc_link_minutes;
