\pset pager off
\set ON_ERROR_STOP off

-- ============ REVERSIBILITY: back up data-bearing tables ============
CREATE SCHEMA IF NOT EXISTS drop_backup_20260908;
COMMENT ON SCHEMA drop_backup_20260908 IS 'P0c reversible backup of dropped data-bearing objects (analytics clean-schema cutover 2026-09-08). Safe to drop after cutover verified.';
CREATE TABLE IF NOT EXISTS drop_backup_20260908.totalizer_spike_backup AS SELECT * FROM public._totalizer_spike_backup_20260907;
CREATE TABLE IF NOT EXISTS drop_backup_20260908.hist_production_orders AS SELECT * FROM public.hist_production_orders;
CREATE TABLE IF NOT EXISTS drop_backup_20260908.hist_production_orders_runtime AS SELECT * FROM public.hist_production_orders_runtime;
CREATE TABLE IF NOT EXISTS drop_backup_20260908.twin_backfill_po_log AS SELECT * FROM public.twin_backfill_po_log;
CREATE TABLE IF NOT EXISTS drop_backup_20260908.areas_history AS SELECT * FROM public.areas_history;
CREATE TABLE IF NOT EXISTS drop_backup_20260908.enterprises_history AS SELECT * FROM public.enterprises_history;
CREATE TABLE IF NOT EXISTS drop_backup_20260908.sites_history AS SELECT * FROM public.sites_history;
CREATE TABLE IF NOT EXISTS drop_backup_20260908.equipments_history AS SELECT * FROM public.equipments_history;
\echo === backup row counts ===
SELECT 'totalizer' t, count(*) FROM drop_backup_20260908.totalizer_spike_backup
UNION ALL SELECT 'hist_po', count(*) FROM drop_backup_20260908.hist_production_orders
UNION ALL SELECT 'hist_po_rt', count(*) FROM drop_backup_20260908.hist_production_orders_runtime
UNION ALL SELECT 'twin_log', count(*) FROM drop_backup_20260908.twin_backfill_po_log
UNION ALL SELECT 'equipments_history', count(*) FROM drop_backup_20260908.equipments_history;

-- ============ PHASE A: dead functions (frees their return-type tables) ============
DROP FUNCTION IF EXISTS public.h_piot_get_downtimes(timestamp without time zone, timestamp without time zone);
DROP FUNCTION IF EXISTS public.h_piot_oee_score_fix1(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean);
DROP FUNCTION IF EXISTS public.h_piot_oee_score_fix1a(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean);
DROP FUNCTION IF EXISTS public.h_piot_production_orders_with_runtimes(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text);
DROP FUNCTION IF EXISTS public.piot_get_shift_hours_by_packml_topic(text);
DROP FUNCTION IF EXISTS public.piot4_13_get_dt5min_po(bigint);
DROP FUNCTION IF EXISTS public.piot4_13_get_microstops_po(bigint);
DROP FUNCTION IF EXISTS public.piot4_13_get_production_po(bigint);
DROP FUNCTION IF EXISTS public.piot4_13_get_production_shift_pos(bigint);

-- ============ PHASE B: dead views ============
DROP VIEW IF EXISTS public.c33_dashboard_producao_24h;
DROP VIEW IF EXISTS public.c35_dashboard_paradas_24h;
DROP VIEW IF EXISTS public.c35_dashboard_producao_24h;
DROP VIEW IF EXISTS public.c35_dashboard_timeline_24h;
DROP VIEW IF EXISTS public.dt5min_po_func_ret;
DROP VIEW IF EXISTS public.report_shift_enterprsie_06;
DROP VIEW IF EXISTS public.report_speed_enterprsie_33;
DROP VIEW IF EXISTS public.v_events_2;
DROP VIEW IF EXISTS public.agg_lab_equipment_values_1min;
DROP VIEW IF EXISTS public.ca_agg_lab_equipment_values_1min;

-- ============ PHASE C: lab cagg + hypertable ============
DROP MATERIALIZED VIEW IF EXISTS public.ca_lab_equipment_values_1min;
DROP TABLE IF EXISTS public.lab_equipment_values;

-- ============ PHASE D: dead tables (return-type tables now free + isolated) ============
DROP TABLE IF EXISTS public.h_downtimes_table;
DROP TABLE IF EXISTS public.h_piot_oee_score_data_test1;
DROP TABLE IF EXISTS public.h_piot_production_orders_with_runtimes_table;
DROP TABLE IF EXISTS public.h_events_timeline;
DROP TABLE IF EXISTS public._totalizer_spike_backup_20260907;
DROP TABLE IF EXISTS public.hist_production_orders;
DROP TABLE IF EXISTS public.hist_production_orders_runtime;
DROP TABLE IF EXISTS public.twin_backfill_po_log;
DROP TABLE IF EXISTS public.function_execution_log;
DROP TABLE IF EXISTS public.insights_logs;
DROP TABLE IF EXISTS public.dt5min_po_function_returns;
DROP TABLE IF EXISTS public.microstops_13_po_func_ret;
DROP TABLE IF EXISTS public.production_13_po_func_ret;
DROP TABLE IF EXISTS public.shift_pos_13_po_func_ret;

-- ============ PHASE E: *_history SCD2 twins (decision #2) — stop writers first ============
DROP TRIGGER IF EXISTS trg_scd2_history ON public.areas;
DROP TRIGGER IF EXISTS trg_scd2_history ON public.enterprises;
DROP TRIGGER IF EXISTS trg_scd2_history ON public.sites;
DROP TRIGGER IF EXISTS trg_scd2_history ON public.equipments;
DROP FUNCTION IF EXISTS public.log_dimension_history();
DROP TABLE IF EXISTS public.areas_history;
DROP TABLE IF EXISTS public.enterprises_history;
DROP TABLE IF EXISTS public.sites_history;
DROP TABLE IF EXISTS public.equipments_history;

-- ============ PHASE F: cutover schema (self-contained parity_log artifact) ============
DROP SCHEMA IF EXISTS cutover CASCADE;

\echo === DROP SCRIPT COMPLETE ===
