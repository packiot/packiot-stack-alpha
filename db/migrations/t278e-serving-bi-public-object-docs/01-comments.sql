-- t278e — Documentation-only migration (COMMENT ON) for the query surface.
-- Scope: serving.* (views + functions), bi.* (views), and the LIVE application
-- objects in public (h_* result-type carriers, scanned_boxes/sample_boxes,
-- piot_get_*/h_piot_get_downtimes_* functions). Non-destructive, idempotent.
-- Extension/knex/pg_*/timescaledb objects are NOT touched.
--
-- Security model (verified on staging 2026-09-13):
--   * serving.* functions: all 45 are SECURITY INVOKER — the programmatic query
--     surface read by read-api under the caller's role/RLS; tenant scope is an
--     explicit in_id_enterprise/$1 argument (or an outer WHERE id_enterprise=$1
--     for the SETOF/view routes). read-api itself connects as a BYPASSRLS role,
--     so the id_enterprise argument is the load-bearing fence.
--   * serving.* views + bi.* views: no security_invoker option set (run
--     definer-side). bi.* view bodies carry NO app.tenant_id predicate — the
--     tenant fence for the Superset (bi) surface is external (Superset dashboard
--     RLS + a NOBYPASSRLS DB role), not in the view SQL. Flagged where relevant.

BEGIN;

-- =====================================================================
-- serving VIEWS (read-api / operator / bootstrap surface)
-- =====================================================================
COMMENT ON VIEW serving.production_information IS 'serving: per-equipment current-shift production/OEE snapshot (total_produced/total_rejected/oee). Read by read-api. SECURITY INVOKER not set (definer-side); scope via explicit id_enterprise column filter.';
COMMENT ON VIEW serving.v_entities_per_user_role IS 'serving: per-role entity tree (site/area/equipment + permissions) for the front4 bootstrap variables-context, scoped to the caller''s user role. Read by read-api /v1/entities-per-user-role family.';
COMMENT ON VIEW serving.v_entities_per_user_role_operator IS 'serving: operator-app variant of v_entities_per_user_role; emits id_enterprise so read-api can add an outer WHERE id_enterprise=$1. Feeds /v1/entities-per-user-role (operator).';
COMMENT ON VIEW serving.v_events_2 IS 'serving: unified event timeline (downtimes + PO/plc events) resolving id_equipment across parent/child event tables. Backing view for event-timeline reads.';
COMMENT ON VIEW serving.v_menu_per_user_role IS 'serving: per-role navigation menu (jsonb menu_group/menu_items) for the front4 bootstrap, scoped to the caller''s user role. Read by read-api.';
COMMENT ON VIEW serving.v_operator_entities_2 IS 'serving: operator-app entity tree as nested jsonb (enterprise->sites->areas->equipments). Read by read-api /v1/operator-entities with outer WHERE id_enterprise=$1.';
COMMENT ON VIEW serving.v_operator_po_details_3 IS 'serving: operator-app production-order detail (net_production/scrap/running_time/downtime + derived rates) for one PO. Read by read-api /v1/operator-po-details.';
COMMENT ON VIEW serving.v_operator_po_list_setup_4 IS 'serving: operator-app production-order list for PO setup/selection. Read by read-api /v1/operator-po-list with outer WHERE id_enterprise=$1.';
COMMENT ON VIEW serving.v_report_downtimes IS 'serving: DBA-owned tenant-carrying downtime report view (UNION+joins), keyed by SHIFT begin (ts_value = shift begin, NOT event ts). Read by read-api report-downtimes (tenant-custom).';

