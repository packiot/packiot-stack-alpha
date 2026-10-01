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

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['equipment_oee_hourly', 'equipment_oee_shift', 'equipment_oee_daily',
                           'equipment_oee_weekly', 'equipment_oee_monthly',
                           'area_oee_daily', 'area_oee_shift', 'site_oee_shift'] LOOP
    EXECUTE format('ALTER TABLE gold.%I ADD COLUMN IF NOT EXISTS no_data_time integer NOT NULL DEFAULT 0', t);
    EXECUTE format('ALTER TABLE gold.%I ADD COLUMN IF NOT EXISTS out_of_service_time integer NOT NULL DEFAULT 0', t);
    EXECUTE format($c$COMMENT ON COLUMN gold.%I.no_data_time IS 'Seconds the PLC could not be read (no data): excluded from available_time, kept in the target. Coverage = 1 - no_data_time / (available_time + planned_downtime + no_data_time).'$c$, t);
    EXECUTE format($c$COMMENT ON COLUMN gold.%I.out_of_service_time IS 'Seconds inside an out-of-service window (config.equipment_out_of_service): excluded from available_time and from the target.'$c$, t);
  END LOOP;
END $$;

COMMIT;
