-- t-ts-c4-ts-optional — ADR-0063 Phase C4 prep: our own objects work with and without the
-- timescaledb extension (2026-10-15). Staging is about to DROP EXTENSION; production keeps
-- TimescaleDB until its own Phase B/C, so every change here behaves identically on a
-- TimescaleDB database and degrades to a no-op on a plain one.
--   * ops.ts_retention_live(): the live TimescaleDB retention policies, read with dynamic SQL so
--     nothing depends on timescaledb_information statically (a view that did would be dropped by
--     DROP EXTENSION ... CASCADE, or block it). Empty set without the extension.
--   * ops.retention_drift: reads that function instead of timescaledb_information.jobs.
--   * ops.apply_retention(): hypertable/cagg rows only touch TimescaleDB policies when the
--     extension is there; without it they are a loud WARNING (nothing can enforce them).
--   * ops.sbx_mirror_silver_day(): the decompression GUC via set_config only with the extension;
--     p_decompress=true without it is an error (there is nothing to decompress).
-- silver.rollup_refresh already uses date_bin/array_agg (no TimescaleDB calls) — unchanged.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION ops.ts_retention_live()
RETURNS TABLE (relation text, live_keep interval)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN RETURN; END IF;
  RETURN QUERY EXECUTE
    $q$SELECT (j.hypertable_schema || '.' || j.hypertable_name)::text, (j.config ->> 'drop_after')::interval
         FROM timescaledb_information.jobs j WHERE j.proc_name = 'policy_retention'$q$;
END $fn$;
COMMENT ON FUNCTION ops.ts_retention_live() IS
  'ADR-0063 C4: live TimescaleDB retention policies (relation, drop_after); empty without the extension';

CREATE OR REPLACE VIEW ops.retention_drift AS
WITH live AS (SELECT relation, live_keep FROM ops.ts_retention_live())
-- COLLATE "C": the old column came from name || name, and CREATE OR REPLACE VIEW cannot change a
-- column's collation (staging 2026-10-15)
SELECT COALESCE(p.relation, l.relation) COLLATE "C" AS relation,
       p.keep AS catalog_keep,
       l.live_keep,
       CASE
         WHEN p.relation IS NULL THEN 'live policy not in catalog'::text
         WHEN p.keep IS NULL THEN 'catalog=forever but live drops'::text
         WHEN l.relation IS NULL THEN 'catalog bounds but no live policy'::text
         ELSE 'keep differs'::text
       END AS problem
  FROM (SELECT relation, kind, time_expr, keep, tier, purge_order, cold_copy, rationale, updated_at
          FROM ops.retention_policy
         WHERE kind = ANY (ARRAY['hypertable'::text, 'cagg'::text])) p
  FULL JOIN live l USING (relation)
 WHERE p.keep IS DISTINCT FROM l.live_keep;

CREATE OR REPLACE PROCEDURE ops.apply_retention()
LANGUAGE plpgsql
AS $procedure$
DECLARE r record; live interval;
  ts boolean := EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb');
BEGIN
  FOR r IN SELECT * FROM ops.retention_policy ORDER BY relation LOOP
    -- validate the time expression against the relation (fail loud on typos)
    EXECUTE format('SELECT %s FROM %s LIMIT 0', r.time_expr, r.relation);
    CONTINUE WHEN r.kind = 'plain';
    IF NOT ts THEN
      RAISE WARNING 'retention % : kind % but no timescaledb extension — not enforced (convert it to plain)', r.relation, r.kind;
      CONTINUE;
    END IF;
    SELECT l.live_keep INTO live FROM ops.ts_retention_live() l WHERE l.relation = r.relation;
    IF r.keep IS NOT DISTINCT FROM live THEN CONTINUE; END IF;
    EXECUTE 'SELECT remove_retention_policy($1, if_exists => true)' USING r.relation::regclass;
    IF r.keep IS NOT NULL THEN
      EXECUTE 'SELECT add_retention_policy($1, drop_after => $2)' USING r.relation::regclass, r.keep;
    END IF;
    RAISE NOTICE 'retention % : % -> %', r.relation, coalesce(live::text,'forever'), coalesce(r.keep::text,'forever');
  END LOOP;
