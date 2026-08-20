-- 10-packml-register-device-key-global-unique.sql — ADR-0046 resolve-by-device_key.
-- __SCH__ = target schema (public on packiot_analytics / F3). Idempotent.
--
-- CONTEXT. Migration 09 added a PER-(enterprise,device_key) partial unique index,
-- which scopes uniqueness per tenant. But edge-transformer is a SINGLE multi-tenant
-- instance: it must resolve a device_key from ANY tenant's birth without knowing the
-- enterprise. device_key is tenant-PREFIXED (CPACK-…, BISNAGO-…), so it is already
-- globally unique in practice. This promotes that to a GLOBAL unique index so the
-- resolve-by-device_key endpoint (WHERE device_key = $1) is guaranteed ≤1 active row,
-- and a cross-tenant device_key collision is rejected at write time (fail-closed).
--
-- The per-enterprise index from 09 is left in place (harmless; still serves a
-- per-tenant caller). Verified zero global collisions before adding (staging).

BEGIN;

DO $$
BEGIN
  IF to_regclass('__SCH__.packml_register') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'uq_pr_device_key_global') THEN
    EXECUTE 'CREATE UNIQUE INDEX uq_pr_device_key_global '
         || 'ON __SCH__.packml_register (device_key) WHERE device_key IS NOT NULL';
  END IF;
END $$;

COMMIT;
