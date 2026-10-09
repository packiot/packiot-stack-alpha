-- 08-oee-full-bounds-and-po-summary.sql — ADR-0037 output-invariant, tightened.
-- __SCH__ = target schema (public on packiot_analytics / F3). Idempotent.
--
-- CONTEXT. Migration 07 landed the UPPER-BOUND guard (oee* ≤ 1) because the code
-- clamp was only LEAST(ratio,1) — no lower bound, so a `BETWEEN 0 AND 1` would
-- have rejected a legitimate future negative row and broken the rollup write.
--
-- The rollup clamp is now tightened to GREATEST(LEAST(ratio,1),0) across ALL 29
-- served-OEE sites (fix/oee-clamp-floor-and-between) — the code can no longer
-- emit <0 OR >1. That unblocks migration-07 deferred item (a): swap the
-- upper-bound-only CHECK for the full `BETWEEN 0 AND 1` Silver invariant.
--
-- This migration:
--   (1) upgrades the 6 runtime tables' `*_oee_ubound` (≤1) → `*_oee_bounds`
--       (BETWEEN 0 AND 1). Existing rows already in [0,1] from migration 07 (1).
--   (2) closes deferred item (c): the `production_orders` SUMMARY table. Its
--       oee/oee_availability/oee_performance are code-clamped [0,1] (recalc.go);
--       oee_quality was a BARE net/gross (unclamped) — now GREATEST(LEAST,0) too
--       (same commit). One-time clamp existing rows + add production_orders_oee_bounds.
--
-- STILL DEFERRED: `net <= gross` raw invariant (needs a Bronze reprocess, not an
-- output clamp — see BRONZE_RAW_APPEND / ADR-0036 B1).

BEGIN;

-- ── (1) 6 runtime tables: upper-bound-only → full BETWEEN 0 AND 1 ─────────────
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY['equipment_runtime_shift','equipment_runtime_1hour',
                               'equipment_runtime_1day','area_runtime_shift',
                               'site_runtime_shift','production_orders_runtime'])
  LOOP
    IF to_regclass('__SCH__.'||t) IS NOT NULL THEN
      -- belt-and-suspenders: re-clamp any row that slipped in <0 or >1 before the
      -- code floor shipped, so VALIDATE below cannot fail on a stale row.
      EXECUTE format('UPDATE __SCH__.%I SET '
        || 'oee=GREATEST(LEAST(oee,1),0), oee_a=GREATEST(LEAST(oee_a,1),0), '
        || 'oee_p=GREATEST(LEAST(oee_p,1),0), oee_q=GREATEST(LEAST(oee_q,1),0) '
        || 'WHERE oee NOT BETWEEN 0 AND 1 OR oee_a NOT BETWEEN 0 AND 1 '
        || 'OR oee_p NOT BETWEEN 0 AND 1 OR oee_q NOT BETWEEN 0 AND 1', t);
      -- drop the old upper-bound-only constraint if present
      IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = t||'_oee_ubound') THEN
        EXECUTE format('ALTER TABLE __SCH__.%I DROP CONSTRAINT %I', t, t||'_oee_ubound');
      END IF;
      -- add the full both-ends invariant
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = t||'_oee_bounds') THEN
        EXECUTE format('ALTER TABLE __SCH__.%I ADD CONSTRAINT %I CHECK '
          || '(oee BETWEEN 0 AND 1 AND oee_a BETWEEN 0 AND 1 '
          || 'AND oee_p BETWEEN 0 AND 1 AND oee_q BETWEEN 0 AND 1) NOT VALID', t, t||'_oee_bounds');
        EXECUTE format('ALTER TABLE __SCH__.%I VALIDATE CONSTRAINT %I', t, t||'_oee_bounds');
      END IF;
    END IF;
  END LOOP;
END $$;

-- ── (2) production_orders SUMMARY table (deferred item c) ─────────────────────
DO $$
BEGIN
  IF to_regclass('__SCH__.production_orders') IS NOT NULL THEN
    UPDATE __SCH__.production_orders
       SET oee              = GREATEST(LEAST(oee, 1), 0),
           oee_availability = GREATEST(LEAST(oee_availability, 1), 0),
           oee_performance  = GREATEST(LEAST(oee_performance, 1), 0),
           oee_quality      = GREATEST(LEAST(oee_quality, 1), 0)
     WHERE oee NOT BETWEEN 0 AND 1 OR oee_availability NOT BETWEEN 0 AND 1
        OR oee_performance NOT BETWEEN 0 AND 1 OR oee_quality NOT BETWEEN 0 AND 1;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'production_orders_oee_bounds') THEN
      ALTER TABLE __SCH__.production_orders ADD CONSTRAINT production_orders_oee_bounds CHECK
        (oee BETWEEN 0 AND 1 AND oee_availability BETWEEN 0 AND 1
         AND oee_performance BETWEEN 0 AND 1 AND oee_quality BETWEEN 0 AND 1) NOT VALID;
      ALTER TABLE __SCH__.production_orders VALIDATE CONSTRAINT production_orders_oee_bounds;
    END IF;
  END IF;
END $$;

COMMIT;

-- ── STILL DEFERRED ───────────────────────────────────────────────────────────
-- `net <= gross` — net>gross on raw summed columns (historical); needs a Bronze
-- reprocess (BRONZE_RAW_APPEND / ADR-0036 B1), not an output clamp.
