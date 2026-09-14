-- t281 ROLLBACK — reverse the int4->int8 widening + FK on gold.production_orders_runtime.
--
-- Inverse of 01-up.sql:
--   1. drop the FK production_orders_runtime_id_production_order_fkey
--   2. drop the 4 dependent views (blockers of ALTER COLUMN ... TYPE)
--   3. narrow id_production_order bigint -> integer
--      (SAFE only while max(id_production_order) < 2^31 = 2,147,483,647; live max = 2,025,144)
--   4. recreate the 4 views VERBATIM (same bodies — bodies do not depend on the column type),
--      restoring owner / grants / security_invoker / COMMENT to their captured state.
--
-- Same search_path as up so the bare names re-resolve identically. lock_timeout guards the
-- brief ACCESS EXCLUSIVE rewrite. If the sequence has since crossed 2^31, this narrowing will
-- fail with a numeric overflow (by design — do not force it).

BEGIN;

SET lock_timeout = '5s';
SET search_path = gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public;

-- ── 1. drop the FK ──
ALTER TABLE gold.production_orders_runtime
  DROP CONSTRAINT production_orders_runtime_id_production_order_fkey;

-- ── 2. drop the 4 views ──
DROP VIEW bi.production_order_runtime;
DROP VIEW serving.v_events_2;
DROP VIEW serving.v_operator_po_details_3;
DROP VIEW serving.v_report_downtimes;

-- ── 3. narrow back to int4 (safe while max < 2^31) ──
ALTER TABLE gold.production_orders_runtime
  ALTER COLUMN id_production_order TYPE integer;

-- ── 4. recreate the 4 views verbatim (identical to up), restore owner/grants/security_invoker/comment ──

-- 4a. bi.production_order_runtime  (owner bi_owner, DEFINER) — create as postgres (bi_owner lacks
--     USAGE on gold/core so cannot resolve bare names at parse time), then transfer ownership and
--     grant under the bi_owner role to match the captured relacl grantor.
CREATE VIEW bi.production_order_runtime AS
 SELECT eq.id_enterprise,
    por.id_production_order,
    por.id_equipment,
    por.oee,
    por.oee_a,
    por.oee_p,
    por.oee_q,
    por.gross_production,
    por.net_production,
    por.running_time,
    lower(por.runtime_timerange) AS ts_start,
    upper(por.runtime_timerange) AS ts_end
   FROM production_orders_runtime por
     JOIN equipments eq ON eq.id_equipment = por.id_equipment;
ALTER VIEW bi.production_order_runtime OWNER TO bi_owner;
SET LOCAL ROLE bi_owner;
GRANT SELECT ON bi.production_order_runtime TO superset_ro, cloudbeaver_ro, readapi_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON bi.production_order_runtime TO cloudbeaver_rw;
RESET ROLE;
COMMENT ON VIEW bi.production_order_runtime IS 'bi (Superset): one row per PO runtime segment (OEE decomposition, gross/net, running_time, runtime range). Tenant fence external.';

-- 4b. serving.v_events_2  (owner postgres, security_invoker=on)
CREATE VIEW serving.v_events_2 AS
 SELECT 1 AS event_type,
    ee.ts_event AS ts_timeline,
    ee.ts_event,
    ee.ts_end,
    ee.duration,
    COALESCE(ppe.id_equipment, pe.id_equipment, e.id_equipment) AS id_equipment,
    COALESCE(ppe.nm_equipment, pe.nm_equipment, e.nm_equipment) AS nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    ee.txt_downtime_notes,
    ee.cd_machine,
    ee.cd_category,
    ee.cd_subcategory,
    ee.change_over,
    ee.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_events ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     LEFT JOIN equipments pe ON pe.id_equipment = e.id_parentequipment
     LEFT JOIN equipments ppe ON ppe.id_equipment = pe.id_parentequipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
  WHERE (ee.duration >= COALESCE(e.stop_threshold_time, 0) OR ee.ts_end IS NULL) AND ee.status <> 6 AND e.event_should_be_displayed = true
UNION
 SELECT 2 AS event_type,
    eem.ts_event AS ts_timeline,
    eem.ts_event,
    eem.ts_end,
    date_part('epoch'::text, eem.ts_end - eem.ts_event)::integer AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    eem.txt_downtime_notes,
    eem.cd_machine,
    eem.cd_category,
    eem.cd_subcategory,
    eem.change_over,
    eem.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_events_man eem
     JOIN equipments e ON eem.id_equipment_event = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
