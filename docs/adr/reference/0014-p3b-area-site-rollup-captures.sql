-- The area/site rollup tier — all 10 live bodies (dispatcher-verified
-- plain names, captured 2026-07-04).
-- ########piot_get_area_runtime_1hour_production

	DECLARE
		r RECORD;
		r_ca RECORD;
		r_oeea RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select *
			from area_runtime_1hour
			where ts_value >= now() - interval '1 month' --and id_area in (25,26,27)
				and ts_value <= now()
				and recalc_needed
			--new eduardo
				and id_area not in (24)
			--new eduardo
			order by id_area, ts_value 
		loop
			select sum(available_time) as available_time,
					sum(running_time) as running_time,
					sum(stopped_time) as stopped_time,
					sum(planned_downtime) as planned_downtime,
					sum(ideal_production) as ideal_production,
					sum(idle_time) as idle_time,
					sum(idle_starved) as idle_starved,
					sum(idle_blocked) as idle_blocked,
					sum(target) as target,
					sum(gross) as gross,
					sum(net) as net,
					sum(scrap) as scrap,
					sum(downtime) as downtime,
					sum(changeover_time) as changeover_time
				into r_ca
				from equipment_runtime_1hour
					where id_equipment in (select id_equipment from equipments where id_area = r.id_area and tp_equipment = 3)
						and ts_value = r.ts_value;
				if found THEN
					update area_runtime_1hour
						set gross = r_ca.gross,
							net = r_ca.net,
							scrap = r_ca.scrap,
							oee_q = r_ca.net / nullif(r_ca.gross,0),
							available_time = r_ca.available_time,
							running_time = r_ca.running_time,
							stopped_time = r_ca.stopped_time,
							planned_downtime = r_ca.planned_downtime,
							ideal_production = r_ca.ideal_production,
							idle_time = r_ca.idle_time,
							idle_starved = r_ca.idle_starved,
							idle_blocked = r_ca.idle_blocked,
							target = r_ca.target,
							downtime = r_ca.downtime,
							changeover_time = r_ca.changeover_time,
							oee = coalesce(r_ca.net / nullif(r_ca.ideal_production,0),0),
							oee_a = coalesce(r_ca.running_time::float / nullif(r_ca.available_time,0),0),
							oee_p = coalesce((r_ca.net / nullif(r_ca.ideal_production,0)) / (nullif(r_ca.running_time::float / nullif(r_ca.available_time,0) * (r_ca.net::float / nullif(r_ca.gross,0)),0)),0),
							proportional_target = r_ca.target,
							recalc_needed = false
						where id_area = r.id_area
							and ts_value = r.ts_value;
					end if;

				-- update area_runtime_1day to require recalculation
				update area_runtime_1day
					set recalc_needed = true
					where id_area = r.id_area
						and ts_value = (select ts_value_production from piot_get_day_begin_by_area(r.id_area, r.ts_value));


		end loop;
		-- set all data from current hour to recalc needed
		update area_runtime_1hour
			set recalc_needed = true,
				proportional_target = target * (select extract(minute from now()) / 60)
			where ts_value >= date_trunc('hour', now())::timestamptz and ts_value <= now();
	end


