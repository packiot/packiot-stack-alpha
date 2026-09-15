\pset pager off
\set ON_ERROR_STOP off
-- P0c remediation: v_events_2 was dropped in 03_p0c as 'orphan' but it backs the
-- LIVE contract fn h_piot_get_events_timeline_full_with_filter_3 (/v1 events-timeline-full).
-- Restore it (additive; reverse with DROP VIEW). Recovered from db/cutover/f3-stop-threshold.sql,
-- with the runtime_->oee_ rename applied (equipment_runtime_shift -> equipment_oee_shift).
CREATE OR REPLACE VIEW public.v_events_2 AS

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

GRANT SELECT ON public.v_events_2 TO superset_ro, bi_owner;
cho === v_events_2 restored; smoke test ===
SELECT 'v_events_2 rows(ent3, last 40d): '||count(*) FROM public.v_events_2 WHERE id_enterprise=3 AND ts_event > now()-interval '40 days';
