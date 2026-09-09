-- t237 P-barcode · CONTRACT — drop the public shim views once every pool has
-- recycled onto the widened path (pgbouncer restarted). `barcode` is a DEST-only
-- schema (no dual-DB reader resolves these names against prod), so no shim needs to
-- survive for a lagging reader. Final state: the 4 tables live solely in `barcode`,
-- no public shadow. v_po_box_totals (binds barcode.box_scans by OID) is unaffected.
BEGIN;
DROP VIEW IF EXISTS public.box_scans;
DROP VIEW IF EXISTS public.po_box_counter;
DROP VIEW IF EXISTS public.scanned_boxes;
DROP VIEW IF EXISTS public.sample_boxes;
COMMIT;
