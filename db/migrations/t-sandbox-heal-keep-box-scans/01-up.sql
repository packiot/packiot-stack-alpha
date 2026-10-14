-- t-sandbox-heal-keep-box-scans — the sandbox heal keeps barcode scans; it deletes only orphans (2026-10-14).
--
-- WHY: barcode feedback "normal labels are not persisted". Five scans on the twin returned 201 on 2026-10-06
-- 14:41-14:46 (PO 500036870, line 2000047) and were gone the next day, while bronze.sample_boxes kept its rows
-- from the same session. ops.sandbox_reflect's PO swap ran
--     DELETE FROM gold.po_box_counter WHERE id_enterprise = p_dst;
--     DELETE FROM bronze.box_scans    WHERE id_enterprise = p_dst;
-- on every heal (nightly + 4 h after the last hands-on change). That wipe was added because po_box_counter rows
-- whose PO had vanished (the swap runs with FK triggers off) made pg_restore fail
-- fk_po_box_counter_production_order (restore drill 2026-09-29). Wiping everything fixed the orphans and also
-- threw away every valid scan.
--
-- WHAT: one asserted edit of the LIVE body (pg_get_functiondef, the convention of t-sandbox-reflect-line-roles and
-- t-adr0062-sandbox-twin-po-uuid; it builds on PRODT-164 / #1750, which did not touch this procedure):
--   1. the two tenant-wide DELETEs before the PO swap are removed;
--   2. after the swap re-inserts the twin POs, rows whose parent is gone are deleted: a counter or scan whose PO no
--      longer exists, and a scan whose equipment / area / site no longer exists (the config layer deletes E2E-made
--      areas). Those are exactly the rows that would break a pg_restore FK. A void scan pointing at a removed scan
--      goes with it.
-- Twin PO ids are deterministic (CPACK id + 500,000,000), so a scan on a twin PO survives every heal. The sandbox has
-- no POs of its own (all 19,667 are twins on 2026-10-14), so there are no native POs to keep.
-- bronze.box_scans is append-only (trg_box_scans_no_mutate); the heal runs with session_replication_role = replica,
-- which is why it can delete orphans at all. Neither table is a hypertable.
--
-- Idempotent: a body that no longer wipes box_scans is left alone. Each anchor must match exactly once, so a body
-- drift fails loudly instead of silently not patching.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $patch$
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
  c int;
BEGIN
  SELECT p.oid::regprocedure INTO fn FROM pg_proc p
   WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = 'sandbox_reflect';
  IF fn IS NULL THEN RAISE EXCEPTION 'ops.sandbox_reflect not found'; END IF;
  def := pg_get_functiondef(fn);
  IF position('t-sandbox-heal-keep-box-scans' IN def) > 0 THEN
    RAISE NOTICE 'sandbox_reflect already keeps box scans — skipped';
    RETURN;
  END IF;
  c := (length(def) - length(replace(def, wipe, ''))) / length(wipe);
  IF c <> 1 THEN RAISE EXCEPTION 'expected exactly 1 box-scan wipe in %, found %', fn, c; END IF;
  c := (length(def) - length(replace(def, after_swap, ''))) / length(after_swap);
  IF c <> 1 THEN RAISE EXCEPTION 'expected exactly 1 PO-runtime notice in %, found %', fn, c; END IF;
  EXECUTE replace(replace(def, wipe, keep), after_swap, orphans);  -- CREATE OR REPLACE: grants + owner kept
  RAISE NOTICE 'sandbox_reflect: box scans kept, orphans only';
END
$patch$;
COMMIT;