UNION
 SELECT 3 AS event_type,
    ee.ts_event AS ts_timeline,
    ee.ts_event,
    ee.ts_end,
    ee.duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    ee.txt_downtime_notes,
    ee.cd_machine,
    ee.cd_category,
    ee.cd_subcategory,
    ee.change_over,
    ee.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_events_low_speed ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
  WHERE (ee.duration >= COALESCE(e.stop_threshold_time, 0) OR ee.ts_end IS NULL) AND ee.status <> 6 AND e.event_should_be_displayed = true
UNION
 SELECT 4 AS event_type,
    lower(ee.runtime_timerange) AS ts_timeline,
    lower(ee.runtime_timerange) AS ts_event,
    upper(ee.runtime_timerange) AS ts_end,
        CASE
            WHEN upper(ee.runtime_timerange) IS NOT NULL THEN date_part('epoch'::text, upper(ee.runtime_timerange) - lower(ee.runtime_timerange))::integer
            ELSE NULL::integer
        END AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    COALESCE(po.id_order_text, po.id_order::character varying) AS id_order,
    c.nm_client
   FROM production_orders_runtime ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN production_orders po USING (id_production_order)
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
     LEFT JOIN clients c USING (id_client)
UNION
 SELECT 5 AS event_type,
    upper(ee.runtime_timerange) AS ts_timeline,
    lower(ee.runtime_timerange) AS ts_event,
    upper(ee.runtime_timerange) AS ts_end,
        CASE
            WHEN upper(ee.runtime_timerange) IS NOT NULL THEN date_part('epoch'::text, upper(ee.runtime_timerange) - lower(ee.runtime_timerange))::integer
            ELSE NULL::integer
        END AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    COALESCE(po.id_order_text, po.id_order::character varying) AS id_order,
    c.nm_client
   FROM production_orders_runtime ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
     JOIN production_orders po USING (id_production_order)
     LEFT JOIN clients c USING (id_client)
  WHERE upper(ee.runtime_timerange) IS NOT NULL
UNION
 SELECT 6 AS event_type,
    ee.ts_value AS ts_timeline,
    ee.ts_value AS ts_event,
    ee.ts_end,
    ee.duration,
    ee.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_oee_shift ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
  WHERE ee.ts_value < now();
ALTER VIEW serving.v_events_2 SET (security_invoker = on);
GRANT SELECT ON serving.v_events_2 TO superset_ro, bi_owner, cloudbeaver_ro, readapi_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON serving.v_events_2 TO cloudbeaver_rw;
COMMENT ON VIEW serving.v_events_2 IS 'serving: unified event timeline (downtimes + PO/plc events) resolving id_equipment across parent/child event tables. Backing view for event-timeline reads.';

-- 4c. serving.v_operator_po_details_3  (owner postgres, security_invoker=on)
CREATE VIEW serving.v_operator_po_details_3 AS
 SELECT base.id_production_order,
    base.id_equipment,
    base.id_enterprise,
    base.net_production,
    base.scrap,
    base.running_time,
    base.downtime,
    base.net_production + base.scrap AS gross
   FROM ( SELECT po.id_production_order,
            po.id_equipment,
            po.id_enterprise,
            po.ts_start,
            po.ts_end,
            COALESCE(NULLIF(sum(por.net_production), 0::double precision), (( SELECT COALESCE(sum(ev.net_production_incr), 0::real) AS "coalesce"
                   FROM equipment_values ev
                  WHERE ev.id_equipment = po.id_equipment AND po.ts_start IS NOT NULL AND ev.ts_value >= po.ts_start AND (po.ts_end IS NULL OR ev.ts_value <= po.ts_end)))::double precision, 0::double precision) AS net_production,
            COALESCE(NULLIF(sum(COALESCE(por.gross_production, 0::double precision) - COALESCE(por.net_production, 0::double precision)), 0::double precision), 0::double precision) AS scrap,
            COALESCE(sum(EXTRACT(epoch FROM COALESCE(upper(por.runtime_timerange), now()) - lower(por.runtime_timerange))), 0::numeric)::integer AS running_time,
            COALESCE(( SELECT sum(
                        CASE
                            WHEN ee.ts_end IS NULL THEN GREATEST(0, EXTRACT(epoch FROM now() - ee.ts_event)::integer)
                            ELSE COALESCE(ee.duration, 0)
                        END) AS sum
                   FROM equipment_events ee
                  WHERE ee.id_equipment = po.id_equipment AND po.ts_start IS NOT NULL AND ee.ts_event >= po.ts_start AND (po.ts_end IS NULL OR ee.ts_event <= po.ts_end) AND ee.status <> 6 AND ee.forced_creation_system = false), 0::bigint)::integer AS downtime
           FROM production_orders po
             LEFT JOIN production_orders_runtime por ON por.id_production_order = po.id_production_order
          WHERE po.status = ANY (ARRAY[1, 2, 4])
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, po.ts_start, po.ts_end) base;
ALTER VIEW serving.v_operator_po_details_3 SET (security_invoker = on);
GRANT SELECT ON serving.v_operator_po_details_3 TO cloudbeaver_ro, readapi_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON serving.v_operator_po_details_3 TO cloudbeaver_rw;
COMMENT ON VIEW serving.v_operator_po_details_3 IS 'serving: operator-app production-order detail (net_production/scrap/running_time/downtime + derived rates) for one PO. Read by read-api /v1/operator-po-details.';

