-- f3-hour-shift-day-oee-reconcile.sql
--
-- ONE-TIME ALL-TIME historical reconcile of the 1hour / shift / 1day OEE grains
-- to the canonical A·P·Q identity (ADR-0048 §Fault-3). Companion to
-- f3-week-month-oee-reconcile.sql (which fixed the week/month grains in #883).
--
-- WHY THE BACKFILL DOES NOT COVER THESE. After ROLLUP_BACKFILL_ENABLED was turned
-- on (#883), it only reprocesses recalc_needed=TRUE rows within the 10-day event-
-- retention horizon. The stranded violations are recalc_needed=FALSE rows computed
-- by OLD buggy code (pre-#875 availability fix, pre-canonical-finalize): their
-- stored oee is the top-down net/ideal_production while oee_a·oee_p·oee_q is the
-- (clamped) product — so oee != oee_a·oee_p·oee_q. The live finalize will never
-- re-touch them, so a one-time recompute is required.
--
-- WHAT THIS DOES (recompute FACTORS from each row's OWN raw columns, then
-- oee = product as the last step — mirroring the deployed hour/shift finalize
-- hourOeeReconcileSQL / shiftOeeReconcileSQL byte-for-byte):
--   oee_a = running_time / available_time                          (Availability)
--   oee_q = net / gross                                            (Quality)
--   oee_p = gross / (ideal_speed · running_time / 60)              (Performance, hour/shift)
--   oee   = oee_a · oee_p · oee_q                                  (product, LAST step)
-- 1day has NO ideal_speed column, so Performance is derived from the summed
-- ideal_production (identical algebra, telescopes to net/ideal_production):
--   oee_p = gross · available_time / (ideal_production · running_time)
-- 1day also uses the canonical product for oee (the deployed dayRollupSQL still
-- back-solves oee_p + keeps a top-down oee, so its identity breaks on clamp — a
-- follow-up gap flagged for the Go finalize; this reconcile closes it for history).
--
-- ::float CAST (the trap from #883): running_time and available_time are INTEGER
-- on all three tables, so running_time / available_time is INTEGER division
-- (3060/3600 -> 0), which would ZERO oee_a on every producing line. The cast is
-- mandatory. Verified live: on run>0 rows the cast reproduces the already-correct
-- stored float availability (a_new == a_old); only oee changes (to the product).
--
-- FACTORS RECOMPUTED, NOT MULTIPLIED STALE: a naive oee = oee_a·oee_p·oee_q of the
-- stored factors would enshrine a stale factor. Every factor is re-derived here
-- from the raw time/count columns with today's corrected formulas.
--
-- LIMITATION (honest): rows whose RAW running_time is 0 (count-only lines whose
-- state events never marked "running", or old open-ended-event corruption) get
-- oee_a = 0 -> oee = 0. That is the canonically-correct value GIVEN running_time=0;
-- restoring count-derived availability needs re-running the events + avail-floor
-- passes against source (equipment_events / ca_agg), which is the backfill's job
-- and is retention-bounded — it cannot be done from the raw grain columns.
--
-- SCOPE: recalc_needed=FALSE (stable) rows, ALL net, ALL ages (no net filter, no
-- time window). Besides the net>0 top-down-vs-product divergence, this also fixes
-- net=0 empty-day/hour rows that OLD code stored with a SPURIOUS oee=1.0 / oee_q=1.0
-- (0/0 defaulted to 1) — a zero-production bucket must read OEE 0, not 100%. The
-- recompute drives those to oee=oee_q=0. Idempotent: running twice is a no-op.
-- Blast radius = same as #883 plus the shift oee_p read by Superset oee_shift /
-- h_piot_oee_progress — which the live finalize already writes as direct-Performance,
-- so historical rows are brought INTO agreement with the live definition.
--
-- USAGE: dry-run first with ROLLBACK; inspect BEFORE/AFTER; then flip to COMMIT.

\set ON_ERROR_STOP on

BEGIN;

\echo ===== BEFORE (ALL stable rows; net>0 broken out) =====
SELECT g, rows, identity_viol, range_viol, viol_net_pos, viol_run0 FROM (
  SELECT 'hour' g, count(*) rows,
    count(*) FILTER (WHERE abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01) identity_viol,
    count(*) FILTER (WHERE oee_a<0 or oee_a>1 or oee_p<0 or oee_p>1 or oee_q<0 or oee_q>1 or oee<0 or oee>1) range_viol,
    count(*) FILTER (WHERE net>0 AND abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01) viol_net_pos,
    count(*) FILTER (WHERE running_time=0 AND net>0 AND abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01) viol_run0
  FROM equipment_runtime_1hour WHERE recalc_needed=false
  UNION ALL SELECT 'shift', count(*),
    count(*) FILTER (WHERE abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01),
    count(*) FILTER (WHERE oee_a<0 or oee_a>1 or oee_p<0 or oee_p>1 or oee_q<0 or oee_q>1 or oee<0 or oee>1),
    count(*) FILTER (WHERE net>0 AND abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01),
    count(*) FILTER (WHERE running_time=0 AND net>0 AND abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01)
  FROM equipment_runtime_shift WHERE recalc_needed=false
  UNION ALL SELECT '1day', count(*),
    count(*) FILTER (WHERE abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01),
    count(*) FILTER (WHERE oee_a<0 or oee_a>1 or oee_p<0 or oee_p>1 or oee_q<0 or oee_q>1 or oee<0 or oee>1),
    count(*) FILTER (WHERE net>0 AND abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01),
    count(*) FILTER (WHERE running_time=0 AND net>0 AND abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01)
  FROM equipment_runtime_1day WHERE recalc_needed=false
) x ORDER BY g;

-- HOUR (mirrors hourOeeReconcileSQL + ::float on Availability).
UPDATE equipment_runtime_1hour e SET
       oee_a = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0),
       oee_q = GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0),
       oee_p = GREATEST(LEAST(COALESCE(e.gross / NULLIF(e.ideal_speed * e.running_time / 60.0, 0), 0), 1), 0),
       oee   = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0)
             * GREATEST(LEAST(COALESCE(e.gross / NULLIF(e.ideal_speed * e.running_time / 60.0, 0), 0), 1), 0)
             * GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0)
 WHERE e.recalc_needed = false;

