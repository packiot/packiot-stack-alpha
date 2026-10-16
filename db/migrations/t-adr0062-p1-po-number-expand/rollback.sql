-- rollback for t-adr0062-p1-po-number-expand. Keeps the backfilled numbers (they are the client's numbers, a strict
-- improvement over NULL) and the corrections table (audit); removes the constraints, trigger, po_uuid and helpers.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DROP TRIGGER IF EXISTS production_orders_po_number ON core.production_orders;
DROP FUNCTION IF EXISTS core.production_orders_po_number();
DROP INDEX IF EXISTS core.production_orders_id_enterprise_order_number_key;
DROP INDEX IF EXISTS core.production_orders_po_uuid_key;
ALTER TABLE core.production_orders ALTER COLUMN id_order_text DROP NOT NULL;
ALTER TABLE core.production_orders DROP COLUMN IF EXISTS po_uuid;
DROP SEQUENCE IF EXISTS core.production_orders_internal_id_order_seq;
DROP FUNCTION IF EXISTS core.uuidv7(timestamptz);
COMMIT;
