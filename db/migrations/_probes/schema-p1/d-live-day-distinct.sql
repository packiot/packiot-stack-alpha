-- schema-p1 probe (d): silver.area_live_day / silver.equipment_live_day — constant-zero feed or genuinely uniform?
-- pg_stats showed n_distinct = 1 for every metric column (oee, gross, net, target, running_time …). READ-ONLY,
-- aggregates only: per metric column total rows, non-NULL, distinct values, min, max, and how many are exactly 0.
-- If distinct = 1 and min = max = 0 → the live-day feed writes zeros (feed bug: stream-engine uns/current_rest.go);
-- if distinct > 1 → pg_stats was stale/sampled. Tiny tables (one row per area / equipment).
\set ON_ERROR_STOP 1
SET default_transaction_read_only = on;
SET statement_timeout = '60s';
SET lock_timeout = '2s';

SELECT 'D0 area_live_day rows|areas|distinct begin_time|min begin_time|max begin_time',
       count(*), count(DISTINCT id_area), count(DISTINCT begin_time), min(begin_time), max(begin_time)
  FROM silver.area_live_day;

SELECT 'D1 area_live_day column|rows|non-NULL|distinct|min|max|=0', c.col, count(*), count(c.v), count(DISTINCT c.v), min(c.v), max(c.v),
       count(*) FILTER (WHERE c.v = 0)
  FROM silver.area_live_day a
  CROSS JOIN LATERAL (VALUES
    ('oee', a.oee::float8), ('oee_a', a.oee_a), ('oee_p', a.oee_p), ('oee_q', a.oee_q),
    ('gross_production', a.gross_production), ('net_production', a.net_production), ('scrap', a.scrap),
    ('target', a.target), ('idle_time', a.idle_time), ('elapsed_time', a.elapsed_time),
    ('idle_blocked', a.idle_blocked), ('idle_starved', a.idle_starved), ('running_time', a.running_time),
    ('stopped_time', a.stopped_time), ('available_time', a.available_time), ('planned_downtime', a.planned_downtime),
    ('ideal_production', a.ideal_production), ('proportional_target', a.proportional_target),
    ('proportional_ideal_production', a.proportional_ideal_production)) AS c(col, v)
 GROUP BY c.col ORDER BY c.col;

SELECT 'D2 equipment_live_day rows|equipments|distinct begin_time|min begin_time|max begin_time|min last_updated|max last_updated',
       count(*), count(DISTINCT id_equipment), count(DISTINCT begin_time), min(begin_time), max(begin_time),
       min(last_updated), max(last_updated)
  FROM silver.equipment_live_day;

SELECT 'D3 equipment_live_day column|rows|non-NULL|distinct|min|max|=0', c.col, count(*), count(c.v), count(DISTINCT c.v), min(c.v), max(c.v),
       count(*) FILTER (WHERE c.v = 0)
  FROM silver.equipment_live_day e
  CROSS JOIN LATERAL (VALUES
    ('oee', e.oee::float8), ('oee_a', e.oee_a), ('oee_p', e.oee_p), ('oee_q', e.oee_q),
    ('gross_production', e.gross_production), ('net_production', e.net_production), ('scrap', e.scrap),
    ('speed', e.speed), ('target', e.target), ('idle_time', e.idle_time), ('elapsed_time', e.elapsed_time),
    ('idle_blocked', e.idle_blocked), ('idle_starved', e.idle_starved), ('running_time', e.running_time),
    ('stopped_time', e.stopped_time), ('available_time', e.available_time), ('planned_downtime', e.planned_downtime),
    ('ideal_production', e.ideal_production), ('proportional_target', e.proportional_target),
    ('proportional_ideal_production', e.proportional_ideal_production),
    ('gross_production_exec_mode', e.gross_production_exec_mode), ('net_production_exec_mode', e.net_production_exec_mode),
    ('scrap_exec_mode', e.scrap_exec_mode)) AS c(col, v)
 GROUP BY c.col ORDER BY c.col;

-- per tenant: is it every tenant or one feed? (non-NULL oee rows | distinct oee | rows with any non-zero metric)
SELECT 'D4 equipment_live_day per tenant: id_enterprise|rows|non-NULL oee|distinct oee|rows with any non-zero metric',
       eq.id_enterprise, count(*), count(e.oee), count(DISTINCT e.oee),
       count(*) FILTER (WHERE coalesce(e.oee, 0) <> 0 OR coalesce(e.gross_production, 0) <> 0
                           OR coalesce(e.net_production, 0) <> 0 OR coalesce(e.running_time, 0) <> 0)
  FROM silver.equipment_live_day e JOIN core.equipments eq USING (id_equipment)
 GROUP BY eq.id_enterprise ORDER BY eq.id_enterprise;
