-- t-historian-svc-hardening (T3 of docs/plans/unified-hot-cold-serving-grain-tiered-retention.md)
-- Analytics side of moving historian consumers off the gateway SUPERUSER.
--
-- histgw_ro is the least-privilege REMOTE identity the gateway's postgres_fdw uses for
-- non-superuser gateway roles (cloudbeaver_histro, and now historian_svc). Two gaps:
--  1. No SELECT on core.production_orders → the hot arm of the gateway's
--     silver.production_orders union (live.production_orders FDW, added with the PO
--     archive #1400) failed for every non-superuser.
--  2. core.production_orders has FORCE RLS (is_all_tenant() OR id_enterprise =
--     current_tenant()); an FDW session carries no app.tenant_id → current_tenant() is
--     NULL → the policy silently returns ZERO rows (not an error).
-- TRUST MODEL (unchanged, documented): the gateway has no RLS engine (pg_duckdb can't
-- evaluate a GUC); the tenant fence is the caller's literal id_enterprise predicate,
-- stamped SERVER-SIDE (read-api from the authed customer; Superset from the server-minted
-- guest-token RLS clause). So the remote identity reads all tenants — as the superuser
-- mapping does today — but only SELECT on exactly three facts, NOSUPERUSER, NOBYPASSRLS.
-- The -1 all-tenant sentinel is the documented is_all_tenant() contract.
-- Postgres privileges are TWO-level: table SELECT is useless without schema USAGE
-- (first attempt granted only the table → "permission denied for schema core").
GRANT USAGE ON SCHEMA core TO histgw_ro;
GRANT SELECT ON core.production_orders TO histgw_ro;
ALTER ROLE histgw_ro SET app.tenant_id = '-1';
COMMENT ON ROLE histgw_ro IS
  'Remote FDW identity for NON-superuser historian gateway roles. SELECT on silver.equipment_values, silver.equipment_events, core.production_orders only; app.tenant_id=-1 (all-tenant) because the gateway tenant fence is the server-stamped caller literal.';
