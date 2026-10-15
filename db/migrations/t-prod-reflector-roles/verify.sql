-- verify for t-prod-reflector-roles. label|value, expected in the label. Read-only (V6 runs inside BEGIN … ROLLBACK).
-- Run as postgres, on staging (both roles) or production. I1/I2 turn t only after provision-db-role.py set the
-- password of the role used on THIS host (prod_reflector on staging, prod_reflector_ro on production).
\set ON_ERROR_STOP 1

SELECT 'V1 roles LOGIN, not superuser/bypassrls/createrole/createdb/replication/inherit: t|f|f|f|f|f|f (x2)',
       rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication, rolinherit
  FROM pg_roles WHERE rolname IN ('prod_reflector', 'prod_reflector_ro') ORDER BY rolname;

SELECT 'V2 session defaults: prod_reflector none; prod_reflector_ro default_transaction_read_only=on,statement_timeout=120s',
       r.rolname, coalesce(array_to_string(array_agg(c ORDER BY c), ','), '')
  FROM pg_roles r LEFT JOIN pg_db_role_setting s ON s.setrole = r.oid LEFT JOIN LATERAL unnest(s.setconfig) c ON true
 WHERE r.rolname IN ('prod_reflector', 'prod_reflector_ro') GROUP BY r.rolname ORDER BY 1;

SELECT 'V3 prod_reflector_ro has no INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER anywhere: 0', count(*)
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'prod_reflector_ro')
   AND a.privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER');

SELECT 'V4 prod_reflector cannot UPDATE core.enterprises.api_key, can UPDATE nm_enterprise: f|t',
       has_column_privilege('prod_reflector', 'core.enterprises', 'api_key', 'UPDATE'),
       has_column_privilege('prod_reflector', 'core.enterprises', 'nm_enterprise', 'UPDATE');

SELECT 'V5 prod_reflector: box_scans insert-only, no TRUNCATE/REFERENCES/TRIGGER, owns nothing: f|f|0|0',
       has_table_privilege('prod_reflector', 'bronze.box_scans', 'UPDATE'),
       has_table_privilege('prod_reflector', 'bronze.box_scans', 'DELETE'),
       (SELECT count(*) FROM pg_class c, aclexplode(c.relacl) a
         WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'prod_reflector')
           AND a.privilege_type IN ('TRUNCATE', 'REFERENCES', 'TRIGGER')),
       (SELECT count(*) FROM pg_class WHERE relowner IN (SELECT oid FROM pg_roles
                                                          WHERE rolname IN ('prod_reflector', 'prod_reflector_ro')));

-- RLS fence: without the tenant stamp the FORCE-RLS hierarchy reads empty; with app.tenant_id=5 it reads tenant 5 only.
BEGIN;
SET LOCAL ROLE prod_reflector_ro;
SELECT 'V6a prod_reflector_ro without stamp sees 0 equipment: 0', count(*) FROM core.equipments;
SET LOCAL app.tenant_id = '5';
SELECT 'V6b prod_reflector_ro stamped 5 sees only tenant 5: >0|0',
       count(*) FILTER (WHERE id_enterprise = 5), count(*) FILTER (WHERE id_enterprise <> 5) FROM core.equipments;
ROLLBACK;
BEGIN;
SET LOCAL ROLE prod_reflector_ro;
SET LOCAL app.tenant_id = '5';
DO $$ BEGIN
  BEGIN
    UPDATE core.sites SET nm_site = nm_site WHERE false;
    RAISE NOTICE 'V6c FAIL: prod_reflector_ro could UPDATE';
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN
    RAISE NOTICE 'V6c prod_reflector_ro write refused: ok';
  END;
END $$;
ROLLBACK;

SELECT 'I1 prod_reflector has a password (staging, after provisioning): t',
       rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'prod_reflector';
SELECT 'I2 prod_reflector_ro has a password (production, after provisioning): t',
       rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'prod_reflector_ro';
