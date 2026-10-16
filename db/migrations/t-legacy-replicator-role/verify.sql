-- verify for t-legacy-replicator-role. label|value, expected in the label. Read-only (V10 runs inside
-- BEGIN … ROLLBACK). Run as postgres. V0–V10 must hold right after 01-up.sql; I1 turns t only after the host
-- set the password (provisioning step 3).
\set ON_ERROR_STOP 1

SELECT 'V0 ops tables present (cursor, dlq with retry columns, manual-event link): t|t|t|t',
       to_regclass('ops.mirror_replay_cursor') IS NOT NULL,
       to_regclass('ops.mirror_replay_dlq') IS NOT NULL,
       (SELECT count(*) = 2 FROM information_schema.columns WHERE table_schema = 'ops'
           AND table_name = 'mirror_replay_dlq' AND column_name IN ('retry_attempts', 'last_retry_at')),
       to_regclass('ops.legacy_manual_event_link') IS NOT NULL;

SELECT 'V1 role exists, LOGIN, not superuser/bypassrls/createrole/createdb/replication/inherit: t|f|f|f|f|f|f',
       rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication, rolinherit
  FROM pg_roles WHERE rolname = 'legacy_replicator';

SELECT 'V2 member of no role (inherits nothing): 0', count(*)
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = 'legacy_replicator';

SELECT 'V3 session defaults (none: the connection stamps app.tenant_id=DST_ENTERPRISE): ',
       coalesce(array_to_string(array_agg(c ORDER BY c), ','), '')
  FROM pg_db_role_setting s, unnest(s.setconfig) c
 WHERE s.setrole = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator');

-- Table + sequence privileges: exactly this set (relation:privilege), nothing else.
WITH want(rel, privs) AS (VALUES
  ('core.equipments','r'),('core.topic_routing','r'),('core.packml_register','r'),
  ('core.po_number_corrections','r'),('core.sites','r'),('core.shifts','r'),('gold.equipment_oee_shift','r'),
  ('ops.sandbox_hold_status','r'),
  ('core.production_orders','arw'),
  ('core.products','ar'),('core.product_families','ar'),('core.clients','ar'),
  ('gold.production_orders_runtime','adrw'),
  ('silver.equipment_events','arw'),
  ('silver.equipment_events_man','adrw'),
  ('serving.downtime_events_resolved','adrw'),
  ('ops.mirror_replay_cursor','arw'),
  ('ops.mirror_replay_dlq','adrw'),('ops.legacy_manual_event_link','adrw'),
  ('core.production_orders_internal_id_order_seq','U'),('core.product_families_id_product_family_seq','U'),
  ('silver.equipment_events_source_seq_seq','U'),('ops.mirror_replay_dlq_id_seq','U'),
  ('core.products_id_product_seq','Urw'),('core.clients_id_client_seq','Urw')),
have AS (
  SELECT format('%I.%I', n.nspname, c.relname) AS rel,
         string_agg(p, '' ORDER BY p) AS privs
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a,
         LATERAL (SELECT CASE a.privilege_type WHEN 'SELECT' THEN 'r' WHEN 'INSERT' THEN 'a' WHEN 'UPDATE' THEN 'w'
                         WHEN 'DELETE' THEN 'd' WHEN 'USAGE' THEN 'U' ELSE a.privilege_type END AS p) x
   WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator')
     AND n.nspname NOT LIKE '\_timescaledb%'   -- TimescaleDB copies hypertable grants onto its chunks
   GROUP BY 1)
SELECT 'V4 table/sequence privileges = the 25 the replicator uses (missing|extra|wrong privs): 0|0|0',
       (SELECT count(*) FROM want w WHERE NOT EXISTS (SELECT 1 FROM have h WHERE h.rel = w.rel)),
       (SELECT count(*) FROM have h WHERE NOT EXISTS (SELECT 1 FROM want w WHERE w.rel = h.rel)),
       (SELECT count(*) FROM want w JOIN have h USING (rel) WHERE w.privs <> h.privs);

SELECT 'V5 no TRUNCATE / REFERENCES / TRIGGER on anything: 0', count(*)
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator')
   AND a.privilege_type IN ('TRUNCATE', 'REFERENCES', 'TRIGGER');

