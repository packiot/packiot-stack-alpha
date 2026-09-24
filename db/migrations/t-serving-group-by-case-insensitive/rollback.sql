-- rollback: the five functions before t-serving-group-by-case-insensitive (verbatim, i.e. as left
-- by t-serving-lookups-leakproof-hour-fix).
BEGIN;
CREATE OR REPLACE FUNCTION serving.total_production_by_team(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, partitionby text, time_grain text DEFAULT 'DAY'::text)
 RETURNS SETOF total_production_by_team_row
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	-- Planner notes for the lookups below (they run under RLS as readapi_ro):
	--  * each `ev.ts_value_production <op> <timestamp expr>` has a date-typed twin: date-vs-
	--    timestamp(tz) operators are not LEAKPROOF, so under RLS only the date-vs-date twin can be an
	--    index condition (idx_*_equipment_prod_day). The original predicate still decides the rows.
	--  * `min/max(ts_value + interval '0')` is min/max(ts_value) that the planner can't rewrite into
	--    "first row of ts_value_idx": that walk scanned ~100k+ shift rows filtering by tenant/day.
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
		-- Production-day bounds. HOUR is day-truncated with an INCLUSIVE end, like the DAY grain: the
	-- hours of the same production days the DAY grain shows. front4 sends naive local windows
	-- ('D 00:00' .. 'D 23:59') → production day D; a UTC-instant start (03:00Z) also lands on D.
	prod_day_grain text := case when upper(time_grain) = 'HOUR' then 'day' else time_grain::text end;
	min_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then min(ts_value + interval '0') else min(ts_value_production) end from equipment_oee_hourly ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(prod_day_grain, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(prod_day_grain, in_begin_time::timestamptz))::date - 1 
								and ev.ts_value_production < date_trunc(prod_day_grain, in_end_time::timestamptz) + case when upper(time_grain) = 'HOUR' then interval '1 day' else interval '0' end and ev.ts_value_production <= (date_trunc(prod_day_grain, in_end_time::timestamptz))::date + 1) 
								and ev.id_equipment = any( ids_equips )
								and e.id_area = any( ids_areas )
								and e.id_site = any( ids_sites )
								);
	max_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then max(ts_value + interval '0') else max(ts_value_production) end from equipment_oee_hourly ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(prod_day_grain, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(prod_day_grain, in_begin_time::timestamptz))::date - 1 
								and ev.ts_value_production <= date_trunc(prod_day_grain, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(prod_day_grain, in_end_time::timestamptz))::date + 1) 
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
$function$;

