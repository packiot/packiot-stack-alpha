-- ADR-0012 Phase 3: writer-target tables for the live-data POC.
--
-- The Hasura metadata-parity stub (17-hasura-metadata-parity.sql) only
-- creates tables Hasura tracks — this excludes the RAW hypertables
-- oeecloud-worker writes to (equipment_values, uns_equipment_current_metrics)
-- because prod Hasura reads from the CAggs on top of these, not the raw
-- hypertables themselves.
--
-- For the live-data POC (source_type="refactored" → packiot_shadow), the
-- worker still needs to INSERT to equipment_values + uns_equipment_current_metrics.
-- This script creates them as REGULAR tables (not hypertables — the
-- sandbox POC doesn't need chunking, just structural parity for the write path).
--
-- Column shapes match prod tsp12 (`packiot40`), captured 2026-07-01
-- via SELECT on information_schema.columns.

CREATE TABLE IF NOT EXISTS public.equipment_values (
    ts_value                       timestamp with time zone NOT NULL,
    id_enterprise                  integer NOT NULL,
    id_site                        integer NOT NULL,
    id_area                        integer NOT NULL,
    id_equipment                   integer NOT NULL,
    net_production_incr            double precision,
    gross_production_incr          double precision,
    scrap_incr                     double precision,
    speed                          real,
    id_order                       character varying,
    conversion_factor              real,
    number_cavities                integer,
    faults                         jsonb,
    analogs                        jsonb,
    signal_quality                 smallint,
    net_production_val             double precision,
    gross_production_val           double precision,
    scrap_val                      double precision,
    id_shift                       integer,
    id_team                        integer,
    id_shift_hour                  integer,
    box_code                       character varying,
    transaction_code               character varying,
    state                          integer,
    mode                           integer,
    id_production_order            bigint,
    ts_value_production            date,
    id_equipment_line_infeed       integer,
    id_equipment_line_outfeed      integer,
    net_production_incr_quality    smallint,
    gross_production_incr_quality  smallint,
    scrap_incr_quality             smallint,
    speed_quality                  smallint,
    id_order_quality               smallint,
    conversion_factor_quality      smallint,
    number_cavities_quality        smallint,
    net_production_val_quality     smallint,
    gross_production_val_quality   smallint,
    scrap_val_quality              smallint,
    id_shift_quality               smallint,
    state_quality                  smallint,
    mode_quality                   smallint,
    id_production_order_quality    smallint,
    ts_value_production_quality    smallint,
    id_equipment_line_connected    integer,
    position_in_equipment_line     smallint,
    is_equipment_line_infeed       smallint,
    is_equipment_line_outfeed      smallint,
    process_scrap_incr             double precision,
    process_scrap_val              double precision,
    process_scrap_incr_quality     smallint,
    process_scrap_val_quality      smallint,
    tp_equipment                   smallint,
    sub_mode                       character varying,
    ideal_production_speed         integer,
    check_number                   bigint,
    PRIMARY KEY (ts_value, id_equipment)
);
CREATE INDEX IF NOT EXISTS equipment_values_id_equipment_ts_idx ON public.equipment_values (id_equipment, ts_value DESC);

CREATE TABLE IF NOT EXISTS public.uns_equipment_current_metrics (
    id_equipment integer PRIMARY KEY,
    ts_value     timestamp with time zone NOT NULL,
    payload      jsonb
);

-- packml_register — the topic→equipment resolver. The worker uses the
-- MAIN pool for resolver lookups (not the shadow pool), so this table
-- exists on `packiot` DB and is NOT needed on `packiot_shadow`. Skipping.

\echo ''
\echo '=== packiot_shadow writer-target tables created ==='
SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename IN ('equipment_values','uns_equipment_current_metrics') ORDER BY tablename;
