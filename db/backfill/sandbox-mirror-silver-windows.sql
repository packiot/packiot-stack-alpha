-- sandbox-mirror-silver-windows.sql — one-off: copy CPACK's REPAIRED silver windows onto the
-- SANDBOX-CPACK twin (2026-09-30, staging).
--
-- The twin's silver is its own fanout-fed copy of CPACK's live stream, so it shares CPACK's feed
-- defects but NOT the repairs applied to ent 3 only:
--   * hole 2026-08-27 17:58 → 09-01 00:30 (no silver for ANY tenant; CPACK backfilled from
--     legacy, #1498) — the twin is empty there;
--   * L8-PTH / L10-PTH 2026-09-01 00:30 → 09-29 23:00 (factory tee saturates at 32767; CPACK's
--     74/78 replaced from legacy) — the twin's 2000074/2000078 hold the saturated half.
-- ONE DAY PER CALL: delete the twin's rows → insert CPACK's remapped (+2,000,000; enterprise
-- 2000003). Those days sit in COMPRESSED daily chunks: inserts check UNIQUE(ts_value, id_equipment)
-- against compressed batches (~11 ms/row). NEVER decompress on a shared DB (see p_decompress). Each CALL is its own transaction: progress is durable and resumable (re-running
-- a day replaces it). Then the 7 silver caggs are refreshed over both windows.
\set ON_ERROR_STOP 1
SET statement_timeout = '0';
SET lock_timeout = '10min';   -- queue behind heals / compression jobs instead of failing (resumable either way)

DROP PROCEDURE IF EXISTS ops.sbx_mirror_silver_day(timestamptz, timestamptz, int[], int, int, int);
CREATE OR REPLACE PROCEDURE ops.sbx_mirror_silver_day(p_lo timestamptz, p_hi timestamptz, p_eqs int[], p_off int DEFAULT 2000000, p_src int DEFAULT 3, p_dst int DEFAULT 2000003, p_decompress boolean DEFAULT false)
LANGUAGE plpgsql AS $$
DECLARE ch regclass; was_compressed regclass[] := '{}'; nd bigint; ni bigint; dst_eqs int[];
BEGIN
  IF p_dst < 1000000 OR p_dst = p_src THEN RAISE EXCEPTION 'refusing dst=%', p_dst; END IF;
  SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
  dst_eqs := CASE WHEN p_eqs IS NULL THEN NULL ELSE ARRAY(SELECT e + p_off FROM unnest(p_eqs) e) END;
  -- p_decompress (default OFF): decompress_chunk takes an ACCESS EXCLUSIVE lock on the chunk, so
  -- every reader touching it waits for the whole day's copy. Run with it on staging 2026-09-30,
  -- that queued CPACK's operator /v1/operator-po-details past read-api's 15 s timeout (500s for
  -- ~20 min). Without it, inserts into compressed chunks are slower (~11 ms/row: unique check
  -- against compressed batches) but take only row-level locks — readers never wait.
  IF p_decompress THEN
  FOR ch IN SELECT c FROM show_chunks('silver.equipment_values', newer_than => p_lo - interval '1 day', older_than => p_hi + interval '1 day') c LOOP
    IF EXISTS (SELECT 1 FROM timescaledb_information.chunks i
                WHERE format('%I.%I', i.chunk_schema, i.chunk_name)::regclass = ch AND i.is_compressed
                  AND i.range_start < p_hi AND i.range_end > p_lo) THEN
      PERFORM decompress_chunk(ch, true);
      was_compressed := was_compressed || ch;
    END IF;
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
    PERFORM compress_chunk(ch, true);
  END LOOP;
  RAISE NOTICE 'sbx silver % → %: deleted %, inserted %, recompressed %', p_lo, p_hi, nd, ni, cardinality(was_compressed);
END $$;

-- hole: every equipment; PTH: 74/78 only. One CALL (= one transaction) per day, ONLY for days
-- whose twin rows don't already equal CPACK's (count + Σgross) — so the script is resumable:
-- re-running after an interruption continues where it stopped.
SELECT format('CALL ops.sbx_mirror_silver_day(%L, %L, %L)', lo, hi, eqs)
  FROM (SELECT greatest(d, w.lo) lo, least(d + interval '1 day', w.hi) hi, w.eqs
          FROM (VALUES ('2026-08-27 17:58+00'::timestamptz, '2026-09-01 00:30+00'::timestamptz, NULL::int[]),
                       ('2026-09-01 00:30+00', '2026-09-29 23:00+00', '{74,78}')) w(lo, hi, eqs),
               generate_series(date_trunc('day', w.lo), w.hi - interval '1 second', interval '1 day') d) days
 WHERE (SELECT (count(*) FILTER (WHERE v.id_enterprise = 3), sum(v.gross_production_incr::numeric) FILTER (WHERE v.id_enterprise = 3))
                IS DISTINCT FROM
               (count(*) FILTER (WHERE v.id_enterprise = 2000003), sum(v.gross_production_incr::numeric) FILTER (WHERE v.id_enterprise = 2000003))
          FROM silver.equipment_values v
         WHERE v.id_enterprise IN (3, 2000003) AND v.ts_value >= days.lo AND v.ts_value < days.hi
           AND (days.eqs IS NULL OR v.id_equipment = ANY (days.eqs || ARRAY(SELECT e + 2000000 FROM unnest(days.eqs) e))))
 ORDER BY 1 \gexec

SELECT 'after', w.lo, count(*) FILTER (WHERE v.id_enterprise = 2000003) twin, count(*) FILTER (WHERE v.id_enterprise = 3) cpack,
       round(sum(v.gross_production_incr) FILTER (WHERE v.id_enterprise = 2000003)) twin_gross,
       round(sum(v.gross_production_incr) FILTER (WHERE v.id_enterprise = 3)) cpack_gross
  FROM (VALUES ('2026-08-27 17:58+00'::timestamptz, '2026-09-01 00:30+00'::timestamptz, NULL::int[]),
               ('2026-09-01 00:30+00', '2026-09-29 23:00+00', '{74,78}')) w(lo, hi, eqs)
  JOIN silver.equipment_values v ON v.id_enterprise IN (3, 2000003) AND v.ts_value >= w.lo AND v.ts_value < w.hi
   AND (w.eqs IS NULL OR (v.id_equipment % 2000000) = ANY (w.eqs))
 GROUP BY 2 ORDER BY 2;

CALL refresh_continuous_aggregate('silver.ca_discrete_changes_1s',     '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.ca_equipment_boxes_1s',      '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.agg_equipment_values_1min',  '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_metrics_1min',     '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.agg_equipment_values_1hour', '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1hour','2026-08-27 17:00+00', '2026-09-30 00:00+00');
