-- verify t-sandbox-heal-keep-box-scans — read-only. label|value, expected in the label.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
WITH d AS (SELECT pg_get_functiondef(p.oid) AS def FROM pg_proc p
            WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = 'sandbox_reflect')
SELECT 'V1 heal wipes all sandbox box_scans: f',
       position('DELETE FROM bronze.box_scans    WHERE id_enterprise = p_dst;' IN def) > 0 FROM d
UNION ALL
SELECT 'V2 heal deletes box-scan orphans after the swap: t',
       position('box scans: % orphans removed' IN def) > position('POs reflected %' IN def)
       AND position('box counters: % orphans removed' IN def) > 0 FROM d;
-- After the next heal (sandbox-selfheal, nightly 06:00 UTC or heal-now): valid scans survive, no orphans remain.
SELECT 'V3 sandbox box_scans orphaned (no PO): 0', count(*) FROM bronze.box_scans s
 WHERE s.id_enterprise >= 1000000
   AND NOT EXISTS (SELECT 1 FROM core.production_orders p WHERE p.id_production_order = s.id_production_order);
SELECT 'V4 sandbox po_box_counter orphaned (no PO): 0', count(*) FROM gold.po_box_counter c
 WHERE c.id_enterprise >= 1000000
   AND NOT EXISTS (SELECT 1 FROM core.production_orders p WHERE p.id_production_order = c.id_production_order);
SELECT 'V5 sandbox scans kept (info: > 0 once a scan is made and a heal ran)', count(*) FROM bronze.box_scans
 WHERE id_enterprise >= 1000000;
ROLLBACK;
