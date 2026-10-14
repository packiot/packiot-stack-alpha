-- rollback t-sandbox-heal-keep-box-scans — restore the tenant-wide box-scan wipe before the PO swap.
-- NOTE: rolled back, every heal deletes all sandbox barcode scans and box counters again.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $rb$
DECLARE
  fn   regprocedure;
  def  text;
  wipe text := $w$  DELETE FROM gold.po_box_counter WHERE id_enterprise = p_dst;
  DELETE FROM bronze.box_scans    WHERE id_enterprise = p_dst;
$w$;
  keep text := $k$  -- box scans + counters are NOT wiped here: orphans are removed after the swap
  -- (t-sandbox-heal-keep-box-scans).
$k$;
  after_swap text := $a$  RAISE NOTICE 'PO runtimes reflected %', n;
$a$;
  orphans text := $o$  RAISE NOTICE 'PO runtimes reflected %', n;
  -- Barcode scans are the sandbox's own history: keep every row whose parents survived the swap
  -- (twin PO ids are deterministic) and delete only orphans, which would break a pg_restore FK
  -- (t-sandbox-heal-keep-box-scans).
  DELETE FROM gold.po_box_counter c
   WHERE c.id_enterprise = p_dst
     AND NOT EXISTS (SELECT 1 FROM core.production_orders p WHERE p.id_production_order = c.id_production_order);
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'box counters: % orphans removed', n;
  DELETE FROM bronze.box_scans s
   WHERE s.id_enterprise = p_dst
     AND (   NOT EXISTS (SELECT 1 FROM core.production_orders p WHERE p.id_production_order = s.id_production_order)
          OR NOT EXISTS (SELECT 1 FROM core.equipments e WHERE e.id_equipment = s.id_equipment)
          OR (s.id_area IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.areas a WHERE a.id_area = s.id_area))
          OR (s.id_site IS NOT NULL AND NOT EXISTS (SELECT 1 FROM core.sites t WHERE t.id_site = s.id_site)));
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'box scans: % orphans removed', n;
  DELETE FROM bronze.box_scans v
   WHERE v.id_enterprise = p_dst AND v.voids_box_scan_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM bronze.box_scans o WHERE o.box_scan_id = v.voids_box_scan_id);
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'box scans: % voids of removed scans removed', n;
$o$;
BEGIN
  SELECT p.oid::regprocedure INTO fn FROM pg_proc p
   WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = 'sandbox_reflect';
  IF fn IS NULL THEN RAISE EXCEPTION 'ops.sandbox_reflect not found'; END IF;
  def := pg_get_functiondef(fn);
  IF position(keep IN def) = 0 OR position(orphans IN def) = 0 THEN
    RAISE NOTICE 'not patched — nothing to roll back';
    RETURN;
  END IF;
  EXECUTE replace(replace(def, keep, wipe), orphans, after_swap);
  RAISE NOTICE 'sandbox_reflect: tenant-wide box-scan wipe restored';
END
$rb$;
COMMIT;
