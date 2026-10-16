-- rollback t-sparkplug-agent-role — remove the sparkplug_agent login.
--
-- FIRST point the agent away from it (unset AGENT_DB_SECRET_ID and recreate the container) or its link-health
-- writes fail (they are best-effort: ingest is unaffected, plc_link_minutes stops). The secret
-- packiot/<env>/sparkplug-agent-db-creds is not touched; delete it separately if the role is gone for good.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE r record;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sparkplug_agent') THEN
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'sparkplug_agent';
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM sparkplug_agent', current_database());
    FOR r IN SELECT DISTINCT c.oid::regclass AS rel
               FROM pg_class c, aclexplode(c.relacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'sparkplug_agent') LOOP
      EXECUTE format('REVOKE ALL ON TABLE %s FROM sparkplug_agent', r.rel);
    END LOOP;
    REVOKE ALL ON FUNCTION public.current_tenant(), public.is_all_tenant() FROM sparkplug_agent;
    REVOKE ALL ON SCHEMA core, silver, public FROM sparkplug_agent;
    DROP ROLE sparkplug_agent;
  END IF;
END $$;

COMMIT;
