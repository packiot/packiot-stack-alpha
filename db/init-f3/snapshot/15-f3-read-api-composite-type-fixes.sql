-- 15-f3-read-api-composite-type-fixes.sql — fixes 9 read-api /v1/query datasets
-- that 500 on packiot_analytics (F3): oee-score-teams, oee-progress, oee-score-full,
-- machine-speed, production-flow, single-period, single-period-legacy, targets,
-- mission-control-timeline. See docs/audits/front4-operator-endpoint-health.md
-- and services/read-api/cmd/refdata-api/datasets.go (flow.go's sqlF3 seam).
--
-- ── Bug #1 (8 datasets) — composite return-type column drift ───────────────
-- 00-packiot_analytics-schema.sql (a pg_dump of live packiot_analytics, best-effort)
-- baked in a porting bug: 8 of the h_piot_*/h_* "row-shape" tables that back a
-- `RETURNS SETOF <table>` PL/pgSQL function declare their jsonb-aggregate
-- column as `text[]`, while packiot (F1) — and every function body, unchanged
-- between F1/F3 — declares/produces `jsonb[]` for the exact same column
-- (`array_agg(jsonb_build_object(...))`). PL/pgSQL's RETURN QUERY does a
-- STRICT structural check against the declared row type, so every call fails:
--   ERROR: structure of query does not match function result type
--   DETAIL: Returned type jsonb[] does not match expected type text[] in column N.
-- Confirmed live via pg_attribute diff against packiot (F1) 2026-08-20 (see the
-- audit doc's root-cause section + task notes) — F1 has jsonb[] on every one of
-- these columns, F3 has text[] on the identical column of the identical table
-- name. This is NOT a missing-object gap (ADR-0032's usual F3 divergence) — the
-- object exists under the right name with the wrong element type.
--
-- These 9 "h_*" tables are NEVER used to store data — relkind='r' purely
-- because CREATE TABLE is the mechanism used to define a composite row type;
-- reltuples=-1 (never analyzed) and a live COUNT(*) confirmed 0 rows on staging
-- across all 8 (2026-08-20). Widening the column is therefore data-safe and,
-- because text[] genuinely round-trips through PostgreSQL's built-in text→jsonb
-- cast, USING is a real (if moot, given 0 rows) conversion rather than a blind
-- reinterpret.
ALTER TABLE public.h_machine_speed
    ALTER COLUMN info TYPE jsonb[] USING info::jsonb[];
ALTER TABLE public.h_piot_oee_progress_with_teams
    ALTER COLUMN oee_progress TYPE jsonb[] USING oee_progress::jsonb[];
ALTER TABLE public.h_piot_oee_score_full_table
    ALTER COLUMN shifts TYPE jsonb[] USING shifts::jsonb[],
    ALTER COLUMN childs TYPE jsonb[] USING childs::jsonb[];
ALTER TABLE public.h_piot_oee_score_teams_table
    ALTER COLUMN shifts TYPE jsonb[] USING shifts::jsonb[],
    ALTER COLUMN teams  TYPE jsonb[] USING teams::jsonb[],
    ALTER COLUMN childs TYPE jsonb[] USING childs::jsonb[];
ALTER TABLE public.h_piot_production_flow_table
    ALTER COLUMN production_flow TYPE jsonb[] USING production_flow::jsonb[];
ALTER TABLE public.h_piot_production_targets
    ALTER COLUMN array_agg TYPE jsonb[] USING array_agg::jsonb[];
ALTER TABLE public.h_single_period_equipment_chart_table_3
    ALTER COLUMN array_agg TYPE jsonb[] USING array_agg::jsonb[];
ALTER TABLE public.h_single_period_equipment_chart_table_4
    ALTER COLUMN array_agg TYPE jsonb[] USING array_agg::jsonb[];

-- ── Bug #2 (1 dataset: mission-control-timeline) — wrong source object ─────
-- h_piot_get_mission_control_timeline reads `agg_equipment_values_1min_t`. In
-- packiot (F1) that name is the wide 30-column per-equipment 1-minute cagg the
-- function needs (id_enterprise, id_site, id_area, id_equipment, ts_value,
-- speed, tp_equipment, …). In packiot_analytics (F3) that exact name is already
-- owned by an UNRELATED, differently-shaped view (3 columns: ts_value,
-- id_equipment, val — some other F3-native per-metric aggregate), so every
-- call 500s:
--   ERROR: column "id_enterprise" does not exist
-- The correctly-shaped F3 equivalent is `agg_equipment_values_1min` (no `_t`
-- suffix) — column-parity verified against every column this function touches
-- (2026-08-20). This CREATE OR REPLACE is byte-identical to the F1 function
-- body except for that one table reference.
CREATE OR REPLACE FUNCTION public.h_piot_get_mission_control_timeline(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) RETURNS SETOF public.h_piot_mission_control_timeline
    LANGUAGE plpgsql STABLE
    AS $$
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
                   FROM (select * from agg_equipment_values_1min aaa
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
$$;
