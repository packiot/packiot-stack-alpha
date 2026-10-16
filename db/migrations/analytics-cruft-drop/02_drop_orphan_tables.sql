-- drop 25 orphaned h_* scaffolding tables (function-return-type composites orphaned by the 56-fn drop)
DROP TABLE IF EXISTS public.h_downtimes_table_2;
DROP TABLE IF EXISTS public.h_equipment_chart_data_1day;
DROP TABLE IF EXISTS public.h_events_timeline2;
DROP TABLE IF EXISTS public.h_events_timeline3;
DROP TABLE IF EXISTS public.h_events_timeline3_with_event_id_cpack;
DROP TABLE IF EXISTS public.h_events_timeline4;
DROP TABLE IF EXISTS public.h_events_timeline5;
DROP TABLE IF EXISTS public.h_overview_i_events_2;
DROP TABLE IF EXISTS public.h_overview_i_shift_production;
DROP TABLE IF EXISTS public.h_pending_events;
DROP TABLE IF EXISTS public.h_pending_events_with_event_id_cpack;
DROP TABLE IF EXISTS public.h_piot_edge_settings;
DROP TABLE IF EXISTS public.h_piot_edited_po;
DROP TABLE IF EXISTS public.h_piot_mission_control_area_uns;
DROP TABLE IF EXISTS public.h_piot_mission_control_uns;
DROP TABLE IF EXISTS public.h_piot_oee_progress_chart_data;
DROP TABLE IF EXISTS public.h_piot_oee_progress_data1;
DROP TABLE IF EXISTS public.h_piot_oee_score_data;
DROP TABLE IF EXISTS public.h_piot_production_orders_merged_new_table;
DROP TABLE IF EXISTS public.h_piot_production_orders_with_runtimes_table6;
DROP TABLE IF EXISTS public.h_piot_production_orders_with_runtimes_table_5;
DROP TABLE IF EXISTS public.h_piot_split_downtime;
DROP TABLE IF EXISTS public.h_shift_hours_per_equipment;
DROP TABLE IF EXISTS public.h_total_production_chart_data;
DROP TABLE IF EXISTS public.h_total_production_chart_data_tz_fix;
DROP TABLE IF EXISTS public.hasura_test;  -- orphaned (its fn h_piot_get_hasura_test was dropped in the 56); 0 rows
