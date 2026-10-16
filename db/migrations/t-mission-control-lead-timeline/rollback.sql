-- rollback: both functions as before t-mission-control-lead-timeline (verbatim).
BEGIN;
CREATE OR REPLACE FUNCTION serving.mission_control(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text)
 RETURNS SETOF mission_control_row
 LANGUAGE plpgsql
 STABLE
AS $function$
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
		uecs.prev2_shift_name,
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
		uecs.prev2_net_production AS prev2shift_netprod,
		uecs.scrap AS curshift_scrap,
		uecs.planned_downtime,
		uecm.planned_perc_stops_24h as planned_duration_percent,
		uecs.change_over_duration,
		uecm.change_over_perc_stops_24h as change_over_duration_percent,
		uecs.unplanned_downtime as unplanned_duration,
		uecm.unplanned_perc_stops_24h as unplanned_duration_percent,
		uecs.stopped_time,
		(select array_agg(sub.situation order by sub.ts_value)
		 from (
			select m.bucket as ts_value,
				case
					when coalesce(m.sum_speed / nullif(m.cnt_speed,0), 0) >= (e.minimum_ideal_performance_threshold / 100.0 * e.production_speed::double precision) then 'running'
					when coalesce(m.sum_speed / nullif(m.cnt_speed,0), 0) >= (e.minimum_performance_threshold / 100.0 * e.production_speed::double precision) then 'lowSpeed'
					else 'stopped'
				end as situation
			from silver.equipment_metrics_1min m
			join equipments e on e.id_equipment = m.id_equipment
			where m.id_equipment = uecm.id_equipment
				and m.tp_equipment = 3
				and m.bucket >= now() - '24:01:00'::interval
				and m.bucket <  now() - '00:01:00'::interval
		 ) sub) as status_24h,
		uecm.status,
		uecm.status_time,
		uecs.proportional_target,
		uecs.prev1_target,
		uecs.prev2_target,
		uecj.current_expected_time::float8 as job_remaining_time
	from equipment_live_job uecj
	join equipment_live_shift uecs on (uecs.id_equipment=uecj.id_equipment)
	join equipment_live_metrics uecm on (uecm.id_equipment=uecj.id_equipment)
	where
		uecm.id_site = any (ids_sites)
		and uecm.id_area = any (ids_areas)
		and uecm.id_equipment = any (ids_equips);

	end
$function$;
CREATE OR REPLACE FUNCTION serving.mission_control_timeline(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text)
 RETURNS SETOF mission_control_timeline_row
 LANGUAGE plpgsql
 STABLE
AS $function$
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
				dt.id_equipment,
            	array_agg(dt.situation ORDER BY dt.ts_value) AS timelinestatus
           FROM (
           		SELECT
           			aaa.ts_value,
                    aaa.id_equipment,
                        CASE
                            WHEN COALESCE(aaa.speed, 0.0::double precision) >= (e.minimum_ideal_performance_threshold / 100.0 * e.production_speed::double precision) THEN 'running'::text
                            WHEN COALESCE(aaa.speed, 0.0::double precision) < (e.minimum_ideal_performance_threshold / 100.0 * e.production_speed::double precision) AND COALESCE(aaa.speed, 0.0::double precision) >= (e.minimum_performance_threshold / 100.0 * e.production_speed::double precision) THEN 'lowSpeed'::text
                            WHEN COALESCE(aaa.speed, 0::double precision) < (e.minimum_performance_threshold / 100.0 * e.production_speed::double precision) THEN 'stopped'::text
                            ELSE NULL::text
                        END AS situation
                   FROM (select bucket as ts_value, id_equipment, tp_equipment, (sum_speed/nullif(cnt_speed,0)) as speed from silver.equipment_metrics_1min aaa
                   where
                   			id_enterprise = in_id_enterprise
                   		and id_site = any (ids_sites)
                   		and id_area = any (ids_areas)
                   		and id_equipment = any (ids_equips)
                   		) aaa
                     LEFT JOIN equipments e USING (id_equipment)
                  WHERE aaa.ts_value >= (now() - '24:01:00'::interval) AND aaa.ts_value < (now() - '00:01:00'::interval) AND aaa.tp_equipment = 3
           ) dt
           GROUP BY dt.id_equipment;


end
$function$;
COMMIT;
