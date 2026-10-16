-- Scrap-spike guard per MEASURE (2026-09-29 clamp audit). Replaces t-scrap-spike-guard's
-- row-drop: impossible scrap no longer removes the hour/shift's real gross/net.
-- Generated from the live definition; see the in-body comments for the bounds.
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
	-- HOUR branches: production-day bounds are DAY-truncated with an INCLUSIVE end, like the DAY
	-- grain. front4 sends naive local windows ('2026-09-24 00:00' .. '2026-09-24 23:59'); for those
	-- this equals the original hour-truncated form exactly, and it also keeps a start that is not
	-- at midnight (or a UTC-instant caller, 03:00Z) on the correct production day.
	min_ts_prod timestamptz := (select case UPPER(time_grain)
									when 'HOUR' then
										(select min(ts_value + interval '0') from silver.equipment_categorical_1hour ev
											where (ev.ts_value_production >= date_trunc('day', in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc('day', in_begin_time::timestamptz))::date - 1 
											and ev.ts_value_production <= date_trunc('day', in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc('day', in_end_time::timestamptz))::date + 1) 
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
										where (ev.ts_value_production >= date_trunc('day', in_begin_time::timestamptz) and ev.ts_value_production >= (date_trunc('day', in_begin_time::timestamptz))::date - 1 
										and ev.ts_value_production <= date_trunc('day', in_end_time::timestamptz) and ev.ts_value_production <= (date_trunc('day', in_end_time::timestamptz))::date + 1) 
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
	-- read-api lowercases enum filters ('shifts'); every comparison below is against the
	-- upper-case literals legacy callers sent ('SHIFTS'/'TEAMS') → normalize once, here.
	group_by_element := upper(group_by_element);
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
			-- Scrap-spike guard, per MEASURE (2026-09-29): an hour whose scrap exceeds ~150% of
			-- the line's max hourly output (production_speed units/min x 60) has an impossible
			-- scrap reading → only the SCRAP is excluded (NULL). The previous guard dropped the
			-- whole hour, so real gross/net vanished with it (L5 2026-09-23..25: 37 hours,
			-- 206k gross / 149k net missing). gross/net are deliberately NOT bounded by
			-- production_speed: configured speeds are often too low (IDEAL_SPEED_TOO_LOW) and
			-- such a bound removed real production in testing (ent5 Sept −10.6% net).
			-- gross/net get only a PHYSICAL bound: 20x configured speed over the whole
			-- time (worst config error seen ~6x, e.g. FLEXO rated 100 runs 300-600/min;
			-- replayed-legacy artifacts sit at >=26x, up to 2000x). Data: 2026-09-29 audit.
			(select h.ts_value, h.id_equipment, h.id_enterprise, h.id_site, h.id_area, h.id_shift, h.id_team, h.ts_value_production,
			        case when h.net_production_incr > 1000 and h.net_production_incr::float8 > coalesce(q.production_speed,0)::float8 * 60.0 * 20 then null else h.net_production_incr end net_production_incr,
			        case when h.gross_production_incr > 1000 and h.gross_production_incr::float8 > coalesce(q.production_speed,0)::float8 * 60.0 * 20 then null else h.gross_production_incr end gross_production_incr,
			        case when h.scrap_incr > 1000 and h.scrap_incr::float8 > coalesce(q.production_speed,0)::float8 * 60.0 * 1.5 then null else h.scrap_incr end scrap_incr
			   from silver.equipment_categorical_1hour h join equipments q on q.id_equipment = h.id_equipment) ers
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
			-- Scrap-spike guard, per MEASURE (2026-09-29), see the HOUR branch:
			-- scrap bound = production_speed x available_time x 1.5 (as before, scrap only);
			-- gross/net bound = production_speed x (available+planned) x 20 — physically
			-- impossible even with a mis-set speed; shifts with no time fields are left alone.
			(select o.id_equipment, o.id_shift, o.cd_shift, o.id_team, o.ts_value, o.ts_value_production, o.target, o.available_time,
			        case when (coalesce(o.available_time,0)+coalesce(o.planned_downtime,0)) > 0 and o.net > 1000 and o.net::float8 > coalesce(q.production_speed,0)::float8 * ((coalesce(o.available_time,0)+coalesce(o.planned_downtime,0))/60.0) * 20 then null else o.net end net,
			        case when (coalesce(o.available_time,0)+coalesce(o.planned_downtime,0)) > 0 and o.gross > 1000 and o.gross::float8 > coalesce(q.production_speed,0)::float8 * ((coalesce(o.available_time,0)+coalesce(o.planned_downtime,0))/60.0) * 20 then null else o.gross end gross,
			        case when o.available_time > 0 and o.scrap > 1000 and o.scrap::float8 > coalesce(q.production_speed,0)::float8 * (o.available_time/60.0) * 1.5 then null else o.scrap end scrap
			   from equipment_oee_shift o join equipments q on q.id_equipment = o.id_equipment) ers
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
$function$;
