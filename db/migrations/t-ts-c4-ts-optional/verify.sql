\pset format unaligned
SET default_transaction_read_only = on;
-- V1: nothing of ours references timescaledb_information statically any more
SELECT 'V1 views reading timescaledb_information: 0', count(*) FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid
  JOIN pg_class v ON v.oid = r.ev_class JOIN pg_namespace n ON n.oid = v.relnamespace
  JOIN pg_class t ON t.oid = d.refobjid JOIN pg_namespace tn ON tn.oid = t.relnamespace
 WHERE tn.nspname IN ('timescaledb_information', '_timescaledb_catalog') AND n.nspname !~ 'timescaledb';
-- V2: the drift view still answers (0 rows = catalog matches the live policies)
SELECT 'V2 retention_drift rows: 0', count(*) FROM ops.retention_drift;
-- V3: live policies are visible through the function while the extension exists
SELECT 'V3 ts_retention_live rows (= policy_retention jobs, 0 without the extension)', count(*) FROM ops.ts_retention_live();
