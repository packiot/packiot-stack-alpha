-- rollback t-sandbox-heal-reset-samples-oos — remove the sample-label + OOS-window reset block from the heal.
-- Restores the exact previous body text (whether or not t-sandbox-heal-keep-box-scans is applied).
-- NOTE: rows already reset by a heal are not restored; rolled back, sample labels and OOS windows made in
-- the sandbox survive heals again.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $rb$
DECLARE
  fn     regprocedure;
  def    text;
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
  IF position('t-sandbox-heal-reset-samples-oos' IN def) = 0 THEN
    RAISE NOTICE 'not patched — nothing to roll back';
    RETURN;
  END IF;
  c := (length(def) - length(replace(def, block || anchor, ''))) / length(block || anchor);
  IF c <> 1 THEN
    RAISE EXCEPTION 'patched block in % was edited after the patch (found % exact copies) — restore by hand', fn, c;
  END IF;
  EXECUTE replace(def, block || anchor, anchor);
  RAISE NOTICE 'sandbox_reflect: sample-label + OOS-window reset removed';
END
$rb$;
COMMIT;
