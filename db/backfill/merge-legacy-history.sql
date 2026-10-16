-- merge-legacy-history.sql — step 2 of the T1 legacy-history backfill.
-- Merges ops.bf_* staging tables (built by scripts/analytics-legacy-history-backfill.sh)
-- into the live gold tables in ONE transaction, behind hard gates.
--
--   psql -d packiot_analytics -v mode=dry   -f db/backfill/merge-legacy-history.sql   # gates + counts, ROLLBACK
--   psql -d packiot_analytics -v mode=apply -f db/backfill/merge-legacy-history.sql   # same, COMMIT, drop staging
--
-- GATES (any violation RAISEs → whole transaction aborts, nothing written):
--   G1 no NULL key (unmapped equipment/area/site)       G2 oee/factors within [0,1]
--   G3 net <= gross (where the grain has them)          G4 no duplicate logical key inside staging
-- Order: PO family parents->children (clients, POs, runtimes), then the OEE grains.
-- REPORTED (not fatal): rows with unmapped id_shift (legacy shift codes with no current shift).
-- ops.bf_merge = ON CONFLICT DO NOTHING → pipeline-computed rows always win.
\set ON_ERROR_STOP 1
SET statement_timeout = '30min';
BEGIN;

CREATE TEMP TABLE bf_plan (ord int, stage text, target text, pk text[], skip text[], tcol text, probe boolean DEFAULT true) ON COMMIT DROP;
INSERT INTO bf_plan (stage, target, pk, skip) VALUES
 ('ops.bf_equipment_oee_shift',         'gold.equipment_oee_shift',         '{id_equipment,ts_value}', '{id_runtime_shift}'),
 ('ops.bf_equipment_oee_hourly',        'gold.equipment_oee_hourly',        '{id_equipment,ts_value}', '{}'),
 ('ops.bf_equipment_oee_daily',         'gold.equipment_oee_daily',         '{id_equipment,ts_value}', '{}'),
 ('ops.bf_equipment_oee_weekly',        'gold.equipment_oee_weekly',        '{id_equipment,ts_value}', '{}'),
 ('ops.bf_equipment_oee_monthly',       'gold.equipment_oee_monthly',       '{id_equipment,ts_value}', '{}'),
 ('ops.bf_equipment_oee_shift_weekly',  'gold.equipment_oee_shift_weekly',  '{id_equipment,id_shift,ts_value}', '{}'),
 ('ops.bf_equipment_oee_shift_monthly', 'gold.equipment_oee_shift_monthly', '{id_equipment,id_shift,ts_value}', '{}'),
 ('ops.bf_area_oee_shift',              'gold.area_oee_shift',              '{id_area,ts_value}', '{}'),
 ('ops.bf_area_oee_daily',              'gold.area_oee_daily',              '{id_area,ts_value}', '{}'),
 ('ops.bf_site_oee_shift',              'gold.site_oee_shift',              '{id_site,ts_value}', '{}');
-- PO family: parents before children (FKs); logical keys: clients id, POs business key
-- (id_enterprise,id_order) = the unique index, runtimes id.
INSERT INTO bf_plan (ord, stage, target, pk, skip, tcol) VALUES
 (1, 'ops.bf_clients',                   'core.clients',                   '{id_client}', '{}', NULL),
 (2, 'ops.bf_production_orders',         'core.production_orders',         '{id_enterprise,id_order}', '{}', 'ts_start'),
 (3, 'ops.bf_production_orders_runtime', 'gold.production_orders_runtime', '{id_production_order_runtime}', '{}', 'lower(runtime_timerange::tstzrange)'),
 (5, 'ops.bf_equipment_events',          'silver.equipment_events',        '{id_equipment,ts_event}', '{}', 'ts_event'),  -- probe=false below
 (6, 'ops.bf_equipment_events_man',      'silver.equipment_events_man',    '{id_equipment,ts_event}', '{id_equipment_event}', 'ts_event');
UPDATE bf_plan SET ord = 10, tcol = 'ts_value' WHERE ord IS NULL;
-- probe = per-row NOT EXISTS guard on the logical key. REQUIRED for PK-less tables
-- (shift_weekly/_monthly). DISABLED for the silver.equipment_events HYPERTABLE: a
-- correlated probe cannot chunk-exclude at plan time, so each of ~1.4M probes touched
-- every (compressed) chunk (>10 min, cancelled). Safe without it: staged events are all
-- strictly older than every existing row (boundary) and the PK + ON CONFLICT still guard.
UPDATE bf_plan SET probe = false WHERE stage = 'ops.bf_equipment_events';
DELETE FROM bf_plan WHERE to_regclass(stage) IS NULL;   -- only grains that were staged

CREATE TEMP TABLE bf_report (stage text, staged bigint, unmapped_shift bigint, inserted bigint, skipped_conflict bigint, per_year text) ON COMMIT DROP;

