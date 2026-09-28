-- P3 — repoint the last serving fn off the legacy numeric agg_* family.
-- ============================================================================
-- serving.mission_control_timeline reads the NUMERIC cagg agg_equipment_values_1min
-- (only column used: speed = avg). Its clean home is silver.equipment_metrics_1min.
--
-- BLOCKER + FIX: silver.equipment_metrics_* were built materialized_only=true (no
-- real-time union), so a 24h status timeline lost the current minute (gate: 15/11402
-- cells missing, all at each equipment's most-recent position). agg_* is
-- materialized_only=false (real-time). Flip the silver numeric family to real-time to
-- match — strictly a freshness improvement (union adds RAW only beyond the ~2min
-- watermark), reversible, and only serving.machine_speed + this fn read the family.
-- After the flip the re-gate is EXACT: old(agg) vs new(silver) 11403=11403, 0/0
-- (no speed-threshold classification flips despite float4 avg -> float8 avg).
-- ============================================================================
ALTER MATERIALIZED VIEW silver.equipment_metrics_1min  SET (timescaledb.materialized_only = false);
ALTER MATERIALIZED VIEW silver.equipment_metrics_10min SET (timescaledb.materialized_only = false);
ALTER MATERIALIZED VIEW silver.equipment_metrics_1hour SET (timescaledb.materialized_only = false);
ALTER MATERIALIZED VIEW silver.equipment_metrics_1day  SET (timescaledb.materialized_only = false);

-- Repoint (drift-proof): swap only the inner scan; re-alias silver's bucket/sum_speed+cnt_speed
-- back to the ts_value/speed(=avg) names the outer body expects.
DO $$
DECLARE def text; nd text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO def FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='serving' AND p.proname='mission_control_timeline';
  nd := regexp_replace(def, 'select \* from agg_equipment_values_1min',
    'select bucket as ts_value, id_equipment, tp_equipment, (sum_speed/nullif(cnt_speed,0)) as speed from silver.equipment_metrics_1min');
  IF nd = def THEN RAISE EXCEPTION 'no agg ref found in mission_control_timeline'; END IF;
  EXECUTE nd;
  RAISE NOTICE 'repointed serving.mission_control_timeline -> silver.equipment_metrics_1min';
END $$;

-- Post-condition: the entire serving layer must be off agg_*/ca_agg_*.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid=p.pronamespace
  WHERE nsp.nspname='serving' AND p.prokind='f' AND (
    pg_get_functiondef(p.oid) LIKE '%ca_agg_equipment_values%' OR pg_get_functiondef(p.oid) LIKE '%agg_equipment_values%'
    OR pg_get_functiondef(p.oid) LIKE '%agg_area_values%' OR pg_get_functiondef(p.oid) LIKE '%agg_site_values%');
  IF n <> 0 THEN RAISE EXCEPTION 'serving still has % agg_/ca_agg reader(s)', n; END IF;
  RAISE NOTICE 'serving layer fully off agg_*/ca_agg_*';
END $$;
