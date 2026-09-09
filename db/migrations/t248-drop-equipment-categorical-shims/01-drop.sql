-- t248 CONTRACT — drop the public.equipment_categorical_{1min,1hour} shim views.
-- These were created by t239 (01-expand-views.sql) SOLELY to back the OEE rollup
-- while it still read via EvSchema=public. #248 (PRs #1187/#1188) repointed the
-- rollup + events engine to read silver.equipment_categorical DIRECTLY (deriving
-- speed = sum_speed/NULLIF(cnt_speed,0) inline, since silver has no scalar speed).
-- Audit before drop: 0 DB dependents; only live consumers are stream-engine + read-api,
-- both now on silver.*. Applied live on staging 2026-09-09; rollup verified healthy after.
-- The BROADER medallion shims (equipment_values/equipment_oee_*/production_orders/
-- production_orders_runtime/area_oee_shift/equipment_events) are NOT dropped here —
-- analytics-sync + mirror-worker still consume some, and Superset/Hasura need auditing
-- (follow-up: org-wide medallion shim drop).
DROP VIEW IF EXISTS public.equipment_categorical_1min;
DROP VIEW IF EXISTS public.equipment_categorical_1hour;
