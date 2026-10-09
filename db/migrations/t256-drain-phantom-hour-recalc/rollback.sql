-- t256 rollback — re-flag the tp=1 (machine) hourly rows this migration cleared.
--
-- There is NO functional reason to run this: recalc_needed on a tp=1 hour row that can
-- never compute OEE is a meaningless flag, and re-setting it only re-inflates the recalc
-- backlog the rollup re-scans. Provided solely so the change is codified-reversible.
-- The WHERE set is deterministic (all currently-unflagged tp=1 hour rows), matching the
-- drain's scope, so this restores the pre-drain flag state.

SET lock_timeout = '25s';

UPDATE gold.equipment_oee_hourly e
   SET recalc_needed = true
  FROM core.equipments q
 WHERE e.id_equipment = q.id_equipment
   AND q.tp_equipment = 1
   AND NOT e.recalc_needed;
