-- t-bispharma-mock-rated-speeds — give Bispharma (enterprise 5) machines realistic,
-- per-machine rated speeds so the twin mock produces a MEANINGFUL OEE Performance
-- factor instead of a placeholder. STAGING.
--
-- WHY
-- ───
-- All 105 ent-5 machines carry production_speed=100 (an onboarding placeholder). OEE
-- Performance = gross / (production_speed · running/60) (services/stream-engine/internal/
-- rollup/oee.go::PerformanceFactor). With a flat placeholder well below the twin's
-- synthetic throughput, raw P > 1 everywhere → P is clamped to 1.0 (pinned, meaningless)
-- and the physics rule IDEAL_SPEED_TOO_LOW fires every bucket. As a faithful MOCK of the
-- real box (which will carry real rated speeds), we set a per-machine CPACK-like spread.
--
-- VALUES
-- ──────
-- CPACK (enterprise 3, real PLCs) production_speed spans ~21..147 units/min (avg ~118).
-- We assign each ent-5 machine a deterministic per-machine value in 65..135 units/min —
-- a CPACK-like spread kept ABOVE the twin's per-machine rate (TWIN_RATE_PER_MIN=50, max
-- ~57.5 with +15% jitter) so actual < rated on every machine → P in a realistic 0.3..0.9
-- band with NO clamp. Deterministic (hashed off id_equipment) so re-runs are stable.
--
-- When the real box comes online these are overwritten by real rated speeds (CS tuning).
-- Reversible: prior values backed up to ops._bkp_ent5_production_speed.

BEGIN;

CREATE TABLE IF NOT EXISTS ops._bkp_ent5_production_speed AS
  SELECT id_equipment, production_speed, now() AS backed_up_at
  FROM core.equipments WHERE id_enterprise = 5;

-- 65 + (0..70) = 65..135 units/min, deterministic per machine (stable across re-runs).
UPDATE core.equipments
SET production_speed = 65 + (abs(('x' || substr(md5(id_equipment::text), 1, 8))::bit(32)::int) % 71)
WHERE id_enterprise = 5 AND tp_equipment = 1;

COMMIT;

-- Verify (after): expect min>=65, max<=135, 0 rows still at the 100 placeholder, spread present.
--   SELECT min(production_speed), max(production_speed), round(avg(production_speed),1),
--          count(*) FILTER (WHERE production_speed=100) AS still_placeholder,
--          count(DISTINCT production_speed) AS distinct_speeds
--     FROM core.equipments WHERE id_enterprise=5 AND tp_equipment=1;
