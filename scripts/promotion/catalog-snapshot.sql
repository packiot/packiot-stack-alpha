-- READ-ONLY catalog snapshot: kind \t schema.name \t detail. Run inside BEGIN TRANSACTION READ ONLY.
WITH s AS (SELECT oid, nspname FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast')
             AND nspname NOT LIKE 'pg_temp%' AND nspname NOT LIKE 'pg_toast_temp%' AND nspname NOT LIKE '\_timescaledb%')
SELECT 'rel', s.nspname||'.'||c.relname, c.relkind::text FROM pg_class c JOIN s ON s.oid=c.relnamespace WHERE c.relkind IN ('r','p','v','m','S','i','I','c','f')
UNION ALL
SELECT 'col', s.nspname||'.'||c.relname||'.'||a.attname, format_type(a.atttypid,a.atttypmod)
  FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN s ON s.oid=c.relnamespace
 WHERE c.relkind IN ('r','p','v','m','f') AND a.attnum>0 AND NOT a.attisdropped
UNION ALL
SELECT 'fn', s.nspname||'.'||p.proname||'('||oidvectortypes(p.proargtypes)||')', md5(p.prosrc)||' '||pg_get_function_result(p.oid)
  FROM pg_proc p JOIN s ON s.oid=p.pronamespace WHERE NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')
UNION ALL
SELECT 'trg', s.nspname||'.'||c.relname||'.'||t.tgname, md5(pg_get_triggerdef(t.oid))
  FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN s ON s.oid=c.relnamespace WHERE NOT t.tgisinternal
UNION ALL
SELECT 'con', s.nspname||'.'||c.relname||'.'||k.conname, md5(pg_get_constraintdef(k.oid))
  FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN s ON s.oid=c.relnamespace
UNION ALL
SELECT 'view', s.nspname||'.'||c.relname, md5(pg_get_viewdef(c.oid)) FROM pg_class c JOIN s ON s.oid=c.relnamespace WHERE c.relkind IN ('v','m')
UNION ALL
SELECT 'schema', s.nspname, '' FROM s
UNION ALL
SELECT 'role', rolname, '' FROM pg_roles WHERE rolname !~ '^pg_'
UNION ALL
SELECT 'ext', extname, extversion FROM pg_extension;