-- 4d. serving.v_report_downtimes  (owner postgres, security_invoker=on)
CREATE VIEW serving.v_report_downtimes AS
 SELECT po.id_order AS op,
    e.nm_equipment AS linha,
    shift.cd_shift AS turno,
    eventos.ts_event AS inicio,
    eventos.ts_end AS fim,
    eventos.duration AS duracao,
    eventos.cd_machine AS maquina,
    eventos.cd_category AS codigo_categoria,
    eventos.cd_subcategory AS codigo_subcategoria,
    eventos.desc_category AS descricao_categoria,
    eventos.desc_subcategory AS descricao_subcategoria,
    eventos.txt_downtime_notes AS anotacao,
    eventos.id_enterprise,
    shift.ts_value
   FROM ( SELECT equipment_events.id_equipment,
            equipment_events.ts_event,
            equipment_events.status,
            equipment_events.id_equipment_event,
            equipment_events.txt_downtime_notes,
            equipment_events.idle,
            equipment_events.idle_processed,
            equipment_events.forced_creation_system,
            equipment_events.fault,
            equipment_events.fault_processed,
            equipment_events.cd_machine,
            equipment_events.cd_category,
            equipment_events.cd_subcategory,
            equipment_events.change_over,
            equipment_events.planned_downtime,
            equipment_events.ts_end,
            equipment_events.duration,
            equipment_events.id_enterprise,
            equipment_events.desc_category,
            equipment_events.desc_subcategory,
            equipment_events.cd_category_client,
            equipment_events.cd_subcategory_client,
            equipment_events.last_update,
            equipment_events.ignore_cost
           FROM equipment_events
        UNION ALL
         SELECT equipment_events_man.id_equipment,
            equipment_events_man.ts_event,
            equipment_events_man.status,
            equipment_events_man.id_equipment_event,
            equipment_events_man.txt_downtime_notes,
            equipment_events_man.idle,
            equipment_events_man.idle_processed,
            equipment_events_man.forced_creation_system,
            equipment_events_man.fault,
            equipment_events_man.fault_processed,
            equipment_events_man.cd_machine,
            equipment_events_man.cd_category,
            equipment_events_man.cd_subcategory,
            equipment_events_man.change_over,
            equipment_events_man.planned_downtime,
            equipment_events_man.ts_end,
            equipment_events_man.duration,
            equipment_events_man.id_enterprise,
            equipment_events_man.desc_category,
            equipment_events_man.desc_subcategory,
            equipment_events_man.cd_category_client,
            equipment_events_man.cd_subcategory_client,
            equipment_events_man.last_update,
            equipment_events_man.ignore_cost
           FROM equipment_events_man) eventos
     JOIN equipment_oee_shift shift ON eventos.id_equipment = shift.id_equipment
     JOIN equipments e ON eventos.id_equipment = e.id_equipment
     LEFT JOIN production_orders_runtime por ON por.id_equipment = eventos.id_equipment AND por.runtime_timerange @> eventos.ts_event
     LEFT JOIN production_orders po ON po.id_production_order = por.id_production_order
  WHERE eventos.status = 10 AND e.event_should_be_displayed = true AND eventos.ts_event >= lower(shift.ts_range) AND eventos.ts_event <= upper(shift.ts_range) AND eventos.duration >= COALESCE(e.stop_threshold_time, 0);
ALTER VIEW serving.v_report_downtimes SET (security_invoker = on);
GRANT SELECT ON serving.v_report_downtimes TO cloudbeaver_ro, readapi_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON serving.v_report_downtimes TO cloudbeaver_rw;
COMMENT ON VIEW serving.v_report_downtimes IS 'serving: DBA-owned tenant-carrying downtime report view (UNION+joins), keyed by SHIFT begin (ts_value = shift begin, NOT event ts). Read by read-api report-downtimes (tenant-custom).';

COMMIT;
