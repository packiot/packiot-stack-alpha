-- t-adr0065-p3a-metrics-view — ADR-0065 P3a (2026-10-16): silver.equipment_metrics_1min becomes a VIEW over
-- silver.equipment_categorical_1min. Measured (pg_stat_statements since 2026-09-24): metrics_1min = 274 calls / 0.00 %
-- of DB time (serving.mission_control, _timeline) for 1.2 GB and a third table written by every rollup tick; it is a
-- pure projection of the categorical minute fact except max(speed). Two steps:
--   01-up.sql   : categorical gets max_speed; rollup_refresh fills it (and still writes metrics_1min) → backfill the
--                 history with backfill.sql (rollup_refresh per day over the retention window)
--   02-swap.sql : parity gate (table = view over the backfilled overlap, else ABORT) → table renamed
--                 equipment_metrics_1min__old (rollback), view created with the same grants, retention row removed,
--                 rollup_refresh stops writing the old table
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '10s';
ALTER TABLE silver.equipment_categorical_1min ADD COLUMN IF NOT EXISTS max_speed double precision;
COMMENT ON COLUMN silver.equipment_categorical_1min.max_speed IS 'max(speed) in the minute and group (ADR-0065 P3a: feeds the equipment_metrics_1min view)';
CREATE OR REPLACE FUNCTION silver.rollup_refresh(p_from timestamp with time zone, p_to timestamp with time zone, p_equipment integer[] DEFAULT NULL::integer[])
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
DECLARE
  o  constant timestamptz := timestamptz '2000-01-01 00:00:00+00';
  m0 timestamptz := date_bin('1 minute', p_from, o);
  m1 timestamptz := date_bin('1 minute', p_to - interval '1 microsecond', o) + interval '1 minute';
  h0 timestamptz := date_bin('1 hour', p_from, o);
  h1 timestamptz := date_bin('1 hour', p_to - interval '1 microsecond', o) + interval '1 hour';
  eq text := CASE WHEN p_equipment IS NULL THEN '' ELSE ' AND id_equipment = ANY ($3)' END;
  -- '__next' while the twins run in shadow; '' after the cutover renamed them over the caggs,
  -- so the cutover is only DROP + RENAME (this function follows the names by itself).
  x  text := CASE WHEN to_regclass('silver.equipment_categorical_1min__next') IS NULL THEN '' ELSE '__next' END;
  n  bigint := 0;
  k  bigint;
