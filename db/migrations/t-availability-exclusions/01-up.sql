-- t-availability-exclusions — out-of-service windows + no-data/out-of-service time columns (2026-10-01)
--
-- Availability policy (agreed 2026-10-01): a line's time is RUNNING / STOPPED
-- (counts), OUT OF SERVICE (not planned production time: excluded from
-- available_time and from the target) or NO DATA (PLC unreadable: excluded from
-- available_time, kept in the target, shown as coverage). stream-engine
-- rollup/availability_exclusions.go writes the two new columns and the reduced
-- available_time; day/week/month and area/site sum them.
--
-- Additive + idempotent. Apply BEFORE the stream-engine that reads them
-- (AVAILABILITY_EXCLUSIONS_ENABLED defaults on). The gold tables are plain
-- tables, so ADD COLUMN ... DEFAULT 0 is metadata-only (no rewrite).
BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE IF NOT EXISTS config.equipment_out_of_service (
    id            bigserial   PRIMARY KEY,
    id_enterprise integer     NOT NULL,
    id_equipment  bigint      NOT NULL,
    period        tstzrange   NOT NULL,
    reason        text        NOT NULL,
    created_by    text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    text,
    updated_at    timestamptz,
    CONSTRAINT equipment_oos_period_ok CHECK (NOT isempty(period) AND lower(period) IS NOT NULL),
    CONSTRAINT equipment_oos_reason_ok CHECK (length(btrim(reason)) > 0),
    -- one window at a time per equipment: overlapping windows are a data-entry error
    CONSTRAINT equipment_oos_no_overlap EXCLUDE USING gist (id_equipment WITH =, period WITH &&)
);
CREATE INDEX IF NOT EXISTS equipment_oos_enterprise_idx ON config.equipment_out_of_service (id_enterprise);

COMMENT ON TABLE config.equipment_out_of_service IS
  'Out-of-service windows set by CS/customer (csadmin): the equipment (normally a LINE; covers its machines too) is not in use, so the period is excluded from available_time and from the production target. period upper NULL = until further notice.';
COMMENT ON COLUMN config.equipment_out_of_service.period IS 'Half-open [from, to) window; to NULL = open-ended (until further notice).';
COMMENT ON COLUMN config.equipment_out_of_service.reason IS 'Plain-language reason shown to users (e.g. "Line waiting for its PLC to be connected").';

ALTER TABLE config.equipment_out_of_service ENABLE ROW LEVEL SECURITY;
ALTER TABLE config.equipment_out_of_service FORCE  ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON config.equipment_out_of_service;
CREATE POLICY tenant_isolation ON config.equipment_out_of_service
    USING ((SELECT is_all_tenant()) OR id_enterprise = (SELECT current_tenant()));
GRANT SELECT ON config.equipment_out_of_service TO readapi_ro, bi_owner, cloudbeaver_ro;

COMMIT;

-- The column adds run ONE TABLE PER TRANSACTION with a short lock_timeout: a single
-- transaction over all 8 gold tables DEADLOCKED with the live rollup on staging
-- (2026-10-01 — it locks them in another order). Each add is metadata-only and
-- idempotent: if one times out, re-run this file until verify.sql reports 16.
SET lock_timeout = '3s';
ALTER TABLE gold.equipment_oee_hourly ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.equipment_oee_hourly.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).';
COMMENT ON COLUMN gold.equipment_oee_hourly.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.';
ALTER TABLE gold.equipment_oee_shift ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.equipment_oee_shift.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).';
COMMENT ON COLUMN gold.equipment_oee_shift.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.';
ALTER TABLE gold.equipment_oee_daily ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.equipment_oee_daily.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).';
COMMENT ON COLUMN gold.equipment_oee_daily.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.';
ALTER TABLE gold.equipment_oee_weekly ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.equipment_oee_weekly.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).';
COMMENT ON COLUMN gold.equipment_oee_weekly.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.';
ALTER TABLE gold.equipment_oee_monthly ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.equipment_oee_monthly.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).';
COMMENT ON COLUMN gold.equipment_oee_monthly.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.';
ALTER TABLE gold.area_oee_daily ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.area_oee_daily.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).';
COMMENT ON COLUMN gold.area_oee_daily.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.';
ALTER TABLE gold.area_oee_shift ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.area_oee_shift.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).';
COMMENT ON COLUMN gold.area_oee_shift.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.';
ALTER TABLE gold.site_oee_shift ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN gold.site_oee_shift.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).';
COMMENT ON COLUMN gold.site_oee_shift.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.';

