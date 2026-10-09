\pset pager off
\set ON_ERROR_STOP off
CREATE SCHEMA IF NOT EXISTS bi_next;
COMMENT ON SCHEMA bi_next IS 'P2 parallel serving layer (security_invoker) for equivalence gating vs bi.*. Analytics clean-schema redesign 2026-09-08.';

CREATE OR REPLACE VIEW bi_next.downtimes WITH (security_invoker=true) AS
 SELECT eq.id_enterprise, ev.id_equipment_event AS id_downtime, ev.id_equipment, eq.nm_equipment,
   ev.cd_category, ev.cd_subcategory, ev.desc_category, ev.desc_subcategory, ev.ts_event AS ts_value,
   ev.ts_end, ev.duration, ev.planned_downtime, ev.change_over, ev.status,
   CASE ev.status WHEN 6 THEN 'Running'::text WHEN 10 THEN 'Stopped'::text ELSE ev.status::text END AS status_label,
   COALESCE(ev.desc_category, CASE WHEN ev.planned_downtime THEN 'Planned'::text WHEN ev.change_over THEN 'Changeover'::text ELSE 'Unjustified'::text END::character varying) AS reason,
   eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
 FROM equipment_events ev JOIN equipments eq ON eq.id_equipment = ev.id_equipment WHERE ev.status <> 6;

CREATE OR REPLACE VIEW bi_next.equipments WITH (security_invoker=true) AS
 SELECT id_enterprise, id_equipment, nm_equipment, tp_equipment, id_area, lead_machine,
   nm_equipment::text || CASE tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
 FROM equipments WHERE active;

CREATE OR REPLACE VIEW bi_next.oee_hourly WITH (security_invoker=true) AS
 SELECT eq.id_enterprise, rh.id_equipment, eq.nm_equipment, rh.ts_value, rh.oee, rh.oee_a, rh.oee_p, rh.oee_q,
   rh.gross, rh.net, rh.running_time,
   eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
 FROM equipment_oee_hourly rh JOIN equipments eq ON eq.id_equipment = rh.id_equipment WHERE rh.ts_value <= now() AND rh.running_time > 0;

CREATE OR REPLACE VIEW bi_next.oee_shift WITH (security_invoker=true) AS
 SELECT eq.id_enterprise, rs.id_equipment, eq.nm_equipment, rs.id_shift, rs.cd_shift, rs.ts_value, rs.ts_end,
   rs.oee, rs.oee_a, rs.oee_p, rs.oee_q, rs.gross, rs.net, rs.running_time,
   eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
 FROM equipment_oee_shift rs JOIN equipments eq ON eq.id_equipment = rs.id_equipment WHERE rs.ts_value <= now() AND rs.running_time > 0;

CREATE OR REPLACE VIEW bi_next.production_orders WITH (security_invoker=true) AS
 SELECT po.id_enterprise, po.id_production_order, po.id_equipment, eq.nm_equipment, po.id_product, po.id_client,
   po.status, po.production_programmed, po.production_ordered, po.production_real, po.net_production, po.gross_production,
   po.oee, po.oee_availability, po.oee_performance, po.oee_quality, po.running_time, po.available_time, po.stopped_time,
   po.ts_start, po.ts_end, po.nm_production_order, po.id_order_text,
   COALESCE(NULLIF(po.nm_production_order::text, ''::text), NULLIF(po.id_order_text::text, ''::text), 'PO #'::text || po.id_production_order) AS po_label,
   eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
 FROM production_orders po JOIN equipments eq ON eq.id_equipment = po.id_equipment;

CREATE OR REPLACE VIEW bi_next.production_order_runtime WITH (security_invoker=true) AS
 SELECT eq.id_enterprise, por.id_production_order, por.id_equipment, por.oee, por.oee_a, por.oee_p, por.oee_q,
   por.gross_production, por.net_production, por.running_time,
   lower(por.runtime_timerange) AS ts_start, upper(por.runtime_timerange) AS ts_end
 FROM production_orders_runtime por JOIN equipments eq ON eq.id_equipment = por.id_equipment;

