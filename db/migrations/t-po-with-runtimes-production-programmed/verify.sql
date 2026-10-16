-- verify t-po-with-runtimes-production-programmed — read-only; every check RAISEs on failure.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
DO $v$
DECLARE
  fn CONSTANT regprocedure := 'serving.production_orders_with_runtimes(integer,text,text,text,text,timestamp,timestamp,text)';
  n_w bigint; n_b bigint; n_bad bigint; n_pp bigint;
BEGIN
  -- V1 shape: trailing (order_number, production_programmed); arguments unchanged
  IF (SELECT proargnames[array_upper(proargnames,1)-1:array_upper(proargnames,1)] FROM pg_proc WHERE oid = fn)
     IS DISTINCT FROM ARRAY['order_number','production_programmed'] THEN
    RAISE EXCEPTION 'V1: wrapper does not end with (order_number, production_programmed)';
  END IF;
  IF pg_get_function_arguments(fn) NOT LIKE 'in_id_enterprise integer, in_ids_sites text%DEFAULT%' THEN
    RAISE EXCEPTION 'V1: argument names/defaults changed: %', pg_get_function_arguments(fn);
  END IF;
  -- V2 grants: every role that could execute before still can
  IF NOT (has_function_privilege('readapi_ro', fn, 'EXECUTE') AND has_function_privilege('superset_ro', fn, 'EXECUTE')
          AND has_function_privilege('bi_owner', fn, 'EXECUTE')
          AND (SELECT bool_or(grantee = 0) FROM pg_proc, aclexplode(proacl) WHERE oid = fn)) THEN
    RAISE EXCEPTION 'V2: EXECUTE grants not restored';
  END IF;
  -- V3 wrapper ≡ base (same rows, same order) and production_programmed = the PO row's value, CPACK last 60 days
  SELECT count(*) INTO n_b FROM serving.production_orders_with_runtimes_base(3,'{}','{}','{}','{}',(now()-interval '60 days')::timestamp, now()::timestamp,'{}');
  SELECT count(*), count(*) FILTER (WHERE w.production_programmed IS DISTINCT FROM po.production_programmed),
         count(w.production_programmed)
    INTO n_w, n_bad, n_pp
    FROM serving.production_orders_with_runtimes(3,'{}','{}','{}','{}',(now()-interval '60 days')::timestamp, now()::timestamp,'{}') w
    LEFT JOIN core.production_orders po USING (id_production_order);
  IF n_w <> n_b OR n_bad <> 0 THEN
    RAISE EXCEPTION 'V3: wrapper rows % vs base % ; production_programmed mismatches %', n_w, n_b, n_bad;
  END IF;
  RAISE NOTICE 'OK: % rows (= base), % with production_programmed', n_w, n_pp;
END
$v$;
ROLLBACK;
