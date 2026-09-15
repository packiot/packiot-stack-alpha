-- 15_p5_drop_h_piot_originals.ROLLBACK.sql
-- Reversibility snapshot: full LIVE definitions (pg_get_functiondef, 2026-09-08) of the
-- 28 h_piot_* originals dropped by 15_p5_drop_h_piot_originals.sql. read-api now executes
-- serving.* twins for these (deployed PR #1132). KEEP set excluded: machine_speed,
-- oee_score_full_3, oee_score_with_teams, set_production_target, set_scrap_target,
-- get_downtimes_per_category_equipment_level_new_4, get_downtimes_sector_microstops.
-- To restore: psql -f this file.

CREATE OR REPLACE FUNCTION public.h_piot_downtimes_duration_by_category(idequipment integer)
 RETURNS SETOF h_downtimes_duration_by_category
 LANGUAGE sql
 STABLE
AS $function$

-- total_time is derived, not just SUM(duration): status_type=0 (line/sector)
-- events for C-PACK are mirrored OPEN (ts_end/duration NULL) and only backfilled
-- later by the mirror-worker close-sweep from prod's authoritative close. Until
-- that lands, SUM(duration) over unclosed stops → NULL → the availability-by-
-- category widget rendered empty bars. Derive each stop's duration from the next
-- state transition (lead(ts_event)) — identical semantics to the events deriver's
-- coalesce(lead(ts_event), now()) — and prefer the stored column when present so
-- already-closed rows keep their authoritative value. See the fix2-durations
-- root-cause note.
 WITH ev AS (
	SELECT
		id_equipment,
		id_enterprise,
		ts_event,
		status,
		desc_category,
		planned_downtime,
		duration,
		lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event) AS next_ts
	FROM
		equipment_events
	WHERE
		id_equipment = idEquipment
 )
 SELECT
	LOWER(desc_category) AS reason,
	SUM(COALESCE(duration, EXTRACT(EPOCH FROM (COALESCE(next_ts, now()) - ts_event))::int)) AS total_time,
	id_enterprise,
	id_equipment
FROM
	ev
WHERE
	desc_category IS NOT NULL
	AND status = 10
	AND planned_downtime = FALSE
	AND EXTRACT(YEAR FROM ts_event) = EXTRACT(YEAR FROM CURRENT_DATE)
	AND EXTRACT(MONTH FROM ts_event) = EXTRACT(MONTH FROM CURRENT_DATE)
GROUP BY
	LOWER(desc_category),
	id_enterprise,
	id_equipment
ORDER BY
	total_time DESC;

$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_events(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false)
 RETURNS SETOF h_downtimes_table_with_sector_2
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_sectors int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=2
						 and case
						 		when cardinality(in_ids_sectors::int[]) = 0 then true
						 		else id_equipment = any( in_ids_sectors::int[])
						 	 end );

begin
return query

select * from (
select
	id_equipment_event,
	(ts_event at time zone (timezone))::timestamp as ts_event,
	(ts_end at time zone (timezone))::timestamp as ts_end,
	id_equipment,
	id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(
	select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case
			when eq.tp_equipment = 2 then eq.id_equipment
			when peq.tp_equipment = 2 then peq.id_equipment
			when ppeq.tp_equipment = 2 then ppeq.id_equipment
			else null
		end as id_sector,
		coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
		case
			when eq.tp_equipment = 3 then eq.nm_equipment
			when peq.tp_equipment = 3 then peq.nm_equipment
			when ppeq.tp_equipment = 3 then ppeq.nm_equipment
			else null
		end as nm_equipment,
		case
			when eq.tp_equipment = 2 then eq.nm_equipment
			when peq.tp_equipment = 2 then peq.nm_equipment
			when ppeq.tp_equipment = 2 then ppeq.nm_equipment
			else null
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		desc_category txt_category,
		cd_subcategory,
		desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,--eduardo 2024-0715 
		--case when ers.ts_range is null then tstzrange(ts_event,coalesce(ee.ts_end,now())) else ers.ts_range end as ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then 
					(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment))
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
		),
		sh.cd_shift, --eduardo 2024-0715 para que todos eventos sejam mostrados
		ers.id_shift, --eduardo 2024-0715 para que todos eventos sejam mostrados
		--case when sh.cd_shift is null then (select cd_shift from shifts where id_enterprise=in_id_enterprise order by id_shift limit 1) else sh.cd_shift end as cd_shift,
		--case when ers.id_shift is null then (select id_shift from shifts where id_enterprise=in_id_enterprise order by id_shift limit 1) else ers.id_shift end as id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status <> 6
		and ts_event > _tsstart::timestamp - interval '1 months'
--		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and (ee.ts_end < _tsend::timestamp + interval '1 months' or ee.ts_end is null)
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view  or cd_category is not null)
--		and ((eq.tp_equipment=3 and not :sector_view) or (eq.tp_equipment=1 and :sector_view))
		and eq.event_should_be_displayed = true
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_equipment=any(ids_sectors) and :sector_view))
	-- Use the next line when using with events of equipments type = 1
	and id_line = any(ids_equips)
	and (
		(ids_sectors is null) 
		or 
		(
			id_sector = any(ids_sectors) and id_site = any(ids_sites) and id_area = any(ids_areas)
		)
		or (id_sector is null)
	)
--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_parentequipment=any(ids_sectors) and :sector_view and id_line=any(ids_equips)))
	UNION
select
	id_equipment_event, (ts_event at time zone (timezone))::timestamp as ts_event, (ts_end at time zone (timezone))::timestamp as ts_end, id_equipment, id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case
			when eq.tp_equipment = 2 then eq.id_equipment
			when peq.tp_equipment = 2 then peq.id_equipment
			when ppeq.tp_equipment = 2 then ppeq.id_equipment
			else null
		end as id_sector,
		coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
		case
			when eq.tp_equipment = 3 then eq.nm_equipment
			when peq.tp_equipment = 3 then peq.nm_equipment
			when ppeq.tp_equipment = 3 then ppeq.nm_equipment
			else null
		end as nm_equipment,
		case
			when eq.tp_equipment = 2 then eq.nm_equipment
			when peq.tp_equipment = 2 then peq.nm_equipment
			when ppeq.tp_equipment = 2 then ppeq.nm_equipment
			else null
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		desc_category txt_category,
		cd_subcategory,
		desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
				(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce(ppeq.id_equipment, peq.id_equipment, ee.id_equipment) )
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
--		status = 10
--		and 
		ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ( ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )
		and eq.event_should_be_displayed = true
--		and ((eq.tp_equipment=3 and not :sector_view) or (eq.tp_equipment=1 and :sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_equipment=any(ids_sectors) and :sector_view))
	-- Use the next line when using with events of equipments type = 1
	and id_line = any(ids_equips)
	and (
		(ids_sectors is null) 
		or 
		(
			id_sector = any(ids_sectors) and id_site = any(ids_sites) and id_area = any(ids_areas)
		)
		or 
		(
			id_sector is null
		)
	)
--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_parentequipment=any(ids_sectors) and :sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_events_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false)
 RETURNS SETOF h_downtimes_table_with_sector_3
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_sectors int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=2
						 and case
						 		when cardinality(in_ids_sectors::int[]) = 0 then true
						 		else id_equipment = any( in_ids_sectors::int[])
						 	 end );

begin
return query

select * from (
select
	id_equipment_event,
	(ts_event at time zone (timezone))::timestamp as ts_event,
	(ts_end at time zone (timezone))::timestamp as ts_end,
	id_equipment,
	id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time,
	false as manual_event
from
	(
	select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case
			when eq.tp_equipment = 2 then eq.id_equipment
			when peq.tp_equipment = 2 then peq.id_equipment
			when ppeq.tp_equipment = 2 then ppeq.id_equipment
			else null
		end as id_sector,
		coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
		case
			when eq.tp_equipment = 3 then eq.nm_equipment
			when peq.tp_equipment = 3 then peq.nm_equipment
			when ppeq.tp_equipment = 3 then ppeq.nm_equipment
			else null
		end as nm_equipment,
		case
			when eq.tp_equipment = 2 then eq.nm_equipment
			when peq.tp_equipment = 2 then peq.nm_equipment
			when ppeq.tp_equipment = 2 then ppeq.nm_equipment
			else null
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		desc_category txt_category,
		cd_subcategory,
		desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then 
					(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment))
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status <> 6
		and ts_event > _tsstart::timestamp - interval '1 months'
--		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and (ee.ts_end < _tsend::timestamp + interval '1 months' or ee.ts_end is null)
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view  or cd_category is not null)
--		and ((eq.tp_equipment=3 and not :sector_view) or (eq.tp_equipment=1 and :sector_view))
		and eq.event_should_be_displayed = true
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_equipment=any(ids_sectors) and :sector_view))
	-- Use the next line when using with events of equipments type = 1
	and id_line = any(ids_equips)
	and (
		(ids_sectors is null) 
		or 
		(
			id_sector = any(ids_sectors) and id_site = any(ids_sites) and id_area = any(ids_areas)
		)
		or (id_sector is null)
	)
--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_parentequipment=any(ids_sectors) and :sector_view and id_line=any(ids_equips)))
	UNION
select
	id_equipment_event, (ts_event at time zone (timezone))::timestamp as ts_event, (ts_end at time zone (timezone))::timestamp as ts_end, id_equipment, id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time,
	true as manual_event
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case
			when eq.tp_equipment = 2 then eq.id_equipment
			when peq.tp_equipment = 2 then peq.id_equipment
			when ppeq.tp_equipment = 2 then ppeq.id_equipment
			else null
		end as id_sector,
		coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
		case
			when eq.tp_equipment = 3 then eq.nm_equipment
			when peq.tp_equipment = 3 then peq.nm_equipment
			when ppeq.tp_equipment = 3 then ppeq.nm_equipment
			else null
		end as nm_equipment,
		case
			when eq.tp_equipment = 2 then eq.nm_equipment
			when peq.tp_equipment = 2 then peq.nm_equipment
			when ppeq.tp_equipment = 2 then ppeq.nm_equipment
			else null
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		desc_category txt_category,
		cd_subcategory,
		desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
				(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce(ppeq.id_equipment, peq.id_equipment, ee.id_equipment) )
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
--		status = 10
--		and 
		ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view  or (cd_category is not null and cd_category <> '') )
		and eq.event_should_be_displayed = true
