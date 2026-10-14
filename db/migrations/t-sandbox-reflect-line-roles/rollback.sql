-- rollback t-sandbox-reflect-line-roles — restore the lead_machine-only override (roles then rely on
-- ops.sandbox_sync_attribution again).
\set ON_ERROR_STOP 1
BEGIN;
DO $rb$
DECLARE
  fn regprocedure := (SELECT oid FROM pg_proc WHERE pronamespace='ops'::regnamespace AND proname='sandbox_reflect')::regprocedure;
  def text := pg_get_functiondef(fn);
  cur text := $n$'lead_machine', x.lead_machine + %1$s, 'gross_machine', x.gross_machine + %1$s, 'net_machine', x.net_machine + %1$s, 'scrap_machine', x.scrap_machine + %1$s$m$$n$;
BEGIN
  IF position(cur IN def) = 0 THEN RAISE NOTICE 'not patched — nothing to roll back'; RETURN; END IF;
  EXECUTE replace(def, cur, $o$'lead_machine', x.lead_machine + %1$s$m$$o$);
END $rb$;
COMMIT;
