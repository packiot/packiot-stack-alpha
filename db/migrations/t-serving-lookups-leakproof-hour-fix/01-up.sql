-- t-serving-lookups-leakproof-hour-fix — the min/max "window lookup" in six serving functions
-- + total-production HOUR grain (500 → correct).
--
-- A. PERF (serving.total_production_by_team, single_period_by_team[_v4], production_flow, targets,
--    events_timeline_full). Each starts with DECLARE lookups like
--      min_ts_prod := (select min(ts_value) from equipment_oee_shift ev
--                      where ev.ts_value_production >= date_trunc(grain, in_begin_time::timestamptz) ...)
--    that took 80–200 ms EACH as readapi_ro. Two stacked causes:
--    1. ts_value_production is DATE; the bound is timestamptz/timestamp → cross-type operators
--       (date_ge_timestamptz …) are NOT LEAKPROOF → under RLS they can't be index conditions, so the
--       (id_equipment, ts_value_production) index was used on id_equipment only and ~107k rows were
--       filtered. FIX: a redundant date-typed twin next to each predicate
--         ev.ts_value_production >= (E)::date - 1      /   <= (E)::date + 1
--       IMPLIED by the original (which stays and still decides the rows) → identical results, and
--       date-vs-date IS leakproof → index condition.
--    2. Once the twin made the estimate small, the planner rewrote min()/max(ts_value) as "first row
--       of equipment_oee_shift_ts_value_idx" (MinMaxAgg) and walked the index — SLOWER than before.
--       FIX: min/max(ts_value + interval '0') — same value, no index matches the expression, so the
--       rewrite can't apply. Commented in each function.
--    New index gold.equipment_oee_hourly (id_equipment, ts_value_production) (the shift table's twin
--    index came with t-downtimes-category-leakproof-bounds; IF NOT EXISTS here too, order-safe).
--    PROOF: md5 of full outputs orig vs new identical on 340 cases (6 fns × day/week/month/hour ×
--    none/shifts/teams × CPACK+Bispharma × 4 windows); interleaved timing as readapi_ro, e.g.
--    single-period 254–344 → 23–25 ms, production-flow 778–822 → 63–68 ms, targets day 869–920 →
--    49–112 ms, total-production day 446–451 → 151–203 ms.
--
-- B. BUG: read-api `total-production` time_grain=hour → HTTP 500 since the analytics cutover:
--    its HOUR branch calls public.piot_get_shift_hour_by_equipment_fixed, which existed only in the
--    legacy packiot DB (both legacy h_piot_total_production_teams[_2] call it). Ported VERBATIM.
--    With the 500 gone the HOUR result was still wrong: read-api sends UTC instants (local midnight =
--    03:00Z) and `ts_value_production (date) >= date_trunc('hour', 03:00Z)` excluded the first day,
--    while the max lookup's `<=` pulled in the next → "today" returned 24 EMPTY future hours. HOUR
--    now uses day-truncated production-day bounds with an exclusive end (DAY/WEEK/MONTH untouched,
--    md5-identical). Verified: 24 hourly rows per production day, sum == gold.equipment_oee_hourly
--    net for that day (today/yesterday/09-11: 596,928 / 843,391 / 753,083 exact).
--
-- Indexes: applied live with CREATE INDEX CONCURRENTLY; plain IF NOT EXISTS here (runner is
-- transactional) — a no-op where they exist.
CREATE INDEX IF NOT EXISTS idx_ers_equipment_prod_day
  ON gold.equipment_oee_shift (id_equipment, ts_value_production);
CREATE INDEX IF NOT EXISTS idx_er1h_equipment_prod_day
  ON gold.equipment_oee_hourly (id_equipment, ts_value_production);

BEGIN;
-- B: ported verbatim from legacy packiot (pg_get_functiondef, 2026-09-24)
CREATE OR REPLACE FUNCTION public.piot_get_shift_hour_by_equipment_fixed(in_id_enterprise integer, in_id_equip integer, ts_value timestamp with time zone)
 RETURNS SETOF shift_hours
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	in_id_site int := (select id_site from equipments s where s.id_equipment=in_id_equip );
	in_id_area int := (select id_area from equipments s where s.id_equipment=in_id_equip );
