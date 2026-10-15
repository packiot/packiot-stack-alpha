-- t-ts-b2-rollup-cutover — verify (read-only)
\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 the five rollups are plain tables (r): 5', count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'silver' AND c.relkind = 'r' AND c.relname IN ('equipment_categorical_1min','equipment_categorical_1hour',
       'equipment_metrics_1min','agg_equipment_values_1min','agg_equipment_values_1hour');
SELECT 'V2 no twin left: 0', count(*) FROM pg_tables WHERE schemaname = 'silver' AND tablename LIKE '%\_\_next';
SELECT 'V3 caggs left (only ones not part of B2, if any)', coalesce(string_agg(view_name, ','), '<none>') FROM timescaledb_information.continuous_aggregates;
SELECT 'V4 retention rows now plain: 5', count(*) FROM ops.retention_policy WHERE kind = 'plain' AND relation IN
 ('silver.equipment_categorical_1min','silver.equipment_categorical_1hour','silver.equipment_metrics_1min',
  'silver.agg_equipment_values_1min','silver.agg_equipment_values_1hour');
SELECT 'V5 readers keep SELECT (readapi_ro on categorical_1hour): t', has_table_privilege('readapi_ro', 'silver.equipment_categorical_1hour', 'SELECT');
SELECT 'V6 freshest minute bucket lag in seconds (want < 180 with the tick on)', round(extract(epoch FROM now() - max(ts_value)))::int FROM silver.equipment_categorical_1min;