CREATE OR REPLACE VIEW bi_next.production_targets WITH (security_invoker=true) AS
 SELECT pt.id_enterprise, pt.id_equipment, eq.nm_equipment, pt.id_area, pt.id_site,
   pt.vl_hour, pt.vl_shift, pt.vl_day, pt.vl_week, pt.vl_month
 FROM production_targets pt JOIN equipments eq ON eq.id_equipment = pt.id_equipment;

CREATE OR REPLACE VIEW bi_next.equipment_speed WITH (security_invoker=true) AS
 SELECT eq.id_enterprise, ev.id_equipment, eq.nm_equipment, ev.ts_value,
   NULLIF(COALESCE(NULLIF(ev.speed, 0::double precision)::double precision,
     CASE WHEN COALESCE(ev.gross_production_incr, ev.net_production_incr, 0::real) > 0::double precision
       THEN COALESCE(NULLIF(ev.gross_production_incr, 0::double precision), ev.net_production_incr) / NULLIF(EXTRACT(epoch FROM ev.ts_value - lag(ev.ts_value) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_value)) / 60.0, 0::numeric)::double precision
       ELSE NULL::double precision END), 0::double precision) AS speed,
   ev.speed AS plc_speed, eq.production_speed AS ideal_production_speed, ev.id_shift, ev.id_production_order, ev.state, ev.mode,
   eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
 FROM equipment_values ev JOIN equipments eq ON eq.id_equipment = ev.id_equipment;

CREATE OR REPLACE VIEW bi_next.production_by_team WITH (security_invoker=true) AS
 SELECT eq.id_enterprise, ev.id_equipment, eq.nm_equipment, ev.id_team, ev.id_shift, ev.ts_value,
   ev.net_production_incr, ev.gross_production_incr, ev.scrap_incr,
   eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
 FROM equipment_values ev JOIN equipments eq ON eq.id_equipment = ev.id_equipment;

CREATE OR REPLACE VIEW bi_next.live_status WITH (security_invoker=true) AS
 SELECT DISTINCT ON (s.id_equipment) s.id_enterprise, s.id_equipment, s.nm_equipment, s.ts_value AS last_update,
   NULLIF(COALESCE(NULLIF(s.speed, 0::double precision)::double precision, s.inferred_speed), 0::double precision) AS speed,
   s.speed AS plc_speed, s.ideal_production_speed, s.state, s.mode, s.id_production_order, s.id_order,
   s.net_production_val, s.gross_production_val, s.scrap_val,
   s.nm_equipment::text || CASE s.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label,
   COALESCE(NULLIF(s.id_order::text, ''::text), 'No production order'::text) AS id_order_label,
   CASE s.state WHEN 6 THEN 'Running'::text WHEN 10 THEN 'Stopped'::text ELSE 'Idle / no signal'::text END AS state_label
 FROM ( SELECT eq.id_enterprise, ev.id_equipment, eq.nm_equipment, eq.tp_equipment, ev.ts_value, ev.speed,
     eq.production_speed AS ideal_production_speed,
     CASE WHEN COALESCE(ev.gross_production_incr, ev.net_production_incr, 0::real) > 0::double precision
       THEN COALESCE(NULLIF(ev.gross_production_incr, 0::double precision), ev.net_production_incr) / NULLIF(EXTRACT(epoch FROM ev.ts_value - lag(ev.ts_value) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_value)) / 60.0, 0::numeric)::double precision
       ELSE NULL::double precision END AS inferred_speed,
     ev.state, ev.mode, ev.id_production_order, ev.id_order, ev.net_production_val, ev.gross_production_val, ev.scrap_val
    FROM equipment_values ev JOIN equipments eq ON eq.id_equipment = ev.id_equipment
    WHERE ev.ts_value > (now() - '06:00:00'::interval)) s
 ORDER BY s.id_equipment, s.ts_value DESC;

GRANT USAGE ON SCHEMA bi_next TO superset_ro, bi_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA bi_next TO superset_ro, bi_owner;
\echo === bi_next views created ===
SELECT count(*) AS bi_next_views FROM pg_class WHERE relnamespace='bi_next'::regnamespace AND relkind='v';
