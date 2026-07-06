-- ===FUNC=== piot_review_equipment_events
CREATE OR REPLACE FUNCTION public.piot_review_equipment_events()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
	rows_to_recalc record;
begin
	-- delete wrong events
with items as materialized
(select e2.id_equipment_event 
	from equipment_events e2 
	join 
	(select ee.ts_event, ee.ts_end, ee.id_equipment, ee.status 
		from public.equipment_events ee
			join public.equipments e on e.id_equipment = ee.id_equipment and e.status_type = 4
		where ts_event > (now() - interval '1 day')
		and ee.id_equipment in (select id_equipment from equipments where tp_equipment>0 and id_area != 24 and id_enterprise not in (2,30,34,36,38,99,100,101,102,111,112,113,114,115,118))
			--and ee.id_equipment = 42
			and not forced_creation_system 
		except
	select 
		ts_event, 
		lead(ts_event, 1) over (partition by id_equipment order by ts_event) as ts_end, 
		id_equipment, status
		from
		(select 
			ts_event, 
			--lead(ts_event, 1) over (partition by id_equipment order by ts_event) as ts_end, 
			id_equipment, status, 
			case when LAG (id_equipment) OVER (ORDER BY id_equipment, ts_event) = id_equipment then
						LAG (status) OVER (ORDER BY id_equipment, ts_event)
			else null end AS prev_status,
			ROW_NUMBER() OVER (PARTITION BY id_equipment ORDER BY ts_event) AS r
		from
			(select
					ts_value as ts_event,
					--lead(ts_value, 1) over (partition by ca.id_equipment order by ts_value) as ts_end,
					ca.id_equipment,
					gapfill(state) over (partition by ca.id_equipment order by  ts_value ) as status
					from ca_discrete_changes_1s ca
						join public.equipments e on e.id_equipment = ca.id_equipment and e.status_type = 4
					where ts_value > (now() - interval '25 hour')
					and ca.id_equipment in (select id_equipment from equipments where tp_equipment>0 and id_area != 24 and id_enterprise not in (2,30,34,36,38,99,100,101,102,111,112,113,114,115,118))
						--and ca.id_equipment = 42
					order by id_equipment, ts_event) s1
			order by id_equipment, ts_event) s2
			where s2.status != s2.prev_status and r > 10) s1
	on e2.ts_event = s1.ts_event and e2.id_equipment = s1.id_equipment
		and e2.ts_event > (now() - interval '1 day'))
delete 
		from equipment_events ev
		using
            items s2 
        where ev.id_equipment_event = s2.id_equipment_event 
        and ts_event >= now() - interval '48 hour';				
       
	-- create correct events
	insert into public.equipment_events 
		(ts_event, ts_end, id_equipment, status, id_enterprise, duration)
		(select
			ts_event, ts_end, id_equipment, status, id_enterprise,
			extract(epoch from (coalesce(ts_end ,now()) - ts_event)) as duration
			from
			(select T1.* from (
				select 
					ts_event, 
					lead(ts_event, 1) over (partition by id_equipment order by ts_event) as ts_end, 
					id_equipment, status, id_enterprise,
					extract(epoch from (coalesce(lead(ts_event, 1) over (partition by id_equipment order by ts_event) ,now()) - ts_event)) as duration
					from
				(select 
					ts_event, 
					--lead(ts_event, 1) over (partition by id_equipment order by ts_event) as ts_end, 
					id_equipment, status, 
					case when LAG (id_equipment) OVER (ORDER BY id_equipment, ts_event) = id_equipment then
					        	LAG (status) OVER (ORDER BY id_equipment, ts_event)
			        else null end AS prev_status,
			        ROW_NUMBER() OVER (PARTITION BY id_equipment ORDER BY ts_event) AS r, id_enterprise
				from
					(select
							ts_value as ts_event,
							--lead(ts_value, 1) over (partition by ca.id_equipment order by ts_value) as ts_end,
							ca.id_equipment,
							gapfill(state) over (partition by ca.id_equipment order by  ts_value ) as status, ca.id_enterprise
							from ca_discrete_changes_1s ca
								join public.equipments e on e.id_equipment = ca.id_equipment and e.status_type = 4
							where ts_value > (now() - interval '25 hour')
							and ca.id_equipment in (select id_equipment from equipments where tp_equipment>0 and id_area != 24 and id_enterprise not in (2,30,34,36,38,99,100,101,102,111,112,113,114,115,118))
								--and ca.id_equipment = 42
							order by id_equipment, ts_event) s1
					order by id_equipment, ts_event) s2
					where s2.status != s2.prev_status and r > 10
				)T1
				left join (
					select ts_event, ts_end, ee.id_equipment, status, ee.id_enterprise, ee.duration
					from public.equipment_events ee 
						join public.equipments e on e.id_equipment = ee.id_equipment and e.status_type = 4
					where ts_event > (now() - interval '1 day')
					and ee.id_equipment in (select id_equipment from equipments where tp_equipment>0 and id_area != 24 and id_enterprise not in (2,30,34,36,38,99,100,101,102,111,112,113,114,115,118))
					order by id_equipment, ts_event
				)T2 on (T1.ts_event = T2.ts_event and T1.id_enterprise = T2.id_enterprise and T1.id_equipment = T2.id_equipment)
			where T2.ts_event is not null
			) s1)	
		on conflict (id_equipment, ts_event) do update 
			set ts_end = excluded.ts_end,
				status = excluded.status,
				duration = excluded.duration;
end $function$

-- ===FUNC=== piot_trig_equipment_events_update_prev
CREATE OR REPLACE FUNCTION public.piot_trig_equipment_events_update_prev()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
    BEGIN
		update equipment_events ee
			set ts_end = NEW.ts_event,
				duration = EXTRACT(epoch from (NEW.ts_event - ee.ts_event))
			where ee.id_equipment = NEW.id_equipment
				and ee.ts_event < new.ts_event
				and ee.ts_end is null;
       	RETURN NEW;	    
    END;
$function$


