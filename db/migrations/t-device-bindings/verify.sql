-- verify for t-device-bindings. Run after 01-up.sql (as the owner). Every line prints label|value; the expected value
-- is in the label. Read-only apart from SET ROLE / SET app.tenant_id, which are reset at the end.
\set ON_ERROR_STOP 1

SELECT 'V1 routed equipments without exactly one active binding: 0',
       count(*) FROM core.equipments e
       WHERE EXISTS (SELECT 1 FROM core.topic_routing tr WHERE tr.id_equipment = e.id_equipment AND tr.active)
         AND (SELECT count(*) FROM core.device_bindings b WHERE b.id_equipment = e.id_equipment AND b.active) <> 1;
SELECT 'V2 bindings whose tenant differs from the routing rows of the same equipment: 0',
       count(*) FROM core.device_bindings b
       WHERE EXISTS (SELECT 1 FROM core.topic_routing tr WHERE tr.id_equipment = b.id_equipment AND tr.active AND tr.id_enterprise <> b.id_enterprise);
SELECT 'V3 keys not in the opaque format: 0', count(*) FROM core.device_bindings WHERE device_key !~ '^dk_[0-9a-f]{32}$';
SELECT 'V4 keys equal to a derived topic string: 0',
       count(*) FROM core.device_bindings b JOIN core.topic_routing tr ON tr.device_key = b.device_key;
SELECT 'V5 RLS enabled and forced: t|t', relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = 'core.device_bindings'::regclass;
SELECT 'V6 tenant_isolation policy present: 1', count(*) FROM pg_policies WHERE schemaname = 'core' AND tablename = 'device_bindings' AND policyname = 'tenant_isolation';
SELECT 'V7 per-tenant bindings (enterprise|bindings)', id_enterprise, count(*) FROM core.device_bindings GROUP BY 2 ORDER BY 2;

-- isolation as the RLS-enforced role: tenant 3 sees only tenant 3, unset tenant sees nothing (fail-closed)
SET ROLE readapi_ro;
SET app.tenant_id = '3';
SELECT 'V8 readapi_ro as tenant 3 sees other tenants: 0', count(*) FROM core.device_bindings WHERE id_enterprise <> 3;
RESET app.tenant_id;
SELECT 'V9 readapi_ro with no tenant sees: 0', count(*) FROM core.device_bindings;
RESET ROLE;

-- the CHECK and the composite FK reject what they must (each inside a savepoint, rolled back)
BEGIN;
SAVEPOINT s;
DO $$ BEGIN
  INSERT INTO core.device_bindings (id_enterprise, id_equipment, device_key)
  SELECT id_enterprise, id_equipment, 'ACME-SC-LINHAS-L5-M1' FROM core.equipments LIMIT 1;
  RAISE NOTICE 'V10 FAIL: derived key accepted';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'V10 derived key rejected: ok';
END $$;
ROLLBACK TO SAVEPOINT s;
DO $$ BEGIN
  -- active = false keeps the one-active-per-equipment index out of the way: only the composite FK can reject this
  INSERT INTO core.device_bindings (id_enterprise, id_equipment, device_key, active)
  SELECT e.id_enterprise + 1000000000, e.id_equipment, 'dk_' || replace(gen_random_uuid()::text, '-', ''), false FROM core.equipments e LIMIT 1;
  RAISE NOTICE 'V11 FAIL: cross-tenant binding accepted';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'V11 cross-tenant binding rejected: ok';
END $$;
ROLLBACK;
