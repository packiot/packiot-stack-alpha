-- 10-f3-timescale-supplement.sql — the TimescaleDB objects a plain pg_dump of
-- packiot_analytics CANNOT restore (caggs dump as views over
-- _timescaledb_internal._materialized_hypertable_NN, absent on a fresh DB).
-- Applied AFTER 00-*-schema.sql (base tables) and 05-f3-cagg-agg.sql (agg_* tier
-- + equipment_values hypertable, from 0012-f3-cagg-layer.sql). Adds the remaining
-- raw hypertables + the ca_* cagg tier. Defs introspected SELECT-only from live
-- packiot_analytics (2026-07-27). materialized_only=false = realtime cagg (prod).
SET statement_timeout = 0;

-- ── remaining raw hypertables (equipment_values done by 05) ───────────────────
SELECT create_hypertable('public.equipment_events',     'ts_event', chunk_time_interval => INTERVAL '1 day',  migrate_data => true, if_not_exists => true);
SELECT create_hypertable('public.equipment_values_raw', 'ts_value', chunk_time_interval => INTERVAL '7 days', migrate_data => true, if_not_exists => true);
SELECT create_hypertable('public.equipment_events_raw', 'ts_event', chunk_time_interval => INTERVAL '7 days', migrate_data => true, if_not_exists => true);

-- ── ca_* continuous-aggregate tier (dependency-ordered: bases before rollups) ──


-- ===== ca_discrete_changes_1s =====
CREATE MATERIALIZED VIEW public.ca_discrete_changes_1s WITH (timescaledb.continuous, timescaledb.materialized_only=false) AS
 SELECT time_bucket('00:00:01'::interval, equipment_values.ts_value) AS ts_value,
    equipment_values.id_equipment,
    equipment_values.id_enterprise,
    equipment_values.id_site,
    equipment_values.id_area,
    equipment_values.state,
    equipment_values.mode,
    equipment_values.id_order,
    equipment_values.id_production_order,
    equipment_values.conversion_factor,
    equipment_values.number_cavities,
    equipment_values.ts_value_production,
    equipment_values.id_shift,
    equipment_values.id_team,
    equipment_values.id_shift_hour,
    equipment_values.sub_mode,
    equipment_values.ideal_production_speed
   FROM equipment_values
  WHERE (NOT ((equipment_values.state IS NULL) AND (equipment_values.mode IS NULL) AND (equipment_values.id_order IS NULL) AND (equipment_values.id_production_order IS NULL) AND (equipment_values.conversion_factor IS NULL) AND (equipment_values.number_cavities IS NULL) AND (equipment_values.ts_value_production IS NULL) AND (equipment_values.id_shift IS NULL) AND (equipment_values.id_team IS NULL) AND (equipment_values.id_shift_hour IS NULL) AND (equipment_values.sub_mode IS NULL) AND (equipment_values.ideal_production_speed IS NULL)))
  GROUP BY (time_bucket('00:00:01'::interval, equipment_values.ts_value)), equipment_values.id_equipment, equipment_values.id_enterprise, equipment_values.id_site, equipment_values.id_area, equipment_values.state, equipment_values.mode, equipment_values.id_order, equipment_values.id_production_order, equipment_values.conversion_factor, equipment_values.number_cavities, equipment_values.ts_value_production, equipment_values.id_shift, equipment_values.id_team, equipment_values.id_shift_hour, equipment_values.sub_mode, equipment_values.ideal_production_speed
WITH NO DATA;

-- ===== ca_equipment_boxes_1s =====
CREATE MATERIALIZED VIEW public.ca_equipment_boxes_1s WITH (timescaledb.continuous, timescaledb.materialized_only=false) AS
 SELECT time_bucket('00:00:01'::interval, ev.ts_value) AS ts_value,
    ((ev.analogs -> 'Label'::text) ->> 'job'::text) AS id_order,
    ev.id_equipment,
    ev.id_area,
    ev.id_site,
    ev.id_enterprise,
    sum((((ev.analogs -> 'Label'::text) ->> 'value'::text))::double precision) AS net_production,
    count((((ev.analogs -> 'Label'::text) ->> 'value'::text))::integer) AS qty
   FROM equipment_values ev
  WHERE ((ev.analogs IS NOT NULL) AND (ev.analogs ? 'Label'::text))
  GROUP BY (time_bucket('00:00:01'::interval, ev.ts_value)), ((ev.analogs -> 'Label'::text) ->> 'job'::text), ev.id_equipment, ev.id_area, ev.id_site, ev.id_enterprise
WITH NO DATA;

-- ===== ca_agg_equipment_values_1min =====
CREATE MATERIALIZED VIEW public.ca_agg_equipment_values_1min WITH (timescaledb.continuous, timescaledb.materialized_only=false) AS
 SELECT time_bucket('00:01:00'::interval, ev.ts_value) AS ts_value,
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
    avg(ev.speed) AS speed,
    sum(ev.net_production_incr) AS net_production_incr,
    sum(ev.gross_production_incr) AS gross_production_incr,
    sum(ev.scrap_incr) AS scrap_incr,
    max(ev.net_production_val) AS net_production_val,
    max(ev.gross_production_val) AS gross_production_val,
    max(ev.scrap_val) AS scrap_val
   FROM equipment_values ev
  GROUP BY (time_bucket('00:01:00'::interval, ev.ts_value)), ev.id_equipment, ev.id_enterprise, ev.id_site, ev.id_area, ev.tp_equipment, ev.state, ev.mode, ev.id_order, ev.conversion_factor, ev.number_cavities, ev.signal_quality, ev.id_shift, ev.id_team, ev.id_shift_hour, ev.id_production_order, ev.ts_value_production, ev.ideal_production_speed
