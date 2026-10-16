-- rollback t-prod-reflector-roles — remove both prod-reflector logins.
--
-- FIRST stop the reflector: remove PROD_MIRROR_ENTERPRISES from /opt/packiot/.env and recreate prod-reflector (it
-- then idles without a DB connection). The secrets packiot/staging/prod-reflector-db-creds and
-- packiot/production/prod-reflector-ro-db-creds are not touched; delete them separately if the roles are gone for good.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $$
DECLARE r record; who text;
BEGIN
  FOREACH who IN ARRAY ARRAY['prod_reflector', 'prod_reflector_ro'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = who) THEN CONTINUE; END IF;
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = who;
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM %I', current_database(), who);
    FOR r IN SELECT DISTINCT c.oid::regclass AS rel, c.relkind FROM pg_class c, aclexplode(c.relacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = who) LOOP
      EXECUTE format('REVOKE ALL ON %s %s FROM %I', CASE WHEN r.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, r.rel, who);
    END LOOP;
    -- column-level grants (core.enterprises UPDATE (…))
    FOR r IN SELECT DISTINCT c.oid::regclass AS rel FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid,
                    aclexplode(at.attacl) a WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = who) LOOP
      EXECUTE format('REVOKE ALL (%s) ON %s FROM %I',
        (SELECT string_agg(quote_ident(attname), ', ') FROM pg_attribute WHERE attrelid = r.rel AND attnum > 0 AND NOT attisdropped),
        r.rel, who);
    END LOOP;
    FOR r IN SELECT DISTINCT p.oid::regprocedure AS fn FROM pg_proc p, aclexplode(p.proacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = who) LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', r.fn, who);
    END LOOP;
    FOR r IN SELECT DISTINCT n.nspname FROM pg_namespace n, aclexplode(n.nspacl) a
              WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = who) LOOP
      EXECUTE format('REVOKE ALL ON SCHEMA %I FROM %I', r.nspname, who);
    END LOOP;
    EXECUTE format('DROP OWNED BY %I', who);
    EXECUTE format('ALTER ROLE %I RESET ALL', who);
    EXECUTE format('DROP ROLE %I', who);
  END LOOP;
END $$;
COMMIT;
