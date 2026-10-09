-- DOWN / reversal for batch po-backfill-2026-08-27 (twin ent-3 PO header backfill).
-- Removes exactly the rows inserted by backfill_headers.sql. Idempotent.
-- Run on twin: psql -h 10.10.10.89 -U postgres -d packiot_analytics -f down_po_backfill.sql
BEGIN;
-- dependent runtime windows first (none inserted by the backfill, but the OEE
-- worker may have created some via recalc_needed=true; clear them to avoid orphans).
DELETE FROM production_orders_runtime r
  USING twin_backfill_po_log b
 WHERE r.id_production_order = b.id_production_order
   AND b.batch = 'po-backfill-2026-08-27';
DELETE FROM production_orders po
  USING twin_backfill_po_log b
 WHERE po.id_production_order = b.id_production_order
   AND b.batch = 'po-backfill-2026-08-27';
DELETE FROM twin_backfill_po_log WHERE batch = 'po-backfill-2026-08-27';
COMMIT;
