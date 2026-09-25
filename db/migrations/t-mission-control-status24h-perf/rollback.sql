-- Restores the pre-fix definition (slow status_24h from t-mission-control-lead-timeline).
CREATE OR REPLACE FUNCTION serving.mission_control(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text)
 RETURNS SETOF mission_control_row
 LANGUAGE plpgsql
 STABLE
AS $function$;
declare
	ids_sites int[] := (select array_agg(id_site)
						from sites s
						where s.id_enterprise=in_id_enterprise
						and case
							when cardinality(in_ids_sites::int[]) = 0 then true
							else id_site = any( in_ids_sites::int[])
						end);
	ids_areas int[] := (select array_agg(id_area)
						from areas s
						where s.id_enterprise=in_id_enterprise
						and case
							when cardinality(in_ids_areas::int[]) = 0 then true
							else id_area = any( in_ids_areas::int[])
						end);
	ids_equips int[] := (select array_agg(id_equipment)
						from equipments s
						where s.id_enterprise=in_id_enterprise
						and s.tp_equipment=3
						and case
							when cardinality(in_ids_equipments::int[]) = 0 then true
							else id_equipment = any( in_ids_equipments::int[])
						end);
begin
return query


   select
	uecm.id_site,
		uecm.id_area,
		uecm.nm_area,
		uecm.id_equipment AS id_line,
		uecm.nm_equipment AS nm_line,
		uecm.id_enterprise,
		uecs.oee AS currshift_oee,
		uecs.shift_name AS curr_shift_name,
		uecs.prev1_shift_name,
		COALESCE(uecs.prev2_shift_name, p2.shift_name::varchar) AS prev2_shift_name,
		uecj.id_order,
		uecj.target AS production_programmed,
		uecj.net_production AS po_net_production,
		uecj.nm_client,
		uecj.elapsed_time AS duration,
		uecj.current_expected_time AS expected_time,
		uecm.speed::real,
		uecs.gross_production AS curshift_grosprod,
		uecs.net_production AS curshift_netprod,
		uecs.prev1_net_production AS prev1shift_netprod,
		COALESCE(uecs.prev2_net_production, p2.net::real) AS prev2shift_netprod,
		uecs.scrap AS curshift_scrap,
		uecs.planned_downtime,
		uecm.planned_perc_stops_24h as planned_duration_percent,
		uecs.change_over_duration,
		uecm.change_over_perc_stops_24h as change_over_duration_percent,
		uecs.unplanned_downtime as unplanned_duration,
		uecm.unplanned_perc_stops_24h as unplanned_duration_percent,
		uecs.stopped_time,
		-- status_24h: the LINE's own 1-min speed when it has any; otherwise its LEAD machine's
		-- (counters-only / line-lead lines — all of Bispharma, 6 CPACK lines — carry no line
		-- metrics, so the timeline was NULL → rendered all red). Thresholds stay the LINE's
		-- percentages, applied to the rated speed of whichever stream is used (the lead's
		-- production_speed for lead-sourced minutes, matching the line-lead OEE model).
		(select array_agg(sub.situation order by sub.ts_value)
		 from (
			select m.bucket as ts_value,
				case
					when coalesce(m.sum_speed / nullif(m.cnt_speed,0), 0) >= (l.minimum_ideal_performance_threshold / 100.0 * src.rated::double precision) then 'running'
					when coalesce(m.sum_speed / nullif(m.cnt_speed,0), 0) >= (l.minimum_performance_threshold / 100.0 * src.rated::double precision) then 'lowSpeed'
					else 'stopped'
				end as situation
			from equipments l
			cross join lateral (
				select case when exists (select 1 from silver.equipment_metrics_1min x
				                          where x.id_equipment = l.id_equipment
				                            and x.bucket >= now() - '24:01:00'::interval)
				            then l.id_equipment else l.lead_machine end as id_src,
				       case when exists (select 1 from silver.equipment_metrics_1min x
				                          where x.id_equipment = l.id_equipment
				                            and x.bucket >= now() - '24:01:00'::interval)
				            then l.production_speed
				            else coalesce((select q.production_speed from equipments q where q.id_equipment = l.lead_machine), l.production_speed) end as rated
			) src
			join silver.equipment_metrics_1min m on m.id_equipment = src.id_src
			where l.id_equipment = uecm.id_equipment
				and m.bucket >= now() - '24:01:00'::interval
				and m.bucket <  now() - '00:01:00'::interval
		 ) sub) as status_24h,
		uecm.status,
		uecm.status_time,
		uecs.proportional_target,
		uecs.prev1_target,
		COALESCE(uecs.prev2_target, p2.target::real) AS prev2_target,
		uecj.current_expected_time::float8 as job_remaining_time
	from equipment_live_job uecj
	join equipment_live_shift uecs on (uecs.id_equipment=uecj.id_equipment)
	join equipment_live_metrics uecm on (uecm.id_equipment=uecj.id_equipment)
	-- prev2 (the shift before prev1): the live-shift writer never populates prev2_* (always NULL →
	-- "null" in the Mission Control card). Take it from gold with the SAME semantics the live
	-- prev1_* follow (verified 43/43: prev1 = 2nd-latest gold shift row by ts_value → net, target,
	-- shifts.cd_shift), i.e. prev2 = the 3rd-latest. Live value wins if the writer ever fills it.
	left join lateral (
		select g.net, g.target, s.cd_shift as shift_name
		  from gold.equipment_oee_shift g
		  left join core.shifts s on s.id_shift = g.id_shift
		 where g.id_equipment = uecm.id_equipment and g.ts_value <= now()
		 order by g.ts_value desc
		 offset 2 limit 1
	) p2 on true
	where
		uecm.id_site = any (ids_sites)
		and uecm.id_area = any (ids_areas)
		and uecm.id_equipment = any (ids_equips);

	end
$function$;

	
