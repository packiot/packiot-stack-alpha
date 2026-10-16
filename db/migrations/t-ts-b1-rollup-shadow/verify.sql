-- t-ts-b1-rollup-shadow — verify (read-only). Every line prints "<check>: <expected>" then the value.
\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 twins present: 5', count(*) FROM pg_tables WHERE schemaname = 'silver' AND tablename LIKE '%\_\_next'
   AND tablename IN ('equipment_categorical_1min__next','equipment_categorical_1hour__next','equipment_metrics_1min__next',
                     'agg_equipment_values_1min__next','agg_equipment_values_1hour__next');
SELECT 'V2 twin columns differing from their cagg: 0', count(*) FROM (
  SELECT c.table_name, c.column_name, c.data_type, c.ordinal_position FROM information_schema.columns c
   WHERE c.table_schema = 'silver' AND c.table_name LIKE '%\_\_next'
  EXCEPT
  SELECT c.table_name || '__next', c.column_name, c.data_type, c.ordinal_position FROM information_schema.columns c
   WHERE c.table_schema = 'silver') x;
SELECT 'V3 invalidation triggers on silver.equipment_values: 3', count(*) FROM pg_trigger
 WHERE tgrelid = 'silver.equipment_values'::regclass AND tgname LIKE 'rollup\_invalidate\_%' AND NOT tgisinternal;
SELECT 'V4 stream_engine may run the tick: t', has_function_privilege('stream_engine', 'silver.rollup_tick(interval, integer)', 'EXECUTE');
SELECT 'V5 stream_engine may NOT write a twin: f', has_table_privilege('stream_engine', 'silver.equipment_categorical_1min__next', 'INSERT');
SELECT 'V6 PUBLIC may NOT call rollup_refresh: f', has_function_privilege('public', 'silver.rollup_refresh(timestamptz, timestamptz, integer[])', 'EXECUTE');
SELECT 'V7 readers of the caggs can read the twins (missing grants): 0', count(*) FROM (
  SELECT g.grantee, g.table_name || '__next' AS t FROM information_schema.role_table_grants g
   WHERE g.table_schema = 'silver' AND g.privilege_type = 'SELECT' AND g.grantee NOT IN ('postgres', 'PUBLIC')
     AND g.table_name IN ('equipment_categorical_1min','equipment_categorical_1hour','equipment_metrics_1min',
                          'agg_equipment_values_1min','agg_equipment_values_1hour')
  EXCEPT
  SELECT g.grantee, g.table_name FROM information_schema.role_table_grants g
   WHERE g.table_schema = 'silver' AND g.privilege_type = 'SELECT') x;
SELECT 'V8 invalidation backlog (info; should stay small once ticking)', count(*) FROM silver.rollup_invalidation;
