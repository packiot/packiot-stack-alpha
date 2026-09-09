-- t239 Tier-1 · drop the 7 provably-dead legacy caggs + the orphaned OEE-teams fn.
-- (task #239; survey: docs/plans/t224-analytics-clean-schema-tail.md Item-5.)
--
-- Each has ZERO DB dependents (pg_depend, verified — DROP…RESTRICT is itself the
-- proof) and ZERO repo references (grep, non-test). agg_area_*/agg_site_* aggregate
-- raw equipment_values but are read by nothing (superseded, never wired to silver);
-- ca_equipment_boxes_1hour is empty (0 chunks, frozen watermark) and unreferenced.
-- Dropping a cagg auto-removes its refresh policy job. NOT hierarchical — no CASCADE.
--
-- NOT dropped (load-bearing — the #235 empty≠dead discipline): ca_agg_equipment_values_*
-- (live rollup engine), ca_discrete_changes_1s (ent4 CPAC deriver), ca_equipment_boxes_1s
-- + agg_equipment_values_* (SAP ent13 report + read-api /v1/query grains), and the
-- v_13_overview_* tables (read-api Neopac datasets). Those are the Tier-2/3 epic.
BEGIN;
DROP MATERIALIZED VIEW public.agg_area_values_1min;
DROP MATERIALIZED VIEW public.agg_area_values_10min;
DROP MATERIALIZED VIEW public.agg_area_values_1hour;
DROP MATERIALIZED VIEW public.agg_site_values_1min;
DROP MATERIALIZED VIEW public.agg_site_values_10min;
DROP MATERIALIZED VIEW public.agg_site_values_1hour;
DROP MATERIALIZED VIEW public.ca_equipment_boxes_1hour;

-- Orphaned: read-api's oee-score-teams dataset was repointed to serving.oee_score_by_team
-- (#218); this fn has 0 DB callers + 0 views + only an explanatory comment in datasets.go.
-- It was the last non-rollup consumer of ca_agg_equipment_values_1hour.
DROP FUNCTION public.h_piot_oee_score_with_teams(integer,text,text,text,text,text,timestamp with time zone,timestamp with time zone,text,text,boolean);
COMMIT;