-- =====================================================================
-- serving FUNCTIONS (all SECURITY INVOKER; tenant = explicit arg)
-- =====================================================================
COMMENT ON FUNCTION serving.data_sync(p_id_enterprise integer, p_numdays integer) IS 'serving (#244 config-driven): generic production data-sync feed replacing the per-tenant ent-06 sync function; derives tz/scope from core.client_descriptors->reports. Consumed by stream-engine sync06 writer and read-api /ext montebello data-sync. Calls report_tz.';
COMMENT ON FUNCTION serving.downtime_by_category(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS 'serving: downtime duration aggregated by category. read-api downtimes-analytics. Internally calls public.h_piot_get_downtimes_per_category_equipment_level_new_4 and h_piot_get_downtimes_sector_microstops.';
COMMENT ON FUNCTION serving.downtime_duration_by_category(idequipment integer) IS 'serving: downtime duration by category for one equipment (overview panel). Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.downtime_events(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone, _tsend timestamp without time zone, microstops_view boolean) IS 'serving: downtime event list, LEGACY generation. read-api downtimes-analytics (/v1/downtime-events).';
COMMENT ON FUNCTION serving.downtime_events_v2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone, _tsend timestamp without time zone, microstops_view boolean) IS 'serving: downtime event list, LIVE generation (v2). read-api downtimes-analytics (/v1/downtime-events-v2).';
COMMENT ON FUNCTION serving.downtime_summary(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS 'serving: downtimes summary rollup. Read by read-api downtimes-analytics.';
COMMENT ON FUNCTION serving.downtime_sync(p_id_enterprise integer) IS 'serving (#244 config-driven): generic downtime-sync feed replacing get_downtime_sync_enterprsie_06 (argc 0, ent-6 hardcoded); tenant now explicit $1. read-api /ext montebello events. Calls report_sites.';
COMMENT ON FUNCTION serving.equipment_scrap_capability(in_id_enterprise integer) IS 'serving (#257): per-equipment scrap-measurability flag (defect-counter OR consumed+processed OR infeed+outfeed present), CONFIG-derived. read-api /v1/scrap-capability; front4 hasNoScrapMeter.';
COMMENT ON FUNCTION serving.events_timeline(in_packml_topic character varying[]) IS 'serving: event timeline for a set of packml topics. read-api /v1/events-timeline with outer WHERE id_enterprise=$1 (operator, byte-stable shape).';
COMMENT ON FUNCTION serving.events_timeline_by_po(_id_production_order integer) IS 'serving: event timeline for one production order. read-api /v1/events-timeline-by-po (id_enterprise applied as outer WHERE).';
COMMENT ON FUNCTION serving.events_timeline_full(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_event_types text, _id_production_order integer, _tsstart timestamp without time zone, _tsend timestamp without time zone) IS 'serving: full filtered event timeline (site/area/equipment/event-type/PO/time filters). Read by read-api events-timeline.';
COMMENT ON FUNCTION serving.home(in_id_enterprise integer) IS 'serving: home-page live OEE tree (enterprise->site->area->equipment live OEE). Read by read-api /v1/home.';
COMMENT ON FUNCTION serving.machine_speed(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, group_by_element text) IS 'serving (#221 canonical): machine-speed series, silver-backed grain-aware (HOUR/DAY). Replaces legacy public.h_piot_machine_speed. Read by read-api machine-speed.';
COMMENT ON FUNCTION serving.mission_control(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) IS 'serving: mission-control equipment grid (live status per equipment). Read by read-api mission-control.';
COMMENT ON FUNCTION serving.mission_control_area(in_id_enterprise integer, in_id_areas text, in_id_sites text) IS 'serving: mission-control area-level rollup. Read by read-api mission-control.';
COMMENT ON FUNCTION serving.mission_control_timeline(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) IS 'serving: mission-control status timeline. Read by read-api mission-control.';
COMMENT ON FUNCTION serving.oee_progress(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, nav_level text, is_shift_filtered boolean, is_team_filtered boolean) IS 'serving: OEE progress over time (grain/nav-level aware, shift/team filterable). Read by read-api oee.';
COMMENT ON FUNCTION serving.oee_score(in_id_enterprise integer, _tsstart timestamp with time zone, _tsend timestamp with time zone) IS 'serving (#218 CANONICAL): per-equipment OEE with canonical A*P*Q decomposition over [_tsstart,_tsend). Output cols: oee, oee_a, oee_p, oee_q, gross, net, running_time. read-api oee-score-full.';
COMMENT ON FUNCTION serving.oee_score_by_team(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, nav_level text, is_shift_filtered boolean) IS 'serving: OEE score split by shifts/teams. Read by read-api oee (oee-score-by-team).';
COMMENT ON FUNCTION serving.overview_events(idequipment integer) IS 'serving: overview event list for one equipment, LEGACY generation. Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.overview_events_v3(idequipment integer) IS 'serving: overview event list for one equipment, LIVE generation (v3). Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.overview_job_info(idequipment integer) IS 'serving: current job info for one equipment (overview header). Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.overview_production_chart(idequipment integer) IS 'serving: overview production chart for one equipment, LEGACY generation. Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.overview_scrap_rate(p_id_enterprise integer) IS 'serving (#244 generic ent-parameterized): per-equipment partial scrap rate; empty off configured tenants. Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.overview_takt(p_id_enterprise integer) IS 'serving (#244 generic ent-parameterized): per-equipment takt / avg speed; empty off configured tenants. Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.pending_downtime(in_packml_topic character varying[]) IS 'serving: pending (unjustified) downtime for a set of packml topics. read-api /v1/pending-downtime with outer WHERE id_enterprise=$1 (operator).';
COMMENT ON FUNCTION serving.production_chart(idequipment integer) IS 'serving: overview production chart for one equipment, LIVE generation. Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.production_chart_legacy(idequipment integer) IS 'serving: overview production chart for one equipment, BASE generation. Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.production_data_sync(p_id_enterprise integer) IS 'serving (#244 config-driven): generic production-data-sync replacing frozen ent-6 v_piot_production_data_sync_cust6; tenant now explicit $1. read-api /ext montebello data-sync. Calls report_cutover, report_tz.';
COMMENT ON FUNCTION serving.production_flow(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text) IS 'serving: production flow (infeed/outfeed) series. Read by read-api production-flow.';
COMMENT ON FUNCTION serving.production_health(idequipment integer) IS 'serving: production-health gauge for one equipment. Read by read-api overview-detail.';
COMMENT ON FUNCTION serving.production_orders(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS 'serving: one row per PO runtime segment. Read by read-api production-orders.';
COMMENT ON FUNCTION serving.production_orders_with_runtimes(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS 'serving: one row per PO with nested runtime segments (jsonb). Read by read-api production-orders.';
COMMENT ON FUNCTION serving.report_areas_excluded(p_id_enterprise integer) IS 'serving (#244 config helper): areas excluded from reports, derived from core.client_descriptors->reports. Called by serving.report_shift (not read directly by read-api).';
COMMENT ON FUNCTION serving.report_config(p_id_enterprise integer) IS 'serving (#244 base config helper): reads core.client_descriptors->reports for one enterprise. Called by report_cutover/report_sites/report_tz/report_areas_excluded (config-derivation root).';
COMMENT ON FUNCTION serving.report_cutover(p_id_enterprise integer) IS 'serving (#244 config helper): report cutover date derived from report_config. Called by serving.production_data_sync.';
COMMENT ON FUNCTION serving.report_shift(p_id_enterprise integer, startdate date, enddate date) IS 'serving (#244 config-driven): generic parameterized shift report replacing the per-enterprise get_report_shift_enterprsie_06* clones. Consumed by stream-engine shift06 writer. Calls report_areas_excluded/report_sites/report_tz.';
COMMENT ON FUNCTION serving.report_sites(p_id_enterprise integer, p_profile text) IS 'serving (#244 config helper): report site scope derived from report_config. Called by report_shift/downtime_sync/sap_* functions.';
COMMENT ON FUNCTION serving.report_tz(p_id_enterprise integer, p_profile text) IS 'serving (#244 config helper): report timezone derived from report_config. Called by report_shift/data_sync/production_data_sync/sap_* functions.';
COMMENT ON FUNCTION serving.sap_report_data_sync(p_id_enterprise integer) IS 'serving (#244/#247 config-driven): generic Neopac SAP data-sync replacing frozen ent-13 v_sap_report_data_sync_customer_13 (which had no id_enterprise); tenant now explicit $1. read-api /ext neopac sap-report-sync. Calls report_config/report_sites/report_tz.';
COMMENT ON FUNCTION serving.sap_site_report(p_id_enterprise integer, p_id_equipment integer) IS 'serving (#244 config-driven): generic Neopac SAP site report replacing frozen ent-13 v_13_site_deb_sap_report; tenant now explicit $1. read-api /ext neopac sap-report. Calls report_sites/report_tz.';
COMMENT ON FUNCTION serving.single_period_by_team(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, group_by_element text) IS 'serving: single-period OEE/production comparison by shift/team, LEGACY generation. Read by read-api single-period.';
COMMENT ON FUNCTION serving.single_period_by_team_v4(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, group_by_element text) IS 'serving: single-period comparison by shift/team, LIVE generation (v4). Read by read-api single-period.';
COMMENT ON FUNCTION serving.targets(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text, nav_level text, group_by_element text) IS 'serving: computed production targets vs actuals over a grain/nav-level. Read by read-api targets.';
COMMENT ON FUNCTION serving.total_production_by_team(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, partitionby text, time_grain text) IS 'serving: total production partitioned by shifts/teams. Read by read-api total-production.';

-- =====================================================================
-- bi VIEWS (Superset surface; tenant fence is EXTERNAL — see header)
-- =====================================================================
COMMENT ON VIEW bi.downtimes IS 'bi (Superset): per-event downtime facts joined to equipment (category/subcategory, ts_value=ts_event, duration). Carries id_enterprise but NO app.tenant_id predicate — tenant fence is Superset RLS + NOBYPASSRLS role.';
COMMENT ON VIEW bi.equipment_speed IS 'bi (Superset): per-equipment speed series (coalesced speed/inferred). Tenant fence external (Superset RLS), not in view body.';
COMMENT ON VIEW bi.equipments IS 'bi (Superset): equipment dimension (name/type/area/lead_machine + display label). Tenant fence external.';
COMMENT ON VIEW bi.live_status IS 'bi (Superset): latest live status/speed snapshot per equipment (DISTINCT ON id_equipment, last_update). Tenant fence external.';
COMMENT ON VIEW bi.oee_hourly IS 'bi (Superset): hourly OEE per equipment (oee/oee_a/oee_p/oee_q, gross/net/running_time) from the 1-hour rollup. Tenant fence external.';
COMMENT ON VIEW bi.oee_shift IS 'bi (Superset): per-shift OEE per equipment (+ id_shift/cd_shift, ts_value/ts_end) from the shift rollup. Tenant fence external.';
COMMENT ON VIEW bi.production_by_team IS 'bi (Superset): production increments (net/gross/scrap) attributed to id_team/id_shift per equipment. Tenant fence external.';
COMMENT ON VIEW bi.production_order_runtime IS 'bi (Superset): one row per PO runtime segment (OEE decomposition, gross/net, running_time, runtime range). Tenant fence external.';
COMMENT ON VIEW bi.production_orders IS 'bi (Superset): production-order facts (status, programmed/ordered/real production). Tenant fence external.';
COMMENT ON VIEW bi.production_targets IS 'bi (Superset): configured production targets per equipment (vl_hour/shift/day/week/month). Tenant fence external.';

-- =====================================================================
-- public: LIVE application objects only
-- =====================================================================
-- h_* result-type carrier tables: 0-row, load-bearing as the composite RETURN
-- type of the matching SETOF function. DO NOT DROP.
COMMENT ON TABLE public.h_machine_speed IS 'RETURNS-SETOF row-type carrier (0-row, load-bearing): composite return type for the legacy machine-speed lookup (id_equipment + info jsonb[]). Do NOT drop while any function returns SETOF this type. Relocation candidate, not dead.';
COMMENT ON TABLE public.h_downtimes_table_with_sector_2 IS 'RETURNS-SETOF row-type carrier (0-row, load-bearing): composite return type for the sector-level downtime table lookup. Do NOT drop. Relocation candidate.';
COMMENT ON TABLE public.h_piot_day_week_begin IS 'RETURNS-SETOF row-type carrier (0-row, load-bearing): composite return type of public.piot_get_day_week_begin_by_packml_topic (day_begin/week_begin int seconds). Do NOT drop.';
COMMENT ON TABLE public.h_piot_get_downtimes_per_category_equipment_level_new IS 'RETURNS-SETOF row-type carrier (0-row, load-bearing): composite return type of public.h_piot_get_downtimes_per_category_equipment_level_new_4 (durations + downtimes_per_category text[]). Do NOT drop.';
COMMENT ON TABLE public.h_shift_hours_per_equipment_packml_topic IS 'RETURNS-SETOF row-type carrier (0-row, load-bearing): composite return type for shift-hours-by-packml-topic lookups (shift_hours jsonb[]). Do NOT drop.';

-- edge-api Samples feature tables (LIVE)
COMMENT ON TABLE public.scanned_boxes IS 'LIVE edge-api Samples feature: box-scan events per production order + equipment. increment accumulates count; box_order_number!=0 filters valid scans. Not a box_scans duplicate.';
COMMENT ON TABLE public.sample_boxes IS 'LIVE edge-api Samples feature: sample-box tracking per production order + equipment (should_increment gate + increment count).';

COMMENT ON COLUMN public.scanned_boxes.increment IS 'Accumulated box count contributed by this scan.';
COMMENT ON COLUMN public.scanned_boxes.box_order_number IS 'Sequence number of the box within the order; box_order_number!=0 filters valid scans.';
COMMENT ON COLUMN public.scanned_boxes.id_production_order IS 'FK to production_orders (the PO this scan is counted against).';
COMMENT ON COLUMN public.sample_boxes.should_increment IS 'Whether this sample box contributes to the running count.';
COMMENT ON COLUMN public.sample_boxes.increment IS 'Accumulated count contributed by this sample box.';

-- public piot_get_* / h_piot_get_downtimes_* functions (read bare)
COMMENT ON FUNCTION public.piot_get_day_begin_by_area(in_id_area integer, in_ts_value timestamp with time zone) IS 'public helper: day-boundary timestamp for an area calendar. Called by rollup procs piot_create_area_oee_daily/_shift. Relocation candidate (public, still called bare).';
COMMENT ON FUNCTION public.piot_get_day_begin_by_equipment(in_id_equipment integer, in_ts_value timestamp with time zone) IS 'public helper: day-boundary timestamp for an equipment calendar. Called by piot_create_equipment_oee_daily/_monthly/_shift. Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_day_begin_by_site(in_id_site integer, in_ts_value timestamp with time zone) IS 'public helper: day-boundary timestamp for a site calendar. Called by piot_create_site_oee_daily/_shift. Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_shift_hour_begin_by_area(in_id_area integer, ts_value timestamp with time zone) IS 'public helper: shift-hour boundary timestamp for an area. Called by piot_create_area_oee_shift. Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_shift_hour_begin_by_equipment(in_id_equipment integer, ts_value timestamp with time zone) IS 'public helper: shift-hour boundary timestamp for an equipment. Called by piot_create_equipment_oee_shift. Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_shift_hour_begin_by_site(in_id_site integer, ts_value timestamp with time zone) IS 'public helper: shift-hour boundary timestamp for a site. Called by piot_create_site_oee_shift. Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_shift_hour_list_by_equipment(in_id_enterprise integer, in_id_equip integer) IS 'public helper: list of shift-hour boundaries for an equipment. Called by h_piot_set_production_target / h_piot_set_scrap_target. Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_shift_hours_by_equipment(in_id_enterprise integer, in_id_equip integer) IS 'public helper: shift-hours per equipment. Called by public.piot_get_shift_hours_by_packml_topic_2. Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_day_week_begin_by_packml_topic(in_topic character varying) IS 'public helper: day_begin/week_begin (int seconds) for a packml topic. Read BARE by read-api /v1/day-week-begin (outer WHERE id_enterprise=$1). Returns SETOF h_piot_day_week_begin. Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_shift_hours_by_packml_topic_2(in_topic character varying) IS 'public helper: shift-hours for a packml topic. Read BARE by read-api /v1/shift-hours (outer WHERE id_enterprise=$1). Relocation candidate.';
COMMENT ON FUNCTION public.piot_get_shift_hours_by_enterprise_packml_topic_2(in_topic character varying, in_enterprise integer) IS 'public helper: STAGING 2-arg wrapper over piot_get_shift_hours_by_packml_topic_2(in_topic); in_enterprise arg is DEAD (prod copy is 1-arg, resolves enterprise from packml_register). Read BARE by read-api /v1/shift-hours-by-enterprise (binds topic only). Relocation candidate.';
COMMENT ON FUNCTION public.h_piot_get_downtimes_per_category_equipment_level_new_4(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone, _tsend timestamp without time zone, in_ids_teams text) IS 'public helper: downtime durations per category at equipment level. Called by serving.downtime_by_category. Returns SETOF h_piot_get_downtimes_per_category_equipment_level_new. Relocation candidate.';
COMMENT ON FUNCTION public.h_piot_get_downtimes_sector_microstops(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone, _tsend timestamp without time zone, sector_view boolean, microstops_view boolean) IS 'public helper: sector-level downtime + microstops aggregation. Called by serving.downtime_by_category. Relocation candidate.';

COMMIT;
