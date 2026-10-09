-- t256 — drain phantom recalc_needed flags on tp=1 (machine) OEE hourly rows.
--
-- ROOT CAUSE (verified on staging 2026-09-10, NOT the earlier "child-meter"
-- hypothesis — that was disproven: id_parentequipment on these machines points at
-- their tp=3 LINE, i.e. it is line-membership, so an "IS NULL" predicate would have
-- excluded every real machine). The true defect is a rollup SCOPE ASYMMETRY between
-- the hour re-flag and the hour eligibility:
--
--   * hour.go hourEligibleSQL selects ONLY tp_equipment > 1 (lines/sectors). Machines
--     (tp=1) roll up at shift/day, NEVER hourly — hour_tp1_ever_computed = 0/274,911.
--   * hour.go hourReflagSQL (pre-fix) re-flagged EVERY hour row in the trailing 2h
--     window with NO equipment filter, so it set recalc_needed=true on tp=1 rows.
--   * Nothing ever clears them: the next eligibility pass (tp>1) does not select tp=1,
--     so phase V never runs on them. The flag is permanent.
--   * Contrast the SHIFT grain, which is correct: shiftEligibleSQL INCLUDES the tp=1
--     counters-only set, so phase V clears their flag every tick (re-flag scope ==
--     eligible scope → no phantom). The durable fix makes hour symmetric: hourReflagSQL
--     now carries the same `tp_equipment > 1` guard so flagged ⊆ computable.
--
-- MEASURED: 6,276 stuck tp=1 hour flags, +552/day, oldest 2026-08-31 — 97% of ALL
-- hour flags. Steady growth because each tick's 2h re-flag catches ~552 tp=1 rows that
-- then never clear. Client-invisible (a row that never computes, computed_at IS NULL,
-- is surfaced by no serving.* view or read-api endpoint — clients see LINE OEE), but it
-- inflates the recalc backlog the rollup re-scans every tick.
--
-- SAFETY: recalc_needed is consumed ONLY by the rollup to decide what to recompute.
-- Clearing it on rows that can never compute is a pure no-op to every computed number.
-- We only touch tp=1 rows, which the (deployed) fixed re-flag no longer sets — so this
-- drain runs ONCE and does not re-accumulate. Idempotent + reversible.
--
-- ORDER OF OPERATIONS: deploy the hour.go tp>1 guard FIRST, then run this drain. If run
-- before the fix, the old re-flag re-adds the flags within one tick.
--
-- The skeleton creator piot_create_equipment_oee_hourly births these tp=1 rows with
-- recalc_needed=false (verified — it never sets the flag), so no writer re-flags them
-- post-fix. (That it creates empty tp=1 hour rows at all is separate data bloat, out of
-- scope here — tracked as an optional hygiene follow-up.)

SET lock_timeout = '25s';

WITH drained AS (
    UPDATE gold.equipment_oee_hourly e
       SET recalc_needed = false
      FROM core.equipments q
     WHERE e.id_equipment = q.id_equipment
       AND q.tp_equipment = 1            -- machines never compute hourly OEE
       AND e.recalc_needed
    RETURNING e.id_equipment
)
SELECT count(*) AS rows_drained, count(DISTINCT id_equipment) AS machines_cleared
FROM drained;
