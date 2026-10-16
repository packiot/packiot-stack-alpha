-- verify for t-stream-engine-role. label|value, expected in the label. Read-only (V10 runs inside
-- BEGIN … ROLLBACK). Run as postgres. V1–V9 must hold right after 01-up.sql; I1 turns t only after the host
-- set the password (provisioning step 3).
\set ON_ERROR_STOP 1

SELECT 'V1 role exists, LOGIN, not superuser/bypassrls/createrole/createdb/replication/inherit: t|f|f|f|f|f|f',
       rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication, rolinherit
  FROM pg_roles WHERE rolname = 'stream_engine';

SELECT 'V2 member of no role (inherits nothing): 0', count(*)
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = 'stream_engine';

SELECT 'V3 session defaults (cross-tenant sentinel): app.tenant_id=-1',
       array_to_string(array_agg(c ORDER BY c), ',')
  FROM pg_db_role_setting s, unnest(s.setconfig) c
 WHERE s.setrole = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine');

-- Table privileges: exactly this set (relation:privilege), nothing else.
WITH want(rel, privs) AS (VALUES
  ('core.enterprises','r'),('core.sites','r'),('core.areas','r'),('core.shifts','r'),('core.shift_hours','r'),
  ('core.shifts_exception_period','r'),('core.client_descriptors','r'),('core.box_production_bridges','r'),
  ('core.downtime_reason','r'),('core.equipment_downtime_reason','r'),('core.equipment_validation_shift','r'),
  ('core.po_number_corrections','r'),('config.label_formats','r'),('config.production_targets','r'),
  ('config.equipment_out_of_service','r'),
  ('silver.equipment_categorical_1min','r'),('silver.equipment_categorical_1hour','r'),
  ('silver.agg_equipment_values_1min','r'),('silver.agg_equipment_values_1hour','r'),
  ('silver.ca_discrete_changes_1s','r'),
  ('silver.plc_endpoint_equipment','r'),('silver.plc_link_minutes','r'),
  ('core.equipments','rw'),('core.topic_routing','rw'),('core.packml_register','rw'),
  ('core.production_orders','arw'),('core.products','arw'),('core.product_families','arw'),('core.clients','arw'),
  ('silver.equipment_values','arw'),('silver.equipment_events_man','arw'),('silver.data_quality_event','arw'),
  ('silver.equipment_live_day','arw'),('silver.equipment_live_job','arw'),('silver.equipment_live_month','arw'),
  ('silver.equipment_live_shift','arw'),('silver.equipment_live_metrics','arw'),('silver.area_live_day','arw'),
  ('silver.area_live_shift','arw'),
  ('silver.equipment_events','adrw'),('silver.equipment_events_cpac_shadow','adrw'),
  ('gold.equipment_oee_hourly','arw'),('gold.equipment_oee_daily','arw'),('gold.equipment_oee_weekly','arw'),
  ('gold.equipment_oee_monthly','arw'),('gold.equipment_oee_shift','arw'),('gold.equipment_oee_shift_weekly','arw'),
  ('gold.equipment_oee_shift_monthly','arw'),('gold.area_oee_daily','arw'),('gold.area_oee_shift','arw'),
  ('gold.site_oee_shift','arw'),('gold.production_orders_runtime','arw'),
  ('bronze.equipment_values_raw','a'),('bronze.equipment_events_raw','a'),('identity.user_logs','a'),
  ('customer_reports.production_data_sync','arw'),('customer_reports.sap_data_sync','arw'),
  ('customer_reports.boxes','arw'),('customer_reports.shift','adr'),
  ('silver.equipment_values_source_seq_seq','U'),('silver.equipment_events_source_seq_seq','U'),
  ('core.clients_id_client_seq','U'),('core.product_families_id_product_family_seq','U'),
  ('core.products_id_product_seq','U'),('core.production_orders_internal_id_order_seq','U'),
  ('customer_reports.production_data_sync_indice_geral_seq','U'),('identity.user_logs_id_user_logs_seq','U'),
  ('public.equipment_oee_shift_id_seq','U')),
