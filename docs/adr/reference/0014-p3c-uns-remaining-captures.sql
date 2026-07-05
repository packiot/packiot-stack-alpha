-- Remaining UNS refresher bodies + PO dispatcher (captured 2026-07-04).
-- ########piot_uns_area_refresh_current_day

begin
	-- current day
	with prod as
		(
			SELECT id_area, ts_value, 
				(net) net_production_incr,
				(gross) gross_production_incr,
				(scrap) scrap_incr,
				oee,
				oee_p,
				oee_a,
				oee_q,
				available_time, 
				running_time, 
				stopped_time, 
				planned_downtime, 
				ideal_production, 
				idle_time, 
				idle_starved, 
				idle_blocked, 
				target,  
				downtime, 
				changeover_time,
				proportional_target
			from area_runtime_1day v 
			where ts_value>= date_trunc('day', now())::timestamptz and ts_value <= now()
			group by id_area, ts_value 
			order by id_area, ts_value
		)
	UPDATE uns_area_current_day u
		SET  gross_production = p.gross_production_incr,
			net_production = p.net_production_incr,
			scrap = p.scrap_incr,
			--target = p.production_programmed,
			begin_time = p.ts_value,
			end_time = p.ts_value + interval '1 day',
			oee = p.oee,
			oee_p = p.oee_p,
			oee_a = p.oee_a,
			oee_q = p.oee_q,
			available_time = p.available_time,
			running_time = p.running_time,
			stopped_time = p.stopped_time,
			planned_downtime = p.planned_downtime,
			ideal_production = p.ideal_production,
			idle_time = p.idle_time,
			idle_starved = p.idle_starved,
			idle_blocked = p.idle_blocked,
			target = p.target,
			proportional_target = p.proportional_target
		from prod p
		where u.id_area = p.id_area;

end 

-- ########piot_uns_area_refresh_current_shift

begin
	-- current shift
	with ts as 
	(
		select id_area, ts_value 
			from
			(select id_area, 
							(select ts_begin from piot_get_shift_hour_begin_by_area(id_area, now())) as ts_value
						from areas e 
						join enterprises et on e.id_enterprise = et.id_enterprise and et.active
						order by id_area) s1
					where ts_value is not null
	) ,
	prod as
		(
			SELECT v.id_area, v.ts_value, 
				(net) net_production_incr,
				(gross) gross_production_incr,
				(scrap) scrap_incr,
				oee,
				oee_p,
				oee_a,
				oee_q,
				available_time, 
				running_time, 
				stopped_time, 
				planned_downtime, 
				ideal_production, 
				idle_time, 
				idle_starved, 
				idle_blocked, 
				target,  
				downtime, 
				changeover_time,
				id_shift,
				id_shift_hour,
				ts_end,
				duration,
				proportional_target
			from area_runtime_shift v 
				join ts on v.id_area = ts.id_area and v.ts_value = ts.ts_value
			group by v.id_area, v.ts_value 
			order by v.id_area, v.ts_value
		),
	prod1 as
		(
			SELECT v.id_area, v.ts_value, 
				(net) net_production_incr,
				(gross) gross_production_incr,
				(scrap) scrap_incr,
				oee,
				oee_p,
				oee_a,
				oee_q, 
				target,  
				id_shift,
				id_shift_hour,
				ts_end,
				duration
			from area_runtime_shift v 
				join ts on v.id_area = ts.id_area and v.ts_value = ts.ts_value - (interval '1 second' * v.duration)
			group by v.id_area, v.ts_value 
			order by v.id_area, v.ts_value --desc limit 1
		)
	UPDATE uns_area_current_shift u
		SET  gross_production = p.gross_production_incr,
			net_production = p.net_production_incr,
			scrap = p.scrap_incr,
			target = p.target,
			oee = p.oee,
			oee_p = p.oee_p,
			oee_a = p.oee_a,
			oee_q = p.oee_q,
			available_time = p.available_time,
			running_time = p.running_time,
			stopped_time = p.stopped_time,
			planned_downtime = p.planned_downtime,
			ideal_production = p.ideal_production,
			idle_time = p.idle_time,
			idle_starved = p.idle_starved,
			idle_blocked = p.idle_blocked,
			id_shift = p.id_shift,
			id_shift_hour = p.id_shift_hour,
			begin_time = p.ts_value,
			end_time = p.ts_end,
			duration = p.duration,
			proportional_target = p.proportional_target,
			prev1_oee = p1.oee,
			prev1_oee_a = p1.oee_a,
			prev1_oee_p = p1.oee_p,
			prev1_oee_q = p1.oee_q,
			prev1_gross_production = p1.gross_production_incr,
			prev1_net_production = p1.net_production_incr,
			prev1_scrap = p1.scrap_incr,
			prev1_target = p1.target,
			prev1_begin_time = p1.ts_value,
			prev1_end_time = p1.ts_end,
			prev1_id_shift = p1.id_shift,
			prev1_id_shift_hour = p1.id_shift_hour,
			prev1_duration = p1.duration,
			elapsed_time = extract(epoch from (now() - p.ts_value))
		from prod p
			join prod1 p1 on p.id_area = p1.id_area
		where u.id_area = p.id_area;

