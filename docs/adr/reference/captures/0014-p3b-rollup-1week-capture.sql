-- piot_get_equipment_runtime_1week_production (captured 2026-07-04)
-- THE CASCADE RECIPE: recalc-driven roll-up from the grain below.
-- NOTE THE PROD BUG (line ~62): the oee_p update targets
-- equipment_runtime_1MONTH from the WEEK function — copy-paste slip,
-- shipped for years. Faithful port keeps it, loudly documented.


	DECLARE
		r RECORD;
		rec RECORD;
	begin
		-- check which week rows need to be recalculated
		FOR r in
			select * from equipment_runtime_1week d 
				where recalc_needed
				--new eduardo
				and id_equipment in (select id_equipment from equipments where tp_equipment >1 and id_area != 24)
				--new eduardo
					and ts_value >= (NOW() - INTERVAL  '1 year' )
					and ts_value <= now() 
				order by d.id_equipment, ts_value
		loop
			select 
				sum(available_time) as available_time,
				sum(running_time) as running_time,
				sum(stopped_time) as stopped_time,
				sum(planned_downtime) as planned_downtime,
				sum(available_time) + sum(planned_downtime) as total_time,
				sum(ideal_production) as ideal_production,
				sum(idle_time) as idle_time,
				sum(idle_starved) as idle_starved,
				sum(idle_blocked) as idle_blocked,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap,
				avg(speed) as speed
			into rec
				from equipment_runtime_1day ard
					where ard.id_equipment = r.id_equipment 
						and r.ts_value = date_trunc('week', ard.ts_value::date)::date;
			if found then
				update equipment_runtime_1week
					set available_time = coalesce(rec.available_time,0),
						running_time = coalesce(rec.running_time,0),
						stopped_time = coalesce(rec.stopped_time,0),
						planned_downtime = coalesce(rec.planned_downtime,0),
						idle_time = coalesce(rec.idle_time,0),
						idle_starved = coalesce(rec.idle_starved,0),
						idle_blocked = coalesce(rec.idle_blocked,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						ideal_production = coalesce(rec.ideal_production,0),
						downtime = coalesce(rec.downtime,0),
						changeover_time = coalesce(rec.changeover_time,0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net / nullif(rec.gross,0), 0)
					where id_equipment = r.id_equipment
						and ts_value = r.ts_value;
				update equipment_runtime_1month e
					set oee_p = coalesce(e.oee / nullif(e.oee_a * e.oee_q,0), 0)
					where id_equipment = r.id_equipment
						and ts_value = r.ts_value;
			end if;
		end loop;
		-- set all data from current week to recalc needed
		update equipment_runtime_1week e
			set recalc_needed = true
			where e.ts_value >= date_trunc('week', now());
		-- Create production target if not customized
		FOR r in
			select *
			from
				equipments e
				join enterprises e2 on (e.id_enterprise = e2.id_enterprise) 
				left join production_targets pt on e.id_equipment = pt.id_equipment
			where e2.active = true
		loop
			with targets_to_update as (
				select ts_value::date as ts_value, id_equipment from equipment_runtime_1week where ts_value>=date_trunc('week', now()) 
				and id_equipment = r.id_equipment and target_customized is not true
			)
			update equipment_runtime_1week erw
			set target = r.vl_week
			from targets_to_update ttu
			where 
				erw.id_equipment = r.id_equipment and
				erw.ts_value = ttu.ts_value;
		end loop;
	end

