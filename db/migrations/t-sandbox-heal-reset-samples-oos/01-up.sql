-- t-sandbox-heal-reset-samples-oos — the sandbox heal also resets sample labels and out-of-service windows
-- (2026-10-14).
--
-- WHY: user decision 2026-10-14 ("yes add both to the heal"): SANDBOX-CPACK (enterprise 2000003) must reset
-- completely to CPACK-Staging (enterprise 3) on every heal. Until now ops.sandbox_reflect never touched
--   bronze.sample_boxes            (sample labels: barcode-app sample total + printed sample labels)
--   config.equipment_out_of_service (OOS windows: excluded from OEE by serving.line_excluded_minutes)
-- so a sample label or an OOS window made in the sandbox survived every heal (5 sample rows on 2026-10-14,
-- while CPACK has none).
--
-- WHAT: one asserted edit of the LIVE body (pg_get_functiondef, as t-sandbox-reflect-line-roles,
-- t-adr0062-sandbox-twin-po-uuid and t-sandbox-heal-keep-box-scans do). A block is inserted after the PO
-- swap's COMMIT and before the HISTORY section, so it runs on every reflect (heal or provision):
--   1. DELETE every sandbox sample_boxes row (id_enterprise = p_dst), then copy p_src's rows with the twin ids:
--      equipment / area / site + p_off (2,000,000), PO + 500,000,000 (po_off, the twin PO id), a new id_box
--      from the column's sequence; id_order is kept (the twin PO keeps the source id_order) and so are
--      should_increment, increment, box_order_number and ts_value.
--   2. DELETE every sandbox OOS window (id_enterprise = p_dst), then copy p_src's windows with
--      id_equipment + p_off and a new id. The EXCLUDE (id_equipment WITH =, period WITH &&) cannot collide:
--      the sandbox's windows are deleted first and the mapped equipment ids belong only to the sandbox.
--   Source with no rows ⇒ sandbox with no rows. Deletes are fenced by id_enterprise = p_dst; the body's own
--   guard (p_dst >= 1,000,000 and != p_src) runs before anything, and this migration asserts it is present.
--   It runs inside the body's session_replication_role = replica, like every other reflect step (the
--   sample_boxes FKs to enterprises/equipments are triggers, so they are off; both targets exist anyway).
--   Neither table is a hypertable and neither has triggers.
--
-- It does not depend on t-sandbox-heal-keep-box-scans (#1759) being applied or rolled back: the anchor is the
-- HISTORY section header, which is identical in both bodies, and that migration's own anchors are untouched,
-- so either can be rolled back independently of this one.
--
-- Idempotent: a body that already contains the marker is left alone ("skipped"). Each anchor must match
-- exactly once, so a body drift fails loudly instead of silently not patching.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $patch$
DECLARE
  fn     regprocedure;
  def    text;
  guard  text := $g$  IF p_dst = p_src OR p_dst < 1000000 THEN
    RAISE EXCEPTION 'sandbox_reflect: refusing dst=% (must be a sandbox id >= 1,000,000 and != src)', p_dst;
  END IF;
$g$;
  anchor text := $a$  -- ── HISTORY (fill-only, strictly BELOW the range the sandbox pipeline owns) ─────
$a$;
  block  text := $b$  -- Sample labels + out-of-service windows: RESET to the source's on every reflect, ids mapped
  -- like the rest of the twin (equipment/area/site + p_off, PO + po_off); none on the source ⇒ none here
  -- (t-sandbox-heal-reset-samples-oos).
  DELETE FROM bronze.sample_boxes WHERE id_enterprise = p_dst;
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'sample labels: % sandbox rows removed', n;
  INSERT INTO bronze.sample_boxes
  SELECT (jsonb_populate_record(NULL::bronze.sample_boxes, to_jsonb(x) || jsonb_build_object(
          'id_box', nextval(pg_get_serial_sequence('bronze.sample_boxes', 'id_box')),
          'id_enterprise', p_dst, 'id_site', x.id_site + p_off, 'id_area', x.id_area + p_off,
          'id_equipment', x.id_equipment + p_off, 'id_production_order', x.id_production_order + po_off))).*
    FROM (SELECT * FROM bronze.sample_boxes WHERE id_enterprise = p_src ORDER BY id_box) x;
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'sample labels reflected %', n;
  DELETE FROM config.equipment_out_of_service WHERE id_enterprise = p_dst;
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'out-of-service windows: % sandbox rows removed', n;
  INSERT INTO config.equipment_out_of_service
  SELECT (jsonb_populate_record(NULL::config.equipment_out_of_service, to_jsonb(x) || jsonb_build_object(
          'id', nextval(pg_get_serial_sequence('config.equipment_out_of_service', 'id')),
          'id_enterprise', p_dst, 'id_equipment', x.id_equipment + p_off))).*
    FROM (SELECT * FROM config.equipment_out_of_service WHERE id_enterprise = p_src ORDER BY id) x;
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'out-of-service windows reflected %', n;
  IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; END IF;

$b$;
  c int;
BEGIN
  SELECT p.oid::regprocedure INTO fn FROM pg_proc p
   WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = 'sandbox_reflect';
  IF fn IS NULL THEN RAISE EXCEPTION 'ops.sandbox_reflect not found'; END IF;
  def := pg_get_functiondef(fn);
  IF position('t-sandbox-heal-reset-samples-oos' IN def) > 0 THEN
    RAISE NOTICE 'sandbox_reflect already resets sample labels + OOS windows — skipped';
    RETURN;
  END IF;
  c := (length(def) - length(replace(def, guard, ''))) / length(guard);
  IF c <> 1 THEN RAISE EXCEPTION 'expected exactly 1 sandbox-id guard in %, found %', fn, c; END IF;
  IF position('po_off constant bigint := 500000000;' IN def) = 0 THEN
    RAISE EXCEPTION 'po_off (500,000,000) not declared in %', fn;
  END IF;
  IF pg_get_serial_sequence('bronze.sample_boxes', 'id_box') IS NULL
     OR pg_get_serial_sequence('config.equipment_out_of_service', 'id') IS NULL THEN
    RAISE EXCEPTION 'id sequence of bronze.sample_boxes / config.equipment_out_of_service is not owned by its column';
  END IF;
  c := (length(def) - length(replace(def, anchor, ''))) / length(anchor);
  IF c <> 1 THEN RAISE EXCEPTION 'expected exactly 1 HISTORY section header in %, found %', fn, c; END IF;
  EXECUTE replace(def, anchor, block || anchor);  -- CREATE OR REPLACE: grants + owner kept
  RAISE NOTICE 'sandbox_reflect: sample labels + OOS windows now reset on every heal';
END
$patch$;
COMMIT;
