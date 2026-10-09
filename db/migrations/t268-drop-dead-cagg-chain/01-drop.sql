-- t268 — necessity-audit Phase B: drop the DEAD equipment_metrics cagg chain +
-- equipment_categorical_10min.
--
-- The metrics chain (1min → 10min → 1hour → 1day) is self-referential: each grain
-- only feeds the next, and the terminus (1day) has ZERO readers (no serving fn, no
-- read-api grain map — which uses only agg_equipment_values_{1min,1hour} — no Superset
-- dataset [grep configs/superset = clean], no Go consumer). equipment_categorical_10min
-- is likewise a dead end (categorical_1min feeds it, nothing reads it). So 10min/1hour/
-- 1day + categorical_10min are pure materialization with no consumer. These are
-- real-time caggs with NO refresh policy (verified 0 jobs), so nothing to unschedule.
--
-- KEPT: equipment_metrics_1min (serving.mission_control_timeline) + equipment_categorical_1min
-- (feeds categorical_1hour) + equipment_categorical_1hour (serving.machine_speed/targets/…).
--
-- Drop in dependency order (dependents first): 1day → 1hour → 10min, then categorical_10min.
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_metrics_1day;
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_metrics_1hour;
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_metrics_10min;
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_categorical_10min;
