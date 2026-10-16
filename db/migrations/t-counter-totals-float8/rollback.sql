-- rollback for t-counter-totals-float8. Deploy a stream-engine that no longer writes *_total FIRST.
-- DROP COLUMN needs the same ACCESS EXCLUSIVE window as the up (stop stream-engine). Values written to *_total are lost.
\set ON_ERROR_STOP 1
BEGIN; SET LOCAL lock_timeout = '3s';
ALTER TABLE silver.equipment_values DROP COLUMN IF EXISTS gross_production_total, DROP COLUMN IF EXISTS net_production_total,
  DROP COLUMN IF EXISTS scrap_total, DROP COLUMN IF EXISTS process_scrap_total;
COMMIT;
BEGIN; SET LOCAL lock_timeout = '3s';
ALTER TABLE bronze.equipment_values_raw DROP COLUMN IF EXISTS gross_production_total, DROP COLUMN IF EXISTS net_production_total,
  DROP COLUMN IF EXISTS scrap_total, DROP COLUMN IF EXISTS process_scrap_total;
COMMIT;
