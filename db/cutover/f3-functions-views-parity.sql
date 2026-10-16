-- ============================================================================
-- F3 (packiot_analytics) functions/views parity — staging F1→F3 cutover
-- ============================================================================
-- CONTEXT: packiot_analytics (F3) is now the sole plane; legacy packiot (F1)
-- is retired. edge-api, sparkplug-decoder, stream-engine (oeecloud-worker) and
-- operator-gateway read/write F3. A census of F1.public vs F3.public found
-- ~164 functions and ~88 views present in F1 but absent in F3. The VAST
-- MAJORITY are LEGACY OEE-compute stored procs/triggers (piot_* refresh/feed/
-- get_*_runtime_*_production/set_recalc_needed_*/trig_*/uns_*_refresh) that the
-- Go worker + TimescaleDB caggs DELIBERATELY replace — copying them back would
-- double-compute or conflict with the medallion. Those are SKIPPED (see the PR
-- body's SKIPPED table). pgcrypto extension fns and dead client-suffixed
-- variants (_99/_gci/_fix2/cust_13…) are likewise skipped.
--
-- This migration is the NEEDED set only: objects a LIVE service actually calls
-- on F3 and that F3 lacks:
--   * get_report_shift_enterprsie_06c  — stream-engine worker (reports/shift06.go),
--       the loud `42883 function ... does not exist` error. Feeds customer_reports.shift.
--   * get_downtime_sync_enterprsie_06, get_data_sync_enterprsie_06b — read-api
--       refdata external SAP-sync shims (external.go, always mounted at main.go).
--   * v_13_site_deb_sap_report, v_sap_report_data_sync_customer_13 (+ its _deb
--       dependency), v_piot_production_data_sync_cust6 — the read-api external
--       shim backing views (Neopac ent-13 / Montebello ent-6 SAP data-sync).
--
-- Plus 4 empty dependency relations these objects reference that F3 lacked
-- (all 0 rows in F1 — legacy sync/validation staging tables no longer fed;
-- created empty so the functions/views RESOLVE and return empty, which is the
-- correct behaviour on staging where those legacy customer-sync flows are off):
--   equipment_validation_shift, production_data_sync_enterprise_06,
--   downtime_sync_enterprise_06 (SETOF rowtype of get_downtime_sync_enterprsie_06),
--   data_sync_enterprise_06b   (SETOF rowtype of get_data_sync_enterprsie_06b).
--
-- ADDITIVE ONLY. Idempotent (CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE).
-- No DROPs, no telemetry data, no legacy OEE-compute procs/triggers.
-- Apply:  psql -d packiot_analytics -f db/cutover/f3-functions-views-parity.sql
--
-- TWO DOCUMENTED ADAPTATIONS to the verbatim F1 definitions (F1→F3 drift; the
-- objects would not even CREATE on F3 without them — SQL-language functions and
-- views are column-validated at creation):
--   1. `agg_equipment_values_1min_t` → `agg_equipment_values_1min`. In F1 the
--      `_t` name was the WIDE physical trigger-table (id_site/id_area/
--      gross_production_incr/net_production_incr/…). In F3 the `_t` name is a
--      vestigial NARROW stub view (ts_value,id_equipment,val over
--      equipment_values_1min); the blessed WIDE medallion compat view (the one
--      the read-api metric catalog reads, backed by the 1-min continuous
--      aggregate, ~56k rows/2d) is `agg_equipment_values_1min`. Nothing in F3
--      depends on the narrow `_t` stub, so we repoint these reports at the wide
--      view. (The worker's own baked-in reports/sap13_body.sql + read-api
--      external_integration.go:326 still read the narrow `_t` and fail the same
--      way — that is a stream-engine CODE repoint + deploy, out of scope here.)
--   2. get_downtime_sync_enterprsie_06 UNION balance: `equipment_events` gained
--      new-stack columns (ingested_at, source_seq) that `equipment_events_man`
--      lacks. The F1 function's stored plan predates them; re-creating re-expands
--      `eqev.*` and mismatches the manual-events UNION branch. Two positional
--      NULL columns realign it. Both are dropped at the fixed SETOF projection.
--
-- NOT MIGRATED (the ~150 fns / ~80 views in F1\public but not the NEEDED set):
--   * LEGACY OEE-COMPUTE procs/triggers the Go worker + TimescaleDB caggs replace
--     — piot_refresh_uns / piot_feed_agg_* / piot_get_*_runtime_*_production /
--     piot_set_shift_on_equipment_values / piot_review_equipment_* /
--     piot_uns_*_refresh / set_recalc_needed_* / piot_trig_* / last_update_to_now*
--     / oee_compute_uns_metrics. Copying them back would double-compute or fight
--     the medallion. (stream-engine PORTS these to Go — the names live only in its
--     source COMMENTS, never as live F3 calls.)
--   * pgcrypto extension fns (armor/crypt/digest/hmac/pgp_*/gen_salt/…) — provided
--     by `CREATE EXTENSION pgcrypto`, not app objects; install the extension if a
--     consumer ever needs them.
--   * DEAD generation variants — h_piot_*_99/_gci/_demo/_test/_fix2/_data1a/_41/
--     _tz_fix3 and client-suffixed cust_13/client6/client_33/cust6 aggregators.
--     The LIVE canonical read-api backing fns/views (h_piot_get_downtimes_events,
--     h_piot_oee_score_full_3, v_menu_per_user_role, v_operator_entities_2,
--     v_report_downtimes, …) ALREADY EXIST in F3 (post-#867) — verified all 36
--     read-api dataset/route objects resolve.
--   * legacy aggregate/client views — v_agg_*, ca_agg_*, shift_agg_*, mv_ohlc_1s,
--     v_13_*/c33_*/c35_* client dashboards, v_operator_* legacy variants, v_pages,
--     v_user_menu, v_total_production_* — replaced by the medallion caggs / uns_*
--     or dead client-specific; not called by any live F3 service.
--   * BROKEN-on-F3 — anything referencing F1-only tables absent from F3.
-- ============================================================================

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- SECTION A — empty dependency relations (additive; all 0 rows in F1)
-- ────────────────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS public.equipment_validation_shift_id_validation_seq;
CREATE SEQUENCE IF NOT EXISTS public.production_data_sync_enterprise_06_indice_geral_seq;


CREATE TABLE IF NOT EXISTS public.equipment_validation_shift (
    index1 text,
    id_enterprise integer,
    id_equipment integer,
    cd_equipment character varying,
    ts_value_production date,
    cd_shift character varying,
    shift_hrs text,
    id_order bigint,
    txt_validation_notes jsonb,
    validation boolean,
    ts_user_validation timestamp with time zone,
    nm_user_validation character varying,
    id_validation integer DEFAULT nextval('public.equipment_validation_shift_id_validation_seq'::regclass) NOT NULL,
    ts_creation timestamp with time zone,
    to_delete boolean,
    last_update timestamp with time zone,
    shift_start_time timestamp with time zone,
    index2 jsonb
);
CREATE TABLE IF NOT EXISTS public.production_data_sync_enterprise_06 (
    site character varying(15),
    line character varying(6),
    shift character varying(6),
    shiftstartdate timestamp with time zone,
    job bigint,
    item character varying(30),
    totalavailablehrsinmin numeric(10,2),
    dtimehrsplannedinmin numeric(10,2),
    dtimehrsunplannedinmin numeric(10,2),
    unplanneddt_proinmin numeric(10,2),
    unplanneddt_resinmin numeric(10,2),
    unplanneddt_mntinmin numeric(10,2),
    setuphoursinmin numeric(10,2),
    runhoursinmin numeric(10,2),
    presscnt bigint,
    packcnt bigint,
    jobstatus character varying(20),
    jobstartdate timestamp with time zone,
    jobcompleteddate timestamp with time zone,
    createddate timestamp with time zone,
    updateddate timestamp with time zone,
    packiotid character varying(25),
    supervisorapproval boolean,
    supervisorapproveddate timestamp with time zone,
    supervisornotes jsonb,
    nm_user_validation character varying(15),
    id_validation bigint,
    ts_creation timestamp with time zone,
    to_delete boolean,
    last_update timestamp with time zone,
    packml_topic character varying,
    indice_geral bigint DEFAULT nextval('public.production_data_sync_enterprise_06_indice_geral_seq'::regclass) NOT NULL,
    trans_status character varying(6),
    logics integer,
    real_update timestamp with time zone,
    prev_indice_geral bigint,
    final_trans_status character varying(6)
);
CREATE TABLE IF NOT EXISTS public.downtime_sync_enterprise_06 (
    nm_site character varying,
    nm_equipment character varying,
    id_order integer,
    sector character varying,
    cd_shift character varying,
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    cd_machine character varying,
    cd_category_client integer,
    cd_category character varying,
    desc_category character varying,
    cd_subcategory_client integer,
    cd_subcategory character varying,
    desc_subcategory character varying,
    txt_downtime_notes character varying,
    pack_id bigint,
    packml_topic character varying,
    last_update timestamp with time zone,
    dt_type text,
    dt_subtype text,
    mnt_trigger boolean,
    methodtype text
);
CREATE TABLE IF NOT EXISTS public.data_sync_enterprise_06b (
    site character varying(15),
    line character varying(6),
    shift character varying(6),
    shiftstartdate timestamp with time zone,
    job bigint,
    item character varying(30),
    totalavailablehrsinmin numeric(10,2),
    dtimehrsplannedinmin numeric(10,2),
    dtimehrsunplannedinmin numeric(10,2),
    unplanneddt_proinmin numeric(10,2),
    unplanneddt_resinmin numeric(10,2),
    unplanneddt_mntinmin numeric(10,2),
    setuphoursinmin numeric(10,2),
    runhoursinmin numeric(10,2),
    presscnt bigint,
    packcnt bigint,
    jobstatus character varying(20),
    jobstartdate timestamp with time zone,
    jobcompleteddate timestamp with time zone,
    createddate timestamp with time zone,
    updateddate timestamp with time zone,
    packiotid character varying(25),
    supervisorapproval boolean,
    supervisorapproveddate timestamp with time zone,
    supervisornotes jsonb,
    nm_user_validation character varying(15),
    id_validation bigint,
    ts_creation timestamp with time zone,
    to_delete boolean,
    last_update timestamp with time zone,
    packml_topic character varying,
    last_update_prod_data timestamp with time zone
);




-- ────────────────────────────────────────────────────────────────────────────
-- SECTION B — report / sync functions (live service calls)
-- ────────────────────────────────────────────────────────────────────────────

-- ==== FUNCTION get_report_shift_enterprsie_06c ====
CREATE OR REPLACE FUNCTION public.get_report_shift_enterprsie_06c(startdate date, enddate date)
 RETURNS TABLE(line character varying, shift character varying, turno_hrs text, day date, job bigint, shift_duration_h numeric, dt_duration_h numeric, setup_duration_h numeric, running numeric, prss_qty double precision, packed_qty double precision, shift_number integer, job_sequence timestamp without time zone, dt_plan_h numeric, dt_unplan_h numeric, shift_start_time timestamp without time zone, index1 text, id_equipment integer, pro_h numeric, res_h numeric, mnt_h numeric, discart_h numeric, index2 jsonb)
 LANGUAGE sql
 STABLE
AS $function$
--novo report 
--versao anterior de 2023-10-05 funcionando, salva por eduardo
--novo report 
with dias as (
SELECT 
	--(generate_series((now() at time zone 'America/Montreal')::date - interval '21 day', (now() at time zone 'America/Montreal')::date,'1 day'))::date as start_day
	(generate_series((startdate)::date, (enddate)::date,'1 day'))::date as start_day
), start_counting_day as (
--para que os dados sejam buscados sempre a partir do ultimo domingo
select 
	start_day
from dias
order by start_day
limit 1
), turnos as (--aqui pega as logicas de turnos na runtime de turnos
select 
	concat(to_char(((ts_value at time zone 'America/Montreal')::time),'HH24:MI'),'-', to_char(((ts_end at time zone 'America/Montreal')::time),'HH24:MI')) as turno_hrs,
	ts_value as shift_start_time, --nova variavel 
	id_equipment,
	cd_shift,
	id_shift,
	ts_value_production,
	ts_value as tz_value,
	case 
		when ts_end > now() then now() 
		else ts_end end as tz_end
from equipment_runtime_shift, start_counting_day scd
where id_equipment in (select id_equipment from equipments where id_enterprise = 6 and tp_equipment = 3 and id_area not in (24))
and ts_value_production >= scd.start_day --now()::date -  interval '3 day' 
and ts_value < now()
order by id_equipment, tz_value
), equipamentos as (--aqui pega uma logica para que cada id_equipment tenha um cd_equipment de uma linha associado
select 
	e.id_equipment,
		case when eq.tp_equipment = 3 then e.id_parentequipment
		when eq.tp_equipment = 2 then eq.id_parentequipment end as id_equipment_line
from equipments e, equipments eq
where e.id_parentequipment = eq.id_equipment
and e.id_equipment in (select id_equipment from equipments where id_enterprise = 6 and tp_equipment in (1,2))
), linhas as (--aqui faz a associacao final do id_equipment com o cd_equipment de uma linha
select 
	e.id_equipment,
	eq.cd_equipment,
	e.id_equipment_line
from equipamentos e, equipments eq
where e.id_equipment_line = eq.id_equipment
--******** parte nova para ser inserida que estava com erro nos downtimes*************
union all
select 
	id_equipment,
	cd_equipment,
	id_equipment as id_equipment_line
from equipments
where id_equipment in (select id_equipment from equipments where id_enterprise = 6 and tp_equipment = 3)
order by cd_equipment 
--***************************************************************************************
), presscount as (--dados de press-count para todos os equipamento tipo 3 da enterprise 6
	select 
	id_equipment,
	id_site,
	id_area,
	ts_value as tz_value,
	gross_production_incr 
	from agg_equipment_values_1min, start_counting_day scd
	where id_equipment in (select id_equipment from equipments where id_enterprise = 6 and tp_equipment = 3)
	and ts_value >= now()- interval '30 day'
	and ts_value >= startdate - interval '1 day'
	and ts_value <= enddate + interval '1 day'
	and id_enterprise = 6
	and id_site in (select id_site from sites where id_enterprise = 6)
	and id_area in (select id_area from areas where id_enterprise = 6 and id_area!=24)
), prod_orders as (--aqui existe um problema a ser resolvido. Se existe um GAP entre OPs
	select 
	porun.id_equipment,
	po.id_enterprise,
	po.id_area, 
	po.id_site,
	po.id_order,
	porun.runtime_timerange,
	lower(porun.runtime_timerange) as job_start,
	case when upper(porun.runtime_timerange) is null then now() else upper(porun.runtime_timerange) end as job_end,
	upper(porun.runtime_timerange) as ts_end_progress
from production_orders_runtime porun, production_orders po
where porun.id_equipment in (select id_equipment from equipments where id_enterprise = 6 and tp_equipment = 3 and id_area not in (24))
and po.id_equipment = porun.id_equipment
and po.id_enterprise = 6
and po.id_production_order = porun.id_production_order 
--and lower(porun.runtime_timerange) >= now() - interval '60 day'
and porun.runtime_timerange && tstzrange(now()- interval '50 day', now())
order by 1,6
),labels_extract as (--pega os labels, e precisa ser hard coded pois nao existe uma logic para qual equipamento tem labels
select 
	ca.ts_value as tz_value, 
	--ca.id_equipment,
	l.id_equipment_line as id_equipment,
	ca.id_order as label_Job,
	ca.net_production  as label_amount
	from ca_equipment_boxes_1s ca, linhas l
	-- a json was created in the custom column with a logic for all equipments that have labels in the table ca_equipment_boxes_1s
	--where ca.id_equipment in (138,144,236,260,266,323,363,374,385,432,458,481,492,503,514,518,525,530,535,549,573,578)
	where ca.id_equipment in (select id_equipment from equipments where id_enterprise = 6 and cast(custom::json#>>'{Label,has_labels}' as BOOLEAN) is true and id_area not in (24))
	and ca.id_enterprise = 6
	and ca.id_site in (select id_site from sites where id_enterprise = 6)
	and ca.ts_value >= now() - interval '60 day'
	and ca.ts_value >= startdate - interval '20 day'
	and ca.ts_value <= enddate + interval '1 day'
	and ca.ts_value >= (select min(lower(runtime_timerange)) - interval '12 hour' from prod_orders)
	and l.id_equipment = ca.id_equipment	
), negative_labels as ( --FOI MODIFICADO E AGORA NAO APENAS OS LABELS NEGATIVOS MAS TB OS POSITIVOS SAO CONSIDERADOS PARA 3H
select l.*, po.job_end,
	case when po.job_end is null then 0 else ((date_part('epoch'::text, l.tz_value -po.job_end)))::bigint end as diff_s
from labels_extract l
left join prod_orders po
on cast(l.label_Job as integer) = po.id_order
), labels as (
select distinct tz_value,id_equipment,label_job,label_amount
--, diff_s
from negative_labels
where diff_s <= 10800 -- condicao de 3h
order by tz_value
), po_sequence_basis as ( --mudar
select 
	id_order,
	lead(id_order) over (order by id_order, runtime_timerange) as id_order_sec,
	runtime_timerange,
	lead(runtime_timerange) over (order by id_order, runtime_timerange) as runtime_timerange_sec	
from prod_orders
order by id_order
), po_sequence as ( --mudar
select 
	id_order,--abaixo modificado no dia 2024-04-03 para evitar duplicacao de dados de OPs que rodaram mais de uma vez
	case when id_order = id_order_sec then tstzrange(lower(runtime_timerange),least((upper(runtime_timerange) + interval '6 hour'),lower(runtime_timerange_sec)))
	else tstzrange(lower(runtime_timerange),now()::timestamp) end as runtime_timerange_new
from po_sequence_basis
order by id_order,runtime_timerange
),jobs as (
select 
	po.id_equipment,
	lag(po.id_equipment) over (order by po.id_equipment,po.job_start) as previous_id_equipment,
	po.id_order,
	lag(po.id_order) over (order by po.id_equipment,po.job_start) as previous_id_order,
	po.job_start as tz_start,
	po.job_end as tz_end,
	tsrange(po.job_start at time zone 'America/Montreal', po.ts_end_progress at time zone 'America/Montreal') as ran,
	ts_end_progress
from prod_orders po
where po.id_equipment in (select id_equipment from equipments where id_enterprise = 6 and tp_equipment = 3)
and po.job_end >= (select start_day - interval '25 day' from start_counting_day)
order by po.id_equipment,po.job_start
), jobs2 as (
select 
	j.*,
	min(l.tz_value) as first_label
from jobs j
left join labels l
on j.id_order = cast(l.label_Job as integer)
and l.tz_value between j.tz_start and j.tz_end
and previous_id_order is not null
group by 1,2,3,4,5,6,7,8
), jobs3 as (
select 
	po.id_equipment,
	lag(po.id_equipment) over (order by po.id_equipment,po.tz_start) as previous_id_equipment,
	po.id_order,
	lag(po.id_order) over (order by po.id_equipment,po.tz_start) as previous_id_order,
	tz_start,
	tz_end,
	first_label
from jobs2 po
where po.first_label is not null
order by id_equipment,po.tz_start
), jobs4 as (
select 
	j2.*,
	max(l.tz_value) as last_label_previous_job
from jobs3 j2
left join labels l
on j2.previous_id_order = cast(l.label_Job as integer)
and l.tz_value <= j2.first_label
and l.tz_value <= j2.tz_start --alteração 2025-03-05 Eduardo, para pegar o last_label before or at the same time as the job_start
and j2.id_equipment = j2.previous_id_equipment
and j2.previous_id_order is not null
and j2.first_label is not null
group by 1,2,3,4,5,6,7
), setups0 as (
select 
	id_equipment,
	id_order,
	last_label_previous_job as setup_start,
	first_label as setup_end,
	tz_start,
	tz_end,
	tsrange(tz_start at time zone 'America/Montreal',tz_end at time zone 'America/Montreal') as tz_range
from jobs4
where previous_id_order is not null
and id_equipment = previous_id_equipment
and COALESCE(first_label,last_label_previous_job) is not null
and tz_start >= now() - interval '60 day'
order by id_equipment, tz_start
), setups1 as (
select 
	j.id_equipment,
	j.id_order,
	null as setup_start,
	null as setup_end,
	j.tz_start,
	j.tz_end,
	j.ran as tz_range
from jobs j
where j.id_equipment = j.previous_id_equipment
and j.tz_start >= now() - interval '60 day'
and j.ran not in (select tz_range from setups0)
and j.ts_end_progress is not null
union all 
select *
from setups0
order by id_equipment,tz_start
), setups as ( --inseri esse union all
select *
from setups1
union all
select 
	id_equipment,
	id_order,
	ts_start as setup_start,
	now() as setup_end,
	ts_start as tz_start,
	now() as tz_end,
	tsrange(ts_start at time zone 'America/Montreal',now() at time zone 'America/Montreal') as tz_range
from production_orders po 
where id_site = 20
and status = 2
and id_order not in (select id_order from setups1)
),base_for_splits as (
select 
	shi.turno_hrs,
	shi.shift_start_time, -- nova variavel celine
	shi.id_equipment,
	shi.cd_shift,
	shi.ts_value_production,
	po.id_order,
	case when tz_value > coalesce(job_start,'2024-01-01') then tz_value else job_start end as inicio,
	case when tz_end < coalesce(job_end,'2100-01-01') then tz_end else job_end end as fim,
	po.id_site,
	po.id_area,
	shi.id_shift
from turnos shi
left join prod_orders po
on po.job_start < shi.tz_end
and po.job_end >= shi.tz_value
and po.id_equipment = shi.id_equipment
order by shi.id_equipment, shi.tz_value
), press_quantity as (
select 
	bfs.id_equipment,
	bfs.cd_shift,
	bfs.ts_value_production,
	bfs.id_order,
	bfs.inicio,
	bfs.fim,
	sum(pc.gross_production_incr) as gross,
	bfs.id_shift,
	bfs.turno_hrs,
	bfs.shift_start_time -- nova variavel celine
from base_for_splits bfs
left join presscount pc
on pc.tz_value between bfs.inicio and bfs.fim
and pc.id_equipment = bfs.id_equipment
and pc.id_site = bfs.id_site
and pc.id_area = bfs.id_area
--and pc.tz_value >= now() - interval '36 hour' 
group by 1,2,3,4,5,6,8,9,10
order by 1,5
), setup_final as ( --**FOI REFEITO PARA PEGAR A SOMA DA DURACAO DO SETUP NO BFS
select bfs.*, 
	    coalesce(sum(date_part('epoch'::text, 
		case 	when s.setup_end is null then null
				when s.setup_end > bfs.fim then bfs.fim else s.setup_end end -
		case 	when s.setup_start is null then null
				when s.setup_start < bfs.inicio then bfs.inicio else s.setup_start end)::bigint),0) as setup_s
from base_for_splits bfs
left join setups s 
on bfs.id_equipment = s.id_equipment
and s.setup_end > bfs.inicio
and s.setup_start <= bfs.fim
group by 1,2,3,4,5,6,7,8,9,10,11
order by 3,2,7
--and teste = 0 -- aqui significa, todas os turnos onde o id_order do pressed é igual ao do packed ou do packeed é null
), stops_raw as (--hard coded para stops tb
select 
	l.id_equipment_line as id_equipment, --esse id_equipment é um equivalente que leva o id_equipment para a mesma base do tp_equipment = 3
	eqv.ts_event as tz_event,
	eqv.ts_end as tz_end,
	case when eqv.cd_category = 'SETUP' then false else eqv.planned_downtime end as planned_downtime,
	eqv.cd_category,
	ignore_cost as mnt
from equipment_events eqv, linhas l
	where eqv.id_equipment in (
				select id_equipment from equipments where event_should_be_displayed is true
				and id_enterprise = 6 and id_area not in (24) and nm_equipment not like '%PRESS%')
and eqv.status = 10
and eqv.id_enterprise = 6
and tstzrange(ts_event,ts_end) && tstzrange(startdate - interval '1 day',enddate + interval '1 day')
and eqv.ts_event >= now() - interval '60 day'
and l.id_equipment = eqv.id_equipment
order by eqv.id_equipment, ts_event
), split_bfs as (
--PRIMEIRO SPLIT DOS DOWNTIMES BASEADO NO BFS (SHIFTS E JOBS)
select st.id_equipment, 
greatest(st.tz_event,bfs.inicio) as tz_event,
least(coalesce(st.tz_end,now()),bfs.fim) as tz_end,
st.planned_downtime,
bfs.inicio,
st.cd_category,
mnt
from stops_raw st
left join base_for_splits bfs
on tstzrange(st.tz_event,coalesce(tz_end,now())) && tstzrange(bfs.inicio, bfs.fim)
and bfs.id_equipment = st.id_equipment
order by 1,2,5
), new_setup as (
--A PARTIR DAQUI EH CRIADO UM TIPO DE SETUP_RUNTIME, COMO SE SEMPRE EXISTISSE UM SETUP
--COMO SE FOSSE UM SETUP AO LADO DO OUTRO. NO FINAL, QUANDO TEM UM ID_ORDER, EH UM SETUP REAL
--ISSO É FEITO PARA PODER CORTAR OS DOWNTIMES EM FUNCAO DOS SETUPS E GARANTIR AS SOMAS CORRETAS DOS DTS MAIS PRA FRENTE
select distinct id_equipment, 
null::int4 as id_order,
--ABAIXO EH CRADO UM SETUP FAKE COMO SE ELE INICIASSE E TERMINASSE 30DIAS ATRAS.
--ISSO EH USADO DEPOIS PARA MARCAR A PARTIDA DO "SETUP-RUNTIME"
now()::date - interval '100 day' as setup_start,
now()::date - interval '100 day' as setup_end
from turnos
union all 
select distinct id_equipment, 
null::int4 as id_order,
--AQUI ABAIXO EH SETUDO UM SETUP COM INICIO E FIM NOW(). ISSO EH USADO PARA O SETUP_RUNTIME IR ATEH O NOW()
now() as setup_start,
now() as setup_end
from turnos
union all 
select 
	id_equipment,
	id_order,
	setup_start,
	setup_end
from setups
order by 1,3
), new_setup2 as (
select 
	id_equipment,
	id_order,
	setup_start,
	setup_end,
	case when lead(id_equipment) over (order by id_equipment, setup_start) = id_equipment 
	then lead(setup_start) over (order by id_equipment, setup_start) else null end as next_stp_start
from new_setup
), new_setup3 as (
--ESSE EH A ESTRUTURA FINAL DE SETUP-RUNTIME. RODANDO PODE VER QUE EH COMO SE FOSSE A TABELA DE OPS
--ASSIM QUE UM SETUP TERMINA, OUTRO "FAKE" INICIA NO MESMO HORARIO QUE O ANTERIOR TERMINOU
--QUANDO O ID_ORDER EH NULL SIGNIFICA QUE EH UM SETUP FEKE OU INEXISTENTE
--ISSO VAI SERVIR UNICAMENTE PARA AJUDAR A CORTAR OS DOWNTIMES
select 
	id_equipment,
	id_order,
	setup_start,
	setup_end
from new_setup2
where next_stp_start is not null
union all 
select 
	id_equipment,
	null as id_order,
	setup_end as setup_start,
	next_stp_start as setup_end
from new_setup2
where next_stp_start is not null
order by 1,3
--), new_setup4 as (
--select *
--from new_setup3
--where setup_end > setup_start
), stops as (
select sbfs.id_equipment,
--tz_event as event_original,
greatest(sbfs.tz_event,nst.setup_start) as tz_event,
least(coalesce(sbfs.tz_end,now()),nst.setup_end) as tz_end,
sbfs.planned_downtime,
nst.setup_start, --pode ser retirado 2024-07-31
nst.setup_end, --pode ser retirado 2024-07-31
nst.id_order, --pra mostrar se era um setup mesmo ou "fake" feito pelo eduardo
sbfs.cd_category,
mnt
from split_bfs sbfs
left join new_setup3 nst
on tstzrange(sbfs.tz_event,coalesce(sbfs.tz_end,now())) && tstzrange(nst.setup_start, nst.setup_end)
and nst.id_equipment = sbfs.id_equipment
and nst.setup_end > nst.setup_start
order by 1,3,6
), stops2 as (
--esse é a nova logica para DT planned que impacta num setup
--o plan_dt_impact_spt is true é porque esse plannedd DT está se sobrepondo o evento de setup
--assim, esse evento com plan_dt_impact_spt = true precisaria ser removido do tempo de setup.
--os demais planned_downtime não deveriam ser removidos do setup e deveriam calcular normalmente
select --s.*,
s.id_equipment,
s.tz_event,
s.tz_end,
s.planned_downtime,
--IMPORTANTE QUE A CATEGORIA NAO SEJA NULL PARA QUE AS LOGICAS MAIS PRA FRENTE FUNCIONEM
case when s.cd_category is null then 'no-reason-input' else s.cd_category end as cd_category,
mnt,
case when s.id_order is null then FALSE else TRUE end as superposed_stp,
case 
	when stp.id_equipment is null then false 
	when stp.id_equipment is not null and planned_downtime is true then true 
	else false end as plan_dt_impact_spt
from stops s
left join setups stp
on s.tz_end > stp.setup_start
and s.tz_event <= stp.setup_end
and s.id_equipment = stp.id_equipment
order by s.id_equipment, s.tz_event
), stops3 as (
-- aqui tem que colocar um distinct senão pode duplicar stops que estao sobre mais de um setup
select 
	distinct *,
	--TODAS AS POSSIBILIDADES DE TIPOS DE DTs SAO CONFIGURADOS AQUI
	--IMPORTANTE PERCEBER QUE EXISTE UMA PROCURA POR TEXTO E EH IMPORTANTE QUE ELE NÃO MUDE E SEJA PADRAO PARA TODAS AS LINHAS
	extract(epoch from coalesce(tz_end,now()) - tz_event) as duration_s,
	case 
		when planned_downtime is false and cd_category = 'RESSOURCES' and superposed_stp is false then 1
		when planned_downtime is false and cd_category = 'RESSOURCES' and superposed_stp is true then 2
		when planned_downtime is false and mnt is true and cd_category != 'RESSOURCES' and superposed_stp is false then 3
		when planned_downtime is false and mnt is true and cd_category != 'RESSOURCES' and superposed_stp is true then 4
		when planned_downtime is false and mnt is false and cd_category != 'RESSOURCES' and superposed_stp is false then 5
		when planned_downtime is false and mnt is false and cd_category != 'RESSOURCES' and superposed_stp is true then 6
		when planned_downtime is true and mnt is true and superposed_stp is false then 7
		when planned_downtime is true and mnt is true and superposed_stp is true then 8
		when planned_downtime is true and mnt is false and superposed_stp is false then 9
		when planned_downtime is true and mnt is false and superposed_stp is true then 10
	end as cat_dt_logics
from stops2
order by cat_dt_logics
--********************************************************************************
--FUNCIONANDO ATEH ESSE PONTO COM AS NOVAS LOGICAS DE DTS
), stops_final as (
select 
	stpf.*,
	--DETERMINACAO DAS LOGICAS DE SOMAS DE DOWNTIME
	--PRECISA SER DEFINIDO CORRETAMENTE COM A MONTEBELLO
	coalesce(stpf.setup_s,0) - sum(case when st.cat_dt_logics in (2,4,8,10) then st.duration_s else 0 end) as stp_s,
	sum(case when st.cat_dt_logics in (7,8,9,10) then st.duration_s else 0 end) as plan_s,
	sum(case when st.cat_dt_logics in (5) then st.duration_s else 0 end) as pro_s,
	sum(case when st.cat_dt_logics in (1,2) then st.duration_s else 0 end) as res_s,
	sum(case when st.cat_dt_logics in (3,4) then st.duration_s else 0 end) as mnt_s,
	sum(case when st.cat_dt_logics in (6) then st.duration_s else 0 end) as discart_s
from setup_final stpf
left join stops3 st
on st.tz_event < stpf.fim
and st.tz_end > stpf.inicio
--and st.tz_end >= now() - interval '36 hour'
and stpf.id_equipment = st.id_equipment
group by 1,2,3,4,5,6,7,8,9,10,11,12
order by 3,2,7
), final_and_press as (
select 
	f.*,
	pqty.gross
from stops_final f
left join press_quantity pqty
on	f.id_equipment = pqty.id_equipment
and	f.cd_shift = pqty.cd_shift
and	f.ts_value_production = pqty.ts_value_production
and	f.id_order = pqty.id_order
and	f.inicio = pqty.inicio
and	f.fim = pqty.fim
and	f.id_shift = pqty.id_shift
and	f.turno_hrs = pqty.turno_hrs
), packed_quantity as (--importannte aqui as excessoes---olhar testes acima e procurar job 12345 
select 
	bfs.id_equipment,
	l.Label_Job,
	bfs.id_order,
	bfs.inicio,
	bfs.fim,
	case when sum(l.Label_amount) is null then 0 else sum(l.Label_amount) end as net,
	bfs.id_shift
from base_for_splits bfs--, linhas eq
left join labels l
on l.tz_value between bfs.inicio and bfs.fim - interval '1 second'
and l.id_equipment = bfs.id_equipment
group by 1,2,3,4,5,7
order by 1,4,2
), press_packed_final as (
--selecionar apenas os casos onde teste = 0 pois nesses sempre existe press e packed com mesmo id_order no mesmo turno
--no final teria que fazer um union all com todos as tinhas de teste = 1, ajeitando as colunas para isso
--cuidar aqui para que o press count não seja somado mais de uma vez
select 
	f.id_equipment,
	f.cd_shift,
	f.ts_value_production,
	f.id_order,
	(date_part('epoch'::text, f.fim - f.inicio))::bigint as shift_duration, 
	f.gross as press_count,
	pack.net as packed_qty,
	f.stp_s,
	pack.label_job,
	f.id_shift,
	f.turno_hrs,
	f.plan_s,
	f.pro_s,
	f.res_s,
	f.mnt_s,
	f.discart_s,
	f.shift_start_time -- nova variavel celine
from final_and_press f
left join packed_quantity pack
on f.inicio = pack.inicio
and f.fim = pack.fim
and f.id_equipment = pack.id_equipment
and f.id_order = pack.label_job::bigint
union all 
select 
	f.id_equipment,
	f.cd_shift,
	f.ts_value_production,
	pack.label_job::bigint as id_order,
	0 as shift_duration, 
	0 as press_count,
	pack.net as packed_qty,
	0 as stp_s,
	null as label_job,
	f.id_shift,
	f.turno_hrs,
	0 as plan_s,
	0 as pro_s,
	0 as res_s,
	0 as mnt_s,
	0 as discart_s,
	f.shift_start_time -- nova variavel celine
from final_and_press f
inner join packed_quantity pack
on f.inicio = pack.inicio
and f.fim = pack.fim
and f.id_equipment = pack.id_equipment
and pack.net is not null
and pack.net != 0
and f.id_order != pack.label_job::bigint
order by id_equipment,ts_value_production, cd_shift
--FUNCIONANDO ATEH AQUI
), shift_report as (
select 
	ppf.id_equipment,
	eq.cd_equipment as line,
	ppf.cd_shift as shift,
	ppf.turno_hrs,
	ppf.ts_value_production as day,
	ppf.id_order as job,
	ppf.shift_duration as shift_duration_s,
	lower(pos.runtime_timerange_new) at time zone 'America/Montreal' as job_sequence, --mudar
	ppf.stp_s::int,
	ppf.plan_s::int,
	ppf.pro_s::int,
	ppf.res_s::int,
	ppf.mnt_s::int,
	ppf.discart_s::int,
	(ppf.pro_s + ppf.res_s + ppf.mnt_s)::int as total_unplan_s,
	(ppf.shift_duration-ppf.stp_s-ppf.plan_s-ppf.pro_s-ppf.res_s-ppf.mnt_s)::int as running_s,
	coalesce(ppf.press_count,0) as prss_qty,
	coalesce(ppf.packed_qty,0) as packed_qty,
	shi.sequence_position as shift_number,
	ppf.shift_start_time at time zone 'America/Montreal' as shift_start_time,
	concat(
	TO_CHAR(eq.id_equipment, 'FM0000'),
	TO_CHAR(coalesce(ppf.id_order,0), 'FM0000000'),
	TO_CHAR(ppf.shift_start_time at time zone 'America/Montreal','YYYYMMDDHH24')) as index1
from press_packed_final ppf
left join equipments eq
on ppf.id_equipment = eq.id_equipment
and eq.id_enterprise = 6
and eq.tp_equipment = 3
left join shifts shi
on shi.id_shift = ppf.id_shift
and shi.id_enterprise = 6
left join po_sequence pos
on ppf.id_order = pos.id_order --mudar
and tstzrange(ppf.shift_start_time,ppf.shift_start_time +interval '12 hour') && pos.runtime_timerange_new --mudar
), validation as (
SELECT evs.*,
(txt_validation_notes->'LastConfirm'->>'ts_confirm')::timestamp at time zone 'UTC' at time zone 'America/Montreal' as ts_confirma,
		case when txt_validation_notes is not null then 
  			concat(
  		to_char((txt_validation_notes->'LastConfirm'->>'ts_confirm')::timestamp at time zone 'UTC' at time zone 'America/Montreal','YYYY-MM-DD HH24:MI'),' | ',
  		txt_validation_notes->'LastConfirm'->>'user',' | Approval: ',
  		txt_validation_notes->'LastConfirm'->>'approved', ' | ',
  		txt_validation_notes->'LastConfirm'->>'note') 
  		else null end as teste,
  		txt_validation_notes->'LastConfirm'->>'note' as nota
FROM  equipment_validation_shift evs 
--where txt_validation_notes is not null
where ts_value_production >= (select start_day from start_counting_day) - interval '1 day'
union all
SELECT evs.*,
		(value->>'ts_confirm')::timestamp at time zone 'UTC' at time zone 'America/Montreal' as ts_confirma,
		case when txt_validation_notes is not null then 
  			concat(
  		to_char((value->>'ts_confirm')::timestamp at time zone 'UTC' at time zone 'America/Montreal','YYYY-MM-DD HH24:MI'),' | ',
  		value->>'user',' | Approval: ',
  		value->>'approved', ' | ',
  		value->>'note')
  		else null end as teste,
  		txt_validation_notes->'LastConfirm'->>'note' as note
  FROM  equipment_validation_shift evs,
  jsonb_each(txt_validation_notes->'history') AS each_item(key, value)
  --where txt_validation_notes is not null
  where ts_value_production >=  (select start_day from start_counting_day) - interval '1 day'
  ), validation_final as (
  select 
  	index1,
  	id_equipment,
  	validation,
  array_to_string(array_agg(teste order by ts_confirma desc), E'\n') as validation_infos,
  array_to_string(array_agg(nota order by ts_confirma desc), E'\n') as validation_nota
  from validation
  group by 1,2,3
  ), shift_report_final as (
select 
	f4.*,
	evs.validation,
	evs.validation_infos,
	evs.validation_nota
from shift_report f4
left join validation_final evs
on f4.index1 = evs.index1
and f4.id_equipment = evs.id_equipment
), shift_report_final2 as (
select
	id_equipment,
	line,
	shift,
	turno_hrs,
	day,
	job,
	sum(shift_duration_s) as shift_duration_s,
	--NO REPORT MOSTRA UMA VARIAVEL DE TEMPO TOTAL 
	sum(stp_s) as stp_s,
	sum(running_s) as running_s,
	sum(prss_qty) as prss_qty,
	sum(packed_qty) as packed_qty,
	sum(plan_s) as plan_s,
	sum(pro_s) as pro_s,
	sum(res_s) as res_s,
	sum(mnt_s) as mnt_s,
	sum(discart_s) as discart_s,
	sum(total_unplan_s) as total_unplan_s,
	job_sequence, --mudar
	shift_number,
	shift_start_time,
	index1,
	validation,
	validation_infos,
	validation_nota
from shift_report_final
group by 1,2,3,4,5,6,18,19,20,21,22,23,24
order by line,shift_start_time, shift_number,job_sequence
), shift_report_final3 as (
select 
id_equipment,
	line,
	shift,
	turno_hrs,
	day,
	job,
	shift_duration_s::numeric(20,6),
	--ABAIXO MOSTRA A SOMA DE TODO O TEMPO PARADO INCLUSIVE SETUP
	((stp_s+plan_s+res_s+mnt_s+
	(pro_s - (case when (stp_s - discart_s) >= pro_s then pro_s else (stp_s - discart_s) end))))::numeric(20,6) as dt_duration_s,
	stp_s::numeric(20,6),
	(running_s + (case when (stp_s - discart_s) >= pro_s then pro_s else (stp_s - discart_s) end))::numeric(20,6) as running_s,
	prss_qty,
	packed_qty,
	plan_s::numeric(20,6),
	--NESSE CASO VERIFICA SE O TEMPO DE discart_s eh menor que o tempo de setup e se sim subtrai a diferença do pro_s
	--exemplo: setup de 3h e o tempo de dt_unplan sobreposto eh de 2,5h e o tempo de dt_unplan nao sobreposto eh de 45min
	--nesse caso eh necessario remover 30min do dt_unplan nao sobreposto, senao a linha mostraria muito tempo parada.
	--essa mesma logica eh usada acima para o tempo tutal de DT e o running
	(pro_s - (case when (stp_s - discart_s) >= pro_s then pro_s else (stp_s - discart_s) end))::numeric(20,6) as pro_s,
	res_s::numeric(20,6),
	mnt_s::numeric(20,6),
	discart_s::numeric(20,6),
	(res_s+mnt_s+(pro_s - (case when (stp_s - discart_s) >= pro_s then pro_s else (stp_s - discart_s) end)))::numeric(20,6) as dt_unplan_s,
	job_sequence,
	shift_number,
	shift_start_time,
	index1,
	validation,
	validation_infos,
	validation_nota
	from shift_report_final2
	),shift_report_final4 as (
	select 
	line,
	shift,
	turno_hrs,
	day,
	job,
	(shift_duration_s)::numeric(20,6)/3600 as shift_duration_h,
	dt_duration_s::numeric(20,6)/3600 as dt_duration_h,
	stp_s::numeric(20,6)/3600 as setup_duration_h,
	running_s::numeric(20,6)/3600 as  running,
	prss_qty,
	packed_qty,
	shift_number,
	job_sequence,
	plan_s::numeric(20,6)/3600 as dt_plan_h, 
	dt_unplan_s::numeric(20,6)/3600 as dt_unplan_h,
	shift_start_time,
	index1,
	id_equipment,
   	(pro_s)::numeric(20,6)/3600 as pro_h,
	(res_s)::numeric(20,6)/3600 as res_h,
	(mnt_s)::numeric(20,6)/3600 as mnt_h,
	(discart_s)::numeric(20,6)/3600 as discart_h,
		jsonb_build_object(
   	   '0', line,
       '1', (shift_duration_s/3600)::numeric(10,4),
       '2', (dt_duration_s/3600)::numeric(10,4),
       '3', (stp_s/3600)::numeric(10,4),
       '4', (running_s/3600)::numeric(10,4),
       '5', prss_qty::int,
       '6', packed_qty::int,
       '7', (dt_unplan_s/3600)::numeric(10,4),
       '8', (plan_s/3600)::numeric(10,4),
       '9', (pro_s/3600)::numeric(10,4),
       '10', (res_s/3600)::numeric(10,4),
       '11', (mnt_s/3600)::numeric(10,4)
   ) AS index2
	--validation,
	--validation_infos,
	--validation_nota
from shift_report_final3
)
select distinct on (line,shift,day,job) *	
from shift_report_final4

$function$
;

-- ==== FUNCTION get_downtime_sync_enterprsie_06 ====
CREATE OR REPLACE FUNCTION public.get_downtime_sync_enterprsie_06()
 RETURNS SETOF downtime_sync_enterprise_06
 LANGUAGE sql
 STABLE
AS $function$
with stops as (
select 
	(select stop_threshold_time from equipments where id_equipment = eqev.id_equipment and id_enterprise = 6) as stop_threshold_time,
	eqev.*,
	false as manual_stop
from equipment_events eqev
	where eqev.id_enterprise = 6
	and eqev.ts_event >= now() - interval '15 day'
	and status = 10
	and id_equipment in (select id_equipment from equipments where id_enterprise = 6 and event_should_be_displayed = true)
union all
select 
	0 as stop_threshold_time,
	*,
	-- F3 parity: equipment_events gained new-stack columns (ingested_at,
	-- source_seq) that equipment_events_man lacks; the F1 function's stored
	-- plan predates them. Align the UNION branch positionally so the verbatim
	-- body re-creates. Both are dropped at the fixed SETOF projection.
	NULL::timestamp with time zone as ingested_at,
	NULL::bigint as source_seq,
	true as manual_stop
from equipment_events_man
	where id_enterprise = 6
	and ts_event >= now() - interval '15 day'
	--and fault = 123
), stops2 as (
select
	*,
	'automatic' as MethodType
	--seleciona todas as paradas com duracao maior que o stop_threshold_time
from stops
	where duration >= stop_threshold_time
	and manual_stop is false
union all
select
	*,
	'microstop' as MethodType
-- seleciona todas as paradas com duracao menor q stop_threshold_time e que foram justificadas
--devem ser chamadas de microparadas mesmo?
from stops
	where duration between 1 and stop_threshold_time
	and cd_machine is not null
	and manual_stop is false
union all
select
	*,
	'microstop' as MethodType
-- seleciona todas as paradas com duracao menor q stop_threshold_time que não seja site 20 (Montreal)
-- do site 20 não eh selecionado pois essas mesma paradas entram como microparadas agrupadas
from stops
	where duration between 1 and stop_threshold_time
	and cd_machine is null
	and id_equipment not in (select id_equipment from equipments where id_site = 20 and tp_equipment = 3)
	and manual_stop is false
union all
select -- seleciona todas as paradas manuais
	*,
	case when fault = 123 then 'grouped_microstops'
		 else 'manual' end as MethodType
from stops
where stop_threshold_time = 0 --isso é definido no union da subquery "stops" como sendo uma parada manual
), stops3 as (
select 
	ignore_cost as mnt, --essa coluna vai ter que estar disponível na de eventos e eventos manuais
	id_equipment_event,
	ts_event,
	ee.ts_end,
	ee.id_equipment,
	case
		when eq.tp_equipment = 2 then eq.id_equipment
		when peq.tp_equipment = 2 then peq.id_equipment
		when ppeq.tp_equipment = 2 then ppeq.id_equipment
		else null end as id_sector,
	coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
	case
		when eq.tp_equipment = 3 then eq.nm_equipment
		when peq.tp_equipment = 3 then peq.nm_equipment
		when ppeq.tp_equipment = 3 then ppeq.nm_equipment
		else null end as nm_equipment,
	case
		when eq.tp_equipment = 2 then eq.nm_equipment
		when peq.tp_equipment = 2 then peq.nm_equipment
		when ppeq.tp_equipment = 2 then ppeq.nm_equipment
		else null end as sector,
	eq.id_area,
	eq.id_site,
	eq.id_parentequipment,
	cd_machine,
	ee.duration,
	case when cd_category is null then '' else cd_category end as cd_category,
	--cd_category,
	cd_category_client,
	ee.desc_category,
	cd_subcategory,
	cd_subcategory_client,
	ee.desc_subcategory,
	txt_downtime_notes,
	st.timezone,
	st.nm_site,
	eq.stop_threshold_time,
	ee.planned_downtime ,
	ee.change_over,
	ers.ts_range,
	pr.packml_topic,
	(select id_order
		from production_orders po 
		where po.id_production_order = (select id_production_order
                            			from production_orders_runtime por
                            			where ee.ts_event <@ por.runtime_timerange
                                		and id_equipment = coalesce (ppeq.id_equipment,
                                		peq.id_equipment,
                                		eq.id_equipment)
                                		)
	),
	sh.cd_shift,
	ers.id_shift,
	ee.id_enterprise,
	ee.last_update,
	manual_stop,
	ee.MethodType
from stops2 ee
left join equipments eq 
	on eq.id_equipment = ee.id_equipment
left join sites st 	
	on eq.id_site = st.id_site
left join equipment_runtime_shift ers 
	on ee.ts_event <@ ers.ts_range
	and ers.id_equipment = ee.id_equipment
left join shifts sh 
	on ers.id_shift = sh.id_shift
left join equipments peq 
	on peq.id_equipment = eq.id_parentequipment
left join equipments ppeq 
	on ppeq.id_equipment = peq.id_parentequipment
join packml_register pr 
	on pr.id_equipment = eq.id_equipment
where (status <> 6 or status is null)
and last_update is not null
and eq.event_should_be_displayed = true
)
select 
	nm_site,
	nm_equipment,
	id_order,
	sector,
	cd_shift,
	ts_event,
	ts_end,
	duration,
	case when cd_machine = '' then null else cd_machine end as cd_machine,
	cd_category_client,
	case when cd_category = '' then null else cd_category end as cd_category,
	case when desc_category = '' then null else desc_category end as desc_category,
	cd_subcategory_client,
	case when cd_subcategory = '' then null else cd_subcategory end as cd_subcategory,
	case when desc_subcategory = '' then null else desc_subcategory end as desc_subcategory,
	txt_downtime_notes,
	id_equipment_event as pack_id,
	packml_topic,
	last_update,
	case
	    when planned_downtime is true then 'planned'
	    else 'unplanned'
	end as DT_Type,
	case 
		when planned_downtime is false and cd_category = 'RESSOURCES'  then 'RES'
		when planned_downtime is false and mnt is true and cd_category != 'RESSOURCES'  then 'MNT'
		when planned_downtime is false and mnt is false and cd_category != 'RESSOURCES' then 'PRO'
	end as DT_SubType,
	mnt as mnt_trigger,
	MethodType
from stops3
	where id_enterprise = 6
	and id_line = any(select e.id_equipment from equipments e where id_enterprise = 6) 
	and last_update >= now() - interval '6 hour'
order by last_update desc
--order by nm_equipment, MethodType
limit 5000


$function$
;

-- ==== FUNCTION get_data_sync_enterprsie_06b ====
CREATE OR REPLACE FUNCTION public.get_data_sync_enterprsie_06b(numdays integer DEFAULT NULL::integer)
 RETURNS SETOF data_sync_enterprise_06b
 LANGUAGE sql
 STABLE
AS $function$
--novo report 
--versao anterior de 2023-10-05 funcionando, salva por eduardo
--novo report 
with data_sync as (
 select 
 	eqvs.ts_value_production as day,
    s.nm_site::varchar(15) as Site,
    s.id_site,
    eqvs.cd_equipment::varchar(6) as line,
    --rse.line::varchar(6),
    eqvs.cd_shift::varchar(6) as shift,
    eqvs.shift_start_time as ShiftStartDate,    
    --rse.shift_start_time at time zone 'America/Montreal' as ShiftStartDate, 
    eqvs.id_order as job,
    ((rse.shift_duration_h-rse.setup_duration_h-rse.dt_plan_h)*60)::NUMERIC(10,1) as TotalAvailableHrsinMin,
    ((rse.dt_plan_h)*60)::NUMERIC(10,1) as DTimeHrsPlannedinMin,
    ((rse.dt_unplan_h)*60)::NUMERIC(10,1) as DTimeHrsUnPlannedinMin,
    ((rse.setup_duration_h)*60)::NUMERIC(10,1) as SetupHoursinMin,
    ((rse.running)*60)::NUMERIC(10,1) as RunHoursinMin,
    rse.prss_qty::bigint as PressCnt,
    rse.packed_qty::bigint as PackCnt,
    pr.packml_topic,
    (case 
        when po.status = 1 then 'available' 
        when po.status = 2 then 'in_progress' 
        when po.status = 3 then 'completed'
        when po.status = 4 then 'paused' 
    end)::varchar(20) as JobStatus,
    lower(por.runtime_timerange)  as JobStartDate,
    upper(por.runtime_timerange) as JobCompletedDate,
    po.ts_creation as CreatedDate,
    case when po.status = 2 then po.last_update else coalesce(po.ts_start_tz,po.last_update,eqvs.ts_creation) end as UpdatedDate,
    eqvs.index1::varchar(25),
    (po.custom_field ->> 'cd_product')::varchar(30) AS cd_product,
 	eqvs.txt_validation_notes,
 	eqvs.validation::bool,
 	eqvs.ts_user_validation,
 	eqvs.nm_user_validation::varchar(15),
 	eqvs.id_validation::bigint,
 	eqvs.ts_creation,
 	eqvs.to_delete,
 	eqvs.last_update,
 	((rse.pro_h)*60)::NUMERIC(10,1) as UnplannedDT_PROinMin,
 	((rse.res_h)*60)::NUMERIC(10,1) as UnplannedDT_RESinMin,
 	((rse.mnt_h)*60)::NUMERIC(10,1) as UnplannedDT_MNTinMin
from equipment_validation_shift eqvs --(aqui paga do relatorio)
left join report_shift_enterprsie_06 rse
on rse.index1 = eqvs.index1
and rse.day >= now() - interval '101 day' --de 41 pra 71 edu 10-fev-25)
left join equipments eq
on eqvs.cd_equipment = eq.nm_equipment and eq.id_enterprise = 6 and eq.tp_equipment = 3
left join sites s
on eq.id_site = s.id_site
left join production_orders po
on po.id_equipment = eq.id_equipment 
and po.id_order = eqvs.id_order
and po.id_enterprise = 6
and po.last_update >= now() - interval '5 month'  --de 3 pra 4 edu 10-fev-25)
left join production_orders_runtime por
on por.id_equipment = eq.id_equipment 
and po.id_production_order = por.id_production_order 
and lower(por.runtime_timerange) at time zone 'America/Montreal' = rse.job_sequence
and por.runtime_timerange && tstzrange(now() - interval '6 month', now())--de 4 pra 5 edu 10-fev-25)
left join packml_register pr
on pr.id_equipment = eq.id_equipment
and pr.id_enterprise = 6
where eqvs.ts_value_production >= now() - interval '100 day' --de 40 pra 70 edu 10-fev-25)
order by rse.line, rse.day desc, rse.shift_number desc, rse.job_sequence desc
)
        select 
            Site,
            line,
            shift,
            ShiftStartDate,
            job,
            cd_product as Item,				--esse eh a info do produto que a celine pediu
            TotalAvailableHrsinMin,
            DTimeHrsPlannedinMin,
            DTimeHrsUnPlannedinMin,
            UnplannedDT_PROinMin,
 			UnplannedDT_RESinMin,
 			UnplannedDT_MNTinMin,
            SetupHoursinMin,
            RunHoursinMin,
            PressCnt,
            PackCnt,
            JobStatus,
            JobStartDate,
            JobCompletedDate,
            CreatedDate,
            UpdatedDate,
            index1 as PackIOTID,
            validation as SupervisorApproval,				-- true para validado
    		ts_user_validation as SupervisorApprovedDate,		--timestamp do horario da valiação os dados
 			txt_validation_notes as SupervisorNotes,	--o note que o supervisor escreveu na validacao dos dados
 			nm_user_validation,		--login do usuário que validou os dados no operator
 			id_validation,			--esse é um id sequencial que em na tabela validation (acho que não precisa)
 			ts_creation,			--timestamp do hoario que a linha de dados foi criada na tabela validation (acho que não precisa)
 			to_delete,				--true para linhas de dados que deixaram de existir
 			greatest(last_update,ts_user_validation) as last_update,				--se houve algum update nos ultimos 21 dias, este horario se reflete aqui. A diferença deste é que olha linha por linha de dados enquanto o UpdatedDate anterior muda por OP,
 			packml_topic,
			last_update as last_update_prod_data
        from data_sync
        --where day >= StartDate
        --and day <= EndDate
        where day >= (now() at time zone 'America/Montreal')::date - coalesce(NumDays,21)*(interval '1 day')
        and day <= (now() at time zone 'America/Montreal')::date


