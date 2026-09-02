-- db/superset/02-tenant-rls.sql
-- W2 embedded-Superset scaffolding — INERT until the W2 go decision.
-- Apply by hand, staging-first. See db/superset/README.md + docs/plans/w2-embedded-superset.md §3.
--
-- Postgres Row-Level Security as a REAL per-tenant CO-ENFORCER (not the
-- fail-closed-only no-op the Metabase donor settled for). Every base table behind
-- a bi.* view gets an RLS policy keyed on the session GUC `app.tenant_id` — with ONE
-- documented exception: equipment_events is a compressed hypertable on the live DB
-- and cannot take RLS, so bi.downtimes isolates it transitively via the RLS-protected
-- equipments join (see that block below). The policy shape:
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
--
-- SEARCH-PATH SAFETY (load-bearing — see is_all_tenant below): these helpers live
-- in `public`, but Superset runs every bi.* query with `search_path = <schema>`
-- (its Postgres engine-spec appends `-csearch_path=bi` per dataset schema), so
-- `public` is NOT on the caller's path. Function bodies of inlinable SQL functions
-- are re-resolved against the CALLER'S search_path at plan/inline time — an
-- UNQUALIFIED cross-function call therefore fails with "function ... does not
-- exist". current_tenant()'s body only touches built-ins (current_setting, NULLIF,
-- int4) which are always resolvable, so it is safe unqualified; is_all_tenant()
-- calls current_tenant() and MUST qualify it (public.current_tenant()).
CREATE OR REPLACE FUNCTION public.current_tenant() RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::int
$$;

