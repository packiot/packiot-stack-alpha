\set ON_ERROR_STOP 1
BEGIN;
DROP FUNCTION IF EXISTS silver.rollup_shadow_record(timestamptz, timestamptz);
COMMIT;
