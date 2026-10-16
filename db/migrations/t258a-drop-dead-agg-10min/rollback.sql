-- t258a rollback — recreate the dead 10-min cagg from its exact captured definition.
-- (Historical materialized rows are not restored; a refresh re-derives them from
-- equipment_values. Harmless — the cagg had 0 consumers and no refresh policy.)

CREATE MATERIALIZED VIEW public.agg_equipment_values_10min WITH (timescaledb.continuous) AS
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
  GROUP BY (time_bucket('00:10:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_equipment, equipment_values.tp_equipment, equipment_values.mode, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.signal_quality, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.box_code, equipment_values.transaction_code, equipment_values.ts_value_production, equipment_values.id_equipment_line_connected, equipment_values.position_in_equipment_line, equipment_values.is_equipment_line_infeed, equipment_values.is_equipment_line_outfeed;
