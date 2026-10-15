-- t-ts-b4-drop-discrete-1s — verify (read-only)
\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 cagg gone: t', to_regclass('silver.ca_discrete_changes_1s') IS NULL;
SELECT 'V2 its jobs gone: 0', count(*) FROM timescaledb_information.jobs j
 WHERE j.hypertable_name IN (SELECT materialization_hypertable_name FROM timescaledb_information.continuous_aggregates WHERE view_name = 'ca_discrete_changes_1s')
    OR j.config::text LIKE '%"mat_hypertable_id": 22%';
SELECT 'V3 retention catalog row gone: 0', count(*) FROM ops.retention_policy WHERE relation = 'silver.ca_discrete_changes_1s';
SELECT 'V4 retention drift rows (want 0)', count(*) FROM ops.retention_drift;
