-- t-downtimes-microstops-po-join — the stop→PO lookup set-based instead of per stop.
--
-- public.h_piot_get_downtimes_sector_microstops (behind serving.downtime_by_category, i.e.
-- front4 Downtimes "Downtime Reasons") resolved each stop's PO with TWO correlated scalar
-- subqueries PER STOP into production_orders_runtime (`ee.ts_event <@ runtime_timerange`).
-- Under RLS `<@` is not LEAKPROOF → no GiST index condition → a scan per stop.
-- FIX: MATERIALIZED CTE por_w = the tenant's runtimes that can contain a stop of this call
-- (stops are > _tsstart - 1 month → overlap [bound, ∞)), scanned once; then LEFT JOIN por_w
-- (equipment per sector_view + containment) + LEFT JOIN production_orders by PK.
-- EQUIVALENCE: the (id_equipment, runtime_timerange) EXCLUSION constraint guarantees at most
-- one runtime contains a stop → the LEFT JOIN is row-for-row identical to the scalar subquery
-- (≤1 match, NULL when none). `status` qualified as ee.status (production_orders has one).
-- PARITY: output md5 identical for CPACK month (4,291 rows / 4,148 with PO), day, 2023-03
-- (6,301 / 3,108), sector_view variants, Bispharma month. readapi_ro: 15–19.5 s → 4.5–4.8 s.
-- Rollback: rollback.sql (previous definition verbatim).
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
, por_w AS MATERIALIZED (
  -- runtimes that can contain a stop of this call: stops are > _tsstart - 1 month, so a
  -- containing runtime overlaps [that bound, ∞). Scanned ONCE (not per stop).
  SELECT id_equipment, id_production_order, runtime_timerange FROM production_orders_runtime
   WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = in_id_enterprise)
     AND runtime_timerange && tstzrange((_tsstart::timestamp - interval '1 months')::timestamptz, NULL)
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
		po_w.id_order,
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
		-- PO of the stop: set-based instead of 2 correlated scalar subqueries PER stop. The
		-- (id_equipment, runtime_timerange) exclusion constraint guarantees at most ONE runtime
		-- contains a stop → this LEFT JOIN is row-for-row identical to the old scalar subquery.
		left join por_w on por_w.id_equipment = (case when sector_view then ppeq.id_equipment else ee.id_equipment end)
		               and ee.ts_event <@ por_w.runtime_timerange
		left join production_orders po_w on po_w.id_production_order = por_w.id_production_order
where
		ee.status = 10
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
		po_w.id_order,
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
		-- PO of the stop: set-based instead of 2 correlated scalar subqueries PER stop. The
		-- (id_equipment, runtime_timerange) exclusion constraint guarantees at most ONE runtime
		-- contains a stop → this LEFT JOIN is row-for-row identical to the old scalar subquery.
		left join por_w on por_w.id_equipment = (case when sector_view then ppeq.id_equipment else ee.id_equipment end)
		               and ee.ts_event <@ por_w.runtime_timerange
		left join production_orders po_w on po_w.id_production_order = por_w.id_production_order
where
--		ee.status = 10
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
COMMIT;
