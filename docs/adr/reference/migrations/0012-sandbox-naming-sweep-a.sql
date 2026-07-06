-- ADR-0012 sandbox naming sweep (A) — h_* Hasura-relation families.
--
-- Scope: the ~50 h_* relations from the Hasura-parity stub. These are
-- NOT covered by the Phase-4 wave plan (that owns the 37 PowerBI-facing
-- c33_/c35_/v_13_/report_* objects); they are product-API-facing
-- function-return relations tracked by Hasura.
--
-- Naming rules applied (see 0012-naming-map.md for the full table):
--   R1 drop noise tokens: piot_, get_, _table, _data suffix/infix
--   R2 version suffixes (2..5, _new, _v2, _test1, _tz_fix, _temp_fix):
--      promote the latest superset shape to the unsuffixed name,
--      retire siblings, keep EVERY old name as a compat view
--   R3 pt-BR → English (resumo → summary)
--   R4 identical-signature duplicates collapse to one table
--
-- Every compat view preserves the OLD column list in the OLD order
-- (column-subset projections — verified against column signatures).
--
-- PROD CAVEATS (why this is sandbox-first):
--   * on prod these are function RETURN TYPES — the real wave must
--     ALTER the paired pg functions and re-track them in Hasura
--     (task #86 gates this; see 0012-phase4-execution-plan.md §1)
--   * canonical names keep shapes ADDITIVE (supersets) except where
--     noted (h_overview_events start/end text→timestamp)
--
-- Single-shot: run once on a freshly provisioned sandbox (or after
-- --reset), like 0012-phase1-renames-and-drops.sql.

BEGIN;

-- ── downtimes family ────────────────────────────────────────────────
DROP TABLE public.h_downtimes_table;               -- v1, subset of _2
DROP TABLE public.h_piot_downtimes_table;          -- subset of _2 (R4)
ALTER TABLE public.h_downtimes_table_2 RENAME TO h_downtimes;
CREATE VIEW public.h_downtimes_table AS
  SELECT ts_event, nm_equipment, cd_machine, duration, cd_category,
         txt_category, cd_subcategory, txt_subcategory,
         txt_downtime_notes, id_order, cd_shift, id_enterprise
  FROM public.h_downtimes;
CREATE VIEW public.h_downtimes_table_2 AS SELECT * FROM public.h_downtimes;
CREATE VIEW public.h_piot_downtimes_table AS
  SELECT ts_event, ts_end, id_equipment, cd_machine, duration,
         cd_category, txt_category, cd_subcategory, txt_subcategory,
         txt_downtime_notes, id_order, cd_shift, id_enterprise
  FROM public.h_downtimes;

DROP TABLE public.h_downtimes_table_with_sector_2; -- _3 minus manual_event
ALTER TABLE public.h_downtimes_table_with_sector_3 RENAME TO h_downtimes_with_sector;
CREATE VIEW public.h_downtimes_table_with_sector_2 AS
  SELECT id_equipment_event, ts_event, ts_end, id_equipment, id_sector,
         nm_equipment, sector, cd_machine, duration, cd_category,
         txt_category, cd_subcategory, txt_subcategory,
         txt_downtime_notes, id_order, cd_shift, id_shift,
         id_enterprise, planned_downtime, change_over, shift_ts_range,
         stop_threshold_time
  FROM public.h_downtimes_with_sector;
CREATE VIEW public.h_downtimes_table_with_sector_3 AS
  SELECT * FROM public.h_downtimes_with_sector;

ALTER TABLE public.h_piot_get_downtimes_per_category_table
  RENAME TO h_downtimes_per_category;
CREATE VIEW public.h_piot_get_downtimes_per_category_table AS
  SELECT * FROM public.h_downtimes_per_category;

ALTER TABLE public.h_piot_get_downtimes_per_category_equipment_level_new
  RENAME TO h_downtimes_per_category_equipment_level;
CREATE VIEW public.h_piot_get_downtimes_per_category_equipment_level_new AS
  SELECT * FROM public.h_downtimes_per_category_equipment_level;

ALTER TABLE public.h_piot_get_downtimes_resumo_table
  RENAME TO h_downtimes_summary;                   -- R3 pt-BR
CREATE VIEW public.h_piot_get_downtimes_resumo_table AS
  SELECT * FROM public.h_downtimes_summary;

ALTER TABLE public.h_piot_split_downtime RENAME TO h_split_downtime;
CREATE VIEW public.h_piot_split_downtime AS
  SELECT * FROM public.h_split_downtime;

-- ── events timeline family (5-deep version chain) ──────────────────
DROP TABLE public.h_events_timeline;               -- v1 ⊂ v5
DROP TABLE public.h_events_timeline2;
DROP TABLE public.h_events_timeline3;
DROP TABLE public.h_events_timeline4;
ALTER TABLE public.h_events_timeline5 RENAME TO h_events_timeline;
CREATE VIEW public.h_events_timeline2 AS
  SELECT ts_event, ts_end, duration, id_equipment, id_enterprise,
         txt_downtime_notes, cd_machine, cd_category, cd_subcategory,
         change_over, desc_category, desc_subcategory, packml_topic,
         event_type
  FROM public.h_events_timeline;
CREATE VIEW public.h_events_timeline3 AS
  SELECT ts_event, ts_end, duration, id_equipment, id_enterprise,
         txt_downtime_notes, cd_machine, cd_category, cd_subcategory,
         change_over, desc_category, desc_subcategory, packml_topic,
         event_type, id_order_text, id_production_order,
         production_programmed, custom_field
  FROM public.h_events_timeline;
CREATE VIEW public.h_events_timeline4 AS
  SELECT ts_event, ts_end, duration, id_equipment, id_enterprise,
         txt_downtime_notes, cd_machine, cd_category, cd_subcategory,
         change_over, desc_category, desc_subcategory, packml_topic,
         event_type, id_order_text, id_production_order,
         production_programmed, custom_field, cd_category_client,
         cd_subcategory_client
  FROM public.h_events_timeline;
CREATE VIEW public.h_events_timeline5 AS SELECT * FROM public.h_events_timeline;

DROP TABLE public.h_events_timeline_full;          -- ⊂ full2
ALTER TABLE public.h_events_timeline_full2 RENAME TO h_events_timeline_full;
CREATE VIEW public.h_events_timeline_full2 AS
  SELECT * FROM public.h_events_timeline_full;

DROP TABLE public.h_events_equipment_timeline_2;   -- R4: identical to base
CREATE VIEW public.h_events_equipment_timeline_2 AS
  SELECT * FROM public.h_events_equipment_timeline;

-- ── overview family (drop the opaque "_i_" token) ───────────────────
DROP TABLE public.h_overview_i_events;             -- start/end were text
DROP TABLE public.h_overview_i_events_2;
ALTER TABLE public.h_overview_i_events_3 RENAME TO h_overview_events;
CREATE VIEW public.h_overview_i_events AS
  SELECT id_enterprise, "start"::text AS "start", "end"::text AS "end",
         duration, reason, sub_category, machine, notes, colorcolumn
  FROM public.h_overview_events;
CREATE VIEW public.h_overview_i_events_2 AS
  SELECT id_enterprise, "start"::text AS "start", "end"::text AS "end",
         duration, reason, sub_category, cd_sector, machine, notes,
         colorcolumn
  FROM public.h_overview_events;
CREATE VIEW public.h_overview_i_events_3 AS SELECT * FROM public.h_overview_events;

ALTER TABLE public.h_overview_i_job_info RENAME TO h_overview_job_info;
CREATE VIEW public.h_overview_i_job_info AS SELECT * FROM public.h_overview_job_info;
ALTER TABLE public.h_overview_i_production_chart RENAME TO h_overview_production_chart;
CREATE VIEW public.h_overview_i_production_chart AS SELECT * FROM public.h_overview_production_chart;
ALTER TABLE public.h_overview_i_shift_production RENAME TO h_overview_shift_production;
CREATE VIEW public.h_overview_i_shift_production AS SELECT * FROM public.h_overview_shift_production;

-- ── simple piot_ de-noising ─────────────────────────────────────────
ALTER TABLE public.h_piot_edge_settings RENAME TO h_edge_settings;
CREATE VIEW public.h_piot_edge_settings AS SELECT * FROM public.h_edge_settings;
ALTER TABLE public.h_piot_edited_po RENAME TO h_edited_po;
CREATE VIEW public.h_piot_edited_po AS SELECT * FROM public.h_edited_po;
ALTER TABLE public.h_piot_home_table RENAME TO h_home;
CREATE VIEW public.h_piot_home_table AS SELECT * FROM public.h_home;
ALTER TABLE public.h_piot_production_flow_table RENAME TO h_production_flow;
CREATE VIEW public.h_piot_production_flow_table AS SELECT * FROM public.h_production_flow;
ALTER TABLE public.h_piot_production_targets RENAME TO h_production_targets;
CREATE VIEW public.h_piot_production_targets AS SELECT * FROM public.h_production_targets;

-- ── mission control family ──────────────────────────────────────────
ALTER TABLE public.h_piot_mission_control RENAME TO h_mission_control;
CREATE VIEW public.h_piot_mission_control AS SELECT * FROM public.h_mission_control;
ALTER TABLE public.h_piot_mission_control_timeline RENAME TO h_mission_control_timeline;
CREATE VIEW public.h_piot_mission_control_timeline AS
  SELECT * FROM public.h_mission_control_timeline;

DROP TABLE public.h_piot_mission_control_uns;      -- ⊂ uns_3
ALTER TABLE public.h_piot_mission_control_uns_3 RENAME TO h_mission_control_uns;
CREATE VIEW public.h_piot_mission_control_uns AS
  SELECT id_site, id_area, nm_area, id_line, nm_line, id_enterprise,
         currshift_oee, curr_shift_name, prev1_shift_name,
         prev2_shift_name, id_order, production_programmed,
         po_net_production, nm_client, duration, expected_time, speed,
         curshift_grosprod, curshift_netprod, prev1shift_netprod,
         prev2shift_netprod, curshift_scrap, planned_downtime,
         planned_duration_percent, change_over_duration,
         change_over_duration_percent, unplanned_duration,
         unplanned_duration_perc, stopped_time, status_24h, status,
         status_time
  FROM public.h_mission_control_uns;
CREATE VIEW public.h_piot_mission_control_uns_3 AS
  SELECT * FROM public.h_mission_control_uns;

-- _area (shift-grain, ts_range+cd_shift) and _area_new (day-grain) are
-- DIFFERENT granularities, not a version chain — both stay, renamed:
ALTER TABLE public.h_piot_mission_control_area RENAME TO h_mission_control_area_by_shift;
CREATE VIEW public.h_piot_mission_control_area AS
  SELECT * FROM public.h_mission_control_area_by_shift;
ALTER TABLE public.h_piot_mission_control_area_new RENAME TO h_mission_control_area;
CREATE VIEW public.h_piot_mission_control_area_new AS
  SELECT * FROM public.h_mission_control_area;

DROP TABLE public.h_piot_mission_control_area_uns; -- ⊂ uns_2
ALTER TABLE public.h_piot_mission_control_area_uns_2 RENAME TO h_mission_control_area_uns;
CREATE VIEW public.h_piot_mission_control_area_uns AS
  SELECT id_enterprise, id_area, nm_area, gross_production,
         net_production, scrap, oee
  FROM public.h_mission_control_area_uns;
CREATE VIEW public.h_piot_mission_control_area_uns_2 AS
  SELECT * FROM public.h_mission_control_area_uns;

-- ── OEE family ──────────────────────────────────────────────────────
ALTER TABLE public.h_piot_oee_progress_chart_data RENAME TO h_oee_progress_chart;
CREATE VIEW public.h_piot_oee_progress_chart_data AS
  SELECT * FROM public.h_oee_progress_chart;
ALTER TABLE public.h_piot_oee_progress_data1 RENAME TO h_oee_progress_by_shift;
CREATE VIEW public.h_piot_oee_progress_data1 AS
  SELECT * FROM public.h_oee_progress_by_shift;
ALTER TABLE public.h_piot_oee_progress_with_teams RENAME TO h_oee_progress_with_teams;
CREATE VIEW public.h_piot_oee_progress_with_teams AS
  SELECT * FROM public.h_oee_progress_with_teams;
ALTER TABLE public.h_piot_oee_score_data RENAME TO h_oee_score;
CREATE VIEW public.h_piot_oee_score_data AS SELECT * FROM public.h_oee_score;
ALTER TABLE public.h_piot_oee_score_data_test1 RENAME TO h_oee_score_shift_detail;
CREATE VIEW public.h_piot_oee_score_data_test1 AS
  SELECT * FROM public.h_oee_score_shift_detail;
ALTER TABLE public.h_piot_oee_score_full_table RENAME TO h_oee_score_full;
CREATE VIEW public.h_piot_oee_score_full_table AS SELECT * FROM public.h_oee_score_full;
ALTER TABLE public.h_piot_oee_score_teams_table RENAME TO h_oee_score_teams;
CREATE VIEW public.h_piot_oee_score_teams_table AS SELECT * FROM public.h_oee_score_teams;

-- ── production orders family ────────────────────────────────────────
DROP TABLE public.h_piot_production_orders_merged_new_table; -- R4 ≡ _new
DROP TABLE public.h_piot_production_orders_merged;           -- v1
ALTER TABLE public.h_piot_production_orders_merged_new RENAME TO h_production_orders_merged;
-- v1 had cd_equipment where canonical has nm_equipment; the stub-era
-- mapping below MUST be verified against prod defs before the real wave
CREATE VIEW public.h_piot_production_orders_merged AS
  SELECT id_enterprise, status, id_production_order, id_order,
         nm_client, nm_product, production_ordered, gross_production,
         net_production, nm_equipment AS cd_equipment, ts_start, ts_end,
         id_equipment
  FROM public.h_production_orders_merged;
CREATE VIEW public.h_piot_production_orders_merged_new AS
  SELECT * FROM public.h_production_orders_merged;
CREATE VIEW public.h_piot_production_orders_merged_new_table AS
  SELECT * FROM public.h_production_orders_merged;

ALTER TABLE public.h_piot_production_orders_table RENAME TO h_production_orders;
CREATE VIEW public.h_piot_production_orders_table AS
  SELECT * FROM public.h_production_orders;

DROP TABLE public.h_piot_production_orders_with_runtimes_table;  -- ⊂ _4
DROP TABLE public.h_piot_production_orders_with_runtimes_table2; -- ⊂ _4
ALTER TABLE public.h_piot_production_orders_with_runtimes_table_4
  RENAME TO h_production_orders_with_runtimes;
CREATE VIEW public.h_piot_production_orders_with_runtimes_table AS
  SELECT id_enterprise, status, id_production_order, id_order,
         nm_client, nm_product, production_ordered, gross_production,
         net_production, nm_equipment, id_area, id_site, ts_start,
         ts_end, id_equipment, runtimes
  FROM public.h_production_orders_with_runtimes;
CREATE VIEW public.h_piot_production_orders_with_runtimes_table2 AS
  SELECT id_enterprise, status, id_production_order, id_order,
         nm_client, nm_product, production_ordered, gross_production,
         net_production, nm_equipment, id_area, id_site, ts_start,
         production_final, ts_end, id_equipment, runtimes
  FROM public.h_production_orders_with_runtimes;
CREATE VIEW public.h_piot_production_orders_with_runtimes_table_4 AS
  SELECT * FROM public.h_production_orders_with_runtimes;

-- ── chart family ────────────────────────────────────────────────────
ALTER TABLE public.h_equipment_chart_data RENAME TO h_equipment_chart;
CREATE VIEW public.h_equipment_chart_data AS SELECT * FROM public.h_equipment_chart;
ALTER TABLE public.h_equipment_chart_data_1day RENAME TO h_equipment_chart_1day;
CREATE VIEW public.h_equipment_chart_data_1day AS
  SELECT * FROM public.h_equipment_chart_1day;

DROP TABLE public.h_single_period_equipment_chart_table_3;   -- ⊂ _4
ALTER TABLE public.h_single_period_equipment_chart_table_4
  RENAME TO h_single_period_equipment_chart;
CREATE VIEW public.h_single_period_equipment_chart_table_3 AS
  SELECT ts_value_production, id_enterprise, net, gross, scrap, target,
         array_agg
  FROM public.h_single_period_equipment_chart;
CREATE VIEW public.h_single_period_equipment_chart_table_4 AS
  SELECT * FROM public.h_single_period_equipment_chart;

DROP TABLE public.h_total_production_chart_data;   -- pre-tz-fix shape
ALTER TABLE public.h_total_production_chart_data_tz_fix
  RENAME TO h_total_production_chart;
-- old base had ts:timestamp; tz_fix made it varchar — cast back for the
-- legacy name (stub-empty today; flag for consumer check on prod)
CREATE VIEW public.h_total_production_chart_data AS
  SELECT ts::timestamp AS ts, net_production_incr, net_production_acc,
         gross_production_acc, scrap, scrap_acc, trendline1, target,
         togoal, id_enterprise, shift_net_prod
  FROM public.h_total_production_chart;
CREATE VIEW public.h_total_production_chart_data_tz_fix AS
  SELECT * FROM public.h_total_production_chart;
-- h_total_production_chart_from_runtime: name already meaningful, keep.

COMMIT;

\echo ''
\echo '=== sweep A verification: canonical tables ==='
SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
  AND relname IN ('h_downtimes','h_downtimes_with_sector',
    'h_downtimes_per_category','h_downtimes_per_category_equipment_level',
    'h_downtimes_summary','h_split_downtime','h_events_timeline',
    'h_events_timeline_full','h_overview_events','h_edge_settings',
    'h_edited_po','h_home','h_production_flow','h_production_targets',
    'h_mission_control','h_mission_control_timeline','h_mission_control_uns',
    'h_mission_control_area','h_mission_control_area_by_shift',
    'h_mission_control_area_uns','h_oee_progress_chart',
    'h_oee_progress_by_shift','h_oee_progress_with_teams','h_oee_score',
    'h_oee_score_shift_detail','h_oee_score_full','h_oee_score_teams',
    'h_production_orders_merged','h_production_orders',
    'h_production_orders_with_runtimes','h_equipment_chart',
    'h_equipment_chart_1day','h_single_period_equipment_chart',
    'h_total_production_chart')
ORDER BY relname;

\echo '=== sweep A verification: every legacy h_* name still resolves ==='
SELECT count(*) AS legacy_names_as_views
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'v'
  AND (relname LIKE 'h\_piot\_%' OR relname LIKE 'h\_%\_table%'
       OR relname ~ 'h_events_timeline[2-5]'
       OR relname LIKE 'h\_overview\_i\_%');
