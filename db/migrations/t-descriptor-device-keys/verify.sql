-- verify for t-descriptor-device-keys. Run after 01-up.sql (as the owner). Every line prints label|value; the
-- expected value is in the label. Read-only. V1 + V2 = 0 is the ADR-0061 §D9 coverage gate for stored descriptors.
\set ON_ERROR_STOP 1

CREATE TEMP VIEW _dk_entries AS
SELECT d.id_enterprise, d.tenant_code, x.ord, x.eq,
       CASE WHEN jsonb_typeof(x.eq) = 'object' AND x.eq->>'id_equipment' ~ '^[0-9]{1,9}$'
            THEN (x.eq->>'id_equipment')::int END AS id_equipment,
       CASE WHEN jsonb_typeof(x.eq) = 'object' THEN x.eq->>'device_key' END AS device_key
FROM core.client_descriptors d
CROSS JOIN LATERAL jsonb_array_elements(d.descriptor->'equipment') WITH ORDINALITY AS x(eq, ord)
WHERE jsonb_typeof(d.descriptor->'equipment') = 'array';

SELECT 'V1 descriptor equipments whose device_key differs from their active binding key: 0', count(*)
FROM _dk_entries t
JOIN core.device_bindings b ON b.active AND b.id_enterprise = t.id_enterprise AND b.id_equipment = t.id_equipment
WHERE t.device_key IS DISTINCT FROM b.device_key;

SELECT 'V2 descriptor equipments without an active binding in their tenant: 0', count(*)
FROM _dk_entries t
WHERE NOT EXISTS (SELECT 1 FROM core.device_bindings b
                   WHERE b.active AND b.id_enterprise = t.id_enterprise AND b.id_equipment = t.id_equipment);

-- detail for V2 (empty when V2 = 0): what a human must fix in that descriptor before edge-api accepts a write for it
SELECT 'V3 unbindable entry (enterprise|tenant|position|id_equipment|reason)', t.id_enterprise, t.tenant_code, t.ord,
       t.id_equipment,
       CASE WHEN t.id_equipment IS NULL THEN 'no numeric id_equipment'
            WHEN e.id_equipment IS NULL THEN 'equipment does not exist'
            WHEN e.id_enterprise IS DISTINCT FROM t.id_enterprise THEN 'equipment belongs to enterprise ' || coalesce(e.id_enterprise::text, 'NULL')
            WHEN NOT e.active THEN 'equipment is soft-deleted'
            ELSE 'no active binding' END
FROM _dk_entries t
LEFT JOIN core.equipments e ON e.id_equipment = t.id_equipment
WHERE NOT EXISTS (SELECT 1 FROM core.device_bindings b
                   WHERE b.active AND b.id_enterprise = t.id_enterprise AND b.id_equipment = t.id_equipment)
ORDER BY 2, 4;

SELECT 'V4 descriptor device_keys not in the opaque dk_ format: 0', count(*)
FROM _dk_entries WHERE device_key IS NOT NULL AND device_key !~ '^dk_[0-9a-f]{32}$';

SELECT 'V5 duplicate device_key inside one descriptor: 0', count(*)
FROM (SELECT id_enterprise, device_key FROM _dk_entries WHERE device_key IS NOT NULL
      GROUP BY 1, 2 HAVING count(*) > 1) dup;

SELECT 'V6 active bindings on an inactive equipment: 0', count(*)
FROM core.device_bindings b JOIN core.equipments e ON e.id_equipment = b.id_equipment
WHERE b.active AND NOT e.active;

SELECT 'V7 descriptors re-keyed by this migration (enterprise|tenant|version|equipments)', d.id_enterprise, d.tenant_code,
       d.version, jsonb_array_length(d.descriptor->'equipment')
FROM core.client_descriptors d WHERE d.updated_by = 't-descriptor-device-keys' ORDER BY 2;