-- ########piot_get_area_runtime_1day_production

	DECLARE
		r RECORD;
		rec RECORD;
	begin
		FOR r in
			select * from area_runtime_1day d 
				where recalc_needed
					and ts_value >= (NOW() - INTERVAL  '1 month' )
					and ts_value <= now() 
				order by d.id_area, ts_value
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
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap,
				avg(speed) as speed,
				sum(proportional_target) as proportional_target
			into rec
				from equipment_runtime_1day ard
					join equipments e on ard.id_equipment = e.id_equipment and e.tp_equipment = 3
					where e.id_area  = r.id_area 
						and ard.ts_value = r.ts_value;
			if found then
				update area_runtime_1day
					set available_time = coalesce(rec.available_time,0),
						running_time = coalesce(rec.running_time,0),
						stopped_time = coalesce(rec.stopped_time,0),
						planned_downtime = coalesce(rec.planned_downtime,0),
						ideal_production = coalesce(rec.ideal_production, 0),
						idle_time = coalesce(rec.idle_time,0),
						idle_starved = coalesce(rec.idle_starved,0),
						idle_blocked = coalesce(rec.idle_blocked,0),
						target = coalesce(rec.target,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						scrap = coalesce(rec.scrap,0),
						downtime = coalesce(rec.downtime,0),
						changeover_time = coalesce(rec.changeover_time,0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time::float / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net::float / nullif(rec.gross,0), 0),
						proportional_target = coalesce(rec.proportional_target,0)
					where id_area = r.id_area
						and ts_value = r.ts_value;
				update area_runtime_1day e
					set oee_p = coalesce(e.oee::float / nullif(e.oee_a * e.oee_q,0), 0)
					where id_area = r.id_area
						and ts_value = r.ts_value;
			end if;
			-- update equipment_runtime_1day to require recalculation
			update area_runtime_1month
				set recalc_needed = true
				where id_area = r.id_area
					and ts_value = date_trunc('month', r.ts_value);
			-- update equipment_runtime_1week to require recalculation
			update area_runtime_1week
				set recalc_needed = true
				where id_area = r.id_area
					and ts_value = date_trunc('week', r.ts_value);
		end loop;
		-- update area_runtime_1day to require recalculation
		update area_runtime_1day
			set recalc_needed = true
			where ts_value >= (select ts_value_production from piot_get_day_begin_by_area(r.id_area, now()))
				and ts_value < (select ts_value_production from piot_get_day_begin_by_area(r.id_area, now() + interval '1 day'));
	end


-- ########piot_get_area_runtime_1week_production

	DECLARE
		r RECORD;
		rec RECORD;
	begin
		FOR r in
		select *
			from area_runtime_1week d
				where ts_value < now()
				and ts_value >= now() - interval '1 month' 
				and recalc_needed
			order by id_area, ts_value 
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
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap,
				avg(speed) as speed,
				sum(proportional_target) as proportional_target		
			into rec
				from area_runtime_1day ard
					where ard.id_area = r.id_area
						and ard.ts_value >= date_trunc('week', r.ts_value)
						and ard.ts_value <= r.ts_value + interval '1 week';
			if found then
				update area_runtime_1week
					set available_time = coalesce(rec.available_time, 0),
						running_time = coalesce(rec.running_time, 0),
						stopped_time = coalesce(rec.stopped_time, 0),
						planned_downtime = coalesce(rec.planned_downtime, 0),
						ideal_production = coalesce(rec.ideal_production, 0),
						idle_time = coalesce(rec.idle_time, 0),
						idle_starved = coalesce(rec.idle_starved, 0),
						idle_blocked = coalesce(rec.idle_blocked, 0),
						target = coalesce(rec.target,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						scrap = coalesce(rec.scrap,0),
						downtime = coalesce(rec.downtime, 0),
						changeover_time = coalesce(rec.changeover_time, 0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time::float / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net::float / nullif(rec.gross,0), 0),
						proportional_target = coalesce(rec.proportional_target,0)
					where id_area = r.id_area
						and ts_value = r.ts_value;
				update area_runtime_1week e
					set oee_p = coalesce(e.oee::float / nullif(e.oee_a * e.oee_q,0), 0)
					where id_area = r.id_area
						and ts_value = r.ts_value;
			end if;
		end loop;
		-- update area_runtime_1WEEK to require recalculation
		update area_runtime_1week
			set recalc_needed = true
			where ts_value >= DATE_TRUNC('WEEK',(now()))
				and ts_value < DATE_TRUNC('WEEK',now() + interval '1 week');
	end


-- ########piot_get_area_runtime_1month_production

	DECLARE
		r RECORD;
		rec RECORD;
	begin
		FOR r in
		select *
			from area_runtime_1month d
				where ts_value < now()
				and ts_value >= now() - interval '1 month' 
				and recalc_needed
			order by id_area, ts_value 
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
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap,
				avg(speed) as speed,
				sum(proportional_target) as proportional_target				
			into rec
				from area_runtime_1day ard
					where ard.id_area = r.id_area
						and ard.ts_value >= date_trunc('month', r.ts_value)
						and ard.ts_value <= r.ts_value + interval '1 month';
			if found then
				update area_runtime_1month
					set available_time = coalesce(rec.available_time, 0),
						running_time = coalesce(rec.running_time, 0),
						stopped_time = coalesce(rec.stopped_time, 0),
						planned_downtime = coalesce(rec.planned_downtime, 0),
						ideal_production = coalesce(rec.ideal_production, 0),
						idle_time = coalesce(rec.idle_time, 0),
						idle_starved = coalesce(rec.idle_starved, 0),
						idle_blocked = coalesce(rec.idle_blocked, 0),
						target = coalesce(rec.target,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						scrap = coalesce(rec.scrap,0),
						downtime = coalesce(rec.downtime, 0),
						changeover_time = coalesce(rec.changeover_time, 0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time::float / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net::float / nullif(rec.gross,0), 0),
						proportional_target = coalesce(rec.proportional_target,0)
					where id_area = r.id_area
						and ts_value = r.ts_value;
				update area_runtime_1month e
					set oee_p = coalesce(e.oee::float / nullif(e.oee_a * e.oee_q,0), 0)
					where id_area = r.id_area
						and ts_value = r.ts_value;
			end if;
		end loop;
		update area_runtime_1month
			set recalc_needed = true
			where ts_value >= DATE_TRUNC('month',(now()))
				and ts_value < DATE_TRUNC('month',now() + interval '1 month');
	end


-- ########piot_get_area_runtime_shift_production

	DECLARE
		r RECORD;
		rec RECORD;
	begin
		FOR r in
			select * from area_runtime_shift d 
				where recalc_needed
					and ts_value >= (NOW() - INTERVAL  '1 month' )
					and ts_value <= now() 
				order by d.id_area, ts_value
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
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap,
				avg(speed) as speed
			into rec
				from equipment_runtime_shift ard
					join equipments e on ard.id_equipment = e.id_equipment and e.tp_equipment = 3
					where e.id_area  = r.id_area 
						and ard.ts_value = r.ts_value;
			if found then
				update area_runtime_shift
					set available_time = coalesce(rec.available_time,0),
						running_time = coalesce(rec.running_time,0),
						stopped_time = coalesce(rec.stopped_time,0),
						planned_downtime = coalesce(rec.planned_downtime,0),
						ideal_production = coalesce(rec.ideal_production, 0),
						idle_time = coalesce(rec.idle_time,0),
						idle_starved = coalesce(rec.idle_starved,0),
						idle_blocked = coalesce(rec.idle_blocked,0),
						target = coalesce(rec.target,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						scrap = coalesce(rec.scrap,0),
						downtime = coalesce(rec.downtime,0),
						changeover_time = coalesce(rec.changeover_time,0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time::float / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net::float / nullif(rec.gross,0), 0)
					where id_area = r.id_area
						and ts_value = r.ts_value;
				update area_runtime_shift e
					set oee_p = coalesce(e.oee::float / nullif(e.oee_a * e.oee_q,0), 0)
					where id_area = r.id_area
						and ts_value = r.ts_value;
			end if;
		end loop;
		-- update area_runtime_1day to require recalculation
		update area_runtime_shift
			set recalc_needed = true
			where ts_value_production >= (select ts_value_production from piot_get_day_begin_by_area(r.id_area, now()))
				and ts_value_production < (select ts_value_production from piot_get_day_begin_by_area(r.id_area, now() + interval '1 day'));
	end


-- ########piot_get_site_runtime_1hour_production

	DECLARE
		r RECORD;
		r_ca RECORD;
		r_oeea RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select *
			from site_runtime_1hour
			where ts_value >= now() - interval '1 month' --and id_site in (25,26,27)
				and ts_value <= now()
				and recalc_needed
			order by id_site, ts_value 
		loop
			select sum(available_time) as available_time,
					sum(running_time) as running_time,
					sum(stopped_time) as stopped_time,
					sum(planned_downtime) as planned_downtime,
					sum(ideal_production) as ideal_production,
					sum(idle_time) as idle_time,
					sum(idle_starved) as idle_starved,
					sum(idle_blocked) as idle_blocked,
					sum(target) as target,
					sum(gross) as gross,
					sum(net) as net,
					sum(scrap) as scrap,
					sum(downtime) as downtime,
					sum(changeover_time) as changeover_time
				into r_ca
				from area_runtime_1hour
					where id_area in (select id_area from areas where id_site = r.id_site)
						and ts_value = r.ts_value;
				if found THEN
					update site_runtime_1hour
						set gross = r_ca.gross,
							net = r_ca.net,
							scrap = r_ca.scrap,
							oee_q = r_ca.net / nullif(r_ca.gross,0),
							available_time = r_ca.available_time,
							running_time = r_ca.running_time,
							stopped_time = r_ca.stopped_time,
							planned_downtime = r_ca.planned_downtime,
							ideal_production = r_ca.ideal_production,
							idle_time = r_ca.idle_time,
							idle_starved = r_ca.idle_starved,
							idle_blocked = r_ca.idle_blocked,
							target = r_ca.target,
							downtime = r_ca.downtime,
							changeover_time = r_ca.changeover_time,
							oee = coalesce(r_ca.net / nullif(r_ca.ideal_production,0),0),
							oee_a = coalesce(r_ca.running_time::float / nullif(r_ca.available_time,0),0),
							oee_p = coalesce((r_ca.net / nullif(r_ca.ideal_production,0)) / (nullif(r_ca.running_time::float / nullif(r_ca.available_time,0) * (r_ca.net::float / nullif(r_ca.gross,0)),0)),0),
							proportional_target = r_ca.target,
							recalc_needed = false
						where id_site = r.id_site
							and ts_value = r.ts_value;
					end if;

				-- update site_runtime_1day to require recalculation
				update site_runtime_1day
					set recalc_needed = true
					where id_site = r.id_site
						and ts_value = (select ts_value_production from piot_get_day_begin_by_site(r.id_site, r.ts_value));


		end loop;
		-- set all data from current hour to recalc needed
		update site_runtime_1hour
			set recalc_needed = true,
				proportional_target = target * (select extract(minute from now()) / 60)
			where ts_value >= date_trunc('hour', now())::timestamptz and ts_value <= now();
	end


-- ########piot_get_site_runtime_1day_production

	DECLARE
		r RECORD;
		rec RECORD;
	begin
		FOR r in
			select * from site_runtime_1day d
				where recalc_needed
					and ts_value >= (NOW() - INTERVAL  '1 month' )
					and ts_value <= now() 
				order by d.id_site, ts_value
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
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap,
				avg(speed) as speed,
				sum(proportional_target) as proportional_target
			into rec
				from area_runtime_1day ard
					join areas e on ard.id_area = e.id_area
					where e.id_site  = r.id_site 
						and ard.ts_value = r.ts_value;
			if found then
				update site_runtime_1day
					set available_time = coalesce(rec.available_time,0),
						running_time = coalesce(rec.running_time,0),
						stopped_time = coalesce(rec.stopped_time,0),
						planned_downtime = coalesce(rec.planned_downtime,0),
						ideal_production = coalesce(rec.ideal_production, 0),
						idle_time = coalesce(rec.idle_time,0),
						idle_starved = coalesce(rec.idle_starved,0),
						idle_blocked = coalesce(rec.idle_blocked,0),
						target = coalesce(rec.target,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						scrap = coalesce(rec.scrap,0),
						downtime = coalesce(rec.downtime,0),
						changeover_time = coalesce(rec.changeover_time,0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time::float / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net::float / nullif(rec.gross,0), 0),
						proportional_target = coalesce(rec.proportional_target,0)
					where id_site = r.id_site
						and ts_value = r.ts_value;
				update site_runtime_1day e
					set oee_p = coalesce(e.oee::float / nullif(e.oee_a * e.oee_q,0), 0)
					where id_site = r.id_site
						and ts_value = r.ts_value;
			end if;
			-- update equipment_runtime_1day to require recalculation
			update site_runtime_1month
				set recalc_needed = true
				where id_site = r.id_site
					and ts_value = date_trunc('month', r.ts_value);
			-- update equipment_runtime_1week to require recalculation
			update site_runtime_1month
				set recalc_needed = true
				where id_site = r.id_site
					and ts_value = date_trunc('week', r.ts_value);
		end loop;
		update site_runtime_1day
			set recalc_needed = true
			where ts_value >= (select ts_value_production from piot_get_day_begin_by_site(id_site, now()))
				and ts_value < (select ts_value_production from piot_get_day_begin_by_site(id_site, now() + interval '1 day'));
	end


-- ########piot_get_site_runtime_1week_production

	DECLARE
		r RECORD;
		rec RECORD;
	begin
		FOR r in
		select *
			from site_runtime_1week d
				where ts_value < now()
				and ts_value >= now() - interval '1 month' 
				and recalc_needed
			order by id_site, ts_value 
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
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap,
				avg(speed) as speed,
				sum(proportional_target) as proportional_target
			into rec
				from site_runtime_1day ard
					where ard.id_site = r.id_site
						and ard.ts_value >= date_trunc('week', r.ts_value)
						and ard.ts_value <= r.ts_value + interval '1 week';
			if found then
				update site_runtime_1week
					set available_time = coalesce(rec.available_time, 0),
						running_time = coalesce(rec.running_time, 0),
						stopped_time = coalesce(rec.stopped_time, 0),
						planned_downtime = coalesce(rec.planned_downtime, 0),
						ideal_production = coalesce(rec.ideal_production, 0),
						idle_time = coalesce(rec.idle_time, 0),
						idle_starved = coalesce(rec.idle_starved, 0),
						idle_blocked = coalesce(rec.idle_blocked, 0),
						target = coalesce(rec.target,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						downtime = coalesce(rec.downtime, 0),
						changeover_time = coalesce(rec.changeover_time, 0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time::float / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net::float / nullif(rec.gross,0), 0),
						proportional_target = coalesce(rec.proportional_target,0)
					where id_site = r.id_site
						and ts_value = r.ts_value;
				update site_runtime_1week e
					set oee_p = coalesce(e.oee::float / nullif(e.oee_a * e.oee_q,0), 0)
					where id_site = r.id_site
						and ts_value = r.ts_value;
			end if;
		end loop;
		-- set all data from current month to recalc needed
		update site_runtime_1week
			set recalc_needed = true
			where ts_value >= date_trunc('month', now()) 
				and ts_value <= now() + interval '1 month';
	end


-- ########piot_get_site_runtime_1month_production

	DECLARE
		r RECORD;
		rec RECORD;
	begin
		FOR r in
		select *
			from site_runtime_1month d
				where ts_value < now()
				and ts_value >= now() - interval '1 month' 
				and recalc_needed
			order by id_site, ts_value 
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
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap,
				avg(speed) as speed,
				sum(proportional_target) as proportional_target
			into rec
				from site_runtime_1day ard
					where ard.id_site = r.id_site
						and ard.ts_value >= date_trunc('month', r.ts_value)
						and ard.ts_value <= r.ts_value + interval '1 month';
			if found then
				update site_runtime_1month
					set available_time = coalesce(rec.available_time, 0),
						running_time = coalesce(rec.running_time, 0),
						stopped_time = coalesce(rec.stopped_time, 0),
						planned_downtime = coalesce(rec.planned_downtime, 0),
						ideal_production = coalesce(rec.ideal_production, 0),
						idle_time = coalesce(rec.idle_time, 0),
						idle_starved = coalesce(rec.idle_starved, 0),
						idle_blocked = coalesce(rec.idle_blocked, 0),
						target = coalesce(rec.target,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						downtime = coalesce(rec.downtime, 0),
						changeover_time = coalesce(rec.changeover_time, 0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time::float / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net::float / nullif(rec.gross,0), 0),
						proportional_target = coalesce(rec.proportional_target,0)
					where id_site = r.id_site
						and ts_value = r.ts_value;
				update site_runtime_1month e
					set oee_p = coalesce(e.oee::float / nullif(e.oee_a * e.oee_q,0), 0)
					where id_site = r.id_site
						and ts_value = r.ts_value;
			end if;
		end loop;
		update site_runtime_1month
			set recalc_needed = true
			where ts_value >= DATE_TRUNC('month',(now()))
				and ts_value < DATE_TRUNC('month',now() + interval '1 month');
	end


-- ########piot_get_site_runtime_shift_production

	DECLARE
		r RECORD;
		rec RECORD;
	begin
		FOR r in
			select * from site_runtime_shift d
				where recalc_needed
					and ts_value >= (NOW() - INTERVAL  '1 month' )
					and ts_value <= now() 
				order by d.id_site, ts_value
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
				sum(target) as target,
				sum(gross) as gross,
				sum(net) as net,
				sum(downtime) as downtime,
				sum(changeover_time) as changeover_time,
				sum(scrap) as scrap
			into rec
				from area_runtime_shift ard
					join areas e on ard.id_area = e.id_area
					where e.id_site  = r.id_site 
						and ard.ts_value = r.ts_value;
			if found then
				update site_runtime_shift
					set available_time = coalesce(rec.available_time,0),
						running_time = coalesce(rec.running_time,0),
						stopped_time = coalesce(rec.stopped_time,0),
						planned_downtime = coalesce(rec.planned_downtime,0),
						ideal_production = coalesce(rec.ideal_production, 0),
						idle_time = coalesce(rec.idle_time,0),
						idle_starved = coalesce(rec.idle_starved,0),
						idle_blocked = coalesce(rec.idle_blocked,0),
						target = coalesce(rec.target,0),
						gross = coalesce(rec.gross,0),
						net = coalesce(rec.net,0),
						scrap = coalesce(rec.scrap,0),
						downtime = coalesce(rec.downtime,0),
						changeover_time = coalesce(rec.changeover_time,0),
						recalc_needed = false,
						oee = coalesce(rec.net / nullif(rec.ideal_production ,0), 0),
						oee_a = coalesce(rec.running_time::float / nullif((rec.total_time - rec.planned_downtime),0), 0),
						oee_q = coalesce(rec.net::float / nullif(rec.gross,0), 0)
					where id_site = r.id_site
						and ts_value = r.ts_value;
				update site_runtime_shift e
					set oee_p = coalesce(e.oee::float / nullif(e.oee_a * e.oee_q,0), 0)
					where id_site = r.id_site
						and ts_value = r.ts_value;
			end if;
		end loop;
		update site_runtime_shift
			set recalc_needed = true
			where ts_value_production >= (select ts_value_production from piot_get_day_begin_by_site(id_site, now()))
				and ts_value_production < (select ts_value_production from piot_get_day_begin_by_site(id_site, now() + interval '1 day'));
	end

