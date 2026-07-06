-- ADR-0012 sandbox gate alignment — make packiot_refactor pass the
-- PowerBI 5-dimension gate against real staging shapes.
--
-- Fixes found by scripts/test-powerbi-compatibility.sh (first run):
--   * 10 PowerBI-only objects missing (not Hasura-tracked, so the
--     parity stub never carried them) -> same-shape stubs from staging
--   * 5 shape diffs: POC-era synthetic shapes (dispositivo/valor,
--     2-col demo report_*) -> rebuilt with REAL staging shapes,
--     pooled + facaded per the ADR pattern
--
-- c35 dashboards are DEAD on prod (drop pending sign-off #224) but the
-- gate requires shape parity until they leave the object list.
-- Single-shot like the other sandbox migrations; reprovision applies
-- it after the naming sweep.

BEGIN;

-- ── retire POC/demo-era wrong-shape objects ────────────────────────
DROP VIEW IF EXISTS public.c35_dashboard_paradas_24h;
DROP VIEW IF EXISTS public.c35_dashboard_producao_24h;
DROP VIEW IF EXISTS public.c35_dashboard_timeline_24h;
DROP VIEW IF EXISTS public.c33_dashboard_producao_24h;
DROP TABLE IF EXISTS customer_dashboards.dashboard_paradas_24h CASCADE;
DROP TABLE IF EXISTS customer_dashboards.dashboard_producao_24h CASCADE;
DROP TABLE IF EXISTS customer_dashboards.dashboard_timeline_24h CASCADE;
-- phase-1 demo report_* lineage (2-col fake shapes)
DROP VIEW IF EXISTS public.report_shift_enterprsie_06;
DROP VIEW IF EXISTS public.report_speed_enterprsie_33;
DROP TABLE IF EXISTS public.report_shift_enterprise_06;
DROP TABLE IF EXISTS public.report_speed_enterprise_33;
CREATE SCHEMA IF NOT EXISTS customer_reports;
DROP TABLE IF EXISTS customer_reports.shift;
DROP TABLE IF EXISTS customer_reports.speed;

-- ── c35_dashboard_paradas_24h → customer_dashboards.dashboard_paradas_24h (customer_id=35) ──
CREATE TABLE customer_dashboards.dashboard_paradas_24h (
    customer_id integer NOT NULL,
    dispositivo character varying,
    operacao character varying,
    inicio timestamp with time zone,
    fim timestamp with time zone,
    duracao real,
    op character varying,
    planejada integer,
    id_enterprise integer
);
CREATE INDEX ON customer_dashboards.dashboard_paradas_24h (customer_id);
CREATE VIEW public.c35_dashboard_paradas_24h AS
  SELECT dispositivo, operacao, inicio, fim, duracao, op, planejada, id_enterprise FROM customer_dashboards.dashboard_paradas_24h WHERE customer_id = 35;

-- ── c35_dashboard_producao_24h → customer_dashboards.dashboard_producao_24h (customer_id=35) ──
CREATE TABLE customer_dashboards.dashboard_producao_24h (
    customer_id integer NOT NULL,
    turno integer,
    dia date,
    turnoanterior integer,
    diaanterior date,
    dispositivo character varying,
    tipodispositivo character varying,
    op character varying,
    cliente character varying,
    tmpprevmin real,
    tmprealmin real,
    qtdprevista double precision,
    qtdproduzida double precision,
    qtdmetaturno double precision,
    velmetaturno real,
    qtdperda double precision,
    qtdperdakg double precision,
    id_enterprise integer,
    tarefa character varying,
    statustarefa character varying,
    qtdproduzidaiot double precision,
    oee double precision,
    oee_area double precision
);
CREATE INDEX ON customer_dashboards.dashboard_producao_24h (customer_id);
CREATE VIEW public.c35_dashboard_producao_24h AS
  SELECT turno, dia, turnoanterior, diaanterior, dispositivo, tipodispositivo, op, cliente, tmpprevmin, tmprealmin, qtdprevista, qtdproduzida, qtdmetaturno, velmetaturno, qtdperda, qtdperdakg, id_enterprise, tarefa, statustarefa, qtdproduzidaiot, oee, oee_area FROM customer_dashboards.dashboard_producao_24h WHERE customer_id = 35;

-- ── c35_dashboard_timeline_24h → customer_dashboards.dashboard_timeline_24h (customer_id=35) ──
CREATE TABLE customer_dashboards.dashboard_timeline_24h (
    customer_id integer NOT NULL,
    dispositivo character varying,
    hora timestamp with time zone,
    status character varying,
    descricao character varying,
    varname character varying,
    varvalue real,
    id_enterprise integer,
    ocorrencia character varying
);
CREATE INDEX ON customer_dashboards.dashboard_timeline_24h (customer_id);
CREATE VIEW public.c35_dashboard_timeline_24h AS
  SELECT dispositivo, hora, status, descricao, varname, varvalue, id_enterprise, ocorrencia FROM customer_dashboards.dashboard_timeline_24h WHERE customer_id = 35;

-- ── report_shift_enterprsie_06 → customer_reports.shift (customer_id=6) ──
CREATE TABLE customer_reports.shift (
    customer_id integer NOT NULL,
    line character varying,
    shift character varying,
    turno_hrs text,
    day date,
    job bigint,
    shift_duration_h numeric,
    dt_duration_h numeric,
    setup_duration_h numeric,
    running numeric,
    prss_qty double precision,
    packed_qty double precision,
    shift_number integer,
    job_sequence timestamp without time zone,
    dt_plan_h numeric,
    dt_unplan_h numeric,
    shift_start_time timestamp without time zone,
    index1 text,
    id_equipment integer,
    pro_h numeric,
    res_h numeric,
    mnt_h numeric,
    discart_h numeric,
    index2 jsonb
);
CREATE INDEX ON customer_reports.shift (customer_id);
CREATE VIEW public.report_shift_enterprsie_06 AS
  SELECT line, shift, turno_hrs, day, job, shift_duration_h, dt_duration_h, setup_duration_h, running, prss_qty, packed_qty, shift_number, job_sequence, dt_plan_h, dt_unplan_h, shift_start_time, index1, id_equipment, pro_h, res_h, mnt_h, discart_h, index2 FROM customer_reports.shift WHERE customer_id = 6;

-- ── report_speed_enterprsie_33 → customer_reports.speed (customer_id=33) ──
CREATE TABLE customer_reports.speed (
    customer_id integer NOT NULL,
    id_equipment integer,
    id_order integer,
    id_product integer,
    production_programmed bigint,
    production_final bigint,
    avg_speed numeric,
    final_net bigint,
    job_start timestamp with time zone,
    product_type text
);
CREATE INDEX ON customer_reports.speed (customer_id);
CREATE VIEW public.report_speed_enterprsie_33 AS
  SELECT id_equipment, id_order, id_product, production_programmed, production_final, avg_speed, final_net, job_start, product_type FROM customer_reports.speed WHERE customer_id = 33;

CREATE VIEW public.c33_dashboard_producao_24h AS
  SELECT turno, dia, turnoanterior, diaanterior, dispositivo, tipodispositivo, op, cliente, tmpprevmin, tmprealmin, qtdprevista, qtdproduzida, qtdmetaturno, velmetaturno, qtdperda, qtdperdakg, id_enterprise, tarefa, statustarefa, qtdproduzidaiot, oee, oee_area FROM customer_dashboards.dashboard_producao_24h WHERE customer_id = 33;

-- typo-era compat names re-pointed at the rebuilt facades
CREATE OR REPLACE VIEW public.report_shift_enterprise_06 AS
  SELECT * FROM public.report_shift_enterprsie_06;
CREATE OR REPLACE VIEW public.report_speed_enterprise_33 AS
  SELECT * FROM public.report_speed_enterprsie_33;

CREATE TABLE public.c33_downtime_events (
    tz_event timestamp without time zone,
    dia date,
    turno character varying,
    ts_event timestamp with time zone,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    duration integer,
    microstop integer
);
CREATE TABLE public.c33_setup_time_adjusted (
    id_equipment integer,
    id_production_order integer,
    ts_start timestamp without time zone,
    start_acerto timestamp without time zone,
    end_acerto timestamp without time zone,
    start_registro timestamp without time zone,
    end_registro timestamp without time zone,
    start_cor timestamp without time zone,
    end_cor timestamp without time zone,
    start_prod timestamp without time zone,
    end_prod timestamp without time zone,
    ts_end timestamp without time zone,
    acerto interval,
    registro interval,
    cor interval,
    tot_setup interval,
    good integer,
    prod_job double precision,
    prod_acerto double precision,
    prod_registro double precision,
    prod_cor double precision,
    prod_real double precision,
    prod_setup double precision,
    prod_setup_adj double precision,
    prod_real_adj double precision,
    production_programmed bigint,
    production_final bigint,
    available_time integer,
    running_time integer,
    stopped_time integer,
    planned_downtime integer,
    ideal_production integer,
    conversion_factor real,
    factor double precision,
    setup_kg double precision
);
CREATE TABLE public.production_data_sync_enterprise_06 (
    site character varying,
    line character varying,
    shift character varying,
    shiftstartdate timestamp with time zone,
    job bigint,
    item character varying,
    totalavailablehrsinmin numeric,
    dtimehrsplannedinmin numeric,
    dtimehrsunplannedinmin numeric,
    unplanneddt_proinmin numeric,
    unplanneddt_resinmin numeric,
    unplanneddt_mntinmin numeric,
    setuphoursinmin numeric,
    runhoursinmin numeric,
    presscnt bigint,
    packcnt bigint,
    jobstatus character varying,
    jobstartdate timestamp with time zone,
    jobcompleteddate timestamp with time zone,
    createddate timestamp with time zone,
    updateddate timestamp with time zone,
    packiotid character varying,
    supervisorapproval boolean,
    supervisorapproveddate timestamp with time zone,
    supervisornotes jsonb,
    nm_user_validation character varying,
    id_validation bigint,
    ts_creation timestamp with time zone,
    to_delete boolean,
    last_update timestamp with time zone,
    packml_topic character varying,
    indice_geral bigint,
    trans_status character varying,
    logics integer,
    real_update timestamp with time zone,
    prev_indice_geral bigint,
    final_trans_status character varying
);
CREATE TABLE public.sap_report_data_sync_customer_13 (
    linie character varying,
    tag date,
    shicht character varying,
    shicht_nummer integer,
    auftrag_key bigint,
    auftrag bigint,
    sum_labels bigint,
    rumpfe double precision,
    gutmenge double precision,
    rustzeit numeric,
    produktionszeit numeric,
    geplante_ausfallzeit numeric,
    ungeplante_ausfallzeit numeric,
    matfehler_ausfallzeit numeric,
    no_order numeric,
    auftrag_startzeit timestamp without time zone,
    running_h numeric,
    shift_start_time timestamp with time zone,
    data_type text,
    id_order_label text
);
CREATE TABLE public.v13_mobile_power_bi_direct_query (
    cd_equipment character varying,
    id_equipment integer,
    status integer,
    curr_info text,
    avg_speed integer,
    duration_in_seconds integer,
    duration text,
    cd_machine character varying,
    cd_category character varying,
    gross double precision,
    net double precision,
    scrap double precision,
    scrap_rate numeric,
    txt_downtime_notes character varying,
    id_order integer,
    last_update text
);
CREATE TABLE public.v_13_site_deb_microstops_piot (
    index text,
    cd_equipment character varying,
    turno text,
    tot_duration double precision,
    id_enterprise integer
);
CREATE TABLE public.v_13_site_deb_pos_labels (
    linie character varying,
    tag date,
    shicht character varying,
    shicht_nummer integer,
    auftrag bigint,
    sum_labels bigint,
    rumpfe double precision,
    gutmenge double precision,
    shift_start_time timestamp with time zone,
    auftrag_startzeit timestamp without time zone,
    data_type text,
    id_order_label text,
    id_enterprise integer
);
CREATE TABLE public.v_13_site_deb_pos_piot4 (
    prod_index text,
    line character varying,
    turno text,
    gross double precision,
    net bigint,
    id_order bigint,
    ts_start timestamp without time zone,
    id_enterprise integer
);
CREATE TABLE public.v_13_site_deb_sap_report (
    line character varying,
    shift character varying,
    shift_hrs text,
    day date,
    job bigint,
    gross double precision,
    net double precision,
    gyartasi_ido numeric,
    beallitasi_ido numeric,
    muszaki_hiba numeric,
    tervezett_karb numeric,
    anyagproblema numeric,
    nem_indokolt_ido numeric,
    total_dt numeric,
    job_start timestamp without time zone,
    shift_start_time timestamp without time zone,
    shift_number integer,
    id_equipment integer,
    id_eterprise integer
);
CREATE TABLE public.v_13_site_wil_microstops_piot4 (
    index text,
    cd_equipment character varying,
    turno text,
    tot_duration double precision,
    id_enterprise integer
);

COMMIT;

\echo '=== gate-alignment verification: all 15 fixed objects present ==='
SELECT relname, relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND relname IN (
 'c33_downtime_events','c33_setup_time_adjusted','c35_dashboard_paradas_24h',
 'c35_dashboard_producao_24h','c35_dashboard_timeline_24h',
 'production_data_sync_enterprise_06','report_shift_enterprsie_06',
 'report_speed_enterprsie_33','sap_report_data_sync_customer_13',
 'v13_mobile_power_bi_direct_query','v_13_site_deb_microstops_piot',
 'v_13_site_deb_pos_labels','v_13_site_deb_pos_piot4','v_13_site_deb_sap_report',
 'v_13_site_wil_microstops_piot4')
ORDER BY relname;
