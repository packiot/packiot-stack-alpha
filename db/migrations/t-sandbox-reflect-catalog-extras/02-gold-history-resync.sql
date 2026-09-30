-- 02 — ops.sandbox_resync_gold_history: keep the twin's LEGACY-ERA gold history equal to its
-- source, month by month, on every heal.
--
-- WHY (2026-09-30): ops.sandbox_reflect's history layer is FILL-ONLY below the twin's
-- earliest row (ON CONFLICT DO NOTHING). When the source's history is REPAIRED (#1496 re-staged
-- CPACK's gold from legacy, unclamped), the twin keeps its old copy for good: lines' daily net
-- before 2026-09-01 read 216.7M (CPACK) vs 222.7M (twin), avg OEE 0.376 vs 0.342, and the
-- sandbox-front4 parity gate ("2023 OEE score is identical") failed.
--
-- WHAT: for every gold grain, compare per-MONTH fingerprints (rows, Σgross, Σnet, Σoee,
-- Σrunning_time, Σavailable_time) of source vs twin for months before p_before (the engine
-- boundary: before it, gold is the legacy replay and no engine pass ever rewrites it). A month
-- that differs is REPLACED: delete the twin's month, insert the source's month remapped exactly
-- like sandbox_reflect (entity ids + offset, id_team kept, id_runtime_shift from the named
-- sequence). Equal months are skipped, so a steady-state heal costs one fingerprint scan.
-- Months from p_before on belong to the twin's own engine (fed the same telemetry) and are
-- not touched. One COMMIT per replaced month (short locks), triggers suppressed like the reflect.
CREATE OR REPLACE PROCEDURE ops.sandbox_resync_gold_history(
    p_src integer, p_dst integer, p_off integer,
    p_before date DEFAULT '2026-09-01', p_commit boolean DEFAULT true)
LANGUAGE plpgsql AS $$
DECLARE
  g record; m record; sc_src text; sc_dst text; remap text; upper_b date;
  n bigint; replaced int := 0; rows_in bigint := 0;
BEGIN
  IF p_dst < 1000000 OR p_dst = p_src THEN
    RAISE EXCEPTION 'sandbox_resync_gold_history: refusing dst=% (must be a sandbox id >= 1,000,000 and != src)', p_dst;
  END IF;
  SET LOCAL session_replication_role = replica;
  SET LOCAL work_mem = '32MB';
  FOR g IN SELECT * FROM (VALUES
        ('gold.equipment_oee_hourly',  'e', false, false),
        ('gold.equipment_oee_shift',   'e', true,  true),
        ('gold.equipment_oee_daily',   'e', false, false),
        ('gold.equipment_oee_weekly',  'e', false, false),
        ('gold.equipment_oee_monthly', 'e', false, false),
        ('gold.area_oee_shift',        'a', true,  false),
        ('gold.area_oee_daily',        'a', false, false),
        ('gold.site_oee_shift',        's', true,  false)) v(tbl, kind, has_shift, runtime_seq) LOOP
    sc_src := CASE g.kind
      WHEN 'e' THEN format('x.id_equipment IN (SELECT id_equipment FROM core.equipments WHERE id_enterprise = %s)', p_src)
      WHEN 'a' THEN format('x.id_area IN (SELECT a.id_area FROM core.areas a JOIN core.sites s USING (id_site) WHERE s.id_enterprise = %s)', p_src)
      ELSE          format('x.id_site IN (SELECT id_site FROM core.sites WHERE id_enterprise = %s)', p_src) END;
    sc_dst := replace(sc_src, format('= %s)', p_src), format('= %s)', p_dst));
    remap := CASE g.kind WHEN 'e' THEN '''id_equipment'', x.id_equipment + $1'
                         WHEN 'a' THEN '''id_area'', x.id_area + $1'
                         ELSE          '''id_site'', x.id_site + $1' END
          || CASE WHEN g.has_shift THEN ', ''id_shift'', x.id_shift + $1, ''id_shift_hour'', x.id_shift_hour + $1' ELSE '' END
          || CASE WHEN g.runtime_seq THEN ', ''id_runtime_shift'', nextval(''public.equipment_oee_shift_id_seq'')' ELSE '' END;
    FOR m IN EXECUTE format($q$
        WITH c AS (SELECT date_trunc('month', x.ts_value)::date AS mo, count(*) n, round(sum(coalesce(x.gross,0))) g,
                          round(sum(coalesce(x.net,0))) t, round(sum(coalesce(x.oee,0))*1000) o,
                          round(sum(coalesce(x.running_time,0))) r, round(sum(coalesce(x.available_time,0))) a
                     FROM %1$s x WHERE %2$s AND x.ts_value < %4$L GROUP BY 1),
             s AS (SELECT date_trunc('month', x.ts_value)::date AS mo, count(*) n, round(sum(coalesce(x.gross,0))) g,
                          round(sum(coalesce(x.net,0))) t, round(sum(coalesce(x.oee,0))*1000) o,
                          round(sum(coalesce(x.running_time,0))) r, round(sum(coalesce(x.available_time,0))) a
                     FROM %1$s x WHERE %3$s AND x.ts_value < %4$L GROUP BY 1)
        SELECT coalesce(c.mo, s.mo) AS mo
          FROM c FULL JOIN s USING (mo)
         WHERE (c.n, c.g, c.t, c.o, c.r, c.a) IS DISTINCT FROM (s.n, s.g, s.t, s.o, s.r, s.a)
         ORDER BY 1 $q$, g.tbl, sc_src, sc_dst, p_before) LOOP
      upper_b := least((m.mo + interval '1 month')::date, p_before);
      -- literal month bounds: plan-time chunk exclusion (see sandbox_reflect's note)
      EXECUTE format('DELETE FROM %1$s x WHERE %2$s AND x.ts_value >= %3$L AND x.ts_value < %4$L',
                     g.tbl, sc_dst, m.mo, upper_b);
      EXECUTE format($q$
        INSERT INTO %1$s SELECT (jsonb_populate_record(NULL::%1$s, to_jsonb(x) || jsonb_build_object(%2$s))).*
          FROM %1$s x WHERE %3$s AND x.ts_value >= %4$L AND x.ts_value < %5$L $q$,
        g.tbl, remap, sc_src, m.mo, upper_b) USING p_off;
      GET DIAGNOSTICS n = ROW_COUNT;
      replaced := replaced + 1; rows_in := rows_in + n;
      RAISE NOTICE 'resync % % → % rows', g.tbl, to_char(m.mo, 'YYYY-MM'), n;
      IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; SET LOCAL work_mem = '32MB'; END IF;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'gold history resync (before %): % month-grains replaced, % rows', p_before, replaced, rows_in;
END $$;
COMMENT ON PROCEDURE ops.sandbox_resync_gold_history(integer, integer, integer, date, boolean) IS
  'Replace every month (before p_before, the engine boundary) of the twin''s gold grains whose fingerprint differs from the source''s, so repairs of the source''s history reach the twin. Called by the sandbox heal after ops.sandbox_reflect. See db/migrations/t-sandbox-reflect-catalog-extras/02.';
