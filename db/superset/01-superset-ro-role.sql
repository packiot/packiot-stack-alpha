-- db/superset/01-superset-ro-role.sql
-- W2 embedded-Superset scaffolding — INERT until the W2 go decision.
-- Apply by hand, staging-first. See db/superset/README.md + docs/plans/w2-embedded-superset.md.
--
-- Creates the CURATED, tenant-safe read surface Superset connects to, wired so
-- the Postgres RLS in 02-tenant-rls.sql is a REAL per-tenant co-enforcer (not the
-- fail-closed no-op the Metabase donor settled for). Three roles, one schema:
--
--   * bi_owner     — NOLOGIN, NOSUPERUSER, **NOBYPASSRLS**. OWNS the bi schema and
--                    every bi.* view. The views are plain (SECURITY DEFINER) views,
--                    so base-table access runs as THIS role. Because bi_owner is
--                    NOBYPASSRLS, the base-table RLS policies in 02 actually bite
--                    when a bi.* view is read — keyed on the session GUC
--                    app.tenant_id (which current_tenant() reads even through a
--                    definer view, since custom GUCs are session-scoped). THIS is
--                    what upgrades Postgres RLS from "fail-closed backstop only" to
--                    a genuine co-enforcer.
--   * superset_ro  — the LOGIN role Superset registers as a "database". SELECT-only
--                    on the bi VIEWS, and NOTHING on the raw ~300-table schema
--                    (definer's rights reach the base tables via bi_owner, so
--                    superset_ro needs no base-table grant — the raw schema stays
--                    fully dark). NOBYPASSRLS. Password is set AT APPLY from Secrets
--                    Manager — never a literal in this file.
--
-- WHY VIEWS, NOT BASE TABLES: expose a small, semantically clean surface (OEE
-- aggregates + dimensions), drop noisy/secret columns, present a stable contract,
-- and GUARANTEE every exposed row carries id_enterprise so both isolation layers
-- (Superset RLS on the id_enterprise column + Postgres RLS via the GUC) have a key.
--
-- WHY A DEFINER VIEW OWNED BY A NOBYPASSRLS ROLE (not security_invoker): a
-- security_invoker view would force us to GRANT superset_ro SELECT on the raw base
-- tables (invoker's rights), widening the dark surface. The definer + NOBYPASSRLS
-- owner keeps superset_ro grant-less on base tables AND makes RLS bite. No PG15
-- dependency (works on any PG >= 9.5).
--
-- Idempotent: guarded role creation + CREATE OR REPLACE views + ALTER OWNER.

-- ── 1. Roles ─────────────────────────────────────────────────────────────────
-- bi_owner: owns the curated surface, is subject to RLS (NOBYPASSRLS). NOLOGIN —
-- nothing ever connects AS bi_owner; it only lends its base-table grants to the
-- definer views.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bi_owner') THEN
    CREATE ROLE bi_owner NOLOGIN;
  END IF;
END$$;
ALTER ROLE bi_owner NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT;

-- superset_ro: the login role Superset uses. Created WITHOUT a password literal —
-- the Metabase donor's `CREATE ROLE metabase_ro ... PASSWORD 'CHANGE_ME_AT_APPLY'`
-- is exactly the anti-pattern to avoid (a placeholder secret that gets committed
-- and forgotten). Create it NOLOGIN here; grant LOGIN + the real password AT APPLY
-- from Secrets Manager (packiot/<env>/app key superset_db_ro_password), e.g.:
--
--   psql -v pw="$SUPERSET_DB_RO_PASSWORD" \
--     -c "ALTER ROLE superset_ro LOGIN PASSWORD :'pw';"
--
-- (:'pw' is a psql variable — the secret is passed on the command line from the
-- environment, never stored in this file.)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superset_ro') THEN
    CREATE ROLE superset_ro NOLOGIN;
  END IF;
END$$;
-- Never let this role escalate or bypass RLS. Explicitly no CREATEDB/CREATEROLE/
-- SUPERUSER and — load-bearing for tenant isolation — NOBYPASSRLS.
ALTER ROLE superset_ro NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT;

-- ── 2. Curated bi schema, OWNED BY bi_owner ──────────────────────────────────
CREATE SCHEMA IF NOT EXISTS bi AUTHORIZATION bi_owner;

-- bi_owner needs SELECT on the base tables the views read (definer's rights). This
-- is the ONLY base-table grant in the design, and it goes to the NOLOGIN owner —
-- superset_ro still cannot touch base tables directly. RLS (02) filters what these
-- grants can return per the session GUC.
GRANT USAGE ON SCHEMA public TO bi_owner;
GRANT SELECT ON
    equipments,
    equipment_runtime_shift,
    equipment_runtime_1hour,
    production_orders_runtime,
    downtimes
  TO bi_owner;

-- superset_ro may enter the bi schema and read its views — nothing else.
GRANT USAGE ON SCHEMA bi TO superset_ro;

-- ── 3. Curated views (every row carries id_enterprise) ───────────────────────
-- Curated OEE aggregate — shift grain. Every row carries id_enterprise (via the
-- equipments dimension) so both isolation layers have a tenant key.
CREATE OR REPLACE VIEW bi.oee_shift AS
SELECT
    eq.id_enterprise,
    rs.id_equipment,
    eq.nm_equipment,
    rs.id_shift,
    rs.begin_time,
    rs.end_time,
    rs.oee,
    rs.oee_availability,
    rs.oee_performance,
    rs.oee_quality,
    rs.count,
    rs.gross,
    rs.running_time
FROM equipment_runtime_shift rs
JOIN equipments eq ON eq.id_equipment = rs.id_equipment;  -- id_enterprise source

-- Curated OEE aggregate — hourly grain (the workhorse for trend charts).
CREATE OR REPLACE VIEW bi.oee_hourly AS
SELECT
    eq.id_enterprise,
    rh.id_equipment,
    eq.nm_equipment,
    rh.bucket,
    rh.oee,
    rh.oee_availability,
    rh.oee_performance,
    rh.oee_quality,
    rh.count,
    rh.gross,
    rh.running_time
FROM equipment_runtime_1hour rh
JOIN equipments eq ON eq.id_equipment = rh.id_equipment;

-- Production-order OEE (one row per PO run). id_enterprise is native here.
CREATE OR REPLACE VIEW bi.production_order_runtime AS
SELECT
    por.id_enterprise,
    por.id_production_order,
    por.id_equipment,
    por.oee,
    por.oee_availability,
    por.oee_performance,
    por.oee_quality,
    por.count,
    por.gross,
    por.begin_time,
    por.end_time
FROM production_orders_runtime por;

-- Downtimes. Tenant key via the equipments dimension.
CREATE OR REPLACE VIEW bi.downtimes AS
SELECT
    eq.id_enterprise,
    d.id_downtime,
    d.id_equipment,
    eq.nm_equipment,
    d.id_downtime_reason,
    d.begin_time,
    d.end_time,
    d.duration
FROM downtimes d
JOIN equipments eq ON eq.id_equipment = d.id_equipment;

-- Equipment dimension (for joins/filters in the authoring UI). Active only.
CREATE OR REPLACE VIEW bi.equipments AS
SELECT
    id_enterprise,
    id_equipment,
    nm_equipment,
    tp_equipment,
    id_area,
    lead_machine
FROM equipments
WHERE active;

-- ── 4. Own + grant ───────────────────────────────────────────────────────────
-- Make bi_owner the OWNER of every bi.* view. This is what makes them run their
-- base-table access as bi_owner (NOBYPASSRLS) → RLS bites. (CREATE VIEW above ran
-- as the applying superuser, so the views are superuser-owned until this ALTER —
-- a superuser owner would BYPASS RLS and silently defeat the co-enforcer, so this
-- re-own step is NOT optional.)
DO $$
DECLARE v record;
BEGIN
  FOR v IN
    SELECT c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'bi' AND c.relkind = 'v'
  LOOP
    EXECUTE format('ALTER VIEW bi.%I OWNER TO bi_owner', v.relname);
  END LOOP;
END$$;

-- Grant SELECT on the curated surface to superset_ro (and default it for future
-- bi.* views someone adds later — but see the CI guard: a new bi.* view MUST
-- expose id_enterprise AND its base tables MUST have an RLS policy, or the
-- 2-tenant isolation gate fails).
GRANT SELECT ON ALL TABLES IN SCHEMA bi TO superset_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE bi_owner IN SCHEMA bi GRANT SELECT ON TABLES TO superset_ro;

-- NOTE (deliberately NOT exposed): equipment_values raw time-series, packml_register,
-- users, enterprises.api_key/secrets columns, shadow_*/internal signal-quality
-- columns, and everything outside `bi`. superset_ro has NO base-table grant at all —
-- only bi_owner does, and only on the five curated tables above. The raw schema is dark.
