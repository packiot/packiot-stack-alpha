-- =============================================================================
-- f1-stop-threshold.sql  —  F1 (packiot) counterpart of f3-stop-threshold.sql.
--
-- Same systemic gap on the F1 plane: equipments.stop_threshold_time NULL for all
-- 169 equipments; 36 functions + 13 views reference it, ~29 functions and 9
-- views row-gate on it raw and therefore silently drop / zero downtimes.
--
-- Actions (see f3-stop-threshold.sql for full rationale + evidence):
--   1. Backfill CPACK (id_enterprise=3) + sandbox twin (2000003) = 301s (the
--      authoritative legacy C-PACK value, uniform across all its equipments).
--   2. Platform default 300s (5 min) for future inserts.
--   3. Fail-open COALESCE on every raw consumer (macro `>=` -> COALESCE(x,0);
--      micro `<` -> COALESCE(x,'infinity')).
--
-- PLANE DIVERGENCE NOTE: unlike F3, F1's composite type
--   h_piot_get_downtimes_per_category_equipment_level_new.downtimes_per_category
--   is already jsonb[] (matches what _new_4 produces) -> F1 has NO column-8 type
--   bug, so the ::text[] cast applied on F3 is intentionally NOT applied here.
--
-- get_downtime_sync_enterprsie_06 left untouched (stop_threshold_time=0 sentinel
-- for manual stops; enterprise 6 not present on F1 staging). Idempotent.
-- =============================================================================

BEGIN;

UPDATE public.equipments
   SET stop_threshold_time = 301
 WHERE id_enterprise IN (3, 2000003)
   AND stop_threshold_time IS DISTINCT FROM 301;

ALTER TABLE public.equipments ALTER COLUMN stop_threshold_time SET DEFAULT 300;

-- NULL-safe consumer functions (fail-open COALESCE).

-- ---- function: h_piot_get_downtimes_equipment_level ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_equipment_level(in_ids_sites text, in_ids_areas text, in_ids_equipments text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now())
 RETURNS SETOF h_downtimes_table_2
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := in_ids_sites::int[];
	ids_areas int[] := in_ids_areas::int[];
	ids_equips int[] := in_ids_equipments::int[];
begin
return query
--select 
--ts_event - date_trunc('week', ts_event),
--(extract('epoch' from (ts_event - date_trunc('week', ts_event)))-(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = aaa.id_equipment)))::int4 aaaaa,
--* from
--(
select 
	id_equipment_event, ts_event, ts_end, id_equipment, (select nm_equipment from equipments where id_equipment=aa.id_equipment), cd_machine, duration, cd_category, cd_category txt_category, --change to description when available
	cd_subcategory,	cd_subcategory txt_subcategory,
	txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise 
from
	(select
		id_equipment_event,
		ts_event,
		ts_end,
		id_equipment,
		(select id_area from equipments e where e.id_equipment = ee.id_equipment) id_area,
		(select id_site from equipments e where e.id_equipment = ee.id_equipment) id_site,
		cd_machine,
		duration,
		cd_category,
		cd_category txt_category, --change to description when available
		cd_subcategory,
		cd_subcategory txt_subcategory, --change to description when available
		txt_downtime_notes,
		(select id_order from production_orders po where po.id_production_order  = (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)),
		(select cd_shift 
			from shifts sh
			where 
				id_shift = 
					(
						select id_shift from equipment_runtime_shift ers where
							ee.ts_event <@ ers.ts_range 
							and id_enterprise = ee.id_enterprise
							and id_equipment = ee.id_equipment
					)
		) cd_shift,
		(select id_shift from equipment_runtime_shift ers where
			ee.ts_event <@ ers.ts_range 
			and id_enterprise = ee.id_enterprise
			and id_equipment = ee.id_equipment
		) id_shift,			
	--	(select cd_shift from shift_hours sh where (extract('epoch' from (ts_event - date_trunc('week', ts_event))))::int4 <@ int4range((sh.begin_time+(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = ee.id_equipment))), (sh.end_time+(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = ee.id_equipment)))) and ((select id_area from equipments where id_equipment = ee.id_equipment) = sh.id_area)),
	--	(select id_shift from shift_hours sh where (extract('epoch' from (ts_event - date_trunc('week', ts_event))))::int4 <@ int4range((sh.begin_time+(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = ee.id_equipment))), (sh.end_time-(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = ee.id_equipment)))) and ((select id_area from equipments where id_equipment = ee.id_equipment) = sh.id_area)),
		id_enterprise 
	from
		equipment_events ee
	where 
		status = 10
--		and ts_event >= date_trunc('month',now()-interval '1 day')
--		and ts_event < now()
		and ts_event >= _tsstart
		and ts_event < _tsend
		and 
			(
			duration >= COALESCE((select stop_threshold_time from equipments e where e.id_equipment = ee.id_equipment), 0)
				or
			duration is null
			)
		and (select tp_equipment from equipments where id_equipment = ee.id_equipment)=3
	) aa
where
	id_equipment = any(ids_equips)
	and id_area= any(ids_areas)
	and id_site = any(ids_sites)
--	id_equipment = 42
--	and id_area= 30
--	and id_site = 30
order by ts_event desc;
--)aaa
--where cd_shift='Noturno'
end
$function$



;

-- ---- function: h_piot_get_downtimes_events_2 ----


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
		left join equipment_runtime_shift ers on
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
		left join equipment_runtime_shift ers on
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

-- ---- function: h_piot_get_downtimes_events_3 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_events_3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false)
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
		left join equipment_runtime_shift ers on
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
		left join equipment_runtime_shift ers on
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

-- ---- function: h_piot_get_downtimes_events_99 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_events_99(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false)
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
		--ers.ts_range,
		case when ers.ts_range is null then tstzrange(ts_event,coalesce(ee.ts_end,now())) else ers.ts_range end as ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then 
					(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment))
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
		),
		case when sh.cd_shift is null then (select cd_shift from shifts where id_enterprise=in_id_enterprise order by id_shift limit 1) else sh.cd_shift end as cd_shift,
		case when ers.id_shift is null then (select id_shift from shifts where id_enterprise=in_id_enterprise order by id_shift limit 1) else ers.id_shift end as id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
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
		left join equipment_runtime_shift ers on
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

-- ---- function: h_piot_get_downtimes_events ----


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
		left join equipment_runtime_shift ers on
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
		left join equipment_runtime_shift ers on
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

-- ---- function: h_piot_get_downtimes_events_test ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_events_test(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false)
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
		left join equipment_runtime_shift ers on
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
		left join equipment_runtime_shift ers on
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
			(id_sector = any(ids_sectors)) and (id_site = any(ids_sites)) and (id_area = any(ids_areas))
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

