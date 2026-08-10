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
-- NOTE (schema reconciliation, 2026-08): the F3 analytics schema has NO `downtimes`
-- table — the real downtime source is `equipment_events` (which carries id_enterprise
-- natively). The five base tables the bi.* views read on F3 are:
GRANT SELECT ON
    equipments,
    equipment_runtime_shift,
    equipment_runtime_1hour,
    production_orders_runtime,
    equipment_events
  TO bi_owner;

-- superset_ro may enter the bi schema and read its views — nothing else.
GRANT USAGE ON SCHEMA bi TO superset_ro;

-- ── 3. Curated views (every row carries id_enterprise) ───────────────────────
-- SCHEMA-RECONCILED to the live F3 analytics schema (2026-08): OEE ratio columns
-- are oee_a/oee_p/oee_q (NOT oee_availability/…); time bounds are ts_value/ts_end
-- (NOT begin_time/end_time); counts are gross/net (there is NO `count` column);
-- equipment_runtime_1hour buckets on ts_value (NOT `bucket`); production_orders_runtime
-- has NO id_enterprise (derived via the equipments dimension) and bounds its run with
-- runtime_timerange (a tstzrange); the downtimes table does not exist (source is
-- equipment_events). Every view still GUARANTEES an id_enterprise column (the RLS key).

-- Curated OEE aggregate — shift grain. Every row carries id_enterprise (via the
-- equipments dimension) so both isolation layers have a tenant key.
--
-- ⚠ DATA-CORRECTNESS FILTER (audit F1/F2/F3, 2026-08-10). The shift-calendar
-- pre-expands FUTURE, zero-activity buckets (equipment_runtime_shift ranges a
-- MONTH into the future — 5 518 of 7 750 rows). The KPI charts AVG(oee) with no
-- time filter, so those empty buckets dragged a real ~60% OEE down to ~2%. Two
-- guards make every consumer honest without per-chart config:
--   • ts_value <= now()   — future calendar buckets can never leak in (F3).
--   • running_time > 0     — idle/empty shifts don't dilute the ratio (F1/F2).
-- Effect: the OEE gauge + A/P/Q big numbers read the true running average
-- (~0.59 / A 0.71 / P 0.60 / Q 0.93) instead of a misleading ~0.02.
CREATE OR REPLACE VIEW bi.oee_shift AS
SELECT
    eq.id_enterprise,
    rs.id_equipment,
    eq.nm_equipment,
    rs.id_shift,
    rs.cd_shift,
    rs.ts_value,
    rs.ts_end,
    rs.oee,
    rs.oee_a,
    rs.oee_p,
    rs.oee_q,
    rs.gross,
    rs.net,
    rs.running_time
FROM equipment_runtime_shift rs
JOIN equipments eq ON eq.id_equipment = rs.id_equipment  -- id_enterprise source
WHERE rs.ts_value <= now()      -- F3: never expose future calendar buckets
  AND rs.running_time > 0;      -- F1/F2: only shifts that actually operated

-- Curated OEE aggregate — hourly grain (the workhorse for trend charts).
-- Same F1/F2/F3 activity+future guard as bi.oee_shift.
CREATE OR REPLACE VIEW bi.oee_hourly AS
SELECT
    eq.id_enterprise,
    rh.id_equipment,
    eq.nm_equipment,
    rh.ts_value,
    rh.oee,
    rh.oee_a,
    rh.oee_p,
    rh.oee_q,
    rh.gross,
    rh.net,
    rh.running_time
FROM equipment_runtime_1hour rh
JOIN equipments eq ON eq.id_equipment = rh.id_equipment
WHERE rh.ts_value <= now()      -- F3: never expose future calendar buckets
  AND rh.running_time > 0;      -- F1/F2: only hours that actually operated

-- Production-order OEE (one row per PO run). production_orders_runtime has NO
-- id_enterprise column on F3, so the tenant key is derived via the equipments
-- dimension (id_equipment is 100% populated). The run window comes from the
-- runtime_timerange tstzrange (lower/upper bounds).
CREATE OR REPLACE VIEW bi.production_order_runtime AS
SELECT
    eq.id_enterprise,                       -- derived tenant key (no native column)
    por.id_production_order,
    por.id_equipment,
    por.oee,
    por.oee_a,
    por.oee_p,
    por.oee_q,
    por.gross_production,
    por.net_production,
    por.running_time,
    lower(por.runtime_timerange) AS ts_start,
    upper(por.runtime_timerange) AS ts_end
FROM production_orders_runtime por
JOIN equipments eq ON eq.id_equipment = por.id_equipment;  -- id_enterprise source

-- Downtimes. The F3 schema has no `downtimes` table — the real downtime source is
-- equipment_events (machine status/downtime events). equipment_events is a
-- COMPRESSED TimescaleDB hypertable, so it cannot take an RLS policy directly
-- (ENABLE ROW LEVEL SECURITY errors on columnstore hypertables). Its tenant key is
-- therefore taken from the equipments dimension (eq.id_enterprise) — the JOIN to
-- the RLS-protected equipments table is what co-enforces isolation on this view
-- (02-tenant-rls.sql explains the transitive path). Every joined row belongs to the
-- session tenant's equipment, so no cross-tenant event can surface.
CREATE OR REPLACE VIEW bi.downtimes AS
SELECT
    eq.id_enterprise,               -- tenant key from the RLS-protected dimension
    ev.id_equipment_event AS id_downtime,
    ev.id_equipment,
    eq.nm_equipment,
    ev.cd_category,
    ev.cd_subcategory,
    ev.desc_category,
    ev.desc_subcategory,
    ev.ts_event AS ts_value,
    ev.ts_end,
    ev.duration,
    ev.planned_downtime,
    ev.change_over
FROM equipment_events ev
JOIN equipments eq ON eq.id_equipment = ev.id_equipment;

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
