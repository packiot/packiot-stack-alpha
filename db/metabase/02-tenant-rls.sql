-- db/metabase/02-tenant-rls.sql
-- W2 embedded-Metabase scaffolding — INERT until the W2 go decision.
-- Apply by hand, staging-first. See db/metabase/README.md + docs/plans/w2-embedded-metabase.md §3.
--
-- The DB-LEVEL BACKSTOP beneath Metabase's own data sandbox. Postgres row-level
-- security (RLS) keyed on a per-connection session GUC `app.tenant_id`. Any
-- connection reading these tables sees ONLY rows whose id_enterprise matches the
-- GUC — regardless of what the querying client (Metabase, psql, a mis-scoped BI
-- tool) intended.
--
-- ── How the GUC gets set (the load-bearing detail) ───────────────────────────
-- RLS is only as good as the value in current_setting('app.tenant_id'). The GUC
-- must be established on the CONNECTION before any tenant query. Options:
--   (a) per-tenant DB connection:  ...?options=-c app.tenant_id=<id_enterprise>
--       (Metabase: one "database" entry per tenant — clean RLS, N connections).
--   (b) per-session SET:  SET app.tenant_id = '<id>';  before each query
--       (works for a bespoke pooled proxy that stamps it from the sandbox attr).
--   (c) role default:  ALTER ROLE metabase_ro_t<id> SET app.tenant_id = '<id>';
--       (one login role per tenant; the GUC rides the role).
-- Under a SINGLE shared metabase_ro connection with NO GUC, current_setting()
-- below returns '' → the policy denies ALL rows (fail-closed). That is why, in
-- the default single-connection topology, the Metabase SANDBOX is the primary
-- enforcement and this RLS is a genuine backstop only under (a)/(b)/(c). See the
-- spec §6 open questions — this is the biggest multi-tenancy design decision.

-- current_tenant(): the GUC as int, or NULL when unset/blank. `true` = missing_ok
-- so an unset GUC yields NULL (→ policy denies) instead of erroring.
CREATE OR REPLACE FUNCTION current_tenant() RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::int
$$;

-- Representative policy on a table that carries id_enterprise NATIVELY.
-- Repeat this block for each tenant-scoped base table you decide to protect
-- (production_orders_runtime shown; production_targets / scrap_targets /
-- oee_targets / data_quality_event follow the identical shape).
ALTER TABLE production_orders_runtime ENABLE ROW LEVEL SECURITY;
ALTER TABLE production_orders_runtime FORCE ROW LEVEL SECURITY;  -- applies even to the table owner

DROP POLICY IF EXISTS tenant_isolation ON production_orders_runtime;
CREATE POLICY tenant_isolation ON production_orders_runtime
    USING (id_enterprise = current_tenant());

-- For tables WITHOUT a native id_enterprise column (e.g. equipment_runtime_1hour,
-- downtimes — tenant is reached via the equipments dimension), the RLS predicate
-- is an EXISTS against equipments. Heavier per-row; measure on the hypertable
-- before enabling broadly (see spec §6 — RLS-on-TimescaleDB performance risk).
--
--   ALTER TABLE equipment_runtime_1hour ENABLE ROW LEVEL SECURITY;
--   ALTER TABLE equipment_runtime_1hour FORCE ROW LEVEL SECURITY;
--   DROP POLICY IF EXISTS tenant_isolation ON equipment_runtime_1hour;
--   CREATE POLICY tenant_isolation ON equipment_runtime_1hour
--       USING (EXISTS (
--           SELECT 1 FROM equipments e
--           WHERE e.id_equipment = equipment_runtime_1hour.id_equipment
--             AND e.id_enterprise = current_tenant()));
--
-- PERFORMANCE NOTE (TimescaleDB): a hypertable is many chunk sub-tables; RLS
-- predicates are pushed to each chunk and an EXISTS-join predicate can defeat
-- chunk exclusion / add a per-row subplan. Prefer keying RLS on a NATIVE
-- id_enterprise column — consider denormalizing id_enterprise onto the hot
-- rollup tables so the policy is a cheap `id_enterprise = current_tenant()`
-- rather than a join. Benchmark on staging before prod.

-- metabase_ro is a normal (non-BYPASSRLS) role — confirm it never bypasses.
ALTER ROLE metabase_ro NOBYPASSRLS;
