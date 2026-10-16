-- Read-only checks after 01-up.sql (and after a heal).
SET default_transaction_read_only = on;
-- 1. the function exists and refuses CPACK (AC-04): expect the refusal NOTICE, no change.
DO $$ BEGIN
  PERFORM ops.sandbox_fix_running_without_runtime(3);
  RAISE EXCEPTION 'verify: the function did not refuse enterprise 3';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'verify:%' THEN RAISE; END IF;
  RAISE NOTICE 'ok: refuses enterprise 3 (%)', SQLERRM;
END $$;
-- 2. AC-01: Running POs of the sandbox without an open window (expect 0 after a heal).
SELECT count(*) AS sandbox_running_without_open_window
  FROM core.production_orders p
 WHERE p.id_enterprise = 2000003 AND p.status = 2
   AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime w
                    WHERE w.id_production_order = p.id_production_order AND upper(w.runtime_timerange) IS NULL);
