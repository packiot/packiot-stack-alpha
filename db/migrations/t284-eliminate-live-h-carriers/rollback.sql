-- Rollback for t284 — restore the 3 LIVE carrier tables + the original
-- RETURNS SETOF <table> function definitions (exact DDL captured pre-change).
-- Target DB: packiot_analytics (10.10.10.89)

-- 1) recreate the carrier tables first (the SETOF fns reference them as types)
CREATE TABLE public.h_machine_speed (
  id_enterprise integer,
  id_equipment integer,
  nm_equipment character varying,
  info jsonb[]
);

CREATE TABLE public.h_piot_get_downtimes_per_category_equipment_level_new (
  id_enterprise integer,
  duration_microstops bigint,
  duration_total bigint,
  duration_justified bigint,
  duration_planned bigint,
  duration_unplanned bigint,
  available_time bigint,
  downtimes_per_category text[]
);

CREATE TABLE public.h_downtimes_table_with_sector_2 (
  id_equipment_event bigint,
  ts_event timestamp without time zone,
  ts_end timestamp without time zone,
  id_equipment integer,
  id_sector integer,
  nm_equipment character varying,
  sector character varying,
  cd_machine character varying,
  duration integer,
  cd_category character varying,
  txt_category character varying,
  cd_subcategory character varying,
  txt_subcategory character varying,
  txt_downtime_notes character varying,
  id_order integer,
  cd_shift character varying,
  id_shift integer,
  id_enterprise integer,
  planned_downtime boolean,
  change_over boolean,
  shift_ts_range tstzrange,
  stop_threshold_time integer
);

-- 2) drop the RETURNS TABLE variants, restore the original SETOF fns
DROP FUNCTION IF EXISTS serving.machine_speed(integer,text,text,text,text,text,timestamptz,timestamptz,text,text);
CREATE OR REPLACE FUNCTION serving.machine_speed(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text)
 RETURNS SETOF h_machine_speed
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
    ids_sites int[] := (select array_agg(id_site)
                        from sites s
                        where s.id_enterprise = in_id_enterprise
                          and case when cardinality(in_id_sites::int[]) = 0 then true
                                   else id_site = any(in_id_sites::int[]) end);
    ids_areas int[] := (select array_agg(id_area)
                        from areas s
                        where s.id_enterprise = in_id_enterprise
                          and case when cardinality(in_id_areas::int[]) = 0 then true
                                   else id_area = any(in_id_areas::int[]) end);
    ids_equips int[] := (select array_agg(id_equipment)
                         from equipments s
                         where s.id_enterprise = in_id_enterprise
                           and s.tp_equipment = 3
                           and case when cardinality(in_id_equipments::int[]) = 0 then true
                                    else id_equipment = any(in_id_equipments::int[]) end);
    ids_shifts int[] := (
        select array_agg(id_shift) from shifts s
        where s.id_enterprise = in_id_enterprise
          and case
                when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
                when left(in_id_shifts, 1) != '{' then cd_shift = any(string_to_array(in_id_shifts, ',')::varchar[])
                else case
                        when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
                        then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
                        else true
                     end
              end);
    ids_teams int[] := (select array_agg(id_team)
                        from teams s
                        where s.id_enterprise = in_id_enterprise
                          and case when cardinality(in_id_teams::int[]) = 0 then true
                                   else id_team = any(in_id_teams::int[]) end);
