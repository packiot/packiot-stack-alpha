CREATE OR REPLACE FUNCTION public.h_piot_oee_score_full_3(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false)
 RETURNS SETOF h_piot_oee_score_full_table
 LANGUAGE plpgsql
 STABLE
AS $function$
declare 
	child_nav_level varchar := (
								select 
									case nav_level 
										when 'SITE' then 'AREA'
										when 'AREA' then 'EQUIPMENT'
										else NULL
									end
								);
	-- F3 cutover fixup M4: tenant-scoped scope arrays. Empty input array => "all within tenant"
	-- (mirrors sibling h_piot_oee_score_with_teams). Prevents `= any('{}')` matching nothing.
	ids_sites int[] := (select array_agg(id_site) from sites
						where id_enterprise = in_id_enterprise
							and (cardinality(in_id_sites::int[]) = 0 or id_site = any(in_id_sites::int[])));
	ids_areas int[] := (select array_agg(id_area) from areas
						where id_enterprise = in_id_enterprise
							and (cardinality(in_id_areas::int[]) = 0 or id_area = any(in_id_areas::int[])));
	ids_equips int[] := (select array_agg(id_equipment) from equipments
						where id_enterprise = in_id_enterprise
							and tp_equipment = 3
							and (cardinality(in_id_equipments::int[]) = 0 or id_equipment = any(in_id_equipments::int[])));
begin
		
	
	
	if nav_level = 'SITE' THEN
	return query
		
	--	//Rever a velocidade ideal
with basic_data as
    ( select ts_value, ent.id_enterprise, sft.cd_shift, ent.nm_area as nm_entity, s.id_area as id_entity, parent.nm_site as nm_parent, sequence_position, ent.id_site as id_parent, avg(net) net, avg(e.ideal_speed)ideal_speed, avg(scrap) scrap, avg(running_time)running_time, avg(ideal_production)ideal_production, avg(available_time)available_time, avg(gross)gross
     from area_oee_shift s
     join shifts sft using (id_shift)
     join areas ent on (ent.id_area= s.id_area)
     join sites parent on (ent.id_site= parent.id_site)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_area
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_area)
          where e.id_site = any(ids_sites)
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_area, ts_value_production ) e on (e.id_area = s.id_area
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_site = any(ids_sites) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
         and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
         and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date 
     group by ts_value, ent.id_enterprise, sft.cd_shift, parent.nm_site,sequence_position, ent.id_site, ent.nm_area, s.id_area)     
     --Start of query
select id_enterprise,nav_name,oee_componentes,oee_info,shifts,childs from (
select id_enterprise,
	nm_entity::text as nav_name,
	id_parent,
    jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
    jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
    shifts
from
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
                	from basic_data
                    group by cd_shift, sequence_position, cd_shift, nm_parent, id_enterprise, id_parent )cld
                group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent) sub1
            group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info ) child_elements
        group by id_enterprise,nm_entity,id_parent)entity_sum
    group by id_enterprise,
    	nm_entity,
        id_parent,
        shifts
 )parent_data join (
--------Start of Childs Query
select id_enterprise,
       id_parent,
       array_agg(child) childs
from
    ( select id_enterprise,
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
     from
         ( select id_enterprise,
                  nm_entity,
                  id_parent,
                  coalesce(sum(gross), 0) gross,
                  coalesce(sum(net), 0) net,
                  coalesce(avg(ideal_speed), 0) ideal_speed,
                  coalesce(sum(ideal_production), 0) ideal_production,
                  coalesce(sum(scrap), 0)scrap,
                  coalesce(sum(running_time), 0) running_time,
                  coalesce(sum(available_time), 0)available_time,
                  jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
                  jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
                  shifts from
              ( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  order by sequence_position) as shifts
               from
                   ( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
                        ( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
                             ( select id_enterprise, id_parent, cd_shift, nm_entity, id_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
                              from basic_data
                              group by id_entity, cd_shift, sequence_position, cd_shift, nm_entity, id_enterprise, id_parent )cld
                         group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent) sub1
                    group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info ) child_elements
               group by id_enterprise,nm_entity,id_parent)entity_sum
          group by id_enterprise,
                   nm_entity,
                   id_parent,
                   shifts) sub1
     group by id_enterprise,
              id_parent,
              nm_entity,
              oee_componentes,
              oee_info,
              shifts) s1
group by id_enterprise,
         id_parent ) children using (id_enterprise, id_parent);
--------End of Childs Query
        
        
        
        
        elseif nav_level = 'AREA' THEN
        return query
        
		
	--	//Rever a velocidade ideal
with basic_data as
    ( select ts_value, ent.id_enterprise, sft.cd_shift, ent.nm_equipment as nm_entity, s.id_equipment as id_entity, parent.nm_area as nm_parent, sequence_position, parent.id_area as id_parent, avg(net) net, avg(e.ideal_speed)ideal_speed, avg(scrap) scrap, avg(running_time)running_time, avg(ideal_production)ideal_production, avg(available_time)available_time, avg(gross)gross
     from equipment_oee_shift s
     join shifts sft using (id_shift)
     join equipments ent on (ent.id_equipment= s.id_equipment)
     join areas parent on (ent.id_area= parent.id_area)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_equipment
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_equipment)
          where e.id_equipment = any(ids_equips)
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_equipment, ts_value_production ) e on (e.id_equipment = s.id_equipment
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_area = any(ids_areas) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
        and ent.tp_equipment =3 
     	and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
        group by ts_value, ent.id_enterprise, sft.cd_shift, parent.nm_area,sequence_position, parent.id_area, ent.nm_equipment, s.id_equipment)
--Start of query
select 
	id_enterprise,nav_name,oee_componentes,oee_info,shifts,childs
 from (
select id_enterprise,
	nm_entity::text as nav_name,
	id_parent,
    jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
    jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
    shifts
from
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	(select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
                	from basic_data
                    group by cd_shift, sequence_position, cd_shift, nm_parent, id_enterprise, id_parent
                    )cld
                group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent
                ) sub1
            group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info ) child_elements
        group by id_enterprise,nm_entity,id_parent
        )entity_sum
    group by id_enterprise,
    	nm_entity,
        id_parent,
        shifts
 )parent_data join (
--------Start of Childs Query
select id_enterprise,
       id_parent,
       array_agg(child) childs
from
    ( select id_enterprise,
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
     from
         ( select id_enterprise,
                  nm_entity,
                  id_parent,
                  coalesce(sum(gross), 0) gross,
                  coalesce(sum(net), 0) net,
                  coalesce(avg(ideal_speed), 0) ideal_speed,
                  coalesce(sum(ideal_production), 0) ideal_production,
                  coalesce(sum(scrap), 0)scrap,
                  coalesce(sum(running_time), 0) running_time,
                  coalesce(sum(available_time), 0)available_time,
                  jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
                  jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
                  shifts from
              ( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  order by sequence_position) as shifts
               from
                   ( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
                        ( select id_enter--output truncated--
