-- 0018-f3-refdata-deps.sql — refdata-api SQL dependencies provisioned on
-- packiot_shadow (APPLIED 2026-07-07, as-executed). Discovery: F3 had only
-- language_packs of refdata's 7 deps — every /v1 operator route would 500
-- at flip. Function bodies = PROD (ground truth; fixes the staging stub's
-- integer event_type — prod returns 'downtime'|'low_speed'|'manual').
-- Type tables = prod column order (fn/type must pair). custom_field jsonb
-- added to F3 production_orders (all-NULL on F1, view-compat only).
-- equipment_events_low_speed created empty (deriver fate = D-phase item).

CREATE TABLE IF NOT EXISTS equipment_events_low_speed (id_equipment integer, ts_event timestamp with time zone, status integer, id_equipment_event bigint, txt_downtime_notes character varying, idle character varying, idle_processed boolean, forced_creation_system boolean, fault integer, fault_processed boolean, cd_machine character varying, cd_category character varying, cd_subcategory character varying, change_over boolean, planned_downtime boolean, ts_end timestamp with time zone, duration integer, id_enterprise integer, desc_category character varying, desc_subcategory character varying, speed real, ideal_production_speed integer);
DROP TABLE IF EXISTS h_events_timeline3_with_event_id CASCADE; CREATE TABLE h_events_timeline3_with_event_id (id_equipment_event bigint, ts_event timestamp with time zone, ts_end timestamp with time zone, duration integer, id_equipment integer, id_enterprise integer, txt_downtime_notes character varying, cd_machine character varying, cd_category character varying, cd_subcategory character varying, change_over boolean, desc_category character varying, desc_subcategory character varying, packml_topic character varying, event_type text, id_order_text character varying, id_production_order bigint, production_programmed bigint, custom_field jsonb);
DROP TABLE IF EXISTS h_pending_events_with_event_id CASCADE; CREATE TABLE h_pending_events_with_event_id (id_equipment_event bigint, ts_event timestamp with time zone, ts_end timestamp with time zone, duration integer, id_equipment integer, id_enterprise integer, packml_topic character varying);

CREATE OR REPLACE FUNCTION public.h_piot_get_equipment_pending_downtime_with_event_id(in_packml_topic character varying[])
 RETURNS SETOF h_pending_events_with_event_id
 LANGUAGE sql
 STABLE
AS $function$
	SELECT id_equipment_event, ts_event, ts_end, duration, e.id_equipment, e.id_enterprise, p.packml_topic
    FROM equipment_events ee
    JOIN equipments e ON ee.id_equipment = e.id_equipment
    join packml_register p on p.id_equipment = e.id_equipment
    WHERE p.packml_topic = ANY (in_packml_topic)
        AND ee.ts_event >= now() - interval '4 days'
        AND ee.status != 6
        AND (ee.duration >= e.stop_threshold_time or ee.duration is null)
        and ee.cd_category is null
    ORDER BY ts_event DESC;
   $function$
;
CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline3_with_event_id(in_packml_topic character varying[])
 RETURNS SETOF h_events_timeline3_with_event_id
 LANGUAGE sql
 STABLE
AS $function$

select
	id_equipment_event,
  ts_event,
  ee.ts_end,
  duration,
  e.id_equipment,
  e.id_enterprise,
  txt_downtime_notes,
  cd_machine,
  cd_category,
  cd_subcategory,
  change_over,
  desc_category,
  desc_subcategory,
  p.packml_topic,
  'downtime' :: text as event_type,
  po.id_order_text,
  po.id_production_order,
  po.production_programmed,
  po.custom_field
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
where
  p.packml_topic = ANY (in_packml_topic)
  --AND 
  --ee.ts_event >= now() - interval '1 days'
  AND (ee.ts_end >= now() - interval '1 days' OR ee.ts_end IS NULL)
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null or ee.cd_category is not null))
  AND ee.status != 6
  and ee.cd_category is not null