begin
return query
	with sh_data as (
		select distinct
			sh.*, s.id_site as site_used_in_timezone
		from
			shift_hours sh
		join sites s on (
							s.id_enterprise = in_id_enterprise
							and
								case when sh.id_site is not null then s.id_site = in_id_site else true end
							and 
								case when sh.id_area is not null then sh.id_area = in_id_area else true end
							and 
								case when sh.id_equipment is not null then sh.id_equipment = in_id_equip else true end
			)
		where
			sh.id_enterprise = in_id_enterprise
			and begin_time <= (select extract(epoch from (ts_value-date_trunc('week', ts_value at time zone s.timezone - interval '1 second' * s.week_begin ) at time zone s.timezone ))-(s.week_begin))
			and end_time 	> (select extract(epoch from (ts_value-date_trunc('week', ts_value at time zone s.timezone - interval '1 second' * s.week_begin ) at time zone s.timezone ))-(s.week_begin))
	)
	select 
		id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment, duration
	from 
		sh_data
	where 
		case
			when exists (select * from sh_data where id_equipment = in_id_equip) then id_equipment = in_id_equip
			when exists (select * from sh_data where id_area = in_id_area) then id_area = in_id_area
			else coalesce(id_site, site_used_in_timezone ) = in_id_site
		end;
end $function$;

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
		-- Production-day bounds. HOUR is day-truncated like DAY: read-api sends UTC instants (local
	-- midnight = 03:00Z), and `ts_value_production (date) >= date_trunc('hour', 03:00Z)` dropped the
	-- first day → "today" returned tomorrow's (empty) hours. Now: the hours of the same production
	-- days the DAY grain shows.
	prod_day_grain text := case when upper(time_grain) = 'HOUR' then 'day' else time_grain::text end;
	min_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then min(ts_value + interval '0') else min(ts_value_production) end from equipment_oee_hourly ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(prod_day_grain, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(prod_day_grain, in_begin_time::timestamptz))::date - 1 
								and ev.ts_value_production < date_trunc(prod_day_grain, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(prod_day_grain, in_end_time::timestamptz))::date + 1) 
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
								-- HOUR: end is exclusive (read-api `to` = next local midnight − 1 s → that day's
								-- production date must not be included), matching the min lookup's `<`.
								and (upper(time_grain) <> 'HOUR' or ev.ts_value_production < date_trunc('day', in_end_time::timestamptz))
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

CREATE OR REPLACE FUNCTION serving.production_flow(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text)
 RETURNS SETOF production_flow_row
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
	ids_teams int[] := 	(select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end
						 );
	min_ts_prod timestamptz := (select min(ts_value + interval '0') from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
										and ev.ts_value_production <= date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz))::date + 1 )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ) 
								);
	max_ts_prod timestamptz := (select case when max(ts_value + interval '0')>now() then now() else max(ts_value + interval '0') end from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc(time_grain::text, in_begin_time::timestamptz))::date - 1 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc(time_grain::text, in_end_time::timestamptz))::date + 1) 
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
$function$;

CREATE OR REPLACE FUNCTION serving.events_timeline_full(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_event_types text, _id_production_order integer DEFAULT NULL::integer, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now())
 RETURNS SETOF events_timeline_full_row
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
	min_ts_prod timestamptz := (select min(ts_value + interval '0') from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) and ev.ts_value_production >= (date_trunc('day', _tsstart::timestamp))::date - 1 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp) and ev.ts_value_production <= (date_trunc('day', _tsend::timestamp))::date + 1) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_end) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) and ev.ts_value_production >= (date_trunc('day', _tsstart::timestamp))::date - 1 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp) and ev.ts_value_production <= (date_trunc('day', _tsend::timestamp))::date + 1) 
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
end $function$;

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
COMMIT;
