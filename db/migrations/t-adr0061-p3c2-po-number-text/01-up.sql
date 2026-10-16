-- t-adr0061-p3c2-po-number-text — the operator PO list (/v2) carries the CLIENT's PO number.
--
-- core.production_orders keeps an internal integer `id_order` and the client's own, possibly ALPHANUMERIC,
-- order number in `id_order_text` (e.g. "ORD 694b…"). v_operator_po_list_setup_4 exposes only the integer, so the
-- operator showed the internal number to the client. This also fixes t-adr0061-p3c's declared type: it said
-- id_order `character varying` and Postgres silently coerced the view's INTEGER (so /v2 returned "36950" where
-- v1 returns 36950). Now: id_order integer (as v1) + id_order_text. Return type changes ⇒ DROP + CREATE, in ONE
-- transaction, so read-api never sees the function missing.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DROP FUNCTION serving.operator_po_list_by_equipment(integer[]);
CREATE FUNCTION serving.operator_po_list_by_equipment(in_id_equipment integer[])
RETURNS TABLE (id_production_order bigint, id_order integer, id_order_text character varying, id_enterprise integer,
               id_equipment integer, status integer, production_programmed bigint, ts_start timestamptz,
               equipment_setup jsonb, conversion_factor double precision, custom_field jsonb, priority jsonb,
               display_path text, nm_client character varying, nm_product_family character varying,
               nm_product character varying, txt_product character varying)
LANGUAGE sql STABLE
AS $$
  SELECT v.id_production_order, v.id_order, po.id_order_text, v.id_enterprise, v.id_equipment, v.status,
         v.production_programmed, v.ts_start, v.equipment_setup, v.conversion_factor, v.custom_field, v.priority,
         core.equipment_display_path(v.id_equipment), v.nm_client, v.nm_product_family, v.nm_product, v.txt_product
    FROM serving.v_operator_po_list_setup_4 v
    LEFT JOIN core.production_orders po ON po.id_production_order = v.id_production_order
   WHERE v.id_equipment = ANY (in_id_equipment)
$$;
COMMENT ON FUNCTION serving.operator_po_list_by_equipment(integer[]) IS
  'ADR-0061 P3: id-based operator PO list (read-api /v2/operator-po-list). Wraps v_operator_po_list_setup_4; display_path replaces the unstable topic; id_order_text = the client''s (alphanumeric) PO number.';
GRANT EXECUTE ON FUNCTION serving.operator_po_list_by_equipment(integer[]) TO readapi_ro, superset_ro, bi_owner;

COMMIT;
