-- sandbox-mirror-silver-windows.sql — one-off: copy CPACK's REPAIRED silver windows onto the
-- SANDBOX-CPACK twin (2026-09-30, staging).
--
-- The twin's silver is its own fanout-fed copy of CPACK's live stream, so it shares CPACK's
-- feed defects but NOT the repairs that were applied to ent 3 only:
--   * hole 2026-08-27 17:58 → 09-01 00:30 (no silver for ANY tenant; CPACK backfilled from
--     legacy, #1498) — the twin is still empty there;
--   * L8-PTH / L10-PTH 2026-09-01 00:30 → 09-29 23:00 (factory tee saturates at 32767; CPACK's
--     74/78 replaced from legacy) — the twin's 2000074/2000078 still hold the saturated half.
-- Replace those windows in the twin with CPACK's rows remapped (entity ids +2,000,000,
-- enterprise 2000003), then refresh the 7 silver caggs over both windows.
-- Rollback: DELETE the twin's rows in the windows (they were empty / saturated before).
\set ON_ERROR_STOP 1
SET statement_timeout = '30min';
SET lock_timeout = '20s';
BEGIN;
SELECT now() AS applied_at \gset
\echo applied_at: :applied_at
CREATE TEMP TABLE w (lo timestamptz, hi timestamptz, eqs int[]) ON COMMIT DROP;
INSERT INTO w VALUES ('2026-08-27 17:58+00', '2026-09-01 00:30+00', NULL),          -- every CPACK equipment
                     ('2026-09-01 00:30+00', '2026-09-29 23:00+00', '{74,78}');     -- the PTH replace
SELECT 'before_twin', w.lo, count(v.*) FROM w LEFT JOIN silver.equipment_values v
    ON v.id_enterprise = 2000003 AND v.ts_value >= w.lo AND v.ts_value < w.hi
   AND (w.eqs IS NULL OR v.id_equipment - 2000000 = ANY (w.eqs)) GROUP BY 2 ORDER BY 2;
DELETE FROM silver.equipment_values v USING w
 WHERE v.id_enterprise = 2000003 AND v.ts_value >= w.lo AND v.ts_value < w.hi
   AND (w.eqs IS NULL OR v.id_equipment - 2000000 = ANY (w.eqs));
INSERT INTO silver.equipment_values
SELECT (jsonb_populate_record(NULL::silver.equipment_values, to_jsonb(x) || jsonb_build_object(
        'id_enterprise', 2000003, 'id_equipment', x.id_equipment + 2000000,
        'id_site', x.id_site + 2000000, 'id_area', x.id_area + 2000000,
        'id_equipment_line_infeed',    x.id_equipment_line_infeed + 2000000,
        'id_equipment_line_outfeed',   x.id_equipment_line_outfeed + 2000000,
        'id_equipment_line_connected', x.id_equipment_line_connected + 2000000,
        'id_production_order', NULL, 'id_shift', x.id_shift + 2000000, 'id_shift_hour', x.id_shift_hour + 2000000,
        'ingested_at', now()))).*
  FROM silver.equipment_values x JOIN w ON x.ts_value >= w.lo AND x.ts_value < w.hi
 WHERE x.id_enterprise = 3 AND (w.eqs IS NULL OR x.id_equipment = ANY (w.eqs));
SELECT 'after', w.lo, count(v.*) FILTER (WHERE v.id_enterprise = 2000003) twin, count(v.*) FILTER (WHERE v.id_enterprise = 3) cpack,
       round(sum(v.gross_production_incr) FILTER (WHERE v.id_enterprise = 2000003)) twin_gross,
       round(sum(v.gross_production_incr) FILTER (WHERE v.id_enterprise = 3)) cpack_gross
  FROM w JOIN silver.equipment_values v ON v.id_enterprise IN (3, 2000003) AND v.ts_value >= w.lo AND v.ts_value < w.hi
   AND (w.eqs IS NULL OR (v.id_equipment % 2000000) = ANY (w.eqs)) GROUP BY 2 ORDER BY 2;
COMMIT;
CALL refresh_continuous_aggregate('silver.ca_discrete_changes_1s',     '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.ca_equipment_boxes_1s',      '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.agg_equipment_values_1min',  '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_metrics_1min',     '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1min', '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.agg_equipment_values_1hour', '2026-08-27 17:00+00', '2026-09-30 00:00+00');
CALL refresh_continuous_aggregate('silver.equipment_categorical_1hour','2026-08-27 17:00+00', '2026-09-30 00:00+00');
