-- Rollback for t-mission-control-timeline-threshold-units.
--
-- Restores the pre-fix serving.mission_control_timeline (threshold * production_speed,
-- no /100). This re-introduces the greying/misclassification and is only for
-- emergency revert. The threshold BACKFILL is intentionally NOT reverted here:
-- re-nulling minimum_(ideal_)performance_threshold would re-break every tenant
-- and there is no way to distinguish backfilled defaults from CS-tuned values
-- after the fact. If a true revert of the data is required, snapshot the column
-- before running 01 and restore from that snapshot.

BEGIN;

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
                            WHEN COALESCE(aaa.speed, 0.0::double precision) >= (e.minimum_ideal_performance_threshold * e.production_speed::double precision) THEN 'running'::text
                            WHEN COALESCE(aaa.speed, 0.0::double precision) < (e.minimum_ideal_performance_threshold * e.production_speed::double precision) AND COALESCE(aaa.speed, 0.0::double precision) >= (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'lowSpeed'::text
                            WHEN COALESCE(aaa.speed, 0::double precision) < (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'stopped'::text
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