$function$
;


-- ────────────────────────────────────────────────────────────────────────────
-- SECTION C — read-api external SAP-shim backing views (dependency order)
-- ────────────────────────────────────────────────────────────────────────────
-- ==== VIEW v_sap_report_data_sync_customer_13_deb ====
CREATE OR REPLACE VIEW public.v_sap_report_data_sync_customer_13_deb AS  WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '4 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN ers.ts_end > now() THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min.id_equipment,
            agg_equipment_values_1min.id_site,
            agg_equipment_values_1min.id_area,
            agg_equipment_values_1min.ts_value AS tz_value,
            agg_equipment_values_1min.gross_production_incr,
            agg_equipment_values_1min.net_production_incr
           FROM agg_equipment_values_1min,
            start_counting_day scd
          WHERE (agg_equipment_values_1min.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval) AND agg_equipment_values_1min.ts_value >= scd.start_day AND agg_equipment_values_1min.id_enterprise = 13 AND agg_equipment_values_1min.id_site = 29
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value < bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = ANY (ARRAY[2, 9]) THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= e.stop_threshold_time::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < e.stop_threshold_time::double precision THEN 5
                    WHEN dc."position" = 7 THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '4 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 6 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_6
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value < (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_4) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_6 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '4 days'::interval)
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM turnos t
             LEFT JOIN labels_data ld ON t.id_equipment = ld.id_equipment AND ld.ts_value >= t.tz_value AND ld.ts_value < t.tz_end
             LEFT JOIN equipments eq ON eq.id_equipment = t.id_equipment
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM final_jobs fj
             LEFT JOIN final_labels fl ON fl.cd_equipment::text = fj.linie::text AND fl.id_order::integer = fj.auftrag AND fl.ts_value_production = fj.tag AND fl.cd_shift::text = fj.shicht::text
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM final_labels fl
             LEFT JOIN final1 f1 ON fl.cd_equipment::text = f1.linie::text AND fl.id_order::integer = f1.auftrag AND fl.ts_value_production = f1.tag AND fl.cd_shift::text = f1.shicht::text
          WHERE fl.sum_labels IS NOT NULL AND f1.id_order IS NULL
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN missing_jobs_labels.cd_shift::text = 'Frühschicht'::text THEN 1
                    WHEN missing_jobs_labels.cd_shift::text = 'Spätschicht'::text THEN 2
                    WHEN missing_jobs_labels.cd_shift::text = 'Nachtschicht'::text THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, (COALESCE(final10.auftrag, 0::bigint))) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, 0::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.running_h,
    final11.shift_start_time,
    final11.data_type,
    final11.id_order_label
   FROM final11;;