SELECT 'V6 owns nothing: 0', count(*) FROM pg_class
 WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator');

SELECT 'V7 schemas with USAGE / CREATE (direct grant): core,gold,ops,public,serving,silver|0',
       (SELECT string_agg(n.nspname, ',' ORDER BY n.nspname) FROM pg_namespace n, aclexplode(n.nspacl) a
         WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator') AND a.privilege_type = 'USAGE'),
       (SELECT count(*) FROM pg_namespace n WHERE has_schema_privilege('legacy_replicator', n.oid, 'CREATE'));

-- (TEMPORARY is not granted to the role; a database whose PUBLIC still has the default TEMP grants it to every
-- login, this one included. The replicator creates no temp objects.)
SELECT 'V8 database privileges granted directly (no TEMPORARY): CONNECT',
       (SELECT string_agg(a.privilege_type, ',' ORDER BY a.privilege_type)
          FROM pg_database d, aclexplode(d.datacl) a
         WHERE d.datname = current_database()
           AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator'));

SELECT 'V9 functions granted directly (5) | SECURITY DEFINER among them: 5|',
       count(*), coalesce(string_agg(p.oid::regprocedure::text, ',') FILTER (WHERE p.prosecdef), '')
  FROM pg_proc p, aclexplode(p.proacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'legacy_replicator');

-- V10: as the role — the tenant stamp through FORCE RLS (fails closed without it), the probes, the denials.
BEGIN;
CREATE TEMP TABLE _v10 (label text, val text) ON COMMIT DROP;
GRANT INSERT ON _v10 TO legacy_replicator;
DO $$
DECLARE n bigint; m bigint; ok boolean; s text;
BEGIN
  SELECT count(*) INTO m FROM core.production_orders WHERE id_enterprise = 3;
  EXECUTE 'SET LOCAL ROLE legacy_replicator';
  PERFORM set_config('app.tenant_id', '', true);    -- a connection that forgot the stamp
  SELECT count(*) INTO n FROM core.production_orders;
  INSERT INTO _v10 VALUES ('V10a no tenant stamp → FORCE-RLS production_orders rows visible: 0', n::text);
  PERFORM set_config('app.tenant_id', '3', true);   -- what the CPACK instance stamps at connect
  SELECT count(*) INTO n FROM core.production_orders;
  INSERT INTO _v10 VALUES ('V10b stamped 3 → sees exactly tenant 3''s POs (as postgres = as role)', n || '=' || m);
  SELECT count(*) INTO n FROM core.packml_register;
  INSERT INTO _v10 VALUES ('V10c packml_register view readable (security_invoker → topic_routing): t', (n >= 0)::text);
  SELECT ops.sandbox_hold_mode(2000003) INTO s;
  INSERT INTO _v10 VALUES ('V10d sandbox_hold_mode callable: t', (s IS NOT NULL)::text);
  BEGIN
    EXECUTE 'TRUNCATE ops.mirror_replay_dlq'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10e TRUNCATE denied: t', ok::text);
  BEGIN
    EXECUTE 'CREATE TABLE IF NOT EXISTS ops.mirror_replay_cursor (source text)'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10f DDL denied (even IF NOT EXISTS on an existing table): t', ok::text);
  BEGIN
    EXECUTE 'DELETE FROM core.production_orders WHERE false'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10g DELETE on core.production_orders denied: t', ok::text);
  BEGIN
    EXECUTE 'DELETE FROM silver.equipment_events WHERE false'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10h DELETE on silver.equipment_events denied: t', ok::text);
  BEGIN
    PERFORM 1 FROM identity.users LIMIT 1; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10i identity.users denied: t', ok::text);
  BEGIN
    EXECUTE 'UPDATE core.equipments SET id_area = id_area WHERE false'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v10 VALUES ('V10j UPDATE core.equipments denied: t', ok::text);
  EXECUTE 'RESET ROLE';
END $$;
SELECT label, val FROM _v10;
ROLLBACK;

SELECT 'I1 password set on the host (t after provisioning step 3)', rolpassword IS NOT NULL
  FROM pg_authid WHERE rolname = 'legacy_replicator';