-- ---- function: h_piot_get_downtimes_per_category_99 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_per_category_99(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
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
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	min_ts_prod timestamp := (select min(ts_value) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamp := (select max(ts_end) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);
begin
return query 	
select distinct 
	id_enterprise,
	array_agg(
		jsonb_build_object(
			'nm_equipment', nm_equipment,
			'id_equipment', id_equipment,
			'cd_machine', cd_machine,
			'change_over', change_over,
			'num_occurence', count(*),
			'avg_time', avg(extract(epoch from st_cut_end - st_cut_start)),
			'planned_downtime', planned_downtime,
			'cd_category', coalesce(cd_category, 'Microstops'),
			'txt_category', coalesce(txt_category, cd_category, 'Microstops'),
			--'duration_total', sum( extract(epoch from least(upper(ee.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ee.ts_value, ee.ts_event) ) ),
			'duration_total', sum(extract(epoch from st_cut_end - st_cut_start)),
			'duration_justified', sum(extract(epoch from st_cut_end - st_cut_start)) filter (where cd_category is not null),
			'duration_planned', sum(extract(epoch from st_cut_end - st_cut_start)) filter (where cd_category is not null and planned_downtime = true),
			'duration_unplanned', sum(extract(epoch from st_cut_end - st_cut_start)) filter (where cd_category is not null and planned_downtime = false)
		)
	) over () as downtimes_per_category
from 
(select 
		ee.id_enterprise,
		ee.id_equipment_event,
		e.nm_equipment,
		ee.id_equipment,
		ee.cd_machine,
		ee.change_over,
		--ers.ts_range,
		--ee.ts_end,
		--ers.ts_value,
		--ee.ts_event,
		ee.planned_downtime,
		ee.cd_category,
		ee.txt_category,
		min(greatest(ers.ts_value, ee.ts_event)) as st_cut_start,
		max(least(upper(ers.ts_range), coalesce(ee.ts_end, now()))) as st_cut_end
	from public.h_piot_get_downtimes_sector_microstops_99(in_id_enterprise,in_ids_sites,in_ids_areas,in_ids_equipments,'{}',_tsstart,_tsend,false,true) ee
	join equipments e on ee.id_equipment =e.id_equipment 
	join equipment_runtime_shift ers 
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
				and (ers.ts_range && tstzrange(min_ts_prod ,max_ts_prod)) --eduardo 2024-07-13 (nao estava funcionando para paradas longas)
--*************************************			--and (ers.ts_range && tstzrange(_tsstart ,_tsend)) --eduardo 2024-07-13 (nao estava funcionando para paradas longas)
			)
	join shifts s on (s.id_shift = ers.id_shift)
	where
		ers.id_shift = any( ids_shifts )
		--Elimination on unjustified stops (but keeps downtimes)
		and	 (
		ee.cd_category is not null
			or
			(
				extract	(
					epoch from
						least(upper(ers.ts_range), coalesce(ee.ts_end, now()))
						-
						greatest(ers.ts_value, ee.ts_event)
				) < COALESCE(e.stop_threshold_time, 'infinity'::double precision)
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
		--and ee.id_equipment_event not in (select id_equipment_event from equipment_events_man where id_enterprise=in_id_enterprise and ts_event >= _tsstart)
	group by
		ee.id_enterprise, e.nm_equipment, ee.id_equipment, ee.cd_machine, ee.change_over, ee.planned_downtime,
		ee.cd_category, ee.txt_category,
		--ers.ts_range,ee.ts_end,ers.ts_value,ee.ts_event,
		ee.id_equipment_event
	order by ee.cd_category, ee.txt_category) aaa 
group by id_enterprise, nm_equipment, id_equipment, cd_machine, change_over, planned_downtime, cd_category, txt_category;
--order by cd_category, txt_category;
return;
end
$function$



;

-- ---- function: h_piot_get_downtimes_per_category_equipment_level_new_4 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_per_category_equipment_level_new_4(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
 RETURNS SETOF h_piot_get_downtimes_per_category_equipment_level_new
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
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
begin
	return query 
	select 
		aa.id_enterprise,
		duration_microstops::int8,
		duration_total::int8,
		duration_justified::int8,
		duration_planned::int8,
		duration_unplanned::int8,
	    shs.available_time::int8,
		downtimes_per_category
	from 
	(
	select distinct 
		ee.id_enterprise,
	--	coalesce(ee.cd_category, 'Microstops') as cd_category,
	--	coalesce(ee.cd_category, 'Microstops') as txt_category, --change to description when available
	--	ee.planned_downtime,
		array_agg( jsonb_build_object(
							'nm_equipment', (select nm_equipment from equipments e where e.id_equipment = ee.id_equipment),
							'id_equipment', ee.id_equipment,
							'cd_machine', ee.cd_machine,
							'change_over', ee.change_over,
							'num_occurence', count(*),
							'avg_time', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) )/count(*),
					 		'planned_downtime', ee.planned_downtime, -- v
				            'cd_category', coalesce(ee.cd_category, 'Microstops'), --V
				            'txt_category',coalesce(ee.desc_category, ee.cd_category, 'Microstops'),--V
				            'duration_total', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) ), --V
				            'duration_justified', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null),
				            'duration_planned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = true), --V
				            'duration_unplanned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = false)
							) ) over () as downtimes_per_category, 
		sum( sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) )
				      ) ) over () duration_total,
	    sum( 
	    	sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)
	    	)) filter (where extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) < COALESCE(e.stop_threshold_time, 'infinity'::double precision)
	    	and cd_category is null 
	    	and extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) >0 ) ) over() duration_microstops,
	    sum( 
	    	sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)
	    	)) filter (where cd_category is not null) ) over () duration_justified,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.cd_category is not null and ee.planned_downtime = true) ) over () duration_planned,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.planned_downtime = false or ee.cd_category is null ) ) over () duration_unplanned
	    from equipment_events ee
	join equipments e on ee.id_equipment =e.id_equipment 
	join equipment_runtime_shift ers 
		on ers.id_equipment = ee.id_equipment
		and (ee.ts_event <@ ers.ts_range
			or ee.ts_end <@ ers.ts_range)
	join shifts s on s.id_shift = ers.id_shift 
	where 
		status = 10
		and ts_event >= _tsstart and ts_event < _tsend
		and e.tp_equipment = 3
		and ee.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and ee.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
--		and e.id_area = 34
--		and e.id_site = 30
--		and (ee.id_equipment = 42 or ee.id_equipment = 1 or ee.id_equipment = 6 or ee.id_equipment = 11)
--		and (ers.id_shift = 35 or ers.id_shift = 34) 
	group by ee.id_enterprise, ee.cd_category, ee.desc_category, ee.planned_downtime, ee.id_equipment, ee.cd_machine, ee.change_over 
	) aa 
	-- SUM OF ALL SHIFTS 
	cross join
	(
		select 
--			sum(ers.duration)
			sum(
--				case when min_ts_prod <@ ers.ts_range
--					then
--						case when max_ts_prod <@ ers.ts_range
--							then extract ('epoch' from max_ts_prod - min_ts_prod)
--							else extract ('epoch' from ers.ts_end - min_ts_prod)
--						end
--					else case when max_ts_prod <@ ers.ts_range
--							then extract ('epoch' from max_ts_prod - ers.ts_value)
--							else duration 
--						end
--				end
				case when now() <@ ers.ts_range
					then extract ('epoch' from now() - ers.ts_value)
					else duration 
				end
			) 
			as available_time
		from equipment_runtime_shift ers 
		join equipments e on ers.id_equipment = e.id_equipment 
		where 
			--ers.ts_value >= _tsstart and ers.ts_value < _tsend 
			ers.ts_value_production >= min_ts_prod and ers.ts_value_production <= max_ts_prod 
			-- excluding futures shifts
			and ers.ts_value <= now()
			and e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ers.id_equipment = any( ids_equips )
			and ers.id_shift = any( ids_shifts )
--			and e.id_area = 34
--			and e.id_site = 30
--			and (ers.id_equipment = 42 or ers.id_equipment = 1 or ers.id_equipment = 6 or ers.id_equipment = 11)
--			and (ers.id_shift = 35 or ers.id_shift = 34) 
	) shs;
return;
end
$function$



;

-- ---- function: h_piot_get_downtimes_per_category_equipment_level_new_4_test ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_per_category_equipment_level_new_4_test(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
 RETURNS SETOF h_piot_get_downtimes_per_category_equipment_level_new
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
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
begin
	return query 
	select 
		aa.id_enterprise,
		duration_microstops::int8,
		duration_total::int8,
		duration_justified::int8,
		duration_planned::int8,
		duration_unplanned::int8,
	    shs.available_time::int8,
		downtimes_per_category
	from 
	(
	select distinct 
		ee.id_enterprise,
	--	coalesce(ee.cd_category, 'Microstops') as cd_category,
	--	coalesce(ee.cd_category, 'Microstops') as txt_category, --change to description when available
	--	ee.planned_downtime,
		array_agg( jsonb_build_object(
							'nm_equipment', (select nm_equipment from equipments e where e.id_equipment = ee.id_equipment),
							'id_equipment', ee.id_equipment,
							'cd_machine', ee.cd_machine,
							'change_over', ee.change_over,
							'num_occurence', count(*),
							'avg_time', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) )/count(*),
					 		'planned_downtime', ee.planned_downtime, -- v
				            'cd_category', coalesce(ee.cd_category, 'Microstops'), --V
				            'txt_category',coalesce(ee.desc_category, ee.cd_category, 'Microstops'),--V
				            'duration_total', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) ), --V
				            'duration_justified', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null),
				            'duration_planned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = true), --V
				            'duration_unplanned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = false)
							) ) over () as downtimes_per_category, 
		sum( sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) )
				      ) ) over () duration_total,
	    sum( 
	    	sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)
	    	)) filter (where extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) < COALESCE(e.stop_threshold_time, 'infinity'::double precision)
	    	and cd_category is null 
	    	and extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) >0 ) ) over() duration_microstops,
	    sum( 
	    	sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)
	    	)) filter (where cd_category is not null) ) over () duration_justified,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.cd_category is not null and ee.planned_downtime = true) ) over () duration_planned,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.planned_downtime = false or ee.cd_category is null ) ) over () duration_unplanned
	    from equipment_events ee
	join equipments e on ee.id_equipment =e.id_equipment 
	join equipment_runtime_shift ers 
		on ers.id_equipment = ee.id_equipment
		and (ee.ts_event <@ ers.ts_range
			or ee.ts_end <@ ers.ts_range)
	join shifts s on s.id_shift = ers.id_shift 
	where 
		status = 10
		and ts_event >= _tsstart and ts_event < _tsend
		and e.tp_equipment = 3
		and ee.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and ee.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
--		and e.id_area = 34
--		and e.id_site = 30
--		and (ee.id_equipment = 42 or ee.id_equipment = 1 or ee.id_equipment = 6 or ee.id_equipment = 11)
--		and (ers.id_shift = 35 or ers.id_shift = 34) 
	group by ee.id_enterprise, ee.cd_category, ee.desc_category, ee.planned_downtime, ee.id_equipment, ee.cd_machine, ee.change_over 
	) aa 
	-- SUM OF ALL SHIFTS 
	cross join
	(
		select 
--			sum(ers.duration)
			sum(
--				case when min_ts_prod <@ ers.ts_range
--					then
--						case when max_ts_prod <@ ers.ts_range
--							then extract ('epoch' from max_ts_prod - min_ts_prod)
--							else extract ('epoch' from ers.ts_end - min_ts_prod)
--						end
--					else case when max_ts_prod <@ ers.ts_range
--							then extract ('epoch' from max_ts_prod - ers.ts_value)
--							else duration 
--						end
--				end
				case when now() <@ ers.ts_range
					then extract ('epoch' from now() - ers.ts_value)
					else duration 
				end
			) 
			as available_time
		from equipment_runtime_shift ers 
		join equipments e on ers.id_equipment = e.id_equipment 
		where 
			--ers.ts_value >= _tsstart and ers.ts_value < _tsend 
			ers.ts_value_production >= min_ts_prod and ers.ts_value_production <= max_ts_prod 
			-- excluding futures shifts
			and ers.ts_value <= now()
			and e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ers.id_equipment = any( ids_equips )
			and ers.id_shift = any( ids_shifts )
--			and e.id_area = 34
--			and e.id_site = 30
--			and (ers.id_equipment = 42 or ers.id_equipment = 1 or ers.id_equipment = 6 or ers.id_equipment = 11)
--			and (ers.id_shift = 35 or ers.id_shift = 34) 
	) shs;
return;
end
$function$



;

