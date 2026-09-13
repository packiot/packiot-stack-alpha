-- t261e — contract step of #261: drop the transient public event-table shim VIEWS
-- created by t261d, now that the deployed stream-engine flow runs EvSchema=silver
-- (flows.go flipped public→silver in PR #1217) and reads/writes the 4 event tables
-- directly in silver: data_quality_event (dq.go/silver.go), equipment_events_cpac_shadow
-- (cpac_deriver CPAC_EVENT_TARGET_TABLE), equipment_events_man/low_speed (reads).
-- edge-api (bare equipment_events_man, no search_path → silver-first default) and
-- read-api resolve to silver directly. The real tables live in silver; only these
-- pass-through shims remain in public.
-- Hardproof before running: pg_stat_statements reset post-deploy → 0 reads of
-- public.<event-table> across the live workload. Reversible (rollback recreates shims).
DROP VIEW IF EXISTS public.data_quality_event;
DROP VIEW IF EXISTS public.equipment_events_man;
DROP VIEW IF EXISTS public.equipment_events_cpac_shadow;
DROP VIEW IF EXISTS public.equipment_events_low_speed;
