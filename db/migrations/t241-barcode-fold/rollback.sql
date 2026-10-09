-- t241 · BARCODE FOLD — ROLLBACK.  Recreate `barcode` and move the 4 tables back
-- (catalog-only, no data at risk). Symmetric to 01-fold.sql. Restores P-barcode's
-- end-state (all 4 tables in `barcode`, search_path with `barcode`).
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE SCHEMA IF NOT EXISTS barcode;

ALTER TABLE bronze.box_scans      SET SCHEMA barcode;
ALTER TABLE gold.po_box_counter   SET SCHEMA barcode;
ALTER TABLE public.scanned_boxes  SET SCHEMA barcode;
ALTER TABLE public.sample_boxes   SET SCHEMA barcode;

COMMIT;

ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, barcode, app, serving, customer_reports, core, public;
