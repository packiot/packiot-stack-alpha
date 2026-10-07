-- core.device_bindings (manifest mode: replace) — fresh, random dk_ keys for the seeded equipment.
-- Real keys are NEVER copied: staging keys are promoted to prod unchanged (t-device-bindings), so a laptop
-- copy would spread production device identities. Same rule as the t-device-bindings backfill: one active
-- binding per equipment that routes today, tenant taken from the equipment (the composite FK enforces it).
INSERT INTO core.device_bindings (id_enterprise, id_equipment, device_key)
SELECT e.id_enterprise, e.id_equipment, 'dk_' || replace(gen_random_uuid()::text, '-', '')
  FROM core.equipments e
 WHERE e.id_enterprise IS NOT NULL
   AND EXISTS (SELECT 1 FROM core.topic_routing tr WHERE tr.id_equipment = e.id_equipment AND tr.active)
   AND NOT EXISTS (SELECT 1 FROM core.device_bindings b WHERE b.id_equipment = e.id_equipment AND b.active);
