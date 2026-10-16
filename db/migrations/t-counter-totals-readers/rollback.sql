-- rollback for t-counter-totals-readers: views back to their 2026-10-07 live definitions.
-- Appended columns can't be removed by CREATE OR REPLACE, so each view is dropped and recreated, then its
-- owner, grants and comment are restored exactly (nothing depends on either view; verified 2026-10-07).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

DROP VIEW bi.live_status;
CREATE VIEW bi.live_status AS
 SELECT DISTINCT ON (s.id_equipment) s.id_enterprise,
    s.id_equipment,
    s.nm_equipment,
    s.ts_value AS last_update,
    NULLIF(COALESCE(NULLIF(s.speed, 0::double precision)::double precision, s.inferred_speed), 0::double precision) AS speed,
    s.speed AS plc_speed,
    s.ideal_production_speed,
    s.state,
    s.mode,
    s.id_production_order,
    s.id_order,
    s.net_production_val,
    s.gross_production_val,
    s.scrap_val,
    s.nm_equipment::text ||
        CASE s.tp_equipment
            WHEN 3 THEN ' (line)'::text
            WHEN 1 THEN ' (machine)'::text
            WHEN 2 THEN ' (sector)'::text
            ELSE ''::text
        END AS equipment_label,
    COALESCE(NULLIF(s.id_order::text, ''::text), 'No production order'::text) AS id_order_label,
        CASE s.state
            WHEN 6 THEN 'Running'::text
            WHEN 10 THEN 'Stopped'::text
            ELSE 'Idle / no signal'::text
        END AS state_label
   FROM ( SELECT eq.id_enterprise,
            ev.id_equipment,
            eq.nm_equipment,
            eq.tp_equipment,
            ev.ts_value,
            ev.speed,
            eq.production_speed AS ideal_production_speed,
                CASE
                    WHEN COALESCE(ev.gross_production_incr, ev.net_production_incr, 0::real) > 0::double precision THEN COALESCE(NULLIF(ev.gross_production_incr, 0::double precision), ev.net_production_incr) / NULLIF(EXTRACT(epoch FROM ev.ts_value - lag(ev.ts_value) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_value)) / 60.0, 0::numeric)::double precision
                    ELSE NULL::double precision
                END AS inferred_speed,
            ev.state,
            ev.mode,
            ev.id_production_order,
            ev.id_order,
            ev.net_production_val,
            ev.gross_production_val,
            ev.scrap_val
           FROM silver.equipment_values ev
             JOIN core.equipments eq ON eq.id_equipment = ev.id_equipment
          WHERE ev.ts_value > (now() - '06:00:00'::interval)) s
  ORDER BY s.id_equipment, s.ts_value DESC;
ALTER VIEW bi.live_status OWNER TO bi_owner;
GRANT SELECT ON bi.live_status TO cloudbeaver_ro, readapi_ro, superset_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON bi.live_status TO cloudbeaver_rw;
COMMENT ON VIEW bi.live_status IS 'bi (Superset): latest live status/speed snapshot per equipment (DISTINCT ON id_equipment, last_update). Tenant fence external.';

DROP VIEW silver.equipment_values_labeled;
CREATE VIEW silver.equipment_values_labeled AS
 SELECT v.id_equipment,
    v.ts_value,
    v.id_enterprise,
    v.id_site,
    v.id_area,
    v.net_production_incr,
    v.gross_production_incr,
    v.scrap_incr,
    v.speed,
    v.id_order,
    v.conversion_factor,
    v.number_cavities,
    v.faults,
    v.analogs,
    v.signal_quality,
    v.net_production_val,
    v.gross_production_val,
    v.scrap_val,
    v.id_shift,
    v.id_team,
    v.id_shift_hour,
    v.box_code,
    v.transaction_code,
    v.state,
    v.mode,
    v.id_production_order,
    v.ts_value_production,
    v.id_equipment_line_infeed,
    v.id_equipment_line_outfeed,
    v.net_production_incr_quality,
    v.gross_production_incr_quality,
    v.scrap_incr_quality,
    v.speed_quality,
    v.id_order_quality,
    v.conversion_factor_quality,
    v.number_cavities_quality,
    v.net_production_val_quality,
    v.gross_production_val_quality,
    v.scrap_val_quality,
    v.id_shift_quality,
    v.state_quality,
    v.mode_quality,
    v.id_production_order_quality,
    v.ts_value_production_quality,
    v.id_equipment_line_connected,
    v.position_in_equipment_line,
    v.is_equipment_line_infeed,
    v.is_equipment_line_outfeed,
    v.process_scrap_incr,
    v.process_scrap_val,
    v.process_scrap_incr_quality,
    v.process_scrap_val_quality,
    v.tp_equipment,
    v.sub_mode,
    v.ideal_production_speed,
    v.check_number,
    v.ingested_at,
    v.source_seq,
    ms.label AS state_label,
    ms.is_running,
    ms.is_stopped
   FROM silver.equipment_values v
     LEFT JOIN silver.machine_state ms ON ms.state = v.state;
ALTER VIEW silver.equipment_values_labeled OWNER TO postgres;
GRANT SELECT ON silver.equipment_values_labeled TO bi_owner, cloudbeaver_ro, readapi_ro, superset_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON silver.equipment_values_labeled TO cloudbeaver_rw;
COMMENT ON VIEW silver.equipment_values_labeled IS 'Readable projection of silver.equipment_values: adds state_label / is_running / is_stopped by joining silver.machine_state on state. Additive; the raw state int is unchanged. NULL state_label = code not in silver.machine_state (or NULL state — counters-only sample with no state signal, cf. #209 CPACK).';

COMMIT;
