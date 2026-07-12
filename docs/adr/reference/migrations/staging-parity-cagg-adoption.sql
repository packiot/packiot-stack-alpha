-- Staging parity — adopt prod's hypertable + CAgg layer (optimized)
--
-- Prod ground truth captured 2026-07-02 (timescaledb_information.
-- continuous_aggregates + dimensions, SELECT-only). Comparison report
-- finding #2: prod runs 19 hypertables + 17 CAggs; staging had 2 + 0.
--
-- DELIBERATE STAGING TUNING (user directive: meaningful, not bloated —
-- prod's refresh/retention policies are unreadable to awslambda, so
-- these are staging-appropriate choices, documented divergences):
--   * CAggs created WITH NO DATA; initial materialization bounded to
--     the last 30 days (not full history)
--   * Refresh policies: 1min grain refreshes every minute over a 2h
--     window; coarser grains proportionally
--   * Retention: raw equipment_values/equipment_events chunks kept 180
--     days; agg_equipment_values_1min_t 90 days (prod keeps everything
--     and its invalidation table hit 496M rows — that is the bloat we
--     are NOT importing)
-- SKIPPED prod objects (niche/legacy, no staging consumer — adopt on
-- demand): ca_agg_equipment_values_1s, ca_discrete_changes_1s,
-- ca_equipment_boxes_{1s,1hour}, ohlc/ticks family, all agg_*_past +
-- agg_*_archive legacy hypertables.

-- AS-EXECUTED NOTES (2026-07-02) — deviations discovered during apply:
--   1. create_hypertable(migrate_data) re-fires ROW TRIGGERS per
--      migrated row: equipment_events (update_prev per-row SELECT) and
--      equipment_values (shift trigger) blew statement_timeout at 282k
--      and 8.2M rows. Fix: ALTER TABLE ... DISABLE TRIGGER USER around
--      the conversion + SET statement_timeout = 0 (semantically correct:
--      migration moves rows, it does not re-insert them).
--   2. agg_{equipment,area,site}_values_{1min,10min,1hour} existed on
--      staging as PLAIN VIEWS with the same names — invisible to the
--      relkind diff (CAgg user objects are also relkind 'v'). Each had a
--      consumer tree (41 objects transitive). Sequence that worked:
--      DROP VIEW ... CASCADE → CREATE CAgg → rebuild consumers from
--      captured prod defs in 3 passes (see staging-parity-prod-view-defs.sql).
--   3. Worker upserts hit transient statement timeouts during the
--      migration+refresh window (19:00-19:30Z); the ADR-0011 DLX retry
--      path drained ALL of them — failed queues at 0 afterwards, zero
--      message loss.
--   4. mv_agg_* matviews recreated WITHOUT prod's indexes (not captured)
--      — add before enabling REFRESH CONCURRENTLY, if ever needed.

-- ── 1. Hypertable conversions (prod chunk interval: 1 day) ─────────
SELECT create_hypertable('public.equipment_events', 'ts_event',
       chunk_time_interval => INTERVAL '1 day', migrate_data => true, if_not_exists => true);
SELECT create_hypertable('public.equipment_values', 'ts_value',
       chunk_time_interval => INTERVAL '1 day', migrate_data => true, if_not_exists => true);
SELECT create_hypertable('public.agg_equipment_values_1min_t', 'ts_value',
       chunk_time_interval => INTERVAL '1 day', migrate_data => true, if_not_exists => true);

-- ── 2. Drop the Wave-0b-deferred drift table (empty) ───────────────
DROP TABLE IF EXISTS public.agg_equipment_values_1min;

-- ── 3. Continuous aggregates (prod defs verbatim) ──────────────

