-- 07-oee-output-clamp-backfill-and-checks.sql — ADR-0037 output-invariant, finished.
-- __SCH__ = target schema (public on packiot_shadow / F3).
--
-- CONTEXT. The rollup code now clamps every served OEE ratio to ≤1 (the #576
-- shift-grain LEAST, extended to hour/day/week-month/area-site/PO-recalc/
-- counters-availability grains — fix/oee-aggregation-clamp). That stops FUTURE
-- blow-ups, but the HISTORICAL corrupt rows (all 2026-07-05..07, from the
-- already-fixed unclosed-event billions-running_time class — surfaced as oee up
-- to 13918, oee_a to 38316) only get recomputed if their buckets re-roll. This:
--   (1) one-time clamps existing served oee* columns into [0,1] — GREATEST(LEAST)
--       so it fixes BOTH the >1 blow-ups AND the handful of negative rows;
--   (2) enables an UPPER-BOUND CHECK (oee* ≤ 1) as the durable Silver guard.
--
-- WHY UPPER-BOUND ONLY (not BETWEEN 0 AND 1): the code clamp is LEAST(ratio,1) —
-- it guarantees ≤1 but not ≥0 (a negative net delta could still yield oee<0).
-- A hard `BETWEEN 0 AND 1` would then REJECT a future negative row and break the
-- rollup write. `≤ 1` matches the code's actual guarantee + catches the real bug
-- class (the blow-up). The lower bound (≥0) is DEFERRED: enable `BETWEEN 0 AND 1`
-- once the code clamp is tightened to GREATEST(LEAST(ratio,1),0). Existing rows
-- are still cleaned to [0,1] by (1).
--
-- SCOPE. Clamps DERIVED oee* only; raw net/gross/running untouched (lineage).
-- `net<=gross` CHECK stays DEFERRED (separate raw-data reprocess). Idempotent.

BEGIN;

-- ── (1) one-time clamp of existing served rows into [0,1] ─────────────────────
UPDATE __SCH__.equipment_runtime_shift
   SET oee=GREATEST(LEAST(oee,1),0), oee_a=GREATEST(LEAST(oee_a,1),0),
       oee_p=GREATEST(LEAST(oee_p,1),0), oee_q=GREATEST(LEAST(oee_q,1),0)
 WHERE oee NOT BETWEEN 0 AND 1 OR oee_a NOT BETWEEN 0 AND 1
    OR oee_p NOT BETWEEN 0 AND 1 OR oee_q NOT BETWEEN 0 AND 1;
UPDATE __SCH__.equipment_runtime_1hour
   SET oee=GREATEST(LEAST(oee,1),0), oee_a=GREATEST(LEAST(oee_a,1),0),
       oee_p=GREATEST(LEAST(oee_p,1),0), oee_q=GREATEST(LEAST(oee_q,1),0)
 WHERE oee NOT BETWEEN 0 AND 1 OR oee_a NOT BETWEEN 0 AND 1
    OR oee_p NOT BETWEEN 0 AND 1 OR oee_q NOT BETWEEN 0 AND 1;
UPDATE __SCH__.equipment_runtime_1day
   SET oee=GREATEST(LEAST(oee,1),0), oee_a=GREATEST(LEAST(oee_a,1),0),
       oee_p=GREATEST(LEAST(oee_p,1),0), oee_q=GREATEST(LEAST(oee_q,1),0)
 WHERE oee NOT BETWEEN 0 AND 1 OR oee_a NOT BETWEEN 0 AND 1
    OR oee_p NOT BETWEEN 0 AND 1 OR oee_q NOT BETWEEN 0 AND 1;
UPDATE __SCH__.area_runtime_shift
   SET oee=GREATEST(LEAST(oee,1),0), oee_a=GREATEST(LEAST(oee_a,1),0),
       oee_p=GREATEST(LEAST(oee_p,1),0), oee_q=GREATEST(LEAST(oee_q,1),0)
 WHERE oee NOT BETWEEN 0 AND 1 OR oee_a NOT BETWEEN 0 AND 1
    OR oee_p NOT BETWEEN 0 AND 1 OR oee_q NOT BETWEEN 0 AND 1;
UPDATE __SCH__.site_runtime_shift
   SET oee=GREATEST(LEAST(oee,1),0), oee_a=GREATEST(LEAST(oee_a,1),0),
       oee_p=GREATEST(LEAST(oee_p,1),0), oee_q=GREATEST(LEAST(oee_q,1),0)
 WHERE oee NOT BETWEEN 0 AND 1 OR oee_a NOT BETWEEN 0 AND 1
    OR oee_p NOT BETWEEN 0 AND 1 OR oee_q NOT BETWEEN 0 AND 1;
UPDATE __SCH__.production_orders_runtime
   SET oee=GREATEST(LEAST(oee,1),0), oee_a=GREATEST(LEAST(oee_a,1),0),
       oee_p=GREATEST(LEAST(oee_p,1),0), oee_q=GREATEST(LEAST(oee_q,1),0)
 WHERE oee NOT BETWEEN 0 AND 1 OR oee_a NOT BETWEEN 0 AND 1
    OR oee_p NOT BETWEEN 0 AND 1 OR oee_q NOT BETWEEN 0 AND 1;

-- ── (2) enable the upper-bound oee CHECK (durable anti-blow-up guard) ─────────
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY['equipment_runtime_shift','equipment_runtime_1hour',
                               'equipment_runtime_1day','area_runtime_shift',
                               'site_runtime_shift','production_orders_runtime'])
  LOOP
    IF to_regclass('__SCH__.'||t) IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = t||'_oee_ubound') THEN
      EXECUTE format('ALTER TABLE __SCH__.%I ADD CONSTRAINT %I CHECK '
        || '(oee <= 1 AND oee_a <= 1 AND oee_p <= 1 AND oee_q <= 1) NOT VALID', t, t||'_oee_ubound');
      EXECUTE format('ALTER TABLE __SCH__.%I VALIDATE CONSTRAINT %I', t, t||'_oee_ubound');
    END IF;
  END LOOP;
END $$;

COMMIT;

-- ── DEFERRED (separate follow-ups, do NOT enable here) ───────────────────────
-- (a) full `BETWEEN 0 AND 1` — after the rollup clamp is tightened to
--     GREATEST(LEAST(ratio,1),0) so a future negative can't break the write.
-- (b) `net <= gross` — net>gross on raw summed columns (112 eq rows, historical);
--     needs a Bronze reprocess (BRONZE_RAW_APPEND), not an output clamp.
-- (c) `production_orders` SUMMARY table (oee_availability/oee_performance) —
--     clamped in code (recalc.go) going forward; existing-row clamp = follow-up.
