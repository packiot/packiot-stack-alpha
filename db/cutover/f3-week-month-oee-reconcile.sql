-- f3-week-month-oee-reconcile.sql
--
-- One-shot LIVE reconcile of the week/month OEE grains to the canonical A·P·Q
-- identity (ADR-0048 §Fault-3), fixing rows written before the stream-engine
-- grain reconcile shipped (grains.go grainOeeReconcileSQL).
--
-- WHY: the legacy week/month pass wrote a top-down oee = net/ideal_production and
-- a back-solved, clamped oee_p — and, via the "amber bug", the WEEK pass wrote its
-- oee_p into equipment_runtime_1MONTH. As a result the identity oee = oee_a·oee_p·oee_q
-- did NOT hold on these two grains (unlike hour/shift). This script rewrites the
-- four oee columns so each factor is a genuine [0,1] value and oee is their PRODUCT
-- as the last step — identical algebra to the shipped Go reconcile.
--
-- PERFORMANCE derivation (the grain carries no ideal_speed column, only the summed
-- ideal_production over the AVAILABLE window):
--   P = gross / (ideal_production · running/available) = gross·available / (ideal_production·running)
-- which telescopes to net/ideal_production on unclamped data (changes nothing there;
-- only lowers oee where a factor was genuinely clamped).
--
-- SAFE: idempotent (running it twice is a no-op), touches ONLY the four oee columns
-- on stable rows (recalc_needed=false), leaves target/target_customized/raw metrics
-- untouched. Blast radius for reads is nil: no consumer reads week/month oee_p/oee_a/
-- oee_q/oee (verified — only `target` is consumed there).
--
-- USAGE: wrap in BEGIN; \i ...; and inspect the violation counts before COMMIT.
-- Dry-run first with ROLLBACK.

\set ON_ERROR_STOP on

DO $$
DECLARE
    v_week_before  bigint;
    v_month_before bigint;
    v_week_after   bigint;
    v_month_after  bigint;
BEGIN
    -- Pre-reconcile violation counts (stable, producing rows only).
    SELECT count(*) INTO v_week_before FROM equipment_runtime_1week
     WHERE recalc_needed = false AND net > 0
       AND abs(coalesce(oee,0) - coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0)) >= 0.01;
    SELECT count(*) INTO v_month_before FROM equipment_runtime_1month
     WHERE recalc_needed = false AND net > 0
       AND abs(coalesce(oee,0) - coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0)) >= 0.01;
    RAISE NOTICE 'BEFORE: 1week violations=%, 1month violations=%', v_week_before, v_month_before;

    -- WEEK reconcile (canonical A·P·Q; own table — no amber bug).
    UPDATE equipment_runtime_1week e SET
           oee_a = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0),
           oee_q = GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0),
           oee_p = GREATEST(LEAST(COALESCE(e.gross * e.available_time / NULLIF(e.ideal_production * e.running_time, 0), 0), 1), 0),
           oee   = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0)
                 * GREATEST(LEAST(COALESCE(e.gross * e.available_time / NULLIF(e.ideal_production * e.running_time, 0), 0), 1), 0)
                 * GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0)
     WHERE e.recalc_needed = false
       AND e.ts_value >= now() - interval '1 year';

    -- MONTH reconcile.
    UPDATE equipment_runtime_1month e SET
           oee_a = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0),
           oee_q = GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0),
           oee_p = GREATEST(LEAST(COALESCE(e.gross * e.available_time / NULLIF(e.ideal_production * e.running_time, 0), 0), 1), 0),
           oee   = GREATEST(LEAST(COALESCE(e.running_time::float / NULLIF(e.available_time, 0), 0), 1), 0)
                 * GREATEST(LEAST(COALESCE(e.gross * e.available_time / NULLIF(e.ideal_production * e.running_time, 0), 0), 1), 0)
                 * GREATEST(LEAST(COALESCE(e.net / NULLIF(e.gross, 0), 0), 1), 0)
     WHERE e.recalc_needed = false
       AND e.ts_value >= now() - interval '1 year';

    -- Post-reconcile violation counts (must be 0).
    SELECT count(*) INTO v_week_after FROM equipment_runtime_1week
     WHERE recalc_needed = false AND net > 0
       AND abs(coalesce(oee,0) - coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0)) >= 0.01;
    SELECT count(*) INTO v_month_after FROM equipment_runtime_1month
     WHERE recalc_needed = false AND net > 0
       AND abs(coalesce(oee,0) - coalesce(oee_a,0)*coalesce(oee_p,0)*coalesce(oee_q,0)) >= 0.01;
    RAISE NOTICE 'AFTER:  1week violations=%, 1month violations=%', v_week_after, v_month_after;
END $$;
