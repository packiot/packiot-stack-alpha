-- db/superset/01-superset-ro-role.sql
-- W2 embedded-Superset scaffolding — INERT until the W2 go decision.
-- Apply by hand, staging-first. See db/superset/README.md + docs/plans/w2-embedded-superset.md.
--
-- (Ported from db/metabase/01-metabase-ro-role.sql — the curated read surface is
--  BI-tool-agnostic; only the login role name changes metabase_ro → superset_ro.)
--
-- Creates:
--   * a least-privilege login role `superset_ro` (SELECT-only, no DDL, no writes),
--   * a `bi` schema of CURATED, tenant-safe VIEWS that Superset connects to.
--
-- WHY VIEWS, NOT BASE TABLES: self-service authoring should expose a small,
-- semantically clean surface (the OEE aggregates + dimensions), NOT the whole
-- 300-table F3 schema. The view layer is also where we (a) drop noisy signal /
-- internal columns, (b) present a stable contract independent of base-table
-- churn, and (c) guarantee every exposed row carries `id_enterprise` so both the
-- Superset Row-Level-Security rule (guest-token AND role-bound) and the Postgres
-- RLS backstop have a column to key on.
--
-- Idempotent: guarded role creation + CREATE OR REPLACE views.

-- ── 1. Read-only login role ──────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superset_ro') THEN
    -- Password is a placeholder; set the real one from Secrets Manager
    -- (packiot/<env>/app key superset_db_ro_password) at apply time, e.g.:
    --   ALTER ROLE superset_ro WITH PASSWORD :'pw';
    CREATE ROLE superset_ro WITH LOGIN PASSWORD 'CHANGE_ME_AT_APPLY';
  END IF;
END$$;

-- Never let this role escalate. Explicitly no CREATEDB/CREATEROLE/SUPERUSER.
ALTER ROLE superset_ro NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;

-- ── 2. Curated BI schema ──────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS bi AUTHORIZATION CURRENT_USER;

-- superset_ro may look inside `bi` and read its views, and read the base tables
-- ONLY through the views (the views run as their owner = the applying superuser,
-- so superset_ro needs no direct base-table grant — least privilege).
GRANT USAGE ON SCHEMA bi TO superset_ro;

-- Curated OEE aggregate — shift grain. Every row carries id_enterprise (resolved
-- via the equipments dimension) so both the Superset RLS rule and the Postgres
-- RLS backstop have a tenant key. Trim to the columns a factory analyst builds on.
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

-- Downtimes (justified + raw). Tenant key via the equipments dimension.
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

-- Grant SELECT on the curated surface (and default it for future bi.* views).
GRANT SELECT ON ALL TABLES IN SCHEMA bi TO superset_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA bi GRANT SELECT ON TABLES TO superset_ro;

-- NOTE (deliberately NOT exposed): equipment_values raw time-series (too large /
-- high-cardinality for ad-hoc self-service — offer a pre-bucketed bi.* rollup
-- instead if a customer asks), packml_register, users, api_key/secrets columns,
-- shadow_* / internal signal-quality columns, and everything outside `bi`.
-- Only `bi` is registered as a Superset dataset source; the raw schema stays dark.
