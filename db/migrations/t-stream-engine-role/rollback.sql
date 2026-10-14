-- rollback t-stream-engine-role — remove the stream_engine login and its wrapper function.
--
-- FIRST point stream-engine back at its previous credentials: set
-- STREAM_ENGINE_PG_SECRET_ID=packiot/staging/db in /opt/packiot/.env and recreate the container (or
-- revert the compose change), or its next connection fails. Then run this. The secret
-- packiot/<env>/stream-engine-db-creds is not touched; delete it separately if the role is gone for good.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DROP FUNCTION IF EXISTS public.ensure_timescaledb_workers();

DO $$
DECLARE r record;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stream_engine') THEN
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'stream_engine';
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM stream_engine', current_database());
    -- every direct grant to the role, whatever the migration version that made it
    FOR r IN SELECT DISTINCT c.oid::regclass AS rel, c.relkind
               FROM pg_class c, aclexplode(c.relacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine') LOOP
      EXECUTE format('REVOKE ALL ON %s %s FROM stream_engine',
                     CASE WHEN r.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, r.rel);
    END LOOP;
    FOR r IN SELECT DISTINCT p.oid::regprocedure AS fn
               FROM pg_proc p, aclexplode(p.proacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine') LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM stream_engine', r.fn);
    END LOOP;
    FOR r IN SELECT DISTINCT n.nspname
               FROM pg_namespace n, aclexplode(n.nspacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine') LOOP
      EXECUTE format('REVOKE ALL ON SCHEMA %I FROM stream_engine', r.nspname);
    END LOOP;
    DROP OWNED BY stream_engine;   -- temp objects, anything granted by hand later, in this database
    ALTER ROLE stream_engine RESET ALL;
    DROP ROLE stream_engine;
  END IF;
END $$;

COMMIT;
