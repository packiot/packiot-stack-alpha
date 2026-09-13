-- t261c — contract step of #261: drop the transient public cagg shim VIEWS created
-- by t261b, now that the deployed stream-engine reads the caggs directly from silver
-- (deriver→SilverSchema, uns→GrainSchema) and read-api resolves them via its
-- silver-first search_path. The real caggs live in silver; only these pass-through
-- shims remain in public. Hardproof before running: pg_stat_statements reset post-
-- deploy → 0 reads of public.<cagg>. Reversible (rollback recreates the shims).
DROP VIEW IF EXISTS public.agg_equipment_values_1min;
DROP VIEW IF EXISTS public.agg_equipment_values_1hour;
DROP VIEW IF EXISTS public.ca_discrete_changes_1s;
DROP VIEW IF EXISTS public.ca_equipment_boxes_1s;
