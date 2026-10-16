-- t-device-key-resolver — ADR-0061 step c: the device_key → id_equipment lookup reads core.device_bindings.
--
-- WHY A SECURITY DEFINER FUNCTION: read-api's /internal/resolve-device (the decoder's birth-binding seam)
-- connects as readapi_ro, which does not bypass RLS, and core.device_bindings has RLS ENABLED + FORCED with
-- the house tenant policy. A lookup by device_key alone has no tenant to set (the key is the identity: it is
-- random and globally unique), so a plain SELECT would always miss. Instead of letting read-api set the
-- all-tenant sentinel (reserved for Superset Admin), this function is the ONE narrow cross-tenant door:
--   * input: an exact key (+ optional enterprise filter); output: one id_equipment or NULL;
--   * no listing, no pattern match, nothing else readable through it;
--   * owner postgres (bypasses RLS), pinned search_path, EXECUTE revoked from PUBLIC, granted to readapi_ro.
-- core.topic_routing.device_key stops being read (comment below); it is dropped with topic_routing in P5.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION core.resolve_device_key(p_device_key text, p_enterprise integer DEFAULT NULL)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, core
AS $$
  SELECT b.id_equipment
    FROM core.device_bindings b
   WHERE b.device_key = p_device_key
     AND b.active
     AND (p_enterprise IS NULL OR b.id_enterprise = p_enterprise)
$$;
ALTER FUNCTION core.resolve_device_key(text, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION core.resolve_device_key(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.resolve_device_key(text, integer) TO readapi_ro;

COMMENT ON FUNCTION core.resolve_device_key(text, integer) IS
  'ADR-0061 step c: active device_bindings.device_key → id_equipment (NULL = no binding). SECURITY DEFINER: the only '
  'cross-tenant read of device_bindings; exact key in, one id out. Caller: read-api /internal/resolve-device.';
COMMENT ON COLUMN core.topic_routing.device_key IS
  'DEPRECATED (ADR-0061 step c, 2026-10-07): no longer read nor written by the cloud; identity is core.device_bindings. Dropped in P5.';

COMMIT;
