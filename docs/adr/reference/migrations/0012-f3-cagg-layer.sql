-- F3 (packiot_shadow) aggregate layer — same prod CAgg defs as Flow 1,
-- staging-tuned policies (see staging-parity-cagg-adoption.sql).
-- ca_* tier DEFERRED: it aggregates the function-fed legacy
-- agg_equipment_values_1min_t, which the refactor does not carry —
-- the refactored ca_ tier will be hierarchical CAggs (ADR-0014 P3).
SET statement_timeout = 0;
SELECT create_hypertable('public.equipment_values', 'ts_value',
       chunk_time_interval => INTERVAL '1 day', migrate_data => true, if_not_exists => true);
SELECT add_retention_policy('public.equipment_values', INTERVAL '180 days', if_not_exists => true);

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
SELECT add_continuous_aggregate_policy('public.agg_equipment_values_1min', start_offset => INTERVAL '2 hours', end_offset => INTERVAL '1 minute', schedule_interval => INTERVAL '1 minute', if_not_exists => true);
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
SELECT add_continuous_aggregate_policy('public.agg_equipment_values_10min', start_offset => INTERVAL '1 day', end_offset => INTERVAL '10 minutes', schedule_interval => INTERVAL '10 minutes', if_not_exists => true);
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
SELECT add_continuous_aggregate_policy('public.agg_equipment_values_1hour', start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '30 minutes', if_not_exists => true);
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
SELECT add_continuous_aggregate_policy('public.agg_area_values_1min', start_offset => INTERVAL '2 hours', end_offset => INTERVAL '1 minute', schedule_interval => INTERVAL '1 minute', if_not_exists => true);
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
SELECT add_continuous_aggregate_policy('public.agg_area_values_10min', start_offset => INTERVAL '1 day', end_offset => INTERVAL '10 minutes', schedule_interval => INTERVAL '10 minutes', if_not_exists => true);
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
SELECT add_continuous_aggregate_policy('public.agg_area_values_1hour', start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '30 minutes', if_not_exists => true);
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
SELECT add_continuous_aggregate_policy('public.agg_site_values_1min', start_offset => INTERVAL '2 hours', end_offset => INTERVAL '1 minute', schedule_interval => INTERVAL '1 minute', if_not_exists => true);
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
SELECT add_continuous_aggregate_policy('public.agg_site_values_10min', start_offset => INTERVAL '1 day', end_offset => INTERVAL '10 minutes', schedule_interval => INTERVAL '10 minutes', if_not_exists => true);
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
SELECT add_continuous_aggregate_policy('public.agg_site_values_1hour', start_offset => INTERVAL '3 days', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '30 minutes', if_not_exists => true);
CALL refresh_continuous_aggregate('public.agg_equipment_values_1min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_equipment_values_10min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_equipment_values_1hour', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_area_values_1min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_area_values_10min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_area_values_1hour', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_site_values_1min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_site_values_10min', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
CALL refresh_continuous_aggregate('public.agg_site_values_1hour', now() - INTERVAL '30 days', now() - INTERVAL '1 hour');
SELECT 'caggs: ' || count(*) FROM timescaledb_information.continuous_aggregates;