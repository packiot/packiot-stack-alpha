-- db/superset/05-bi-scanned-boxes.sql
-- Bispharma new-client scanned-box reporting: RLS-fenced bi.* presentation views
-- over the barcode medallion tables (bronze.box_scans raw scans, gold.po_box_counter
-- per-PO aggregate). Apply by hand, staging-first (like 01/02), idempotent.
--
-- TENANT FENCE: identical mechanism to bi.downtimes/bi.production_targets — the
-- INNER JOIN to core.equipments (FORCE RLS on the app.tenant_id GUC) filters rows
-- to the connection's tenant. The base barcode tables carry no RLS of their own;
-- they inherit isolation transitively via the equipments join. Owned by bi_owner
-- (NOSUPERUSER NOBYPASSRLS) so RLS bites through the (non-security_invoker) view;
-- superset_ro (NOBYPASSRLS) reads them.
--
-- PROVEN (staging 2026-09-15, SET ROLE superset_ro + SET app.tenant_id):
--   ent5 → 295 scans / 6 counters / 4 lines ; ent3(CPACK) → 0 ; GUC unset → 0 (deny-all).

GRANT USAGE  ON SCHEMA bronze, gold TO bi_owner;
GRANT SELECT ON bronze.box_scans, gold.po_box_counter TO bi_owner;
GRANT SELECT ON core.sites, core.areas, core.production_orders TO bi_owner;

CREATE OR REPLACE VIEW bi.scanned_boxes AS
SELECT bs.box_scan_id, bs.id_enterprise,
       bs.id_site, s.nm_site, bs.id_area, a.nm_area,
       bs.id_equipment, eq.nm_equipment,
       bs.id_production_order, po.nm_production_order,
       bs.scan_type, bs.label_seq, bs.qty, bs.counts_toward_total,
       bs.raw_barcode, bs.ts_value
FROM bronze.box_scans bs
JOIN core.equipments eq ON eq.id_equipment = bs.id_equipment          -- RLS fence
LEFT JOIN core.sites s   ON s.id_site = bs.id_site
LEFT JOIN core.areas a   ON a.id_area = bs.id_area
LEFT JOIN core.production_orders po ON po.id_production_order = bs.id_production_order;
ALTER VIEW bi.scanned_boxes OWNER TO bi_owner;
GRANT SELECT ON bi.scanned_boxes TO superset_ro;
COMMENT ON VIEW bi.scanned_boxes IS 'Per-scan box detail (barcode). Tenant-fenced via equipments join. Cols: line/site/area/PO labels, scan_type (production|void), label_seq, qty, counts_toward_total, ts_value.';

CREATE OR REPLACE VIEW bi.po_box_counter AS
SELECT c.id_production_order, c.id_enterprise, c.last_label_seq, c.total_qty, c.updated_at,
       po.nm_production_order, po.id_equipment, eq.nm_equipment,
       po.id_site, s.nm_site, po.id_area, a.nm_area
FROM gold.po_box_counter c
JOIN core.production_orders po ON po.id_production_order = c.id_production_order
JOIN core.equipments eq ON eq.id_equipment = po.id_equipment          -- RLS fence
LEFT JOIN core.sites s   ON s.id_site = po.id_site
LEFT JOIN core.areas a   ON a.id_area = po.id_area;
ALTER VIEW bi.po_box_counter OWNER TO bi_owner;
GRANT SELECT ON bi.po_box_counter TO superset_ro;
COMMENT ON VIEW bi.po_box_counter IS 'Per-PO scanned-box aggregate: last_label_seq (box count), total_qty (units). Tenant-fenced via equipments join.';
