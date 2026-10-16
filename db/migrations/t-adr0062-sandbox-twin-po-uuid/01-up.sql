-- t-adr0062-sandbox-twin-po-uuid — the sandbox twin heal must give each reflected PO its OWN po_uuid.
--
-- ops.sandbox_reflect clones the source tenant's POs with to_jsonb(x) || {offset ids}: every column is copied,
-- and since ADR-0062 P1 that includes po_uuid (UNIQUE). Every nightly heal since the P1 apply (2026-10-08) failed:
--   ERROR: duplicate key value violates unique constraint "production_orders_po_uuid_key"
-- (the grace hold stayed on, so the twin was frozen, not damaged).
--
-- The twin's handle: the source v7 UUID with its last 6 (random) bytes replaced by md5(source uuid : p_dst).
-- Bytes 1-6 (timestamp), the version nibble (byte 7) and the variant (byte 9) are the source's, so it is a valid
-- UUIDv7 with the same time; it is deterministic (stable across nightly heals) and distinct from the source.
--
-- One asserted edit of the LIVE body (generated from pg_get_functiondef, not from migration history).
-- Idempotent: a body that already sets po_uuid is left alone.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $fix$
DECLARE
  fn  regprocedure := 'ops.sandbox_reflect(integer,integer,integer,interval,boolean,text,text,boolean)';
  def text := pg_get_functiondef('ops.sandbox_reflect(integer,integer,integer,interval,boolean,text,text,boolean)'::regprocedure);
  anchor text := $a$'id_user_operator', NULL, 'id_equipment_executed', x.id_equipment_executed + p_off, 'id_label', NULL)$a$;
  patch  text := $p$'id_user_operator', NULL, 'id_equipment_executed', x.id_equipment_executed + p_off, 'id_label', NULL,
          -- ADR-0062: the twin's own handle (source v7 time + version/variant, last 6 bytes from a hash)
          'po_uuid', encode(overlay(uuid_send(x.po_uuid) PLACING
                       substring(decode(md5(x.po_uuid::text || ':' || p_dst), 'hex') FROM 11 FOR 6) FROM 11 FOR 6), 'hex')::uuid)$p$;
  n int;
BEGIN
  IF def ~ '''po_uuid''' THEN
    RAISE NOTICE 'sandbox_reflect already sets po_uuid — skipped';
    RETURN;
  END IF;
  n := (length(def) - length(replace(def, anchor, ''))) / length(anchor);
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected exactly 1 PO clone anchor in %, found %', fn, n;
  END IF;
  EXECUTE replace(def, anchor, patch);  -- CREATE OR REPLACE: same signature, grants and owner kept
  RAISE NOTICE 'sandbox_reflect: twin POs get their own po_uuid';
END
$fix$;

COMMIT;
