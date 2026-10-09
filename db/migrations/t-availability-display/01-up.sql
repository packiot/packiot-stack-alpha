-- t-availability-display — show NO DATA / OUT OF SERVICE + coverage (2026-10-01)
--
-- Availability three-state policy, step 5 (display). The engine already leaves
-- out-of-service and no-data time out of availability (t-availability-exclusions,
-- stream-engine #1534). This makes it VISIBLE:
--   * serving.line_excluded_minutes(line, from, to): the minutes a line is out of
--     service (a CS window on the line or its parent) or has no data (its lead's
--     status-20 events), as 'outOfService' / 'noData'.
--   * Mission Control status_24h + timeline: those minutes take precedence over the
--     metric minute and minutes without metrics are added (they used to vanish, so
--     a dark line's bar showed only its few live minutes). Lines without exclusions
--     return exactly what they did before (the FULL JOIN adds nothing).
--   * serving.oee_score: + no_data_time / out_of_service_time (appended columns) so
--     the UI can show coverage = available / (available + no data).
BEGIN;

CREATE OR REPLACE FUNCTION serving.line_excluded_minutes(in_id_line bigint, in_from timestamptz, in_to timestamptz)
 RETURNS TABLE (bucket timestamptz, state text)
 LANGUAGE sql STABLE
AS $function$
  WITH l AS (
      SELECT e.id_equipment, e.id_parentequipment,
             CASE WHEN COALESCE(e.lead_machine, 0) > 0 THEN e.lead_machine ELSE e.id_equipment END AS nd_src
        FROM core.equipments e WHERE e.id_equipment = in_id_line
  ), oos AS (
      SELECT o.period FROM config.equipment_out_of_service o, l
       WHERE o.id_equipment IN (l.id_equipment, COALESCE(l.id_parentequipment, 0))
         AND o.period && tstzrange(in_from, in_to)
  ), nd AS (
      SELECT tstzrange(ev.ts_event,
                       COALESCE(ev.ts_end,
                                (SELECT min(n.ts_event) FROM silver.equipment_events n
                                  WHERE n.id_equipment = ev.id_equipment AND n.ts_event > ev.ts_event),
                                now())) AS period
        FROM silver.equipment_events ev, l
       WHERE ev.id_equipment = l.nd_src AND ev.status = 20
         AND ev.ts_event < in_to AND ev.ts_event >= in_from - interval '60 days'
  )
  SELECT g.b,
         CASE WHEN EXISTS (SELECT 1 FROM oos WHERE oos.period @> g.b) THEN 'outOfService' ELSE 'noData' END
    FROM generate_series(date_trunc('minute', in_from), in_to - interval '1 minute', interval '1 minute') AS g(b)
   WHERE (EXISTS (SELECT 1 FROM oos) OR EXISTS (SELECT 1 FROM nd))
     AND (EXISTS (SELECT 1 FROM oos WHERE oos.period @> g.b) OR EXISTS (SELECT 1 FROM nd WHERE nd.period @> g.b))
$function$;
COMMENT ON FUNCTION serving.line_excluded_minutes(bigint, timestamptz, timestamptz) IS
  'Minutes in [from, to) a LINE is out of service (config.equipment_out_of_service on the line or its parent) or has no data (status-20 events of its lead machine): bucket + ''outOfService''/''noData''. Empty for a line without exclusions.';
GRANT EXECUTE ON FUNCTION serving.line_excluded_minutes(bigint, timestamptz, timestamptz) TO readapi_ro;

-- OEE score + coverage columns (appended: SELECT * consumers keep their fields).
ALTER TYPE serving.oee_score_row ADD ATTRIBUTE no_data_time double precision;
ALTER TYPE serving.oee_score_row ADD ATTRIBUTE out_of_service_time double precision;
CREATE OR REPLACE FUNCTION serving.oee_score(in_id_enterprise integer, _tsstart timestamp with time zone, _tsend timestamp with time zone)
 RETURNS SETOF serving.oee_score_row
 LANGUAGE sql
 STABLE
AS $function$
  SELECT eq.id_enterprise, rs.id_equipment, min(rs.ts_value), max(rs.ts_end),
    coalesce(sum(rs.net::float8) / nullif(sum(rs.ideal_production), 0), 0)                                        AS oee,
    coalesce(sum(rs.running_time)::float8 / nullif(sum(rs.available_time), 0), 0)                                 AS oee_a,
    coalesce(sum(rs.gross::float8) * sum(rs.available_time)
             / nullif(sum(rs.ideal_production) * sum(rs.running_time), 0), 0)                                     AS oee_p,
    coalesce(sum(rs.net::float8) / nullif(sum(rs.gross::float8), 0), 0)                                           AS oee_q,
    sum(rs.gross::float8), sum(rs.net::float8), sum(rs.running_time)::float8,
    sum(rs.available_time)::float8, sum(rs.ideal_production),
    sum(rs.no_data_time)::float8, sum(rs.out_of_service_time)::float8
  FROM gold.equipment_oee_shift rs JOIN core.equipments eq ON eq.id_equipment = rs.id_equipment
  WHERE eq.id_enterprise = in_id_enterprise AND rs.ts_value >= _tsstart AND rs.ts_value < _tsend
  GROUP BY eq.id_enterprise, rs.id_equipment;
$function$;

-- Mission Control grid: status_24h with exclusions (rest of the body unchanged).

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
		-- status_24h: the LINE's own 1-min speed when it has any in 24h, else its LEAD machine's
		-- (counters-only / line-lead lines carry no line metrics). Thresholds stay the LINE's
		-- percentages, applied to the rated speed of whichever stream is used.
		-- PERF: silver.equipment_metrics_1min is a REAL-TIME cagg view. Joining it on a
		-- COMPUTED id (the old "join ... on m.id_equipment = src.id_src") kept the id out of the
		-- view's real-time branch, so every line aggregated 24h for ALL equipment (0.9s/line →
		-- 18-25s per call, Mission Control "loading forever"). Each step is its own
		-- LATERAL ... OFFSET 0 so the id reaches the view as a runtime parameter (#259/#1450).
		-- SPEED-LESS SOURCES (2026-09-29): a stream with counts but no speed register (CPACK
		-- L3's lead L3-BREYER) read as 'stopped' every minute → an all-red timeline on a line
		-- producing 8k+/shift. When a minute has no speed reading, its count rate (units
		-- counted in that 1-min bucket = units/min) stands in; minutes WITH a speed register
		-- are unchanged.
		-- status_24h + EXCLUSIONS (2026-10-01): minutes the line is OUT OF SERVICE (a CS
		-- window) or has NO DATA (its lead's PLC was unreadable — status-20 events) read
		-- 'outOfService' / 'noData' and take precedence over the metric minute; excluded
		-- minutes without metrics are ADDED (they used to vanish, so a dark line's bar
		-- showed only its few live minutes). No exclusions ⇒ identical to before.
		(select array_agg(coalesce(x.state, s.state) order by coalesce(s.bucket, x.bucket))
		   from (select m.bucket, case
					when coalesce(m.sum_speed / nullif(m.cnt_speed,0), greatest(m.sum_gross, m.sum_net), 0) >= (l.minimum_ideal_performance_threshold / 100.0 * src.rated::double precision) then 'running'
					when coalesce(m.sum_speed / nullif(m.cnt_speed,0), greatest(m.sum_gross, m.sum_net), 0) >= (l.minimum_performance_threshold / 100.0 * src.rated::double precision) then 'lowSpeed'
					else 'stopped'
				end as state

		   from equipments l
		   cross join lateral (
				select exists (select 1 from silver.equipment_metrics_1min x
				                where x.id_equipment = l.id_equipment
				                  and x.bucket >= now() - '24:01:00'::interval) as own
				offset 0) o
		   cross join lateral (
				select case when o.own then l.id_equipment else l.lead_machine end as id_src,
				       case when o.own then l.production_speed
				            else coalesce((select q.production_speed from equipments q where q.id_equipment = l.lead_machine), l.production_speed) end as rated
				offset 0) src
		   cross join lateral (
				select mm.bucket, mm.sum_speed, mm.cnt_speed, mm.sum_gross, mm.sum_net
				  from silver.equipment_metrics_1min mm
				 where mm.id_equipment = src.id_src
				   and mm.bucket >= now() - '24:01:00'::interval
				   and mm.bucket <  now() - '00:01:00'::interval
				offset 0) m
		  where l.id_equipment = uecm.id_equipment) s
		   full join serving.line_excluded_minutes(uecm.id_equipment, now() - '24:01:00'::interval, now() - '00:01:00'::interval) x
		     on x.bucket = s.bucket) as status_24h,
		uecm.status,
		uecm.status_time,
		uecs.proportional_target,
		uecs.prev1_target,
		COALESCE(uecs.prev2_target, p2.target::real) AS prev2_target,
		uecj.current_expected_time::float8 as job_remaining_time,
		-- Current-shift Performance / Quality (2026-09-29): uncapped, so the UI can show
		-- P > 100% with a "check ideal speed" marker and cap hourly-transit Q for display.
		uecs.oee_p::real AS currshift_oee_p,
		uecs.oee_q::real AS currshift_oee_q
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
$function$
;

-- Mission Control timeline: same per-minute states, plus excluded minutes.
CREATE OR REPLACE FUNCTION serving.mission_control_timeline(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text)
 RETURNS SETOF serving.mission_control_timeline_row
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
		-- otherwise its LEAD machine's (counters-only / line-lead lines carry no line metrics).
		-- EXCLUSIONS (2026-10-01): out-of-service / no-data minutes (serving.line_excluded_minutes)
		-- take precedence and are added when the line has no metric that minute.
		with dt as (
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
		), lines as (
			select distinct dt.id_equipment from dt
			union
			select l.id_equipment from equipments l
			 where l.id_enterprise = in_id_enterprise and l.tp_equipment = 3
			   and l.id_site = any (ids_sites) and l.id_area = any (ids_areas) and l.id_equipment = any (ids_equips)
			   and exists (select 1 from serving.line_excluded_minutes(l.id_equipment, now() - '24:01:00'::interval, now() - '00:01:00'::interval))
		)
		select ln.id_equipment,
		       (select array_agg(coalesce(x.state, s.situation) order by coalesce(s.ts_value, x.bucket))
		          from (select dt.ts_value, dt.situation from dt where dt.id_equipment = ln.id_equipment) s
		          full join serving.line_excluded_minutes(ln.id_equipment, now() - '24:01:00'::interval, now() - '00:01:00'::interval) x
		            on x.bucket = s.ts_value) as timelinestatus
		  from lines ln;
end
$function$;

COMMIT;
