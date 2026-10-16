-- t-adr0062-p3a-order-number-readers — ADR-0062 step 3 (readers, D3): every serving function that returns the
-- integer PO number gains `order_number` (the client's number, production_orders.id_order_text).
--
-- WRAP, don't copy (same move as ADR-0061 P3): each function keeps its live body byte-for-byte under
-- `<name>_base` (still returning its original row type); a thin SQL wrapper takes the public name and returns
-- base.* + order_number in the base's row order (WITH ORDINALITY). So nothing a caller reads changes except
-- one trailing column, and no body drift between this file and the live DB is possible.
--
-- The single body edit: downtime_events_v3 falls back to `SELECT * FROM serving.downtime_events_v2(...)`
-- (plpgsql resolves the name at run time). That call now targets downtime_events_v2_base — otherwise the
-- wrapper's extra column would not match v3's row type. The edit is asserted (exactly one occurrence).
--
-- Join keys: the PO primary key where the row has it; otherwise (id_enterprise, id_order), still UNIQUE until
-- the ADR-0062 contract step (which rewrites these functions on id_production_order).
-- Idempotent: an existing <name>_base means "already wrapped" and is skipped.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE FUNCTION pg_temp.adr0062_wrap(p_fn regprocedure, p_join text) RETURNS void
LANGUAGE plpgsql AS $wrap$
DECLARE
  f        pg_proc;
  nsp      text;
  base     text;
  base_fn  regprocedure;
  sig      text;
  cols     text[];
  types    text[];
  decl     text;
  callargs text;
  sel      text;
  g        record;
BEGIN
  SELECT * INTO f FROM pg_proc WHERE oid = p_fn;
  nsp  := f.pronamespace::regnamespace::text;
  base := f.proname || '_base';
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = f.pronamespace AND proname = base) THEN
    RAISE NOTICE 'ADR-0062 P3a: %.% already wrapped — skipped', nsp, f.proname;
    RETURN;
  END IF;
  IF NOT f.proretset THEN
    RAISE EXCEPTION 'ADR-0062 P3a: % is not set-returning', p_fn;
  END IF;

  -- output columns: a composite row type, or RETURNS TABLE (proargmodes 't')
  IF f.prorettype <> 'record'::regtype THEN
    SELECT array_agg(a.attname::text ORDER BY a.attnum), array_agg(format_type(a.atttypid, a.atttypmod) ORDER BY a.attnum)
      INTO cols, types
      FROM pg_attribute a JOIN pg_type t ON t.typrelid = a.attrelid
     WHERE t.oid = f.prorettype AND a.attnum > 0 AND NOT a.attisdropped;
  ELSE
    SELECT array_agg(n ORDER BY i), array_agg(format_type(ty, NULL) ORDER BY i)
      INTO cols, types
      FROM unnest(f.proargnames, f.proallargtypes::oid[], f.proargmodes::text[]) WITH ORDINALITY AS u(n, ty, m, i)
     WHERE m = 't';
  END IF;
  IF cols IS NULL OR 'order_number' = ANY (cols) THEN
    RAISE EXCEPTION 'ADR-0062 P3a: unexpected output columns for %: %', p_fn, cols;
  END IF;

  SELECT string_agg(format('%I %s', c, t), ', ' ORDER BY i), string_agg(format('b.%I', c), ', ' ORDER BY i)
    INTO decl, sel
    FROM unnest(cols, types) WITH ORDINALITY AS u(c, t, i);
  SELECT string_agg('$' || i, ', ') INTO callargs FROM generate_series(1, f.pronargs) i;

  EXECUTE format('ALTER FUNCTION %s RENAME TO %I', p_fn, base);
  base_fn := p_fn;  -- same oid, now named <name>_base
  sig := format('%I.%I(%s)', nsp, f.proname, oidvectortypes(f.proargtypes));

  EXECUTE format($f$
    CREATE FUNCTION %I.%I(%s) RETURNS TABLE (%s, order_number character varying)
    LANGUAGE sql STABLE AS $body$
      SELECT %s, po.id_order_text
        FROM %I.%I(%s) WITH ORDINALITY AS b(%s, adr0062_ord)
        LEFT JOIN core.production_orders po ON %s
       ORDER BY b.adr0062_ord
    $body$$f$,
    nsp, f.proname, pg_get_function_arguments(base_fn), decl,
    sel, nsp, base, callargs,
    (SELECT string_agg(format('%I', c), ', ' ORDER BY i) FROM unnest(cols) WITH ORDINALITY AS u(c, i)),
    p_join);

  -- same EXECUTE privileges as the base (incl. PUBLIC), so no caller loses or gains access
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', sig);
  FOR g IN SELECT (aclexplode(coalesce(f.proacl, acldefault('f', f.proowner)))).* LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %s', sig,
                   CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(g.grantee)) END);
  END LOOP;
  EXECUTE format('ALTER FUNCTION %s OWNER TO %I', sig, pg_get_userbyid(f.proowner));
  EXECUTE format('COMMENT ON FUNCTION %s IS %L', sig,
                 format('ADR-0062 P3a: %s_base + order_number (the client PO number, id_order_text). Join: %s', f.proname, p_join));