-- ---- function: h_piot_get_downtimes_per_category_gci ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_per_category_gci(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
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
			'id_equipment', (case when ee.id_equipment = 274 then 293 when ee.id_equipment = 275 then 276 else ee.id_equipment end),  
			'cd_machine', ee.cd_machine,
			'change_over', ee.change_over,
			'num_occurence', count(*),
			'avg_time', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)))/count(*),
			'planned_downtime', ee.planned_downtime,
			'cd_category', coalesce(ee.cd_category, 'Microstops'),
			'txt_category', coalesce(ee.txt_category, ee.cd_category, 'Microstops'),
			'duration_total', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) ),
			'duration_justified', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null),
			'duration_planned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = true),
			'duration_unplanned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = false)
		)
	) over () as downtimes_per_category
from
	public.h_piot_get_downtimes_sector_microstops_gci (in_id_enterprise,in_ids_sites,in_ids_areas,in_ids_equipments,'{}',_tsstart,_tsend,false,true) ee
	join equipments e on (case when ee.id_equipment = 274 then 293 when ee.id_equipment = 275 then 276 else ee.id_equipment end) =e.id_equipment 
	join equipment_runtime_shift ers 
		on (
			ers.id_equipment = (case when ee.id_equipment = 274 then 293 when ee.id_equipment = 275 then 276 else ee.id_equipment end)
			and (
				ee.ts_event::timestamptz <@ ers.ts_range
				or
				ee.ts_end::timestamptz <@ ers.ts_range
			)
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
				) < COALESCE(e.stop_threshold_time, 'infinity'::double precision)
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
	group by
		ee.id_enterprise, e.nm_equipment, ee.id_equipment, ee.cd_machine, ee.change_over, ee.planned_downtime,
		ee.cd_category, ee.txt_category;
return;
end
$function$



;

-- ---- function: h_piot_get_downtimes_per_category ----


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
	join equipment_runtime_shift ers 
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
				) < COALESCE(e.stop_threshold_time, 'infinity'::double precision)
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

-- ---- function: h_piot_get_downtimes_sector_2 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_sector_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), sector_view boolean DEFAULT false)
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
	id_equipment_event, (ts_event at time zone (timezone))::timestamp as ts_event, (ts_end at time zone (timezone))::timestamp as ts_end, id_equipment, id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
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
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status <> 6
		and ts_event > _tsstart::timestamp - interval '1 months'
		and (ee.ts_end < _tsend::timestamp + interval '1 months' or ee.ts_end is null)
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ( ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
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
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
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
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
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
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $function$



;

-- ---- function: h_piot_get_downtimes_sector_demo ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_sector_demo(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), sector_view boolean DEFAULT false)
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
	id_equipment_event, (ts_event at time zone (timezone))::timestamp as ts_event, (ts_end at time zone (timezone))::timestamp as ts_end, id_equipment, id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
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
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status = 10
		and ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ( ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
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
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
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
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
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
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $function$



;

-- ---- function: h_piot_get_downtimes_sector_microstops_99 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_sector_microstops_99(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), sector_view boolean DEFAULT false, microstops_view boolean DEFAULT false)
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
	min_ts_prod timestamp := (select min(ts_value) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamp := (select max(ts_end) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);

begin
return query

select * from (
select
	id_equipment_event, 
	--(ts_event at time zone (timezone))::timestamp as ts_event,
	ts_event::timestamp as ts_event,
	ts_end::timestamp as ts_end,
	--(ts_end at time zone (timezone))::timestamp as ts_end, 
	id_equipment, id_sector,
	nm_equipment, sector, 
	--cd_machine, 
	case when coalesce(duration,extract(epoch from now()-ts_event))>=stop_threshold_time and cd_machine is null then 'No_Reason_Input' else cd_machine end as cd_machine,
	duration, 
	--cd_category, --alteração eduardo 2024-03-26 para que a categoria Non-Reason-Input passe a ser mostrada no go.packiot na pagina de Downtimes, em "Motivos de Paradas"
	case when coalesce(duration,extract(epoch from now()-ts_event))>=stop_threshold_time and cd_category is null then 'No_Reason_Input' else cd_category end as cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		--desc_category txt_category,
		cd_category txt_category,
		cd_subcategory,
		cd_subcategory txt_subcategory,
		--desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise,
		false as manual_event --eduardo 2024-03-27 to avoid manual stops counting time in go packiot
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status = 10
		and ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		--and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and tstzrange(ts_event, coalesce(ee.ts_end,now())) && tstzrange (min_ts_prod,max_ts_prod)		
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
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
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		cd_category txt_category,
		--desc_category txt_category,
		cd_subcategory,
		--desc_subcategory txt_subcategory,
		cd_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise,
		true as manual_event --eduardo 2024-03-27 to avoid manual stops counting time in go packiot
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
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
		and tstzrange(ts_event, coalesce(ee.ts_end,now())) && tstzrange (min_ts_prod,max_ts_prod)		
		--and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ( ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $function$





;

-- ---- function: h_piot_get_downtimes_sector_microstops_gci ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_sector_microstops_gci(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), sector_view boolean DEFAULT false, microstops_view boolean DEFAULT false)
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
						 and s.tp_equipment in (2,3)
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
	id_equipment_event, (ts_event at time zone (timezone))::timestamp as ts_event, (ts_end at time zone (timezone))::timestamp as ts_end, id_equipment, id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
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
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status = 10
		and ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
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
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
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
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
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
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $function$



;

-- ---- function: h_piot_get_downtimes_sector_microstops ----


CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_sector_microstops(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), sector_view boolean DEFAULT false, microstops_view boolean DEFAULT false)
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
	min_ts_prod timestamp := (select min(ts_value) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamp := (select max(ts_end) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);

begin
return query

select * from (
select
	id_equipment_event, 
	--(ts_event at time zone (timezone))::timestamp as ts_event,
	ts_event::timestamp as ts_event,
	ts_end::timestamp as ts_end,
	--(ts_end at time zone (timezone))::timestamp as ts_end, 
	id_equipment, id_sector,
	nm_equipment, sector, 
	--cd_machine, 
	case when coalesce(duration,extract(epoch from now()-ts_event))>=stop_threshold_time and cd_machine is null then 'No_Reason_Input' else cd_machine end as cd_machine,
	duration, 
	--cd_category, --alteração eduardo 2024-03-26 para que a categoria Non-Reason-Input passe a ser mostrada no go.packiot na pagina de Downtimes, em "Motivos de Paradas"
	case when coalesce(duration,extract(epoch from now()-ts_event))>=stop_threshold_time and cd_category is null then 'No_Reason_Input' else cd_category end as cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		--desc_category txt_category,
		cd_category txt_category, --alteracao eduardo 2024-07-14
		cd_subcategory,
		cd_subcategory txt_subcategory, --alteracao eduardo 2024-07-14
		--desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise,
		false as manual_event --eduardo 2024-03-27 to avoid manual stops counting time in go packiot
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status = 10
		and ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		--and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and tstzrange(ts_event, coalesce(ee.ts_end,now())) && tstzrange (min_ts_prod,max_ts_prod)		
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
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
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		cd_category txt_category,
		--desc_category txt_category,
		cd_subcategory,
		--desc_subcategory txt_subcategory,
		cd_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise,
		true as manual_event --eduardo 2024-03-27 to avoid manual stops counting time in go packiot
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
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
		and tstzrange(ts_event, coalesce(ee.ts_end,now())) && tstzrange (min_ts_prod,max_ts_prod)		
		--and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ( ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $function$



;

-- ---- function: h_piot_get_downtimes ----

CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes(_tsstart timestamp without time zone DEFAULT (now() - '1 mon'::interval), _tsend timestamp without time zone DEFAULT now())
 RETURNS SETOF h_downtimes_table
 LANGUAGE sql
 STABLE
AS $function$
select
	ts_event,
	(select nm_equipment from equipments e where e.id_equipment = ee.id_equipment),
	cd_machine,
	duration,
	cd_category,
	cd_category txt_category, --change to description when available
	cd_subcategory,
	cd_subcategory txt_subcategory, --change to description when available
	txt_downtime_notes,
	(select id_order from production_orders po where po.id_production_order  = (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)),
	(select cd_shift from shift_hours sh where (extract('epoch' from (ts_event - date_trunc('week', ts_event))))::int4 <@ int4range(sh.begin_time, sh.end_time) and ((select id_area from equipments where id_equipment = ee.id_equipment) = sh.id_area)),
	id_enterprise 
from
	equipment_events ee
where 
	status = 10
	and ts_event >= _tsstart
	and ts_event < _tsend
	and 
		(
		duration >= COALESCE((select stop_threshold_time from equipments e where e.id_equipment = ee.id_equipment), 0)
			or
		duration is null
		)
	and (select tp_equipment from equipments where id_equipment = ee.id_equipment)=3
order by ts_event desc;
$function$



;

-- ---- function: h_piot_get_equipment_pending_downtime ----


CREATE OR REPLACE FUNCTION public.h_piot_get_equipment_pending_downtime(in_packml_topic character varying[])
 RETURNS SETOF h_pending_events
 LANGUAGE sql
 STABLE
AS $function$
SELECT ts_event, ts_end, duration, e.id_equipment, e.id_enterprise, p.packml_topic, ignore_cost
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

-- ---- function: h_piot_get_equipment_pending_downtime_with_event_id_cpack ----


CREATE OR REPLACE FUNCTION public.h_piot_get_equipment_pending_downtime_with_event_id_cpack(in_packml_topic character varying[])
 RETURNS SETOF h_pending_events_with_event_id_cpack
 LANGUAGE sql
 STABLE
AS $function$
	SELECT id_equipment_event, ts_event, ts_end, duration, e.id_equipment, e.id_enterprise, p.packml_topic
    FROM equipment_events ee
    JOIN equipments e ON ee.id_equipment = e.id_equipment
    join packml_register p on p.id_equipment = e.id_equipment
    WHERE p.packml_topic = ANY (in_packml_topic)
        AND (ee.ts_end >= now() - interval '8 hours' OR ee.ts_end IS NULL)
        AND ee.status != 6
        AND (ee.duration >= COALESCE(e.stop_threshold_time, 0) or ee.duration is null)
        and ee.cd_category is null
    ORDER BY ts_event DESC;
   $function$



;

-- ---- function: h_piot_get_events_timeline2 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline2(in_packml_topic character varying[])
 RETURNS SETOF h_events_timeline2
 LANGUAGE sql
 STABLE
AS $function$
SELECT
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
  desc_category,
  desc_subcategory,
  p.packml_topic,
  'downtime' :: text as event_type
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
UNION 
SELECT
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
	'low_speed' :: text as event_type
FROM
	equipment_events_low_speed eels
	JOIN equipments e ON eels.id_equipment = e.id_equipment
	JOIN packml_register p ON p.id_equipment = e.id_equipment
WHERE
	p.packml_topic = ANY (in_packml_topic)
	AND eels.ts_event >= now() - interval '1 days'
	AND eels.status = 1 OR eels.status = 2
UNION
SELECT
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
  'manual' :: text as event_type
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment = e.id_equipment
  JOIN packml_register p on p.id_equipment = e.id_equipment
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND eem.ts_event >= now() - interval '1 days'
   -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
 
$function$



;

-- ---- function: h_piot_get_events_timeline3 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline3(in_packml_topic character varying[])
 RETURNS SETOF h_events_timeline3
 LANGUAGE sql
 STABLE
AS $function$

select
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
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND 
  ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null or ee.cd_category is not null))
  AND ee.status != 6
  and ee.cd_category is not null
  
UNION 
SELECT
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
SELECT
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

-- ---- function: h_piot_get_events_timeline3_with_event_id_cpack ----


CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline3_with_event_id_cpack(in_packml_topic character varying[])
 RETURNS SETOF h_events_timeline3_with_event_id_cpack
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
  AND 
  (ee.ts_end >= now() - interval '8 hours' or ee.ts_end is null)
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
	AND eels.ts_end >= now() - interval '9 hours'
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
  AND eem.ts_event >= now() - interval '8 hours'
   -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
 
$function$



;

-- ---- function: h_piot_get_events_timeline4 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline4(in_packml_topic character varying[])
 RETURNS SETOF h_events_timeline4
 LANGUAGE sql
 STABLE
AS $function$

select
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
  po.custom_field,
  cd_category_client,
  cd_subcategory_client
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND 
  ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
  
UNION 
SELECT
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
	po.custom_field,
	null,
	null
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
SELECT
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
  po.custom_field,
	null,
	null
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

-- ---- function: h_piot_get_events_timeline5 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline5(in_packml_topic character varying[])
 RETURNS SETOF h_events_timeline5
 LANGUAGE sql
 STABLE
AS $function$

select
  ts_event,
  ee.ts_end,
  ee.fault,
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
  po.custom_field,
  cd_category_client,
  cd_subcategory_client,
  ignore_cost
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND 
  ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
  
UNION 
SELECT
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	eels.fault,
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
	po.custom_field,
	null,
	null,
	null
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
SELECT
  eem.ts_event as ts_event,
  eem.ts_end as ts_end,
  eem.fault,
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
  po.custom_field,
	null,
	null,
	eem.ignore_cost
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

-- ---- function: h_piot_get_events_timeline_from_po_2 ----


CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline_from_po_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, _id_production_order integer DEFAULT NULL::integer)
 RETURNS SETOF h_events_equipment_timeline_2
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
	_id_prod_order int := (_id_production_order);
begin
	return query

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
	e.id_equipment = any(ids_equips)
    and e.id_area= any(ids_areas)
    and e.id_site = any(ids_sites)
--    ee.id_equipment = _id_equipment
--  	 case when _id_production_order is not null then ee.id_equipment = (select id_equipment from production_orders where id_production_order = _id_production_order) else true end
    and (_id_prod_order is null or 
    	ee.id_equipment = (select id_equipment from production_orders where id_production_order = _id_prod_order)
    )
	and (_id_prod_order is null or 
    	ee.ts_event::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_prod_order ) )
    )
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
    e.id_equipment = any(ids_equips)
    and e.id_area= any(ids_areas)
    and e.id_site = any(ids_sites)
