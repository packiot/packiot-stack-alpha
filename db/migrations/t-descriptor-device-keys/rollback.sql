-- rollback for t-descriptor-device-keys.
--
-- The PREVIOUS keys cannot be restored: they were name-derived strings ('<TENANT>-SC-LINHAS-L5-…') or absent, and
-- 01-up.sql overwrote them in place without keeping a copy (keeping derived keys anywhere is what ADR-0061 removes).
-- So the rollback REMOVES device_key from every descriptor equipment entry instead. That is behaviour-equivalent to
-- the pre-migration state for the agent: with no declared key, clientdescriptor.ResolvedDeviceKey() falls back to
-- the dash-joined topic — the same string the name-derived keys were (ADR-0061 §1.3, birth.go fallback). An entry
-- whose old key was hand-authored and differed from that derivation is the one case not restored.
--
-- NOT rolled back: bindings minted/re-activated by 01-up.sql step 1 stay (they are indistinguishable from the ones
-- edge-api mints and harmless while nothing resolves through core.device_bindings; t-device-bindings/rollback.sql
-- drops the table if that is the goal).
--
-- ORDER: roll back edge-api's server-side stamping (feat/adr0061-device-keys) FIRST — while it is deployed, the next
-- descriptor write or generate stamps the binding keys right back.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

WITH stripped AS (
  SELECT d.id,
         jsonb_agg(CASE WHEN jsonb_typeof(x.eq) = 'object' THEN x.eq - 'device_key' ELSE x.eq END ORDER BY x.ord)
           AS equipment
  FROM core.client_descriptors d
  CROSS JOIN LATERAL jsonb_array_elements(d.descriptor->'equipment') WITH ORDINALITY AS x(eq, ord)
  WHERE jsonb_typeof(d.descriptor->'equipment') = 'array'
  GROUP BY d.id
)
UPDATE core.client_descriptors d
   SET descriptor = jsonb_set(d.descriptor, '{equipment}', s.equipment),
       version    = d.version + 1,
       updated_by = 't-descriptor-device-keys-rollback',
       updated_at = now()
  FROM stripped s
 WHERE d.id = s.id
   AND d.descriptor->'equipment' IS DISTINCT FROM s.equipment;

COMMIT;
