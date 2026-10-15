-- t-prod-reflector-roles — the two least-privilege logins of prod-reflector (ADR-0064, 2026-10-15).
--
-- WHY
-- After a tenant's production go-live, staging keeps that tenant as a read-only MIRROR of production
-- (services/analytics-sync/cmd/prod-reflector). The reflector reads the tenant's rows in PRODUCTION and converges
-- STAGING to them every minute. Two databases, two logins, each with exactly what its side needs:
--
--   prod_reflector_ro  PRODUCTION, the source. SELECT on the reflected tables (and their sequences, read for the
--                      MR4 id-block invariant), nothing else: no DML, no DDL, default_transaction_read_only = on.
--                      Its password lives in Secrets Manager packiot/production/prod-reflector-ro-db-creds; the
--                      staging app role may read that ONE secret (terraform/staging, ADR-0064 §6).
--   prod_reflector     STAGING, the destination. SELECT/INSERT/UPDATE/DELETE on the reflected tables, EXCEPT:
--                        * core.enterprises: UPDATE on every column but api_key (staging keeps its own key: the
--                          role cannot change it even by a bug);
--                        * bronze.box_scans: SELECT/INSERT only (append-only, like the table's own trigger).
--                      Plus: EXECUTE on the serving refresh (it re-resolves serving.downtime_events_resolved for the
--                      changed days) and DML on that table; INSERT on ops.data_invariant_result (MR1–MR5); USAGE on
--                      the reflected tables' sequences (pg_sequences.last_value for MR4; serial defaults of a column
--                      only staging has).
--
-- The table list is services/analytics-sync/internal/mirror/spec.go `Reflected`, verbatim and in the same order
-- (TestMigrationGrantsMatchSpec fails when they drift). Tables absent in this database are skipped with a NOTICE,
-- so the same file applies to staging and to production.
--
-- RLS: both roles are NOBYPASSRLS with NO app.tenant_id default. Each connection stamps app.tenant_id = <the
-- mirrored enterprise> at connect (cmd/prod-reflector). Without the stamp a FORCE-RLS table reads EMPTY — on the
-- production side the reflector's empty_source guard then refuses to delete anything on staging.
--
-- WHERE TO APPLY
--   staging    (packiot_analytics): creates both roles. prod_reflector_ro stays without a password on staging
--              (it is the role production inherits through the go-live transplant: build.py copies roles + grants).
--   production (packiot, after the go-live swap): only needed if the transplant ran before this migration was on
--              staging — the file is idempotent; prod_reflector there stays without a password (never used).
-- Then, per role, on the host of its database: scripts/ops/provision-db-role.py (--service prod-reflector on the
-- staging app host; --service prod-reflector-ro --env production on the production app host).
--
-- Idempotent (guarded CREATE ROLE, ALTER ROLE re-asserts, GRANTs repeatable). Run as postgres. Reversible: rollback.sql.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prod_reflector') THEN CREATE ROLE prod_reflector LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prod_reflector_ro') THEN CREATE ROLE prod_reflector_ro LOGIN; END IF;
END $$;

ALTER ROLE prod_reflector LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT CONNECTION LIMIT 8;
ALTER ROLE prod_reflector RESET app.tenant_id;      -- stamped per connection
ALTER ROLE prod_reflector_ro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT CONNECTION LIMIT 6;
ALTER ROLE prod_reflector_ro RESET app.tenant_id;   -- stamped per connection
ALTER ROLE prod_reflector_ro SET default_transaction_read_only = on;
ALTER ROLE prod_reflector_ro SET statement_timeout = '120s';

COMMENT ON ROLE prod_reflector IS
  'prod-reflector STAGING login (t-prod-reflector-roles, ADR-0064): DML on the reflected tables of a mirrored tenant '
  '(no UPDATE of core.enterprises.api_key; box_scans insert-only), serving refresh, MR invariant rows. NOBYPASSRLS, '
  'app.tenant_id stamped per connection. Password: packiot/staging/prod-reflector-db-creds.';
COMMENT ON ROLE prod_reflector_ro IS
  'prod-reflector PRODUCTION login (t-prod-reflector-roles, ADR-0064): SELECT on the reflected tables and their '
  'sequences, read-only by default. NOBYPASSRLS, app.tenant_id stamped per connection. Password: '
  'packiot/production/prod-reflector-ro-db-creds (readable by the staging app role).';

DO $$ BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO prod_reflector, prod_reflector_ro', current_database());
END $$;

