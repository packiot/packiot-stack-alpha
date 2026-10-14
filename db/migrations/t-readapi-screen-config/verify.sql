-- verify for t-readapi-screen-config. label|value, expected in the label. Read-only. Run as postgres.
\set ON_ERROR_STOP 1

SELECT 'V1 table exists: t', to_regclass('identity.user_screen_config') IS NOT NULL;

SELECT 'V2 columns (by name): config:jsonb,id_enterprise:integer,id_user:text,screen:text,updated_at:timestamp with time zone',
       string_agg(column_name || ':' || data_type, ',' ORDER BY column_name)
  FROM information_schema.columns
 WHERE table_schema = 'identity' AND table_name = 'user_screen_config';

SELECT 'V3 unique (id_enterprise,id_user,screen) index present, old pkey gone: t|f',
       EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'identity' AND indexname = 'user_screen_config_tenant_key'),
       EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'user_screen_config_pkey'
                 AND conrelid = 'identity.user_screen_config'::regclass);

-- The role's privileges on this table are exactly SELECT, INSERT, UPDATE (no DELETE/TRUNCATE/ownership).
SELECT 'V4 readapi_ro privileges on the table: INSERT,SELECT,UPDATE',
       (SELECT string_agg(a.privilege_type, ',' ORDER BY a.privilege_type)
          FROM pg_class c, aclexplode(c.relacl) a
         WHERE c.oid = 'identity.user_screen_config'::regclass
           AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'readapi_ro'));

SELECT 'V5 readapi_ro owns it / may CREATE in identity: f|f',
       (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'identity.user_screen_config'::regclass) = 'readapi_ro',
       has_schema_privilege('readapi_ro', 'identity', 'CREATE');
