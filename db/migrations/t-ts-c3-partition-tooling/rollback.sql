-- rollback for t-ts-c3-partition-tooling: removes the tooling. Refuses while a conversion is prepared
-- but not swapped (drop its twin, capture table and pc_capture trigger first). Swapped tables stay.
\set ON_ERROR_STOP 1
BEGIN;
DO $c$ BEGIN
  IF EXISTS (SELECT 1 FROM ops.pc_state WHERE swapped_at IS NULL) THEN
    RAISE EXCEPTION 'a conversion is in progress (ops.pc_state.swapped_at IS NULL); clean it up first';
  END IF;
END $c$;
DROP FUNCTION IF EXISTS ops.partition_maintain(interval);
DROP FUNCTION IF EXISTS ops.pc_swap(regclass);
DROP PROCEDURE IF EXISTS ops.pc_copy(regclass);
DROP PROCEDURE IF EXISTS ops.pc_prepare(regclass, interval, interval);
DROP FUNCTION IF EXISTS ops.pc_add_partitions(regclass, interval, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS ops.pc_floor(timestamptz, interval);
COMMIT;
