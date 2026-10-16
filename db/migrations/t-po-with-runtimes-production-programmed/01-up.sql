-- t-po-with-runtimes-production-programmed — front4's main Production Orders page shows the PO's programmed
-- quantity (core.production_orders.production_programmed) next to "ordered", as the legacy line did
-- (front4 legacy #167). serving.production_orders_with_runtimes is the ADR-0062 P3a wrapper over
-- production_orders_with_runtimes_base and already LEFT JOINs the PO row, so the value is one more trailing
-- column from that join — the base body is untouched.
--
-- A RETURNS TABLE change needs DROP + CREATE (CREATE OR REPLACE cannot change OUT columns). EXECUTE grants and
-- the owner are captured before the drop and restored, so no caller gains or loses access. The DROP is plain
-- (no CASCADE): if anything ever depends on the wrapper, this fails instead of silently dropping it.
-- Idempotent: a wrapper that already returns production_programmed is skipped.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pp$
DECLARE
  fn  CONSTANT text := 'serving.production_orders_with_runtimes(integer,text,text,text,text,timestamp,timestamp,text)';
  f   pg_proc;
  g   record;
  acl aclitem[];
  args text;
BEGIN
  SELECT * INTO f FROM pg_proc WHERE oid = fn::regprocedure;
  IF 'production_programmed' = ANY (f.proargnames) THEN
    RAISE NOTICE 'production_orders_with_runtimes already returns production_programmed — skipped';
    RETURN;
  END IF;
  IF to_regproc('serving.production_orders_with_runtimes_base') IS NULL OR f.proargnames[array_upper(f.proargnames, 1)] <> 'order_number' THEN
    RAISE EXCEPTION 'expected the ADR-0062 P3a wrapper (…, order_number) — found %', f.proargnames;
  END IF;
  acl := coalesce(f.proacl, acldefault('f', f.proowner));

  -- argument list (names + DEFAULTs) copied from the live wrapper, so named/defaulted callers keep working
  args := pg_get_function_arguments(f.oid);
  EXECUTE 'DROP FUNCTION ' || fn;
  EXECUTE format($f$
    CREATE FUNCTION serving.production_orders_with_runtimes(%s)
    RETURNS TABLE (id_enterprise integer, status integer, id_production_order bigint, id_order integer,
                   nm_client character varying, nm_product character varying, txt_product character varying,
                   production_ordered bigint, gross_production double precision, net_production double precision,
                   nm_equipment character varying, id_area integer, id_site integer,
                   ts_start timestamp with time zone, production_final bigint, ts_end timestamp with time zone,
                   id_equipment integer, runtimes json, order_number character varying,
                   production_programmed bigint)
    LANGUAGE sql STABLE AS $body$
      SELECT b.id_enterprise, b.status, b.id_production_order, b.id_order, b.nm_client, b.nm_product,
             b.txt_product, b.production_ordered, b.gross_production, b.net_production, b.nm_equipment,
             b.id_area, b.id_site, b.ts_start, b.production_final, b.ts_end, b.id_equipment, b.runtimes,
             po.id_order_text, po.production_programmed
        FROM serving.production_orders_with_runtimes_base($1, $2, $3, $4, $5, $6, $7, $8) WITH ORDINALITY
             AS b(id_enterprise, status, id_production_order, id_order, nm_client, nm_product, txt_product,
                  production_ordered, gross_production, net_production, nm_equipment, id_area, id_site,
                  ts_start, production_final, ts_end, id_equipment, runtimes, adr0062_ord)
        LEFT JOIN core.production_orders po ON po.id_production_order = b.id_production_order
       ORDER BY b.adr0062_ord
    $body$$f$, args);

  EXECUTE 'REVOKE ALL ON FUNCTION ' || fn || ' FROM PUBLIC';
  FOR g IN SELECT (aclexplode(acl)).* LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %s', fn,
                   CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(g.grantee)) END);
  END LOOP;
  EXECUTE format('ALTER FUNCTION %s OWNER TO %I', fn, pg_get_userbyid(f.proowner));
  EXECUTE format('COMMENT ON FUNCTION %s IS %L', fn,
    'ADR-0062 P3a: production_orders_with_runtimes_base + order_number (id_order_text) + production_programmed '
    '(the PO''s programmed quantity). Join: po.id_production_order = b.id_production_order');
END
$pp$;

COMMIT;
