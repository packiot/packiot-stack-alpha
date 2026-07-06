-- piot_get_equipment_runtime_1day_production2 — THE LIVE day generation
-- (dispatcher-verified 2026-07-04; piot_monitor_function logs the OLD
-- name — the monitor lies, the perform() is truth).
-- ARCHITECTURE: day2 sums equipment_runtime_1HOUR rows (tvp-keyed,
-- ts >= day-1d window) — 13 metrics + oee=net/ideal + target (sum,
-- customized-respected) + proportional_target(sum); upward re-flags
-- month+week; tail re-flag current day only (proportional formula
-- commented out in THIS generation). NOTE: prod's exclusion list
-- includes enterprise 35 (CPACK) — day tier not maintained for CPACK
-- on prod; our flows keep it via config (divergence-by-config).

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
		select e.*, eq.id_enterprise,
				date_trunc('week', ts_value) as ts_value_week,
				date_trunc('month', ts_value) as ts_value_month
				from equipment_runtime_1day e
				left join equipments eq 
				on eq.id_equipment = e.id_equipment
				where e.ts_value >= now() - interval '1 month' --and id_equipment in (select id_equipment from equipments where id_enterprise = 30)
				and ts_value < (select ts_value_production from piot_get_day_begin_by_equipment(e.id_equipment, now() + interval '1day'))
				and recalc_needed
				and e.id_equipment in (select id_equipment from equipments where tp_equipment >1 and id_area != 24 and id_enterprise not in (2,30,34,35,36,38,99,100,101,102,111,112,113,114,115,118))
				order by id_enterprise
		loop
			select 
				--min(ts_value_production) as ts_value,
				sum(net)/nullif(sum(ideal_production),0) as oee,
				--recalc_needed
				--oee_p
				--oee_a
				--oee_q
				sum(available_time) as available_time, 
				sum(running_time) as running_time,
				sum(stopped_time) as stopped_time,
				sum(planned_downtime) as planned_downtime,
				sum(ideal_production) as ideal_production,	
				--idle_time
				--idle_starved	
				--idle_blocked	
				--min(id_equipment) as id_equipment,
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net, 	
				sum(downtime) as downtime,	
				sum(changeover_time) as changeover_time,	
				sum(scrap) as scrap, 	
				avg(speed) as speed,
				--sum(target_customized) as target_customized,
				sum(proportional_target) as proportional_target		
				into r_ca
				from equipment_runtime_1hour ca
					where ca.id_equipment = r.id_equipment
						and ca.ts_value >= r.ts_value - interval '1 day'
						and ca.ts_value_production = r.ts_value;				
			if found THEN
				update equipment_runtime_1day
					set oee = coalesce(r_ca.oee, 0),
						available_time = coalesce(r_ca.available_time, 0),
						running_time = coalesce(r_ca.running_time, 0),
						stopped_time = coalesce(r_ca.stopped_time, 0),
						planned_downtime = coalesce(r_ca.planned_downtime, 0),
						ideal_production = coalesce(r_ca.ideal_production, 0),
						target = case when target_customized is true then target else coalesce(r_ca.target, 0) end,
						gross = coalesce(r_ca.gross, 0),
						net = coalesce(r_ca.net, 0),
						downtime = coalesce(r_ca.downtime, 0),
						changeover_time = coalesce(r_ca.changeover_time, 0),
						scrap = coalesce(r_ca.scrap, 0),
						speed = coalesce(r_ca.speed, 0),
						--target_customized = coalesce(r_ca.target_customized, 0),
						proportional_target = coalesce(r_ca.proportional_target, 0),
						recalc_needed = false
					where id_equipment = r.id_equipment
						and ts_value = r.ts_value
						and	ts_value >= r.ts_value - interval '1 day';
				-- update equipment_runtime_1day to require recalculation
				update equipment_runtime_1month
					set recalc_needed = true
					where id_equipment = r.id_equipment
						and ts_value = r.ts_value_month
						and ts_value >= r.ts_value_month;--date_trunc('month', r.ts_value)
						--and ts_value >= r.minimo;
				-- update equipment_runtime_1week to require recalculation
				update equipment_runtime_1week
					set recalc_needed = true
					where id_equipment = r.id_equipment
						and ts_value = r.ts_value_week
						and ts_value >= r.ts_value_week;--date_trunc('week', r.ts_value)
						--and ts_value >=r.minimo;
			end if;
		end loop;
		-- set all data from current day to recalc needed
		update equipment_runtime_1day e
			set recalc_needed = true
				--proportional_target = target * (select (select extract(epoch from now() - ts_value) from piot_get_day_begin_by_equipment(r.id_equipment, r.ts_value))/3600/24) -- seconds on the day
			where e.ts_value >= (select ts_value_production from piot_get_day_begin_by_equipment(e.id_equipment, now()))
			and ts_value < (select ts_value_production from piot_get_day_begin_by_equipment(e.id_equipment, now())) + interval '1 day'
			and e.id_equipment in (select id_equipment from equipments where tp_equipment >1 and id_area != 24 and id_enterprise not in (2,30,34,35,36,38,99,100,101,102,111,112,113,114,115,118));
	end

