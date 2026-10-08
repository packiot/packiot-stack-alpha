-- verify for t-adr0061-p3d-bindings-backfill. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 active equipments without an active binding: 0', count(*) FROM core.equipments e
 WHERE e.active AND NOT EXISTS (SELECT 1 FROM core.device_bindings b WHERE b.id_equipment = e.id_equipment AND b.active);
SELECT 'V2 equipments with >1 active binding: 0', count(*) FROM (SELECT id_equipment FROM core.device_bindings WHERE active GROUP BY 1 HAVING count(*) > 1) d;
SELECT 'V3 bindings whose enterprise != the equipment''s: 0', count(*) FROM core.device_bindings b JOIN core.equipments e USING (id_equipment) WHERE b.id_enterprise <> e.id_enterprise;