--		and ((eq.tp_equipment=3 and not :sector_view) or (eq.tp_equipment=1 and :sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_equipment=any(ids_sectors) and :sector_view))
	-- Use the next line when using with events of equipments type = 1
	and id_line = any(ids_equips)
	and (
		(ids_sectors is null) 
		or 
		(
			id_sector = any(ids_sectors) and id_site = any(ids_sites) and id_area = any(ids_areas)
		)
		or
		(
			id_sector is null
		)
	)
--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_parentequipment=any(ids_sectors) and :sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_per_category(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
 RETURNS SETOF h_piot_get_downtimes_per_category_table
 LANGUAGE plpgsql
 STABLE
AS $function$
declare 
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_ids_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_ids_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_ids_shifts, ',')) = 0 then true
										when left(in_ids_shifts, 1) != '{' then cd_shift = any( string_to_array(in_ids_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_ids_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_ids_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
begin
return query 	
select distinct 
	ee.id_enterprise,
	array_agg(
		jsonb_build_object(
			'nm_equipment', e.nm_equipment,
			'id_equipment', ee.id_equipment,
			'cd_machine', ee.cd_machine,
			'change_over', ee.change_over,
			'num_occurence', count(*),
			'avg_time', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)))/count(*),
			'planned_downtime', ee.planned_downtime,
			'cd_category', coalesce(ee.cd_category, 'Microstops'),
			'txt_category', coalesce(ee.txt_category, ee.cd_category, 'Microstops'),
			--'duration_total', sum( extract(epoch from least(upper(ee.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ee.ts_value, ee.ts_event) ) ),
			'duration_total', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) ),
			'duration_justified', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null),
			'duration_planned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = true),
			'duration_unplanned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = false)
		)
	) over () as downtimes_per_category
from
	public.h_piot_get_downtimes_sector_microstops(in_id_enterprise,in_ids_sites,in_ids_areas,in_ids_equipments,'{}',_tsstart,_tsend,false,true) ee
	join equipments e on ee.id_equipment =e.id_equipment 
	join equipment_oee_shift ers 
		on (
			ers.id_equipment = ee.id_equipment
			and (
				--ee.ts_event::timestamptz <@ ers.ts_range
				--or
				--ee.ts_end::timestamptz <@ ers.ts_range
				--eduardo 2024-03-27 essas condicoes acima nao funcionavam para paradas longas alem da duracao de um turno
				tstzrange(ee.ts_event,ee.ts_end) && ers.ts_range
			)
--*************************************			
				and (ers.ts_range && tstzrange(_tsstart ,_tsend)) --eduardo 2024-07-13 (nao estava funcionando para paradas longas)
--*************************************
						)
	join shifts s on (s.id_shift = ers.id_shift)
	where
		ers.id_shift = any( ids_shifts )
		--Elimination on unjustified stops (but keeps downtimes)
		and (
			ee.cd_category is not null
			or
			(
				extract	(
					epoch from
						least(upper(ers.ts_range), coalesce(ee.ts_end, now()))
						-
						greatest(ers.ts_value, ee.ts_event)
				-- F3 cutover fixup M4: stop_threshold_time is NULL for ALL equipment (F1 & F3),
				-- so `< NULL` => NULL => every uncategorized stop was dropped and the function
				-- returned 0 rows for every tenant. Treat an unconfigured (NULL) threshold as
				-- "no upper bound" so uncategorized microstops are kept (consistent with sibling
				-- h_piot_get_downtimes_per_category_equipment_level_new_4, which never row-gates on it).
				) < coalesce(e.stop_threshold_time, 'infinity'::double precision)
				and cd_category is null
				--Elimina tempos negativos, provavelmente já pode remover isso
				and extract(
					epoch from
						least(upper(ers.ts_range), coalesce(ee.ts_end, now()))
						-
						greatest(ers.ts_value, ee.ts_event)
				) > 0
			)
		)
		--eduardo '2024-03-27' para não pegar paradas manuais e adicionar aos cálculos de tempos
		and ee.id_equipment_event not in (select id_equipment_event from equipment_events_man where id_enterprise=in_id_enterprise and ts_event >= _tsstart)
	group by
		ee.id_enterprise, e.nm_equipment, ee.id_equipment, ee.cd_machine, ee.change_over, ee.planned_downtime,
		ee.cd_category, ee.txt_category;
return;
end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_resumo(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
 RETURNS SETOF h_piot_get_downtimes_resumo_table
 LANGUAGE plpgsql
 STABLE
AS $function$
declare 
	ids_sites int[] := (select array_agg(id_site) 
						from sites s
						where s.id_enterprise=in_id_enterprise 
							and case
								when cardinality(in_ids_sites::int[]) = 0 then true
								else id_site = any( in_ids_sites::int[])
								end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_ids_shifts, ',')) = 0 then true
										when left(in_ids_shifts, 1) != '{' then cd_shift = any( string_to_array(in_ids_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_ids_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_ids_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
begin
return query 

		select 
		e.id_enterprise,
		null::int8 as duration_microstops,
		sum(downtime) as duration_total,
		null::int8 as duration_justified,
		sum(planned_downtime) as duration_planned,
		sum(downtime)-sum(planned_downtime) as duration_unplanned,
		sum(
			case when now() <@ ers.ts_range
				then extract ('epoch' from now() - ers.ts_value)
				else duration 
			end
		)::int8 as available_time
		from equipment_oee_shift ers 
		join equipments e on ers.id_equipment = e.id_equipment 
		where 
			ers.ts_value_production >= min_ts_prod and ers.ts_value_production <= max_ts_prod 
			-- excluding futures shifts
			and ers.ts_value <= now()
			and e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ers.id_equipment = any( ids_equips )
			and ers.id_shift = any( ids_shifts )
		group by id_enterprise;
return;
end
$function$
;

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
        AND (ee.duration >= COALESCE(e.stop_threshold_time, 0) or ee.duration is null)
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

CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline_from_po(_id_production_order integer)
 RETURNS SETOF h_events_equipment_timeline_2
 LANGUAGE sql
 STABLE
AS $function$ 
select
    ts_event,
    ts_end,
    duration,
    e.id_equipment,
    e.id_enterprise,
    txt_downtime_notes,
    cd_machine,
    cd_category,
    cd_subcategory,
    change_over,
    status
from equipment_events ee
join equipments e on ee.id_equipment = e.id_equipment
--cross join ranges
where   
--	ee.id_equipment = _id_equipment
  ee.id_equipment = (select id_equipment from production_orders where id_production_order = _id_production_order) 
    and ee.ts_event::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_production_order ) )
    and (
            (ee.duration >= COALESCE(e.stop_threshold_time, 0))
            or (ee.ts_end is null)
        )
    and ee.status != 6
--    and ee.cd_category is not null
UNION
SELECT
  eem.ts_event,
  eem.ts_end,
  extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer as duration,
  e.id_equipment,
  e.id_enterprise,
  eem.txt_downtime_notes,
  null as cd_machine,
  null as cd_category,
  null as cd_subcategory,
  null as changeover,
  null as status
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment_event = e.id_equipment
  where
--  id_equipment = _id_equipment
  e.id_equipment = (select id_equipment from production_orders where id_production_order = _id_production_order) 
  AND 
--  eem.ts_event_start >= now() - interval '24 hour'
--  (select runtime_timerange from production_orders_runtime por where id_production_order=_id_production_order) @> eem.ts_event_start
  eem.ts_event::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_production_order ) )
  AND extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer >= COALESCE(e.stop_threshold_time, 0) -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline_full_with_filter_3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_event_types text, _id_production_order integer DEFAULT NULL::integer, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now())
 RETURNS SETOF h_events_timeline_full2
 LANGUAGE plpgsql
 STABLE
AS $function$ 
declare
    ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	min_ts_prod timestamptz := (select min(ts_value) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_end) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	id_event_types int[] := in_event_types::int[];
	_id_prod_order int := (_id_production_order);
begin
	return query	
--	create table h_events_timeline_full as 
	select
		ev.*
	from
		v_events_2 ev
		join equipments using (id_equipment)
	where
		id_equipment = any(ids_equips)
    	and id_area= any(ids_areas)
    	and id_site = any(ids_sites)
    	and (_id_prod_order is null or 
    		id_equipment = (select id_equipment from production_orders where id_production_order = _id_prod_order)
    	)
		and (
			_id_prod_order is null
				or 
	    	ts_timeline::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_prod_order ) )
	    		or 
	    	tstzrange(ts_event::timestamptz, ts_end::timestamptz, '[)') <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_prod_order ) )
	    )
	    and (
	    	(
		    	event_type not in (4, 5, 6) and 
		    	(
		    		(tstzrange(ts_event::timestamptz, ts_end::timestamptz, '[)') @> min_ts_prod::timestamptz or tstzrange(ts_event::timestamptz, ts_end::timestamptz, '[)') @> max_ts_prod::timestamptz)
		    		or (ts_event >= min_ts_prod and ts_event <= max_ts_prod)
		    	)
		    	or 
		    	event_type in (4, 5, 6) and 
		    	(
		    		(ts_timeline >= min_ts_prod and ts_timeline <= max_ts_prod)
		    	)
		    )
	    )
	    and event_type = any(id_event_types)
	ORDER by ts_timeline DESC;
end $function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_mission_control_area_uns_2(in_id_enterprise integer, in_id_areas text, in_id_sites text)
 RETURNS SETOF h_piot_mission_control_area_uns_2
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
begin
	return query
	-- F3 cutover fixup M4: area_live_shift is a fact snapshot whose denormalized
	-- id_enterprise / id_site / nm_area columns are left NULL by the worker. The old body
	-- filtered on the snapshot's NULL id_site (NULL = any(...) => NULL => 0 rows) and returned
	-- NULL enterprise/nm_area. Join the canonical `areas` dimension by id_area for those
	-- attributes and for tenant scoping; keep metrics from the snapshot.
select
	a.id_enterprise,
	uacs.id_area,
	a.nm_area,
	uacs.gross_production,
	uacs.net_production,
	uacs.scrap,
	uacs.oee,
	uacs.target,
	uacs.net_production + ((uacs.net_production/nullif(uacs.running_time , 0)) * (uacs.duration - uacs.elapsed_time)) as projected_production,
	oeet.vl_shift
from
	area_live_shift uacs
	join areas a on (a.id_area = uacs.id_area)
	left join oee_targets oeet on (uacs.id_area = oeet.id_area and oeet.id_equipment is null)
where
    a.id_enterprise = in_id_enterprise
    and a.id_site = any (ids_sites)
    and uacs.id_area = any (ids_areas);
