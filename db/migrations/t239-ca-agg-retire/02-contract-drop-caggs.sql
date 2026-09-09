-- t239 CONTRACT — drop the retired ca_agg chain AFTER the renamed stream-engine
-- deploys + OEE before/after parity is verified. Nothing live reads these (repo-wide
-- audit: only stream-engine, now repointed; read-api already reads silver; port-parity
-- is a retired F2 comparator tool). DB deps = only the caggs' own internal TS views.
-- ca_agg_1hour is hierarchical over ca_agg_1min → drop 1hour first.
DROP MATERIALIZED VIEW IF EXISTS public.ca_agg_equipment_values_1hour;
DROP MATERIALIZED VIEW IF EXISTS public.ca_agg_equipment_values_1min;
