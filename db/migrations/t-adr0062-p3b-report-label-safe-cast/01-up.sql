-- t-adr0062-p3b-report-label-safe-cast — ADR-0062 step 3b: a non-numeric box label must not crash a report.
--
-- The Neopac/SAP report functions join the PLC box label (silver text, the PO number the line printed) to the
-- integer PO number with a HARD cast: cast(l.label_job as integer), pack.label_job::bigint,
-- fl.id_order::integer. Since ADR-0062 a client number may be alphanumeric — one such label in the window makes
-- the whole report raise 22P02 (invalid input syntax for type integer) and the client gets nothing.
--
-- Fix, numeric behaviour unchanged by construction: core.try_int4/try_int8(text) return exactly the cast's value
-- for every input the cast accepts, and NULL (no match) where the cast would raise. Each body is edited ONLY at
-- those cast sites (asserted counts per pattern). Text-keyed matching of alphanumeric labels is the contract
-- step (rekey on id_production_order), not this one.
--
-- The previous bodies are kept as <name>_pre_p3b so verify.sql can prove new ≡ old on live data; the contract
-- step drops them. Idempotent: an existing <name>_pre_p3b means "already applied".

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION core.try_int4(v text) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN v ~ '^\s*[+-]?[0-9]+\s*$' AND btrim(v)::numeric BETWEEN -2147483648 AND 2147483647
              THEN btrim(v)::integer END
$$;
CREATE OR REPLACE FUNCTION core.try_int8(v text) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN v ~ '^\s*[+-]?[0-9]+\s*$' AND btrim(v)::numeric BETWEEN -9223372036854775808 AND 9223372036854775807
              THEN btrim(v)::bigint END
$$;
COMMENT ON FUNCTION core.try_int4(text) IS 'ADR-0062: v::integer where the cast succeeds, else NULL (never raises). For joining free-text PO labels.';
COMMENT ON FUNCTION core.try_int8(text) IS 'ADR-0062: v::bigint where the cast succeeds, else NULL (never raises). For joining free-text PO labels.';
GRANT EXECUTE ON FUNCTION core.try_int4(text), core.try_int8(text) TO PUBLIC;

CREATE FUNCTION pg_temp.adr0062_safe_casts(p_fn regprocedure, p_expected jsonb) RETURNS void
LANGUAGE plpgsql AS $fx$
DECLARE
  f    pg_proc;
  def  text;
  r    record;
  n    int;
  pre  text;
  sig  text;
  g    record;
BEGIN
  SELECT * INTO f FROM pg_proc WHERE oid = p_fn;
  pre := f.proname || '_pre_p3b';
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = f.pronamespace AND proname = pre) THEN
    RAISE NOTICE 'ADR-0062 P3b: % already applied — skipped', p_fn;
    RETURN;
  END IF;
  def := pg_get_functiondef(p_fn);
  -- (pattern, replacement) in order: parenthesized forms before bare ones
  FOR r IN SELECT * FROM (VALUES
      (1, 'cast\(\s*\ml\.label_job\s+as\s+integer\s*\)', 'core.try_int4(l.label_job)'),
      (2, '\(\ml\.label_job\)::integer',                  'core.try_int4(l.label_job)'),
      (3, '\ml\.label_job::integer',                      'core.try_int4(l.label_job)'),
      (4, '\(\mpack\.label_job\)::bigint',                'core.try_int8(pack.label_job)'),
      (5, '\mpack\.label_job::bigint',                    'core.try_int8(pack.label_job)'),
      (6, '\(\mfl\.id_order\)::integer',                  'core.try_int4(fl.id_order)'),
      (7, '\mfl\.id_order::integer',                      'core.try_int4(fl.id_order)')
    ) v(k, pat, rep) ORDER BY k LOOP
    SELECT count(*) INTO n FROM regexp_matches(def, r.pat, 'gi');
    IF n <> coalesce((p_expected ->> r.k::text)::int, 0) THEN
      RAISE EXCEPTION 'ADR-0062 P3b: % pattern % (%) matched % times, expected %', p_fn, r.k, r.pat, n,
                      coalesce((p_expected ->> r.k::text)::int, 0);
    END IF;
    def := regexp_replace(def, r.pat, r.rep, 'gi');
  END LOOP;
  IF def ~* '(label_job\)?::(int|bigint)|cast\(\s*l\.label_job|fl\.id_order\)?::int)' THEN
    RAISE EXCEPTION 'ADR-0062 P3b: % still has a hard label cast after rewrite', p_fn;
  END IF;

  sig := format('%s.%I(%s)', f.pronamespace::regnamespace, f.proname, oidvectortypes(f.proargtypes));
  EXECUTE format('ALTER FUNCTION %s RENAME TO %I', p_fn, pre);
  EXECUTE def;  -- CREATE OR REPLACE under the original name: a new function (the original is renamed)
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', sig);
  FOR g IN SELECT (aclexplode(coalesce(f.proacl, acldefault('f', f.proowner)))).* LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %s', sig,
                   CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(g.grantee)) END);
  END LOOP;
  EXECUTE format('ALTER FUNCTION %s OWNER TO %I', sig, pg_get_userbyid(f.proowner));
  EXECUTE format('COMMENT ON FUNCTION %s IS %L', sig,
                 coalesce(obj_description(p_fn, 'pg_proc') || ' | ', '') ||
                 'ADR-0062 P3b: label casts are core.try_int4/try_int8 (non-numeric label = no match, not an error).');
END
$fx$;

SELECT pg_temp.adr0062_safe_casts('serving.report_shift(integer,date,date)',          '{"1": 3, "5": 3}');
SELECT pg_temp.adr0062_safe_casts('serving.sap_site_report(integer,integer)',         '{"3": 1, "5": 3}');
SELECT pg_temp.adr0062_safe_casts('serving.sap_report_data_sync(integer)',            '{"4": 3, "5": 3, "6": 2, "7": 2}');

COMMIT;
