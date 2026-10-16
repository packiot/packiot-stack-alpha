-- t-sandbox-reflect-line-roles — ops.sandbox_reflect remaps the twin lines' meter roles itself (2026-10-09).
--
-- WHY: the reflect clones core.equipments as to_jsonb(src) || overrides, and the overrides remap only id_equipment,
-- id_parentequipment and lead_machine. gross_machine / net_machine / scrap_machine (and updated_at) were copied RAW
-- from CPACK, so after every reflect the six twin lines (2000047..2000052) pointed net_machine at CPACK's own machines
-- (57, 60, 63, 69, 75, 79 — enterprise 3): a cross-tenant read. ops.sandbox_sync_attribution (t-sandbox-attribution-
-- sync) fixes them, but the heal runs it AFTER the gold-history resync (minutes of per-month commits), so for minutes
-- of every heal the twin read CPACK's counts — invariant R3_line_roles_bad caught it on 2026-10-09.
-- WHAT: patch the live function body — the lead_machine override gains the three role columns (+ p_off; NULL stays
-- NULL). Exactly one occurrence is asserted, so a body drift fails loudly instead of silently not patching.
-- Idempotent: a body that already remaps net_machine is left alone. sandbox_sync_attribution stays (it also syncs
-- topic routing) and becomes a no-op for roles.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $patch$
DECLARE
  fn  regprocedure;
  def text;
  old text := $o$'lead_machine', x.lead_machine + %1$s$m$$o$;
  new text := $n$'lead_machine', x.lead_machine + %1$s, 'gross_machine', x.gross_machine + %1$s, 'net_machine', x.net_machine + %1$s, 'scrap_machine', x.scrap_machine + %1$s$m$$n$;
  n int;
BEGIN
  SELECT p.oid::regprocedure INTO fn FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = 'sandbox_reflect';
  IF fn IS NULL THEN RAISE EXCEPTION 'ops.sandbox_reflect not found'; END IF;
  def := pg_get_functiondef(fn);
  IF position($c$'net_machine', x.net_machine$c$ IN def) > 0 THEN
    RAISE NOTICE 'sandbox_reflect already remaps net_machine — skipped';
    RETURN;
  END IF;
  n := (length(def) - length(replace(def, old, ''))) / length(old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected exactly 1 lead_machine override in %, found %', fn, n;
  END IF;
  EXECUTE replace(def, old, new);
END
$patch$;
COMMIT;
