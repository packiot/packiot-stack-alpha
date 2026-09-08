-- P3 — silver categorical companion family (Decision #1)
-- ============================================================================
-- The 5 serving fns (oee_score_by_team, single_period_by_team[_v4], targets,
-- overview_production_chart) read the CATEGORICAL cagg ca_agg_equipment_values_*
-- (grain: equipment x time x {state,mode,id_order,conversion_factor,
-- number_cavities,signal_quality,id_shift,id_team,id_shift_hour,
-- id_production_order,ts_value_production,ideal_production_speed}). silver's
-- numeric family deliberately drops those categorical dims, so those 5 fns
-- cannot repoint to silver.equipment_metrics_*. This file builds a CLEAN
-- categorical companion that:
--   * carries the FULL ca_agg key set (so it is a byte-grain drop-in), and
--   * uses ca_agg's VERBATIM float4 sum()/max() expressions + 1min->1hour
--     structure (bit-exact to ca_agg -> symdiff-0 by construction), but
--   * FIXES the non-telescoping avg(speed) -> decomposable sum_speed/cnt_speed
--     (+cnt_rows) so every tier telescopes (higher tier = sum of lower).
-- Column names for the keys + *_incr + *_val MATCH ca_agg exactly, so the
-- serving repoint is a pure FROM-target swap.
--
-- PRECISION: partials are float8 (cast RAW ::double precision in tier-1),
-- IDENTICAL to the silver.equipment_metrics_* family (P3 pre-fix, file 10).
-- This makes the companion EXACTLY RAW-equivalent (a cagg on float8 is the true
-- sum); the residual vs the legacy float4 ca_agg (~3.6e-7 rel = ~3 float4 ULP)
-- is the LEGACY's float4 sum-order rounding, not a companion error. Consistent
-- precision across the whole silver medallion.
-- ============================================================================

DROP MATERIALIZED VIEW IF EXISTS silver.equipment_categorical_1hour CASCADE;
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_categorical_10min CASCADE;
DROP MATERIALIZED VIEW IF EXISTS silver.equipment_categorical_1min  CASCADE;

-- ---- tier 1: 1min on RAW equipment_values (mirrors ca_agg_equipment_values_1min) ----
CREATE MATERIALIZED VIEW silver.equipment_categorical_1min
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket(INTERVAL '1 minute', ev.ts_value) AS ts_value,
    ev.id_equipment,
    ev.id_enterprise,
    ev.id_site,
    ev.id_area,
    ev.tp_equipment,
    ev.state,
    ev.mode,
    ev.id_order,
    ev.conversion_factor,
    ev.number_cavities,
    ev.signal_quality,
    ev.id_shift,
    ev.id_team,
    ev.id_shift_hour,
    ev.id_production_order,
    ev.ts_value_production,
    ev.ideal_production_speed,
    sum((ev.net_production_incr)::double precision)   AS net_production_incr,
    sum((ev.gross_production_incr)::double precision) AS gross_production_incr,
    sum((ev.scrap_incr)::double precision)            AS scrap_incr,
    sum((ev.speed)::double precision)                 AS sum_speed,
    count(ev.speed)               AS cnt_speed,
    count(*)                      AS cnt_rows,
    max((ev.net_production_val)::double precision)    AS net_production_val,
    max((ev.gross_production_val)::double precision)  AS gross_production_val,
    max((ev.scrap_val)::double precision)             AS scrap_val
FROM equipment_values ev
GROUP BY
    time_bucket(INTERVAL '1 minute', ev.ts_value),
    ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area, ev.tp_equipment,
    ev.state, ev.mode, ev.id_order, ev.conversion_factor, ev.number_cavities,
    ev.signal_quality, ev.id_shift, ev.id_team, ev.id_shift_hour,
    ev.id_production_order, ev.ts_value_production, ev.ideal_production_speed
WITH NO DATA;

-- ---- tier 2: 10min rolled up from 1min (telescoping) ----
CREATE MATERIALIZED VIEW silver.equipment_categorical_10min
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket(INTERVAL '10 minutes', m.ts_value) AS ts_value,
    m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment,
    m.state, m.mode, m.id_order, m.conversion_factor, m.number_cavities,
    m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour,
    m.id_production_order, m.ts_value_production, m.ideal_production_speed,
    sum(m.net_production_incr)   AS net_production_incr,
    sum(m.gross_production_incr) AS gross_production_incr,
    sum(m.scrap_incr)            AS scrap_incr,
    sum(m.sum_speed)             AS sum_speed,
    sum(m.cnt_speed)             AS cnt_speed,
    sum(m.cnt_rows)              AS cnt_rows,
    max(m.net_production_val)    AS net_production_val,
    max(m.gross_production_val)  AS gross_production_val,
    max(m.scrap_val)             AS scrap_val
FROM silver.equipment_categorical_1min m
GROUP BY
    time_bucket(INTERVAL '10 minutes', m.ts_value),
    m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment,
    m.state, m.mode, m.id_order, m.conversion_factor, m.number_cavities,
    m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour,
    m.id_production_order, m.ts_value_production, m.ideal_production_speed
WITH NO DATA;

-- ---- tier 3: 1hour rolled up from 1min (mirrors ca_agg_equipment_values_1hour
--             structure exactly -> bit-exact sums; telescopes from 10min too) ----
CREATE MATERIALIZED VIEW silver.equipment_categorical_1hour
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket(INTERVAL '1 hour', m.ts_value) AS ts_value,
    m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment,
    m.state, m.mode, m.id_order, m.conversion_factor, m.number_cavities,
    m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour,
    m.id_production_order, m.ts_value_production, m.ideal_production_speed,
    sum(m.net_production_incr)   AS net_production_incr,
    sum(m.gross_production_incr) AS gross_production_incr,
    sum(m.scrap_incr)            AS scrap_incr,
    sum(m.sum_speed)             AS sum_speed,
    sum(m.cnt_speed)             AS cnt_speed,
    sum(m.cnt_rows)              AS cnt_rows,
    max(m.net_production_val)    AS net_production_val,
    max(m.gross_production_val)  AS gross_production_val,
    max(m.scrap_val)             AS scrap_val
FROM silver.equipment_categorical_1min m
GROUP BY
    time_bucket(INTERVAL '1 hour', m.ts_value),
    m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment,
    m.state, m.mode, m.id_order, m.conversion_factor, m.number_cavities,
    m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour,
    m.id_production_order, m.ts_value_production, m.ideal_production_speed
WITH NO DATA;
