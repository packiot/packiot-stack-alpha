-- t-stream-engine-role — the least-privilege login stream-engine (oeecloud-worker) runs under (2026-10-14).
--
-- WHY
-- stream-engine connected to packiot_analytics as ${POSTGRES_USER} (postgres: SUPERUSER, BYPASSRLS),
-- with env_file: [.env] (every secret on the host in its environment). It is the OEE engine: it ingests
-- every tenant's SparkPlug metrics from RabbitMQ and runs the rollup / events / UNS / report loops. A
-- bug or a compromised dependency in it could DROP, TRUNCATE, ALTER or read anything on the cluster.
--
-- WHAT IT ACTUALLY NEEDS (the full statement inventory is in services/stream-engine/README.md
-- § Database role; nothing below needs ownership):
--   * DML only: SELECT on its inputs; INSERT / UPDATE (upserts) on its outputs; DELETE only where a
--     loop rewrites a window (silver.equipment_events{,_cpac_shadow} event deriver, customer_reports.shift).
--   * No DDL on persistent objects, no TRUNCATE, no COPY, no cagg refresh, no compress/decompress, no
--     jobs API, no SET ROLE, no session_replication_role (all grep-confirmed absent).
--   * TEMP on the database: rollup hour/day/shift/backfill build ON COMMIT DROP temp tables (+ index +
--     ANALYZE on them, which the creator owns).
--   * USAGE on the sequences behind its serial INSERT targets (identity columns need none).
--   * EXECUTE on the INVOKER engine functions it calls (public.piot_*, serving.data_sync/report_shift,
--     core.try_int4/8, the RLS helpers); none is SECURITY DEFINER.
--   * Session GUCs it sets itself are user-settable: statement_timeout, search_path,
--     timescaledb.max_tuples_decompressed_per_dml_transaction (SET LOCAL).
--   * DML on compressed hypertable chunks needs only the hypertable's privileges (TimescaleDB
--     propagates GRANTs to chunks).
--   * _timescaledb_functions.start_background_workers() at boot is SUPERUSER-ONLY and load-bearing (the
--     TimescaleDB launcher has failed to start packiot_analytics' scheduler before, leaving the cagg
--     refresh policies dormant). The one owner-level need, so it gets the narrowest possible door: the
--     SECURITY DEFINER wrapper public.ensure_timescaledb_workers() below (owned by the migration's
--     superuser, no arguments, pinned search_path, does exactly that call, EXECUTE revoked from PUBLIC
--     and granted to stream_engine only). The worker calls it when it is not a superuser.
--
-- RLS. The engine is CROSS-TENANT by design (every loop walks all enterprises; ingest writes any
-- tenant). FORCE RLS tables it touches: core.equipments, core.production_orders, core.topic_routing
-- (via the security_invoker core.packml_register view), config.production_targets,
-- config.equipment_out_of_service, gold.production_orders_runtime, gold.equipment_oee_shift,
-- gold.equipment_oee_hourly, silver.plc_link_minutes. Instead of BYPASSRLS the role is NOBYPASSRLS
-- with the role-level default app.tenant_id = '-1' (the all-tenant sentinel: is_all_tenant() = true),
-- the same mechanism as histgw_ro. Effect: identical reach today, but every policy is still
-- evaluated, so a policy that does not grant the sentinel fails closed for the engine instead of
-- being silently skipped, and the cross-tenant grant is one visible, revocable setting.
--
-- PASSWORD. Not here. LOGIN with a NULL password until the host sets it from Secrets Manager
-- packiot/<env>/stream-engine-db-creds (services/stream-engine/README.md § Provisioning the DB role).
--
-- Idempotent: guarded CREATE, ALTER re-asserts attributes, GRANTs are repeatable.
-- Reversible: rollback.sql (point stream-engine back at its old login first).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stream_engine') THEN
    CREATE ROLE stream_engine LOGIN;
  END IF;
END $$;

ALTER ROLE stream_engine LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT
  CONNECTION LIMIT 40;   -- main pool 5 + analytics pool 15 + provision conn; 40 covers a rolling recreate
ALTER ROLE stream_engine SET app.tenant_id = '-1';   -- cross-tenant engine (see RLS above)

COMMENT ON ROLE stream_engine IS
  'stream-engine OEE engine (t-stream-engine-role). Table-level DML on its silver/gold/bronze/core/config/'
  'customer_reports/identity tables, TEMP, sequence USAGE, EXECUTE on INVOKER engine functions; no DDL, '
  'no TRUNCATE. NOBYPASSRLS with role default app.tenant_id=-1 (cross-tenant). Password from Secrets '
  'Manager packiot/<env>/stream-engine-db-creds, set on the host.';

DO $$ BEGIN
  EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO stream_engine', current_database());
END $$;

GRANT USAGE ON SCHEMA core, config, silver, gold, bronze, identity, serving, customer_reports, public
  TO stream_engine;

-- ── inputs (read-only) ────────────────────────────────────────────────────────────────────────────
GRANT SELECT ON
  core.enterprises, core.sites, core.areas, core.shifts, core.shift_hours, core.shifts_exception_period,
  core.client_descriptors, core.box_production_bridges, core.downtime_reason,
  core.equipment_downtime_reason, core.equipment_validation_shift,
  config.label_formats,
  silver.equipment_categorical_1min, silver.equipment_categorical_1hour,
  silver.agg_equipment_values_1min, silver.agg_equipment_values_1hour,
  -- silver.ca_equipment_boxes_1s dropped by t-drop-ca-equipment-boxes-1s (ADR-0063 A1, 2026-10-14); its
  -- rollback re-grants it. Listing it here failed every re-run of this file (dev seed boot, dev slices).
  silver.ca_discrete_changes_1s,
  silver.plc_endpoint_equipment, silver.plc_link_minutes
