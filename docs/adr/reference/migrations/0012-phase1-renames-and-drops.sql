-- ADR-0012 Phase 1: renames + drops on sandbox
-- Demonstrates the migration pattern end-to-end

\echo '========== PHASE 1a: populate sandbox with prod-only pathologies for demo =========='

-- Simulate the pathologies that exist in prod but not in the sandbox stub
CREATE TABLE IF NOT EXISTS report_shift_enterprsie_06 (ts_value timestamptz, valor int); -- typo
CREATE TABLE IF NOT EXISTS report_speed_enterprsie_33 (ts_value timestamptz, valor int); -- typo
CREATE TABLE IF NOT EXISTS monitoramento_execucao_functions (ts_value timestamptz, function_name text); -- pt-BR
CREATE TABLE IF NOT EXISTS agg_equipment_values_1min_t (ts_value timestamptz, id_equipment int, val double precision); -- opaque _t
CREATE TABLE IF NOT EXISTS dt5min_po_func_ret (ts_value timestamptz, po_id text); -- cryptic
CREATE TABLE IF NOT EXISTS mv_agg_equipment_values_1min_full_hot (ts_value timestamptz, val double precision); -- retired design
CREATE TABLE IF NOT EXISTS mv_agg_equipment_values_1min_full_warm (ts_value timestamptz, val double precision);
CREATE TABLE IF NOT EXISTS mv_agg_equipment_values_1hour_full_hot (ts_value timestamptz, val double precision);
CREATE TABLE IF NOT EXISTS mv_agg_equipment_values_1hour_full_warm (ts_value timestamptz, val double precision);
CREATE TABLE IF NOT EXISTS agg_equipment_values_1day_archive (ts_value timestamptz, val double precision); -- superseded archive
CREATE TABLE IF NOT EXISTS agg_equipment_values_1week_archive (ts_value timestamptz, val double precision);
CREATE TABLE IF NOT EXISTS agg_equipment_values_1month_archive (ts_value timestamptz, val double precision);
CREATE TABLE IF NOT EXISTS hasura_test (id int); -- test artifact
CREATE TABLE IF NOT EXISTS data_sync_enterprise_06 (id int, valor int);
CREATE TABLE IF NOT EXISTS data_sync_enterprise_06b (id int, valor int);
CREATE TABLE IF NOT EXISTS downtime_sync_enterprise_06 (id int, ts_start timestamptz);
CREATE TABLE IF NOT EXISTS shift_agg_from_events_v2 (id_equipment int, ts_shift date); -- superseded version
CREATE TABLE IF NOT EXISTS shift_agg_from_events_v3 (id_equipment int, ts_shift date);
CREATE TABLE IF NOT EXISTS shift_agg_from_events_v4 (id_equipment int, ts_shift date);
CREATE TABLE IF NOT EXISTS v_operator_po_details_2 (po_id text);
CREATE TABLE IF NOT EXISTS v_operator_po_details_3 (po_id text);
CREATE TABLE IF NOT EXISTS v_events_2 (ts_value timestamptz);

\echo ''
\echo '========== PHASE 1b: PRE-STATE (count) =========='
SELECT COUNT(*) AS objects_before FROM pg_tables WHERE schemaname='public';

\echo ''
\echo '========== TASK #71: RENAMES =========='

BEGIN;

