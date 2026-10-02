-- serving.oee_score_by_team: upper caps GREATEST(LEAST(x,1),0) -> GREATEST(x,0) (28 sites).
-- The ratios were already ratios of sums (unbiased); only the cap hid P>1 (ideal speed
-- configured too low, e.g. ent5 L60 P=2.16) and hourly Q>1 (units in transit).
-- Body kept byte-identical otherwise (it has CRLF line endings).
CREATE OR REPLACE FUNCTION serving.oee_score_by_team(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false)
 RETURNS SETOF oee_score_by_team_row
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
							and id_site = any(ids_sites)
							and case
								when cardinality(in_id_areas::int[]) = 0 then true
								else id_area = any( in_id_areas::int[])
							end);
	ids_equips int[] := (
						select array_agg(id_equipment) 
						from equipments s
						where s.id_enterprise=in_id_enterprise 
							and s.tp_equipment=3
							and id_area = any(ids_areas)
							and case
								when cardinality(in_id_equipments::int[]) = 0 then true
								else id_equipment = any( in_id_equipments::int[])
							end);
begin
return query

with basic_data as(
	select
		ts_value,
		_equipments.id_enterprise,
		cd_shift,
		case nav_level
			when 'EQUIPMENT' then null
			when 'AREA' then _equipments.nm_equipment
			when 'SITE' then _areas.nm_area
		end as nm_entity,
		case nav_level
			when 'EQUIPMENT' then null
			when 'AREA' then _equipments.id_equipment
			when 'SITE' then _areas.id_area
		end as id_entity,
		case nav_level
			when 'EQUIPMENT' then _equipments.nm_equipment
			when 'AREA' then _areas.nm_area
			when 'SITE' then _sites.nm_site
		end as nm_parent,
		sequence_position,
		case nav_level
			when 'EQUIPMENT' then _equipments.id_equipment
			when 'AREA' then _areas.id_area
			when 'SITE' then _sites.id_site
		end as id_parent,
		sum(net) net,
		avg(s0.ideal_speed) ideal_speed,
		sum(scrap) scrap,
		sum(running_time) running_time,
		sum(ideal_production) ideal_production,
		sum(available_time) available_time,
		sum(gross) gross,
		id_team,
		cd_team 
	from(
		select 
			ts_value,
			_equipments.id_enterprise,
			_equipments.id_equipment,
			sft.cd_shift,
			sft.sequence_position,
			avg(net) net,
			avg(e.ideal_speed) ideal_speed,
			avg(scrap) scrap,
			avg(running_time) running_time,
			avg(ideal_production) ideal_production,
			avg(available_time) available_time,
			avg(gross) gross,
			id_team,
			cd_team
		from 
			equipment_oee_shift s
			join shifts sft using (id_shift)
			left join teams tms using (id_team)
			join equipments _equipments on (_equipments.id_equipment= s.id_equipment)
			left join(
				select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_equipment
				from
					silver.equipment_categorical_1hour caevh
					join equipments e using (id_equipment)
				where 
					e.id_equipment = any(ids_equips::int[])
					and caevh.ts_value_production >= date_trunc('day', in_begin_time::timestamp)::date
					and caevh.ts_value_production < date_trunc('day', in_end_time::timestamp+ interval '1 day')::date
				group by 
					e.id_equipment,
					ts_value_production
			) e on (e.id_equipment = s.id_equipment and e.ts_value_production = e.ts_value_production)
		where 
			_equipments.id_equipment = any(ids_equips::int[])
			and _equipments.tp_equipment =3 
			and s.ts_value_production >= date_trunc('day', in_begin_time::timestamp)::date
			and s.ts_value_production < date_trunc('day', in_end_time::timestamp+ interval '1 day')::date
		group by
			_equipments.id_enterprise,
			_equipments.id_equipment,
			id_team,
			cd_team,
			sft.cd_shift,
			ts_value,
			sft.sequence_position
	) s0
	join equipments _equipments on (_equipments.id_equipment= s0.id_equipment)
	join areas _areas on (_equipments.id_area = _areas.id_area)
	join sites _sites on (_equipments.id_site = _sites.id_site)
	group by
		ts_value,
		_equipments.id_enterprise,
		cd_shift,
		case nav_level
			when 'EQUIPMENT' then _equipments.nm_equipment
			when 'AREA' then _areas.nm_area
			when 'SITE' then _sites.nm_site
		end,
		sequence_position,
		case nav_level
			when 'EQUIPMENT' then _equipments.id_equipment
			when 'AREA' then _areas.id_area
			when 'SITE' then _sites.id_site
		end,
		case nav_level
			when 'EQUIPMENT' then null
			when 'AREA' then _equipments.id_equipment
			when 'SITE' then _areas.id_area
		end,
		case nav_level
			when 'EQUIPMENT' then null
			when 'AREA' then _equipments.nm_equipment
			when 'SITE' then _areas.nm_area
		end,
		id_team,
		cd_team
)
--Start of query
select 
	id_enterprise,
	nav_name,
	oee_componentes,
	oee_info,shifts,
	teams,
	case nav_level
		when 'EQUIPMENT' then null::jsonb[]
		else childs
	end as childs
