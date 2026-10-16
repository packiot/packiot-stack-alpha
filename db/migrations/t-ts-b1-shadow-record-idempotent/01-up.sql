-- t-ts-b1-shadow-record-idempotent — ADR-0063 B1: one R1/R2 record per hour WINDOW (2026-10-15).
-- stream-engine remembers the last recorded hour in memory, so a restart re-records the same hour
-- (staging: 15:00..16:00 recorded at 16:07 and again at 16:44 after a maintenance restart). The B2 gate
-- counted DISTINCT run_at, so restarts would have inflated "clean hours" and opened the gate early.
-- Now the function records a window once (a re-call returns 0) and the gate counts distinct windows.
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION silver.rollup_shadow_record(p_from timestamptz, p_to timestamptz)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
DECLARE t timestamptz := now(); n integer; w text := to_char(p_from AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI');
BEGIN
  IF to_regclass('silver.equipment_categorical_1min__next') IS NULL THEN RETURN 0; END IF;   -- after B2
  IF EXISTS (SELECT 1 FROM ops.data_invariant_result WHERE source = 'rollup-shadow'
              AND check_id = 'R1_rollup_twin_vs_truth' AND detail LIKE '% ' || w || '..%') THEN
    RETURN 0;   -- this hour window is already recorded
  END IF;
  INSERT INTO ops.data_invariant_result (run_at, check_id, dimension, layer, severity, id_enterprise, observed, expected, ok, detail, source)
  WITH d AS MATERIALIZED (SELECT * FROM silver.rollup_shadow_diff(p_from, p_to))
  SELECT t, 'R1_rollup_twin_vs_truth', 'consistency', 'silver', 'warn', NULL::integer, d.twin_vs_truth, '= 0', d.twin_vs_truth = 0,
         d.target || ' ' || w || '..' || to_char(p_to AT TIME ZONE 'UTC', 'HH24:MI') || ' UTC, ' || d.buckets_twin || ' buckets', 'rollup-shadow'
    FROM d
  UNION ALL
  SELECT t, 'R2_cagg_vs_truth', 'consistency', 'silver', 'info', NULL::integer, d.cagg_vs_truth, '= 0 (stale cagg if > 0)', d.cagg_vs_truth = 0,
         d.target || ' ' || w || '..' || to_char(p_to AT TIME ZONE 'UTC', 'HH24:MI') || ' UTC, ' || d.buckets_cagg || ' buckets', 'rollup-shadow'
    FROM d;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $f$;
REVOKE ALL ON FUNCTION silver.rollup_shadow_record(timestamptz, timestamptz) FROM PUBLIC;
DO $s$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stream_engine') THEN
    GRANT EXECUTE ON FUNCTION silver.rollup_shadow_record(timestamptz, timestamptz) TO stream_engine;
  END IF;
END $s$;
COMMIT;
