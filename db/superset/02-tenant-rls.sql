-- db/superset/02-tenant-rls.sql
-- W2 embedded-Superset scaffolding — INERT until the W2 go decision.
-- Apply by hand, staging-first. See db/superset/README.md + docs/plans/w2-embedded-superset.md §3.
--
-- Postgres Row-Level Security as a REAL per-tenant CO-ENFORCER (not the
-- fail-closed-only no-op the Metabase donor settled for). Every base table behind
-- a bi.* view gets an RLS policy keyed on the session GUC `app.tenant_id`:
--
--   * GUC set to a tenant id → the policy FILTERS to that tenant's rows.
--   * GUC unset/blank         → current_tenant() is NULL → the policy DENIES ALL
--                               rows (fail-closed).
--
-- This bites through the bi.* views because 01-superset-ro-role.sql owns those
-- (SECURITY DEFINER) views with `bi_owner`, a NOSUPERUSER **NOBYPASSRLS** role.
-- current_setting('app.tenant_id') is session-scoped, so even inside the definer
-- view it reads the value stamped on the CONNECTION — so RLS filters by the
-- connection's tenant. superset_ro is also NOBYPASSRLS; nothing on this path
-- bypasses.
--
-- ── How the GUC gets stamped (the load-bearing detail) ───────────────────────
-- RLS is only a co-enforcer if the CONNECTION carries the tenant. Superset opens
-- ONE pooled SQLAlchemy connection per registered "database" and does NOT run a
-- per-query SET. So to make Postgres RLS co-enforce (rather than deny-all), the
-- tenant must ride the connection/role. Pick a topology (spec §3.2, §6):
--
--   (a) per-tenant DB connection:  register the analytics source per tenant with
--       connect_args {"options": "-c app.tenant_id=<id_enterprise>"} — the GUC is
--       fixed on that pool. Clean; N connections (one per onboarded tenant).
--   (c) per-tenant login role:  superset_ro_t<id> with
--         ALTER ROLE superset_ro_t<id> SET app.tenant_id = '<id>';
--       — the GUC rides the role; register one Superset database per tenant role.
--   (b) pooled proxy:  a thin proxy stamps SET app.tenant_id per checkout from the
--       request/token context (build/run cost).
--
-- The 2-tenant isolation gate (tests/superset/test_superset_tenant_isolation.py)
-- exercises the SESSION-STAMP primitive directly (SET app.tenant_id per session)
-- and proves: set → filter, wrong-tenant clause → 0 rows, unset → 0 rows,
-- tenant A rows ∩ tenant B rows = ∅. That is the co-enforcer, demonstrated.
--
-- Note on the guest-token/embed path: the single pooled superset_ro (GUC unset)
-- would be deny-all here, so the EMBED viewer path relies on Superset's guest-token
-- RLS (the id_enterprise = <derived> clause on the view column) as PRIMARY, and
-- this Postgres layer is its fail-closed net. The AUTHORING path (and any direct
-- superset_ro client) SHOULD use a per-tenant connection/role (a/c) so this layer
-- co-enforces. See the spec for the full matrix.
--
-- Idempotent: CREATE OR REPLACE FUNCTION + guarded ENABLE + DROP/CREATE POLICY.

-- current_tenant(): the GUC as int, or NULL when unset/blank. `true` = missing_ok
-- so an unset GUC yields NULL (→ policy denies) instead of erroring.
CREATE OR REPLACE FUNCTION current_tenant() RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::int
$$;

-- ── Native-id tables (id_enterprise is a real column) — cheap policy ─────────
-- production_orders_runtime carries id_enterprise natively.
ALTER TABLE production_orders_runtime ENABLE ROW LEVEL SECURITY;
ALTER TABLE production_orders_runtime FORCE ROW LEVEL SECURITY;  -- applies even to the table owner
DROP POLICY IF EXISTS tenant_isolation ON production_orders_runtime;
CREATE POLICY tenant_isolation ON production_orders_runtime
    USING (id_enterprise = current_tenant());

-- equipments carries id_enterprise natively (and is the dimension the other
-- policies reach through — protect it directly too).
ALTER TABLE equipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipments FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON equipments;
CREATE POLICY tenant_isolation ON equipments
    USING (id_enterprise = current_tenant());

-- ── Reached-via-equipments tables (no native id_enterprise) — EXISTS policy ──
-- equipment_runtime_shift → equipments for the tenant key.
ALTER TABLE equipment_runtime_shift ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_runtime_shift FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON equipment_runtime_shift;
CREATE POLICY tenant_isolation ON equipment_runtime_shift
    USING (EXISTS (
        SELECT 1 FROM equipments e
        WHERE e.id_equipment = equipment_runtime_shift.id_equipment
          AND e.id_enterprise = current_tenant()));

-- equipment_runtime_1hour → equipments.
ALTER TABLE equipment_runtime_1hour ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_runtime_1hour FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON equipment_runtime_1hour;
CREATE POLICY tenant_isolation ON equipment_runtime_1hour
    USING (EXISTS (
        SELECT 1 FROM equipments e
        WHERE e.id_equipment = equipment_runtime_1hour.id_equipment
          AND e.id_enterprise = current_tenant()));

-- downtimes → equipments.
ALTER TABLE downtimes ENABLE ROW LEVEL SECURITY;
ALTER TABLE downtimes FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON downtimes;
CREATE POLICY tenant_isolation ON downtimes
    USING (EXISTS (
        SELECT 1 FROM equipments e
        WHERE e.id_equipment = downtimes.id_equipment
          AND e.id_enterprise = current_tenant()));

-- PERFORMANCE NOTE (TimescaleDB): equipment_runtime_1hour / _shift are hypertable-
-- backed; an EXISTS-join RLS predicate is pushed per-chunk and can defeat chunk
-- exclusion / add a per-row subplan. If ad-hoc self-service query latency bites,
-- DENORMALIZE id_enterprise onto these rollups (the OEE writer already knows the
-- equipment→enterprise mapping) and swap the EXISTS for a native
-- `id_enterprise = current_tenant()` — same isolation, far cheaper. Benchmark on
-- staging before prod. (The isolation gate passes under either predicate shape.)

-- Belt-and-suspenders: confirm the read roles never bypass RLS.
ALTER ROLE superset_ro NOBYPASSRLS;
ALTER ROLE bi_owner NOBYPASSRLS;