end 

-- ########piot_uns_area_refresh_current_week

begin
	with currentData as ( 
		select * from area_runtime_1week erw inner join equipments e using(id_area)
			join public.piot_get_shift_hour_list_by_equipment(e.id_enterprise, e.id_equipment) using(id_area, id_equipment, id_enterprise)
			where ts_value >= date_trunc('week', now())::date 
			and ts_value < date_trunc('week', now() + interval '1 week')::date
			and e.tp_equipment = 3
			--order by id_equipment, ts_value 
		)
		update uns_area_current_week w
			set	gross_production = c.gross,
				net_production = c.net,
				scrap = c.scrap,
				--speed = c.speed,
				begin_time = ts_value,
				end_time = date_trunc('week', now()+ interval '1 week'),
				elapsed_time = (select extract(epoch from now() - ts_value) from piot_get_day_begin_by_equipment(c.id_equipment, date_trunc('week', now())) ),
				target = c.target,
				proportional_target = (select c.target * ( select extract(epoch from now() - ts_value )
				        from piot_get_day_begin_by_equipment(c.id_equipment, date_trunc('week', now())))  /
			        (select sum(shift_size) from piot_get_shift_hour_list_by_equipment(c.id_enterprise, c.id_equipment)) ),
				idle_time = c.idle_time,
				idle_blocked = c.idle_blocked,
				idle_starved = c.idle_starved,
				running_time = c.running_time,
				stopped_time = c.stopped_time,
				available_time = c.available_time,
				planned_downtime = c.planned_downtime,
				ideal_production = c.ideal_production,
				oee = c.oee,
				oee_a = c.oee_a,
				oee_p = c.oee_p,
				oee_q = c.oee_q
			from currentData c 
			where w.id_area = c.id_area;
	end


-- ########piot_uns_area_refresh_current_month

begin	
	with prod as
		(
			SELECT 
				id_area, ts_value,
				sum(net) net_production_incr,
				sum(gross) gross_production_incr,
				sum(scrap) scrap_incr,
				oee,
				oee_a,
				oee_p,
				oee_q,
				available_time,
				running_time,
				stopped_time,
				planned_downtime,
				ideal_production,
				idle_time,
				idle_starved,
				idle_blocked,
				target,
				extract( epoch from (now() - ts_value)) as elapsed_time,
				(target*(extract( epoch from (now() - ts_value))))/ (extract( epoch from ((date_trunc('month', now())+interval'1 month')-(date_trunc('month', now())))))  as proportional_target,
				(ideal_production*(extract( epoch from (now() - ts_value))))/(extract( epoch from ((date_trunc('month', now())+interval'1 month')-(date_trunc('month', now()))))) as proportional_ideal_production
			from area_runtime_1month erh 
			where ts_value = date_trunc('month', now())::timestamptz
			group by id_area, ts_value 
			order by id_area, ts_value
		)
