-- t-counter-totals-readers — F1b of t-counter-totals-float8 (2026-10-07): the two views that expose the
-- float4 totalizers also expose the exact float8 *_total.
--
-- WHY: silver.equipment_values.*_val is float4 (exact only to 2^24 = 16,777,216; the largest client's
-- totalizers are ~3e8, where float4 steps by 32). t-counter-totals-float8 added *_total double precision
-- next to them and stream-engine dual-writes both from F1b on.
--
-- WHAT: CREATE OR REPLACE VIEW can only APPEND columns (an existing column can't change type), so the
-- *_val columns stay exactly as they are (Superset charts, read-api) and *_total columns are appended at the
-- end. Each *_total is COALESCE(*_total, *_val): exact on rows written since the dual-write, the old float4
-- value before it, so readers switch columns once and never see a NULL hole for history.
-- Bodies are the LIVE definitions (pg_get_viewdef with search_path='', 2026-10-07) plus the appended columns.
-- No table lock: only the two views are replaced (nothing depends on either view).
-- Rollback: rollback.sql. Verify: verify.sql.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE VIEW bi.live_status AS
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
        END AS state_label,
    s.net_production_total,
    s.gross_production_total,
    s.scrap_total
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
            ev.scrap_val,
            COALESCE(ev.net_production_total, ev.net_production_val::double precision) AS net_production_total,
            COALESCE(ev.gross_production_total, ev.gross_production_val::double precision) AS gross_production_total,
            COALESCE(ev.scrap_total, ev.scrap_val::double precision) AS scrap_total
           FROM silver.equipment_values ev
             JOIN core.equipments eq ON eq.id_equipment = ev.id_equipment
          WHERE ev.ts_value > (now() - '06:00:00'::interval)) s
  ORDER BY s.id_equipment, s.ts_value DESC;

CREATE OR REPLACE VIEW silver.equipment_values_labeled AS
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
    ms.is_stopped,
    COALESCE(v.net_production_total, v.net_production_val::double precision) AS net_production_total,
    COALESCE(v.gross_production_total, v.gross_production_val::double precision) AS gross_production_total,
    COALESCE(v.scrap_total, v.scrap_val::double precision) AS scrap_total,
    COALESCE(v.process_scrap_total, v.process_scrap_val::double precision) AS process_scrap_total
   FROM silver.equipment_values v
     LEFT JOIN silver.machine_state ms ON ms.state = v.state;

COMMENT ON COLUMN bi.live_status.net_production_total IS 'Exact net totalizer (float8): *_total when written (stream-engine dual-write, 2026-10-07+), else the float4 net_production_val. Use this, not net_production_val.';
COMMENT ON COLUMN bi.live_status.gross_production_total IS 'Exact gross totalizer (float8): *_total when written, else the float4 gross_production_val. Use this, not gross_production_val.';
COMMENT ON COLUMN bi.live_status.scrap_total IS 'Exact scrap totalizer (float8): *_total when written, else the float4 scrap_val. Use this, not scrap_val.';
COMMENT ON COLUMN silver.equipment_values_labeled.net_production_total IS 'Exact net totalizer (float8): *_total when written (stream-engine dual-write, 2026-10-07+), else the float4 net_production_val.';
COMMENT ON COLUMN silver.equipment_values_labeled.gross_production_total IS 'Exact gross totalizer (float8): *_total when written, else the float4 gross_production_val.';
COMMENT ON COLUMN silver.equipment_values_labeled.scrap_total IS 'Exact scrap totalizer (float8): *_total when written, else the float4 scrap_val.';
COMMENT ON COLUMN silver.equipment_values_labeled.process_scrap_total IS 'Exact process-scrap totalizer (float8): *_total when written, else the float4 process_scrap_val.';

COMMIT;