-- Typo fixes (create façade views under old typo'd names for backward compat)
ALTER TABLE public.report_shift_enterprsie_06 RENAME TO report_shift_enterprise_06;
CREATE VIEW public.report_shift_enterprsie_06 AS SELECT * FROM public.report_shift_enterprise_06;

ALTER TABLE public.report_speed_enterprsie_33 RENAME TO report_speed_enterprise_33;
CREATE VIEW public.report_speed_enterprsie_33 AS SELECT * FROM public.report_speed_enterprise_33;

-- pt-BR legacy rename
ALTER TABLE public.monitoramento_execucao_functions RENAME TO function_execution_log;
CREATE VIEW public.monitoramento_execucao_functions AS SELECT * FROM public.function_execution_log;

-- Opaque suffix drop (_t)
ALTER TABLE public.agg_equipment_values_1min_t RENAME TO equipment_values_1min;
CREATE VIEW public.agg_equipment_values_1min_t AS SELECT * FROM public.equipment_values_1min;

-- Cryptic rename
ALTER TABLE public.dt5min_po_func_ret RENAME TO dt5min_po_function_returns;
CREATE VIEW public.dt5min_po_func_ret AS SELECT * FROM public.dt5min_po_function_returns;

\echo 'Renames complete. Backward-compat views created for every renamed object.'

COMMIT;

\echo ''
\echo '========== TASK #73: DROPS =========='

BEGIN;

-- Retired matview family: mv_agg_*_full_hot|_full_warm (all 0 rows on prod)
DROP TABLE public.mv_agg_equipment_values_1min_full_hot;
DROP TABLE public.mv_agg_equipment_values_1min_full_warm;
DROP TABLE public.mv_agg_equipment_values_1hour_full_hot;
DROP TABLE public.mv_agg_equipment_values_1hour_full_warm;

-- Superseded archives (user confirmed unused earlier)
DROP TABLE public.agg_equipment_values_1day_archive;
DROP TABLE public.agg_equipment_values_1week_archive;
DROP TABLE public.agg_equipment_values_1month_archive;

-- Test artifact + enterprise 06 sync legacy (all empty on prod)
DROP TABLE public.hasura_test;
DROP TABLE public.data_sync_enterprise_06;
DROP TABLE public.data_sync_enterprise_06b;
DROP TABLE public.downtime_sync_enterprise_06;

\echo 'Drops complete. 11 dead objects removed.'

COMMIT;

\echo ''
\echo '========== TASK #71b: version-suffix retirement =========='

BEGIN;

-- shift_agg_from_events family: base has 1 dep, _v2 has 1 dep on prod, _v3/_v4 have 0.
-- Retire _v3 + _v4 (verified 0 dependents on prod), keep base + _v2 until dependents migrate.
DROP TABLE public.shift_agg_from_events_v3;
DROP TABLE public.shift_agg_from_events_v4;

-- v_operator_po_details: base has 0 dep, _2 has 0, _3 has 0 on prod → retire ALL suffixed
DROP TABLE public.v_operator_po_details_2;
DROP TABLE public.v_operator_po_details_3;

-- v_events + v_events_2: both 0 deps → retire _2, keep base
DROP TABLE public.v_events_2;

\echo 'Version suffixes retired (v3+v4 shift, _2+_3 operator details, _2 events).'

COMMIT;

\echo ''
\echo '========== VERIFICATION =========='

\echo '=== Renamed tables + their backward-compat façades ==='
SELECT
  c.relname AS name,
  CASE c.relkind WHEN 'r' THEN 'TABLE' WHEN 'v' THEN 'VIEW' ELSE c.relkind::text END AS kind
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND c.relname ~ '^(report_shift_enterp|report_speed_enterp|monitoramento_execucao|function_execution|agg_equipment_values_1min_t|equipment_values_1min|dt5min_po)'
ORDER BY name;

\echo ''
\echo '=== Dropped objects (should NOT appear) ==='
SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND c.relname IN ('hasura_test','mv_agg_equipment_values_1min_full_hot','data_sync_enterprise_06','agg_equipment_values_1day_archive','shift_agg_from_events_v3','v_operator_po_details_2')
ORDER BY relname;

\echo ''
\echo '=== Backward-compat facade returns identical rows to canonical ==='
INSERT INTO public.function_execution_log (ts_value, function_name) VALUES (now(), 'test_fn');
SELECT COUNT(*) AS via_new_name FROM public.function_execution_log;
SELECT COUNT(*) AS via_old_facade FROM public.monitoramento_execucao_functions;
DELETE FROM public.function_execution_log WHERE function_name='test_fn';

\echo ''
\echo '=== Final object count ==='
SELECT COUNT(*) AS objects_after FROM pg_tables WHERE schemaname='public';