-- is_all_tenant(): TRUE when the session carries the super-admin ALL-TENANT
-- sentinel (app.tenant_id = -1). This sentinel is stamped ONLY by the Superset
-- DB_CONNECTION_MUTATOR for a native **Admin** (internal super-admin) UI session
-- (superset_config.py::_admin_all_tenant_stamp) — never for a guest token or a
-- per-tenant authoring role. It is UNFORGEABLE from the token path: the mutator
-- derives per-tenant ids by a `\d+` regex, which can only yield a NON-NEGATIVE
-- integer, so a negative value can come ONLY from the trusted admin branch.
--
-- Every tenant_isolation policy below is `is_all_tenant() OR <per-tenant match>`:
--   * super-admin session (GUC = -1) → is_all_tenant() short-circuits TRUE →
--     the policy returns EVERY tenant's rows (the internal super-admin sees all).
--   * any tenant/guest session (GUC = <real id>) → is_all_tenant() FALSE → the
--     per-tenant predicate bites exactly as before (strict per-tenant isolation).
--   * GUC unset/blank → current_tenant() NULL, is_all_tenant() FALSE, per-tenant
--     match NULL → deny-all (fail-closed) — unchanged.
--
-- The `public.` qualifier on current_tenant() is REQUIRED, not cosmetic: when the
-- planner inlines this STABLE SQL function into an RLS policy, its body is parsed
-- under the caller's search_path (`bi` for Superset chart queries — see
-- current_tenant above). Without the qualifier the inlined `current_tenant()` is
-- unresolvable → `UndefinedFunction: function current_tenant() does not exist`,
-- failing EVERY bi.* chart. The policies themselves call is_all_tenant()/
-- current_tenant() unqualified safely because policy expressions are OID-pinned at
-- CREATE POLICY time (resolved with `public` on the applying role's path); only the
-- nested body call re-resolves at run time, so only it must be qualified.
--
-- RESIDUAL-RISK NOTE (2026-08-23 BI-hardening review): "gate the -1 sentinel to a
-- dedicated admin role/connection, not any superset_ro session" was considered and
-- deliberately NOT implemented, because:
--   (a) It is not cleanly feasible under the current model — EVERY Superset session
--       (guest embeds, per-tenant, and the internal super-admin all-tenant session)
--       connects with the SAME DB login role `superset_ro`; the ONLY differentiator
--       is the GUC value the DB_CONNECTION_MUTATOR stamps. A `pg_has_role(current_user,
--       'superset_admin_ro', ...)` gate here would therefore either deny the admin's
--       own all-tenant view (superset_ro is not that role) or require a SECOND
--       physical connection/credential + a mutator URI rewrite — a cross-layer change
--       with real breakage surface, for near-zero gain (see b).
--   (b) The sentinel is UNREACHABLE from the token/embed path already (the mutator
--       only stamps -1 for a native Admin UI session; guest/anon never reach it —
--       superset_config.py::_admin_all_tenant_stamp). The only actor who could set
--       app.tenant_id = -1 directly is a holder of the superset_ro PASSWORD — who can
--       equally `SET app.tenant_id = <any real id>` in a loop and read every tenant
--       regardless of this sentinel. So the real control is superset_ro credential
--       secrecy (Secrets Manager), not the sentinel value.
-- If a dedicated all-tenant DB role is ever introduced, gate it here with
-- `AND pg_has_role(current_user, 'superset_admin_ro', 'MEMBER')` and route the admin
-- session through that role in DB_CONNECTION_MUTATOR.
CREATE OR REPLACE FUNCTION public.is_all_tenant() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT public.current_tenant() = -1
$$;

-- ── Native-id tables (id_enterprise is a real column) — cheap policy ─────────
-- equipments carries id_enterprise natively (and is the dimension the reached-via
-- policies below join through — protect it directly too).
ALTER TABLE equipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipments FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON equipments;
CREATE POLICY tenant_isolation ON equipments
    USING (is_all_tenant() OR id_enterprise = current_tenant());

-- equipment_events (the F3 downtime source — there is NO `downtimes` table) carries
-- id_enterprise natively, BUT on the live analytics DB it is a COMPRESSED TimescaleDB
-- hypertable, and `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` is rejected on
-- columnstore hypertables ("operation not supported on hypertables that have
-- columnstore enabled"). So we enable a native policy CONDITIONALLY: only when the
-- table can actually take one (a plain table, or an uncompressed hypertable).
--   * Live DB (compressed hypertable) → SKIP. bi.downtimes still isolates
--     TRANSITIVELY: it joins equipment_events to the RLS-protected `equipments`
--     dimension and exposes eq.id_enterprise, so only events for the session
--     tenant's equipment surface. Superset's guest-token clause on the view column
--     is the primary embed-path enforcer, as for every other bi.* view.
--   * Plain-table deployments (e.g. the CI isolation-gate fixture, or a future
--     decompressed equipment_events) → enable the native policy too, so the base
--     table is directly protected (and the "every base table has a policy" gate holds).
-- The to_regclass guard keeps this working on a bare Postgres with no TimescaleDB
-- catalog (the timescaledb_information schema simply won't exist there).
DO $$
DECLARE is_columnstore boolean := false;
BEGIN
  IF to_regclass('timescaledb_information.hypertables') IS NOT NULL THEN
    SELECT COALESCE(bool_or(compression_enabled), false) INTO is_columnstore
    FROM timescaledb_information.hypertables
    WHERE hypertable_name = 'equipment_events';
  END IF;
  IF is_columnstore THEN
    RAISE NOTICE 'equipment_events is a compressed hypertable — RLS skipped; bi.downtimes isolates transitively via the equipments join';
  ELSE
    EXECUTE 'ALTER TABLE equipment_events ENABLE ROW LEVEL SECURITY';
    EXECUTE 'ALTER TABLE equipment_events FORCE ROW LEVEL SECURITY';
    EXECUTE 'DROP POLICY IF EXISTS tenant_isolation ON equipment_events';
    EXECUTE 'CREATE POLICY tenant_isolation ON equipment_events USING (is_all_tenant() OR id_enterprise = current_tenant())';
  END IF;
END$$;

-- ── Reached-via-equipments tables (no native id_enterprise) — EXISTS policy ──
-- production_orders_runtime has NO id_enterprise column on F3 (the earlier scaffold
-- assumed one). id_equipment is 100% populated, so derive the tenant via equipments.
ALTER TABLE production_orders_runtime ENABLE ROW LEVEL SECURITY;
ALTER TABLE production_orders_runtime FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON production_orders_runtime;
CREATE POLICY tenant_isolation ON production_orders_runtime
    USING (is_all_tenant() OR EXISTS (
        SELECT 1 FROM equipments e
        WHERE e.id_equipment = production_orders_runtime.id_equipment
          AND e.id_enterprise = current_tenant()));

-- equipment_runtime_shift → equipments for the tenant key.
ALTER TABLE equipment_runtime_shift ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_runtime_shift FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON equipment_runtime_shift;
CREATE POLICY tenant_isolation ON equipment_runtime_shift
    USING (is_all_tenant() OR EXISTS (
        SELECT 1 FROM equipments e
        WHERE e.id_equipment = equipment_runtime_shift.id_equipment
          AND e.id_enterprise = current_tenant()));

-- equipment_runtime_1hour → equipments.
ALTER TABLE equipment_runtime_1hour ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_runtime_1hour FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON equipment_runtime_1hour;
CREATE POLICY tenant_isolation ON equipment_runtime_1hour
    USING (is_all_tenant() OR EXISTS (
        SELECT 1 FROM equipments e
        WHERE e.id_equipment = equipment_runtime_1hour.id_equipment
          AND e.id_enterprise = current_tenant()));

-- ── GAP-view base tables (W3 dashboards) ─────────────────────────────────────
-- equipment_values (source for bi.equipment_speed / bi.live_status /
-- bi.production_by_team) carries id_enterprise natively, but — exactly like
-- equipment_events — it is a COMPRESSED TimescaleDB hypertable on the live DB and
-- rejects `ENABLE ROW LEVEL SECURITY`. Same conditional shape: SKIP on a compressed
-- hypertable (those views isolate TRANSITIVELY via the equipments join, which is why
-- they select eq.id_enterprise, not ev.id_enterprise), enable the native policy on a
-- plain table (the CI fixture) so the "every base table has a rule" guard holds.
DO $$
DECLARE is_columnstore boolean := false;
BEGIN
  IF to_regclass('timescaledb_information.hypertables') IS NOT NULL THEN
    SELECT COALESCE(bool_or(compression_enabled), false) INTO is_columnstore
    FROM timescaledb_information.hypertables
    WHERE hypertable_name = 'equipment_values';
  END IF;
  IF is_columnstore THEN
    RAISE NOTICE 'equipment_values is a compressed hypertable — RLS skipped; bi.equipment_speed/live_status/production_by_team isolate transitively via the equipments join';
  ELSE
    EXECUTE 'ALTER TABLE equipment_values ENABLE ROW LEVEL SECURITY';
    EXECUTE 'ALTER TABLE equipment_values FORCE ROW LEVEL SECURITY';
    EXECUTE 'DROP POLICY IF EXISTS tenant_isolation ON equipment_values';
    EXECUTE 'CREATE POLICY tenant_isolation ON equipment_values USING (public.is_all_tenant() OR id_enterprise = public.current_tenant())';
  END IF;
END$$;

-- production_orders (source for bi.production_orders) carries id_enterprise NATIVELY
-- (unlike production_orders_runtime) → cheap direct policy. Plain table (not a
-- hypertable), so the ENABLE is unconditional.
ALTER TABLE production_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE production_orders FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON production_orders;
CREATE POLICY tenant_isolation ON production_orders
    USING (public.is_all_tenant() OR id_enterprise = public.current_tenant());

-- production_targets (source for bi.production_targets) carries id_enterprise
-- natively → cheap direct policy.
ALTER TABLE production_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE production_targets FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON production_targets;
CREATE POLICY tenant_isolation ON production_targets
    USING (public.is_all_tenant() OR id_enterprise = public.current_tenant());

-- (The F3 downtime source equipment_events is handled above with a native-id
-- policy — there is no `downtimes` table to protect.)

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
