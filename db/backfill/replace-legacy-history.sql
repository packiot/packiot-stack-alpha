-- replace-legacy-history.sql — step 2 of scripts/analytics-legacy-history-replace.sh (2026-09-29).
-- STAGING ONLY (user-approved 2026-09-29: "full history, staging stack only").
-- REPLACES CPACK (ent 3) gold history before production day 2026-09-01 with the re-staged
-- legacy rows (ops.bf2_*), in ONE transaction:
--   psql -d packiot_analytics -v mode=dry   -f db/backfill/replace-legacy-history.sql   # ROLLBACK
--   psql -d packiot_analytics -v mode=apply -f db/backfill/replace-legacy-history.sql   # COMMIT
-- Per grain: (1) impossibility guard on the staging rows, (2) snapshot the live window into
-- ops._bkp_hist_replace_<table>, (3) DELETE the window, (4) ops.bf_merge the staging rows.
--
-- WINDOW = the ts_value range the STAGING rows cover (fixed 2026-10-14). The 2026-09-29 run keyed
-- the hourly window on the stored label (ts_value_production::date < 09-01); that label still had
-- the run-minute bug (#1727), so CPACK's 09-01 02:00 UTC hour was labelled 08-31, deleted, and —
-- legacy labelling it 09-01 (minute-59 rule) — never re-inserted (62 rows lost). Never select rows
-- to delete by a DERIVED label; bound by the key (ts_value) the replacement actually covers.
-- UNREPLACED GUARD: rows the window would delete with no staged (key, ts_value) replacement are
-- counted (report column `unreplaced`); mode=apply aborts if any, unless -v allow_unreplaced=1.
--
-- IMPOSSIBILITY GUARD (policy 2026-09-29: store facts raw, exclude only the impossible and record
-- it): a gross/net above 20x the configured speed over the whole period (and > 1000) cannot be
-- production — legacy carries totalizer-in-increment garbage (e.g. L5-POLYTYPE 13.6e9 in one day,
-- 2022-10..2023-09). That MEASURE becomes NULL (scrap and the factors that use it too) and an
-- IMPOSSIBLE_COUNT data_quality_event records the observed value (equipment grains). Anything
-- below the bound — including net > gross (undercounting infeed, transit) — is kept as measured.
-- Speed: equipments.production_speed (a line also takes its lead machine's if higher); areas and
-- sites use the sum over their lines. No configured speed → no bound (value kept).
\set ON_ERROR_STOP 1
SET statement_timeout = '60min';
SET lock_timeout = '60s';
BEGIN;

CREATE TEMP TABLE rp (stage text, target text, kind text, pk text[], skip text[], grain text, minutes text, win text) ON COMMIT DROP;
INSERT INTO rp VALUES
 ('ops.bf2_equipment_oee_hourly',  'gold.equipment_oee_hourly',  'eq',   '{id_equipment,ts_value}', '{}',              'hour',  '60'),
 ('ops.bf2_equipment_oee_shift',   'gold.equipment_oee_shift',   'eq',   '{id_equipment,ts_value}', '{id_runtime_shift}',
  'shift', $$extract(epoch FROM (upper(s.ts_range::tstzrange) - lower(s.ts_range::tstzrange)))/60$$),
 ('ops.bf2_equipment_oee_daily',   'gold.equipment_oee_daily',   'eq',   '{id_equipment,ts_value}', '{}',              'day',   '1500'),
 ('ops.bf2_equipment_oee_weekly',  'gold.equipment_oee_weekly',  'eq',   '{id_equipment,ts_value}', '{}',              'week',  '10080'),
 ('ops.bf2_equipment_oee_monthly', 'gold.equipment_oee_monthly', 'eq',   '{id_equipment,ts_value}', '{}',              'month', '44640');
DELETE FROM rp WHERE to_regclass(stage) IS NULL;
-- window = [min, max] ts_value of the staging table, as LITERALS (a subquery bound is a stable
-- expression → no chunk exclusion, and DML on compressed chunks needs literal bounds).
DO $$
DECLARE r record; lo timestamptz; hi timestamptz;
BEGIN
  FOR r IN SELECT stage FROM rp LOOP
    EXECUTE format('SELECT min(ts_value)::timestamptz, max(ts_value)::timestamptz FROM %s', r.stage) INTO lo, hi;
    IF lo IS NULL THEN RAISE EXCEPTION 'staging table % is empty', r.stage; END IF;
    UPDATE rp SET win = format('ts_value BETWEEN %L AND %L', lo, hi) WHERE stage = r.stage;
  END LOOP;
END $$;

-- bound speeds (units/min) per key
CREATE TEMP TABLE sp_eq ON COMMIT DROP AS
  SELECT e.id_equipment AS k, GREATEST(COALESCE(e.production_speed,0), COALESCE(lm.production_speed,0))::float8 AS spd
    FROM core.equipments e LEFT JOIN core.equipments lm ON lm.id_equipment = e.lead_machine WHERE e.id_enterprise = 3;
CREATE TEMP TABLE sp_area ON COMMIT DROP AS
  SELECT e.id_area AS k, sum(GREATEST(COALESCE(e.production_speed,0), COALESCE(lm.production_speed,0)))::float8 AS spd
    FROM core.equipments e LEFT JOIN core.equipments lm ON lm.id_equipment = e.lead_machine WHERE e.id_enterprise = 3 AND e.tp_equipment = 3 GROUP BY 1;
CREATE TEMP TABLE sp_site ON COMMIT DROP AS
  SELECT e.id_site AS k, sum(GREATEST(COALESCE(e.production_speed,0), COALESCE(lm.production_speed,0)))::float8 AS spd
    FROM core.equipments e LEFT JOIN core.equipments lm ON lm.id_equipment = e.lead_machine WHERE e.id_enterprise = 3 AND e.tp_equipment = 3 GROUP BY 1;

CREATE TEMP TABLE rp_report (target text, staged bigint, impossible_gross bigint, impossible_net bigint, deleted bigint, unreplaced bigint, inserted bigint,
  gross_before float8, gross_after float8, net_before float8, net_after float8) ON COMMIT DROP;

DO $$
DECLARE p record; keycol text; keyset text; spt text; n bigint; ig bigint; inet bigint; del bigint; unrep bigint; ins bigint;
        gb float8; ga float8; nb float8; na float8; bkp text;
BEGIN
  FOR p IN SELECT * FROM rp LOOP
    keycol := p.pk[1];
    spt := CASE p.kind WHEN 'eq' THEN 'sp_eq' WHEN 'area' THEN 'sp_area' ELSE 'sp_site' END;
    keyset := CASE p.kind
      WHEN 'eq'   THEN 'SELECT id_equipment FROM core.equipments WHERE id_enterprise = 3'
      WHEN 'area' THEN 'SELECT a.id_area FROM core.areas a JOIN core.sites s USING (id_site) WHERE s.id_enterprise = 3'
      ELSE             'SELECT id_site FROM core.sites WHERE id_enterprise = 3' END;
    EXECUTE format('SELECT count(*) FROM %s', p.stage) INTO n;

    -- (1) impossibility guard
    EXECUTE format($q$CREATE TEMP TABLE imp ON COMMIT DROP AS
      SELECT s.%1$I AS k, s.ts_value, s.gross, s.net, sp.spd * (%3$s) * 20 AS bound
        FROM %2$s s JOIN %4$s sp ON sp.k = s.%1$I
       WHERE sp.spd > 0 AND ((s.gross > 1000 AND s.gross > sp.spd * (%3$s) * 20) OR (s.net > 1000 AND s.net > sp.spd * (%3$s) * 20))$q$,
      keycol, p.stage, p.minutes, spt);
    SELECT count(*) FILTER (WHERE gross > bound), count(*) FILTER (WHERE net > bound) INTO ig, inet FROM imp;
    IF p.kind = 'eq' THEN
      INSERT INTO silver.data_quality_event (id_enterprise, id_equipment, grain, bucket_ts, rule, observed_value, severity)
      SELECT 3, k, 'legacy_' || p.grain, ts_value::timestamptz, 'IMPOSSIBLE_COUNT', greatest(gross, net), 'error' FROM imp
      ON CONFLICT (id_enterprise, COALESCE(id_equipment, 0), grain, bucket_ts, rule)
      DO UPDATE SET observed_value = EXCLUDED.observed_value, detected_at = now();
    END IF;
    EXECUTE format($q$UPDATE %2$s s SET
        gross = CASE WHEN i.gross > i.bound AND i.gross > 1000 THEN NULL ELSE s.gross END,
        net   = CASE WHEN i.net   > i.bound AND i.net   > 1000 THEN NULL ELSE s.net   END
      FROM imp i WHERE s.%1$I = i.k AND s.ts_value = i.ts_value$q$, keycol, p.stage);
    EXECUTE format($q$UPDATE %1$s s SET scrap = s.gross - s.net,
        oee_p = CASE WHEN s.gross IS NULL THEN NULL ELSE s.oee_p END,
        oee_q = CASE WHEN s.gross IS NULL OR s.net IS NULL THEN NULL ELSE s.oee_q END,
        oee   = CASE WHEN s.gross IS NULL OR s.net IS NULL THEN NULL ELSE s.oee END
      WHERE s.gross IS NULL OR s.net IS NULL$q$, p.stage);
    DROP TABLE imp;

    -- (2) snapshot the live window, (3) delete it
    bkp := 'ops._bkp_hist_replace_' || split_part(p.target, '.', 2);
    EXECUTE format('DROP TABLE IF EXISTS %s', bkp);
    EXECUTE format('CREATE TABLE %s AS SELECT * FROM %s WHERE %I IN (%s) AND %s', bkp, p.target, keycol, keyset, p.win);
    EXECUTE format('SELECT sum(gross::float8), sum(net::float8) FROM %s', bkp) INTO gb, nb;
    -- rows about to be deleted that the staging table does NOT replace (data that would be lost)
    EXECUTE format('SELECT count(*) FROM %s b WHERE NOT EXISTS (SELECT 1 FROM %s s WHERE s.%I = b.%I AND s.ts_value = b.ts_value)',
                   bkp, p.stage, keycol, keycol) INTO unrep;
    EXECUTE format('DELETE FROM %s WHERE %I IN (%s) AND %s', p.target, keycol, keyset, p.win);
    GET DIAGNOSTICS del = ROW_COUNT;

    -- (4) insert the corrected history
    ins := ops.bf_merge(p.stage::regclass, p.target::regclass, p.skip, '{}'::text[]);
    EXECUTE format('SELECT sum(gross::float8), sum(net::float8) FROM %s WHERE %I IN (%s) AND %s', p.target, keycol, keyset, p.win) INTO ga, na;
    INSERT INTO rp_report VALUES (p.target, n, ig, inet, del, unrep, ins, gb, ga, nb, na);
  END LOOP;
END $$;

-- AREA / SITE = Σ of their LINES (tp=3), rebuilt from the corrected line rows. Legacy's own
-- area/site rows do not equal the sum of their lines (dry run: legacy area_daily 1.28e9 vs
-- Σ lines 2.2e9); gold keeps area = Σ lines (audit 2026-09-29), so history follows it too.
-- Existing rows are updated in place (keys/shifts kept); factors from the sums, same rules.
CREATE TEMP TABLE agg_def (target text, keycol text, src text, win text) ON COMMIT DROP;
INSERT INTO agg_def  -- same window as the equipment grain it sums (the staging ts range)
SELECT v.target, v.keycol, v.src, rp.win
  FROM (VALUES ('gold.area_oee_shift', 'id_area', 'gold.equipment_oee_shift'),
               ('gold.area_oee_daily', 'id_area', 'gold.equipment_oee_daily'),
               ('gold.site_oee_shift', 'id_site', 'gold.equipment_oee_shift')) v(target, keycol, src)
  JOIN rp ON rp.target = v.src;
DO $$
DECLARE d record; bkp text; upd bigint; gb float8; ga float8; nb float8; na float8; keyset text;
BEGIN
  FOR d IN SELECT * FROM agg_def LOOP
    keyset := CASE d.keycol WHEN 'id_area' THEN 'SELECT a.id_area FROM core.areas a JOIN core.sites s USING (id_site) WHERE s.id_enterprise = 3'
                            ELSE 'SELECT id_site FROM core.sites WHERE id_enterprise = 3' END;
    bkp := 'ops._bkp_hist_replace_' || split_part(d.target, '.', 2);
    EXECUTE format('DROP TABLE IF EXISTS %s', bkp);
    EXECUTE format('CREATE TABLE %s AS SELECT * FROM %s WHERE %I IN (%s) AND %s', bkp, d.target, d.keycol, keyset, d.win);
    EXECUTE format('SELECT sum(gross::float8), sum(net::float8) FROM %s', bkp) INTO gb, nb;
    EXECUTE format($q$
      WITH x AS (
        SELECT e.%2$I AS k, s.ts_value, sum(s.gross::float8) g, sum(s.net::float8) n, sum(s.running_time::float8) run,
               sum(s.available_time::float8) av, sum(s.planned_downtime::float8) pl, sum(s.ideal_production::float8) ip
          FROM %3$s s JOIN core.equipments e USING (id_equipment)
         WHERE e.id_enterprise = 3 AND e.tp_equipment = 3 AND %4$s
         GROUP BY 1, 2),
      f AS (
        SELECT x.*, COALESCE(LEAST(run / NULLIF(av, 0), 1), 0) fa,
               COALESCE(g * av / NULLIF(ip * run, 0), 0) fp, COALESCE(n / NULLIF(g, 0), 0) fq FROM x)
      UPDATE %1$s t SET gross = f.g, net = f.n, scrap = f.g - f.n, running_time = f.run, available_time = f.av,
             planned_downtime = f.pl, ideal_production = f.ip, oee_a = f.fa,
             oee_p = CASE WHEN f.fp > 10 THEN NULL ELSE f.fp END,
             oee_q = CASE WHEN f.fq > 10 THEN NULL ELSE f.fq END,
             oee   = CASE WHEN f.fp > 10 OR f.fq > 10 OR f.fa * f.fp * f.fq > 10 THEN NULL ELSE f.fa * f.fp * f.fq END,
             recalc_needed = false, computed_at = now()
        FROM f WHERE t.%2$I = f.k AND t.ts_value = f.ts_value AND %5$s$q$,
      d.target, d.keycol, d.src, replace(d.win, 'ts_value', 's.ts_value'), replace(d.win, 'ts_value', 't.ts_value'));
    GET DIAGNOSTICS upd = ROW_COUNT;
    EXECUTE format('SELECT sum(gross::float8), sum(net::float8) FROM %s WHERE %I IN (%s) AND %s', d.target, d.keycol, keyset, d.win) INTO ga, na;
    INSERT INTO rp_report VALUES (d.target, NULL, NULL, NULL, NULL, NULL, upd, gb, ga, nb, na);
  END LOOP;
END $$;

SELECT target, staged, impossible_gross, impossible_net, deleted, unreplaced, inserted,
       round(gross_before) gross_before, round(gross_after) gross_after, round(net_before) net_before, round(net_after) net_after
  FROM rp_report ORDER BY target;

\if :{?mode}
\else
  \set mode dry
\endif
\if :{?allow_unreplaced}
\else
  \set allow_unreplaced 0
\endif
SELECT (:'mode' = 'apply') AS is_apply,
       COALESCE((SELECT sum(unreplaced) FROM rp_report), 0) AS unreplaced_total \gset
\if :is_apply
  SELECT (:unreplaced_total > 0 AND :'allow_unreplaced' <> '1') AS unreplaced_block \gset
  \if :unreplaced_block
    ROLLBACK;
    \echo '== ABORTED: ' :unreplaced_total ' live rows would be deleted with no staged replacement (column unreplaced). Inspect, then re-run with -v allow_unreplaced=1 only if that loss is intended. =='
    \quit
  \endif
  COMMIT;
  \echo '== APPLIED. Backups in ops._bkp_hist_replace_*; staging ops.bf2_* kept for audit. =='
\else
  ROLLBACK;
  \echo '== DRY RUN (rolled back). Re-run with -v mode=apply to commit. =='
\endif