TO stream_engine;
GRANT SELECT ON config.production_targets, config.equipment_out_of_service TO stream_engine;
-- read by trigger production_orders_po_number on every core.production_orders INSERT/UPDATE (PO control,
-- recalc, stranded sweep), which runs as the invoker
GRANT SELECT ON core.po_number_corrections TO stream_engine;

-- ── read + write ──────────────────────────────────────────────────────────────────────────────────
-- dimension writes: inferspeed (equipments), PO control (production_orders, products, families,
-- clients), 30700 topology (topic_routing through the packml_register view)
GRANT SELECT, UPDATE         ON core.equipments                                     TO stream_engine;
GRANT SELECT, UPDATE         ON core.topic_routing, core.packml_register            TO stream_engine;
GRANT SELECT, INSERT, UPDATE ON core.production_orders, core.products,
                                core.product_families, core.clients                 TO stream_engine;
-- silver facts and live tables (upserts)
GRANT SELECT, INSERT, UPDATE ON
  silver.equipment_values, silver.equipment_events_man, silver.data_quality_event,
  silver.equipment_live_day, silver.equipment_live_job, silver.equipment_live_month,
  silver.equipment_live_shift, silver.equipment_live_metrics,
  silver.area_live_day, silver.area_live_shift
TO stream_engine;
GRANT SELECT, INSERT, UPDATE, DELETE ON silver.equipment_events, silver.equipment_events_cpac_shadow
  TO stream_engine;
-- gold grains (provision INSERT … ON CONFLICT DO NOTHING, rollup UPDATE)
GRANT SELECT, INSERT, UPDATE ON
  gold.equipment_oee_hourly, gold.equipment_oee_daily, gold.equipment_oee_weekly,
  gold.equipment_oee_monthly, gold.equipment_oee_shift, gold.equipment_oee_shift_weekly,
  gold.equipment_oee_shift_monthly, gold.area_oee_daily, gold.area_oee_shift, gold.site_oee_shift,
  gold.production_orders_runtime
TO stream_engine;
-- bronze raw append (BRONZE_RAW_APPEND), audit trail, customer report tables
GRANT INSERT ON bronze.equipment_values_raw, bronze.equipment_events_raw, identity.user_logs TO stream_engine;
GRANT SELECT, INSERT, UPDATE ON customer_reports.production_data_sync, customer_reports.sap_data_sync,
                                customer_reports.boxes                               TO stream_engine;
GRANT SELECT, INSERT, DELETE ON customer_reports.shift                               TO stream_engine;

-- ── sequences behind serial INSERT targets ────────────────────────────────────────────────────────
GRANT USAGE ON SEQUENCE
  silver.equipment_values_source_seq_seq, silver.equipment_events_source_seq_seq,
  core.clients_id_client_seq, core.product_families_id_product_family_seq, core.products_id_product_seq,
  core.production_orders_internal_id_order_seq,   -- nextval in trigger production_orders_po_number (30805)
  customer_reports.production_data_sync_indice_geral_seq, identity.user_logs_id_user_logs_seq,
  public.equipment_oee_shift_id_seq
TO stream_engine;

-- ── the one superuser-only operation, behind a narrow SECURITY DEFINER wrapper ─────────────────────
CREATE OR REPLACE FUNCTION public.ensure_timescaledb_workers() RETURNS boolean
  LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
  AS $$ SELECT _timescaledb_functions.start_background_workers() $$;
COMMENT ON FUNCTION public.ensure_timescaledb_workers() IS
  'Starts the TimescaleDB background-worker scheduler for this database (idempotent). SECURITY DEFINER '
  'wrapper so the least-privilege stream_engine role can self-heal cagg refresh after a DB restart '
  '(t-stream-engine-role).';
REVOKE ALL ON FUNCTION public.ensure_timescaledb_workers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_timescaledb_workers() TO stream_engine;

-- ── functions (all INVOKER) ───────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION
  public.current_tenant(), public.is_all_tenant(),
  public.piot_get_day_begin_by_equipment(integer, timestamptz),
  public.piot_get_day_begin_by_area(integer, timestamptz),
  public.piot_get_day_begin_by_site(integer, timestamptz),
  public.piot_get_shift_hour_begin_by_equipment(integer, timestamptz),
  public.piot_get_shift_hour_begin_by_area(integer, timestamptz),
  public.piot_get_shift_hour_begin_by_site(integer, timestamptz),
  public.piot_create_equipment_oee_hourly(), public.piot_create_equipment_oee_daily(),
  public.piot_create_equipment_oee_weekly(), public.piot_create_equipment_oee_monthly(),
  public.piot_create_equipment_oee_shift(), public.piot_create_equipment_oee_shift_weekly(),
  public.piot_create_equipment_oee_shift_monthly(), public.piot_create_area_oee_daily(),
  public.piot_create_area_oee_shift(), public.piot_create_site_oee_shift(),
  public.piot_create_site_oee_daily(),
  serving.data_sync(integer, integer), serving.report_shift(integer, date, date),
  core.try_int4(text), core.try_int8(text)
TO stream_engine;

COMMIT;