begin
IF UPPER(time_grain) = 'HOUR' THEN
    RETURN QUERY
    select
        id_enterprise, id_equipment, nm_equipment,
        array_agg(jsonb_build_object(
            'info_per_period', info_per_period,
            'info_per_shift_or_team', info_per_shift,
            'ts_value', ts_value_production
        ) order by ts_value_production) as info
    from (
        select
            case when date_trunc('hour', now()) = ts_value then now() else ts_value end as ts_value_production,
            id_enterprise, id_equipment, nm_equipment,
            jsonb_build_object(
                'net',    sum(coalesce(net, 0))::float8,
                'gross',  sum(coalesce(gross, 0))::float8,
                'scrap',  sum(coalesce(scrap, 0))::float8,
                'target', sum(coalesce(target, 0))::int8,
                'speed',  case when sum(cnt_speed) > 0 then sum(sum_speed) / sum(cnt_speed) end,
                'speed_target', avg(ideal_speed)
            ) as info_per_period,
            array_agg(obj order by coalesce(shift_position, team_position)) as info_per_shift
        from (
            select
                case when date_trunc('hour', now()) = ers.ts_value then now() else ers.ts_value end::timestamptz as ts_value,
                ers.id_enterprise, e.id_equipment, e.nm_equipment,
                case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
                case group_by_element when 'TEAMS'  then t.sequence_position end as team_position,
                sum(coalesce(ers.net_production_incr, 0))   net,
                sum(coalesce(ers.gross_production_incr, 0)) gross,
                sum(coalesce(ers.scrap_incr, 0))            scrap,
                avg(coalesce(pt.vl_hour, 0))                target,
                sum(ers.sum_speed)                          sum_speed,
                sum(ers.cnt_speed)                          cnt_speed,
                avg(coalesce(ers.ideal_production_speed, e.production_speed, 0)) as ideal_speed,
                jsonb_build_object(
                    'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift end,
                    'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift end,
                    'cd_team',  case group_by_element when 'TEAMS'  then t.cd_team end,
                    'id_team',  case group_by_element when 'TEAMS'  then t.id_team end,
                    'net',   sum(coalesce(ers.net_production_incr, 0)),
                    'gross', sum(coalesce(ers.gross_production_incr, 0)),
                    'scrap', sum(coalesce(ers.scrap_incr, 0)),
                    'scrap_percentage', sum(coalesce(ers.scrap_incr, 0)) / nullif(sum(coalesce(ers.gross_production_incr, 0)), 0),
                    'scrap_target', avg(st.vl_shift),
                    'target', avg(coalesce(pt.vl_hour, 0)),
                    'speed', case when sum(ers.cnt_speed) > 0 then sum(ers.sum_speed) / sum(ers.cnt_speed) end,
                    'speed_target', avg(coalesce(ers.ideal_production_speed, e.production_speed, 0))
                ) obj
            from
                silver.equipment_categorical_1hour ers
                left join production_targets pt using (id_equipment)
                left join equipments e using (id_equipment)
                left join shifts s using (id_shift)
                left join teams t using (id_team)
                left join scrap_targets st on (ers.id_equipment = st.id_equipment)
            where
                ers.ts_value >= date_trunc('hour', in_begin_time)
                and ers.ts_value < in_end_time
                and ers.id_enterprise = in_id_enterprise
                and ers.id_area = any(ids_areas)
                and ers.id_site = any(ids_sites)
                and ers.id_equipment = any(ids_equips)
                and ers.id_shift = any(ids_shifts)
            group by
                ers.id_enterprise, ers.ts_value, e.id_equipment, e.nm_equipment,
                case group_by_element when 'SHIFTS' then ers.id_shift else null end,
                case group_by_element when 'SHIFTS' then s.cd_shift else null end,
                case group_by_element when 'SHIFTS' then s.sequence_position else null end,
                case group_by_element when 'TEAMS' then t.sequence_position else null end,
                t.id_team, t.cd_team
        ) aa
        group by ts_value, id_enterprise, id_equipment, nm_equipment order by ts_value
    ) s0
    group by id_enterprise, id_equipment, nm_equipment;

