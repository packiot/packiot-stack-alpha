-- t-descriptor-device-keys — ADR-0061 §D9 "Descriptor key flow": stamp every descriptor equipment's device_key from
-- its ACTIVE core.device_bindings row.
--
-- WHY: the descriptor's equipment[i].device_key is the identity the agent puts in each DBIRTH. Today it is either
-- missing (the agent then DERIVES it from the PackML topic) or a name-derived string ('<TENANT>-SC-LINHAS-L5-…').
-- core.device_bindings (t-device-bindings) holds the opaque, random key per equipment. From edge-api
-- feat/adr0061-device-keys on, the server stamps the key from the binding on every descriptor write and before every
-- generate; this migration brings the descriptors ALREADY stored to the same state, so the next generate is a no-op
-- for keys and the coverage gate (verify V1/V2) can be read.
--
-- WHAT
--   1. bindings for descriptor equipments: every ACTIVE equipment of the descriptor's OWN tenant that is referenced by
--      a descriptor but has no active binding gets one — the newest inactive binding is re-activated (same key) when
--      there is one, else a fresh opaque key is minted (t-device-bindings only bound equipments that route today).
--      Inactive, missing or other-tenant equipment ids are NOT bound; verify V3 lists them for a human fix.
--   2. stamp: each descriptor's equipment[] is rebuilt in order (WITH ORDINALITY) with device_key = the active binding
--      key of the entry's id_equipment (overwriting a name-derived key). Entries with no active binding are left as
--      they are. Only rows whose equipment[] actually changes are updated: version + 1 (auditable lineage, as every
--      descriptor write), updated_by = 't-descriptor-device-keys'. status / artifacts / validation are untouched —
--      re-keying is not a re-onboarding (no lifecycle rollback); cached artifacts keep the old keys until the next
--      generate, which is the P1 agent re-push step.
-- Idempotent: a re-run binds nothing new and updates no row (the IS DISTINCT FROM guard).
-- Requires t-device-bindings. Run as the owner (superuser bypasses the FORCED RLS on core.device_bindings).

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $$ BEGIN
  IF to_regclass('core.device_bindings') IS NULL THEN
    RAISE EXCEPTION 't-descriptor-device-keys: core.device_bindings missing; apply t-device-bindings first';
  END IF;
END $$;

-- descriptor equipment references, one row per (descriptor, entry); id_equipment parsed defensively (raw-JSON hatch)
CREATE TEMP TABLE _dk_refs ON COMMIT DROP AS
SELECT d.id AS id_descriptor, d.id_enterprise, x.ord,
       CASE WHEN jsonb_typeof(x.eq) = 'object' AND x.eq->>'id_equipment' ~ '^[0-9]{1,9}$'
            THEN (x.eq->>'id_equipment')::int END AS id_equipment
FROM core.client_descriptors d
CROSS JOIN LATERAL jsonb_array_elements(d.descriptor->'equipment') WITH ORDINALITY AS x(eq, ord)
WHERE jsonb_typeof(d.descriptor->'equipment') = 'array';

-- 1a. re-activate the NEWEST inactive binding of a referenced active same-tenant equipment with no active binding
UPDATE core.device_bindings b SET active = true
WHERE b.id_device_binding IN (
  SELECT max(x.id_device_binding)
  FROM core.device_bindings x
  JOIN core.equipments e ON e.id_equipment = x.id_equipment AND e.active
  WHERE EXISTS (SELECT 1 FROM _dk_refs r WHERE r.id_equipment = e.id_equipment AND r.id_enterprise = e.id_enterprise)
    AND NOT EXISTS (SELECT 1 FROM core.device_bindings a WHERE a.id_equipment = e.id_equipment AND a.active)
  GROUP BY x.id_equipment
);

-- 1b. mint for referenced active same-tenant equipments that never had a binding
INSERT INTO core.device_bindings (id_enterprise, id_equipment, device_key)
SELECT e.id_enterprise, e.id_equipment, 'dk_' || replace(gen_random_uuid()::text, '-', '')
FROM core.equipments e
WHERE e.active
  AND EXISTS (SELECT 1 FROM _dk_refs r WHERE r.id_equipment = e.id_equipment AND r.id_enterprise = e.id_enterprise)
  AND NOT EXISTS (SELECT 1 FROM core.device_bindings b WHERE b.id_equipment = e.id_equipment);

-- 2. stamp: rebuild equipment[] in its original order with the binding keys
WITH rebuilt AS (
  SELECT d.id,
         jsonb_agg(CASE WHEN b.device_key IS NOT NULL THEN x.eq || jsonb_build_object('device_key', b.device_key)
                        ELSE x.eq END
                   ORDER BY x.ord) AS equipment
  FROM core.client_descriptors d
  CROSS JOIN LATERAL jsonb_array_elements(d.descriptor->'equipment') WITH ORDINALITY AS x(eq, ord)
  LEFT JOIN core.device_bindings b
         ON b.active AND b.id_enterprise = d.id_enterprise
        -- CASE, not AND: join-qual order is not guaranteed, so the cast must not see a non-numeric id
        AND b.id_equipment = CASE WHEN jsonb_typeof(x.eq) = 'object' AND x.eq->>'id_equipment' ~ '^[0-9]{1,9}$'
                                  THEN (x.eq->>'id_equipment')::int END
  WHERE jsonb_typeof(d.descriptor->'equipment') = 'array'
  GROUP BY d.id
)
UPDATE core.client_descriptors d
   SET descriptor = jsonb_set(d.descriptor, '{equipment}', r.equipment),
       version    = d.version + 1,
       updated_by = 't-descriptor-device-keys',
       updated_at = now()
  FROM rebuilt r
 WHERE d.id = r.id
   AND d.descriptor->'equipment' IS DISTINCT FROM r.equipment;

COMMIT;