end $function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_mission_control_timeline(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text)
 RETURNS SETOF h_piot_mission_control_timeline
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
begin
return query

		select
				dt.id_equipment,
            	array_agg(dt.situation ORDER BY dt.ts_value) AS timelinestatus
           FROM (
           		SELECT
           			aaa.ts_value,
                    aaa.id_equipment,
                        CASE
                            WHEN COALESCE(aaa.speed, 0.0::double precision) >= (e.minimum_ideal_performance_threshold * e.production_speed::double precision) THEN 'running'::text
                            WHEN COALESCE(aaa.speed, 0.0::double precision) < (e.minimum_ideal_performance_threshold * e.production_speed::double precision) AND COALESCE(aaa.speed, 0.0::double precision) >= (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'lowSpeed'::text
                            WHEN COALESCE(aaa.speed, 0::double precision) < (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'stopped'::text
                            ELSE NULL::text
                        END AS situation
                   FROM (select * from agg_equipment_values_1min aaa
                   where
                   			id_enterprise = in_id_enterprise
                   		and id_site = any (ids_sites)
                   		and id_area = any (ids_areas)
                   		and id_equipment = any (ids_equips)
                   		) aaa
                     LEFT JOIN equipments e USING (id_equipment)
                  WHERE aaa.ts_value >= (now() - '24:01:00'::interval) AND aaa.ts_value < (now() - '00:01:00'::interval) AND aaa.tp_equipment = 3
           ) dt
           GROUP BY dt.id_equipment;


end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_mission_control_uns_3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text)
 RETURNS SETOF h_piot_mission_control_uns_3
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site)
						from sites s
						where s.id_enterprise=in_id_enterprise
						and case
							when cardinality(in_ids_sites::int[]) = 0 then true
							else id_site = any( in_ids_sites::int[])
						end);
	ids_areas int[] := (select array_agg(id_area)
						from areas s
						where s.id_enterprise=in_id_enterprise
						and case
							when cardinality(in_ids_areas::int[]) = 0 then true
							else id_area = any( in_ids_areas::int[])
						end);
	ids_equips int[] := (select array_agg(id_equipment)
						from equipments s
						where s.id_enterprise=in_id_enterprise
						and s.tp_equipment=3
						and case
							when cardinality(in_ids_equipments::int[]) = 0 then true
							else id_equipment = any( in_ids_equipments::int[])
						end);
begin
return query


   select
	uecm.id_site,
		uecm.id_area,
		uecm.nm_area,
		uecm.id_equipment AS id_line,
		uecm.nm_equipment AS nm_line,
		uecm.id_enterprise,
		uecs.oee AS currshift_oee,
		uecs.shift_name AS curr_shift_name,
		uecs.prev1_shift_name,
		uecs.prev2_shift_name,
		uecj.id_order,
		uecj.target AS production_programmed,
		uecj.net_production AS po_net_production,
		uecj.nm_client,
		uecj.elapsed_time AS duration,
		uecj.current_expected_time AS expected_time,
		uecm.speed::real,
		uecs.gross_production AS curshift_grosprod,
		uecs.net_production AS curshift_netprod,
		uecs.prev1_net_production AS prev1shift_netprod,
		uecs.prev2_net_production AS prev2shift_netprod,
		uecs.scrap AS curshift_scrap,
		uecs.planned_downtime,
		uecm.planned_perc_stops_24h as planned_duration_percent,
		uecs.change_over_duration,
		uecm.change_over_perc_stops_24h as change_over_duration_percent,
		uecs.unplanned_downtime as unplanned_duration,
		uecm.unplanned_perc_stops_24h as unplanned_duration_percent,
		uecs.stopped_time,
		uecm.status_24h,
		uecm.status,
		uecm.status_time,
		uecs.proportional_target,
		uecs.prev1_target,
		uecs.prev2_target,
		uecj.current_expected_time::float8 as job_remaining_time
	from equipment_live_job uecj
	join equipment_live_shift uecs on (uecs.id_equipment=uecj.id_equipment)
	join equipment_live_metrics uecm on (uecm.id_equipment=uecj.id_equipment)
	where
		uecm.id_site = any (ids_sites)
		and uecm.id_area = any (ids_areas)
		and uecm.id_equipment = any (ids_equips);

	end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_production_health(idequipment integer)
 RETURNS SETOF h_production_health
 LANGUAGE sql
 STABLE
AS $function$
		WITH this_week AS (
SELECT
	(date_trunc('week',
	now() AT TIME ZONE s.timezone) + s.week_begin * INTERVAL '1 second') AT time ZONE 'UTC' AS week_start
FROM
	equipments eq
LEFT JOIN sites s 
        ON
	eq.id_site = s.id_site
WHERE
	id_equipment = idEquipment
        )
        SELECT
	id_equipment,
	sum(net) AS net,
	sum(target) AS target,
	(sum(net)/(sum(target)+ 1))::NUMERIC(5,
	1) AS status_overview
FROM
	equipment_oee_shift ers
WHERE
	ers.id_equipment = idEquipment
	AND ts_value >= (
	SELECT
		week_start
	FROM
		this_week)
	AND ts_value < now()
GROUP BY
	1
ORDER BY
	1;

$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_get_targets(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, group_by_element text DEFAULT 'DAY'::text)
 RETURNS SETOF h_piot_production_targets
 LANGUAGE plpgsql
 STABLE
AS $function$
declare 
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case UPPER(time_grain)
									when 'HOUR' then
										(select min(ts_value) from ca_agg_equipment_values_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value) from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
			--								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			--								and ev.id_enterprise = in_id_enterprise
			--								and ev.id_area = any( ids_areas)
			--								and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) )
								end
							);
	max_ts_prod timestamptz := (
						select case UPPER(time_grain)
									when 'HOUR' then
										(
										select max(ts_value) 
--										from ca_agg_equipment_values_1hour ev
										from equipment_oee_hourly ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
--										and ev.id_enterprise = in_id_enterprise
--										and ev.id_area = any( ids_areas)
--										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
--										and ev.id_shift = any( ids_shifts )
										)
								else (
									select 
										max(ts_value)
									from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
		--								and ev.id_enterprise = in_id_enterprise
		--								and ev.id_area = any( ids_areas)
		--								and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts )
								)
							end
							);
