-- t-sparkplug-agent-role — the least-privilege login the shared sparkplug-agent runs under (2026-10-16).
--
-- WHY
-- The agent reaches the analytics DB for two best-effort features: PLC link health (t-plc-link-health —
-- one row per tenant × endpoint × minute in silver.plc_link_minutes, the input of the "NO DATA" availability
-- state) and saved derive rules (the newest core.client_descriptors row per tenant, read at boot). On staging
-- it connects as ${POSTGRES_USER} (SUPERUSER) through the .env passthrough. Production gave it NO DSN at all
-- (to keep capture off), which also switched link health off: no plc_link_minutes on production since the
-- go-live (2026-10-16 13:18 UTC; invariant L1_link_endpoints_silent_10min). This is the login production uses.
--
-- WHAT IT ACTUALLY NEEDS (services/sparkplug-decoder: internal/agent/linkhealth, cmd/sparkplug-agent/
-- tenant_rules.go; nothing else runs while AGENT_CAPTURE_ENABLED=false):
--   * SELECT core.client_descriptors   — tenant_code → id_enterprise (link health) + the descriptor (rules);
--   * INSERT/UPDATE silver.plc_link_minutes — the upsert; SELECT on it too (ON CONFLICT DO UPDATE reads t.*).
--   Capture (AGENT_CAPTURE_ENABLED=true) needs more (descriptor writes, capture_observations); it stays off
--   wherever this login is used. Grant it separately if capture is ever turned on with this login.
--
-- RLS. silver.plc_link_minutes has FORCE RLS (tenant_isolation). The agent is multi-tenant by design and
-- resolves the enterprise inside its statement, so — like stream_engine — the role is NOBYPASSRLS with the
-- role default app.tenant_id = '-1' (the all-tenant sentinel): every policy is still evaluated and fails
-- closed if it ever stops granting the sentinel.
--
-- PASSWORD. Not here. LOGIN with a NULL password until the host sets it from Secrets Manager
-- packiot/<env>/sparkplug-agent-db-creds (scripts/ops/provision-db-role.py --service sparkplug-agent).
--
-- Idempotent: guarded CREATE, ALTER re-asserts attributes, GRANTs are repeatable. Reversible: rollback.sql.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sparkplug_agent') THEN
    CREATE ROLE sparkplug_agent LOGIN;
  END IF;
END $$;

ALTER ROLE sparkplug_agent LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT
  CONNECTION LIMIT 10;   -- link-health pool + derive-rules pool (pgxpool defaults) + a rolling recreate
ALTER ROLE sparkplug_agent SET app.tenant_id = '-1';           -- multi-tenant writer (see RLS above)
ALTER ROLE sparkplug_agent SET statement_timeout = '30s';

COMMENT ON ROLE sparkplug_agent IS
  'shared sparkplug-agent (t-sparkplug-agent-role): SELECT core.client_descriptors; SELECT/INSERT/UPDATE '
  'silver.plc_link_minutes (PLC link health). NOBYPASSRLS with role default app.tenant_id=-1 (multi-tenant). '
  'Password from Secrets Manager packiot/<env>/sparkplug-agent-db-creds, set on the host.';

DO $$ BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO sparkplug_agent', current_database());
END $$;

GRANT USAGE ON SCHEMA core, silver, public TO sparkplug_agent;
GRANT SELECT ON core.client_descriptors TO sparkplug_agent;
GRANT SELECT, INSERT, UPDATE ON silver.plc_link_minutes TO sparkplug_agent;
GRANT EXECUTE ON FUNCTION public.current_tenant(), public.is_all_tenant() TO sparkplug_agent;

COMMIT;
