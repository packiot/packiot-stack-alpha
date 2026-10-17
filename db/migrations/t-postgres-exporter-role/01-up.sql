-- t-postgres-exporter-role — the least-privilege login postgres-exporter runs under (2026-10-16).
--
-- WHY
-- Production had no database telemetry and no path from ops.data_invariant_result to an alert. The fix adds
-- postgres-exporter to compose.production.yml; staging's exporter logs in as the admin (${POSTGRES_USER}),
-- which production must not repeat: an exporter needs to READ statistics, never to write or own anything.
--
-- WHAT IT NEEDS (monitoring/postgres-exporter/queries.yaml + the exporter's built-in collectors):
--   * pg_monitor (predefined role: pg_read_all_stats + pg_read_all_settings + pg_stat_scan_tables). Without it
--     pg_stat_activity hides the state/query of other roles' backends, so pg_activity_by_state and
--     pg_longest_query under-report. pg_stat_database, pg_locks and pg_class sizes need nothing extra.
--     INHERIT is required for the membership to take effect; it is the role's only membership (verify V2).
--   * USAGE on schemas ops + silver and SELECT on exactly the relations the custom queries read (list below).
--     ops.data_invariant_result/latest/timing are already SELECT-to-PUBLIC (t-data-invariants*), but the ops
--     schema itself is not, so without USAGE the invariant series would silently be absent.
--   * CONNECT on this database. Nothing else: no DML, no DDL, no TEMP, no functions.
--   * read-only session (default_transaction_read_only = on) and a 30 s statement_timeout, so a slow catalog
--     query can never hold a backend for long.
-- Not granted: pg_cron (cron.job_run_details lives in the `postgres` database and pg_cron shows a non-owner only
-- its own jobs), so pg_cron_job emits nothing for this login. No production alert reads it.
--
-- RLS: NOBYPASSRLS, no app.tenant_id default. None of the granted relations is FORCE-RLS today; if one becomes
-- so, its query returns no rows (fail closed) rather than leaking.
--
-- PASSWORD. Not here. LOGIN with a NULL password until the host sets it from Secrets Manager
-- packiot/<env>/postgres-exporter-db-creds:
--   scripts/ops/provision-db-role.py --service postgres-exporter --env production --db-name packiot \
--       --db-host 10.20.10.89 --admin-host 10.20.10.89
-- and the next production deploy writes the password file the exporter reads (deploy-production.yml).
--
-- WHERE TO APPLY: production (packiot). Also safe on staging (packiot_analytics) — absent relations are skipped
-- with a NOTICE — but staging's exporter is not switched to it by this change.
-- Idempotent: guarded CREATE, ALTER re-asserts attributes, GRANTs are repeatable. Run as postgres.
-- Reversible: rollback.sql.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres_exporter') THEN
    CREATE ROLE postgres_exporter LOGIN;
  END IF;
END $$;

ALTER ROLE postgres_exporter LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION INHERIT
  CONNECTION LIMIT 5;   -- the exporter holds 1–2 connections; 5 covers a rolling recreate
ALTER ROLE postgres_exporter SET default_transaction_read_only = on;
ALTER ROLE postgres_exporter SET statement_timeout = '30s';

COMMENT ON ROLE postgres_exporter IS
  'postgres-exporter login (t-postgres-exporter-role): pg_monitor + SELECT on the ops/silver relations of '
  'monitoring/postgres-exporter/queries.yaml, read-only by default. NOBYPASSRLS. Password: '
  'packiot/<env>/postgres-exporter-db-creds.';

GRANT pg_monitor TO postgres_exporter;

DO $$
DECLARE
  -- = the relations monitoring/postgres-exporter/queries.yaml reads outside pg_catalog
  rels text[] := ARRAY[
    'ops.data_invariant_result', 'ops.data_invariant_latest', 'ops.data_invariant_timing',
    'ops.retention_drift', 'ops.retention_run',
    'ops.cold_export', 'ops.partition_drop_blocked',
    'silver.rollup_invalidation',
    'silver.equipment_categorical_1min', 'silver.agg_equipment_values_1min',
    'silver.equipment_categorical_1hour', 'silver.agg_equipment_values_1hour'];
  r text;
  s text;
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO postgres_exporter', current_database());
  FOREACH s IN ARRAY ARRAY['ops', 'silver'] LOOP
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = s) THEN
      EXECUTE format('GRANT USAGE ON SCHEMA %I TO postgres_exporter', s);
    ELSE
      RAISE NOTICE 'schema % absent here — skipped', s;
    END IF;
  END LOOP;
  FOREACH r IN ARRAY rels LOOP
    IF to_regclass(r) IS NOT NULL THEN
      EXECUTE format('GRANT SELECT ON %s TO postgres_exporter', r);
    ELSE
      RAISE NOTICE '% absent here — skipped', r;
    END IF;
  END LOOP;
END $$;

COMMIT;