union
select
	eels.id_equipment_event  as id_equipment_event,
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	e.id_equipment,
	e.id_enterprise,
	eels.txt_downtime_notes,
	eels.cd_machine,
	eels.cd_category,
	eels.desc_category,
	eels.change_over,
	eels.desc_subcategory,
	eels.cd_subcategory,
	p.packml_topic,
	'low_speed' :: text as event_type,
	po.id_order_text,
	po.id_production_order,
	po.production_programmed,
	po.custom_field
FROM
	equipment_events_low_speed eels
	JOIN equipments e ON eels.id_equipment = e.id_equipment
	JOIN packml_register p ON p.id_equipment = e.id_equipment
	left join production_orders_runtime por on (eels.id_equipment = por.id_equipment  and eels.ts_event <@ por.runtime_timerange)
	left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
	p.packml_topic = ANY (in_packml_topic)
	AND eels.ts_event >= now() - interval '1 days'
	AND eels.status = 1 OR eels.status = 2	
UNION
select
	eem.id_equipment_event as id_equipment_event,
  eem.ts_event as ts_event,
  eem.ts_end as ts_end,
  extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer as duration,
  e.id_equipment,
  e.id_enterprise,
  eem.txt_downtime_notes,
  eem.cd_machine,
  eem.cd_category,
  eem.cd_subcategory,
  eem.change_over,
  eem.desc_category,
  eem.desc_subcategory,
  p.packml_topic,
  'manual' :: text as event_type,
  po.id_order_text,
  po.id_production_order,
  po.production_programmed,
  po.custom_field
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment = e.id_equipment
  JOIN packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (eem.id_equipment = por.id_equipment  and eem.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND eem.ts_event >= now() - interval '1 days'
   -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
 
$function$
;
CREATE OR REPLACE VIEW v_entities_per_user_role_operator AS  SELECT v.id_enterprise,
    v.id_enterprise AS id_user_role,
    e.nm_enterprise AS nm_user_role,
    v.enterprise,
    v.sites,
    v.areas,
    v.lines,
    v.sectors,
    v.machines,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'id_equipment', eq.id_equipment, 'name', eq.nm_equipment, 'packml_topic', pr.packml_topic) ORDER BY eq.id_equipment) AS jsonb_agg
           FROM equipments eq
             LEFT JOIN packml_register pr ON pr.id_equipment = eq.id_equipment AND pr.active = true
          WHERE eq.id_enterprise = v.id_enterprise AND eq.tp_equipment = 1), '[]'::jsonb) AS equipments,
    '[]'::jsonb AS shifts,
    '[]'::jsonb AS teams
   FROM v_operator_entities_2 v
     JOIN enterprises e ON e.id_enterprise = v.id_enterprise;;
CREATE OR REPLACE VIEW v_operator_entities_2 AS  SELECT e.id_enterprise,
    jsonb_build_array(jsonb_build_object('id', e.id_enterprise, 'name', e.nm_enterprise)) AS enterprise,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', s.id_site, 'name', s.nm_site)) AS jsonb_agg
           FROM sites s
          WHERE s.id_enterprise = e.id_enterprise), '[]'::jsonb) AS sites,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', a.id_area, 'name', a.nm_area)) AS jsonb_agg
           FROM areas a
             JOIN sites s ON s.id_site = a.id_site
          WHERE s.id_enterprise = e.id_enterprise), '[]'::jsonb) AS areas,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment)) AS jsonb_agg
           FROM equipments eq
          WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 3), '[]'::jsonb) AS lines,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment)) AS jsonb_agg
           FROM equipments eq
          WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 2), '[]'::jsonb) AS sectors,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment)) AS jsonb_agg
           FROM equipments eq
          WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 1), '[]'::jsonb) AS machines
   FROM enterprises e;;