CREATE OR REPLACE FUNCTION serving.single_period_by_team_v4(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text)
 RETURNS SETOF single_period_by_team_v4_row
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	-- Planner notes for the lookups below (they run under RLS as readapi_ro):
	--  * each `ev.ts_value_production <op> <timestamp expr>` has a date-typed twin: date-vs-
	--    timestamp(tz) operators are not LEAKPROOF, so under RLS only the date-vs-date twin can be an
	--    index condition (idx_*_equipment_prod_day). The original predicate still decides the rows.
	--  * `min/max(ts_value + interval '0')` is min/max(ts_value) that the planner can't rewrite into
	--    "first row of ts_value_idx": that walk scanned ~100k+ shift rows filtering by tenant/day.
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
										(select min(ts_value + interval '0') from silver.equipment_categorical_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value + interval '0') from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz))::date + 1 )
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
										(select max(ts_value + interval '0') from silver.equipment_categorical_1hour ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
										and ev.id_enterprise = in_id_enterprise
										and ev.id_area = any( ids_areas)
										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ))
								else (select case when max(ts_value + interval '0')>now() then now() else max(ts_value + interval '0') end from equipment_oee_shift ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
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
			silver.equipment_categorical_1hour ers
			join production_targets pt using (id_enterprise, id_equipment)
			join enterprises e using (id_enterprise)
			join equipments eq_g on eq_g.id_equipment = ers.id_equipment
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
			-- scrap-spike guard (live branch): drop hours whose scrap exceeds ~150% of
			-- the line's max hourly output (production_speed units/min x 60) — impossible
			-- = a counter/sensor artifact. Mirrors the historical-branch guard.
			and not (coalesce(ers.scrap_incr,0) > 1000
			         and coalesce(ers.scrap_incr,0)::float8 > coalesce(eq_g.production_speed,0)::float8 * 60.0 * 1.5)
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
			-- scrap-spike guard (#3): drop shifts whose scrap exceeds ~150% of the line's
			-- max possible output (production_speed units/min x available_time min) — a
			-- physically-impossible value = a counter/sensor artifact (e.g. L5 Aug 2026).
			and not (coalesce(ers.available_time,0) > 0
			         and coalesce(ers.scrap,0) > 1000
			         and coalesce(ers.scrap,0)::float8 > coalesce(e.production_speed,0)::float8 * (ers.available_time/60.0) * 1.5) 
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
$function$;

CREATE OR REPLACE FUNCTION serving.single_period_by_team(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text)
 RETURNS SETOF single_period_by_team_row
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	-- Planner notes for the lookups below (they run under RLS as readapi_ro):
	--  * each `ev.ts_value_production <op> <timestamp expr>` has a date-typed twin: date-vs-
	--    timestamp(tz) operators are not LEAKPROOF, so under RLS only the date-vs-date twin can be an
	--    index condition (idx_*_equipment_prod_day). The original predicate still decides the rows.
	--  * `min/max(ts_value + interval '0')` is min/max(ts_value) that the planner can't rewrite into
	--    "first row of ts_value_idx": that walk scanned ~100k+ shift rows filtering by tenant/day.
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
										(select min(ts_value + interval '0') from silver.equipment_categorical_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value + interval '0') from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz))::date + 1 )
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
										(select max(ts_value + interval '0') from silver.equipment_categorical_1hour ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
										and ev.id_enterprise = in_id_enterprise
										and ev.id_area = any( ids_areas)
										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ))
								else (select case when max(ts_value + interval '0')>now() then now() else max(ts_value + interval '0') end from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
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
				silver.equipment_categorical_1hour ers
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
$function$;

CREATE OR REPLACE FUNCTION serving.targets(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, group_by_element text DEFAULT 'DAY'::text)
 RETURNS SETOF targets_row
 LANGUAGE plpgsql
 STABLE
AS $function$
declare 
	-- Planner notes for the lookups below (they run under RLS as readapi_ro):
	--  * each `ev.ts_value_production <op> <timestamp expr>` has a date-typed twin: date-vs-
	--    timestamp(tz) operators are not LEAKPROOF, so under RLS only the date-vs-date twin can be an
	--    index condition (idx_*_equipment_prod_day). The original predicate still decides the rows.
	--  * `min/max(ts_value + interval '0')` is min/max(ts_value) that the planner can't rewrite into
	--    "first row of ts_value_idx": that walk scanned ~100k+ shift rows filtering by tenant/day.
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
										(select min(ts_value + interval '0') from silver.equipment_categorical_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value + interval '0') from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz))::date + 1 )
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
										select max(ts_value + interval '0') 
--										from silver.equipment_categorical_1hour ev
										from equipment_oee_hourly ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
--										and ev.id_enterprise = in_id_enterprise
--										and ev.id_area = any( ids_areas)
--										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
--										and ev.id_shift = any( ids_shifts )
										)
								else (
									select 
										max(ts_value + interval '0')
									from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
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
								left join silver.equipment_categorical_1hour ers using (id_equipment, ts_value)
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
$function$;

CREATE OR REPLACE FUNCTION serving.machine_speed(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text)
 RETURNS TABLE(id_enterprise integer, id_equipment integer, nm_equipment character varying, info jsonb[])
 LANGUAGE plpgsql
 STABLE
AS $function$
#variable_conflict use_column
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
$function$;
COMMIT;