-- ==== VIEW v_sap_report_data_sync_customer_13 ====
CREATE OR REPLACE VIEW public.v_sap_report_data_sync_customer_13 AS  WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '4 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN ers.ts_end > now() THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 13)) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 13 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min.id_equipment,
            agg_equipment_values_1min.id_site,
            agg_equipment_values_1min.id_area,
            agg_equipment_values_1min.ts_value AS tz_value,
            agg_equipment_values_1min.gross_production_incr,
            agg_equipment_values_1min.net_production_incr
           FROM agg_equipment_values_1min,
            start_counting_day scd
          WHERE (agg_equipment_values_1min.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval) AND agg_equipment_values_1min.ts_value >= scd.start_day AND agg_equipment_values_1min.id_enterprise = 13 AND agg_equipment_values_1min.id_site = 13
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 13)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value < bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 13))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = ANY (ARRAY[2, 9]) THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= e.stop_threshold_time::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < e.stop_threshold_time::double precision THEN 5
                    WHEN dc."position" = 7 THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 13
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '4 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 6 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_6
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value < (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_4) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_6 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '4 days'::interval)
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM turnos t
             LEFT JOIN labels_data ld ON t.id_equipment = ld.id_equipment AND ld.ts_value >= t.tz_value AND ld.ts_value < t.tz_end
             LEFT JOIN equipments eq ON eq.id_equipment = t.id_equipment
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM final_jobs fj
             LEFT JOIN final_labels fl ON fl.cd_equipment::text = fj.linie::text AND fl.id_order::integer = fj.auftrag AND fl.ts_value_production = fj.tag AND fl.cd_shift::text = fj.shicht::text
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM final_labels fl
             LEFT JOIN final1 f1 ON fl.cd_equipment::text = f1.linie::text AND fl.id_order::integer = f1.auftrag AND fl.ts_value_production = f1.tag AND fl.cd_shift::text = f1.shicht::text
          WHERE fl.sum_labels IS NOT NULL AND f1.id_order IS NULL
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN missing_jobs_labels.cd_shift::text = 'Frühschicht'::text THEN 1
                    WHEN missing_jobs_labels.cd_shift::text = 'Spätschicht'::text THEN 2
                    WHEN missing_jobs_labels.cd_shift::text = 'Nachtschicht'::text THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, (COALESCE(final10.auftrag, 0::bigint))) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, 0::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.running_h,
    final11.shift_start_time,
    final11.data_type,
    final11.id_order_label
   FROM final11
