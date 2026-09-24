-- t-events-timeline-bound — fix serving.events_timeline (operator HISTORIC events).
-- 1) detected-events branch had its ts_event bound commented out → no chunk exclusion →
--    full-history scan/decompression → >15 s → read-api 500 for CPACK and every tenant
--    (worsened by the T1 history backfill). Bound: ts_event >= now() - 7 days.
-- 2) low-speed branch: `AND status = 1 OR status = 2` (precedence) → parenthesized.
-- Generated from the LIVE definition (pg_get_functiondef) + two surgical edits.
CREATE OR REPLACE FUNCTION serving.events_timeline(in_packml_topic character varying[])
 RETURNS SETOF events_timeline_row
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
  -- Partition-column bound (t-events-timeline-bound, 2026-09-24): WITHOUT a ts_event
  -- predicate TimescaleDB cannot exclude chunks, so every call scanned + decompressed the
  -- WHOLE silver.equipment_events history (5 y after the T1 backfill) → >15 s → read-api
  -- 500 → operator HISTORIC list empty for every tenant. 7 days covers any event that
  -- ended within the last day unless it lasted >6 days; also drops never-closed junk.
  AND ee.ts_event >= now() - interval '7 days'
  AND (ee.ts_end >= now() - interval '1 days' OR ee.ts_end IS NULL)
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null or ee.cd_category is not null))
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
	AND (eels.status = 1 OR eels.status = 2)  -- was unparenthesized: status=2 rows bypassed the topic + time filters	
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
 
$function$;
