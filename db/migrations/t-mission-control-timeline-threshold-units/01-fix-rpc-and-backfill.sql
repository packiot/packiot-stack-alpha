-- t-mission-control-timeline-threshold-units
--
-- Fixes the greyed-out Mission Control status timeline (and the OEE/status
-- classifier family) caused by an incomplete new-stack migration. TWO defects:
--
--   1. UNITS BUG in serving.mission_control_timeline. The classifier compares
--      speed to `threshold * production_speed` with NO `/100`, but the threshold
--      columns are PERCENTAGES (0..100): the sparkplug decoder treats the same
--      value — PLC param 30750 — as a percentage (`machSpeed * quant / 100.0`,
--      calc_production_counters/calc.go), and CS Admin collects it as a percent.
--      Without `/100` the function multiplies e.g. 85 * 147 → everything would
--      classify "stopped". Fixed to `threshold / 100.0 * production_speed`.
--
--   2. UNPOPULATED CONFIG. minimum_ideal_performance_threshold and
--      minimum_performance_threshold were NULL for every equipment / every tenant
--      (onboarding never set them), so the CASE fell through to ELSE NULL → an
--      all-null timelinestatus → front4's MachineTimeline paints the neutral
--      "#808080 no-data" strip. Backfilled to the platform default
--      (running >= 85% of ideal, stopped < 30%; low-speed between). This pairs
--      with the edge-api create-equipment onboarding default + the csadmin form
--      default so NEW clients never ship NULL again.
--
-- Canonical unit going forward: PERCENT (0..100), everywhere (decoder, csadmin,
-- edge-api DTO, this classifier). Proven on staging (CPACK ent 3): post-fix the
-- RPC returns 10 lines 100% classified (running/lowSpeed/stopped), zero nulls.
--
-- NOTE: the legacy Hasura path (packiot.h_piot_get_mission_control_timeline)
-- carries the same units bug, but its source agg (packiot.agg_equipment_values_
-- 1min_t) is unfed on the new stack, so the legacy timeline is dead regardless;
-- front4 staging/prod reads the analytics path (VITE_REFDATA_ANALYTICS=true).
-- If a tenant is ever repointed to the Hasura path, apply the same /100 there.

BEGIN;

-- (1) units fix — CREATE OR REPLACE with `/100.0` on all four threshold*speed comparisons
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

-- (2) backfill the unpopulated thresholds (percent) for every equipment that lacks them.
-- Scoped to NULLs only so it never clobbers a value CS has already tuned.
UPDATE core.equipments SET minimum_ideal_performance_threshold = 85 WHERE minimum_ideal_performance_threshold IS NULL;
UPDATE core.equipments SET minimum_performance_threshold       = 30 WHERE minimum_performance_threshold       IS NULL;

COMMIT;
