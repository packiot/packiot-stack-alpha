-- rollback for t-adr0061-p3a-operator-by-id (read-api /v2 operator routes must be gone first).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION IF EXISTS serving.downtime_reasons_by_equipment(integer[]);
DROP FUNCTION IF EXISTS serving.events_timeline_by_equipment(integer[]);
DROP FUNCTION IF EXISTS serving.pending_downtime_by_equipment(integer[]);
DROP FUNCTION IF EXISTS serving.topics_of_equipment(integer[]);
DROP FUNCTION IF EXISTS core.equipment_display_path(integer);
COMMIT;
