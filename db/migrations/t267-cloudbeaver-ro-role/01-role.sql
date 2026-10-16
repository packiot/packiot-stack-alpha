-- t267 — cloudbeaver_ro: read-only staff DB-browser role for the CloudBeaver instance.
--
-- Design: READ-ONLY (SELECT grants only — NO insert/update/delete/DDL) + BYPASSRLS.
-- Rationale: this is an internal staff debug browser behind the cs-admin oauth2 gate,
-- so seeing all tenants' rows is the intended function (BYPASSRLS), but it must NOT be
-- able to mutate — strictly safer than pgweb's current `postgres` SUPERUSER connection,
-- which can DROP/DELETE. (Ties to the read-api NOBYPASSRLS hardening theme, but inverted:
-- a debug browser WANTS cross-tenant visibility; what it must not have is write.)
--
-- The LOGIN password is set out-of-band (ALTER ROLE ... PASSWORD, sourced from
-- CLOUDBEAVER_RO_PASSWORD in /opt/packiot/.env) so no secret is committed. This
-- migration only creates the role (NOLOGIN) + grants; the password/LOGIN is applied live.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='cloudbeaver_ro') THEN
    CREATE ROLE cloudbeaver_ro NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE BYPASSRLS;
  END IF;
END $$;

GRANT USAGE ON SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  TO cloudbeaver_ro;

GRANT SELECT ON ALL TABLES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  TO cloudbeaver_ro;

-- future tables in these schemas stay readable without re-granting
ALTER DEFAULT PRIVILEGES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  GRANT SELECT ON TABLES TO cloudbeaver_ro;
