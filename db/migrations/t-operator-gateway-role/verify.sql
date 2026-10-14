-- verify for t-operator-gateway-role. label|value, expected in the label. Read-only (V9 runs inside
-- BEGIN … ROLLBACK). Run as postgres. V1–V8 must hold right after 01-up.sql; I1 turns t only after the
-- host set the password (provisioning step 3).
\set ON_ERROR_STOP 1

SELECT 'V1 role exists, LOGIN, not superuser/bypassrls/createrole/createdb/replication/inherit: t|f|f|f|f|f|f',
       rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication, rolinherit
  FROM pg_roles WHERE rolname = 'operator_gateway';

SELECT 'V2 member of no role (inherits nothing): 0', count(*)
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = 'operator_gateway';

SELECT 'V3 session defaults: default_transaction_read_only=on,statement_timeout=5s',
       array_to_string(array_agg(c ORDER BY c), ',')
  FROM pg_db_role_setting s, unnest(s.setconfig) c
 WHERE s.setrole = (SELECT oid FROM pg_roles WHERE rolname = 'operator_gateway');

-- Column grants: exactly these 10 (relation.column), nothing else.
WITH want(rel, col) AS (VALUES
  ('core.topic_routing', 'packml_topic'), ('core.topic_routing', 'id_equipment'), ('core.topic_routing', 'active'),
  ('core.equipments', 'id_equipment'), ('core.equipments', 'cd_equipment'), ('core.equipments', 'id_area'),
  ('core.areas', 'id_area'), ('core.areas', 'id_site'),
  ('core.sites', 'id_site'), ('core.sites', 'id_enterprise')),
have AS (
  SELECT format('%I.%I', table_schema, table_name) AS rel, column_name AS col
    FROM information_schema.column_privileges
   WHERE grantee = 'operator_gateway' AND privilege_type = 'SELECT')
SELECT 'V4 SELECT columns granted = the 10 the resolver reads (missing|extra): 0|0',
       (SELECT count(*) FROM (SELECT * FROM want EXCEPT SELECT * FROM have) m),
       (SELECT count(*) FROM (SELECT * FROM have EXCEPT SELECT * FROM want) x);

SELECT 'V5 non-SELECT column privileges (INSERT/UPDATE/REFERENCES): 0', count(*)
  FROM information_schema.column_privileges
 WHERE grantee = 'operator_gateway' AND privilege_type <> 'SELECT';

SELECT 'V6 whole-table privileges on any relation (tables, views, sequences): 0', count(*)
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'operator_gateway');

SELECT 'V7 schemas with USAGE / CREATE (direct grant): core,public|0',
       (SELECT string_agg(n.nspname, ',' ORDER BY n.nspname) FROM pg_namespace n, aclexplode(n.nspacl) a
         WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'operator_gateway') AND a.privilege_type = 'USAGE'),
       (SELECT count(*) FROM pg_namespace n
         WHERE has_schema_privilege('operator_gateway', n.oid, 'CREATE'));

SELECT 'V8 functions granted directly: current_tenant(),is_all_tenant()',
       string_agg(p.oid::regprocedure::text, ',' ORDER BY p.proname)
  FROM pg_proc p, aclexplode(p.proacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'operator_gateway');

-- V9: the real resolver shape AS the role (any tenant that has an active route), plus the denials.
BEGIN;
CREATE TEMP TABLE _v9 (label text, val text) ON COMMIT DROP;
GRANT INSERT ON _v9 TO operator_gateway;
DO $$
DECLARE ent int; n int; ok boolean;
BEGIN
  SELECT s.id_enterprise INTO ent
    FROM core.topic_routing t JOIN core.equipments e USING (id_equipment)
    JOIN core.areas a ON a.id_area = e.id_area JOIN core.sites s ON s.id_site = a.id_site
   WHERE t.active LIMIT 1;
  INSERT INTO _v9 VALUES ('V9a sample tenant with an active route (informational)', coalesce(ent::text, 'none'));
  EXECUTE 'SET LOCAL ROLE operator_gateway';
  PERFORM set_config('app.tenant_id', ent::text, true);
  SELECT count(*) INTO n
    FROM core.topic_routing p
    JOIN core.equipments e ON e.id_equipment = p.id_equipment
    JOIN core.areas a      ON a.id_area      = e.id_area
    JOIN core.sites s      ON s.id_site      = a.id_site
   WHERE p.active AND s.id_enterprise = ent;
  INSERT INTO _v9 VALUES ('V9b resolver join as operator_gateway, tenant stamped: >0 rows', n::text);
  PERFORM set_config('app.tenant_id', '', true);
  SELECT count(*) INTO n FROM core.topic_routing p WHERE p.active;
  INSERT INTO _v9 VALUES ('V9c same read, GUC unset (RLS fail-closed): 0', n::text);
  BEGIN
    PERFORM device_key FROM core.topic_routing LIMIT 1; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v9 VALUES ('V9d ungranted column denied: t', ok::text);
  BEGIN
    PERFORM 1 FROM core.production_orders LIMIT 1; ok := false;
  EXCEPTION WHEN insufficient_privilege THEN ok := true; END;
  INSERT INTO _v9 VALUES ('V9e other table denied: t', ok::text);
  BEGIN
    EXECUTE 'UPDATE core.sites SET id_site = id_site WHERE false'; ok := false;
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN ok := true; END;
  INSERT INTO _v9 VALUES ('V9f write denied: t', ok::text);
  EXECUTE 'RESET ROLE';
END $$;
SELECT label, val FROM _v9;
ROLLBACK;

SELECT 'I1 password set on the host (t after provisioning step 3)', rolpassword IS NOT NULL
  FROM pg_authid WHERE rolname = 'operator_gateway';
