-- rollback for t-prodt172-operator-last-line. Run as postgres.
--
-- The table holds only landing-line convenience data (nothing references it). Roll back the edge-api release that
-- reads/writes it FIRST: /session tolerates a missing table (logs and returns last_line_id null), but
-- POST /api/operator/last-line would answer 500 until edge-api is rolled back (the Operator ignores that error).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP TABLE IF EXISTS identity.operator_last_line;
COMMIT;
SELECT 'rollback t-prodt172-operator-last-line: done';
