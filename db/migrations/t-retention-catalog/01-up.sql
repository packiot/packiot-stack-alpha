-- t-retention-catalog — grain-tiered retention as DECLARED CONFIG (T0 of
-- docs/plans/unified-hot-cold-serving-grain-tiered-retention.md)
--
-- WHY: retention was scattered across Timescale policies, a hand-written purge
-- procedure (purge_analytics_plain, hardcoded DELETEs) and docs that disagreed with
-- live (repo said silver.equipment_values 2 y, live 90 d; 5 caggs had NO policy and
-- grew forever; the purge DELETED client-facing gold shift/hourly OEE at 90 d).
--
-- WHAT: one catalog table (ops.retention_policy) is the single source of truth.
--   * ops.apply_retention()      — reconciles Timescale retention policies to the
--                                  catalog (hypertables + caggs), changing only diffs.
--   * public.purge_analytics_plain (job 1033, same name/schedule) — now catalog-driven
--                                  for plain tables, per-relation fault-isolated, logged
--                                  to ops.retention_run.
--   * ops.retention_drift        — rows = catalog vs live disagreements (want: 0 rows).
--   * Environment profiles live in db/retention/profiles/*.sql (UPDATE keep + CALL
--     ops.apply_retention()). This migration seeds the PRODUCTION profile.
--
-- keep = NULL means "retain forever" (the archive of record is still the historian).
-- SAFE (verified live 2026-09-23): with these values NO relation deletes any row it
-- would not already have deleted — every newly-bounded relation's oldest data is
-- younger than its new keep; gold shift/hourly keep MORE than before. Idempotent.

CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.retention_policy (
  relation     text PRIMARY KEY,               -- schema-qualified
  kind         text NOT NULL CHECK (kind IN ('hypertable','cagg','plain')),
  time_expr    text NOT NULL,                  -- column or expression, e.g. lower(runtime_timerange)
  keep         interval,                       -- NULL = forever
  tier         text NOT NULL CHECK (tier IN ('hot_raw','hot_agg','business','ops')),
  purge_order  int  NOT NULL DEFAULT 100,      -- plain tables: children before parents (FKs)
  cold_copy    text,                           -- where rows older than keep live (historian), if anywhere
  rationale    text NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.retention_policy IS
  'Single source of truth for data lifetime in packiot_analytics. Edit via db/retention/profiles/*.sql then CALL ops.apply_retention(). keep NULL = forever.';

CREATE TABLE IF NOT EXISTS ops.retention_run (
  relation      text        NOT NULL,
  ran_at        timestamptz NOT NULL DEFAULT now(),
  rows_deleted  bigint,
  error         text
);
CREATE INDEX IF NOT EXISTS retention_run_ran_at_idx ON ops.retention_run (ran_at DESC);

-- ── Seed: PRODUCTION profile ────────────────────────────────────────────────
INSERT INTO ops.retention_policy (relation, kind, time_expr, keep, tier, purge_order, cold_copy, rationale) VALUES
 -- raw (hot 90 d, archived daily to the historian)
 ('silver.equipment_values',           'hypertable','ts_value', '90 days',  'hot_raw', 100, 'historian equipment_values (daily cold copy)', 'Raw metric series; ~1.3 GB/90 d. Deep history served by the historian.'),
 ('bronze.equipment_values_raw',       'hypertable','ts_value', '90 days',  'hot_raw', 100, NULL, 'Landing/replay buffer; was 2 y = ~34 GB/yr leak (1.3 GB in 2 wk). Replay window = silver hot window.'),
 ('bronze.equipment_events_raw',       'hypertable','ts_event', '90 days',  'hot_raw', 100, NULL, 'Landing/replay buffer; aligned with bronze values.'),
 ('silver.ca_discrete_changes_1s',     'cagg',      'ts_value', '90 days',  'hot_raw', 100, NULL, '1 s cagg; 2.5 GB/90 d. Derivable from raw.'),
 ('silver.ca_equipment_boxes_1s',      'cagg',      'ts_value', '90 days',  'hot_raw', 100, NULL, '1 s cagg; previously unbounded.'),
 ('silver.agg_equipment_values_1min',  'cagg',      'ts_value', '90 days',  'hot_raw', 100, NULL, '1 min cagg; read-api composer caps 1-min windows at 7 d.'),
 ('silver.equipment_metrics_1min',     'cagg',      'bucket',   '90 days',  'hot_raw', 100, NULL, '1 min cagg (Mission Control); previously unbounded (~800 MB/80 d).'),
 ('silver.equipment_categorical_1min', 'cagg',      'ts_value', '90 days',  'hot_raw', 100, NULL, '1 min cagg; previously unbounded (~1.65 GB/80 d ≈ 7.5 GB/yr leak).'),
 -- hourly grain: 13 months (year-over-year)
 ('silver.agg_equipment_values_1hour', 'cagg',      'ts_value', '13 months','hot_agg', 100, NULL, 'Hourly cagg; YoY comparisons. Refresh start_offset 3 d << raw 90 d, so old buckets are never re-materialized away.'),
 ('silver.equipment_categorical_1hour','cagg',      'ts_value', '13 months','hot_agg', 100, NULL, 'Hierarchical on categorical_1min; refresh start_offset 1 d.'),
 ('gold.equipment_oee_hourly',         'plain',     'ts_value', '13 months','hot_agg', 100, NULL, 'Was purged at 90 d. Client-facing hourly OEE.'),
 -- client-facing aggregates: forever
 ('gold.equipment_oee_shift',          'plain',     'ts_value', NULL,       'hot_agg', 100, 'historian gold.equipment_oee_shift', 'Was purged at 90 d (deleting client history nightly). Tiny (~32 MB/qtr all tenants).'),
 ('gold.equipment_oee_daily',          'plain',     'ts_value', NULL,       'hot_agg', 100, NULL, 'Client-facing.'),
 ('gold.equipment_oee_weekly',         'plain',     'ts_value', NULL,       'hot_agg', 100, NULL, 'Client-facing.'),
 ('gold.equipment_oee_monthly',        'plain',     'ts_value', NULL,       'hot_agg', 100, NULL, 'Client-facing.'),
 ('gold.equipment_oee_shift_weekly',   'plain',     'ts_value', NULL,       'hot_agg', 100, NULL, 'Client-facing.'),
 ('gold.equipment_oee_shift_monthly',  'plain',     'ts_value', NULL,       'hot_agg', 100, NULL, 'Client-facing.'),
 ('gold.area_oee_shift',               'plain',     'ts_value', NULL,       'hot_agg', 100, NULL, 'Client-facing.'),
 ('gold.area_oee_daily',               'plain',     'ts_value', NULL,       'hot_agg', 100, NULL, 'Client-facing.'),
 ('gold.site_oee_shift',               'plain',     'ts_value', NULL,       'hot_agg', 100, NULL, 'Client-facing.'),
 ('silver.equipment_events',           'hypertable','ts_event', '5 years',  'hot_agg', 100, 'historian equipment_events', 'Downtime events (Pareto, timelines) are client-facing; was 2 y. ~143 MB/4 mo compressed.'),
 -- business records: forever (FK children purge before parents under capped profiles)
 ('bronze.box_scans',                  'plain',     'ts_value', NULL,       'business', 10, NULL, 'Box scan records.'),
 ('gold.po_box_counter',               'plain',     'updated_at', NULL,     'business', 10, NULL, 'FK child of core.production_orders.'),
 ('gold.production_orders_runtime',    'plain',     'lower(runtime_timerange)', NULL, 'business', 20, 'historian production_orders', 'FK child of core.production_orders.'),
 ('core.production_orders',            'plain',     'ts_start', NULL,       'business', 30, 'historian production_orders', 'Business record.'),
 ('silver.equipment_events_man',       'plain',     'ts_event', NULL,       'business', 100, NULL, 'Manual/justified events (operator input).'),
 -- ops / derived-debug
 ('silver.equipment_events_cpac_shadow','plain',    'ts_event', '90 days',  'ops',     100, NULL, 'Shadow deriver output (ADR-0010), not client-facing. Unchanged.'),
 ('ops.retention_run',                 'plain',     'ran_at',   '13 months','ops',     100, NULL, 'This catalog''s own run log.')
ON CONFLICT (relation) DO NOTHING;

-- ── Drift view: catalog vs live Timescale policies (want: 0 rows) ───────────
CREATE OR REPLACE VIEW ops.retention_drift AS
WITH live AS (
  SELECT hypertable_schema || '.' || hypertable_name AS relation,
         (config->>'drop_after')::interval          AS live_keep
  FROM timescaledb_information.jobs
  WHERE proc_name = 'policy_retention'
)
SELECT coalesce(p.relation, l.relation) AS relation,
       p.keep      AS catalog_keep,
       l.live_keep AS live_keep,
       CASE WHEN p.relation IS NULL THEN 'live policy not in catalog'
            WHEN p.keep IS NULL      THEN 'catalog=forever but live drops'
            WHEN l.relation IS NULL  THEN 'catalog bounds but no live policy'
            ELSE 'keep differs' END AS problem
FROM (SELECT * FROM ops.retention_policy WHERE kind IN ('hypertable','cagg')) p
FULL JOIN live l USING (relation)
WHERE p.keep IS DISTINCT FROM l.live_keep;

-- ── Reconciler for Timescale-managed relations ──────────────────────────────
CREATE OR REPLACE PROCEDURE ops.apply_retention()
LANGUAGE plpgsql AS $$
DECLARE r record; live interval;
BEGIN
  FOR r IN SELECT * FROM ops.retention_policy ORDER BY relation LOOP
    -- validate the time expression against the relation (fail loud on typos)
    EXECUTE format('SELECT %s FROM %s LIMIT 0', r.time_expr, r.relation);
    CONTINUE WHEN r.kind = 'plain';
    SELECT (config->>'drop_after')::interval INTO live
      FROM timescaledb_information.jobs
     WHERE proc_name = 'policy_retention'
       AND hypertable_schema || '.' || hypertable_name = r.relation;
    IF r.keep IS NOT DISTINCT FROM live THEN CONTINUE; END IF;
    PERFORM remove_retention_policy(r.relation::regclass, if_exists => true);
    IF r.keep IS NOT NULL THEN
      PERFORM add_retention_policy(r.relation::regclass, drop_after => r.keep);
    END IF;
    RAISE NOTICE 'retention % : % -> %', r.relation, coalesce(live::text,'forever'), coalesce(r.keep::text,'forever');
  END LOOP;
END $$;

-- ── Catalog-driven purge for plain tables (keeps job 1033's name + schedule) ─
CREATE OR REPLACE PROCEDURE public.purge_analytics_plain(IN job_id integer, IN config jsonb)
LANGUAGE plpgsql AS $$
DECLARE r record; n bigint;
BEGIN
  FOR r IN SELECT * FROM ops.retention_policy
           WHERE kind = 'plain' AND keep IS NOT NULL
           ORDER BY purge_order, relation LOOP
    BEGIN  -- per-relation subtransaction: one failure (e.g. FK) never blocks the rest
      EXECUTE format('DELETE FROM %s WHERE %s < now() - $1', r.relation, r.time_expr) USING r.keep;
      GET DIAGNOSTICS n = ROW_COUNT;
      INSERT INTO ops.retention_run (relation, rows_deleted) VALUES (r.relation, n);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO ops.retention_run (relation, error) VALUES (r.relation, SQLSTATE || ': ' || SQLERRM);
      RAISE WARNING 'purge % failed: %', r.relation, SQLERRM;
    END;
  END LOOP;
END $$;

-- read access for consumers that need the hot floor (read-api T2 router, dashboards)
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['readapi_ro','superset_ro','histgw_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('GRANT USAGE ON SCHEMA ops TO %I', r);
      EXECUTE format('GRANT SELECT ON ops.retention_policy, ops.retention_drift, ops.retention_run TO %I', r);
    END IF;
  END LOOP;
END $$;

CALL ops.apply_retention();