ELSE  -- DAY grain (canonical equipment_oee_shift; unchanged source, clean window)
    RETURN QUERY
    select
        id_enterprise, id_equipment, nm_equipment,
        array_agg(jsonb_build_object(
            'info_per_period', info_per_period,
            'info_per_shift_or_team', info_per_shift,
            'ts_value', ts_value_production
        ) order by ts_value_production) as info
    from (
        select
            case when date_trunc('day', now()) = date_trunc('day', ts_value_production) then now() else ts_value_production end as ts_value_production,
            id_enterprise, id_equipment, nm_equipment,
            jsonb_build_object(
                'net',    sum(coalesce(net, 0))::float8,
                'gross',  sum(coalesce(gross, 0))::float8,
                'scrap',  sum(coalesce(scrap, 0))::float8,
                'target', sum(coalesce(target, 0))::int8,
                'speed',  avg(speed),
                'speed_target', avg(ideal_speed)
            ) as info_per_period,
            array_agg(obj order by coalesce(shift_position, team_position)) as info_per_shift
        from (
            select
                date_trunc('day', ers.ts_value_production)::timestamptz as ts_value_production,
                e.id_enterprise, e.id_equipment, e.nm_equipment,
                case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
                case group_by_element when 'TEAMS'  then t.sequence_position end as team_position,
                sum(coalesce(ers.net, 0))    net,
                sum(coalesce(ers.gross, 0))  gross,
                sum(coalesce(ers.scrap, 0))  scrap,
                sum(coalesce(ers.target, 0))::int8 target,
                avg(ers.speed) as speed,
                avg(coalesce(ers.ideal_speed, e.production_speed, 0)) as ideal_speed,
                jsonb_build_object(
                    'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift end,
                    'cd_shift', case group_by_element when 'SHIFTS' then ers.cd_shift end,
                    'cd_team',  case group_by_element when 'TEAMS'  then t.cd_team end,
                    'id_team',  case group_by_element when 'TEAMS'  then t.id_team end,
                    'net',   sum(coalesce(ers.net, 0)),
                    'gross', sum(coalesce(ers.gross, 0)),
                    'scrap', sum(coalesce(ers.scrap, 0)),
                    'scrap_percentage', sum(coalesce(ers.scrap, 0)) / nullif(sum(coalesce(ers.gross, 0)), 0),
                    'scrap_target', avg(st.vl_shift),
                    'target', sum(coalesce(ers.target, 0)),
                    'speed', avg(coalesce(ers.speed, 0)),
                    'speed_target', avg(coalesce(ers.ideal_speed, e.production_speed, 0))
                ) obj
            from
                equipment_oee_shift ers
                join equipments e using (id_equipment)
                join shifts s using (id_shift)
                left join teams t using (id_team)
                left join scrap_targets st on (ers.id_equipment = st.id_equipment)
            where
                ers.ts_value >= date_trunc('day', in_begin_time)
                and ers.ts_value < in_end_time
                and e.id_enterprise = in_id_enterprise
                and e.id_area = any(ids_areas)
                and e.id_site = any(ids_sites)
                and e.id_equipment = any(ids_equips)
                and ers.id_shift = any(ids_shifts)
                and (ers.id_team is null or ers.id_team = any(ids_teams))
            group by
                e.id_enterprise, e.id_equipment, e.nm_equipment,
                date_trunc('day', ers.ts_value_production),
                case group_by_element when 'SHIFTS' then ers.id_shift else null end,
                case group_by_element when 'SHIFTS' then ers.cd_shift else null end,
                case group_by_element when 'SHIFTS' then s.sequence_position else null end,
                case group_by_element when 'TEAMS' then t.id_team else null end,
                case group_by_element when 'TEAMS' then t.cd_team else null end,
                case group_by_element when 'TEAMS' then t.sequence_position else null end
        ) aa
        group by ts_value_production, id_enterprise, id_equipment, nm_equipment order by ts_value_production
    ) s0
    group by id_enterprise, id_equipment, nm_equipment;

END IF;
end
$function$


---STATUS:Success---
;

DROP FUNCTION IF EXISTS public.h_piot_get_downtimes_per_category_equipment_level_new_4(integer,text,text,text,text,timestamp,timestamp,text);
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
		aa.id_enterprise,
		duration_microstops::int8,
		duration_total::int8,
		duration_justified::int8,
		duration_planned::int8,
		duration_unplanned::int8,
	    shs.available_time::int8,
		downtimes_per_category::text[]
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
	join equipment_oee_shift ers 
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
		from equipment_oee_shift ers 
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


---STATUS:Success---
;

DROP FUNCTION IF EXISTS public.h_piot_get_downtimes_sector_microstops(integer,text,text,text,text,timestamp,timestamp,boolean,boolean);
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
		left join equipment_oee_shift ers on
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


---STATUS:Success---
;

