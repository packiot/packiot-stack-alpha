-- ADR-0012 POC: customer_dashboards pool schema + façades preserving PowerBI names
-- Applied to packiot_refactor sandbox

BEGIN;

-- Confirm we're not on the wrong DB
SELECT current_database() AS db, current_user AS role;

-- ============================================================
-- Phase 1: canonical schema (pool multi-tenancy)
-- ============================================================
CREATE SCHEMA IF NOT EXISTS customer_dashboards;
CREATE SCHEMA IF NOT EXISTS customer_reports;

-- 1a. dashboard_producao_24h — unified from c33 + c35
DROP TABLE IF EXISTS customer_dashboards.dashboard_producao_24h CASCADE;
CREATE TABLE customer_dashboards.dashboard_producao_24h (
    customer_id integer NOT NULL,
    dispositivo character varying,
    ts_value    timestamptz,
    valor       double precision,
    ts_ingestion timestamptz DEFAULT now()
);
CREATE INDEX ON customer_dashboards.dashboard_producao_24h (customer_id, ts_value DESC);

-- 1b. dashboard_paradas_24h
DROP TABLE IF EXISTS customer_dashboards.dashboard_paradas_24h CASCADE;
CREATE TABLE customer_dashboards.dashboard_paradas_24h (
    customer_id integer NOT NULL,
    dispositivo character varying,
    ts_start    timestamptz,
    ts_end      timestamptz,
    duracao     integer,
    motivo      text
);
CREATE INDEX ON customer_dashboards.dashboard_paradas_24h (customer_id, ts_start DESC);

-- 1c. dashboard_timeline_24h — biggest on prod at 3.5 GB
DROP TABLE IF EXISTS customer_dashboards.dashboard_timeline_24h CASCADE;
CREATE TABLE customer_dashboards.dashboard_timeline_24h (
    customer_id integer NOT NULL,
    dispositivo character varying,
    ts_value    timestamptz,
    estado      integer,
    id_ordem    text
);
CREATE INDEX ON customer_dashboards.dashboard_timeline_24h (customer_id, ts_value DESC);

-- ============================================================
-- Phase 2: façade views — every historical PowerBI name preserved
-- ============================================================
-- Naming: c35_* becomes a customer-filtered view
DROP TABLE IF EXISTS public.c35_dashboard_producao_24h CASCADE;
DROP TABLE IF EXISTS public.c35_dashboard_producao_24h CASCADE;
CREATE VIEW public.c35_dashboard_producao_24h AS
    SELECT dispositivo, ts_value, valor, ts_ingestion
    FROM customer_dashboards.dashboard_producao_24h
    WHERE customer_id = 35;

DROP TABLE IF EXISTS public.c33_dashboard_producao_24h CASCADE;
CREATE VIEW public.c33_dashboard_producao_24h AS
    SELECT dispositivo, ts_value, valor, ts_ingestion
    FROM customer_dashboards.dashboard_producao_24h
    WHERE customer_id = 33;

DROP TABLE IF EXISTS public.c35_dashboard_paradas_24h CASCADE;
CREATE VIEW public.c35_dashboard_paradas_24h AS
    SELECT dispositivo, ts_start, ts_end, duracao, motivo
    FROM customer_dashboards.dashboard_paradas_24h
    WHERE customer_id = 35;

DROP TABLE IF EXISTS public.c35_dashboard_timeline_24h CASCADE;
CREATE VIEW public.c35_dashboard_timeline_24h AS
    SELECT dispositivo, ts_value, estado, id_ordem
    FROM customer_dashboards.dashboard_timeline_24h
    WHERE customer_id = 35;

-- ============================================================
-- Phase 3: synthetic sample data to prove out query patterns
-- ============================================================
INSERT INTO customer_dashboards.dashboard_producao_24h (customer_id, dispositivo, ts_value, valor)
SELECT
    (ARRAY[35, 33, 6, 13])[1 + (n % 4)] AS customer_id,
    'MACHINE_' || (n % 20)::text,
    now() - (interval '1 hour' * (n % 24)),
    (n * 1.7)::double precision
FROM generate_series(1, 400) n;

INSERT INTO customer_dashboards.dashboard_paradas_24h (customer_id, dispositivo, ts_start, ts_end, duracao, motivo)
SELECT
    (ARRAY[35, 33])[1 + (n % 2)],
    'MACHINE_' || (n % 10)::text,
    now() - (interval '30 minutes' * n),
    now() - (interval '30 minutes' * (n - 1)),
    1800,
    (ARRAY['setup', 'maintenance', 'breakdown'])[1 + (n % 3)]
FROM generate_series(1, 100) n;

INSERT INTO customer_dashboards.dashboard_timeline_24h (customer_id, dispositivo, ts_value, estado, id_ordem)
SELECT
    (ARRAY[35, 33])[1 + (n % 2)],
    'MACHINE_' || (n % 10)::text,
    now() - (interval '10 minutes' * n),
    (n % 5),
    'PO_' || (100 + (n % 30))::text
FROM generate_series(1, 500) n;

-- ============================================================
-- Verification
-- ============================================================
\echo '=== Row counts by customer (canonical) ==='
SELECT customer_id, COUNT(*) FROM customer_dashboards.dashboard_producao_24h GROUP BY customer_id ORDER BY customer_id;

\echo ''
\echo '=== Façade returns only that customer rows (c35_dashboard_producao_24h) ==='
SELECT COUNT(*) AS c35_rows FROM public.c35_dashboard_producao_24h;
SELECT COUNT(*) AS c33_rows FROM public.c33_dashboard_producao_24h;

\echo ''
\echo '=== Cross-customer analytics (which was IMPOSSIBLE before) ==='
SELECT customer_id, dispositivo, COUNT(*) AS events, MAX(ts_value) AS most_recent
FROM customer_dashboards.dashboard_timeline_24h
GROUP BY customer_id, dispositivo
ORDER BY customer_id, dispositivo LIMIT 8;

\echo ''
\echo '=== Query planner: does customer_id filter push down? ==='
EXPLAIN (COSTS OFF) SELECT * FROM public.c35_dashboard_producao_24h WHERE ts_value > now() - interval '6 hours';

COMMIT;