--		select * from prod;
	UPDATE uns_area_current_month u
		SET 
			gross_production = p.gross_production_incr,
			net_production = p.net_production_incr,
			scrap = p.scrap_incr,
			oee = p.oee,
			oee_a = p.oee_a,
			oee_p = p.oee_p,
			oee_q = p.oee_q,
			available_time = p.available_time,
			running_time = p.running_time,
			stopped_time = p.stopped_time,
			planned_downtime = p.planned_downtime,
			ideal_production = p.ideal_production,
			idle_time = p.idle_time,
			idle_starved = p.idle_starved,
			idle_blocked = p.idle_blocked,
			target = p.target,
			elapsed_time = p.elapsed_time,
			proportional_target = p.proportional_target,
			proportional_ideal_production = p.proportional_ideal_production 
		from prod p
		where u.id_area = p.id_area;
end 

-- ########piot_uns_site_refresh_current_day

begin
	-- current day
	with prod as
		(
			SELECT id_site, ts_value, 
				(net) net_production_incr,
				(gross) gross_production_incr,
				(scrap) scrap_incr,
				oee,
				oee_p,
				oee_a,
				oee_q,
				available_time, 
				running_time, 
				stopped_time, 
				planned_downtime, 
				ideal_production, 
				idle_time, 
				idle_starved, 
				idle_blocked, 
				target,  
				downtime, 
				changeover_time,
				proportional_target
			from site_runtime_1day v 
			where ts_value>= date_trunc('day', now())::timestamptz and ts_value <= now()
			group by id_site, ts_value 
			order by id_site, ts_value
		)
	UPDATE uns_site_current_day u
		SET  gross_production = p.gross_production_incr,
			net_production = p.net_production_incr,
			scrap = p.scrap_incr,
			--target = p.production_programmed,
			begin_time = p.ts_value,
			end_time = p.ts_value + interval '1 day',
			oee = p.oee,
			oee_p = p.oee_p,
			oee_a = p.oee_a,
			oee_q = p.oee_q,
			available_time = p.available_time,
			running_time = p.running_time,
			stopped_time = p.stopped_time,
			planned_downtime = p.planned_downtime,
			ideal_production = p.ideal_production,
			idle_time = p.idle_time,
			idle_starved = p.idle_starved,
			idle_blocked = p.idle_blocked,
			target = p.target,
			proportional_target = p.proportional_target
		from prod p
		where u.id_site = p.id_site;

end 

-- ########piot_uns_site_refresh_current_week

begin
	with currentData as ( 
		select * from site_runtime_1week erw inner join equipments e using(id_site)
			join public.piot_get_shift_hour_list_by_equipment(e.id_enterprise, e.id_equipment) using(id_site, id_equipment, id_enterprise)
			where ts_value >= date_trunc('week', now())::date 
			and ts_value < date_trunc('week', now() + interval '1 week')::date
			and e.tp_equipment = 3
			--order by id_equipment, ts_value 
		)
		update uns_site_current_week w
			set	gross_production = c.gross,
				net_production = c.net,
				scrap = c.scrap,
				--speed = c.speed,
				begin_time = ts_value,
				end_time = date_trunc('week', now()+ interval '1 week'),
				elapsed_time = (select extract(epoch from now() - ts_value) from piot_get_day_begin_by_equipment(c.id_equipment, date_trunc('week', now())) ),
				target = c.target,
				proportional_target = (select c.target * ( select extract(epoch from now() - ts_value )
				        from piot_get_day_begin_by_equipment(c.id_equipment, date_trunc('week', now())))  /
			        (select sum(shift_size) from piot_get_shift_hour_list_by_equipment(c.id_enterprise, c.id_equipment)) ),
				idle_time = c.idle_time,
				idle_blocked = c.idle_blocked,
				idle_starved = c.idle_starved,
				running_time = c.running_time,
				stopped_time = c.stopped_time,
				available_time = c.available_time,
				planned_downtime = c.planned_downtime,
				ideal_production = c.ideal_production,
				oee = c.oee,
				oee_a = c.oee_a,
				oee_p = c.oee_p,
				oee_q = c.oee_q
			from currentData c 
			where w.id_site = c.id_site;
	end


-- ########piot_uns_site_refresh_current_month