END $procedure$;

CREATE OR REPLACE PROCEDURE ops.sbx_mirror_silver_day(IN p_lo timestamp with time zone, IN p_hi timestamp with time zone, IN p_eqs integer[], IN p_off integer DEFAULT 2000000, IN p_src integer DEFAULT 3, IN p_dst integer DEFAULT 2000003, IN p_decompress boolean DEFAULT false)
LANGUAGE plpgsql
AS $procedure$
DECLARE ch regclass; was_compressed regclass[] := '{}'; nd bigint; ni bigint; dst_eqs int[];
  ts boolean := EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb');
BEGIN
  IF p_dst < 1000000 OR p_dst = p_src THEN RAISE EXCEPTION 'refusing dst=%', p_dst; END IF;
  IF p_decompress AND NOT ts THEN RAISE EXCEPTION 'p_decompress needs the timescaledb extension'; END IF;
  IF ts THEN PERFORM set_config('timescaledb.max_tuples_decompressed_per_dml_transaction', '0', true); END IF;
  dst_eqs := CASE WHEN p_eqs IS NULL THEN NULL ELSE ARRAY(SELECT e + p_off FROM unnest(p_eqs) e) END;
  -- p_decompress (default OFF): decompress_chunk takes an ACCESS EXCLUSIVE lock on the chunk, so
  -- every reader touching it waits for the whole day's copy. Run with it on staging 2026-09-30,
  -- that queued CPACK's operator /v1/operator-po-details past read-api's 15 s timeout (500s for
  -- ~20 min). Without it, inserts into compressed chunks are slower (~11 ms/row: unique check
  -- against compressed batches) but take only row-level locks — readers never wait.
  IF p_decompress THEN
  FOR ch IN EXECUTE $q$SELECT c FROM show_chunks('silver.equipment_values', newer_than => $1 - interval '1 day', older_than => $2 + interval '1 day') c
                        WHERE EXISTS (SELECT 1 FROM timescaledb_information.chunks i
                                       WHERE format('%I.%I', i.chunk_schema, i.chunk_name)::regclass = c AND i.is_compressed
                                         AND i.range_start < $2 AND i.range_end > $1)$q$ USING p_lo, p_hi LOOP
    EXECUTE 'SELECT decompress_chunk($1, true)' USING ch;
    was_compressed := was_compressed || ch;
  END LOOP;
  END IF;
  DELETE FROM silver.equipment_values v
   WHERE v.id_enterprise = p_dst AND v.ts_value >= p_lo AND v.ts_value < p_hi
     AND (dst_eqs IS NULL OR v.id_equipment = ANY (dst_eqs));
  GET DIAGNOSTICS nd = ROW_COUNT;
  INSERT INTO silver.equipment_values
  SELECT (jsonb_populate_record(NULL::silver.equipment_values, to_jsonb(x) || jsonb_build_object(
          'id_enterprise', p_dst, 'id_equipment', x.id_equipment + p_off,
          'id_site', x.id_site + p_off, 'id_area', x.id_area + p_off,
          'id_equipment_line_infeed',    x.id_equipment_line_infeed + p_off,
          'id_equipment_line_outfeed',   x.id_equipment_line_outfeed + p_off,
          'id_equipment_line_connected', x.id_equipment_line_connected + p_off,
          'id_production_order', NULL, 'id_shift', x.id_shift + p_off, 'id_shift_hour', x.id_shift_hour + p_off,
          'ingested_at', now()))).*
    FROM silver.equipment_values x
   WHERE x.id_enterprise = p_src AND x.ts_value >= p_lo AND x.ts_value < p_hi
     AND (p_eqs IS NULL OR x.id_equipment = ANY (p_eqs));
  GET DIAGNOSTICS ni = ROW_COUNT;
  FOREACH ch IN ARRAY was_compressed LOOP
    EXECUTE 'SELECT compress_chunk($1, true)' USING ch;
  END LOOP;
  RAISE NOTICE 'sbx silver % → %: deleted %, inserted %, recompressed %', p_lo, p_hi, nd, ni, cardinality(was_compressed);
END $procedure$;

COMMIT;
