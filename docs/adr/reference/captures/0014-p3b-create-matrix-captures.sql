########piot_create_area_runtime_1day

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_area
			from areas e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..30 
			loop -- 30 days
				insert into area_runtime_1day(id_area, ts_value)
					select r.id_area, ts_value_production from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_area_runtime_1hour

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_area
			from areas e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..720 
			loop -- 30 days - 720 hours
				insert into area_runtime_1hour(id_area, ts_value)
					select r.id_area, date_trunc('hour', now() + interval '1 hour' * (i)) 
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_area_runtime_1month

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_area
			from areas e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..3
			loop -- 3 months
				insert into area_runtime_1month(id_area, ts_value)
					select r.id_area, date_trunc('month', ts_value_production) from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 month' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_area_runtime_1week

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_area
			from areas e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..12
			loop -- 12 weeks
				insert into area_runtime_1week(id_area, ts_value)
					select r.id_area, date_trunc('week', ts_value_production) from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 week' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_area_runtime_shift

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_area
			from areas e
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null
		loop
			time_now := now();
			for i in -16..180 
			loop -- 180 blocks of 4 hours in a month
				insert into area_runtime_shift(id_area, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
					select r.id_area, *, (select ts_value_production from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 hour' * (i * 4)) limit 1) 
					from piot_get_shift_hour_begin_by_area(r.id_area, time_now + interval '1 hour' * (i * 4))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_equipment_runtime_1day

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			time_now := now();
			for i in 0..30 
			loop -- 30 days
				insert into equipment_runtime_1day(id_equipment, ts_value)
					select r.id_equipment, ts_value_production from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_equipment_runtime_1hour



	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..722 
			loop -- 30 days - 720 hours
				
				insert into equipment_runtime_1hour (id_equipment, ts_value, target, ts_value_production)
				
					select r.id_equipment, date_trunc('hour', now() + interval '1 hour' * (i)), coalesce((select coalesce(vl_hour, vl_day/24) from production_targets pt where id_equipment = r.id_equipment),0)
						, date_trunc('day', (now() + interval '1 hour' * (i))::timestamptz at time zone (timezone) - interval '1 second' * (day_begin) ) at time zone (timezone) + interval '1 second' * (day_begin)
					from (
						select
							*
						from
							equipments
							join sites s using (id_site)
						where
							id_equipment = r.id_equipment
						) targets
					on conflict (id_equipment, ts_value)
						do update set
							target = CASE WHEN equipment_runtime_1hour.target_customized = false and (equipment_runtime_1hour.target <> EXCLUDED.target or equipment_runtime_1hour.target is null) THEN EXCLUDED.target ELSE equipment_runtime_1hour.target END,
							ts_value_production = EXCLUDED.ts_value_production
							where
								equipment_runtime_1hour.id_equipment  = r.id_equipment
								and equipment_runtime_1hour.ts_value = excluded.ts_value;
			end loop;
		end loop;
	end	
	

########piot_create_equipment_runtime_1month

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			time_now := now();
			for i in 0..3
			loop -- 3 months
				insert into equipment_runtime_1month(id_equipment, ts_value)
					select r.id_equipment, date_trunc('month', ts_value_production) from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 month' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_equipment_runtime_1week

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			time_now := now();
			for i in -200..30 
			loop -- 30 days
				insert into equipment_runtime_1week(id_equipment, ts_value)
					select r.id_equipment, date_trunc('week', ts_value_production) from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_equipment_runtime_shift

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			and e.id_enterprise not in (2,36,99,100,101,102,111,112,113,117)
			--where tp_equipment = 3 --and et.id_enterprise = 31
		loop
			time_now := now();
			for i in -4..180 -- Using -4 to create the previous 2 shitfs
			loop -- 180 blocks of 4 hours in a month
				insert into equipment_runtime_shift(id_equipment, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
				select r.id_equipment, e.*, (select ts_value_production from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 hour' * (i * 4)) limit 1) 
					from piot_get_shift_hour_begin_by_equipment(r.id_equipment, time_now + interval '1 hour' * (i * 4)) e
						left join shifts_exception_period sep on (r.id_equipment  = sep.id_equipment and e.ts_begin>=sep.ts_begin and e.ts_begin<sep.ts_end)
						where sep.id_equipment is null
					on conflict do NOTHING;
			end loop;

			update equipment_runtime_shift u
				set target = p.target_shift
			from (
				select id_equipment, ts_value_production, coalesce((duration/3600)*vl_hour,0) as target_shift --coalesce(vl_day/count(*), 0) as target_shift
				from equipment_runtime_shift ers
				join production_targets pt using (id_equipment)
				where id_equipment = r.id_equipment and ts_value > date_trunc('day', now()-interval '1 day')
				--group by ts_value_production, id_equipment, vl_day
			) p
					where
				u.target_customized = false
				and u.id_equipment = p.id_equipment 
				and u.ts_value_production = p.ts_value_production
				and u.ts_value >= now();

		end loop;
	end

########piot_create_equipment_runtime_shift_1month

	DECLARE
		r RECORD;
		i int;
	begin
		FOR r in
			select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			insert into equipment_runtime_shift_1month(ts_value, id_equipment, id_shift, duration, target)
				select 
					s1.ts_value,
					s1.id_equipment,
					s1.id_shift,
					duration,
					(erw.target * s1.duration)/ duration_of_all_shifts_in_month  as target --month target divided proportional to the duration of the shift
				from 
					(
					select 
						*,
						sum(duration) over (partition by id_equipment, ts_value) as duration_of_all_shifts_in_month
					from 
						(
						select
							date_trunc('month', ts_value) as ts_value,
							id_equipment,
							id_shift,
							sum(duration) as duration
						from equipment_runtime_shift_1month ers
						where 
							id_equipment = r.id_equipment
							and ts_value >= date_trunc('month', now())
						group by
							date_trunc('month', ts_value), id_equipment, id_shift
						order by ts_value
						)s0
					)s1
					left join equipment_runtime_1month erw using (ts_value, id_equipment)
				on conflict (id_equipment, ts_value, id_shift) DO UPDATE
					SET target = EXCLUDED.target;
		end loop;
	end

########piot_create_equipment_runtime_shift_1week

	DECLARE
		r RECORD;
		i int;
	begin
		FOR r in
			select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			insert into equipment_runtime_shift_1week(ts_value, id_equipment, id_shift, duration, target)
				select 
					s1.ts_value::date,
					s1.id_equipment,
					s1.id_shift,
					duration,
					(erw.target * s1.duration)/ duration_of_all_shifts_in_week  as target --Week target divided proportional to the duration of the shift
				from 
					(
					select 
						*,
						sum(duration) over (partition by id_equipment, ts_value) as duration_of_all_shifts_in_week
					from 
						(
						select
							date_trunc('week', ts_value) as ts_value,
							id_equipment,
							id_shift,
							sum(duration) as duration
						from equipment_runtime_shift_1week ers
						where 
							id_equipment = r.id_equipment
							and ts_value >= date_trunc('week', now())
						group by
							date_trunc('week', ts_value), id_equipment, id_shift
						order by ts_value
						)s0
					)s1
					left join equipment_runtime_1week erw using (ts_value, id_equipment)
				on conflict (id_equipment, ts_value, id_shift) do update
				SET target = EXCLUDED.target;
		end loop;
	end

########piot_create_site_runtime_1day

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_site
			from sites e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..30 
			loop -- 30 days
				insert into site_runtime_1day(id_site, ts_value)
					select r.id_site, ts_value_production from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_site_runtime_1hour

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_site
			from sites e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..720 
			loop -- 30 days - 720 hours
				insert into site_runtime_1hour(id_site, ts_value)
					select r.id_site, date_trunc('hour', now() + interval '1 hour' * (i)) 
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_site_runtime_1month

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_site
			from sites e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..3
			loop -- 3 months
				insert into site_runtime_1month(id_site, ts_value)
					select r.id_site, date_trunc('month', ts_value_production) from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 month' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_site_runtime_1week

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_site
			from sites e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..12
			loop -- 12 weeks
				insert into site_runtime_1week(id_site, ts_value)
					select r.id_site, date_trunc('week', ts_value_production) from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 week' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

########piot_create_site_runtime_shift

	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_site
			from sites e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..180 
			loop -- 180 blocks of 4 hours in a month
				insert into site_runtime_shift(id_site, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
					select r.id_site, *, (select ts_value_production from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 hour' * (i * 4)) limit 1) 
					from piot_get_shift_hour_begin_by_site(r.id_site, time_now + interval '1 hour' * (i * 4))
					on conflict do NOTHING;
			end loop;
		end loop;
	end

