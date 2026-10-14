-- rollback t-legacy-replicator-role — remove the legacy_replicator login.
--
-- FIRST point BOTH replicators back at their previous credentials: set
-- LEGACY_REPLICATOR_PG_SECRET_ID=packiot/staging/db in /opt/packiot/.env and recreate legacy-replicator and
-- legacy-replicator-sbx (or revert the compose change), or their next connection fails. Then run this.
-- Section 1 of 01-up.sql (the ops tables) is NOT undone: those tables predate this migration and hold the
-- replicators' cursor, DLQ and manual-event provenance. The secret packiot/<env>/legacy-replicator-db-creds
-- is not touched; delete it separately if the role is gone for good.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$
DECLARE r record;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'legacy_replicator') THEN
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'legacy_replicator';
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM legacy_replicator', current_database());
    -- every direct grant to the role, whatever the migration version that made it
    FOR r IN SELECT DISTINCT c.oid::regclass AS rel, c.relkind
               FROM pg_class c, aclexplode(c.relacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator') LOOP
      EXECUTE format('REVOKE ALL ON %s %s FROM legacy_replicator',
                     CASE WHEN r.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, r.rel);
    END LOOP;
    FOR r IN SELECT DISTINCT p.oid::regprocedure AS fn
               FROM pg_proc p, aclexplode(p.proacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator') LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM legacy_replicator', r.fn);
    END LOOP;
    FOR r IN SELECT DISTINCT n.nspname
               FROM pg_namespace n, aclexplode(n.nspacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator') LOOP
      EXECUTE format('REVOKE ALL ON SCHEMA %I FROM legacy_replicator', r.nspname);
    END LOOP;
    DROP OWNED BY legacy_replicator;   -- temp objects, anything granted by hand later, in this database
    ALTER ROLE legacy_replicator RESET ALL;
    DROP ROLE legacy_replicator;
  END IF;
END $$;

COMMIT;