UNION ALL
 SELECT v_sap_report_data_sync_customer_13_deb.linie,
    v_sap_report_data_sync_customer_13_deb.tag,
    v_sap_report_data_sync_customer_13_deb.shicht,
    v_sap_report_data_sync_customer_13_deb.shicht_nummer,
    v_sap_report_data_sync_customer_13_deb.auftrag,
    v_sap_report_data_sync_customer_13_deb.sum_labels,
    v_sap_report_data_sync_customer_13_deb.rumpfe,
    v_sap_report_data_sync_customer_13_deb.gutmenge,
    v_sap_report_data_sync_customer_13_deb.rustzeit,
    v_sap_report_data_sync_customer_13_deb.produktionszeit,
    v_sap_report_data_sync_customer_13_deb.geplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.ungeplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.matfehler_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.no_order,
    v_sap_report_data_sync_customer_13_deb.auftrag_startzeit,
    v_sap_report_data_sync_customer_13_deb.running_h,
    v_sap_report_data_sync_customer_13_deb.shift_start_time,
    v_sap_report_data_sync_customer_13_deb.data_type,
    v_sap_report_data_sync_customer_13_deb.id_order_label
   FROM v_sap_report_data_sync_customer_13_deb;;

-- ==== VIEW v_13_site_deb_sap_report ====
CREATE OR REPLACE VIEW public.v_13_site_deb_sap_report AS  WITH dias AS (
         SELECT generate_series(timezone('Europe/Budapest'::text, now())::date - '3 days'::interval, timezone('Europe/Budapest'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Budapest'::text, equipment_runtime_shift.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Budapest'::text, equipment_runtime_shift.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            equipment_runtime_shift.ts_value AS shift_start_time,
            equipment_runtime_shift.id_equipment,
            equipment_runtime_shift.cd_shift,
            equipment_runtime_shift.id_shift,
            equipment_runtime_shift.ts_value_production,
            equipment_runtime_shift.ts_value AS tz_value,
                CASE
                    WHEN equipment_runtime_shift.ts_end > now() THEN now()
                    ELSE equipment_runtime_shift.ts_end
                END AS tz_end
           FROM equipment_runtime_shift,
            start_counting_day scd
          WHERE (equipment_runtime_shift.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND equipment_runtime_shift.ts_value_production >= scd.start_day AND equipment_runtime_shift.ts_value < now()
          ORDER BY equipment_runtime_shift.id_equipment, equipment_runtime_shift.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min.id_equipment,
            agg_equipment_values_1min.id_site,
            agg_equipment_values_1min.id_area,
            agg_equipment_values_1min.ts_value AS tz_value,
            agg_equipment_values_1min.gross_production_incr,
            agg_equipment_values_1min.net_production_incr
           FROM agg_equipment_values_1min,
            start_counting_day scd
          WHERE (agg_equipment_values_1min.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min.ts_value >= (now() - '3 days'::interval) AND agg_equipment_values_1min.ts_value >= scd.start_day AND agg_equipment_values_1min.id_enterprise = 13 AND agg_equipment_values_1min.id_site = 29
        ), labels_extract AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), negative_labels AS (
         SELECT l.tz_value,
            l.id_equipment,
            l.label_job,
            l.label_amount,
            po.job_end,
                CASE
                    WHEN po.job_end IS NULL THEN 0::bigint
                    ELSE date_part('epoch'::text, l.tz_value - po.job_end)::bigint
                END AS diff_s
           FROM labels_extract l
             LEFT JOIN prod_orders po ON l.label_job::integer = po.id_order
        ), labels AS (
         SELECT DISTINCT negative_labels.tz_value,
            negative_labels.id_equipment,
            negative_labels.label_job,
            negative_labels.label_amount
           FROM negative_labels
          WHERE negative_labels.diff_s <= 10800
          ORDER BY negative_labels.tz_value
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value <= bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description,
            category_level.id_equipment
           FROM category_level
          ORDER BY category_level.id_equipment, category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = 2 THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= e.stop_threshold_time::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < e.stop_threshold_time::double precision THEN 5
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description AND ee.id_equipment = dc.id_equipment
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '15 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '3 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value <= (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_5) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_5)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_5) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_4 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            timezone('Europe/Budapest'::text, ppf.shift_start_time) AS shift_start_time,
            timezone('Europe/Budapest'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        )
 SELECT shift_report.line,
    shift_report.shift,
    shift_report.shift_hrs,
    shift_report.day,
    shift_report.job,
    shift_report.prss_qty AS gross,
    shift_report.net_sensor AS net,
    shift_report.running_s AS gyartasi_ido,
    shift_report.dt_0 AS beallitasi_ido,
    shift_report.dt_1 AS muszaki_hiba,
    shift_report.dt_2 AS tervezett_karb,
    shift_report.dt_3 AS anyagproblema,
    shift_report.dt_4 AS nem_indokolt_ido,
    shift_report.total_dt_s AS total_dt,
    shift_report.job_sequence AS job_start,
    shift_report.shift_start_time,
    shift_report.shift_number,
    shift_report.id_equipment,
    13 AS id_eterprise
   FROM shift_report
  WHERE shift_report.day >= (timezone('Europe/Budapest'::text, now()) - '2 days'::interval);;

-- ==== VIEW v_piot_production_data_sync_cust6 ====
CREATE OR REPLACE VIEW public.v_piot_production_data_sync_cust6 AS  SELECT pdse.indice_geral AS uniqueid,
    pdse.prev_indice_geral AS previousuniqueid,
    pdse.packiotid,
    pdse.site,
    pdse.line,
    pdse.shift,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.shiftstartdate)) AS shiftstartdate,
    pdse.job::integer AS job,
    pdse.item,
    COALESCE(pdse.totalavailablehrsinmin, 0::numeric)::numeric(10,2) AS totalavailablehrsinmin,
    COALESCE(pdse.dtimehrsplannedinmin, 0::numeric)::numeric(10,2) AS dtimehrsplannedinmin,
    COALESCE(pdse.dtimehrsunplannedinmin, 0::numeric)::numeric(10,2) AS dtimehrsunplannedinmin,
    COALESCE(pdse.unplanneddt_proinmin, 0::numeric)::numeric(10,2) AS unplanneddt_proinmin,
    COALESCE(pdse.unplanneddt_resinmin, 0::numeric)::numeric(10,2) AS unplanneddt_resinmin,
    COALESCE(pdse.unplanneddt_mntinmin, 0::numeric)::numeric(10,2) AS unplanneddt_mntinmin,
    COALESCE(pdse.setuphoursinmin, 0::numeric)::numeric(10,2) AS setuphoursinmin,
    COALESCE(pdse.runhoursinmin, 0::numeric)::numeric(10,2) AS runhoursinmin,
    COALESCE(pdse.presscnt, 0::bigint)::integer AS presscnt,
    COALESCE(pdse.packcnt, 0::bigint)::integer AS packcnt,
    pdse.jobstatus,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.jobstartdate)) AS jobstartdate,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.jobcompleteddate)) AS jobcompleteddate,
    pdse.final_trans_status AS transstatus,
        CASE
            WHEN pdse.supervisorapproval IS TRUE THEN 1
            ELSE 0
        END AS supervisorapproval,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.supervisorapproveddate)) AS supervisorapproveddate,
    pdse.supervisornotes::text AS supervisornotes,
    date_trunc('second'::text, pdse.real_update) AS last_update
   FROM production_data_sync_enterprise_06 pdse
  WHERE pdse.shiftstartdate >= (now() - '21 days'::interval) AND (pdse.final_trans_status::text <> ALL (ARRAY['H'::character varying::text, 'D'::character varying::text])) AND pdse.shiftstartdate <= '2025-02-20 16:00:00+00'::timestamp with time zone
