-- verify for t-device-key-resolver. label|value, expected in the label. Read-only apart from SET ROLE (reset).
\set ON_ERROR_STOP 1
SELECT 'V1 function is SECURITY DEFINER, owner postgres, search_path pinned: t|postgres|t',
       p.prosecdef, pg_get_userbyid(p.proowner), coalesce(array_to_string(p.proconfig, ','), '') LIKE 'search_path=%'
  FROM pg_proc p WHERE p.oid = 'core.resolve_device_key(text,integer)'::regprocedure;
SELECT 'V2 PUBLIC cannot execute, readapi_ro can: f|t',
       has_function_privilege('public', 'core.resolve_device_key(text,integer)', 'EXECUTE'),
       has_function_privilege('readapi_ro', 'core.resolve_device_key(text,integer)', 'EXECUTE');
-- a real active binding, resolved AS readapi_ro with NO tenant set (the decoder's situation)
SELECT b.device_key AS k, b.id_equipment AS want, b.id_enterprise AS ent FROM core.device_bindings b WHERE b.active ORDER BY b.id_device_binding LIMIT 1 \gset
SET ROLE readapi_ro;
RESET app.tenant_id;
SELECT 'V3 readapi_ro resolves a key through RLS with no tenant: t', core.resolve_device_key(:'k') = :want;
SELECT 'V4 same key, right enterprise: t', core.resolve_device_key(:'k', :ent) = :want;
SELECT 'V5 same key, wrong enterprise: NULL→t', core.resolve_device_key(:'k', :ent + 1000000000) IS NULL;
SELECT 'V6 unknown / derived key: t', core.resolve_device_key('dk_00000000000000000000000000000000') IS NULL
                                     AND core.resolve_device_key('CPACK-SC-LINHAS-L5') IS NULL;
SELECT 'V7 the table itself stays fenced for readapi_ro (rows visible): 0', count(*) FROM core.device_bindings;
RESET ROLE;
SELECT 'V8 every active binding resolves to its own equipment (mismatches): 0',
       count(*) FROM core.device_bindings b WHERE b.active AND core.resolve_device_key(b.device_key) IS DISTINCT FROM b.id_equipment;