begin
	if true THEN --nav_level = EQUIPMENT
		if upper(time_grain) = 'DAY' then
		-- Targets in equipment level and by day	
		return query
				select distinct
					id_enterprise,
					ts_value_production::timestamp(0) with time zone,
					sum(target) target,
					array_agg(obj order by coalesce(shift_position, team_position))
				from(
					select 
						e.id_enterprise,
						ts_value_production,
						sum(target) as target,
						case group_by_element when 'SHIFTS' then s.sequence_position else null end shift_position,
						case group_by_element when 'TEAMS' then t.sequence_position else null end team_position,
						--array_agg( 
							jsonb_build_object(
								'id_shift', case group_by_element when 'SHIFTS' then s.id_shift END,
								'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
								'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
								'id_team', case group_by_element when 'TEAMS' then t.id_team END,
								'target', SUM(target)
							) as obj
					from 
						equipment_oee_shift ers
						join equipments e using (id_equipment)
						left join shifts s using (id_shift)
						left join teams t using (id_team)
					where
						ts_value >= min_ts_prod
						and ts_value <= max_ts_prod
						and e.id_enterprise = in_id_enterprise
						and e.id_area = any( ids_areas)
						and e.id_site = any( ids_sites )
						and e.id_equipment =  any( ids_equips )
						and ers.id_shift = any( ids_shifts )
					group by 
						e.id_enterprise, ts_value_production,
						case group_by_element when 'SHIFTS' then s.id_shift else null END,
						case group_by_element when 'SHIFTS' then s.cd_shift else null END,
						case group_by_element when 'SHIFTS' then s.sequence_position else null END,
						case group_by_element when 'TEAMS' then t.sequence_position else null end,
						case group_by_element when 'TEAMS' then t.cd_team else null end,
						case group_by_element when 'TEAMS' then t.id_team else null end
						) s0
				group by id_enterprise , ts_value_production;
			
			
			elsif  upper(time_grain) = 'WEEK' then
				-- Targets in equipment level and by WEEK	
				return query
						select  distinct
							id_enterprise,
							ts_value_production::timestamp(0) with time zone,
							sum(target) target,
							array_agg(obj order by coalesce(shift_position, team_position))
						from(
							select 
								e.id_enterprise,
								ts_value as ts_value_production,
								sum(target) as target,
								case group_by_element when 'SHIFTS' then s.sequence_position else null end shift_position,
								case group_by_element when 'TEAMS' then t.sequence_position else null end team_position,
								--array_agg( 
									jsonb_build_object(
										'id_shift', case group_by_element when 'SHIFTS' then s.id_shift END,
										'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
										'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
										'id_team', case group_by_element when 'TEAMS' then t.id_team END,
										'target', SUM(target)
									) as obj
							from 
								equipment_oee_shift_weekly ers
								join equipments e using (id_equipment)
								left join shifts s using (id_shift)
								left join teams t using (id_team)
							where
								ts_value >= min_ts_prod
								and ts_value <= max_ts_prod
								and e.id_enterprise = in_id_enterprise
								and e.id_area = any( ids_areas)
								and e.id_site = any( ids_sites )
								and e.id_equipment =  any( ids_equips )
								and ers.id_shift = any( ids_shifts )
							group by 
								e.id_enterprise, ts_value_production,
								case group_by_element when 'SHIFTS' then s.id_shift else null END,
								case group_by_element when 'SHIFTS' then s.cd_shift else null END,
								case group_by_element when 'SHIFTS' then s.sequence_position else null END,
								case group_by_element when 'TEAMS' then t.sequence_position else null end,
								case group_by_element when 'TEAMS' then t.cd_team else null end,
								case group_by_element when 'TEAMS' then t.id_team else null end
								) s0
						group by id_enterprise , ts_value_production;
					
			elsif  upper(time_grain) = 'MONTH' then
				-- Targets in equipment level and by MONTH	
				return query
				
						select  distinct
							id_enterprise,
							ts_value_production::timestamp(0) with time zone,
							sum(target) target,
							array_agg(obj order by coalesce(shift_position, team_position))
						from(
							select 
								e.id_enterprise,
								ts_value as ts_value_production,
								sum(target) as target,
								case group_by_element when 'SHIFTS' then s.sequence_position else null end shift_position,
								case group_by_element when 'TEAMS' then t.sequence_position else null end team_position,
								--array_agg( 
									jsonb_build_object(
										'id_shift', case group_by_element when 'SHIFTS' then s.id_shift END,
										'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
										'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
										'id_team', case group_by_element when 'TEAMS' then t.id_team END,
										'target', SUM(target)
									) as obj
							from 
								equipment_oee_shift_monthly ers
								join equipments e using (id_equipment)
								left join shifts s using (id_shift)
								left join teams t using (id_team)
							where
								ts_value >= min_ts_prod
								and ts_value <= max_ts_prod
								and e.id_enterprise = in_id_enterprise
								and e.id_area = any( ids_areas)
								and e.id_site = any( ids_sites )
								and e.id_equipment =  any( ids_equips )
								and ers.id_shift = any( ids_shifts )
							group by 
								e.id_enterprise, ts_value_production,
								case group_by_element when 'SHIFTS' then s.id_shift else null END,
								case group_by_element when 'SHIFTS' then s.cd_shift else null END,
								case group_by_element when 'SHIFTS' then s.sequence_position else null END,
								case group_by_element when 'TEAMS' then t.sequence_position else null end,
								case group_by_element when 'TEAMS' then t.cd_team else null end,
								case group_by_element when 'TEAMS' then t.id_team else null end
								) s0
						group by id_enterprise , ts_value_production;
			elsif  upper(time_grain) = 'HOUR' then
				-- Targets in equipment level and by HOUR	
				return query
				select  distinct
							id_enterprise,
							ts_value_production::timestamp(0) with time zone,
							sum(target) target,
							array_agg(obj order by coalesce(shift_position, team_position))
						from(
							select 
								e.id_enterprise,
								erh.ts_value::timestamptz as ts_value_production,
								sum(target) as target,
								case group_by_element when 'SHIFTS' then s.sequence_position else null end shift_position,
								case group_by_element when 'TEAMS' then t.sequence_position else null end team_position,
								--array_agg( 
									jsonb_build_object(
										'id_shift', case group_by_element when 'SHIFTS' then s.id_shift END,
										'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
										'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
										'id_team', case group_by_element when 'TEAMS' then t.id_team END,
										'target', SUM(target)
									) as obj
							from 
								equipment_oee_hourly erh 
								left join ca_agg_equipment_values_1hour ers using (id_equipment, ts_value)
								join equipments e using (id_equipment)
								left join shifts s on  (e.id_enterprise = ers.id_enterprise and ers.id_shift = s.id_shift)
								left join teams t on e.id_enterprise = t.id_enterprise and t.id_team = erh.id_team
							where
								erh.ts_value >= min_ts_prod
								and erh.ts_value <= max_ts_prod
								and e.id_enterprise = in_id_enterprise
								and e.id_area = any( ids_areas)
								and e.id_site = any( ids_sites )
								and e.id_equipment =  any( ids_equips )
								and (
									ers.id_shift = any( ids_shifts )
									or
									ers.id_shift is null
									)
							group by 
								e.id_enterprise, erh.ts_value,
								case group_by_element when 'SHIFTS' then s.id_shift else null END,
								case group_by_element when 'SHIFTS' then s.cd_shift else null END,
								case group_by_element when 'SHIFTS' then s.sequence_position else null END,
								case group_by_element when 'TEAMS' then t.sequence_position else null end,
								case group_by_element when 'TEAMS' then t.cd_team else null end,
								case group_by_element when 'TEAMS' then t.id_team else null end
								) s0
						group by id_enterprise , ts_value_production;
		end if;
	end if;
end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_home_uns(in_id_enterprise integer)
 RETURNS SETOF h_piot_home_table
 LANGUAGE plpgsql
 STABLE
AS $function$
begin
	return query 
	


select
	id_enterprise,
	jsonb_agg(sites order by nm_site) as sites
from 
	(
	select
		id_enterprise,
		id_site,
		nm_site,
		jsonb_build_object(
	   		'areas', jsonb_agg(areas order by nm_area),
			'id_site', id_site,
			'nm_site', nm_site
			) as sites
	from
		sites 
		join
			(
				select
					id_enterprise,
					id_site,
					nm_area,
					jsonb_build_object(
				   		'id_area', id_area,
						'nm_area', nm_area,
						'gross', uacd.gross_production,
						'net', uacd.net_production,
						'scrap',  uacd.scrap,
						'oee', uacd.oee,
						'lines', lines_data.lines
						) as areas	
				from
					areas 
					left join area_live_day uacd using (id_area)
					join 
						(
							select 
								id_area,
								jsonb_agg(jsonb_build_object(
												 		'id_equipment', id_equipment,
											            'nm_equipment', nm_equipment,
											            'status', coalesce(status, 'unknown')
										) order by nm_equipment) as lines
							from
								equipments
								left join equipment_live_metrics uecm using (id_equipment, id_enterprise, nm_equipment, id_area)
							where 
								id_enterprise = in_id_enterprise 
								and tp_equipment = 3
							group by id_area
						) lines_data using (id_area)
				where 
					id_enterprise = in_id_enterprise 
			) area_data using (id_enterprise, id_site)
		group by id_enterprise, id_site
	) site_data
group by id_enterprise;

return;
end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_oee_progress_new2(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false, is_team_filtered boolean DEFAULT false)
 RETURNS SETOF h_piot_oee_progress_with_teams
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
begin  		
	if nav_level = 'SITE' then
	
		return query
		
		with basic_data as (
			select
				ts_value_production, ent.id_enterprise, s.id_site as id_entity, ent.nm_site as nm_entity, oee, oee_p, oee_a, oee_q,
				case
					when is_shift_filtered then cd_shift
					else null::varchar
				end cd_shift,
				case
					when is_shift_filtered then sft.sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then tms.cd_team--null::varchar --cd_team
					else null::varchar
				end cd_team,
				case
					when is_team_filtered then tms.sequence_position --null::int4 --team_sequence_position
					else null::int4
				end team_sequence_position
		    from site_oee_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join sites ent on (ent.id_site = s.id_site)
		    where
		    	ent.id_site = any(ids_sites::int[])
		        and s.ts_value_production >= date_trunc('day', in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day', in_end_time::timestamp+ interval '1 day')::date
		        and s.ts_value_production < now()
		    group by ts_value, ent.id_enterprise, ent.nm_site, ent.id_site, s.id_site,
			    case when is_shift_filtered then sft.sequence_position end,
			    case when is_team_filtered then tms.sequence_position end,
			    case when is_shift_filtered then sft.cd_shift end,
			    case when is_team_filtered then tms.cd_team end
		)
	select
			id_enterprise, nm_entity, array_agg(oee_data order by ts_value_production, sequence_position, team_sequence_position) oee_progress
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production, sequence_position, team_sequence_position,
				jsonb_build_object(
						'ts_value_production', ts_value_production,
						'cd_shift', cd_shift,
						'cd_team', cd_team,
						'oee', avg(oee),
						'oee_p', avg(oee_p),
						'oee_a', avg(oee_a),
						'oee_q', avg(oee_q)
				) oee_data
			from (
					select
						ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position,
						avg(oee) oee, avg(oee_p) oee_p, avg(oee_a) oee_a, avg(oee_q) oee_q
					from basic_data
					group by ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position
				)s0
			group by id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position, ts_value_production
		)s1
		group by id_enterprise, nm_entity;
	
	    
	elseif nav_level = 'AREA' then
	
		return query
		with basic_data as (
			select
				ts_value_production, ent.id_enterprise, s.id_area as id_entity, ent.nm_area as nm_entity, oee, oee_p, oee_a, oee_q,
				case
					when is_shift_filtered then cd_shift
					else null::varchar
				end cd_shift,
				case
					when is_shift_filtered then sft.sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then tms.cd_team--null::varchar --cd_team
					else null::varchar
				end cd_team,
				case
					when is_team_filtered then tms.sequence_position --null::int4 --team_sequence_position
					else null::int4
				end team_sequence_position
		    from area_oee_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join areas ent on (ent.id_area = s.id_area)
		    where
		    	ent.id_site = any(ids_sites::int[])
		    	and ent.id_area = any(ids_areas::int[])
		        and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date 
		        and s.ts_value_production < now()
		    group by ts_value, ent.id_enterprise, ent.nm_area, ent.id_site, s.id_area,
		    case when is_shift_filtered then sft.sequence_position end,
		    case when is_team_filtered then tms.sequence_position end,
		    case when is_shift_filtered then sft.cd_shift end,
		    case when is_team_filtered then tms.cd_team end
		)
--		select
--		id_enterprise, nm_entity,
--			array_agg(jsonb_build_object(
--				'ts_value_production', ts_value_production, 
--				'oee_data', oee_data
--			) order by ts_value_production) oee_progress
--	from (
		select
			id_enterprise, nm_entity, array_agg(oee_data order by ts_value_production, sequence_position, team_sequence_position) oee_progress
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production,sequence_position, team_sequence_position,
				jsonb_build_object(
						'ts_value_production', ts_value_production,
						'cd_shift', cd_shift,
						'cd_team', cd_team,
						'oee', avg(oee),
						'oee_p', avg(oee_p),
						'oee_a', avg(oee_a),
						'oee_q', avg(oee_q)
				) oee_data
			from (
					select
						ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position,
						avg(oee) oee, avg(oee_p) oee_p, avg(oee_a) oee_a, avg(oee_q) oee_q
					from basic_data
					group by ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position
				)s0
			group by id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position, ts_value_production
		)s1
		group by id_enterprise, nm_entity;


	else 
	
		return query
		with basic_data as (
			select
				ts_value_production, ent.id_enterprise, s.id_equipment as id_entity, ent.nm_equipment as nm_entity, oee, oee_p, oee_a, oee_q,
				case
					when is_shift_filtered then sft.cd_shift
					else null::varchar
				end cd_shift,
				case
					when is_shift_filtered then sft.sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then tms.cd_team
					else null::varchar
				end cd_team,
				case
					when is_team_filtered then tms.sequence_position --null::int4
					else null::int4
				end team_sequence_position
		    from equipment_oee_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join equipments ent on (ent.id_equipment = s.id_equipment and ent.tp_equipment=3)
		    where
		    	ent.id_site = any(ids_sites::int[])
		    	and ent.id_area = any(ids_areas::int[])
		    	and ent.id_equipment = any(ids_equips::int[])
		        and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
		        and s.ts_value_production < now()
		    group by ts_value, ent.id_enterprise, ent.nm_equipment, ent.id_site, s.id_equipment,
		    case when is_shift_filtered then sft.sequence_position end,
		    case when is_team_filtered then tms.sequence_position end,
		    case when is_shift_filtered then sft.cd_shift end,
		    case when is_team_filtered then tms.cd_team end
		)
		select
			id_enterprise, nm_entity, array_agg(oee_data order by ts_value_production, sequence_position, team_sequence_position) oee_progress
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production, sequence_position, team_sequence_position,
				jsonb_build_object(
						'ts_value_production', ts_value_production,
						'cd_shift', cd_shift,
						'cd_team', cd_team,
						'oee', avg(oee),
						'oee_p', avg(oee_p),
						'oee_a', avg(oee_a),
						'oee_q', avg(oee_q)
				) oee_data
			from (
					select
						ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position,
						avg(oee) oee, avg(oee_p) oee_p, avg(oee_a) oee_a, avg(oee_q) oee_q
					from basic_data
					group by ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position
				)s0
			group by id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position, ts_value_production
		)s1
		group by id_enterprise, nm_entity;
	
	end if;
        
end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_overview_i_get_events(idequipment integer)
 RETURNS SETOF h_overview_i_events
 LANGUAGE sql
 STABLE
AS $function$


select id_enterprise,"start","end",duration,reason,sub_category,machine,notes,colorcolumn from (
select 
        ee.id_enterprise, 
        ts_event,
        to_char(timezone(st.timezone, ts_event), 'DD/MM HH24:MI' ) as "start",
        coalesce(to_char(timezone(st.timezone, ts_end), 'DD/MM HH24:MI'), '-') as "end",
        coalesce((interval '1sec'*ee.duration)::varchar, ' ') as "duration", 
        coalesce(ee.cd_category, ' ')  "reason",
        coalesce(ee.cd_subcategory, ' ')  "sub_category", 
        coalesce(ee.cd_machine, ' ') "machine",
        coalesce(ee.txt_downtime_notes, ' ') "notes" ,
        case 
            when ts_end is null then 'runningStop'
            when ts_end is not null and ee.cd_category is null then 'notJustified' 
            else 'justified'
        end as colorcolumn
from equipment_events ee 
inner join equipments e using (id_equipment)
left join sites st using (id_site)
where 
status != 6
--eduardo adicionou a linha abaixo para delimitar eventos as ultimas 2 semanas
and ee.ts_event >= now() - interval '14 day'
and coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time 
and 
	case (select overview_events_type from equipments e where id_equipment = idEquipment)
		when 1 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
												join equipments e4 on (e3.id_parentequipment= e4.id_equipment)
											where e2.tp_equipment = 1 and e4.id_equipment = idEquipment
											)
		else e.id_equipment = idEquipment
	end
and 
	case 
		when (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) is not null
		then (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) = ee.idle 
		else true
	end
UNION
	select 
        ee.id_enterprise, 
        ts_event,
        to_char(timezone(st.timezone, ts_event), 'DD/MM HH24:MI' ) as "start",
        coalesce(to_char(timezone(st.timezone, ts_end), 'DD/MM HH24:MI'), '-') as "end",
        coalesce((interval '1sec'*ee.duration)::varchar, ' ') as "duration", 
        coalesce(ee.cd_category, ' ')  "reason",
        coalesce(ee.cd_subcategory, ' ')  "sub_category", 
        coalesce(ee.cd_machine, ' ') "machine",
        coalesce(ee.txt_downtime_notes, ' ') "notes" ,
        case 
            when ts_end is null then 'runningStop'
            when ts_end is not null and ee.cd_category is null then 'notJustified' 
            else 'justified'
        end as colorcolumn
from equipment_events_man ee 
inner join equipments e using (id_equipment)
left join sites st using (id_site)
where 
--status != 6
--and 
coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time 
and 
	case (select overview_events_type from equipments e where id_equipment = idEquipment)
		when 1 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
												join equipments e4 on (e3.id_parentequipment= e4.id_equipment)
											where e2.tp_equipment = 1 and e4.id_equipment = idEquipment
											)
		else e.id_equipment = idEquipment
	end
and 
	case 
		when (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) is not null
		then (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) = ee.idle 
		else true
	end
	) DAT	
order by ts_event desc 
limit 5;

$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_overview_i_get_events_3(idequipment integer)
 RETURNS SETOF h_overview_i_events_3
 LANGUAGE sql
 STABLE
AS $function$


select id_enterprise,"start","end",duration,reason,sub_category,cd_sector,machine,notes,colorcolumn from (
select 
	ee.id_enterprise,
	case
		when e.tp_equipment = 2 then e.nm_equipment
		when pe.tp_equipment = 2 then pe.nm_equipment
		else null::varchar
	end cd_sector,
	ts_event,
	timezone(st.timezone, ts_event) as "start",
	timezone(st.timezone, ts_end) as "end",
	--coalesce((interval '1sec'*ee.duration)::varchar, ' ') as "duration", 
	--novo Eduardo 2024-09-25 to show the duration of a stop in progress
	coalesce((interval '1sec'*ee.duration)::varchar, ((interval '1sec')*extract(epoch from now()- (ts_event))::int)::varchar) as "duration", 
	coalesce(ee.cd_category, ' ')  "reason",
	coalesce(ee.cd_subcategory, ' ')  "sub_category", 
	coalesce(ee.cd_machine, ' ') "machine",
	coalesce(ee.txt_downtime_notes, ' ') "notes" ,
	case 
		when ts_end is null then 'runningStop'
		when ts_end is not null and ee.cd_category is null then 'notJustified' 
		else 'justified'
	end as colorcolumn
from equipment_events ee 
inner join equipments e using (id_equipment)
left join sites st using (id_site)
left join equipments pe on (e.id_parentequipment=pe.id_equipment)
where 
status != 6
--eduardo adicionou a linha abaixo para delimitar eventos as ultimas 2 semanas
and ee.ts_event >= now() - interval '14 day'
and coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time 
and 
	case (select overview_events_type from equipments e where id_equipment = idEquipment)
		when 1 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
												join equipments e4 on (e3.id_parentequipment= e4.id_equipment)
											where e2.tp_equipment = 1 and e4.id_equipment = idEquipment
											)
		when 2 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
											where e2.tp_equipment = 2 and e3.id_equipment = idEquipment
											)
		else e.id_equipment = idEquipment
	end