UNION ALL
 SELECT pdse.indice_geral AS uniqueid,
    pdse.prev_indice_geral AS previousuniqueid,
    pdse.packiotid,
    pdse.site,
    pdse.line,
    pdse.shift,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.shiftstartdate)) AS shiftstartdate,
    pdse.job::integer AS job,
    pdse.item,
    COALESCE(pdse.totalavailablehrsinmin, 0::numeric)::numeric(10,2) AS totalavailablehrsinmin,
    COALESCE(pdse.dtimehrsplannedinmin, 0::numeric)::numeric(10,2) AS dtimehrsplannedinmin,
    COALESCE(pdse.dtimehrsunplannedinmin, 0::numeric)::numeric(10,2) AS dtimehrsunplannedinmin,
    COALESCE(pdse.unplanneddt_proinmin, 0::numeric)::numeric(10,2) AS unplanneddt_proinmin,
    COALESCE(pdse.unplanneddt_resinmin, 0::numeric)::numeric(10,2) AS unplanneddt_resinmin,
    COALESCE(pdse.unplanneddt_mntinmin, 0::numeric)::numeric(10,2) AS unplanneddt_mntinmin,
    COALESCE(pdse.setuphoursinmin, 0::numeric)::numeric(10,2) AS setuphoursinmin,
    COALESCE(pdse.runhoursinmin, 0::numeric)::numeric(10,2) AS runhoursinmin,
    COALESCE(pdse.presscnt, 0::bigint)::integer AS presscnt,
    COALESCE(pdse.packcnt, 0::bigint)::integer AS packcnt,
    pdse.jobstatus,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.jobstartdate)) AS jobstartdate,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.jobcompleteddate)) AS jobcompleteddate,
    pdse.final_trans_status AS transstatus,
        CASE
            WHEN pdse.supervisorapproval IS TRUE THEN 1
            ELSE 0
        END AS supervisorapproval,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.supervisorapproveddate)) AS supervisorapproveddate,
    pdse.supervisornotes::text AS supervisornotes,
    date_trunc('second'::text, pdse.real_update) AS last_update
   FROM production_data_sync_enterprise_06 pdse
  WHERE pdse.shiftstartdate >= (now() - '365 days'::interval) AND pdse.shiftstartdate > '2025-02-20 16:00:00+00'::timestamp with time zone AND pdse.real_update >= (now() - '06:00:00'::interval)
  ORDER BY 27 DESC;;





COMMIT;
