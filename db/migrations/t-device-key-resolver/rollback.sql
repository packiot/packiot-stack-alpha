-- rollback for t-device-key-resolver (read-api must be back on the packml_register query first).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION IF EXISTS core.resolve_device_key(text, integer);
-- restore the t278a comment
COMMENT ON COLUMN core.topic_routing.device_key IS 'Tenant-prefixed, GLOBALLY-UNIQUE SparkPlug device id (e.g. CPACK-…, BISNAGO-…). read-api /internal/resolve-device resolves device_key -> id_equipment (ADR-0046); a partial unique index enforces <=1 active row per device_key.';
COMMIT;