begin	
	with prod as
		(
			SELECT 
				id_site, ts_value,
				sum(net) net_production_incr,
				sum(gross) gross_production_incr,
				sum(scrap) scrap_incr,
				oee,
				oee_a,
				oee_p,
				oee_q,
				available_time,
				running_time,
				stopped_time,
				planned_downtime,
				ideal_production,
				idle_time,
				idle_starved,
				idle_blocked,
				target,
				extract( epoch from (now() - ts_value)) as elapsed_time,
				(target*(extract( epoch from (now() - ts_value))))/ (extract( epoch from ((date_trunc('month', now())+interval'1 month')-(date_trunc('month', now())))))  as proportional_target,
				(ideal_production*(extract( epoch from (now() - ts_value))))/(extract( epoch from ((date_trunc('month', now())+interval'1 month')-(date_trunc('month', now()))))) as proportional_ideal_production
			from site_runtime_1month erh 
			where ts_value = date_trunc('month', now())::timestamptz
			group by id_site, ts_value 
			order by id_site, ts_value
		)
--		select * from prod;
	UPDATE uns_site_current_month u
		SET 
			gross_production = p.gross_production_incr,
			net_production = p.net_production_incr,
			scrap = p.scrap_incr,
			oee = p.oee,
			oee_a = p.oee_a,
			oee_p = p.oee_p,
			oee_q = p.oee_q,
			available_time = p.available_time,
			running_time = p.running_time,
			stopped_time = p.stopped_time,
			planned_downtime = p.planned_downtime,
			ideal_production = p.ideal_production,
			idle_time = p.idle_time,
			idle_starved = p.idle_starved,
			idle_blocked = p.idle_blocked,
			target = p.target,
			elapsed_time = p.elapsed_time,
			proportional_target = p.proportional_target,
			proportional_ideal_production = p.proportional_ideal_production 
		from prod p
		where u.id_site = p.id_site;
end 

-- ########piot_uns_refresh_current_jobs

declare 
	idle integer := 0;
	r record;
	r_prev record;
begin
	FOR r IN 
		with po as
		(
			select 
					id_production_order, id_order, id_equipment,
					id_area, id_site,
					p.nm_product, pf.nm_product_family, c.nm_client 
				from production_orders po
				join products p on po.id_product = p.id_product 
				join product_families pf on pf.id_product_family = p.id_product_family
				join clients c on c.id_client = po.id_client 
				where status = 2 and po.id_enterprise = in_id_enterprise
		)
		SELECT v.id_equipment, cd_equipment, v.id_production_order, id_order, 
				nm_product, nm_product_family, nm_client ,
				a.nm_area , s.nm_site ,
				sum(v.net_production_incr) net_production_incr,
				sum(v.gross_production_incr) gross_production_incr,
				sum(v.scrap_incr) scrap_incr
			from v_agg_equipment_values_1day_full v 
			join po on po.id_production_order = v.id_production_order
			join areas a on v.id_area = a.id_area 
			join sites s on a.id_site = s.id_site 
			join equipments e on v.id_equipment = e.id_equipment 
			where v.ts_value>= date_trunc('day', now())::date - interval '20 day'  and v.id_enterprise = in_id_enterprise
			group by v.id_equipment, cd_equipment, v.id_production_order, id_order,
				nm_product, nm_product_family, nm_client ,
				a.nm_area , s.nm_site 
			order by 1, 2, 3
	loop
		UPDATE uns 
			SET uns_data = jsonb_set(uns_data,('{sites,' || r.nm_site || ',areas,' || r.nm_area || ',lines,' || r.cd_equipment || ',current_job,net_production}'), ('''' || r.net_production_incr ||'''')::jsonb) 
			where id_enterprise = in_id_enterprise;
		commit;
		
	end loop;
end 

-- ########piot_proc_refresh_production_orders


begin

	
	begin
		--perform piot_get_equipment_production_order_runtime();
		perform piot_get_equipment_production_order_runtime_test();
	EXCEPTION WHEN OTHERS then commit;
	END;
	commit;
	begin
		perform piot_get_equipment_production_order_runtime_final();
	EXCEPTION WHEN OTHERS then commit;
	END;
	commit;
	begin
    	-- perform piot_uns_equipment_refresh_current_jobs();
		perform piot_uns_equipment_refresh_current_jobs_without_equipment_value();
	EXCEPTION WHEN OTHERS then perform 1;
	END;
end 