CREATE MATERIALIZED VIEW public.agg_equipment_values_1min
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:01:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.id_equipment,
    equipment_values.tp_equipment,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    max(equipment_values.state) AS state,
    max(equipment_values.mode) AS mode,
    avg(equipment_values.speed) AS speed,
    max((equipment_values.id_order)::text) AS id_order,
    max(equipment_values.conversion_factor) AS conversion_factor,
    max(equipment_values.number_cavities) AS number_cavities,
    max(equipment_values.signal_quality) AS signal_quality,
    max(equipment_values.net_production_val) AS net_production_val,
    max(equipment_values.gross_production_val) AS gross_production_val,
    max(equipment_values.scrap_val) AS scrap_val,
    max(equipment_values.id_shift) AS id_shift,
    max(equipment_values.id_team) AS id_team,
    max(equipment_values.id_shift_hour) AS id_shift_hour,
    last(equipment_values.box_code, equipment_values.ts_value) AS box_code,
    last(equipment_values.transaction_code, equipment_values.ts_value) AS transaction_code,
    max(equipment_values.id_production_order) AS id_production_order,
    max(equipment_values.ts_value_production) AS ts_value_production,
    max(equipment_values.id_equipment_line_connected) AS id_equipment_line_connected,
    max(equipment_values.position_in_equipment_line) AS position_in_equipment_line,
    max(equipment_values.is_equipment_line_infeed) AS is_equipment_line_infeed,
    max(equipment_values.is_equipment_line_outfeed) AS is_equipment_line_outfeed,
    max(equipment_values.ideal_production_speed) AS ideal_production_speed
   FROM equipment_values
  WHERE (equipment_values.tp_equipment IS NOT NULL)
  GROUP BY (time_bucket('00:01:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_equipment, equipment_values.tp_equipment
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_equipment_values_1min',
       -- start_offset narrowed 2h→30min (task #57/#60): a 1-minute schedule with a
       -- 2-hour window re-materializes ~119 minutes of already-materialized buckets
       -- every run (~99% redundant) — the wasteful pattern proven on the 1-second
       -- caggs (ca_discrete_changes_1s ran 19min under it). 30min keeps ample
       -- late-data tolerance at a fraction of the per-run I/O.
       start_offset => INTERVAL '30 minutes', end_offset => INTERVAL '1 minute',
       schedule_interval => INTERVAL '1 minute', if_not_exists => true);

CREATE MATERIALIZED VIEW public.agg_equipment_values_10min
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:10:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.id_equipment,
    equipment_values.tp_equipment,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.mode,
    avg(equipment_values.speed) AS speed,
    equipment_values.id_production_order,
    equipment_values.conversion_factor,
    equipment_values.number_cavities,
    equipment_values.signal_quality,
    max(equipment_values.net_production_val) AS net_production_val,
    max(equipment_values.gross_production_val) AS gross_production_val,
    max(equipment_values.scrap_val) AS scrap_val,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.box_code,
    equipment_values.transaction_code,
    equipment_values.ts_value_production,
    equipment_values.id_equipment_line_connected,
    equipment_values.position_in_equipment_line,
    equipment_values.is_equipment_line_infeed,
    equipment_values.is_equipment_line_outfeed
   FROM equipment_values
  WHERE (equipment_values.tp_equipment IS NOT NULL)
  GROUP BY (time_bucket('00:10:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_equipment, equipment_values.tp_equipment, equipment_values.mode, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.signal_quality, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.box_code, equipment_values.transaction_code, equipment_values.ts_value_production, equipment_values.id_equipment_line_connected, equipment_values.position_in_equipment_line, equipment_values.is_equipment_line_infeed, equipment_values.is_equipment_line_outfeed
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_equipment_values_10min',
       start_offset => INTERVAL '1 day', end_offset => INTERVAL '10 minutes',
       schedule_interval => INTERVAL '10 minutes', if_not_exists => true);

CREATE MATERIALIZED VIEW public.agg_equipment_values_1hour
WITH (timescaledb.continuous) AS
SELECT time_bucket('01:00:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.id_equipment,
    equipment_values.tp_equipment,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.mode,
    avg(equipment_values.speed) AS speed,
    equipment_values.id_production_order,
    equipment_values.conversion_factor,
    equipment_values.number_cavities,
    equipment_values.signal_quality,
    max(equipment_values.net_production_val) AS net_production_val,
    max(equipment_values.gross_production_val) AS gross_production_val,
    max(equipment_values.scrap_val) AS scrap_val,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.box_code,
    equipment_values.transaction_code,
    equipment_values.ts_value_production,
    equipment_values.id_equipment_line_connected,
    equipment_values.position_in_equipment_line,
    equipment_values.is_equipment_line_infeed,
    equipment_values.is_equipment_line_outfeed
   FROM equipment_values
  WHERE (equipment_values.tp_equipment IS NOT NULL)
  GROUP BY (time_bucket('01:00:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_equipment, equipment_values.tp_equipment, equipment_values.mode, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.signal_quality, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.box_code, equipment_values.transaction_code, equipment_values.ts_value_production, equipment_values.id_equipment_line_connected, equipment_values.position_in_equipment_line, equipment_values.is_equipment_line_infeed, equipment_values.is_equipment_line_outfeed
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_equipment_values_1hour',
       start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour',
       schedule_interval => INTERVAL '30 minutes', if_not_exists => true);

CREATE MATERIALIZED VIEW public.agg_area_values_1min
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:01:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    last(equipment_values.id_shift, equipment_values.ts_value) AS id_shift,
    last(equipment_values.id_team, equipment_values.ts_value) AS id_team,
    last(equipment_values.id_shift_hour, equipment_values.ts_value) AS id_shift_hour,
    last(equipment_values.ts_value_production, equipment_values.ts_value) AS ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('00:01:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_area_values_1min',
       -- start_offset narrowed 2h→30min (task #57/#60): a 1-minute schedule with a
       -- 2-hour window re-materializes ~119 minutes of already-materialized buckets
       -- every run (~99% redundant) — the wasteful pattern proven on the 1-second
       -- caggs (ca_discrete_changes_1s ran 19min under it). 30min keeps ample
       -- late-data tolerance at a fraction of the per-run I/O.
       start_offset => INTERVAL '30 minutes', end_offset => INTERVAL '1 minute',
       schedule_interval => INTERVAL '1 minute', if_not_exists => true);

CREATE MATERIALIZED VIEW public.agg_area_values_10min
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:10:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('00:10:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.ts_value_production
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_area_values_10min',
       start_offset => INTERVAL '1 day', end_offset => INTERVAL '10 minutes',
       schedule_interval => INTERVAL '10 minutes', if_not_exists => true);

CREATE MATERIALIZED VIEW public.agg_area_values_1hour
WITH (timescaledb.continuous) AS
SELECT time_bucket('01:00:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('01:00:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.ts_value_production
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_area_values_1hour',
       start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour',
       schedule_interval => INTERVAL '30 minutes', if_not_exists => true);

CREATE MATERIALIZED VIEW public.agg_site_values_1min
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:01:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    last(equipment_values.id_shift, equipment_values.ts_value) AS id_shift,

    last(equipment_values.id_team, equipment_values.ts_value) AS id_team,
    last(equipment_values.id_shift_hour, equipment_values.ts_value) AS id_shift_hour,
    last(equipment_values.ts_value_production, equipment_values.ts_value) AS ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('00:01:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_site_values_1min',
       -- start_offset narrowed 2h→30min (task #57/#60): a 1-minute schedule with a
       -- 2-hour window re-materializes ~119 minutes of already-materialized buckets
       -- every run (~99% redundant) — the wasteful pattern proven on the 1-second
       -- caggs (ca_discrete_changes_1s ran 19min under it). 30min keeps ample
       -- late-data tolerance at a fraction of the per-run I/O.
       start_offset => INTERVAL '30 minutes', end_offset => INTERVAL '1 minute',
       schedule_interval => INTERVAL '1 minute', if_not_exists => true);

CREATE MATERIALIZED VIEW public.agg_site_values_10min
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:10:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('00:10:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.ts_value_production
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_site_values_10min',
       start_offset => INTERVAL '1 day', end_offset => INTERVAL '10 minutes',
       schedule_interval => INTERVAL '10 minutes', if_not_exists => true);

CREATE MATERIALIZED VIEW public.agg_site_values_1hour
WITH (timescaledb.continuous) AS
SELECT time_bucket('01:00:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('01:00:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.ts_value_production
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.agg_site_values_1hour',
       start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour',
       schedule_interval => INTERVAL '30 minutes', if_not_exists => true);

CREATE MATERIALIZED VIEW public.ca_agg_equipment_values_10min
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:10:00'::interval, agg_equipment_values_1min_t.ts_value) AS ts_value,
    agg_equipment_values_1min_t.id_equipment,
    agg_equipment_values_1min_t.id_enterprise,
    agg_equipment_values_1min_t.id_site,
    agg_equipment_values_1min_t.id_area,
    agg_equipment_values_1min_t.tp_equipment,
    agg_equipment_values_1min_t.state,
    agg_equipment_values_1min_t.mode,
    avg(agg_equipment_values_1min_t.speed) AS speed,
    agg_equipment_values_1min_t.id_order,
    agg_equipment_values_1min_t.conversion_factor,
    agg_equipment_values_1min_t.number_cavities,
    agg_equipment_values_1min_t.signal_quality,
    agg_equipment_values_1min_t.id_shift,
    agg_equipment_values_1min_t.id_team,
    agg_equipment_values_1min_t.id_shift_hour,
    agg_equipment_values_1min_t.id_production_order,
    agg_equipment_values_1min_t.ts_value_production,
    agg_equipment_values_1min_t.ideal_production_speed,
    sum(agg_equipment_values_1min_t.net_production_incr) AS net_production_incr,
    sum(agg_equipment_values_1min_t.gross_production_incr) AS gross_production_incr,
    sum(agg_equipment_values_1min_t.scrap_incr) AS scrap_incr,
    max(agg_equipment_values_1min_t.net_production_val) AS net_production_val,
    max(agg_equipment_values_1min_t.gross_production_val) AS gross_production_val,
    max(agg_equipment_values_1min_t.scrap_val) AS scrap_val
   FROM agg_equipment_values_1min_t
  GROUP BY (time_bucket('00:10:00'::interval, agg_equipment_values_1min_t.ts_value)), agg_equipment_values_1min_t.id_equipment, agg_equipment_values_1min_t.id_enterprise, agg_equipment_values_1min_t.id_site, agg_equipment_values_1min_t.id_area, agg_equipment_values_1min_t.tp_equipment, agg_equipment_values_1min_t.state, agg_equipment_values_1min_t.mode, agg_equipment_values_1min_t.id_order, agg_equipment_values_1min_t.conversion_factor, agg_equipment_values_1min_t.number_cavities, agg_equipment_values_1min_t.signal_quality, agg_equipment_values_1min_t.id_shift, agg_equipment_values_1min_t.id_team, agg_equipment_values_1min_t.id_shift_hour, agg_equipment_values_1min_t.id_production_order, agg_equipment_values_1min_t.ts_value_production, agg_equipment_values_1min_t.ideal_production_speed
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.ca_agg_equipment_values_10min',
       start_offset => INTERVAL '1 day', end_offset => INTERVAL '10 minutes',
       schedule_interval => INTERVAL '10 minutes', if_not_exists => true);

CREATE MATERIALIZED VIEW public.ca_agg_equipment_values_1hour
WITH (timescaledb.continuous) AS
SELECT time_bucket('01:00:00'::interval, agg_equipment_values_1min_t.ts_value) AS ts_value,
    agg_equipment_values_1min_t.id_equipment,
    agg_equipment_values_1min_t.id_enterprise,
    agg_equipment_values_1min_t.id_site,
    agg_equipment_values_1min_t.id_area,
    agg_equipment_values_1min_t.tp_equipment,
    agg_equipment_values_1min_t.state,
    agg_equipment_values_1min_t.mode,
    avg(agg_equipment_values_1min_t.speed) AS speed,
    (count(*) * 60) AS duration,
    agg_equipment_values_1min_t.id_order,
    agg_equipment_values_1min_t.conversion_factor,
    agg_equipment_values_1min_t.number_cavities,
    agg_equipment_values_1min_t.signal_quality,
    agg_equipment_values_1min_t.id_shift,
    agg_equipment_values_1min_t.id_team,
    agg_equipment_values_1min_t.id_shift_hour,
    agg_equipment_values_1min_t.id_production_order,
    agg_equipment_values_1min_t.ts_value_production,
    agg_equipment_values_1min_t.ideal_production_speed,
    sum(agg_equipment_values_1min_t.net_production_incr) AS net_production_incr,
    sum(agg_equipment_values_1min_t.gross_production_incr) AS gross_production_incr,
    sum(agg_equipment_values_1min_t.scrap_incr) AS scrap_incr,
    max(agg_equipment_values_1min_t.net_production_val) AS net_production_val,
    max(agg_equipment_values_1min_t.gross_production_val) AS gross_production_val,
    max(agg_equipment_values_1min_t.scrap_val) AS scrap_val
   FROM agg_equipment_values_1min_t
  GROUP BY (time_bucket('01:00:00'::interval, agg_equipment_values_1min_t.ts_value)), agg_equipment_values_1min_t.id_equipment, agg_equipment_values_1min_t.id_enterprise, agg_equipment_values_1min_t.id_site, agg_equipment_values_1min_t.id_area, agg_equipment_values_1min_t.tp_equipment, agg_equipment_values_1min_t.state, agg_equipment_values_1min_t.mode, agg_equipment_values_1min_t.id_order, agg_equipment_values_1min_t.conversion_factor, agg_equipment_values_1min_t.number_cavities, agg_equipment_values_1min_t.signal_quality, agg_equipment_values_1min_t.id_shift, agg_equipment_values_1min_t.id_team, agg_equipment_values_1min_t.id_shift_hour, agg_equipment_values_1min_t.id_production_order, agg_equipment_values_1min_t.ts_value_production, agg_equipment_values_1min_t.ideal_production_speed
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.ca_agg_equipment_values_1hour',
       start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour',
       schedule_interval => INTERVAL '30 minutes', if_not_exists => true);

CREATE MATERIALIZED VIEW public.ca_agg_equipment_values_1day
WITH (timescaledb.continuous) AS
SELECT agg_equipment_values_1min_t.ts_value_production AS ts_value,
    time_bucket('1 day'::interval, agg_equipment_values_1min_t.ts_value) AS ts_value_real,
    agg_equipment_values_1min_t.id_equipment,
    agg_equipment_values_1min_t.id_enterprise,
    agg_equipment_values_1min_t.id_site,
    agg_equipment_values_1min_t.id_area,
    agg_equipment_values_1min_t.tp_equipment,
    agg_equipment_values_1min_t.state,
    agg_equipment_values_1min_t.mode,
    avg(agg_equipment_values_1min_t.speed) AS speed,
    agg_equipment_values_1min_t.id_order,
    agg_equipment_values_1min_t.conversion_factor,
    agg_equipment_values_1min_t.number_cavities,
    agg_equipment_values_1min_t.signal_quality,
    agg_equipment_values_1min_t.id_shift,
    agg_equipment_values_1min_t.id_team,
    agg_equipment_values_1min_t.id_shift_hour,
    agg_equipment_values_1min_t.id_production_order,
    agg_equipment_values_1min_t.ideal_production_speed,
    sum(agg_equipment_values_1min_t.net_production_incr) AS net_production_incr,
    sum(agg_equipment_values_1min_t.gross_production_incr) AS gross_production_incr,
    sum(agg_equipment_values_1min_t.scrap_incr) AS scrap_incr,
    max(agg_equipment_values_1min_t.net_production_val) AS net_production_val,
    max(agg_equipment_values_1min_t.gross_production_val) AS gross_production_val,
    max(agg_equipment_values_1min_t.scrap_val) AS scrap_val
   FROM agg_equipment_values_1min_t
  GROUP BY agg_equipment_values_1min_t.ts_value_production, (time_bucket('1 day'::interval, agg_equipment_values_1min_t.ts_value)), agg_equipment_values_1min_t.id_equipment, agg_equipment_values_1min_t.id_enterprise, agg_equipment_values_1min_t.id_site, agg_equipment_values_1min_t.id_area, agg_equipment_values_1min_t.tp_equipment, agg_equipment_values_1min_t.state, agg_equipment_values_1min_t.mode, agg_equipment_values_1min_t.id_order, agg_equipment_values_1min_t.conversion_factor, agg_equipment_values_1min_t.number_cavities, agg_equipment_values_1min_t.signal_quality, agg_equipment_values_1min_t.id_shift, agg_equipment_values_1min_t.id_team, agg_equipment_values_1min_t.id_shift_hour, agg_equipment_values_1min_t.id_production_order, agg_equipment_values_1min_t.ideal_production_speed
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.ca_agg_equipment_values_1day',
       start_offset => INTERVAL '7 days', end_offset => INTERVAL '1 day',
       schedule_interval => INTERVAL '6 hours', if_not_exists => true);

-- ── 4. Bounded initial materialization (last 30 days) ──────────────
CALL refresh_continuous_aggregate('public.agg_equipment_values_1min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_equipment_values_10min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_equipment_values_1hour', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_area_values_1min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_area_values_10min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_area_values_1hour', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_site_values_1min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_site_values_10min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_site_values_1hour', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.ca_agg_equipment_values_10min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.ca_agg_equipment_values_1hour', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.ca_agg_equipment_values_1day', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');

-- ── 5. Retention (staging-tuned; prod has none — deliberate) ───────
SELECT add_retention_policy('public.equipment_values', INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('public.equipment_events', INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('public.agg_equipment_values_1min_t', INTERVAL '90 days', if_not_exists => true);

\echo '=== gate: hypertables ==='
SELECT hypertable_name FROM timescaledb_information.hypertables ORDER BY 1;
\echo '=== gate: caggs ==='
SELECT view_name FROM timescaledb_information.continuous_aggregates ORDER BY 1;
