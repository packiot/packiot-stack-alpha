-- t-shift-no-overlap — schema P1 (2026-10-07): two shifts of one equipment can never overlap (EXCLUDE).
-- Requires t-shift-end-range first (open-ended ranges made every shift of a NULL-shift_size tenant overlap the next;
-- after it, overlapping pairs = 0 — verify V5 there). Overlapping windows double-count production/downtime between
-- shifts (the class of the 10-02 boundary-hour bug).
--
-- LOCK: ADD CONSTRAINT ... EXCLUDE builds a GiST index under ACCESS EXCLUSIVE on gold.equipment_oee_shift
-- (~718k rows): rollup writes AND Mission Control/read-api reads of the shift table wait for the build. Run it in a
-- stream-engine stop window (same procedure as the 2026-10-07 float8 window), never as a casual apply.
-- The constraint's index (id_equipment, ts_range) makes the old plain GiST index redundant: it is dropped.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $$ DECLARE n bigint; BEGIN
  SELECT count(*) INTO n FROM gold.equipment_oee_shift a JOIN gold.equipment_oee_shift b
    ON a.id_equipment = b.id_equipment AND a.ts_value < b.ts_value AND a.ts_range && b.ts_range;
  IF n > 0 THEN RAISE EXCEPTION 't-shift-no-overlap: % overlapping pair(s); apply t-shift-end-range / fix data first', n; END IF;
END $$;
ALTER TABLE gold.equipment_oee_shift DROP CONSTRAINT IF EXISTS equipment_oee_shift_no_overlap;
ALTER TABLE gold.equipment_oee_shift ADD CONSTRAINT equipment_oee_shift_no_overlap
  EXCLUDE USING gist (id_equipment WITH =, ts_range WITH &&);
DROP INDEX IF EXISTS gold.equipment_oee_shift_ts_range_id_equipment_idx;
COMMIT;
