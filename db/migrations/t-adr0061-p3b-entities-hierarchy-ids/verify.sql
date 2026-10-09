-- verify for t-adr0061-p3b-entities-hierarchy-ids. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 security_invoker kept: t', coalesce('security_invoker=on' = ANY (reloptions) OR 'security_invoker=true' = ANY (reloptions), false)
  FROM pg_class WHERE oid = 'serving.v_entities_per_user_role_operator'::regclass;
SELECT 'V2 columns unchanged: id_enterprise,id_user_role,nm_user_role,enterprise,sites,areas,lines,sectors,machines,equipments,shifts,teams',
       string_agg(attname, ',' ORDER BY attnum) FROM pg_attribute
 WHERE attrelid = 'serving.v_entities_per_user_role_operator'::regclass AND attnum > 0 AND NOT attisdropped;
SELECT 'V3 equipments / sectors elements missing the new keys: 0|0',
  (SELECT count(*) FROM serving.v_entities_per_user_role_operator v, jsonb_array_elements(v.equipments) e WHERE NOT (e ? 'id_parentequipment' AND e ? 'id_area' AND e ? 'id_site')),
  (SELECT count(*) FROM serving.v_entities_per_user_role_operator v, jsonb_array_elements(v.sectors) e WHERE NOT (e ? 'id_parentequipment' AND e ? 'id_area' AND e ? 'id_site'));
-- the tree the operator builds: every machine's parent is a line/sector of the SAME enterprise row
SELECT 'V4 machines whose parent is not a line/sector of their enterprise (orphans): 0', count(*)
  FROM serving.v_entities_per_user_role_operator v, jsonb_array_elements(v.equipments) m
 WHERE m->>'id_parentequipment' IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v.lines || v.sectors) p WHERE p->>'id' = m->>'id_parentequipment');
SELECT 'V5 readapi_ro can read: t', has_table_privilege('readapi_ro', 'serving.v_entities_per_user_role_operator', 'SELECT');
