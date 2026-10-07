-- rollback for t-po-runtime-exclusion-not-null-fk: back to nullable operands and no FK (the pre-2026-10-06 shape).
-- DROP NOT NULL / DROP CONSTRAINT are catalog-only (brief ACCESS EXCLUSIVE). Data is not touched.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE gold.production_orders_runtime DROP CONSTRAINT IF EXISTS production_orders_runtime_id_equipment_fkey;
ALTER TABLE gold.production_orders_runtime DROP CONSTRAINT IF EXISTS production_orders_runtime_id_equipment_nn;
ALTER TABLE gold.production_orders_runtime DROP CONSTRAINT IF EXISTS production_orders_runtime_timerange_nn;
ALTER TABLE gold.production_orders_runtime ALTER COLUMN id_equipment DROP NOT NULL;
ALTER TABLE gold.production_orders_runtime ALTER COLUMN runtime_timerange DROP NOT NULL;
COMMIT;
