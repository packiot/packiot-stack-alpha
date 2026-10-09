-- verify for t-adr0061-p3c-po-list-by-id. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
-- per equipment that has POs: v2(ids=[e]) must return exactly the view's rows for e (same columns but the topic).
SELECT 'V1 equipments whose v2 rows differ from the view rows: 0', count(*) FROM (SELECT DISTINCT id_equipment FROM serving.v_operator_po_list_setup_4) e
 WHERE ARRAY(SELECT (v.id_production_order, v.status, v.ts_start, v.production_programmed, v.nm_product) FROM serving.v_operator_po_list_setup_4 v WHERE v.id_equipment = e.id_equipment ORDER BY 1)
    IS DISTINCT FROM ARRAY(SELECT (f.id_production_order, f.status, f.ts_start, f.production_programmed, f.nm_product) FROM serving.operator_po_list_by_equipment(ARRAY[e.id_equipment]) f ORDER BY 1);
SELECT 'V2 POs compared: >0', count(*) FROM serving.v_operator_po_list_setup_4;
SELECT 'V3 every PO has a display path (missing): 0', count(*) FROM serving.operator_po_list_by_equipment(ARRAY(SELECT DISTINCT id_equipment FROM serving.v_operator_po_list_setup_4)) WHERE coalesce(display_path, '') = '';
SELECT 'V4 readapi_ro can execute: t', has_function_privilege('readapi_ro', 'serving.operator_po_list_by_equipment(integer[])', 'EXECUTE');
-- informational: POs whose v1 topic is not the equipment's base topic (the nondeterminism v2 removes)
SELECT 'I1 POs on equipment with >1 active routing row (v1 topic unstable)', count(*) FROM serving.v_operator_po_list_setup_4 v
 WHERE (SELECT count(*) FROM topic_routing t WHERE t.id_equipment = v.id_equipment AND t.active) > 1;
