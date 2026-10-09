-- t-device-resolver-enterprise — ADR-0061 P2: the device_key lookup also returns the TENANT (D3).
--
-- The decoder becomes the single binding authority: at birth it resolves each declared device_key and stamps
-- id_equipment AND id_enterprise on what it publishes, so the tenant comes from the binding, never from the
-- SparkPlug group_id or a name segment. core.resolve_device_key (t-device-key-resolver) returns only the id;
-- changing its return type would need a DROP under a live read-api, so this adds a sibling with the same
-- security shape and leaves the old one for the currently-deployed read-api (dropped in P5).
--   * exact key in (+ optional enterprise filter), one row (id_equipment, id_enterprise) or none out;
--   * owner postgres (bypasses the FORCED RLS), pinned search_path, EXECUTE revoked from PUBLIC → readapi_ro.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION core.resolve_device(p_device_key text, p_enterprise integer DEFAULT NULL)
RETURNS TABLE (id_equipment integer, id_enterprise integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, core
AS $$
  SELECT b.id_equipment, b.id_enterprise
    FROM core.device_bindings b
   WHERE b.device_key = p_device_key
     AND b.active
     AND (p_enterprise IS NULL OR b.id_enterprise = p_enterprise)
$$;
ALTER FUNCTION core.resolve_device(text, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION core.resolve_device(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.resolve_device(text, integer) TO readapi_ro;

COMMENT ON FUNCTION core.resolve_device(text, integer) IS
  'ADR-0061 P2: active device_bindings.device_key → (id_equipment, id_enterprise); no row = no binding. SECURITY DEFINER: '
  'the only cross-tenant read of device_bindings; exact key in, one row out. Caller: read-api /internal/resolve-device.';
COMMENT ON FUNCTION core.resolve_device_key(text, integer) IS
  'DEPRECATED (ADR-0061 P2): superseded by core.resolve_device (adds id_enterprise). Kept for a read-api that predates it; dropped in P5.';

COMMIT;
