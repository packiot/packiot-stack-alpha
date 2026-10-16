\pset format unaligned
SET default_transaction_read_only = on;
SELECT 'V1 manifest + exempt + blocked tables', count(*) FROM pg_class WHERE oid IN (to_regclass('ops.cold_export'), to_regclass('ops.cold_export_exempt'), to_regclass('ops.partition_drop_blocked'));
SELECT 'V2 partition_maintain returns blocked', pg_get_function_result('ops.partition_maintain(interval)'::regprocedure) LIKE '%blocked integer%';
SELECT 'V3 gated relations (cold_copy set)', string_agg(relation, ', ') FROM ops.retention_policy
 WHERE relation IN (SELECT rel FROM ops.pc_state) AND nullif(cold_copy, 'none') IS NOT NULL;
SELECT 'V4 blocked partitions now', count(*) FROM ops.partition_drop_blocked;
