-- t-operator-gateway-role — the least-privilege login operator-gateway runs under (2026-10-13).
--
-- WHY
-- operator-gateway connected to packiot_analytics as ${POSTGRES_USER} (postgres: SUPERUSER, BYPASSRLS).
-- Its whole DB surface is ONE read: the topic resolver (services/operator-gateway/internal/adapter/
-- resolver.go, queryEquipment) plus the pool's connect/ping. A leaked gateway credential (it sits on a
-- TLS endpoint that client Node-RED flows call) was a full superuser on the shared analytics DB.
--
-- CALL PATH → PRIVILEGE (the complete list; nothing else in the service touches the DB)
--   pool connect (MinConns=1) + /healthz Ping .......... CONNECT on the database
--   resolver tx: set_config('app.tenant_id', ent, true)  built-in, no grant
--   resolver SELECT, every name schema-qualified:
--     core.topic_routing  (topic, id_equipment, active)   SELECT on those 3 columns
--     core.equipments     (id_equipment, cd_equipment, id_area)  SELECT on those 3 columns
--     core.areas          (id_area, id_site)              SELECT on those 2 columns
--     core.sites          (id_site, id_enterprise)        SELECT on those 2 columns
--   RLS policies on core.topic_routing + core.equipments (FORCE, tenant_isolation) call
--     public.current_tenant() / public.is_all_tenant() as the invoker ... USAGE on core + public,
--     EXECUTE on the two helpers (explicit, so a future REVOKE ... FROM PUBLIC cannot break it)
-- No INSERT/UPDATE/DELETE anywhere, no sequences, no LISTEN, no other functions. All writes go
-- through edge-api over HTTP.
--
-- RLS. core.topic_routing and core.equipments are FORCE ROW LEVEL SECURITY keyed on app.tenant_id
-- (db/superset/02-tenant-rls.sql). This role is NOBYPASSRLS, so the resolver stamps the instance's one
-- enterprise as a TRANSACTION-LOCAL GUC before its SELECT (same primitive as read-api's
-- runQueryJSON; safe under pgbouncer transaction pooling). An unstamped session sees 0 rows
-- (fail closed). The resolver's own `s.id_enterprise = $2` fence stays primary; RLS is the backstop.
-- Columns referenced only by a policy (id_enterprise on those two tables) need no column grant.
--
-- The resolver reads core.topic_routing, not the security_invoker compat view over it (old name):
-- a security_invoker view needs SELECT on EVERY column of its base table (sparkplug_json, value,
-- mqtt_topic, device_key, ...), while the base table can be granted the 3 columns actually read.
--
-- PASSWORD. Not here (no secret in git). The role is LOGIN with a NULL password, so it cannot
-- authenticate until the host sets it from Secrets Manager (packiot/<env>/operator-gateway-db-creds):
-- services/operator-gateway/README.md § Provisioning the DB role. Same split as readapi_ro (t276) and
-- histgw_ro (t282). The dev seed gives every login role the password "dev" (dev/seed/load.sh).
--
-- Session defaults: read-only transactions (defense in depth: even a future bug cannot write) and a
-- 5 s statement timeout (the resolver is a 4-table PK/FK join; the HTTP handler times out at 10 s).
--
-- Idempotent: guarded CREATE, ALTER re-asserts attributes, GRANTs are repeatable.
-- Reversible: rollback.sql (operator-gateway must be pointed back at the old secret first).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'operator_gateway') THEN
    CREATE ROLE operator_gateway LOGIN;
  END IF;
END $$;

-- Re-assert every attribute even if the role pre-existed with other flags.
ALTER ROLE operator_gateway LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT
  CONNECTION LIMIT 10;   -- pool max 3; 10 leaves room for a rolling recreate and a psql check
ALTER ROLE operator_gateway SET default_transaction_read_only = on;
ALTER ROLE operator_gateway SET statement_timeout = '5s';

COMMENT ON ROLE operator_gateway IS
  'operator-gateway topic resolver (t-operator-gateway-role). SELECT on 10 columns of core.topic_routing, '
  'core.equipments, core.areas, core.sites; NOBYPASSRLS (stamps app.tenant_id per tx); read-only sessions. '
  'Password from Secrets Manager packiot/<env>/operator-gateway-db-creds, set on the host.';

DO $$ BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO operator_gateway', current_database());
END $$;

GRANT USAGE ON SCHEMA core, public TO operator_gateway;

GRANT SELECT (packml_topic, id_equipment, active)  ON core.topic_routing TO operator_gateway;
GRANT SELECT (id_equipment, cd_equipment, id_area) ON core.equipments    TO operator_gateway;
GRANT SELECT (id_area, id_site)                    ON core.areas         TO operator_gateway;
GRANT SELECT (id_site, id_enterprise)              ON core.sites         TO operator_gateway;

-- the RLS helpers the tenant_isolation policies call as the invoker
GRANT EXECUTE ON FUNCTION public.current_tenant(), public.is_all_tenant() TO operator_gateway;

COMMIT;
