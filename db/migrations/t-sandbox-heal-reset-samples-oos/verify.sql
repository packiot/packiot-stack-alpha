-- verify t-sandbox-heal-reset-samples-oos — read-only. label|value, expected in the label.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
WITH d AS (SELECT pg_get_functiondef(p.oid) AS def FROM pg_proc p
            WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = 'sandbox_reflect')
SELECT 'V1 heal deletes the sandbox sample labels: t',
       position('DELETE FROM bronze.sample_boxes WHERE id_enterprise = p_dst;' IN def) > 0 FROM d
UNION ALL
SELECT 'V2 heal copies the source sample labels (PO + po_off): t',
       position('FROM (SELECT * FROM bronze.sample_boxes WHERE id_enterprise = p_src ORDER BY id_box) x;' IN def) > 0
       AND position('''id_production_order'', x.id_production_order + po_off' IN def) > 0 FROM d
UNION ALL
SELECT 'V3 heal deletes the sandbox OOS windows: t',
       position('DELETE FROM config.equipment_out_of_service WHERE id_enterprise = p_dst;' IN def) > 0 FROM d
UNION ALL
SELECT 'V4 heal copies the source OOS windows: t',
       position('FROM (SELECT * FROM config.equipment_out_of_service WHERE id_enterprise = p_src ORDER BY id) x;' IN def) > 0 FROM d
UNION ALL
SELECT 'V5 reset runs after the PO swap and before HISTORY: t',
       position('sample labels reflected %' IN def) > position('POs reflected %' IN def)
       AND position('-- ── HISTORY (fill-only' IN def) > position('out-of-service windows reflected %' IN def) FROM d
UNION ALL
SELECT 'V6 sandbox-id guard still first: t',
       position('p_dst < 1000000 THEN' IN def) BETWEEN 1 AND position('DELETE FROM bronze.sample_boxes' IN def) FROM d
UNION ALL
SELECT 'V6b both id sequences owned by their column (the copy draws new ids from them): t',
       pg_get_serial_sequence('bronze.sample_boxes', 'id_box') IS NOT NULL
       AND pg_get_serial_sequence('config.equipment_out_of_service', 'id') IS NOT NULL;
-- Informational: after the next heal (nightly 06:00 UTC or heal-now) the sandbox counts equal CPACK's.
SELECT 'V7 sample labels ent ' || e || ' (info: 2000003 = 3 after a heal)',
       (SELECT count(*) FROM bronze.sample_boxes WHERE id_enterprise = e) FROM (VALUES (3), (2000003)) v(e);
SELECT 'V8 OOS windows ent ' || e || ' (info: 2000003 = 3 after a heal)',
       (SELECT count(*) FROM config.equipment_out_of_service WHERE id_enterprise = e) FROM (VALUES (3), (2000003)) v(e);
-- After a heal: every sandbox row is a mapped source row (expected 0).
SELECT 'V9 sandbox sample labels without a mapped CPACK row (after a heal): 0', count(*)
  FROM bronze.sample_boxes s
 WHERE s.id_enterprise = 2000003
   AND NOT EXISTS (SELECT 1 FROM bronze.sample_boxes c
                    WHERE c.id_enterprise = 3 AND c.id_equipment + 2000000 = s.id_equipment
                      AND c.id_production_order + 500000000 = s.id_production_order AND c.ts_value = s.ts_value);
SELECT 'V10 sandbox OOS windows without a mapped CPACK window (after a heal): 0', count(*)
  FROM config.equipment_out_of_service s
 WHERE s.id_enterprise = 2000003
   AND NOT EXISTS (SELECT 1 FROM config.equipment_out_of_service c
                    WHERE c.id_enterprise = 3 AND c.id_equipment + 2000000 = s.id_equipment AND c.period = s.period);
ROLLBACK;
