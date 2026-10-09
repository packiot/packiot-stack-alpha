-- verify t-adr0062-p3b-report-label-safe-cast — read-only. Every check RAISEs on failure.
--   S1 core.try_int4/try_int8 ≡ the hard cast wherever the cast succeeds, NULL where it raises —
--      on edge cases + every live label of the last 7 days + every client PO number
--   S2 the 3 report functions: no hard label cast left; <name>_pre_p3b present; same grantees
--   S3 new ≡ pre on live data for every enterprise with labelled equipment (7 days). If the PRE body raises
--      (a non-numeric label is live), that is the bug this fixes: reported as NOTICE, and new must not raise.
\set ON_ERROR_STOP 1
SET statement_timeout = '400s';

CREATE FUNCTION pg_temp.c4(v text) RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN v::int; EXCEPTION WHEN others THEN RETURN NULL; END $$;
CREATE FUNCTION pg_temp.c8(v text) RETURNS bigint LANGUAGE plpgsql AS $$ BEGIN RETURN v::bigint; EXCEPTION WHEN others THEN RETURN NULL; END $$;

DO $s1$
DECLARE n bigint; bad bigint;
BEGIN
  WITH s(v) AS (
    SELECT unnest(ARRAY['0','-0','+0','08396260',' 123','123 ',E'\t42\n','+7','-7','2147483647','2147483648','-2147483648',
                        '-2147483649','9223372036854775807','9223372036854775808','-9223372036854775808','','  ','OP-77A',
                        '834.058','1e3','12a','1_000','0x1F','--1', NULL])
    UNION ALL SELECT DISTINCT id_order FROM silver.ca_equipment_boxes_1s WHERE ts_value >= now() - interval '7 days'
    UNION ALL SELECT DISTINCT id_order FROM customer_reports.boxes WHERE ts_value >= now() - interval '7 days'
    UNION ALL SELECT id_order_text FROM core.production_orders
  )
  SELECT count(*), count(*) FILTER (WHERE core.try_int4(v) IS DISTINCT FROM pg_temp.c4(v)
                                       OR core.try_int8(v) IS DISTINCT FROM pg_temp.c8(v))
    INTO n, bad FROM s;
  IF bad > 0 THEN RAISE EXCEPTION 'S1 FAIL: % of % samples differ from the cast', bad, n; END IF;
  RAISE NOTICE 'S1 OK: try_int4/try_int8 ≡ cast on % samples', n;
END
$s1$;

DO $s2$
DECLARE fn text; problems text[] := '{}';
BEGIN
  FOREACH fn IN ARRAY ARRAY['report_shift', 'sap_site_report', 'sap_report_data_sync'] LOOP
    IF (SELECT prosrc FROM pg_proc WHERE pronamespace = 'serving'::regnamespace AND proname = fn)
       ~* '(label_job\)?::(int|bigint)|cast\(\s*l\.label_job|fl\.id_order\)?::int)' THEN
      problems := problems || (fn || ': hard cast left');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'serving'::regnamespace AND proname = fn || '_pre_p3b') THEN
      problems := problems || (fn || '_pre_p3b: missing');
    END IF;
    IF (SELECT array_agg(DISTINCT a.grantee ORDER BY a.grantee) FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         WHERE p.pronamespace = 'serving'::regnamespace AND p.proname = fn)
       IS DISTINCT FROM
       (SELECT array_agg(DISTINCT a.grantee ORDER BY a.grantee) FROM pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
         WHERE p.pronamespace = 'serving'::regnamespace AND p.proname = fn || '_pre_p3b') THEN
      problems := problems || (fn || ': grantees differ');
    END IF;
  END LOOP;
  IF cardinality(problems) > 0 THEN RAISE EXCEPTION 'S2 FAIL: %', problems; END IF;
  RAISE NOTICE 'S2 OK: 3 functions rewritten, pre bodies kept, same grantees';
END
$s2$;

DO $s3$
DECLARE e record; c record; newj jsonb; prej jsonb; calls int := 0; fixed int := 0;
BEGIN
  FOR e IN SELECT eq.id_enterprise, min(coalesce(eq.id_parentequipment, eq.id_equipment)) AS id_line
             FROM equipments eq
            WHERE (eq.custom::json #>> '{Label,has_labels}')::boolean IS TRUE
            GROUP BY 1 ORDER BY 1 LOOP
    FOR c IN SELECT * FROM (VALUES
        (format('serving.%%s(%s, %L::date, %L::date)', e.id_enterprise, current_date - 7, current_date), 'report_shift'),
        (format('serving.%%s(%s, %s)', e.id_enterprise, e.id_line), 'sap_site_report'),
        (format('serving.%%s(%s)', e.id_enterprise), 'sap_report_data_sync')) v(call, fn) LOOP
      EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]'') FROM %s t', format(c.call, c.fn)) INTO newj;
      BEGIN
        EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]'') FROM %s t', format(c.call, c.fn || '_pre_p3b')) INTO prej;
      EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE NOTICE 'S3: % ent % — the PRE body raises (%) on live labels; the new one returns % rows', c.fn, e.id_enterprise, SQLERRM, jsonb_array_length(newj);
        fixed := fixed + 1; calls := calls + 1;
        CONTINUE;
      END;
      IF newj IS DISTINCT FROM prej THEN
        RAISE EXCEPTION 'S3 FAIL: % ent % — new ≠ pre (% vs % rows)', c.fn, e.id_enterprise, jsonb_array_length(newj), jsonb_array_length(prej);
      END IF;
      calls := calls + 1;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'S3 OK: % calls new ≡ pre (% where only the new body succeeds)', calls, fixed;
END
$s3$;
