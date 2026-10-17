-- verify for t-postgres-exporter-role. label|value, expected in the label. Read-only. Run as postgres.
-- V1–V7 must hold right after 01-up.sql; V8 needs the password (provisioning step 3) only for the login test,
-- which provision-db-role.py performs itself.
\set ON_ERROR_STOP 1

SELECT 'V1 role exists, LOGIN, not superuser/bypassrls/createrole/createdb/replication, inherit: t|f|f|f|f|f|t',
       rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication, rolinherit
  FROM pg_roles WHERE rolname = 'postgres_exporter';

SELECT 'V2 memberships = pg_monitor only: pg_monitor',
       string_agg(g.rolname, ',' ORDER BY g.rolname)
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member JOIN pg_roles g ON g.oid = m.roleid
 WHERE r.rolname = 'postgres_exporter';

SELECT 'V3 session defaults: default_transaction_read_only=on,statement_timeout=30s',
       array_to_string(array_agg(c ORDER BY c), ',')
  FROM pg_db_role_setting s, unnest(s.setconfig) c
 WHERE s.setrole = (SELECT oid FROM pg_roles WHERE rolname = 'postgres_exporter');

SELECT 'V4 non-SELECT privileges on any relation: 0', count(*)
  FROM pg_class c, aclexplode(c.relacl) a
 WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'postgres_exporter') AND a.privilege_type <> 'SELECT';

SELECT 'V5 schemas with CREATE: 0', count(*)
  FROM pg_namespace n WHERE has_schema_privilege('postgres_exporter', n.oid, 'CREATE');

SELECT 'V6 can read the invariants (ops.data_invariant_latest exists → t): t',
       to_regclass('ops.data_invariant_latest') IS NULL
       OR has_table_privilege('postgres_exporter', 'ops.data_invariant_latest', 'SELECT')
          AND has_schema_privilege('postgres_exporter', 'ops', 'USAGE');

SELECT 'V7 cannot write anywhere (INSERT/UPDATE/DELETE/TRUNCATE on any user table): 0', count(*)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
   AND (has_table_privilege('postgres_exporter', c.oid, 'INSERT') OR has_table_privilege('postgres_exporter', c.oid, 'UPDATE')
        OR has_table_privilege('postgres_exporter', c.oid, 'DELETE') OR has_table_privilege('postgres_exporter', c.oid, 'TRUNCATE'));
