-- RECORD of a one-off applied on staging 2026-10-01 (user-approved). The 09-14 GAP-1 twin producer
-- (feedback: bispharma_twin_gap1_direct_sparkplug) published SIMULATED counters for L01 members
-- 2000225-2000230 under the real Bispharma tenant: all of their rows 09-14 13:00 → 09-15 11:00 (the real box
-- was down — the twin was the only producer) and, 11:00 → 14:00 once the real box resumed, the rows whose
-- totalizer was the twin's (≥ 600k; real L01 ≤ 75k). 34,231 rows / 4.60M gross; backup
-- ops._bkp_bis_twin_silver_20261001. The 09-15 11/13/14 "all 105 equipments" hours were the REAL box resuming
-- (totalizers continue the pre-outage values) — kept. Follow-up: forced cagg refresh 09-14 13:00→09-15 15:00, then
-- the line hours recomputed with RunHourBackfill's own steps (bounds 10→20 d; day/week/month cascaded by the
-- engine). Result: L01 09-14 OEE 5.555 → 0 (no real data), 09-15 1.361 → 0.410, week 1.216 → 0.287.
-- user-approved 2026-10-01 ("do those 3"): purge the 09-14 GAP-1 twin producer's synthetic L01 rows from Bispharma (ent 5)
SET statement_timeout = '600s';
SET lock_timeout = '20s';
SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
BEGIN;
CREATE TEMP TABLE twin_rows ON COMMIT DROP AS
SELECT v.* FROM silver.equipment_values v
 WHERE v.id_enterprise = 5 AND v.id_equipment BETWEEN 2000225 AND 2000230
   AND ((v.ts_value >= '2026-09-14 13:00+00' AND v.ts_value < '2026-09-15 11:00+00')
     OR (v.ts_value >= '2026-09-15 11:00+00' AND v.ts_value < '2026-09-15 14:00+00' AND v.gross_production_val >= 600000));
SELECT 'to_purge', count(*), round(sum(gross_production_incr)::numeric) gross, round(sum(net_production_incr)::numeric) net, min(ts_value)::text, max(ts_value)::text FROM twin_rows;
CREATE TABLE ops._bkp_bis_twin_silver_20261001 AS SELECT * FROM twin_rows;
DELETE FROM silver.equipment_values v USING twin_rows t
 WHERE v.id_enterprise = 5 AND v.id_equipment = t.id_equipment AND v.ts_value = t.ts_value AND v.id_equipment BETWEEN 2000225 AND 2000230;
SELECT 'left_in_window_L01', count(*) FILTER (WHERE ts_value < '2026-09-15 11:00+00') before_11, count(*) FILTER (WHERE ts_value >= '2026-09-15 11:00+00' AND gross_production_val >= 600000) twin_after_11,
       count(*) FILTER (WHERE ts_value >= '2026-09-15 11:00+00') real_kept
  FROM silver.equipment_values WHERE id_enterprise = 5 AND id_equipment BETWEEN 2000225 AND 2000230 AND ts_value >= '2026-09-14 13:00+00' AND ts_value < '2026-09-15 14:00+00';
COMMIT;