-- SHIFT (mirrors shiftOeeReconcileSQL + ::float on Availability).
UPDATE equipment_runtime_shift e SET
       oee_a = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0),
       oee_q = GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0),
       oee_p = GREATEST(LEAST(COALESCE(e.gross / NULLIF(e.ideal_speed * e.running_time / 60.0, 0), 0), 1), 0),
       oee   = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0)
             * GREATEST(LEAST(COALESCE(e.gross / NULLIF(e.ideal_speed * e.running_time / 60.0, 0), 0), 1), 0)
             * GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0)
 WHERE e.recalc_needed = false;

-- 1DAY (no ideal_speed column -> Performance from summed ideal_production;
-- canonical product closes the deployed day back-solve identity gap).
UPDATE equipment_runtime_1day e SET
       oee_a = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0),
       oee_q = GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0),
       oee_p = GREATEST(LEAST(COALESCE(e.gross * e.available_time / NULLIF(e.ideal_production * e.running_time, 0), 0), 1), 0),
       oee   = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0)
             * GREATEST(LEAST(COALESCE(e.gross * e.available_time / NULLIF(e.ideal_production * e.running_time, 0), 0), 1), 0)
             * GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0)
 WHERE e.recalc_needed = false;

\echo ===== AFTER (ALL stable rows) — identity_viol + range_viol must be 0 =====
SELECT g, rows, identity_viol, range_viol FROM (
  SELECT 'hour' g, count(*) rows,
    count(*) FILTER (WHERE abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01) identity_viol,
    count(*) FILTER (WHERE oee_a<0 or oee_a>1 or oee_p<0 or oee_p>1 or oee_q<0 or oee_q>1 or oee<0 or oee>1) range_viol
  FROM equipment_runtime_1hour WHERE recalc_needed=false
  UNION ALL SELECT 'shift', count(*),
    count(*) FILTER (WHERE abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01),
    count(*) FILTER (WHERE oee_a<0 or oee_a>1 or oee_p<0 or oee_p>1 or oee_q<0 or oee_q>1 or oee<0 or oee>1)
  FROM equipment_runtime_shift WHERE recalc_needed=false
  UNION ALL SELECT '1day', count(*),
    count(*) FILTER (WHERE abs(coalesce(oee,0)-coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0))>=0.01),
    count(*) FILTER (WHERE oee_a<0 or oee_a>1 or oee_p<0 or oee_p>1 or oee_q<0 or oee_q>1 or oee<0 or oee>1)
  FROM equipment_runtime_1day WHERE recalc_needed=false
) x ORDER BY g;

-- Dry-run: change to COMMIT once BEFORE/AFTER look right.
ROLLBACK;