and 
	case 
		when (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) is not null
		then (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) = ee.idle 
		else true
	end
	
	
union

	select 
		ee.id_enterprise, 
		case
			when e.tp_equipment = 2 then e.nm_equipment
			when pe.tp_equipment = 2 then pe.nm_equipment
			else null::varchar
		end cd_sector,
		ts_event,
		timezone(st.timezone, ts_event) as "start",
		timezone(st.timezone, ts_end) as "end",
		--coalesce((interval '1sec'*ee.duration)::varchar, ' ') as "duration", 
		--novo Eduardo 2024-09-25 to show the duration of a stop in progress
		--coalesce((interval '1sec'*ee.duration)::varchar, ((interval '1sec')*extract(epoch from now()- (ts_event))::int)::varchar) as "duration", 
		case when idequipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3)
		then null else coalesce((interval '1sec'*ee.duration)::varchar, ((interval '1sec')*extract(epoch from now()- (ts_event))::int)::varchar) end as "duration",
		coalesce(ee.cd_category, ' ')  "reason",
		coalesce(ee.cd_subcategory, ' ')  "sub_category", 
		coalesce(ee.cd_machine, ' ') "machine",
		--coalesce(ee.txt_downtime_notes, ' ') "notes" , ABAIXO UMA CUSTOMIZACAO PARA NEOPAC-CH
		case when idequipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3) 
		then concat('(Manual Stop)_',coalesce(ee.txt_downtime_notes, ' ')) else coalesce(ee.txt_downtime_notes, ' ') end as "notes",
		case 
			when ts_end is null then 'runningStop'
			when ts_end is not null and ee.cd_category is null then 'notJustified' 
			else 'justified'
		end as colorcolumn
from equipment_events_man ee 
inner join equipments e using (id_equipment)
left join sites st using (id_site)
left join equipments pe on (e.id_parentequipment=pe.id_equipment)
where 
--status != 6
--and 
--coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time
case when idequipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3)
then true else coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time end

and 
	case (select overview_events_type from equipments e where id_equipment = idEquipment)
		when 1 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
												join equipments e4 on (e3.id_parentequipment= e4.id_equipment)
											where e2.tp_equipment = 1 and e4.id_equipment = idEquipment
											)
		when 2 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
											where e2.tp_equipment = 2 and e3.id_equipment = idEquipment
											)
		else e.id_equipment = idEquipment
	end
and 
	case 
		when (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) is not null
		then (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) = ee.idle 
		else true
	end
	
	) DAT	
order by ts_event desc 
limit 5;

$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_overview_i_get_job_info(idequipment integer)
 RETURNS SETOF h_overview_i_job_info
 LANGUAGE sql
 STABLE
AS $function$
select 
	id_enterprise::int4, 
	idequipment::int4 as id_equipment,
	(select cd_equipment from equipments where id_equipment = idequipment)::varchar as cd_equipment,
	(select nm_client from clients where id_client =(select id_client from production_orders where id_equipment = idequipment and status = 2))::varchar as nm_client,
	id_order::varchar,
	(select speed from production_orders_runtime where id_production_order in (select id_production_order from production_orders where id_equipment = idequipment and status = 2) order by runtime_timerange desc limit 1)::float8  as average_speed,
	production_ordered::int8 as order_size,
	net_production::float8 as collected_prod,
	(net_production/nullif(production_ordered,0))::float8 as job_production_percentage,
	(production_ordered - net_production)::float8 as production_remaining,
	to_char((((production_ordered - net_production)/nullif((select speed from production_orders_runtime where id_production_order in (select id_production_order from production_orders where id_equipment = idequipment and status = 2)order by runtime_timerange desc limit 1),0))*60)::int * interval '1 second', 'HH24:MI:SS')::varchar as remaining_time
from production_orders 
where id_equipment = idequipment
and status = 2
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_overview_i_production_chart(idequipment integer)
 RETURNS SETOF h_overview_i_production_chart
 LANGUAGE sql
 STABLE
AS $function$
select 
        vaevh.id_enterprise,
        id_equipment,
        to_char(ts_value at time zone s.timezone, 'HH24 h') as "time",
        ts_value at time zone s.timezone as times,
        row_number() over (order by ts_value desc) as rn,
        e.cd_equipment,
        sum(coalesce(net_production_incr, 0)) as "production",
        (case when sum(coalesce(scrap_incr, 0))>0 then sum(coalesce(scrap_incr, 0)) else 0 end) as "scrap" 
from ca_agg_equipment_values_1hour vaevh
left join equipments e using (id_equipment, id_site)
left join sites s using (id_site)
where ts_value >= now() - '12h'::interval
and vaevh.tp_equipment = 3
and id_equipment = idEquipment
group by vaevh.id_enterprise , id_equipment, vaevh.ts_value, e.cd_equipment, s.timezone 
order by id_equipment , ts_value desc;
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_overview_production_chart(idequipment integer)
 RETURNS SETOF h_overview_i_production_chart
 LANGUAGE sql
 STABLE
