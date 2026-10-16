-- verify for t-adr0061-p3c2-po-number-text. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 id_order type is integer, id_order_text present: integer|character varying',
       (SELECT format_type(t, NULL) FROM unnest(p.proallargtypes) WITH ORDINALITY a(t, n) WHERE n = 3),
       (SELECT format_type(t, NULL) FROM unnest(p.proallargtypes) WITH ORDINALITY a(t, n) WHERE n = 4)
  FROM pg_proc p WHERE p.oid = 'serving.operator_po_list_by_equipment(integer[])'::regprocedure;
SELECT 'V2 rows still == the view per equipment (differing equipments): 0', count(*) FROM (SELECT DISTINCT id_equipment FROM serving.v_operator_po_list_setup_4) e
 WHERE ARRAY(SELECT (v.id_production_order, v.id_order, v.status) FROM serving.v_operator_po_list_setup_4 v WHERE v.id_equipment = e.id_equipment ORDER BY 1)
    IS DISTINCT FROM ARRAY(SELECT (f.id_production_order, f.id_order, f.status) FROM serving.operator_po_list_by_equipment(ARRAY[e.id_equipment]) f ORDER BY 1);
SELECT 'V3 client PO numbers carried (rows with id_order_text = the table''s): mismatches 0', count(*)
  FROM serving.operator_po_list_by_equipment(ARRAY(SELECT DISTINCT id_equipment FROM serving.v_operator_po_list_setup_4)) f
  JOIN core.production_orders po USING (id_production_order) WHERE f.id_order_text IS DISTINCT FROM po.id_order_text;
SELECT 'I1 listed POs with an alphanumeric client number (informational)', count(*)
  FROM serving.operator_po_list_by_equipment(ARRAY(SELECT DISTINCT id_equipment FROM serving.v_operator_po_list_setup_4)) WHERE id_order_text ~ '[^0-9]';
SELECT 'V4 readapi_ro can execute: t', has_function_privilege('readapi_ro', 'serving.operator_po_list_by_equipment(integer[])', 'EXECUTE');
