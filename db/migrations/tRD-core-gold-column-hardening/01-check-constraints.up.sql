-- tRD-core-gold-column-hardening — SAFE, additive, reversible.
-- Column-level redesign review of core + gold (packiot_analytics, STAGING).
-- Adds defense-in-depth CHECK constraints that MATCH existing data (verified 0 violations
-- before apply). No column semantics/types touched; zero producer/consumer changes required.
--
-- HARDPROOF (pre-apply, 2026-09-13 staging):
--   * gold oee bounds violations on the 4 tables lacking the CHECK: 0/0/0/0 each
--       area_oee_daily(1611), equipment_oee_monthly(1312),
--       equipment_oee_shift_weekly(5362), equipment_oee_shift_monthly(1532)
--     (the other 7 gold OEE tables already carry <tbl>_oee_bounds — this closes the gap.)
--   * core.production_orders.status distinct = {1,2,3,4} only (4/29/21345/4322)
--   * core.equipments.tp_equipment distinct = {1,3} (domain {1,2,3}; 2=sector currently unused)
--   * core.equipments.net_production_type distinct = {0,NULL}  (domain {0,1})
--   * core.enterprises.scrap_calc_type distinct = {1} (domain {0,1,2})
-- CHECK constraints pass on NULL, so nullable columns keep accepting NULL.

SET lock_timeout = '5s';

-- ---- gold: close the oee_bounds gap (mirror the 7 existing *_oee_bounds checks) ----
ALTER TABLE gold.area_oee_daily
  ADD CONSTRAINT area_oee_daily_oee_bounds CHECK (
    oee   >= 0 AND oee   <= 1 AND
    oee_a >= 0 AND oee_a <= 1 AND
    oee_p >= 0 AND oee_p <= 1 AND
    oee_q >= 0 AND oee_q <= 1);

ALTER TABLE gold.equipment_oee_monthly
  ADD CONSTRAINT equipment_oee_monthly_oee_bounds CHECK (
    oee   >= 0 AND oee   <= 1 AND
    oee_a >= 0 AND oee_a <= 1 AND
    oee_p >= 0 AND oee_p <= 1 AND
    oee_q >= 0 AND oee_q <= 1);

ALTER TABLE gold.equipment_oee_shift_weekly
  ADD CONSTRAINT equipment_oee_shift_weekly_oee_bounds CHECK (
    oee   >= 0 AND oee   <= 1 AND
    oee_a >= 0 AND oee_a <= 1 AND
    oee_p >= 0 AND oee_p <= 1 AND
    oee_q >= 0 AND oee_q <= 1);

ALTER TABLE gold.equipment_oee_shift_monthly
  ADD CONSTRAINT equipment_oee_shift_monthly_oee_bounds CHECK (
    oee   >= 0 AND oee   <= 1 AND
    oee_a >= 0 AND oee_a <= 1 AND
    oee_p >= 0 AND oee_p <= 1 AND
    oee_q >= 0 AND oee_q <= 1);

-- ---- core: pin the well-established magic-number domains (documented enums) ----
ALTER TABLE core.production_orders
  ADD CONSTRAINT production_orders_status_domain
  CHECK (status IN (1,2,3,4));            -- 1=available 2=running 3=finished 4=paused

-- core.equipments is a HOT table: the live stream-engine rollup holds AccessShareLock
-- on it for 60s+ per query, back-to-back, so a plain (validated) ADD CONSTRAINT cannot
-- win the brief ACCESS EXCLUSIVE lock (repeatedly hit lock_timeout on staging).
-- Lock-safe path: ADD ... NOT VALID (instant, catalog-only) then VALIDATE (Share-Update-
-- Exclusive, does not block reads/writes). Data already verified 0-violation, so both
-- steps are safe. Give NOT VALID a long lock_timeout so it queues ahead of new readers.
SET lock_timeout = '90s';
ALTER TABLE core.equipments
  ADD CONSTRAINT equipments_tp_equipment_domain
  CHECK (tp_equipment IN (1,2,3)) NOT VALID;        -- 1=machine 2=sector 3=line
ALTER TABLE core.equipments VALIDATE CONSTRAINT equipments_tp_equipment_domain;

ALTER TABLE core.equipments
  ADD CONSTRAINT equipments_net_production_type_domain
  CHECK (net_production_type IN (0,1)) NOT VALID;    -- 0=counters 1=scanned boxes
ALTER TABLE core.equipments VALIDATE CONSTRAINT equipments_net_production_type_domain;

ALTER TABLE core.enterprises
  ADD CONSTRAINT enterprises_scrap_calc_type_domain
  CHECK (scrap_calc_type IN (0,1,2));     -- 0/1=% of gross, 2=% of net
