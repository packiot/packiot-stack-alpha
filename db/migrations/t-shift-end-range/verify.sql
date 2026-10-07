-- verify for t-shift-end-range. Read-only; label|value, expected in the label.
\set ON_ERROR_STOP 1
SELECT 'V1 shift rows with NULL ts_end or ts_range <> [ts_value, ts_end): 0',
       count(*) FROM gold.equipment_oee_shift WHERE ts_end IS NULL OR ts_range IS DISTINCT FROM tstzrange(ts_value, ts_end, '[)');
SELECT 'V2 consistency CHECK present and validated: t', convalidated FROM pg_constraint
 WHERE conrelid = 'gold.equipment_oee_shift'::regclass AND conname = 'chk_equipment_oee_shift_range_consistent';
SELECT 'V3 shift_hours with NULL shift_size: 0', count(*) FROM core.shift_hours WHERE shift_size IS NULL;
SELECT 'V4 getter gives a finite end for every equipment with a shift now (open-ended): 0',
       count(*) FROM core.equipments e, piot_get_shift_hour_begin_by_equipment(e.id_equipment, now()) g WHERE g.ts_end IS NULL OR upper_inf(g.ts_range);
SELECT 'V5 overlapping shift pairs per equipment, last 120 days (EXCLUDE prerequisite): 0',
       count(*) FROM gold.equipment_oee_shift a JOIN gold.equipment_oee_shift b
         ON a.id_equipment = b.id_equipment AND a.ts_value < b.ts_value AND a.ts_range && b.ts_range
      WHERE a.ts_value > now() - interval '120 days';
SELECT 'V6 rows re-flagged by this migration (must stay untouched): 0',
       count(*) FROM gold.equipment_oee_shift WHERE recalc_needed AND ts_value < '2022-04-01';
SELECT 'V7 shift_hours bounds CHECK validated: t', convalidated FROM pg_constraint
 WHERE conrelid = 'core.shift_hours'::regclass AND conname = 'chk_shift_hours_bounds';
