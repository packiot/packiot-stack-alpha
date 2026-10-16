-- verify t-adr0062-p3a-order-number-readers — read-only. Every check RAISEs on failure.
--   W1 structure: each public name returns order_number; its <name>_base exists; same EXECUTE grantees
--   W2 v3's fallback calls downtime_events_v2_base (not the wrapper)
--   W3 equivalence by construction: wrapper minus order_number ≡ base, row for row IN ORDER, on real scopes
--      (every enterprise with POs in the last 30 days; downtime functions on 7 days to stay inside the SSM cap)
--   W4 order_number = the PO's id_order_text on every row that names a PO
\set ON_ERROR_STOP 1
SET statement_timeout = '400s';

DO $w1$
DECLARE r record; missing text[] := '{}';
BEGIN
  FOR r IN SELECT unnest(ARRAY['downtime_events','downtime_events_v2','downtime_events_v3','production_orders',
                               'production_orders_with_runtimes','overview_job_info','data_sync','downtime_sync']) AS fn LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'serving'::regnamespace AND proname = r.fn
                     AND pg_get_function_result(oid) ~ '\morder_number character varying\)$') THEN
      missing := missing || (r.fn || ': no order_number');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'serving'::regnamespace AND proname = r.fn || '_base') THEN
      missing := missing || (r.fn || '_base: missing');
    END IF;
    IF (SELECT array_agg(DISTINCT a.grantee ORDER BY a.grantee) FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         WHERE p.pronamespace = 'serving'::regnamespace AND p.proname = r.fn)
       IS DISTINCT FROM
       (SELECT array_agg(DISTINCT a.grantee ORDER BY a.grantee) FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         WHERE p.pronamespace = 'serving'::regnamespace AND p.proname = r.fn || '_base') THEN
      missing := missing || (r.fn || ': grantees differ from _base');
    END IF;
  END LOOP;
  IF cardinality(missing) > 0 THEN RAISE EXCEPTION 'W1 FAIL: %', missing; END IF;
  RAISE NOTICE 'W1 OK: 8 wrappers, bases present, same grantees';
END
$w1$;

DO $w2$
BEGIN
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'serving.downtime_events_v3_base'::regproc) !~ 'serving\.downtime_events_v2_base\('
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'serving.downtime_events_v3_base'::regproc) ~ 'serving\.downtime_events_v2\(' THEN
    RAISE EXCEPTION 'W2 FAIL: downtime_events_v3_base must call downtime_events_v2_base';
  END IF;
  RAISE NOTICE 'W2 OK: v3 fallback → v2_base';
END
$w2$;

DO $w3$
DECLARE e int; c record; n_calls int := 0; n_rows bigint := 0; diffs text[] := '{}'; bad bigint; wr jsonb; br jsonb; k bigint;
BEGIN
  FOR e IN SELECT DISTINCT id_enterprise FROM core.production_orders WHERE ts_start >= now() - interval '30 days' ORDER BY 1 LOOP
    PERFORM set_config('app.current_enterprise', e::text, true);  -- harmless for superuser; keeps RLS honest otherwise
    FOR c IN SELECT * FROM (VALUES
      ('production_orders', format('serving.%%s(%s,''{}'',''{}'',''{}'',''{}'',%L,%L,''{}'')', e, (now() - interval '30 days')::timestamp, now()::timestamp), 'id_production_order'),
      ('production_orders_with_runtimes', format('serving.%%s(%s,''{}'',''{}'',''{}'',''{}'',%L,%L,''{}'')', e, (now() - interval '30 days')::timestamp, now()::timestamp), 'id_production_order'),
      ('downtime_events_v3', format('serving.%%s(%s,''{}'',''{}'',''{}'',''{}'',%L,%L,false)', e, (now() - interval '7 days')::timestamp, now()::timestamp), 'id_order'),
      ('downtime_events_v3', format('serving.%%s(%s,''{}'',''{}'',''{}'',''{}'',%L,%L,true)', e, (now() - interval '7 days')::timestamp, now()::timestamp), 'id_order')
    ) v(fn, call, key) LOOP
      EXECUTE format('SELECT count(*), coalesce(jsonb_agg(to_jsonb(t) - ''ordinality'' - ''order_number'' ORDER BY t.ordinality), ''[]'') FROM %s WITH ORDINALITY t',
                     format(c.call, c.fn)) INTO k, wr;
      EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) - ''ordinality'' ORDER BY t.ordinality), ''[]'') FROM %s WITH ORDINALITY t',
                     format(c.call, c.fn || '_base')) INTO br;
      IF wr IS DISTINCT FROM br THEN diffs := diffs || format('%s ent %s', c.fn, e); END IF;
      -- W4
      EXECUTE format($q$SELECT count(*) FROM %s t WHERE t.%I IS NOT NULL AND t.order_number IS DISTINCT FROM
                       (SELECT po.id_order_text FROM core.production_orders po WHERE %s)$q$,
                     format(c.call, c.fn), c.key,
                     CASE c.key WHEN 'id_production_order' THEN 'po.id_production_order = t.id_production_order'
                                ELSE format('po.id_enterprise = %s AND po.id_order = t.id_order', e) END) INTO bad;
      IF bad > 0 THEN diffs := diffs || format('%s ent %s: %s rows wrong order_number', c.fn, e, bad); END IF;
      n_calls := n_calls + 1; n_rows := n_rows + k;
    END LOOP;
  END LOOP;
  IF cardinality(diffs) > 0 THEN RAISE EXCEPTION 'W3/W4 FAIL: %', diffs; END IF;
  RAISE NOTICE 'W3/W4 OK: % calls, % rows — wrapper ≡ base in order; order_number = id_order_text', n_calls, n_rows;
END
$w3$;

-- the slow legacy generations (v2 exact path ~20 s cold, v1): one enterprise, one day, equivalence only
DO $w3b$
DECLARE e int; fn text; wr jsonb; br jsonb;
BEGIN
  SELECT id_enterprise INTO e FROM core.production_orders WHERE ts_start >= now() - interval '30 days'
   GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;
  IF e IS NULL THEN RAISE NOTICE 'W3b skipped: no recent POs'; RETURN; END IF;
  FOREACH fn IN ARRAY ARRAY['downtime_events_v2', 'downtime_events'] LOOP
    EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) - ''ordinality'' - ''order_number'' ORDER BY t.ordinality), ''[]'') FROM serving.%I(%s,''{}'',''{}'',''{}'',''{}'',%L,%L,false) WITH ORDINALITY t',
                   fn, e, (now() - interval '1 day')::timestamp, now()::timestamp) INTO wr;
    EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) - ''ordinality'' ORDER BY t.ordinality), ''[]'') FROM serving.%I(%s,''{}'',''{}'',''{}'',''{}'',%L,%L,false) WITH ORDINALITY t',
                   fn || '_base', e, (now() - interval '1 day')::timestamp, now()::timestamp) INTO br;
    IF wr IS DISTINCT FROM br THEN RAISE EXCEPTION 'W3b FAIL: % ent %', fn, e; END IF;
  END LOOP;
  RAISE NOTICE 'W3b OK: downtime_events_v2 + downtime_events ≡ base (ent %, 1 day)', e;
END
$w3b$;
