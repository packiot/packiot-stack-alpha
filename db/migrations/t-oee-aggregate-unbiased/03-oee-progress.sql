-- serving.oee_progress: per-bucket avg() of shift ratios -> ratios of sums (3 branches).
-- avg() weighted a planned-stop or not-yet-started shift (gold pre-creates rows at OEE 0)
-- like a full production shift: e.g. CPACK HOTMADAG daily 0.71 served vs 0.93 real
-- (its working shifts run 0.84-0.99). Same definition as serving.oee_score(_by_team).
CREATE OR REPLACE FUNCTION serving.oee_progress(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false, is_team_filtered boolean DEFAULT false)
 RETURNS SETOF oee_progress_row
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
				ts_value_production, ent.id_enterprise, s.id_site as id_entity, ent.nm_site as nm_entity, oee, oee_p, oee_a, oee_q, s.net, s.gross, s.running_time, s.available_time, s.ideal_production,
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
						sum(net::float8)/nullif(sum(ideal_production),0) oee, sum(gross::float8)*sum(available_time)/nullif(sum(ideal_production)*sum(running_time),0) oee_p, sum(running_time)::float8/nullif(sum(available_time),0) oee_a, sum(net::float8)/nullif(sum(gross::float8),0) oee_q  -- ratios of sums (2026-09-29), not avg of shift ratios
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
				ts_value_production, ent.id_enterprise, s.id_area as id_entity, ent.nm_area as nm_entity, oee, oee_p, oee_a, oee_q, s.net, s.gross, s.running_time, s.available_time, s.ideal_production,
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
						sum(net::float8)/nullif(sum(ideal_production),0) oee, sum(gross::float8)*sum(available_time)/nullif(sum(ideal_production)*sum(running_time),0) oee_p, sum(running_time)::float8/nullif(sum(available_time),0) oee_a, sum(net::float8)/nullif(sum(gross::float8),0) oee_q  -- ratios of sums (2026-09-29), not avg of shift ratios
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
				ts_value_production, ent.id_enterprise, s.id_equipment as id_entity, ent.nm_equipment as nm_entity, oee, oee_p, oee_a, oee_q, s.net, s.gross, s.running_time, s.available_time, s.ideal_production,
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
						sum(net::float8)/nullif(sum(ideal_production),0) oee, sum(gross::float8)*sum(available_time)/nullif(sum(ideal_production)*sum(running_time),0) oee_p, sum(running_time)::float8/nullif(sum(available_time),0) oee_a, sum(net::float8)/nullif(sum(gross::float8),0) oee_q  -- ratios of sums (2026-09-29), not avg of shift ratios
					from basic_data
					group by ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position
				)s0
			group by id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position, ts_value_production
		)s1
		group by id_enterprise, nm_entity;
	
	end if;
        
end
$function$;
