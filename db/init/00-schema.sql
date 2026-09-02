-- Dev schema for Packiot local stack.
-- Aligned with production schema (edge-api/schema.sql) — column names, types, and nullability match.
-- Omits production-only aggregation tables (agg_*) and _quality signal columns.

CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- ── Hierarchy ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS enterprises (
    id_enterprise SERIAL PRIMARY KEY,
    nm_enterprise VARCHAR NOT NULL,
    api_key       VARCHAR,
    active        BOOLEAN,
    week_begin    INTEGER,   -- seconds offset from Mon 00:00 (can be negative)
    day_begin     INTEGER,   -- seconds into week when the production day starts
    week_size     INTEGER,   -- seconds in a production week
    timezone      VARCHAR
);

CREATE TABLE IF NOT EXISTS sites (
    id_site       SERIAL PRIMARY KEY,
    id_enterprise INTEGER NOT NULL REFERENCES enterprises(id_enterprise),
    nm_site       VARCHAR,
    week_begin    INTEGER,
    day_begin     INTEGER NOT NULL DEFAULT 0,
    week_size     INTEGER NOT NULL DEFAULT 604800,
    timezone      VARCHAR NOT NULL DEFAULT 'UTC'
);

CREATE TABLE IF NOT EXISTS areas (
    id_area       SERIAL PRIMARY KEY,
    id_site       INTEGER NOT NULL REFERENCES sites(id_site),
    id_enterprise INTEGER NOT NULL REFERENCES enterprises(id_enterprise),
    nm_area       VARCHAR,
    day_begin     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS equipments (
    id_equipment        SERIAL PRIMARY KEY,
    id_area             INTEGER NOT NULL REFERENCES areas(id_area),
    id_site             INTEGER NOT NULL REFERENCES sites(id_site),
    id_enterprise       INTEGER NOT NULL REFERENCES enterprises(id_enterprise),
    cd_equipment        VARCHAR,
    nm_equipment        VARCHAR,
    tp_equipment        INTEGER NOT NULL DEFAULT 1,  -- 1=machine 2=sector 3=line
    status_type         INTEGER NOT NULL DEFAULT 1,
    production_speed    INTEGER,                     -- ideal speed (units/min); used for Performance %
    production_speed_source TEXT,                    -- provenance of production_speed: NULL=unset, 'inferred'=provisional (inferspeed.go), 'client'=confirmed nameplate
    lead_machine        INTEGER REFERENCES equipments(id_equipment)
);

-- ── SparkPlug / PackML routing ────────────────────────────────────────────────
-- PK name matches production (id_packml_register, not id).

CREATE TABLE IF NOT EXISTS packml_register (
    id_packml_register  SERIAL PRIMARY KEY,
    packml_topic        VARCHAR,
    id_enterprise       INTEGER REFERENCES enterprises(id_enterprise),
    id_site             INTEGER REFERENCES sites(id_site),
    id_area             INTEGER REFERENCES areas(id_area),
    id_equipment        INTEGER REFERENCES equipments(id_equipment),
    active              BOOLEAN NOT NULL DEFAULT false,
    id_unit             INTEGER REFERENCES equipments(id_equipment),
    signal_quality      SMALLINT DEFAULT 0,
    ts_quality          TIMESTAMPTZ,
    line_unit_seq       VARCHAR,
    attributed          BOOLEAN NOT NULL DEFAULT false,
    mqtt_topic          VARCHAR,
    sparkplug_json      JSONB,
    timestamp           TIMESTAMPTZ DEFAULT now(),
    id_infeedcounter    INTEGER,
    id_outfeedcounter   INTEGER,
    device_nm           VARCHAR,
    device_key          TEXT,        -- ADR-0046 §2 declared equipment identity (birth device_key)
    UNIQUE (packml_topic)
);

-- ── Production orders ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS production_orders (
    id_production_order     BIGSERIAL PRIMARY KEY,
    id_enterprise           INTEGER,
    id_site                 INTEGER,
    id_area                 INTEGER,
    id_equipment            INTEGER,
    nm_production_order     VARCHAR,
    status                  SMALLINT NOT NULL DEFAULT 1,  -- 1=available 2=running 3=finished 4=paused
    ts_start                TIMESTAMPTZ,
    ts_end                  TIMESTAMPTZ,
    production_final        DOUBLE PRECISION,
    txt_production_order_notes VARCHAR
);

-- ── Raw time-series ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS equipment_values (
    ts_value                    TIMESTAMPTZ NOT NULL,
    id_enterprise               INTEGER,
    id_site                     INTEGER,
    id_area                     INTEGER,
    id_equipment                INTEGER NOT NULL,   -- NOT NULL: matches production
    net_production_incr         DOUBLE PRECISION,
    gross_production_incr       DOUBLE PRECISION,
    scrap_incr                  DOUBLE PRECISION,
    net_production_val          DOUBLE PRECISION,
    gross_production_val        DOUBLE PRECISION,
    scrap_val                   DOUBLE PRECISION,
    speed                       REAL,               -- REAL matches production (not DOUBLE PRECISION)
    state                       INTEGER,
    mode                        INTEGER,
    sub_mode                    VARCHAR,            -- VARCHAR matches production (was INTEGER)
    tp_equipment                SMALLINT,
    id_production_order         BIGINT,
    signal_quality              SMALLINT,
    faults                      JSONB,              -- JSONB matches production (was TEXT)
    analogs                     JSONB,
    id_order                    VARCHAR,
    conversion_factor           REAL,
    number_cavities             INTEGER,
    id_team                     INTEGER,
    box_code                    VARCHAR,
    transaction_code            VARCHAR,
    ts_value_production         DATE,
    ideal_production_speed      INTEGER,
    id_shift                    INTEGER,
    id_equipment_line_connected INTEGER,
    position_in_equipment_line  SMALLINT,
    is_equipment_line_infeed    SMALLINT,           -- SMALLINT matches production (was INTEGER)
    is_equipment_line_outfeed   SMALLINT,
    process_scrap_incr          DOUBLE PRECISION,
    process_scrap_val           DOUBLE PRECISION,
    check_number                BIGINT,
    id_shift_hour               INTEGER,
    id_equipment_line_infeed    INTEGER,
    id_equipment_line_outfeed   INTEGER,
    UNIQUE (ts_value, id_equipment)
);

CREATE TABLE IF NOT EXISTS equipment_events (
    id_equipment_event      BIGSERIAL PRIMARY KEY,
    ts_event                TIMESTAMPTZ NOT NULL,
    id_enterprise           INTEGER,
    id_equipment            INTEGER,
    status                  INTEGER,
    txt_downtime_notes      VARCHAR,
    idle                    VARCHAR,
    idle_processed          BOOLEAN DEFAULT false,
    forced_creation_system  BOOLEAN DEFAULT false,
    fault                   INTEGER,
    fault_processed         BOOLEAN DEFAULT false,
    cd_machine              VARCHAR,
    cd_category             VARCHAR,
    cd_subcategory          VARCHAR,
    change_over             BOOLEAN DEFAULT false,
    planned_downtime        BOOLEAN DEFAULT false,
    ts_end                  TIMESTAMPTZ,
    duration                INTEGER,
    desc_category           VARCHAR,
    desc_subcategory        VARCHAR,
    cd_category_client      INTEGER,
    cd_subcategory_client   INTEGER,
    last_update             TIMESTAMPTZ,
    ignore_cost             BOOLEAN DEFAULT false,
    UNIQUE (id_equipment, ts_event)
);

CREATE TABLE IF NOT EXISTS uns_metrics (
    ts_value      TIMESTAMPTZ NOT NULL,
    id_enterprise INTEGER,
    id_site       INTEGER,
    id_area       INTEGER,
    id_equipment  INTEGER,
    metric_name   TEXT NOT NULL,
    metric_value  DOUBLE PRECISION,
    metric_type   TEXT,
    UNIQUE (ts_value, id_equipment, metric_name)
);

-- ── Shifts ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS shifts (
    id_shift   SERIAL PRIMARY KEY,
    id_site    INTEGER NOT NULL REFERENCES sites(id_site),
    id_area    INTEGER REFERENCES areas(id_area),
    cd_shift   TEXT NOT NULL,
    nm_shift   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS shift_hours (
    id_shift_hour SERIAL PRIMARY KEY,
    id_shift      INTEGER NOT NULL REFERENCES shifts(id_shift),
    begin_time    INTEGER NOT NULL,  -- seconds from week_begin
    end_time      INTEGER NOT NULL
);

-- ── Users ─────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS users (
    id_user       SERIAL PRIMARY KEY,
    id_enterprise INTEGER REFERENCES enterprises(id_enterprise),
    nm_user       TEXT NOT NULL,
    email         TEXT,
    active        BOOLEAN NOT NULL DEFAULT true
);

-- ── Current-state snapshot (one row per equipment, UPSERT on id_equipment) ────

CREATE TABLE IF NOT EXISTS uns_equipment_current_metrics (
    id_equipment    INTEGER PRIMARY KEY REFERENCES equipments(id_equipment),
    id_enterprise   INTEGER,
    id_site         INTEGER,
    id_area         INTEGER,
    ts_value        TIMESTAMPTZ,
    state           INTEGER,
    speed           REAL,
    cur_mach_speed  REAL,
    set_mach_speed  REAL,
    mode            INTEGER,
    last_update     TIMESTAMPTZ DEFAULT now()
);

-- ── SparkPlug B message receipt log ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS packml_transmition_states (
    id_packml_transmition_state BIGSERIAL PRIMARY KEY,
    ts_event                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    id_enterprise               INTEGER,
    id_equipment                INTEGER,
    packml_topic                VARCHAR,
    payload                     JSONB
);

-- ── Production order runtimes ────────────────────────────────────────────────
-- One row per PO run segment. PO status is derived:
--   running  = has a row with ts_end IS NULL
--   paused   = all rows have ts_end NOT NULL, PO status still 1 or 2
--   finished = PO status = 3

CREATE TABLE IF NOT EXISTS production_order_runtime (
    id_production_order_runtime BIGSERIAL PRIMARY KEY,
    id_production_order         BIGINT NOT NULL REFERENCES production_orders(id_production_order),
    id_enterprise               INTEGER,
    id_equipment                INTEGER,
    ts_start                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ts_end                      TIMESTAMPTZ,
    net_production              DOUBLE PRECISION,
    scrap                       DOUBLE PRECISION,
    recalc_needed               BOOLEAN DEFAULT false
);

-- ── TimescaleDB hypertable ────────────────────────────────────────────────────
-- equipment_events left as regular table: BIGSERIAL PK (id_equipment_event)
-- conflicts with TimescaleDB requirement that PK must include the partition column.

SELECT create_hypertable('equipment_values', 'ts_value', if_not_exists => TRUE);

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_ev_equipment    ON equipment_values (id_equipment, ts_value DESC);
CREATE INDEX IF NOT EXISTS idx_ev_enterprise   ON equipment_values (id_enterprise, ts_value DESC);
CREATE INDEX IF NOT EXISTS idx_ee_equipment    ON equipment_events (id_equipment, ts_event DESC);
CREATE INDEX IF NOT EXISTS idx_ee_ts           ON equipment_events (ts_event DESC);
CREATE INDEX IF NOT EXISTS idx_pr_topic        ON packml_register (packml_topic);
CREATE INDEX IF NOT EXISTS idx_pr_id_equipment ON packml_register (id_equipment);
-- ADR-0046 §2: one declared device_key per (enterprise, key). Partial so the many
-- legacy NULL-device_key rows are exempt (they still resolve by topic).
CREATE UNIQUE INDEX IF NOT EXISTS uq_pr_enterprise_device_key
    ON packml_register (id_enterprise, device_key) WHERE device_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_po_equip_status ON production_orders (id_equipment, status);
CREATE INDEX IF NOT EXISTS idx_por_po          ON production_order_runtime (id_production_order);
CREATE INDEX IF NOT EXISTS idx_por_equipment   ON production_order_runtime (id_equipment, ts_start DESC);

-- ── production_information (stub for edge-api compatibility) ──────────────────
-- Production uses an aggregated view; dev exposes the same columns as a table.
-- edge-api queries: SELECT * FROM production_information WHERE id_enterprise=$1 AND id_equipment=$2

CREATE TABLE IF NOT EXISTS production_information (
    id_enterprise           INTEGER,
    id_equipment            INTEGER,
    net_production          DOUBLE PRECISION,
    gross_production        DOUBLE PRECISION,
    scrap                   DOUBLE PRECISION,
    oee                     DOUBLE PRECISION,
    availability            DOUBLE PRECISION,
    performance             DOUBLE PRECISION,
    quality                 DOUBLE PRECISION,
    avg_speed               DOUBLE PRECISION,
    id_production_order     BIGINT,
    ts_last_update          TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (id_enterprise, id_equipment)
);

-- ── Check constraints ─────────────────────────────────────────────────────────

ALTER TABLE production_orders
    DROP CONSTRAINT IF EXISTS chk_po_status,
    ADD  CONSTRAINT chk_po_status CHECK (status IN (1, 2, 3, 4));