AS $function$


select 
        e.id_enterprise,
        id_equipment,
        to_char(ts_value at time zone s.timezone, 'HH24 h') as "time",
        ts_value at time zone s.timezone as times,
        row_number() over (order by ts_value desc) as rn,
        e.cd_equipment,
        sum(coalesce(net, 0))::float8 as "production",
        (case when sum(coalesce(scrap, 0))>0 then sum(coalesce(scrap, 0)) else 0 end)::float8 as "scrap" 
from equipment_oee_hourly vaevh
left join equipments e using (id_equipment)
left join sites s using (id_site)
where ts_value >= now() - '12h'::interval and ts_value < now()
and e.tp_equipment = 3
and id_equipment = idequipment
group by e.id_enterprise , id_equipment, vaevh.ts_value, e.cd_equipment, s.timezone 
order by id_equipment , ts_value desc;


$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_overview_production_chart_v6(idequipment integer)
 RETURNS SETOF h_overview_i_production_chart_v6
 LANGUAGE sql
 STABLE
AS $function$

select 
        e.id_enterprise,
        id_equipment,
        to_char(ts_value at time zone s.timezone, 'HH24 h') as "time",
        ts_value at time zone s.timezone as times,
        row_number() over (order by ts_value desc) as rn,
        e.cd_equipment,
        sum(coalesce(net, 0))::float8 as "production",
        (case when sum(coalesce(scrap, 0))>0 then sum(coalesce(scrap, 0)) else 0 end)::float8 as "scrap" 
from equipment_oee_hourly vaevh
left join equipments e using (id_equipment)
left join sites s using (id_site)
where ts_value >= now() - '24h'::interval and ts_value < now()
and e.tp_equipment = 3
and id_equipment = idequipment
group by e.id_enterprise , id_equipment, vaevh.ts_value, e.cd_equipment, s.timezone 
order by id_equipment , ts_value desc;

$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_production_flow(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text)
 RETURNS SETOF h_piot_production_flow_table
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_id_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_id_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := 	(select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end
						 );
	min_ts_prod timestamptz := (select min(ts_value) from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ) 
								);
	max_ts_prod timestamptz := (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts )
								);
begin 
	
	return query
	
	select 
		id_enterprise,
		total_scrap,
		nm_equipment,
		flexible_position,
		array_agg(jsonb_build_object(
			'nm_machine',nm_machine,
			'net',net,
			'gross',gross,
			'scrap', scrap,
			'stopped_time', stopped_time 
		) order by ppe_position, pe_position, machine_position) production_flow
	from 
	(
			select
				ers.id_enterprise,
				ers.id_equipment,
				ers.nm_machine,
				coalesce(ppe.nm_equipment, pe.nm_equipment) as nm_equipment,
				coalesce(ppe.id_parentequipment, pe.id_parentequipment) as id_parentequipment,
				coalesce(ppe.flexible_position, pe.flexible_position) as flexible_position,
				machine_position,
				ppe.position as ppe_position,
				pe.position as pe_position,
				ers.net,
				ers.gross,
				ers.scrap,
				ers.stopped_time,
				sum(scrap) over (partition by coalesce(ppe.nm_equipment, pe.nm_equipment)) as total_scrap
			from 
				(
					select
						e.id_enterprise,
						ers.id_equipment,
						e.nm_equipment as nm_machine,
						e.id_parentequipment,
						e."position" as machine_position,
						sum(net) net,
						sum(gross) gross,
						sum(scrap) scrap,
						sum(stopped_time) stopped_time
					from 
						equipment_oee_shift ers
						join equipments e using (id_equipment)
						join shifts s using (id_shift)
						left join teams t using (id_team)
					where
						ts_value >= min_ts_prod
						and ts_value <= max_ts_prod
						and e.id_enterprise = in_id_enterprise
						and ers.id_shift = any( ids_shifts )
						and (case when ids_teams is not null then t.id_team = any(ids_teams) else true end )
						and tp_equipment = 1		
					group by e.id_enterprise, ers.id_equipment, e.nm_equipment, e.position, e.id_parentequipment
				) ers
				join equipments pe on (ers.id_parentequipment=pe.id_equipment)
				left join equipments ppe on (pe.id_parentequipment=ppe.id_equipment)
			where coalesce (ppe.id_equipment, pe.id_equipment) = any( ids_equips )
			group by 
				ers.id_enterprise, ers.id_equipment, ers.nm_machine,
				coalesce(ppe.nm_equipment, pe.nm_equipment),
				coalesce(ppe.id_parentequipment, pe.id_parentequipment),
				coalesce(ppe.flexible_position, pe.flexible_position),
				machine_position, ppe.position, pe.position, ers.net, ers.gross, ers.scrap, ers.stopped_time
		)s1
	group by id_enterprise, total_scrap, id_parentequipment, nm_equipment, flexible_position
	order by nm_equipment;


end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_production_orders_runtimes(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
 RETURNS SETOF h_piot_production_orders_table
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
begin
	return query	
	
	
SELECT 
	po2.id_enterprise,
    case when upper(runtime_timerange) is null then 2
    	else 3
    end status,
    po.id_production_order,
    po2.id_order,
    c.nm_client,
    p.nm_product,
    po2.production_ordered,
    COALESCE(po.gross_production, 0::double precision) AS gross_production,
    COALESCE(po.net_production, 0::double precision) AS net_production,
    e.nm_equipment,
    e.id_area,
    e.id_site,
    lower(runtime_timerange) as ts_start,
    upper(runtime_timerange) as ts_end,
    po2.id_equipment,
    id_production_order_runtime 
   FROM production_orders_runtime po
   		join production_orders po2 using (id_production_order, id_equipment)
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN products p USING (id_product)
     LEFT JOIN equipments e USING (id_equipment)
  WHERE 
 	e.id_site = ANY(ids_sites)
 	and e.id_area = ANY(ids_areas)
 	and id_equipment = ANY(ids_equips)
 	and ts_start >= _tsstart and ts_start < _tsend;
-- 	and ids_shifts = ANY(ids_shifts);
 
 
  return;
end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_production_orders_with_runtimes4(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
 RETURNS SETOF h_piot_production_orders_with_runtimes_table_4
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_ids_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_ids_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_ids_shifts, ',')) = 0 then true
										when left(in_ids_shifts, 1) != '{' then cd_shift = any( string_to_array(in_ids_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_ids_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_ids_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
begin
	return query	
	--CREATE TABLE public.h_piot_production_orders_with_runtimes_table2
	--AS 
SELECT po.id_enterprise,
    po.status,
    po.id_production_order,
    po.id_order,
    c.nm_client,
    p.nm_product,
    p.txt_product,
    po.production_ordered,
--    COALESCE(NULLIF(po.gross_production, 0::double precision), po.production_final::double precision) AS gross_production,
--    COALESCE(NULLIF(po.net_production, 0::double precision), po.production_final::double precision) AS net_production,
    COALESCE(po.gross_production, 0::double precision) AS gross_production,
    COALESCE(po.net_production, 0::double precision) AS net_production,
--    po.net_production,
    e.nm_equipment,
    e.id_area,
    e.id_site,
    po.ts_start,
    po.production_final,
--    COALESCE(po.ts_end, now()) AS ts_end,
    po.ts_end,
    po.id_equipment,
    (
    select 
    		json_agg(runtimes) runtimes
    from(
	    select     	
				json_build_object(
					'ts_start', LOWER(runtime_timerange),
					'ts_end', UPPER(runtime_timerange),
					'duration',
						case when UPPER(runtime_timerange) is not null
							then (UPPER(runtime_timerange)-LOWER(runtime_timerange))
							else NULL
						end,
					'net', net_production,
					'gross', gross_production,
					'production_final', production_final,
					'scrap', coalesce(gross_production, 0) - coalesce(net_production, 0),
					'scrap_percentage',
						case when coalesce(gross_production, 0) = 0
							then 1
							else (coalesce(gross_production, 0) - coalesce(net_production, 0))/gross_production
						end,
					'nm_equipment', (select nm_equipment from equipments where id_equipment = por.id_equipment),
					'id_production_order', por.id_production_order,
					'id_production_order_runtime', id_production_order_runtime
				) runtimes
	    	from production_orders_runtime por
	    	where por.id_production_order=po.id_production_order 
    	)a
    ) as runtimes
   FROM production_orders po
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN products p USING (id_product)
     LEFT JOIN equipments e USING (id_equipment)
  WHERE po.status <> 1
 	and
 	 e.id_site = ANY(ids_sites)
 	and e.id_area = ANY(ids_areas)
 	and id_equipment = ANY(ids_equips)
 	and (
 		tstzrange (_tsstart, _tsend, '[)') && tstzrange (ts_start, ts_end, '[)')
 		--or po.status = 1
 	);
-- 	and ids_shifts = ANY(ids_shifts);
 
 
  return;
end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_single_period_with_teams_3(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text)
 RETURNS SETOF h_single_period_equipment_chart_table_3
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_id_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_id_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case UPPER(time_grain)
									when 'HOUR' then
										(select min(ts_value) from ca_agg_equipment_values_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value) from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
			--								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			--								and ev.id_enterprise = in_id_enterprise
			--								and ev.id_area = any( ids_areas)
			--								and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) )
								end
							);
	max_ts_prod timestamptz := (
						select case UPPER(time_grain)
									when 'HOUR' then
										(select max(ts_value) from ca_agg_equipment_values_1hour ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
										and ev.id_enterprise = in_id_enterprise
										and ev.id_area = any( ids_areas)
										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ))
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
--								and ev.id_enterprise = in_id_enterprise
--								and ev.id_area = any( ids_areas)
--								and ev.id_site = any( ids_sites )
								and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ))
							end
							);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return QUERY 
	
	select
		case when date_trunc(time_grain, now()) = ts_value then now() else ts_value end ts_value_production,
		id_enterprise,
		sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
		array_agg(obj order by coalesce (shift_position, team_position) )
		from (
			select 
				ts_value::timestamptz,
				ers.id_enterprise,
				case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
				case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
				sum(coalesce(net_production_incr, 0)) net, sum(coalesce(gross_production_incr, 0)) gross, sum(coalesce(scrap_incr, 0)) scrap, avg(coalesce(pt.vl_hour, 0)) target,
				jsonb_build_object(							
					'id_shift', case group_by_element when 'SHIFTS' then id_shift END,
					'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
					'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
					'id_team', case group_by_element when 'TEAMS' then t.id_team END,
					'net', sum(coalesce(net_production_incr, 0)),
					'gross', sum(coalesce(gross_production_incr, 0)),
					'scrap', sum(coalesce(scrap_incr, 0)),
					'scrap_percentage', sum(coalesce(scrap_incr, 0)) / nullif( sum(coalesce(gross_production_incr, 0)) , 0),
					'scrap_target', avg(st.vl_shift),
					'target', avg(coalesce(pt.vl_hour, 0))
				) obj
			from 
				ca_agg_equipment_values_1hour ers
				join production_targets pt using (id_equipment)
				left join shifts s using (id_shift)
				left join teams t using (id_team)
				left join scrap_targets st on (ers.id_equipment = st.id_equipment)
			where
				ts_value >= min_ts_prod
				and ts_value <= max_ts_prod
				and ers.id_enterprise = in_id_enterprise
				and ers.id_area = any( ids_areas)
				and ers.id_site = any( ids_sites )
				and ers.id_equipment =  any( ids_equips )
				and ers.id_shift = any( ids_shifts )
			group by 
				ers.id_enterprise, ts_value,
				case group_by_element when 'SHIFTS' then ers.id_shift else null END,
				case group_by_element when 'SHIFTS' then s.cd_shift else null END,
				case group_by_element when 'SHIFTS' then s.sequence_position else null END,
				case group_by_element when 'TEAMS' then t.sequence_position else null end,
				t.id_team, t.cd_team
			) aa 
		group by ts_value, id_enterprise order by ts_value;

