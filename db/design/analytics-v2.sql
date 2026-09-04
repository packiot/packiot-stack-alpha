-- ============================================================================
-- analytics_v2 — ground-up target metrics + serving layer (PROOF OF CONCEPT)
-- ============================================================================
-- Target: PostgreSQL 15 + TimescaleDB 2.27 (packiot_analytics).
-- Isolation: creates ONLY new objects in schema `analytics_v2`. Touches no
--   existing object. The base hypertable `public.equipment_values` already has
--   a cagg (agg_equipment_values_1min) so its invalidation trigger pre-exists —
--   adding these caggs registers catalog entries + internal materialization
--   hypertables only; it does not alter equipment_values.
-- Proven live 2026-09-04 on i-064bb36d1c454d861 (see analytics-v2-target-schema.md §Hardproof).
--
-- Teardown (fully reversible):
--   DROP MATERIALIZED VIEW analytics_v2.equipment_metrics_1hour;
--   DROP MATERIALIZED VIEW analytics_v2.equipment_metrics_10min;
--   DROP MATERIALIZED VIEW analytics_v2.equipment_metrics_1min;
--   DROP SCHEMA analytics_v2 CASCADE;
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS analytics_v2;

-- ----------------------------------------------------------------------------
-- METRICS LAYER — ONE hierarchical cagg family. All tiers share the SAME 6
-- grouping keys (bucket + equipment grain), so each higher tier is an EXACT
-- rollup of the tier below. avg speed is NEVER stored; instead we store the
-- decomposable partials sum(speed) + count(speed) so that at any tier
--   avg = sum(sum_speed) / sum(cnt_speed)  ==  avg(speed) over raw rows.
--
-- DESIGN DECISION (resolves 04_REVIEW_cagg_redesign_DECISION_NEEDED.sql):
--   The legacy agg_* family is NOT a hierarchy — agg_1min groups by 6 keys but
--   agg_10min/1hour group by ~20 (state/mode/id_order preserving), so 10min
--   cannot be built from 1min. The metrics family is deliberately a PURE
--   time-hierarchy on the equipment grain. Categorical context (state, mode,
--   id_production_order) is a SEPARATE concern (state-timeline / events), not a
--   grouping key of the numeric metrics rollup. This is what makes the tiers
--   telescope exactly (proven: 1593 buckets, 0 mismatches).
-- ----------------------------------------------------------------------------

-- Tier 1: 1-minute (built on RAW equipment_values)
CREATE MATERIALIZED VIEW analytics_v2.equipment_metrics_1min
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT
  time_bucket('1 minute', ts_value)   AS bucket,
  id_equipment, id_enterprise, id_site, id_area, tp_equipment,
  sum(net_production_incr)             AS sum_net,
  sum(gross_production_incr)           AS sum_gross,
  sum(scrap_incr)                      AS sum_scrap,
  sum(speed)                           AS sum_speed,   -- partial (numerator)
  count(speed)                         AS cnt_speed,   -- partial (denominator)
  count(*)                            AS cnt_rows,
  max(speed)                           AS max_speed,
  max(ideal_production_speed)          AS ideal_production_speed
FROM public.equipment_values
WHERE tp_equipment IS NOT NULL
GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
WITH NO DATA;

-- Tier 2: 10-minute (built ON tier 1 — hierarchical cagg-on-cagg)
CREATE MATERIALIZED VIEW analytics_v2.equipment_metrics_10min
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT
  time_bucket('10 minutes', bucket)   AS bucket,
  id_equipment, id_enterprise, id_site, id_area, tp_equipment,
  sum(sum_net)                         AS sum_net,
  sum(sum_gross)                       AS sum_gross,
  sum(sum_scrap)                       AS sum_scrap,
  sum(sum_speed)                       AS sum_speed,
  sum(cnt_speed)                       AS cnt_speed,
  sum(cnt_rows)                        AS cnt_rows,
  max(max_speed)                       AS max_speed,
  max(ideal_production_speed)          AS ideal_production_speed
FROM analytics_v2.equipment_metrics_1min
GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
WITH NO DATA;

-- Tier 3: 1-hour (built ON tier 2)
CREATE MATERIALIZED VIEW analytics_v2.equipment_metrics_1hour
WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
SELECT
  time_bucket('1 hour', bucket)       AS bucket,
  id_equipment, id_enterprise, id_site, id_area, tp_equipment,
  sum(sum_net)                         AS sum_net,
  sum(sum_gross)                       AS sum_gross,
  sum(sum_scrap)                       AS sum_scrap,
  sum(sum_speed)                       AS sum_speed,
  sum(cnt_speed)                       AS cnt_speed,
  sum(cnt_rows)                        AS cnt_rows,
  max(max_speed)                       AS max_speed,
  max(ideal_production_speed)          AS ideal_production_speed
FROM analytics_v2.equipment_metrics_10min
GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
WITH NO DATA;

-- Tier 4 (1-day) — same pattern on tier 3; omitted from the PoC materialization
-- but identical shape. Uncomment for production:
-- CREATE MATERIALIZED VIEW analytics_v2.equipment_metrics_1day
-- WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
-- SELECT time_bucket('1 day', bucket) AS bucket, id_equipment, id_enterprise,
--   id_site, id_area, tp_equipment, sum(sum_net) sum_net, sum(sum_gross) sum_gross,
--   sum(sum_scrap) sum_scrap, sum(sum_speed) sum_speed, sum(cnt_speed) cnt_speed,
--   sum(cnt_rows) cnt_rows, max(max_speed) max_speed,
--   max(ideal_production_speed) ideal_production_speed
-- FROM analytics_v2.equipment_metrics_1hour
-- GROUP BY 1, id_equipment, id_enterprise, id_site, id_area, tp_equipment
-- WITH NO DATA;