--    and case when _id_prod_order is not null then e.id_equipment = (select id_equipment from production_orders where id_production_order = _id_prod_order) else true end
  and 
    (_id_prod_order is null or 
    e.id_equipment = (select id_equipment from production_orders where id_production_order = _id_prod_order)
    )
--  eem.ts_event_start >= now() - interval '24 hour'
--  (select runtime_timerange from production_orders_runtime por where id_production_order=_id_prod_order) @> eem.ts_event_start
  and 
    (_id_prod_order is null or 
  eem.ts_event::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_prod_order ) )
    )
  AND extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer >= COALESCE(e.stop_threshold_time, 0) -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER by ts_event DESC;


end $function$



;

-- ---- function: h_piot_get_events_timeline_from_po ----


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

-- ---- function: h_piot_get_events_timeline ----


CREATE OR REPLACE FUNCTION public.h_piot_get_events_timeline(in_packml_topic character varying[])
 RETURNS SETOF h_events_timeline
 LANGUAGE sql
 STABLE
AS $function$
SELECT
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
  p.packml_topic,
  'downtime' :: text as event_type
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND ee.ts_event >= now() - interval '4 days'
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
UNION 
SELECT
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	e.id_equipment,
	e.id_enterprise,
	eels.txt_downtime_notes,
	eels.cd_machine,
	eels.cd_category,
	eels.cd_subcategory,
	eels.change_over,
	p.packml_topic,
	'low_speed' :: text as event_type
FROM
	equipment_events_low_speed eels
	JOIN equipments e ON eels.id_equipment = e.id_equipment
	JOIN packml_register p ON p.id_equipment = e.id_equipment
WHERE
	p.packml_topic = ANY (in_packml_topic)
	AND eels.ts_event >= now() - interval '4 days'
	AND eels.status = 1 OR eels.status = 2
UNION
SELECT
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
  p.packml_topic,
  'manual' :: text as event_type
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment = e.id_equipment
  JOIN packml_register p on p.id_equipment = e.id_equipment
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND eem.ts_event >= now() - interval '4 days'
   -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
 
$function$



;

-- ---- function: h_piot_get_hasura_test ----


CREATE OR REPLACE FUNCTION public.h_piot_get_hasura_test(in_packml_topic character varying[])
 RETURNS SETOF hasura_test
 LANGUAGE sql
 STABLE
AS $function$

select
  ts_event,
  ee.ts_end,
  ee.fault,
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
  po.custom_field,
  cd_category_client,
  cd_subcategory_client,
  ignore_cost
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND 
  ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
  
UNION 
SELECT
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	eels.fault,
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
	po.custom_field,
	null,
	null,
	null
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
SELECT
  eem.ts_event as ts_event,
  eem.ts_end as ts_end,
  eem.fault,
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
  po.custom_field,
	null,
	null,
	eem.ignore_cost
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

-- ---- function: upsert_sap_report_data_sync_customer_13 ----


CREATE OR REPLACE FUNCTION public.upsert_sap_report_data_sync_customer_13()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  INSERT INTO sap_report_data_sync_customer_13 (
    linie,
    tag,
    shicht,
    shicht_nummer,
    auftrag_key,
    auftrag,
    sum_labels,
    rumpfe,
    gutmenge,
    rustzeit,
    produktionszeit,
    geplante_ausfallzeit,
    ungeplante_ausfallzeit,
    matfehler_ausfallzeit,
    no_order,
    auftrag_startzeit,
    running_h,
    shift_start_time,
    data_type,
    id_order_label
  )
  WITH dias as (
SELECT 
	(generate_series((now() at time zone 'Europe/Zurich')::date - interval '8 day', (now() at time zone 'Europe/Zurich')::date,'1 day'))::date as start_day
), start_counting_day as (
--para que os dados sejam buscados sempre a partir do ultimo domingo
select 
	min(start_day) as start_day
from dias
--where to_char(start_day, 'dy') in ('sun')
order by start_day desc
limit 1
), turnos as (--aqui pega as logicas de turnos na runtime de turnos
select 
	concat(to_char(((ers.ts_value at time zone 'Europe/Zurich')::time),'HH24:MI'),'-', to_char(((ers.ts_end at time zone 'Europe/Zurich')::time),'HH24:MI')) as turno_hrs,
	ers.ts_value as shift_start_time, --nova variavel 
	ers.id_equipment,
	shi.cd_shift as cd_shift, --alteracao feita para evitar erro de falta dessa info na troca de turno
	ers.id_shift,
	ers.ts_value_production,
	ers.ts_value as tz_value,
	case 
		when ers.ts_end > now() then now() 
		else ers.ts_end end as tz_end
from equipment_runtime_shift ers, start_counting_day scd, shifts shi 
where ers.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and tp_equipment = 3 and id_site = 13)
and ers.ts_value_production >= scd.start_day --now()::date -  interval '3 day' 
and ers.ts_value <= now()
and shi.id_shift = ers.id_shift
order by ers.id_equipment, tz_value
), equipamentos as (--aqui pega uma logica para que cada id_equipment tenha um cd_equipment de uma linha associado
select 
	e.id_equipment,
		case when eq.tp_equipment = 3 then e.id_parentequipment
		when eq.tp_equipment = 2 then eq.id_parentequipment end as id_equipment_line
from equipments e, equipments eq
where e.id_parentequipment = eq.id_equipment
and e.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment in (1,2))
), linhas as (--aqui faz a associacao final do id_equipment com o cd_equipment de uma linha
select 
	e.id_equipment,
	eq.cd_equipment,
	e.id_equipment_line,
	eq.stop_threshold_time
from equipamentos e, equipments eq
where e.id_equipment_line = eq.id_equipment
--******** parte nova para ser inserida que estava com erro nos downtimes*************
union all
select 
	id_equipment,
	cd_equipment,
	id_equipment as id_equipment_line,
	stop_threshold_time
from equipments
where id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3)
order by cd_equipment 
--***************************************************************************************
), presscount as (--dados de press-count para todos os equipamento tipo 3 da enterprise 6
	select 
	id_equipment,
	id_site,
	id_area,
	ts_value as tz_value,
	gross_production_incr,
	net_production_incr 
	from agg_equipment_values_1min_t, start_counting_day scd
	where id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3)
	and ts_value >= now()- interval '8 day'
	and ts_value >= start_day
	and id_enterprise = 13
	and id_site = 13--in (select id_site from sites where id_enterprise = 6)
	--and id_area = 58--in (select id_area from areas where id_enterprise = 6 and id_area!=24)
