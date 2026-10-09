-- rollback for t-device-resolver-enterprise (read-api must be back on core.resolve_device_key first).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION IF EXISTS core.resolve_device(text, integer);
COMMENT ON FUNCTION core.resolve_device_key(text, integer) IS
  'ADR-0061 step c: active device_bindings.device_key → id_equipment (NULL = no binding). SECURITY DEFINER: the only '
  'cross-tenant read of device_bindings; exact key in, one id out. Caller: read-api /internal/resolve-device.';
COMMIT;