BEGIN
  IF p_to <= p_from THEN RETURN 0; END IF;

  -- equipment_categorical_1min (cagg: time_bucket 1 min, no tp filter)
  EXECUTE 'DELETE FROM silver.equipment_categorical_1min' || x || ' WHERE ts_value >= $1 AND ts_value < $2' || eq USING m0, m1, p_equipment;
  EXECUTE 'INSERT INTO silver.equipment_categorical_1min' || x || '
    SELECT date_bin(''1 minute'', ev.ts_value, $4), ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area, ev.tp_equipment,
           ev.state, ev.mode, ev.id_order, ev.conversion_factor, ev.number_cavities, ev.signal_quality, ev.id_shift, ev.id_team,
           ev.id_shift_hour, ev.id_production_order, ev.ts_value_production, ev.ideal_production_speed,
           sum(ev.net_production_incr::double precision), sum(ev.gross_production_incr::double precision),
           sum(ev.scrap_incr::double precision), sum(ev.speed::double precision), count(ev.speed), count(*),
           max(ev.net_production_val::double precision), max(ev.gross_production_val::double precision),
           max(ev.scrap_val::double precision), max(ev.speed::double precision)
      FROM silver.equipment_values ev
     WHERE ev.ts_value >= $1 AND ev.ts_value < $2' || replace(eq, 'id_equipment', 'ev.id_equipment') || '
     GROUP BY 1, ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area, ev.tp_equipment, ev.state, ev.mode, ev.id_order,
              ev.conversion_factor, ev.number_cavities, ev.signal_quality, ev.id_shift, ev.id_team, ev.id_shift_hour,
              ev.id_production_order, ev.ts_value_production, ev.ideal_production_speed'
    USING m0, m1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  -- equipment_metrics_1min (cagg: tp_equipment IS NOT NULL; column `bucket`)
  EXECUTE 'DELETE FROM silver.equipment_metrics_1min' || x || ' WHERE bucket >= $1 AND bucket < $2' || eq USING m0, m1, p_equipment;
  EXECUTE 'INSERT INTO silver.equipment_metrics_1min' || x || '
    SELECT date_bin(''1 minute'', ts_value, $4), id_equipment, id_enterprise, id_site, id_area, tp_equipment,
           sum(net_production_incr::double precision), sum(gross_production_incr::double precision),
           sum(scrap_incr::double precision), sum(speed::double precision), count(speed), count(*),
           max(speed::double precision), max(ideal_production_speed)
      FROM silver.equipment_values
     WHERE tp_equipment IS NOT NULL AND ts_value >= $1 AND ts_value < $2' || eq || '
     GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment'
    USING m0, m1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  -- agg_equipment_values_1min (cagg: tp_equipment IS NOT NULL; last() → array_agg ORDER BY ts DESC)
  EXECUTE 'DELETE FROM silver.agg_equipment_values_1min' || x || ' WHERE ts_value >= $1 AND ts_value < $2' || eq USING m0, m1, p_equipment;
  EXECUTE 'INSERT INTO silver.agg_equipment_values_1min' || x || '
    SELECT date_bin(''1 minute'', ts_value, $4), id_enterprise, id_site, id_area, id_equipment, tp_equipment,
           sum(net_production_incr), sum(gross_production_incr), sum(scrap_incr), max(state), max(mode), avg(speed),
           max(id_order::text), max(conversion_factor), max(number_cavities), max(signal_quality),
           max(net_production_val), max(gross_production_val), max(scrap_val), max(id_shift), max(id_team), max(id_shift_hour),
           (array_agg(box_code ORDER BY ts_value DESC))[1], (array_agg(transaction_code ORDER BY ts_value DESC))[1],
           max(id_production_order), max(ts_value_production), max(id_equipment_line_connected),
           max(position_in_equipment_line), max(is_equipment_line_infeed), max(is_equipment_line_outfeed),
           max(ideal_production_speed)
      FROM silver.equipment_values
     WHERE tp_equipment IS NOT NULL AND ts_value >= $1 AND ts_value < $2' || eq || '
     GROUP BY 1, id_enterprise, id_site, id_area, id_equipment, tp_equipment'
    USING m0, m1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  -- equipment_categorical_1hour (cagg: over the minute cagg → over the minute twin)
  EXECUTE 'DELETE FROM silver.equipment_categorical_1hour' || x || ' WHERE ts_value >= $1 AND ts_value < $2' || eq USING h0, h1, p_equipment;
  EXECUTE 'INSERT INTO silver.equipment_categorical_1hour' || x || '
    SELECT date_bin(''1 hour'', m.ts_value, $4), m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment,
           m.state, m.mode, m.id_order, m.conversion_factor, m.number_cavities, m.signal_quality, m.id_shift, m.id_team,
           m.id_shift_hour, m.id_production_order, m.ts_value_production, m.ideal_production_speed,
           sum(m.net_production_incr), sum(m.gross_production_incr), sum(m.scrap_incr), sum(m.sum_speed),
           sum(m.cnt_speed), sum(m.cnt_rows), max(m.net_production_val), max(m.gross_production_val), max(m.scrap_val)
      FROM silver.equipment_categorical_1min' || x || ' m
     WHERE m.ts_value >= $1 AND m.ts_value < $2' || replace(eq, 'id_equipment', 'm.id_equipment') || '
     GROUP BY 1, m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment, m.state, m.mode, m.id_order,
              m.conversion_factor, m.number_cavities, m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour,
              m.id_production_order, m.ts_value_production, m.ideal_production_speed'
    USING h0, h1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  -- agg_equipment_values_1hour (cagg: over raw, tp_equipment IS NOT NULL, wide GROUP BY)
  EXECUTE 'DELETE FROM silver.agg_equipment_values_1hour' || x || ' WHERE ts_value >= $1 AND ts_value < $2' || eq USING h0, h1, p_equipment;
  EXECUTE 'INSERT INTO silver.agg_equipment_values_1hour' || x || '
    SELECT date_bin(''1 hour'', ts_value, $4), id_enterprise, id_site, id_area, id_equipment, tp_equipment,
           sum(net_production_incr), sum(gross_production_incr), sum(scrap_incr), mode, avg(speed),
           id_production_order, conversion_factor, number_cavities, signal_quality,
           max(net_production_val), max(gross_production_val), max(scrap_val), id_shift, id_team, id_shift_hour,
           box_code, transaction_code, ts_value_production, id_equipment_line_connected, position_in_equipment_line,
           is_equipment_line_infeed, is_equipment_line_outfeed
      FROM silver.equipment_values
     WHERE tp_equipment IS NOT NULL AND ts_value >= $1 AND ts_value < $2' || eq || '
     GROUP BY 1, id_enterprise, id_site, id_area, id_equipment, tp_equipment, mode, id_production_order, conversion_factor,
              number_cavities, signal_quality, id_shift, id_team, id_shift_hour, box_code, transaction_code,
              ts_value_production, id_equipment_line_connected, position_in_equipment_line, is_equipment_line_infeed,
              is_equipment_line_outfeed'
    USING h0, h1, p_equipment, o;
  GET DIAGNOSTICS k = ROW_COUNT; n := n + k;

  RETURN n;
END $function$;
COMMIT;