ELSE return QUERY 


select
	case when date_trunc(time_grain, now()) = date_trunc(time_grain, ts_value_production) then now() else ts_value_production end ts_value_production,
	id_enterprise,
	sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
	array_agg(obj order by coalesce (shift_position, team_position))
from (
	select 
		date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
		e.id_enterprise,
		case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
		case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
		sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target,
		jsonb_build_object(
			'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift END,
			'cd_shift', case group_by_element when 'SHIFTS' then ers.cd_shift END,
			'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
			'id_team', case group_by_element when 'TEAMS' then t.id_team END,
			'net', sum(coalesce(net, 0)),
			'gross', sum(coalesce(gross, 0)),
			'scrap', sum(coalesce(scrap, 0)),
			'scrap_percentage', sum(coalesce(scrap, 0)) / nullif( sum(coalesce(gross, 0)) , 0),
			'scrap_target', avg(st.vl_shift),
			'target', sum(coalesce(target, 0))
		) obj
	from 
		equipment_oee_shift ers
		join equipments e using (id_equipment) 
		join shifts s using (id_shift)
		left join teams t using (id_team)
		left join scrap_targets st on (ers.id_equipment = st.id_equipment)
	where
		ts_value >= min_ts_prod
		and ts_value_production <= max_ts_prod
		and e.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and e.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
		and (ers.id_team is null or ers.id_team = any(ids_teams) ) 
	group by e.id_enterprise, date_trunc(time_grain, ts_value_production),
		case group_by_element when 'SHIFTS' then ers.id_shift else null END,
		case group_by_element when 'SHIFTS' then ers.cd_shift else null END,
		case group_by_element when 'SHIFTS' then s.sequence_position else null END,
		case group_by_element when 'TEAMS' then t.id_team else null END,
		case group_by_element when 'TEAMS' then t.cd_team else null end,
		case group_by_element when 'TEAMS' then t.sequence_position else null END
		) aa 
group by ts_value_production, id_enterprise order by ts_value_production;

END IF;

end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_single_period_with_teams_4(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text)
 RETURNS SETOF h_single_period_equipment_chart_table_4
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_id_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_id_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case UPPER(time_grain)
									when 'HOUR' then
										(select min(ts_value) from ca_agg_equipment_values_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value) from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
			--								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			--								and ev.id_enterprise = in_id_enterprise
			--								and ev.id_area = any( ids_areas)
			--								and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) )
								end
							);
	max_ts_prod timestamptz := (
						select case UPPER(time_grain)
									when 'HOUR' then
										(select max(ts_value) from ca_agg_equipment_values_1hour ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
										and ev.id_enterprise = in_id_enterprise
										and ev.id_area = any( ids_areas)
										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ))
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_oee_shift ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
--								and ev.id_enterprise = in_id_enterprise
--								and ev.id_area = any( ids_areas)
--								and ev.id_site = any( ids_sites )
								and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ))
							end
							);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return QUERY 
	
	select
		case when date_trunc(time_grain, now()) = ts_value then now() else ts_value end ts_value_production,
		id_enterprise,
		sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
		case scrap_calc_type
			when 2 then (sum(coalesce(scrap, 0)::float8) / nullif( sum(coalesce(net, 0))::float8 , 0))::float8 *100 
			else (sum(coalesce(scrap, 0)::float8) / nullif( sum(coalesce(gross, 0))::float8 , 0))::float8 *100 
		end scrap_percentage,
		avg(scrap_target)::float8  *100 scrap_target,
		array_agg(obj order by coalesce (shift_position, team_position) )
	from (
		select 
			ts_value::timestamptz,
			ers.id_enterprise,
			scrap_calc_type,
			case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
			case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
			sum(coalesce(net_production_incr, 0)) net, sum(coalesce(gross_production_incr, 0)) gross, sum(coalesce(scrap_incr, 0)) scrap, avg(st.vl_hour)::float8 scrap_target,
			avg(coalesce(pt.vl_hour, 0)) target, jsonb_build_object(							
				'id_shift', case group_by_element when 'SHIFTS' then id_shift END,
				'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
				'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
				'id_team', case group_by_element when 'TEAMS' then t.id_team END,
				'net', sum(coalesce(net_production_incr, 0)),
				'gross', sum(coalesce(gross_production_incr, 0)),
				'scrap', sum(coalesce(scrap_incr, 0)),
				'scrap_percentage', 
					case scrap_calc_type
						when 2 then (sum(coalesce(scrap_incr, 0)) / nullif( sum(coalesce(net_production_incr, 0)) , 0)) * 100
						else (sum(coalesce(scrap_incr, 0)) / nullif( sum(coalesce(gross_production_incr, 0)) , 0)) * 100
					end,
				'scrap_target', avg(st.vl_hour)*100,
				'target', avg(coalesce(pt.vl_hour, 0))
			) obj
		from 
			ca_agg_equipment_values_1hour ers
			join production_targets pt using (id_enterprise, id_equipment)
			join enterprises e using (id_enterprise)
			left join shifts s using (id_shift)
			left join teams t using (id_team)
			left join scrap_targets st on (ers.id_equipment = st.id_equipment)
		where
			ts_value >= min_ts_prod
			and ts_value <= max_ts_prod
			and ers.id_enterprise = in_id_enterprise
			and ers.id_area = any( ids_areas)
			and ers.id_site = any( ids_sites )
			and ers.id_equipment =  any( ids_equips )
			and ers.id_shift = any( ids_shifts )
		group by 
			ers.id_enterprise, ts_value, scrap_calc_type,
			case group_by_element when 'SHIFTS' then ers.id_shift else null END,
			case group_by_element when 'SHIFTS' then s.cd_shift else null END,
			case group_by_element when 'SHIFTS' then s.sequence_position else null END,
			case group_by_element when 'TEAMS' then t.sequence_position else null end,
			t.id_team, t.cd_team
	) aa 
	group by ts_value, id_enterprise, scrap_calc_type order by ts_value;

ELSE return QUERY 


	select
		case when date_trunc(time_grain, now()) = date_trunc(time_grain, ts_value_production) then now() else ts_value_production end ts_value_production,
		id_enterprise,
		sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
		case scrap_calc_type
			when 2 then sum(coalesce(scrap, 0)::float8) / nullif( sum(coalesce(net, 0))::float8 , 0)::float8 *100
			else sum(coalesce(scrap, 0)::float8) / nullif( sum(coalesce(gross, 0))::float8 , 0)::float8 *100
		end scrap_percentage,
		avg(scrap_target)::float8 *100 scrap_target,
		array_agg(obj order by coalesce (shift_position, team_position))
	from (
		select 
			date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
			e.id_enterprise,
			scrap_calc_type,
			case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
			case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
			sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target, avg(st.vl_shift)::float8 scrap_target,
			jsonb_build_object(
				'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift END,
				'cd_shift', case group_by_element when 'SHIFTS' then ers.cd_shift END,
				'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
				'id_team', case group_by_element when 'TEAMS' then t.id_team END,
				'net', sum(coalesce(net, 0)),
				'gross', sum(coalesce(gross, 0)),
				'scrap', sum(coalesce(scrap, 0)),
				'scrap_percentage',
					case scrap_calc_type
						when 2 then (sum(coalesce(scrap, 0)) / nullif( sum(coalesce(net, 0)) , 0))*100
						else (sum(coalesce(scrap, 0)) / nullif( sum(coalesce(gross, 0)) , 0))*100
					end,
				'scrap_target', avg(st.vl_shift)*100,
				'target', sum(coalesce(target, 0))
		) obj
		from 
			equipment_oee_shift ers
			join equipments e using (id_equipment)
			join enterprises et using (id_enterprise)
			join shifts s using (id_shift)
			left join teams t using (id_team)
			left join scrap_targets st on (ers.id_equipment = st.id_equipment)
		where
			ts_value >= min_ts_prod
			and ts_value <= max_ts_prod
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and e.id_equipment = any( ids_equips )
			and ers.id_shift = any( ids_shifts )
			and (ers.id_team is null or ers.id_team = any(ids_teams) ) 
		group by e.id_enterprise, scrap_calc_type, date_trunc(time_grain, ts_value_production),
			case group_by_element when 'SHIFTS' then ers.id_shift else null END,
			case group_by_element when 'SHIFTS' then ers.cd_shift else null END,
			case group_by_element when 'SHIFTS' then s.sequence_position else null END,
			case group_by_element when 'TEAMS' then t.id_team else null END,
			case group_by_element when 'TEAMS' then t.cd_team else null end,
			case group_by_element when 'TEAMS' then t.sequence_position else null END
	) aa 
	group by ts_value_production, id_enterprise, scrap_calc_type order by ts_value_production;

END IF;

end
$function$
;

