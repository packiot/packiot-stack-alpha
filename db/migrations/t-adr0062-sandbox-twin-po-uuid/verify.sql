-- verify t-adr0062-sandbox-twin-po-uuid — read-only.
--   T1 the live body sets po_uuid in the PO clone
--   T2 the twin-uuid expression, over every PO of every source tenant: valid v7 (version 7, RFC variant), same
--      48-bit time as the source, distinct per (source, sandbox), never equal to ANY existing po_uuid
\set ON_ERROR_STOP 1
SET statement_timeout = '300s';

DO $t$
DECLARE n bigint; bad_ver bigint; bad_time bigint; dup bigint; clash bigint;
BEGIN
  IF pg_get_functiondef('ops.sandbox_reflect(integer,integer,integer,interval,boolean,text,text,boolean)'::regprocedure)
     !~ '''po_uuid'', encode\(overlay\(uuid_send\(x\.po_uuid\)' THEN
    RAISE EXCEPTION 'T1 FAIL: sandbox_reflect does not set the twin po_uuid';
  END IF;
  RAISE NOTICE 'T1 OK: sandbox_reflect sets the twin po_uuid';

  CREATE TEMP TABLE _tw ON COMMIT DROP AS
  SELECT x.po_uuid AS src,
         encode(overlay(uuid_send(x.po_uuid) PLACING
                substring(decode(md5(x.po_uuid::text || ':' || 2000000 + x.id_enterprise), 'hex') FROM 11 FOR 6) FROM 11 FOR 6), 'hex')::uuid AS twin
    FROM core.production_orders x
   WHERE x.id_enterprise < 2000000;
  SELECT count(*),
         count(*) FILTER (WHERE substring(twin::text, 15, 1) <> '7' OR substring(twin::text, 20, 1) NOT IN ('8','9','a','b')),
         count(*) FILTER (WHERE substring(twin::text, 1, 13) <> substring(src::text, 1, 13)),
         count(*) - count(DISTINCT twin),
         count(*) FILTER (WHERE EXISTS (SELECT 1 FROM core.production_orders p WHERE p.po_uuid = _tw.twin))
    INTO n, bad_ver, bad_time, dup, clash FROM _tw;
  IF bad_ver + bad_time + dup + clash > 0 THEN
    RAISE EXCEPTION 'T2 FAIL: % POs — bad version/variant %, time differs %, duplicates %, clash with existing %',
                    n, bad_ver, bad_time, dup, clash;
  END IF;
  RAISE NOTICE 'T2 OK: % twin handles — valid v7, source time, unique, no clash', n;
END
$t$;
