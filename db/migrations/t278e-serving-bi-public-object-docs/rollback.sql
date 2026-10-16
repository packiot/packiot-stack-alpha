-- t278e rollback — clears every COMMENT set by 01-comments.sql (one IS NULL each).
BEGIN;

-- serving VIEWS (9)
COMMENT ON VIEW serving.production_information IS NULL;
COMMENT ON VIEW serving.v_entities_per_user_role IS NULL;
COMMENT ON VIEW serving.v_entities_per_user_role_operator IS NULL;
COMMENT ON VIEW serving.v_events_2 IS NULL;
COMMENT ON VIEW serving.v_menu_per_user_role IS NULL;
COMMENT ON VIEW serving.v_operator_entities_2 IS NULL;
COMMENT ON VIEW serving.v_operator_po_details_3 IS NULL;
COMMENT ON VIEW serving.v_operator_po_list_setup_4 IS NULL;
COMMENT ON VIEW serving.v_report_downtimes IS NULL;

-- serving FUNCTIONS (45)
COMMENT ON FUNCTION serving.data_sync(p_id_enterprise integer, p_numdays integer) IS NULL;
COMMENT ON FUNCTION serving.downtime_by_category(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS NULL;
COMMENT ON FUNCTION serving.downtime_duration_by_category(idequipment integer) IS NULL;
COMMENT ON FUNCTION serving.downtime_events(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone, _tsend timestamp without time zone, microstops_view boolean) IS NULL;
COMMENT ON FUNCTION serving.downtime_events_v2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone, _tsend timestamp without time zone, microstops_view boolean) IS NULL;
COMMENT ON FUNCTION serving.downtime_summary(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS NULL;
COMMENT ON FUNCTION serving.downtime_sync(p_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.equipment_scrap_capability(in_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.events_timeline(in_packml_topic character varying[]) IS NULL;
COMMENT ON FUNCTION serving.events_timeline_by_po(_id_production_order integer) IS NULL;
COMMENT ON FUNCTION serving.events_timeline_full(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_event_types text, _id_production_order integer, _tsstart timestamp without time zone, _tsend timestamp without time zone) IS NULL;
COMMENT ON FUNCTION serving.home(in_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.machine_speed(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, group_by_element text) IS NULL;
COMMENT ON FUNCTION serving.mission_control(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) IS NULL;
COMMENT ON FUNCTION serving.mission_control_area(in_id_enterprise integer, in_id_areas text, in_id_sites text) IS NULL;
COMMENT ON FUNCTION serving.mission_control_timeline(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) IS NULL;
COMMENT ON FUNCTION serving.oee_progress(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, nav_level text, is_shift_filtered boolean, is_team_filtered boolean) IS NULL;
COMMENT ON FUNCTION serving.oee_score(in_id_enterprise integer, _tsstart timestamp with time zone, _tsend timestamp with time zone) IS NULL;
COMMENT ON FUNCTION serving.oee_score_by_team(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, nav_level text, is_shift_filtered boolean) IS NULL;
COMMENT ON FUNCTION serving.overview_events(idequipment integer) IS NULL;
COMMENT ON FUNCTION serving.overview_events_v3(idequipment integer) IS NULL;
COMMENT ON FUNCTION serving.overview_job_info(idequipment integer) IS NULL;
COMMENT ON FUNCTION serving.overview_production_chart(idequipment integer) IS NULL;
COMMENT ON FUNCTION serving.overview_scrap_rate(p_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.overview_takt(p_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.pending_downtime(in_packml_topic character varying[]) IS NULL;
COMMENT ON FUNCTION serving.production_chart(idequipment integer) IS NULL;
COMMENT ON FUNCTION serving.production_chart_legacy(idequipment integer) IS NULL;
COMMENT ON FUNCTION serving.production_data_sync(p_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.production_flow(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text) IS NULL;
COMMENT ON FUNCTION serving.production_health(idequipment integer) IS NULL;
COMMENT ON FUNCTION serving.production_orders(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS NULL;
COMMENT ON FUNCTION serving.production_orders_with_runtimes(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS NULL;
COMMENT ON FUNCTION serving.report_areas_excluded(p_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.report_config(p_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.report_cutover(p_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.report_shift(p_id_enterprise integer, startdate date, enddate date) IS NULL;
COMMENT ON FUNCTION serving.report_sites(p_id_enterprise integer, p_profile text) IS NULL;
COMMENT ON FUNCTION serving.report_tz(p_id_enterprise integer, p_profile text) IS NULL;
COMMENT ON FUNCTION serving.sap_report_data_sync(p_id_enterprise integer) IS NULL;
COMMENT ON FUNCTION serving.sap_site_report(p_id_enterprise integer, p_id_equipment integer) IS NULL;
COMMENT ON FUNCTION serving.single_period_by_team(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, group_by_element text) IS NULL;
COMMENT ON FUNCTION serving.single_period_by_team_v4(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, group_by_element text) IS NULL;
COMMENT ON FUNCTION serving.targets(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, nav_level text, group_by_element text) IS NULL;
COMMENT ON FUNCTION serving.total_production_by_team(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, partitionby text, time_grain text) IS NULL;

-- bi VIEWS (10)
COMMENT ON VIEW bi.downtimes IS NULL;
COMMENT ON VIEW bi.equipment_speed IS NULL;
COMMENT ON VIEW bi.equipments IS NULL;
COMMENT ON VIEW bi.live_status IS NULL;
COMMENT ON VIEW bi.oee_hourly IS NULL;
COMMENT ON VIEW bi.oee_shift IS NULL;
COMMENT ON VIEW bi.production_by_team IS NULL;
COMMENT ON VIEW bi.production_order_runtime IS NULL;
COMMENT ON VIEW bi.production_orders IS NULL;
COMMENT ON VIEW bi.production_targets IS NULL;

-- public TABLES (7)
COMMENT ON TABLE public.h_machine_speed IS NULL;
COMMENT ON TABLE public.h_downtimes_table_with_sector_2 IS NULL;
COMMENT ON TABLE public.h_piot_day_week_begin IS NULL;
COMMENT ON TABLE public.h_piot_get_downtimes_per_category_equipment_level_new IS NULL;
COMMENT ON TABLE public.h_shift_hours_per_equipment_packml_topic IS NULL;
COMMENT ON TABLE public.scanned_boxes IS NULL;
COMMENT ON TABLE public.sample_boxes IS NULL;

-- public COLUMNS (5)
COMMENT ON COLUMN public.scanned_boxes.increment IS NULL;
COMMENT ON COLUMN public.scanned_boxes.box_order_number IS NULL;
COMMENT ON COLUMN public.scanned_boxes.id_production_order IS NULL;
COMMENT ON COLUMN public.sample_boxes.should_increment IS NULL;
COMMENT ON COLUMN public.sample_boxes.increment IS NULL;

-- public FUNCTIONS (13)
COMMENT ON FUNCTION public.piot_get_day_begin_by_area(in_id_area integer, in_ts_value timestamp with time zone) IS NULL;
COMMENT ON FUNCTION public.piot_get_day_begin_by_equipment(in_id_equipment integer, in_ts_value timestamp with time zone) IS NULL;
COMMENT ON FUNCTION public.piot_get_day_begin_by_site(in_id_site integer, in_ts_value timestamp with time zone) IS NULL;
COMMENT ON FUNCTION public.piot_get_shift_hour_begin_by_area(in_id_area integer, ts_value timestamp with time zone) IS NULL;
COMMENT ON FUNCTION public.piot_get_shift_hour_begin_by_equipment(in_id_equipment integer, ts_value timestamp with time zone) IS NULL;
COMMENT ON FUNCTION public.piot_get_shift_hour_begin_by_site(in_id_site integer, ts_value timestamp with time zone) IS NULL;
COMMENT ON FUNCTION public.piot_get_shift_hour_list_by_equipment(in_id_enterprise integer, in_id_equip integer) IS NULL;
COMMENT ON FUNCTION public.piot_get_shift_hours_by_equipment(in_id_enterprise integer, in_id_equip integer) IS NULL;
COMMENT ON FUNCTION public.piot_get_day_week_begin_by_packml_topic(in_topic character varying) IS NULL;
COMMENT ON FUNCTION public.piot_get_shift_hours_by_packml_topic_2(in_topic character varying) IS NULL;
COMMENT ON FUNCTION public.piot_get_shift_hours_by_enterprise_packml_topic_2(in_topic character varying, in_enterprise integer) IS NULL;
COMMENT ON FUNCTION public.h_piot_get_downtimes_per_category_equipment_level_new_4(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS NULL;
COMMENT ON FUNCTION public.h_piot_get_downtimes_sector_microstops(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone, _tsend timestamp without time zone, sector_view boolean, microstops_view boolean) IS NULL;

COMMIT;
