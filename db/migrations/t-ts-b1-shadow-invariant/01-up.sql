-- t-ts-b1-shadow-invariant — record the ADR-0063 Phase B shadow diff as data invariants (2026-10-15).
--
-- The B2 cutover's exit criterion is "7 days of zero twin-vs-truth diff". Instead of someone running
-- silver.rollup_shadow_diff() by hand every day, the shadow tick (stream-engine, internal/rollupshadow)
-- calls silver.rollup_shadow_record() once an hour for the previous complete hour, which writes:
--   R1_rollup_twin_vs_truth  warn  per target: (equipment, minute) buckets where a twin ≠ raw truth.
--                                  Must be 0 — anything else is a bug in the tick/invalidation.
--   R2_cagg_vs_truth         info  per target: same for the TimescaleDB cagg (stale materialization of
--                                  late data — the reason for Phase B; expected to be > 0 at times).
-- Same table, alerting and views as the in-DB invariants, with source = 'rollup-shadow' (like the
-- prod-reflector's MR1–MR5). The gate becomes one query (verify.sql V3).
\set ON_ERROR_STOP 1
BEGIN;
CREATE OR REPLACE FUNCTION silver.rollup_shadow_record(p_from timestamptz, p_to timestamptz)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
DECLARE t timestamptz := now(); n integer;
BEGIN
  INSERT INTO ops.data_invariant_result (run_at, check_id, dimension, layer, severity, id_enterprise, observed, expected, ok, detail, source)
  WITH d AS MATERIALIZED (SELECT * FROM silver.rollup_shadow_diff(p_from, p_to))   -- one diff, two checks
  SELECT t, 'R1_rollup_twin_vs_truth', 'consistency', 'silver', 'warn', NULL::integer, d.twin_vs_truth, '= 0', d.twin_vs_truth = 0,
         d.target || ' ' || to_char(p_from, 'YYYY-MM-DD HH24:MI') || '..' || to_char(p_to, 'HH24:MI') || ' UTC, ' || d.buckets_twin || ' buckets',
         'rollup-shadow'
    FROM d
  UNION ALL
  SELECT t, 'R2_cagg_vs_truth', 'consistency', 'silver', 'info', NULL::integer, d.cagg_vs_truth, '= 0 (stale cagg if > 0)', d.cagg_vs_truth = 0,
         d.target || ' ' || to_char(p_from, 'YYYY-MM-DD HH24:MI') || '..' || to_char(p_to, 'HH24:MI') || ' UTC, ' || d.buckets_cagg || ' buckets',
         'rollup-shadow'
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
