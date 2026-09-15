\pset pager off
\set ON_ERROR_STOP off
-- Reverse of 08_p2_serving_functions_port.sql. Additive-only cleanup: drops the
-- ported serving.* functions + their composite row types. Does NOT touch
-- serving.oee_score / serving.machine_speed (from 07_*.sql) or the h_piot_* originals.
-- DROP TYPE ... CASCADE removes both the type and the function that returns it.
DO $d$
DECLARE r record;
BEGIN
  FOR r IN SELECT unnest(ARRAY[
    'downtime_duration_by_category','downtime_events','downtime_events_v2','downtime_by_category',
    'downtime_summary','pending_downtime','events_timeline','events_timeline_by_po','events_timeline_full',
    'mission_control_area','mission_control_timeline','mission_control','production_health','targets','home',
    'oee_progress','oee_score_by_team','overview_events','overview_events_v3','overview_job_info',
    'overview_production_chart','production_chart_legacy','production_chart','production_flow',
    'production_orders','production_orders_with_runtimes','single_period_by_team','single_period_by_team_v4',
    'total_production_by_team']) AS intent
  LOOP
    EXECUTE format('DROP TYPE IF EXISTS serving.%I CASCADE', r.intent||'_row');
  END LOOP;
END $d$;
\echo === remaining serving functions (should be oee_score + machine_speed only) ===
SELECT proname FROM pg_proc WHERE pronamespace='serving'::regnamespace ORDER BY 1;
