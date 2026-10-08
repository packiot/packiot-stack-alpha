-- PROMOTION PRELUDE 02 — the medallion rename staging was BORN with (its analytics DB came from the F3 snapshot):
-- base table public.topic_routing + auto-updatable compat view public.packml_register over it. No migration
-- file does this; t237-core-schema/01-expand.sql assumes it ("packml_register is a VIEW over the base table
-- topic_routing"). Prod still has the base table named packml_register. Idempotent.
-- Old writers keep working: plain DML and ON CONFLICT (col) pass through an auto-updatable view; triggers,
-- indexes, constraints and policies stay on the table (OID-bound).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $r$
DECLARE g record;
BEGIN
  IF to_regclass('public.topic_routing') IS NOT NULL THEN
    RAISE NOTICE 'public.topic_routing already exists — skipped'; RETURN;
  END IF;
  IF (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.packml_register')) IS DISTINCT FROM 'r' THEN
    RAISE EXCEPTION 'public.packml_register is not a base table — unexpected starting shape';
  END IF;
  ALTER TABLE public.packml_register RENAME TO topic_routing;
  CREATE VIEW public.packml_register AS SELECT * FROM public.topic_routing;
  -- same privileges on the view as the table had
  FOR g IN SELECT grantee, string_agg(privilege_type, ', ') AS privs FROM information_schema.role_table_grants
            WHERE table_schema = 'public' AND table_name = 'topic_routing' AND grantee <> current_user GROUP BY grantee LOOP
    EXECUTE format('GRANT %s ON public.packml_register TO %s', g.privs,
                   CASE WHEN g.grantee = 'PUBLIC' THEN 'PUBLIC' ELSE quote_ident(g.grantee) END);
  END LOOP;
  RAISE NOTICE 'public.packml_register → base table public.topic_routing + compat view';
END
$r$;
COMMIT;
