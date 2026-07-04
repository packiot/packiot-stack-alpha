
	DECLARE
		r RECORD;
		r_ca RECORD;
		r_oeea RECORD;
		r_target RECORD;
		r_shift RECORD;
		vl_target float;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select
			(select ts_value from piot_get_day_begin_by_equipment(id_equipment,ts_value + interval '12 hour'))as ts_start,
			*
			from equipment_runtime_1day e
			where e.ts_value >= now() - interval '1 month' --and id_equipment in (select id_equipment from equipments where id_enterprise = 30)
				and ts_value < (select ts_value_production from piot_get_day_begin_by_equipment(id_equipment, now() + interval '1day'))
				and recalc_needed
				--new eduardo
				and id_equipment in (select id_equipment from equipments where tp_equipment >1 and id_area != 24 and id_enterprise not in (2,30,34,36,38,99,100,101,102,111,112,113,114,115,118))
				--new eduardo
			order by id_equipment, ts_value 
		loop
			EXECUTE 'SET LOCAL TIME ZONE ''' || (select timezone from sites where id_site = (select id_site from equipments where id_equipment = r.id_equipment)) || ''';' ;
			select sum(gross_production_incr) as gross_production_incr,
				sum(net_production_incr) as net_production_incr,
				sum(gross_production_incr) - sum(net_production_incr) as scrap_incr,
				coalesce(avg(ideal_production_speed), (select production_speed from equipments where id_equipment = r.id_equipment) ) as ideal_production_speed,
				--avg(speed) as speed,
				avg(case when state = 6 then speed end) as speed, --alteracao Eduardo 2024-02-29 para nao pegar state 10
				(select ts_value from piot_get_day_begin_by_equipment(r.id_equipment, (r.ts_value::date + (interval '1 second' * (piot_get_day_begin_offset_by_equipment(r.id_equipment))))::timestamptz)) as ts_value_real
			into r_ca
				from ca_agg_equipment_values_1hour ca
					where ca.id_equipment = r.id_equipment
						and ts_value_production >= now() - interval '1 month'
						and ca.ts_value >= r.ts_start
						and ca.ts_value_production = r.ts_value;
			if found THEN
				update equipment_runtime_1day
					set gross = coalesce(r_ca.gross_production_incr, 0),
						net = coalesce(r_ca.net_production_incr, 0),
						scrap = coalesce(r_ca.scrap_incr, 0),
						--oee_q = coalesce(r_ca.net_production_incr / nullif(r_ca.gross_production_incr,0), 0),
						speed = coalesce(r_ca.speed, 0),
						recalc_needed = false
					where id_equipment = r.id_equipment
						and ts_value = r.ts_value
						and ts_value >= r.ts_start;
				-- update equipment_runtime_1day to require recalculation
				update equipment_runtime_1month
					set recalc_needed = true
					where id_equipment = r.id_equipment
						and ts_value = date_trunc('month', r.ts_value);
				-- update equipment_runtime_1week to require recalculation
				update equipment_runtime_1week
					set recalc_needed = true
					where id_equipment = r.id_equipment
						and ts_value = date_trunc('week', r.ts_value);
			end if;

			-- select OEE A
			SELECT r.ts_value as ts_value,
				extract(epoch from (least(r_ca.ts_value_real + interval '1 day',now()) - (r_ca.ts_value_real))) as ts_total, 
				coalesce(sum(CASE WHEN ee.planned_downtime = true then 
					extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_planned, 
				coalesce(sum(CASE WHEN ee.change_over = true then 
					extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_changeover,
				--coalesce(sum(CASE WHEN ee.idle_processed = true then 
					--extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_idle_processed,
				--coalesce(sum(CASE WHEN ee.idle = 'yes' then 
					--extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_idle,
				--coalesce(sum(CASE WHEN ee.idle = 'starved' then 
					--extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_idle_starved,
				--coalesce(sum(CASE WHEN ee.idle = 'blocked' then 
					--extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_idle_blocked,
				coalesce(sum(CASE WHEN ee.status = 6 then 
					extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_running_time,
				coalesce(sum(CASE WHEN ee.status <> 6 then 
					extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_downtime,
				coalesce(sum(CASE WHEN (ee.status = 5 OR ee.status = 10 OR ee.status = 11) then 
					extract(epoch from(least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real))) end),0) as ts_stopped_time,
				count(CASE WHEN (ee.status = 5 OR ee.status = 10 OR ee.status = 11) then 
					least(coalesce(ee.ts_end,now()),coalesce(r_ca.ts_value_real + interval '1 day',now())) - greatest(ts_event,r_ca.ts_value_real) end) as ts_qt_stops,
				r_ca.ts_value_real as ts_lower,
				r_ca.ts_value_real + interval '1 day' as ts_upper
				into r_oeea
			FROM public.equipment_events ee
			where (tstzrange((ee.ts_event),coalesce(ee.ts_end, now())) && (tstzrange(r_ca.ts_value_real, r_ca.ts_value_real + interval '1 day')))  and  ee.id_equipment = r.id_equipment
				and ee.ts_event  >= now() - interval '1 month' and ee.ts_event < now()
			group by r.ts_value, r_ca.ts_value_real + interval '1 day', r_ca.ts_value_real
			order by r.ts_value desc;
			if found then
				update equipment_runtime_1day e
					set available_time = coalesce(r_oeea.ts_total - r_oeea.ts_planned, 0),
						running_time = coalesce(r_oeea.ts_running_time, 0),
						stopped_time = coalesce(r_oeea.ts_stopped_time, 0),
						planned_downtime = coalesce(r_oeea.ts_planned, 0),
						ideal_production = coalesce(((r_oeea.ts_total - r_oeea.ts_planned)/60.0)*nullif(r_ca.ideal_production_speed,0), 0),
						--idle_time = coalesce(r_oeea.ts_idle + r_oeea.ts_idle_starved + r_oeea.ts_idle_blocked, 0),
						--idle_starved = coalesce(r_oeea.ts_idle_starved, 0),
						--idle_blocked = coalesce(r_oeea.ts_idle_blocked, 0),
						downtime = coalesce(r_oeea.ts_downtime, 0),
						changeover_time = coalesce(r_oeea.ts_changeover, 0),
						recalc_needed = false,
						oee = coalesce(e.net / nullif(((r_oeea.ts_total - r_oeea.ts_planned)/60.0)*nullif(r_ca.ideal_production_speed,0),0), 0)
						--oee_a = coalesce(r_oeea.ts_running_time / nullif((r_oeea.ts_total - r_oeea.ts_planned),0), 0)
					where id_equipment = r.id_equipment
						and ts_value = r.ts_value;
				update equipment_runtime_1day e
					set available_time = coalesce(r_oeea.ts_total - r_oeea.ts_planned, 0)
						--oee_p = coalesce(e.oee / nullif(e.oee_a * e.oee_q,0), 0)
						--coalesce(e.net / (((r_oeea.ts_total - r_oeea.ts_planned)/60.0)*nullif(r_ca.ideal_production_speed,0)), 0)/nullif(e.oee_q * (r_oeea.ts_running_time / nullif((r_oeea.ts_total - r_oeea.ts_planned)::float,0)),0)),0)
					where id_equipment = r.id_equipment
						and ts_value = r.ts_value;
			end if;
			-- calculate targets
				if not r.target_customized then
					select vl_day 
						into r_target
						from production_targets
						where id_equipment = r.id_equipment;
						-- calculate target considering 24 hours and full hour, as long as this hour belongs to a shift
						if found THEN
							select * into r_shift
								from
								piot_get_shift_hour_begin_by_equipment(r.id_equipment, r.ts_value);
							if found THEN
								vl_target := coalesce(r_target.vl_day,0); -- 3600 seconds, one hour - available time / 1 hour * 24 hours
								update equipment_runtime_1day
									set target = vl_target,
										proportional_target = vl_target
									where id_equipment = r.id_equipment
										and ts_value = r.ts_value;
							end if;
						end if;
				end if;
		end loop;
		-- set all data from current day to recalc needed
		update equipment_runtime_1day e
			set recalc_needed = true,
				proportional_target = target * (select (select extract(epoch from now() - ts_value) from piot_get_day_begin_by_equipment(r.id_equipment, r.ts_value))/3600/24) -- seconds on the day
			where e.ts_value >= (select ts_value_production from piot_get_day_begin_by_equipment(e.id_equipment, now()))
				and ts_value < (select ts_value_production from piot_get_day_begin_by_equipment(e.id_equipment, now())) + interval '1 day';
	end

