-- #226 item 1 (oee_q CONTRACT — reader repoint phase).
-- Repoint the ONLY DB reader of the legacy oee_quality/availability/performance
-- columns — the Superset serving view bi.production_orders — onto the canonical
-- oee_q/oee_a/oee_p columns. The OUTPUT column names are kept IDENTICAL
-- (oee_q AS oee_quality, …) so the deployed (dark) Superset dataset + charts are
-- untouched: this repoints STORAGE, not the serving contract. Equivalence is
-- guaranteed — oee_q ≡ oee_quality for every row (0 mismatch, backfill + dual-write
-- trigger), so the view emits byte-identical values (proven live: same md5).
-- bi.* stays security-DEFINER (deployed Superset is dark-schema). The writer
-- (stream-engine recalc) + dual-write trigger are repointed/dropped in the
-- contract phase (02).
CREATE OR REPLACE VIEW bi.production_orders AS
 SELECT po.id_enterprise,
    po.id_production_order,
    po.id_equipment,
    eq.nm_equipment,
    po.id_product,
    po.id_client,
    po.status,
    po.production_programmed,
    po.production_ordered,
    po.production_real,
    po.net_production,
    po.gross_production,
    po.oee,
    po.oee_a AS oee_availability,
    po.oee_p AS oee_performance,
    po.oee_q AS oee_quality,
    po.running_time,
    po.available_time,
    po.stopped_time,
    po.ts_start,
    po.ts_end,
    po.nm_production_order,
    po.id_order_text,
    COALESCE(NULLIF(po.nm_production_order::text, ''::text), NULLIF(po.id_order_text::text, ''::text), 'PO #'::text || po.id_production_order) AS po_label,
    eq.nm_equipment::text ||
        CASE eq.tp_equipment
            WHEN 3 THEN ' (line)'::text
            WHEN 1 THEN ' (machine)'::text
            WHEN 2 THEN ' (sector)'::text
            ELSE ''::text
        END AS equipment_label
   FROM production_orders po
     JOIN equipments eq ON eq.id_equipment = po.id_equipment;
