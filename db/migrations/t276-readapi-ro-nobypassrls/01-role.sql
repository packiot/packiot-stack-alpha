-- t276 — readapi_ro: the LEAST-PRIVILEGE, NOBYPASSRLS login role read-api runs under.
--
-- WHY (task #264 — defense-in-depth tenant fence)
-- ────────────────────────────────────────────────
-- read-api's tenant isolation is app-layer-only today: every dataset query carries a
-- `WHERE id_enterprise = $1` fence (CI-gated by TestEveryDatasetIsTenantScoped) and the
-- customer id is ALWAYS server-derived (never client-supplied). But read-api connects as
-- `postgres`, a SUPERUSER with rolbypassrls=true — so the FORCE ROW LEVEL SECURITY that
-- db/superset/02-tenant-rls.sql put on the tenant tables (core.equipments,
-- core.production_orders, core.production_targets, gold.equipment_oee_hourly,
-- gold.equipment_oee_shift, gold.production_orders_runtime) NEVER bites the read plane.
-- If a future dataset ever ships WITHOUT the $1 fence, it would leak EVERY tenant's rows.
--
-- This role removes that: NOBYPASSRLS + NOSUPERUSER. Combined with read-api stamping the
-- `app.tenant_id` GUC per read (task #264 read-api change — runQueryJSON), Postgres RLS
-- becomes a CO-ENFORCER of the SAME server-derived tenant the app-layer already fences to.
-- An unfenced future dataset is then RLS-scoped to that tenant instead of leaking all of
-- them. The $1 fence stays PRIMARY; RLS is the backstop. Mirrors the superset_ro/bi_owner
-- dual-layer posture (02-tenant-rls.sql), inverted from cloudbeaver_ro (which WANTS
-- cross-tenant visibility and keeps BYPASSRLS).
--
-- PRIVILEGE MODEL
-- ────────────────
--   * NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE  — the security win of #264.
--   * READ-ONLY across the analytics schemas (SELECT only). read-api's read surface is
--     ~45 serving.* SECURITY INVOKER functions + direct SELECTs whose bodies transitively
--     touch core/silver/gold/config/identity/bi/customer_reports; a broad read-only grant
--     (matching cloudbeaver_ro's breadth, minus BYPASSRLS) guarantees no legitimate read
--     breaks on a missing grant. The hardening that matters for #264 is NOBYPASSRLS +
--     no-write + no-DDL, NOT schema-narrowing.
--   * NARROW WRITE — read-api is not purely read: it persists per-user UI state and runs
--     the Cognito link-on-login self-heal. So exactly TWO write grants, both on tables
--     WITHOUT RLS (so no GUC needed there):
--       - identity.user_screen_config : INSERT, UPDATE (PUT /v1/screen-config upsert)
--       - identity.users              : UPDATE        (link id_user_cognito on first login)
--   * NO CREATE on any schema — read-api's ensureSchema() startup DDL is best-effort
--     (errors swallowed) and its objects already exist, so it degrades to a harmless no-op.
--
-- The LOGIN + PASSWORD are applied OUT-OF-BAND (ALTER ROLE ... LOGIN PASSWORD, sourced from
-- READAPI_RO_PASSWORD in /opt/packiot/.env + Secrets Manager) so no secret is committed —
-- same pattern as t267 (cloudbeaver_ro) / t271 (cloudbeaver_rw). This migration creates the
-- role NOLOGIN and lays down the grants; the password/LOGIN flip is a live one-time step.
--
-- Reversible: rollback.sql (revoke + drop). Idempotent: guarded CREATE + plain re-GRANTs.

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='readapi_ro') THEN
    CREATE ROLE readapi_ro NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END $$;

-- Belt-and-suspenders: ensure the two attributes #264 depends on, even if the role
-- pre-existed with different flags.
ALTER ROLE readapi_ro NOSUPERUSER NOBYPASSRLS;

-- ── Schema access (USAGE) ────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  TO readapi_ro;

-- ── Read (SELECT) across the analytics schemas ───────────────────────────────
GRANT SELECT ON ALL TABLES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  TO readapi_ro;

-- future tables/views stay readable without re-granting
ALTER DEFAULT PRIVILEGES IN SCHEMA
  core, silver, gold, bronze, identity, config, ops, serving, bi, customer_reports, public
  GRANT SELECT ON TABLES TO readapi_ro;

-- ── EXECUTE on functions (serving.* are the datasets read-api calls; the RLS
--    helper functions live in public.current_tenant()/is_all_tenant()). Explicit
--    grants so the role does not silently rely on the PUBLIC default EXECUTE. ────
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA
  serving, core, silver, gold, config, identity, bi, customer_reports, public
  TO readapi_ro;

ALTER DEFAULT PRIVILEGES IN SCHEMA
  serving, core, silver, gold, config, identity, bi, customer_reports, public
  GRANT EXECUTE ON FUNCTIONS TO readapi_ro;

-- ── Narrow WRITE surface (both tables are RLS-free — no GUC needed) ───────────
-- PUT /v1/screen-config upsert (INSERT ... ON CONFLICT DO UPDATE).
GRANT SELECT, INSERT, UPDATE ON identity.user_screen_config TO readapi_ro;
-- Cognito link-on-login self-heal: UPDATE users SET id_user_cognito = ... .
GRANT UPDATE ON identity.users TO readapi_ro;

-- NOTE: LOGIN + PASSWORD applied live, NOT here (no secret in git):
--   ALTER ROLE readapi_ro LOGIN PASSWORD '<READAPI_RO_PASSWORD from /opt/packiot/.env>';
