-- t-ent5-line-lead-repoint
--
-- SYMPTOM (2026-09-24, Bispharma demo-readiness audit): 15 of ent5's 23 lines showed
-- OEE = A = P = 0 for the whole week while producing 70–80k units/day; Mission Control
-- greyed the same lines ("lowSpeed", availability 0).
--
-- ROOT CAUSE: line OEE comes from the LINE-LEAD pass (lead_machine = the member whose
-- activity defines the line's running time). The 14 SP lines (L01–L20) were onboarded with
-- lead = S6OUTPUT and L18 with lead = IMPRESSAO — members the PLCs NEVER fill (0 one-minute
-- rows in 24 h). No lead activity ⇒ running_time = 0 ⇒ the whole shift counts as stopped.
-- The BISNAGO lines (L56–L73), whose leads DO report, were realistic all along.
--
-- FIX: repoint to the member carrying the line's real signal:
--   * SP lines → S1INFEED: the ONLY station with gross count + speed (S3/S4/S5 carry net
--     counts only, S6OUTPUT nothing) — the same signal shape the working BISNAGO leads have.
--   * L18 (tube line PRENSA→TORNO→IMPRESSAO→TAMPADEIRA→ACUMULADOR; no station has speed)
--     → TAMPADEIRA: last PROCESS station with counts (ACUMULADOR is a buffer).
-- Revert once the box reader maps S6OUTPUT (the DW mis-map found in the 2026-09-15
-- client-box audit) — rollback.sql restores the original leads.
--
-- Then flag the last 7 days of line OEE for recompute (the runtime-rollup drains
-- recalc_needed oldest-first, ROLLUP_SHIFT_LIMIT rows per tick).
-- SAFE: ent5 only; trg_seed_line_default_target is insert-if-missing (all 23 lines already
-- have config.production_targets) → no-op. Idempotent.

BEGIN;

WITH pick AS (
  SELECT l.id_equipment AS line, c.id_equipment AS new_lead
    FROM core.equipments l
    JOIN core.equipments cur ON cur.id_equipment = l.lead_machine
    JOIN core.equipments c   ON c.id_parentequipment = l.id_equipment AND c.tp_equipment = 1
   WHERE l.id_enterprise = 5 AND l.tp_equipment = 3
     AND ((cur.nm_equipment = 'S6OUTPUT'  AND c.nm_equipment = 'S1INFEED')
       OR (cur.nm_equipment = 'IMPRESSAO' AND c.nm_equipment = 'TAMPADEIRA'))
)
UPDATE core.equipments e SET lead_machine = p.new_lead
  FROM pick p WHERE e.id_equipment = p.line AND e.lead_machine IS DISTINCT FROM p.new_lead;

-- recompute the last 7 days of the repointed lines
UPDATE gold.equipment_oee_shift o SET recalc_needed = true
  FROM core.equipments l JOIN core.equipments c ON c.id_equipment = l.lead_machine
 WHERE o.id_equipment = l.id_equipment AND l.id_enterprise = 5 AND l.tp_equipment = 3
   AND c.nm_equipment IN ('S1INFEED', 'TAMPADEIRA')
   AND o.ts_value > now() - interval '7 days' AND o.ts_value <= now();

COMMIT;
