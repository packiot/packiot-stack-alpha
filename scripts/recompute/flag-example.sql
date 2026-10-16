-- flag-example.sql — scope SQL for run-day-recompute.sh (--flag-sql).
-- Spliced INSIDE each day's transaction, after the engine advisory locks. It decides WHICH rows
-- the rendered engine passes rebuild: set recalc_needed = true on the hour and shift rows of the
-- day window; the day/week/month grains follow through the cascades.
-- __FROM__ / __TO__ are the UTC day bounds. Copy this file and edit the equipment predicate.
--
-- Example: every line (tp_equipment = 3) of enterprise 5 plus the lines whose lead machine is in
-- a repair table (the 2026-10-01 unbacked-increment repair used ops._fix_unbacked_20261001).

UPDATE gold.equipment_oee_hourly h SET recalc_needed = true
  FROM core.equipments q
 WHERE q.id_equipment = h.id_equipment
   AND q.tp_equipment > 1
   AND q.id_enterprise = 5
   AND h.ts_value >= '__FROM__' AND h.ts_value < '__TO__';

UPDATE gold.equipment_oee_shift e SET recalc_needed = true
  FROM core.equipments q
 WHERE q.id_equipment = e.id_equipment
   AND q.tp_equipment > 1
   AND q.id_enterprise = 5
   AND e.ts_value >= '__FROM__' AND e.ts_value < '__TO__'
   AND e.ts_end < now();   -- an open shift belongs to the live rollup

SELECT 'n_flag_hour', count(*) FROM gold.equipment_oee_hourly
 WHERE recalc_needed AND ts_value >= '__FROM__' AND ts_value < '__TO__';
SELECT 'n_flag_shift', count(*) FROM gold.equipment_oee_shift
 WHERE recalc_needed AND ts_value >= '__FROM__' AND ts_value < '__TO__';
