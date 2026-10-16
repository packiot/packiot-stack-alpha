\set ON_ERROR_STOP 1
SELECT 'V1 no-overlap EXCLUDE present: 1', count(*) FROM pg_constraint
 WHERE conrelid = 'gold.equipment_oee_shift'::regclass AND conname = 'equipment_oee_shift_no_overlap' AND contype = 'x';
SELECT 'V2 a GiST index on (id_equipment, ts_range) still serves the <@ joins: 1', count(*) FROM pg_indexes
 WHERE schemaname = 'gold' AND tablename = 'equipment_oee_shift' AND indexdef ~ 'USING gist \(id_equipment, ts_range\)';
