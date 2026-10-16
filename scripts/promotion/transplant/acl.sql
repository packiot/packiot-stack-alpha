-- acl.sql — READ ONLY. Run on staging and on packiot_next; compare with compare-acl.py (2026-10-14 dress rehearsal).
-- READ ONLY: ACLs, RLS policies (roles/qual), role settings, Timescale jobs — the parts catalog.sql does not cover
-- TimescaleDB-optional (ADR-0063): without the extension 'jobs' and 'compression' are empty (housekeeping then runs from
-- pg_cron on staging / systemd timers on prod, outside this database — docs/runbooks/go-live-bispharma.md).
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') AS acl_has_ts \gset
\if :acl_has_ts
\set acl_jobs 'SELECT proc_schema::text AS proc_schema, proc_name::text AS proc_name, hypertable_schema::text AS hypertable_schema, hypertable_name::text AS hypertable_name, schedule_interval, scheduled, config FROM timescaledb_information.jobs WHERE job_id >= 1000'
\set acl_comp 'SELECT hypertable_schema::text AS hypertable_schema, hypertable_name::text AS hypertable_name, compression_enabled FROM timescaledb_information.hypertables'
\else
\set acl_jobs 'SELECT NULL::text AS proc_schema, NULL::text AS proc_name, NULL::text AS hypertable_schema, NULL::text AS hypertable_name, NULL::interval AS schedule_interval, NULL::boolean AS scheduled, NULL::jsonb AS config WHERE false'
\set acl_comp 'SELECT NULL::text AS hypertable_schema, NULL::text AS hypertable_name, NULL::boolean AS compression_enabled WHERE false'
\endif
WITH tsjobs AS (:acl_jobs), tscomp AS (:acl_comp)
SELECT json_build_object(
 'acl', (SELECT json_agg(json_build_object('o', n.nspname||'.'||c.relname, 'k', c.relkind, 'acl', (SELECT array_agg(x ORDER BY x) FROM unnest(c.relacl::text[]) x WHERE x !~ '^(cloudbeaver|"?dev@)')))
         FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE c.relkind IN ('r','v','m','p','S') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname !~ '^(_timescaledb|timescaledb|pg_toast|hdb_catalog)' AND c.relname !~ '^_bkp'),
 'fnacl', (SELECT json_agg(json_build_object('o', n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')', 'acl', (SELECT array_agg(x ORDER BY x) FROM unnest(p.proacl::text[]) x WHERE x !~ '^(cloudbeaver|"?dev@)')))
         FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('public','core','gold','silver','bronze','serving','ops','identity','config','customer_reports','bi') AND p.proacl IS NOT NULL),
 'nspacl', (SELECT json_agg(json_build_object('o', nspname, 'acl', (SELECT array_agg(x ORDER BY x) FROM unnest(nspacl::text[]) x WHERE x !~ '^(cloudbeaver|"?dev@)'))) FROM pg_namespace WHERE nspname !~ '^(pg_|_timescaledb|timescaledb|information_schema|hdb_catalog)'),
 'pol', (SELECT json_agg(json_build_object('o', schemaname||'.'||tablename||'.'||policyname, 'cmd', cmd, 'roles', roles, 'qual', qual, 'chk', with_check)) FROM pg_policies),
 'rls', (SELECT json_agg(json_build_object('o', n.nspname||'.'||c.relname, 'rls', c.relrowsecurity, 'force', c.relforcerowsecurity)) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relrowsecurity),
 'jobs', (SELECT json_agg(json_build_object('proc', proc_schema||'.'||proc_name, 'ht', coalesce(hypertable_schema||'.'||hypertable_name,'-'), 'every', schedule_interval::text, 'on', scheduled,
           'cfg', coalesce(config->>'drop_after', config->>'compress_after', (config->>'start_offset')||'/'||(config->>'end_offset'), ''))) FROM tsjobs),
 'retention', (SELECT json_agg(json_build_object('rel', relation, 'tier', tier, 'keep', keep::text)) FROM ops.retention_policy),
 'rolesettings', (SELECT json_agg(json_build_object('r', r.rolname, 's', s.setconfig)) FROM pg_db_role_setting s JOIN pg_roles r ON r.oid=s.setrole WHERE s.setdatabase=0),
 'compression', (SELECT json_agg(json_build_object('ht', hypertable_schema||'.'||hypertable_name, 'on', compression_enabled)) FROM tscomp)
);
