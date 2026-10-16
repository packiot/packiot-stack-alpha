-- t268 rollback — recreate the 4 caggs from their exact defining queries (captured
-- from timescaledb_information.continuous_aggregates.view_definition). Recreate in
-- dependency order (source-first): metrics_10min (on 1min) → 1hour (on 10min) →
-- 1day (on 1hour); categorical_10min (on categorical_1min). WITH NO DATA — a
-- refresh_continuous_aggregate (or the next real-time read) repopulates from source.
CREATE MATERIALIZED VIEW silver.equipment_metrics_10min
  WITH (timescaledb.continuous) AS
  SELECT time_bucket('00:10:00'::interval, equipment_metrics_1min.bucket) AS bucket,
     equipment_metrics_1min.id_equipment, equipment_metrics_1min.id_enterprise,
     equipment_metrics_1min.id_site, equipment_metrics_1min.id_area, equipment_metrics_1min.tp_equipment,
     sum(equipment_metrics_1min.sum_net) AS sum_net, sum(equipment_metrics_1min.sum_gross) AS sum_gross,
     sum(equipment_metrics_1min.sum_scrap) AS sum_scrap, sum(equipment_metrics_1min.sum_speed) AS sum_speed,
     sum(equipment_metrics_1min.cnt_speed) AS cnt_speed, sum(equipment_metrics_1min.cnt_rows) AS cnt_rows,
     max(equipment_metrics_1min.max_speed) AS max_speed, max(equipment_metrics_1min.ideal_production_speed) AS ideal_production_speed
    FROM equipment_metrics_1min
   GROUP BY 1, equipment_metrics_1min.id_equipment, equipment_metrics_1min.id_enterprise,
     equipment_metrics_1min.id_site, equipment_metrics_1min.id_area, equipment_metrics_1min.tp_equipment
  WITH NO DATA;

CREATE MATERIALIZED VIEW silver.equipment_metrics_1hour
  WITH (timescaledb.continuous) AS
  SELECT time_bucket('01:00:00'::interval, equipment_metrics_10min.bucket) AS bucket,
     equipment_metrics_10min.id_equipment, equipment_metrics_10min.id_enterprise,
     equipment_metrics_10min.id_site, equipment_metrics_10min.id_area, equipment_metrics_10min.tp_equipment,
     sum(equipment_metrics_10min.sum_net) AS sum_net, sum(equipment_metrics_10min.sum_gross) AS sum_gross,
     sum(equipment_metrics_10min.sum_scrap) AS sum_scrap, sum(equipment_metrics_10min.sum_speed) AS sum_speed,
     sum(equipment_metrics_10min.cnt_speed) AS cnt_speed, sum(equipment_metrics_10min.cnt_rows) AS cnt_rows,
     max(equipment_metrics_10min.max_speed) AS max_speed, max(equipment_metrics_10min.ideal_production_speed) AS ideal_production_speed
    FROM equipment_metrics_10min
   GROUP BY 1, equipment_metrics_10min.id_equipment, equipment_metrics_10min.id_enterprise,
     equipment_metrics_10min.id_site, equipment_metrics_10min.id_area, equipment_metrics_10min.tp_equipment
  WITH NO DATA;

CREATE MATERIALIZED VIEW silver.equipment_metrics_1day
  WITH (timescaledb.continuous) AS
  SELECT time_bucket('1 day'::interval, equipment_metrics_1hour.bucket) AS bucket,
     equipment_metrics_1hour.id_equipment, equipment_metrics_1hour.id_enterprise,
     equipment_metrics_1hour.id_site, equipment_metrics_1hour.id_area, equipment_metrics_1hour.tp_equipment,
     sum(equipment_metrics_1hour.sum_net) AS sum_net, sum(equipment_metrics_1hour.sum_gross) AS sum_gross,
     sum(equipment_metrics_1hour.sum_scrap) AS sum_scrap, sum(equipment_metrics_1hour.sum_speed) AS sum_speed,
     sum(equipment_metrics_1hour.cnt_speed) AS cnt_speed, sum(equipment_metrics_1hour.cnt_rows) AS cnt_rows,
     max(equipment_metrics_1hour.max_speed) AS max_speed, max(equipment_metrics_1hour.ideal_production_speed) AS ideal_production_speed
    FROM equipment_metrics_1hour
   GROUP BY 1, equipment_metrics_1hour.id_equipment, equipment_metrics_1hour.id_enterprise,
     equipment_metrics_1hour.id_site, equipment_metrics_1hour.id_area, equipment_metrics_1hour.tp_equipment
  WITH NO DATA;

CREATE MATERIALIZED VIEW silver.equipment_categorical_10min
  WITH (timescaledb.continuous) AS
  SELECT time_bucket('00:10:00'::interval, m.ts_value) AS ts_value,
     m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment, m.state, m.mode, m.id_order,
     m.conversion_factor, m.number_cavities, m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour,
     m.id_production_order, m.ts_value_production, m.ideal_production_speed,
     sum(m.net_production_incr) AS net_production_incr, sum(m.gross_production_incr) AS gross_production_incr,
     sum(m.scrap_incr) AS scrap_incr, sum(m.sum_speed) AS sum_speed, sum(m.cnt_speed) AS cnt_speed,
     sum(m.cnt_rows) AS cnt_rows, max(m.net_production_val) AS net_production_val,
     max(m.gross_production_val) AS gross_production_val, max(m.scrap_val) AS scrap_val
    FROM equipment_categorical_1min m
   GROUP BY 1, m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment, m.state, m.mode, m.id_order,
     m.conversion_factor, m.number_cavities, m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour,
     m.id_production_order, m.ts_value_production, m.ideal_production_speed
  WITH NO DATA;
