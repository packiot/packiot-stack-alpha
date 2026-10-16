-- verify for t-prodt172-operator-last-line. label|value, expected in the label. Read-only. Run as postgres.
\set ON_ERROR_STOP 1

SELECT 'V1 table exists in identity: t', to_regclass('identity.operator_last_line') IS NOT NULL;

SELECT 'V2 columns (by name): id_enterprise:integer,id_equipment:integer,id_user:integer,updated_at:timestamp with time zone',
       string_agg(column_name || ':' || data_type, ',' ORDER BY column_name)
  FROM information_schema.columns
 WHERE table_schema = 'identity' AND table_name = 'operator_last_line';

SELECT 'V3 primary key (id_user, id_enterprise): id_user,id_enterprise',
       (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
          FROM pg_constraint c
          CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
         WHERE c.conrelid = 'identity.operator_last_line'::regclass AND c.contype = 'p');

-- The unqualified name edge-api uses resolves to THIS table (no shadow copy in public from an earlier knex run).
SELECT 'V4 unqualified operator_last_line resolves to identity, no public copy: t|f',
       to_regclass('operator_last_line') = to_regclass('identity.operator_last_line'),
       to_regclass('public.operator_last_line') IS NOT NULL;

SELECT 'V5 the identity.users owner may read and write it: t|t',
       has_table_privilege((SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'identity.users'::regclass),
                           'identity.operator_last_line', 'SELECT'),
       has_table_privilege((SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'identity.users'::regclass),
                           'identity.operator_last_line', 'INSERT,UPDATE');