CREATE OR REPLACE VIEW v_operator_po_details_3 AS  SELECT base.id_production_order,
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
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, po.ts_start, po.ts_end) base;;
CREATE OR REPLACE VIEW v_operator_po_list_setup_4 AS  SELECT po.id_production_order,
    po.id_production_order::integer AS id_order,
    po.id_enterprise,
    po.id_equipment,
    po.status,
    COALESCE(po.production_programmed, 0::bigint) AS production_programmed,
    po.ts_start,
    NULL::jsonb AS equipment_setup,
    1.0::double precision AS conversion_factor,
    NULL::jsonb AS custom_field,
    NULL::jsonb AS priority,
    pr.packml_topic AS topic,
    po.txt_production_order_notes AS nm_client,
    NULL::character varying AS nm_product_family,
    COALESCE(po.id_order_text, ('PO-'::text || po.id_production_order::text)::character varying) AS nm_product,
    NULL::character varying AS txt_product
   FROM production_orders po
     LEFT JOIN LATERAL ( SELECT packml_register.packml_topic
           FROM packml_register
          WHERE packml_register.id_equipment = po.id_equipment AND packml_register.active = true
         LIMIT 1) pr ON true;;


CREATE OR REPLACE VIEW v_operator_entities_2 AS  SELECT e.id_enterprise,
    jsonb_build_array(jsonb_build_object('id', e.id_enterprise, 'name', e.nm_enterprise)) AS enterprise,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', s.id_site, 'name', s.nm_site)) AS jsonb_agg
           FROM sites s
          WHERE s.id_enterprise = e.id_enterprise), '[]'::jsonb) AS sites,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', a.id_area, 'name', a.nm_area)) AS jsonb_agg
           FROM areas a
             JOIN sites s ON s.id_site = a.id_site
          WHERE s.id_enterprise = e.id_enterprise), '[]'::jsonb) AS areas,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment)) AS jsonb_agg
           FROM equipments eq
          WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 3), '[]'::jsonb) AS lines,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment)) AS jsonb_agg
           FROM equipments eq
          WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 2), '[]'::jsonb) AS sectors,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment)) AS jsonb_agg
           FROM equipments eq
          WHERE eq.id_enterprise = e.id_enterprise AND eq.tp_equipment = 1), '[]'::jsonb) AS machines
   FROM enterprises e;
CREATE OR REPLACE VIEW v_operator_po_details_3 AS  SELECT base.id_production_order,
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
CREATE OR REPLACE VIEW v_operator_po_list_setup_4 AS  SELECT po.id_production_order,
    po.id_production_order::integer AS id_order,
    po.id_enterprise,
    po.id_equipment,
    po.status,
    COALESCE(po.production_programmed, 0::bigint) AS production_programmed,
    po.ts_start,
    NULL::jsonb AS equipment_setup,
    1.0::double precision AS conversion_factor,
    NULL::jsonb AS custom_field,
    NULL::jsonb AS priority,
    pr.packml_topic AS topic,
    po.txt_production_order_notes AS nm_client,
    NULL::character varying AS nm_product_family,
    COALESCE(po.id_order_text, ('PO-'::text || po.id_production_order::text)::character varying) AS nm_product,
    NULL::character varying AS txt_product
   FROM production_orders po
     LEFT JOIN LATERAL ( SELECT packml_register.packml_topic
           FROM packml_register
          WHERE packml_register.id_equipment = po.id_equipment AND packml_register.active = true
         LIMIT 1) pr ON true;
CREATE OR REPLACE VIEW v_entities_per_user_role_operator AS  SELECT v.id_enterprise,
    v.id_enterprise AS id_user_role,
    e.nm_enterprise AS nm_user_role,
    v.enterprise,
    v.sites,
    v.areas,
    v.lines,
    v.sectors,
    v.machines,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'id_equipment', eq.id_equipment, 'name', eq.nm_equipment, 'packml_topic', pr.packml_topic) ORDER BY eq.id_equipment) AS jsonb_agg
           FROM equipments eq
             LEFT JOIN packml_register pr ON pr.id_equipment = eq.id_equipment AND pr.active = true
          WHERE eq.id_enterprise = v.id_enterprise AND eq.tp_equipment = 1), '[]'::jsonb) AS equipments,
    '[]'::jsonb AS shifts,
    '[]'::jsonb AS teams
   FROM v_operator_entities_2 v
     JOIN enterprises e ON e.id_enterprise = v.id_enterprise;