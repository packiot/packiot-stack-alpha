-- Staging parity — captured prod definitions (ground truth archive)
--
-- Captured 2026-07-02 from prod tsp12/packiot40 via pg_get_viewdef,
-- SELECT-only. Sections: Wave 0b views (20) · agg chain views+matviews
-- (19) · agg consumer rebuild set (32) · prod CAgg definitions (17).
-- Transfer note: 2 section markers glued by SSM chunking; every
-- object was applied + verified live on staging 2026-07-02.

-- ===VIEW=== h_piot_production_orders_merged
CREATE VIEW public.h_piot_production_orders_merged AS
 SELECT po.id_enterprise,
    po.status,
    po.id_production_order,
    po.id_order,
    c.nm_client,
    p.nm_product,
    po.production_ordered,
    po.gross_production,
    po.net_production,
    e.cd_equipment,
    po.ts_start,
    COALESCE(po.ts_end, now()) AS ts_end,
    po.id_equipment
   FROM production_orders po
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN products p USING (id_product)
     LEFT JOIN equipments e USING (id_equipment)
  WHERE po.status <> 1;
;
-- ===VIEW=== h_piot_production_orders_merged_new
CREATE VIEW public.h_piot_production_orders_merged_new AS
 SELECT po.id_enterprise,
    po.status,
    po.id_production_order,
    po.id_order,
    c.nm_client,
    p.nm_product,
    po.production_ordered,
    COALESCE(NULLIF(po.gross_production, 0::double precision), po.production_final::double precision) AS gross_production,
    po.net_production,
    e.nm_equipment,
    e.id_area,
    e.id_site,
    po.ts_start,
    po.ts_end,
    po.id_equipment
   FROM production_orders po
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN products p USING (id_product)
     LEFT JOIN equipments e USING (id_equipment)
  WHERE po.status <> 1;