DO $$
DECLARE
  -- = internal/mirror/spec.go Reflected (order kept)
  reflected text[] := ARRAY[
    'core.enterprises', 'core.sites', 'core.areas', 'core.equipments', 'core.topic_routing', 'core.device_bindings',
    'core.client_descriptors', 'core.box_production_bridges', 'core.downtime_reason', 'core.scrap_reason',
    'core.equipment_downtime_reason', 'core.equipment_scrap_reason', 'core.shifts', 'core.shift_hours',
    'core.shifts_exception_period', 'core.teams', 'core.product_families', 'core.products', 'core.clients',
    'config.labels', 'config.label_formats', 'config.dashboard_config', 'config.tenant_translations',
    'config.equipment_out_of_service', 'config.oee_targets', 'config.production_targets', 'config.scrap_targets',
    'identity.user_roles', 'identity.users', 'core.production_orders', 'core.po_number_corrections',
    'gold.production_orders_runtime', 'gold.po_box_counter', 'silver.equipment_events', 'silver.equipment_events_man',
    'silver.equipment_events_low_speed', 'bronze.box_scans', 'bronze.sample_boxes', 'bronze.scanned_boxes',
    'gold.equipment_oee_hourly', 'gold.equipment_oee_shift', 'gold.equipment_oee_daily', 'gold.equipment_oee_weekly',
    'gold.equipment_oee_monthly', 'gold.equipment_oee_shift_weekly', 'gold.equipment_oee_shift_monthly',
    'gold.area_oee_daily', 'gold.area_oee_shift', 'gold.site_oee_shift', 'silver.data_quality_event',
    'silver.equipment_live_day', 'silver.equipment_live_shift', 'silver.equipment_live_job',
    'silver.equipment_live_month', 'silver.area_live_day', 'silver.area_live_shift'];
  t text;
  cols text;
  s record;
  sch text;
BEGIN
  FOREACH sch IN ARRAY ARRAY['core', 'config', 'identity', 'gold', 'silver', 'bronze', 'serving', 'ops', 'public'] LOOP
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sch) THEN
      EXECUTE format('GRANT USAGE ON SCHEMA %I TO prod_reflector, prod_reflector_ro', sch);
    END IF;
  END LOOP;
  FOREACH t IN ARRAY reflected LOOP
    IF to_regclass(t) IS NULL THEN
      RAISE NOTICE 't-prod-reflector-roles: % absent in this database — skipped', t;
      CONTINUE;
    END IF;
    EXECUTE format('GRANT SELECT ON %s TO prod_reflector_ro', t);
    IF t = 'core.enterprises' THEN
      SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols
        FROM pg_attribute WHERE attrelid = 'core.enterprises'::regclass AND attnum > 0 AND NOT attisdropped
         AND attname <> 'api_key' AND attgenerated = '';
      EXECUTE 'GRANT SELECT, INSERT, DELETE ON core.enterprises TO prod_reflector';
      EXECUTE format('GRANT UPDATE (%s) ON core.enterprises TO prod_reflector', cols);
    ELSIF t = 'bronze.box_scans' THEN
      EXECUTE format('GRANT SELECT, INSERT ON %s TO prod_reflector', t);
    ELSE
      EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %s TO prod_reflector', t);
    END IF;
    -- sequences owned by the table (serial / identity)
    FOR s IN SELECT sc.oid::regclass AS seq
               FROM pg_depend d JOIN pg_class sc ON sc.oid = d.objid AND sc.relkind = 'S'
              WHERE d.refobjid = t::regclass AND d.deptype IN ('a', 'i') LOOP
      EXECUTE format('GRANT SELECT ON SEQUENCE %s TO prod_reflector_ro', s.seq);
      EXECUTE format('GRANT USAGE ON SEQUENCE %s TO prod_reflector', s.seq);
    END LOOP;
  END LOOP;

  -- trigger production_orders_po_number (every PO INSERT/UPDATE) may nextval this one (not owned by a column)
  IF to_regclass('core.production_orders_internal_id_order_seq') IS NOT NULL THEN
    EXECUTE 'GRANT USAGE ON SEQUENCE core.production_orders_internal_id_order_seq TO prod_reflector';
  END IF;
  -- serving.refresh_downtime_events_resolved (INVOKER): delete range + re-insert, joins the reflected tables above
  IF to_regclass('serving.downtime_events_resolved') IS NOT NULL THEN
    EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON serving.downtime_events_resolved TO prod_reflector';
  END IF;
  IF to_regprocedure('serving.refresh_downtime_events_resolved(timestamptz, timestamptz)') IS NOT NULL THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION serving.refresh_downtime_events_resolved(timestamptz, timestamptz) TO prod_reflector';
  END IF;
  -- MR1–MR5 rows (t-data-invariants)
  IF to_regclass('ops.data_invariant_result') IS NOT NULL THEN
    EXECUTE 'GRANT INSERT ON ops.data_invariant_result TO prod_reflector';
  END IF;
  -- RLS policy helpers + defaults the written tables call (explicit: never rely on PUBLIC EXECUTE)
  IF to_regprocedure('public.current_tenant()') IS NOT NULL THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.current_tenant() TO prod_reflector, prod_reflector_ro';
  END IF;
  IF to_regprocedure('public.is_all_tenant()') IS NOT NULL THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.is_all_tenant() TO prod_reflector, prod_reflector_ro';
  END IF;
  IF to_regprocedure('core.uuidv7(timestamptz)') IS NOT NULL THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION core.uuidv7(timestamptz) TO prod_reflector';
  END IF;
END $$;

COMMIT;