have AS (
  SELECT format('%I.%I', n.nspname, c.relname) AS rel,
         string_agg(p, '' ORDER BY p) AS privs
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a,
         LATERAL (SELECT CASE a.privilege_type WHEN 'SELECT' THEN 'r' WHEN 'INSERT' THEN 'a' WHEN 'UPDATE' THEN 'w'
                         WHEN 'DELETE' THEN 'd' WHEN 'USAGE' THEN 'U' ELSE a.privilege_type END AS p) x
   WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine')
     AND n.nspname NOT LIKE '\_timescaledb%'   -- TimescaleDB copies hypertable grants onto its chunks
   GROUP BY 1)
SELECT 'V4 table/sequence privileges = the 69 the engine uses (missing|extra|wrong privs): 0|0|0',
       (SELECT count(*) FROM want w WHERE NOT EXISTS (SELECT 1 FROM have h WHERE h.rel = w.rel)),
       (SELECT count(*) FROM have h WHERE NOT EXISTS (SELECT 1 FROM want w WHERE w.rel = h.rel)),
       (SELECT count(*) FROM want w JOIN have h USING (rel) WHERE w.privs <> h.privs);

SELECT 'V5 no TRUNCATE / REFERENCES / TRIGGER on anything: 0', count(*)
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine')
   AND a.privilege_type IN ('TRUNCATE', 'REFERENCES', 'TRIGGER');

SELECT 'V6 owns nothing: 0', count(*) FROM pg_class
 WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine');

SELECT 'V7 schemas with USAGE / CREATE (direct grant): bronze,config,core,customer_reports,gold,identity,public,serving,silver|0',
       (SELECT string_agg(n.nspname, ',' ORDER BY n.nspname) FROM pg_namespace n, aclexplode(n.nspacl) a
         WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine') AND a.privilege_type = 'USAGE'),
       (SELECT count(*) FROM pg_namespace n WHERE has_schema_privilege('stream_engine', n.oid, 'CREATE'));

SELECT 'V8 database privileges: CONNECT,TEMPORARY',
       (SELECT string_agg(a.privilege_type, ',' ORDER BY a.privilege_type)
          FROM pg_database d, aclexplode(d.datacl) a
         WHERE d.datname = current_database()
           AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine'));

SELECT 'V9 functions granted directly (24) | SECURITY DEFINER among them = ensure_timescaledb_workers only: 24|ensure_timescaledb_workers()',
       count(*), string_agg(p.oid::regprocedure::text, ',') FILTER (WHERE p.prosecdef)
  FROM pg_proc p, aclexplode(p.proacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'stream_engine');

-- V10: as the role — cross-tenant read through FORCE RLS, the wrapper, and the denials.
BEGIN;
CREATE TEMP TABLE _v10 (label text, val text) ON COMMIT DROP;
GRANT INSERT ON _v10 TO stream_engine;
DO $$
DECLARE n bigint; m bigint; ok boolean;
BEGIN
  SELECT count(DISTINCT id_enterprise) INTO m FROM core.topic_routing;
  EXECUTE 'SET LOCAL ROLE stream_engine';
  PERFORM set_config('app.tenant_id', '-1', true);  -- what the role default gives a real login
  SELECT count(DISTINCT id_enterprise) INTO n FROM core.topic_routing;
  INSERT INTO _v10 VALUES ('V10a FORCE-RLS topic_routing: tenants seen as stream_engine = as postgres', n || '=' || m);
  INSERT INTO _v10 VALUES ('V10b ensure_timescaledb_workers() callable: t', public.ensure_timescaledb_workers()::text);
  BEGIN
    EXECUTE 'TRUNCATE silver.data_quality_event'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10c TRUNCATE denied: t', ok::text);
  BEGIN
    EXECUTE 'CREATE TABLE silver.se_should_not_exist (x int)'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10d DDL denied: t', ok::text);
  BEGIN
    EXECUTE 'DELETE FROM core.production_orders WHERE false'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10e DELETE on core denied: t', ok::text);
  BEGIN
    PERFORM 1 FROM identity.users LIMIT 1; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10f identity.users denied: t', ok::text);
  BEGIN
    PERFORM _timescaledb_functions.start_background_workers(); ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10g superuser-only call directly denied: t', ok::text);
  EXECUTE 'RESET ROLE';
END $$;
SELECT label, val FROM _v10;
ROLLBACK;

SELECT 'I1 password set on the host (t after provisioning step 3)', rolpassword IS NOT NULL
  FROM pg_authid WHERE rolname = 'stream_engine';