from(
	select
		id_enterprise,
		nm_entity::text as nav_name,
		id_parent,
		jsonb_build_object(
			'oee_q', sum(sss0.oee_q),
			'oee_a', sum(sss0.oee_a),
			'oee_p', sum(sss0.oee_p),
			'oee', sum(sss0.oee)
		) as oee_componentes,
		jsonb_build_object(
			'running_time', coalesce(sum(sss0.running_time), 0),
			'available_time', coalesce(sum(sss0.available_time), 0),
			'total_prod', coalesce(sum(sss0.net), 0),
			'scrap', coalesce(sum(sss0.scrap), 0),
			'ideal_speed', coalesce(avg(sss0.ideal_speed), 0),
			'avg_speed', coalesce(sum(sss0.oee_p) * avg(sss0.ideal_speed), 0)
		) as oee_info,
		shifts,
		teams
	from (
		select
			*
		from (
			select
				id_enterprise,
				nm_entity,
				id_parent,
				coalesce(sum(net), 0) as net,
				coalesce(sum(gross),0) as gross,
				coalesce(avg(ideal_speed), 0) as ideal_speed,
				coalesce(sum(scrap),0) as scrap,
				coalesce(sum(ideal_production),0) as ideal_production,
				coalesce(sum(running_time),0) as running_time,
				coalesce(sum(available_time),0) as available_time,
				GREATEST(coalesce(sum(net)::float/nullif(sum(gross),0),0),0) as oee_q,
				GREATEST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),0) as oee_a,
				GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),0) as oee,
				GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),0) as oee_p,
				array_agg(child_shift order by sequence_position) as shifts
			from (
				select
					id_enterprise,
					nm_entity,
					sequence_position,
					id_parent,
					coalesce(sum(net), 0) net,
					coalesce(avg(ideal_speed), 0) ideal_speed,
					coalesce(sum(ideal_production), 0) ideal_production,
					coalesce(sum(scrap), 0)scrap,
					coalesce(sum(gross), 0)gross,
					coalesce(sum(running_time), 0) running_time,
					coalesce(sum(available_time), 0)available_time,
					jsonb_build_object(
						'nav_name', nm_entity,
						'oee_componentes', oee_componentes,
						'oee_info', oee_info,
						'shift', cd_shift
					) as child_shift
				from (
					select
						id_enterprise,
						nm_entity,
						cd_shift,
						sequence_position,
						id_parent,
						coalesce(sum(gross), 0) gross,
						coalesce(sum(net), 0) net,
						coalesce(avg(ideal_speed), 0) ideal_speed,
						coalesce(sum(ideal_production), 0) ideal_production,
						coalesce(sum(scrap), 0)scrap,
						coalesce(sum(running_time), 0) running_time,
						coalesce(sum(available_time), 0)available_time,
						jsonb_build_object(
							'oee_q', sum(oee_q),
							'oee_a', sum(oee_a),
							'oee_p', sum(oee_p),
							'oee', sum(oee)
						) as oee_componentes,
						jsonb_build_object(
							'running_time', coalesce(sum(running_time), 0),
							'available_time', coalesce(sum(available_time), 0),
							'total_prod', coalesce(sum(net), 0),
							'scrap', coalesce(sum(scrap), 0),
							'ideal_speed', coalesce(avg(ideal_speed), 0),
							'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
						) as oee_info
					from (
						select
							id_enterprise,
							id_parent,
							cd_shift,
							nm_parent as nm_entity,
							sequence_position,
							coalesce(sum(net),0) as net,
							coalesce(sum(gross),0) as gross,
							coalesce(avg(ideal_speed), 0) as ideal_speed,
							coalesce(sum(scrap),0) as scrap,
							coalesce(sum(running_time),0) as running_time,
							coalesce(sum(ideal_production), 0) ideal_production,
							coalesce(sum(available_time),0) as available_time,
							GREATEST(coalesce(sum(net)::float/nullif(sum(gross),0),0),0) as oee_q,
							GREATEST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),0) as oee_a,
							GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),0) as oee,
							GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),0) as oee_p
						from basic_data
						group by cd_shift, sequence_position, cd_shift, nm_parent, id_enterprise, id_parent
					)cld
					group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent
				) sub1
				group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info
			) child_elements
			group by id_enterprise,nm_entity,id_parent
		)entity_sum
		group by id_enterprise, nm_entity, id_parent, shifts, net, gross, ideal_production, ideal_speed, scrap, running_time , available_time, oee, oee_a, oee_p, oee_q 
	)sss0
	left join (
		select
			*
		from (
			select
				id_enterprise,
				nm_entity,
				id_parent,
				coalesce(sum(net),0) as net,
				coalesce(sum(gross),0) as gross,
				coalesce(avg(ideal_speed),0) as ideal_speed,
				coalesce(sum(scrap),0) as scrap,
				coalesce(sum(ideal_production),0) as ideal_production,
				coalesce(sum(running_time),0) as running_time,
				coalesce(sum(available_time),0) as available_time,
				GREATEST(coalesce(sum(net)::float/nullif(sum(gross),0),0),0) as oee_q,
				GREATEST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),0) as oee_a,
				GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),0) as oee,
				GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),0) as oee_p,
				array_agg(child_team) as teams
			from (
				select 
					id_enterprise,
					nm_entity,
					id_parent,
					coalesce(sum(net),0) net,
					coalesce(avg(ideal_speed),0) ideal_speed,
					coalesce(sum(ideal_production), 0) ideal_production,
					coalesce(sum(scrap), 0)scrap,
					coalesce(sum(gross), 0)gross,
					coalesce(sum(running_time),0) running_time,
					coalesce(sum(available_time),0)available_time,
					jsonb_build_object(
						'nav_name', nm_entity,
						'oee_componentes', oee_componentes,
						'oee_info', oee_info,
						'team', cd_team
					) as child_team
				from (
					select
						id_enterprise,
						nm_entity,
						cd_team,
						id_parent,
						coalesce(sum(gross), 0) gross,
						coalesce(sum(net), 0) net,
						coalesce(avg(ideal_speed), 0) ideal_speed,
						coalesce(sum(ideal_production), 0) ideal_production,
						coalesce(sum(scrap), 0) scrap,
						coalesce(sum(running_time), 0) running_time,
						coalesce(sum(available_time), 0) available_time,
						jsonb_build_object(
							'oee_q', sum(oee_q),
							'oee_a', sum(oee_a),
							'oee_p', sum(oee_p),
							'oee', sum(oee)
						) as oee_componentes,
						jsonb_build_object(
							'running_time', coalesce(sum(running_time), 0),
							'available_time', coalesce(sum(available_time), 0),
							'total_prod', coalesce(sum(net), 0),
							'scrap', coalesce(sum(scrap), 0),
							'ideal_speed', coalesce(avg(ideal_speed), 0),
							'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
						) as oee_info
					from (
						select
							id_enterprise,
							id_parent,
							cd_team,
							nm_parent as nm_entity,
							coalesce(sum(net),0) as net,
							coalesce(sum(gross),0) as gross,
							coalesce(avg(ideal_speed), 0) as ideal_speed,
							coalesce(sum(scrap),0) as scrap,
							coalesce(sum(running_time),0) as running_time,
							coalesce(sum(ideal_production), 0) ideal_production,
							coalesce(sum(available_time),0) as available_time,
							GREATEST(coalesce(sum(net)::float/nullif(sum(gross),0),0),0) as oee_q,
							GREATEST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),0) as oee_a,
							GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),0) as oee,
							GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),0) as oee_p
						from basic_data
						group by cd_team, nm_parent, id_enterprise, id_parent
					)cld
					group by id_enterprise, nm_entity, cd_team, id_parent
				) sub1
				group by id_enterprise, nm_entity, id_parent, oee_componentes, oee_info, cd_team
			) child_elements
			group by id_enterprise,nm_entity,id_parent
		)entity_sum
		group by id_enterprise, nm_entity, id_parent, teams, net, gross, ideal_production, ideal_speed, scrap, running_time , available_time, oee, oee_a, oee_p, oee_q
	)sss1 using (id_enterprise, nm_entity, id_parent)
	group by id_enterprise, nm_entity, id_parent, shifts, teams
)parent_data
--------Start of Childs Query
join (
	select 
		id_enterprise,
		id_parent,
		array_agg(child) childs
	from (
		select
			id_enterprise,
			id_parent,
			nm_entity,
			coalesce(sum(gross), 0) gross,
			coalesce(sum(net), 0) net,
			coalesce(avg(ideal_speed), 0) ideal_speed,
			coalesce(sum(ideal_production), 0) ideal_production,
			coalesce(sum(scrap), 0)scrap,
			coalesce(sum(running_time), 0) running_time,
			coalesce(sum(available_time), 0)available_time,
			jsonb_build_object('nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shifts', sub1.shifts ) as child
		from (
			select 
				id_enterprise,
				nm_entity,
				id_parent,
				coalesce(sum(gross), 0) gross,
				coalesce(sum(net), 0) net,
				coalesce(avg(ideal_speed), 0) ideal_speed,
				coalesce(sum(ideal_production), 0) ideal_production,
				coalesce(sum(scrap), 0)scrap,
				coalesce(sum(running_time), 0) running_time,
				coalesce(sum(available_time), 0)available_time,
				jsonb_build_object(
					'oee_q', sum(oee_q),
					'oee_a', sum(oee_a),
					'oee_p', sum(oee_p),
					'oee', sum(oee)
				) as oee_componentes,
				jsonb_build_object(
					'running_time', coalesce(sum(running_time), 0),
					'available_time', coalesce(sum(available_time), 0),
					'total_prod', coalesce(sum(net), 0),
					'scrap', coalesce(sum(scrap), 0),
					'ideal_speed', coalesce(avg(ideal_speed), 0),
					'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
				) as oee_info, shifts
			from (
				select
					sss0.id_enterprise,
					sss0.nm_entity,
					sss0.id_parent,
					sss0.net,
					sss0.gross,
					sss0.ideal_speed,
					sss0.scrap,
					sss0.available_time,
					sss0.ideal_production,
					sss0.running_time,
					sss0.oee_p,
					sss0.oee_q,
					sss0.oee_a,
					sss0.oee,
					shifts,
					teams
				from(
					select 
						id_enterprise,
						nm_entity,
						id_parent,
						coalesce(sum(net),0) as net,
						coalesce(sum(gross),0) as gross,
						coalesce(avg(ideal_speed), 0) as ideal_speed,
						coalesce(sum(scrap),0) as scrap,
						coalesce(sum(ideal_production),0) as ideal_production,
						coalesce(sum(running_time),0) as running_time,
						coalesce(sum(available_time),0) as available_time,
						GREATEST(coalesce(sum(net)::float/nullif(sum(gross),0),0),0) as oee_q,
						GREATEST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),0) as oee_a,
						GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),0) as oee,
						GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
					from (
						select
							id_enterprise,
							nm_entity,
							sequence_position,
							id_parent,
							coalesce(sum(net), 0) net,
							coalesce(avg(ideal_speed), 0) ideal_speed,
							coalesce(sum(ideal_production), 0) ideal_production,
							coalesce(sum(scrap), 0) scrap,
							coalesce(sum(gross), 0) gross,
							coalesce(sum(running_time), 0) running_time,
							coalesce(sum(available_time), 0) available_time,
							jsonb_build_object(
								'nav_name', nm_entity,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info,
								'shift', cd_shift
							) as child_shift
						from (
							select
								id_enterprise,
								nm_entity,
								cd_shift,
								sequence_position,
								id_parent,
								coalesce(sum(gross), 0) gross,
								coalesce(sum(net), 0) net,
								coalesce(avg(ideal_speed), 0) ideal_speed,
								coalesce(sum(ideal_production), 0) ideal_production,
								coalesce(sum(scrap), 0) scrap,
								coalesce(sum(running_time), 0) running_time,
								coalesce(sum(available_time), 0) available_time,
								jsonb_build_object(
									'oee_q', sum(oee_q),
									'oee_a', sum(oee_a),
									'oee_p', sum(oee_p),
									'oee', sum(oee)
								) as oee_componentes,
								jsonb_build_object(
									'running_time', coalesce(sum(running_time), 0),
									'available_time', coalesce(sum(available_time), 0),
									'total_prod', coalesce(sum(net), 0),
									'scrap', coalesce(sum(scrap), 0),
									'ideal_speed', coalesce(avg(ideal_speed), 0),
									'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
								) as oee_info
							from (
								select
									id_enterprise,
									id_parent,
									cd_shift,
									nm_entity,
									id_entity,
									sequence_position,
									coalesce(sum(net),0) as net,
									coalesce(sum(gross),0) as gross,
									coalesce(avg(ideal_speed), 0) as ideal_speed,
									coalesce(sum(scrap),0) as scrap,
									coalesce(sum(running_time),0) as running_time,
									coalesce(sum(ideal_production), 0) as ideal_production,
									coalesce(sum(available_time),0) as available_time,
									GREATEST(coalesce(sum(net)::float/nullif(sum(gross),0),0),0) as oee_q,
									GREATEST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),0) as oee_a,
									GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),0) as oee,
									GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),0) as oee_p
								from basic_data
								group by id_entity, cd_shift, sequence_position, cd_shift, nm_entity, id_enterprise, id_parent
							)cld
							group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent
						) sub1
						group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info
					) child_elements
					group by id_enterprise,nm_entity,id_parent
				) sss0
				left join (
					select 
						id_enterprise,
						nm_entity,
						id_parent,
						array_agg(child_team) as teams
					from (
						select
							id_enterprise,
							nm_entity,
							id_parent,
							coalesce(sum(net), 0) net,
							coalesce(avg(ideal_speed), 0) ideal_speed,
							coalesce(sum(ideal_production), 0) ideal_production,
							coalesce(sum(scrap), 0) scrap,
							coalesce(sum(gross), 0) gross,
							coalesce(sum(running_time), 0) running_time,
							coalesce(sum(available_time), 0)available_time,
							jsonb_build_object(
								'nav_name', nm_entity,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info,
								'team', cd_team
							) as child_team
						from (
							select
								id_enterprise,
								nm_entity,
								cd_team,
								id_parent,
								coalesce(sum(gross), 0) gross,
								coalesce(sum(net), 0) net,
								coalesce(avg(ideal_speed), 0) ideal_speed,
								coalesce(sum(ideal_production), 0) ideal_production,
								coalesce(sum(scrap), 0)scrap,
								coalesce(sum(running_time), 0) running_time,
								coalesce(sum(available_time), 0)available_time,
								jsonb_build_object(
									'oee_q', sum(oee_q),
									'oee_a', sum(oee_a),
									'oee_p', sum(oee_p),
									'oee', sum(oee)
								) as oee_componentes,
								jsonb_build_object(
									'running_time', coalesce(sum(running_time), 0),
									'available_time', coalesce(sum(available_time), 0),
									'total_prod', coalesce(sum(net), 0),
									'scrap', coalesce(sum(scrap), 0),
									'ideal_speed', coalesce(avg(ideal_speed), 0),
									'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
								) as oee_info
							from (
								select
									id_enterprise,
									id_parent,
									cd_team,
									nm_entity,
									id_entity,
									coalesce(sum(net),0) as net,
									coalesce(sum(gross),0) as gross,
									coalesce(avg(ideal_speed), 0) as ideal_speed,
									coalesce(sum(scrap),0) as scrap,
									coalesce(sum(running_time),0) as running_time,
									coalesce(sum(ideal_production), 0) ideal_production,
									coalesce(sum(available_time),0) as available_time,
									GREATEST(coalesce(sum(net)::float/nullif(sum(gross),0),0),0) as oee_q,
									GREATEST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),0) as oee_a,
									GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),0) as oee,
									GREATEST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),0) as oee_p
								from basic_data
								group by id_entity, cd_team, cd_team, nm_entity, id_enterprise, id_parent
							)cld
							group by id_enterprise, nm_entity, cd_team, id_parent
						) sub1
						group by id_enterprise, cd_team, nm_entity, id_parent, oee_componentes, oee_info
					) child_elements
					group by id_enterprise,nm_entity,id_parent
				)sss1 using (id_enterprise, nm_entity, id_parent)
			)entity_sum
			group by id_enterprise, nm_entity, id_parent, shifts, teams
		)sub1
		group by id_enterprise, id_parent, nm_entity, oee_componentes, oee_info, shifts
	) s1
	group by id_enterprise, id_parent
) children using (id_enterprise, id_parent);

end $function$;
