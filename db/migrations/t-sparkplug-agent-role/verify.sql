-- verify for t-sparkplug-agent-role. label|value, expected in the label. Read-only (V6 runs inside
-- BEGIN … ROLLBACK). Run as postgres. V1–V6 must hold right after 01-up.sql; I1 turns t only after the host
-- set the password (provisioning step 3).
\set ON_ERROR_STOP 1

SELECT 'V1 role exists, LOGIN, not superuser/bypassrls/createrole/createdb/replication/inherit: t|f|f|f|f|f|f',
       rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication, rolinherit
  FROM pg_roles WHERE rolname = 'sparkplug_agent';

SELECT 'V2 member of no role (inherits nothing): 0', count(*)
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = 'sparkplug_agent';

SELECT 'V3 session defaults: app.tenant_id=-1,statement_timeout=30s',
       array_to_string(array_agg(c ORDER BY c), ',')
  FROM pg_db_role_setting s, unnest(s.setconfig) c
 WHERE s.setrole = (SELECT oid FROM pg_roles WHERE rolname = 'sparkplug_agent');

-- Table privileges: exactly this set (relation:privilege), nothing else.
WITH want(rel, privs) AS (VALUES ('core.client_descriptors', 'r'), ('silver.plc_link_minutes', 'arw')),
have AS (
  SELECT format('%s.%s', c.relnamespace::regnamespace, c.relname) AS rel,   -- qualified: regclass::text drops
         -- the schema when it is on the search_path (core/silver are, on packiot_analytics and packiot)
         string_agg(DISTINCT CASE a.privilege_type WHEN 'SELECT' THEN 'r' WHEN 'INSERT' THEN 'a'
                    WHEN 'UPDATE' THEN 'w' WHEN 'DELETE' THEN 'd' ELSE lower(a.privilege_type) END, ''
                    ORDER BY CASE a.privilege_type WHEN 'SELECT' THEN 'r' WHEN 'INSERT' THEN 'a'
                    WHEN 'UPDATE' THEN 'w' WHEN 'DELETE' THEN 'd' ELSE lower(a.privilege_type) END) AS privs
    FROM pg_class c, aclexplode(c.relacl) a
   WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'sparkplug_agent')
   GROUP BY 1)
SELECT 'V4 table privileges exactly {client_descriptors:r, plc_link_minutes:arw} (differences): 0', count(*)
  FROM (SELECT * FROM want EXCEPT SELECT * FROM have UNION ALL (SELECT * FROM have EXCEPT SELECT * FROM want)) d;

SELECT 'V5 no DDL: owns nothing, CREATE on no schema: 0|0',
       (SELECT count(*) FROM pg_class WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = 'sparkplug_agent')),
       (SELECT count(*) FROM pg_namespace WHERE has_schema_privilege('sparkplug_agent', oid, 'CREATE')
           AND nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema');

-- V6: as the role, the upsert the agent runs works for a real tenant code, and a foreign write is impossible
-- without the sentinel (RLS fails closed). Rolled back.
BEGIN;
SET LOCAL ROLE sparkplug_agent;
SET LOCAL app.tenant_id = '-1';
WITH ins AS (
  INSERT INTO silver.plc_link_minutes AS t (id_enterprise, endpoint, ts_minute, ok_ticks, fail_ticks, updated_at)
  SELECT cd.id_enterprise, '__verify__', date_trunc('minute', now()), 1, 0, now()
    FROM core.client_descriptors cd ORDER BY cd.id_enterprise LIMIT 1
  ON CONFLICT (id_enterprise, endpoint, ts_minute) DO UPDATE SET ok_ticks = t.ok_ticks + 1
  RETURNING 1)
SELECT 'V6 upsert as sparkplug_agent (rows, 1 when any descriptor exists): 1', count(*) FROM ins;
ROLLBACK;

SELECT 'I1 password set (after provisioning): t',
       (SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'sparkplug_agent');