-- PoC materialization window (recent 14 days). Order matters: parent tiers read
-- their child's materialization, so refresh bottom-up.
-- CALL refresh_continuous_aggregate('analytics_v2.equipment_metrics_1min',  '2026-08-21 00:00+00', '2026-09-04 05:00+00');
-- CALL refresh_continuous_aggregate('analytics_v2.equipment_metrics_10min', '2026-08-21 00:00+00', '2026-09-04 05:00+00');
-- CALL refresh_continuous_aggregate('analytics_v2.equipment_metrics_1hour', '2026-08-21 00:00+00', '2026-09-04 05:00+00');

-- PRODUCTION refresh policies (continuous, incremental — replace the manual CALLs):
-- SELECT add_continuous_aggregate_policy('analytics_v2.equipment_metrics_1min',
--   start_offset => INTERVAL '3 hours', end_offset => INTERVAL '1 minute', schedule_interval => INTERVAL '1 minute');
-- SELECT add_continuous_aggregate_policy('analytics_v2.equipment_metrics_10min',
--   start_offset => INTERVAL '6 hours', end_offset => INTERVAL '10 minutes', schedule_interval => INTERVAL '10 minutes');
-- SELECT add_continuous_aggregate_policy('analytics_v2.equipment_metrics_1hour',
--   start_offset => INTERVAL '2 days', end_offset => INTERVAL '1 hour', schedule_interval => INTERVAL '1 hour');

-- ----------------------------------------------------------------------------
-- SERVING LAYER — security_invoker views so tenant RLS binds to the CALLER.
-- The base tables equipment_runtime_shift + equipments have FORCE ROW LEVEL
-- SECURITY with policy `is_all_tenant() OR id_enterprise = current_tenant()`,
-- where current_tenant() = current_setting('app.tenant_id') and -1 = all.
-- security_invoker=true (PG15) enforces that RLS against the querying role
-- (superset_ro / read-api role), NOT the view owner — the modern, safe pattern
-- that avoids the definer-view RLS-bypass footgun.
-- ----------------------------------------------------------------------------

-- oee_shift — reproduces bi.oee_shift. The Gold rollup (equipment_runtime_shift,
-- renamed equipment_oee_shift in the target model) is written by the stream-engine
-- Go worker; this view is the SERVING contract over it.
CREATE OR REPLACE VIEW analytics_v2.oee_shift WITH (security_invoker = true) AS
SELECT eq.id_enterprise, rs.id_equipment, eq.nm_equipment, rs.id_shift, rs.cd_shift,
       rs.ts_value, rs.ts_end, rs.oee, rs.oee_a, rs.oee_p, rs.oee_q,
       rs.gross, rs.net, rs.running_time,
       eq.nm_equipment::text || CASE eq.tp_equipment
         WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text
         WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
FROM public.equipment_runtime_shift rs
JOIN public.equipments eq ON eq.id_equipment = rs.id_equipment
WHERE rs.ts_value <= now() AND rs.running_time > 0;

-- equipment_speed — NEW target serving view on the metrics cagg. Per-minute
-- grain; speed is the CORRECT decomposable weighted mean sum_speed/cnt_speed.
CREATE OR REPLACE VIEW analytics_v2.equipment_speed WITH (security_invoker = true) AS
SELECT eq.id_enterprise, m.id_equipment, eq.nm_equipment, m.bucket AS ts_value,
       (m.sum_speed / NULLIF(m.cnt_speed, 0)) AS speed,
       m.max_speed AS plc_speed_max,
       eq.production_speed AS ideal_production_speed,
       m.sum_gross, m.sum_net, m.sum_scrap, m.cnt_rows, m.tp_equipment,
       eq.nm_equipment::text || CASE eq.tp_equipment
         WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text
         WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
FROM analytics_v2.equipment_metrics_1min m
JOIN public.equipments eq ON eq.id_equipment = m.id_equipment;

-- equipment_speed_raw — byte-identical reproduction of the CURRENT bi.equipment_speed
-- (raw per-sample serving view). Kept for exact backward-compat + equivalence proof.
CREATE OR REPLACE VIEW analytics_v2.equipment_speed_raw WITH (security_invoker = true) AS
SELECT eq.id_enterprise, ev.id_equipment, eq.nm_equipment, ev.ts_value,
  NULLIF(COALESCE(NULLIF(ev.speed, 0)::double precision,
    CASE WHEN COALESCE(ev.gross_production_incr, ev.net_production_incr, 0::real) > 0::double precision
      THEN COALESCE(NULLIF(ev.gross_production_incr, 0::double precision), ev.net_production_incr)
           / NULLIF(EXTRACT(epoch FROM ev.ts_value
               - lag(ev.ts_value) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_value)) / 60.0, 0::numeric)::double precision
      ELSE NULL::double precision END), 0::double precision) AS speed,
  ev.speed AS plc_speed, eq.production_speed AS ideal_production_speed,
  ev.id_shift, ev.id_production_order, ev.state, ev.mode,
  eq.nm_equipment::text || CASE eq.tp_equipment
    WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text
    WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
FROM public.equipment_values ev
JOIN public.equipments eq ON eq.id_equipment = ev.id_equipment;

-- Consumer grants (mirror the bi.* grant model).
GRANT USAGE ON SCHEMA analytics_v2 TO superset_ro, bi_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics_v2 TO superset_ro, bi_owner;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics_v2 GRANT SELECT ON TABLES TO superset_ro, bi_owner;
