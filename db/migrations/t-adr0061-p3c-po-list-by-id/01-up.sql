-- t-adr0061-p3c-po-list-by-id — ADR-0061 P3: the operator's PO list by id_equipment (read-api /v2/operator-po-list).
--
-- v_operator_po_list_setup_4 already carries po.id_equipment, but the operator matched POs on its `topic`
-- column — a LATERAL `SELECT packml_topic FROM topic_routing … LIMIT 1` with NO ORDER BY: for an equipment with
-- several routing rows (e.g. CER400: 3) the topic is whichever row the planner returns, so `po.topic ===
-- packmlTopic` could silently miss the running PO. This function WRAPS the live view (same rows/rules by
-- construction), filters by id, and replaces the unstable topic with the D6 display path. ADDITIVE; v1 untouched.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION serving.operator_po_list_by_equipment(in_id_equipment integer[])
RETURNS TABLE (id_production_order bigint, id_order character varying, id_enterprise integer, id_equipment integer,
               status integer, production_programmed bigint, ts_start timestamptz, equipment_setup jsonb,
               conversion_factor double precision, custom_field jsonb, priority jsonb, display_path text,
               nm_client character varying, nm_product_family character varying, nm_product character varying,
               txt_product character varying)
LANGUAGE sql STABLE
AS $$
  SELECT v.id_production_order, v.id_order, v.id_enterprise, v.id_equipment, v.status, v.production_programmed,
         v.ts_start, v.equipment_setup, v.conversion_factor, v.custom_field, v.priority,
         core.equipment_display_path(v.id_equipment), v.nm_client, v.nm_product_family, v.nm_product, v.txt_product
    FROM serving.v_operator_po_list_setup_4 v
   WHERE v.id_equipment = ANY (in_id_equipment)
$$;
COMMENT ON FUNCTION serving.operator_po_list_by_equipment(integer[]) IS
  'ADR-0061 P3: id-based operator PO list (read-api /v2/operator-po-list). Wraps v_operator_po_list_setup_4 by construction; display_path replaces the unstable topic.';
GRANT EXECUTE ON FUNCTION serving.operator_po_list_by_equipment(integer[]) TO readapi_ro, superset_ro, bi_owner;

COMMIT;
