-- transplant phase 5: data repairs staging applied BEFORE adding constraints its schema now carries.
-- Each block names the migration it comes from; all keyed by data, not surrogate ids. Idempotent.
\set ON_ERROR_STOP 1
-- [t-shift-end-range] shift_size from the span; legacy rows' ts_end from the finite range; open-ended rows closed
UPDATE core.shift_hours SET shift_size = end_time - begin_time
 WHERE shift_size IS NULL AND begin_time IS NOT NULL AND end_time IS NOT NULL;
UPDATE gold.equipment_oee_shift SET ts_end = upper(ts_range)
 WHERE ts_end IS NULL AND ts_range IS NOT NULL AND NOT upper_inf(ts_range);
UPDATE gold.equipment_oee_shift e
   SET ts_end   = e.ts_value + (sh.end_time - sh.begin_time) * interval '1 second',
       ts_range = tstzrange(e.ts_value, e.ts_value + (sh.end_time - sh.begin_time) * interval '1 second')
  FROM core.shift_hours sh
 WHERE sh.id_shift_hour = e.id_shift_hour AND e.ts_end IS NULL AND upper_inf(e.ts_range);
SELECT 'shift rows still inconsistent', count(*) FROM gold.equipment_oee_shift
 WHERE ts_end IS NULL OR ts_range IS DISTINCT FROM tstzrange(ts_value, ts_end, '[)');
SELECT 'overlapping shift pairs', count(*) FROM gold.equipment_oee_shift a JOIN gold.equipment_oee_shift b
    ON a.id_equipment = b.id_equipment AND a.ts_value < b.ts_value AND a.ts_range && b.ts_range;
