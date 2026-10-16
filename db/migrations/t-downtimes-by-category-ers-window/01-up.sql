-- t-downtimes-by-category-ers-window — front4 Downtimes "This Month" for CPACK never loaded.
--
-- CHAIN (2026-09-24): read-api `downtimes-per-category` → 500 at its 40 s timeout.
-- serving.downtime_by_category(CPACK, month): 1.9 s as superuser, 61 s as readapi_ro.
--   (1) RLS policies evaluated per row → fixed in t-rls-initplan-policies (61 s → ~15 s).
--   (2) THIS: under RLS the planner may not use a NON-LEAKPROOF operator as an index
--       condition, and range `<@` / `&&` are not leakproof → the shift join
--       `ee.ts_event <@ ers.ts_range` could not use the (id_equipment, ts_range) GiST index
--       and hashed EVERY shift row of the tenant since 2020 (23.7 M join-filter rows).
--       Fix: a MATERIALIZED CTE fetches the shift rows the joins can possibly match ONCE,
--       with leakproof filters only (id_equipment IN tenant, ts_value > implied bound — served
--       by idx_ers_equipment). Join predicates are UNCHANGED. The bounds are implied:
--       events are restricted to ts_event > _tsstart - 1 month and a shift containing an event
--       starts < 1 day before it (max shift length verified = 1 day); by_category's window
--       overlap implies ts_value in (_tsstart - 1 day, _tsend).
-- PARITY: output md5 IDENTICAL to the previous functions for CPACK month/week/day/2023-03
-- and Bispharma month. Rollback: rollback.sql (previous definitions verbatim).
BEGIN;
CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_sector_microstops(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), sector_view boolean DEFAULT false, microstops_view boolean DEFAULT false)
 RETURNS TABLE(id_equipment_event bigint, ts_event timestamp without time zone, ts_end timestamp without time zone, id_equipment integer, id_sector integer, nm_equipment character varying, sector character varying, cd_machine character varying, duration integer, cd_category character varying, txt_category character varying, cd_subcategory character varying, txt_subcategory character varying, txt_downtime_notes character varying, id_order integer, cd_shift character varying, id_shift integer, id_enterprise integer, planned_downtime boolean, change_over boolean, shift_ts_range tstzrange, stop_threshold_time integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
#variable_conflict use_column
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
	min_ts_prod timestamp := (select min(ts_value) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamp := (select max(ts_end) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);

begin
return query
-- Shift rows the joins can possibly match, fetched ONCE with leakproof filters (served by
-- idx_ers_equipment under RLS): events are restricted to ts_event > _tsstart - 1 month and a
-- shift containing an event starts < 1 day before it (max shift length verified: 1 day).
-- Without this, `ee.ts_event <@ ers.ts_range` (non-LEAKPROOF → no GiST index under RLS) made
-- the planner hash EVERY shift row of the tenant since 2020 (23.7 M join-filter rows).
WITH ers_w AS MATERIALIZED (
  SELECT * FROM equipment_oee_shift
   WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = in_id_enterprise)
     AND ts_value > (_tsstart::timestamp - interval '1 months' - interval '1 day')
)

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
		left join ers_w ers on
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
		left join ers_w ers on
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


end $function$;
CREATE OR REPLACE FUNCTION serving.downtime_by_category(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
 RETURNS SETOF downtime_by_category_row
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
-- same pattern: the window's shift rows once (overlap with [_tsstart,_tsend) ⇒ starts in
-- (_tsstart - 1 day, _tsend)), leakproof filters only.
WITH ers_w AS MATERIALIZED (
  SELECT * FROM equipment_oee_shift
   WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = in_id_enterprise)
     AND ts_value > (_tsstart - interval '1 day') AND ts_value < _tsend
) 	
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
	join ers_w ers 
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
$function$;
COMMIT;
