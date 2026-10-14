-- verify for t-barcode-service-role. label|value, expected in the label. Run as postgres. V1–V8 must hold
-- right after 01-up.sql; I1 turns t only after the host set the password (provisioning step 3).
-- V9 runs the real scan statements AS the role inside BEGIN … ROLLBACK: nothing is kept (the box_scans
-- identity advances by one, which only leaves a gap in box_scan_id).
\set ON_ERROR_STOP 1

SELECT 'V1 role exists, LOGIN, not superuser/bypassrls/createrole/createdb/replication/inherit: t|f|f|f|f|f|f',
       rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication, rolinherit
  FROM pg_roles WHERE rolname = 'barcode_service';

SELECT 'V2 member of no role (inherits nothing): 0', count(*)
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = 'barcode_service';

SELECT 'V3 session defaults: statement_timeout=30s',
       array_to_string(array_agg(c ORDER BY c), ',')
  FROM pg_db_role_setting s, unnest(s.setconfig) c
 WHERE s.setrole = (SELECT oid FROM pg_roles WHERE rolname = 'barcode_service');

WITH want(rel, priv, col) AS (VALUES
  ('bronze.box_scans', 'SELECT', 'box_scan_id'), ('bronze.box_scans', 'SELECT', 'id_enterprise'),
  ('bronze.box_scans', 'SELECT', 'id_production_order'), ('bronze.box_scans', 'SELECT', 'label_seq'),
  ('bronze.box_scans', 'SELECT', 'scan_uuid'),
  ('bronze.box_scans', 'INSERT', 'id_enterprise'), ('bronze.box_scans', 'INSERT', 'id_site'),
  ('bronze.box_scans', 'INSERT', 'id_area'), ('bronze.box_scans', 'INSERT', 'id_equipment'),
  ('bronze.box_scans', 'INSERT', 'id_production_order'), ('bronze.box_scans', 'INSERT', 'id_order'),
  ('bronze.box_scans', 'INSERT', 'scan_type'), ('bronze.box_scans', 'INSERT', 'label_seq'),
  ('bronze.box_scans', 'INSERT', 'qty'), ('bronze.box_scans', 'INSERT', 'counts_toward_total'),
  ('bronze.box_scans', 'INSERT', 'raw_barcode'), ('bronze.box_scans', 'INSERT', 'scan_uuid'),
  ('bronze.box_scans', 'INSERT', 'ts_value'),
  ('gold.po_box_counter', 'SELECT', 'id_production_order'), ('gold.po_box_counter', 'SELECT', 'id_enterprise'),
  ('gold.po_box_counter', 'SELECT', 'last_label_seq'), ('gold.po_box_counter', 'SELECT', 'total_qty'),
  ('gold.po_box_counter', 'INSERT', 'id_production_order'), ('gold.po_box_counter', 'INSERT', 'id_enterprise'),
  ('gold.po_box_counter', 'INSERT', 'last_label_seq'), ('gold.po_box_counter', 'INSERT', 'total_qty'),
  ('gold.po_box_counter', 'INSERT', 'updated_at'),
  ('gold.po_box_counter', 'UPDATE', 'last_label_seq'), ('gold.po_box_counter', 'UPDATE', 'total_qty'),
  ('gold.po_box_counter', 'UPDATE', 'updated_at'),
  ('core.production_orders', 'SELECT', 'id_production_order'), ('core.production_orders', 'SELECT', 'id_enterprise'),
  ('core.production_orders', 'SELECT', 'id_order'),
  ('core.equipments', 'SELECT', 'id_equipment'), ('core.equipments', 'SELECT', 'id_enterprise'),
  ('core.equipments', 'SELECT', 'id_site'), ('core.equipments', 'SELECT', 'id_area')),
have AS (
  SELECT format('%I.%I', table_schema, table_name) AS rel, privilege_type AS priv, column_name AS col
    FROM information_schema.column_privileges WHERE grantee = 'barcode_service')
SELECT 'V4 column privileges = the 37 the service uses (missing|extra): 0|0',
       (SELECT count(*) FROM (SELECT * FROM want EXCEPT SELECT * FROM have) m),
       (SELECT count(*) FROM (SELECT * FROM have EXCEPT SELECT * FROM want) x);

SELECT 'V5 REFERENCES column privileges: 0', count(*)
  FROM information_schema.column_privileges
 WHERE grantee = 'barcode_service' AND privilege_type = 'REFERENCES';

SELECT 'V6 whole-table privileges on any relation (tables, views, sequences): 0', count(*)
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'barcode_service');

