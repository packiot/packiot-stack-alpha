-- 15_p5_drop_h_piot_originals.sql
-- P5: drop the 28 legacy h_piot_* originals that read-api repointed away from
-- (PR #1132: read-api now executes serving.* twins; deployed+live-proven 2026-09-08).
-- Static writer-audit (exhaustive): NONE of these 28 is referenced as executed SQL by
-- read-api (golden = serving.* + machine_speed + oee_score_full_3), edge-api (only
-- set_production_target/set_scrap_target), stream-engine, any other stack service,
-- back4-api, primary-api, any view, any serving fn (only the 2 kept downtime helpers),
-- any surviving h_piot, Hasura (absent) or pg_cron (absent).
-- KEEP (7, excluded): h_piot_machine_speed, h_piot_oee_score_full_3 (read-api #218-owned),
--   h_piot_oee_score_with_teams (called by oee_score_full_3), h_piot_set_production_target,
--   h_piot_set_scrap_target (edge-api DAO), h_piot_get_downtimes_per_category_equipment_level_new_4,
--   h_piot_get_downtimes_sector_microstops (bodies of serving.downtime_by_category).
-- SELF-GUARDING: no CASCADE -> Postgres blocks+rolls back if any dependent exists.
-- Reverse: 15_p5_drop_h_piot_originals.ROLLBACK.sql (full live defs snapshot).
BEGIN;
DROP FUNCTION IF EXISTS public.h_piot_downtimes_duration_by_category(idequipment integer);
DROP FUNCTION IF EXISTS public.h_piot_get_downtimes_events(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone, _tsend timestamp without time zone, microstops_view boolean);
DROP FUNCTION IF EXISTS public.h_piot_get_downtimes_events_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone, _tsend timestamp without time zone, microstops_view boolean);
DROP FUNCTION IF EXISTS public.h_piot_get_downtimes_per_category(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text);
DROP FUNCTION IF EXISTS public.h_piot_get_downtimes_resumo(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text);
DROP FUNCTION IF EXISTS public.h_piot_get_equipment_pending_downtime_with_event_id(in_packml_topic character varying[]);
DROP FUNCTION IF EXISTS public.h_piot_get_events_timeline3_with_event_id(in_packml_topic character varying[]);
DROP FUNCTION IF EXISTS public.h_piot_get_events_timeline_from_po(_id_production_order integer);
DROP FUNCTION IF EXISTS public.h_piot_get_events_timeline_full_with_filter_3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_event_types text, _id_production_order integer, _tsstart timestamp without time zone, _tsend timestamp without time zone);
DROP FUNCTION IF EXISTS public.h_piot_get_mission_control_area_uns_2(in_id_enterprise integer, in_id_areas text, in_id_sites text);
DROP FUNCTION IF EXISTS public.h_piot_get_mission_control_timeline(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text);
DROP FUNCTION IF EXISTS public.h_piot_get_mission_control_uns_3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text);
DROP FUNCTION IF EXISTS public.h_piot_get_production_health(idequipment integer);
DROP FUNCTION IF EXISTS public.h_piot_get_targets(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, nav_level text, group_by_element text);
DROP FUNCTION IF EXISTS public.h_piot_home_uns(in_id_enterprise integer);
DROP FUNCTION IF EXISTS public.h_piot_oee_progress_new2(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, nav_level text, is_shift_filtered boolean, is_team_filtered boolean);
DROP FUNCTION IF EXISTS public.h_piot_overview_i_get_events(idequipment integer);
DROP FUNCTION IF EXISTS public.h_piot_overview_i_get_events_3(idequipment integer);
DROP FUNCTION IF EXISTS public.h_piot_overview_i_get_job_info(idequipment integer);
DROP FUNCTION IF EXISTS public.h_piot_overview_i_production_chart(idequipment integer);
DROP FUNCTION IF EXISTS public.h_piot_overview_production_chart(idequipment integer);
DROP FUNCTION IF EXISTS public.h_piot_overview_production_chart_v6(idequipment integer);
DROP FUNCTION IF EXISTS public.h_piot_production_flow(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text);
DROP FUNCTION IF EXISTS public.h_piot_production_orders_runtimes(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text);
DROP FUNCTION IF EXISTS public.h_piot_production_orders_with_runtimes4(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text);
DROP FUNCTION IF EXISTS public.h_piot_single_period_with_teams_3(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, group_by_element text);
DROP FUNCTION IF EXISTS public.h_piot_single_period_with_teams_4(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, group_by_element text);
DROP FUNCTION IF EXISTS public.h_piot_total_production_teams_2(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, partitionby text, time_grain text);
COMMIT;