/*)--,labels_extract as (--pega os labels, e precisa ser hard coded pois nao existe uma logic para qual equipamento tem labels
select 
	ca.ts_value as tz_value, 
	--ca.id_equipment,
	l.id_equipment_line as id_equipment,
	ca.id_order as label_Job,
	ca.net_production  as label_amount
	from ca_equipment_boxes_1s ca, linhas l
	-- a json was created in the custom column with a logic for all equipments that have labels in the table ca_equipment_boxes_1s
	--where ca.id_equipment in (138,144,236,260,266,323,363,374,385,432,458,481,492,503,514,518,525,530,535,549,573,578)
	where ca.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 29 and cast(custom::json#>>'{Label,has_labels}' as BOOLEAN) is true and id_area not in (24))
	and ca.id_enterprise = 13
	and ca.id_site = 29--in (select id_site from sites where id_enterprise = 6)
	and ca.ts_value >= now() - interval '30 day'
	and l.id_equipment = ca.id_equipment
	order by ts_value	
*/
),labels_extract as (--pega os labels, e precisa ser hard coded pois nao existe uma logic para qual equipamento tem labels
	select 	
		null::timestamptz as tz_value,
		null::int4 as id_equipment,
		null::text as label_Job,
		null::float8 as label_amount	
), prod_orders as (--aqui existe um problema a ser resolvido. Se existe um GAP entre OPs
	select 
	porun.id_equipment,
	po.id_enterprise,
	po.id_area, 
	po.id_site,
	po.id_order,
	porun.runtime_timerange,
	lower(porun.runtime_timerange) as job_start,
	case when upper(porun.runtime_timerange) is null then now() else upper(porun.runtime_timerange) end as job_end,
	upper(porun.runtime_timerange) as ts_end_progress
from production_orders_runtime porun, production_orders po
where porun.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and tp_equipment = 3 and id_site = 13)
and po.id_equipment = porun.id_equipment
and po.id_enterprise = 13
and po.id_production_order = porun.id_production_order 
and lower(porun.runtime_timerange) >= now() - interval '90 day'
order by 1,6
), negative_labels as ( --FOI MODIFICADO E AGORA NAO APENAS OS LABELS NEGATIVOS MAS TB OS POSITIVOS SAO CONSIDERADOS PARA 3H
select l.*, po.job_end,
	case when po.job_end is null then 0 else ((date_part('epoch'::text, l.tz_value -po.job_end)))::bigint end as diff_s
from labels_extract l
left join prod_orders po
on cast(l.label_Job as integer) = po.id_order
), labels as (
select distinct tz_value,id_equipment,label_job,label_amount
--, diff_s
from negative_labels
where diff_s <= 10800 -- condicao de 3h
order by tz_value
), po_sequence_basis as ( --mudar
select 
	id_order,
	lead(id_order) over (order by id_order, runtime_timerange) as id_order_sec,
	runtime_timerange,
	lead(runtime_timerange) over (order by id_order, runtime_timerange) as runtime_timerange_sec	
from prod_orders
order by id_order
), po_sequence as ( --mudar
select 
	id_order,--abaixo modificado no dia 2024-04-03 para evitar duplicacao de dados de OPs que rodaram mais de uma vez
	case when id_order = id_order_sec then tstzrange(lower(runtime_timerange),least((upper(runtime_timerange) + interval '6 hour'),lower(runtime_timerange_sec)))
	else tstzrange(lower(runtime_timerange),now()::timestamp) end as runtime_timerange_new
from po_sequence_basis
order by id_order,runtime_timerange
),base_for_splits as (
select 
	shi.turno_hrs,
	shi.shift_start_time, -- nova variavel celine
	shi.id_equipment,
	shi.cd_shift,
	shi.ts_value_production,
	po.id_order,
	case when tz_value > coalesce(job_start,'2024-01-01') then tz_value else job_start end as inicio,
	case when tz_end < coalesce(job_end,'2100-01-01') then tz_end else job_end end as fim,
	po.id_site,
	po.id_area,
	shi.id_shift
from turnos shi
left join prod_orders po
on po.job_start < shi.tz_end
and po.job_end >= shi.tz_value
and po.id_equipment = shi.id_equipment
order by shi.id_equipment, shi.tz_value
), press_quantity as (
select 
	bfs.id_equipment,
	bfs.cd_shift,
	bfs.ts_value_production,
	bfs.id_order,
	bfs.inicio,
	bfs.fim,
	sum(pc.gross_production_incr) as gross,
	bfs.id_shift,
	bfs.turno_hrs,
	bfs.shift_start_time,
	sum(pc.net_production_incr) as net
from base_for_splits bfs
left join presscount pc
on pc.tz_value >= bfs.inicio and pc.tz_value < bfs.fim
and pc.id_equipment = bfs.id_equipment
and pc.id_site = bfs.id_site
and pc.id_area = bfs.id_area
--and pc.tz_value >= now() - interval '36 hour' 
group by 1,2,3,4,5,6,8,9,10
order by 1,5
), top_level AS (
         SELECT id_equipment,jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE equipments.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and tp_equipment = 3 and id_site = 13)--708 --(TL205)
        ), category_level AS (
         SELECT 
         	id_equipment,
         	--jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'position'::text AS "position",
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code')::int as position
          FROM top_level
           order by 1,2          
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position"::integer AS "position",
            category_level.description
            --id_equipment
           FROM category_level
          ORDER BY 1--(category_level."position"::integer)  
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" as code,
            case 
            	when dc."position" in (24) then 1 --Műszaki hiba--DEFECTS--UNPLANNED
            	when dc."position" in (2) then 2 --Tervezett karbantartás--MAINTENANCE-PLANNED
            	when dc."position" in (5,8) then 3--(5,8) then 3 --Anyagprobléma--MATERIAL (HU TAKE ALSO LAMINAT AS MATERIAL)
            	when dc."position" is null and extract(epoch from coalesce(ts_end,now())-ts_event) >= COALESCE(e.stop_threshold_time, 0) then 4 --no_reson--
            	when dc."position" is null and extract(epoch from coalesce(ts_end,now())-ts_event) < COALESCE(e.stop_threshold_time, 'infinity'::double precision) then  5 --microstops--
            	when dc."position" in (7) then 6 --Tervezett karbantartás--MAINTENANCE-PLANNED
            	else 0 --Beállítási idő-- 
            	end AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 
          AND ee.ts_event >= (now() - '90 days'::interval) 
          and tstzrange(ee.ts_event, coalesce(ee.ts_end, now())) && tstzrange(now()- interval '8 day', now())
          and tstzrange (ee.ts_event,  COALESCE(ee.ts_end, now())) && tstzrange(now()- interval '7 day', now())
          AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT 
            sb.id_equipment,
            sb.ts_event as tz_event,
            sb.nextts as tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
    		sb.downtimereason
          FROM stops_neopac_ch sb
          where coalesce(nextts,now()) >= (select start_day - interval '1 day' from start_counting_day)
          ORDER BY sb.cd_equipment, sb.ts_event
), split_bfs as (
--PRIMEIRO SPLIT DOS DOWNTIMES BASEADO NO BFS (SHIFTS E JOBS)
select st.id_equipment, 
greatest(st.tz_event,bfs.inicio) as tz_event,
least(coalesce(st.tz_end,now()),bfs.fim) as tz_end,
st.planned_downtime,
bfs.inicio,
st.cd_category,
st.code,
st.downtimereason
from stops_raw st
left join base_for_splits bfs
on tstzrange(st.tz_event,coalesce(tz_end,now())) && tstzrange(bfs.inicio, bfs.fim)
and bfs.id_equipment = st.id_equipment
order by 1,2,5
--********************************************************************************
--FUNCIONANDO ATEH ESSE PONTO COM AS NOVAS LOGICAS DE DTS
), stops_final as (
select 
	stpf.*,
	--DETERMINACAO DAS LOGICAS DE SOMAS DE DOWNTIME
	--PRECISA SER DEFINIDO CORRETAMENTE COM A MONTEBELLO
	--coalesce(stpf.setup_s,0) - sum(case when st.cat_dt_logics in (2,4,8,10) then st.duration_s else 0 end) as stp_s,
	coalesce(sum(case when st.downtimereason in (0) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_0,
	coalesce(sum(case when st.downtimereason in (1) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_1,
	coalesce(sum(case when st.downtimereason in (2) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_2,
	coalesce(sum(case when st.downtimereason in (3) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_3,
	coalesce(sum(case when st.downtimereason in (4) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_4,
	coalesce(sum(case when st.downtimereason in (5) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_5,
	coalesce(sum(case when st.downtimereason in (6) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_6
--from setup_final stpf
from base_for_splits stpf
left join split_bfs st
on st.tz_event < stpf.fim
and st.tz_end > stpf.inicio
--and st.tz_end >= now() - interval '36 hour'
and stpf.id_equipment = st.id_equipment
group by 1,2,3,4,5,6,7,8,9,10,11
order by 3,2,7
), final_and_press as (
select 
	f.*,
	pqty.gross,
	pqty.net
from stops_final f
left join press_quantity pqty
on	f.id_equipment = pqty.id_equipment
and	f.cd_shift = pqty.cd_shift
and	f.ts_value_production = pqty.ts_value_production
and	f.id_order = pqty.id_order
and	f.inicio = pqty.inicio
and	f.fim = pqty.fim
and	f.id_shift = pqty.id_shift
and	f.turno_hrs = pqty.turno_hrs
), packed_quantity as (--importannte aqui as excessoes---olhar testes acima e procurar job 12345 
select 
	bfs.id_equipment,
	l.Label_Job,
	bfs.id_order,
	bfs.inicio,
	bfs.fim,
	case when sum(l.Label_amount) is null then 0 else sum(l.Label_amount) end as net_label,
	bfs.id_shift
from base_for_splits bfs--, linhas eq
left join labels l
on l.tz_value >= bfs.inicio and l.tz_value < bfs.fim - interval '1 second'
and l.id_equipment = bfs.id_equipment
group by 1,2,3,4,5,7
order by 1,4,2
), press_packed_final as (
--selecionar apenas os casos onde teste = 0 pois nesses sempre existe press e packed com mesmo id_order no mesmo turno
--no final teria que fazer um union all com todos as tinhas de teste = 1, ajeitando as colunas para isso
--cuidar aqui para que o press count não seja somado mais de uma vez
select 
	f.id_equipment,
	f.cd_shift,
	f.ts_value_production,
	f.id_order,
	(date_part('epoch'::text, f.fim - f.inicio))::bigint as shift_duration, 
	f.gross as press_count,
	f.net as net_sensor,
	pack.net_label as packed_qty,
	pack.label_job,
	f.id_shift,
	f.turno_hrs,
	f.shift_start_time,
	dt_0,
	dt_1,
	dt_2,
	dt_3,
	dt_4,
	dt_5,
	dt_6
from final_and_press f
left join packed_quantity pack
on f.inicio = pack.inicio
and f.fim = pack.fim
and f.id_equipment = pack.id_equipment
and f.id_order = pack.label_job::bigint
union all 
select 
	f.id_equipment,
	f.cd_shift,
	f.ts_value_production,
	pack.label_job::bigint as id_order,
	0 as shift_duration, 
	0 as press_count,
	0 as net_sensor,
	pack.net_label as packed_qty,
	null as label_job,
	f.id_shift,
	f.turno_hrs,
	f.shift_start_time,
	dt_0,
	dt_1,
	dt_2,
	dt_3,
	dt_4,
	dt_5,
	dt_6
from final_and_press f
inner join packed_quantity pack
on f.inicio = pack.inicio
and f.fim = pack.fim
and f.id_equipment = pack.id_equipment
and pack.net_label is not null
and pack.net_label != 0
and f.id_order != pack.label_job::bigint
order by id_equipment,ts_value_production, cd_shift
--FUNCIONANDO ATEH AQUI
), shift_report as (
select 
	ppf.id_equipment,
	eq.cd_equipment as line,
	ppf.cd_shift as shift,
	ppf.turno_hrs as shift_hrs,
	ppf.ts_value_production as day,
	ppf.id_order as job,
	ppf.shift_duration::float,
	((ppf.shift_duration::float)/3600)::numeric(10,2) as shift_duration_s,
	((ppf.dt_0::float + ppf.dt_1::float + ppf.dt_2::float + ppf.dt_3::float + ppf.dt_4::float + ppf.dt_5::float + ppf.dt_6::float)/3600)::numeric(10,2) as total_dt_s,
	((ppf.shift_duration::float - (ppf.dt_0::float + ppf.dt_1::float + ppf.dt_2::float + ppf.dt_3::float + ppf.dt_4::float + ppf.dt_5::float + ppf.dt_6::float))/3600)::numeric(10,2) as running_s,
	((ppf.dt_0::float + ppf.dt_4::float + ppf.dt_5::float)/3600)::numeric(10,2) as dt_0, --Beállítási idő-- including NO REASON dt_4 and microstops dt_5 
	(ppf.dt_1::float/3600)::numeric(10,2) as dt_1, --Műszaki hiba--
	(ppf.dt_2::float/3600)::numeric(10,2) as dt_2, --Tervezett karbantartás--
	(ppf.dt_3::float/3600)::numeric(10,2) as dt_3, --Anyagprobléma--
	(ppf.dt_6::float/3600)::numeric(10,2) as dt_4, --no_reson--
	coalesce(ppf.press_count,0) as prss_qty,
	coalesce(ppf.net_sensor,0) as net_sensor,
	coalesce(ppf.packed_qty,0) as packed_qty,
	shi.sequence_position as shift_number,
	ppf.shift_start_time at time zone 'Europe/Zurich' as shift_start_time,
	lower(pos.runtime_timerange_new) at time zone 'Europe/Zurich' as job_sequence
from press_packed_final ppf
left join equipments eq
on ppf.id_equipment = eq.id_equipment
and eq.id_enterprise = 13
and eq.tp_equipment = 3
left join shifts shi
on shi.id_shift = ppf.id_shift
and shi.id_enterprise = 13
left join po_sequence pos
on ppf.id_order = pos.id_order --mudar
and tstzrange(ppf.shift_start_time,ppf.shift_start_time +interval '12 hour') && pos.runtime_timerange_new --mudar
),labels_data as (
select 
ebc.id_equipment,
ebc.ts_value,
ebc.id_order,
ebc.net_production
from equipment_boxes_cust_13 ebc 
where ebc.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3) 
and ts_value >= now() - interval '8 day'
order by 1,ts_value
), final_labels as (
select 
	eq.cd_equipment,
	t.*,
	ld.id_order,
	sum(ld.net_production) as sum_labels
from turnos t
left join labels_data ld 
on t.id_equipment = ld.id_equipment
and ld.ts_value >= t.tz_value and ld.ts_value < t.tz_end
left join equipments eq 
on eq.id_equipment = t.id_equipment 
group by 1,2,3,4,5,6,7,8,9,10
order by id_equipment, shift_start_time
), final_jobs as (
select 
prss_qty as rumpfe,
net_sensor as gutmenge,
dt_0 as rustzeit,
shift_duration_s as produktionszeit,
dt_2 as geplante_ausfallzeit,
dt_1 as ungeplante_ausfallzeit,
dt_3 as matfehler_ausfallzeit,
dt_4 as no_order,
job as auftrag,
line as linie,
shift as shicht,
shift_number as shicht_nummer,
job_sequence as auftrag_startzeit,
day as tag,
running_s as running_h,
shift_start_time
from shift_report 
--where day >= now() at time zone 'Europe/Zurich' - interval '3 day'
order by line, day,shift_number, job_sequence
), final1 as (
select fl.id_order,fl.sum_labels,fj.*
from final_jobs fj
left join final_labels fl
on fl.cd_equipment = fj.linie
and fl.id_order::int = fj.auftrag
and fl.ts_value_production = fj.tag
and fl.cd_shift = fj.shicht
), missing_jobs_labels as (
select fl.*,f1.id_order as job
from final_labels fl
left join final1 f1
on fl.cd_equipment = f1.linie
and fl.id_order::int = f1.auftrag
and fl.ts_value_production = f1.tag
and fl.cd_shift = f1.shicht
where fl.sum_labels is not null
and f1.id_order is null
), final10 as (
select 
	'normal' as data_type,
	id_order as id_order_label,
	sum_labels,
	rumpfe,
	gutmenge,
	rustzeit,
	produktionszeit,
	geplante_ausfallzeit,
	ungeplante_ausfallzeit,
	matfehler_ausfallzeit,
	no_order,
	auftrag,
	linie,
	shicht,
	shicht_nummer,
	auftrag_startzeit at time zone 'Europe/Zurich' as auftrag_startzeit,
	tag,
	running_h,
	shift_start_time
from final1
union all 
select 
	'missing_job' as data_type,
	id_order as id_order_label,
	sum_labels,
	0 as rumpfe,
	0 as gutmenge,
	0 as rustzeit,
	0 as produktionszeit,
	0 as geplante_ausfallzeit,
	0 as ungeplante_ausfallzeit,
	0 as matfehler_ausfallzeit,
	0 as no_order,
	null as auftrag,
	cd_equipment as linie,
	cd_shift as shicht,
	case when  cd_shift = 'Frühschicht' then 1 when cd_shift = 'Spätschicht' then 2 when cd_shift = 'Nachtschicht' then 3 end as shicht_nummer,
	null as auftrag_startzeit,
	ts_value_production as tag,
	0 as running_h,
	shift_start_time
from missing_jobs_labels
order by linie, tag, shicht_nummer-- case when shicht = 'Frühschicht' then 1 when shicht = 'Spätschicht' then 2 else 3 end
)
  SELECT DISTINCT ON (linie, tag, shicht, auftrag_key)  
    linie,
    tag,
    shicht,
    shicht_nummer,
    COALESCE(auftrag, 0) AS auftrag_key,
    auftrag,
    sum_labels,
    rumpfe,
    sum_labels as gutmenge, --HJ falou q eles estavam pegando gutmenge como labels
    rustzeit,
    produktionszeit,
    geplante_ausfallzeit,
    ungeplante_ausfallzeit,
    matfehler_ausfallzeit,
    no_order,
    auftrag_startzeit,
    running_h,
    shift_start_time,
    data_type,
    id_order_label
  FROM final10
  WHERE tag >= now() at time zone 'Europe/Zurich' - interval '5 day'
  --AND concat(linie, tag, shicht, auftrag) != 'TL1142025-08-05Frühschicht20083337' 
  ON CONFLICT (linie, tag, shicht, auftrag_key)
  DO UPDATE SET
    auftrag = EXCLUDED.auftrag,
    sum_labels = EXCLUDED.sum_labels,
    rumpfe = EXCLUDED.rumpfe,
    gutmenge = EXCLUDED.gutmenge,
    rustzeit = EXCLUDED.rustzeit,
    produktionszeit = EXCLUDED.produktionszeit,
    geplante_ausfallzeit = EXCLUDED.geplante_ausfallzeit,
    ungeplante_ausfallzeit = EXCLUDED.ungeplante_ausfallzeit,
    matfehler_ausfallzeit = EXCLUDED.matfehler_ausfallzeit,
    no_order = EXCLUDED.no_order,
    auftrag_startzeit = EXCLUDED.auftrag_startzeit,
    running_h = EXCLUDED.running_h,
    shift_start_time = EXCLUDED.shift_start_time,
    data_type = EXCLUDED.data_type,
    id_order_label = EXCLUDED.id_order_label;
END;
$function$



;

-- NULL-safe consumer views (fail-open COALESCE).

-- ---- view: v_13_site_deb_sap_report ----
CREATE OR REPLACE VIEW public.v_13_site_deb_sap_report AS

 WITH dias AS (
         SELECT generate_series(timezone('Europe/Budapest'::text, now())::date - '3 days'::interval, timezone('Europe/Budapest'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Budapest'::text, equipment_runtime_shift.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Budapest'::text, equipment_runtime_shift.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            equipment_runtime_shift.ts_value AS shift_start_time,
            equipment_runtime_shift.id_equipment,
            equipment_runtime_shift.cd_shift,
            equipment_runtime_shift.id_shift,
            equipment_runtime_shift.ts_value_production,
            equipment_runtime_shift.ts_value AS tz_value,
                CASE
                    WHEN equipment_runtime_shift.ts_end > now() THEN now()
                    ELSE equipment_runtime_shift.ts_end
                END AS tz_end
           FROM equipment_runtime_shift,
            start_counting_day scd
          WHERE (equipment_runtime_shift.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND equipment_runtime_shift.ts_value_production >= scd.start_day AND equipment_runtime_shift.ts_value < now()
          ORDER BY equipment_runtime_shift.id_equipment, equipment_runtime_shift.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '3 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 29
        ), labels_extract AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), negative_labels AS (
         SELECT l.tz_value,
            l.id_equipment,
            l.label_job,
            l.label_amount,
            po.job_end,
                CASE
                    WHEN po.job_end IS NULL THEN 0::bigint
                    ELSE date_part('epoch'::text, l.tz_value - po.job_end)::bigint
                END AS diff_s
           FROM labels_extract l
             LEFT JOIN prod_orders po ON l.label_job::integer = po.id_order
        ), labels AS (
         SELECT DISTINCT negative_labels.tz_value,
            negative_labels.id_equipment,
            negative_labels.label_job,
            negative_labels.label_amount
           FROM negative_labels
          WHERE negative_labels.diff_s <= 10800
          ORDER BY negative_labels.tz_value
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value <= bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description,
            category_level.id_equipment
           FROM category_level
          ORDER BY category_level.id_equipment, category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = 2 THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'infinity'::double precision) THEN 5
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description AND ee.id_equipment = dc.id_equipment
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '15 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '3 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value <= (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_5) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_5)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_5) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_4 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            timezone('Europe/Budapest'::text, ppf.shift_start_time) AS shift_start_time,
            timezone('Europe/Budapest'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        )
 SELECT shift_report.line,
    shift_report.shift,
    shift_report.shift_hrs,
    shift_report.day,
    shift_report.job,
    shift_report.prss_qty AS gross,
    shift_report.net_sensor AS net,
    shift_report.running_s AS gyartasi_ido,
    shift_report.dt_0 AS beallitasi_ido,
    shift_report.dt_1 AS muszaki_hiba,
    shift_report.dt_2 AS tervezett_karb,
    shift_report.dt_3 AS anyagproblema,
    shift_report.dt_4 AS nem_indokolt_ido,
    shift_report.total_dt_s AS total_dt,
    shift_report.job_sequence AS job_start,
    shift_report.shift_start_time,
    shift_report.shift_number,
    shift_report.id_equipment,
    13 AS id_eterprise
   FROM shift_report
  WHERE shift_report.day >= (timezone('Europe/Budapest'::text, now()) - '2 days'::interval);

-- ---- view: v_13_site_deb_pos_labels ----
CREATE OR REPLACE VIEW public.v_13_site_deb_pos_labels AS

 WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '6 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN ers.ts_end > now() THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '6 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 29
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value < bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = ANY (ARRAY[2, 9]) THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'infinity'::double precision) THEN 5
                    WHEN dc."position" = 7 THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '6 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 6 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_6
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value < (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_4) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_6 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '6 days'::interval)
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM turnos t
             LEFT JOIN labels_data ld ON t.id_equipment = ld.id_equipment AND ld.ts_value >= t.tz_value AND ld.ts_value < t.tz_end
             LEFT JOIN equipments eq ON eq.id_equipment = t.id_equipment
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM final_jobs fj
             LEFT JOIN final_labels fl ON fl.cd_equipment::text = fj.linie::text AND fl.id_order::integer = fj.auftrag AND fl.ts_value_production = fj.tag AND fl.cd_shift::text = fj.shicht::text
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM final_labels fl
             LEFT JOIN final1 f1 ON fl.cd_equipment::text = f1.linie::text AND fl.id_order::integer = f1.auftrag AND fl.ts_value_production = f1.tag AND fl.cd_shift::text = f1.shicht::text
          WHERE fl.sum_labels IS NOT NULL AND f1.id_order IS NULL
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN missing_jobs_labels.cd_shift::text = 'Frühschicht'::text THEN 1
                    WHEN missing_jobs_labels.cd_shift::text = 'Spätschicht'::text THEN 2
                    WHEN missing_jobs_labels.cd_shift::text = 'Nachtschicht'::text THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, (COALESCE(final10.auftrag, 0::bigint))) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, 0::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '5 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.shift_start_time,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.data_type,
    final11.id_order_label,
    13 AS id_enterprise
   FROM final11
  WHERE (final11.linie::text IN ( SELECT equipments.nm_equipment
           FROM equipments
          WHERE equipments.id_site = 29 AND equipments.id_area = 58 AND equipments.tp_equipment = 3));

-- ---- view: v_events ----
CREATE OR REPLACE VIEW public.v_events AS

 SELECT 1 AS event_type,
    ee.ts_event AS ts_timeline,
    ee.ts_event,
    ee.ts_end,
    ee.duration,
    e.id_equipment,
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
  WHERE (ee.duration >= COALESCE(e.stop_threshold_time, 0) OR ee.ts_end IS NULL) AND ee.status <> 6
UNION
 SELECT 2 AS event_type,
    eem.ts_event AS ts_timeline,
    eem.ts_event,
    eem.ts_end,
    date_part('epoch'::text, eem.ts_end - eem.ts_event)::integer AS duration,
    e.id_equipment,
    e.id_enterprise,
    eem.txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_events_man eem
     JOIN equipments e ON eem.id_equipment_event = e.id_equipment
UNION
 SELECT 3 AS event_type,
    ee.ts_event AS ts_timeline,
    ee.ts_event,
    ee.ts_end,
    ee.duration,
    e.id_equipment,
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
  WHERE (ee.duration >= COALESCE(e.stop_threshold_time, 0) OR ee.ts_end IS NULL) AND ee.status <> 6
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
     LEFT JOIN clients c USING (id_client)
  WHERE upper(ee.runtime_timerange) IS NOT NULL
UNION
 SELECT 6 AS event_type,
    ee.ts_value AS ts_timeline,
    ee.ts_value AS ts_event,
    ee.ts_end,
    ee.duration,
    ee.id_equipment,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_runtime_shift ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
  WHERE ee.ts_value < now();

-- ---- view: v_events_2 ----
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
   FROM equipment_runtime_shift ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
  WHERE ee.ts_value < now();

-- ---- view: v_sap_report_data_sync_customer_13_deb ----
CREATE OR REPLACE VIEW public.v_sap_report_data_sync_customer_13_deb AS

 WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '4 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN ers.ts_end > now() THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '4 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 29
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value < bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = ANY (ARRAY[2, 9]) THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'infinity'::double precision) THEN 5
                    WHEN dc."position" = 7 THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '4 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 6 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_6
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value < (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_4) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_6 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '4 days'::interval)
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM turnos t
             LEFT JOIN labels_data ld ON t.id_equipment = ld.id_equipment AND ld.ts_value >= t.tz_value AND ld.ts_value < t.tz_end
             LEFT JOIN equipments eq ON eq.id_equipment = t.id_equipment
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM final_jobs fj
             LEFT JOIN final_labels fl ON fl.cd_equipment::text = fj.linie::text AND fl.id_order::integer = fj.auftrag AND fl.ts_value_production = fj.tag AND fl.cd_shift::text = fj.shicht::text
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM final_labels fl
             LEFT JOIN final1 f1 ON fl.cd_equipment::text = f1.linie::text AND fl.id_order::integer = f1.auftrag AND fl.ts_value_production = f1.tag AND fl.cd_shift::text = f1.shicht::text
          WHERE fl.sum_labels IS NOT NULL AND f1.id_order IS NULL
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN missing_jobs_labels.cd_shift::text = 'Frühschicht'::text THEN 1
                    WHEN missing_jobs_labels.cd_shift::text = 'Spätschicht'::text THEN 2
                    WHEN missing_jobs_labels.cd_shift::text = 'Nachtschicht'::text THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, (COALESCE(final10.auftrag, 0::bigint))) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, 0::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.running_h,
    final11.shift_start_time,
    final11.data_type,
    final11.id_order_label
   FROM final11;

-- ---- view: v_sap_report_data_sync_customer_13 ----
CREATE OR REPLACE VIEW public.v_sap_report_data_sync_customer_13 AS

 WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '4 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN ers.ts_end > now() THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 13)) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 13 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '4 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 13
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 13)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value < bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 13))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = ANY (ARRAY[2, 9]) THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'infinity'::double precision) THEN 5
                    WHEN dc."position" = 7 THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 13
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '4 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 6 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_6
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value < (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_4) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_6 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '4 days'::interval)
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM turnos t
             LEFT JOIN labels_data ld ON t.id_equipment = ld.id_equipment AND ld.ts_value >= t.tz_value AND ld.ts_value < t.tz_end
             LEFT JOIN equipments eq ON eq.id_equipment = t.id_equipment
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM final_jobs fj
             LEFT JOIN final_labels fl ON fl.cd_equipment::text = fj.linie::text AND fl.id_order::integer = fj.auftrag AND fl.ts_value_production = fj.tag AND fl.cd_shift::text = fj.shicht::text
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM final_labels fl
             LEFT JOIN final1 f1 ON fl.cd_equipment::text = f1.linie::text AND fl.id_order::integer = f1.auftrag AND fl.ts_value_production = f1.tag AND fl.cd_shift::text = f1.shicht::text
          WHERE fl.sum_labels IS NOT NULL AND f1.id_order IS NULL
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN missing_jobs_labels.cd_shift::text = 'Frühschicht'::text THEN 1
                    WHEN missing_jobs_labels.cd_shift::text = 'Spätschicht'::text THEN 2
                    WHEN missing_jobs_labels.cd_shift::text = 'Nachtschicht'::text THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, (COALESCE(final10.auftrag, 0::bigint))) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, 0::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.running_h,
    final11.shift_start_time,
    final11.data_type,
    final11.id_order_label
   FROM final11
UNION ALL
 SELECT v_sap_report_data_sync_customer_13_deb.linie,
    v_sap_report_data_sync_customer_13_deb.tag,
    v_sap_report_data_sync_customer_13_deb.shicht,
    v_sap_report_data_sync_customer_13_deb.shicht_nummer,
    v_sap_report_data_sync_customer_13_deb.auftrag,
    v_sap_report_data_sync_customer_13_deb.sum_labels,
    v_sap_report_data_sync_customer_13_deb.rumpfe,
    v_sap_report_data_sync_customer_13_deb.gutmenge,
    v_sap_report_data_sync_customer_13_deb.rustzeit,
    v_sap_report_data_sync_customer_13_deb.produktionszeit,
    v_sap_report_data_sync_customer_13_deb.geplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.ungeplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.matfehler_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.no_order,
    v_sap_report_data_sync_customer_13_deb.auftrag_startzeit,
    v_sap_report_data_sync_customer_13_deb.running_h,
    v_sap_report_data_sync_customer_13_deb.shift_start_time,
    v_sap_report_data_sync_customer_13_deb.data_type,
    v_sap_report_data_sync_customer_13_deb.id_order_label
   FROM v_sap_report_data_sync_customer_13_deb;

-- ---- view: v_sap_report_data_sync_customer_13_b ----
CREATE OR REPLACE VIEW public.v_sap_report_data_sync_customer_13_b AS

 WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '4 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN ers.ts_end > now() THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 13)) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 13 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '4 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 13
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 13)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value < bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 13))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = 2 THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'infinity'::double precision) THEN 5
                    WHEN dc."position" = 7 THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '4 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 6 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_6
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value < (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_5 + ppf.dt_6) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_5 + ppf.dt_6)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_4 + ppf.dt_5) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_6 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '4 days'::interval)
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM turnos t
             LEFT JOIN labels_data ld ON t.id_equipment = ld.id_equipment AND ld.ts_value >= t.tz_value AND ld.ts_value < t.tz_end
             LEFT JOIN equipments eq ON eq.id_equipment = t.id_equipment
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM final_jobs fj
             LEFT JOIN final_labels fl ON fl.cd_equipment::text = fj.linie::text AND fl.id_order::integer = fj.auftrag AND fl.ts_value_production = fj.tag AND fl.cd_shift::text = fj.shicht::text
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM final_labels fl
             LEFT JOIN final1 f1 ON fl.cd_equipment::text = f1.linie::text AND fl.id_order::integer = f1.auftrag AND fl.ts_value_production = f1.tag AND fl.cd_shift::text = f1.shicht::text
          WHERE fl.sum_labels IS NOT NULL AND f1.id_order IS NULL
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN missing_jobs_labels.cd_shift::text = 'Frühschicht'::text THEN 1
                    WHEN missing_jobs_labels.cd_shift::text = 'Spätschicht'::text THEN 2
                    WHEN missing_jobs_labels.cd_shift::text = 'Nachtschicht'::text THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, (COALESCE(final10.auftrag, 0::bigint))) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, 0::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.running_h,
    final11.shift_start_time,
    final11.data_type,
    final11.id_order_label
   FROM final11
