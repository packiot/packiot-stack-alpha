-- Revert bi.production_orders to read the legacy oee_quality/availability/performance.
CREATE OR REPLACE VIEW bi.production_orders AS
 SELECT po.id_enterprise, po.id_production_order, po.id_equipment, eq.nm_equipment,
    po.id_product, po.id_client, po.status, po.production_programmed, po.production_ordered,
    po.production_real, po.net_production, po.gross_production, po.oee,
    po.oee_availability, po.oee_performance, po.oee_quality,
    po.running_time, po.available_time, po.stopped_time, po.ts_start, po.ts_end,
    po.nm_production_order, po.id_order_text,
    COALESCE(NULLIF(po.nm_production_order::text, ''::text), NULLIF(po.id_order_text::text, ''::text), 'PO #'::text || po.id_production_order) AS po_label,
    eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
   FROM production_orders po JOIN equipments eq ON eq.id_equipment = po.id_equipment;