END
$wrap$;

-- v2 first, then point v3's fallback at v2_base (before v3 itself is wrapped).
SELECT pg_temp.adr0062_wrap('serving.downtime_events_v2(integer,text,text,text,text,timestamp,timestamp,boolean)',
                            'po.id_enterprise = b.id_enterprise AND po.id_order = b.id_order');
DO $v3$
DECLARE def text; n int;
BEGIN
  IF to_regproc('serving.downtime_events_v3_base') IS NOT NULL THEN RETURN; END IF;
  def := pg_get_functiondef('serving.downtime_events_v3(integer,text,text,text,text,timestamp,timestamp,boolean)'::regprocedure);
  n := (length(def) - length(replace(def, 'serving.downtime_events_v2(', ''))) / length('serving.downtime_events_v2(');
  IF n <> 1 THEN
    RAISE EXCEPTION 'ADR-0062 P3a: expected exactly 1 call to serving.downtime_events_v2( in v3, found %', n;
  END IF;
  EXECUTE replace(def, 'serving.downtime_events_v2(', 'serving.downtime_events_v2_base(');
END
$v3$;
SELECT pg_temp.adr0062_wrap('serving.downtime_events_v3(integer,text,text,text,text,timestamp,timestamp,boolean)',
                            'po.id_enterprise = b.id_enterprise AND po.id_order = b.id_order');
SELECT pg_temp.adr0062_wrap('serving.downtime_events(integer,text,text,text,text,timestamp,timestamp,boolean)',
                            'po.id_enterprise = b.id_enterprise AND po.id_order = b.id_order');
SELECT pg_temp.adr0062_wrap('serving.production_orders(integer,text,text,text,text,timestamp,timestamp,text)',
                            'po.id_production_order = b.id_production_order');
SELECT pg_temp.adr0062_wrap('serving.production_orders_with_runtimes(integer,text,text,text,text,timestamp,timestamp,text)',
                            'po.id_production_order = b.id_production_order');
-- overview_job_info.id_order is the integer rendered as varchar (always digits or '-n')
SELECT pg_temp.adr0062_wrap('serving.overview_job_info(integer)',
                            'po.id_enterprise = b.id_enterprise AND po.id_order = b.id_order::integer');
-- external client contracts (read-api /integration, Montebello): rows carry no id_enterprise → the argument
SELECT pg_temp.adr0062_wrap('serving.data_sync(integer,integer)',
                            'po.id_enterprise = $1 AND po.id_order = b.job');
SELECT pg_temp.adr0062_wrap('serving.downtime_sync(integer)',
                            'po.id_enterprise = $1 AND po.id_order = b.id_order');

COMMIT;
