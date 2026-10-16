-- 2026-10-01: Bispharma (ent 5) MACHINE (tp=1) shift rows 09-24 17:20 .. 10-23 were
-- flagged recalc_needed by a one-time bulk command on 2026-09-24 (not in the repo;
-- every repo script flags tp=3 only). Ent 5 is not a machine-level enterprise, so the
-- shift rollup never selects tp=1 rows (shiftEligibleSQL) → 7,770 permanent phantom
-- flags (1,904 in the past). Values are unaffected; this only removes the noise from
-- backlog monitoring. Rows provisioned since are unflagged (no recurring source).
SET lock_timeout = '10s';
UPDATE gold.equipment_oee_shift s SET recalc_needed = false
  FROM core.equipments e
 WHERE e.id_equipment = s.id_equipment AND e.id_enterprise = 5 AND e.tp_equipment = 1
   AND s.recalc_needed;
