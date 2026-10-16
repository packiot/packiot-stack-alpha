-- Operator PO list was a migration-era STUB: id_order = the internal id_production_order
-- (operator header "PO 36432" instead of order 897120), nm_client = the PO notes,
-- nm_product = 'PO-<id>', family/setup/custom NULL, and NO status filter (every poll
-- shipped all ~19k CPACK POs). Now matches legacy's v_operator_po_list_setup_4: real
-- id_order + client/product/family joins + legacy's filter (status 1/2/4, or 3 ended
-- in the last 10 days). Kept: the one-topic-per-equipment topic_routing lateral, the
-- exact column names/order/types (CREATE OR REPLACE VIEW), security_invoker.
-- Writes are unaffected: setup/replace write by id_production_order; idOrder is only
-- read when the operator TYPES a new order (shouldCreatePo).
SET search_path = serving, core, public;
CREATE OR REPLACE VIEW serving.v_operator_po_list_setup_4 WITH (security_invoker = on) AS
 SELECT po.id_production_order,
    po.id_order,
    po.id_enterprise,
    po.id_equipment,
    po.status,
    COALESCE(po.production_programmed, 0::bigint) AS production_programmed,
    po.ts_start,
    p.equipment_setup,
    COALESCE(po.conversion_factor, 1)::double precision AS conversion_factor,
    po.custom_field,
    po.custom_field -> 'priority'::text AS priority,
    pr.packml_topic AS topic,
    c.nm_client,
    pf.nm_product_family::character varying AS nm_product_family,
    p.nm_product::character varying AS nm_product,
    p.txt_product::character varying AS txt_product
   FROM production_orders po
     LEFT JOIN clients c ON c.id_client = po.id_client AND c.id_enterprise = po.id_enterprise
     LEFT JOIN products p ON p.id_product = po.id_product AND p.id_enterprise = po.id_enterprise
     LEFT JOIN product_families pf ON pf.id_product_family = p.id_product_family AND pf.id_enterprise = po.id_enterprise
     LEFT JOIN LATERAL ( SELECT topic_routing.packml_topic
           FROM topic_routing
          WHERE topic_routing.id_equipment = po.id_equipment AND topic_routing.active = true
         LIMIT 1) pr ON true
  WHERE po.status = ANY (ARRAY[1, 2, 4])
     OR (po.status = 3 AND po.ts_end >= now() - '10 days'::interval);
