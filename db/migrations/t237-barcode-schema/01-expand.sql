-- t237 P-barcode · EXPAND — move the 4 barcode tables public → schema `barcode`,
-- leave auto-updatable public shim views to bridge in-flight (unqualified) writers
-- until pgbouncer's server connections recycle onto the widened search_path.
--
-- Reversibility: fully symmetric (catalog-only; no data copied). See rollback.sql.
-- Hardproof: the po_box_counter ON CONFLICT(id_production_order) DO UPDATE with a
-- table-qualified SET ref (GREATEST(po_box_counter.last_label_seq, ...)) passes
-- through an auto-updatable shim view (throwaway t237_bc/t237_pub, 0 residual).
--
-- Writers are all UNQUALIFIED (search_path-absorbed): barcode-service
-- (box_scans, po_box_counter) + edge-api samples-dao (scanned_boxes, sample_boxes).
-- stream-engine has 0 refs to these 4 tables. No Go code change in this phase.
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE SCHEMA IF NOT EXISTS barcode;

-- Move the base tables (AccessExclusive for the sub-second catalog flip).
-- Triggers (box_scans_no_mutate), FKs, the v_po_box_totals view, AND owned
-- sequences (serial scanned_boxes_id_seq / sample_boxes_id_box_seq + the box_scans
-- IDENTITY sequence) all bind by OID and follow the table automatically — do NOT
-- move sequences explicitly (they are no longer in `public` after the table move).
-- v_po_box_totals stays in public, now internally referencing barcode.box_scans.
ALTER TABLE public.box_scans      SET SCHEMA barcode;
ALTER TABLE public.po_box_counter SET SCHEMA barcode;
ALTER TABLE public.scanned_boxes  SET SCHEMA barcode;
ALTER TABLE public.sample_boxes   SET SCHEMA barcode;

-- Auto-updatable public shim views bridge any connection still on the old path
-- (no `barcode` yet) until pgbouncer recycles. INSERT/UPDATE pass through to base.
CREATE VIEW public.box_scans      AS SELECT * FROM barcode.box_scans;
CREATE VIEW public.po_box_counter AS SELECT * FROM barcode.po_box_counter;
CREATE VIEW public.scanned_boxes  AS SELECT * FROM barcode.scanned_boxes;
CREATE VIEW public.sample_boxes   AS SELECT * FROM barcode.sample_boxes;

COMMIT;
