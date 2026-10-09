-- t241 · BARCODE FOLD — reverse P-barcode; fold the 4 `barcode` tables into the
-- medallion layers by MATURITY, and drop the `barcode` schema.  (task #241,
-- adversarial-review correction — see docs/plans/public-schema-reorg.md §12.1)
--
--   box_scans      → bronze   (immutable append-only raw scan ledger; no_mutate trigger)
--   po_box_counter → gold     (per-PO computed aggregate: last_label_seq / total_qty)
--   scanned_boxes  → public   (KEEP — live production Samples feature, NOT legacy; see §12.1.1)
--   sample_boxes   → public   (KEEP — same)
--
-- SHIM-FREE (§12.1.2): bronze & gold already sit on the DB search_path AHEAD of
-- `barcode` (…gold, silver, bronze, barcode, …). Every writer of these tables uses
-- BARE, unqualified names — edge-api scanned-boxes-dao.ts + samples-dao.ts, and the
-- standalone barcode-service scans.go — so after the catalog move a bare `box_scans`
-- resolves `bronze` directly (bronze precedes barcode) and `po_box_counter` resolves
-- `gold` (first on path). `scanned_boxes`/`sample_boxes` resolve `public` (on every
-- path). No public shim view is needed, so the po_box_counter ON CONFLICT upsert never
-- traverses a view (avoiding the arbiter-inference footgun entirely).
--
-- Catalog-only, no data copied. Owned sequences (box_scans IDENTITY seq, scanned/
-- sample serial seqs), indexes, the box_scans_no_mutate trigger, fk_box_scans_voids
-- (self-ref), and serving.v_po_box_totals (binds box_scans by OID) all FOLLOW the
-- table automatically. stream-engine has 0 refs to any of these 4 tables → no deploy.
BEGIN;
SET LOCAL lock_timeout = '5s';

-- Move each base table to its correct layer. AccessExclusive is sub-second; the few
-- concurrent bare writers queue behind the lock and resolve to the new layer after.
ALTER TABLE barcode.box_scans      SET SCHEMA bronze;
ALTER TABLE barcode.po_box_counter SET SCHEMA gold;
ALTER TABLE barcode.scanned_boxes  SET SCHEMA public;
ALTER TABLE barcode.sample_boxes   SET SCHEMA public;

-- barcode is now empty (only ever held these 4 tables + their owned objects;
-- v_po_box_totals lives in `serving`). RESTRICT (default) asserts emptiness.
DROP SCHEMA barcode;

COMMIT;

-- Narrow the DB search_path to drop the now-nonexistent `barcode`. A missing schema
-- in search_path is silently ignored by Postgres, so this is cosmetic + correctness;
-- existing pooled connections keep resolving correctly with or without a pgbouncer
-- bounce (bronze/gold precede the old `barcode` slot; public is always present).
ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, app, serving, customer_reports, core, public;