UNION ALL
 SELECT v_sap_report_data_sync_customer_13_deb.linie,
    v_sap_report_data_sync_customer_13_deb.tag,
    v_sap_report_data_sync_customer_13_deb.shicht,
    v_sap_report_data_sync_customer_13_deb.shicht_nummer,
    v_sap_report_data_sync_customer_13_deb.auftrag,
    v_sap_report_data_sync_customer_13_deb.sum_labels,
    v_sap_report_data_sync_customer_13_deb.rumpfe,
    v_sap_report_data_sync_customer_13_deb.gutmenge,
    v_sap_report_data_sync_customer_13_deb.rustzeit,
    v_sap_report_data_sync_customer_13_deb.produktionszeit,
    v_sap_report_data_sync_customer_13_deb.geplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.ungeplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.matfehler_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.no_order,
    v_sap_report_data_sync_customer_13_deb.auftrag_startzeit,
    v_sap_report_data_sync_customer_13_deb.running_h,
    v_sap_report_data_sync_customer_13_deb.shift_start_time,
    v_sap_report_data_sync_customer_13_deb.data_type,
    v_sap_report_data_sync_customer_13_deb.id_order_label
   FROM v_sap_report_data_sync_customer_13_deb;

-- ---- view: v_13_site_deb_labels_piot4v_13 ----
CREATE OR REPLACE VIEW public.v_13_site_deb_labels_piot4v_13 AS

 WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '6 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN ers.ts_end > now() THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29 AND (equipments.id_equipment <> ALL (ARRAY[708, 835, 833, 831])))) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '6 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 29
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value < bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = ANY (ARRAY[2, 9]) THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'infinity'::double precision) THEN 5
                    WHEN dc."position" = 7 THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '6 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 6 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_6
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value < (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_4) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_6 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '6 days'::interval)
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM turnos t
             LEFT JOIN labels_data ld ON t.id_equipment = ld.id_equipment AND ld.ts_value >= t.tz_value AND ld.ts_value < t.tz_end
             LEFT JOIN equipments eq ON eq.id_equipment = t.id_equipment
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM final_jobs fj
             LEFT JOIN final_labels fl ON fl.cd_equipment::text = fj.linie::text AND fl.id_order::integer = fj.auftrag AND fl.ts_value_production = fj.tag AND fl.cd_shift::text = fj.shicht::text
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM final_labels fl
             LEFT JOIN final1 f1 ON fl.cd_equipment::text = f1.linie::text AND fl.id_order::integer = f1.auftrag AND fl.ts_value_production = f1.tag AND fl.cd_shift::text = f1.shicht::text
          WHERE fl.sum_labels IS NOT NULL AND f1.id_order IS NULL
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN missing_jobs_labels.cd_shift::text = 'Frühschicht'::text THEN 1
                    WHEN missing_jobs_labels.cd_shift::text = 'Spätschicht'::text THEN 2
                    WHEN missing_jobs_labels.cd_shift::text = 'Nachtschicht'::text THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, (COALESCE(final10.auftrag, 0::bigint))) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, 0::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '5 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.shift_start_time,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.data_type,
    final11.id_order_label,
    13 AS id_enterprise
   FROM final11;

-- ---- view: v_report_downtimes ----
CREATE OR REPLACE VIEW public.v_report_downtimes AS

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
     JOIN equipment_runtime_shift shift ON eventos.id_equipment = shift.id_equipment
     JOIN equipments e ON eventos.id_equipment = e.id_equipment
     JOIN production_orders po ON eventos.id_equipment = po.id_equipment
     JOIN production_orders_runtime por ON po.id_production_order = por.id_production_order
  WHERE eventos.status = 10 AND e.event_should_be_displayed = true AND eventos.ts_event >= lower(shift.ts_range) AND eventos.ts_event <= upper(shift.ts_range) AND eventos.duration >= COALESCE(e.stop_threshold_time, 0) AND por.runtime_timerange @> lower(shift.ts_range);

COMMIT;
