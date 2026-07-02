-- Applied to F2 (packiot) —
-- F2 events-derivation prerequisites (design doc §prereqs 1-3)
SET statement_timeout = 0;
SELECT create_hypertable('shadow_go_port.equipment_values', 'ts_value',
       chunk_time_interval => INTERVAL '1 day', migrate_data => true, if_not_exists => true);
CREATE TABLE IF NOT EXISTS shadow_go_port.equipment_events
       (LIKE public.equipment_events INCLUDING DEFAULTS INCLUDING INDEXES);
SELECT create_hypertable('shadow_go_port.equipment_events', 'ts_event',
       chunk_time_interval => INTERVAL '1 day', migrate_data => true, if_not_exists => true);
SELECT add_retention_policy('shadow_go_port.equipment_values', INTERVAL '180 days', if_not_exists => true);
CREATE MATERIALIZED VIEW IF NOT EXISTS shadow_go_port.ca_discrete_changes_1s
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:00:01'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_equipment,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.state,
    equipment_values.mode,
    equipment_values.id_order,
    equipment_values.id_production_order,
    equipment_values.conversion_factor,
    equipment_values.number_cavities,
    equipment_values.ts_value_production,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.sub_mode,
    equipment_values.ideal_production_speed
   FROM shadow_go_port.equipment_values
  WHERE (NOT ((equipment_values.state IS NULL) AND (equipment_values.mode IS NULL) AND (equipment_values.id_order IS NULL) AND (equipment_values.id_production_order IS NULL) AND (equipment_values.conversion_factor IS NULL) AND (equipment_values.number_cavities IS NULL) AND (equipment_values.ts_value_production IS NULL) AND (equipment_values.id_shift IS NULL) AND (equipment_values.id_team IS NULL) AND (equipment_values.id_shift_hour IS NULL) AND (equipment_values.sub_mode IS NULL) AND (equipment_values.ideal_production_speed IS NULL)))
  GROUP BY (time_bucket('00:00:01'::interval, equipment_values.ts_value)), equipment_values.id_equipment, equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.state, equipment_values.mode, equipment_values.id_order, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.ts_value_production, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.sub_mode, equipment_values.ideal_production_speed
WITH NO DATA;
SELECT add_continuous_aggregate_policy('shadow_go_port.ca_discrete_changes_1s',
       start_offset => INTERVAL '2 hours', end_offset => INTERVAL '1 minute',
       schedule_interval => INTERVAL '1 minute', if_not_exists => true);
CALL refresh_continuous_aggregate('shadow_go_port.ca_discrete_changes_1s', now() - INTERVAL '7 days', now() - INTERVAL '1 hour');

-- Applied to F3 (packiot_shadow) — DDL generated from F1 shape:
SET statement_timeout = 0;
DDL_PLACEHOLDER
CREATE UNIQUE INDEX IF NOT EXISTS equipment_events_pk ON public.equipment_events (id_equipment, ts_event);
SELECT create_hypertable('public.equipment_events', 'ts_event',
       chunk_time_interval => INTERVAL '1 day', migrate_data => true, if_not_exists => true);
SELECT add_retention_policy('public.equipment_events', INTERVAL '180 days', if_not_exists => true);
CREATE MATERIALIZED VIEW IF NOT EXISTS public.ca_discrete_changes_1s
WITH (timescaledb.continuous) AS
SELECT time_bucket('00:00:01'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_equipment,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.state,
    equipment_values.mode,
    equipment_values.id_order,
    equipment_values.id_production_order,
    equipment_values.conversion_factor,
    equipment_values.number_cavities,
    equipment_values.ts_value_production,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.sub_mode,
    equipment_values.ideal_production_speed
   FROM equipment_values
  WHERE (NOT ((equipment_values.state IS NULL) AND (equipment_values.mode IS NULL) AND (equipment_values.id_order IS NULL) AND (equipment_values.id_production_order IS NULL) AND (equipment_values.conversion_factor IS NULL) AND (equipment_values.number_cavities IS NULL) AND (equipment_values.ts_value_production IS NULL) AND (equipment_values.id_shift IS NULL) AND (equipment_values.id_team IS NULL) AND (equipment_values.id_shift_hour IS NULL) AND (equipment_values.sub_mode IS NULL) AND (equipment_values.ideal_production_speed IS NULL)))
  GROUP BY (time_bucket('00:00:01'::interval, equipment_values.ts_value)), equipment_values.id_equipment, equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.state, equipment_values.mode, equipment_values.id_order, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.ts_value_production, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.sub_mode, equipment_values.ideal_production_speed
WITH NO DATA;
SELECT add_continuous_aggregate_policy('public.ca_discrete_changes_1s',
       start_offset => INTERVAL '2 hours', end_offset => INTERVAL '1 minute',
       schedule_interval => INTERVAL '1 minute', if_not_exists => true);
CALL refresh_continuous_aggregate('public.ca_discrete_changes_1s', now() - INTERVAL '7 days', now() - INTERVAL '1 hour');