WITH NO DATA;

-- ===== ca_equipment_boxes_1hour =====
CREATE MATERIALIZED VIEW public.ca_equipment_boxes_1hour WITH (timescaledb.continuous, timescaledb.materialized_only=false) AS
 SELECT time_bucket('01:00:00'::interval, ev.ts_value) AS ts_value,
    ((ev.analogs -> 'Label'::text) ->> 'job'::text) AS id_order,
    ev.id_equipment,
    ev.id_area,
    ev.id_site,
    ev.id_enterprise,
    sum((((ev.analogs -> 'Label'::text) ->> 'value'::text))::double precision) AS net_production,
    count((((ev.analogs -> 'Label'::text) ->> 'value'::text))::integer) AS qty
   FROM equipment_values ev
  WHERE ((ev.analogs IS NOT NULL) AND (ev.analogs ? 'Label'::text))
  GROUP BY (time_bucket('01:00:00'::interval, ev.ts_value)), ((ev.analogs -> 'Label'::text) ->> 'job'::text), ev.id_equipment, ev.id_area, ev.id_site, ev.id_enterprise
WITH NO DATA;

-- ===== ca_agg_equipment_values_1hour =====
CREATE MATERIALIZED VIEW public.ca_agg_equipment_values_1hour WITH (timescaledb.continuous, timescaledb.materialized_only=false) AS
 SELECT time_bucket('01:00:00'::interval, m.ts_value) AS ts_value,
    m.id_equipment,
    m.id_enterprise,
    m.id_site,
    m.id_area,
    m.tp_equipment,
    m.state,
    m.mode,
    avg(m.speed) AS speed,
    (count(*) * 60) AS duration,
    m.id_order,
    m.conversion_factor,
    m.number_cavities,
    m.signal_quality,
    m.id_shift,
    m.id_team,
    m.id_shift_hour,
    m.id_production_order,
    m.ts_value_production,
    m.ideal_production_speed,
    sum(m.net_production_incr) AS net_production_incr,
    sum(m.gross_production_incr) AS gross_production_incr,
    sum(m.scrap_incr) AS scrap_incr,
    max(m.net_production_val) AS net_production_val,
    max(m.gross_production_val) AS gross_production_val,
    max(m.scrap_val) AS scrap_val
   FROM ca_agg_equipment_values_1min m
  GROUP BY (time_bucket('01:00:00'::interval, m.ts_value)), m.id_equipment, m.id_enterprise, m.id_site, m.id_area, m.tp_equipment, m.state, m.mode, m.id_order, m.conversion_factor, m.number_cavities, m.signal_quality, m.id_shift, m.id_team, m.id_shift_hour, m.id_production_order, m.ts_value_production, m.ideal_production_speed
WITH NO DATA;


-- ══════════════════════════════════════════════════════════════════════════════
-- ADR-0036 B1 — Bronze raw immutability + compression + 2-year retention.
-- Folded from migration docs/adr/reference/migrations/0036-b1-bronze-raw-
-- immutability.sql so a FRESH F3 bootstrap reproduces the immutable, multi-year
-- Bronze landing zone (single source of truth). The _raw hypertables were created
-- above (lines 12-13). See that migration's header for the full rationale; the
-- load-bearing point: the DB writer is a SUPERUSER, so REVOKE is silently useless
-- — immutability MUST be a RAISEing BEFORE UPDATE OR DELETE trigger. drop_chunks
-- retention drops whole chunks via DDL (not row DELETE), so the FOR EACH ROW guard
-- never fires on it.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.bronze_raw_no_mutate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION
        'Bronze raw table %.% is append-only (attempted %); corrections are new appended rows, never in-place edits',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$$;

DROP TRIGGER IF EXISTS trg_equipment_values_raw_no_mutate ON public.equipment_values_raw;
CREATE TRIGGER trg_equipment_values_raw_no_mutate
    BEFORE UPDATE OR DELETE ON public.equipment_values_raw
    FOR EACH ROW EXECUTE FUNCTION public.bronze_raw_no_mutate();

DROP TRIGGER IF EXISTS trg_equipment_events_raw_no_mutate ON public.equipment_events_raw;
CREATE TRIGGER trg_equipment_events_raw_no_mutate
    BEFORE UPDATE OR DELETE ON public.equipment_events_raw
    FOR EACH ROW EXECUTE FUNCTION public.bronze_raw_no_mutate();

-- Columnstore (matches live packiot_analytics: 7-day warm window, orderby carries
-- source_seq DESC after the ts key) + 2-year drop horizon (== B0). if_not_exists
-- makes both a no-op where already configured.
ALTER TABLE public.equipment_values_raw SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'id_equipment',
    timescaledb.compress_orderby   = 'ts_value DESC, source_seq DESC');
SELECT add_compression_policy('public.equipment_values_raw', compress_after => INTERVAL '7 days', if_not_exists => true);
SELECT add_retention_policy('public.equipment_values_raw', drop_after => INTERVAL '2 years', if_not_exists => true);

ALTER TABLE public.equipment_events_raw SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'id_equipment',
    timescaledb.compress_orderby   = 'ts_event DESC, source_seq DESC');
SELECT add_compression_policy('public.equipment_events_raw', compress_after => INTERVAL '7 days', if_not_exists => true);
SELECT add_retention_policy('public.equipment_events_raw', drop_after => INTERVAL '2 years', if_not_exists => true);



