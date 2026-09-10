-- t256 — drain phantom recalc_needed flags on child-meter OEE shift rows.
--
-- ROOT CAUSE (stream-engine rollup asymmetry): the shift/hour/day flag-setters
-- (shift.go shiftReflagSQL, hour.go, entity_grains.go) flag recalc_needed=true on
-- tp_equipment=1 machines for the counters-only-OEE enterprise list ($2), WITHOUT
-- excluding CHILD meters (id_parentequipment IS NOT NULL). But child meters are leaf
-- physical meters that feed a line/parent and NEVER compute their own OEE — the
-- consumer (shiftEligibleSQL) selects them yet produces no row, so their flag never
-- clears. They sit flagged until they age out of the 30-day compute window into
-- permanent phantoms.
--
-- PROOF this is benign + client-invisible:
--   * gold.equipment_oee_shift: these rows have computed_at IS NULL and 0 ever-computed
--     rows across 40+ days (id_parentequipment IS NOT NULL, tp_equipment=1).
--   * A number that never computes cannot be surfaced by any serving.* view or read-api
--     endpoint — clients see OEE for LINES (tp=3) and STANDALONE machines only.
--   * Real in-window backlog on OEE-computing equipment is tiny (CPACK 40 / Bispharma 46),
--     draining every 60s LoopGrains tick. There is no real OEE staleness.
--
-- SAFETY: recalc_needed is consumed ONLY by the rollup to decide what to recompute.
-- Clearing it on rows that never compute is a pure no-op to every computed number —
-- it just stops the consumer from re-scanning dead rows. We only touch rows OLDER than
-- the reflag window (ts_value < now() - 18h) so we never fight the live reflagger on the
-- current shift. Fully reversible (rollback re-sets the same deterministic WHERE set,
-- though there is no reason to — the flags are meaningless).
--
-- This is a DATA drain only; the durable code fix (exclude id_parentequipment IS NOT NULL
-- from the tp=1 flag/compute predicates + golden test) is tracked separately (task #256).

SET lock_timeout = '25s';

WITH drained AS (
    UPDATE gold.equipment_oee_shift e
       SET recalc_needed = false
      FROM core.equipments q
     WHERE e.id_equipment = q.id_equipment
       AND q.tp_equipment = 1
       AND q.id_parentequipment IS NOT NULL   -- child meter: never computes OEE
       AND e.recalc_needed
       AND e.computed_at IS NULL              -- provably never computed
       AND e.ts_value < now() - interval '18 hours'  -- outside the live reflag window
    RETURNING e.id_equipment
)
SELECT count(*) AS rows_drained, count(DISTINCT id_equipment) AS child_meters_cleared
FROM drained;
