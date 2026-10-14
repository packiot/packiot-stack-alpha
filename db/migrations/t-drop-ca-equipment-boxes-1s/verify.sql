-- verify for t-drop-ca-equipment-boxes-1s. label|value, expected in the label. Read-only, cheap.
\set ON_ERROR_STOP 1
SELECT 'V1 cagg gone: t', to_regclass('silver.ca_equipment_boxes_1s') IS NULL;
SELECT 'V2 refresh policies whose cagg no longer exists: 0', count(*)
  FROM timescaledb_information.jobs j
 WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
   AND NOT EXISTS (SELECT 1 FROM _timescaledb_catalog.continuous_agg c WHERE c.mat_hypertable_id = (j.config->>'mat_hypertable_id')::int);
SELECT 'V3 refresh policies left (was 7): 6', count(*) FROM timescaledb_information.jobs WHERE proc_name = 'policy_refresh_continuous_aggregate';
SELECT 'V4 retention catalog row: 0', count(*) FROM ops.retention_policy WHERE relation = 'silver.ca_equipment_boxes_1s';
SELECT 'V5 retention drift rows: 0', count(*) FROM ops.retention_drift;
SELECT 'V6 functions still naming the cagg: 0', count(*) FROM pg_proc WHERE position('ca_equipment_boxes_1s' in prosrc) > 0;
SELECT 'V7 report_shift + _pre_p3b carry the stub: 2', count(*) FROM pg_proc
 WHERE oid IN ('serving.report_shift(integer,date,date)'::regprocedure, 'serving.report_shift_pre_p3b(integer,date,date)'::regprocedure)
   AND position('t-drop-ca-equipment-boxes-1s' in prosrc) > 0;
SELECT 'V8 orphan cagg invalidation rows (materialization without cagg): 0', count(*)
  FROM _timescaledb_catalog.continuous_aggs_materialization_invalidation_log l
 WHERE NOT EXISTS (SELECT 1 FROM _timescaledb_catalog.continuous_agg c WHERE c.mat_hypertable_id = l.materialization_id);
SELECT 'V9 report_shift still plans and runs (enterprise 6): t', count(*) >= 0
  FROM serving.report_shift(6, current_date - 21, current_date);
