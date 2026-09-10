-- t256 rollback — re-flag the child-meter shift rows this migration cleared.
--
-- There is NO functional reason to run this: recalc_needed on a child meter that never
-- computes OEE is a meaningless flag, and re-setting it only re-inflates the counter and
-- makes the consumer re-scan dead rows. Provided solely so the change is codified-reversible.
-- The WHERE set is deterministic (same predicate as 01-drain, minus the time bound which
-- has moved), so this restores the flag on all currently-uncomputed child-meter rows.

SET lock_timeout = '25s';

UPDATE gold.equipment_oee_shift e
   SET recalc_needed = true
  FROM core.equipments q
 WHERE e.id_equipment = q.id_equipment
   AND q.tp_equipment = 1
   AND q.id_parentequipment IS NOT NULL
   AND e.computed_at IS NULL
   AND NOT e.recalc_needed;
