-- rollback t-adr0062-sandbox-twin-po-uuid — remove the po_uuid override from the PO clone.
-- NOTE: with ADR-0062 P1 in place the heal then fails again on production_orders_po_uuid_key.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $rb$
DECLARE
  def text := pg_get_functiondef('ops.sandbox_reflect(integer,integer,integer,interval,boolean,text,text,boolean)'::regprocedure);
  patched text := $p$'id_user_operator', NULL, 'id_equipment_executed', x.id_equipment_executed + p_off, 'id_label', NULL,
          -- ADR-0062: the twin's own handle (source v7 time + version/variant, last 6 bytes from a hash)
          'po_uuid', encode(overlay(uuid_send(x.po_uuid) PLACING
                       substring(decode(md5(x.po_uuid::text || ':' || p_dst), 'hex') FROM 11 FOR 6) FROM 11 FOR 6), 'hex')::uuid)$p$;
BEGIN
  IF position(patched IN def) = 0 THEN RAISE NOTICE 'not patched — nothing to roll back'; RETURN; END IF;
  EXECUTE replace(def, patched,
    $o$'id_user_operator', NULL, 'id_equipment_executed', x.id_equipment_executed + p_off, 'id_label', NULL)$o$);
END
$rb$;

COMMIT;
