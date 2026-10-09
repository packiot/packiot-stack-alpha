WITH s AS (SELECT oid, nspname FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast')
             AND nspname !~ '^(pg_temp|pg_toast_temp|_timescaledb|timescaledb_)' ),
ht AS (SELECT h.hypertable_schema AS sch, h.hypertable_name AS nm,
              (SELECT d.column_name FROM timescaledb_information.dimensions d WHERE d.hypertable_schema=h.hypertable_schema AND d.hypertable_name=h.hypertable_name ORDER BY d.dimension_number LIMIT 1) AS tcol,
              (SELECT d.time_interval::text FROM timescaledb_information.dimensions d WHERE d.hypertable_schema=h.hypertable_schema AND d.hypertable_name=h.hypertable_name ORDER BY d.dimension_number LIMIT 1) AS chunk
         FROM timescaledb_information.hypertables h),
ca AS (SELECT view_schema AS sch, view_name AS nm, materialized_only, view_definition, materialization_hypertable_schema AS msch, materialization_hypertable_name AS mnm FROM timescaledb_information.continuous_aggregates)
SELECT json_build_object(
 'tables', (SELECT json_agg(json_build_object('s', s.nspname, 'n', c.relname, 'kind', c.relkind, 'rls', c.relrowsecurity, 'force', c.relforcerowsecurity,
        'ht', (SELECT json_build_object('tcol', ht.tcol, 'chunk', ht.chunk) FROM ht WHERE ht.sch=s.nspname AND ht.nm=c.relname),
        'cols', (SELECT json_agg(json_build_object('n', a.attname, 't', format_type(a.atttypid, a.atttypmod), 'nn', a.attnotnull,
                   'def', pg_get_expr(ad.adbin, ad.adrelid), 'id', a.attidentity, 'gen', a.attgenerated) ORDER BY a.attnum)
                 FROM pg_attribute a LEFT JOIN pg_attrdef ad ON ad.adrelid=a.attrelid AND ad.adnum=a.attnum
                 WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped)) ORDER BY 1)
     FROM pg_class c JOIN s ON s.oid=c.relnamespace WHERE c.relkind IN ('r','p')),
 'indexes', (SELECT json_agg(json_build_object('s', s.nspname, 'tbl', t.relname, 'n', i.relname, 'def', pg_get_indexdef(i.oid),
        'con', EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid=i.oid)))
     FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid JOIN pg_class t ON t.oid=x.indrelid JOIN s ON s.oid=t.relnamespace WHERE t.relkind IN ('r','p','m')),
 'constraints', (SELECT json_agg(json_build_object('s', s.nspname, 'tbl', t.relname, 'n', k.conname, 'type', k.contype, 'def', pg_get_constraintdef(k.oid)))
     FROM pg_constraint k JOIN pg_class t ON t.oid=k.conrelid JOIN s ON s.oid=t.relnamespace),
 'sequences', (SELECT json_agg(json_build_object('s', s.nspname, 'n', c.relname,
        'owned', (SELECT d.refobjid::regclass::text||'.'||a.attname FROM pg_depend d JOIN pg_attribute a ON a.attrelid=d.refobjid AND a.attnum=d.refobjsubid WHERE d.objid=c.oid AND d.deptype IN ('a','i') LIMIT 1)))
     FROM pg_class c JOIN s ON s.oid=c.relnamespace WHERE c.relkind='S'),
 'views', (SELECT json_agg(json_build_object('s', s.nspname, 'n', c.relname, 'kind', c.relkind, 'md5', md5(pg_get_viewdef(c.oid)),
        'cagg', EXISTS (SELECT 1 FROM ca WHERE ca.sch=s.nspname AND ca.nm=c.relname)))
     FROM pg_class c JOIN s ON s.oid=c.relnamespace WHERE c.relkind IN ('v','m')),
 'caggs', (SELECT json_agg(json_build_object('s', sch, 'n', nm, 'mo', materialized_only, 'def', view_definition)) FROM ca),
 'functions', (SELECT json_agg(json_build_object('s', s.nspname, 'n', p.proname, 'args', oidvectortypes(p.proargtypes), 'kind', p.prokind, 'md5', md5(p.prosrc)))
     FROM pg_proc p JOIN s ON s.oid=p.pronamespace WHERE NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')),
 'types', (SELECT json_agg(json_build_object('s', s.nspname, 'n', t.typname)) FROM pg_type t JOIN s ON s.oid=t.typnamespace
     WHERE t.typtype='c' AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid=t.typrelid AND c.relkind='c')),
 'policies', (SELECT json_agg(json_build_object('s', schemaname, 'tbl', tablename, 'n', policyname)) FROM pg_policies WHERE schemaname NOT LIKE '\_timescaledb%'),
 'triggers', (SELECT json_agg(json_build_object('s', s.nspname, 'tbl', c.relname, 'n', t.tgname, 'def', pg_get_triggerdef(t.oid)))
     FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN s ON s.oid=c.relnamespace WHERE NOT t.tgisinternal),
 'schemas', (SELECT json_agg(nspname) FROM s),
 'roles', (SELECT json_agg(rolname) FROM pg_roles WHERE rolname !~ '^pg_')
);