;
-- ===VIEW=== v_entities_per_user_role
CREATE VIEW public.v_entities_per_user_role AS
 WITH lines AS (
         SELECT ur.id_enterprise,
            e_1.id_site,
            e_1.id_area,
            ur.id_equipment,
            ur.id_user_role,
            ur.nm_user_role,
            ur.permissions,
            e_1.cd_equipment,
            e_1.nm_equipment,
            e_1."position",
            e_1.tp_equipment,
            e_1.id_parentequipment,
            e_1.stop_threshold_time,
            e_1.production_speed,
            e_1.alerts,
            e_1.performance_alert_threshold,
            e_1.id_equipment_type,
            e_1.minimum_performance_threshold,
            e_1.require_downtime_reason,
            e_1.sector_equipment_infeed,
            e_1.sector_equipment_outfeed,
            e_1.status_type,
            e_1.id_counter_status,
            e_1.id_equipment_state_status,
            e_1.id_equipment_state_idle,
            e_1.id_equipment_state_starved,
            e_1.id_equipment_state_blocked,
            e_1.id_equipment_status_mirror,
            e_1.id_packed_counter,
            e_1.cd_sector,
            e_1.id_equipment_state_fault,
            e_1.downtime_reasons,
            e_1.minimum_ideal_performance_threshold,
            e_1.custom,
            e_1.scrap_reasons,
            e_1.ideal_speed,
            e_1.overview_events_type,
            e_1.overview_events_filter_by_idle,
            e_1.flexible_position,
            e_1.event_should_be_displayed,
            e_1.overview_version,
            areas.nm_area,
            areas.id_infeedcounter,
            areas.id_outfeedcounter,
            areas.id_rejectscounter,
            areas.week_begin,
            areas.day_begin,
            areas.week_size,
            sites.nm_site,
            sites.week_begin,
            sites.day_begin,
            sites.timezone,
            sites.language_tag,
            sites.week_size,
            sites.email_alert_users,
            enterprises.nm_enterprise,
            enterprises.api_key,
            enterprises.week_begin,
            enterprises.day_begin,
            enterprises.week_size,
            enterprises.timezone,
            enterprises.logo_url,
            enterprises.active,
            enterprises.basic_menu,
            enterprises.custom_menu,
            enterprises.language_packs
           FROM ( SELECT user_roles.id_user_role,
                    user_roles.nm_user_role,
                    user_roles.id_enterprise,
                    user_roles.permissions,
                    jsonb_array_elements((user_roles.permissions -> 'desktop'::text) -> 'line'::text)::integer AS id_equipment
                   FROM user_roles) ur
             JOIN equipments e_1 USING (id_enterprise, id_equipment)
             JOIN areas USING (id_enterprise, id_area, id_site)
             JOIN sites USING (id_enterprise, id_site)
             JOIN enterprises USING (id_enterprise)
        ), shifts AS (
         SELECT DISTINCT array_agg(jsonb_build_object('cd_shift', s7.cd_shift, 'id_shift', s7.id_shift)) AS shifts,
            s7.id_user_role
           FROM ( SELECT DISTINCT sh_1.cd_shift,
                    sh_1.id_shift,
                    ev.id_user_role
                   FROM lines ev(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                     JOIN shift_hours sh_1 ON ev.id_enterprise = sh_1.id_enterprise AND ev.id_enterprise = sh_1.id_enterprise AND
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM shift_hours ssh
                              WHERE ssh.id_equipment = ev.id_equipment)) THEN ev.id_equipment = sh_1.id_equipment
                            WHEN (EXISTS ( SELECT 1
                               FROM shift_hours ssh
                              WHERE ssh.id_area = ev.id_area)) THEN ev.id_area = sh_1.id_area AND sh_1.id_equipment IS NULL
                            WHEN (EXISTS ( SELECT 1
                               FROM shift_hours ssh
                              WHERE ssh.id_site = ev.id_site)) THEN ev.id_site = sh_1.id_site AND sh_1.id_area IS NULL
                            WHEN (EXISTS ( SELECT 1
                               FROM shift_hours ssh
                              WHERE ssh.id_enterprise = ev.id_enterprise)) THEN ev.id_enterprise = sh_1.id_enterprise AND sh_1.id_site IS NULL
                            ELSE false
                        END) s7
          GROUP BY s7.id_user_role
        ), teams AS (
         SELECT DISTINCT array_agg(jsonb_build_object('cd_team', s8.cd_team, 'id_team', s8.id_team)) AS teams,
            s8.id_user_role
           FROM ( SELECT DISTINCT t.cd_team,
                    t.id_team,
                    l.id_user_role
                   FROM lines l(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                     JOIN public.teams t USING (id_enterprise, id_equipment)) s8
          GROUP BY s8.id_user_role
        ), sectors AS (
         SELECT DISTINCT array_agg(jsonb_build_object('nm_equipment', s9.nm_equipment, 'id_area', s9.id_area, 'id_site', s9.id_site, 'id_equipment', s9.id_equipment, 'id_parentequipment', s9.id_parentequipment, 'require_downtime_reason', s9.require_downtime_reason) ORDER BY s9.id_area, (regexp_replace(s9.nm_equipment::text, '[^\d]'::text, ''::text, 'g'::text)::integer)) AS sectors,
            s9.id_user_role
           FROM ( SELECT DISTINCT s_1.nm_equipment,
                    s_1.id_equipment,
                    l.id_area,
                    l.id_site,
                    s_1.id_parentequipment,
                    s_1.require_downtime_reason,
                    l.id_user_role
                   FROM lines l(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                     JOIN equipments s_1 ON s_1.id_enterprise = l.id_enterprise AND l.id_equipment = s_1.id_parentequipment AND s_1.tp_equipment = 2) s9
          GROUP BY s9.id_user_role, s9.require_downtime_reason
        )
 SELECT s.id_enterprise,
    s.id_user_role,
    s.nm_user_role,
    s.enterprise,
    s.sites,
    a.areas,
    e.equipments,
    sec.sectors,
    sh.shifts,
    tm.teams
   FROM ( SELECT s1.nm_user_role,
            s1.enterprise,
            array_agg(s1.sites) AS sites,
            s1.id_enterprise,
            s1.id_user_role
           FROM ( SELECT jsonb_build_object('id_site', lines.id_site, 'nm_site', lines.nm_site, 'timezone', lines.timezone) AS sites,
                    jsonb_build_object('id_enterprise', lines.id_enterprise, 'nm_enterprise', lines.nm_enterprise) AS enterprise,
                    lines.id_enterprise,
                    lines.id_user_role,
                    lines.nm_user_role
                   FROM lines lines(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                  GROUP BY lines.id_site, lines.id_enterprise, lines.nm_site, lines.nm_enterprise, lines.id_user_role, lines.nm_user_role, lines.timezone) s1
          GROUP BY s1.id_enterprise, s1.enterprise, s1.id_user_role, s1.nm_user_role) s
     JOIN ( SELECT array_agg(s0.areas) AS areas,
            s0.id_enterprise,
            s0.id_user_role
           FROM ( SELECT jsonb_build_object('id_area', lines.id_area, 'nm_area', lines.nm_area, 'id_site', lines.id_site) AS areas,
                    lines.id_enterprise,
                    lines.id_user_role
                   FROM lines lines(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                  GROUP BY lines.id_area, lines.id_enterprise, lines.nm_area, lines.id_user_role, lines.id_site
                  ORDER BY (concat("left"(lines.nm_area::text, 1), to_char(COALESCE(NULLIF(regexp_replace(lines.nm_area::text, '[^\d]'::text, ''::text, 'g'::text), ''::text)::integer, 0), 'FM0000'::text))), lines.nm_area) s0
          GROUP BY s0.id_enterprise, s0.id_user_role) a USING (id_enterprise, id_user_role)
     JOIN ( SELECT array_agg(s1.equipments) AS equipments,
            s1.id_enterprise,
            s1.id_user_role
           FROM ( SELECT jsonb_build_object('id_equipment', lines.id_equipment, 'nm_equipment', lines.nm_equipment, 'id_area', lines.id_area, 'id_site', lines.id_site, 'require_downtime_reason', lines.require_downtime_reason) AS equipments,
                    lines.id_enterprise,
                    lines.id_user_role
                   FROM lines lines(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                  GROUP BY lines.id_equipment, lines.id_enterprise, lines.nm_equipment, lines.id_user_role, lines.id_site, lines.id_area, lines.require_downtime_reason
                  ORDER BY lines.id_area, (concat("left"(lines.nm_equipment::text, 1), to_char(COALESCE(NULLIF(regexp_replace(lines.nm_equipment::text, '[^\d]'::text, ''::text, 'g'::text), ''::text)::integer, 0), 'FM0000'::text))), lines.nm_equipment) s1
          GROUP BY s1.id_enterprise, s1.id_user_role) e USING (id_enterprise, id_user_role)
     LEFT JOIN shifts sh USING (id_user_role)
     LEFT JOIN teams tm USING (id_user_role)
     LEFT JOIN sectors sec USING (id_user_role);
;
-- ===VIEW=== v_insights_main
CREATE VIEW public.v_insights_main AS
 SELECT v_insights_downtime_module.ts_regist,
    v_insights_downtime_module.id_enterprise,
    v_insights_downtime_module.id_equipment,
    v_insights_downtime_module.id_site,
    v_insights_downtime_module.message,
    v_insights_downtime_module.warn_type,
    1 AS module_number
   FROM v_insights_downtime_module
UNION ALL
 SELECT vism.ts_regist,
    vism.id_enterprise,
    vism.id_equipment,
    vism.id_site,
    vism.message,
    vism.warn_type,
    2 AS module_number
   FROM v_insights_speed_module vism
UNION ALL
 SELECT v_insights_downtime_superposition_module.ts_regist,
    v_insights_downtime_superposition_module.id_enterprise,
    v_insights_downtime_superposition_module.id_equipment,
    v_insights_downtime_superposition_module.id_site,
    v_insights_downtime_superposition_module.message,
    v_insights_downtime_superposition_module.warn_type,
    3 AS module_number
   FROM v_insights_downtime_superposition_module;
;
-- ===VIEW=== v_menu_per_user_role
CREATE VIEW public.v_menu_per_user_role AS
 SELECT s3.id_enterprise,
    s3.id_user_role,
    array_agg(jsonb_build_object('menu_group', s3.menu_group, 'menu_items', s3.menu_items) ORDER BY s3.menu_group) AS menu
   FROM ( SELECT s2.id_enterprise,
            s2.id_user_role,
            s2.menu_group,
            array_agg(s2.menu_items ORDER BY s2.page_order, s2.page_name) AS menu_items
           FROM ( SELECT s1.id_enterprise,
                    s1.id_user_role,
                    p.menu_group,
                    p.page_name,
                    p.page_order,
                    p.page_info || s1.screen AS menu_items
                   FROM ( SELECT s0.id_enterprise,
                            s0.id_user_role,
                            s0.screen,
                            (s0.screen -> 'code'::text)::integer AS id_page
                           FROM ( SELECT ur.id_enterprise,
                                    ur.id_user_role,
                                    jsonb_array_elements((ur.permissions -> 'desktop'::text) -> 'screen'::text) AS screen
                                   FROM user_roles ur) s0) s1
                     JOIN ( SELECT pages.id_page,
                            pages.list_of_enterprises,
                            pages.page_info,
                            pages.default_piot_page,
                            (pages.page_info -> 'menu_group'::text)::integer AS menu_group,
                            (pages.page_info ->> 'name'::text)::character varying AS page_name,
                            (pages.page_info -> 'page_order'::text)::integer AS page_order
                           FROM pages) p USING (id_page)
                UNION
                 SELECT s0.id_enterprise,
                    s0.id_user_role,
                    3 AS menu_group,
                    s0.nm_equipment,
                    NULL::integer,
                    s0.overview_configuration || jsonb_build_object('URL', concat('/overview/', s0.overview_configuration ->> 'version'::text, '/', s0.id_equipment), 'name', s0.nm_equipment, 'id_equipment', s0.id_equipment) AS menu_items
                   FROM ( SELECT e.id_enterprise,
                            ur.id_user_role,
                            e.id_equipment,
                            e.nm_equipment,
                            jsonb_array_elements(e.overview_version) AS overview_configuration
                           FROM equipments e
                             JOIN ( SELECT user_roles.id_user_role,
                                    user_roles.id_enterprise,
                                    jsonb_array_elements((user_roles.permissions -> 'desktop'::text) -> 'line'::text)::integer AS id_equipment
                                   FROM user_roles) ur USING (id_enterprise, id_equipment)) s0) s2
          GROUP BY s2.id_enterprise, s2.id_user_role, s2.menu_group) s3
  GROUP BY s3.id_enterprise, s3.id_user_role;
;
-- ===VIEW=== v_mission_control
CREATE VIEW public.v_mission_control AS
 SELECT sh_info.id_site,
    sh_info.id_area,
    a2.nm_area,
    sh_info.id_equipment AS id_line,
    e2.nm_equipment AS nm_line,
    e2.id_enterprise,
    timeline.timelinestatus,
    uecs.oee AS currshift_oee,
    sh.cd_shift AS curr_shift_name,
    sh2.cd_shift AS prev1_shift_name,
    sh3.cd_shift AS prev2_shift_name,
    po.id_production_order,
    po.id_order,
    po.production_programmed,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value > po.ts_start) AS po_net_production,
    c.nm_client,
    date_part('epoch'::text, now() - po.ts_start) AS duration,
    date_part('epoch'::text, po.production_programmed::double precision / NULLIF(avg(aevm.speed), 0::double precision) * '00:01:00'::interval) AS expected_time,
    avg(aevm.speed) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range AND aevm.speed IS NOT NULL) AS curshift_lastspeed,
    sum(aevm.gross_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range) AS curshift_grosprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range) AS curshift_netprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.prev1_shift_range) AS prev1shift_netprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.prev2_shift_range) AS prev2shift_netprod,
    GREATEST(0::double precision, sum(aevm.scrap_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range)) AS curshift_scrap,
    stoppedtime.planned_duration,
    stoppedtime.planned_duration_percent,
    stoppedtime.change_over_duration,
    stoppedtime.change_over_duration_percent,
    stoppedtime.unplanned_duration,
    stoppedtime.unplanned_duration_percent,
    stoppedtime.total_stopped_time,
    to_json(timeline.timelinestatus) -> '-1'::integer AS laststate
   FROM ca_agg_equipment_values_1hour aevm
     RIGHT JOIN ( SELECT ers.id_equipment,
            e.id_area,
            e.id_site,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[1] AS current_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[1] AS curshift_range,
            max(uecs2.oee) AS currshift_oee,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[2] AS prev1_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[2] AS prev1_shift_range,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[3] AS prev2_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[3] AS prev2_shift_range
           FROM equipment_runtime_shift ers
             LEFT JOIN equipments e USING (id_equipment)
             LEFT JOIN uns_equipment_current_shift uecs2 ON uecs2.id_equipment = ers.id_equipment
          WHERE ers.ts_value < now() AND ers.ts_value > (now() - '3 days'::interval) AND e.tp_equipment = 3
          GROUP BY ers.id_equipment, e.id_area, e.id_site) sh_info USING (id_equipment)
     LEFT JOIN uns_equipment_current_shift uecs USING (id_equipment)
     LEFT JOIN ( SELECT ev.id_equipment,
            pos.id_production_order,


            pos.id_order,
            pos.id_client,
            pos.production_programmed,
            pos.production_real,
            pos.ts_start,
            last(ev.id_production_order, ev.ts_value) FILTER (WHERE ev.id_production_order IS NOT NULL) AS last_po_order
           FROM ca_agg_equipment_values_1hour ev
             LEFT JOIN production_orders pos USING (id_equipment, id_production_order)
          WHERE ev.tp_equipment = 3 AND pos.status = 2
          GROUP BY ev.id_equipment, pos.id_production_order, pos.id_order, pos.id_client, pos.production_programmed, pos.production_real, pos.ts_start) po USING (id_equipment)
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN shift_hours sh(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh.id_shift_hour = sh_info.current_shift
     LEFT JOIN shift_hours sh2(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh2.id_shift_hour = sh_info.prev1_shift
     LEFT JOIN equipments e2(id_equipment_1, cd_equipment, nm_equipment, "position", tp_equipment, id_area, id_site, id_enterprise, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, use_label_net_production, state_change_threshold_time, lead_machine, speed_calculated_by_packiot, event_generated_by_packiot, conversion_factor, net_production_type, id_plc) ON e2.id_equipment_1 = aevm.id_equipment
     LEFT JOIN areas a2 ON a2.id_area = aevm.id_area
     LEFT JOIN shift_hours sh3(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh3.id_shift_hour = sh_info.prev2_shift
     LEFT JOIN ( SELECT dt.id_equipment,
            array_agg(dt.situation ORDER BY dt.ts_value) AS timelinestatus
           FROM ( SELECT aevm_1.ts_value,
                    aevm_1.id_equipment,
                        CASE
                            WHEN COALESCE(aevm_1.net_production_incr, 0.0::double precision) >= (e.minimum_ideal_performance_threshold * e.production_speed::double precision) THEN 'running'::text
                            WHEN COALESCE(aevm_1.net_production_incr, 0.0::double precision) < (e.minimum_ideal_performance_threshold * e.production_speed::double precision) AND COALESCE(aevm_1.net_production_incr, 0.0::double precision) >= (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'lowSpeed'::text
                            WHEN COALESCE(aevm_1.net_production_incr, 0::double precision) < (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'stopped'::text
                            ELSE NULL::text
                        END AS situation
                   FROM agg_equipment_values_1min_t aevm_1
                     LEFT JOIN equipments e USING (id_equipment)
                  WHERE aevm_1.ts_value >= (now() - '24:01:00'::interval) AND aevm_1.ts_value < (now() - '00:01:00'::interval) AND aevm_1.tp_equipment = 3) dt
          GROUP BY dt.id_equipment) timeline(id_equipment_1, timelinestatus) ON timeline.id_equipment_1 = sh_info.id_equipment
     LEFT JOIN ( SELECT dsum.id_equipment,
            dsum.planned_duration,
            dsum.total_stopped_time,
            dsum.planned_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS planned_duration_percent,
            dsum.change_over_duration,
            dsum.change_over_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS change_over_duration_percent,
            dsum.unplanned_duration,
            dsum.unplanned_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS unplanned_duration_percent
           FROM ( SELECT durationsum.id_equipment,
                    durationsum.planned_duration,
                    durationsum.change_over_duration,
                    durationsum.unplanned_duration,
                    durationsum.planned_duration + durationsum.change_over_duration + durationsum.unplanned_duration AS total_stopped_time
                   FROM ( SELECT durations.id_equipment,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE
                                    WHEN durations.change_over = true THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS change_over_duration,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE
                                    WHEN durations.change_over = false AND durations.planned_downtime = true THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS planned_duration,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE
                                    WHEN durations.change_over = false AND durations.planned_downtime = false THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS unplanned_duration
                           FROM ( SELECT ee.planned_downtime,
                                    ee.change_over,
                                    ee.id_equipment,
                                    ee.status,
                                    ee.ts_event,
                                    ee.ts_end,
                                    sum(
CASE
 WHEN ee.ts_event >= (date_trunc('day'::text, now()) + '00:00:01'::interval * e3.day_begin::double precision) THEN
 CASE
  WHEN ee.ts_end IS NULL THEN now() - ee.ts_event
  ELSE ee.ts_end - ee.ts_event
 END
 ELSE
 CASE
  WHEN ee.ts_end IS NULL THEN now() - ee.ts_event
  ELSE
  CASE
   WHEN ee.ts_end > (date_trunc('day'::text, now()) + '00:00:01'::interval * e3.day_begin::double precision) THEN ee.ts_end - ee.ts_event
   ELSE NULL::interval
  END
 END
END) AS duration
                                   FROM equipment_events ee
                                     LEFT JOIN ( SELECT equipments.id_equipment,
    equipments.tp_equipment
   FROM equipments) e2_1 ON e2_1.id_equipment = ee.id_equipment
                                     LEFT JOIN ( SELECT enterprises.id_enterprise,
    enterprises.day_begin
   FROM enterprises) e3 ON e3.id_enterprise = ee.id_enterprise
                                  WHERE ee.ts_event >= (now() - '4 days'::interval) AND e2_1.tp_equipment = 3 AND ee.status = 10
                                  GROUP BY ee.id_equipment, e2_1.id_equipment, ee.ts_event, e2_1.tp_equipment, e3.id_enterprise, e3.day_begin) durations
                          GROUP BY durations.id_equipment) durationsum) dsum) stoppedtime(id_equipment_1, planned_duration, total_stopped_time, planned_duration_percent, change_over_duration, change_over_duration_percent, unplanned_duration, unplanned_duration_percent) ON stoppedtime.id_equipment_1 = sh_info.id_equipment
  WHERE aevm.ts_value >= (now() - '4 days'::interval)
  GROUP BY sh_info.id_site, sh_info.id_area, sh_info.id_equipment, sh_info.currshift_oee, sh.cd_shift, sh2.cd_shift, sh3.cd_shift, timeline.timelinestatus, po.id_production_order, po.id_order, po.ts_start, c.nm_client, po.production_programmed, e2.nm_equipment, a2.nm_area, e2.id_enterprise, stoppedtime.planned_duration, stoppedtime.planned_duration_percent, stoppedtime.change_over_duration, stoppedtime.change_over_duration_percent, stoppedtime.unplanned_duration, stoppedtime.unplanned_duration_percent, stoppedtime.total_stopped_time, uecs.oee;
;
-- ===VIEW=== v_mission_control_areas
CREATE VIEW public.v_mission_control_areas AS
 SELECT a1.id_enterprise,
    a1.id_area,
    a1.nm_area,
    a1.net_production,
    a1.gross_production,
    a1.scrap,
    a1.ts_value_production
   FROM ( SELECT vaavhf.id_area,
            a3.nm_area,
            vaavhf.id_enterprise,
            sum(vaavhf.net_production_incr) AS net_production,
            sum(vaavhf.gross_production_incr) AS gross_production,
            sum(vaavhf.scrap_incr) AS scrap,
            vaavhf.ts_value_production,
            row_number() OVER (PARTITION BY vaavhf.id_area ORDER BY vaavhf.ts_value_production DESC) AS rank_per_area
           FROM v_agg_area_values_1hour_full vaavhf
             LEFT JOIN ( SELECT areas.nm_area,
                    areas.id_area
                   FROM areas) a3 ON vaavhf.id_area = a3.id_area
          WHERE vaavhf.ts_value_production >= (now() - '7 days'::interval)
          GROUP BY vaavhf.id_enterprise, vaavhf.id_site, vaavhf.id_area, a3.nm_area, vaavhf.ts_value_production) a1
  WHERE a1.rank_per_area = 1;
;
-- ===VIEW=== v_mission_control_areas_shift
CREATE VIEW public.v_mission_control_areas_shift AS
 SELECT data.ts_value_production,
    data.id_area,
    data.nm_area,
    data.id_enterprise,
    data.gross_production,
    data.net_production,
    data.scrap,
    data.oee_q * data.oee_a * data.oee_p AS oee
   FROM ( SELECT last_shifts.ts_value AS ts_value_production,
            last_shifts.id_area,
            last_shifts.nm_area,
            last_shifts.id_enterprise,
            last_shifts.gross - last_shifts.net AS scrap,
            COALESCE(last_shifts.running_time::double precision / NULLIF(last_shifts.running_time::double precision + last_shifts.stopped_time::double precision, 0::double precision), 0::double precision) AS oee_a,
            COALESCE(last_shifts.net / NULLIF(last_shifts.gross, 0::double precision), 0::real)::double precision AS oee_q,
            last_shifts.oee_p,
            last_shifts.gross AS gross_production,
            last_shifts.net AS net_production
           FROM ( SELECT aaa.ts_value,
                    aaa.id_enterprise,
                    aa.id_area,
                    aa.nm_area,
                    sum(aaa.available_time) AS available_time,
                    sum(aaa.running_time) AS running_time,
                    sum(aaa.stopped_time) AS stopped_time,
                    sum(aaa.planned_downtime) AS planned_downtime,
                    sum(aaa.ideal_production) AS ideal_production,
                    sum(aaa.idle_time) AS idle_time,
                    sum(aaa.idle_starved) AS idle_starved,
                    sum(aaa.idle_blocked) AS idle_blocked,
                    aaa.id_shift,
                    aaa.id_shift_hour,
                    sum(aaa.duration) AS duration,
                    sum(aaa.gross) AS gross,
                    sum(aaa.net) AS net,
                    sum(aaa.downtime) AS downtime,
                    sum(aaa.changeover_time) AS changeover_time,
                    avg(aaa.oee_p_line) AS oee_p
                   FROM ( SELECT ers.ts_value,
                            ers.oee,
                            ers.recalc_needed,
                            ers.oee_p,
                            ers.oee_a,
                            ers.oee_q,
                            ers.available_time,
                            ers.running_time,
                            ers.stopped_time,
                            ers.planned_downtime,
                            ers.ideal_production,
                            ers.idle_time,
                            ers.idle_starved,
                            ers.idle_blocked,
                            ers.id_equipment,
                            ers.id_shift,
                            ers.id_shift_hour,
                            ers.id_team,
                            ers.duration,
                            ers.ts_range,
                            ers.gross,
                            ers.net,
                            ers.downtime,
                            ers.changeover_time,
                            ers.target,
                            ad.id_enterprise,
                            ad.id_area,
                            ad.id_equipment,
                            ad.tp_equipment,
                            ad.production_speed,
                            COALESCE(ers.gross * 60::double precision / NULLIF(ad.production_speed * ers.running_time, 0)::double precision, 0::double precision) AS oee_p_line,
                            rank() OVER (PARTITION BY ad.id_area ORDER BY ers.ts_value DESC) AS rank
                           FROM equipment_runtime_shift ers
                             LEFT JOIN ( SELECT e.id_enterprise,
                                    e.id_area,
                                    e.id_equipment,
                                    e.tp_equipment,
                                    e.production_speed
                                   FROM equipments e) ad ON ad.id_equipment = ers.id_equipment
                          WHERE ers.ts_value > (now() - '7 days'::interval) AND ers.ts_value <= now() AND ad.tp_equipment = 3) aaa(ts_value, oee, recalc_needed, oee_p, oee_a, oee_q, available_time, running_time, stopped_time, planned_downtime, ideal_production, idle_time, idle_starved, idle_blocked, id_equipment, id_shift, id_shift_hour, id_team, duration, ts_range, gross, net, downtime, changeover_time, target, id_enterprise, id_area, id_equipment_1, tp_equipment, production_speed, oee_p_line, rank)
                     LEFT JOIN ( SELECT a.id_area,
                            a.nm_area
                           FROM areas a) aa ON aa.id_area = aaa.id_area
                  WHERE aaa.rank = 1
                  GROUP BY aaa.id_enterprise, aa.id_area, aa.nm_area, aaa.id_shift, aaa.id_shift_hour, aaa.ts_value) last_shifts) data;
;
-- ===VIEW=== v_mission_control_areas_shift_temp_fix
CREATE VIEW public.v_mission_control_areas_shift_temp_fix AS
 SELECT dataa.ts_value_production,
    dataa.id_area,
    dataa.nm_area,
    dataa.id_enterprise,
    dataa.gross_production,
    dataa.net_production,
    dataa.scrap,
    dataa.oee_q * dataa.oee_a * dataa.oee_p AS oee
   FROM ( SELECT shift_ordered.ts_value_production,
            shift_ordered.id_area,
            ( SELECT areas.nm_area
                   FROM areas
                  WHERE areas.id_area = shift_ordered.id_area) AS nm_area,
            ( SELECT areas.id_enterprise
                   FROM areas
                  WHERE areas.id_area = shift_ordered.id_area) AS id_enterprise,
            shift_ordered.gross AS gross_production,
            shift_ordered.net AS net_production,
            COALESCE(shift_ordered.gross, 0::double precision) - COALESCE(shift_ordered.net, 0::double precision) AS scrap,
                CASE
                    WHEN shift_ordered.gross IS NOT NULL AND shift_ordered.gross > 0::double precision THEN COALESCE(shift_ordered.net, 0::double precision) / shift_ordered.gross
                    ELSE 1::double precision
                END AS oee_q,
                CASE
                    WHEN shift_ordered.available_time IS NOT NULL AND shift_ordered.available_time > 0::numeric THEN COALESCE(shift_ordered.running_time, 0::double precision) / shift_ordered.available_time::double precision
                    ELSE 1::double precision
                END AS oee_a,
                CASE
                    WHEN shift_ordered.ideal_production IS NOT NULL AND shift_ordered.ideal_production > 0::numeric THEN COALESCE(shift_ordered.gross, 0::double precision) / shift_ordered.ideal_production::double precision
                    ELSE 1::double precision
                END AS oee_p
           FROM ( SELECT shifts.id_area,
                    shifts.id_shift,
                    shifts.id_shift_hour,
                    shifts.ts_value_production,
                    shifts.ts_value,
                    COALESCE(shifts.duration, 0::double precision) AS duration,
                    COALESCE(shifts.changeover_time, 0::double precision) AS changeover_time,
                    COALESCE(shifts.planned_downtime, 0::double precision) AS planned_downtime,
                    COALESCE(shifts.running_time, 0::double precision) AS running_time,
                    COALESCE(shifts.available_time, 0::numeric) AS available_time,
                    COALESCE(shifts.net, 0::double precision) AS net,
                    COALESCE(shifts.gross, 0::double precision) AS gross,
                    COALESCE(shifts.ideal_production, 0::numeric) AS ideal_production,
                    row_number(*) OVER (PARTITION BY shifts.id_area ORDER BY shifts.ts_value_production DESC, shifts.ts_value DESC) AS row_rank
                   FROM ( SELECT shift_agg_from_events.id_area,
                            shift_agg_from_events.id_shift,
                            shift_agg_from_events.id_shift_hour,
                            shift_agg_from_events.ts_value_production,
                            shift_agg_from_events.ts_value,
                            sum(shift_agg_from_events.duration) AS duration,
                            sum(shift_agg_from_events.changeover_time) AS changeover_time,
                            sum(shift_agg_from_events.planned_downtime) AS planned_downtime,
                            sum(shift_agg_from_events.running_time) AS running_time,
                            sum(shift_agg_from_events.available_time) AS available_time,
                            sum(shift_agg_from_events.net) AS net,
                            sum(shift_agg_from_events.gross) AS gross,
                            sum(shift_agg_from_events.ideal_production) AS ideal_production
                           FROM shift_agg_from_events shift_agg_from_events
                          WHERE shift_agg_from_events.ts_value_production > (now() - '7 days'::interval)
                          GROUP BY shift_agg_from_events.id_site, shift_agg_from_events.id_area, shift_agg_from_events.id_shift_hour, shift_agg_from_events.id_shift, shift_agg_from_events.ts_value_production, shift_agg_from_events.ts_value) shifts) shift_ordered
          WHERE shift_ordered.row_rank = 1) dataa;
;
-- ===VIEW=== v_mission_control_areas_sum_from_equipment
CREATE VIEW public.v_mission_control_areas_sum_from_equipment AS
 WITH last_shift AS (
         SELECT ls_1.id_area,
            ls_1.id_shift_hour,
            ls_1.ts_value_production,
            sum(ls_1.ideal_production) AS ideal_production
           FROM ( SELECT safev.id_area,
                    safev.ts_value,
                    safev.id_shift_hour,
                    safev.ideal_production,
                    safev.ts_value_production,
                    row_number(*) OVER (PARTITION BY safev.id_area ORDER BY safev.ts_value DESC) AS rn
                   FROM shift_agg_from_events_v2 safev
                  WHERE safev.ts_value_production > (now() - '2 days'::interval)) ls_1
          WHERE ls_1.rn = 1
          GROUP BY ls_1.id_area, ls_1.id_shift_hour, ls_1.ts_value_production
        ), areas_sum AS (
         SELECT vmc.id_enterprise,
            vmc.id_area,
            vmc.nm_area,
            sum(vmc.curshift_grosprod) AS gross_production,
            sum(vmc.curshift_netprod) AS net_production,
            sum(vmc.curshift_scrap) AS scrap
           FROM v_mission_control vmc
          GROUP BY vmc.id_enterprise, vmc.id_area, vmc.nm_area
        )
 SELECT ls.ts_value_production,
    sa.id_enterprise,
    sa.id_area,
    sa.nm_area,
    sa.gross_production,
    sa.net_production,
    sa.scrap,
    sa.net_production / NULLIF(ls.ideal_production, 0::numeric)::double precision AS oee_area_raw,
    COALESCE(LEAST(1::double precision, GREATEST(0::double precision, sa.net_production / NULLIF(ls.ideal_production, 0::numeric)::double precision)), 0::double precision) AS oee_area
   FROM areas_sum sa
     LEFT JOIN last_shift ls USING (id_area);
;
-- ===VIEW=== v_operator_entities
CREATE VIEW public.v_operator_entities AS
 WITH enterprises AS (
         SELECT pr.id_packml_register,
            pr.packml_topic,
            pr."timestamp",
            pr.value,
            pr.signal_quality,
            pr.ts_quality,
            pr.mqtt_topic,
            pr.sparkplug_json,
            pr.id_equipment,
            pr.id_site,
            pr.id_area,
            pr.id_enterprise,
            pr.id_infeedcounter,
            pr.id_outfeedcounter,
            pr.id_rejectcounter,
            pr.active,
            pr.attributed,
            pr.id_unit,
            pr.line_unit_seq,
            pr.device_nm
           FROM packml_register pr
          WHERE pr.packml_topic::text !~~ '%/%'::text
        ), sites AS (
         SELECT pr.id_packml_register,
            pr.packml_topic,
            pr."timestamp",
            pr.value,
            pr.signal_quality,
            pr.ts_quality,
            pr.mqtt_topic,
            pr.sparkplug_json,
            pr.id_equipment,
            pr.id_site,
            pr.id_area,
            pr.id_enterprise,
            pr.id_infeedcounter,
            pr.id_outfeedcounter,


            pr.id_rejectcounter,
            pr.active,
            pr.attributed,
            pr.id_unit,
            pr.line_unit_seq,
            pr.device_nm
           FROM packml_register pr
          WHERE pr.packml_topic::text ~~ '%/%'::text AND pr.packml_topic::text !~~ '%/%/%'::text
        ), areas AS (
         SELECT pr.id_packml_register,
            pr.packml_topic,
            pr."timestamp",
            pr.value,
            pr.signal_quality,
            pr.ts_quality,
            pr.mqtt_topic,
            pr.sparkplug_json,
            pr.id_equipment,
            pr.id_site,
            pr.id_area,
            pr.id_enterprise,
            pr.id_infeedcounter,
            pr.id_outfeedcounter,
            pr.id_rejectcounter,
            pr.active,
            pr.attributed,
            pr.id_unit,
            pr.line_unit_seq,
            pr.device_nm
           FROM packml_register pr
          WHERE pr.packml_topic::text ~~ '%/%/%'::text AND pr.packml_topic::text !~~ '%/%/%/%'::text
        ), lines AS (
         SELECT pr.id_packml_register,
            pr.packml_topic,
            pr."timestamp",
            pr.value,
            pr.signal_quality,
            pr.ts_quality,
            pr.mqtt_topic,
            pr.sparkplug_json,
            pr.id_equipment,
            pr.id_site,
            pr.id_area,
            pr.id_enterprise,
            pr.id_infeedcounter,
            pr.id_outfeedcounter,
            pr.id_rejectcounter,
            pr.active,
            pr.attributed,
            pr.id_unit,
            pr.line_unit_seq,
            pr.device_nm
           FROM packml_register pr
          WHERE pr.packml_topic::text ~~ '%/%/%/%'::text AND pr.packml_topic::text !~~ '%/%/%/%/%'::text AND pr.packml_topic::text !~~ '%/%/%/%::%'::text
        ), sectors AS (
         SELECT pr.id_packml_register,
            pr.packml_topic,
            pr."timestamp",
            pr.value,
            pr.signal_quality,
            pr.ts_quality,
            pr.mqtt_topic,
            pr.sparkplug_json,
            pr.id_equipment,
            pr.id_site,
            pr.id_area,
            pr.id_enterprise,
            pr.id_infeedcounter,
            pr.id_outfeedcounter,
            pr.id_rejectcounter,
            pr.active,
            pr.attributed,
            pr.id_unit,
            pr.line_unit_seq,
            pr.device_nm
           FROM packml_register pr
          WHERE pr.packml_topic::text ~~ '%/%/%/%'::text AND pr.packml_topic::text !~~ '%/%/%/%/%'::text AND pr.packml_topic::text ~~ '%/%/%/%::%'::text
        ), machines AS (
         SELECT pr.id_packml_register,
            pr.packml_topic,
            pr."timestamp",
            pr.value,
            pr.signal_quality,
            pr.ts_quality,
            pr.mqtt_topic,
            pr.sparkplug_json,
            pr.id_equipment,
            pr.id_site,
            pr.id_area,
            pr.id_enterprise,
            pr.id_infeedcounter,
            pr.id_outfeedcounter,
            pr.id_rejectcounter,
            pr.active,
            pr.attributed,
            pr.id_unit,
            pr.line_unit_seq,
            pr.device_nm
           FROM packml_register pr
          WHERE pr.packml_topic::text ~~ '%/%/%/%/%'::text AND pr.packml_topic::text !~~ '%/%/%/%/%/%'::text
        )
 SELECT et.id_enterprise,
    et.enterprise,
    s.sites,
    a.areas,
    l.lines,
    se.sectors,
    mac.machines
   FROM ( SELECT et_1.id_enterprise,
            json_object_agg(et_1.packml_topic, e.nm_enterprise) AS enterprise
           FROM enterprises et_1
             JOIN public.enterprises e USING (id_enterprise)
          GROUP BY et_1.id_enterprise) et
     JOIN ( SELECT et_1.id_enterprise,
            json_object_agg(et_1.packml_topic, e.nm_site) AS sites
           FROM sites et_1
             JOIN public.sites e USING (id_enterprise, id_site)
          GROUP BY et_1.id_enterprise) s USING (id_enterprise)
     JOIN ( SELECT et_1.id_enterprise,
            json_object_agg(et_1.packml_topic, e.nm_area) AS areas
           FROM areas et_1
             JOIN public.areas e USING (id_enterprise, id_site, id_area)
          GROUP BY et_1.id_enterprise) a USING (id_enterprise)
     JOIN ( SELECT et_1.id_enterprise,
            json_object_agg(et_1.packml_topic, e.nm_equipment) AS lines
           FROM lines et_1
             JOIN equipments e USING (id_enterprise, id_site, id_area, id_equipment)
          GROUP BY et_1.id_enterprise) l USING (id_enterprise)
     LEFT JOIN ( SELECT et_1.id_enterprise,
            json_object_agg(et_1.packml_topic, e.nm_equipment) AS sectors
           FROM sectors et_1
             JOIN equipments e USING (id_enterprise, id_site, id_area, id_equipment)
          GROUP BY et_1.id_enterprise) se USING (id_enterprise)
     JOIN ( SELECT et_1.id_enterprise,
            json_object_agg(et_1.packml_topic, e.nm_equipment) AS machines
           FROM machines et_1
             JOIN equipments e USING (id_enterprise, id_site, id_area, id_equipment)
          GROUP BY et_1.id_enterprise) mac USING (id_enterprise);
;
-- ===VIEW=== v_operator_po_list
CREATE VIEW public.v_operator_po_list AS
 SELECT po.id_production_order,
    po.id_order,
    pf.nm_product_family,
    c.nm_client,
    po.production_programmed,
    po.ts_start,
    po.id_equipment,
    po.status,
    po.id_enterprise,
    pr.packml_topic AS topic,
    po.conversion_factor
   FROM production_orders po,
    clients c,
    products p,
    product_families pf,
    packml_register pr
  WHERE po.id_product = p.id_product AND p.id_product_family = pf.id_product_family AND po.id_client = c.id_client AND ((po.status = ANY (ARRAY[1, 2, 4])) OR po.status = 3 AND po.ts_end >= (now() - '10 days'::interval)) AND pr.id_equipment = po.id_equipment AND pr.id_enterprise = po.id_enterprise
  GROUP BY pf.nm_product_family, po.id_production_order, c.nm_client, po.production_programmed, po.ts_start, po.id_enterprise, po.id_equipment, po.status, pr.packml_topic;
;
-- ===VIEW=== v_operator_po_list_setup
CREATE VIEW public.v_operator_po_list_setup AS
 SELECT po.id_production_order,
    po.id_order,
    pf.nm_product_family,
    c.nm_client,
    po.production_programmed,
    po.ts_start,
    po.id_equipment,
    po.status,
    po.id_enterprise,
    pr.packml_topic AS topic,
    po.conversion_factor,
    p.equipment_setup,
    p.nm_product
   FROM production_orders po,
    clients c,
    products p,
    product_families pf,
    packml_register pr
  WHERE po.id_product = p.id_product AND p.id_product_family = pf.id_product_family AND po.id_client = c.id_client AND ((po.status = ANY (ARRAY[1, 2, 4])) OR po.status = 3 AND po.ts_end >= (now() - '10 days'::interval)) AND pr.id_equipment = po.id_equipment AND pr.id_enterprise = po.id_enterprise
  GROUP BY pf.nm_product_family, po.id_production_order, c.nm_client, po.production_programmed, po.ts_start, po.id_enterprise, po.id_equipment, po.status, pr.packml_topic, p.equipment_setup, p.nm_product;
;
-- ===VIEW=== v_operator_po_list_setup_2
CREATE VIEW public.v_operator_po_list_setup_2 AS
 SELECT po.id_production_order,
    po.id_order,
    pf.nm_product_family,
    c.nm_client,
    po.production_programmed,
    po.ts_start,
    po.id_equipment,
    po.status,
    po.id_enterprise,
    pr.packml_topic AS topic,
    po.conversion_factor,
    p.equipment_setup,
    p.nm_product,
    po.custom_field
   FROM production_orders po,
    clients c,
    products p,
    product_families pf,
    packml_register pr
  WHERE po.id_product = p.id_product AND p.id_product_family = pf.id_product_family AND po.id_client = c.id_client AND ((po.status = ANY (ARRAY[1, 2, 4])) OR po.status = 3 AND po.ts_end >= (now() - '10 days'::interval)) AND pr.id_equipment = po.id_equipment AND pr.id_enterprise = po.id_enterprise
  GROUP BY pf.nm_product_family, po.id_production_order, c.nm_client, po.production_programmed, po.ts_start, po.id_enterprise, po.id_equipment, po.status, pr.packml_topic, p.equipment_setup, p.nm_product;
;
-- ===VIEW=== v_operator_po_list_setup_3
CREATE VIEW public.v_operator_po_list_setup_3 AS
 SELECT po.id_production_order,
    po.id_order,
    pf.nm_product_family,
    c.nm_client,
    po.production_programmed,
    po.ts_start,
    po.id_equipment,
    po.status,
    po.id_enterprise,
    pr.packml_topic AS topic,
    po.conversion_factor,
    p.equipment_setup,
    p.nm_product,
    po.custom_field,
    po.custom_field -> 'priority'::text AS priority
   FROM production_orders po
     LEFT JOIN clients c USING (id_enterprise, id_client)
     LEFT JOIN products p USING (id_enterprise, id_product)
     LEFT JOIN product_families pf USING (id_enterprise, id_product_family)
     LEFT JOIN packml_register pr USING (id_enterprise, id_equipment)
  WHERE (po.status = ANY (ARRAY[1, 2, 4])) OR po.status = 3 AND po.ts_end >= (now() - '10 days'::interval);
;
-- ===VIEW=== v_pages
CREATE VIEW public.v_pages AS
 SELECT pages.id_page,
    pages.page_info,
    pages.default_piot_page,
    unnest(pages.list_of_enterprises) AS id_enterprise
   FROM pages;
;
-- ===VIEW=== v_total_production_month_grain_1day
CREATE VIEW public.v_total_production_month_grain_1day AS
 SELECT s0.id_enterprise,
    s0.id_site,
    s0.id_area,
    s0.id_equipment,
    s0.ts_value,
    s0.gross_production,
    s0.net_production,
    s0.gross_production_partial AS gross_production_incr,
    s0.net_production_partial AS net_production_incr
   FROM ( SELECT t.id_enterprise,
            t.id_site,
            t.id_area,
            t.id_equipment,
            ts.ts AS ts_value,
            COALESCE(t.gross_production, 0::double precision) AS gross_production,
            COALESCE(t.net_production, 0::double precision) AS net_production,
            t.gross_production_partial,
            t.net_production_partial
           FROM generate_series(date_trunc('MONTH'::text, now())::timestamp without time zone, date_trunc('DAY'::text, now())::timestamp without time zone, '1 day'::interval) ts(ts)
             LEFT JOIN ( SELECT dta.id_enterprise,
                    dta.id_site,
                    dta.id_area,
                    dta.id_equipment,
                    dta.ts_value,
                    dta.gross_production_partial,
                    dta.net_production_partial,
                    dta.net_production,
                    dta.gross_production
                   FROM ( SELECT dp.id_enterprise,
                            dp.id_site,
                            dp.id_area,
                            dp.id_equipment,
                            dp.ts_value,
                            dp.gross_production_partial,
                            dp.net_production_partial,
                            sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
                            sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
                           FROM ( SELECT vaevdf.id_enterprise,
                                    vaevdf.id_site,
                                    vaevdf.id_area,
                                    vaevdf.id_equipment,
                                    sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
                                    sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
                                    vaevdf.ts_value
                                   FROM v_agg_equipment_values_1day_full vaevdf
                                  WHERE vaevdf.ts_value >= date_trunc('MONTH'::text, now()) AND vaevdf.tp_equipment = 3
                                  GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
                                  ORDER BY vaevdf.ts_value) dp
                          GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
                          ORDER BY dp.id_equipment, dp.ts_value) dta) t ON t.ts_value = ts.ts) s0
  WHERE s0.ts_value >= date_trunc('MONTH'::text, now())
  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value;
;
-- ===VIEW=== v_total_production_month_grain_1week
CREATE VIEW public.v_total_production_month_grain_1week AS
 SELECT s0.id_enterprise,
    s0.id_site,
    s0.id_area,
    s0.id_equipment,
    s0.ts_value,
    s0.gross_production,
    s0.net_production,
    s0.gross_production_partial AS gross_production_incr,
    s0.net_production_partial AS net_production_incr
   FROM ( SELECT t.id_enterprise,
            t.id_site,
            t.id_area,
            t.id_equipment,
            ts.ts AS ts_value,
            COALESCE(t.gross_production, 0::double precision) AS gross_production,
            COALESCE(t.net_production, 0::double precision) AS net_production,
            t.gross_production_partial,
            t.net_production_partial
           FROM generate_series(date_trunc('MONTH'::text, now())::timestamp without time zone, date_trunc('WEEK'::text, now())::timestamp without time zone, '7 days'::interval) ts(ts)
             LEFT JOIN ( SELECT dta.id_enterprise,
                    dta.id_site,
                    dta.id_area,
                    dta.id_equipment,
                    dta.ts_value,
                    dta.gross_production_partial,
                    dta.net_production_partial,
                    dta.net_production,
                    dta.gross_production
                   FROM ( SELECT dp.id_enterprise,
                            dp.id_site,
                            dp.id_area,
                            dp.id_equipment,
                            dp.ts_value,
                            dp.gross_production_partial,
                            dp.net_production_partial,
                            sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
                            sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
                           FROM ( SELECT vaevdf.id_enterprise,
                                    vaevdf.id_site,
                                    vaevdf.id_area,
                                    vaevdf.id_equipment,
                                    sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
                                    sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
                                    vaevdf.ts_value
                                   FROM v_agg_equipment_values_1day_full vaevdf
                                  WHERE vaevdf.ts_value >= date_trunc('WEEK'::text, date_trunc('MONTH'::text, now())) AND vaevdf.tp_equipment = 3
                                  GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
                                  ORDER BY vaevdf.ts_value) dp
                          GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
                          ORDER BY dp.id_equipment, dp.ts_value) dta) t ON t.ts_value = ts.ts) s0
  WHERE s0.ts_value >= date_trunc('WEEK'::text, date_trunc('MONTH'::text, now()))
  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value;
;
-- ===VIEW=== v_total_production_today


CREATE VIEW public.v_total_production_today AS
 SELECT s0.id_enterprise,
    s0.id_site,
    s0.id_area,
    s0.id_equipment,
    s0.ts_value,
    s0.gross_production,
    s0.net_production,
    s0.gross_production_partial AS gross_production_incr,
    s0.net_production_partial AS net_production_incr
   FROM ( SELECT t.id_enterprise,
            t.id_site,
            t.id_area,
            t.id_equipment,
            ts.ts AS ts_value,
            COALESCE(t.gross_production, 0::double precision) AS gross_production,
            COALESCE(t.net_production, 0::double precision) AS net_production,
            t.gross_production_partial,
            t.net_production_partial
           FROM generate_series(date_trunc('DAY'::text, now())::timestamp without time zone, date_trunc('HOUR'::text, now())::timestamp without time zone, '01:00:00'::interval) ts(ts)
             LEFT JOIN ( SELECT dta.id_enterprise,
                    dta.id_site,
                    dta.id_area,
                    dta.id_equipment,
                    dta.ts_value,
                    dta.gross_production_partial,
                    dta.net_production_partial,
                    dta.net_production,
                    dta.gross_production
                   FROM ( SELECT dp.id_enterprise,
                            dp.id_site,
                            dp.id_area,
                            dp.id_equipment,
                            dp.ts_value,
                            dp.gross_production_partial,
                            dp.net_production_partial,
                            sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
                            sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
                           FROM ( SELECT vaevdf.id_enterprise,
                                    vaevdf.id_site,
                                    vaevdf.id_area,
                                    vaevdf.id_equipment,
                                    sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
                                    sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
                                    vaevdf.ts_value
                                   FROM v_agg_equipment_values_1hour_full vaevdf
                                  WHERE vaevdf.ts_value >= date_trunc('DAY'::text, now()) AND vaevdf.tp_equipment = 3
                                  GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
                                  ORDER BY vaevdf.ts_value) dp
                          GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
                          ORDER BY dp.id_equipment, dp.ts_value) dta) t ON t.ts_value = ts.ts) s0
  WHERE s0.ts_value >= date_trunc('DAY'::text, now())
  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value;
;
-- ===VIEW=== v_total_production_yesterday
CREATE VIEW public.v_total_production_yesterday AS
 SELECT s0.id_enterprise,
    s0.id_site,
    s0.id_area,
    s0.id_equipment,
    s0.ts_value,
    s0.gross_production,
    s0.net_production,
    s0.gross_production_partial AS gross_production_incr,
    s0.net_production_partial AS net_production_incr
   FROM ( SELECT t.id_enterprise,
            t.id_site,
            t.id_area,
            t.id_equipment,
            ts.ts AS ts_value,
            COALESCE(t.gross_production, 0::double precision) AS gross_production,
            COALESCE(t.net_production, 0::double precision) AS net_production,
            t.gross_production_partial,
            t.net_production_partial
           FROM generate_series(date_trunc('DAY'::text, (now() - '1 day'::interval)::timestamp without time zone), date_trunc('DAY'::text, date_trunc('DAY'::text, now()))::timestamp without time zone - '01:00:00'::interval, '01:00:00'::interval) ts(ts)
             LEFT JOIN ( SELECT dta.id_enterprise,
                    dta.id_site,
                    dta.id_area,
                    dta.id_equipment,
                    dta.ts_value,
                    dta.gross_production_partial,
                    dta.net_production_partial,
                    dta.net_production,
                    dta.gross_production
                   FROM ( SELECT dp.id_enterprise,
                            dp.id_site,
                            dp.id_area,
                            dp.id_equipment,
                            dp.ts_value,
                            dp.gross_production_partial,
                            dp.net_production_partial,
                            sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
                            sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
                           FROM ( SELECT vaevdf.id_enterprise,
                                    vaevdf.id_site,
                                    vaevdf.id_area,
                                    vaevdf.id_equipment,
                                    sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
                                    sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
                                    vaevdf.ts_value
                                   FROM v_agg_equipment_values_1hour_full vaevdf
                                  WHERE vaevdf.ts_value >= date_trunc('DAY'::text, now() - '1 day'::interval) AND vaevdf.tp_equipment = 3
                                  GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
                                  ORDER BY vaevdf.ts_value) dp
                          GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
                          ORDER BY dp.id_equipment, dp.ts_value) dta) t ON t.ts_value = ts.ts) s0
  WHERE s0.ts_value >= date_trunc('DAY'::text, now() - '1 day'::interval)
  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value;
;



-- ===OBJ=== mv_agg_equipment_values_1day_full_hot kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1day_full_hot AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_equipment,
    s2.id_area,
    s2.id_site,
    s2.id_enterprise,
    s2.tp_equipment,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.mode,
    s2.id_production_order,
    s2.conversion_factor,
    s2.number_cavities,
    s2.signal_quality,
    s2.speed,
    s2.net_production_val,
    s2.gross_production_val,
    s2.scrap_val,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour,
    s2.id_equipment_line_connected,
    s2.position_in_equipment_line,
    s2.is_equipment_line_infeed,
    s2.is_equipment_line_outfeed,
    s2.ideal_production_speed
   FROM ( SELECT v_agg_equipment_values_1hour_full.ts_value_production AS ts_value,
            v_agg_equipment_values_1hour_full.id_equipment,
            v_agg_equipment_values_1hour_full.id_area,
            v_agg_equipment_values_1hour_full.id_site,
            v_agg_equipment_values_1hour_full.id_enterprise,
            v_agg_equipment_values_1hour_full.tp_equipment,
            COALESCE(sum(v_agg_equipment_values_1hour_full.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour_full.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour_full.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_equipment_values_1hour_full.mode,
            v_agg_equipment_values_1hour_full.id_production_order,
            v_agg_equipment_values_1hour_full.conversion_factor,
            v_agg_equipment_values_1hour_full.number_cavities,
            locf(max(v_agg_equipment_values_1hour_full.signal_quality), treat_null_as_missing => true) AS signal_quality,
            COALESCE(avg(v_agg_equipment_values_1hour_full.speed) FILTER (WHERE v_agg_equipment_values_1hour_full.speed > 0::double precision), 0::double precision) AS speed,
            locf(max(v_agg_equipment_values_1hour_full.net_production_val), treat_null_as_missing => true) AS net_production_val,
            locf(max(v_agg_equipment_values_1hour_full.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
            locf(max(v_agg_equipment_values_1hour_full.scrap_val), treat_null_as_missing => true) AS scrap_val,
            v_agg_equipment_values_1hour_full.id_shift,
            v_agg_equipment_values_1hour_full.id_team,
            v_agg_equipment_values_1hour_full.id_shift_hour,
            v_agg_equipment_values_1hour_full.id_equipment_line_connected,
            v_agg_equipment_values_1hour_full.position_in_equipment_line,
            v_agg_equipment_values_1hour_full.is_equipment_line_infeed,
            v_agg_equipment_values_1hour_full.is_equipment_line_outfeed,
            v_agg_equipment_values_1hour_full.ideal_production_speed
           FROM v_agg_equipment_values_1hour_full
          WHERE v_agg_equipment_values_1hour_full.ts_value >= (now() - '11 days'::interval) AND v_agg_equipment_values_1hour_full.ts_value_production IS NOT NULL
          GROUP BY v_agg_equipment_values_1hour_full.ts_value_production, v_agg_equipment_values_1hour_full.id_equipment, v_agg_equipment_values_1hour_full.id_area, v_agg_equipment_values_1hour_full.id_site, v_agg_equipment_values_1hour_full.id_enterprise, v_agg_equipment_values_1hour_full.tp_equipment, v_agg_equipment_values_1hour_full.mode, v_agg_equipment_values_1hour_full.id_production_order, v_agg_equipment_values_1hour_full.conversion_factor, v_agg_equipment_values_1hour_full.number_cavities, v_agg_equipment_values_1hour_full.id_shift, v_agg_equipment_values_1hour_full.id_team, v_agg_equipment_values_1hour_full.id_shift_hour, v_agg_equipment_values_1hour_full.id_equipment_line_connected, v_agg_equipment_values_1hour_full.position_in_equipment_line, v_agg_equipment_values_1hour_full.is_equipment_line_infeed, v_agg_equipment_values_1hour_full.is_equipment_line_outfeed, v_agg_equipment_values_1hour_full.ideal_production_speed
          ORDER BY v_agg_equipment_values_1hour_full.id_equipment, v_agg_equipment_values_1hour_full.ts_value_production) s2;
;
-- ===OBJ=== mv_agg_equipment_values_1day_full_warm kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1day_full_warm AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_equipment,
    s2.id_area,
    s2.id_site,
    s2.id_enterprise,
    s2.tp_equipment,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.mode,
    s2.id_production_order,
    s2.conversion_factor,
    s2.number_cavities,
    s2.signal_quality,
    s2.speed,
    s2.net_production_val,
    s2.gross_production_val,
    s2.scrap_val,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour,
    s2.id_equipment_line_connected,
    s2.position_in_equipment_line,
    s2.is_equipment_line_infeed,
    s2.is_equipment_line_outfeed,
    s2.ideal_production_speed
   FROM ( SELECT v_agg_equipment_values_1hour_full.ts_value_production AS ts_value,
            v_agg_equipment_values_1hour_full.id_equipment,
            v_agg_equipment_values_1hour_full.id_area,
            v_agg_equipment_values_1hour_full.id_site,
            v_agg_equipment_values_1hour_full.id_enterprise,
            v_agg_equipment_values_1hour_full.tp_equipment,
            COALESCE(sum(v_agg_equipment_values_1hour_full.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour_full.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour_full.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_equipment_values_1hour_full.mode,
            v_agg_equipment_values_1hour_full.id_production_order,
            v_agg_equipment_values_1hour_full.conversion_factor,
            v_agg_equipment_values_1hour_full.number_cavities,
            locf(max(v_agg_equipment_values_1hour_full.signal_quality), treat_null_as_missing => true) AS signal_quality,
            COALESCE(avg(v_agg_equipment_values_1hour_full.speed) FILTER (WHERE v_agg_equipment_values_1hour_full.speed > 0::double precision), 0::double precision) AS speed,
            locf(max(v_agg_equipment_values_1hour_full.net_production_val), treat_null_as_missing => true) AS net_production_val,
            locf(max(v_agg_equipment_values_1hour_full.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
            locf(max(v_agg_equipment_values_1hour_full.scrap_val), treat_null_as_missing => true) AS scrap_val,
            v_agg_equipment_values_1hour_full.id_shift,
            v_agg_equipment_values_1hour_full.id_team,
            v_agg_equipment_values_1hour_full.id_shift_hour,
            v_agg_equipment_values_1hour_full.id_equipment_line_connected,
            v_agg_equipment_values_1hour_full.position_in_equipment_line,
            v_agg_equipment_values_1hour_full.is_equipment_line_infeed,
            v_agg_equipment_values_1hour_full.is_equipment_line_outfeed,
            v_agg_equipment_values_1hour_full.ideal_production_speed
           FROM v_agg_equipment_values_1hour_full
          WHERE v_agg_equipment_values_1hour_full.ts_value >= date_trunc('day'::text, now() - '70 days'::interval) AND v_agg_equipment_values_1hour_full.ts_value < now() AND v_agg_equipment_values_1hour_full.ts_value_production IS NOT NULL
          GROUP BY v_agg_equipment_values_1hour_full.ts_value_production, v_agg_equipment_values_1hour_full.id_equipment, v_agg_equipment_values_1hour_full.id_area, v_agg_equipment_values_1hour_full.id_site, v_agg_equipment_values_1hour_full.id_enterprise, v_agg_equipment_values_1hour_full.tp_equipment, v_agg_equipment_values_1hour_full.mode, v_agg_equipment_values_1hour_full.id_production_order, v_agg_equipment_values_1hour_full.conversion_factor, v_agg_equipment_values_1hour_full.number_cavities, v_agg_equipment_values_1hour_full.id_shift, v_agg_equipment_values_1hour_full.id_team, v_agg_equipment_values_1hour_full.id_shift_hour, v_agg_equipment_values_1hour_full.id_equipment_line_connected, v_agg_equipment_values_1hour_full.position_in_equipment_line, v_agg_equipment_values_1hour_full.is_equipment_line_infeed, v_agg_equipment_values_1hour_full.is_equipment_line_outfeed, v_agg_equipment_values_1hour_full.ideal_production_speed
          ORDER BY v_agg_equipment_values_1hour_full.id_equipment, v_agg_equipment_values_1hour_full.ts_value_production) s2;
;
-- ===OBJ=== mv_agg_equipment_values_1hour_full_hot kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1hour_full_hot AS
 SELECT date_trunc('hour'::text, a.ts_value) AS ts_value,
    a.id_equipment,
    a.id_area,
    a.id_site,
    a.id_enterprise,
    a.tp_equipment,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.ts_value_production,
    a.mode,
    a.id_production_order,
    a.conversion_factor,
    a.number_cavities,
    max(a.signal_quality) AS signal_quality,
    COALESCE(avg(a.speed) FILTER (WHERE a.speed > 0::double precision), 0::double precision) AS speed,
    max(a.net_production_val) AS net_production_val,
    max(a.gross_production_val) AS gross_production_val,
    max(a.scrap_val) AS scrap_val,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.id_equipment_line_connected,
    a.position_in_equipment_line,
    a.is_equipment_line_infeed,
    a.is_equipment_line_outfeed,
    a.ideal_production_speed
   FROM v_agg_equipment_values_1min_full a
  WHERE a.ts_value >= (now() - '11 days'::interval) AND a.ts_value_production IS NOT NULL
  GROUP BY (date_trunc('hour'::text, a.ts_value)), a.id_equipment, a.id_area, a.id_site, a.id_enterprise, a.tp_equipment, a.ts_value_production, a.mode, a.id_production_order, a.conversion_factor, a.number_cavities, a.id_shift, a.id_team, a.id_shift_hour, a.id_equipment_line_connected, a.position_in_equipment_line, a.is_equipment_line_infeed, a.is_equipment_line_outfeed, a.ideal_production_speed
  ORDER BY a.id_equipment, (date_trunc('hour'::text, a.ts_value)) DESC;
;
-- ===OBJ=== mv_agg_equipment_values_1hour_full_warm kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1hour_full_warm AS
 SELECT date_trunc('hour'::text, a.ts_value) AS ts_value,
    a.id_equipment,
    a.id_area,
    a.id_site,
    a.id_enterprise,
    a.tp_equipment,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.ts_value_production,
    a.mode,
    a.id_production_order,
    a.conversion_factor,
    a.number_cavities,
    max(a.signal_quality) AS signal_quality,
    COALESCE(avg(a.speed) FILTER (WHERE a.speed > 0::double precision), 0::double precision) AS speed,
    max(a.net_production_val) AS net_production_val,
    max(a.gross_production_val) AS gross_production_val,
    max(a.scrap_val) AS scrap_val,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.id_equipment_line_connected,
    a.position_in_equipment_line,
    a.is_equipment_line_infeed,
    a.is_equipment_line_outfeed,
    a.ideal_production_speed
   FROM v_agg_equipment_values_1min_full a
  WHERE a.ts_value >= date_trunc('day'::text, now() - '70 days'::interval) AND a.ts_value < now() AND a.ts_value_production IS NOT NULL
  GROUP BY (date_trunc('hour'::text, a.ts_value)), a.id_equipment, a.id_area, a.id_site, a.id_enterprise, a.tp_equipment, a.ts_value_production, a.mode, a.id_production_order, a.conversion_factor, a.number_cavities, a.id_shift, a.id_team, a.id_shift_hour, a.id_equipment_line_connected, a.position_in_equipment_line, a.is_equipment_line_infeed, a.is_equipment_line_outfeed, a.ideal_production_speed
  ORDER BY a.id_equipment, (date_trunc('hour'::text, a.ts_value)) DESC;
;
-- ===OBJ=== mv_agg_equipment_values_1min_full_hot kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1min_full_hot AS
 SELECT time_bucket_gapfill('00:01:00'::interval, a.ts_value, date_trunc('day'::text, now() - '11 days'::interval), now()) AS ts_value,
    a.id_equipment,
    a.id_area,
    a.id_site,
    a.id_enterprise,
    a.tp_equipment,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    locf(max(a.ts_value_production), treat_null_as_missing => true) AS ts_value_production,
    locf(max(a.state), treat_null_as_missing => true) AS state,
    locf(max(a.mode), treat_null_as_missing => true) AS mode,
    locf(max(a.id_production_order), treat_null_as_missing => true) AS id_production_order,
    locf(max(a.conversion_factor), treat_null_as_missing => true) AS conversion_factor,
    locf(max(a.number_cavities), treat_null_as_missing => true) AS number_cavities,
    locf(max(a.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(a.speed) FILTER (WHERE a.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(a.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(a.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(a.scrap_val), treat_null_as_missing => true) AS scrap_val,
    locf(max(a.id_shift), treat_null_as_missing => true) AS id_shift,
    locf(max(a.id_team), treat_null_as_missing => true) AS id_team,
    locf(max(a.id_shift_hour), treat_null_as_missing => true) AS id_shift_hour,
    locf(max(a.box_code::text), treat_null_as_missing => true) AS box_code,
    locf(max(a.transaction_code::text), treat_null_as_missing => true) AS transaction_code,
    locf(max(a.id_equipment_line_connected), treat_null_as_missing => true) AS id_equipment_line_connected,
    locf(max(a.position_in_equipment_line), treat_null_as_missing => true) AS position_in_equipment_line,
    locf(max(a.is_equipment_line_infeed), treat_null_as_missing => true) AS is_equipment_line_infeed,
    locf(max(a.is_equipment_line_outfeed), treat_null_as_missing => true) AS is_equipment_line_outfeed,
    locf(max(a.ideal_production_speed), treat_null_as_missing => true) AS ideal_production_speed
   FROM v_agg_equipment_values_1min_layer a
  WHERE a.ts_value >= date_trunc('day'::text, now() - '11 days'::interval) AND a.ts_value < now() AND a.id_area IS NOT NULL
  GROUP BY (time_bucket_gapfill('00:01:00'::interval, a.ts_value, date_trunc('day'::text, now() - '11 days'::interval), now())), a.id_equipment, a.id_area, a.id_site, a.id_enterprise, a.tp_equipment
  ORDER BY a.id_equipment, (time_bucket_gapfill('00:01:00'::interval, a.ts_value, date_trunc('day'::text, now() - '11 days'::interval), now())) DESC;
;
-- ===OBJ=== mv_agg_equipment_values_1min_full_warm kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1min_full_warm AS
 SELECT time_bucket_gapfill('00:01:00'::interval, a.ts_value, date_trunc('day'::text, now() - '70 days'::interval), now()) AS ts_value,
    a.id_equipment,
    a.id_area,
    a.id_site,
    a.id_enterprise,
    a.tp_equipment,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    locf(max(a.ts_value_production), treat_null_as_missing => true) AS ts_value_production,
    locf(max(a.state), treat_null_as_missing => true) AS state,
    locf(max(a.mode), treat_null_as_missing => true) AS mode,
    locf(max(a.id_production_order), treat_null_as_missing => true) AS id_production_order,
    locf(max(a.conversion_factor), treat_null_as_missing => true) AS conversion_factor,
    locf(max(a.number_cavities), treat_null_as_missing => true) AS number_cavities,
    locf(max(a.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(a.speed) FILTER (WHERE a.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(a.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(a.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(a.scrap_val), treat_null_as_missing => true) AS scrap_val,
    locf(max(a.id_shift), treat_null_as_missing => true) AS id_shift,
    locf(max(a.id_team), treat_null_as_missing => true) AS id_team,
    locf(max(a.id_shift_hour), treat_null_as_missing => true) AS id_shift_hour,
    locf(max(a.box_code::text), treat_null_as_missing => true) AS box_code,
    locf(max(a.transaction_code::text), treat_null_as_missing => true) AS transaction_code,
    locf(max(a.id_equipment_line_connected), treat_null_as_missing => true) AS id_equipment_line_connected,
    locf(max(a.position_in_equipment_line), treat_null_as_missing => true) AS position_in_equipment_line,
    locf(max(a.is_equipment_line_infeed), treat_null_as_missing => true) AS is_equipment_line_infeed,
    locf(max(a.is_equipment_line_outfeed), treat_null_as_missing => true) AS is_equipment_line_outfeed,
    locf(max(a.ideal_production_speed), treat_null_as_missing => true) AS ideal_production_speed
   FROM v_agg_equipment_values_1min_layer a
  WHERE a.ts_value >= date_trunc('day'::text, now() - '70 days'::interval) AND a.ts_value < now() AND a.id_area IS NOT NULL
  GROUP BY (time_bucket_gapfill('00:01:00'::interval, a.ts_value, date_trunc('day'::text, now() - '70 days'::interval), now())), a.id_equipment, a.id_area, a.id_site, a.id_enterprise, a.tp_equipment
  ORDER BY a.id_equipment, (time_bucket_gapfill('00:01:00'::interval, a.ts_value, date_trunc('day'::text, now() - '70 days'::interval), now())) DESC;
;
-- ===OBJ=== mv_agg_equipment_values_1month_full_hot kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1month_full_hot AS
 SELECT date_trunc('month'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date AS ts_value,
    v_agg_equipment_values_1day_full.id_equipment,
    v_agg_equipment_values_1day_full.id_area,
    v_agg_equipment_values_1day_full.id_site,
    v_agg_equipment_values_1day_full.id_enterprise,
    v_agg_equipment_values_1day_full.tp_equipment,
    COALESCE(sum(v_agg_equipment_values_1day_full.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.scrap_incr), 0::double precision) AS scrap_incr,
    v_agg_equipment_values_1day_full.mode,
    v_agg_equipment_values_1day_full.id_production_order,
    v_agg_equipment_values_1day_full.conversion_factor,
    v_agg_equipment_values_1day_full.number_cavities,
    locf(max(v_agg_equipment_values_1day_full.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(v_agg_equipment_values_1day_full.speed) FILTER (WHERE v_agg_equipment_values_1day_full.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(v_agg_equipment_values_1day_full.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(v_agg_equipment_values_1day_full.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(v_agg_equipment_values_1day_full.scrap_val), treat_null_as_missing => true) AS scrap_val,
    v_agg_equipment_values_1day_full.id_shift,
    v_agg_equipment_values_1day_full.id_team,
    v_agg_equipment_values_1day_full.id_shift_hour,
    v_agg_equipment_values_1day_full.id_equipment_line_connected,
    v_agg_equipment_values_1day_full.position_in_equipment_line,
    v_agg_equipment_values_1day_full.is_equipment_line_infeed,
    v_agg_equipment_values_1day_full.is_equipment_line_outfeed,
    v_agg_equipment_values_1day_full.ideal_production_speed
   FROM v_agg_equipment_values_1day_full
  GROUP BY (date_trunc('month'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date), v_agg_equipment_values_1day_full.id_equipment, v_agg_equipment_values_1day_full.id_area, v_agg_equipment_values_1day_full.id_site, v_agg_equipment_values_1day_full.id_enterprise, v_agg_equipment_values_1day_full.tp_equipment, v_agg_equipment_values_1day_full.mode, v_agg_equipment_values_1day_full.id_production_order, v_agg_equipment_values_1day_full.conversion_factor, v_agg_equipment_values_1day_full.number_cavities, v_agg_equipment_values_1day_full.id_shift, v_agg_equipment_values_1day_full.id_team, v_agg_equipment_values_1day_full.id_shift_hour, v_agg_equipment_values_1day_full.id_equipment_line_connected, v_agg_equipment_values_1day_full.position_in_equipment_line, v_agg_equipment_values_1day_full.is_equipment_line_infeed, v_agg_equipment_values_1day_full.is_equipment_line_outfeed, v_agg_equipment_values_1day_full.ideal_production_speed
  ORDER BY v_agg_equipment_values_1day_full.id_equipment, (date_trunc('month'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date) DESC;
;
-- ===OBJ=== mv_agg_equipment_values_1month_full_warm kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1month_full_warm AS
 SELECT date_trunc('month'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date AS ts_value,
    v_agg_equipment_values_1day_full.id_equipment,
    v_agg_equipment_values_1day_full.id_area,
    v_agg_equipment_values_1day_full.id_site,
    v_agg_equipment_values_1day_full.id_enterprise,
    v_agg_equipment_values_1day_full.tp_equipment,
    COALESCE(sum(v_agg_equipment_values_1day_full.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.scrap_incr), 0::double precision) AS scrap_incr,
    v_agg_equipment_values_1day_full.mode,
    v_agg_equipment_values_1day_full.id_production_order,
    v_agg_equipment_values_1day_full.conversion_factor,
    v_agg_equipment_values_1day_full.number_cavities,
    locf(max(v_agg_equipment_values_1day_full.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(v_agg_equipment_values_1day_full.speed) FILTER (WHERE v_agg_equipment_values_1day_full.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(v_agg_equipment_values_1day_full.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(v_agg_equipment_values_1day_full.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(v_agg_equipment_values_1day_full.scrap_val), treat_null_as_missing => true) AS scrap_val,
    v_agg_equipment_values_1day_full.id_shift,
    v_agg_equipment_values_1day_full.id_team,
    v_agg_equipment_values_1day_full.id_shift_hour,
    v_agg_equipment_values_1day_full.id_equipment_line_connected,
    v_agg_equipment_values_1day_full.position_in_equipment_line,
    v_agg_equipment_values_1day_full.is_equipment_line_infeed,
    v_agg_equipment_values_1day_full.is_equipment_line_outfeed,
    v_agg_equipment_values_1day_full.ideal_production_speed
   FROM v_agg_equipment_values_1day_full
  GROUP BY (date_trunc('month'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date), v_agg_equipment_values_1day_full.id_equipment, v_agg_equipment_values_1day_full.id_area, v_agg_equipment_values_1day_full.id_sit--output truncated--
    v_agg_equipment_values_1day_full.is_equipment_line_outfeed,
    v_agg_equipment_values_1day_full.ideal_production_speed
   FROM v_agg_equipment_values_1day_full
  GROUP BY (date_trunc('week'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date), v_agg_equipment_values_1day_full.id_equipment, v_agg_equipment_values_1day_full.id_area, v_agg_equipment_values_1day_full.id_site, v_agg_equipment_values_1day_full.id_enterprise, v_agg_equipment_values_1day_full.tp_equipment, v_agg_equipment_values_1day_full.mode, v_agg_equipment_values_1day_full.id_production_order, v_agg_equipment_values_1day_full.conversion_factor, v_agg_equipment_values_1day_full.number_cavities, v_agg_equipment_values_1day_full.id_shift, v_agg_equipment_values_1day_full.id_team, v_agg_equipment_values_1day_full.id_shift_hour, v_agg_equipment_values_1day_full.id_equipment_line_connected, v_agg_equipment_values_1day_full.position_in_equipment_line, v_agg_equipment_values_1day_full.is_equipment_line_infeed, v_agg_equipment_values_1day_full.is_equipment_line_outfeed, v_agg_equipment_values_1day_full.ideal_production_speed
  ORDER BY v_agg_equipment_values_1day_full.id_equipment, (date_trunc('week'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date) DESC;
;
-- ===OBJ=== mv_agg_equipment_values_1week_full_warm kind=m
CREATE MATERIALIZED VIEW public.mv_agg_equipment_values_1week_full_warm AS
 SELECT date_trunc('week'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date AS ts_value,
    v_agg_equipment_values_1day_full.id_equipment,
    v_agg_equipment_values_1day_full.id_area,
    v_agg_equipment_values_1day_full.id_site,
    v_agg_equipment_values_1day_full.id_enterprise,
    v_agg_equipment_values_1day_full.tp_equipment,
    COALESCE(sum(v_agg_equipment_values_1day_full.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.scrap_incr), 0::double precision) AS scrap_incr,
    v_agg_equipment_values_1day_full.mode,
    v_agg_equipment_values_1day_full.id_production_order,
    v_agg_equipment_values_1day_full.conversion_factor,
    v_agg_equipment_values_1day_full.number_cavities,
    locf(max(v_agg_equipment_values_1day_full.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(v_agg_equipment_values_1day_full.speed) FILTER (WHERE v_agg_equipment_values_1day_full.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(v_agg_equipment_values_1day_full.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(v_agg_equipment_values_1day_full.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(v_agg_equipment_values_1day_full.scrap_val), treat_null_as_missing => true) AS scrap_val,
    v_agg_equipment_values_1day_full.id_shift,
    v_agg_equipment_values_1day_full.id_team,
    v_agg_equipment_values_1day_full.id_shift_hour,
    v_agg_equipment_values_1day_full.id_equipment_line_connected,
    v_agg_equipment_values_1day_full.position_in_equipment_line,
    v_agg_equipment_values_1day_full.is_equipment_line_infeed,
    v_agg_equipment_values_1day_full.is_equipment_line_outfeed,
    v_agg_equipment_values_1day_full.ideal_production_speed
   FROM v_agg_equipment_values_1day_full
  GROUP BY (date_trunc('week'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date), v_agg_equipment_values_1day_full.id_equipment, v_agg_equipment_values_1day_full.id_area, v_agg_equipment_values_1day_full.id_site, v_agg_equipment_values_1day_full.id_enterprise, v_agg_equipment_values_1day_full.tp_equipment, v_agg_equipment_values_1day_full.mode, v_agg_equipment_values_1day_full.id_production_order, v_agg_equipment_values_1day_full.conversion_factor, v_agg_equipment_values_1day_full.number_cavities, v_agg_equipment_values_1day_full.id_shift, v_agg_equipment_values_1day_full.id_team, v_agg_equipment_values_1day_full.id_shift_hour, v_agg_equipment_values_1day_full.id_equipment_line_connected, v_agg_equipment_values_1day_full.position_in_equipment_line, v_agg_equipment_values_1day_full.is_equipment_line_infeed, v_agg_equipment_values_1day_full.is_equipment_line_outfeed, v_agg_equipment_values_1day_full.ideal_production_speed
  ORDER BY v_agg_equipment_values_1day_full.id_equipment, (date_trunc('week'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date) DESC;
;
-- ===OBJ=== v_agg_equipment_prod_1min_full kind=v
CREATE VIEW public.v_agg_equipment_prod_1min_full AS
 SELECT time_bucket_gapfill('00:01:00'::interval, a.ts_value, now() - '2 days'::interval, now()) AS ts_value,
    a.id_equipment,
    a.id_area,
    a.id_site,
    a.id_enterprise,
    a.tp_equipment,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr
   FROM v_agg_equipment_values_1min_layer a
  WHERE a.ts_value >= (now() - '2 days'::interval) AND a.id_area IS NOT NULL
  GROUP BY (time_bucket_gapfill('00:01:00'::interval, a.ts_value, now() - '2 days'::interval, now())), a.id_equipment, a.id_area, a.id_site, a.id_enterprise, a.tp_equipment;
;
-- ===OBJ=== v_agg_equipment_values_1day_full kind=v
CREATE VIEW public.v_agg_equipment_values_1day_full AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_equipment,
    s2.id_area,
    s2.id_site,
    s2.id_enterprise,
    s2.tp_equipment,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.mode,
    s2.id_production_order,
    s2.conversion_factor,
    s2.number_cavities,
    s2.signal_quality,
    s2.speed,
    s2.net_production_val,
    s2.gross_production_val,
    s2.scrap_val,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour,
    s2.id_equipment_line_connected,
    s2.position_in_equipment_line,
    s2.is_equipment_line_infeed,
    s2.is_equipment_line_outfeed,
    s2.ideal_production_speed
   FROM ( SELECT v_agg_equipment_values_1hour_full.ts_value_production AS ts_value,
            v_agg_equipment_values_1hour_full.id_equipment,
            v_agg_equipment_values_1hour_full.id_area,
            v_agg_equipment_values_1hour_full.id_site,
            v_agg_equipment_values_1hour_full.id_enterprise,
            v_agg_equipment_values_1hour_full.tp_equipment,
            COALESCE(sum(v_agg_equipment_values_1hour_full.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour_full.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour_full.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_equipment_values_1hour_full.mode,
            v_agg_equipment_values_1hour_full.id_production_order,
            v_agg_equipment_values_1hour_full.conversion_factor,
            v_agg_equipment_values_1hour_full.number_cavities,
            locf(max(v_agg_equipment_values_1hour_full.signal_quality), treat_null_as_missing => true) AS signal_quality,
            COALESCE(avg(v_agg_equipment_values_1hour_full.speed) FILTER (WHERE v_agg_equipment_values_1hour_full.speed > 0::double precision), 0::double precision) AS speed,
            locf(max(v_agg_equipment_values_1hour_full.net_production_val), treat_null_as_missing => true) AS net_production_val,
            locf(max(v_agg_equipment_values_1hour_full.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
            locf(max(v_agg_equipment_values_1hour_full.scrap_val), treat_null_as_missing => true) AS scrap_val,
            v_agg_equipment_values_1hour_full.id_shift,
            v_agg_equipment_values_1hour_full.id_team,
            v_agg_equipment_values_1hour_full.id_shift_hour,
            v_agg_equipment_values_1hour_full.id_equipment_line_connected,
            v_agg_equipment_values_1hour_full.position_in_equipment_line,
            v_agg_equipment_values_1hour_full.is_equipment_line_infeed,
            v_agg_equipment_values_1hour_full.is_equipment_line_outfeed,
            v_agg_equipment_values_1hour_full.ideal_production_speed
           FROM v_agg_equipment_values_1hour_full
          WHERE v_agg_equipment_values_1hour_full.ts_value >= date_trunc('day'::text, now() - '60 days'::interval)
          GROUP BY v_agg_equipment_values_1hour_full.ts_value_production, v_agg_equipment_values_1hour_full.id_equipment, v_agg_equipment_values_1hour_full.id_area, v_agg_equipment_values_1hour_full.id_site, v_agg_equipment_values_1hour_full.id_enterprise, v_agg_equipment_values_1hour_full.tp_equipment, v_agg_equipment_values_1hour_full.mode, v_agg_equipment_values_1hour_full.id_production_order, v_agg_equipment_values_1hour_full.conversion_factor, v_agg_equipment_values_1hour_full.number_cavities, v_agg_equipment_values_1hour_full.id_shift, v_agg_equipment_values_1hour_full.id_team, v_agg_equipment_values_1hour_full.id_shift_hour, v_agg_equipment_values_1hour_full.id_equipment_line_connected, v_agg_equipment_values_1hour_full.position_in_equipment_line, v_agg_equipment_values_1hour_full.is_equipment_line_infeed, v_agg_equipment_values_1hour_full.is_equipment_line_outfeed, v_agg_equipment_values_1hour_full.ideal_production_speed
          ORDER BY v_agg_equipment_values_1hour_full.id_equipment, v_agg_equipment_values_1hour_full.ts_value_production) s2
UNION ALL
 SELECT agg_equipment_values_1day_archive.ts_value,
    agg_equipment_values_1day_archive.id_equipment,
    agg_equipment_values_1day_archive.id_area,
    agg_equipment_values_1day_archive.id_site,
    agg_equipment_values_1day_archive.id_enterprise,
    agg_equipment_values_1day_archive.tp_equipment,
    agg_equipment_values_1day_archive.net_production_incr,
    agg_equipment_values_1day_archive.gross_production_incr,
    agg_equipment_values_1day_archive.scrap_incr,
    agg_equipment_values_1day_archive.mode,
    agg_equipment_values_1day_archive.id_production_order,
    agg_equipment_values_1day_archive.conversion_factor,
    agg_equipment_values_1day_archive.number_cavities,
    agg_equipment_values_1day_archive.signal_quality,
    agg_equipment_values_1day_archive.speed,
    agg_equipment_values_1day_archive.net_production_val,
    agg_equipment_values_1day_archive.gross_production_val,
    agg_equipment_values_1day_archive.scrap_val,
    agg_equipment_values_1day_archive.id_shift,
    agg_equipment_values_1day_archive.id_team,
    agg_equipment_values_1day_archive.id_shift_hour,
    agg_equipment_values_1day_archive.id_equipment_line_connected,
    agg_equipment_values_1day_archive.position_in_equipment_line,
    agg_equipment_values_1day_archive.is_equipment_line_infeed,
    agg_equipment_values_1day_archive.is_equipment_line_outfeed,
    agg_equipment_values_1day_archive.ideal_production_speed
   FROM agg_equipment_values_1day_archive
  WHERE agg_equipment_values_1day_archive.ts_value >= '2021-01-01'::date AND agg_equipment_values_1day_archive.ts_value < date_trunc('day'::text, now() - '60 days'::interval)
  ORDER BY 2, 1 DESC;
;
-- ===OBJ=== v_agg_equipment_values_1day_full_20d kind=v
CREATE VIEW public.v_agg_equipment_values_1day_full_20d AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_equipment,
    s2.id_area,
    s2.id_site,
    s2.id_enterprise,
    s2.tp_equipment,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.mode,
    s2.id_production_order,
    s2.conversion_factor,
    s2.number_cavities,
    s2.signal_quality,
    s2.speed,
    s2.net_production_val,
    s2.gross_production_val,
    s2.scrap_val,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour,
    s2.id_equipment_line_connected,
    s2.position_in_equipment_line,
    s2.is_equipment_line_infeed,
    s2.is_equipment_line_outfeed,
    s2.ideal_production_speed
   FROM ( SELECT v_agg_equipment_values_1hour_full_20d.ts_value_production AS ts_value,
            v_agg_equipment_values_1hour_full_20d.id_equipment,
            v_agg_equipment_values_1hour_full_20d.id_area,
            v_agg_equipment_values_1hour_full_20d.id_site,
            v_agg_equipment_values_1hour_full_20d.id_enterprise,
            v_agg_equipment_values_1hour_full_20d.tp_equipment,
            COALESCE(sum(v_agg_equipment_values_1hour_full_20d.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour_full_20d.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour_full_20d.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_equipment_values_1hour_full_20d.mode,
            v_agg_equipment_values_1hour_full_20d.id_production_order,
            v_agg_equipment_values_1hour_full_20d.conversion_factor,
            v_agg_equipment_values_1hour_full_20d.number_cavities,
            locf(max(v_agg_equipment_values_1hour_full_20d.signal_quality), treat_null_as_missing => true) AS signal_quality,
            COALESCE(avg(v_agg_equipment_values_1hour_full_20d.speed) FILTER (WHERE v_agg_equipment_values_1hour_full_20d.speed > 0::double precision), 0::double precision) AS speed,
            locf(max(v_agg_equipment_values_1hour_full_20d.net_production_val), treat_null_as_missing => true) AS net_production_val,
            locf(max(v_agg_equipment_values_1hour_full_20d.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
            locf(max(v_agg_equipment_values_1hour_full_20d.scrap_val), treat_null_as_missing => true) AS scrap_val,
            v_agg_equipment_values_1hour_full_20d.id_shift,
            v_agg_equipment_values_1hour_full_20d.id_team,
            v_agg_equipment_values_1hour_full_20d.id_shift_hour,
            v_agg_equipment_values_1hour_full_20d.id_equipment_line_connected,
            v_agg_equipment_values_1hour_full_20d.position_in_equipment_line,
            v_agg_equipment_values_1hour_full_20d.is_equipment_line_infeed,
            v_agg_equipment_values_1hour_full_20d.is_equipment_line_outfeed,
            v_agg_equipment_values_1hour_full_20d.ideal_production_speed
           FROM v_agg_equipment_values_1hour_full_20d
          WHERE v_agg_equipment_values_1hour_full_20d.ts_value >= date_trunc('day'::text, now() - '20 days'::interval)
          GROUP BY v_agg_equipment_values_1hour_full_20d.ts_value_production, v_agg_equipment_values_1hour_full_20d.id_equipment, v_agg_equipment_values_1hour_full_20d.id_area, v_agg_equipment_values_1hour_full_20d.id_site, v_agg_equipment_values_1hour_full_20d.id_enterprise, v_agg_equipment_values_1hour_full_20d.tp_equipment, v_agg_equipment_values_1hour_full_20d.mode, v_agg_equipment_values_1hour_full_20d.id_production_order, v_agg_equipment_values_1hour_full_20d.conversion_factor, v_agg_equipment_values_1hour_full_20d.number_cavities, v_agg_equipment_values_1hour_full_20d.id_shift, v_agg_equipment_values_1hour_full_20d.id_team, v_agg_equipment_values_1hour_full_20d.id_shift_hour, v_agg_equipment_values_1hour_full_20d.id_equipment_line_connected, v_agg_equipment_values_1hour_full_20d.position_in_equipment_line, v_agg_equipment_values_1hour_full_20d.is_equipment_line_infeed, v_agg_equipment_values_1hour_full_20d.is_equipment_line_outfeed, v_agg_equipment_values_1hour_full_20d.ideal_production_speed
          ORDER BY v_agg_equipment_values_1hour_full_20d.id_equipment, v_agg_equipment_values_1hour_full_20d.ts_value_production) s2
  ORDER BY s2.id_equipment, (timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date) DESC;
;
-- ===OBJ=== v_agg_equipment_values_1hour_full kind=v
CREATE VIEW public.v_agg_equipment_values_1hour_full AS
 SELECT date_trunc('hour'::text, a.ts_value) AS ts_value,
    a.id_equipment,
    a.id_area,
    a.id_site,
    a.id_enterprise,
    a.tp_equipment,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.ts_value_production,
    a.mode,
    a.id_production_order,
    a.conversion_factor,
    a.number_cavities,
    locf(max(a.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(a.speed) FILTER (WHERE a.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(a.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(a.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(a.scrap_val), treat_null_as_missing => true) AS scrap_val,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.id_equipment_line_connected,
    a.position_in_equipment_line,
    a.is_equipment_line_infeed,
    a.is_equipment_line_outfeed,
    a.ideal_production_speed
   FROM ( SELECT time_bucket_gapfill('00:01:00'::interval, a_1.ts_value, date_trunc('day'::text, now() - '60 days'::interval), now()) AS ts_value,
            a_1.id_equipment,
            a_1.id_area,
            a_1.id_site,
            a_1.id_enterprise,
            a_1.tp_equipment,
            COALESCE(sum(a_1.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(a_1.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(a_1.scrap_incr), 0::double precision) AS scrap_incr,
            locf(max(a_1.ts_value_production), treat_null_as_missing => true) AS ts_value_production,
            locf(max(a_1.state), treat_null_as_missing => true) AS state,
            locf(max(a_1.mode), treat_null_as_missing => true) AS mode,
            locf(max(a_1.id_production_order), treat_null_as_missing => true) AS id_production_order,
            locf(max(a_1.conversion_factor), treat_null_as_missing => true) AS conversion_factor,
            locf(max(a_1.number_cavities), treat_null_as_missing => true) AS number_cavities,
            locf(max(a_1.signal_quality), treat_null_as_missing => true) AS signal_quality,
            COALESCE(avg(a_1.speed) FILTER (WHERE a_1.speed > 0::double precision), 0::double precision) AS speed,
            locf(max(a_1.net_production_val), treat_null_as_missing => true) AS net_production_val,
            locf(max(a_1.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
            locf(max(a_1.scrap_val), treat_null_as_missing => true) AS scrap_val,
            locf(max(a_1.id_shift), treat_null_as_missing => true) AS id_shift,
            locf(max(a_1.id_team), treat_null_as_missing => true) AS id_team,
            locf(max(a_1.id_shift_hour), treat_null_as_missing => true) AS id_shift_hour,
            locf(max(a_1.box_code::text), treat_null_as_missing => true) AS box_code,
            locf(max(a_1.transaction_code::text), treat_null_as_missing => true) AS transaction_code,
            locf(max(a_1.id_equipment_line_connected), treat_null_as_missing => true) AS id_equipment_line_connected,
            locf(max(a_1.position_in_equipment_line), treat_null_as_missing => true) AS position_in_equipment_line,
            locf(max(a_1.is_equipment_line_infeed), treat_null_as_missing => true) AS is_equipment_line_infeed,
            locf(max(a_1.is_equipment_line_outfeed), treat_null_as_missing => true) AS is_equipment_line_outfeed,
            locf(max(a_1.ideal_production_speed), treat_null_as_missing => true) AS ideal_production_speed
           FROM v_agg_equipment_values_1min_layer a_1
          WHERE a_1.ts_value >= date_trunc('day'::text, now() - '60 days'::interval)
          GROUP BY (time_bucket_gapfill('00:01:00'::interval, a_1.ts_value, date_trunc('day'::text, now() - '60 days'::interval), now())), a_1.id_equipment, a_1.id_area, a_1.id_site, a_1.id_enterprise, a_1.tp_equipment) a
  WHERE a.ts_value >= date_trunc('day'::text, now() - '60 days'::interval) AND a.ts_value_production IS NOT NULL
  GROUP BY (date_trunc('hour'::text, a.ts_value)), a.id_equipment, a.id_area, a.id_site, a.id_enterprise, a.tp_equipment, a.ts_value_production, a.mode, a.id_production_order, a.conversion_factor, a.number_cavities, a.id_shift, a.id_team, a.id_shift_hour, a.id_equipment_line_connected, a.position_in_equipment_line, a.is_equipment_line_infeed, a.is_equipment_line_outfeed, a.ideal_production_speed
UNION ALL
 SELECT agg_equipment_values_1hour_archive.ts_value,
    agg_equipment_values_1hour_archive.id_equipment,
    agg_equipment_values_1hour_archive.id_area,
    agg_equipment_values_1hour_archive.id_site,
    agg_equipment_values_1hour_archive.id_enterprise,
    agg_equipment_values_1hour_archive.tp_equipment,
    agg_equipment_values_1hour_archive.net_production_incr,
    agg_equipment_values_1hour_archive.gross_production_incr,
    agg_equipment_values_1hour_archive.scrap_incr,
    agg_equipment_values_1hour_archive.ts_value_production,
    agg_equipment_values_1hour_archive.mode,
    agg_equipment_values_1hour_archive.id_production_order,
    agg_equipment_values_1hour_archive.conversion_factor,
    agg_equipment_values_1hour_archive.number_cavities,
    agg_equipment_values_1hour_archive.signal_quality,
    agg_equipment_values_1hour_archive.speed,
    agg_equipment_values_1hour_archive.net_production_val,
    agg_equipment_values_1hour_archive.gross_production_val,
    agg_equipment_values_1hour_archive.scrap_val,
    agg_equipment_values_1hour_archive.id_shift,
    agg_equipment_values_1hour_archive.id_team,
    agg_equipment_values_1hour_archive.id_shift_hour,
    agg_equipment_values_1hour_archive.id_equipment_line_connected,
    agg_equipment_values_1hour_archive.position_in_equipment_line,
    agg_equipment_values_1hour_archive.is_equipment_line_infeed,
    agg_equipment_values_1hour_archive.is_equipment_line_outfeed,
    agg_equipment_values_1hour_archive.ideal_production_speed
   FROM agg_equipment_values_1hour_archive
  WHERE agg_equipment_values_1hour_archive.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND agg_equipment_values_1hour_archive.ts_value < date_trunc('day'::text, now() - '60 days'::interval)
  ORDER BY 2, 1 DESC;
;
-- ===OBJ=== v_agg_equipment_values_1hour_full2 kind=v
CREATE VIEW public.v_agg_equipment_values_1hour_full2 AS
 SELECT date_trunc('hour'::text, a.ts_value) AS ts_value,
    a.id_equipment,
    a.id_area,
    a.id_site,
    a.id_enterprise,
    a.tp_equipment,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.ts_value_production,
    a.mode,
    a.id_production_order,
    a.conversion_factor,
    a.number_cavities,
    locf(max(a.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(a.speed) FILTER (WHERE a.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(a.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(a.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(a.scrap_val), treat_null_as_missing => true) AS scrap_val,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.id_equipment_line_connected,
    a.position_in_equipment_line,
    a.is_equipment_line_infeed,
    a.is_equipment_line_outfeed,
    a.ideal_production_speed
   FROM ( SELECT time_bucket_gapfill('00:01:00'::interval, a_1.ts_value, date_trunc('day'::text, now() - '60 days'::interval), now()) AS ts_value,
            a_1.id_equipment,
            a_1.id_area,
            a_1.id_site,
  --output truncated--
            locf(max(a_1.transaction_code::text), treat_null_as_missing => true) AS transaction_code,
            locf(max(a_1.id_equipment_line_connected), treat_null_as_missing => true) AS id_equipment_line_connected,
            locf(max(a_1.position_in_equipment_line), treat_null_as_missing => true) AS position_in_equipment_line,
            locf(max(a_1.is_equipment_line_infeed), treat_null_as_missing => true) AS is_equipment_line_infeed,
            locf(max(a_1.is_equipment_line_outfeed), treat_null_as_missing => true) AS is_equipment_line_outfeed,
            locf(max(a_1.ideal_production_speed), treat_null_as_missing => true) AS ideal_production_speed
           FROM v_agg_equipment_values_1min_layer a_1
          WHERE a_1.ts_value >= date_trunc('day'::text, now() - '60 days'::interval)
          GROUP BY (time_bucket_gapfill('00:01:00'::interval, a_1.ts_value, date_trunc('day'::text, now() - '60 days'::interval), now())), a_1.id_equipment, a_1.id_area, a_1.id_site, a_1.id_enterprise, a_1.tp_equipment) a
  WHERE a.ts_value >= date_trunc('day'::text, now() - '60 days'::interval) AND a.ts_value_production IS NOT NULL
  GROUP BY (date_trunc('hour'::text, a.ts_value)), a.id_equipment, a.id_area, a.id_site, a.id_enterprise, a.tp_equipment, a.ts_value_production, a.mode, a.id_production_order, a.conversion_factor, a.number_cavities, a.id_shift, a.id_team, a.id_shift_hour, a.id_equipment_line_connected, a.position_in_equipment_line, a.is_equipment_line_infeed, a.is_equipment_line_outfeed, a.ideal_production_speed
UNION ALL
 SELECT agg_equipment_values_1hour_archive.ts_value,
    agg_equipment_values_1hour_archive.id_equipment,
    agg_equipment_values_1hour_archive.id_area,
    agg_equipment_values_1hour_archive.id_site,
    agg_equipment_values_1hour_archive.id_enterprise,
    agg_equipment_values_1hour_archive.tp_equipment,
    agg_equipment_values_1hour_archive.net_production_incr,
    agg_equipment_values_1hour_archive.gross_production_incr,
    agg_equipment_values_1hour_archive.scrap_incr,
    agg_equipment_values_1hour_archive.ts_value_production,
    agg_equipment_values_1hour_archive.mode,
    agg_equipment_values_1hour_archive.id_production_order,
    agg_equipment_values_1hour_archive.conversion_factor,
    agg_equipment_values_1hour_archive.number_cavities,
    agg_equipment_values_1hour_archive.signal_quality,
    agg_equipment_values_1hour_archive.speed,
    agg_equipment_values_1hour_archive.net_production_val,
    agg_equipment_values_1hour_archive.gross_production_val,
    agg_equipment_values_1hour_archive.scrap_val,
    agg_equipment_values_1hour_archive.id_shift,
    agg_equipment_values_1hour_archive.id_team,
    agg_equipment_values_1hour_archive.id_shift_hour,
    agg_equipment_values_1hour_archive.id_equipment_line_connected,
    agg_equipment_values_1hour_archive.position_in_equipment_line,
    agg_equipment_values_1hour_archive.is_equipment_line_infeed,
    agg_equipment_values_1hour_archive.is_equipment_line_outfeed,
    agg_equipment_values_1hour_archive.ideal_production_speed
   FROM agg_equipment_values_1hour_archive
  WHERE agg_equipment_values_1hour_archive.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND agg_equipment_values_1hour_archive.ts_value < date_trunc('day'::text, now() - '60 days'::interval)
  ORDER BY 2, 1 DESC;
;
-- ===OBJ=== v_agg_equipment_values_1hour_full_20d kind=v
CREATE VIEW public.v_agg_equipment_values_1hour_full_20d AS
 SELECT date_trunc('hour'::text, a.ts_value) AS ts_value,
    a.id_equipment,
    a.id_area,
    a.id_site,
    a.id_enterprise,
    a.tp_equipment,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.ts_value_production,
    a.mode,
    a.id_production_order,
    a.conversion_factor,
    a.number_cavities,
    locf(max(a.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(a.speed) FILTER (WHERE a.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(a.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(a.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(a.scrap_val), treat_null_as_missing => true) AS scrap_val,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.id_equipment_line_connected,
    a.position_in_equipment_line,
    a.is_equipment_line_infeed,
    a.is_equipment_line_outfeed,
    a.ideal_production_speed
   FROM ( SELECT time_bucket_gapfill('00:01:00'::interval, a_1.ts_value, date_trunc('day'::text, now() - '20 days'::interval), now()) AS ts_value,
            a_1.id_equipment,
            a_1.id_area,
            a_1.id_site,
            a_1.id_enterprise,
            a_1.tp_equipment,
            COALESCE(sum(a_1.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(a_1.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(a_1.scrap_incr), 0::double precision) AS scrap_incr,
            locf(max(a_1.ts_value_production), treat_null_as_missing => true) AS ts_value_production,
            locf(max(a_1.state), treat_null_as_missing => true) AS state,
            locf(max(a_1.mode), treat_null_as_missing => true) AS mode,
            locf(max(a_1.id_production_order), treat_null_as_missing => true) AS id_production_order,
            locf(max(a_1.conversion_factor), treat_null_as_missing => true) AS conversion_factor,
            locf(max(a_1.number_cavities), treat_null_as_missing => true) AS number_cavities,
            locf(max(a_1.signal_quality), treat_null_as_missing => true) AS signal_quality,
            COALESCE(avg(a_1.speed) FILTER (WHERE a_1.speed > 0::double precision), 0::double precision) AS speed,
            locf(max(a_1.net_production_val), treat_null_as_missing => true) AS net_production_val,
            locf(max(a_1.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
            locf(max(a_1.scrap_val), treat_null_as_missing => true) AS scrap_val,
            locf(max(a_1.id_shift), treat_null_as_missing => true) AS id_shift,
            locf(max(a_1.id_team), treat_null_as_missing => true) AS id_team,
            locf(max(a_1.id_shift_hour), treat_null_as_missing => true) AS id_shift_hour,
            locf(max(a_1.box_code::text), treat_null_as_missing => true) AS box_code,
            locf(max(a_1.transaction_code::text), treat_null_as_missing => true) AS transaction_code,
            locf(max(a_1.id_equipment_line_connected), treat_null_as_missing => true) AS id_equipment_line_connected,
            locf(max(a_1.position_in_equipment_line), treat_null_as_missing => true) AS position_in_equipment_line,
            locf(max(a_1.is_equipment_line_infeed), treat_null_as_missing => true) AS is_equipment_line_infeed,
            locf(max(a_1.is_equipment_line_outfeed), treat_null_as_missing => true) AS is_equipment_line_outfeed,
            locf(max(a_1.ideal_production_speed), treat_null_as_missing => true) AS ideal_production_speed
           FROM v_agg_equipment_values_1min_layer a_1
          WHERE a_1.ts_value >= date_trunc('day'::text, now() - '20 days'::interval)
          GROUP BY (time_bucket_gapfill('00:01:00'::interval, a_1.ts_value, date_trunc('day'::text, now() - '20 days'::interval), now())), a_1.id_equipment, a_1.id_area, a_1.id_site, a_1.id_enterprise, a_1.tp_equipment) a
  WHERE a.ts_value >= date_trunc('day'::text, now() - '20 days'::interval) AND a.ts_value_production IS NOT NULL
  GROUP BY (date_trunc('hour'::text, a.ts_value)), a.id_equipment, a.id_area, a.id_site, a.id_enterprise, a.tp_equipment, a.ts_value_production, a.mode, a.id_production_order, a.conversion_factor, a.number_cavities, a.id_shift, a.id_team, a.id_shift_hour, a.id_equipment_line_connected, a.position_in_equipment_line, a.is_equipment_line_infeed, a.is_equipment_line_outfeed, a.ideal_production_speed
  ORDER BY a.id_equipment, (date_trunc('hour'::text, a.ts_value)) DESC;
;
-- ===OBJ=== v_agg_equipment_values_1min_layer kind=v
CREATE VIEW public.v_agg_equipment_values_1min_layer AS
 SELECT agg_equipment_values_1min.ts_value,
    agg_equipment_values_1min.id_enterprise,
    agg_equipment_values_1min.id_site,
    agg_equipment_values_1min.id_area,
    agg_equipment_values_1min.id_equipment,
    agg_equipment_values_1min.tp_equipment,
    agg_equipment_values_1min.net_production_incr,
    agg_equipment_values_1min.gross_production_incr,
    agg_equipment_values_1min.scrap_incr,
    agg_equipment_values_1min.state,
    agg_equipment_values_1min.mode,
    agg_equipment_values_1min.speed,
    agg_equipment_values_1min.id_order,
    agg_equipment_values_1min.conversion_factor,
    agg_equipment_values_1min.number_cavities,
    agg_equipment_values_1min.signal_quality,
    agg_equipment_values_1min.net_production_val,
    agg_equipment_values_1min.gross_production_val,
    agg_equipment_values_1min.scrap_val,
    agg_equipment_values_1min.id_shift,
    agg_equipment_values_1min.id_team,
    agg_equipment_values_1min.id_shift_hour,
    agg_equipment_values_1min.box_code,
    agg_equipment_values_1min.transaction_code,
    agg_equipment_values_1min.id_production_order,
    agg_equipment_values_1min.ts_value_production,
    agg_equipment_values_1min.id_equipment_line_connected,
    agg_equipment_values_1min.position_in_equipment_line,
    agg_equipment_values_1min.is_equipment_line_infeed,
    agg_equipment_values_1min.is_equipment_line_outfeed,
    agg_equipment_values_1min.ideal_production_speed
   FROM agg_equipment_values_1min;
;
-- ===OBJ=== v_agg_equipment_values_1month_full kind=v
CREATE VIEW public.v_agg_equipment_values_1month_full AS
 SELECT date_trunc('month'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date AS ts_value,
    v_agg_equipment_values_1day_full.id_equipment,
    v_agg_equipment_values_1day_full.id_area,
    v_agg_equipment_values_1day_full.id_site,
    v_agg_equipment_values_1day_full.id_enterprise,
    v_agg_equipment_values_1day_full.tp_equipment,
    COALESCE(sum(v_agg_equipment_values_1day_full.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.scrap_incr), 0::double precision) AS scrap_incr,
    v_agg_equipment_values_1day_full.mode,
    v_agg_equipment_values_1day_full.id_production_order,
    v_agg_equipment_values_1day_full.conversion_factor,
    v_agg_equipment_values_1day_full.number_cavities,
    locf(max(v_agg_equipment_values_1day_full.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(v_agg_equipment_values_1day_full.speed) FILTER (WHERE v_agg_equipment_values_1day_full.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(v_agg_equipment_values_1day_full.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(v_agg_equipment_values_1day_full.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(v_agg_equipment_values_1day_full.scrap_val), treat_null_as_missing => true) AS scrap_val,
    v_agg_equipment_values_1day_full.id_shift,
    v_agg_equipment_values_1day_full.id_team,
    v_agg_equipment_values_1day_full.id_shift_hour,
    v_agg_equipment_values_1day_full.id_equipment_line_connected,
    v_agg_equipment_values_1day_full.position_in_equipment_line,
    v_agg_equipment_values_1day_full.is_equipment_line_infeed,
    v_agg_equipment_values_1day_full.is_equipment_line_outfeed,
    v_agg_equipment_values_1day_full.ideal_production_speed
   FROM v_agg_equipment_values_1day_full
  WHERE v_agg_equipment_values_1day_full.ts_value >= date_trunc('day'::text, now() - '60 days'::interval)
  GROUP BY (date_trunc('month'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date), v_agg_equipment_values_1day_full.id_equipment, v_agg_equipment_values_1day_full.id_area, v_agg_equipment_values_1day_full.id_site, v_agg_equipment_values_1day_full.id_enterprise, v_agg_equipment_values_1day_full.tp_equipment, v_agg_equipment_values_1day_full.mode, v_agg_equipment_values_1day_full.id_production_order, v_agg_equipment_values_1day_full.conversion_factor, v_agg_equipment_values_1day_full.number_cavities, v_agg_equipment_values_1day_full.id_shift, v_agg_equipment_values_1day_full.id_team, v_agg_equipment_values_1day_full.id_shift_hour, v_agg_equipment_values_1day_full.id_equipment_line_connected, v_agg_equipment_values_1day_full.position_in_equipment_line, v_agg_equipment_values_1day_full.is_equipment_line_infeed, v_agg_equipment_values_1day_full.is_equipment_line_outfeed, v_agg_equipment_values_1day_full.ideal_production_speed
UNION ALL
 SELECT agg_equipment_values_1month_archive.ts_value,
    agg_equipment_values_1month_archive.id_equipment,
    agg_equipment_values_1month_archive.id_area,
    agg_equipment_values_1month_archive.id_site,
    agg_equipment_values_1month_archive.id_enterprise,
    agg_equipment_values_1month_archive.tp_equipment,
    agg_equipment_values_1month_archive.net_production_incr,
    agg_equipment_values_1month_archive.gross_production_incr,
    agg_equipment_values_1month_archive.scrap_incr,
    agg_equipment_values_1month_archive.mode,
    agg_equipment_values_1month_archive.id_production_order,
    agg_equipment_values_1month_archive.conversion_factor,
    agg_equipment_values_1month_archive.number_cavities,
    agg_equipment_values_1month_archive.signal_quality,
    agg_equipment_values_1month_archive.speed,
    agg_equipment_values_1month_archive.net_production_val,
    agg_equipment_values_1month_archive.gross_production_val,
    agg_equipment_values_1month_archive.scrap_val,
    agg_equipment_values_1month_archive.id_shift,
    agg_equipment_values_1month_archive.id_team,
    agg_equipment_values_1month_archive.id_shift_hour,
    agg_equipment_values_1month_archive.id_equipment_line_connected,
    agg_equipment_values_1month_archive.position_in_equipment_line,
    agg_equipment_values_1month_archive.is_equipment_line_infeed,
    agg_equipment_values_1month_archive.is_equipment_line_outfeed,
    agg_equipment_values_1month_archive.ideal_production_speed
   FROM agg_equipment_values_1month_archive
  WHERE agg_equipment_values_1month_archive.ts_value >= '2021-01-01'::date AND agg_equipment_values_1month_archive.ts_value < date_trunc('day'::text, now() - '60 days'::interval)
  ORDER BY 2, 1 DESC;
;
-- ===OBJ=== v_agg_equipment_values_1week_full kind=v
CREATE VIEW public.v_agg_equipment_values_1week_full AS
 SELECT date_trunc('week'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date AS ts_value,
    v_agg_equipment_values_1day_full.id_equipment,
    v_agg_equipment_values_1day_full.id_area,
    v_agg_equipment_values_1day_full.id_site,
    v_agg_equipment_values_1day_full.id_enterprise,
    v_agg_equipment_values_1day_full.tp_equipment,
    COALESCE(sum(v_agg_equipment_values_1day_full.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(v_agg_equipment_values_1day_full.scrap_incr), 0::double precision) AS scrap_incr,
    v_agg_equipment_values_1day_full.mode,
    v_agg_equipment_values_1day_full.id_production_order,
    v_agg_equipment_values_1day_full.conversion_factor,
    v_agg_equipment_values_1day_full.number_cavities,
    locf(max(v_agg_equipment_values_1day_full.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(v_agg_equipment_values_1day_full.speed) FILTER (WHERE v_agg_equipment_values_1day_full.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(v_agg_equipment_values_1day_full.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(v_agg_equipment_values_1day_full.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(v_agg_equipment_values_1day_full.scrap_val), treat_null_as_missing => true) AS scrap_val,
    v_agg_equipment_values_1day_full.id_shift,
    v_agg_equipment_values_1day_full.id_team,
    v_agg_equipment_values_1day_full.id_shift_hour,
    v_agg_equipment_values_1day_full.id_equipment_line_connected,
    v_agg_equipment_values_1day_full.position_in_equipment_line,
    v_agg_equipment_values_1day_full.is_equipment_line_infeed,
    v_agg_equipment_values_1day_full.is_equipment_line_outfeed,
    v_agg_equipment_values_1day_full.ideal_production_speed
   FROM v_agg_equipment_values_1day_full
  WHERE v_agg_equipment_values_1day_full.ts_value >= date_trunc('day'::text, now() - '60 days'::interval)
  GROUP BY (date_trunc('week'::text, timezone('UTC'::text, v_agg_equipment_values_1day_full.ts_value::timestamp with time zone))::date), v_agg_equipment_values_1day_full.id_equipment, v_agg_equipment_values_1day_full.id_area, v_agg_equipment_values_1day_full.id_site, v_agg_equipment_values_1day_full.id_enterprise, v_agg_equipment_values_1day_full.tp_equipment, v_agg_equipment_values_1day_full.mode, v_agg_equipment_values_1day_full.id_production_order, v_agg_equipment_values_1day_full.conversion_factor, v_agg_equipment_values_1day_full.number_cavities, v_agg_equipment_values_1day_full.id_shift, v_agg_equipment_values_1day_full.id_team, v_agg_equipment_values_1day_full.id_shift_hour, v_agg_equipment_values_1day_full.id_equipment_line_connected, v_agg_equipment_values_1day_full.position_in_equipment_line, v_agg_equipment_values_1day_full.is_equipment_line_infeed, v_agg_equipment_values_1day_full.is_equipment_line_outfeed, v_agg_equipment_values_1day_full.ideal_production_speed
UNION ALL
 SELECT agg_equipment_values_1week_archive.ts_value,
    agg_equipment_values_1week_archive.id_equipment,
    agg_equipment_values_1week_archive.id_area,
    agg_equipment_values_1week_archive.id_site,
    agg_equipment_values_1week_archive.id_enterprise,
    agg_equipment_values_1week_archive.tp_equipment,
    agg_equipment_values_1week_archive.net_production_incr,
    agg_equipment_values_1week_archive.gross_production_incr,
    agg_equipment_values_1week_archive.scrap_incr,
    agg_equipment_values_1week_archive.mode,
    agg_equipment_values_1week_archive.id_production_order,
    agg_equipment_values_1week_archive.conversion_factor,
    agg_equipment_values_1week_archive.number_cavities,
    agg_equipment_values_1week_archive.signal_quality,
    agg_equipment_values_1week_archive.speed,
    agg_equipment_values_1week_archive.net_production_val,
    agg_equipment_values_1week_archive.gross_production_val,
    agg_equipment_values_1week_archive.scrap_val,
    agg_equipment_values_1week_archive.id_shift,
    agg_equipment_values_1week_archive.id_team,
    agg_equipment_values_1week_archive.id_shift_hour,
    agg_equipment_values_1week_archive.id_equipment_line_connected,
    agg_equipment_values_1week_archive.position_in_equipment_line,
    agg_equipment_values_1week_archive.is_equipment_line_infeed,
    agg_equipment_values_1week_archive.is_equipment_line_outfeed,
    agg_equipment_values_1week_archive.ideal_production_speed
   FROM agg_equipment_values_1week_archive
  WHERE agg_equipment_values_1week_archive.ts_value >= '2021-01-01'::date AND agg_equipment_values_1week_archive.ts_value < date_trunc('day'::text, now() - '60 days'::interval)
  ORDER BY 2, 1 DESC;
;



-- ===OBJ=== shift_agg_from_events
CREATE VIEW public.shift_agg_from_events AS
 SELECT dats.id_equipment,
    dats.id_area,
    dats.id_site,
    dats.id_shift,
    dats.id_shift_hour,
    dats.ts_value_production,
    lower(dats.sh_range) AS ts_value,
    dats.sh_range AS ts_range,
    date_part('epoch'::text, upper(dats.sh_range) - lower(dats.sh_range)) AS duration,
    dats.changeover_time,
    dats.planned_downtime,
    dats.running_time,
    dats.available_time,
    dats.net,
    dats.gross,
    dats.ideal_production,
    dats.net / NULLIF(dats.gross, 0::double precision) AS oee_q,
    dats.running_time / NULLIF(dats.available_time, 0)::double precision AS oee_a,
    dats.net / NULLIF(dats.ideal_production, 0)::double precision / NULLIF(dats.net / NULLIF(dats.gross, 0::double precision) * (dats.running_time / NULLIF(dats.available_time, 0)::double precision), 0::double precision) AS oee_p,
    dats.net / NULLIF(dats.ideal_production, 0)::double precision AS oee
   FROM ( SELECT ag.id_equipment,
            ag.id_area,
            e.id_site,
            ag.id_shift,
            ag.id_shift_hour,
            ag.ts_value_production,
            ag.sh_range,
                CASE
                    WHEN ag.max_ts > now() THEN date_part('epoch'::text, now() - ag.min_ts)
                    ELSE ag.available_time::double precision
                END::bigint AS available_time,
            ag.net,
            ag.gross,
            (
                CASE
                    WHEN ag.max_ts > now() THEN date_part('epoch'::text, now() - ag.min_ts)
                    ELSE ag.available_time::double precision
                END / 60.0::double precision * e.production_speed::double precision)::bigint AS ideal_production,
            COALESCE(sum(GREATEST(0::double precision,
                CASE
                    WHEN ee.ts_end > upper(ag.sh_range) OR ee.ts_event < lower(ag.sh_range) THEN date_part('epoch'::text, LEAST(COALESCE(ee.ts_end, now()), upper(ag.sh_range)) - GREATEST(ee.ts_event, lower(ag.sh_range)))
                    ELSE ee.duration::double precision
                END)) FILTER (WHERE ee.status = 6), 0::double precision) AS running_time,
            COALESCE(sum(GREATEST(0::double precision,
                CASE
                    WHEN ee.ts_end > upper(ag.sh_range) THEN date_part('epoch'::text, LEAST(COALESCE(ee.ts_end, now()), upper(ag.sh_range)) - GREATEST(ee.ts_event, lower(ag.sh_range)))
                    ELSE ee.duration::double precision
                END)) FILTER (WHERE ee.status <> 6 AND ee.planned_downtime = true), 0::double precision) AS planned_downtime,
            COALESCE(sum(GREATEST(0::double precision,
                CASE
                    WHEN ee.ts_end > upper(ag.sh_range) THEN date_part('epoch'::text, LEAST(COALESCE(ee.ts_end, now()), upper(ag.sh_range)) - GREATEST(ee.ts_event, lower(ag.sh_range)))
                    ELSE ee.duration::double precision
                END)) FILTER (WHERE ee.status <> 6 AND ee.change_over = true), 0::double precision) AS changeover_time
           FROM equipment_events ee
             JOIN equipments e USING (id_equipment)
             RIGHT JOIN ( SELECT ad.id_equipment,
                    ad.id_area,
                    ad.id_shift,
                    ad.id_shift_hour,
                    ad.ts_value_production,
                    min(ad.ts_value) AS min_ts,
                    min(ad.ts_value) + max(sh.shift_size)::double precision * '00:00:01'::interval AS max_ts,
                    tstzrange(min(ad.ts_value), min(ad.ts_value) + max(sh.shift_size)::double precision * '00:00:01'::interval, '[)'::text) AS sh_range,
                    sum(ad.net_production_incr) AS net,
                    sum(ad.gross_production_incr) AS gross,
                    max(sh.shift_size) AS available_time
                   FROM v_agg_equipment_values_1hour ad
                     JOIN shift_hours sh ON sh.id_shift_hour = ad.id_shift_hour
                  GROUP BY ad.id_equipment, ad.id_area, ad.id_shift, ad.id_shift_hour, ad.ts_value_production) ag ON ee.id_equipment = ag.id_equipment AND e.id_area = ag.id_area AND ee.ts_event <@ ag.sh_range
          GROUP BY ag.id_equipment, ag.id_area, e.id_site, ag.id_shift, ag.id_shift_hour, ag.sh_range, ag.max_ts, ag.min_ts, ag.available_time, ag.net, ag.gross, ag.ts_value_production, e.production_speed) dats;
;
-- ===OBJ=== shift_agg_from_events_v3
CREATE VIEW public.shift_agg_from_events_v3 AS
 SELECT dats.id_equipment,
    dats.id_area,
    dats.id_site,
    dats.id_shift,
    dats.id_shift_hour,
    dats.ts_value_production,
    dats.ts_value::timestamp with time zone AS ts_value,
    dats.sh_range AS ts_range,
    date_part('epoch'::text, upper(dats.sh_range) - lower(dats.sh_range)) AS duration,
    dats.changeover_time,
    dats.planned_downtime,
    dats.running_time,
    dats.available_time,
    dats.net,
    dats.gross,
    dats.ideal_production,
    dats.net / NULLIF(dats.gross, 0::double precision) AS oee_q,
    dats.running_time / NULLIF(dats.available_time, 0)::double precision AS oee_a,
    dats.net / NULLIF(dats.ideal_production, 0)::double precision / NULLIF(dats.net / NULLIF(dats.gross, 0::double precision) * (dats.running_time / NULLIF(dats.available_time, 0)::double precision), 0::double precision) AS oee_p,
    dats.net / NULLIF(dats.ideal_production, 0)::double precision AS oee
   FROM ( SELECT ag.id_equipment,
            ag.id_area,
            ag.id_site,
            ag.id_shift,
            ag.id_shift_hour,
            ag.ts_value_production,
            ag.min_ts AS ts_value,
            ag.sh_range,
            date_part('epoch'::text, LEAST(now(), ag.max_ts) - ag.min_ts)::bigint AS available_time,
            ag.net,
            ag.gross,
            (
                CASE
                    WHEN ag.max_ts > now() THEN date_part('epoch'::text, now() - ag.min_ts)
                    ELSE ag.available_time::double precision
                END / 60.0::double precision * e.production_speed::double precision)::bigint AS ideal_production,
            COALESCE(sum(GREATEST(0::double precision,
                CASE
                    WHEN ee.ts_end > upper(ag.sh_range) OR ee.ts_event < lower(ag.sh_range) THEN date_part('epoch'::text, LEAST(COALESCE(ee.ts_end, now()), upper(ag.sh_range)) - GREATEST(ee.ts_event, lower(ag.sh_range)))
                    ELSE ee.duration::double precision
                END)) FILTER (WHERE ee.status = 6), 0::double precision) AS running_time,
            COALESCE(sum(GREATEST(0::double precision,
                CASE
                    WHEN ee.ts_end > upper(ag.sh_range) THEN date_part('epoch'::text, LEAST(COALESCE(ee.ts_end, now()), upper(ag.sh_range)) - GREATEST(ee.ts_event, lower(ag.sh_range)))
                    ELSE ee.duration::double precision
                END)) FILTER (WHERE ee.status <> 6 AND ee.planned_downtime = true), 0::double precision) AS planned_downtime,
            COALESCE(sum(GREATEST(0::double precision,
                CASE
                    WHEN ee.ts_end > upper(ag.sh_range) THEN date_part('epoch'::text, LEAST(COALESCE(ee.ts_end, now()), upper(ag.sh_range)) - GREATEST(ee.ts_event, lower(ag.sh_range)))
                    ELSE ee.duration::double precision
                END)) FILTER (WHERE ee.status <> 6 AND ee.change_over = true), 0::double precision) AS changeover_time
           FROM equipment_events ee
             JOIN equipments e USING (id_equipment)
             RIGHT JOIN ( SELECT ad.id_equipment,
                    ad.id_area,
                    ad.id_site,
                    ad.id_shift,
                    ad.id_shift_hour,
                    ad.ts_value_production,
                    ers.ts_value AS min_ts,
                    COALESCE(upper(ers.ts_range), ers.ts_value + max(sh.shift_size)::double precision * '00:00:01'::interval) AS max_ts,
                    ers.ts_range AS sh_range,
                    sum(ad.net_production_incr) AS net,
                    sum(ad.gross_production_incr) AS gross,
                    max(sh.shift_size) AS available_time
                   FROM ca_agg_equipment_values_1hour ad
                     JOIN shift_hours sh ON sh.id_shift_hour = ad.id_shift_hour
                     RIGHT JOIN equipment_runtime_shift ers ON ers.id_shift_hour = sh.id_shift_hour AND ers.id_equipment = ad.id_equipment AND ers.ts_range @> ad.ts_value
                  WHERE ers.ts_value <= now()
                  GROUP BY ad.id_equipment, ad.id_area, ad.id_site, ad.id_shift, ad.id_shift_hour, ad.ts_value_production, ers.ts_range, ers.ts_value) ag ON ee.id_equipment = ag.id_equipment AND e.id_equipment = ee.id_equipment AND e.id_area = ag.id_area AND e.id_site = ag.id_site AND ee.ts_event <@ ag.sh_range AND (ag.id_equipment = ANY (ARRAY[1, 42, 90]))
          GROUP BY ag.id_equipment, ag.id_area, ag.id_site, ag.id_shift, ag.id_shift_hour, ag.sh_range, ag.max_ts, ag.min_ts, ag.available_time, ag.net, ag.gross, ag.ts_value_production, e.production_speed) dats;
;
-- ===OBJ=== v_agg_area_values_10min
CREATE VIEW public.v_agg_area_values_10min AS
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS ts_value_production
   FROM agg_area_values_10min aevh
  WHERE aevh.ts_value >= (now() - '60 days'::interval)
UNION ALL
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS ts_value_production
   FROM agg_area_values_10min_past aevh
  WHERE aevh.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND aevh.ts_value < (now() - '60 days'::interval)
  ORDER BY 4, 1;
;
-- ===OBJ=== v_agg_area_values_10min_full
CREATE VIEW public.v_agg_area_values_10min_full AS
 SELECT time_bucket('00:10:00'::interval, a.ts_value) AS ts_value,
    a.id_enterprise,
    a.id_site,
    a.id_area,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.ts_value_production
   FROM v_agg_area_values_1min_full a
  GROUP BY (time_bucket('00:10:00'::interval, a.ts_value)), a.id_enterprise, a.id_site, a.id_area, a.id_shift, a.id_team, a.id_shift_hour, a.ts_value_production
  ORDER BY a.id_area, (time_bucket('00:10:00'::interval, a.ts_value)) DESC;
;
-- ===OBJ=== v_agg_area_values_1day
CREATE VIEW public.v_agg_area_values_1day AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.id_area,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT v_agg_area_values_1hour.ts_value_production AS ts_value,
            v_agg_area_values_1hour.id_enterprise,
            v_agg_area_values_1hour.id_site,
            v_agg_area_values_1hour.id_area,
            COALESCE(sum(v_agg_area_values_1hour.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_area_values_1hour.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_area_values_1hour.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_area_values_1hour.id_shift,
            v_agg_area_values_1hour.id_team,
            v_agg_area_values_1hour.id_shift_hour
           FROM v_agg_area_values_1hour
          WHERE v_agg_area_values_1hour.ts_value_production IS NOT NULL
          GROUP BY v_agg_area_values_1hour.ts_value_production, v_agg_area_values_1hour.id_enterprise, v_agg_area_values_1hour.id_site, v_agg_area_values_1hour.id_area, v_agg_area_values_1hour.id_shift, v_agg_area_values_1hour.id_team, v_agg_area_values_1hour.id_shift_hour
          ORDER BY v_agg_area_values_1hour.id_area, v_agg_area_values_1hour.ts_value_production DESC) s2;
;
-- ===OBJ=== v_agg_area_values_1day_full
CREATE VIEW public.v_agg_area_values_1day_full AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.id_area,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT v_agg_area_values_1hour_full.ts_value_production AS ts_value,
            v_agg_area_values_1hour_full.id_enterprise,
            v_agg_area_values_1hour_full.id_site,
            v_agg_area_values_1hour_full.id_area,
            COALESCE(sum(v_agg_area_values_1hour_full.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_area_values_1hour_full.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_area_values_1hour_full.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_area_values_1hour_full.id_shift,
            v_agg_area_values_1hour_full.id_team,
            v_agg_area_values_1hour_full.id_shift_hour
           FROM v_agg_area_values_1hour_full
          WHERE v_agg_area_values_1hour_full.ts_value_production IS NOT NULL
          GROUP BY v_agg_area_values_1hour_full.ts_value_production, v_agg_area_values_1hour_full.id_enterprise, v_agg_area_values_1hour_full.id_site, v_agg_area_values_1hour_full.id_area, v_agg_area_values_1hour_full.id_shift, v_agg_area_values_1hour_full.id_team, v_agg_area_values_1hour_full.id_shift_hour
          ORDER BY v_agg_area_values_1hour_full.id_area, v_agg_area_values_1hour_full.ts_value_production DESC) s2;
;
-- ===OBJ=== v_agg_area_values_1hour
CREATE VIEW public.v_agg_area_values_1hour AS
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS ts_value_production
   FROM agg_area_values_1hour aevh
  WHERE aevh.ts_value >= (now() - '60 days'::interval)
UNION ALL
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_area, aevh.ts_value) AS ts_value_production
   FROM agg_area_values_1hour_past aevh
  WHERE aevh.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND aevh.ts_value < (now() - '60 days'::interval)
  ORDER BY 4, 1;
;
-- ===OBJ=== v_agg_area_values_1hour_full
CREATE VIEW public.v_agg_area_values_1hour_full AS
 SELECT date_trunc('hour'::text, a.ts_value) AS ts_value,
    a.id_enterprise,
    a.id_site,
    a.id_area,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.ts_value_production
   FROM v_agg_area_values_1min_full a
  WHERE a.ts_value >= (now() - '60 days'::interval) AND a.ts_value_production IS NOT NULL
  GROUP BY (date_trunc('hour'::text, a.ts_value)), a.id_enterprise, a.id_site, a.id_area, a.id_shift, a.id_team, a.id_shift_hour, a.ts_value_production
  ORDER BY a.id_area, (date_trunc('hour'::text, a.ts_value)) DESC;
;
-- ===OBJ=== v_agg_area_values_1min_full
CREATE VIEW public.v_agg_area_values_1min_full AS
 SELECT time_bucket_gapfill('00:01:00'::interval, a.ts_value, now() - '60 days'::interval, now()) AS ts_value,
    a.id_enterprise,
    a.id_site,
    a.id_area,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    locf(max(a.id_shift), treat_null_as_missing => true) AS id_shift,
    locf(max(a.id_team), treat_null_as_missing => true) AS id_team,
    locf(max(a.id_shift_hour), treat_null_as_missing => true) AS id_shift_hour,
    locf(last(a.ts_value_production, a.ts_value), treat_null_as_missing => true) AS ts_value_production
   FROM agg_area_values_1min a
  WHERE a.ts_value >= (now() - '60 days'::interval) AND a.id_area IS NOT NULL
  GROUP BY (time_bucket_gapfill('00:01:00'::interval, a.ts_value, now() - '60 days'::interval, now())), a.id_enterprise, a.id_site, a.id_area
UNION ALL
 SELECT time_bucket_gapfill('00:01:00'::interval, a.ts_value, '2021-01-01 03:00:00+00'::timestamp with time zone, now() - '60 days'::interval) AS ts_value,
    a.id_enterprise,
    a.id_site,
    a.id_area,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    locf(max(a.id_shift), treat_null_as_missing => true) AS id_shift,
    locf(max(a.id_team), treat_null_as_missing => true) AS id_team,
    locf(max(a.id_shift_hour), treat_null_as_missing => true) AS id_shift_hour,
    locf(max(a.ts_value_production), treat_null_as_missing => true) AS ts_value_production
   FROM agg_area_values_1min_past a
  WHERE a.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND a.ts_value < (now() - '60 days'::interval) AND a.id_area IS NOT NULL
  GROUP BY (time_bucket_gapfill('00:01:00'::interval, a.ts_value, '2021-01-01 03:00:00+00'::timestamp with time zone, now() - '60 days'::interval)), a.id_enterprise, a.id_site, a.id_area
  ORDER BY 4, 1 DESC;
;
-- ===OBJ=== v_agg_area_values_1month
CREATE VIEW public.v_agg_area_values_1month AS
 SELECT timezone('UTC'::text, s2.ts_value)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.id_area,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT date_trunc('month'::text, v_agg_area_values_1hour.ts_value_production::timestamp with time zone) AS ts_value,
            v_agg_area_values_1hour.id_enterprise,
            v_agg_area_values_1hour.id_site,
            v_agg_area_values_1hour.id_area,
            COALESCE(sum(v_agg_area_values_1hour.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_area_values_1hour.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_area_values_1hour.scrap_incr), 0::double precision) AS scrap_incr,


            v_agg_area_values_1hour.id_shift,
            v_agg_area_values_1hour.id_team,
            v_agg_area_values_1hour.id_shift_hour
           FROM v_agg_area_values_1hour
          WHERE v_agg_area_values_1hour.ts_value_production IS NOT NULL
          GROUP BY (date_trunc('month'::text, v_agg_area_values_1hour.ts_value_production::timestamp with time zone)), v_agg_area_values_1hour.id_enterprise, v_agg_area_values_1hour.id_site, v_agg_area_values_1hour.id_area, v_agg_area_values_1hour.id_shift, v_agg_area_values_1hour.id_team, v_agg_area_values_1hour.id_shift_hour
          ORDER BY v_agg_area_values_1hour.id_area, (date_trunc('month'::text, v_agg_area_values_1hour.ts_value_production::timestamp with time zone)) DESC) s2;
;
-- ===OBJ=== v_agg_area_values_1month_full
CREATE VIEW public.v_agg_area_values_1month_full AS
 SELECT timezone('UTC'::text, s2.ts_value)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.id_area,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT date_trunc('month'::text, v_agg_area_values_1hour_full.ts_value_production::timestamp with time zone) AS ts_value,
            v_agg_area_values_1hour_full.id_enterprise,
            v_agg_area_values_1hour_full.id_site,
            v_agg_area_values_1hour_full.id_area,
            COALESCE(sum(v_agg_area_values_1hour_full.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_area_values_1hour_full.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_area_values_1hour_full.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_area_values_1hour_full.id_shift,
            v_agg_area_values_1hour_full.id_team,
            v_agg_area_values_1hour_full.id_shift_hour
           FROM v_agg_area_values_1hour_full
          WHERE v_agg_area_values_1hour_full.ts_value_production IS NOT NULL
          GROUP BY (date_trunc('month'::text, v_agg_area_values_1hour_full.ts_value_production::timestamp with time zone)), v_agg_area_values_1hour_full.id_enterprise, v_agg_area_values_1hour_full.id_site, v_agg_area_values_1hour_full.id_area, v_agg_area_values_1hour_full.id_shift, v_agg_area_values_1hour_full.id_team, v_agg_area_values_1hour_full.id_shift_hour
          ORDER BY v_agg_area_values_1hour_full.id_area, (date_trunc('month'::text, v_agg_area_values_1hour_full.ts_value_production::timestamp with time zone)) DESC) s2;
;
-- ===OBJ=== v_agg_area_values_1week
CREATE VIEW public.v_agg_area_values_1week AS
 SELECT timezone('UTC'::text, s2.ts_value)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.id_area,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT date_trunc('week'::text, v_agg_area_values_1hour.ts_value_production::timestamp with time zone) AS ts_value,
            v_agg_area_values_1hour.id_enterprise,
            v_agg_area_values_1hour.id_site,
            v_agg_area_values_1hour.id_area,
            COALESCE(sum(v_agg_area_values_1hour.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_area_values_1hour.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_area_values_1hour.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_area_values_1hour.id_shift,
            v_agg_area_values_1hour.id_team,
            v_agg_area_values_1hour.id_shift_hour
           FROM v_agg_area_values_1hour
          WHERE v_agg_area_values_1hour.ts_value_production IS NOT NULL
          GROUP BY (date_trunc('week'::text, v_agg_area_values_1hour.ts_value_production::timestamp with time zone)), v_agg_area_values_1hour.id_enterprise, v_agg_area_values_1hour.id_site, v_agg_area_values_1hour.id_area, v_agg_area_values_1hour.id_shift, v_agg_area_values_1hour.id_team, v_agg_area_values_1hour.id_shift_hour
          ORDER BY v_agg_area_values_1hour.id_area, (date_trunc('week'::text, v_agg_area_values_1hour.ts_value_production::timestamp with time zone)) DESC) s2;
;
-- ===OBJ=== v_agg_area_values_1week_full
CREATE VIEW public.v_agg_area_values_1week_full AS
 SELECT timezone('UTC'::text, s2.ts_value)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.id_area,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT date_trunc('week'::text, v_agg_area_values_1hour_full.ts_value_production::timestamp with time zone) AS ts_value,
            v_agg_area_values_1hour_full.id_enterprise,
            v_agg_area_values_1hour_full.id_site,
            v_agg_area_values_1hour_full.id_area,
            COALESCE(sum(v_agg_area_values_1hour_full.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_area_values_1hour_full.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_area_values_1hour_full.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_area_values_1hour_full.id_shift,
            v_agg_area_values_1hour_full.id_team,
            v_agg_area_values_1hour_full.id_shift_hour
           FROM v_agg_area_values_1hour_full
          WHERE v_agg_area_values_1hour_full.ts_value_production IS NOT NULL
          GROUP BY (date_trunc('week'::text, v_agg_area_values_1hour_full.ts_value_production::timestamp with time zone)), v_agg_area_values_1hour_full.id_enterprise, v_agg_area_values_1hour_full.id_site, v_agg_area_values_1hour_full.id_area, v_agg_area_values_1hour_full.id_shift, v_agg_area_values_1hour_full.id_team, v_agg_area_values_1hour_full.id_shift_hour
          ORDER BY v_agg_area_values_1hour_full.id_area, (date_trunc('week'::text, v_agg_area_values_1hour_full.ts_value_production::timestamp with time zone)) DESC) s2;
;
-- ===OBJ=== v_agg_equipment_values_10min
CREATE VIEW public.v_agg_equipment_values_10min AS
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.id_equipment,
    aevh.tp_equipment,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.mode) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS mode,
    gapfill(aevh.speed) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS speed,
    gapfill(aevh.id_production_order) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_production_order,
    gapfill(aevh.conversion_factor) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS conversion_factor,
    gapfill(aevh.number_cavities) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS number_cavities,
    gapfill(aevh.signal_quality) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS signal_quality,
    gapfill(aevh.net_production_val) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS net_production_val,
    gapfill(aevh.gross_production_val) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS gross_production_val,
    gapfill(aevh.scrap_val) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS scrap_val,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.box_code) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS box_code,
    gapfill(aevh.transaction_code) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS transaction_code,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS ts_value_production,
    gapfill(aevh.id_equipment_line_connected) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_equipment_line_connected,
    gapfill(aevh.position_in_equipment_line) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS position_in_equipment_line,
    gapfill(aevh.is_equipment_line_infeed) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS is_equipment_line_infeed,
    gapfill(aevh.is_equipment_line_outfeed) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS is_equipment_line_outfeed
   FROM agg_equipment_values_10min aevh
  WHERE aevh.ts_value >= (now() - '60 days'::interval)
UNION ALL
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.id_equipment,
    aevh.tp_equipment,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.mode) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS mode,
    gapfill(aevh.speed) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS speed,
    gapfill(aevh.id_production_order) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_production_order,
    gapfill(aevh.conversion_factor) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS conversion_factor,
    gapfill(aevh.number_cavities) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS number_cavities,
    gapfill(aevh.signal_quality) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS signal_quality,
    gapfill(aevh.net_production_val) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS net_production_val,
    gapfill(aevh.gross_production_val) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS gross_production_val,
    gapfill(aevh.scrap_val) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS scrap_val,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.box_code) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS box_code,
    gapfill(aevh.transaction_code) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS transaction_code,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS ts_value_production,
    gapfill(aevh.id_equipment_line_connected) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS id_equipment_line_connected,
    gapfill(aevh.position_in_equipment_line) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS position_in_equipment_line,
    gapfill(aevh.is_equipment_line_infeed) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS is_equipment_line_infeed,
    gapfill(aevh.is_equipment_line_outfeed) OVER (ORDER BY aevh.id_equipment, aevh.ts_value) AS is_equipment_line_outfeed
   FROM agg_equipment_values_10min_past aevh
  WHERE aevh.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND aevh.ts_value < (now() - '60 days'::interval)
  ORDER BY 5, 1;
;
-- ===OBJ=== v_agg_equipment_values_1day
CREATE VIEW public.v_agg_equipment_values_1day AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_equipment,
    s2.id_area,
    s2.id_site,
    s2.id_enterprise,
    s2.tp_equipment,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.mode,
    s2.id_production_order,
    s2.conversion_factor,
    s2.number_cavities,
    s2.signal_quality,
    s2.speed,
    s2.net_production_val,
    s2.gross_production_val,
    s2.scrap_val,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour,
    s2.id_equipment_line_connected,
    s2.position_in_equipment_line,
    s2.is_equipment_line_infeed,
    s2.is_equipment_line_outfeed
   FROM ( SELECT v_agg_equipment_values_1hour.ts_value_production AS ts_value,
            v_agg_equipment_values_1hour.id_equipment,
            v_agg_equipment_values_1hour.id_area,
            v_agg_equipment_values_1hour.id_site,
            v_agg_equipment_values_1hour.id_enterprise,
            v_agg_equipment_values_1hour.tp_equipment,
            COALESCE(sum(v_agg_equipment_values_1hour.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_equipment_values_1hour.mode,
            v_agg_equipment_values_1hour.id_production_order,
            v_agg_equipment_values_1hour.conversion_factor,
            v_agg_equipment_values_1hour.number_cavities,
            locf(max(v_agg_equipment_values_1hour.signal_quality), treat_null_as_missing => true) AS signal_quality,
            COALESCE(avg(v_agg_equipment_values_1hour.speed) FILTER (WHERE v_agg_equipment_values_1hour.speed > 0::double precision), 0::double precision) AS speed,
            locf(max(v_agg_equipment_values_1hour.net_production_val), treat_null_as_missing => true) AS net_production_val,
            locf(max(v_agg_equipment_values_1hour.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
            locf(max(v_agg_equipment_values_1hour.scrap_val), treat_null_as_missing => true) AS scrap_val,
            v_agg_equipment_values_1hour.id_shift,
            v_agg_equipment_values_1hour.id_team,
            v_agg_equipment_values_1hour.id_shift_hour,
            v_agg_equipment_values_1hour.id_equipment_line_connected,
            v_agg_equipment_values_1hour.position_in_equipment_line,
            v_agg_equipment_values_1hour.is_equipment_line_infeed,
            v_agg_equipment_values_1hour.is_equipment_line_outfeed
           FROM v_agg_equipment_values_1hour
          WHERE v_agg_equipment_values_1hour.ts_value_production IS NOT NULL
          GROUP BY v_agg_equipment_values_1hour.ts_value_production, v_agg_equipment_values_1hour.id_equipment, v_agg_equipment_values_1hour.id_area, v_agg_equipment_values_1hour.id_site, v_agg_equipment_values_1hour.id_enterprise, v_agg_equipment_values_1hour.tp_equipment, v_agg_equipment_values_1hour.mode, v_agg_equipment_values_1hour.id_production_order, v_agg_equipment_values_1hour.conversion_factor, v_agg_equipment_values_1hour.number_cavities, v_agg_equipment_values_1hour.id_shift, v_agg_equipment_values_1hour.id_team, v_agg_equipment_values_1hour.id_shift_hour, v_agg_equipment_values_1hour.id_equipment_line_connected, v_agg_equipment_values_1hour.position_in_equipment_line, v_agg_equipment_values_1hour.is_equipment_line_infeed, v_agg_equipment_values_1hour.is_equipment_line_outfeed
          ORDER BY v_agg_equipment_values_1hour.id_equipment, v_agg_equipment_values_1hour.ts_value_production DESC) s2;
;
-- ===OBJ=== v_agg_equipment_values_1hour
CREATE VIEW public.v_agg_equipment_values_1hour AS
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.id_equipment,
    aevh.tp_equipment,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.mode) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS mode,
    gapfill(aevh.speed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS speed,
    gapfill(aevh.id_production_order) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_production_order,
    gapfill(aevh.conversion_factor) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS conversion_factor,
    gapfill(aevh.number_cavities) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS number_cavities,
    gapfill(aevh.signal_quality) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS signal_quality,
    gapfill(aevh.net_production_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS net_production_val,
    gapfill(aevh.gross_production_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS gross_production_val,
    gapfill(aevh.scrap_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS scrap_val,
    gapfill(aevh.id_shift) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.box_code) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS box_code,
    gapfill(aevh.transaction_code) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS transaction_code,
    gapfill(aevh.ts_value_production) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS ts_value_production,
    gapfill(aevh.id_equipment_line_connected) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_equipment_line_connected,
    gapfill(aevh.position_in_equipment_line) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS position_in_equipment_line,
    gapfill(aevh.is_equipment_line_infeed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS is_equipment_line_infeed,
    gapfill(aevh.is_equipment_line_outfeed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS is_equipment_line_outfeed
   FROM agg_equipment_values_1hour aevh
  WHERE aevh.ts_value >= (now() - '60 days'::interval)
UNION ALL
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.id_equipment,
    aevh.tp_equipment,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.mode) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS mode,
    gapfill(aevh.speed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS speed,
    gapfill(aevh.id_production_order) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_production_order,
    gapfill(aevh.conversion_factor) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS conversion_factor,
    gapfill(aevh.number_cavities) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS number_cavities,
    gapfill(aevh.signal_quality) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS signal_quality,
    gapfill(aevh.net_production_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS net_production_val,
    gapfill(aevh.gross_production_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS gross_production_val,
    gapfill(aevh.scrap_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS scrap_val,
    gapfill(aevh.id_shift) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.box_code) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS box_code,
    gapfill(aevh.transaction_code) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS transaction_code,
    gapfill(aevh.ts_value_production) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS ts_value_production,
    gapfill(aevh.id_equipment_line_connected) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_equipment_line_connected,
    gapfill(aevh.position_in_equipment_line) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS position_in_equipment_line,
    gapfill(aevh.is_equipment_line_infeed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS is_equipment_line_infeed,
    gapfill(aevh.is_equipment_line_outfeed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS is_equipment_line_outfeed
   FROM agg_equipment_values_1hour_past aevh
  WHERE aevh.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND aevh.ts_value < (now() - '60 days'::interval)
  ORDER BY 5, 1;
;
-- ===OBJ=== v_agg_equipment_values_1hour2
CREATE VIEW public.v_agg_equipment_values_1hour2 AS
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.id_area,
    aevh.id_equipment,
    aevh.tp_equipment,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.mode) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS mode,
    gapfill(aevh.speed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS speed,
    gapfill(aevh.id_production_order) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_production_order,
    gapfill(aevh.conversion_factor) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS conversion_factor,
    gapfill(aevh.number_cavities) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS number_cavities,
    gapfill(aevh.signal_quality) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS signal_quality,
    gapfill(aevh.net_production_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS net_production_val,
    gapfill(aevh.gross_production_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS gross_production_val,
    gapfill(aevh.scrap_val) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS scrap_val,
    gapfill(aevh.id_shift) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.box_code) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS box_code,
    gapfill(aevh.transaction_code) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS transaction_code,
    gapfill(aevh.ts_value_production) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS ts_value_production,
    gapfill(aevh.id_equipment_line_connected) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS id_equipment_line_connected,
    gapfill(aevh.position_in_equipment_line) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS position_in_equipment_line,
    gapfill(aevh.is_equipment_line_infeed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS is_equipment_line_infeed,
    gapfill(aevh.is_equipment_line_outfeed) OVER (PARTITION BY aevh.id_equipment ORDER BY aevh.ts_value) AS is_equipment_line_outfeed
   FROM agg_equipment_values_1hour aevh
  WHERE aevh.ts_value >= (now() - '10 days'::interval)
  ORDER BY aevh.id_equipment, aevh.ts_value;
;
-- ===OBJ=== v_agg_equipment_values_1month
CREATE VIEW public.v_agg_equipment_values_1month AS
 SELECT date_trunc('month'::text, v_agg_equipment_values_1hour.ts_value_production::timestamp with time zone)::date AS ts_value,
    v_agg_equipment_values_1hour.id_equipment,
    v_agg_equipment_values_1hour.id_area,
    v_agg_equipment_values_1hour.id_site,
    v_agg_equipment_values_1hour.id_enterprise,
    v_agg_equipment_values_1hour.tp_equipment,
    COALESCE(sum(v_agg_equipment_values_1hour.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(v_agg_equipment_values_1hour.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(v_agg_equipment_values_1hour.scrap_incr), 0::double precision) AS scrap_incr,
    v_agg_equipment_values_1hour.mode,
    v_agg_equipment_values_1hour.id_production_order,
    v_agg_equipment_values_1hour.conversion_factor,
    v_agg_equipment_values_1hour.number_cavities,
    locf(max(v_agg_equipment_values_1hour.signal_quality), treat_null_as_missing => true) AS signal_quality,
    COALESCE(avg(v_agg_equipment_values_1hour.speed) FILTER (WHERE v_agg_equipment_values_1hour.speed > 0::double precision), 0::double precision) AS speed,
    locf(max(v_agg_equipment_values_1hour.net_production_val), treat_null_as_missing => true) AS net_production_val,
    locf(max(v_agg_equipment_values_1hour.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
    locf(max(v_agg_equipment_values_1hour.scrap_val), treat_null_as_missing => true) AS scra--output truncated--
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.mode,
    s2.id_production_order,
    s2.conversion_factor,
    s2.number_cavities,
    s2.signal_quality,
    s2.speed,
    s2.net_production_val,
    s2.gross_production_val,
    s2.scrap_val,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour,
    s2.id_equipment_line_connected,
    s2.position_in_equipment_line,
    s2.is_equipment_line_infeed,
    s2.is_equipment_line_outfeed
   FROM ( SELECT date_trunc('week'::text, v_agg_equipment_values_1hour.ts_value_production::timestamp with time zone) AS ts_value,
            v_agg_equipment_values_1hour.id_equipment,
            v_agg_equipment_values_1hour.id_area,
            v_agg_equipment_values_1hour.id_site,
            v_agg_equipment_values_1hour.id_enterprise,
            v_agg_equipment_values_1hour.tp_equipment,
            COALESCE(sum(v_agg_equipment_values_1hour.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_equipment_values_1hour.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_equipment_values_1hour.mode,
            v_agg_equipment_values_1hour.id_production_order,
            v_agg_equipment_values_1hour.conversion_factor,
            v_agg_equipment_values_1hour.number_cavities,
            locf(max(v_agg_equipment_values_1hour.signal_quality), treat_null_as_missing => true) AS signal_quality,
            COALESCE(avg(v_agg_equipment_values_1hour.speed) FILTER (WHERE v_agg_equipment_values_1hour.speed > 0::double precision), 0::double precision) AS speed,
            locf(max(v_agg_equipment_values_1hour.net_production_val), treat_null_as_missing => true) AS net_production_val,
            locf(max(v_agg_equipment_values_1hour.gross_production_val), treat_null_as_missing => true) AS gross_production_val,
            locf(max(v_agg_equipment_values_1hour.scrap_val), treat_null_as_missing => true) AS scrap_val,
            v_agg_equipment_values_1hour.id_shift,
            v_agg_equipment_values_1hour.id_team,
            v_agg_equipment_values_1hour.id_shift_hour,
            v_agg_equipment_values_1hour.id_equipment_line_connected,
            v_agg_equipment_values_1hour.position_in_equipment_line,
            v_agg_equipment_values_1hour.is_equipment_line_infeed,
            v_agg_equipment_values_1hour.is_equipment_line_outfeed
           FROM v_agg_equipment_values_1hour
          WHERE v_agg_equipment_values_1hour.ts_value_production IS NOT NULL
          GROUP BY (date_trunc('week'::text, v_agg_equipment_values_1hour.ts_value_production::timestamp with time zone)), v_agg_equipment_values_1hour.id_equipment, v_agg_equipment_values_1hour.id_area, v_agg_equipment_values_1hour.id_site, v_agg_equipment_values_1hour.id_enterprise, v_agg_equipment_values_1hour.tp_equipment, v_agg_equipment_values_1hour.mode, v_agg_equipment_values_1hour.id_production_order, v_agg_equipment_values_1hour.conversion_factor, v_agg_equipment_values_1hour.number_cavities, v_agg_equipment_values_1hour.id_shift, v_agg_equipment_values_1hour.id_team, v_agg_equipment_values_1hour.id_shift_hour, v_agg_equipment_values_1hour.id_equipment_line_connected, v_agg_equipment_values_1hour.position_in_equipment_line, v_agg_equipment_values_1hour.is_equipment_line_infeed, v_agg_equipment_values_1hour.is_equipment_line_outfeed
          ORDER BY v_agg_equipment_values_1hour.id_equipment, (date_trunc('week'::text, v_agg_equipment_values_1hour.ts_value_production::timestamp with time zone)) DESC) s2;
;
-- ===OBJ=== v_agg_site_values_10min
CREATE VIEW public.v_agg_site_values_10min AS
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS ts_value_production
   FROM agg_site_values_10min aevh
  WHERE aevh.ts_value >= (now() - '60 days'::interval)
UNION ALL
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS ts_value_production
   FROM agg_site_values_10min_past aevh
  WHERE aevh.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND aevh.ts_value < (now() - '60 days'::interval)
  ORDER BY 3, 1;
;
-- ===OBJ=== v_agg_site_values_10min_full
CREATE VIEW public.v_agg_site_values_10min_full AS
 SELECT time_bucket('00:10:00'::interval, a.ts_value) AS ts_value,
    a.id_enterprise,
    a.id_site,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.ts_value_production
   FROM v_agg_site_values_1min_full a
  GROUP BY (time_bucket('00:10:00'::interval, a.ts_value)), a.id_enterprise, a.id_site, a.id_shift, a.id_team, a.id_shift_hour, a.ts_value_production
  ORDER BY a.id_site, (time_bucket('00:10:00'::interval, a.ts_value)) DESC;
;
-- ===OBJ=== v_agg_site_values_1day
CREATE VIEW public.v_agg_site_values_1day AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT v_agg_site_values_1hour.ts_value_production AS ts_value,
            v_agg_site_values_1hour.id_enterprise,
            v_agg_site_values_1hour.id_site,
            COALESCE(sum(v_agg_site_values_1hour.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_site_values_1hour.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_site_values_1hour.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_site_values_1hour.id_shift,
            v_agg_site_values_1hour.id_team,
            v_agg_site_values_1hour.id_shift_hour
           FROM v_agg_site_values_1hour
          WHERE v_agg_site_values_1hour.ts_value_production IS NOT NULL
          GROUP BY v_agg_site_values_1hour.ts_value_production, v_agg_site_values_1hour.id_enterprise, v_agg_site_values_1hour.id_site, v_agg_site_values_1hour.id_shift, v_agg_site_values_1hour.id_team, v_agg_site_values_1hour.id_shift_hour
          ORDER BY v_agg_site_values_1hour.id_site, v_agg_site_values_1hour.ts_value_production DESC) s2;
;
-- ===OBJ=== v_agg_site_values_1day_full
CREATE VIEW public.v_agg_site_values_1day_full AS
 SELECT timezone('UTC'::text, s2.ts_value::timestamp with time zone)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT v_agg_site_values_1hour_full.ts_value_production AS ts_value,
            v_agg_site_values_1hour_full.id_enterprise,
            v_agg_site_values_1hour_full.id_site,
            COALESCE(sum(v_agg_site_values_1hour_full.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_site_values_1hour_full.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_site_values_1hour_full.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_site_values_1hour_full.id_shift,
            v_agg_site_values_1hour_full.id_team,
            v_agg_site_values_1hour_full.id_shift_hour
           FROM v_agg_site_values_1hour_full
          WHERE v_agg_site_values_1hour_full.ts_value_production IS NOT NULL
          GROUP BY v_agg_site_values_1hour_full.ts_value_production, v_agg_site_values_1hour_full.id_enterprise, v_agg_site_values_1hour_full.id_site, v_agg_site_values_1hour_full.id_shift, v_agg_site_values_1hour_full.id_team, v_agg_site_values_1hour_full.id_shift_hour
          ORDER BY v_agg_site_values_1hour_full.id_site, v_agg_site_values_1hour_full.ts_value_production DESC) s2;
;
-- ===OBJ=== v_agg_site_values_1hour
CREATE VIEW public.v_agg_site_values_1hour AS
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS ts_value_production
   FROM agg_site_values_1hour aevh
  WHERE aevh.ts_value >= (now() - '60 days'::interval)
UNION ALL
 SELECT aevh.ts_value,
    aevh.id_enterprise,
    aevh.id_site,
    aevh.net_production_incr,
    aevh.gross_production_incr,
    aevh.scrap_incr,
    gapfill(aevh.id_shift) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_shift,
    gapfill(aevh.id_team) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_team,
    gapfill(aevh.id_shift_hour) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS id_shift_hour,
    gapfill(aevh.ts_value_production) OVER (ORDER BY aevh.id_site, aevh.ts_value) AS ts_value_production
   FROM agg_site_values_1hour_past aevh
  WHERE aevh.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND aevh.ts_value < (now() - '60 days'::interval)
  ORDER BY 3, 1;
;
-- ===OBJ=== v_agg_site_values_1hour_full
CREATE VIEW public.v_agg_site_values_1hour_full AS
 SELECT date_trunc('hour'::text, a.ts_value) AS ts_value,
    a.id_enterprise,
    a.id_site,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    a.id_shift,
    a.id_team,
    a.id_shift_hour,
    a.ts_value_production
   FROM v_agg_site_values_1min_full a
  WHERE a.ts_value >= (now() - '60 days'::interval) AND a.ts_value_production IS NOT NULL
  GROUP BY (date_trunc('hour'::text, a.ts_value)), a.id_enterprise, a.id_site, a.id_shift, a.id_team, a.id_shift_hour, a.ts_value_production
  ORDER BY a.id_site, (date_trunc('hour'::text, a.ts_value)) DESC;
;
-- ===OBJ=== v_agg_site_values_1min_full
CREATE VIEW public.v_agg_site_values_1min_full AS
 SELECT time_bucket_gapfill('00:01:00'::interval, a.ts_value, now() - '60 days'::interval, now()) AS ts_value,
    a.id_enterprise,
    a.id_site,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    locf(max(a.id_shift), treat_null_as_missing => true) AS id_shift,
    locf(max(a.id_team), treat_null_as_missing => true) AS id_team,
    locf(max(a.id_shift_hour), treat_null_as_missing => true) AS id_shift_hour,
    locf(last(a.ts_value_production, a.ts_value), treat_null_as_missing => true) AS ts_value_production
   FROM agg_site_values_1min a
  WHERE a.ts_value >= (now() - '60 days'::interval) AND a.id_site IS NOT NULL
  GROUP BY (time_bucket_gapfill('00:01:00'::interval, a.ts_value, now() - '60 days'::interval, now())), a.id_enterprise, a.id_site
UNION ALL
 SELECT time_bucket_gapfill('00:01:00'::interval, a.ts_value, '2021-01-01 03:00:00+00'::timestamp with time zone, now() - '60 days'::interval) AS ts_value,
    a.id_enterprise,
    a.id_site,
    COALESCE(sum(a.net_production_incr), 0::double precision) AS net_production_incr,
    COALESCE(sum(a.gross_production_incr), 0::double precision) AS gross_production_incr,
    COALESCE(sum(a.scrap_incr), 0::double precision) AS scrap_incr,
    locf(max(a.id_shift), treat_null_as_missing => true) AS id_shift,
    locf(max(a.id_team), treat_null_as_missing => true) AS id_team,
    locf(max(a.id_shift_hour), treat_null_as_missing => true) AS id_shift_hour,
    locf(max(a.ts_value_production), treat_null_as_missing => true) AS ts_value_production
   FROM agg_site_values_1min_past a
  WHERE a.ts_value >= '2021-01-01 03:00:00+00'::timestamp with time zone AND a.ts_value < (now() - '60 days'::interval) AND a.id_site IS NOT NULL
  GROUP BY (time_bucket_gapfill('00:01:00'::interval, a.ts_value, '2021-01-01 03:00:00+00'::timestamp with time zone, now() - '60 days'::interval)), a.id_enterprise, a.id_site
  ORDER BY 3, 1 DESC;
;
-- ===OBJ=== v_agg_site_values_1month
CREATE VIEW public.v_agg_site_values_1month AS
 SELECT timezone('UTC'::text, s2.ts_value)::date AS ts_value,
    s2.id_enterprise,
    s2.id_site,
    s2.net_production_incr,
    s2.gross_production_incr,
    s2.scrap_incr,
    s2.id_shift,
    s2.id_team,
    s2.id_shift_hour
   FROM ( SELECT date_trunc('month'::text, v_agg_site_values_1hour.ts_value_production::timestamp with time zone) AS ts_value,
            v_agg_site_values_1hour.id_enterprise,
            v_agg_site_values_1hour.id_site,
            COALESCE(sum(v_agg_site_values_1hour.net_production_incr), 0::double precision) AS net_production_incr,
            COALESCE(sum(v_agg_site_values_1hour.gross_production_incr), 0::double precision) AS gross_production_incr,
            COALESCE(sum(v_agg_site_values_1hour.scrap_incr), 0::double precision) AS scrap_incr,
            v_agg_site_values_1hour.id_shift,
            v_agg_site_values_1hour.id_team,
            v_agg_site_values_1hour.id_shift_hour
           FROM v_agg_site_values_1hour
          WHERE v_agg_site_values_1hour.ts_value_production IS NOT NULL
          GROUP BY (date_trunc('month'::text, v_agg_site_values_1hour.ts_value_production::timestamp with time zone)), v_agg_site_values_1hour.id_enterprise, v_agg_site_values_1hour.id_site, v_agg_site_values_1hour.id_shift, v_agg_site_values_1hour.id_team, v_agg_site_values_1hour.id_shift_hour
          ORDER BY v_agg_site_values_1hour.id_site, (date_trunc('month'::text, v_agg_site_values_1hour.ts_value_production::timestamp with time zone)) DESC) s2;
;
-- ===OBJ=== v_mission_control
CREATE VIEW public.v_mission_control AS
 SELECT sh_info.id_site,
    sh_info.id_area,
    a2.nm_area,
    sh_info.id_equipment AS id_line,
    e2.nm_equipment AS nm_line,
    e2.id_enterprise,
    timeline.timelinestatus,
    uecs.oee AS currshift_oee,
    sh.cd_shift AS curr_shift_name,
    sh2.cd_shift AS prev1_shift_name,
    sh3.cd_shift AS prev2_shift_name,
    po.id_production_order,
    po.id_order,
    po.production_programmed,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value > po.ts_start) AS po_net_production,
    c.nm_client,
    date_part('epoch'::text, now() - po.ts_start) AS duration,
    date_part('epoch'::text, po.production_programmed::double precision / NULLIF(avg(aevm.speed), 0::double precision) * '00:01:00'::interval) AS expected_time,
    avg(aevm.speed) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range AND aevm.speed IS NOT NULL) AS curshift_lastspeed,
    sum(aevm.gross_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range) AS curshift_grosprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range) AS curshift_netprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.prev1_shift_range) AS prev1shift_netprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.prev2_shift_range) AS prev2shift_netprod,
    GREATEST(0::double precision, sum(aevm.scrap_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range)) AS curshift_scrap,
    stoppedtime.planned_duration,
    stoppedtime.planned_duration_percent,
    stoppedtime.change_over_duration,
    stoppedtime.change_over_duration_percent,
    stoppedtime.unplanned_duration,
    stoppedtime.unplanned_duration_percent,
    stoppedtime.total_stopped_time,
    to_json(timeline.timelinestatus) -> '-1'::integer AS laststate
   FROM ca_agg_equipment_values_1hour aevm
     RIGHT JOIN ( SELECT ers.id_equipment,
            e.id_area,
            e.id_site,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[1] AS current_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[1] AS curshift_range,
            max(uecs2.oee) AS currshift_oee,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[2] AS prev1_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[2] AS prev1_shift_range,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[3] AS prev2_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[3] AS prev2_shift_range
           FROM equipment_runtime_shift ers
             LEFT JOIN equipments e USING (id_equipment)
             LEFT JOIN uns_equipment_current_shift uecs2 ON uecs2.id_equipment = ers.id_equipment
          WHERE ers.ts_value < now() AND ers.ts_value > (now() - '3 days'::interval) AND e.tp_equipment = 3
          GROUP BY ers.id_equipment, e.id_area, e.id_site) sh_info USING (id_equipment)
     LEFT JOIN uns_equipment_current_shift uecs USING (id_equipment)
     LEFT JOIN ( SELECT ev.id_equipment,
            pos.id_production_order,
            pos.id_order,
            pos.id_client,
            pos.production_programmed,
            pos.production_real,
            pos.ts_start,
            last(ev.id_production_order, ev.ts_value) FILTER (WHERE ev.id_production_order IS NOT NULL) AS last_po_order
           FROM ca_agg_equipment_values_1hour ev
             LEFT JOIN production_orders pos USING (id_equipment, id_production_order)
          WHERE ev.tp_equipment = 3 AND pos.status = 2
          GROUP BY ev.id_equipment, pos.id_production_order, pos.id_order, pos.id_client, pos.production_programmed, pos.production_real, pos.ts_start) po USING (id_equipment)
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN shift_hours sh(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh.id_shift_hour = sh_info.current_shift
     LEFT JOIN shift_hours sh2(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh2.id_shift_hour = sh_info.prev1_shift
     LEFT JOIN equipments e2(id_equipment_1, cd_equipment, nm_equipment, "position", tp_equipment, id_area, id_site, id_enterprise, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, use_label_net_production, state_change_threshold_time, lead_machine, speed_calculated_by_packiot, event_generated_by_packiot, conversion_factor, net_production_type, id_plc) ON e2.id_equipment_1 = aevm.id_equipment
     LEFT JOIN areas a2 ON a2.id_area = aevm.id_area
     LEFT JOIN shift_hours sh3(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh3.id_shift_hour = sh_info.prev2_shift
     LEFT JOIN ( SELECT dt.id_equipment,
            array_agg(dt.situation ORDER BY dt.ts_value) AS timelinestatus
           FROM ( SELECT aevm_1.ts_value,
                    aevm_1.id_equipment,
                        CASE
                            WHEN COALESCE(aevm_1.net_production_incr, 0.0::double precision) >= (e.minimum_ideal_performance_threshold * e.production_speed::double precision) THEN 'running'::text
                            WHEN COALESCE(aevm_1.net_production_incr, 0.0::double precision) < (e.minimum_ideal_performance_threshold * e.production_speed::double precision) AND COALESCE(aevm_1.net_production_incr, 0.0::double precision) >= (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'lowSpeed'::text
                            WHEN COALESCE(aevm_1.net_production_incr, 0::double precision) < (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'stopped'::text
                            ELSE NULL::text
                        END AS situation
                   FROM agg_equipment_values_1min_t aevm_1
                     LEFT JOIN equipments e USING (id_equipment)
                  WHERE aevm_1.ts_value >= (now() - '24:01:00'::interval) AND aevm_1.ts_value < (now() - '00:01:00'::interval) AND aevm_1.tp_equipment = 3) dt
          GROUP BY dt.id_equipment) timeline(id_equipment_1, timelinestatus) ON timeline.id_equipment_1 = sh_info.id_equipment
     LEFT JOIN ( SELECT dsum.id_equipment,
            dsum.planned_duration,
            dsum.total_stopped_time,
            dsum.planned_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS planned_duration_percent,
            dsum.change_over_duration,
            dsum.change_over_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS change_over_duration_percent,
            dsum.unplanned_duration,
            dsum.unplanned_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS unplanned_duration_percent
           FROM ( SELECT durationsum.id_equipment,
                    durationsum.planned_duration,
                    durationsum.change_over_duration,
                    durationsum.unplanned_duration,
                    durationsum.planned_duration + durationsum.change_over_duration + durationsum.unplanned_duration AS total_stopped_time
                   FROM ( SELECT durations.id_equipment,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE
                                    WHEN durations.change_over = true THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS change_over_duration,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE


                                    WHEN durations.change_over = false AND durations.planned_downtime = true THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS planned_duration,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE
                                    WHEN durations.change_over = false AND durations.planned_downtime = false THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS unplanned_duration
                           FROM ( SELECT ee.planned_downtime,
                                    ee.change_over,
                                    ee.id_equipment,
                                    ee.status,
                                    ee.ts_event,
                                    ee.ts_end,
                                    sum(
CASE
 WHEN ee.ts_event >= (date_trunc('day'::text, now()) + '00:00:01'::interval * e3.day_begin::double precision) THEN
 CASE
  WHEN ee.ts_end IS NULL THEN now() - ee.ts_event
  ELSE ee.ts_end - ee.ts_event
 END
 ELSE
 CASE
  WHEN ee.ts_end IS NULL THEN now() - ee.ts_event
  ELSE
  CASE
   WHEN ee.ts_end > (date_trunc('day'::text, now()) + '00:00:01'::interval * e3.day_begin::double precision) THEN ee.ts_end - ee.ts_event
   ELSE NULL::interval
  END
 END
END) AS duration
                                   FROM equipment_events ee
                                     LEFT JOIN ( SELECT equipments.id_equipment,
    equipments.tp_equipment
   FROM equipments) e2_1 ON e2_1.id_equipment = ee.id_equipment
                                     LEFT JOIN ( SELECT enterprises.id_enterprise,
    enterprises.day_begin
   FROM enterprises) e3 ON e3.id_enterprise = ee.id_enterprise
                                  WHERE ee.ts_event >= (now() - '4 days'::interval) AND e2_1.tp_equipment = 3 AND ee.status = 10
                                  GROUP BY ee.id_equipment, e2_1.id_equipment, ee.ts_event, e2_1.tp_equipment, e3.id_enterprise, e3.day_begin) durations
                          GROUP BY durations.id_equipment) durationsum) dsum) stoppedtime(id_equipment_1, planned_duration, total_stopped_time, planned_duration_percent, change_over_duration, change_over_duration_percent, unplanned_duration, unplanned_duration_percent) ON stoppedtime.id_equipment_1 = sh_info.id_equipment
  WHERE aevm.ts_value >= (now() - '4 days'::interval)
  GROUP BY sh_info.id_site, sh_info.id_area, sh_info.id_equipment, sh_info.currshift_oee, sh.cd_shift, sh2.cd_shift, sh3.cd_shift, timeline.timelinestatus, po.id_production_order, po.id_order, po.ts_start, c.nm_client, po.production_programmed, e2.nm_equipment, a2.nm_area, e2.id_enterprise, stoppedtime.planned_duration, stoppedtime.planned_duration_percent, stoppedtime.change_over_duration, stoppedtime.change_over_duration_percent, stoppedtime.unplanned_duration, stoppedtime.unplanned_duration_percent, stoppedtime.total_stopped_time, uecs.oee;
;
-- ===OBJ=== v_mission_control_areas
CREATE VIEW public.v_mission_control_areas AS
 SELECT a1.id_enterprise,
    a1.id_area,
    a1.nm_area,
    a1.net_production,
    a1.gross_production,
    a1.scrap,
    a1.ts_value_production
   FROM ( SELECT vaavhf.id_area,
            a3.nm_area,
            vaavhf.id_enterprise,
            sum(vaavhf.net_production_incr) AS net_production,
            sum(vaavhf.gross_production_incr) AS gross_production,
            sum(vaavhf.scrap_incr) AS scrap,
            vaavhf.ts_value_production,
            row_number() OVER (PARTITION BY vaavhf.id_area ORDER BY vaavhf.ts_value_production DESC) AS rank_per_area
           FROM v_agg_area_values_1hour_full vaavhf
             LEFT JOIN ( SELECT areas.nm_area,
                    areas.id_area
                   FROM areas) a3 ON vaavhf.id_area = a3.id_area
          WHERE vaavhf.ts_value_production >= (now() - '7 days'::interval)
          GROUP BY vaavhf.id_enterprise, vaavhf.id_site, vaavhf.id_area, a3.nm_area, vaavhf.ts_value_production) a1
  WHERE a1.rank_per_area = 1;
;
-- ===OBJ=== v_mission_control_areas_shift_temp_fix
CREATE VIEW public.v_mission_control_areas_shift_temp_fix AS
 SELECT dataa.ts_value_production,
    dataa.id_area,
    dataa.nm_area,
    dataa.id_enterprise,
    dataa.gross_production,
    dataa.net_production,
    dataa.scrap,
    dataa.oee_q * dataa.oee_a * dataa.oee_p AS oee
   FROM ( SELECT shift_ordered.ts_value_production,
            shift_ordered.id_area,
            ( SELECT areas.nm_area
                   FROM areas
                  WHERE areas.id_area = shift_ordered.id_area) AS nm_area,
            ( SELECT areas.id_enterprise
                   FROM areas
                  WHERE areas.id_area = shift_ordered.id_area) AS id_enterprise,
            shift_ordered.gross AS gross_production,
            shift_ordered.net AS net_production,
            COALESCE(shift_ordered.gross, 0::double precision) - COALESCE(shift_ordered.net, 0::double precision) AS scrap,
                CASE
                    WHEN shift_ordered.gross IS NOT NULL AND shift_ordered.gross > 0::double precision THEN COALESCE(shift_ordered.net, 0::double precision) / shift_ordered.gross
                    ELSE 1::double precision
                END AS oee_q,
                CASE
                    WHEN shift_ordered.available_time IS NOT NULL AND shift_ordered.available_time > 0::numeric THEN COALESCE(shift_ordered.running_time, 0::double precision) / shift_ordered.available_time::double precision
                    ELSE 1::double precision
                END AS oee_a,
                CASE
                    WHEN shift_ordered.ideal_production IS NOT NULL AND shift_ordered.ideal_production > 0::numeric THEN COALESCE(shift_ordered.gross, 0::double precision) / shift_ordered.ideal_production::double precision
                    ELSE 1::double precision
                END AS oee_p
           FROM ( SELECT shifts.id_area,
                    shifts.id_shift,
                    shifts.id_shift_hour,
                    shifts.ts_value_production,
                    shifts.ts_value,
                    COALESCE(shifts.duration, 0::double precision) AS duration,
                    COALESCE(shifts.changeover_time, 0::double precision) AS changeover_time,
                    COALESCE(shifts.planned_downtime, 0::double precision) AS planned_downtime,
                    COALESCE(shifts.running_time, 0::double precision) AS running_time,
                    COALESCE(shifts.available_time, 0::numeric) AS available_time,
                    COALESCE(shifts.net, 0::double precision) AS net,
                    COALESCE(shifts.gross, 0::double precision) AS gross,
                    COALESCE(shifts.ideal_production, 0::numeric) AS ideal_production,
                    row_number(*) OVER (PARTITION BY shifts.id_area ORDER BY shifts.ts_value_production DESC, shifts.ts_value DESC) AS row_rank
                   FROM ( SELECT shift_agg_from_events.id_area,
                            shift_agg_from_events.id_shift,
                            shift_agg_from_events.id_shift_hour,
                            shift_agg_from_events.ts_value_production,
                            shift_agg_from_events.ts_value,
                            sum(shift_agg_from_events.duration) AS duration,
                            sum(shift_agg_from_events.changeover_time) AS changeover_time,
                            sum(shift_agg_from_events.planned_downtime) AS planned_downtime,
                            sum(shift_agg_from_events.running_time) AS running_time,
                            sum(shift_agg_from_events.available_time) AS available_time,
                            sum(shift_agg_from_events.net) AS net,
                            sum(shift_agg_from_events.gross) AS gross,
                            sum(shift_agg_from_events.ideal_production) AS ideal_production
                           FROM shift_agg_from_events shift_agg_from_events
                          WHERE shift_agg_from_events.ts_value_production > (now() - '7 days'::interval)
                          GROUP BY shift_agg_from_events.id_site, shift_agg_from_events.id_area, shift_agg_from_events.id_shift_hour, shift_agg_from_events.id_shift, shift_agg_from_events.ts_value_production, shift_agg_from_events.ts_value) shifts) shift_ordered
          WHERE shift_ordered.row_rank = 1) dataa;
;
-- ===OBJ=== v_mission_control_areas_sum_from_equipment
CREATE VIEW public.v_mission_control_areas_sum_from_equipment AS
 WITH last_shift AS (
         SELECT ls_1.id_area,
            ls_1.id_shift_hour,
            ls_1.ts_value_production,
            sum(ls_1.ideal_production) AS ideal_production
           FROM ( SELECT safev.id_area,
                    safev.ts_value,
                    safev.id_shift_hour,
                    safev.ideal_production,
                    safev.ts_value_production,
                    row_number(*) OVER (PARTITION BY safev.id_area ORDER BY safev.ts_value DESC) AS rn
                   FROM shift_agg_from_events_v2 safev
                  WHERE safev.ts_value_production > (now() - '2 days'::interval)) ls_1
          WHERE ls_1.rn = 1
          GROUP BY ls_1.id_area, ls_1.id_shift_hour, ls_1.ts_value_production
        ), areas_sum AS (
         SELECT vmc.id_enterprise,
            vmc.id_area,
            vmc.nm_area,
            sum(vmc.curshift_grosprod) AS gross_production,
            sum(vmc.curshift_netprod) AS net_production,
            sum(vmc.curshift_scrap) AS scrap
           FROM v_mission_control vmc
          GROUP BY vmc.id_enterprise, vmc.id_area, vmc.nm_area
        )
 SELECT ls.ts_value_production,
    sa.id_enterprise,
    sa.id_area,
    sa.nm_area,
    sa.gross_production,
    sa.net_production,
    sa.scrap,
    sa.net_production / NULLIF(ls.ideal_production, 0::numeric)::double precision AS oee_area_raw,
    COALESCE(LEAST(1::double precision, GREATEST(0::double precision, sa.net_production / NULLIF(ls.ideal_production, 0::numeric)::double precision)), 0::double precision) AS oee_area
   FROM areas_sum sa
     LEFT JOIN last_shift ls USING (id_area);
;
-- ===OBJ=== v_operator_po_details
CREATE VIEW public.v_operator_po_details AS
 WITH count_from_label AS (
         SELECT COALESCE(ppe.id_equipment, pe.id_equipment, e.id_equipment) AS id_equipment,
            ca.id_order,
            sum(ca.net_production) AS net_production
           FROM ca_equipment_boxes_1hour ca
             JOIN equipments e ON e.id_equipment = ca.id_equipment
             LEFT JOIN equipments pe ON pe.id_equipment = e.id_parentequipment
             LEFT JOIN equipments ppe ON ppe.id_equipment = pe.id_parentequipment
             JOIN production_orders po ON po.id_order_text::text = ca.id_order
          WHERE po.status = 2
          GROUP BY (COALESCE(ppe.id_equipment, pe.id_equipment, e.id_equipment)), ca.id_order
        )
 SELECT
        CASE
            WHEN eeq.net_production_type = 1 THEN COALESCE(vq.net_production_from_boxes, 0::double precision)
            ELSE vq.net_production
        END AS net_production,
    vq.scrap,
    eeq.running_time,
    eeq.downtime,
    vq.id_equipment,
    vq.id_enterprise,
    vq.id_production_order,
    vq.gross
   FROM ( SELECT po.net_production,
            cfl.net_production AS net_production_from_boxes,
            po.gross_production AS gross,
            po.id_equipment,
            po.id_enterprise,
            po.id_order,
            po.id_production_order,
            sum(v.scrap_incr) AS scrap
           FROM ca_agg_equipment_values_1hour v
             JOIN production_orders po ON po.id_production_order = v.id_production_order
             LEFT JOIN count_from_label cfl ON cfl.id_equipment = v.id_equipment AND po.id_order_text::text = cfl.id_order
          WHERE po.status = 2 AND v.id_enterprise = po.id_enterprise AND v.tp_equipment = 3 AND v.ts_value >= (now() - '10 days'::interval)
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, cfl.net_production) vq
     LEFT JOIN ( SELECT sum(
                CASE
                    WHEN ee.status = 6 AND ee.ts_end IS NOT NULL THEN ee.duration
                    ELSE NULL::integer
                END) AS running_time,
            sum(
                CASE
                    WHEN ee.status <> 6 AND ee.ts_end IS NOT NULL THEN ee.duration
                    ELSE NULL::integer
                END) AS downtime,
            po.id_production_order,
            po.id_enterprise,
            e.net_production_type
           FROM equipment_events ee
             JOIN production_orders po ON po.id_equipment = ee.id_equipment
             JOIN production_orders_runtime por ON por.id_production_order = po.id_production_order AND por.runtime_timerange @> ee.ts_event
             JOIN equipments e ON e.id_equipment = ee.id_equipment AND e.tp_equipment = 3
          WHERE po.status = 2 AND ee.ts_event >= (now() - '10 days'::interval)
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, e.net_production_type) eeq ON vq.id_production_order = eeq.id_production_order AND vq.id_enterprise = eeq.id_enterprise;
;



-- ===CAGG=== agg_area_values_10min materialized_only=false
 SELECT time_bucket('00:10:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('00:10:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.ts_value_production;
-- ===CAGG=== agg_area_values_1hour materialized_only=false
 SELECT time_bucket('01:00:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('01:00:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.ts_value_production;
-- ===CAGG=== agg_area_values_1min materialized_only=false
 SELECT time_bucket('00:01:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    last(equipment_values.id_shift, equipment_values.ts_value) AS id_shift,
    last(equipment_values.id_team, equipment_values.ts_value) AS id_team,
    last(equipment_values.id_shift_hour, equipment_values.ts_value) AS id_shift_hour,
    last(equipment_values.ts_value_production, equipment_values.ts_value) AS ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('00:01:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area;
-- ===CAGG=== agg_equipment_values_10min materialized_only=false
 SELECT time_bucket('00:10:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.id_equipment,
    equipment_values.tp_equipment,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.mode,
    avg(equipment_values.speed) AS speed,
    equipment_values.id_production_order,
    equipment_values.conversion_factor,
    equipment_values.number_cavities,
    equipment_values.signal_quality,
    max(equipment_values.net_production_val) AS net_production_val,
    max(equipment_values.gross_production_val) AS gross_production_val,
    max(equipment_values.scrap_val) AS scrap_val,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.box_code,
    equipment_values.transaction_code,
    equipment_values.ts_value_production,
    equipment_values.id_equipment_line_connected,
    equipment_values.position_in_equipment_line,
    equipment_values.is_equipment_line_infeed,
    equipment_values.is_equipment_line_outfeed
   FROM equipment_values
  WHERE (equipment_values.tp_equipment IS NOT NULL)
  GROUP BY (time_bucket('00:10:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_equipment, equipment_values.tp_equipment, equipment_values.mode, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.signal_quality, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.box_code, equipment_values.transaction_code, equipment_values.ts_value_production, equipment_values.id_equipment_line_connected, equipment_values.position_in_equipment_line, equipment_values.is_equipment_line_infeed, equipment_values.is_equipment_line_outfeed;
-- ===CAGG=== agg_equipment_values_1hour materialized_only=false
 SELECT time_bucket('01:00:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.id_equipment,
    equipment_values.tp_equipment,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.mode,
    avg(equipment_values.speed) AS speed,
    equipment_values.id_production_order,
    equipment_values.conversion_factor,
    equipment_values.number_cavities,
    equipment_values.signal_quality,
    max(equipment_values.net_production_val) AS net_production_val,
    max(equipment_values.gross_production_val) AS gross_production_val,
    max(equipment_values.scrap_val) AS scrap_val,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.box_code,
    equipment_values.transaction_code,
    equipment_values.ts_value_production,
    equipment_values.id_equipment_line_connected,
    equipment_values.position_in_equipment_line,
    equipment_values.is_equipment_line_infeed,
    equipment_values.is_equipment_line_outfeed
   FROM equipment_values
  WHERE (equipment_values.tp_equipment IS NOT NULL)
  GROUP BY (time_bucket('01:00:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_equipment, equipment_values.tp_equipment, equipment_values.mode, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.signal_quality, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.box_code, equipment_values.transaction_code, equipment_values.ts_value_production, equipment_values.id_equipment_line_connected, equipment_values.position_in_equipment_line, equipment_values.is_equipment_line_infeed, equipment_values.is_equipment_line_outfeed;
-- ===CAGG=== agg_equipment_values_1min materialized_only=false
 SELECT time_bucket('00:01:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.id_equipment,
    equipment_values.tp_equipment,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    max(equipment_values.state) AS state,
    max(equipment_values.mode) AS mode,
    avg(equipment_values.speed) AS speed,
    max((equipment_values.id_order)::text) AS id_order,
    max(equipment_values.conversion_factor) AS conversion_factor,
    max(equipment_values.number_cavities) AS number_cavities,
    max(equipment_values.signal_quality) AS signal_quality,
    max(equipment_values.net_production_val) AS net_production_val,
    max(equipment_values.gross_production_val) AS gross_production_val,
    max(equipment_values.scrap_val) AS scrap_val,
    max(equipment_values.id_shift) AS id_shift,
    max(equipment_values.id_team) AS id_team,
    max(equipment_values.id_shift_hour) AS id_shift_hour,
    last(equipment_values.box_code, equipment_values.ts_value) AS box_code,
    last(equipment_values.transaction_code, equipment_values.ts_value) AS transaction_code,
    max(equipment_values.id_production_order) AS id_production_order,
    max(equipment_values.ts_value_production) AS ts_value_production,
    max(equipment_values.id_equipment_line_connected) AS id_equipment_line_connected,
    max(equipment_values.position_in_equipment_line) AS position_in_equipment_line,
    max(equipment_values.is_equipment_line_infeed) AS is_equipment_line_infeed,
    max(equipment_values.is_equipment_line_outfeed) AS is_equipment_line_outfeed,
    max(equipment_values.ideal_production_speed) AS ideal_production_speed
   FROM equipment_values
  WHERE (equipment_values.tp_equipment IS NOT NULL)
  GROUP BY (time_bucket('00:01:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_equipment, equipment_values.tp_equipment;
-- ===CAGG=== agg_site_values_10min materialized_only=false
 SELECT time_bucket('00:10:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('00:10:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.ts_value_production;
-- ===CAGG=== agg_site_values_1hour materialized_only=false
 SELECT time_bucket('01:00:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('01:00:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.ts_value_production;
-- ===CAGG=== agg_site_values_1min materialized_only=false
 SELECT time_bucket('00:01:00'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    last(equipment_values.id_shift, equipment_values.ts_value) AS id_shift,

    last(equipment_values.id_team, equipment_values.ts_value) AS id_team,
    last(equipment_values.id_shift_hour, equipment_values.ts_value) AS id_shift_hour,
    last(equipment_values.ts_value_production, equipment_values.ts_value) AS ts_value_production
   FROM equipment_values
  WHERE (equipment_values.tp_equipment = 3)
  GROUP BY (time_bucket('00:01:00'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site;
-- ===CAGG=== ca_agg_equipment_values_10min materialized_only=false
 SELECT time_bucket('00:10:00'::interval, agg_equipment_values_1min_t.ts_value) AS ts_value,
    agg_equipment_values_1min_t.id_equipment,
    agg_equipment_values_1min_t.id_enterprise,
    agg_equipment_values_1min_t.id_site,
    agg_equipment_values_1min_t.id_area,
    agg_equipment_values_1min_t.tp_equipment,
    agg_equipment_values_1min_t.state,
    agg_equipment_values_1min_t.mode,
    avg(agg_equipment_values_1min_t.speed) AS speed,
    agg_equipment_values_1min_t.id_order,
    agg_equipment_values_1min_t.conversion_factor,
    agg_equipment_values_1min_t.number_cavities,
    agg_equipment_values_1min_t.signal_quality,
    agg_equipment_values_1min_t.id_shift,
    agg_equipment_values_1min_t.id_team,
    agg_equipment_values_1min_t.id_shift_hour,
    agg_equipment_values_1min_t.id_production_order,
    agg_equipment_values_1min_t.ts_value_production,
    agg_equipment_values_1min_t.ideal_production_speed,
    sum(agg_equipment_values_1min_t.net_production_incr) AS net_production_incr,
    sum(agg_equipment_values_1min_t.gross_production_incr) AS gross_production_incr,
    sum(agg_equipment_values_1min_t.scrap_incr) AS scrap_incr,
    max(agg_equipment_values_1min_t.net_production_val) AS net_production_val,
    max(agg_equipment_values_1min_t.gross_production_val) AS gross_production_val,
    max(agg_equipment_values_1min_t.scrap_val) AS scrap_val
   FROM agg_equipment_values_1min_t
  GROUP BY (time_bucket('00:10:00'::interval, agg_equipment_values_1min_t.ts_value)), agg_equipment_values_1min_t.id_equipment, agg_equipment_values_1min_t.id_enterprise, agg_equipment_values_1min_t.id_site, agg_equipment_values_1min_t.id_area, agg_equipment_values_1min_t.tp_equipment, agg_equipment_values_1min_t.state, agg_equipment_values_1min_t.mode, agg_equipment_values_1min_t.id_order, agg_equipment_values_1min_t.conversion_factor, agg_equipment_values_1min_t.number_cavities, agg_equipment_values_1min_t.signal_quality, agg_equipment_values_1min_t.id_shift, agg_equipment_values_1min_t.id_team, agg_equipment_values_1min_t.id_shift_hour, agg_equipment_values_1min_t.id_production_order, agg_equipment_values_1min_t.ts_value_production, agg_equipment_values_1min_t.ideal_production_speed;
-- ===CAGG=== ca_agg_equipment_values_1day materialized_only=false
 SELECT agg_equipment_values_1min_t.ts_value_production AS ts_value,
    time_bucket('1 day'::interval, agg_equipment_values_1min_t.ts_value) AS ts_value_real,
    agg_equipment_values_1min_t.id_equipment,
    agg_equipment_values_1min_t.id_enterprise,
    agg_equipment_values_1min_t.id_site,
    agg_equipment_values_1min_t.id_area,
    agg_equipment_values_1min_t.tp_equipment,
    agg_equipment_values_1min_t.state,
    agg_equipment_values_1min_t.mode,
    avg(agg_equipment_values_1min_t.speed) AS speed,
    agg_equipment_values_1min_t.id_order,
    agg_equipment_values_1min_t.conversion_factor,
    agg_equipment_values_1min_t.number_cavities,
    agg_equipment_values_1min_t.signal_quality,
    agg_equipment_values_1min_t.id_shift,
    agg_equipment_values_1min_t.id_team,
    agg_equipment_values_1min_t.id_shift_hour,
    agg_equipment_values_1min_t.id_production_order,
    agg_equipment_values_1min_t.ideal_production_speed,
    sum(agg_equipment_values_1min_t.net_production_incr) AS net_production_incr,
    sum(agg_equipment_values_1min_t.gross_production_incr) AS gross_production_incr,
    sum(agg_equipment_values_1min_t.scrap_incr) AS scrap_incr,
    max(agg_equipment_values_1min_t.net_production_val) AS net_production_val,
    max(agg_equipment_values_1min_t.gross_production_val) AS gross_production_val,
    max(agg_equipment_values_1min_t.scrap_val) AS scrap_val
   FROM agg_equipment_values_1min_t
  GROUP BY agg_equipment_values_1min_t.ts_value_production, (time_bucket('1 day'::interval, agg_equipment_values_1min_t.ts_value)), agg_equipment_values_1min_t.id_equipment, agg_equipment_values_1min_t.id_enterprise, agg_equipment_values_1min_t.id_site, agg_equipment_values_1min_t.id_area, agg_equipment_values_1min_t.tp_equipment, agg_equipment_values_1min_t.state, agg_equipment_values_1min_t.mode, agg_equipment_values_1min_t.id_order, agg_equipment_values_1min_t.conversion_factor, agg_equipment_values_1min_t.number_cavities, agg_equipment_values_1min_t.signal_quality, agg_equipment_values_1min_t.id_shift, agg_equipment_values_1min_t.id_team, agg_equipment_values_1min_t.id_shift_hour, agg_equipment_values_1min_t.id_production_order, agg_equipment_values_1min_t.ideal_production_speed;
-- ===CAGG=== ca_agg_equipment_values_1hour materialized_only=false
 SELECT time_bucket('01:00:00'::interval, agg_equipment_values_1min_t.ts_value) AS ts_value,
    agg_equipment_values_1min_t.id_equipment,
    agg_equipment_values_1min_t.id_enterprise,
    agg_equipment_values_1min_t.id_site,
    agg_equipment_values_1min_t.id_area,
    agg_equipment_values_1min_t.tp_equipment,
    agg_equipment_values_1min_t.state,
    agg_equipment_values_1min_t.mode,
    avg(agg_equipment_values_1min_t.speed) AS speed,
    (count(*) * 60) AS duration,
    agg_equipment_values_1min_t.id_order,
    agg_equipment_values_1min_t.conversion_factor,
    agg_equipment_values_1min_t.number_cavities,
    agg_equipment_values_1min_t.signal_quality,
    agg_equipment_values_1min_t.id_shift,
    agg_equipment_values_1min_t.id_team,
    agg_equipment_values_1min_t.id_shift_hour,
    agg_equipment_values_1min_t.id_production_order,
    agg_equipment_values_1min_t.ts_value_production,
    agg_equipment_values_1min_t.ideal_production_speed,
    sum(agg_equipment_values_1min_t.net_production_incr) AS net_production_incr,
    sum(agg_equipment_values_1min_t.gross_production_incr) AS gross_production_incr,
    sum(agg_equipment_values_1min_t.scrap_incr) AS scrap_incr,
    max(agg_equipment_values_1min_t.net_production_val) AS net_production_val,
    max(agg_equipment_values_1min_t.gross_production_val) AS gross_production_val,
    max(agg_equipment_values_1min_t.scrap_val) AS scrap_val
   FROM agg_equipment_values_1min_t
  GROUP BY (time_bucket('01:00:00'::interval, agg_equipment_values_1min_t.ts_value)), agg_equipment_values_1min_t.id_equipment, agg_equipment_values_1min_t.id_enterprise, agg_equipment_values_1min_t.id_site, agg_equipment_values_1min_t.id_area, agg_equipment_values_1min_t.tp_equipment, agg_equipment_values_1min_t.state, agg_equipment_values_1min_t.mode, agg_equipment_values_1min_t.id_order, agg_equipment_values_1min_t.conversion_factor, agg_equipment_values_1min_t.number_cavities, agg_equipment_values_1min_t.signal_quality, agg_equipment_values_1min_t.id_shift, agg_equipment_values_1min_t.id_team, agg_equipment_values_1min_t.id_shift_hour, agg_equipment_values_1min_t.id_production_order, agg_equipment_values_1min_t.ts_value_production, agg_equipment_values_1min_t.ideal_production_speed;
-- ===CAGG=== ca_agg_equipment_values_1s materialized_only=false
 SELECT time_bucket('00:00:01'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.id_equipment,
    equipment_values.tp_equipment,
    sum(equipment_values.net_production_incr) AS net_production_incr,
    sum(equipment_values.gross_production_incr) AS gross_production_incr,
    sum(equipment_values.scrap_incr) AS scrap_incr,
    max(equipment_values.state) AS state,
    max(equipment_values.mode) AS mode,
    avg(equipment_values.speed) AS speed,
    max((equipment_values.id_order)::text) AS id_order,
    max(equipment_values.conversion_factor) AS conversion_factor,
    max(equipment_values.number_cavities) AS number_cavities,
    max(equipment_values.signal_quality) AS signal_quality,
    max(equipment_values.net_production_val) AS net_production_val,
    max(equipment_values.gross_production_val) AS gross_production_val,
    max(equipment_values.scrap_val) AS scrap_val,
    max(equipment_values.id_shift) AS id_shift,
    max(equipment_values.id_team) AS id_team,
    max(equipment_values.id_shift_hour) AS id_shift_hour,
    last(equipment_values.box_code, equipment_values.ts_value) AS box_code,
    last(equipment_values.transaction_code, equipment_values.ts_value) AS transaction_code,
    max(equipment_values.id_production_order) AS id_production_order,
    max(equipment_values.ts_value_production) AS ts_value_production,
    max(equipment_values.id_equipment_line_connected) AS id_equipment_line_connected,
    max(equipment_values.position_in_equipment_line) AS position_in_equipment_line,
    max(equipment_values.is_equipment_line_infeed) AS is_equipment_line_infeed,
    max(equipment_values.is_equipment_line_outfeed) AS is_equipment_line_outfeed,
    max(equipment_values.ideal_production_speed) AS ideal_production_speed
   FROM equipment_values
  GROUP BY (time_bucket('00:00:01'::interval, equipment_values.ts_value)), equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.id_equipment, equipment_values.tp_equipment;
-- ===CAGG=== ca_discrete_changes_1s materialized_only=false
 SELECT time_bucket('00:00:01'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_equipment,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.state,
    equipment_values.mode,
    equipment_values.id_order,
    equipment_values.id_production_order,
    equipment_values.conversion_factor,
    equipment_values.number_cavities,
    equipment_values.ts_value_production,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.sub_mode,
    equipment_values.ideal_production_speed
   FROM equipment_values
  WHERE (NOT ((equipment_values.state IS NULL) AND (equipment_values.mode IS NULL) AND (equipment_values.id_order IS NULL) AND (equipment_values.id_production_order IS NULL) AND (equipment_values.conversion_factor IS NULL) AND (equipment_values.number_cavities IS NULL) AND (equipment_values.ts_value_production IS NULL) AND (equipment_values.id_shift IS NULL) AND (equipment_values.id_team IS NULL) AND (equipment_values.id_shift_hour IS NULL) AND (equipment_values.sub_mode IS NULL) AND (equipment_values.ideal_production_speed IS NULL)))
  GROUP BY (time_bucket('00:00:01'::interval, equipment_values.ts_value)), equipment_values.id_equipment, equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.state, equipment_values.mode, equipment_values.id_order, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.ts_value_production, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.sub_mode, equipment_values.ideal_production_speed;
-- ===CAGG=== ca_equipment_boxes_1hour materialized_only=false
 SELECT time_bucket('01:00:00'::interval, ev.ts_value) AS ts_value,
    ((ev.analogs -> 'Label'::text) ->> 'job'::text) AS id_order,
    ev.id_equipment,
    ev.id_area,
    ev.id_site,
    ev.id_enterprise,
    sum((((ev.analogs -> 'Label'::text) ->> 'value'::text))::double precision) AS net_production,
    count((((ev.analogs -> 'Label'::text) ->> 'value'::text))::integer) AS qty
   FROM equipment_values ev
  WHERE ((ev.analogs IS NOT NULL) AND (ev.analogs ? 'Label'::text))
  GROUP BY (time_bucket('01:00:00'::interval, ev.ts_value)), ((ev.analogs -> 'Label'::text) ->> 'job'::text), ev.id_equipment, ev.id_area, ev.id_site, ev.id_enterprise;
-- ===CAGG=== ca_equipment_boxes_1s materialized_only=false
 SELECT time_bucket('00:00:01'::interval, ev.ts_value) AS ts_value,
    ((ev.analogs -> 'Label'::text) ->> 'job'::text) AS id_order,
    ev.id_equipment,
    ev.id_area,
    ev.id_site,
    ev.id_enterprise,
    sum((((ev.analogs -> 'Label'::text) ->> 'value'::text))::double precision) AS net_production,
    count((((ev.analogs -> 'Label'::text) ->> 'value'::text))::integer) AS qty
   FROM equipment_values ev
  WHERE ((ev.analogs IS NOT NULL) AND (ev.analogs ? 'Label'::text))
  GROUP BY (time_bucket('00:00:01'::interval, ev.ts_value)), ((ev.analogs -> 'Label'::text) ->> 'job'::text), ev.id_equipment, ev.id_area, ev.id_site, ev.id_enterprise;
-- ===CAGG=== mv_ohlc_1s materialized_only=false
 SELECT time_bucket('00:00:01'::interval, ticks."time") AS "time",
    ticks.symbol,
    sum(ticks.counter1) AS counter1,
    sum(ticks.counter2) AS counter2,
    avg(ticks.speed) AS speed
   FROM ticks
  GROUP BY (time_bucket('00:00:01'::interval, ticks."time")), ticks.symbol;