CREATE OR REPLACE FUNCTION public.h_piot_total_production_teams_2(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, partitionby text, time_grain text DEFAULT 'DAY'::text)
 RETURNS SETOF h_total_production_chart_from_runtime
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_id_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_id_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then min(ts_value) else min(ts_value_production) end from equipment_oee_hourly ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								and e.id_area = any( ids_areas )
								and e.id_site = any( ids_sites )
								);
	max_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then max(ts_value) else max(ts_value_production) end from equipment_oee_hourly ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								and e.id_area = any( ids_areas )
								and e.id_site = any( ids_sites )
								);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return query 
	
	with query_data as (
		select
			e.id_enterprise,
			case UPPER(partitionBy) when 'SHIFTS' then cd_shift when 'TEAMS' then cd_team else null end	shift_or_team,
			scrap, net, gross, 
			target,
			ts_value,
			ts_value_production
		from
			equipment_oee_hourly ev
			join equipments e using (id_equipment)
			left JOIN LATERAL piot_get_shift_hour_by_equipment_fixed(e.id_enterprise, e.id_equipment, ev.ts_value) f ON true
			left join teams t using (id_team) 
		where 
			(ev.ts_value >= min_ts_prod::timestamp		--date_trunc(time_grain::text, min_ts_prod::timestamptz) 
				and ev.ts_value <= max_ts_prod::timestamp)	--date_trunc(time_grain::text, max_ts_prod::timestamptz)
			and e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
--			and ev.id_shift = any( ids_shifts )
--			and ev.id_team = any( ids_teams )
			and (case when ids_teams is not null then ev.id_team = any( ids_teams ) else true end)
	)
	select(
		timezone('utc', ts::timestamptz)::timestamptz(0))::varchar,
		case 
			when ts <= now() 
				then coalesce(net_incr, 0)::int8
			else null
		end::int8 as net_production_incr,
		case 
			when ts <= now() 
				then coalesce(sum(net_incr) over (order by ts), 0)
			else null
		end::int8 net_production_acc,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts), 0)
		end::int8 as gross_production_acc,
		case 
			when ts <= now() 
				then coalesce(gross_incr - net_incr, 0) --coalesce(scrap_incr, 0)::int8 
			else null
		end::int8 scrap_incr,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts) - sum(net_incr) over (order by ts), 0)
		end::int8 as scrap_acc,
		case 
	 		when ts < now() then null
	 		else
				coalesce(greatest(0,
					(regr_slope((net_acc), (secs))  filter (where ts< now()::timestamptz(0)) over () * extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over()))
				  	+ max(net_acc) over())
		 		, 0)::int8
		end trendline1,
		coalesce(sum(target) over (order by ts), 0)::int8 target,
		case 
			when ts <= max(ts_value) over () then coalesce( (net_acc - sum(target) ) / nullif(net_acc, 0), 0 )
	 	end::float8 as toGoal,
		id_enterprise,
		shift_info::json as shift_net_prod,
		coalesce(sum(target), 0)::int8 target_period
	from 
	(
		select 
			id_enterprise, coalesce (d.ts_value, ts.ts) ts, max(secs) secs, max(ts_value) ts_value,
			sum(net_production_incr) as net_incr,
			sum(gross_production_incr) as gross_incr,
			sum(scrap_incr) as scrap_incr,
			sum(target) as target,
			jsonb_agg( jsonb_build_object(
				case partitionBy  when 'SHIFTS' then 'shift' when 'TEAMS' then 'team' else 'id_enterprise' end,
				case partitionBy  when 'SHIFTS' then shift_or_team when 'TEAMS' then shift_or_team else id_enterprise::varchar end,
				'scrap', scrapacc_sh, 
				'net', netacc_sh)	order by shift_or_team
			) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from (
			select 
				id_enterprise,
				shift_or_team,
				case ts_value
					when date_trunc('hour', now()) then now()::timestamptz 
					else ts_value -- + interval '1 hour'
				end ts_value,
				extract(epoch from ts_value	- min(ts_value) over ()) secs,
				coalesce(sum(target), 0) target,
				coalesce(sum(net), 0) net_production_incr,
				coalesce(sum(gross), 0) gross_production_incr,
				coalesce(sum(scrap), 0) scrap_incr,
				sum(sum(net)) over part netacc_sh,
				sum(sum(scrap)) over part scrapacc_sh,
				sum(sum(net)) over T_part netacc,
				sum(sum(gross)) over T_part grossacc,
				sum(sum(scrap)) over T_part scrapacc
			from
				query_data
			group by id_enterprise, ts_value_production, shift_or_team, ts_value
			window part as ( 
				partition by case partitionBy  when 'SHIFTS' then shift_or_team when 'TEAMS' then shift_or_team else id_enterprise::VARCHAR end				
				order by ts_value),
			T_part as (
				partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d	
		full outer join (
			select ts
			from
				generate_series(min_ts_prod::timestamptz, max_ts_prod::timestamptz, ('1 HOUR')::interval) ts(ts)
			where 
				ts >= min_ts_prod
				and  ts <> date_trunc('hour', now())
		) ts on ts.ts = d.ts_value
		group by id_enterprise, ts, d.ts_value
	) vals
	group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value, target
	order by ts;


ELSE return QUERY 
--	Por Dia, mes ...
	with query_data as (
		select
			e.id_enterprise,
			case UPPER(partitionBy) when 'SHIFTS' then cd_shift when 'TEAMS' then cd_team else null end	shift_or_team,
			sum(scrap) scrap, sum(net) net, sum(gross) gross,
			sum(target) target,
			date_trunc(time_grain::text, ts_value_production) ts_value_production
		from
			equipment_oee_shift ev
			join equipments e using (id_equipment) 
			left join teams t using (id_team) 
		where 
			(ev.ts_value_production >= date_trunc(time_grain::text, min_ts_prod::timestamp) 
				and ev.ts_value_production <= date_trunc(time_grain::text, max_ts_prod::timestamp)) 
			AND e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
			and ev.id_shift = any( ids_shifts )
--			and ev.id_team = any( ids_teams )
			and (case when ids_teams is not null then ev.id_team = any( ids_teams ) else true end)
		group by
			e.id_enterprise,
			date_trunc(time_grain::text, ts_value_production),
			case UPPER(partitionBy) when 'SHIFTS' then cd_shift when 'TEAMS' then cd_team else null end
	)
	select 
		(timezone('utc', ts)::timestamptz(0))::varchar,
		case 
			when ts <= now() 
				then coalesce(net_incr, 0)::int8
			else null
		end::int8 as net_production_incr,
		case 
			when ts <= now() 
				then coalesce(sum(net_incr) over (order by ts), 0)
			else null
		end::int8 net_production_acc,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts), 0)
		end::int8 as gross_production_acc,
		case 
			when ts <= now() 
				then coalesce(gross_incr - net_incr, 0)
			else null
		end::int8 scrap_incr,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts) - sum(net_incr) over (order by ts), 0)
		end::int8 as scrap_acc,
--		case 
--			when ts < now() then null
--			else
--			coalesce(greatest(0,
--				(
--					(max(net_acc) filter(where ts <= now()::timestamptz) over()/nullif(extract (epoch from max(ts) filter(where ts <= now()::timestamptz) over()-min(ts) over() ),0))
--					* extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over()))
--		 		  	+ max(net_acc) over())
--			 , 0)::int8 end trendline1,
		case 
			when ts < now() then null
			else
			coalesce(
				greatest(
					0,
					(
						(
							max(net_acc) filter(where ts <= now()::timestamptz) over()
							/
							nullif(extract (epoch from max(ts) filter(where ts <= now()::timestamptz) over()
							---min(ts) over()
							-min_ts_prod
							),0)
						)
						* extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over())
					)+ max(net_acc) over())
			 , 0)::int8 end trendline1,
		coalesce(sum(target) over (order by ts), 0)::int8 target,
		case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(target) ) /nullif(net_acc, 0), 0 )
		end::float8 as toGoal,
		id_enterprise,
		shift_info::json as shift_net_prod,
		coalesce(sum(target), 0)::int8 target_period
		from (
			select 
				id_enterprise,
				--coalesce ( date_trunc(time_grain, date_trunc(time_grain, d.ts_value)) , ts.ts) ts,
				case
					when date_trunc(time_grain, d.ts_value) = date_trunc(time_grain, now()) then now()
					else coalesce ( date_trunc(time_grain, d.ts_value) , ts.ts)
				end ts,
				--coalesce (d.ts_value, ts.ts) ts,
				max(secs) secs, max(ts_value) ts_value,
				sum(net_production_incr) as net_incr,
				sum(gross_production_incr) as gross_incr,
				sum(scrap_incr) as scrap_incr,
				sum(target) as target,
				jsonb_agg( jsonb_build_object(
					case partitionBy  when 'SHIFTS' then 'shift' when 'TEAMS' then 'team' else 'id_enterprise' end,
					case partitionBy  when 'SHIFTS' then shift_or_team when 'TEAMS' then shift_or_team else id_enterprise::varchar end,
					'scrap', scrapacc_sh, 
					'net', netacc_sh
				)	order by shift_or_team) shift_info,
				sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
				sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
				sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
			from (
				select 
					id_enterprise,
					shift_or_team,
					case
						date_trunc(time_grain, ts_value_production) when date_trunc(time_grain, now())::date then now()::timestamptz 
						else ts_value_production -- + interval '1 hour'
					end ts_value,
					extract(
						epoch from 
						date_trunc(time_grain, ts_value_production) 
						- min(date_trunc(time_grain, ts_value_production)) over ()
					) secs,
					coalesce(sum(target), 0) target,
					coalesce(sum(net), 0) net_production_incr,
					coalesce(sum(gross), 0) gross_production_incr,
					coalesce(sum(scrap), 0) scrap_incr,
					sum(sum(net)) over part netacc_sh,
					sum(sum(scrap)) over part scrapacc_sh,
					sum(sum(net)) over T_part netacc,
					sum(sum(gross)) over T_part grossacc,
					sum(sum(scrap)) over T_part scrapacc
				from query_data
				group by id_enterprise, shift_or_team, ts_value_production,
						date_trunc(time_grain, ts_value_production)
				window part as ( 
					partition by case partitionBy  when 'SHIFTS' then shift_or_team when 'TEAMS' then shift_or_team else id_enterprise::VARCHAR end				
					order by date_trunc(time_grain, ts_value_production) 
				), 
				T_part as (
					partition by date_trunc(time_grain, ts_value_production)
				)
			) d
			full outer join--right join
			(
				select ts
				from generate_series(
					date_trunc(time_grain, min_ts_prod::timestamp),
					date_trunc(time_grain, max_ts_prod::timestamp),
					('1'||time_grain)::interval) ts(ts)
				where ts<>date_trunc(time_grain, now())
			) ts on ts.ts = d.ts_value
			group by id_enterprise, ts, date_trunc(time_grain, d.ts_value) 
		) vals
		group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value, target
	order by ts;


END IF;
end
$function$
;

