-- ADR-0012 Phase 4 Wave 1 — customer_reports pool tables (expand step)
--
-- Canonical pool versions of the 3 LIVE per-customer report tables
-- (writer inventory 2026-07-02: everything else in the 37-object gate
-- is either a plain view or dead). Column shapes captured from prod
-- tsp12 via information_schema (SELECT-only, 2026-07-02); names —
-- including the German SAP ones — preserved verbatim because the
-- Wave 3 façades must be column-identical.
--
-- Expand-contract: these tables are ADDITIVE. The per-customer tables
-- stay live and written until Wave 2 (writer dual-write + bake) and
-- Wave 3 (façade flip) complete.
--
-- Apply order: packiot_shadow FIRST (rehearsal), then staging packiot.
-- Idempotent: IF NOT EXISTS everywhere.

CREATE SCHEMA IF NOT EXISTS customer_reports;

-- ── customer_reports.shift ──────────────────────────────────────────
-- Pool for report_shift_enterprsie_06 (customer 6; canonical name also
-- fixes the 'enterprsie' typo per ADR-0012 rename table). Prod: no PK,
-- no indexes — delete-and-reload refresh (11.1M ins+del). Pool adds
-- (customer_id, day) as the hot composite.
CREATE TABLE IF NOT EXISTS customer_reports.shift (
    customer_id       integer NOT NULL,
    line              character varying,
    shift             character varying,
    turno_hrs         text,
    day               date,
    job               bigint,
    shift_duration_h  numeric,
    dt_duration_h     numeric,
    setup_duration_h  numeric,
    running           numeric,
    prss_qty          double precision,
    packed_qty        double precision,
    shift_number      integer,
    job_sequence      timestamp without time zone,
    dt_plan_h         numeric,
    dt_unplan_h       numeric,
    shift_start_time  timestamp without time zone,
    index1            text,
    id_equipment      integer,
    pro_h             numeric,
    res_h             numeric,
    mnt_h             numeric,
    discart_h         numeric,
    index2            jsonb
);
CREATE INDEX IF NOT EXISTS shift_customer_day_idx
    ON customer_reports.shift (customer_id, day);

-- ── customer_reports.speed ──────────────────────────────────────────
-- Pool for report_speed_enterprsie_33 (customer 33). Prod: no indexes.
CREATE TABLE IF NOT EXISTS customer_reports.speed (
    customer_id           integer NOT NULL,
    id_equipment          integer,
    id_order              integer,
    id_product            integer,
    production_programmed bigint,
    production_final      bigint,
    avg_speed             numeric,
    final_net             bigint,
    job_start             timestamp with time zone,
    product_type          text
);
CREATE INDEX IF NOT EXISTS speed_customer_job_start_idx
    ON customer_reports.speed (customer_id, job_start);

-- ── customer_reports.sap_data_sync ──────────────────────────────────
-- Pool for sap_report_data_sync_customer_13 (customer 13, neopac SAP
-- integration — 18.4M updates against pk_sap_sync). The pool unique
-- index extends the prod upsert key with customer_id; back4-api's
-- data-sync controller must target this key at Wave 2 cutover.
CREATE TABLE IF NOT EXISTS customer_reports.sap_data_sync (
    customer_id           integer NOT NULL,
    linie                 character varying NOT NULL,
    tag                   date NOT NULL,
    shicht                character varying NOT NULL,
    shicht_nummer         integer,
    auftrag_key           bigint NOT NULL,
    auftrag               bigint,
    sum_labels            bigint,
    rumpfe                double precision,
    gutmenge              double precision,
    rustzeit              numeric,
    produktionszeit       numeric,
    geplante_ausfallzeit  numeric,
    ungeplante_ausfallzeit numeric,
    matfehler_ausfallzeit numeric,
    no_order              numeric,
    auftrag_startzeit     timestamp without time zone,
    running_h             numeric,
    shift_start_time      timestamp with time zone,
    data_type             text,
    id_order_label        text
);
CREATE UNIQUE INDEX IF NOT EXISTS sap_data_sync_pool_key
    ON customer_reports.sap_data_sync (customer_id, linie, tag, shicht, auftrag_key);

-- ── Backfill (best-effort, per-table fail-soft) ─────────────────────
-- Idempotent guard: only backfill when the pool slice is empty. Each
-- table is exception-protected: packiot_shadow's Hasura-parity STUB
-- versions of these tables have a different column shape than prod
-- (discovered on first rehearsal apply, 2026-07-02) — a shape mismatch
-- must skip that table with a NOTICE, not abort the wave.
DO $$
BEGIN
    BEGIN
        IF to_regclass('public.report_shift_enterprsie_06') IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM customer_reports.shift WHERE customer_id = 6) THEN
            INSERT INTO customer_reports.shift
            SELECT 6, line, shift, turno_hrs, day, job, shift_duration_h,
                   dt_duration_h, setup_duration_h, running, prss_qty,
                   packed_qty, shift_number, job_sequence, dt_plan_h,
                   dt_unplan_h, shift_start_time, index1, id_equipment,
                   pro_h, res_h, mnt_h, discart_h, index2
              FROM public.report_shift_enterprsie_06;
        END IF;
    EXCEPTION WHEN undefined_column OR datatype_mismatch THEN
        RAISE NOTICE 'shift backfill skipped (source shape mismatch): %', SQLERRM;
    END;
    BEGIN
        IF to_regclass('public.report_speed_enterprsie_33') IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM customer_reports.speed WHERE customer_id = 33) THEN
            INSERT INTO customer_reports.speed
            SELECT 33, id_equipment, id_order, id_product,
                   production_programmed, production_final, avg_speed,
                   final_net, job_start, product_type
              FROM public.report_speed_enterprsie_33;
        END IF;
    EXCEPTION WHEN undefined_column OR datatype_mismatch THEN
        RAISE NOTICE 'speed backfill skipped (source shape mismatch): %', SQLERRM;
    END;
    BEGIN
        IF to_regclass('public.sap_report_data_sync_customer_13') IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM customer_reports.sap_data_sync WHERE customer_id = 13) THEN
            INSERT INTO customer_reports.sap_data_sync
            SELECT 13, linie, tag, shicht, shicht_nummer, auftrag_key,
                   auftrag, sum_labels, rumpfe, gutmenge, rustzeit,
                   produktionszeit, geplante_ausfallzeit,
                   ungeplante_ausfallzeit, matfehler_ausfallzeit, no_order,
                   auftrag_startzeit, running_h, shift_start_time,
                   data_type, id_order_label
              FROM public.sap_report_data_sync_customer_13;
        END IF;
    EXCEPTION WHEN undefined_column OR datatype_mismatch THEN
        RAISE NOTICE 'sap_data_sync backfill skipped (source shape mismatch): %', SQLERRM;
    END;
END $$;

\echo ''
\echo '=== Wave 1 pool state ==='
SELECT 'shift', count(*) FROM customer_reports.shift
UNION ALL SELECT 'speed', count(*) FROM customer_reports.speed
UNION ALL SELECT 'sap_data_sync', count(*) FROM customer_reports.sap_data_sync;
