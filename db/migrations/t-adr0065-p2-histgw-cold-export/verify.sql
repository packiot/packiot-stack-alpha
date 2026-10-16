\pset format unaligned
SELECT 'V1 histgw_ro can read ops.cold_export: t', has_table_privilege('histgw_ro', 'ops.cold_export', 'SELECT');
