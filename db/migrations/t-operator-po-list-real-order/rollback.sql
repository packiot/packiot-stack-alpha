-- Restores the pre-fix stub definition.
SET search_path = serving, core, public;
CREATE OR REPLACE VIEW serving.v_operator_po_list_setup_4 WITH (security_invoker = on) AS
 SELECT po.id_production_order,
    po.id_production_order::integer AS id_order,
    po.id_enterprise,
    po.id_equipment,
    po.status,
    COALESCE(po.production_programmed, 0::bigint) AS production_programmed,
    po.ts_start,
    NULL::jsonb AS equipment_setup,
    1.0::double precision AS conversion_factor,
    NULL::jsonb AS custom_field,
    NULL::jsonb AS priority,
    pr.packml_topic AS topic,
    po.txt_production_order_notes AS nm_client,
    NULL::character varying AS nm_product_family,
    COALESCE(po.id_order_text, ('PO-'::text || po.id_production_order::text)::character varying) AS nm_product,
    NULL::character varying AS txt_product
   FROM production_orders po
     LEFT JOIN LATERAL ( SELECT topic_routing.packml_topic
           FROM topic_routing
          WHERE topic_routing.id_equipment = po.id_equipment AND topic_routing.active = true
         LIMIT 1) pr ON true
;
