-- t-mission-control-lead-timeline — Mission Control timeline empty/all-red for counters-only lines.
--
-- serving.mission_control.status_24h and serving.mission_control_timeline built the 24 h status
-- strictly from the LINE's own silver.equipment_metrics_1min (tp_equipment = 3). Counters-only /
-- line-lead lines carry no line metrics (Bispharma: 0 of 23 lines; CPACK: 6 of 20), so the
-- timeline was NULL/empty and front4 rendered it all red.
-- FIX: per line, use its own 1-min speed when it has any in the window, else its LEAD machine's
-- (the same 'a line borrows its lead's stream' model as the line-lead OEE). Thresholds stay the
-- line's percentages, over the rated speed of the stream used (lead production_speed when
-- lead-sourced). Lines with their own metrics are byte-identical (CPACK 14/14 unchanged, both fns);
-- Bispharma 0 → 21 lines with a real 24 h timeline (2 remaining = offline PLCs); every other
-- mission_control column identical.
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

		-- Per-minute status of each LINE: its own 1-min speed when it has any in the window;
		-- otherwise its LEAD machine's (counters-only / line-lead lines carry no line metrics →
		-- the timeline was empty → rendered all red). Thresholds = the LINE's percentages over
		-- the rated speed of the stream used (lead production_speed for lead-sourced minutes).
		-- The 3-way CASE (incl. NULL when thresholds are NULL) is kept verbatim.
		select
				dt.id_equipment,
            	array_agg(dt.situation ORDER BY dt.ts_value) AS timelinestatus
           FROM (
           		SELECT
           			m.bucket AS ts_value,
                    l.id_equipment,
                        CASE
                            WHEN COALESCE(m.sum_speed / nullif(m.cnt_speed,0), 0.0::double precision) >= (l.minimum_ideal_performance_threshold / 100.0 * src.rated::double precision) THEN 'running'::text
                            WHEN COALESCE(m.sum_speed / nullif(m.cnt_speed,0), 0.0::double precision) < (l.minimum_ideal_performance_threshold / 100.0 * src.rated::double precision) AND COALESCE(m.sum_speed / nullif(m.cnt_speed,0), 0.0::double precision) >= (l.minimum_performance_threshold / 100.0 * src.rated::double precision) THEN 'lowSpeed'::text
                            WHEN COALESCE(m.sum_speed / nullif(m.cnt_speed,0), 0::double precision) < (l.minimum_performance_threshold / 100.0 * src.rated::double precision) THEN 'stopped'::text
                            ELSE NULL::text
                        END AS situation
                   FROM equipments l
                   CROSS JOIN LATERAL (
                        SELECT CASE WHEN own.has THEN l.id_equipment ELSE l.lead_machine END AS id_src,
                               CASE WHEN own.has THEN l.production_speed
                                    ELSE COALESCE((SELECT q.production_speed FROM equipments q WHERE q.id_equipment = l.lead_machine), l.production_speed) END AS rated
                          FROM (SELECT EXISTS (SELECT 1 FROM silver.equipment_metrics_1min x
                                                WHERE x.id_equipment = l.id_equipment
                                                  AND x.bucket >= (now() - '24:01:00'::interval)) AS has) own
                   ) src
                   JOIN silver.equipment_metrics_1min m ON m.id_equipment = src.id_src
                  WHERE l.id_enterprise = in_id_enterprise
                    AND l.tp_equipment = 3
                    AND l.id_site = any (ids_sites)
                    AND l.id_area = any (ids_areas)
                    AND l.id_equipment = any (ids_equips)
                    AND m.bucket >= (now() - '24:01:00'::interval) AND m.bucket < (now() - '00:01:00'::interval)
           ) dt
           GROUP BY dt.id_equipment;


end
$function$;
COMMIT;