DO $$
DECLARE p record; n bigint; bad bigint; ushift bigint; ins bigint; yrs text; keycol text; has_net boolean; has_shift boolean; has_oee boolean; netc text; grossc text;
BEGIN
  FOR p IN SELECT * FROM bf_plan ORDER BY ord, stage LOOP
    keycol := p.pk[array_length(p.pk, 1)];
    IF p.stage = 'ops.bf_production_orders_runtime' THEN
      -- FK: keep only runtimes whose PO now exists (POs merged just before; a PO skipped on
      -- its business key is owned by the pipeline, and so is its runtime).
      DELETE FROM ops.bf_production_orders_runtime s
       WHERE NOT EXISTS (SELECT 1 FROM core.production_orders po WHERE po.id_production_order = s.id_production_order);
      GET DIAGNOSTICS bad = ROW_COUNT;
      RAISE NOTICE 'runtime staging: dropped % orphan rows (PO not inserted)', bad;
    END IF;
    SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = p.stage::regclass AND attname = 'oee' AND NOT attisdropped) INTO has_oee;
    netc := CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = p.stage::regclass AND attname = 'net_production' AND NOT attisdropped) THEN 'net_production' ELSE 'net' END;
    grossc := CASE WHEN netc = 'net_production' THEN 'gross_production' ELSE 'gross' END;
    SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = p.stage::regclass AND attname = netc AND NOT attisdropped) INTO has_net;
    SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = p.stage::regclass AND attname = 'id_shift' AND NOT attisdropped) INTO has_shift;
    EXECUTE format('SELECT count(*) FROM %s', p.stage) INTO n;
    -- G1
    EXECUTE format('SELECT count(*) FROM %s WHERE %s', p.stage,
                   array_to_string(ARRAY(SELECT quote_ident(c) || ' IS NULL' FROM unnest(p.pk) c), ' OR ')) INTO bad;
    IF bad > 0 THEN RAISE EXCEPTION 'G1 % has % rows with NULL key', p.stage, bad; END IF;
    -- G2
    IF has_oee THEN
      EXECUTE format('SELECT count(*) FROM %s WHERE NOT (oee BETWEEN 0 AND 1 AND oee_a BETWEEN 0 AND 1 AND oee_p BETWEEN 0 AND 1 AND oee_q BETWEEN 0 AND 1)', p.stage) INTO bad;
      IF bad > 0 THEN RAISE EXCEPTION 'G2 % has % rows with OEE/factor outside [0,1]', p.stage, bad; END IF;
    END IF;
    -- G3
    IF has_net THEN
      EXECUTE format('SELECT count(*) FROM %s WHERE %I > %I', p.stage, netc, grossc) INTO bad;
      IF bad > 0 THEN RAISE EXCEPTION 'G3 % has % rows with net > gross', p.stage, bad; END IF;
    END IF;
    -- G4
    EXECUTE format('SELECT count(*) - count(DISTINCT (%s)) FROM %s',
                   array_to_string(ARRAY(SELECT quote_ident(c) FROM unnest(p.pk) c), ','), p.stage) INTO bad;
    IF bad > 0 THEN RAISE EXCEPTION 'G4 % has % duplicate PK rows', p.stage, bad; END IF;
    ushift := NULL;
    IF has_shift THEN EXECUTE format('SELECT count(*) FROM %s WHERE id_shift IS NULL', p.stage) INTO ushift; END IF;
    yrs := NULL;
    IF p.tcol IS NOT NULL THEN
      EXECUTE format($q$SELECT string_agg(y||':'||c, ' ' ORDER BY y) FROM (SELECT extract(year FROM %s)::int y, count(*) c FROM %s GROUP BY 1) x$q$, p.tcol, p.stage) INTO yrs;
    END IF;
    ins := ops.bf_merge(p.stage::regclass, p.target::regclass, p.skip, CASE WHEN p.probe THEN p.pk ELSE '{}'::text[] END);
    INSERT INTO bf_report VALUES (p.stage, n, ushift, ins, n - ins, yrs);
  END LOOP;
END $$;

SELECT * FROM bf_report ORDER BY stage;

\if :{?mode}
\else
  \set mode dry
\endif
SELECT (:'mode' = 'apply') AS is_apply \gset
\if :is_apply
  COMMIT;
  \echo '== APPLIED (committed). Dropping staging tables. =='
  DO $$ DECLARE r record; BEGIN
    FOR r IN SELECT c.oid::regclass AS t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'ops' AND c.relname LIKE 'bf\_%' AND c.relkind = 'r' LOOP
      EXECUTE format('DROP TABLE %s', r.t);
    END LOOP; END $$;
\else
  ROLLBACK;
  \echo '== DRY RUN (rolled back). Re-run with -v mode=apply to commit. =='
\endif
