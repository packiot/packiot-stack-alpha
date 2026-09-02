-- ADR-0045 G3 — packiot_shadow (F3) grain-table gap-fill (2026-08-13 residuals sweep).
--
-- The shift→week/month runtime grain tables were MISSING on the packiot_shadow
-- (F3) database → oeecloud-worker runtime-provision + runtime-rollup-unmetered
-- jobs failed (42P01 "does not exist", then 42P10 "no unique constraint for
-- ON CONFLICT"). These tables + their PK are defined for the MAIN DB in
-- edge-node-red/db/17-hasura-metadata-parity.sql (table) + 20-oee-engine-parity.sql
-- (PK, lines 1092/1922), but packiot_shadow provisioning never applied them.
-- This idempotent script captures the DDL so packiot_shadow is durably provisioned
-- (applied live to packiot_shadow + packiot on 2026-08-13).
--
--   docker ... psql -d packiot_shadow -f 0045-g3-packiot-shadow-grain-tables.sql
--
CREATE TABLE IF NOT EXISTS equipment_runtime_shift_1week (
    ts_value date,
    oee real,
    recalc_needed boolean,
    oee_p real,
    oee_a real,
    oee_q real,
    available_time integer,
    running_time integer,
    stopped_time integer,
    planned_downtime integer,
    ideal_production double precision,
    idle_time integer,
    idle_starved integer,
    idle_blocked integer,
    id_equipment integer,
    id_shift integer,
    id_shift_hour integer,
    id_team integer,
    duration integer,
    target double precision,
    target_customized boolean
);
CREATE TABLE IF NOT EXISTS equipment_runtime_shift_1month (
    ts_value date NOT NULL,
    oee real,
    recalc_needed boolean,
    oee_p real,
    oee_a real,
    oee_q real,
    available_time integer,
    running_time integer,
    stopped_time integer,
    planned_downtime integer,
    ideal_production double precision,
    idle_time integer,
    idle_starved integer,
    idle_blocked integer,
    id_equipment integer NOT NULL,
    id_shift integer NOT NULL,
    id_shift_hour integer,
    id_team integer,
    duration integer,
    target double precision,
    target_customized boolean
);

-- The runtime-provision fn upserts these with ON CONFLICT (id_equipment, ts_value,
-- id_shift), so the matching unique index is required.
CREATE UNIQUE INDEX IF NOT EXISTS equipment_runtime_shift_1week_pk
  ON public.equipment_runtime_shift_1week  (id_equipment, ts_value, id_shift);
CREATE UNIQUE INDEX IF NOT EXISTS equipment_runtime_shift_1month_pk
  ON public.equipment_runtime_shift_1month (id_equipment, ts_value, id_shift);
