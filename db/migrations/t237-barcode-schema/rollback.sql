-- t237 P-barcode · ROLLBACK — symmetric reverse of expand/contract (catalog-only,
-- no data at risk). Safe to run whether or not the contract already dropped shims.
BEGIN;
SET LOCAL lock_timeout = '3s';

-- Drop any surviving shim views so the names are free in public.
DROP VIEW IF EXISTS public.box_scans;
DROP VIEW IF EXISTS public.po_box_counter;
DROP VIEW IF EXISTS public.scanned_boxes;
DROP VIEW IF EXISTS public.sample_boxes;

-- Move the bases back to public (owned sequences follow automatically).
ALTER TABLE barcode.box_scans      SET SCHEMA public;
ALTER TABLE barcode.po_box_counter SET SCHEMA public;
ALTER TABLE barcode.scanned_boxes  SET SCHEMA public;
ALTER TABLE barcode.sample_boxes   SET SCHEMA public;

COMMIT;

-- Narrow the search_path back to the pre-P-barcode value.
ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, public;

-- DROP SCHEMA barcode;  -- optional: only after confirming it is empty.
-- Then restart stack-pgbouncer-1 to recycle pools onto the narrowed path.
