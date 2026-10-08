-- rollback for t-adr0061-p3c-po-list-by-id (read-api /v2/operator-po-list must be gone first; the operator falls back to v1).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION IF EXISTS serving.operator_po_list_by_equipment(integer[]);
COMMIT;
