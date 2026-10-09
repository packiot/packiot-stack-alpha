-- verify for t-device-resolver-enterprise. label|value, expected in the label. Read-only apart from SET ROLE (reset).
\set ON_ERROR_STOP 1
SELECT 'V1 function is SECURITY DEFINER, owner postgres, search_path pinned: t|postgres|t',
       p.prosecdef, pg_get_userbyid(p.proowner), coalesce(array_to_string(p.proconfig, ','), '') LIKE 'search_path=%'
  FROM pg_proc p WHERE p.oid = 'core.resolve_device(text,integer)'::regprocedure;
SELECT 'V2 PUBLIC cannot execute, readapi_ro can: f|t',
       has_function_privilege('public', 'core.resolve_device(text,integer)', 'EXECUTE'),
       has_function_privilege('readapi_ro', 'core.resolve_device(text,integer)', 'EXECUTE');
SELECT b.device_key AS k, b.id_equipment AS want, b.id_enterprise AS ent FROM core.device_bindings b WHERE b.active ORDER BY b.id_device_binding LIMIT 1 \gset
SET ROLE readapi_ro;
RESET app.tenant_id;
SELECT 'V3 readapi_ro resolves (id, tenant) with no tenant set: t', (SELECT (id_equipment, id_enterprise) = (:want, :ent) FROM core.resolve_device(:'k'));
SELECT 'V4 wrong enterprise filter: 0 rows', count(*) FROM core.resolve_device(:'k', :ent + 1000000000);
SELECT 'V5 unknown / derived key rows: 0|0', (SELECT count(*) FROM core.resolve_device('dk_00000000000000000000000000000000')),
       (SELECT count(*) FROM core.resolve_device('CPACK-SC-LINHAS-L5'));
RESET ROLE;
SELECT 'V6 every active binding resolves to its own (equipment, enterprise) (mismatches): 0',
       count(*) FROM core.device_bindings b
       WHERE b.active AND NOT EXISTS (SELECT 1 FROM core.resolve_device(b.device_key) r
                                       WHERE r.id_equipment = b.id_equipment AND r.id_enterprise = b.id_enterprise);
SELECT 'V7 old resolver still works (deployed read-api): t', core.resolve_device_key(:'k') = :want;
