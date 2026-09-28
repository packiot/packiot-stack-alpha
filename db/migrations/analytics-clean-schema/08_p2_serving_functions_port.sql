\pset pager off
\set ON_ERROR_STOP off
-- =============================================================================
-- P2 (cont.) — port the remaining contract h_piot_* SETOF functions to the clean
-- serving.* surface. Analytics clean-schema redesign, docs/plans §4/§7.
--
-- Method (drift-proof): each serving.<intent> function is generated from the LIVE
-- pg_get_functiondef of its h_piot_* twin, with exactly two token substitutions:
--   1. FUNCTION public.<oldfn>(  ->  FUNCTION serving.<intent>(
--   2. RETURNS SETOF public.<rt> ->  RETURNS SETOF serving.<intent>_row
-- The 0-row SETOF return-type "table" public.<rt> is replaced by a REAL composite
-- TYPE serving.<intent>_row (§4). Every body references its return type exactly once
-- (verified: rt_refs=1), only in the RETURNS clause, so the body is copied byte-for-
-- byte -> the port is equivalent by construction. Generating from the LIVE catalog
-- (not the stale snapshot) picks up the runtime_->oee_ / uns_->live_ table renames
-- already applied on staging.
--
-- Additive-only. serving.oee_score + serving.machine_speed were built in 07_*.sql;
-- this set covers the other 29 contract functions. Reverse with 08b_*_drop.sql.
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS serving;

DROP TABLE IF EXISTS _serving_port_map;
CREATE TEMP TABLE _serving_port_map(oldfn text, intent text, rt text);
INSERT INTO _serving_port_map(oldfn, intent, rt) VALUES
 ('h_piot_downtimes_duration_by_category','downtime_duration_by_category','h_downtimes_duration_by_category'),
 ('h_piot_get_downtimes_events','downtime_events','h_downtimes_table_with_sector_2'),
 ('h_piot_get_downtimes_events_2','downtime_events_v2','h_downtimes_table_with_sector_3'),
 ('h_piot_get_downtimes_per_category','downtime_by_category','h_piot_get_downtimes_per_category_table'),
 ('h_piot_get_downtimes_resumo','downtime_summary','h_piot_get_downtimes_resumo_table'),
 ('h_piot_get_equipment_pending_downtime_with_event_id','pending_downtime','h_pending_events_with_event_id'),
 ('h_piot_get_events_timeline3_with_event_id','events_timeline','h_events_timeline3_with_event_id'),
 ('h_piot_get_events_timeline_from_po','events_timeline_by_po','h_events_equipment_timeline_2'),
 ('h_piot_get_events_timeline_full_with_filter_3','events_timeline_full','h_events_timeline_full2'),
 ('h_piot_get_mission_control_area_uns_2','mission_control_area','h_piot_mission_control_area_uns_2'),
 ('h_piot_get_mission_control_timeline','mission_control_timeline','h_piot_mission_control_timeline'),
 ('h_piot_get_mission_control_uns_3','mission_control','h_piot_mission_control_uns_3'),
 ('h_piot_get_production_health','production_health','h_production_health'),
 ('h_piot_get_targets','targets','h_piot_production_targets'),
 ('h_piot_home_uns','home','h_piot_home_table'),
 ('h_piot_oee_progress_new2','oee_progress','h_piot_oee_progress_with_teams'),
 ('h_piot_oee_score_with_teams','oee_score_by_team','h_piot_oee_score_teams_table'),
 ('h_piot_overview_i_get_events','overview_events','h_overview_i_events'),
 ('h_piot_overview_i_get_events_3','overview_events_v3','h_overview_i_events_3'),
 ('h_piot_overview_i_get_job_info','overview_job_info','h_overview_i_job_info'),
 ('h_piot_overview_i_production_chart','overview_production_chart','h_overview_i_production_chart'),
 ('h_piot_overview_production_chart','production_chart_legacy','h_overview_i_production_chart'),
 ('h_piot_overview_production_chart_v6','production_chart','h_overview_i_production_chart_v6'),
 ('h_piot_production_flow','production_flow','h_piot_production_flow_table'),
 ('h_piot_production_orders_runtimes','production_orders','h_piot_production_orders_table'),
 ('h_piot_production_orders_with_runtimes4','production_orders_with_runtimes','h_piot_production_orders_with_runtimes_table_4'),
 ('h_piot_single_period_with_teams_3','single_period_by_team','h_single_period_equipment_chart_table_3'),
 ('h_piot_single_period_with_teams_4','single_period_by_team_v4','h_single_period_equipment_chart_table_4'),
 ('h_piot_total_production_teams_2','total_production_by_team','h_total_production_chart_from_runtime');

DO $gen$
DECLARE r record; fdef text; cols text; newdef text; tn text; oldoid oid; n int := 0;
BEGIN
  FOR r IN SELECT * FROM _serving_port_map ORDER BY oldfn LOOP
    SELECT p.oid INTO oldoid FROM pg_proc p
      WHERE p.pronamespace='public'::regnamespace AND p.proname=r.oldfn;
    IF oldoid IS NULL THEN RAISE WARNING 'SKIP % (source function not found)', r.oldfn; CONTINUE; END IF;
    tn := 'serving.'||quote_ident(r.intent||'_row');
    -- real composite type mirroring the 0-row return-type table's columns
    SELECT string_agg(quote_ident(a.attname)||' '||format_type(a.atttypid,a.atttypmod), ', ' ORDER BY a.attnum)
      INTO cols FROM pg_attribute a
      WHERE a.attrelid=('public.'||quote_ident(r.rt))::regclass AND a.attnum>0 AND NOT a.attisdropped;
    EXECUTE format('DROP TYPE IF EXISTS %s CASCADE', tn);
    EXECUTE format('CREATE TYPE %s AS (%s)', tn, cols);
    -- copy live body, swap only the fn name + the return type
    fdef := pg_get_functiondef(oldoid);
    newdef := replace(fdef, 'FUNCTION public.'||r.oldfn||'(', 'FUNCTION serving.'||quote_ident(r.intent)||'(');
    newdef := regexp_replace(newdef, 'SETOF (public\.)?'||r.rt||'(\s|$)', 'SETOF '||tn||E'\\2');
    EXECUTE newdef;
    n := n + 1;
    RAISE NOTICE 'PORTED %  ->  serving.%', r.oldfn, r.intent;
  END LOOP;
  RAISE NOTICE 'total ported: %', n;
END $gen$;

GRANT USAGE ON SCHEMA serving TO superset_ro, bi_owner;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA serving TO superset_ro, bi_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA serving TO superset_ro, bi_owner;

\echo === serving functions after port ===
SELECT count(*) AS serving_functions FROM pg_proc WHERE pronamespace='serving'::regnamespace;
SELECT count(*) AS serving_row_types FROM pg_type WHERE typnamespace='serving'::regnamespace AND typtype='c' AND typname LIKE '%\_row';
