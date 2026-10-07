\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE gold.equipment_oee_shift DROP CONSTRAINT IF EXISTS equipment_oee_shift_no_overlap;
CREATE INDEX IF NOT EXISTS equipment_oee_shift_ts_range_id_equipment_idx ON gold.equipment_oee_shift USING gist (id_equipment, ts_range);
COMMIT;
