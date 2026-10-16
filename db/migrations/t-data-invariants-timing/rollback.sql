BEGIN;
DROP VIEW IF EXISTS ops.data_invariant_timing;
ALTER TABLE ops.data_invariant_result DROP COLUMN IF EXISTS recorded_at;
COMMIT;
