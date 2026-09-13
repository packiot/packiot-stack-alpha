-- t271 — cloudbeaver_rw: the read-WRITE editor role for CloudBeaver's "editors" team.
--
-- Design: DML editing (SELECT/INSERT/UPDATE/DELETE + sequence usage for serial inserts)
-- but NO DDL — deliberately NO CREATE on schemas, so editors cannot CREATE/ALTER/DROP
-- objects (a wrong click can't drop a table on live staging). BYPASSRLS (staff debug
-- across tenants, behind the cs-admin gate). NOSUPERUSER/NOCREATEDB/NOCREATEROLE.
--
-- Access model: this role backs a SECOND CloudBeaver connection ("packiot_analytics
-- (read-write)") that is granted ONLY to an "editors" team — NOT to the anonymous team.
-- Anonymous/gate users keep the cloudbeaver_ro (view-only) connection. So "only certain
-- users may edit" = only named CloudBeaver logins in the editors team.
--
-- Password set out-of-band (ALTER ROLE ... LOGIN PASSWORD from CLOUDBEAVER_RW_PASSWORD
-- in /opt/packiot/.env + Secrets Manager) — no secret committed.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='cloudbeaver_rw') THEN
    CREATE ROLE cloudbeaver_rw NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE BYPASSRLS;
  END IF;
END $$;

GRANT USAGE ON SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  TO cloudbeaver_rw;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  TO cloudbeaver_rw;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  TO cloudbeaver_rw;

ALTER DEFAULT PRIVILEGES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO cloudbeaver_rw;

ALTER DEFAULT PRIVILEGES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  GRANT USAGE, SELECT ON SEQUENCES TO cloudbeaver_rw;