SELECT 'V7 schemas with USAGE / CREATE (direct grant): bronze,core,gold,public|0',
       (SELECT string_agg(n.nspname, ',' ORDER BY n.nspname) FROM pg_namespace n, aclexplode(n.nspacl) a
         WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'barcode_service') AND a.privilege_type = 'USAGE'),
       (SELECT count(*) FROM pg_namespace n
         WHERE has_schema_privilege('barcode_service', n.oid, 'CREATE'));

SELECT 'V8 functions granted directly: current_tenant(),is_all_tenant()',
       string_agg(p.oid::regprocedure::text, ',' ORDER BY p.proname)
  FROM pg_proc p, aclexplode(p.proacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'barcode_service');

-- V9: the real scan statements AS the role, for any tenant PO + equipment, then the denials.
BEGIN;
CREATE TEMP TABLE _v9 (label text, val text) ON COMMIT DROP;
GRANT INSERT ON _v9 TO barcode_service;
DO $$
DECLARE ent int; po bigint; eq int; n bigint; ok boolean; uuid0 uuid := gen_random_uuid();
BEGIN
  SELECT p.id_enterprise, p.id_production_order, e.id_equipment INTO ent, po, eq
    FROM core.production_orders p JOIN core.equipments e ON e.id_enterprise = p.id_enterprise
   ORDER BY p.id_production_order DESC LIMIT 1;
  INSERT INTO _v9 VALUES ('V9a sample tenant|po|equipment (informational)', concat_ws('|', ent, po, eq));
  EXECUTE 'SET LOCAL ROLE barcode_service';
  PERFORM pg_advisory_xact_lock(po);
  PERFORM set_config('app.tenant_id', ent::text, true);
  SELECT count(*) INTO n FROM bronze.box_scans bs
    LEFT JOIN gold.po_box_counter c ON c.id_production_order = bs.id_production_order WHERE bs.scan_uuid = uuid0;
  SELECT (EXISTS (SELECT 1 FROM core.production_orders WHERE id_production_order = po AND id_enterprise = ent)
      AND EXISTS (SELECT 1 FROM core.equipments WHERE id_equipment = eq AND id_enterprise = ent))::int INTO n;
  INSERT INTO _v9 VALUES ('V9b tenant fence as barcode_service, tenant stamped: 1', n::text);
  INSERT INTO bronze.box_scans (id_enterprise, id_site, id_area, id_equipment, id_production_order, id_order,
                                scan_type, label_seq, qty, counts_toward_total, raw_barcode, scan_uuid, ts_value)
  VALUES (ent, (SELECT id_site FROM core.equipments WHERE id_equipment = eq AND id_enterprise = ent),
          (SELECT id_area FROM core.equipments WHERE id_equipment = eq AND id_enterprise = ent), eq, po,
          (SELECT id_order FROM core.production_orders WHERE id_production_order = po AND id_enterprise = ent),
          'production', 1, 1, true, 'verify', uuid0, now())
  RETURNING box_scan_id INTO n;
  INSERT INTO gold.po_box_counter (id_production_order, id_enterprise, last_label_seq, total_qty, updated_at)
  VALUES (po, ent, 1, 1, now())
  ON CONFLICT (id_production_order) DO UPDATE
     SET last_label_seq = GREATEST(po_box_counter.last_label_seq, EXCLUDED.last_label_seq),
         total_qty = po_box_counter.total_qty + 1, updated_at = now()
  RETURNING total_qty INTO n;
  INSERT INTO _v9 VALUES ('V9c scan insert + counter upsert as barcode_service: ok', 'ok');
  PERFORM set_config('app.tenant_id', '', true);
  SELECT count(*) INTO n FROM core.production_orders WHERE id_production_order = po;
  INSERT INTO _v9 VALUES ('V9d same fence, GUC unset (RLS fail-closed): 0', n::text);
  BEGIN
    PERFORM raw_barcode FROM bronze.box_scans LIMIT 1; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v9 VALUES ('V9e ungranted column denied: t', ok::text);
  BEGIN
    EXECUTE 'DELETE FROM gold.po_box_counter WHERE false'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v9 VALUES ('V9f DELETE denied: t', ok::text);
  BEGIN
    EXECUTE 'UPDATE core.production_orders SET id_order = id_order WHERE false'; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v9 VALUES ('V9g write to core denied: t', ok::text);
  EXECUTE 'RESET ROLE';
END $$;
SELECT label, val FROM _v9;
ROLLBACK;

SELECT 'I1 password set on the host (t after provisioning step 3)', rolpassword IS NOT NULL
  FROM pg_authid WHERE rolname = 'barcode_service';
