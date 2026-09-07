--
-- PostgreSQL database dump
--

\restrict 2kWdUZ5czkc5UcnOMR6js9F0CrkNdrGqi7dz8kxTA863iZqLrPZ4CMf63E6cAT2

-- Dumped from database version 15.17
-- Dumped by pg_dump version 15.17

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: box_scans_no_mutate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.box_scans_no_mutate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'box_scans is append-only (attempted %); model corrections as a new void scan',
        TG_OP USING ERRCODE = 'restrict_violation';
END;
$$;


--
-- Name: bronze_raw_no_mutate(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bronze_raw_no_mutate() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION
        'Bronze raw table %.% is append-only (attempted %); corrections are new appended rows, never in-place edits',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
END;
$$;


--
-- Name: current_tenant(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_tenant() RETURNS integer
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::int
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: data_sync_enterprise_06b; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.data_sync_enterprise_06b (
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


--
-- Name: get_data_sync_enterprsie_06b(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_data_sync_enterprsie_06b(numdays integer DEFAULT NULL::integer) RETURNS SETOF public.data_sync_enterprise_06b
    LANGUAGE sql STABLE
    AS $$
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


$$;


--
-- Name: downtime_sync_enterprise_06; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.downtime_sync_enterprise_06 (
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


--
-- Name: get_downtime_sync_enterprsie_06(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_downtime_sync_enterprsie_06() RETURNS SETOF public.downtime_sync_enterprise_06
    LANGUAGE sql STABLE
    AS $$
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
left join equipment_oee_shift ers 
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


$$;


--
-- Name: get_report_shift_enterprsie_06c(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_report_shift_enterprsie_06c(startdate date, enddate date) RETURNS TABLE(line character varying, shift character varying, turno_hrs text, day date, job bigint, shift_duration_h numeric, dt_duration_h numeric, setup_duration_h numeric, running numeric, prss_qty double precision, packed_qty double precision, shift_number integer, job_sequence timestamp without time zone, dt_plan_h numeric, dt_unplan_h numeric, shift_start_time timestamp without time zone, index1 text, id_equipment integer, pro_h numeric, res_h numeric, mnt_h numeric, discart_h numeric, index2 jsonb)
    LANGUAGE sql STABLE
    AS $$
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
from equipment_oee_shift, start_counting_day scd
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

$$;


--
-- Name: h_downtimes_duration_by_category; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_downtimes_duration_by_category (
    reason text,
    total_time bigint,
    id_enterprise integer,
    id_equipment integer
);


--
-- Name: h_piot_downtimes_duration_by_category(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_downtimes_duration_by_category(idequipment integer) RETURNS SETOF public.h_downtimes_duration_by_category
    LANGUAGE sql STABLE
    AS $$

-- total_time is derived, not just SUM(duration): status_type=0 (line/sector)
-- events for C-PACK are mirrored OPEN (ts_end/duration NULL) and only backfilled
-- later by the mirror-worker close-sweep from prod's authoritative close. Until
-- that lands, SUM(duration) over unclosed stops → NULL → the availability-by-
-- category widget rendered empty bars. Derive each stop's duration from the next
-- state transition (lead(ts_event)) — identical semantics to the events deriver's
-- coalesce(lead(ts_event), now()) — and prefer the stored column when present so
-- already-closed rows keep their authoritative value. See the fix2-durations
-- root-cause note.
 WITH ev AS (
	SELECT
		id_equipment,
		id_enterprise,
		ts_event,
		status,
		desc_category,
		planned_downtime,
		duration,
		lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event) AS next_ts
	FROM
		equipment_events
	WHERE
		id_equipment = idEquipment
 )
 SELECT
	LOWER(desc_category) AS reason,
	SUM(COALESCE(duration, EXTRACT(EPOCH FROM (COALESCE(next_ts, now()) - ts_event))::int)) AS total_time,
	id_enterprise,
	id_equipment
FROM
	ev
WHERE
	desc_category IS NOT NULL
	AND status = 10
	AND planned_downtime = FALSE
	AND EXTRACT(YEAR FROM ts_event) = EXTRACT(YEAR FROM CURRENT_DATE)
	AND EXTRACT(MONTH FROM ts_event) = EXTRACT(MONTH FROM CURRENT_DATE)
GROUP BY
	LOWER(desc_category),
	id_enterprise,
	id_equipment
ORDER BY
	total_time DESC;

$$;


--
-- Name: h_downtimes_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_downtimes_table (
    ts_event timestamp with time zone,
    nm_equipment character varying,
    cd_machine character varying,
    duration integer,
    cd_category character varying,
    txt_category character varying,
    cd_subcategory character varying,
    txt_subcategory character varying,
    txt_downtime_notes character varying,
    id_order integer,
    cd_shift character varying,
    id_enterprise integer
);


--
-- Name: h_piot_get_downtimes(timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes(_tsstart timestamp without time zone DEFAULT (now() - '1 mon'::interval), _tsend timestamp without time zone DEFAULT now()) RETURNS SETOF public.h_downtimes_table
    LANGUAGE sql STABLE
    AS $$
select
	ts_event,
	(select nm_equipment from equipments e where e.id_equipment = ee.id_equipment),
	cd_machine,
	duration,
	cd_category,
	cd_category txt_category, --change to description when available
	cd_subcategory,
	cd_subcategory txt_subcategory, --change to description when available
	txt_downtime_notes,
	(select id_order from production_orders po where po.id_production_order  = (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)),
	(select cd_shift from shift_hours sh where (extract('epoch' from (ts_event - date_trunc('week', ts_event))))::int4 <@ int4range(sh.begin_time, sh.end_time) and ((select id_area from equipments where id_equipment = ee.id_equipment) = sh.id_area)),
	id_enterprise 
from
	equipment_events ee
where 
	status = 10
	and ts_event >= _tsstart
	and ts_event < _tsend
	and 
		(
		duration >= COALESCE((select stop_threshold_time from equipments e where e.id_equipment = ee.id_equipment), 0)
			or
		duration is null
		)
	and (select tp_equipment from equipments where id_equipment = ee.id_equipment)=3
order by ts_event desc;
$$;


--
-- Name: h_downtimes_table_with_sector_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_downtimes_table_with_sector_2 (
    id_equipment_event bigint,
    ts_event timestamp without time zone,
    ts_end timestamp without time zone,
    id_equipment integer,
    id_sector integer,
    nm_equipment character varying,
    sector character varying,
    cd_machine character varying,
    duration integer,
    cd_category character varying,
    txt_category character varying,
    cd_subcategory character varying,
    txt_subcategory character varying,
    txt_downtime_notes character varying,
    id_order integer,
    cd_shift character varying,
    id_shift integer,
    id_enterprise integer,
    planned_downtime boolean,
    change_over boolean,
    shift_ts_range tstzrange,
    stop_threshold_time integer
);


--
-- Name: h_piot_get_downtimes_events(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_events(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false) RETURNS SETOF public.h_downtimes_table_with_sector_2
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_sectors int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=2
						 and case
						 		when cardinality(in_ids_sectors::int[]) = 0 then true
						 		else id_equipment = any( in_ids_sectors::int[])
						 	 end );

begin
return query

select * from (
select
	id_equipment_event,
	(ts_event at time zone (timezone))::timestamp as ts_event,
	(ts_end at time zone (timezone))::timestamp as ts_end,
	id_equipment,
	id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(
	select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case
			when eq.tp_equipment = 2 then eq.id_equipment
			when peq.tp_equipment = 2 then peq.id_equipment
			when ppeq.tp_equipment = 2 then ppeq.id_equipment
			else null
		end as id_sector,
		coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
		case
			when eq.tp_equipment = 3 then eq.nm_equipment
			when peq.tp_equipment = 3 then peq.nm_equipment
			when ppeq.tp_equipment = 3 then ppeq.nm_equipment
			else null
		end as nm_equipment,
		case
			when eq.tp_equipment = 2 then eq.nm_equipment
			when peq.tp_equipment = 2 then peq.nm_equipment
			when ppeq.tp_equipment = 2 then ppeq.nm_equipment
			else null
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		desc_category txt_category,
		cd_subcategory,
		desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,--eduardo 2024-0715 
		--case when ers.ts_range is null then tstzrange(ts_event,coalesce(ee.ts_end,now())) else ers.ts_range end as ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then 
					(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment))
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
		),
		sh.cd_shift, --eduardo 2024-0715 para que todos eventos sejam mostrados
		ers.id_shift, --eduardo 2024-0715 para que todos eventos sejam mostrados
		--case when sh.cd_shift is null then (select cd_shift from shifts where id_enterprise=in_id_enterprise order by id_shift limit 1) else sh.cd_shift end as cd_shift,
		--case when ers.id_shift is null then (select id_shift from shifts where id_enterprise=in_id_enterprise order by id_shift limit 1) else ers.id_shift end as id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status <> 6
		and ts_event > _tsstart::timestamp - interval '1 months'
--		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and (ee.ts_end < _tsend::timestamp + interval '1 months' or ee.ts_end is null)
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view  or cd_category is not null)
--		and ((eq.tp_equipment=3 and not :sector_view) or (eq.tp_equipment=1 and :sector_view))
		and eq.event_should_be_displayed = true
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_equipment=any(ids_sectors) and :sector_view))
	-- Use the next line when using with events of equipments type = 1
	and id_line = any(ids_equips)
	and (
		(ids_sectors is null) 
		or 
		(
			id_sector = any(ids_sectors) and id_site = any(ids_sites) and id_area = any(ids_areas)
		)
		or (id_sector is null)
	)
--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_parentequipment=any(ids_sectors) and :sector_view and id_line=any(ids_equips)))
	UNION
select
	id_equipment_event, (ts_event at time zone (timezone))::timestamp as ts_event, (ts_end at time zone (timezone))::timestamp as ts_end, id_equipment, id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case
			when eq.tp_equipment = 2 then eq.id_equipment
			when peq.tp_equipment = 2 then peq.id_equipment
			when ppeq.tp_equipment = 2 then ppeq.id_equipment
			else null
		end as id_sector,
		coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
		case
			when eq.tp_equipment = 3 then eq.nm_equipment
			when peq.tp_equipment = 3 then peq.nm_equipment
			when ppeq.tp_equipment = 3 then ppeq.nm_equipment
			else null
		end as nm_equipment,
		case
			when eq.tp_equipment = 2 then eq.nm_equipment
			when peq.tp_equipment = 2 then peq.nm_equipment
			when ppeq.tp_equipment = 2 then ppeq.nm_equipment
			else null
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		desc_category txt_category,
		cd_subcategory,
		desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
				(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce(ppeq.id_equipment, peq.id_equipment, ee.id_equipment) )
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
--		status = 10
--		and 
		ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ( ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )
		and eq.event_should_be_displayed = true
--		and ((eq.tp_equipment=3 and not :sector_view) or (eq.tp_equipment=1 and :sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_equipment=any(ids_sectors) and :sector_view))
	-- Use the next line when using with events of equipments type = 1
	and id_line = any(ids_equips)
	and (
		(ids_sectors is null) 
		or 
		(
			id_sector = any(ids_sectors) and id_site = any(ids_sites) and id_area = any(ids_areas)
		)
		or 
		(
			id_sector is null
		)
	)
--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_parentequipment=any(ids_sectors) and :sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $$;


--
-- Name: h_downtimes_table_with_sector_3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_downtimes_table_with_sector_3 (
    id_equipment_event bigint,
    ts_event timestamp without time zone,
    ts_end timestamp without time zone,
    id_equipment integer,
    id_sector integer,
    nm_equipment character varying,
    sector character varying,
    cd_machine character varying,
    duration integer,
    cd_category character varying,
    txt_category character varying,
    cd_subcategory character varying,
    txt_subcategory character varying,
    txt_downtime_notes character varying,
    id_order integer,
    cd_shift character varying,
    id_shift integer,
    id_enterprise integer,
    planned_downtime boolean,
    change_over boolean,
    shift_ts_range tstzrange,
    stop_threshold_time integer,
    manual_event boolean
);


--
-- Name: h_piot_get_downtimes_events_2(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_events_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false) RETURNS SETOF public.h_downtimes_table_with_sector_3
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_sectors int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=2
						 and case
						 		when cardinality(in_ids_sectors::int[]) = 0 then true
						 		else id_equipment = any( in_ids_sectors::int[])
						 	 end );

begin
return query

select * from (
select
	id_equipment_event,
	(ts_event at time zone (timezone))::timestamp as ts_event,
	(ts_end at time zone (timezone))::timestamp as ts_end,
	id_equipment,
	id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time,
	false as manual_event
from
	(
	select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case
			when eq.tp_equipment = 2 then eq.id_equipment
			when peq.tp_equipment = 2 then peq.id_equipment
			when ppeq.tp_equipment = 2 then ppeq.id_equipment
			else null
		end as id_sector,
		coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
		case
			when eq.tp_equipment = 3 then eq.nm_equipment
			when peq.tp_equipment = 3 then peq.nm_equipment
			when ppeq.tp_equipment = 3 then ppeq.nm_equipment
			else null
		end as nm_equipment,
		case
			when eq.tp_equipment = 2 then eq.nm_equipment
			when peq.tp_equipment = 2 then peq.nm_equipment
			when ppeq.tp_equipment = 2 then ppeq.nm_equipment
			else null
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		desc_category txt_category,
		cd_subcategory,
		desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then 
					(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment))
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status <> 6
		and ts_event > _tsstart::timestamp - interval '1 months'
--		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and (ee.ts_end < _tsend::timestamp + interval '1 months' or ee.ts_end is null)
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view  or cd_category is not null)
--		and ((eq.tp_equipment=3 and not :sector_view) or (eq.tp_equipment=1 and :sector_view))
		and eq.event_should_be_displayed = true
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_equipment=any(ids_sectors) and :sector_view))
	-- Use the next line when using with events of equipments type = 1
	and id_line = any(ids_equips)
	and (
		(ids_sectors is null) 
		or 
		(
			id_sector = any(ids_sectors) and id_site = any(ids_sites) and id_area = any(ids_areas)
		)
		or (id_sector is null)
	)
--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_parentequipment=any(ids_sectors) and :sector_view and id_line=any(ids_equips)))
	UNION
select
	id_equipment_event, (ts_event at time zone (timezone))::timestamp as ts_event, (ts_end at time zone (timezone))::timestamp as ts_end, id_equipment, id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time,
	true as manual_event
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case
			when eq.tp_equipment = 2 then eq.id_equipment
			when peq.tp_equipment = 2 then peq.id_equipment
			when ppeq.tp_equipment = 2 then ppeq.id_equipment
			else null
		end as id_sector,
		coalesce (ppeq.id_equipment, peq.id_equipment, eq.id_equipment) as id_line,
		case
			when eq.tp_equipment = 3 then eq.nm_equipment
			when peq.tp_equipment = 3 then peq.nm_equipment
			when ppeq.tp_equipment = 3 then ppeq.nm_equipment
			else null
		end as nm_equipment,
		case
			when eq.tp_equipment = 2 then eq.nm_equipment
			when peq.tp_equipment = 2 then peq.nm_equipment
			when ppeq.tp_equipment = 2 then ppeq.nm_equipment
			else null
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		desc_category txt_category,
		cd_subcategory,
		desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
--				(case when :sector_view
--					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
--					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
--				end)
				(select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce(ppeq.id_equipment, peq.id_equipment, ee.id_equipment) )
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
--		status = 10
--		and 
		ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view  or (cd_category is not null and cd_category <> '') )
		and eq.event_should_be_displayed = true
--		and ((eq.tp_equipment=3 and not :sector_view) or (eq.tp_equipment=1 and :sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_equipment=any(ids_sectors) and :sector_view))
	-- Use the next line when using with events of equipments type = 1
	and id_line = any(ids_equips)
	and (
		(ids_sectors is null) 
		or 
		(
			id_sector = any(ids_sectors) and id_site = any(ids_sites) and id_area = any(ids_areas)
		)
		or
		(
			id_sector is null
		)
	)
--	and ((id_equipment=any(ids_equips) and not :sector_view) or (id_parentequipment=any(ids_sectors) and :sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $$;


--
-- Name: h_piot_get_downtimes_per_category_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_get_downtimes_per_category_table (
    id_enterprise integer,
    downtimes_per_category jsonb[]
);


--
-- Name: h_piot_get_downtimes_per_category(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_per_category(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_get_downtimes_per_category_table
    LANGUAGE plpgsql STABLE
    AS $$
declare 
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_ids_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_ids_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_ids_shifts, ',')) = 0 then true
										when left(in_ids_shifts, 1) != '{' then cd_shift = any( string_to_array(in_ids_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_ids_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_ids_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
begin
return query 	
select distinct 
	ee.id_enterprise,
	array_agg(
		jsonb_build_object(
			'nm_equipment', e.nm_equipment,
			'id_equipment', ee.id_equipment,
			'cd_machine', ee.cd_machine,
			'change_over', ee.change_over,
			'num_occurence', count(*),
			'avg_time', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)))/count(*),
			'planned_downtime', ee.planned_downtime,
			'cd_category', coalesce(ee.cd_category, 'Microstops'),
			'txt_category', coalesce(ee.txt_category, ee.cd_category, 'Microstops'),
			--'duration_total', sum( extract(epoch from least(upper(ee.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ee.ts_value, ee.ts_event) ) ),
			'duration_total', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) ),
			'duration_justified', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null),
			'duration_planned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = true),
			'duration_unplanned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = false)
		)
	) over () as downtimes_per_category
from
	public.h_piot_get_downtimes_sector_microstops(in_id_enterprise,in_ids_sites,in_ids_areas,in_ids_equipments,'{}',_tsstart,_tsend,false,true) ee
	join equipments e on ee.id_equipment =e.id_equipment 
	join equipment_oee_shift ers 
		on (
			ers.id_equipment = ee.id_equipment
			and (
				--ee.ts_event::timestamptz <@ ers.ts_range
				--or
				--ee.ts_end::timestamptz <@ ers.ts_range
				--eduardo 2024-03-27 essas condicoes acima nao funcionavam para paradas longas alem da duracao de um turno
				tstzrange(ee.ts_event,ee.ts_end) && ers.ts_range
			)
--*************************************			
				and (ers.ts_range && tstzrange(_tsstart ,_tsend)) --eduardo 2024-07-13 (nao estava funcionando para paradas longas)
--*************************************
						)
	join shifts s on (s.id_shift = ers.id_shift)
	where
		ers.id_shift = any( ids_shifts )
		--Elimination on unjustified stops (but keeps downtimes)
		and (
			ee.cd_category is not null
			or
			(
				extract	(
					epoch from
						least(upper(ers.ts_range), coalesce(ee.ts_end, now()))
						-
						greatest(ers.ts_value, ee.ts_event)
				-- F3 cutover fixup M4: stop_threshold_time is NULL for ALL equipment (F1 & F3),
				-- so `< NULL` => NULL => every uncategorized stop was dropped and the function
				-- returned 0 rows for every tenant. Treat an unconfigured (NULL) threshold as
				-- "no upper bound" so uncategorized microstops are kept (consistent with sibling
				-- h_piot_get_downtimes_per_category_equipment_level_new_4, which never row-gates on it).
				) < coalesce(e.stop_threshold_time, 'infinity'::double precision)
				and cd_category is null
				--Elimina tempos negativos, provavelmente já pode remover isso
				and extract(
					epoch from
						least(upper(ers.ts_range), coalesce(ee.ts_end, now()))
						-
						greatest(ers.ts_value, ee.ts_event)
				) > 0
			)
		)
		--eduardo '2024-03-27' para não pegar paradas manuais e adicionar aos cálculos de tempos
		and ee.id_equipment_event not in (select id_equipment_event from equipment_events_man where id_enterprise=in_id_enterprise and ts_event >= _tsstart)
	group by
		ee.id_enterprise, e.nm_equipment, ee.id_equipment, ee.cd_machine, ee.change_over, ee.planned_downtime,
		ee.cd_category, ee.txt_category;
return;
end
$$;


--
-- Name: h_piot_get_downtimes_per_category_equipment_level_new; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_get_downtimes_per_category_equipment_level_new (
    id_enterprise integer,
    duration_microstops bigint,
    duration_total bigint,
    duration_justified bigint,
    duration_planned bigint,
    duration_unplanned bigint,
    available_time bigint,
    downtimes_per_category text[]
);


--
-- Name: h_piot_get_downtimes_per_category_equipment_level_new_4(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_per_category_equipment_level_new_4(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_get_downtimes_per_category_equipment_level_new
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
begin
	return query 
	select 
		aa.id_enterprise,
		duration_microstops::int8,
		duration_total::int8,
		duration_justified::int8,
		duration_planned::int8,
		duration_unplanned::int8,
	    shs.available_time::int8,
		downtimes_per_category::text[]
	from 
	(
	select distinct 
		ee.id_enterprise,
	--	coalesce(ee.cd_category, 'Microstops') as cd_category,
	--	coalesce(ee.cd_category, 'Microstops') as txt_category, --change to description when available
	--	ee.planned_downtime,
		array_agg( jsonb_build_object(
							'nm_equipment', (select nm_equipment from equipments e where e.id_equipment = ee.id_equipment),
							'id_equipment', ee.id_equipment,
							'cd_machine', ee.cd_machine,
							'change_over', ee.change_over,
							'num_occurence', count(*),
							'avg_time', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) )/count(*),
					 		'planned_downtime', ee.planned_downtime, -- v
				            'cd_category', coalesce(ee.cd_category, 'Microstops'), --V
				            'txt_category',coalesce(ee.desc_category, ee.cd_category, 'Microstops'),--V
				            'duration_total', sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) ) ), --V
				            'duration_justified', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null),
				            'duration_planned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = true), --V
				            'duration_unplanned', sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where cd_category is not null and ee.planned_downtime = false)
							) ) over () as downtimes_per_category, 
		sum( sum( extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now()) ) - greatest(ers.ts_value, ee.ts_event) )
				      ) ) over () duration_total,
	    sum( 
	    	sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)
	    	)) filter (where extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) < COALESCE(e.stop_threshold_time, 'infinity'::double precision)
	    	and cd_category is null 
	    	and extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) >0 ) ) over() duration_microstops,
	    sum( 
	    	sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)
	    	)) filter (where cd_category is not null) ) over () duration_justified,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.cd_category is not null and ee.planned_downtime = true) ) over () duration_planned,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.planned_downtime = false or ee.cd_category is null ) ) over () duration_unplanned
	    from equipment_events ee
	join equipments e on ee.id_equipment =e.id_equipment 
	join equipment_oee_shift ers 
		on ers.id_equipment = ee.id_equipment
		and (ee.ts_event <@ ers.ts_range
			or ee.ts_end <@ ers.ts_range)
	join shifts s on s.id_shift = ers.id_shift 
	where 
		status = 10
		and ts_event >= _tsstart and ts_event < _tsend
		and e.tp_equipment = 3
		and ee.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and ee.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
--		and e.id_area = 34
--		and e.id_site = 30
--		and (ee.id_equipment = 42 or ee.id_equipment = 1 or ee.id_equipment = 6 or ee.id_equipment = 11)
--		and (ers.id_shift = 35 or ers.id_shift = 34) 
	group by ee.id_enterprise, ee.cd_category, ee.desc_category, ee.planned_downtime, ee.id_equipment, ee.cd_machine, ee.change_over 
	) aa 
	-- SUM OF ALL SHIFTS 
	cross join
	(
		select 
--			sum(ers.duration)
			sum(
--				case when min_ts_prod <@ ers.ts_range
--					then
--						case when max_ts_prod <@ ers.ts_range
--							then extract ('epoch' from max_ts_prod - min_ts_prod)
--							else extract ('epoch' from ers.ts_end - min_ts_prod)
--						end
--					else case when max_ts_prod <@ ers.ts_range
--							then extract ('epoch' from max_ts_prod - ers.ts_value)
--							else duration 
--						end
--				end
				case when now() <@ ers.ts_range
					then extract ('epoch' from now() - ers.ts_value)
					else duration 
				end
			) 
			as available_time
		from equipment_oee_shift ers 
		join equipments e on ers.id_equipment = e.id_equipment 
		where 
			--ers.ts_value >= _tsstart and ers.ts_value < _tsend 
			ers.ts_value_production >= min_ts_prod and ers.ts_value_production <= max_ts_prod 
			-- excluding futures shifts
			and ers.ts_value <= now()
			and e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ers.id_equipment = any( ids_equips )
			and ers.id_shift = any( ids_shifts )
--			and e.id_area = 34
--			and e.id_site = 30
--			and (ers.id_equipment = 42 or ers.id_equipment = 1 or ers.id_equipment = 6 or ers.id_equipment = 11)
--			and (ers.id_shift = 35 or ers.id_shift = 34) 
	) shs;
return;
end
$$;


--
-- Name: h_piot_get_downtimes_resumo_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_get_downtimes_resumo_table (
    id_enterprise integer,
    duration_microstops bigint,
    duration_total bigint,
    duration_justified bigint,
    duration_planned bigint,
    duration_unplanned bigint,
    available_time bigint
);


--
-- Name: h_piot_get_downtimes_resumo(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_resumo(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_get_downtimes_resumo_table
    LANGUAGE plpgsql STABLE
    AS $$
declare 
	ids_sites int[] := (select array_agg(id_site) 
						from sites s
						where s.id_enterprise=in_id_enterprise 
							and case
								when cardinality(in_ids_sites::int[]) = 0 then true
								else id_site = any( in_ids_sites::int[])
								end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_ids_shifts, ',')) = 0 then true
										when left(in_ids_shifts, 1) != '{' then cd_shift = any( string_to_array(in_ids_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_ids_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_ids_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
begin
return query 

		select 
		e.id_enterprise,
		null::int8 as duration_microstops,
		sum(downtime) as duration_total,
		null::int8 as duration_justified,
		sum(planned_downtime) as duration_planned,
		sum(downtime)-sum(planned_downtime) as duration_unplanned,
		sum(
			case when now() <@ ers.ts_range
				then extract ('epoch' from now() - ers.ts_value)
				else duration 
			end
		)::int8 as available_time
		from equipment_oee_shift ers 
		join equipments e on ers.id_equipment = e.id_equipment 
		where 
			ers.ts_value_production >= min_ts_prod and ers.ts_value_production <= max_ts_prod 
			-- excluding futures shifts
			and ers.ts_value <= now()
			and e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ers.id_equipment = any( ids_equips )
			and ers.id_shift = any( ids_shifts )
		group by id_enterprise;
return;
end
$$;


--
-- Name: h_piot_get_downtimes_sector_microstops(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_sector_microstops(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), sector_view boolean DEFAULT false, microstops_view boolean DEFAULT false) RETURNS SETOF public.h_downtimes_table_with_sector_2
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_sectors int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=2
						 and case
						 		when cardinality(in_ids_sectors::int[]) = 0 then true
						 		else id_equipment = any( in_ids_sectors::int[])
						 	 end );
	min_ts_prod timestamp := (select min(ts_value) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamp := (select max(ts_end) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);

begin
return query

select * from (
select
	id_equipment_event, 
	--(ts_event at time zone (timezone))::timestamp as ts_event,
	ts_event::timestamp as ts_event,
	ts_end::timestamp as ts_end,
	--(ts_end at time zone (timezone))::timestamp as ts_end, 
	id_equipment, id_sector,
	nm_equipment, sector, 
	--cd_machine, 
	case when coalesce(duration,extract(epoch from now()-ts_event))>=stop_threshold_time and cd_machine is null then 'No_Reason_Input' else cd_machine end as cd_machine,
	duration, 
	--cd_category, --alteração eduardo 2024-03-26 para que a categoria Non-Reason-Input passe a ser mostrada no go.packiot na pagina de Downtimes, em "Motivos de Paradas"
	case when coalesce(duration,extract(epoch from now()-ts_event))>=stop_threshold_time and cd_category is null then 'No_Reason_Input' else cd_category end as cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		--desc_category txt_category,
		cd_category txt_category, --alteracao eduardo 2024-07-14
		cd_subcategory,
		cd_subcategory txt_subcategory, --alteracao eduardo 2024-07-14
		--desc_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise,
		false as manual_event --eduardo 2024-03-27 to avoid manual stops counting time in go packiot
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status = 10
		and ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		--and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and tstzrange(ts_event, coalesce(ee.ts_end,now())) && tstzrange (min_ts_prod,max_ts_prod)		
		and ((not microstops_view and (ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )) or microstops_view )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
UNION
select
	id_equipment_event, (ts_event at time zone (timezone))::timestamp as ts_event, (ts_end at time zone (timezone))::timestamp as ts_end, id_equipment, id_sector,
	nm_equipment, sector, cd_machine, duration, cd_category,
	txt_category, cd_subcategory, txt_subcategory, txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise, planned_downtime, change_over,ts_range as shift_ts_range, stop_threshold_time
from
	(select
		id_equipment_event,
		ts_event,
		ee.ts_end,
		ee.id_equipment,
		case when eq.tp_equipment = 1 then peq.id_equipment
			else null
		end as id_sector,
		ppeq.id_equipment as id_line,
		case when eq.tp_equipment = 1 then ppeq.nm_equipment
			else eq.nm_equipment
		end as nm_equipment,
		case when eq.tp_equipment = 1 then peq.nm_equipment
			else NULL
		end as sector,
		eq.id_area,
		eq.id_site,
		eq.id_parentequipment,
		cd_machine,
		ee.duration,
		cd_category,
		cd_category txt_category,
		--desc_category txt_category,
		cd_subcategory,
		--desc_subcategory txt_subcategory,
		cd_subcategory txt_subcategory,
		txt_downtime_notes,
		st.timezone,
		eq.stop_threshold_time,
		ee.planned_downtime ,
		ee.change_over,
		ers.ts_range,
		(
			select id_order from production_orders po where
				po.id_production_order  =
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise,
		true as manual_event --eduardo 2024-03-27 to avoid manual stops counting time in go packiot
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_oee_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
--		status = 10
--		and 
		ts_event > _tsstart::timestamp - interval '1 months'
		and ee.ts_end < _tsend::timestamp + interval '1 months'
		and tstzrange(ts_event, coalesce(ee.ts_end,now())) && tstzrange (min_ts_prod,max_ts_prod)		
		--and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ( ee.duration >= COALESCE(eq.stop_threshold_time, 0) or ee.duration is null )
		and ((eq.tp_equipment=3 and not sector_view) or (eq.tp_equipment=1 and sector_view))
	) aa
where
	id_enterprise = in_id_enterprise
	and id_site = any(ids_sites)
	and id_area = any(ids_areas)
	-- Use the next line when using with events of equipments type = 2
	--	and ((id_equipment=any(ids_equips) and not sector_view) or (id_equipment=any(ids_sectors) and sector_view))
	-- Use the next line when using with events of equipments type = 1
	and ((id_equipment=any(ids_equips) and not sector_view) or (id_parentequipment=any(ids_sectors) and sector_view and id_line=any(ids_equips)))
)AAA order by ts_event desc;


end $$;


--
-- Name: h_pending_events_with_event_id; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_pending_events_with_event_id (
    id_equipment_event bigint,
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    id_equipment integer,
    id_enterprise integer,
    packml_topic character varying
);


--
-- Name: h_piot_get_equipment_pending_downtime_with_event_id(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_equipment_pending_downtime_with_event_id(in_packml_topic character varying[]) RETURNS SETOF public.h_pending_events_with_event_id
    LANGUAGE sql STABLE
    AS $$
	SELECT id_equipment_event, ts_event, ts_end, duration, e.id_equipment, e.id_enterprise, p.packml_topic
    FROM equipment_events ee
    JOIN equipments e ON ee.id_equipment = e.id_equipment
    join packml_register p on p.id_equipment = e.id_equipment
    WHERE p.packml_topic = ANY (in_packml_topic)
        AND ee.ts_event >= now() - interval '4 days'
        AND ee.status != 6
        AND (ee.duration >= COALESCE(e.stop_threshold_time, 0) or ee.duration is null)
        and ee.cd_category is null
    ORDER BY ts_event DESC;
   $$;


--
-- Name: h_events_timeline3_with_event_id; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline3_with_event_id (
    id_equipment_event bigint,
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    id_equipment integer,
    id_enterprise integer,
    txt_downtime_notes character varying,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    desc_category character varying,
    desc_subcategory character varying,
    packml_topic character varying,
    event_type text,
    id_order_text character varying,
    id_production_order bigint,
    production_programmed bigint,
    custom_field jsonb
);


--
-- Name: h_piot_get_events_timeline3_with_event_id(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline3_with_event_id(in_packml_topic character varying[]) RETURNS SETOF public.h_events_timeline3_with_event_id
    LANGUAGE sql STABLE
    AS $$

select
	id_equipment_event,
  ts_event,
  ee.ts_end,
  duration,
  e.id_equipment,
  e.id_enterprise,
  txt_downtime_notes,
  cd_machine,
  cd_category,
  cd_subcategory,
  change_over,
  desc_category,
  desc_subcategory,
  p.packml_topic,
  'downtime' :: text as event_type,
  po.id_order_text,
  po.id_production_order,
  po.production_programmed,
  po.custom_field
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
where
  p.packml_topic = ANY (in_packml_topic)
  --AND 
  --ee.ts_event >= now() - interval '1 days'
  AND (ee.ts_end >= now() - interval '1 days' OR ee.ts_end IS NULL)
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null or ee.cd_category is not null))
  AND ee.status != 6
  and ee.cd_category is not null
union
select
	eels.id_equipment_event  as id_equipment_event,
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	e.id_equipment,
	e.id_enterprise,
	eels.txt_downtime_notes,
	eels.cd_machine,
	eels.cd_category,
	eels.desc_category,
	eels.change_over,
	eels.desc_subcategory,
	eels.cd_subcategory,
	p.packml_topic,
	'low_speed' :: text as event_type,
	po.id_order_text,
	po.id_production_order,
	po.production_programmed,
	po.custom_field
FROM
	equipment_events_low_speed eels
	JOIN equipments e ON eels.id_equipment = e.id_equipment
	JOIN packml_register p ON p.id_equipment = e.id_equipment
	left join production_orders_runtime por on (eels.id_equipment = por.id_equipment  and eels.ts_event <@ por.runtime_timerange)
	left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
	p.packml_topic = ANY (in_packml_topic)
	AND eels.ts_event >= now() - interval '1 days'
	AND eels.status = 1 OR eels.status = 2	
UNION
select
	eem.id_equipment_event as id_equipment_event,
  eem.ts_event as ts_event,
  eem.ts_end as ts_end,
  extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer as duration,
  e.id_equipment,
  e.id_enterprise,
  eem.txt_downtime_notes,
  eem.cd_machine,
  eem.cd_category,
  eem.cd_subcategory,
  eem.change_over,
  eem.desc_category,
  eem.desc_subcategory,
  p.packml_topic,
  'manual' :: text as event_type,
  po.id_order_text,
  po.id_production_order,
  po.production_programmed,
  po.custom_field
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment = e.id_equipment
  JOIN packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (eem.id_equipment = por.id_equipment  and eem.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND eem.ts_event >= now() - interval '1 days'
   -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
 
$$;


--
-- Name: h_events_equipment_timeline_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_equipment_timeline_2 (
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    id_equipment integer,
    id_enterprise integer,
    txt_downtime_notes character varying,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    status integer
);


--
-- Name: h_piot_get_events_timeline_from_po(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline_from_po(_id_production_order integer) RETURNS SETOF public.h_events_equipment_timeline_2
    LANGUAGE sql STABLE
    AS $$ 
select
    ts_event,
    ts_end,
    duration,
    e.id_equipment,
    e.id_enterprise,
    txt_downtime_notes,
    cd_machine,
    cd_category,
    cd_subcategory,
    change_over,
    status
from equipment_events ee
join equipments e on ee.id_equipment = e.id_equipment
--cross join ranges
where   
--	ee.id_equipment = _id_equipment
  ee.id_equipment = (select id_equipment from production_orders where id_production_order = _id_production_order) 
    and ee.ts_event::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_production_order ) )
    and (
            (ee.duration >= COALESCE(e.stop_threshold_time, 0))
            or (ee.ts_end is null)
        )
    and ee.status != 6
--    and ee.cd_category is not null
UNION
SELECT
  eem.ts_event,
  eem.ts_end,
  extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer as duration,
  e.id_equipment,
  e.id_enterprise,
  eem.txt_downtime_notes,
  null as cd_machine,
  null as cd_category,
  null as cd_subcategory,
  null as changeover,
  null as status
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment_event = e.id_equipment
  where
--  id_equipment = _id_equipment
  e.id_equipment = (select id_equipment from production_orders where id_production_order = _id_production_order) 
  AND 
--  eem.ts_event_start >= now() - interval '24 hour'
--  (select runtime_timerange from production_orders_runtime por where id_production_order=_id_production_order) @> eem.ts_event_start
  eem.ts_event::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_production_order ) )
  AND extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer >= COALESCE(e.stop_threshold_time, 0) -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
$$;


--
-- Name: h_events_timeline_full2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline_full2 (
    event_type integer,
    ts_timeline timestamp with time zone,
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    id_equipment integer,
    nm_equipment character varying,
    nm_area character varying,
    nm_site character varying,
    id_enterprise integer,
    txt_downtime_notes character varying,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    status integer,
    id_order character varying,
    nm_client character varying
);


--
-- Name: h_piot_get_events_timeline_full_with_filter_3(integer, text, text, text, text, integer, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline_full_with_filter_3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_event_types text, _id_production_order integer DEFAULT NULL::integer, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now()) RETURNS SETOF public.h_events_timeline_full2
    LANGUAGE plpgsql STABLE
    AS $$ 
declare
    ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	min_ts_prod timestamptz := (select min(ts_value) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_end) from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	id_event_types int[] := in_event_types::int[];
	_id_prod_order int := (_id_production_order);
begin
	return query	
--	create table h_events_timeline_full as 
	select
		ev.*
	from
		v_events_2 ev
		join equipments using (id_equipment)
	where
		id_equipment = any(ids_equips)
    	and id_area= any(ids_areas)
    	and id_site = any(ids_sites)
    	and (_id_prod_order is null or 
    		id_equipment = (select id_equipment from production_orders where id_production_order = _id_prod_order)
    	)
		and (
			_id_prod_order is null
				or 
	    	ts_timeline::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_prod_order ) )
	    		or 
	    	tstzrange(ts_event::timestamptz, ts_end::timestamptz, '[)') <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_prod_order ) )
	    )
	    and (
	    	(
		    	event_type not in (4, 5, 6) and 
		    	(
		    		(tstzrange(ts_event::timestamptz, ts_end::timestamptz, '[)') @> min_ts_prod::timestamptz or tstzrange(ts_event::timestamptz, ts_end::timestamptz, '[)') @> max_ts_prod::timestamptz)
		    		or (ts_event >= min_ts_prod and ts_event <= max_ts_prod)
		    	)
		    	or 
		    	event_type in (4, 5, 6) and 
		    	(
		    		(ts_timeline >= min_ts_prod and ts_timeline <= max_ts_prod)
		    	)
		    )
	    )
	    and event_type = any(id_event_types)
	ORDER by ts_timeline DESC;
end $$;


--
-- Name: h_piot_mission_control_area_uns_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_mission_control_area_uns_2 (
    id_enterprise integer,
    id_area integer,
    nm_area character varying,
    gross_production real,
    net_production real,
    scrap real,
    oee real,
    target real,
    projected_production double precision,
    vl_shift double precision
);


--
-- Name: h_piot_get_mission_control_area_uns_2(integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_mission_control_area_uns_2(in_id_enterprise integer, in_id_areas text, in_id_sites text) RETURNS SETOF public.h_piot_mission_control_area_uns_2
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
begin
	return query
	-- F3 cutover fixup M4: area_live_shift is a fact snapshot whose denormalized
	-- id_enterprise / id_site / nm_area columns are left NULL by the worker. The old body
	-- filtered on the snapshot's NULL id_site (NULL = any(...) => NULL => 0 rows) and returned
	-- NULL enterprise/nm_area. Join the canonical `areas` dimension by id_area for those
	-- attributes and for tenant scoping; keep metrics from the snapshot.
select
	a.id_enterprise,
	uacs.id_area,
	a.nm_area,
	uacs.gross_production,
	uacs.net_production,
	uacs.scrap,
	uacs.oee,
	uacs.target,
	uacs.net_production + ((uacs.net_production/nullif(uacs.running_time , 0)) * (uacs.duration - uacs.elapsed_time)) as projected_production,
	oeet.vl_shift
from
	area_live_shift uacs
	join areas a on (a.id_area = uacs.id_area)
	left join oee_targets oeet on (uacs.id_area = oeet.id_area and oeet.id_equipment is null)
where
    a.id_enterprise = in_id_enterprise
    and a.id_site = any (ids_sites)
    and uacs.id_area = any (ids_areas);
end $$;


--
-- Name: h_piot_mission_control_timeline; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_mission_control_timeline (
    id_equipment integer,
    timelinestatus text[]
);


--
-- Name: h_piot_get_mission_control_timeline(integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_mission_control_timeline(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) RETURNS SETOF public.h_piot_mission_control_timeline
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site)
						 from sites s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area)
						 from areas s
						 where s.id_enterprise=in_id_enterprise
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment)
						 from equipments s
						 where s.id_enterprise=in_id_enterprise
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
begin
return query

		select
				dt.id_equipment,
            	array_agg(dt.situation ORDER BY dt.ts_value) AS timelinestatus
           FROM (
           		SELECT
           			aaa.ts_value,
                    aaa.id_equipment,
                        CASE
                            WHEN COALESCE(aaa.speed, 0.0::double precision) >= (e.minimum_ideal_performance_threshold * e.production_speed::double precision) THEN 'running'::text
                            WHEN COALESCE(aaa.speed, 0.0::double precision) < (e.minimum_ideal_performance_threshold * e.production_speed::double precision) AND COALESCE(aaa.speed, 0.0::double precision) >= (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'lowSpeed'::text
                            WHEN COALESCE(aaa.speed, 0::double precision) < (e.minimum_performance_threshold * e.production_speed::double precision) THEN 'stopped'::text
                            ELSE NULL::text
                        END AS situation
                   FROM (select * from agg_equipment_values_1min aaa
                   where
                   			id_enterprise = in_id_enterprise
                   		and id_site = any (ids_sites)
                   		and id_area = any (ids_areas)
                   		and id_equipment = any (ids_equips)
                   		) aaa
                     LEFT JOIN equipments e USING (id_equipment)
                  WHERE aaa.ts_value >= (now() - '24:01:00'::interval) AND aaa.ts_value < (now() - '00:01:00'::interval) AND aaa.tp_equipment = 3
           ) dt
           GROUP BY dt.id_equipment;


end
$$;


--
-- Name: h_piot_mission_control_uns_3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_mission_control_uns_3 (
    id_site integer,
    id_area integer,
    nm_area character varying,
    id_line integer,
    nm_line character varying,
    id_enterprise integer,
    currshift_oee real,
    curr_shift_name character varying,
    prev1_shift_name character varying,
    prev2_shift_name character varying,
    id_order character varying,
    production_programmed real,
    po_net_production real,
    nm_client character varying,
    duration integer,
    expected_time integer,
    speed real,
    curshift_grosprod real,
    curshift_netprod real,
    prev1shift_netprod real,
    prev2shift_netprod real,
    curshift_scrap real,
    planned_downtime integer,
    planned_duration_percent double precision,
    change_over_duration integer,
    change_over_duration_percent double precision,
    unplanned_duration integer,
    unplanned_duration_perc double precision,
    stopped_time integer,
    status_24h text[],
    status character varying,
    status_time integer,
    proportional_target real,
    prev1_target real,
    prev2_target real,
    job_remaining_time double precision
);


--
-- Name: h_piot_get_mission_control_uns_3(integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_mission_control_uns_3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) RETURNS SETOF public.h_piot_mission_control_uns_3
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site)
						from sites s
						where s.id_enterprise=in_id_enterprise
						and case
							when cardinality(in_ids_sites::int[]) = 0 then true
							else id_site = any( in_ids_sites::int[])
						end);
	ids_areas int[] := (select array_agg(id_area)
						from areas s
						where s.id_enterprise=in_id_enterprise
						and case
							when cardinality(in_ids_areas::int[]) = 0 then true
							else id_area = any( in_ids_areas::int[])
						end);
	ids_equips int[] := (select array_agg(id_equipment)
						from equipments s
						where s.id_enterprise=in_id_enterprise
						and s.tp_equipment=3
						and case
							when cardinality(in_ids_equipments::int[]) = 0 then true
							else id_equipment = any( in_ids_equipments::int[])
						end);
begin
return query


   select
	uecm.id_site,
		uecm.id_area,
		uecm.nm_area,
		uecm.id_equipment AS id_line,
		uecm.nm_equipment AS nm_line,
		uecm.id_enterprise,
		uecs.oee AS currshift_oee,
		uecs.shift_name AS curr_shift_name,
		uecs.prev1_shift_name,
		uecs.prev2_shift_name,
		uecj.id_order,
		uecj.target AS production_programmed,
		uecj.net_production AS po_net_production,
		uecj.nm_client,
		uecj.elapsed_time AS duration,
		uecj.current_expected_time AS expected_time,
		uecm.speed::real,
		uecs.gross_production AS curshift_grosprod,
		uecs.net_production AS curshift_netprod,
		uecs.prev1_net_production AS prev1shift_netprod,
		uecs.prev2_net_production AS prev2shift_netprod,
		uecs.scrap AS curshift_scrap,
		uecs.planned_downtime,
		uecm.planned_perc_stops_24h as planned_duration_percent,
		uecs.change_over_duration,
		uecm.change_over_perc_stops_24h as change_over_duration_percent,
		uecs.unplanned_downtime as unplanned_duration,
		uecm.unplanned_perc_stops_24h as unplanned_duration_percent,
		uecs.stopped_time,
		uecm.status_24h,
		uecm.status,
		uecm.status_time,
		uecs.proportional_target,
		uecs.prev1_target,
		uecs.prev2_target,
		uecj.current_expected_time::float8 as job_remaining_time
	from equipment_live_job uecj
	join equipment_live_shift uecs on (uecs.id_equipment=uecj.id_equipment)
	join equipment_live_metrics uecm on (uecm.id_equipment=uecj.id_equipment)
	where
		uecm.id_site = any (ids_sites)
		and uecm.id_area = any (ids_areas)
		and uecm.id_equipment = any (ids_equips);

	end
$$;


--
-- Name: h_production_health; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_production_health (
    id_equipment integer,
    net real,
    target double precision,
    status_overview numeric(5,1)
);


--
-- Name: h_piot_get_production_health(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_production_health(idequipment integer) RETURNS SETOF public.h_production_health
    LANGUAGE sql STABLE
    AS $$
		WITH this_week AS (
SELECT
	(date_trunc('week',
	now() AT TIME ZONE s.timezone) + s.week_begin * INTERVAL '1 second') AT time ZONE 'UTC' AS week_start
FROM
	equipments eq
LEFT JOIN sites s 
        ON
	eq.id_site = s.id_site
WHERE
	id_equipment = idEquipment
        )
        SELECT
	id_equipment,
	sum(net) AS net,
	sum(target) AS target,
	(sum(net)/(sum(target)+ 1))::NUMERIC(5,
	1) AS status_overview
FROM
	equipment_oee_shift ers
WHERE
	ers.id_equipment = idEquipment
	AND ts_value >= (
	SELECT
		week_start
	FROM
		this_week)
	AND ts_value < now()
GROUP BY
	1
ORDER BY
	1;

$$;


--
-- Name: h_piot_production_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_targets (
    id_enterprise integer,
    ts_value_production timestamp with time zone,
    target double precision,
    array_agg jsonb[]
);


--
-- Name: h_piot_get_targets(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_targets(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, group_by_element text DEFAULT 'DAY'::text) RETURNS SETOF public.h_piot_production_targets
    LANGUAGE plpgsql STABLE
    AS $$
declare 
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case UPPER(time_grain)
									when 'HOUR' then
										(select min(ts_value) from ca_agg_equipment_values_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value) from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
			--								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			--								and ev.id_enterprise = in_id_enterprise
			--								and ev.id_area = any( ids_areas)
			--								and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) )
								end
							);
	max_ts_prod timestamptz := (
						select case UPPER(time_grain)
									when 'HOUR' then
										(
										select max(ts_value) 
--										from ca_agg_equipment_values_1hour ev
										from equipment_oee_hourly ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
--										and ev.id_enterprise = in_id_enterprise
--										and ev.id_area = any( ids_areas)
--										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
--										and ev.id_shift = any( ids_shifts )
										)
								else (
									select 
										max(ts_value)
									from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
		--								and ev.id_enterprise = in_id_enterprise
		--								and ev.id_area = any( ids_areas)
		--								and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts )
								)
							end
							);
begin
	if true THEN --nav_level = EQUIPMENT
		if upper(time_grain) = 'DAY' then
		-- Targets in equipment level and by day	
		return query
				select distinct
					id_enterprise,
					ts_value_production::timestamp(0) with time zone,
					sum(target) target,
					array_agg(obj order by coalesce(shift_position, team_position))
				from(
					select 
						e.id_enterprise,
						ts_value_production,
						sum(target) as target,
						case group_by_element when 'SHIFTS' then s.sequence_position else null end shift_position,
						case group_by_element when 'TEAMS' then t.sequence_position else null end team_position,
						--array_agg( 
							jsonb_build_object(
								'id_shift', case group_by_element when 'SHIFTS' then s.id_shift END,
								'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
								'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
								'id_team', case group_by_element when 'TEAMS' then t.id_team END,
								'target', SUM(target)
							) as obj
					from 
						equipment_oee_shift ers
						join equipments e using (id_equipment)
						left join shifts s using (id_shift)
						left join teams t using (id_team)
					where
						ts_value >= min_ts_prod
						and ts_value <= max_ts_prod
						and e.id_enterprise = in_id_enterprise
						and e.id_area = any( ids_areas)
						and e.id_site = any( ids_sites )
						and e.id_equipment =  any( ids_equips )
						and ers.id_shift = any( ids_shifts )
					group by 
						e.id_enterprise, ts_value_production,
						case group_by_element when 'SHIFTS' then s.id_shift else null END,
						case group_by_element when 'SHIFTS' then s.cd_shift else null END,
						case group_by_element when 'SHIFTS' then s.sequence_position else null END,
						case group_by_element when 'TEAMS' then t.sequence_position else null end,
						case group_by_element when 'TEAMS' then t.cd_team else null end,
						case group_by_element when 'TEAMS' then t.id_team else null end
						) s0
				group by id_enterprise , ts_value_production;
			
			
			elsif  upper(time_grain) = 'WEEK' then
				-- Targets in equipment level and by WEEK	
				return query
						select  distinct
							id_enterprise,
							ts_value_production::timestamp(0) with time zone,
							sum(target) target,
							array_agg(obj order by coalesce(shift_position, team_position))
						from(
							select 
								e.id_enterprise,
								ts_value as ts_value_production,
								sum(target) as target,
								case group_by_element when 'SHIFTS' then s.sequence_position else null end shift_position,
								case group_by_element when 'TEAMS' then t.sequence_position else null end team_position,
								--array_agg( 
									jsonb_build_object(
										'id_shift', case group_by_element when 'SHIFTS' then s.id_shift END,
										'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
										'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
										'id_team', case group_by_element when 'TEAMS' then t.id_team END,
										'target', SUM(target)
									) as obj
							from 
								equipment_oee_shift_weekly ers
								join equipments e using (id_equipment)
								left join shifts s using (id_shift)
								left join teams t using (id_team)
							where
								ts_value >= min_ts_prod
								and ts_value <= max_ts_prod
								and e.id_enterprise = in_id_enterprise
								and e.id_area = any( ids_areas)
								and e.id_site = any( ids_sites )
								and e.id_equipment =  any( ids_equips )
								and ers.id_shift = any( ids_shifts )
							group by 
								e.id_enterprise, ts_value_production,
								case group_by_element when 'SHIFTS' then s.id_shift else null END,
								case group_by_element when 'SHIFTS' then s.cd_shift else null END,
								case group_by_element when 'SHIFTS' then s.sequence_position else null END,
								case group_by_element when 'TEAMS' then t.sequence_position else null end,
								case group_by_element when 'TEAMS' then t.cd_team else null end,
								case group_by_element when 'TEAMS' then t.id_team else null end
								) s0
						group by id_enterprise , ts_value_production;
					
			elsif  upper(time_grain) = 'MONTH' then
				-- Targets in equipment level and by MONTH	
				return query
				
						select  distinct
							id_enterprise,
							ts_value_production::timestamp(0) with time zone,
							sum(target) target,
							array_agg(obj order by coalesce(shift_position, team_position))
						from(
							select 
								e.id_enterprise,
								ts_value as ts_value_production,
								sum(target) as target,
								case group_by_element when 'SHIFTS' then s.sequence_position else null end shift_position,
								case group_by_element when 'TEAMS' then t.sequence_position else null end team_position,
								--array_agg( 
									jsonb_build_object(
										'id_shift', case group_by_element when 'SHIFTS' then s.id_shift END,
										'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
										'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
										'id_team', case group_by_element when 'TEAMS' then t.id_team END,
										'target', SUM(target)
									) as obj
							from 
								equipment_oee_shift_monthly ers
								join equipments e using (id_equipment)
								left join shifts s using (id_shift)
								left join teams t using (id_team)
							where
								ts_value >= min_ts_prod
								and ts_value <= max_ts_prod
								and e.id_enterprise = in_id_enterprise
								and e.id_area = any( ids_areas)
								and e.id_site = any( ids_sites )
								and e.id_equipment =  any( ids_equips )
								and ers.id_shift = any( ids_shifts )
							group by 
								e.id_enterprise, ts_value_production,
								case group_by_element when 'SHIFTS' then s.id_shift else null END,
								case group_by_element when 'SHIFTS' then s.cd_shift else null END,
								case group_by_element when 'SHIFTS' then s.sequence_position else null END,
								case group_by_element when 'TEAMS' then t.sequence_position else null end,
								case group_by_element when 'TEAMS' then t.cd_team else null end,
								case group_by_element when 'TEAMS' then t.id_team else null end
								) s0
						group by id_enterprise , ts_value_production;
			elsif  upper(time_grain) = 'HOUR' then
				-- Targets in equipment level and by HOUR	
				return query
				select  distinct
							id_enterprise,
							ts_value_production::timestamp(0) with time zone,
							sum(target) target,
							array_agg(obj order by coalesce(shift_position, team_position))
						from(
							select 
								e.id_enterprise,
								erh.ts_value::timestamptz as ts_value_production,
								sum(target) as target,
								case group_by_element when 'SHIFTS' then s.sequence_position else null end shift_position,
								case group_by_element when 'TEAMS' then t.sequence_position else null end team_position,
								--array_agg( 
									jsonb_build_object(
										'id_shift', case group_by_element when 'SHIFTS' then s.id_shift END,
										'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
										'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
										'id_team', case group_by_element when 'TEAMS' then t.id_team END,
										'target', SUM(target)
									) as obj
							from 
								equipment_oee_hourly erh 
								left join ca_agg_equipment_values_1hour ers using (id_equipment, ts_value)
								join equipments e using (id_equipment)
								left join shifts s on  (e.id_enterprise = ers.id_enterprise and ers.id_shift = s.id_shift)
								left join teams t on e.id_enterprise = t.id_enterprise and t.id_team = erh.id_team
							where
								erh.ts_value >= min_ts_prod
								and erh.ts_value <= max_ts_prod
								and e.id_enterprise = in_id_enterprise
								and e.id_area = any( ids_areas)
								and e.id_site = any( ids_sites )
								and e.id_equipment =  any( ids_equips )
								and (
									ers.id_shift = any( ids_shifts )
									or
									ers.id_shift is null
									)
							group by 
								e.id_enterprise, erh.ts_value,
								case group_by_element when 'SHIFTS' then s.id_shift else null END,
								case group_by_element when 'SHIFTS' then s.cd_shift else null END,
								case group_by_element when 'SHIFTS' then s.sequence_position else null END,
								case group_by_element when 'TEAMS' then t.sequence_position else null end,
								case group_by_element when 'TEAMS' then t.cd_team else null end,
								case group_by_element when 'TEAMS' then t.id_team else null end
								) s0
						group by id_enterprise , ts_value_production;
		end if;
	end if;
end
$$;


--
-- Name: h_piot_home_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_home_table (
    in_id_enterprise integer,
    sites jsonb
);


--
-- Name: h_piot_home_uns(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_home_uns(in_id_enterprise integer) RETURNS SETOF public.h_piot_home_table
    LANGUAGE plpgsql STABLE
    AS $$
begin
	return query 
	


select
	id_enterprise,
	jsonb_agg(sites order by nm_site) as sites
from 
	(
	select
		id_enterprise,
		id_site,
		nm_site,
		jsonb_build_object(
	   		'areas', jsonb_agg(areas order by nm_area),
			'id_site', id_site,
			'nm_site', nm_site
			) as sites
	from
		sites 
		join
			(
				select
					id_enterprise,
					id_site,
					nm_area,
					jsonb_build_object(
				   		'id_area', id_area,
						'nm_area', nm_area,
						'gross', uacd.gross_production,
						'net', uacd.net_production,
						'scrap',  uacd.scrap,
						'oee', uacd.oee,
						'lines', lines_data.lines
						) as areas	
				from
					areas 
					left join area_live_day uacd using (id_area)
					join 
						(
							select 
								id_area,
								jsonb_agg(jsonb_build_object(
												 		'id_equipment', id_equipment,
											            'nm_equipment', nm_equipment,
											            'status', coalesce(status, 'unknown')
										) order by nm_equipment) as lines
							from
								equipments
								left join equipment_live_metrics uecm using (id_equipment, id_enterprise, nm_equipment, id_area)
							where 
								id_enterprise = in_id_enterprise 
								and tp_equipment = 3
							group by id_area
						) lines_data using (id_area)
				where 
					id_enterprise = in_id_enterprise 
			) area_data using (id_enterprise, id_site)
		group by id_enterprise, id_site
	) site_data
group by id_enterprise;

return;
end
$$;


--
-- Name: h_machine_speed; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_machine_speed (
    id_enterprise integer,
    id_equipment integer,
    nm_equipment character varying,
    info jsonb[]
);


--
-- Name: h_piot_machine_speed(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_machine_speed(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text) RETURNS SETOF public.h_machine_speed
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise= in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise= in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise= in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise= in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case UPPER(time_grain)
									when 'HOUR' then
										(select min(ts_value) from ca_agg_equipment_values_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value) from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
			--								and ev.ts_value_production < date_trunc(time_grain: text, in_end_time::timestamptz)) 
			--								and ev.id_enterprise = in_id_enterprise
			--								and ev.id_area = any( ids_areas)
			--								and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) )
								end
							);
	max_ts_prod timestamptz := (
						select case UPPER(time_grain)
									when 'HOUR' then
										(select max(ts_value) from ca_agg_equipment_values_1hour ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
										and ev.id_enterprise = in_id_enterprise
										and ev.id_area = any( ids_areas)
										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ))
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
--								and ev.id_enterprise = in_id_enterprise
--								and ev.id_area = any( ids_areas)
--								and ev.id_site = any( ids_sites )
								and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ))
							end
							);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return QUERY 
	
	select
		id_enterprise, id_equipment, nm_equipment,
		array_agg(jsonb_build_object( 
			'info_per_period', info_per_period,
			'info_per_shift_or_team', info_per_shift,
			'ts_value', ts_value_production
		) order by ts_value_production) info
	from (
	select
		case when date_trunc(time_grain, now()) = ts_value then now() else ts_value end ts_value_production,
		id_enterprise, id_equipment, nm_equipment,
		jsonb_build_object(
			'net', sum(coalesce(net, 0))::float8 ,
			'gross', sum(coalesce(gross, 0))::float8 ,
			'scrap', sum(coalesce(scrap, 0))::float8 ,
			'target', sum(coalesce(target, 0))::int8 ,
			'speed', avg(speed),
			'speed_target', avg(ideal_speed)
		) as info_per_period,
		array_agg(obj order by coalesce (shift_position, team_position) ) as info_per_shift
		from (
			select 
				ts_value::timestamptz,
				ers.id_enterprise, e.id_equipment, nm_equipment,
				case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
				case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
				sum(coalesce(net_production_incr, 0)) net, sum(coalesce(gross_production_incr, 0)) gross, sum(coalesce(scrap_incr, 0)) scrap, avg(coalesce(pt.vl_hour, 0)) target,
				--coalesce(avg(case when ers.speed >0 then ers.speed end),0) as speed, 
				avg(ers.speed) as speed,
				avg(coalesce(ers.ideal_production_speed , e.production_speed,0)) as ideal_speed, 
				jsonb_build_object(							
					'id_shift', case group_by_element when 'SHIFTS' then id_shift END,
					'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
					'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
					'id_team', case group_by_element when 'TEAMS' then t.id_team END,
					'net', sum(coalesce(net_production_incr, 0)),
					'gross', sum(coalesce(gross_production_incr, 0)),
					'scrap', sum(coalesce(scrap_incr, 0)),
					'scrap_percentage', sum(coalesce(scrap_incr, 0)) / nullif( sum(coalesce(gross_production_incr, 0)) , 0),
					'scrap_target', avg(st.vl_shift),
					'target', avg(coalesce(pt.vl_hour, 0)),
					'speed', avg(ers.duration*ers.speed)/60,    --avg(coalesce(ers.speed, 0)),
					'speed_target', avg(coalesce(ers.ideal_production_speed, e.production_speed,0))
				) obj
			from 
				ca_agg_equipment_values_1hour ers
				left join production_targets pt using (id_equipment)
				left join equipments e using (id_equipment)
				left join shifts s using (id_shift)
				left join teams t using (id_team)
				left join scrap_targets st on (ers.id_equipment = st.id_equipment)
			where
				ts_value >= min_ts_prod
				and ts_value <= max_ts_prod
				and ers.id_enterprise = in_id_enterprise
				and ers.id_area = any( ids_areas)
				and ers.id_site = any( ids_sites )
				and ers.id_equipment =  any( ids_equips )
				and ers.id_shift = any( ids_shifts )
			group by 
				ers.id_enterprise, ts_value, e.id_equipment, nm_equipment,
				case group_by_element when 'SHIFTS' then ers.id_shift else null END,
				case group_by_element when 'SHIFTS' then s.cd_shift else null END,
				case group_by_element when 'SHIFTS' then s.sequence_position else null END,
				case group_by_element when 'TEAMS' then t.sequence_position else null end,
				t.id_team, t.cd_team
			) aa 
		group by ts_value, id_enterprise, id_equipment, nm_equipment order by ts_value
	)s0
group by id_enterprise, id_equipment, nm_equipment;

ELSE return QUERY 

select
		id_enterprise, id_equipment, nm_equipment,
		array_agg(jsonb_build_object( 
			'info_per_period', info_per_period,
			'info_per_shift_or_team', info_per_shift,
			'ts_value', ts_value_production
		) order by ts_value_production) info
	from (
select
	case when date_trunc(time_grain, now()) = date_trunc(time_grain, ts_value_production) then now() else ts_value_production end ts_value_production,
	id_enterprise, id_equipment, nm_equipment,
	jsonb_build_object(
			'net', sum(coalesce(net, 0))::float8 ,
			'gross', sum(coalesce(gross, 0))::float8 ,
			'scrap', sum(coalesce(scrap, 0))::float8 ,
			'target', sum(coalesce(target, 0))::int8 ,
			'speed', avg(speed),
			'speed_target', avg(ideal_speed)
	) as info_per_period,
	array_agg(obj order by coalesce (shift_position, team_position)) info_per_shift 
from (
	select 
		date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
		e.id_enterprise, e.id_equipment, nm_equipment,
		case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
		case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
		sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target,
		avg(ers.speed) as speed, avg(coalesce(ers.ideal_speed, e.production_speed,0)) as ideal_speed, jsonb_build_object(
			'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift END,
			'cd_shift', case group_by_element when 'SHIFTS' then ers.cd_shift END,
			'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
			'id_team', case group_by_element when 'TEAMS' then t.id_team END,
			'net', sum(coalesce(net, 0)),
			'gross', sum(coalesce(gross, 0)),
			'scrap', sum(coalesce(scrap, 0)),
			'scrap_percentage', sum(coalesce(scrap, 0)) / nullif( sum(coalesce(gross, 0)) , 0),
			'scrap_target', avg(st.vl_shift),
			'target', sum(coalesce(target, 0)),
			'speed', avg(coalesce(ers.speed, 0)),
			'speed_target', avg(coalesce(ers.ideal_speed, e.production_speed,0))
		) obj
	from 
		equipment_oee_shift ers
		join equipments e using (id_equipment) 
		join shifts s using (id_shift)
		left join teams t using (id_team)
		left join scrap_targets st on (ers.id_equipment = st.id_equipment)
	where
		ts_value >= min_ts_prod
		and ts_value_production <= max_ts_prod
		and e.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and e.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
		and (ers.id_team is null or ers.id_team = any( ids_teams) ) 
	group by e.id_enterprise, e.id_equipment, e.nm_equipment,
		date_trunc(time_grain, ts_value_production),
		case group_by_element when 'SHIFTS' then ers.id_shift else null END,
		case group_by_element when 'SHIFTS' then ers.cd_shift else null END,
		case group_by_element when 'SHIFTS' then s.sequence_position else null END,
		case group_by_element when 'TEAMS' then t.id_team else null END,
		case group_by_element when 'TEAMS' then t.cd_team else null end,
		case group_by_element when 'TEAMS' then t.sequence_position else null END
		) aa 
group by ts_value_production, id_enterprise, id_equipment, nm_equipment order by ts_value_production
)s0 group by id_enterprise, id_equipment, nm_equipment ;

END IF;

end
$$;


--
-- Name: h_piot_oee_progress_with_teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_progress_with_teams (
    id_enterprise integer,
    nm_entity character varying,
    oee_progress jsonb[]
);


--
-- Name: h_piot_oee_progress_new2(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_progress_new2(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false, is_team_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_progress_with_teams
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
begin  		
	if nav_level = 'SITE' then
	
		return query
		
		with basic_data as (
			select
				ts_value_production, ent.id_enterprise, s.id_site as id_entity, ent.nm_site as nm_entity, oee, oee_p, oee_a, oee_q,
				case
					when is_shift_filtered then cd_shift
					else null::varchar
				end cd_shift,
				case
					when is_shift_filtered then sft.sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then tms.cd_team--null::varchar --cd_team
					else null::varchar
				end cd_team,
				case
					when is_team_filtered then tms.sequence_position --null::int4 --team_sequence_position
					else null::int4
				end team_sequence_position
		    from site_oee_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join sites ent on (ent.id_site = s.id_site)
		    where
		    	ent.id_site = any(ids_sites::int[])
		        and s.ts_value_production >= date_trunc('day', in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day', in_end_time::timestamp+ interval '1 day')::date
		        and s.ts_value_production < now()
		    group by ts_value, ent.id_enterprise, ent.nm_site, ent.id_site, s.id_site,
			    case when is_shift_filtered then sft.sequence_position end,
			    case when is_team_filtered then tms.sequence_position end,
			    case when is_shift_filtered then sft.cd_shift end,
			    case when is_team_filtered then tms.cd_team end
		)
	select
			id_enterprise, nm_entity, array_agg(oee_data order by ts_value_production, sequence_position, team_sequence_position) oee_progress
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production, sequence_position, team_sequence_position,
				jsonb_build_object(
						'ts_value_production', ts_value_production,
						'cd_shift', cd_shift,
						'cd_team', cd_team,
						'oee', avg(oee),
						'oee_p', avg(oee_p),
						'oee_a', avg(oee_a),
						'oee_q', avg(oee_q)
				) oee_data
			from (
					select
						ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position,
						avg(oee) oee, avg(oee_p) oee_p, avg(oee_a) oee_a, avg(oee_q) oee_q
					from basic_data
					group by ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position
				)s0
			group by id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position, ts_value_production
		)s1
		group by id_enterprise, nm_entity;
	
	    
	elseif nav_level = 'AREA' then
	
		return query
		with basic_data as (
			select
				ts_value_production, ent.id_enterprise, s.id_area as id_entity, ent.nm_area as nm_entity, oee, oee_p, oee_a, oee_q,
				case
					when is_shift_filtered then cd_shift
					else null::varchar
				end cd_shift,
				case
					when is_shift_filtered then sft.sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then tms.cd_team--null::varchar --cd_team
					else null::varchar
				end cd_team,
				case
					when is_team_filtered then tms.sequence_position --null::int4 --team_sequence_position
					else null::int4
				end team_sequence_position
		    from area_oee_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join areas ent on (ent.id_area = s.id_area)
		    where
		    	ent.id_site = any(ids_sites::int[])
		    	and ent.id_area = any(ids_areas::int[])
		        and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date 
		        and s.ts_value_production < now()
		    group by ts_value, ent.id_enterprise, ent.nm_area, ent.id_site, s.id_area,
		    case when is_shift_filtered then sft.sequence_position end,
		    case when is_team_filtered then tms.sequence_position end,
		    case when is_shift_filtered then sft.cd_shift end,
		    case when is_team_filtered then tms.cd_team end
		)
--		select
--		id_enterprise, nm_entity,
--			array_agg(jsonb_build_object(
--				'ts_value_production', ts_value_production, 
--				'oee_data', oee_data
--			) order by ts_value_production) oee_progress
--	from (
		select
			id_enterprise, nm_entity, array_agg(oee_data order by ts_value_production, sequence_position, team_sequence_position) oee_progress
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production,sequence_position, team_sequence_position,
				jsonb_build_object(
						'ts_value_production', ts_value_production,
						'cd_shift', cd_shift,
						'cd_team', cd_team,
						'oee', avg(oee),
						'oee_p', avg(oee_p),
						'oee_a', avg(oee_a),
						'oee_q', avg(oee_q)
				) oee_data
			from (
					select
						ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position,
						avg(oee) oee, avg(oee_p) oee_p, avg(oee_a) oee_a, avg(oee_q) oee_q
					from basic_data
					group by ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position
				)s0
			group by id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position, ts_value_production
		)s1
		group by id_enterprise, nm_entity;


	else 
	
		return query
		with basic_data as (
			select
				ts_value_production, ent.id_enterprise, s.id_equipment as id_entity, ent.nm_equipment as nm_entity, oee, oee_p, oee_a, oee_q,
				case
					when is_shift_filtered then sft.cd_shift
					else null::varchar
				end cd_shift,
				case
					when is_shift_filtered then sft.sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then tms.cd_team
					else null::varchar
				end cd_team,
				case
					when is_team_filtered then tms.sequence_position --null::int4
					else null::int4
				end team_sequence_position
		    from equipment_oee_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join equipments ent on (ent.id_equipment = s.id_equipment and ent.tp_equipment=3)
		    where
		    	ent.id_site = any(ids_sites::int[])
		    	and ent.id_area = any(ids_areas::int[])
		    	and ent.id_equipment = any(ids_equips::int[])
		        and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
		        and s.ts_value_production < now()
		    group by ts_value, ent.id_enterprise, ent.nm_equipment, ent.id_site, s.id_equipment,
		    case when is_shift_filtered then sft.sequence_position end,
		    case when is_team_filtered then tms.sequence_position end,
		    case when is_shift_filtered then sft.cd_shift end,
		    case when is_team_filtered then tms.cd_team end
		)
		select
			id_enterprise, nm_entity, array_agg(oee_data order by ts_value_production, sequence_position, team_sequence_position) oee_progress
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production, sequence_position, team_sequence_position,
				jsonb_build_object(
						'ts_value_production', ts_value_production,
						'cd_shift', cd_shift,
						'cd_team', cd_team,
						'oee', avg(oee),
						'oee_p', avg(oee_p),
						'oee_a', avg(oee_a),
						'oee_q', avg(oee_q)
				) oee_data
			from (
					select
						ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position,
						avg(oee) oee, avg(oee_p) oee_p, avg(oee_a) oee_a, avg(oee_q) oee_q
					from basic_data
					group by ts_value_production, id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position
				)s0
			group by id_enterprise, nm_entity, cd_shift, cd_team, sequence_position, team_sequence_position, ts_value_production
		)s1
		group by id_enterprise, nm_entity;
	
	end if;
        
end
$$;


--
-- Name: h_piot_oee_score_data_test1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_score_data_test1 (
    id_enterprise integer,
    nav_name text,
    shift text,
    oee_timeline text[],
    oee_componentes jsonb,
    oee_info jsonb
);


--
-- Name: h_piot_oee_score_fix1(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_fix1(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_data_test1
    LANGUAGE plpgsql STABLE
    AS $$
declare 
	r RECORD;
begin  	
	-- if navigation level is sites, query for site
	if nav_level = 'SITE' THEN
		if not is_shift_filtered then
			return query
			select 
					in_id_enterprise as id_enterprise,
					nm_site::text as nav_name,
					null::text as shift,
					(select array_agg(oee::float8 order by ts_value)
						from site_oee_daily where id_site = s1.id_site 
							and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from 
				(
				select 
					--(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_site from sites where id_site = s.id_site) as nm_site,
					id_site,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0),1),0) as oee_p
					from site_oee_daily s
					where id_site = any( in_id_sites::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					group by s.id_site
				) s1
				group by 1, 2, 3, id_site
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					nm_site::text as nav_name,
					cd_shift::text as shift,
					(select array_agg(oee::float8 order by ts_value_production)
						from site_oee_shift where id_site = s1.id_site 
							and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_site from sites where id_site = s.id_site) as nm_site,
					s.id_site,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0),1),0) as oee_p
					from site_oee_shift s
					where id_site = any( in_id_sites::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					group by s.id_site, s.id_shift
				) s1
				group by 1, 2, 3, id_site
				order by 3;
		end if;
	ELSEif nav_level = 'AREA' THEN
		if not is_shift_filtered then
			return query
			select 
					in_id_enterprise as id_enterprise,
					nm_area::text as nav_name,
					null::text as shift,
					(select array_agg(oee::float8 order by ts_value)
						from area_oee_daily where id_area = s1.id_area 
							and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from 
				(
				select 
					(select nm_area from areas where id_area = s.id_area) as nm_area,
					id_area,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0),1),0) as oee_p
					from area_oee_daily s
					where id_area = any( in_id_areas::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					group by s.id_area
				) s1
				group by 1, 2, 3, id_area
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					nm_area::text as nav_name,
					cd_shift::text as shift,
					(select array_agg(oee::float8 order by ts_value_production)
						from area_oee_shift where id_area = s1.id_area 
							and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_area from areas where id_area = s.id_area) as nm_area,
					id_area,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0),1),0) as oee_p
					from area_oee_shift s
					where id_area = any( in_id_areas::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					group by s.id_area, s.id_shift
				) s1
				group by 1, 2, 3, id_area
				order by 3;
		end if;
	ELSEif nav_level = 'EQUIPMENT' THEN
		if not is_shift_filtered then
			return query
			select 
					in_id_enterprise as id_enterprise,
					cd_equipment::text as nav_name,
					null::text as shift,
					(select array_agg(oee::float8 order by ts_value)
						from equipment_oee_daily where id_equipment = s1.id_equipment 
							and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from 
				(
				select 
					(select cd_equipment from equipments where id_equipment = s.id_equipment) as cd_equipment,
					s.id_equipment,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0),1),0) as oee_p
					from equipment_oee_daily s
					where id_equipment = any( in_id_equipments::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					group by s.id_equipment
				) s1
				group by 1, 2, 3, id_equipment
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					cd_equipment::text as nav_name,
					cd_shift::text as shift,
					(select array_agg(oee::float8 order by ts_value_production)
						from equipment_oee_shift where id_equipment = s1.id_equipment 
							and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select cd_equipment from equipments where id_equipment = s.id_equipment) as cd_equipment,
					id_equipment,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0),1),0) as oee_p
					from equipment_oee_shift s
					where id_equipment = any( in_id_equipments::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
					group by s.id_equipment, s.id_shift
				) s1
				group by 1, 2, 3, id_equipment
				order by 3;
		end if;
	end if;
end
$$;


--
-- Name: h_piot_oee_score_fix1a(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_fix1a(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_data_test1
    LANGUAGE plpgsql STABLE
    AS $$
declare 
	r RECORD;
begin  	
	-- if navigation level is sites, query for site
	if nav_level = 'SITE' THEN
		if not is_shift_filtered then
			return query
			select 
					in_id_enterprise as id_enterprise,
					nm_site::text as nav_name,
					null::text as shift,
					(select array_agg(oee::float8 order by ts_value)
						from site_oee_daily where id_site = s1.id_site 
							and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from 
				(
				select 
					--(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_site from sites where id_site = s.id_site) as nm_site,
					id_site,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
					from site_oee_daily s
					where id_site = any( in_id_sites::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					group by s.id_site
				) s1
				group by 1, 2, 3, id_site
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					nm_site::text as nav_name,
					cd_shift::text as shift,
					(select array_agg(oee::float8 order by ts_value_production)
						from site_oee_shift where id_site = s1.id_site 
							and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_site from sites where id_site = s.id_site) as nm_site,
					s.id_site,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
					from site_oee_shift s
					where id_site = any( in_id_sites::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					group by s.id_site, s.id_shift
				) s1
				group by 1, 2, 3, id_site
				order by 3;
		end if;
	ELSEif nav_level = 'AREA' THEN
		if not is_shift_filtered then
			return query
			select 
					in_id_enterprise as id_enterprise,
					nm_area::text as nav_name,
					null::text as shift,
					(select array_agg(oee::float8 order by ts_value)
						from area_oee_daily where id_area = s1.id_area 
							and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from 
				(
				select 
					(select nm_area from areas where id_area = s.id_area) as nm_area,
					id_area,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
					from area_oee_daily s
					where id_area = any( in_id_areas::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					group by s.id_area
				) s1
				group by 1, 2, 3, id_area
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					nm_area::text as nav_name,
					cd_shift::text as shift,
					(select array_agg(oee::float8 order by ts_value_production)
						from area_oee_shift where id_area = s1.id_area 
							and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_area from areas where id_area = s.id_area) as nm_area,
					id_area,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
					from area_oee_shift s
					where id_area = any( in_id_areas::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					group by s.id_area, s.id_shift
				) s1
				group by 1, 2, 3, id_area
				order by 3;
		end if;
	ELSEif nav_level = 'EQUIPMENT' THEN
		if not is_shift_filtered then
			return query
			select 
					in_id_enterprise as id_enterprise,
					nm_equipment::text as nav_name,
					null::text as shift,
					(select array_agg(oee::float8 order by ts_value)
						from equipment_oee_daily where id_equipment = s1.id_equipment 
							and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from 
				(
				select 
					(select nm_equipment from equipments where id_equipment = s.id_equipment) as nm_equipment,
					s.id_equipment,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
					from equipment_oee_daily s
					where id_equipment = any( in_id_equipments::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					group by s.id_equipment
				) s1
				group by 1, 2, 3, id_equipment
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					nm_equipment::text as nav_name,
					cd_shift::text as shift,
					(select array_agg(oee::float8 order by ts_value_production)
						from equipment_oee_shift where id_equipment = s1.id_equipment 
							and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
							and ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					) as oee_timeline,
					jsonb_build_object(						
						 	'oee_q', sum(s1.oee_q),
						 	'oee_a', sum(s1.oee_a),
						 	'oee_p', sum(s1.oee_p),
						 	'oee', sum(s1.oee) 
							) as oee_componentes,
					jsonb_build_object(						 
						 	'running_time', coalesce(sum(s1.running_time), 0),
						 	'available_time', coalesce(sum(s1.available_time), 0),
						 	'total_prod', coalesce(sum(s1.total_prod), 0),
						 	'scrap', coalesce(sum(s1.scrap), 0),
						 	'prod_possible', coalesce(sum(s1.prod_possible), 0)
							) as oee_info
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_equipment from equipments where id_equipment = s.id_equipment) as nm_equipment,
					id_equipment,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
					GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
					GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
					from equipment_oee_shift s
					where id_equipment = any( in_id_equipments::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
					group by s.id_equipment, s.id_shift
				) s1
				group by 1, 2, 3, id_equipment
				order by 3;
		end if;
	end if;
end
$$;


--
-- Name: h_piot_oee_score_full_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_score_full_table (
    id_enterprise integer,
    nav_name text,
    oee_componentes jsonb,
    oee_info jsonb,
    shifts jsonb[],
    childs jsonb[]
);


--
-- Name: h_piot_oee_score_full_3(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_full_3(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_full_table
    LANGUAGE plpgsql STABLE
    AS $$
declare 
	child_nav_level varchar := (
								select 
									case nav_level 
										when 'SITE' then 'AREA'
										when 'AREA' then 'EQUIPMENT'
										else NULL
									end
								);
	-- F3 cutover fixup M4: tenant-scoped scope arrays. Empty input array => "all within tenant"
	-- (mirrors sibling h_piot_oee_score_with_teams). Prevents `= any('{}')` matching nothing.
	ids_sites int[] := (select array_agg(id_site) from sites
						where id_enterprise = in_id_enterprise
							and (cardinality(in_id_sites::int[]) = 0 or id_site = any(in_id_sites::int[])));
	ids_areas int[] := (select array_agg(id_area) from areas
						where id_enterprise = in_id_enterprise
							and (cardinality(in_id_areas::int[]) = 0 or id_area = any(in_id_areas::int[])));
	ids_equips int[] := (select array_agg(id_equipment) from equipments
						where id_enterprise = in_id_enterprise
							and tp_equipment = 3
							and (cardinality(in_id_equipments::int[]) = 0 or id_equipment = any(in_id_equipments::int[])));
begin
		
	
	
	if nav_level = 'SITE' THEN
	return query
		
	--	//Rever a velocidade ideal
with basic_data as
    ( select ts_value, ent.id_enterprise, sft.cd_shift, ent.nm_area as nm_entity, s.id_area as id_entity, parent.nm_site as nm_parent, sequence_position, ent.id_site as id_parent, avg(net) net, avg(e.ideal_speed)ideal_speed, avg(scrap) scrap, avg(running_time)running_time, avg(ideal_production)ideal_production, avg(available_time)available_time, avg(gross)gross
     from area_oee_shift s
     join shifts sft using (id_shift)
     join areas ent on (ent.id_area= s.id_area)
     join sites parent on (ent.id_site= parent.id_site)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_area
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_area)
          where e.id_site = any(ids_sites)
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_area, ts_value_production ) e on (e.id_area = s.id_area
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_site = any(ids_sites) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
         and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
         and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date 
     group by ts_value, ent.id_enterprise, sft.cd_shift, parent.nm_site,sequence_position, ent.id_site, ent.nm_area, s.id_area)     
     --Start of query
select id_enterprise,nav_name,oee_componentes,oee_info,shifts,childs from (
select id_enterprise,
	nm_entity::text as nav_name,
	id_parent,
    jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
    jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
    shifts
from
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
                	from basic_data
                    group by cd_shift, sequence_position, cd_shift, nm_parent, id_enterprise, id_parent )cld
                group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent) sub1
            group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info ) child_elements
        group by id_enterprise,nm_entity,id_parent)entity_sum
    group by id_enterprise,
    	nm_entity,
        id_parent,
        shifts
 )parent_data join (
--------Start of Childs Query
select id_enterprise,
       id_parent,
       array_agg(child) childs
from
    ( select id_enterprise,
             id_parent,
             nm_entity,
             coalesce(sum(gross), 0) gross,
             coalesce(sum(net), 0) net,
             coalesce(avg(ideal_speed), 0) ideal_speed,
             coalesce(sum(ideal_production), 0) ideal_production,
             coalesce(sum(scrap), 0)scrap,
             coalesce(sum(running_time), 0) running_time,
             coalesce(sum(available_time), 0)available_time,
             jsonb_build_object('nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shifts', sub1.shifts ) as child
     from
         ( select id_enterprise,
                  nm_entity,
                  id_parent,
                  coalesce(sum(gross), 0) gross,
                  coalesce(sum(net), 0) net,
                  coalesce(avg(ideal_speed), 0) ideal_speed,
                  coalesce(sum(ideal_production), 0) ideal_production,
                  coalesce(sum(scrap), 0)scrap,
                  coalesce(sum(running_time), 0) running_time,
                  coalesce(sum(available_time), 0)available_time,
                  jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
                  jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
                  shifts from
              ( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  order by sequence_position) as shifts
               from
                   ( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
                        ( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
                             ( select id_enterprise, id_parent, cd_shift, nm_entity, id_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
                              from basic_data
                              group by id_entity, cd_shift, sequence_position, cd_shift, nm_entity, id_enterprise, id_parent )cld
                         group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent) sub1
                    group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info ) child_elements
               group by id_enterprise,nm_entity,id_parent)entity_sum
          group by id_enterprise,
                   nm_entity,
                   id_parent,
                   shifts) sub1
     group by id_enterprise,
              id_parent,
              nm_entity,
              oee_componentes,
              oee_info,
              shifts) s1
group by id_enterprise,
         id_parent ) children using (id_enterprise, id_parent);
--------End of Childs Query
        
        
        
        
        elseif nav_level = 'AREA' THEN
        return query
        
		
	--	//Rever a velocidade ideal
with basic_data as
    ( select ts_value, ent.id_enterprise, sft.cd_shift, ent.nm_equipment as nm_entity, s.id_equipment as id_entity, parent.nm_area as nm_parent, sequence_position, parent.id_area as id_parent, avg(net) net, avg(e.ideal_speed)ideal_speed, avg(scrap) scrap, avg(running_time)running_time, avg(ideal_production)ideal_production, avg(available_time)available_time, avg(gross)gross
     from equipment_oee_shift s
     join shifts sft using (id_shift)
     join equipments ent on (ent.id_equipment= s.id_equipment)
     join areas parent on (ent.id_area= parent.id_area)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_equipment
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_equipment)
          where e.id_equipment = any(ids_equips)
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_equipment, ts_value_production ) e on (e.id_equipment = s.id_equipment
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_area = any(ids_areas) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
        and ent.tp_equipment =3 
     	and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
        group by ts_value, ent.id_enterprise, sft.cd_shift, parent.nm_area,sequence_position, parent.id_area, ent.nm_equipment, s.id_equipment)
--Start of query
select 
	id_enterprise,nav_name,oee_componentes,oee_info,shifts,childs
 from (
select id_enterprise,
	nm_entity::text as nav_name,
	id_parent,
    jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
    jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
    shifts
from
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	(select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
                	from basic_data
                    group by cd_shift, sequence_position, cd_shift, nm_parent, id_enterprise, id_parent
                    )cld
                group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent
                ) sub1
            group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info ) child_elements
        group by id_enterprise,nm_entity,id_parent
        )entity_sum
    group by id_enterprise,
    	nm_entity,
        id_parent,
        shifts
 )parent_data join (
--------Start of Childs Query
select id_enterprise,
       id_parent,
       array_agg(child) childs
from
    ( select id_enterprise,
             id_parent,
             nm_entity,
             coalesce(sum(gross), 0) gross,
             coalesce(sum(net), 0) net,
             coalesce(avg(ideal_speed), 0) ideal_speed,
             coalesce(sum(ideal_production), 0) ideal_production,
             coalesce(sum(scrap), 0)scrap,
             coalesce(sum(running_time), 0) running_time,
             coalesce(sum(available_time), 0)available_time,
             jsonb_build_object('nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shifts', sub1.shifts ) as child
     from
         ( select id_enterprise,
                  nm_entity,
                  id_parent,
                  coalesce(sum(gross), 0) gross,
                  coalesce(sum(net), 0) net,
                  coalesce(avg(ideal_speed), 0) ideal_speed,
                  coalesce(sum(ideal_production), 0) ideal_production,
                  coalesce(sum(scrap), 0)scrap,
                  coalesce(sum(running_time), 0) running_time,
                  coalesce(sum(available_time), 0)available_time,
                  jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
                  jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
                  shifts from
              ( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  order by sequence_position) as shifts
               from
                   ( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
                        ( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
                             ( select id_enterprise, id_parent, cd_shift, nm_entity, id_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
                              from basic_data
                              group by id_entity, cd_shift, sequence_position, cd_shift, nm_entity, id_enterprise, id_parent )cld
                         group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent) sub1
                    group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info ) child_elements
               group by id_enterprise,nm_entity,id_parent)entity_sum
          group by id_enterprise,
                   nm_entity,
                   id_parent,
                   shifts) sub1
     group by id_enterprise,
              id_parent,
              nm_entity,
              oee_componentes,
              oee_info,
              shifts order by nm_entity ) s1
group by id_enterprise,
         id_parent) children using (id_enterprise, id_parent);
        
        
        
--------End of Childs Query
      else 
        return query
        
		
	--	//Rever a velocidade ideal
with basic_data as
    ( select ts_value, parent.id_enterprise, sft.cd_shift, null as nm_entity, null as id_entity, parent.nm_equipment as nm_parent, sequence_position, parent.id_equipment as id_parent, avg(net) net, avg(e.ideal_speed)ideal_speed, avg(scrap) scrap, avg(running_time)running_time, avg(ideal_production)ideal_production, avg(available_time)available_time, avg(gross)gross
     from equipment_oee_shift s
     join shifts sft using (id_shift)
     join equipments parent on (parent.id_equipment= s.id_equipment)
     --join areas parent on (ent.id_site= parent.id_site)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_equipment
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_equipment)
          where e.id_equipment = any(ids_equips)
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_equipment, ts_value_production ) e on (e.id_equipment = s.id_equipment
                                                          and e.ts_value_production = e.ts_value_production)
     where parent.id_equipment = any(ids_equips) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
        and parent.tp_equipment =3 
     	and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date 
        group by ts_value, parent.id_enterprise, sft.cd_shift, parent.nm_equipment,sequence_position, parent.id_equipment)
        --select * from basic_data;
--Start of query
select 
	id_enterprise,nav_name,oee_componentes,oee_info,shifts, null::jsonb[] as childs
 from (
select id_enterprise,
	nm_entity::text as nav_name,
	id_parent,
    jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
    jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
    shifts
from
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q, GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee, GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
                	from basic_data
                    group by cd_shift, sequence_position, cd_shift, nm_parent, id_enterprise, id_parent )cld
                group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent) sub1
            group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info ) child_elements
        group by id_enterprise,nm_entity,id_parent)entity_sum
    group by id_enterprise,
    	nm_entity,
        id_parent,
        shifts
 )parent_data;
        
        
        
--------End of Childs Query
       end if;
        
        
end
$$;


--
-- Name: h_piot_oee_score_teams_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_score_teams_table (
    id_enterprise integer,
    nav_name text,
    oee_componentes jsonb,
    oee_info jsonb,
    shifts jsonb[],
    teams jsonb[],
    childs jsonb[]
);


--
-- Name: h_piot_oee_score_with_teams(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_with_teams(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_teams_table
    LANGUAGE plpgsql STABLE
    AS $$
declare 
	ids_sites int[] := (select array_agg(id_site) 
						from sites s
						where s.id_enterprise=in_id_enterprise 
							and case 
								when cardinality(in_id_sites::int[]) = 0 then true
								else id_site = any( in_id_sites::int[])
							end);
	ids_areas int[] := (select array_agg(id_area) 
						from areas s
						where s.id_enterprise=in_id_enterprise 
							and id_site = any(ids_sites)
							and case
								when cardinality(in_id_areas::int[]) = 0 then true
								else id_area = any( in_id_areas::int[])
							end);
	ids_equips int[] := (
						select array_agg(id_equipment) 
						from equipments s
						where s.id_enterprise=in_id_enterprise 
							and s.tp_equipment=3
							and id_area = any(ids_areas)
							and case
								when cardinality(in_id_equipments::int[]) = 0 then true
								else id_equipment = any( in_id_equipments::int[])
							end);
begin
return query

with basic_data as(
	select
		ts_value,
		_equipments.id_enterprise,
		cd_shift,
		case nav_level
			when 'EQUIPMENT' then null
			when 'AREA' then _equipments.nm_equipment
			when 'SITE' then _areas.nm_area
		end as nm_entity,
		case nav_level
			when 'EQUIPMENT' then null
			when 'AREA' then _equipments.id_equipment
			when 'SITE' then _areas.id_area
		end as id_entity,
		case nav_level
			when 'EQUIPMENT' then _equipments.nm_equipment
			when 'AREA' then _areas.nm_area
			when 'SITE' then _sites.nm_site
		end as nm_parent,
		sequence_position,
		case nav_level
			when 'EQUIPMENT' then _equipments.id_equipment
			when 'AREA' then _areas.id_area
			when 'SITE' then _sites.id_site
		end as id_parent,
		sum(net) net,
		avg(s0.ideal_speed) ideal_speed,
		sum(scrap) scrap,
		sum(running_time) running_time,
		sum(ideal_production) ideal_production,
		sum(available_time) available_time,
		sum(gross) gross,
		id_team,
		cd_team 
	from(
		select 
			ts_value,
			_equipments.id_enterprise,
			_equipments.id_equipment,
			sft.cd_shift,
			sft.sequence_position,
			avg(net) net,
			avg(e.ideal_speed) ideal_speed,
			avg(scrap) scrap,
			avg(running_time) running_time,
			avg(ideal_production) ideal_production,
			avg(available_time) available_time,
			avg(gross) gross,
			id_team,
			cd_team
		from 
			equipment_oee_shift s
			join shifts sft using (id_shift)
			left join teams tms using (id_team)
			join equipments _equipments on (_equipments.id_equipment= s.id_equipment)
			left join(
				select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_equipment
				from
					ca_agg_equipment_values_1hour caevh
					join equipments e using (id_equipment)
				where 
					e.id_equipment = any(ids_equips::int[])
					and caevh.ts_value_production >= date_trunc('day', in_begin_time::timestamp)::date
					and caevh.ts_value_production < date_trunc('day', in_end_time::timestamp+ interval '1 day')::date
				group by 
					e.id_equipment,
					ts_value_production
			) e on (e.id_equipment = s.id_equipment and e.ts_value_production = e.ts_value_production)
		where 
			_equipments.id_equipment = any(ids_equips::int[])
			and _equipments.tp_equipment =3 
			and s.ts_value_production >= date_trunc('day', in_begin_time::timestamp)::date
			and s.ts_value_production < date_trunc('day', in_end_time::timestamp+ interval '1 day')::date
		group by
			_equipments.id_enterprise,
			_equipments.id_equipment,
			id_team,
			cd_team,
			sft.cd_shift,
			ts_value,
			sft.sequence_position
	) s0
	join equipments _equipments on (_equipments.id_equipment= s0.id_equipment)
	join areas _areas on (_equipments.id_area = _areas.id_area)
	join sites _sites on (_equipments.id_site = _sites.id_site)
	group by
		ts_value,
		_equipments.id_enterprise,
		cd_shift,
		case nav_level
			when 'EQUIPMENT' then _equipments.nm_equipment
			when 'AREA' then _areas.nm_area
			when 'SITE' then _sites.nm_site
		end,
		sequence_position,
		case nav_level
			when 'EQUIPMENT' then _equipments.id_equipment
			when 'AREA' then _areas.id_area
			when 'SITE' then _sites.id_site
		end,
		case nav_level
			when 'EQUIPMENT' then null
			when 'AREA' then _equipments.id_equipment
			when 'SITE' then _areas.id_area
		end,
		case nav_level
			when 'EQUIPMENT' then null
			when 'AREA' then _equipments.nm_equipment
			when 'SITE' then _areas.nm_area
		end,
		id_team,
		cd_team
)
--Start of query
select 
	id_enterprise,
	nav_name,
	oee_componentes,
	oee_info,shifts,
	teams,
	case nav_level
		when 'EQUIPMENT' then null::jsonb[]
		else childs
	end as childs
from(
	select
		id_enterprise,
		nm_entity::text as nav_name,
		id_parent,
		jsonb_build_object(
			'oee_q', sum(sss0.oee_q),
			'oee_a', sum(sss0.oee_a),
			'oee_p', sum(sss0.oee_p),
			'oee', sum(sss0.oee)
		) as oee_componentes,
		jsonb_build_object(
			'running_time', coalesce(sum(sss0.running_time), 0),
			'available_time', coalesce(sum(sss0.available_time), 0),
			'total_prod', coalesce(sum(sss0.net), 0),
			'scrap', coalesce(sum(sss0.scrap), 0),
			'ideal_speed', coalesce(avg(sss0.ideal_speed), 0),
			'avg_speed', coalesce(sum(sss0.oee_p) * avg(sss0.ideal_speed), 0)
		) as oee_info,
		shifts,
		teams
	from (
		select
			*
		from (
			select
				id_enterprise,
				nm_entity,
				id_parent,
				coalesce(sum(net), 0) as net,
				coalesce(sum(gross),0) as gross,
				coalesce(avg(ideal_speed), 0) as ideal_speed,
				coalesce(sum(scrap),0) as scrap,
				coalesce(sum(ideal_production),0) as ideal_production,
				coalesce(sum(running_time),0) as running_time,
				coalesce(sum(available_time),0) as available_time,
				GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
				GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
				GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
				GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p,
				array_agg(child_shift order by sequence_position) as shifts
			from (
				select
					id_enterprise,
					nm_entity,
					sequence_position,
					id_parent,
					coalesce(sum(net), 0) net,
					coalesce(avg(ideal_speed), 0) ideal_speed,
					coalesce(sum(ideal_production), 0) ideal_production,
					coalesce(sum(scrap), 0)scrap,
					coalesce(sum(gross), 0)gross,
					coalesce(sum(running_time), 0) running_time,
					coalesce(sum(available_time), 0)available_time,
					jsonb_build_object(
						'nav_name', nm_entity,
						'oee_componentes', oee_componentes,
						'oee_info', oee_info,
						'shift', cd_shift
					) as child_shift
				from (
					select
						id_enterprise,
						nm_entity,
						cd_shift,
						sequence_position,
						id_parent,
						coalesce(sum(gross), 0) gross,
						coalesce(sum(net), 0) net,
						coalesce(avg(ideal_speed), 0) ideal_speed,
						coalesce(sum(ideal_production), 0) ideal_production,
						coalesce(sum(scrap), 0)scrap,
						coalesce(sum(running_time), 0) running_time,
						coalesce(sum(available_time), 0)available_time,
						jsonb_build_object(
							'oee_q', sum(oee_q),
							'oee_a', sum(oee_a),
							'oee_p', sum(oee_p),
							'oee', sum(oee)
						) as oee_componentes,
						jsonb_build_object(
							'running_time', coalesce(sum(running_time), 0),
							'available_time', coalesce(sum(available_time), 0),
							'total_prod', coalesce(sum(net), 0),
							'scrap', coalesce(sum(scrap), 0),
							'ideal_speed', coalesce(avg(ideal_speed), 0),
							'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
						) as oee_info
					from (
						select
							id_enterprise,
							id_parent,
							cd_shift,
							nm_parent as nm_entity,
							sequence_position,
							coalesce(sum(net),0) as net,
							coalesce(sum(gross),0) as gross,
							coalesce(avg(ideal_speed), 0) as ideal_speed,
							coalesce(sum(scrap),0) as scrap,
							coalesce(sum(running_time),0) as running_time,
							coalesce(sum(ideal_production), 0) ideal_production,
							coalesce(sum(available_time),0) as available_time,
							GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
							GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
							GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
							GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
						from basic_data
						group by cd_shift, sequence_position, cd_shift, nm_parent, id_enterprise, id_parent
					)cld
					group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent
				) sub1
				group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info
			) child_elements
			group by id_enterprise,nm_entity,id_parent
		)entity_sum
		group by id_enterprise, nm_entity, id_parent, shifts, net, gross, ideal_production, ideal_speed, scrap, running_time , available_time, oee, oee_a, oee_p, oee_q 
	)sss0
	left join (
		select
			*
		from (
			select
				id_enterprise,
				nm_entity,
				id_parent,
				coalesce(sum(net),0) as net,
				coalesce(sum(gross),0) as gross,
				coalesce(avg(ideal_speed),0) as ideal_speed,
				coalesce(sum(scrap),0) as scrap,
				coalesce(sum(ideal_production),0) as ideal_production,
				coalesce(sum(running_time),0) as running_time,
				coalesce(sum(available_time),0) as available_time,
				GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
				GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
				GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
				GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p,
				array_agg(child_team) as teams
			from (
				select 
					id_enterprise,
					nm_entity,
					id_parent,
					coalesce(sum(net),0) net,
					coalesce(avg(ideal_speed),0) ideal_speed,
					coalesce(sum(ideal_production), 0) ideal_production,
					coalesce(sum(scrap), 0)scrap,
					coalesce(sum(gross), 0)gross,
					coalesce(sum(running_time),0) running_time,
					coalesce(sum(available_time),0)available_time,
					jsonb_build_object(
						'nav_name', nm_entity,
						'oee_componentes', oee_componentes,
						'oee_info', oee_info,
						'team', cd_team
					) as child_team
				from (
					select
						id_enterprise,
						nm_entity,
						cd_team,
						id_parent,
						coalesce(sum(gross), 0) gross,
						coalesce(sum(net), 0) net,
						coalesce(avg(ideal_speed), 0) ideal_speed,
						coalesce(sum(ideal_production), 0) ideal_production,
						coalesce(sum(scrap), 0) scrap,
						coalesce(sum(running_time), 0) running_time,
						coalesce(sum(available_time), 0) available_time,
						jsonb_build_object(
							'oee_q', sum(oee_q),
							'oee_a', sum(oee_a),
							'oee_p', sum(oee_p),
							'oee', sum(oee)
						) as oee_componentes,
						jsonb_build_object(
							'running_time', coalesce(sum(running_time), 0),
							'available_time', coalesce(sum(available_time), 0),
							'total_prod', coalesce(sum(net), 0),
							'scrap', coalesce(sum(scrap), 0),
							'ideal_speed', coalesce(avg(ideal_speed), 0),
							'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
						) as oee_info
					from (
						select
							id_enterprise,
							id_parent,
							cd_team,
							nm_parent as nm_entity,
							coalesce(sum(net),0) as net,
							coalesce(sum(gross),0) as gross,
							coalesce(avg(ideal_speed), 0) as ideal_speed,
							coalesce(sum(scrap),0) as scrap,
							coalesce(sum(running_time),0) as running_time,
							coalesce(sum(ideal_production), 0) ideal_production,
							coalesce(sum(available_time),0) as available_time,
							GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
							GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
							GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
							GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
						from basic_data
						group by cd_team, nm_parent, id_enterprise, id_parent
					)cld
					group by id_enterprise, nm_entity, cd_team, id_parent
				) sub1
				group by id_enterprise, nm_entity, id_parent, oee_componentes, oee_info, cd_team
			) child_elements
			group by id_enterprise,nm_entity,id_parent
		)entity_sum
		group by id_enterprise, nm_entity, id_parent, teams, net, gross, ideal_production, ideal_speed, scrap, running_time , available_time, oee, oee_a, oee_p, oee_q
	)sss1 using (id_enterprise, nm_entity, id_parent)
	group by id_enterprise, nm_entity, id_parent, shifts, teams
)parent_data
--------Start of Childs Query
join (
	select 
		id_enterprise,
		id_parent,
		array_agg(child) childs
	from (
		select
			id_enterprise,
			id_parent,
			nm_entity,
			coalesce(sum(gross), 0) gross,
			coalesce(sum(net), 0) net,
			coalesce(avg(ideal_speed), 0) ideal_speed,
			coalesce(sum(ideal_production), 0) ideal_production,
			coalesce(sum(scrap), 0)scrap,
			coalesce(sum(running_time), 0) running_time,
			coalesce(sum(available_time), 0)available_time,
			jsonb_build_object('nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shifts', sub1.shifts ) as child
		from (
			select 
				id_enterprise,
				nm_entity,
				id_parent,
				coalesce(sum(gross), 0) gross,
				coalesce(sum(net), 0) net,
				coalesce(avg(ideal_speed), 0) ideal_speed,
				coalesce(sum(ideal_production), 0) ideal_production,
				coalesce(sum(scrap), 0)scrap,
				coalesce(sum(running_time), 0) running_time,
				coalesce(sum(available_time), 0)available_time,
				jsonb_build_object(
					'oee_q', sum(oee_q),
					'oee_a', sum(oee_a),
					'oee_p', sum(oee_p),
					'oee', sum(oee)
				) as oee_componentes,
				jsonb_build_object(
					'running_time', coalesce(sum(running_time), 0),
					'available_time', coalesce(sum(available_time), 0),
					'total_prod', coalesce(sum(net), 0),
					'scrap', coalesce(sum(scrap), 0),
					'ideal_speed', coalesce(avg(ideal_speed), 0),
					'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
				) as oee_info, shifts
			from (
				select
					sss0.id_enterprise,
					sss0.nm_entity,
					sss0.id_parent,
					sss0.net,
					sss0.gross,
					sss0.ideal_speed,
					sss0.scrap,
					sss0.available_time,
					sss0.ideal_production,
					sss0.running_time,
					sss0.oee_p,
					sss0.oee_q,
					sss0.oee_a,
					sss0.oee,
					shifts,
					teams
				from(
					select 
						id_enterprise,
						nm_entity,
						id_parent,
						coalesce(sum(net),0) as net,
						coalesce(sum(gross),0) as gross,
						coalesce(avg(ideal_speed), 0) as ideal_speed,
						coalesce(sum(scrap),0) as scrap,
						coalesce(sum(ideal_production),0) as ideal_production,
						coalesce(sum(running_time),0) as running_time,
						coalesce(sum(available_time),0) as available_time,
						GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
						GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
						GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
						GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
					from (
						select
							id_enterprise,
							nm_entity,
							sequence_position,
							id_parent,
							coalesce(sum(net), 0) net,
							coalesce(avg(ideal_speed), 0) ideal_speed,
							coalesce(sum(ideal_production), 0) ideal_production,
							coalesce(sum(scrap), 0) scrap,
							coalesce(sum(gross), 0) gross,
							coalesce(sum(running_time), 0) running_time,
							coalesce(sum(available_time), 0) available_time,
							jsonb_build_object(
								'nav_name', nm_entity,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info,
								'shift', cd_shift
							) as child_shift
						from (
							select
								id_enterprise,
								nm_entity,
								cd_shift,
								sequence_position,
								id_parent,
								coalesce(sum(gross), 0) gross,
								coalesce(sum(net), 0) net,
								coalesce(avg(ideal_speed), 0) ideal_speed,
								coalesce(sum(ideal_production), 0) ideal_production,
								coalesce(sum(scrap), 0) scrap,
								coalesce(sum(running_time), 0) running_time,
								coalesce(sum(available_time), 0) available_time,
								jsonb_build_object(
									'oee_q', sum(oee_q),
									'oee_a', sum(oee_a),
									'oee_p', sum(oee_p),
									'oee', sum(oee)
								) as oee_componentes,
								jsonb_build_object(
									'running_time', coalesce(sum(running_time), 0),
									'available_time', coalesce(sum(available_time), 0),
									'total_prod', coalesce(sum(net), 0),
									'scrap', coalesce(sum(scrap), 0),
									'ideal_speed', coalesce(avg(ideal_speed), 0),
									'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
								) as oee_info
							from (
								select
									id_enterprise,
									id_parent,
									cd_shift,
									nm_entity,
									id_entity,
									sequence_position,
									coalesce(sum(net),0) as net,
									coalesce(sum(gross),0) as gross,
									coalesce(avg(ideal_speed), 0) as ideal_speed,
									coalesce(sum(scrap),0) as scrap,
									coalesce(sum(running_time),0) as running_time,
									coalesce(sum(ideal_production), 0) as ideal_production,
									coalesce(sum(available_time),0) as available_time,
									GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
									GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
									GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
									GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
								from basic_data
								group by id_entity, cd_shift, sequence_position, cd_shift, nm_entity, id_enterprise, id_parent
							)cld
							group by id_enterprise, nm_entity, cd_shift, sequence_position, id_parent
						) sub1
						group by id_enterprise, cd_shift, nm_entity, sequence_position, id_parent, oee_componentes, oee_info
					) child_elements
					group by id_enterprise,nm_entity,id_parent
				) sss0
				left join (
					select 
						id_enterprise,
						nm_entity,
						id_parent,
						array_agg(child_team) as teams
					from (
						select
							id_enterprise,
							nm_entity,
							id_parent,
							coalesce(sum(net), 0) net,
							coalesce(avg(ideal_speed), 0) ideal_speed,
							coalesce(sum(ideal_production), 0) ideal_production,
							coalesce(sum(scrap), 0) scrap,
							coalesce(sum(gross), 0) gross,
							coalesce(sum(running_time), 0) running_time,
							coalesce(sum(available_time), 0)available_time,
							jsonb_build_object(
								'nav_name', nm_entity,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info,
								'team', cd_team
							) as child_team
						from (
							select
								id_enterprise,
								nm_entity,
								cd_team,
								id_parent,
								coalesce(sum(gross), 0) gross,
								coalesce(sum(net), 0) net,
								coalesce(avg(ideal_speed), 0) ideal_speed,
								coalesce(sum(ideal_production), 0) ideal_production,
								coalesce(sum(scrap), 0)scrap,
								coalesce(sum(running_time), 0) running_time,
								coalesce(sum(available_time), 0)available_time,
								jsonb_build_object(
									'oee_q', sum(oee_q),
									'oee_a', sum(oee_a),
									'oee_p', sum(oee_p),
									'oee', sum(oee)
								) as oee_componentes,
								jsonb_build_object(
									'running_time', coalesce(sum(running_time), 0),
									'available_time', coalesce(sum(available_time), 0),
									'total_prod', coalesce(sum(net), 0),
									'scrap', coalesce(sum(scrap), 0),
									'ideal_speed', coalesce(avg(ideal_speed), 0),
									'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0)
								) as oee_info
							from (
								select
									id_enterprise,
									id_parent,
									cd_team,
									nm_entity,
									id_entity,
									coalesce(sum(net),0) as net,
									coalesce(sum(gross),0) as gross,
									coalesce(avg(ideal_speed), 0) as ideal_speed,
									coalesce(sum(scrap),0) as scrap,
									coalesce(sum(running_time),0) as running_time,
									coalesce(sum(ideal_production), 0) ideal_production,
									coalesce(sum(available_time),0) as available_time,
									GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(gross),0),0),1),0) as oee_q,
									GREATEST(LEAST(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0),1),0) as oee_a,
									GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0),1),0) as oee,
									GREATEST(LEAST(coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0),1),0) as oee_p
								from basic_data
								group by id_entity, cd_team, cd_team, nm_entity, id_enterprise, id_parent
							)cld
							group by id_enterprise, nm_entity, cd_team, id_parent
						) sub1
						group by id_enterprise, cd_team, nm_entity, id_parent, oee_componentes, oee_info
					) child_elements
					group by id_enterprise,nm_entity,id_parent
				)sss1 using (id_enterprise, nm_entity, id_parent)
			)entity_sum
			group by id_enterprise, nm_entity, id_parent, shifts, teams
		)sub1
		group by id_enterprise, id_parent, nm_entity, oee_componentes, oee_info, shifts
	) s1
	group by id_enterprise, id_parent
) children using (id_enterprise, id_parent);

end $$;


--
-- Name: h_overview_i_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_overview_i_events (
    id_enterprise integer,
    start text,
    "end" text,
    duration character varying,
    reason character varying,
    sub_category character varying,
    machine character varying,
    notes character varying,
    colorcolumn text
);


--
-- Name: h_piot_overview_i_get_events(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_overview_i_get_events(idequipment integer) RETURNS SETOF public.h_overview_i_events
    LANGUAGE sql STABLE
    AS $$


select id_enterprise,"start","end",duration,reason,sub_category,machine,notes,colorcolumn from (
select 
        ee.id_enterprise, 
        ts_event,
        to_char(timezone(st.timezone, ts_event), 'DD/MM HH24:MI' ) as "start",
        coalesce(to_char(timezone(st.timezone, ts_end), 'DD/MM HH24:MI'), '-') as "end",
        coalesce((interval '1sec'*ee.duration)::varchar, ' ') as "duration", 
        coalesce(ee.cd_category, ' ')  "reason",
        coalesce(ee.cd_subcategory, ' ')  "sub_category", 
        coalesce(ee.cd_machine, ' ') "machine",
        coalesce(ee.txt_downtime_notes, ' ') "notes" ,
        case 
            when ts_end is null then 'runningStop'
            when ts_end is not null and ee.cd_category is null then 'notJustified' 
            else 'justified'
        end as colorcolumn
from equipment_events ee 
inner join equipments e using (id_equipment)
left join sites st using (id_site)
where 
status != 6
--eduardo adicionou a linha abaixo para delimitar eventos as ultimas 2 semanas
and ee.ts_event >= now() - interval '14 day'
and coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time 
and 
	case (select overview_events_type from equipments e where id_equipment = idEquipment)
		when 1 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
												join equipments e4 on (e3.id_parentequipment= e4.id_equipment)
											where e2.tp_equipment = 1 and e4.id_equipment = idEquipment
											)
		else e.id_equipment = idEquipment
	end
and 
	case 
		when (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) is not null
		then (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) = ee.idle 
		else true
	end
UNION
	select 
        ee.id_enterprise, 
        ts_event,
        to_char(timezone(st.timezone, ts_event), 'DD/MM HH24:MI' ) as "start",
        coalesce(to_char(timezone(st.timezone, ts_end), 'DD/MM HH24:MI'), '-') as "end",
        coalesce((interval '1sec'*ee.duration)::varchar, ' ') as "duration", 
        coalesce(ee.cd_category, ' ')  "reason",
        coalesce(ee.cd_subcategory, ' ')  "sub_category", 
        coalesce(ee.cd_machine, ' ') "machine",
        coalesce(ee.txt_downtime_notes, ' ') "notes" ,
        case 
            when ts_end is null then 'runningStop'
            when ts_end is not null and ee.cd_category is null then 'notJustified' 
            else 'justified'
        end as colorcolumn
from equipment_events_man ee 
inner join equipments e using (id_equipment)
left join sites st using (id_site)
where 
--status != 6
--and 
coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time 
and 
	case (select overview_events_type from equipments e where id_equipment = idEquipment)
		when 1 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
												join equipments e4 on (e3.id_parentequipment= e4.id_equipment)
											where e2.tp_equipment = 1 and e4.id_equipment = idEquipment
											)
		else e.id_equipment = idEquipment
	end
and 
	case 
		when (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) is not null
		then (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) = ee.idle 
		else true
	end
	) DAT	
order by ts_event desc 
limit 5;

$$;


--
-- Name: h_overview_i_events_3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_overview_i_events_3 (
    id_enterprise integer,
    start timestamp without time zone,
    "end" timestamp without time zone,
    duration character varying,
    reason character varying,
    sub_category character varying,
    cd_sector character varying,
    machine character varying,
    notes character varying,
    colorcolumn text
);


--
-- Name: h_piot_overview_i_get_events_3(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_overview_i_get_events_3(idequipment integer) RETURNS SETOF public.h_overview_i_events_3
    LANGUAGE sql STABLE
    AS $$


select id_enterprise,"start","end",duration,reason,sub_category,cd_sector,machine,notes,colorcolumn from (
select 
	ee.id_enterprise,
	case
		when e.tp_equipment = 2 then e.nm_equipment
		when pe.tp_equipment = 2 then pe.nm_equipment
		else null::varchar
	end cd_sector,
	ts_event,
	timezone(st.timezone, ts_event) as "start",
	timezone(st.timezone, ts_end) as "end",
	--coalesce((interval '1sec'*ee.duration)::varchar, ' ') as "duration", 
	--novo Eduardo 2024-09-25 to show the duration of a stop in progress
	coalesce((interval '1sec'*ee.duration)::varchar, ((interval '1sec')*extract(epoch from now()- (ts_event))::int)::varchar) as "duration", 
	coalesce(ee.cd_category, ' ')  "reason",
	coalesce(ee.cd_subcategory, ' ')  "sub_category", 
	coalesce(ee.cd_machine, ' ') "machine",
	coalesce(ee.txt_downtime_notes, ' ') "notes" ,
	case 
		when ts_end is null then 'runningStop'
		when ts_end is not null and ee.cd_category is null then 'notJustified' 
		else 'justified'
	end as colorcolumn
from equipment_events ee 
inner join equipments e using (id_equipment)
left join sites st using (id_site)
left join equipments pe on (e.id_parentequipment=pe.id_equipment)
where 
status != 6
--eduardo adicionou a linha abaixo para delimitar eventos as ultimas 2 semanas
and ee.ts_event >= now() - interval '14 day'
and coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time 
and 
	case (select overview_events_type from equipments e where id_equipment = idEquipment)
		when 1 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
												join equipments e4 on (e3.id_parentequipment= e4.id_equipment)
											where e2.tp_equipment = 1 and e4.id_equipment = idEquipment
											)
		when 2 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
											where e2.tp_equipment = 2 and e3.id_equipment = idEquipment
											)
		else e.id_equipment = idEquipment
	end
and 
	case 
		when (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) is not null
		then (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) = ee.idle 
		else true
	end
	
	
union

	select 
		ee.id_enterprise, 
		case
			when e.tp_equipment = 2 then e.nm_equipment
			when pe.tp_equipment = 2 then pe.nm_equipment
			else null::varchar
		end cd_sector,
		ts_event,
		timezone(st.timezone, ts_event) as "start",
		timezone(st.timezone, ts_end) as "end",
		--coalesce((interval '1sec'*ee.duration)::varchar, ' ') as "duration", 
		--novo Eduardo 2024-09-25 to show the duration of a stop in progress
		--coalesce((interval '1sec'*ee.duration)::varchar, ((interval '1sec')*extract(epoch from now()- (ts_event))::int)::varchar) as "duration", 
		case when idequipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3)
		then null else coalesce((interval '1sec'*ee.duration)::varchar, ((interval '1sec')*extract(epoch from now()- (ts_event))::int)::varchar) end as "duration",
		coalesce(ee.cd_category, ' ')  "reason",
		coalesce(ee.cd_subcategory, ' ')  "sub_category", 
		coalesce(ee.cd_machine, ' ') "machine",
		--coalesce(ee.txt_downtime_notes, ' ') "notes" , ABAIXO UMA CUSTOMIZACAO PARA NEOPAC-CH
		case when idequipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3) 
		then concat('(Manual Stop)_',coalesce(ee.txt_downtime_notes, ' ')) else coalesce(ee.txt_downtime_notes, ' ') end as "notes",
		case 
			when ts_end is null then 'runningStop'
			when ts_end is not null and ee.cd_category is null then 'notJustified' 
			else 'justified'
		end as colorcolumn
from equipment_events_man ee 
inner join equipments e using (id_equipment)
left join sites st using (id_site)
left join equipments pe on (e.id_parentequipment=pe.id_equipment)
where 
--status != 6
--and 
--coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time
case when idequipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3)
then true else coalesce(duration, extract(epoch from now() - ts_event))>e.stop_threshold_time end

and 
	case (select overview_events_type from equipments e where id_equipment = idEquipment)
		when 1 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
												join equipments e4 on (e3.id_parentequipment= e4.id_equipment)
											where e2.tp_equipment = 1 and e4.id_equipment = idEquipment
											)
		when 2 then e.id_equipment = any (
											select e2.id_equipment  from equipments e2 
												join equipments e3 on (e2.id_parentequipment= e3.id_equipment)
											where e2.tp_equipment = 2 and e3.id_equipment = idEquipment
											)
		else e.id_equipment = idEquipment
	end
and 
	case 
		when (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) is not null
		then (select overview_events_filter_by_idle from equipments e where id_equipment = idEquipment) = ee.idle 
		else true
	end
	
	) DAT	
order by ts_event desc 
limit 5;

$$;


--
-- Name: h_overview_i_job_info; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_overview_i_job_info (
    id_enterprise integer,
    id_equipment integer,
    cd_equipment character varying,
    nm_client character varying,
    id_order character varying,
    average_speed double precision,
    order_size bigint,
    collected_prod double precision,
    job_production_percentage double precision,
    production_remaining double precision,
    remaining_time character varying
);


--
-- Name: h_piot_overview_i_get_job_info(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_overview_i_get_job_info(idequipment integer) RETURNS SETOF public.h_overview_i_job_info
    LANGUAGE sql STABLE
    AS $$
select 
	id_enterprise::int4, 
	idequipment::int4 as id_equipment,
	(select cd_equipment from equipments where id_equipment = idequipment)::varchar as cd_equipment,
	(select nm_client from clients where id_client =(select id_client from production_orders where id_equipment = idequipment and status = 2))::varchar as nm_client,
	id_order::varchar,
	(select speed from production_orders_runtime where id_production_order in (select id_production_order from production_orders where id_equipment = idequipment and status = 2) order by runtime_timerange desc limit 1)::float8  as average_speed,
	production_ordered::int8 as order_size,
	net_production::float8 as collected_prod,
	(net_production/nullif(production_ordered,0))::float8 as job_production_percentage,
	(production_ordered - net_production)::float8 as production_remaining,
	to_char((((production_ordered - net_production)/nullif((select speed from production_orders_runtime where id_production_order in (select id_production_order from production_orders where id_equipment = idequipment and status = 2)order by runtime_timerange desc limit 1),0))*60)::int * interval '1 second', 'HH24:MI:SS')::varchar as remaining_time
from production_orders 
where id_equipment = idequipment
and status = 2
$$;


--
-- Name: h_overview_i_production_chart; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_overview_i_production_chart (
    id_enterprise integer,
    id_equipment integer,
    "time" text,
    times timestamp without time zone,
    rn bigint,
    cd_equipment character varying,
    production double precision,
    scrap double precision
);


--
-- Name: h_piot_overview_i_production_chart(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_overview_i_production_chart(idequipment integer) RETURNS SETOF public.h_overview_i_production_chart
    LANGUAGE sql STABLE
    AS $$
select 
        vaevh.id_enterprise,
        id_equipment,
        to_char(ts_value at time zone s.timezone, 'HH24 h') as "time",
        ts_value at time zone s.timezone as times,
        row_number() over (order by ts_value desc) as rn,
        e.cd_equipment,
        sum(coalesce(net_production_incr, 0)) as "production",
        (case when sum(coalesce(scrap_incr, 0))>0 then sum(coalesce(scrap_incr, 0)) else 0 end) as "scrap" 
from ca_agg_equipment_values_1hour vaevh
left join equipments e using (id_equipment, id_site)
left join sites s using (id_site)
where ts_value >= now() - '12h'::interval
and vaevh.tp_equipment = 3
and id_equipment = idEquipment
group by vaevh.id_enterprise , id_equipment, vaevh.ts_value, e.cd_equipment, s.timezone 
order by id_equipment , ts_value desc;
$$;


--
-- Name: h_piot_overview_production_chart(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_overview_production_chart(idequipment integer) RETURNS SETOF public.h_overview_i_production_chart
    LANGUAGE sql STABLE
    AS $$


select 
        e.id_enterprise,
        id_equipment,
        to_char(ts_value at time zone s.timezone, 'HH24 h') as "time",
        ts_value at time zone s.timezone as times,
        row_number() over (order by ts_value desc) as rn,
        e.cd_equipment,
        sum(coalesce(net, 0))::float8 as "production",
        (case when sum(coalesce(scrap, 0))>0 then sum(coalesce(scrap, 0)) else 0 end)::float8 as "scrap" 
from equipment_oee_hourly vaevh
left join equipments e using (id_equipment)
left join sites s using (id_site)
where ts_value >= now() - '12h'::interval and ts_value < now()
and e.tp_equipment = 3
and id_equipment = idequipment
group by e.id_enterprise , id_equipment, vaevh.ts_value, e.cd_equipment, s.timezone 
order by id_equipment , ts_value desc;


$$;


--
-- Name: h_overview_i_production_chart_v6; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_overview_i_production_chart_v6 (
    id_enterprise integer,
    id_equipment integer,
    "time" text,
    times timestamp without time zone,
    rn bigint,
    cd_equipment character varying,
    production double precision,
    scrap double precision
);


--
-- Name: h_piot_overview_production_chart_v6(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_overview_production_chart_v6(idequipment integer) RETURNS SETOF public.h_overview_i_production_chart_v6
    LANGUAGE sql STABLE
    AS $$

select 
        e.id_enterprise,
        id_equipment,
        to_char(ts_value at time zone s.timezone, 'HH24 h') as "time",
        ts_value at time zone s.timezone as times,
        row_number() over (order by ts_value desc) as rn,
        e.cd_equipment,
        sum(coalesce(net, 0))::float8 as "production",
        (case when sum(coalesce(scrap, 0))>0 then sum(coalesce(scrap, 0)) else 0 end)::float8 as "scrap" 
from equipment_oee_hourly vaevh
left join equipments e using (id_equipment)
left join sites s using (id_site)
where ts_value >= now() - '24h'::interval and ts_value < now()
and e.tp_equipment = 3
and id_equipment = idequipment
group by e.id_enterprise , id_equipment, vaevh.ts_value, e.cd_equipment, s.timezone 
order by id_equipment , ts_value desc;

$$;


--
-- Name: h_piot_production_flow_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_flow_table (
    id_enterprise integer,
    total_scrap real,
    nm_equipment character varying,
    flexible_position boolean,
    production_flow jsonb[]
);


--
-- Name: h_piot_production_flow(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_flow(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_piot_production_flow_table
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_id_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_id_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := 	(select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end
						 );
	min_ts_prod timestamptz := (select min(ts_value) from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ) 
								);
	max_ts_prod timestamptz := (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_oee_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts )
								);
begin 
	
	return query
	
	select 
		id_enterprise,
		total_scrap,
		nm_equipment,
		flexible_position,
		array_agg(jsonb_build_object(
			'nm_machine',nm_machine,
			'net',net,
			'gross',gross,
			'scrap', scrap,
			'stopped_time', stopped_time 
		) order by ppe_position, pe_position, machine_position) production_flow
	from 
	(
			select
				ers.id_enterprise,
				ers.id_equipment,
				ers.nm_machine,
				coalesce(ppe.nm_equipment, pe.nm_equipment) as nm_equipment,
				coalesce(ppe.id_parentequipment, pe.id_parentequipment) as id_parentequipment,
				coalesce(ppe.flexible_position, pe.flexible_position) as flexible_position,
				machine_position,
				ppe.position as ppe_position,
				pe.position as pe_position,
				ers.net,
				ers.gross,
				ers.scrap,
				ers.stopped_time,
				sum(scrap) over (partition by coalesce(ppe.nm_equipment, pe.nm_equipment)) as total_scrap
			from 
				(
					select
						e.id_enterprise,
						ers.id_equipment,
						e.nm_equipment as nm_machine,
						e.id_parentequipment,
						e."position" as machine_position,
						sum(net) net,
						sum(gross) gross,
						sum(scrap) scrap,
						sum(stopped_time) stopped_time
					from 
						equipment_oee_shift ers
						join equipments e using (id_equipment)
						join shifts s using (id_shift)
						left join teams t using (id_team)
					where
						ts_value >= min_ts_prod
						and ts_value <= max_ts_prod
						and e.id_enterprise = in_id_enterprise
						and ers.id_shift = any( ids_shifts )
						and (case when ids_teams is not null then t.id_team = any(ids_teams) else true end )
						and tp_equipment = 1		
					group by e.id_enterprise, ers.id_equipment, e.nm_equipment, e.position, e.id_parentequipment
				) ers
				join equipments pe on (ers.id_parentequipment=pe.id_equipment)
				left join equipments ppe on (pe.id_parentequipment=ppe.id_equipment)
			where coalesce (ppe.id_equipment, pe.id_equipment) = any( ids_equips )
			group by 
				ers.id_enterprise, ers.id_equipment, ers.nm_machine,
				coalesce(ppe.nm_equipment, pe.nm_equipment),
				coalesce(ppe.id_parentequipment, pe.id_parentequipment),
				coalesce(ppe.flexible_position, pe.flexible_position),
				machine_position, ppe.position, pe.position, ers.net, ers.gross, ers.scrap, ers.stopped_time
		)s1
	group by id_enterprise, total_scrap, id_parentequipment, nm_equipment, flexible_position
	order by nm_equipment;


end
$$;


--
-- Name: h_piot_production_orders_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_orders_table (
    id_enterprise integer,
    status integer,
    id_production_order integer,
    id_order integer,
    nm_client character varying,
    nm_product character varying,
    production_ordered bigint,
    gross_production double precision,
    net_production double precision,
    nm_equipment character varying,
    id_area integer,
    id_site integer,
    ts_start timestamp with time zone,
    ts_end timestamp with time zone,
    id_equipment integer,
    id_production_order_runtime bigint
);


--
-- Name: h_piot_production_orders_runtimes(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_orders_runtimes(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_production_orders_table
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
begin
	return query	
	
	
SELECT 
	po2.id_enterprise,
    case when upper(runtime_timerange) is null then 2
    	else 3
    end status,
    po.id_production_order,
    po2.id_order,
    c.nm_client,
    p.nm_product,
    po2.production_ordered,
    COALESCE(po.gross_production, 0::double precision) AS gross_production,
    COALESCE(po.net_production, 0::double precision) AS net_production,
    e.nm_equipment,
    e.id_area,
    e.id_site,
    lower(runtime_timerange) as ts_start,
    upper(runtime_timerange) as ts_end,
    po2.id_equipment,
    id_production_order_runtime 
   FROM production_orders_runtime po
   		join production_orders po2 using (id_production_order, id_equipment)
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN products p USING (id_product)
     LEFT JOIN equipments e USING (id_equipment)
  WHERE 
 	e.id_site = ANY(ids_sites)
 	and e.id_area = ANY(ids_areas)
 	and id_equipment = ANY(ids_equips)
 	and ts_start >= _tsstart and ts_start < _tsend;
-- 	and ids_shifts = ANY(ids_shifts);
 
 
  return;
end
$$;


--
-- Name: h_piot_production_orders_with_runtimes_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_orders_with_runtimes_table (
    id_enterprise integer,
    status integer,
    id_production_order bigint,
    id_order integer,
    nm_client character varying,
    nm_product character varying,
    production_ordered bigint,
    gross_production double precision,
    net_production double precision,
    nm_equipment character varying,
    id_area integer,
    id_site integer,
    ts_start timestamp with time zone,
    ts_end timestamp with time zone,
    id_equipment integer,
    runtimes json
);


--
-- Name: h_piot_production_orders_with_runtimes(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_orders_with_runtimes(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_production_orders_with_runtimes_table
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
begin
	return query	
--CREATE TABLE public.h_piot_production_orders_with_runtimes_table
--AS 
SELECT po.id_enterprise,
    po.status,
    po.id_production_order,
    po.id_order,
    c.nm_client,
    p.nm_product,
    po.production_ordered,
    COALESCE(NULLIF(po.gross_production, 0::double precision), po.production_final::double precision) AS gross_production,
    COALESCE(NULLIF(po.net_production, 0::double precision), po.production_final::double precision) AS net_production,
--    po.net_production,
    e.nm_equipment,
    e.id_area,
    e.id_site,
    po.ts_start,
--    COALESCE(po.ts_end, now()) AS ts_end,
    po.ts_end,
    po.id_equipment,
    (
    select 
    		json_agg(runtimes) runtimes
    from(
	    select     	
				json_build_object(
					'ts_start', LOWER(runtime_timerange),
					'ts_end', UPPER(runtime_timerange),
					'duration',
						case when UPPER(runtime_timerange) is not null
							then (UPPER(runtime_timerange)-LOWER(runtime_timerange))
							else NULL
						end,
					'net', net_production,
					'gross', gross_production,
					'scrap', coalesce(gross_production, 0) - coalesce(net_production, 0),
					'scrap_percentage',
						case when coalesce(gross_production, 0) = 0
							then 1
							else (coalesce(gross_production, 0) - coalesce(net_production, 0))/gross_production
						end,
					'nm_equipment', (select nm_equipment from equipments where id_equipment = por.id_equipment)
				) runtimes
	    	from production_orders_runtime por
	    	where por.id_production_order=po.id_production_order 
    	)a
    ) as runtimes
   FROM production_orders po
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN products p USING (id_product)
     LEFT JOIN equipments e USING (id_equipment)
  WHERE po.status <> 1
 	and e.id_site = ANY(ids_sites)
 	and e.id_area = ANY(ids_areas)
 	and id_equipment = ANY(ids_equips)
 	and ts_start >= _tsstart and ts_start < _tsend;
 	-- 	and ids_shifts = ANY(ids_shifts);
  return;
end
$$;


--
-- Name: h_piot_production_orders_with_runtimes_table_4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_orders_with_runtimes_table_4 (
    id_enterprise integer,
    status integer,
    id_production_order bigint,
    id_order integer,
    nm_client character varying,
    nm_product character varying,
    txt_product character varying,
    production_ordered bigint,
    gross_production double precision,
    net_production double precision,
    nm_equipment character varying,
    id_area integer,
    id_site integer,
    ts_start timestamp with time zone,
    production_final bigint,
    ts_end timestamp with time zone,
    id_equipment integer,
    runtimes json
);


--
-- Name: h_piot_production_orders_with_runtimes4(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_orders_with_runtimes4(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_production_orders_with_runtimes_table_4
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_sites::int[]) = 0 then true
						 		else id_site = any( in_ids_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_areas::int[]) = 0 then true
						 		else id_area = any( in_ids_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_ids_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_ids_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_ids_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_ids_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_ids_shifts, ',')) = 0 then true
										when left(in_ids_shifts, 1) != '{' then cd_shift = any( string_to_array(in_ids_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_ids_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_ids_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
begin
	return query	
	--CREATE TABLE public.h_piot_production_orders_with_runtimes_table2
	--AS 
SELECT po.id_enterprise,
    po.status,
    po.id_production_order,
    po.id_order,
    c.nm_client,
    p.nm_product,
    p.txt_product,
    po.production_ordered,
--    COALESCE(NULLIF(po.gross_production, 0::double precision), po.production_final::double precision) AS gross_production,
--    COALESCE(NULLIF(po.net_production, 0::double precision), po.production_final::double precision) AS net_production,
    COALESCE(po.gross_production, 0::double precision) AS gross_production,
    COALESCE(po.net_production, 0::double precision) AS net_production,
--    po.net_production,
    e.nm_equipment,
    e.id_area,
    e.id_site,
    po.ts_start,
    po.production_final,
--    COALESCE(po.ts_end, now()) AS ts_end,
    po.ts_end,
    po.id_equipment,
    (
    select 
    		json_agg(runtimes) runtimes
    from(
	    select     	
				json_build_object(
					'ts_start', LOWER(runtime_timerange),
					'ts_end', UPPER(runtime_timerange),
					'duration',
						case when UPPER(runtime_timerange) is not null
							then (UPPER(runtime_timerange)-LOWER(runtime_timerange))
							else NULL
						end,
					'net', net_production,
					'gross', gross_production,
					'production_final', production_final,
					'scrap', coalesce(gross_production, 0) - coalesce(net_production, 0),
					'scrap_percentage',
						case when coalesce(gross_production, 0) = 0
							then 1
							else (coalesce(gross_production, 0) - coalesce(net_production, 0))/gross_production
						end,
					'nm_equipment', (select nm_equipment from equipments where id_equipment = por.id_equipment),
					'id_production_order', por.id_production_order,
					'id_production_order_runtime', id_production_order_runtime
				) runtimes
	    	from production_orders_runtime por
	    	where por.id_production_order=po.id_production_order 
    	)a
    ) as runtimes
   FROM production_orders po
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN products p USING (id_product)
     LEFT JOIN equipments e USING (id_equipment)
  WHERE po.status <> 1
 	and
 	 e.id_site = ANY(ids_sites)
 	and e.id_area = ANY(ids_areas)
 	and id_equipment = ANY(ids_equips)
 	and (
 		tstzrange (_tsstart, _tsend, '[)') && tstzrange (ts_start, ts_end, '[)')
 		--or po.status = 1
 	);
-- 	and ids_shifts = ANY(ids_shifts);
 
 
  return;
end
$$;


--
-- Name: production_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.production_targets (
    id_site integer DEFAULT 0 NOT NULL,
    vl_day integer DEFAULT 0,
    vl_week integer DEFAULT 0,
    vl_month integer DEFAULT 0,
    id_equipment integer DEFAULT 0 NOT NULL,
    id_enterprise integer,
    id_area integer,
    vl_shift integer DEFAULT 0,
    vl_hour integer DEFAULT 0
);

ALTER TABLE ONLY public.production_targets FORCE ROW LEVEL SECURITY;


--
-- Name: h_piot_set_production_target(integer, integer, boolean, integer, integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_set_production_target(in_id_enterprise integer, in_id_equipment integer, proportional boolean DEFAULT true, in_target_day integer DEFAULT NULL::integer, in_target_week integer DEFAULT NULL::integer, in_target_month integer DEFAULT NULL::integer, in_target_shift integer DEFAULT NULL::integer, in_target_hour integer DEFAULT NULL::integer) RETURNS SETOF public.production_targets
    LANGUAGE plpgsql
    AS $$
declare

begin 

IF proportional THEN 
	return query 

	with shifts_h as (select * from piot_get_shift_hour_list_by_equipment(in_id_enterprise, in_id_equipment)),
	days_week as (select  count(*) from (select distinct day_week from shifts_h) aa),
	hours_day as (select sum(shift_size)/3600 as hours_day from shifts_h group by day_number order by day_number limit 1),
	shift_per_day as (select  count(*) from (select distinct id_shift from shifts_h) aa)
	update production_targets pt
	set
		vl_day = target_day,
		vl_week = target_week,
		vl_month = target_month,
		vl_shift = target_shift,
		vl_hour = target_hour
	from(
		select
			in_target_day as target_day,
			(in_target_day/nullif((select * from hours_day), 0))::int4 as target_hour,
			(in_target_day*(select * from days_week))::int4 as target_week,
			(in_target_day*30)::int4 as target_month,
			(in_target_day/nullif((select * from shift_per_day),0))::int4 as target_shift
	) subdata
	where id_equipment = in_id_equipment
	returning id_site, vl_day, vl_week, vl_month, id_equipment, id_enterprise, id_area, vl_shift, vl_hour;
		
else
	
return query 

	update production_targets pt
	set
		vl_day = in_target_day,
		vl_week = in_target_week,
		vl_month = in_target_month,
		vl_shift = in_target_shift,
		vl_hour = in_target_hour
	where id_equipment = in_id_equipment
	returning *;
	
END IF;

end
$$;


--
-- Name: scrap_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scrap_targets (
    id_site integer DEFAULT 0 NOT NULL,
    vl_day double precision DEFAULT 0,
    vl_week double precision DEFAULT 0,
    vl_month double precision DEFAULT 0,
    id_equipment integer DEFAULT 0 NOT NULL,
    id_enterprise integer,
    id_area integer,
    vl_shift double precision DEFAULT 0,
    vl_hour double precision DEFAULT 0
);


--
-- Name: h_piot_set_scrap_target(integer, integer, boolean, integer, integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_set_scrap_target(in_id_enterprise integer, in_id_equipment integer, proportional boolean DEFAULT true, in_target_day integer DEFAULT NULL::integer, in_target_week integer DEFAULT NULL::integer, in_target_month integer DEFAULT NULL::integer, in_target_shift integer DEFAULT NULL::integer, in_target_hour integer DEFAULT NULL::integer) RETURNS SETOF public.scrap_targets
    LANGUAGE plpgsql
    AS $$
declare

begin 

IF proportional THEN 
	return query 

	with shifts_h as (select * from piot_get_shift_hour_list_by_equipment(in_id_enterprise, in_id_equipment)),
	days_week as (select  count(*) from (select distinct day_week from shifts_h) aa),
	hours_day as (select sum(shift_size)/3600 as hours_day from shifts_h group by day_number order by day_number limit 1),
	shift_per_day as (select  count(*) from (select distinct id_shift from shifts_h) aa)
	INSERT INTO public.scrap_targets
	(id_site, vl_day, vl_week, vl_month, id_equipment, id_enterprise, id_area, vl_shift, vl_hour)
		select
			e.id_site,
			in_target_day as target_day,
			(in_target_day*(select * from days_week))::int4 as target_week,
			(in_target_day*30)::int4 as target_month,
			e.id_equipment,
			e.id_enterprise,
			e.id_area,
			(in_target_day/nullif((select * from shift_per_day),0))::int4 as target_shift,
			(in_target_day/nullif((select * from hours_day), 0))::int4 as target_hour
		from equipments e
		where id_equipment = in_id_equipment
	on conflict (id_equipment)
	DO UPDATE set
	vl_day = EXCLUDED.vl_day,
	vl_week = EXCLUDED.vl_week,
	vl_month = EXCLUDED.vl_month,
	vl_shift = EXCLUDED.vl_shift,
	vl_hour = EXCLUDED.vl_hour
	returning id_site, vl_day, vl_week, vl_month, id_equipment, id_enterprise, id_area, vl_shift, vl_hour;
		
else
	
return query 

INSERT INTO public.scrap_targets
	(id_site, vl_day, vl_week, vl_month, id_equipment, id_enterprise, id_area, vl_shift, vl_hour)
select
	e.id_site,
	in_target_day vl_day,
	in_target_week vl_week,
	in_target_month vl_month,
	in_id_equipment id_equipment,
	e.id_enterprise,
	e.id_area,
	in_target_shift vl_shift,
	in_target_hour vl_hour
from
	equipments e
where id_equipment = in_id_equipment
on conflict (id_equipment)
DO UPDATE set
	vl_day = EXCLUDED.vl_day,
	vl_week = EXCLUDED.vl_week,
	vl_month = EXCLUDED.vl_month,
	vl_shift = EXCLUDED.vl_shift,
	vl_hour = EXCLUDED.vl_hour
returning *;
	
END IF;

end
$$;


--
-- Name: h_single_period_equipment_chart_table_3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_single_period_equipment_chart_table_3 (
    ts_value_production timestamp with time zone,
    id_enterprise integer,
    net double precision,
    gross double precision,
    scrap double precision,
    target bigint,
    array_agg jsonb[]
);


--
-- Name: h_piot_single_period_with_teams_3(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_single_period_with_teams_3(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text) RETURNS SETOF public.h_single_period_equipment_chart_table_3
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_id_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_id_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case UPPER(time_grain)
									when 'HOUR' then
										(select min(ts_value) from ca_agg_equipment_values_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value) from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
			--								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			--								and ev.id_enterprise = in_id_enterprise
			--								and ev.id_area = any( ids_areas)
			--								and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) )
								end
							);
	max_ts_prod timestamptz := (
						select case UPPER(time_grain)
									when 'HOUR' then
										(select max(ts_value) from ca_agg_equipment_values_1hour ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
										and ev.id_enterprise = in_id_enterprise
										and ev.id_area = any( ids_areas)
										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ))
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_oee_shift ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
--								and ev.id_enterprise = in_id_enterprise
--								and ev.id_area = any( ids_areas)
--								and ev.id_site = any( ids_sites )
								and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ))
							end
							);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return QUERY 
	
	select
		case when date_trunc(time_grain, now()) = ts_value then now() else ts_value end ts_value_production,
		id_enterprise,
		sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
		array_agg(obj order by coalesce (shift_position, team_position) )
		from (
			select 
				ts_value::timestamptz,
				ers.id_enterprise,
				case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
				case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
				sum(coalesce(net_production_incr, 0)) net, sum(coalesce(gross_production_incr, 0)) gross, sum(coalesce(scrap_incr, 0)) scrap, avg(coalesce(pt.vl_hour, 0)) target,
				jsonb_build_object(							
					'id_shift', case group_by_element when 'SHIFTS' then id_shift END,
					'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
					'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
					'id_team', case group_by_element when 'TEAMS' then t.id_team END,
					'net', sum(coalesce(net_production_incr, 0)),
					'gross', sum(coalesce(gross_production_incr, 0)),
					'scrap', sum(coalesce(scrap_incr, 0)),
					'scrap_percentage', sum(coalesce(scrap_incr, 0)) / nullif( sum(coalesce(gross_production_incr, 0)) , 0),
					'scrap_target', avg(st.vl_shift),
					'target', avg(coalesce(pt.vl_hour, 0))
				) obj
			from 
				ca_agg_equipment_values_1hour ers
				join production_targets pt using (id_equipment)
				left join shifts s using (id_shift)
				left join teams t using (id_team)
				left join scrap_targets st on (ers.id_equipment = st.id_equipment)
			where
				ts_value >= min_ts_prod
				and ts_value <= max_ts_prod
				and ers.id_enterprise = in_id_enterprise
				and ers.id_area = any( ids_areas)
				and ers.id_site = any( ids_sites )
				and ers.id_equipment =  any( ids_equips )
				and ers.id_shift = any( ids_shifts )
			group by 
				ers.id_enterprise, ts_value,
				case group_by_element when 'SHIFTS' then ers.id_shift else null END,
				case group_by_element when 'SHIFTS' then s.cd_shift else null END,
				case group_by_element when 'SHIFTS' then s.sequence_position else null END,
				case group_by_element when 'TEAMS' then t.sequence_position else null end,
				t.id_team, t.cd_team
			) aa 
		group by ts_value, id_enterprise order by ts_value;

ELSE return QUERY 


select
	case when date_trunc(time_grain, now()) = date_trunc(time_grain, ts_value_production) then now() else ts_value_production end ts_value_production,
	id_enterprise,
	sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
	array_agg(obj order by coalesce (shift_position, team_position))
from (
	select 
		date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
		e.id_enterprise,
		case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
		case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
		sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target,
		jsonb_build_object(
			'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift END,
			'cd_shift', case group_by_element when 'SHIFTS' then ers.cd_shift END,
			'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
			'id_team', case group_by_element when 'TEAMS' then t.id_team END,
			'net', sum(coalesce(net, 0)),
			'gross', sum(coalesce(gross, 0)),
			'scrap', sum(coalesce(scrap, 0)),
			'scrap_percentage', sum(coalesce(scrap, 0)) / nullif( sum(coalesce(gross, 0)) , 0),
			'scrap_target', avg(st.vl_shift),
			'target', sum(coalesce(target, 0))
		) obj
	from 
		equipment_oee_shift ers
		join equipments e using (id_equipment) 
		join shifts s using (id_shift)
		left join teams t using (id_team)
		left join scrap_targets st on (ers.id_equipment = st.id_equipment)
	where
		ts_value >= min_ts_prod
		and ts_value_production <= max_ts_prod
		and e.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and e.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
		and (ers.id_team is null or ers.id_team = any(ids_teams) ) 
	group by e.id_enterprise, date_trunc(time_grain, ts_value_production),
		case group_by_element when 'SHIFTS' then ers.id_shift else null END,
		case group_by_element when 'SHIFTS' then ers.cd_shift else null END,
		case group_by_element when 'SHIFTS' then s.sequence_position else null END,
		case group_by_element when 'TEAMS' then t.id_team else null END,
		case group_by_element when 'TEAMS' then t.cd_team else null end,
		case group_by_element when 'TEAMS' then t.sequence_position else null END
		) aa 
group by ts_value_production, id_enterprise order by ts_value_production;

END IF;

end
$$;


--
-- Name: h_single_period_equipment_chart_table_4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_single_period_equipment_chart_table_4 (
    ts_value_production timestamp with time zone,
    id_enterprise integer,
    net double precision,
    gross double precision,
    scrap double precision,
    target bigint,
    scrap_percentage double precision,
    scrap_targets double precision,
    array_agg jsonb[]
);


--
-- Name: h_piot_single_period_with_teams_4(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_single_period_with_teams_4(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text) RETURNS SETOF public.h_single_period_equipment_chart_table_4
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_id_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_id_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case UPPER(time_grain)
									when 'HOUR' then
										(select min(ts_value) from ca_agg_equipment_values_1hour ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
											and ev.id_enterprise = in_id_enterprise
											and ev.id_area = any( ids_areas)
											and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
											and ev.id_shift = any( ids_shifts )
										)
									else (select min(ts_value) from equipment_oee_shift ev
											where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
											and ev.ts_value_production < date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
			--								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			--								and ev.id_enterprise = in_id_enterprise
			--								and ev.id_area = any( ids_areas)
			--								and ev.id_site = any( ids_sites )
											and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) )
								end
							);
	max_ts_prod timestamptz := (
						select case UPPER(time_grain)
									when 'HOUR' then
										(select max(ts_value) from ca_agg_equipment_values_1hour ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
										and ev.id_enterprise = in_id_enterprise
										and ev.id_area = any( ids_areas)
										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ))
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_oee_shift ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
--								and ev.id_enterprise = in_id_enterprise
--								and ev.id_area = any( ids_areas)
--								and ev.id_site = any( ids_sites )
								and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ))
							end
							);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return QUERY 
	
	select
		case when date_trunc(time_grain, now()) = ts_value then now() else ts_value end ts_value_production,
		id_enterprise,
		sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
		case scrap_calc_type
			when 2 then (sum(coalesce(scrap, 0)::float8) / nullif( sum(coalesce(net, 0))::float8 , 0))::float8 *100 
			else (sum(coalesce(scrap, 0)::float8) / nullif( sum(coalesce(gross, 0))::float8 , 0))::float8 *100 
		end scrap_percentage,
		avg(scrap_target)::float8  *100 scrap_target,
		array_agg(obj order by coalesce (shift_position, team_position) )
	from (
		select 
			ts_value::timestamptz,
			ers.id_enterprise,
			scrap_calc_type,
			case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
			case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
			sum(coalesce(net_production_incr, 0)) net, sum(coalesce(gross_production_incr, 0)) gross, sum(coalesce(scrap_incr, 0)) scrap, avg(st.vl_hour)::float8 scrap_target,
			avg(coalesce(pt.vl_hour, 0)) target, jsonb_build_object(							
				'id_shift', case group_by_element when 'SHIFTS' then id_shift END,
				'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
				'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
				'id_team', case group_by_element when 'TEAMS' then t.id_team END,
				'net', sum(coalesce(net_production_incr, 0)),
				'gross', sum(coalesce(gross_production_incr, 0)),
				'scrap', sum(coalesce(scrap_incr, 0)),
				'scrap_percentage', 
					case scrap_calc_type
						when 2 then (sum(coalesce(scrap_incr, 0)) / nullif( sum(coalesce(net_production_incr, 0)) , 0)) * 100
						else (sum(coalesce(scrap_incr, 0)) / nullif( sum(coalesce(gross_production_incr, 0)) , 0)) * 100
					end,
				'scrap_target', avg(st.vl_hour)*100,
				'target', avg(coalesce(pt.vl_hour, 0))
			) obj
		from 
			ca_agg_equipment_values_1hour ers
			join production_targets pt using (id_enterprise, id_equipment)
			join enterprises e using (id_enterprise)
			left join shifts s using (id_shift)
			left join teams t using (id_team)
			left join scrap_targets st on (ers.id_equipment = st.id_equipment)
		where
			ts_value >= min_ts_prod
			and ts_value <= max_ts_prod
			and ers.id_enterprise = in_id_enterprise
			and ers.id_area = any( ids_areas)
			and ers.id_site = any( ids_sites )
			and ers.id_equipment =  any( ids_equips )
			and ers.id_shift = any( ids_shifts )
		group by 
			ers.id_enterprise, ts_value, scrap_calc_type,
			case group_by_element when 'SHIFTS' then ers.id_shift else null END,
			case group_by_element when 'SHIFTS' then s.cd_shift else null END,
			case group_by_element when 'SHIFTS' then s.sequence_position else null END,
			case group_by_element when 'TEAMS' then t.sequence_position else null end,
			t.id_team, t.cd_team
	) aa 
	group by ts_value, id_enterprise, scrap_calc_type order by ts_value;

ELSE return QUERY 


	select
		case when date_trunc(time_grain, now()) = date_trunc(time_grain, ts_value_production) then now() else ts_value_production end ts_value_production,
		id_enterprise,
		sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
		case scrap_calc_type
			when 2 then sum(coalesce(scrap, 0)::float8) / nullif( sum(coalesce(net, 0))::float8 , 0)::float8 *100
			else sum(coalesce(scrap, 0)::float8) / nullif( sum(coalesce(gross, 0))::float8 , 0)::float8 *100
		end scrap_percentage,
		avg(scrap_target)::float8 *100 scrap_target,
		array_agg(obj order by coalesce (shift_position, team_position))
	from (
		select 
			date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
			e.id_enterprise,
			scrap_calc_type,
			case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
			case group_by_element when 'TEAMS' then t.sequence_position end as team_position,
			sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target, avg(st.vl_shift)::float8 scrap_target,
			jsonb_build_object(
				'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift END,
				'cd_shift', case group_by_element when 'SHIFTS' then ers.cd_shift END,
				'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
				'id_team', case group_by_element when 'TEAMS' then t.id_team END,
				'net', sum(coalesce(net, 0)),
				'gross', sum(coalesce(gross, 0)),
				'scrap', sum(coalesce(scrap, 0)),
				'scrap_percentage',
					case scrap_calc_type
						when 2 then (sum(coalesce(scrap, 0)) / nullif( sum(coalesce(net, 0)) , 0))*100
						else (sum(coalesce(scrap, 0)) / nullif( sum(coalesce(gross, 0)) , 0))*100
					end,
				'scrap_target', avg(st.vl_shift)*100,
				'target', sum(coalesce(target, 0))
		) obj
		from 
			equipment_oee_shift ers
			join equipments e using (id_equipment)
			join enterprises et using (id_enterprise)
			join shifts s using (id_shift)
			left join teams t using (id_team)
			left join scrap_targets st on (ers.id_equipment = st.id_equipment)
		where
			ts_value >= min_ts_prod
			and ts_value <= max_ts_prod
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and e.id_equipment = any( ids_equips )
			and ers.id_shift = any( ids_shifts )
			and (ers.id_team is null or ers.id_team = any(ids_teams) ) 
		group by e.id_enterprise, scrap_calc_type, date_trunc(time_grain, ts_value_production),
			case group_by_element when 'SHIFTS' then ers.id_shift else null END,
			case group_by_element when 'SHIFTS' then ers.cd_shift else null END,
			case group_by_element when 'SHIFTS' then s.sequence_position else null END,
			case group_by_element when 'TEAMS' then t.id_team else null END,
			case group_by_element when 'TEAMS' then t.cd_team else null end,
			case group_by_element when 'TEAMS' then t.sequence_position else null END
	) aa 
	group by ts_value_production, id_enterprise, scrap_calc_type order by ts_value_production;

END IF;

end
$$;


--
-- Name: h_total_production_chart_from_runtime; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_total_production_chart_from_runtime (
    ts character varying,
    net_production_incr bigint,
    net_production_acc bigint,
    gross_production_acc bigint,
    scrap bigint,
    scrap_acc bigint,
    trendline1 bigint,
    target bigint,
    togoal double precision,
    id_enterprise integer,
    shift_net_prod json,
    target_period bigint
);


--
-- Name: h_piot_total_production_teams_2(integer, text, text, text, text, text, timestamp without time zone, timestamp without time zone, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_teams_2(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, partitionby text, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_from_runtime
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := (select array_agg(id_site) 
						 from sites s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_sites::int[]) = 0 then true
						 		else id_site = any( in_id_sites::int[])
						 	 end);
	ids_areas int[] := (select array_agg(id_area) 
						 from areas s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_areas::int[]) = 0 then true
						 		else id_area = any( in_id_areas::int[])
						 	 end);
	ids_equips int[] := (select array_agg(id_equipment) 
						 from equipments s
						 where s.id_enterprise=in_id_enterprise 
						 and s.tp_equipment=3
						 and case
						 		when cardinality(in_id_equipments::int[]) = 0 then true
						 		else id_equipment = any( in_id_equipments::int[])
						 	 end);
--	ids_shifts int[] := (select array_agg(id_shift) 
--						 from shifts s
--						 where s.id_enterprise=in_id_enterprise 
--						 and case
--						 		when cardinality(in_id_shifts::int[]) = 0 then true
--						 		else id_shift = any( in_id_shifts::int[])
--						 	 end);
	ids_shifts int[] := (
							select array_agg(id_shift) from shifts s
							where s.id_enterprise = in_id_enterprise
								and
									case
										when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
										when left(in_id_shifts, 1) != '{' then cd_shift = any( string_to_array(in_id_shifts, ',')::varchar[])
										else
											case 
												when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
												then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
												else true
											end
									end
						);
	ids_teams int[] := (select array_agg(id_team) 
						 from teams s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_teams::int[]) = 0 then true
						 		else id_team = any( in_id_teams::int[])
						 	 end);
	min_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then min(ts_value) else min(ts_value_production) end from equipment_oee_hourly ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								and e.id_area = any( ids_areas )
								and e.id_site = any( ids_sites )
								);
	max_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then max(ts_value) else max(ts_value_production) end from equipment_oee_hourly ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								and e.id_area = any( ids_areas )
								and e.id_site = any( ids_sites )
								);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return query 
	
	with query_data as (
		select
			e.id_enterprise,
			case UPPER(partitionBy) when 'SHIFTS' then cd_shift when 'TEAMS' then cd_team else null end	shift_or_team,
			scrap, net, gross, 
			target,
			ts_value,
			ts_value_production
		from
			equipment_oee_hourly ev
			join equipments e using (id_equipment)
			left JOIN LATERAL piot_get_shift_hour_by_equipment_fixed(e.id_enterprise, e.id_equipment, ev.ts_value) f ON true
			left join teams t using (id_team) 
		where 
			(ev.ts_value >= min_ts_prod::timestamp		--date_trunc(time_grain::text, min_ts_prod::timestamptz) 
				and ev.ts_value <= max_ts_prod::timestamp)	--date_trunc(time_grain::text, max_ts_prod::timestamptz)
			and e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
--			and ev.id_shift = any( ids_shifts )
--			and ev.id_team = any( ids_teams )
			and (case when ids_teams is not null then ev.id_team = any( ids_teams ) else true end)
	)
	select(
		timezone('utc', ts::timestamptz)::timestamptz(0))::varchar,
		case 
			when ts <= now() 
				then coalesce(net_incr, 0)::int8
			else null
		end::int8 as net_production_incr,
		case 
			when ts <= now() 
				then coalesce(sum(net_incr) over (order by ts), 0)
			else null
		end::int8 net_production_acc,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts), 0)
		end::int8 as gross_production_acc,
		case 
			when ts <= now() 
				then coalesce(gross_incr - net_incr, 0) --coalesce(scrap_incr, 0)::int8 
			else null
		end::int8 scrap_incr,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts) - sum(net_incr) over (order by ts), 0)
		end::int8 as scrap_acc,
		case 
	 		when ts < now() then null
	 		else
				coalesce(greatest(0,
					(regr_slope((net_acc), (secs))  filter (where ts< now()::timestamptz(0)) over () * extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over()))
				  	+ max(net_acc) over())
		 		, 0)::int8
		end trendline1,
		coalesce(sum(target) over (order by ts), 0)::int8 target,
		case 
			when ts <= max(ts_value) over () then coalesce( (net_acc - sum(target) ) / nullif(net_acc, 0), 0 )
	 	end::float8 as toGoal,
		id_enterprise,
		shift_info::json as shift_net_prod,
		coalesce(sum(target), 0)::int8 target_period
	from 
	(
		select 
			id_enterprise, coalesce (d.ts_value, ts.ts) ts, max(secs) secs, max(ts_value) ts_value,
			sum(net_production_incr) as net_incr,
			sum(gross_production_incr) as gross_incr,
			sum(scrap_incr) as scrap_incr,
			sum(target) as target,
			jsonb_agg( jsonb_build_object(
				case partitionBy  when 'SHIFTS' then 'shift' when 'TEAMS' then 'team' else 'id_enterprise' end,
				case partitionBy  when 'SHIFTS' then shift_or_team when 'TEAMS' then shift_or_team else id_enterprise::varchar end,
				'scrap', scrapacc_sh, 
				'net', netacc_sh)	order by shift_or_team
			) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from (
			select 
				id_enterprise,
				shift_or_team,
				case ts_value
					when date_trunc('hour', now()) then now()::timestamptz 
					else ts_value -- + interval '1 hour'
				end ts_value,
				extract(epoch from ts_value	- min(ts_value) over ()) secs,
				coalesce(sum(target), 0) target,
				coalesce(sum(net), 0) net_production_incr,
				coalesce(sum(gross), 0) gross_production_incr,
				coalesce(sum(scrap), 0) scrap_incr,
				sum(sum(net)) over part netacc_sh,
				sum(sum(scrap)) over part scrapacc_sh,
				sum(sum(net)) over T_part netacc,
				sum(sum(gross)) over T_part grossacc,
				sum(sum(scrap)) over T_part scrapacc
			from
				query_data
			group by id_enterprise, ts_value_production, shift_or_team, ts_value
			window part as ( 
				partition by case partitionBy  when 'SHIFTS' then shift_or_team when 'TEAMS' then shift_or_team else id_enterprise::VARCHAR end				
				order by ts_value),
			T_part as (
				partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d	
		full outer join (
			select ts
			from
				generate_series(min_ts_prod::timestamptz, max_ts_prod::timestamptz, ('1 HOUR')::interval) ts(ts)
			where 
				ts >= min_ts_prod
				and  ts <> date_trunc('hour', now())
		) ts on ts.ts = d.ts_value
		group by id_enterprise, ts, d.ts_value
	) vals
	group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value, target
	order by ts;


ELSE return QUERY 
--	Por Dia, mes ...
	with query_data as (
		select
			e.id_enterprise,
			case UPPER(partitionBy) when 'SHIFTS' then cd_shift when 'TEAMS' then cd_team else null end	shift_or_team,
			sum(scrap) scrap, sum(net) net, sum(gross) gross,
			sum(target) target,
			date_trunc(time_grain::text, ts_value_production) ts_value_production
		from
			equipment_oee_shift ev
			join equipments e using (id_equipment) 
			left join teams t using (id_team) 
		where 
			(ev.ts_value_production >= date_trunc(time_grain::text, min_ts_prod::timestamp) 
				and ev.ts_value_production <= date_trunc(time_grain::text, max_ts_prod::timestamp)) 
			AND e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
			and ev.id_shift = any( ids_shifts )
--			and ev.id_team = any( ids_teams )
			and (case when ids_teams is not null then ev.id_team = any( ids_teams ) else true end)
		group by
			e.id_enterprise,
			date_trunc(time_grain::text, ts_value_production),
			case UPPER(partitionBy) when 'SHIFTS' then cd_shift when 'TEAMS' then cd_team else null end
	)
	select 
		(timezone('utc', ts)::timestamptz(0))::varchar,
		case 
			when ts <= now() 
				then coalesce(net_incr, 0)::int8
			else null
		end::int8 as net_production_incr,
		case 
			when ts <= now() 
				then coalesce(sum(net_incr) over (order by ts), 0)
			else null
		end::int8 net_production_acc,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts), 0)
		end::int8 as gross_production_acc,
		case 
			when ts <= now() 
				then coalesce(gross_incr - net_incr, 0)
			else null
		end::int8 scrap_incr,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts) - sum(net_incr) over (order by ts), 0)
		end::int8 as scrap_acc,
--		case 
--			when ts < now() then null
--			else
--			coalesce(greatest(0,
--				(
--					(max(net_acc) filter(where ts <= now()::timestamptz) over()/nullif(extract (epoch from max(ts) filter(where ts <= now()::timestamptz) over()-min(ts) over() ),0))
--					* extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over()))
--		 		  	+ max(net_acc) over())
--			 , 0)::int8 end trendline1,
		case 
			when ts < now() then null
			else
			coalesce(
				greatest(
					0,
					(
						(
							max(net_acc) filter(where ts <= now()::timestamptz) over()
							/
							nullif(extract (epoch from max(ts) filter(where ts <= now()::timestamptz) over()
							---min(ts) over()
							-min_ts_prod
							),0)
						)
						* extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over())
					)+ max(net_acc) over())
			 , 0)::int8 end trendline1,
		coalesce(sum(target) over (order by ts), 0)::int8 target,
		case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(target) ) /nullif(net_acc, 0), 0 )
		end::float8 as toGoal,
		id_enterprise,
		shift_info::json as shift_net_prod,
		coalesce(sum(target), 0)::int8 target_period
		from (
			select 
				id_enterprise,
				--coalesce ( date_trunc(time_grain, date_trunc(time_grain, d.ts_value)) , ts.ts) ts,
				case
					when date_trunc(time_grain, d.ts_value) = date_trunc(time_grain, now()) then now()
					else coalesce ( date_trunc(time_grain, d.ts_value) , ts.ts)
				end ts,
				--coalesce (d.ts_value, ts.ts) ts,
				max(secs) secs, max(ts_value) ts_value,
				sum(net_production_incr) as net_incr,
				sum(gross_production_incr) as gross_incr,
				sum(scrap_incr) as scrap_incr,
				sum(target) as target,
				jsonb_agg( jsonb_build_object(
					case partitionBy  when 'SHIFTS' then 'shift' when 'TEAMS' then 'team' else 'id_enterprise' end,
					case partitionBy  when 'SHIFTS' then shift_or_team when 'TEAMS' then shift_or_team else id_enterprise::varchar end,
					'scrap', scrapacc_sh, 
					'net', netacc_sh
				)	order by shift_or_team) shift_info,
				sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
				sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
				sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
			from (
				select 
					id_enterprise,
					shift_or_team,
					case
						date_trunc(time_grain, ts_value_production) when date_trunc(time_grain, now())::date then now()::timestamptz 
						else ts_value_production -- + interval '1 hour'
					end ts_value,
					extract(
						epoch from 
						date_trunc(time_grain, ts_value_production) 
						- min(date_trunc(time_grain, ts_value_production)) over ()
					) secs,
					coalesce(sum(target), 0) target,
					coalesce(sum(net), 0) net_production_incr,
					coalesce(sum(gross), 0) gross_production_incr,
					coalesce(sum(scrap), 0) scrap_incr,
					sum(sum(net)) over part netacc_sh,
					sum(sum(scrap)) over part scrapacc_sh,
					sum(sum(net)) over T_part netacc,
					sum(sum(gross)) over T_part grossacc,
					sum(sum(scrap)) over T_part scrapacc
				from query_data
				group by id_enterprise, shift_or_team, ts_value_production,
						date_trunc(time_grain, ts_value_production)
				window part as ( 
					partition by case partitionBy  when 'SHIFTS' then shift_or_team when 'TEAMS' then shift_or_team else id_enterprise::VARCHAR end				
					order by date_trunc(time_grain, ts_value_production) 
				), 
				T_part as (
					partition by date_trunc(time_grain, ts_value_production)
				)
			) d
			full outer join--right join
			(
				select ts
				from generate_series(
					date_trunc(time_grain, min_ts_prod::timestamp),
					date_trunc(time_grain, max_ts_prod::timestamp),
					('1'||time_grain)::interval) ts(ts)
				where ts<>date_trunc(time_grain, now())
			) ts on ts.ts = d.ts_value
			group by id_enterprise, ts, date_trunc(time_grain, d.ts_value) 
		) vals
		group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value, target
	order by ts;


END IF;
end
$$;


--
-- Name: is_all_tenant(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_all_tenant() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  SELECT public.current_tenant() = -1
$$;


--
-- Name: log_dimension_history(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_dimension_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
  hist_tbl text := TG_TABLE_NAME || '_history';
  hist_seq text := TG_TABLE_NAME || '_history_history_id_seq';
  audit_cols text[] := ARRAY['valid_from','valid_to','created_at','updated_at'];
BEGIN
  -- Change-guard: only version on a SUBSTANTIVE change. Strip the temporal/audit
  -- columns (R6's updated_at bump, our own valid_from roll) before comparing, so a
  -- no-op UPDATE or a pure touch does not spawn a spurious history version.
  IF (to_jsonb(OLD) - audit_cols) IS NOT DISTINCT FROM (to_jsonb(NEW) - audit_cols) THEN
    RETURN NEW;
  END IF;

  EXECUTE format(
    'INSERT INTO %I SELECT (jsonb_populate_record(NULL::%I,'
    ' $1 || jsonb_build_object('
    '   ''history_id'', nextval(%L),'   -- surrogate PK for this version row
    '   ''valid_to'',   $2,'            -- close the superseded interval at change time
    '   ''changed_at'', $2))).*',       -- audit stamp
    hist_tbl, hist_tbl, hist_seq
  ) USING to_jsonb(OLD), now();

  NEW.valid_from := now();  -- the surviving live row is the NEW version: it starts now
  RETURN NEW;
END;
$_$;


--
-- Name: piot_create_area_runtime_1day(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_area_runtime_1day() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_area
			from areas e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..30 
			loop -- 30 days
				insert into area_oee_daily(id_area, ts_value)
					select r.id_area, ts_value_production from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_area_runtime_shift(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_area_runtime_shift() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_area
			from areas e
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null
		loop
			time_now := now();
			for i in -16..180 
			loop -- 180 blocks of 4 hours in a month
				insert into area_oee_shift(id_area, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
					select r.id_area, *, (select ts_value_production from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 hour' * (i * 4)) limit 1) 
					from piot_get_shift_hour_begin_by_area(r.id_area, time_now + interval '1 hour' * (i * 4))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_equipment_runtime_1day(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_equipment_runtime_1day() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			time_now := now();
			for i in 0..30 
			loop -- 30 days
				insert into equipment_oee_daily(id_equipment, ts_value)
					select r.id_equipment, ts_value_production from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_equipment_runtime_1hour(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_equipment_runtime_1hour() RETURNS void
    LANGUAGE plpgsql
    AS $$


	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..722 
			loop -- 30 days - 720 hours
				
				insert into equipment_oee_hourly (id_equipment, ts_value, target, ts_value_production)
				
					select r.id_equipment, date_trunc('hour', now() + interval '1 hour' * (i)), coalesce((select coalesce(vl_hour, vl_day/24) from production_targets pt where id_equipment = r.id_equipment),0)
						, date_trunc('day', (now() + interval '1 hour' * (i))::timestamptz at time zone (timezone) - interval '1 second' * (day_begin) ) at time zone (timezone) + interval '1 second' * (day_begin)
					from (
						select
							*
						from
							equipments
							join sites s using (id_site)
						where
							id_equipment = r.id_equipment
						) targets
					on conflict (id_equipment, ts_value)
						do update set
							target = CASE WHEN equipment_oee_hourly.target_customized = false and (equipment_oee_hourly.target <> EXCLUDED.target or equipment_oee_hourly.target is null) THEN EXCLUDED.target ELSE equipment_oee_hourly.target END,
							ts_value_production = EXCLUDED.ts_value_production
							where
								equipment_oee_hourly.id_equipment  = r.id_equipment
								and equipment_oee_hourly.ts_value = excluded.ts_value;
			end loop;
		end loop;
	end	
	
$$;


--
-- Name: piot_create_equipment_runtime_1month(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_equipment_runtime_1month() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			time_now := now();
			for i in 0..3
			loop -- 3 months
				insert into equipment_oee_monthly(id_equipment, ts_value)
					select r.id_equipment, date_trunc('month', ts_value_production) from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 month' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_equipment_runtime_1week(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_equipment_runtime_1week() RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  insert into equipment_oee_weekly (id_equipment, ts_value)
  select distinct e.id_equipment,
         date_trunc('week',
           (date_trunc('day', (now() + interval '1 day' * g.i)::timestamptz at time zone s.timezone
              - interval '1 second' * coalesce(a.day_begin, s.day_begin)))::date)
  from equipments e
  join enterprises et on e.id_enterprise = et.id_enterprise and et.active
  join sites s on s.id_site = e.id_site
  left join areas a on a.id_area = e.id_area
  cross join generate_series(-200,30) g(i)
  where e.id_area is not null and e.id_site is not null
  on conflict do nothing;
end $$;


--
-- Name: piot_create_equipment_runtime_shift(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_equipment_runtime_shift() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			and e.id_enterprise not in (2,36,99,100,101,102,111,112,113,117)
			--where tp_equipment = 3 --and et.id_enterprise = 31
		loop
			time_now := now();
			for i in -4..180 -- Using -4 to create the previous 2 shitfs
			loop -- 180 blocks of 4 hours in a month
				insert into equipment_oee_shift(id_equipment, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
				select r.id_equipment, e.*, (select ts_value_production from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 hour' * (i * 4)) limit 1) 
					from piot_get_shift_hour_begin_by_equipment(r.id_equipment, time_now + interval '1 hour' * (i * 4)) e
						left join shifts_exception_period sep on (r.id_equipment  = sep.id_equipment and e.ts_begin>=sep.ts_begin and e.ts_begin<sep.ts_end)
						where sep.id_equipment is null
					on conflict do NOTHING;
			end loop;

			update equipment_oee_shift u
				set target = p.target_shift
			from (
				select id_equipment, ts_value_production, coalesce((duration/3600)*vl_hour,0) as target_shift --coalesce(vl_day/count(*), 0) as target_shift
				from equipment_oee_shift ers
				join production_targets pt using (id_equipment)
				where id_equipment = r.id_equipment and ts_value > date_trunc('day', now()-interval '1 day')
				--group by ts_value_production, id_equipment, vl_day
			) p
					where
				u.target_customized = false
				and u.id_equipment = p.id_equipment 
				and u.ts_value_production = p.ts_value_production
				and u.ts_value >= now();

		end loop;
	end
$$;


--
-- Name: piot_create_equipment_runtime_shift_1month(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_equipment_runtime_shift_1month() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		i int;
	begin
		FOR r in
			select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			insert into equipment_oee_shift_monthly(ts_value, id_equipment, id_shift, duration, target)
				select 
					s1.ts_value,
					s1.id_equipment,
					s1.id_shift,
					duration,
					(erw.target * s1.duration)/ duration_of_all_shifts_in_month  as target --month target divided proportional to the duration of the shift
				from 
					(
					select 
						*,
						sum(duration) over (partition by id_equipment, ts_value) as duration_of_all_shifts_in_month
					from 
						(
						select
							date_trunc('month', ts_value) as ts_value,
							id_equipment,
							id_shift,
							sum(duration) as duration
						from equipment_oee_shift ers
						where 
							id_equipment = r.id_equipment
							and ts_value >= date_trunc('month', now())
						group by
							date_trunc('month', ts_value), id_equipment, id_shift
						order by ts_value
						)s0
					)s1
					left join equipment_oee_monthly erw using (ts_value, id_equipment)
				on conflict (id_equipment, ts_value, id_shift) DO UPDATE
					SET target = EXCLUDED.target;
		end loop;
	end
$$;


--
-- Name: piot_create_equipment_runtime_shift_1week(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_equipment_runtime_shift_1week() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		i int;
	begin
		FOR r in
			select id_equipment
			from equipments e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_area is not null and id_site is not null
		loop
			insert into equipment_oee_shift_weekly(ts_value, id_equipment, id_shift, duration, target)
				select 
					s1.ts_value::date,
					s1.id_equipment,
					s1.id_shift,
					duration,
					(erw.target * s1.duration)/ duration_of_all_shifts_in_week  as target --Week target divided proportional to the duration of the shift
				from 
					(
					select 
						*,
						sum(duration) over (partition by id_equipment, ts_value) as duration_of_all_shifts_in_week
					from 
						(
						select
							date_trunc('week', ts_value) as ts_value,
							id_equipment,
							id_shift,
							sum(duration) as duration
						from equipment_oee_shift ers
						where 
							id_equipment = r.id_equipment
							and ts_value >= date_trunc('week', now())
						group by
							date_trunc('week', ts_value), id_equipment, id_shift
						order by ts_value
						)s0
					)s1
					left join equipment_oee_weekly erw using (ts_value, id_equipment)
				on conflict (id_equipment, ts_value, id_shift) do update
				SET target = EXCLUDED.target;
		end loop;
	end
$$;


--
-- Name: piot_create_site_runtime_1day(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_site_runtime_1day() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_site
			from sites e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..30 
			loop -- 30 days
				insert into site_oee_daily(id_site, ts_value)
					select r.id_site, ts_value_production from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_site_runtime_shift(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_site_runtime_shift() RETURNS void
    LANGUAGE plpgsql
    AS $$
	DECLARE
		r RECORD;
		time_now timestamp with time zone;
		i int;
	begin
		FOR r in
		select id_site
			from sites e 
			join enterprises et on e.id_enterprise = et.id_enterprise and et.active
			where id_site is not null --and et.id_enterprise = 2
		loop
			time_now := now();
			for i in 0..180 
			loop -- 180 blocks of 4 hours in a month
				insert into site_oee_shift(id_site, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
					select r.id_site, *, (select ts_value_production from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 hour' * (i * 4)) limit 1) 
					from piot_get_shift_hour_begin_by_site(r.id_site, time_now + interval '1 hour' * (i * 4))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_get_day_begin_by_area(integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_day_begin_by_area(in_id_area integer, in_ts_value timestamp with time zone) RETURNS TABLE(ts_value timestamp with time zone, ts_value_production date)
    LANGUAGE plpgsql STABLE
    AS $$
declare
	in_id_site int := (select id_site from areas s where s.id_area=in_id_area );
	r RECORD;
begin
 return query
	select s1.ts_value, s1.ts_value_production from
	(
	select 
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone)) - interval '1 second' * (s.day_begin)) at time zone (s.timezone) + interval '1 second' * (s.day_begin) as ts_value,
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone) - interval '1 second' * (s.day_begin)))::date as ts_value_production,
			null as id_area, id_site
		from sites s
		where id_site = in_id_site
	union all 
	select 
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone)) - interval '1 second' * (a.day_begin)) at time zone (s.timezone) + interval '1 second' * (a.day_begin) as ts_value,
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone) - interval '1 second' * (a.day_begin)))::date as ts_value_production,
			a.id_area, s.id_site
		from areas a
		join sites s on a.id_site = s.id_site
		where a.id_area = in_id_area
	order by id_area, id_site limit 1
	) s1;
end
$$;


--
-- Name: piot_get_day_begin_by_equipment(integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_day_begin_by_equipment(in_id_equipment integer, in_ts_value timestamp with time zone) RETURNS TABLE(ts_value timestamp with time zone, ts_value_production date)
    LANGUAGE plpgsql STABLE
    AS $$
declare
	in_id_site int := (select id_site from equipments s where s.id_equipment=in_id_equipment );
	in_id_area int := (select id_area from equipments s where s.id_equipment=in_id_equipment );
	in_id_enterprise int := (select id_enterprise from equipments s where s.id_equipment=in_id_equipment );
	r RECORD;
begin
 return query
	select s1.ts_value, s1.ts_value_production from
	(
	select 
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone)) - interval '1 second' * (s.day_begin) ) at time zone (s.timezone) + interval '1 second' * (s.day_begin) as ts_value,
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone) - interval '1 second' * (s.day_begin)))::date as ts_value_production,
			null as id_area, id_site
		from sites s
		where id_site = in_id_site
	union all 
	select 
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone)) - interval '1 second' * (a.day_begin)) at time zone (s.timezone) + interval '1 second' * (a.day_begin) as ts_value,
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone) - interval '1 second' * (a.day_begin)))::date as ts_value_production,
			a.id_area, s.id_site
		from areas a
		join sites s on a.id_site = s.id_site
		where a.id_area = in_id_area
	order by id_area, id_site limit 1
	) s1;
end
$$;


--
-- Name: piot_get_day_begin_by_site(integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_day_begin_by_site(in_id_site integer, in_ts_value timestamp with time zone) RETURNS TABLE(ts_value timestamp with time zone, ts_value_production date)
    LANGUAGE plpgsql STABLE
    AS $$
declare
	r RECORD;
begin
 return query
	select s1.ts_value, s1.ts_value_production from
	(
	select 
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone)) - interval '1 second' * (s.day_begin)) at time zone (s.timezone) + interval '1 second' * (s.day_begin) as ts_value,
			date_trunc('day', (in_ts_value::timestamptz at time zone (s.timezone) - interval '1 second' * (s.day_begin)))::date as ts_value_production,
			id_site
		from sites s
		where id_site = in_id_site
	order by id_site limit 1
	) s1;
end
$$;


--
-- Name: h_piot_day_week_begin; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_day_week_begin (
    id_enterprise integer,
    packml_topic character varying,
    day_begin integer,
    week_begin integer
);


--
-- Name: piot_get_day_week_begin_by_packml_topic(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_day_week_begin_by_packml_topic(in_topic character varying) RETURNS SETOF public.h_piot_day_week_begin
    LANGUAGE sql STABLE
    AS $$
    SELECT
        pr.id_enterprise,
        pr.packml_topic,
        COALESCE(a.day_begin, si.day_begin, e.day_begin, 0) AS day_begin,
        COALESCE(si.week_begin, e.week_begin, 0)            AS week_begin
    FROM packml_register pr
    JOIN enterprises e  ON e.id_enterprise = pr.id_enterprise
    LEFT JOIN sites  si ON si.id_site       = pr.id_site
    LEFT JOIN areas  a  ON a.id_area        = pr.id_area
    WHERE pr.packml_topic = in_topic;
$$;


--
-- Name: piot_get_shift_hour_begin_by_area(integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hour_begin_by_area(in_id_area integer, ts_value timestamp with time zone) RETURNS TABLE(ts_begin timestamp with time zone, ts_end timestamp with time zone, shift_size integer, ts_range tstzrange, id_shift integer, id_shift_hour integer)
    LANGUAGE plpgsql STABLE
    AS $$
declare
	in_id_site int := (select id_site from areas s where s.id_area=in_id_area );
	in_id_enterprise int := (select id_enterprise from areas s where s.id_area=in_id_area );
	r RECORD;
begin
 return query
 select
	date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site)
	) at time zone (select timezone from sites where id_site = in_id_site) + begin_time * interval '1 second' + (select week_begin from	sites where id_site = in_id_site and id_enterprise = in_id_enterprise) * interval '1 second' as ts_begin,
    date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site)) at time zone (select timezone from sites where id_site = in_id_site) + begin_time * interval '1 second' + (select week_begin from	sites where id_site = in_id_site and id_enterprise = in_id_enterprise) * interval '1 second'+ sh.shift_size  * interval '1 second' as ts_end,
    sh.shift_size as shift_size,
    tstzrange(date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site)) at time zone (select timezone from sites where id_site = in_id_site) + begin_time * interval '1 second' + (select week_begin from	sites where id_site = in_id_site and id_enterprise = in_id_enterprise) * interval '1 second', 
        date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site)) at time zone (select timezone from sites where id_site = in_id_site) + begin_time * interval '1 second' + (select week_begin from	sites where id_site = in_id_site and id_enterprise = in_id_enterprise) * interval '1 second'+ sh.shift_size * interval '1 second') as ts_range,
    sh.id_shift ,
    sh.id_shift_hour 
from
	shift_hours sh
where
	sh.id_shift_hour = ( select s1.id_shift_hour from
					(
					select
						*, 1 as r
					from
						shift_hours
					where
						id_area = in_id_area
						and begin_time <= (
						select
							extract(epoch
						from
							(ts_value-date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site) - interval '1 second' * (select week_begin from sites where id_site = in_id_site) ) at time zone (select timezone from sites where id_site = in_id_site)))-(
							select
								week_begin
							from
								sites
							where
								id_site = in_id_site
							    and id_enterprise = in_id_enterprise))
						and end_time > (
						select
							extract(epoch
						from
							(ts_value-date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site) - interval '1 second' * (select week_begin from sites where id_site = in_id_site)  ) at time zone (select timezone from sites where id_site = in_id_site)))-(
							select
								week_begin
							from
								sites
							where
								id_site = in_id_site
							    and id_enterprise = in_id_enterprise))
					union all
					select
						*, 2 as r
					from
						shift_hours
					where
						id_site = in_id_site
						and begin_time <= (
						select
							extract(epoch
						from
							(ts_value-date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site) - interval '1 second' * (select week_begin from sites where id_site = in_id_site) ) at time zone (select timezone from sites where id_site = in_id_site)))-(
							select
								week_begin
							from
								sites
							where
								id_site = in_id_site
							    and id_enterprise = in_id_enterprise))
						and end_time > (
						select
							extract(epoch
						from
							(ts_value-date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site) - interval '1 second' * (select week_begin from sites where id_site = in_id_site)  ) at time zone (select timezone from sites where id_site = in_id_site)))-(
							select
								week_begin
							from
								sites
							where
								id_site = in_id_site
							    and id_enterprise = in_id_enterprise))
					union all 
					select
						*, 4 as r
					from
						shift_hours
					where
						id_enterprise = in_id_enterprise
						and begin_time <= (
						select
							extract(epoch
						from
							(ts_value-date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site) - interval '1 second' * (select week_begin from sites where id_site = in_id_site) ) at time zone (select timezone from sites where id_site = in_id_site)))-(
							select
								week_begin
							from
								sites
							where
								id_site = in_id_site
								and id_enterprise = in_id_enterprise))
						and end_time > (
						select
							extract(epoch
						from
							(ts_value-date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site) - interval '1 second' * (select week_begin from sites where id_site = in_id_site)  ) at time zone (select timezone from sites where id_site = in_id_site)))-(
							select
								week_begin
							from
								sites
							where
								id_site = in_id_site
							    and id_enterprise = in_id_enterprise))
						order by r
limit 1
					) s1) ;
end
$$;


--
-- Name: piot_get_shift_hour_begin_by_equipment(integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hour_begin_by_equipment(in_id_equipment integer, ts_value timestamp with time zone) RETURNS TABLE(ts_begin timestamp with time zone, ts_end timestamp with time zone, shift_size integer, ts_range tstzrange, id_shift integer, id_shift_hour integer)
    LANGUAGE plpgsql STABLE
    AS $$
declare
  in_id_site       int := (select id_site       from equipments where id_equipment = in_id_equipment);
  in_id_area       int := (select id_area        from equipments where id_equipment = in_id_equipment);
  in_id_enterprise int := (select id_enterprise  from equipments where id_equipment = in_id_equipment);
  v_tz      text := (select timezone   from sites where id_site = in_id_site);
  v_wb_ent  int  := (select week_begin  from sites where id_site = in_id_site and id_enterprise = in_id_enterprise);
  v_wb_site int  := (select week_begin  from sites where id_site = in_id_site);
  v_week_base timestamptz := date_trunc('week', ts_value at time zone v_tz - v_wb_ent * interval '1 second') at time zone v_tz + v_wb_ent * interval '1 second';
  v_offset double precision := extract(epoch from (ts_value - date_trunc('week', ts_value at time zone v_tz - interval '1 second' * v_wb_site) at time zone v_tz)) - v_wb_ent;
begin
  return query
  select
    v_week_base + sh.begin_time * interval '1 second',
    v_week_base + sh.begin_time * interval '1 second' + sh.shift_size * interval '1 second',
    sh.shift_size,
    tstzrange(v_week_base + sh.begin_time * interval '1 second',
              v_week_base + sh.begin_time * interval '1 second' + sh.shift_size * interval '1 second'),
    sh.id_shift, sh.id_shift_hour
  from shift_hours sh
  where sh.id_shift_hour = (
    select s1.id_shift_hour from (
      select s.id_shift_hour, 1 as r from shift_hours s where s.id_equipment = in_id_equipment and s.begin_time <= v_offset and s.end_time > v_offset
      union all
      select s.id_shift_hour, 2 as r from shift_hours s where s.id_area = in_id_area and s.id_equipment is null and s.begin_time <= v_offset and s.end_time > v_offset
      union all
      select s.id_shift_hour, 3 as r from shift_hours s where s.id_site = in_id_site and s.id_area is null and s.id_equipment is null and s.begin_time <= v_offset and s.end_time > v_offset
      union all
      select s.id_shift_hour, 4 as r from shift_hours s where s.id_enterprise = in_id_enterprise and s.id_site is null and s.id_area is null and s.id_equipment is null and s.begin_time <= v_offset and s.end_time > v_offset
      order by r limit 1
    ) s1);
end
$$;


--
-- Name: piot_get_shift_hour_begin_by_site(integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hour_begin_by_site(in_id_site integer, ts_value timestamp with time zone) RETURNS TABLE(ts_begin timestamp with time zone, ts_end timestamp with time zone, shift_size integer, ts_range tstzrange, id_shift integer, id_shift_hour integer)
    LANGUAGE plpgsql STABLE
    AS $$
declare
	in_id_enterprise int := (select id_enterprise from sites s where s.id_site=in_id_site );
	r RECORD;
begin
 return query
 select
	date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site)) at time zone (select timezone from sites where id_site = in_id_site) + begin_time * interval '1 second' + (select week_begin from	sites where id_site = in_id_site and id_enterprise = in_id_enterprise) * interval '1 second' as ts_begin,
    date_trunc('week',  ts_value at time zone (select timezone from sites where id_site = in_id_site)) at time zone (select timezone from sites where id_site = in_id_site) + begin_time * interval '1 second' + (select week_begin from	sites where id_site = in_id_site and id_enterprise = in_id_enterprise) * interval '1 second'+ sh.shift_size  * interval '1 second' as ts_end,
    sh.shift_size as shift_size,
    tstzrange(date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site)) at time zone (select timezone from sites where id_site = in_id_site) + begin_time * interval '1 second' + (select week_begin from	sites where id_site = in_id_site and id_enterprise = in_id_enterprise) * interval '1 second', 
        date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site)) at time zone (select timezone from sites where id_site = in_id_site) + begin_time * interval '1 second' + (select week_begin from	sites where id_site = in_id_site and id_enterprise = in_id_enterprise) * interval '1 second'+ sh.shift_size * interval '1 second') as ts_range,
    sh.id_shift ,
    sh.id_shift_hour 
from
	shift_hours sh
where
	sh.id_shift_hour = ( select s1.id_shift_hour from
					(
					select
						*
					from
						shift_hours
					where
						id_site = in_id_site
						and begin_time <= (
						select
							extract(epoch
						from
							(ts_value-date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site) - interval '1 second' * (select week_begin from sites where id_site = in_id_site) ) at time zone (select timezone from sites where id_site = in_id_site)))-(
							select
								week_begin
							from
								sites
							where
								id_site = in_id_site
							    and id_enterprise = in_id_enterprise))
						and end_time > (
						select
							extract(epoch
						from
							(ts_value-date_trunc('week', ts_value at time zone (select timezone from sites where id_site = in_id_site) - interval '1 second' * (select week_begin from sites where id_site = in_id_site)  ) at time zone (select timezone from sites where id_site = in_id_site)))-(
							select
								week_begin
							from
								sites
							where
								id_site = in_id_site
							    and id_enterprise = in_id_enterprise))
						 order by id_site limit 1
					) s1) ;
end
$$;


--
-- Name: shift_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shift_hours (
    id_shift_hour integer NOT NULL,
    id_shift integer,
    cd_shift character varying,
    begin_time integer,
    end_time integer,
    id_enterprise integer,
    id_site integer,
    id_area integer,
    day_number integer,
    day_week character varying,
    shift_size integer,
    id_equipment integer,
    duration integer
);


--
-- Name: piot_get_shift_hour_list_by_equipment(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hour_list_by_equipment(in_id_enterprise integer, in_id_equip integer) RETURNS SETOF public.shift_hours
    LANGUAGE plpgsql STABLE
    AS $$
declare
	in_id_site int := (select id_site from equipments s where s.id_equipment=in_id_equip );
	in_id_area int := (select id_area from equipments s where s.id_equipment=in_id_equip );
begin
return query


-- Enter function body here
with dataa as (
		select
			sh.*
		from
			shift_hours sh
			join sites s on (s.id_site= sh.id_site)
		where
			sh.id_enterprise = in_id_enterprise
			and sh.id_site = in_id_site
			and (sh.id_area = in_id_area or sh.id_area is null)
			and (sh.id_equipment = in_id_equip or sh.id_equipment is null)
--			and begin_time <= (select extract(epoch from (ts_value-date_trunc('week', ts_value at time zone s.timezone - interval '1 second' * s.week_begin ) at time zone s.timezone ))-(s.week_begin))
--			and end_time 	> (select extract(epoch from (ts_value-date_trunc('week', ts_value at time zone s.timezone - interval '1 second' * s.week_begin ) at time zone s.timezone ))-(s.week_begin))
)
select * from dataa
where 
	case
		when exists (select * from dataa where id_equipment is not null) then dataa.id_equipment is not null
		when exists (select * from dataa where id_area is not null) then dataa.id_area is not null
		else true
	end;
		   
		   

end	   
$$;


--
-- Name: h_shift_hours_per_equipment_packml_topic; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_shift_hours_per_equipment_packml_topic (
    id_enterprise integer,
    packml_topic character varying,
    shift_hours jsonb[]
);


--
-- Name: piot_get_shift_hours_by_enterprise_packml_topic_2(character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hours_by_enterprise_packml_topic_2(in_topic character varying, in_enterprise integer DEFAULT NULL::integer) RETURNS SETOF public.h_shift_hours_per_equipment_packml_topic
    LANGUAGE sql STABLE
    AS $$
    SELECT * FROM piot_get_shift_hours_by_packml_topic_2(in_topic);
$$;


--
-- Name: piot_get_shift_hours_by_equipment(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hours_by_equipment(in_id_enterprise integer, in_id_equip integer) RETURNS SETOF public.shift_hours
    LANGUAGE sql
    AS $$
    select
        sh.*
    from (select * from equipments where id_equipment = in_id_equip) ev
        right join shift_hours sh on ev.id_enterprise = sh.id_enterprise and ev.id_enterprise = sh.id_enterprise
            and
                (
                    case
                        when exists (select 1 from shift_hours ssh where ssh.id_equipment = ev.id_equipment) then ev.id_equipment = sh.id_equipment
                        when exists (select 1 from shift_hours ssh where ssh.id_area = ev.id_area) then ev.id_area = sh.id_area and sh.id_equipment is null
                        when exists (select 1 from shift_hours ssh where ssh.id_site = ev.id_site) then ev.id_site = sh.id_site and sh.id_area is null
                        when exists (select 1 from shift_hours ssh where ssh.id_enterprise = ev.id_enterprise) then ev.id_enterprise = sh.id_enterprise and sh.id_site is null
                        else false
                    end
                )
    where
        ev.id_enterprise = in_id_enterprise;
$$;


--
-- Name: piot_get_shift_hours_by_packml_topic(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hours_by_packml_topic(in_topic text) RETURNS SETOF public.shift_hours
    LANGUAGE sql STABLE
    AS $$

select piot_get_shift_hours_by_equipment(aa.id_enterprise, aa.id_equipment)
from (
	select
		id_equipment, id_enterprise from packml_register pr where packml_topic = in_topic) aa;

$$;


--
-- Name: piot_get_shift_hours_by_packml_topic_2(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hours_by_packml_topic_2(in_topic character varying) RETURNS SETOF public.h_shift_hours_per_equipment_packml_topic
    LANGUAGE sql STABLE
    AS $$
    SELECT
        id_enterprise, packml_topic, array_agg(sh_per_equip) AS shift_hours
    FROM (
        SELECT eq.id_enterprise, packml.packml_topic,
            jsonb_build_object(
                'id_shift_hour', sh.id_shift_hour,
                'id_shift',      sh.id_shift,
                'cd_shift',      sh.cd_shift,
                'begin_time',    sh.begin_time,
                'end_time',      sh.end_time,
                'id_site',       sh.id_site,
                'id_area',       sh.id_area,
                'day_number',    sh.day_number,
                'day_week',      sh.day_week,
                'shift_size',    sh.shift_size,
                'duration',      sh.duration
            ) AS sh_per_equip
        FROM (
            SELECT * FROM equipments
            WHERE id_enterprise = (
                SELECT id_enterprise FROM packml_register
                WHERE packml_topic = (string_to_array(in_topic, '/'))[1]
            )
        ) eq
        JOIN (
            SELECT *
            FROM packml_register
            WHERE
                CASE cardinality(string_to_array(in_topic, '/'))
                    WHEN 4 THEN id_equipment  = (SELECT id_equipment  FROM packml_register WHERE packml_topic = in_topic)
                    WHEN 3 THEN id_area       = (SELECT id_area       FROM packml_register WHERE packml_topic = in_topic)
                    WHEN 2 THEN id_site       = (SELECT id_site       FROM packml_register WHERE packml_topic = in_topic)
                    ELSE id_enterprise        = (SELECT id_enterprise FROM packml_register WHERE packml_topic = (string_to_array(in_topic, '/'))[1])
                END
                AND active = true
                AND id_equipment IS NOT NULL
                AND packml_topic LIKE '%/%/%/%'
                AND packml_topic NOT LIKE '%/%/%/%/%'
        ) packml ON packml.id_equipment = eq.id_equipment
        JOIN piot_get_shift_hours_by_equipment(eq.id_enterprise, eq.id_equipment) sh ON true
        GROUP BY eq.id_enterprise, eq.id_equipment, sh.id_shift_hour, sh.id_shift, sh.cd_shift,
                 sh.begin_time, sh.end_time, sh.id_site, sh.id_area, sh.day_number, sh.day_week,
                 sh.shift_size, sh.duration, packml.packml_topic
    ) eqs
    GROUP BY id_enterprise, packml_topic;
$$;


--
-- Name: purge_analytics_plain(integer, jsonb); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.purge_analytics_plain(IN job_id integer, IN config jsonb)
    LANGUAGE plpgsql
    AS $$
   BEGIN
     DELETE FROM public.equipment_oee_hourly        WHERE ts_value < now() - interval '90 days';
     DELETE FROM public.equipment_oee_shift        WHERE ts_value < now() - interval '90 days';
     DELETE FROM public.equipment_events_cpac_shadow   WHERE ts_event < now() - interval '90 days';
   END;
   $$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: equipment_values; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_values (
    id_equipment integer NOT NULL,
    ts_value timestamp with time zone NOT NULL,
    id_enterprise integer,
    id_site integer,
    id_area integer,
    net_production_incr real,
    gross_production_incr real,
    scrap_incr real,
    speed real,
    id_order character varying(255),
    conversion_factor real,
    number_cavities integer,
    faults jsonb,
    analogs jsonb,
    signal_quality integer,
    net_production_val real,
    gross_production_val real,
    scrap_val real,
    id_shift integer,
    id_team integer,
    id_shift_hour integer,
    box_code character varying(255),
    transaction_code character varying(255),
    state integer,
    mode integer,
    id_production_order integer,
    ts_value_production date,
    id_equipment_line_infeed integer,
    id_equipment_line_outfeed integer,
    net_production_incr_quality integer,
    gross_production_incr_quality integer,
    scrap_incr_quality integer,
    speed_quality integer,
    id_order_quality character varying(255),
    conversion_factor_quality integer,
    number_cavities_quality integer,
    net_production_val_quality integer,
    gross_production_val_quality integer,
    scrap_val_quality integer,
    id_shift_quality integer,
    state_quality integer,
    mode_quality integer,
    id_production_order_quality integer,
    ts_value_production_quality date,
    id_equipment_line_connected integer,
    position_in_equipment_line integer,
    is_equipment_line_infeed integer,
    is_equipment_line_outfeed integer,
    process_scrap_incr real,
    process_scrap_val real,
    process_scrap_incr_quality integer,
    process_scrap_val_quality integer,
    tp_equipment integer,
    sub_mode character varying(255),
    ideal_production_speed integer,
    check_number bigint,
    ingested_at timestamp with time zone DEFAULT now(),
    source_seq bigint
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000');


--
-- Name: equipment_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_events (
    id_equipment integer NOT NULL,
    ts_event timestamp with time zone NOT NULL,
    status integer,
    id_equipment_event bigint NOT NULL,
    txt_downtime_notes character varying,
    idle character varying,
    idle_processed boolean,
    forced_creation_system boolean,
    fault integer,
    fault_processed boolean,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    planned_downtime boolean,
    ts_end timestamp with time zone,
    duration integer,
    id_enterprise integer,
    desc_category character varying,
    desc_subcategory character varying,
    cd_category_client integer,
    cd_subcategory_client integer,
    last_update timestamp with time zone,
    ignore_cost boolean,
    ingested_at timestamp with time zone DEFAULT now(),
    source_seq bigint
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000');


--
-- Name: equipments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipments (
    id_equipment integer NOT NULL,
    cd_equipment character varying(255),
    nm_equipment character varying(255),
    "position" integer,
    tp_equipment integer,
    id_area integer,
    id_site integer,
    id_enterprise integer,
    id_parentequipment integer,
    stop_threshold_time integer DEFAULT 300,
    production_speed integer,
    alerts jsonb,
    performance_alert_threshold real,
    id_equipment_type integer,
    minimum_performance_threshold real,
    require_downtime_reason boolean,
    sector_equipment_infeed integer,
    sector_equipment_outfeed integer,
    status_type integer,
    id_counter_status integer,
    id_equipment_state_status integer,
    id_equipment_state_idle integer,
    id_equipment_state_starved integer,
    id_equipment_state_blocked integer,
    id_equipment_status_mirror integer,
    id_packed_counter integer,
    cd_sector character varying(255),
    id_equipment_state_fault integer,
    downtime_reasons jsonb,
    minimum_ideal_performance_threshold real,
    custom jsonb,
    scrap_reasons jsonb,
    ideal_speed integer,
    overview_events_type integer,
    overview_events_filter_by_idle character varying(255),
    flexible_position boolean,
    event_should_be_displayed boolean,
    overview_version jsonb,
    use_label_net_production boolean,
    state_change_threshold_time integer,
    lead_machine integer,
    speed_calculated_by_packiot boolean,
    event_generated_by_packiot boolean,
    conversion_factor real,
    net_production_type integer,
    id_plc integer,
    active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone,
    gross_machine bigint,
    scrap_machine bigint,
    exclude_idle_from_availability boolean,
    idle_timeout_seconds integer
);

ALTER TABLE ONLY public.equipments FORCE ROW LEVEL SECURITY;


--
-- Name: equipment_runtime_shift_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.equipment_runtime_shift_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: equipment_oee_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_oee_shift (
    id_runtime_shift bigint DEFAULT nextval('public.equipment_runtime_shift_id_seq'::regclass) NOT NULL,
    ts_value timestamp with time zone NOT NULL,
    id_equipment integer DEFAULT 0 NOT NULL,
    oee real DEFAULT 0,
    recalc_needed boolean DEFAULT false,
    oee_p real DEFAULT 0,
    oee_a real DEFAULT 0,
    oee_q real DEFAULT 0,
    available_time integer DEFAULT 0,
    running_time integer DEFAULT 0,
    stopped_time integer DEFAULT 0,
    planned_downtime integer DEFAULT 0,
    ideal_production double precision DEFAULT 0,
    idle_time integer DEFAULT 0,
    idle_starved integer DEFAULT 0,
    idle_blocked integer DEFAULT 0,
    id_shift integer,
    id_shift_hour integer,
    id_team integer,
    duration integer DEFAULT 0,
    ts_range tstzrange,
    gross real DEFAULT 0,
    net real DEFAULT 0,
    downtime integer DEFAULT 0,
    changeover_time integer DEFAULT 0,
    target double precision DEFAULT 0,
    ts_end timestamp with time zone,
    manually_customized boolean DEFAULT false,
    invalidated boolean DEFAULT false,
    scrap real DEFAULT 0,
    speed real DEFAULT 0,
    cd_shift character varying,
    ts_value_production date,
    target_customized boolean DEFAULT false,
    proportional_target real DEFAULT 0,
    ideal_speed double precision DEFAULT 0,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone,
    CONSTRAINT chk_equipment_runtime_shift_ts_order CHECK ((ts_value <= ts_end)),
    CONSTRAINT equipment_runtime_shift_oee_bounds CHECK ((((oee >= (0)::double precision) AND (oee <= (1)::double precision)) AND ((oee_a >= (0)::double precision) AND (oee_a <= (1)::double precision)) AND ((oee_p >= (0)::double precision) AND (oee_p <= (1)::double precision)) AND ((oee_q >= (0)::double precision) AND (oee_q <= (1)::double precision))))
)
WITH (autovacuum_vacuum_threshold='100', autovacuum_vacuum_scale_factor='0.05', autovacuum_analyze_threshold='100', autovacuum_analyze_scale_factor='0.05', fillfactor='85');

ALTER TABLE ONLY public.equipment_oee_shift FORCE ROW LEVEL SECURITY;


--
-- Name: equipment_oee_hourly; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_oee_hourly (
    id_equipment integer DEFAULT 0 NOT NULL,
    ts_value timestamp(0) with time zone NOT NULL,
    oee real DEFAULT 0,
    recalc_needed boolean DEFAULT false,
    oee_p real DEFAULT 0,
    oee_a real DEFAULT 0,
    oee_q real DEFAULT 0,
    available_time integer DEFAULT 0,
    running_time integer DEFAULT 0,
    stopped_time integer DEFAULT 0,
    planned_downtime integer DEFAULT 0,
    ideal_production double precision DEFAULT 0,
    idle_time integer DEFAULT 0,
    idle_starved integer DEFAULT 0,
    idle_blocked integer DEFAULT 0,
    target double precision DEFAULT 0,
    gross real DEFAULT 0,
    net real DEFAULT 0,
    downtime integer DEFAULT 0,
    changeover_time integer DEFAULT 0,
    scrap real DEFAULT 0,
    speed real DEFAULT 0,
    ts_value_production date,
    target_customized boolean DEFAULT false,
    proportional_target real DEFAULT 0,
    id_team integer,
    ideal_speed double precision DEFAULT 0,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone,
    CONSTRAINT equipment_runtime_1hour_oee_bounds CHECK ((((oee >= (0)::double precision) AND (oee <= (1)::double precision)) AND ((oee_a >= (0)::double precision) AND (oee_a <= (1)::double precision)) AND ((oee_p >= (0)::double precision) AND (oee_p <= (1)::double precision)) AND ((oee_q >= (0)::double precision) AND (oee_q <= (1)::double precision))))
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000', fillfactor='90');

ALTER TABLE ONLY public.equipment_oee_hourly FORCE ROW LEVEL SECURITY;


--
-- Name: production_orders_runtime; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.production_orders_runtime (
    id_production_order integer NOT NULL,
    runtime_timerange tstzrange,
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
    id_production_orders_runtime bigint NOT NULL,
    id_equipment integer,
    id_production_order_runtime bigint NOT NULL,
    net_production double precision,
    gross_production double precision,
    downtime integer,
    changeover_time integer,
    speed real,
    last_update timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    multiplier double precision,
    CONSTRAINT production_orders_runtime_oee_bounds CHECK ((((oee >= (0)::double precision) AND (oee <= (1)::double precision)) AND ((oee_a >= (0)::double precision) AND (oee_a <= (1)::double precision)) AND ((oee_p >= (0)::double precision) AND (oee_p <= (1)::double precision)) AND ((oee_q >= (0)::double precision) AND (oee_q <= (1)::double precision))))
)
WITH (autovacuum_vacuum_threshold='200', autovacuum_vacuum_scale_factor='0.05', autovacuum_analyze_threshold='200', autovacuum_analyze_scale_factor='0.05', fillfactor='85');

ALTER TABLE ONLY public.production_orders_runtime FORCE ROW LEVEL SECURITY;


--
-- Name: production_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.production_orders (
    id_production_order bigint NOT NULL,
    id_enterprise integer NOT NULL,
    id_site integer NOT NULL,
    id_area integer NOT NULL,
    id_equipment integer NOT NULL,
    id_product integer,
    id_client integer,
    status integer DEFAULT 1 NOT NULL,
    production_programmed bigint,
    production_ordered bigint,
    id_order integer NOT NULL,
    id_user_operator integer,
    id_equipment_executed integer,
    production_real bigint,
    production_final bigint,
    ts_start timestamp with time zone,
    ts_end timestamp with time zone,
    equipment_setup jsonb,
    oee_processed boolean DEFAULT false NOT NULL,
    oee real,
    stopped_time integer,
    planned_downtime integer,
    qt_stops integer,
    erp_processed boolean DEFAULT false NOT NULL,
    ts_creation timestamp with time zone DEFAULT now() NOT NULL,
    txt_production_order_notes character varying(255),
    txt_production_order_description character varying(255),
    conversion_factor real DEFAULT 1,
    net_production double precision,
    speed real,
    ideal_production_speed integer,
    id_order_text character varying(255),
    recalc_needed boolean DEFAULT true NOT NULL,
    last_update timestamp with time zone DEFAULT now(),
    nm_production_order character varying,
    multiplier double precision,
    gross_production double precision,
    oee_quality double precision,
    oee_availability double precision,
    oee_performance double precision,
    available_time double precision,
    running_time double precision,
    custom_field jsonb,
    ideal_production integer,
    ts_start_tz timestamp with time zone,
    ts_end_tz timestamp with time zone,
    id_label bigint,
    CONSTRAINT production_orders_oee_bounds CHECK ((((oee >= (0)::double precision) AND (oee <= (1)::double precision)) AND ((oee_availability >= (0)::double precision) AND (oee_availability <= (1)::double precision)) AND ((oee_performance >= (0)::double precision) AND (oee_performance <= (1)::double precision)) AND ((oee_quality >= (0)::double precision) AND (oee_quality <= (1)::double precision)))),
    CONSTRAINT production_orders_speed_check CHECK (((ideal_production_speed IS NULL) OR (ideal_production_speed > 0))),
    CONSTRAINT production_orders_ts_start_ts_end CHECK ((((ts_start < ts_end) AND (status = ANY (ARRAY[3, 4]))) OR ((status = 1) AND (ts_start IS NULL)) OR ((status = 1) AND (ts_end IS NULL)) OR ((status = 2) AND (ts_start IS NOT NULL))))
);

ALTER TABLE ONLY public.production_orders FORCE ROW LEVEL SECURITY;


--
-- Name: equipment_values_1min; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_values_1min (
    ts_value timestamp with time zone,
    id_equipment integer,
    val double precision
);


--
-- Name: agg_equipment_values_1min_t; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.agg_equipment_values_1min_t AS
 SELECT equipment_values_1min.ts_value,
    equipment_values_1min.id_equipment,
    equipment_values_1min.val
   FROM public.equipment_values_1min;


--
-- Name: area_live_day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_live_day (
    id_area integer NOT NULL,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    target real,
    begin_time date,
    end_time date,
    idle_time integer,
    elapsed_time integer,
    idle_blocked integer,
    idle_starved integer,
    running_time integer,
    stopped_time integer,
    available_time integer,
    planned_downtime integer,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real
);


--
-- Name: area_live_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_live_shift (
    id_area integer NOT NULL,
    id_shift integer,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    target real,
    begin_time timestamp(0) with time zone,
    end_time timestamp(0) with time zone,
    idle_time integer,
    elapsed_time integer,
    idle_blocked integer,
    idle_starved integer,
    running_time integer,
    stopped_time integer,
    available_time integer,
    planned_downtime integer,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real,
    duration integer,
    previous_shift integer,
    next_shift integer,
    prev1_oee real,
    prev1_oee_a real,
    prev1_oee_p real,
    prev1_oee_q real,
    prev1_gross_production real,
    prev1_net_production real,
    prev1_scrap real,
    prev1_target real,
    prev1_begin_time timestamp(0) with time zone,
    prev1_end_time timestamp(0) with time zone,
    prev1_id_shift integer,
    prev1_duration integer,
    prev2_oee real,
    prev2_oee_a real,
    prev2_oee_p real,
    prev2_oee_q real,
    prev2_gross_production real,
    prev2_net_production real,
    prev2_scrap real,
    prev2_target real,
    prev2_begin_time timestamp(0) with time zone,
    prev2_end_time timestamp(0) with time zone,
    prev2_id_shift integer,
    prev2_duration integer,
    prev3_oee real,
    prev3_oee_a real,
    prev3_oee_p real,
    prev3_oee_q real,
    prev3_gross_production real,
    prev3_net_production real,
    prev3_scrap real,
    prev3_target real,
    prev3_begin_time timestamp(0) with time zone,
    prev3_end_time timestamp(0) with time zone,
    prev3_id_shift integer,
    prev3_duration integer,
    id_enterprise integer,
    nm_area character varying,
    id_site integer,
    id_shift_hour integer,
    prev1_id_shift_hour integer
);


--
-- Name: area_oee_daily; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_oee_daily (
    ts_value date NOT NULL,
    id_area integer NOT NULL,
    oee real,
    recalc_needed boolean DEFAULT true,
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
    target double precision,
    gross real,
    net real,
    downtime integer,
    changeover_time integer,
    scrap real,
    speed real,
    proportional_target double precision,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
);


--
-- Name: area_oee_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_oee_shift (
    ts_value timestamp(0) with time zone NOT NULL,
    id_area integer NOT NULL,
    oee real,
    recalc_needed boolean DEFAULT true,
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
    id_shift integer,
    id_shift_hour integer,
    id_team integer,
    duration integer,
    ts_range tstzrange,
    gross real,
    net real,
    downtime integer,
    changeover_time integer,
    target double precision,
    ts_end timestamp with time zone,
    ts_value_production date,
    target_customized boolean DEFAULT false,
    proportional_target real,
    scrap real,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone,
    CONSTRAINT area_runtime_shift_oee_bounds CHECK ((((oee >= (0)::double precision) AND (oee <= (1)::double precision)) AND ((oee_a >= (0)::double precision) AND (oee_a <= (1)::double precision)) AND ((oee_p >= (0)::double precision) AND (oee_p <= (1)::double precision)) AND ((oee_q >= (0)::double precision) AND (oee_q <= (1)::double precision)))),
    CONSTRAINT chk_area_runtime_shift_ts_order CHECK ((ts_value <= ts_end))
)
WITH (autovacuum_vacuum_threshold='50', autovacuum_vacuum_scale_factor='0.05', autovacuum_analyze_threshold='50', autovacuum_analyze_scale_factor='0.05', fillfactor='85');


--
-- Name: areas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.areas (
    id_area integer NOT NULL,
    nm_area character varying(255),
    id_infeedcounter integer,
    id_outfeedcounter integer,
    id_rejectscounter integer,
    id_site integer,
    week_begin integer NOT NULL,
    day_begin integer NOT NULL,
    week_size integer NOT NULL,
    id_enterprise integer NOT NULL,
    active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: COLUMN areas.id_infeedcounter; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.areas.id_infeedcounter IS 'DEPRECATED / DEAD (0 rows). Legacy count-index metadata, no functional reader (view-passthrough only). Pending drop.';


--
-- Name: COLUMN areas.id_outfeedcounter; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.areas.id_outfeedcounter IS 'DEPRECATED / DEAD (0 rows). See id_infeedcounter.';


--
-- Name: COLUMN areas.id_rejectscounter; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.areas.id_rejectscounter IS 'DEPRECATED / DEAD (0 rows). See id_infeedcounter.';


--
-- Name: areas_history_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.areas_history_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: areas_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.areas_history (
    history_id bigint DEFAULT nextval('public.areas_history_history_id_seq'::regclass) NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    id_area integer NOT NULL,
    nm_area character varying(255),
    id_infeedcounter integer,
    id_outfeedcounter integer,
    id_rejectscounter integer,
    id_site integer,
    week_begin integer NOT NULL,
    day_begin integer NOT NULL,
    week_size integer NOT NULL,
    id_enterprise integer NOT NULL,
    active boolean NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: areas_id_area_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.areas_id_area_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: areas_id_area_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.areas_id_area_seq OWNED BY public.areas.id_area;


--
-- Name: box_production_bridges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.box_production_bridges (
    id_enterprise integer NOT NULL,
    source_cd text NOT NULL,
    target_cd text NOT NULL,
    label_key text DEFAULT 'Label_Neopac'::text NOT NULL,
    bucket interval DEFAULT '00:01:00'::interval NOT NULL,
    lookback interval DEFAULT '00:05:00'::interval NOT NULL
);


--
-- Name: box_scans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.box_scans (
    box_scan_id bigint NOT NULL,
    box_uid uuid DEFAULT gen_random_uuid() NOT NULL,
    id_enterprise integer NOT NULL,
    id_site integer,
    id_area integer,
    id_equipment integer NOT NULL,
    id_production_order bigint NOT NULL,
    id_order integer,
    scan_type text DEFAULT 'production'::text NOT NULL,
    label_seq bigint,
    qty integer DEFAULT 1 NOT NULL,
    counts_toward_total boolean DEFAULT true NOT NULL,
    raw_barcode text,
    voids_box_scan_id bigint,
    scan_uuid uuid NOT NULL,
    ts_value timestamp with time zone DEFAULT now() NOT NULL,
    ingested_at timestamp with time zone DEFAULT now() NOT NULL,
    source_seq bigint,
    scanned_by text,
    CONSTRAINT box_scans_scan_type_check CHECK ((scan_type = ANY (ARRAY['production'::text, 'sample'::text, 'void'::text, 'reprint'::text, 'rework'::text])))
);


--
-- Name: box_scans_box_scan_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.box_scans ALTER COLUMN box_scan_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.box_scans_box_scan_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: capture_observations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capture_observations (
    id_capture_observation bigint NOT NULL,
    id_enterprise integer NOT NULL,
    topic character varying NOT NULL,
    count_index integer NOT NULL,
    metric_suffix character varying NOT NULL,
    first_seen_ts timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_ts timestamp with time zone DEFAULT now() NOT NULL,
    observed_count bigint DEFAULT 0 NOT NULL
);


--
-- Name: capture_observations_id_capture_observation_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.capture_observations_id_capture_observation_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: capture_observations_id_capture_observation_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.capture_observations_id_capture_observation_seq OWNED BY public.capture_observations.id_capture_observation;


--
-- Name: client_descriptors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_descriptors (
    id integer NOT NULL,
    id_enterprise integer NOT NULL,
    tenant_code text NOT NULL,
    descriptor jsonb NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    artifacts jsonb,
    validation jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text,
    updated_by text,
    CONSTRAINT client_descriptors_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'generated'::text, 'deployed'::text, 'captured'::text, 'validated'::text, 'cutover'::text])))
);


--
-- Name: client_descriptors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.client_descriptors_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: client_descriptors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.client_descriptors_id_seq OWNED BY public.client_descriptors.id;


--
-- Name: clients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clients (
    id_client bigint NOT NULL,
    nm_client character varying(255),
    id_enterprise integer
);


--
-- Name: clients_id_client_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clients_id_client_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clients_id_client_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clients_id_client_seq OWNED BY public.clients.id_client;


--
-- Name: dashboard_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dashboard_config (
    id_enterprise integer NOT NULL,
    dashboard_id text NOT NULL,
    config jsonb NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: data_quality_event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.data_quality_event (
    id bigint NOT NULL,
    id_enterprise integer NOT NULL,
    id_equipment integer,
    grain text NOT NULL,
    bucket_ts timestamp with time zone NOT NULL,
    rule text NOT NULL,
    observed_value double precision,
    severity text DEFAULT 'warn'::text NOT NULL,
    detected_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: data_quality_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.data_quality_event ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.data_quality_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: downtime_reason; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.downtime_reason (
    id bigint NOT NULL,
    id_enterprise integer NOT NULL,
    code character varying NOT NULL,
    label character varying,
    label_i18n jsonb,
    category character varying,
    parent_id bigint,
    reason_level smallint DEFAULT 1 NOT NULL,
    planned_downtime boolean DEFAULT false NOT NULL,
    change_over boolean DEFAULT false NOT NULL,
    idle boolean DEFAULT false NOT NULL,
    active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: downtime_reason_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.downtime_reason ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.downtime_reason_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: enterprises; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enterprises (
    id_enterprise integer NOT NULL,
    nm_enterprise character varying(255) NOT NULL,
    api_key character varying(255),
    week_begin integer,
    day_begin integer,
    week_size integer,
    timezone character varying(255),
    logo_url character varying(255),
    active boolean DEFAULT true,
    basic_menu jsonb,
    custom_menu jsonb,
    language_packs jsonb,
    scrap_calc_type integer DEFAULT 1,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: enterprises_history_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.enterprises_history_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enterprises_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enterprises_history (
    history_id bigint DEFAULT nextval('public.enterprises_history_history_id_seq'::regclass) NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    id_enterprise integer NOT NULL,
    nm_enterprise character varying(255) NOT NULL,
    api_key character varying(255),
    week_begin integer,
    day_begin integer,
    week_size integer,
    timezone character varying(255),
    logo_url character varying(255),
    active boolean,
    basic_menu jsonb,
    custom_menu jsonb,
    language_packs jsonb,
    scrap_calc_type integer,
    valid_from timestamp with time zone NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: enterprises_id_enterprise_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.enterprises_id_enterprise_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enterprises_id_enterprise_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.enterprises_id_enterprise_seq OWNED BY public.enterprises.id_enterprise;


--
-- Name: equipment_downtime_reason; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_downtime_reason (
    id_equipment integer NOT NULL,
    id_reason bigint NOT NULL,
    active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: equipment_events_source_seq_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.equipment_events_source_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: equipment_events_source_seq_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.equipment_events_source_seq_seq OWNED BY public.equipment_events.source_seq;


--
-- Name: equipment_events_cpac_shadow; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_events_cpac_shadow (
    id_equipment integer NOT NULL,
    ts_event timestamp with time zone NOT NULL,
    status integer,
    id_equipment_event bigint NOT NULL,
    txt_downtime_notes character varying,
    idle character varying,
    idle_processed boolean,
    forced_creation_system boolean,
    fault integer,
    fault_processed boolean,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    planned_downtime boolean,
    ts_end timestamp with time zone,
    duration integer,
    id_enterprise integer,
    desc_category character varying,
    desc_subcategory character varying,
    cd_category_client integer,
    cd_subcategory_client integer,
    last_update timestamp with time zone,
    ignore_cost boolean,
    ingested_at timestamp with time zone DEFAULT now(),
    source_seq bigint DEFAULT nextval('public.equipment_events_source_seq_seq'::regclass)
);


--
-- Name: equipment_events_cpac_shadow_id_equipment_event_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.equipment_events_cpac_shadow ALTER COLUMN id_equipment_event ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.equipment_events_cpac_shadow_id_equipment_event_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: equipment_events_id_equipment_event_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.equipment_events ALTER COLUMN id_equipment_event ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.equipment_events_id_equipment_event_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: equipment_events_low_speed; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_events_low_speed (
    id_equipment integer,
    ts_event timestamp with time zone,
    status integer,
    id_equipment_event bigint,
    txt_downtime_notes character varying,
    idle character varying,
    idle_processed boolean,
    forced_creation_system boolean,
    fault integer,
    fault_processed boolean,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    planned_downtime boolean,
    ts_end timestamp with time zone,
    duration integer,
    id_enterprise integer,
    desc_category character varying,
    desc_subcategory character varying,
    speed real,
    ideal_production_speed integer
);


--
-- Name: equipment_events_man; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_events_man (
    id_equipment integer,
    ts_event timestamp with time zone,
    status integer,
    id_equipment_event integer NOT NULL,
    txt_downtime_notes text,
    idle character varying,
    idle_processed boolean,
    forced_creation_system boolean,
    fault integer,
    fault_processed boolean,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    planned_downtime boolean,
    ts_end timestamp with time zone,
    duration integer,
    id_enterprise integer,
    desc_category character varying,
    desc_subcategory character varying,
    cd_category_client integer,
    cd_subcategory_client integer,
    last_update timestamp with time zone DEFAULT now(),
    ignore_cost boolean
);


--
-- Name: equipment_events_man_id_equipment_event_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.equipment_events_man ALTER COLUMN id_equipment_event ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.equipment_events_man_id_equipment_event_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: equipment_events_raw; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_events_raw (
    id_equipment integer NOT NULL,
    ts_event timestamp with time zone NOT NULL,
    status integer,
    txt_downtime_notes character varying,
    idle character varying,
    idle_processed boolean,
    forced_creation_system boolean,
    fault integer,
    fault_processed boolean,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    planned_downtime boolean,
    ts_end timestamp with time zone,
    duration integer,
    id_enterprise integer,
    desc_category character varying,
    desc_subcategory character varying,
    cd_category_client integer,
    cd_subcategory_client integer,
    last_update timestamp with time zone,
    ignore_cost boolean,
    ingested_at timestamp with time zone DEFAULT now(),
    source_seq bigint DEFAULT nextval('public.equipment_events_source_seq_seq'::regclass) NOT NULL
);


--
-- Name: equipment_live_day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_live_day (
    id_equipment integer NOT NULL,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    speed real,
    target real,
    begin_time date,
    end_time date,
    idle_time integer,
    elapsed_time integer,
    idle_blocked integer,
    idle_starved integer,
    running_time integer,
    stopped_time integer,
    available_time integer,
    planned_downtime integer,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real,
    last_30_days jsonb,
    gross_production_exec_mode real,
    net_production_exec_mode real,
    scrap_exec_mode real,
    last_updated timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: equipment_live_hour; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_live_hour (
    id_equipment integer NOT NULL,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    speed real,
    target real,
    begin_time timestamp(0) with time zone,
    end_time timestamp(0) with time zone,
    idle_time integer,
    elapsed_time integer,
    idle_blocked integer,
    idle_starved integer,
    running_time integer,
    stopped_time integer,
    available_time integer,
    planned_downtime integer,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real,
    last_24_hours jsonb,
    gross_production_exec_mode real,
    net_production_exec_mode real,
    scrap_exec_mode real,
    last_updated timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: equipment_live_job; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_live_job (
    id_equipment integer NOT NULL,
    setup_begin_time timestamp with time zone,
    setup_end_time timestamp with time zone,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    speed real,
    target real,
    begin_time timestamp(0) with time zone,
    end_time timestamp(0) with time zone,
    idle_time integer DEFAULT 0,
    elapsed_time integer DEFAULT 0,
    idle_blocked integer DEFAULT 0,
    idle_starved integer DEFAULT 0,
    running_time integer DEFAULT 0,
    stopped_time integer DEFAULT 0,
    available_time integer DEFAULT 0,
    planned_downtime integer DEFAULT 0,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real,
    id_order character varying,
    id_production_order integer,
    nm_client character varying,
    nm_product character varying,
    nm_product_family character varying,
    setup_speed real,
    gross_production_exec_mode real,
    net_production_exec_mode real,
    scrap_exec_mode real,
    current_expected_time integer DEFAULT 0,
    production_programmed bigint,
    production_ordered bigint,
    setup_target_duration bigint,
    cd_setup character varying,
    last_setup_duration bigint,
    last_updated timestamp with time zone DEFAULT now()
);


--
-- Name: equipment_live_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_live_metrics (
    id_enterprise integer,
    id_site integer,
    id_area integer,
    id_equipment integer NOT NULL,
    state integer,
    speed numeric(12,4),
    updated_at timestamp with time zone DEFAULT now(),
    status character varying,
    downtime_category character varying,
    downtime_subcategory character varying,
    status_time integer DEFAULT 0,
    production_record_shifts integer DEFAULT 0,
    nm_equipment character varying,
    nm_area character varying,
    nm_site character varying,
    status_24h text[],
    ideal_speed character varying,
    change_over_perc_stops_24h double precision DEFAULT 0,
    planned_perc_stops_24h double precision DEFAULT 0,
    unplanned_perc_stops_24h double precision DEFAULT 0,
    last_updated timestamp with time zone DEFAULT now()
);


--
-- Name: equipment_live_month; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_live_month (
    id_equipment integer NOT NULL,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    speed real,
    target real,
    begin_time timestamp(0) with time zone,
    end_time timestamp(0) with time zone,
    idle_time bigint,
    elapsed_time bigint,
    idle_blocked bigint,
    idle_starved bigint,
    running_time bigint,
    stopped_time bigint,
    available_time bigint,
    planned_downtime bigint,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real,
    gross_production_exec_mode real,
    net_production_exec_mode real,
    scrap_exec_mode real,
    last_updated timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: equipment_live_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_live_shift (
    id_equipment integer NOT NULL,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    speed real,
    target real,
    begin_time timestamp(0) with time zone,
    end_time timestamp(0) with time zone,
    idle_time integer,
    elapsed_time integer,
    idle_blocked integer,
    idle_starved integer,
    running_time integer,
    stopped_time integer,
    available_time integer,
    planned_downtime integer,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real,
    id_shift integer,
    id_shift_hour integer,
    duration integer,
    previous_shift integer,
    next_shift integer,
    previous_shift_hour integer,
    next_shift_hour integer,
    prev1_oee real,
    prev1_oee_a real,
    prev1_oee_p real,
    prev1_oee_q real,
    prev1_gross_production real,
    prev1_net_production real,
    prev1_scrap real,
    prev1_speed real,
    prev1_target real,
    prev1_begin_time timestamp(0) with time zone,
    prev1_end_time timestamp(0) with time zone,
    prev1_id_shift integer,
    prev1_id_shift_hour integer,
    prev1_duration integer,
    prev2_oee real,
    prev2_oee_a real,
    prev2_oee_p real,
    prev2_oee_q real,
    prev2_gross_production real,
    prev2_net_production real,
    prev2_scrap real,
    prev2_speed real,
    prev2_target real,
    prev2_begin_time timestamp(0) with time zone,
    prev2_end_time timestamp(0) with time zone,
    prev2_id_shift integer,
    prev2_id_shift_hour integer,
    prev2_duration integer,
    prev3_oee real,
    prev3_oee_a real,
    prev3_oee_p real,
    prev3_oee_q real,
    prev3_gross_production real,
    prev3_net_production real,
    prev3_scrap real,
    prev3_speed real,
    prev3_target real,
    prev3_begin_time timestamp(0) with time zone,
    prev3_end_time timestamp(0) with time zone,
    prev3_id_shift integer,
    prev3_id_shift_hour integer,
    prev3_duration integer,
    gross_production_exec_mode real,
    net_production_exec_mode real,
    scrap_exec_mode real,
    prev2_shift_name character varying,
    prev1_shift_name character varying,
    prev3_shift_name character varying,
    shift_name character varying,
    unplanned_downtime integer,
    change_over_duration integer,
    change_over_duration_perc double precision,
    planned_duration_perc double precision,
    unplanned_duration_perc double precision,
    id_team integer,
    last_updated timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: equipment_live_week; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_live_week (
    id_equipment integer NOT NULL,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    speed real,
    target real,
    begin_time timestamp(0) with time zone,
    end_time timestamp(0) with time zone,
    idle_time bigint,
    elapsed_time bigint,
    idle_blocked bigint,
    idle_starved bigint,
    running_time bigint,
    stopped_time bigint,
    available_time bigint,
    planned_downtime bigint,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real,
    gross_production_exec_mode real,
    net_production_exec_mode real,
    scrap_exec_mode real,
    last_updated timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: equipment_oee_daily; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_oee_daily (
    id_equipment integer DEFAULT 0 NOT NULL,
    ts_value date NOT NULL,
    oee real DEFAULT 0,
    recalc_needed boolean DEFAULT false,
    oee_p real DEFAULT 0,
    oee_a real DEFAULT 0,
    oee_q real DEFAULT 0,
    available_time integer DEFAULT 0,
    running_time integer DEFAULT 0,
    stopped_time integer DEFAULT 0,
    planned_downtime integer DEFAULT 0,
    ideal_production double precision DEFAULT 0,
    idle_time integer DEFAULT 0,
    idle_starved integer DEFAULT 0,
    idle_blocked integer DEFAULT 0,
    target double precision DEFAULT 0,
    gross real DEFAULT 0,
    net real DEFAULT 0,
    downtime integer DEFAULT 0,
    changeover_time integer DEFAULT 0,
    scrap real DEFAULT 0,
    speed real DEFAULT 0,
    target_customized boolean DEFAULT false,
    proportional_target real DEFAULT 0,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone,
    CONSTRAINT equipment_runtime_1day_oee_bounds CHECK ((((oee >= (0)::double precision) AND (oee <= (1)::double precision)) AND ((oee_a >= (0)::double precision) AND (oee_a <= (1)::double precision)) AND ((oee_p >= (0)::double precision) AND (oee_p <= (1)::double precision)) AND ((oee_q >= (0)::double precision) AND (oee_q <= (1)::double precision))))
)
WITH (autovacuum_vacuum_threshold='100', autovacuum_vacuum_scale_factor='0.05', autovacuum_analyze_threshold='100', autovacuum_analyze_scale_factor='0.05', fillfactor='85');


--
-- Name: equipment_oee_monthly; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_oee_monthly (
    id_equipment integer DEFAULT 0 NOT NULL,
    ts_value date NOT NULL,
    oee real DEFAULT 0,
    recalc_needed boolean DEFAULT false,
    oee_p real DEFAULT 0,
    oee_a real DEFAULT 0,
    oee_q real DEFAULT 0,
    available_time bigint DEFAULT 0,
    running_time bigint DEFAULT 0,
    stopped_time bigint DEFAULT 0,
    planned_downtime bigint DEFAULT 0,
    ideal_production double precision DEFAULT 0,
    idle_time bigint DEFAULT 0,
    idle_starved bigint DEFAULT 0,
    idle_blocked bigint DEFAULT 0,
    target double precision DEFAULT 0,
    gross real DEFAULT 0,
    net real DEFAULT 0,
    downtime bigint DEFAULT 0,
    changeover_time bigint DEFAULT 0,
    scrap real DEFAULT 0,
    speed real DEFAULT 0,
    proportional_target double precision DEFAULT 0,
    target_customized boolean DEFAULT false,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
);


--
-- Name: equipment_oee_shift_monthly; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_oee_shift_monthly (
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


--
-- Name: equipment_oee_shift_weekly; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_oee_shift_weekly (
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


--
-- Name: equipment_oee_weekly; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_oee_weekly (
    id_equipment integer DEFAULT 0 NOT NULL,
    ts_value date NOT NULL,
    oee real DEFAULT 0,
    recalc_needed boolean DEFAULT false,
    oee_p real DEFAULT 0,
    oee_a real DEFAULT 0,
    oee_q real DEFAULT 0,
    available_time bigint DEFAULT 0,
    running_time bigint DEFAULT 0,
    stopped_time bigint DEFAULT 0,
    planned_downtime bigint DEFAULT 0,
    ideal_production double precision DEFAULT 0,
    idle_time bigint DEFAULT 0,
    idle_starved bigint DEFAULT 0,
    idle_blocked bigint DEFAULT 0,
    target double precision DEFAULT 0,
    gross real DEFAULT 0,
    net real DEFAULT 0,
    downtime bigint DEFAULT 0,
    changeover_time bigint DEFAULT 0,
    scrap real DEFAULT 0,
    speed real DEFAULT 0,
    proportional_target double precision DEFAULT 0,
    target_customized boolean DEFAULT false,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
);


--
-- Name: equipment_scrap_reason; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_scrap_reason (
    id_equipment integer NOT NULL,
    id_reason bigint NOT NULL,
    active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: equipment_validation_shift_id_validation_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.equipment_validation_shift_id_validation_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: equipment_validation_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_validation_shift (
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


--
-- Name: equipment_values_id_equipment_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.equipment_values_id_equipment_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: equipment_values_id_equipment_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.equipment_values_id_equipment_seq OWNED BY public.equipment_values.id_equipment;


--
-- Name: equipment_values_source_seq_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.equipment_values_source_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: equipment_values_source_seq_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.equipment_values_source_seq_seq OWNED BY public.equipment_values.source_seq;


--
-- Name: equipment_values_raw; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_values_raw (
    id_equipment integer DEFAULT nextval('public.equipment_values_id_equipment_seq'::regclass) NOT NULL,
    ts_value timestamp with time zone NOT NULL,
    id_enterprise integer,
    id_site integer,
    id_area integer,
    net_production_incr real,
    gross_production_incr real,
    scrap_incr real,
    speed real,
    id_order character varying(255),
    conversion_factor real,
    number_cavities integer,
    faults jsonb,
    analogs jsonb,
    signal_quality integer,
    net_production_val real,
    gross_production_val real,
    scrap_val real,
    id_shift integer,
    id_team integer,
    id_shift_hour integer,
    box_code character varying(255),
    transaction_code character varying(255),
    state integer,
    mode integer,
    id_production_order integer,
    ts_value_production date,
    id_equipment_line_infeed integer,
    id_equipment_line_outfeed integer,
    net_production_incr_quality integer,
    gross_production_incr_quality integer,
    scrap_incr_quality integer,
    speed_quality integer,
    id_order_quality character varying(255),
    conversion_factor_quality integer,
    number_cavities_quality integer,
    net_production_val_quality integer,
    gross_production_val_quality integer,
    scrap_val_quality integer,
    id_shift_quality integer,
    state_quality integer,
    mode_quality integer,
    id_production_order_quality integer,
    ts_value_production_quality date,
    id_equipment_line_connected integer,
    position_in_equipment_line integer,
    is_equipment_line_infeed integer,
    is_equipment_line_outfeed integer,
    process_scrap_incr real,
    process_scrap_val real,
    process_scrap_incr_quality integer,
    process_scrap_val_quality integer,
    tp_equipment integer,
    sub_mode character varying(255),
    ideal_production_speed integer,
    check_number bigint,
    ingested_at timestamp with time zone DEFAULT now(),
    source_seq bigint DEFAULT nextval('public.equipment_values_source_seq_seq'::regclass) NOT NULL
);


--
-- Name: equipments_history_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.equipments_history_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: equipments_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipments_history (
    history_id bigint DEFAULT nextval('public.equipments_history_history_id_seq'::regclass) NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    id_equipment integer NOT NULL,
    cd_equipment character varying(255),
    nm_equipment character varying(255),
    "position" integer,
    tp_equipment integer,
    id_area integer,
    id_site integer,
    id_enterprise integer,
    id_parentequipment integer,
    stop_threshold_time integer,
    production_speed integer,
    alerts jsonb,
    performance_alert_threshold real,
    id_equipment_type integer,
    minimum_performance_threshold real,
    require_downtime_reason boolean,
    sector_equipment_infeed integer,
    sector_equipment_outfeed integer,
    status_type integer,
    id_counter_status integer,
    id_equipment_state_status integer,
    id_equipment_state_idle integer,
    id_equipment_state_starved integer,
    id_equipment_state_blocked integer,
    id_equipment_status_mirror integer,
    id_packed_counter integer,
    cd_sector character varying(255),
    id_equipment_state_fault integer,
    downtime_reasons jsonb,
    minimum_ideal_performance_threshold real,
    custom jsonb,
    scrap_reasons jsonb,
    ideal_speed integer,
    overview_events_type integer,
    overview_events_filter_by_idle character varying(255),
    flexible_position boolean,
    event_should_be_displayed boolean,
    overview_version jsonb,
    use_label_net_production boolean,
    state_change_threshold_time integer,
    lead_machine integer,
    speed_calculated_by_packiot boolean,
    event_generated_by_packiot boolean,
    conversion_factor real,
    net_production_type integer,
    id_plc integer,
    active boolean NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: equipments_id_equipment_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.equipments_id_equipment_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: equipments_id_equipment_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.equipments_id_equipment_seq OWNED BY public.equipments.id_equipment;


--
-- Name: function_execution_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.function_execution_log (
    ts_value timestamp with time zone,
    function_name text
);


--
-- Name: h_events_timeline; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline (
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    id_equipment integer,
    id_enterprise integer,
    txt_downtime_notes character varying,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    packml_topic character varying,
    event_type text
);


--
-- Name: h_events_timeline_full; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline_full (
    event_type integer,
    ts_timeline timestamp with time zone,
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    id_equipment integer,
    id_enterprise integer,
    txt_downtime_notes character varying,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    status integer,
    id_order character varying,
    nm_client character varying
);


--
-- Name: h_piot_production_orders_with_runtimes_table2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_orders_with_runtimes_table2 (
    id_enterprise integer,
    status integer,
    id_production_order bigint,
    id_order integer,
    nm_client character varying,
    nm_product character varying,
    production_ordered bigint,
    gross_production double precision,
    net_production double precision,
    nm_equipment character varying,
    id_area integer,
    id_site integer,
    ts_start timestamp with time zone,
    production_final bigint,
    ts_end timestamp with time zone,
    id_equipment integer,
    runtimes json
);


--
-- Name: hist_production_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hist_production_orders (
    id_production_order bigint NOT NULL,
    id_enterprise integer NOT NULL,
    id_site integer NOT NULL,
    id_area integer NOT NULL,
    id_equipment integer NOT NULL,
    id_product integer,
    id_client integer,
    status integer DEFAULT 1 NOT NULL,
    production_programmed bigint NOT NULL,
    production_ordered bigint,
    id_order integer NOT NULL,
    id_user_operator integer,
    id_equipment_executed integer,
    production_real bigint,
    production_final bigint,
    ts_start timestamp with time zone,
    ts_end timestamp with time zone,
    equipment_setup jsonb,
    oee_processed boolean DEFAULT false NOT NULL,
    oee_quality real,
    oee_performance real,
    oee_availability real,
    oee real,
    available_time integer,
    running_time integer,
    stopped_time integer,
    planned_downtime integer,
    ideal_production integer,
    qt_stops integer,
    erp_processed boolean DEFAULT false NOT NULL,
    gross_production double precision,
    ts_creation timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    ts_start_tz timestamp with time zone,
    ts_end_tz timestamp with time zone,
    txt_production_order_notes character varying(255),
    txt_production_order_description character varying(255),
    conversion_factor real DEFAULT '1'::real,
    net_production double precision,
    speed real,
    ideal_production_speed integer,
    id_order_text character varying(255),
    custom_field jsonb,
    recalc_needed boolean DEFAULT true NOT NULL,
    last_update timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    nm_production_order character varying,
    multiplier double precision,
    id_label bigint,
    CONSTRAINT production_orders_speed_check CHECK (((ideal_production_speed IS NULL) OR (ideal_production_speed > 0))),
    CONSTRAINT production_orders_ts_start_ts_end CHECK ((((ts_start < ts_end) AND (status = ANY (ARRAY[3, 4]))) OR ((status = 1) AND (ts_start IS NULL)) OR ((status = 1) AND (ts_end IS NULL)) OR ((status = 2) AND (ts_start IS NOT NULL))))
);


--
-- Name: hist_production_orders_id_production_order_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.hist_production_orders_id_production_order_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: hist_production_orders_id_production_order_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.hist_production_orders_id_production_order_seq OWNED BY public.hist_production_orders.id_production_order;


--
-- Name: hist_production_orders_runtime; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hist_production_orders_runtime (
    id_production_order integer,
    runtime_timerange tstzrange,
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
    id_production_orders_runtime bigint,
    id_equipment integer,
    id_production_order_runtime bigint,
    net_production double precision,
    gross_production double precision,
    downtime integer,
    changeover_time integer,
    speed real,
    last_update timestamp with time zone,
    multiplier double precision
);


--
-- Name: idempotency_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.idempotency_keys (
    idempotency_key text NOT NULL,
    response_status integer NOT NULL,
    response_body jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: insights_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.insights_logs (
    id_insight bigint,
    ts_event timestamp with time zone,
    id_enterprise bigint,
    id_equipment bigint,
    id_site bigint,
    message text,
    warn_type bigint,
    module_number bigint,
    open boolean
);


--
-- Name: knex_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knex_migrations (
    id integer NOT NULL,
    name character varying(255),
    batch integer,
    migration_time timestamp with time zone
);


--
-- Name: knex_migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knex_migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knex_migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knex_migrations_id_seq OWNED BY public.knex_migrations.id;


--
-- Name: knex_migrations_lock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.knex_migrations_lock (
    index integer NOT NULL,
    is_locked integer
);


--
-- Name: knex_migrations_lock_index_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.knex_migrations_lock_index_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: knex_migrations_lock_index_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.knex_migrations_lock_index_seq OWNED BY public.knex_migrations_lock.index;


--
-- Name: label_formats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.label_formats (
    id_enterprise integer NOT NULL,
    label_key text NOT NULL,
    archetype text NOT NULL,
    order_field text,
    qty_field text,
    workcenter_field text,
    date_field text,
    time_field text,
    tz text,
    bucket interval,
    CONSTRAINT label_formats_archetype_check CHECK ((archetype = ANY (ARRAY['delivery'::text, 'counter'::text])))
);


--
-- Name: labels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.labels (
    id_label bigint NOT NULL,
    id_enterprise bigint NOT NULL,
    id_equipment bigint NOT NULL,
    name character varying(255) NOT NULL,
    template text
);


--
-- Name: labels_id_label_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.labels_id_label_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: labels_id_label_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.labels_id_label_seq OWNED BY public.labels.id_label;


--
-- Name: language_packs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.language_packs (
    language_tag character varying NOT NULL,
    language_pack_desktop jsonb,
    language_pack_mobile jsonb,
    id_language_pack integer,
    language_pack_operator jsonb,
    language_pack_overview jsonb,
    language_pack_operator40 jsonb
);


--
-- Name: mirror_replay_cursor; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mirror_replay_cursor (
    source text NOT NULL,
    last_log_id bigint NOT NULL,
    last_run_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mirror_replay_dlq; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mirror_replay_dlq (
    id bigint NOT NULL,
    source text NOT NULL,
    source_log_id bigint NOT NULL,
    category text,
    subcategory text,
    payload jsonb,
    error text NOT NULL,
    retry_attempts integer DEFAULT 0 NOT NULL,
    last_retry_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mirror_replay_dlq_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mirror_replay_dlq_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mirror_replay_dlq_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mirror_replay_dlq_id_seq OWNED BY public.mirror_replay_dlq.id;


--
-- Name: monitoramento_execucao_functions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.monitoramento_execucao_functions AS
 SELECT function_execution_log.ts_value,
    function_execution_log.function_name
   FROM public.function_execution_log;


--
-- Name: oee_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oee_targets (
    id_site integer,
    vl_day double precision DEFAULT 0,
    vl_week double precision DEFAULT 0,
    vl_month double precision DEFAULT 0,
    id_equipment integer,
    id_enterprise integer DEFAULT 0 NOT NULL,
    id_area integer,
    vl_shift double precision DEFAULT 0,
    id bigint NOT NULL
);


--
-- Name: oee_targets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.oee_targets ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.oee_targets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: packml_register; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.packml_register (
    id_packml_register integer NOT NULL,
    packml_topic character varying(255),
    "timestamp" timestamp with time zone,
    value character varying,
    signal_quality smallint,
    ts_quality timestamp with time zone,
    mqtt_topic character varying,
    sparkplug_json jsonb,
    id_equipment integer,
    id_site integer,
    id_area integer,
    id_enterprise integer,
    id_infeedcounter integer,
    id_outfeedcounter integer,
    active boolean,
    attributed boolean,
    id_unit integer,
    line_unit_seq character varying,
    device_nm character varying,
    device_key text
);


--
-- Name: COLUMN packml_register.id_infeedcounter; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.packml_register.id_infeedcounter IS 'WIRE COUNT-INDEX (PLC count-tag position), NOT an id_equipment FK. On LINE rows (tp_equipment=3) this is the line INFEED meter index; read LIVE by edge-transformer line_param30700_seed.go to seed Parameter30700 for Phase-9 line aggregation (gated PHASE9_LINE_AGG_ENABLED). Single-consumer since the counterroles resolver was removed (ADR-0047 counterroles-removal note, 2026-08-26). Do NOT reuse for role FKs and do NOT read as id_equipment — that mislabel caused the 2026-08-26 counterroles/Phase-9 collision. Add dedicated id_*_equipment columns if you ever need role FKs.';


--
-- Name: COLUMN packml_register.id_outfeedcounter; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.packml_register.id_outfeedcounter IS 'WIRE COUNT-INDEX — line OUTFEED meter index. Read LIVE by Phase-9 (see id_infeedcounter comment). NOT an id_equipment FK.';


--
-- Name: COLUMN packml_register.id_unit; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.packml_register.id_unit IS 'Nullable metering-unit FK: = id_equipment for machines (tp_equipment=1), NULL for lines/sectors. NOT a duplicate of id_equipment — its NULL-ness marks non-machine rows and is load-bearing for the decoder/refdata joins. Do NOT rename to id_equipment.';


--
-- Name: packml_register_id_packml_register_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.packml_register_id_packml_register_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: packml_register_id_packml_register_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.packml_register_id_packml_register_seq OWNED BY public.packml_register.id_packml_register;


--
-- Name: pages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pages (
    id_page integer NOT NULL,
    list_of_enterprises integer[] DEFAULT '{}'::integer[] NOT NULL,
    page_info jsonb,
    default_piot_page boolean DEFAULT false
);


--
-- Name: po_box_counter; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.po_box_counter (
    id_production_order bigint NOT NULL,
    id_enterprise integer NOT NULL,
    last_label_seq bigint DEFAULT 0 NOT NULL,
    total_qty bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: product_families; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_families (
    id_product_family bigint NOT NULL,
    nm_product_family character varying,
    id_enterprise integer
);


--
-- Name: product_families_id_product_family_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_families_id_product_family_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_families_id_product_family_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_families_id_product_family_seq OWNED BY public.product_families.id_product_family;


--
-- Name: production_data_sync_enterprise_06_indice_geral_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.production_data_sync_enterprise_06_indice_geral_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: production_data_sync_enterprise_06; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.production_data_sync_enterprise_06 (
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


--
-- Name: production_information; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.production_information AS
 SELECT e.id_enterprise,
    ucs.id_equipment,
    (ucs.gross_production)::double precision AS total_produced,
    (ucs.scrap)::double precision AS total_rejected,
    ucs.oee,
    ucs.begin_time AS shift_start,
    ucs.end_time AS shift_end
   FROM (public.equipment_live_shift ucs
     JOIN public.equipments e ON ((e.id_equipment = ucs.id_equipment)));


--
-- Name: VIEW production_information; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.production_information IS 'F3 cutover fixup H2: per-equipment live current-shift metrics for edge-api GET /api/production-orders/current. Reconstructed from endpoint/DTO contract (no F1 original existed). Source: uns_equipment_current_shift + equipments.';


--
-- Name: production_orders_id_production_order_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.production_orders ALTER COLUMN id_production_order ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.production_orders_id_production_order_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: production_orders_runtime_id_production_order_runtime_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.production_orders_runtime ALTER COLUMN id_production_order_runtime ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.production_orders_runtime_id_production_order_runtime_seq
    START WITH 1000000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: production_orders_runtime_id_production_orders_runtime_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.production_orders_runtime ALTER COLUMN id_production_orders_runtime ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.production_orders_runtime_id_production_orders_runtime_seq
    START WITH 1000000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id_product bigint NOT NULL,
    nm_product character varying(255) NOT NULL,
    id_product_family integer NOT NULL,
    txt_product character varying,
    id_enterprise integer NOT NULL,
    scrap_target integer DEFAULT 15,
    speed integer,
    equipment_setup jsonb,
    cd_product character varying
);


--
-- Name: products_id_product_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.products_id_product_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: products_id_product_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.products_id_product_seq OWNED BY public.products.id_product;


--
-- Name: sample_boxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sample_boxes (
    id_box bigint NOT NULL,
    box_order_number integer,
    should_increment boolean DEFAULT false,
    ts_value timestamp with time zone NOT NULL,
    increment integer,
    id_site bigint NOT NULL,
    id_production_order bigint NOT NULL,
    id_order bigint NOT NULL,
    id_equipment bigint NOT NULL,
    id_enterprise bigint NOT NULL,
    id_area bigint
);


--
-- Name: sample_boxes_id_box_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sample_boxes_id_box_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sample_boxes_id_box_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sample_boxes_id_box_seq OWNED BY public.sample_boxes.id_box;


--
-- Name: scanned_boxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scanned_boxes (
    id bigint NOT NULL,
    box_order_number integer,
    increment integer,
    id_enterprise integer,
    id_equipment integer,
    id_order integer,
    id_production_order integer,
    id_site integer,
    ts_value timestamp with time zone,
    id_area integer,
    id_box bigint
);


--
-- Name: scanned_boxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.scanned_boxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: scanned_boxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.scanned_boxes_id_seq OWNED BY public.scanned_boxes.id;


--
-- Name: scrap_reason; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scrap_reason (
    id bigint NOT NULL,
    id_enterprise integer NOT NULL,
    code character varying NOT NULL,
    label character varying,
    label_i18n jsonb,
    category character varying,
    parent_id bigint,
    reason_level smallint DEFAULT 1 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: scrap_reason_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.scrap_reason ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.scrap_reason_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shift_hours_id_shift_hour_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.shift_hours_id_shift_hour_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shift_hours_id_shift_hour_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.shift_hours_id_shift_hour_seq OWNED BY public.shift_hours.id_shift_hour;


--
-- Name: shifts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shifts (
    id_shift integer NOT NULL,
    cd_shift character varying,
    id_enterprise integer,
    id_site integer,
    id_area integer,
    id_equipment integer,
    begin_time time without time zone,
    end_time time without time zone,
    sequence_position integer
);


--
-- Name: shifts_exception_period; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shifts_exception_period (
    id_equipment integer DEFAULT 0 NOT NULL,
    id_enterprise integer,
    ts_begin timestamp(0) with time zone NOT NULL,
    ts_end timestamp(0) with time zone NOT NULL
);


--
-- Name: shifts_id_shift_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.shifts_id_shift_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shifts_id_shift_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.shifts_id_shift_seq OWNED BY public.shifts.id_shift;


--
-- Name: site_live_day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_live_day (
    id_site integer NOT NULL,
    oee real,
    oee_a real,
    oee_p real,
    oee_q real,
    gross_production real,
    net_production real,
    scrap real,
    target real,
    begin_time date,
    end_time date,
    idle_time integer,
    elapsed_time integer,
    idle_blocked integer,
    idle_starved integer,
    running_time integer,
    stopped_time integer,
    available_time integer,
    planned_downtime integer,
    ideal_production real,
    proportional_target real,
    proportional_ideal_production real
);


--
-- Name: site_oee_daily; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_oee_daily (
    ts_value date NOT NULL,
    id_site integer NOT NULL,
    oee real,
    recalc_needed boolean DEFAULT true,
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
    target double precision,
    gross real,
    net real,
    downtime integer,
    changeover_time integer,
    scrap real,
    speed real,
    proportional_target double precision,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
);


--
-- Name: site_oee_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_oee_shift (
    ts_value timestamp(0) with time zone NOT NULL,
    id_site integer NOT NULL,
    oee real,
    recalc_needed boolean DEFAULT true,
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
    id_shift integer,
    id_shift_hour integer,
    id_team integer,
    duration integer,
    ts_range tstzrange,
    gross real,
    net real,
    downtime integer,
    changeover_time integer,
    target double precision,
    ts_end timestamp with time zone,
    ts_value_production date,
    target_customized boolean DEFAULT false,
    proportional_target real,
    scrap real,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone,
    CONSTRAINT chk_site_runtime_shift_ts_order CHECK ((ts_value <= ts_end)),
    CONSTRAINT site_runtime_shift_oee_bounds CHECK ((((oee >= (0)::double precision) AND (oee <= (1)::double precision)) AND ((oee_a >= (0)::double precision) AND (oee_a <= (1)::double precision)) AND ((oee_p >= (0)::double precision) AND (oee_p <= (1)::double precision)) AND ((oee_q >= (0)::double precision) AND (oee_q <= (1)::double precision))))
);


--
-- Name: sites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sites (
    id_site integer NOT NULL,
    nm_site character varying(255),
    id_enterprise integer NOT NULL,
    week_begin integer NOT NULL,
    day_begin integer NOT NULL,
    timezone character varying(255) NOT NULL,
    language_tag character varying(255),
    week_size integer NOT NULL,
    email_alert_users jsonb,
    active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: sites_history_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sites_history_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sites_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sites_history (
    history_id bigint DEFAULT nextval('public.sites_history_history_id_seq'::regclass) NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    id_site integer NOT NULL,
    nm_site character varying(255),
    id_enterprise integer NOT NULL,
    week_begin integer NOT NULL,
    day_begin integer NOT NULL,
    timezone character varying(255) NOT NULL,
    language_tag character varying(255),
    week_size integer NOT NULL,
    email_alert_users jsonb,
    active boolean NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone
);


--
-- Name: sites_id_site_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sites_id_site_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sites_id_site_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sites_id_site_seq OWNED BY public.sites.id_site;


--
-- Name: teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teams (
    id_team bigint NOT NULL,
    cd_team character varying,
    id_equipment integer,
    id_area integer,
    id_site integer,
    id_enterprise integer,
    sequence_position integer DEFAULT 0
);


--
-- Name: teams_id_team_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.teams_id_team_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: teams_id_team_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.teams_id_team_seq OWNED BY public.teams.id_team;


--
-- Name: tenant_translations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_translations (
    id_enterprise integer NOT NULL,
    language_tag text NOT NULL,
    app text NOT NULL,
    namespace text DEFAULT 'common'::text NOT NULL,
    key text NOT NULL,
    value text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by text
);


--
-- Name: translations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.translations (
    language_tag text NOT NULL,
    app text NOT NULL,
    namespace text DEFAULT 'common'::text NOT NULL,
    key text NOT NULL,
    value text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by text
);


--
-- Name: twin_backfill_po_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.twin_backfill_po_log (
    id_production_order bigint NOT NULL,
    id_order bigint,
    id_equipment integer,
    status integer,
    ts_start timestamp with time zone,
    ts_end timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now(),
    batch text
);


--
-- Name: user_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_logs (
    id_user_logs bigint NOT NULL,
    ts_event timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    id_enterprise integer NOT NULL,
    id_site integer,
    id_area integer,
    id_equipment integer,
    nm_user character varying(255),
    cd_user integer,
    category character varying(255),
    subcategory character varying(255),
    description text,
    ts_log timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    ip character varying(255),
    payload jsonb
);


--
-- Name: user_logs_id_user_logs_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_logs_id_user_logs_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_logs_id_user_logs_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_logs_id_user_logs_seq OWNED BY public.user_logs.id_user_logs;


--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_roles (
    id_user_role integer NOT NULL,
    nm_user_role character varying,
    id_enterprise integer,
    permissions jsonb,
    super_user boolean
);


--
-- Name: user_screen_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_screen_config (
    id_enterprise integer DEFAULT 0 NOT NULL,
    id_user text NOT NULL,
    screen text NOT NULL,
    config jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id_user integer NOT NULL,
    user_email character varying,
    user_name character varying,
    id_enterprise integer,
    id_user_firebase character varying,
    phone_number character varying,
    user_roles integer,
    timezone character varying,
    languages character varying,
    user_menu jsonb DEFAULT '{"custom_user": []}'::jsonb,
    internal_user boolean,
    active boolean DEFAULT true,
    id_user_cognito text
);


--
-- Name: users_id_user_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_user_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_user_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_user_seq OWNED BY public.users.id_user;


--
-- Name: v_13_overview_partial_scrap_rate; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.v_13_overview_partial_scrap_rate (
    cd_equipment character varying,
    id_enterprise integer,
    id_site integer,
    id_equipment integer,
    gross double precision,
    net double precision,
    scrap double precision,
    scrap_rate numeric
);


--
-- Name: v_13_overview_takt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.v_13_overview_takt (
    id_equipment integer,
    id_enterprise integer,
    id_site integer,
    avg_speed integer
);


--
-- Name: v_13_site_deb_sap_report; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_13_site_deb_sap_report AS
 WITH dias AS (
         SELECT (generate_series(((timezone('Europe/Budapest'::text, now()))::date - '3 days'::interval), ((timezone('Europe/Budapest'::text, now()))::date)::timestamp without time zone, '1 day'::interval))::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(((timezone('Europe/Budapest'::text, equipment_oee_shift.ts_value))::time without time zone)::interval, 'HH24:MI'::text), '-', to_char(((timezone('Europe/Budapest'::text, equipment_oee_shift.ts_end))::time without time zone)::interval, 'HH24:MI'::text)) AS turno_hrs,
            equipment_oee_shift.ts_value AS shift_start_time,
            equipment_oee_shift.id_equipment,
            equipment_oee_shift.cd_shift,
            equipment_oee_shift.id_shift,
            equipment_oee_shift.ts_value_production,
            equipment_oee_shift.ts_value AS tz_value,
                CASE
                    WHEN (equipment_oee_shift.ts_end > now()) THEN now()
                    ELSE equipment_oee_shift.ts_end
                END AS tz_end
           FROM public.equipment_oee_shift,
            start_counting_day scd
          WHERE ((equipment_oee_shift.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 29)))) AND (equipment_oee_shift.ts_value_production >= scd.start_day) AND (equipment_oee_shift.ts_value < now()))
          ORDER BY equipment_oee_shift.id_equipment, equipment_oee_shift.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN (eq.tp_equipment = 3) THEN e.id_parentequipment
                    WHEN (eq.tp_equipment = 2) THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM public.equipments e,
            public.equipments eq
          WHERE ((e.id_parentequipment = eq.id_equipment) AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            public.equipments eq
          WHERE (e.id_equipment_line = eq.id_equipment)
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM public.equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM public.equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.id_site = 29) AND (equipments_1.tp_equipment = 3))))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min.id_equipment,
            agg_equipment_values_1min.id_site,
            agg_equipment_values_1min.id_area,
            agg_equipment_values_1min.ts_value AS tz_value,
            agg_equipment_values_1min.gross_production_incr,
            agg_equipment_values_1min.net_production_incr
           FROM public.agg_equipment_values_1min,
            start_counting_day scd
          WHERE ((agg_equipment_values_1min.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))) AND (agg_equipment_values_1min.ts_value >= (now() - '3 days'::interval)) AND (agg_equipment_values_1min.ts_value >= scd.start_day) AND (agg_equipment_values_1min.id_enterprise = 13) AND (agg_equipment_values_1min.id_site = 29))
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
                    WHEN (upper(porun.runtime_timerange) IS NULL) THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM public.production_orders_runtime porun,
            public.production_orders po
          WHERE ((porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 29)))) AND (po.id_equipment = porun.id_equipment) AND (po.id_enterprise = 13) AND (po.id_production_order = porun.id_production_order) AND (lower(porun.runtime_timerange) >= (now() - '90 days'::interval)))
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), negative_labels AS (
         SELECT l.tz_value,
            l.id_equipment,
            l.label_job,
            l.label_amount,
            po.job_end,
                CASE
                    WHEN (po.job_end IS NULL) THEN (0)::bigint
                    ELSE (date_part('epoch'::text, (l.tz_value - po.job_end)))::bigint
                END AS diff_s
           FROM (labels_extract l
             LEFT JOIN prod_orders po ON (((l.label_job)::integer = po.id_order)))
        ), labels AS (
         SELECT DISTINCT negative_labels.tz_value,
            negative_labels.id_equipment,
            negative_labels.label_job,
            negative_labels.label_amount
           FROM negative_labels
          WHERE (negative_labels.diff_s <= 10800)
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
                    WHEN (po_sequence_basis.id_order = po_sequence_basis.id_order_sec) THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST((upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval), lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), ((now())::timestamp without time zone)::timestamp with time zone)
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
                    WHEN (shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone)) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN (shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone)) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM (turnos shi
             LEFT JOIN prod_orders po ON (((po.job_start < shi.tz_end) AND (po.job_end >= shi.tz_value) AND (po.id_equipment = shi.id_equipment))))
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
           FROM (base_for_splits bfs
             LEFT JOIN presscount pc ON (((pc.tz_value >= bfs.inicio) AND (pc.tz_value <= bfs.fim) AND (pc.id_equipment = bfs.id_equipment) AND (pc.id_site = bfs.id_site) AND (pc.id_area = bfs.id_area))))
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM public.equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM public.equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.tp_equipment = 3) AND (equipments_1.id_site = 29))))
        ), category_level AS (
         SELECT top_level.id_equipment,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text) AS description,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) ->> 'code'::text))::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text)
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
                    WHEN (dc."position" = 24) THEN 1
                    WHEN (dc."position" = 2) THEN 2
                    WHEN (dc."position" = ANY (ARRAY[5, 8])) THEN 3
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) >= (COALESCE(e.stop_threshold_time, 0))::double precision)) THEN 4
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) < COALESCE((e.stop_threshold_time)::double precision, 'Infinity'::double precision))) THEN 5
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM ((public.equipment_events ee
             LEFT JOIN public.equipments e ON (((ee.id_equipment = e.id_equipment) AND (e.id_enterprise = 13) AND (e.tp_equipment = 3) AND (e.id_site = 29))))
             LEFT JOIN downtime_codes dc ON ((((ee.cd_category)::text = dc.description) AND (ee.id_equipment = dc.id_equipment))))
          WHERE ((ee.status = 10) AND (ee.ts_event >= (now() - '15 days'::interval)) AND (tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange((now() - '3 days'::interval), now())) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))))
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
          WHERE (COALESCE(sb.nextts, now()) >= ( SELECT (start_counting_day.start_day - '1 day'::interval)
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
           FROM (stops_raw st
             LEFT JOIN base_for_splits bfs ON (((tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim)) AND (bfs.id_equipment = st.id_equipment))))
          ORDER BY st.id_equipment, GREATEST(st.tz_event, bfs.inicio), bfs.inicio
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
                    WHEN (st.downtimereason = 0) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 1) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 2) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 3) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 4) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 5) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_5
           FROM (base_for_splits stpf
             LEFT JOIN split_bfs st ON (((st.tz_event < stpf.fim) AND (st.tz_end > stpf.inicio) AND (stpf.id_equipment = st.id_equipment))))
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
           FROM (stops_final f
             LEFT JOIN press_quantity pqty ON (((f.id_equipment = pqty.id_equipment) AND ((f.cd_shift)::text = (pqty.cd_shift)::text) AND (f.ts_value_production = pqty.ts_value_production) AND (f.id_order = pqty.id_order) AND (f.inicio = pqty.inicio) AND (f.fim = pqty.fim) AND (f.id_shift = pqty.id_shift) AND (f.turno_hrs = pqty.turno_hrs))))
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN (sum(l.label_amount) IS NULL) THEN (0)::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM (base_for_splits bfs
             LEFT JOIN labels l ON (((l.tz_value >= bfs.inicio) AND (l.tz_value <= (bfs.fim - '00:00:01'::interval)) AND (l.id_equipment = bfs.id_equipment))))
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            (date_part('epoch'::text, (f.fim - f.inicio)))::bigint AS shift_duration,
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
           FROM (final_and_press f
             LEFT JOIN packed_quantity pack ON (((f.inicio = pack.inicio) AND (f.fim = pack.fim) AND (f.id_equipment = pack.id_equipment) AND (f.id_order = (pack.label_job)::bigint))))
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            (pack.label_job)::bigint AS id_order,
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
           FROM (final_and_press f
             JOIN packed_quantity pack ON (((f.inicio = pack.inicio) AND (f.fim = pack.fim) AND (f.id_equipment = pack.id_equipment) AND (pack.net_label IS NOT NULL) AND (pack.net_label <> (0)::double precision) AND (f.id_order <> (pack.label_job)::bigint))))
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            (ppf.shift_duration)::double precision AS shift_duration,
            (((ppf.shift_duration)::double precision / (3600)::double precision))::numeric(10,2) AS shift_duration_s,
            (((((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_5) / (3600)::double precision))::numeric(10,2) AS total_dt_s,
            ((((ppf.shift_duration)::double precision - (((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_5)) / (3600)::double precision))::numeric(10,2) AS running_s,
            (((ppf.dt_0 + ppf.dt_5) / (3600)::double precision))::numeric(10,2) AS dt_0,
            ((ppf.dt_1 / (3600)::double precision))::numeric(10,2) AS dt_1,
            ((ppf.dt_2 / (3600)::double precision))::numeric(10,2) AS dt_2,
            ((ppf.dt_3 / (3600)::double precision))::numeric(10,2) AS dt_3,
            ((ppf.dt_4 / (3600)::double precision))::numeric(10,2) AS dt_4,
            COALESCE((ppf.press_count)::double precision, (0)::double precision) AS prss_qty,
            COALESCE((ppf.net_sensor)::double precision, (0)::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, (0)::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            timezone('Europe/Budapest'::text, ppf.shift_start_time) AS shift_start_time,
            timezone('Europe/Budapest'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM (((press_packed_final ppf
             LEFT JOIN public.equipments eq ON (((ppf.id_equipment = eq.id_equipment) AND (eq.id_enterprise = 13) AND (eq.tp_equipment = 3))))
             LEFT JOIN public.shifts shi ON (((shi.id_shift = ppf.id_shift) AND (shi.id_enterprise = 13))))
             LEFT JOIN po_sequence pos ON (((ppf.id_order = pos.id_order) AND (tstzrange(ppf.shift_start_time, (ppf.shift_start_time + '12:00:00'::interval)) && pos.runtime_timerange_new))))
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
  WHERE (shift_report.day >= (timezone('Europe/Budapest'::text, now()) - '2 days'::interval));


--
-- Name: v_entities_per_user_role; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_entities_per_user_role AS
 WITH lines AS (
         SELECT ur.id_enterprise,
            e_1.id_site,
            e_1.id_area,
            ur.id_equipment,
            ur.id_user_role,
            ur.nm_user_role,
            ur.permissions,
            e_1.cd_equipment,
            e_1.nm_equipment,
            e_1."position",
            e_1.tp_equipment,
            e_1.id_parentequipment,
            e_1.stop_threshold_time,
            e_1.production_speed,
            e_1.alerts,
            e_1.performance_alert_threshold,
            e_1.id_equipment_type,
            e_1.minimum_performance_threshold,
            e_1.require_downtime_reason,
            e_1.sector_equipment_infeed,
            e_1.sector_equipment_outfeed,
            e_1.status_type,
            e_1.id_counter_status,
            e_1.id_equipment_state_status,
            e_1.id_equipment_state_idle,
            e_1.id_equipment_state_starved,
            e_1.id_equipment_state_blocked,
            e_1.id_equipment_status_mirror,
            e_1.id_packed_counter,
            e_1.cd_sector,
            e_1.id_equipment_state_fault,
            e_1.downtime_reasons,
            e_1.minimum_ideal_performance_threshold,
            e_1.custom,
            e_1.scrap_reasons,
            e_1.ideal_speed,
            e_1.overview_events_type,
            e_1.overview_events_filter_by_idle,
            e_1.flexible_position,
            e_1.event_should_be_displayed,
            e_1.overview_version,
            areas.nm_area,
            areas.id_infeedcounter,
            areas.id_outfeedcounter,
            areas.id_rejectscounter,
            areas.week_begin,
            areas.day_begin,
            areas.week_size,
            sites.nm_site,
            sites.week_begin,
            sites.day_begin,
            sites.timezone,
            sites.language_tag,
            sites.week_size,
            sites.email_alert_users,
            enterprises.nm_enterprise,
            enterprises.api_key,
            enterprises.week_begin,
            enterprises.day_begin,
            enterprises.week_size,
            enterprises.timezone,
            enterprises.logo_url,
            enterprises.active,
            enterprises.basic_menu,
            enterprises.custom_menu,
            enterprises.language_packs
           FROM ((((( SELECT user_roles.id_user_role,
                    user_roles.nm_user_role,
                    user_roles.id_enterprise,
                    user_roles.permissions,
                    (jsonb_array_elements(((user_roles.permissions -> 'desktop'::text) -> 'line'::text)))::integer AS id_equipment
                   FROM public.user_roles) ur
             JOIN public.equipments e_1 USING (id_enterprise, id_equipment))
             JOIN public.areas USING (id_enterprise, id_area, id_site))
             JOIN public.sites USING (id_enterprise, id_site))
             JOIN public.enterprises USING (id_enterprise))
        ), shifts AS (
         SELECT DISTINCT array_agg(jsonb_build_object('cd_shift', s7.cd_shift, 'id_shift', s7.id_shift)) AS shifts,
            s7.id_user_role
           FROM ( SELECT DISTINCT sh_1.cd_shift,
                    sh_1.id_shift,
                    ev.id_user_role
                   FROM (lines ev(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                     JOIN public.shift_hours sh_1 ON (((ev.id_enterprise = sh_1.id_enterprise) AND (ev.id_enterprise = sh_1.id_enterprise) AND
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.shift_hours ssh
                              WHERE (ssh.id_equipment = ev.id_equipment))) THEN (ev.id_equipment = sh_1.id_equipment)
                            WHEN (EXISTS ( SELECT 1
                               FROM public.shift_hours ssh
                              WHERE (ssh.id_area = ev.id_area))) THEN ((ev.id_area = sh_1.id_area) AND (sh_1.id_equipment IS NULL))
                            WHEN (EXISTS ( SELECT 1
                               FROM public.shift_hours ssh
                              WHERE (ssh.id_site = ev.id_site))) THEN ((ev.id_site = sh_1.id_site) AND (sh_1.id_area IS NULL))
                            WHEN (EXISTS ( SELECT 1
                               FROM public.shift_hours ssh
                              WHERE (ssh.id_enterprise = ev.id_enterprise))) THEN ((ev.id_enterprise = sh_1.id_enterprise) AND (sh_1.id_site IS NULL))
                            ELSE false
                        END)))) s7
          GROUP BY s7.id_user_role
        ), teams AS (
         SELECT DISTINCT array_agg(jsonb_build_object('cd_team', s8.cd_team, 'id_team', s8.id_team)) AS teams,
            s8.id_user_role
           FROM ( SELECT DISTINCT t.cd_team,
                    t.id_team,
                    l.id_user_role
                   FROM (lines l(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                     JOIN public.teams t USING (id_enterprise, id_equipment))) s8
          GROUP BY s8.id_user_role
        ), sectors AS (
         SELECT DISTINCT array_agg(jsonb_build_object('nm_equipment', s9.nm_equipment, 'id_area', s9.id_area, 'id_site', s9.id_site, 'id_equipment', s9.id_equipment, 'id_parentequipment', s9.id_parentequipment, 'require_downtime_reason', s9.require_downtime_reason) ORDER BY s9.id_area, (regexp_replace((s9.nm_equipment)::text, '[^\d]'::text, ''::text, 'g'::text))::integer) AS sectors,
            s9.id_user_role
           FROM ( SELECT DISTINCT s_1.nm_equipment,
                    s_1.id_equipment,
                    l.id_area,
                    l.id_site,
                    s_1.id_parentequipment,
                    s_1.require_downtime_reason,
                    l.id_user_role
                   FROM (lines l(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                     JOIN public.equipments s_1 ON (((s_1.id_enterprise = l.id_enterprise) AND (l.id_equipment = s_1.id_parentequipment) AND (s_1.tp_equipment = 2))))) s9
          GROUP BY s9.id_user_role, s9.require_downtime_reason
        )
 SELECT s.id_enterprise,
    s.id_user_role,
    s.nm_user_role,
    s.enterprise,
    s.sites,
    a.areas,
    e.equipments,
    sec.sectors,
    sh.shifts,
    tm.teams
   FROM (((((( SELECT s1.nm_user_role,
            s1.enterprise,
            array_agg(s1.sites) AS sites,
            s1.id_enterprise,
            s1.id_user_role
           FROM ( SELECT jsonb_build_object('id_site', lines.id_site, 'nm_site', lines.nm_site, 'timezone', lines.timezone) AS sites,
                    jsonb_build_object('id_enterprise', lines.id_enterprise, 'nm_enterprise', lines.nm_enterprise) AS enterprise,
                    lines.id_enterprise,
                    lines.id_user_role,
                    lines.nm_user_role
                   FROM lines lines(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                  GROUP BY lines.id_site, lines.id_enterprise, lines.nm_site, lines.nm_enterprise, lines.id_user_role, lines.nm_user_role, lines.timezone) s1
          GROUP BY s1.id_enterprise, s1.enterprise, s1.id_user_role, s1.nm_user_role) s
     JOIN ( SELECT array_agg(s0.areas) AS areas,
            s0.id_enterprise,
            s0.id_user_role
           FROM ( SELECT jsonb_build_object('id_area', lines.id_area, 'nm_area', lines.nm_area, 'id_site', lines.id_site) AS areas,
                    lines.id_enterprise,
                    lines.id_user_role
                   FROM lines lines(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                  GROUP BY lines.id_area, lines.id_enterprise, lines.nm_area, lines.id_user_role, lines.id_site
                  ORDER BY (concat("left"((lines.nm_area)::text, 1), to_char(COALESCE((NULLIF(regexp_replace((lines.nm_area)::text, '[^\d]'::text, ''::text, 'g'::text), ''::text))::integer, 0), 'FM0000'::text))), lines.nm_area) s0
          GROUP BY s0.id_enterprise, s0.id_user_role) a USING (id_enterprise, id_user_role))
     JOIN ( SELECT array_agg(s1.equipments) AS equipments,
            s1.id_enterprise,
            s1.id_user_role
           FROM ( SELECT jsonb_build_object('id_equipment', lines.id_equipment, 'nm_equipment', lines.nm_equipment, 'id_area', lines.id_area, 'id_site', lines.id_site, 'require_downtime_reason', lines.require_downtime_reason) AS equipments,
                    lines.id_enterprise,
                    lines.id_user_role
                   FROM lines lines(id_enterprise, id_site, id_area, id_equipment, id_user_role, nm_user_role, permissions, cd_equipment, nm_equipment, "position", tp_equipment, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons, ideal_speed, overview_events_type, overview_events_filter_by_idle, flexible_position, event_should_be_displayed, overview_version, nm_area, id_infeedcounter, id_outfeedcounter, id_rejectscounter, week_begin, day_begin, week_size, nm_site, week_begin_1, day_begin_1, timezone, language_tag, week_size_1, email_alert_users, nm_enterprise, api_key, week_begin_2, day_begin_2, week_size_2, timezone_1, logo_url, active, basic_menu, custom_menu, language_packs)
                  GROUP BY lines.id_equipment, lines.id_enterprise, lines.nm_equipment, lines.id_user_role, lines.id_site, lines.id_area, lines.require_downtime_reason
                  ORDER BY lines.id_area, (concat("left"((lines.nm_equipment)::text, 1), to_char(COALESCE((NULLIF(regexp_replace((lines.nm_equipment)::text, '[^\d]'::text, ''::text, 'g'::text), ''::text))::integer, 0), 'FM0000'::text))), lines.nm_equipment) s1
          GROUP BY s1.id_enterprise, s1.id_user_role) e USING (id_enterprise, id_user_role))
     LEFT JOIN shifts sh USING (id_user_role))
     LEFT JOIN teams tm USING (id_user_role))
     LEFT JOIN sectors sec USING (id_user_role));


--
-- Name: v_operator_entities_2; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_operator_entities_2 AS
 SELECT e.id_enterprise,
    jsonb_build_array(jsonb_build_object('id', e.id_enterprise, 'name', e.nm_enterprise)) AS enterprise,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', s.id_site, 'name', s.nm_site)) AS jsonb_agg
           FROM public.sites s
          WHERE (s.id_enterprise = e.id_enterprise)), '[]'::jsonb) AS sites,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', a.id_area, 'name', a.nm_area)) AS jsonb_agg
           FROM (public.areas a
             JOIN public.sites s ON ((s.id_site = a.id_site)))
          WHERE (s.id_enterprise = e.id_enterprise)), '[]'::jsonb) AS areas,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment, 'position', eq."position")) AS jsonb_agg
           FROM public.equipments eq
          WHERE ((eq.id_enterprise = e.id_enterprise) AND (eq.tp_equipment = 3))), '[]'::jsonb) AS lines,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment, 'position', eq."position")) AS jsonb_agg
           FROM public.equipments eq
          WHERE ((eq.id_enterprise = e.id_enterprise) AND (eq.tp_equipment = 2))), '[]'::jsonb) AS sectors,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'name', eq.nm_equipment, 'position', eq."position")) AS jsonb_agg
           FROM public.equipments eq
          WHERE ((eq.id_enterprise = e.id_enterprise) AND (eq.tp_equipment = 1))), '[]'::jsonb) AS machines
   FROM public.enterprises e;


--
-- Name: v_entities_per_user_role_operator; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_entities_per_user_role_operator AS
 SELECT v.id_enterprise,
    v.id_enterprise AS id_user_role,
    e.nm_enterprise AS nm_user_role,
    v.enterprise,
    COALESCE(( SELECT jsonb_agg((s.elem || jsonb_build_object('packml_topic', d.topic)) ORDER BY ((s.elem ->> 'id'::text))::integer) AS jsonb_agg
           FROM (jsonb_array_elements(v.sites) s(elem)
             LEFT JOIN LATERAL ( SELECT ((split_part((pr.packml_topic)::text, '/'::text, 1) || '/'::text) || split_part((pr.packml_topic)::text, '/'::text, 2)) AS topic
                   FROM (public.equipments eq
                     JOIN public.packml_register pr ON (((pr.id_equipment = eq.id_equipment) AND (pr.active = true))))
                  WHERE ((eq.id_site = ((s.elem ->> 'id'::text))::integer) AND (pr.packml_topic IS NOT NULL))
                 LIMIT 1) d ON (true))), v.sites) AS sites,
    COALESCE(( SELECT jsonb_agg((a.elem || jsonb_build_object('id_site', d.id_site, 'packml_topic', d.topic)) ORDER BY ((a.elem ->> 'id'::text))::integer) AS jsonb_agg
           FROM (jsonb_array_elements(v.areas) a(elem)
             LEFT JOIN LATERAL ( SELECT eq.id_site,
                    ((((split_part((pr.packml_topic)::text, '/'::text, 1) || '/'::text) || split_part((pr.packml_topic)::text, '/'::text, 2)) || '/'::text) || split_part((pr.packml_topic)::text, '/'::text, 3)) AS topic
                   FROM (public.equipments eq
                     JOIN public.packml_register pr ON (((pr.id_equipment = eq.id_equipment) AND (pr.active = true))))
                  WHERE ((eq.id_area = ((a.elem ->> 'id'::text))::integer) AND (pr.packml_topic IS NOT NULL))
                 LIMIT 1) d ON (true))), v.areas) AS areas,
    COALESCE(( SELECT jsonb_agg((l.elem || jsonb_build_object('id_area', eq.id_area, 'id_site', eq.id_site, 'packml_topic', pr.packml_topic)) ORDER BY ((l.elem ->> 'id'::text))::integer) AS jsonb_agg
           FROM ((jsonb_array_elements(v.lines) l(elem)
             LEFT JOIN public.equipments eq ON ((eq.id_equipment = ((l.elem ->> 'id'::text))::integer)))
             LEFT JOIN public.packml_register pr ON (((pr.id_equipment = eq.id_equipment) AND (pr.active = true))))), v.lines) AS lines,
    v.sectors,
    v.machines,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', eq.id_equipment, 'id_equipment', eq.id_equipment, 'name', eq.nm_equipment, 'packml_topic', pr.packml_topic) ORDER BY eq.id_equipment) AS jsonb_agg
           FROM (public.equipments eq
             LEFT JOIN public.packml_register pr ON (((pr.id_equipment = eq.id_equipment) AND (pr.active = true))))
          WHERE ((eq.id_enterprise = v.id_enterprise) AND (eq.tp_equipment = 1))), '[]'::jsonb) AS equipments,
    '[]'::jsonb AS shifts,
    '[]'::jsonb AS teams
   FROM (public.v_operator_entities_2 v
     JOIN public.enterprises e ON ((e.id_enterprise = v.id_enterprise)));


--
-- Name: v_events_2; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_events_2 AS
 SELECT 1 AS event_type,
    ee.ts_event AS ts_timeline,
    ee.ts_event,
    ee.ts_end,
    ee.duration,
    COALESCE(ppe.id_equipment, pe.id_equipment, e.id_equipment) AS id_equipment,
    COALESCE(ppe.nm_equipment, pe.nm_equipment, e.nm_equipment) AS nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    ee.txt_downtime_notes,
    ee.cd_machine,
    ee.cd_category,
    ee.cd_subcategory,
    ee.change_over,
    ee.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM (((((public.equipment_events ee
     JOIN public.equipments e ON ((ee.id_equipment = e.id_equipment)))
     LEFT JOIN public.equipments pe ON ((pe.id_equipment = e.id_parentequipment)))
     LEFT JOIN public.equipments ppe ON ((ppe.id_equipment = pe.id_parentequipment)))
     JOIN public.areas a ON ((e.id_area = a.id_area)))
     JOIN public.sites s ON ((e.id_site = s.id_site)))
  WHERE (((ee.duration >= COALESCE(e.stop_threshold_time, 0)) OR (ee.ts_end IS NULL)) AND (ee.status <> 6) AND (e.event_should_be_displayed = true))
UNION
 SELECT 2 AS event_type,
    eem.ts_event AS ts_timeline,
    eem.ts_event,
    eem.ts_end,
    (date_part('epoch'::text, (eem.ts_end - eem.ts_event)))::integer AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    eem.txt_downtime_notes,
    eem.cd_machine,
    eem.cd_category,
    eem.cd_subcategory,
    eem.change_over,
    eem.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM (((public.equipment_events_man eem
     JOIN public.equipments e ON ((eem.id_equipment_event = e.id_equipment)))
     JOIN public.areas a ON ((e.id_area = a.id_area)))
     JOIN public.sites s ON ((e.id_site = s.id_site)))
UNION
 SELECT 3 AS event_type,
    ee.ts_event AS ts_timeline,
    ee.ts_event,
    ee.ts_end,
    ee.duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    ee.txt_downtime_notes,
    ee.cd_machine,
    ee.cd_category,
    ee.cd_subcategory,
    ee.change_over,
    ee.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM (((public.equipment_events_low_speed ee
     JOIN public.equipments e ON ((ee.id_equipment = e.id_equipment)))
     JOIN public.areas a ON ((e.id_area = a.id_area)))
     JOIN public.sites s ON ((e.id_site = s.id_site)))
  WHERE (((ee.duration >= COALESCE(e.stop_threshold_time, 0)) OR (ee.ts_end IS NULL)) AND (ee.status <> 6) AND (e.event_should_be_displayed = true))
UNION
 SELECT 4 AS event_type,
    lower(ee.runtime_timerange) AS ts_timeline,
    lower(ee.runtime_timerange) AS ts_event,
    upper(ee.runtime_timerange) AS ts_end,
        CASE
            WHEN (upper(ee.runtime_timerange) IS NOT NULL) THEN (date_part('epoch'::text, (upper(ee.runtime_timerange) - lower(ee.runtime_timerange))))::integer
            ELSE NULL::integer
        END AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    COALESCE(po.id_order_text, (po.id_order)::character varying) AS id_order,
    c.nm_client
   FROM (((((public.production_orders_runtime ee
     JOIN public.equipments e ON ((ee.id_equipment = e.id_equipment)))
     JOIN public.production_orders po USING (id_production_order))
     JOIN public.areas a ON ((e.id_area = a.id_area)))
     JOIN public.sites s ON ((e.id_site = s.id_site)))
     LEFT JOIN public.clients c USING (id_client))
UNION
 SELECT 5 AS event_type,
    upper(ee.runtime_timerange) AS ts_timeline,
    lower(ee.runtime_timerange) AS ts_event,
    upper(ee.runtime_timerange) AS ts_end,
        CASE
            WHEN (upper(ee.runtime_timerange) IS NOT NULL) THEN (date_part('epoch'::text, (upper(ee.runtime_timerange) - lower(ee.runtime_timerange))))::integer
            ELSE NULL::integer
        END AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    COALESCE(po.id_order_text, (po.id_order)::character varying) AS id_order,
    c.nm_client
   FROM (((((public.production_orders_runtime ee
     JOIN public.equipments e ON ((ee.id_equipment = e.id_equipment)))
     JOIN public.areas a ON ((e.id_area = a.id_area)))
     JOIN public.sites s ON ((e.id_site = s.id_site)))
     JOIN public.production_orders po USING (id_production_order))
     LEFT JOIN public.clients c USING (id_client))
  WHERE (upper(ee.runtime_timerange) IS NOT NULL)
UNION
 SELECT 6 AS event_type,
    ee.ts_value AS ts_timeline,
    ee.ts_value AS ts_event,
    ee.ts_end,
    ee.duration,
    ee.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM (((public.equipment_oee_shift ee
     JOIN public.equipments e ON ((ee.id_equipment = e.id_equipment)))
     JOIN public.areas a ON ((e.id_area = a.id_area)))
     JOIN public.sites s ON ((e.id_site = s.id_site)))
  WHERE (ee.ts_value < now());


--
-- Name: v_menu_per_user_role; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_menu_per_user_role AS
 SELECT s3.id_enterprise,
    s3.id_user_role,
    array_agg(jsonb_build_object('menu_group', s3.menu_group, 'menu_items', s3.menu_items) ORDER BY s3.menu_group) AS menu
   FROM ( SELECT s2.id_enterprise,
            s2.id_user_role,
            s2.menu_group,
            array_agg(s2.menu_items ORDER BY s2.page_order, s2.page_name) AS menu_items
           FROM ( SELECT s1.id_enterprise,
                    s1.id_user_role,
                    p.menu_group,
                    p.page_name,
                    p.page_order,
                    (p.page_info || s1.screen) AS menu_items
                   FROM (( SELECT s0.id_enterprise,
                            s0.id_user_role,
                            s0.screen,
                            ((s0.screen -> 'code'::text))::integer AS id_page
                           FROM ( SELECT ur.id_enterprise,
                                    ur.id_user_role,
                                    jsonb_array_elements(((ur.permissions -> 'desktop'::text) -> 'screen'::text)) AS screen
                                   FROM public.user_roles ur) s0) s1
                     JOIN ( SELECT pages.id_page,
                            pages.list_of_enterprises,
                            pages.page_info,
                            pages.default_piot_page,
                            ((pages.page_info -> 'menu_group'::text))::integer AS menu_group,
                            ((pages.page_info ->> 'name'::text))::character varying AS page_name,
                            ((pages.page_info -> 'page_order'::text))::integer AS page_order
                           FROM public.pages) p USING (id_page))
                UNION
                 SELECT s0.id_enterprise,
                    s0.id_user_role,
                    3 AS menu_group,
                    s0.nm_equipment,
                    NULL::integer AS int4,
                    (s0.overview_configuration || jsonb_build_object('URL', concat('/overview/', (s0.overview_configuration ->> 'version'::text), '/', s0.id_equipment), 'name', s0.nm_equipment, 'id_equipment', s0.id_equipment)) AS menu_items
                   FROM ( SELECT e.id_enterprise,
                            ur.id_user_role,
                            e.id_equipment,
                            e.nm_equipment,
                            jsonb_array_elements(e.overview_version) AS overview_configuration
                           FROM (public.equipments e
                             JOIN ( SELECT user_roles.id_user_role,
                                    user_roles.id_enterprise,
                                    (jsonb_array_elements(((user_roles.permissions -> 'desktop'::text) -> 'line'::text)))::integer AS id_equipment
                                   FROM public.user_roles) ur USING (id_enterprise, id_equipment))) s0) s2
          GROUP BY s2.id_enterprise, s2.id_user_role, s2.menu_group) s3
  GROUP BY s3.id_enterprise, s3.id_user_role;


--
-- Name: v_operator_po_details_3; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_operator_po_details_3 AS
 SELECT base.id_production_order,
    base.id_equipment,
    base.id_enterprise,
    base.net_production,
    base.scrap,
    base.running_time,
    base.downtime,
    (base.net_production + base.scrap) AS gross
   FROM ( SELECT po.id_production_order,
            po.id_equipment,
            po.id_enterprise,
            po.ts_start,
            po.ts_end,
            COALESCE(NULLIF(sum(por.net_production), (0)::double precision), (( SELECT COALESCE(sum(ev.net_production_incr), (0)::real) AS "coalesce"
                   FROM public.equipment_values ev
                  WHERE ((ev.id_equipment = po.id_equipment) AND (po.ts_start IS NOT NULL) AND (ev.ts_value >= po.ts_start) AND ((po.ts_end IS NULL) OR (ev.ts_value <= po.ts_end)))))::double precision, (0)::double precision) AS net_production,
            COALESCE(NULLIF(sum((COALESCE(por.gross_production, (0)::double precision) - COALESCE(por.net_production, (0)::double precision))), (0)::double precision), (0)::double precision) AS scrap,
            (COALESCE(sum(EXTRACT(epoch FROM (COALESCE(upper(por.runtime_timerange), now()) - lower(por.runtime_timerange)))), (0)::numeric))::integer AS running_time,
            (COALESCE(( SELECT sum(
                        CASE
                            WHEN (ee.ts_end IS NULL) THEN GREATEST(0, (EXTRACT(epoch FROM (now() - ee.ts_event)))::integer)
                            ELSE COALESCE(ee.duration, 0)
                        END) AS sum
                   FROM public.equipment_events ee
                  WHERE ((ee.id_equipment = po.id_equipment) AND (po.ts_start IS NOT NULL) AND (ee.ts_event >= po.ts_start) AND ((po.ts_end IS NULL) OR (ee.ts_event <= po.ts_end)) AND (ee.status <> 6) AND (ee.forced_creation_system = false))), (0)::bigint))::integer AS downtime
           FROM (public.production_orders po
             LEFT JOIN public.production_orders_runtime por ON ((por.id_production_order = po.id_production_order)))
          WHERE (po.status = ANY (ARRAY[1, 2, 4]))
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, po.ts_start, po.ts_end) base;


--
-- Name: v_operator_po_list_setup_4; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_operator_po_list_setup_4 AS
 SELECT po.id_production_order,
    (po.id_production_order)::integer AS id_order,
    po.id_enterprise,
    po.id_equipment,
    po.status,
    COALESCE(po.production_programmed, (0)::bigint) AS production_programmed,
    po.ts_start,
    NULL::jsonb AS equipment_setup,
    (1.0)::double precision AS conversion_factor,
    NULL::jsonb AS custom_field,
    NULL::jsonb AS priority,
    pr.packml_topic AS topic,
    po.txt_production_order_notes AS nm_client,
    NULL::character varying AS nm_product_family,
    COALESCE(po.id_order_text, (('PO-'::text || (po.id_production_order)::text))::character varying) AS nm_product,
    NULL::character varying AS txt_product
   FROM (public.production_orders po
     LEFT JOIN LATERAL ( SELECT packml_register.packml_topic
           FROM public.packml_register
          WHERE ((packml_register.id_equipment = po.id_equipment) AND (packml_register.active = true))
         LIMIT 1) pr ON (true));


--
-- Name: v_piot_production_data_sync_cust6; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_piot_production_data_sync_cust6 AS
 SELECT pdse.indice_geral AS uniqueid,
    pdse.prev_indice_geral AS previousuniqueid,
    pdse.packiotid,
    pdse.site,
    pdse.line,
    pdse.shift,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.shiftstartdate)) AS shiftstartdate,
    (pdse.job)::integer AS job,
    pdse.item,
    (COALESCE(pdse.totalavailablehrsinmin, (0)::numeric))::numeric(10,2) AS totalavailablehrsinmin,
    (COALESCE(pdse.dtimehrsplannedinmin, (0)::numeric))::numeric(10,2) AS dtimehrsplannedinmin,
    (COALESCE(pdse.dtimehrsunplannedinmin, (0)::numeric))::numeric(10,2) AS dtimehrsunplannedinmin,
    (COALESCE(pdse.unplanneddt_proinmin, (0)::numeric))::numeric(10,2) AS unplanneddt_proinmin,
    (COALESCE(pdse.unplanneddt_resinmin, (0)::numeric))::numeric(10,2) AS unplanneddt_resinmin,
    (COALESCE(pdse.unplanneddt_mntinmin, (0)::numeric))::numeric(10,2) AS unplanneddt_mntinmin,
    (COALESCE(pdse.setuphoursinmin, (0)::numeric))::numeric(10,2) AS setuphoursinmin,
    (COALESCE(pdse.runhoursinmin, (0)::numeric))::numeric(10,2) AS runhoursinmin,
    (COALESCE(pdse.presscnt, (0)::bigint))::integer AS presscnt,
    (COALESCE(pdse.packcnt, (0)::bigint))::integer AS packcnt,
    pdse.jobstatus,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.jobstartdate)) AS jobstartdate,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.jobcompleteddate)) AS jobcompleteddate,
    pdse.final_trans_status AS transstatus,
        CASE
            WHEN (pdse.supervisorapproval IS TRUE) THEN 1
            ELSE 0
        END AS supervisorapproval,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.supervisorapproveddate)) AS supervisorapproveddate,
    (pdse.supervisornotes)::text AS supervisornotes,
    date_trunc('second'::text, pdse.real_update) AS last_update
   FROM public.production_data_sync_enterprise_06 pdse
  WHERE ((pdse.shiftstartdate >= (now() - '21 days'::interval)) AND ((pdse.final_trans_status)::text <> ALL (ARRAY[('H'::character varying)::text, ('D'::character varying)::text])) AND (pdse.shiftstartdate <= '2025-02-20 16:00:00+00'::timestamp with time zone))
UNION ALL
 SELECT pdse.indice_geral AS uniqueid,
    pdse.prev_indice_geral AS previousuniqueid,
    pdse.packiotid,
    pdse.site,
    pdse.line,
    pdse.shift,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.shiftstartdate)) AS shiftstartdate,
    (pdse.job)::integer AS job,
    pdse.item,
    (COALESCE(pdse.totalavailablehrsinmin, (0)::numeric))::numeric(10,2) AS totalavailablehrsinmin,
    (COALESCE(pdse.dtimehrsplannedinmin, (0)::numeric))::numeric(10,2) AS dtimehrsplannedinmin,
    (COALESCE(pdse.dtimehrsunplannedinmin, (0)::numeric))::numeric(10,2) AS dtimehrsunplannedinmin,
    (COALESCE(pdse.unplanneddt_proinmin, (0)::numeric))::numeric(10,2) AS unplanneddt_proinmin,
    (COALESCE(pdse.unplanneddt_resinmin, (0)::numeric))::numeric(10,2) AS unplanneddt_resinmin,
    (COALESCE(pdse.unplanneddt_mntinmin, (0)::numeric))::numeric(10,2) AS unplanneddt_mntinmin,
    (COALESCE(pdse.setuphoursinmin, (0)::numeric))::numeric(10,2) AS setuphoursinmin,
    (COALESCE(pdse.runhoursinmin, (0)::numeric))::numeric(10,2) AS runhoursinmin,
    (COALESCE(pdse.presscnt, (0)::bigint))::integer AS presscnt,
    (COALESCE(pdse.packcnt, (0)::bigint))::integer AS packcnt,
    pdse.jobstatus,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.jobstartdate)) AS jobstartdate,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.jobcompleteddate)) AS jobcompleteddate,
    pdse.final_trans_status AS transstatus,
        CASE
            WHEN (pdse.supervisorapproval IS TRUE) THEN 1
            ELSE 0
        END AS supervisorapproval,
    date_trunc('second'::text, timezone('America/Montreal'::text, pdse.supervisorapproveddate)) AS supervisorapproveddate,
    (pdse.supervisornotes)::text AS supervisornotes,
    date_trunc('second'::text, pdse.real_update) AS last_update
   FROM public.production_data_sync_enterprise_06 pdse
  WHERE ((pdse.shiftstartdate >= (now() - '365 days'::interval)) AND (pdse.shiftstartdate > '2025-02-20 16:00:00+00'::timestamp with time zone) AND (pdse.real_update >= (now() - '06:00:00'::interval)))
  ORDER BY 27 DESC;


--
-- Name: v_po_box_totals; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_po_box_totals AS
 SELECT box_scans.id_production_order,
    box_scans.id_enterprise,
    count(*) FILTER (WHERE (box_scans.scan_type = 'production'::text)) AS box_count,
    COALESCE(max(box_scans.label_seq) FILTER (WHERE (box_scans.scan_type = 'production'::text)), (0)::bigint) AS last_label_seq,
    COALESCE(sum(box_scans.qty) FILTER (WHERE box_scans.counts_toward_total), (0)::bigint) AS total_qty
   FROM public.box_scans
  GROUP BY box_scans.id_production_order, box_scans.id_enterprise;


--
-- Name: v_report_downtimes; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_report_downtimes AS
 SELECT po.id_order AS op,
    e.nm_equipment AS linha,
    shift.cd_shift AS turno,
    eventos.ts_event AS inicio,
    eventos.ts_end AS fim,
    eventos.duration AS duracao,
    eventos.cd_machine AS maquina,
    eventos.cd_category AS codigo_categoria,
    eventos.cd_subcategory AS codigo_subcategoria,
    eventos.desc_category AS descricao_categoria,
    eventos.desc_subcategory AS descricao_subcategoria,
    eventos.txt_downtime_notes AS anotacao,
    eventos.id_enterprise,
    shift.ts_value
   FROM ((((( SELECT equipment_events.id_equipment,
            equipment_events.ts_event,
            equipment_events.status,
            equipment_events.id_equipment_event,
            equipment_events.txt_downtime_notes,
            equipment_events.idle,
            equipment_events.idle_processed,
            equipment_events.forced_creation_system,
            equipment_events.fault,
            equipment_events.fault_processed,
            equipment_events.cd_machine,
            equipment_events.cd_category,
            equipment_events.cd_subcategory,
            equipment_events.change_over,
            equipment_events.planned_downtime,
            equipment_events.ts_end,
            equipment_events.duration,
            equipment_events.id_enterprise,
            equipment_events.desc_category,
            equipment_events.desc_subcategory,
            equipment_events.cd_category_client,
            equipment_events.cd_subcategory_client,
            equipment_events.last_update,
            equipment_events.ignore_cost
           FROM public.equipment_events
        UNION ALL
         SELECT equipment_events_man.id_equipment,
            equipment_events_man.ts_event,
            equipment_events_man.status,
            equipment_events_man.id_equipment_event,
            equipment_events_man.txt_downtime_notes,
            equipment_events_man.idle,
            equipment_events_man.idle_processed,
            equipment_events_man.forced_creation_system,
            equipment_events_man.fault,
            equipment_events_man.fault_processed,
            equipment_events_man.cd_machine,
            equipment_events_man.cd_category,
            equipment_events_man.cd_subcategory,
            equipment_events_man.change_over,
            equipment_events_man.planned_downtime,
            equipment_events_man.ts_end,
            equipment_events_man.duration,
            equipment_events_man.id_enterprise,
            equipment_events_man.desc_category,
            equipment_events_man.desc_subcategory,
            equipment_events_man.cd_category_client,
            equipment_events_man.cd_subcategory_client,
            equipment_events_man.last_update,
            equipment_events_man.ignore_cost
           FROM public.equipment_events_man) eventos
     JOIN public.equipment_oee_shift shift ON ((eventos.id_equipment = shift.id_equipment)))
     JOIN public.equipments e ON ((eventos.id_equipment = e.id_equipment)))
     LEFT JOIN public.production_orders_runtime por ON (((por.id_equipment = eventos.id_equipment) AND (por.runtime_timerange @> eventos.ts_event))))
     LEFT JOIN public.production_orders po ON ((po.id_production_order = por.id_production_order)))
  WHERE ((eventos.status = 10) AND (e.event_should_be_displayed = true) AND (eventos.ts_event >= lower(shift.ts_range)) AND (eventos.ts_event <= upper(shift.ts_range)) AND (eventos.duration >= COALESCE(e.stop_threshold_time, 0)));


--
-- Name: v_sap_report_data_sync_customer_13_deb; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_sap_report_data_sync_customer_13_deb AS
 WITH dias AS (
         SELECT (generate_series(((timezone('Europe/Zurich'::text, now()))::date - '4 days'::interval), ((timezone('Europe/Zurich'::text, now()))::date)::timestamp without time zone, '1 day'::interval))::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(((timezone('Europe/Zurich'::text, ers.ts_value))::time without time zone)::interval, 'HH24:MI'::text), '-', to_char(((timezone('Europe/Zurich'::text, ers.ts_end))::time without time zone)::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN (ers.ts_end > now()) THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM public.equipment_oee_shift ers,
            start_counting_day scd,
            public.shifts shi
          WHERE ((ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 29)))) AND (ers.ts_value_production >= scd.start_day) AND (ers.ts_value <= now()) AND (shi.id_shift = ers.id_shift))
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN (eq.tp_equipment = 3) THEN e.id_parentequipment
                    WHEN (eq.tp_equipment = 2) THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM public.equipments e,
            public.equipments eq
          WHERE ((e.id_parentequipment = eq.id_equipment) AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            public.equipments eq
          WHERE (e.id_equipment_line = eq.id_equipment)
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM public.equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM public.equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.id_site = 29) AND (equipments_1.tp_equipment = 3))))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min.id_equipment,
            agg_equipment_values_1min.id_site,
            agg_equipment_values_1min.id_area,
            agg_equipment_values_1min.ts_value AS tz_value,
            agg_equipment_values_1min.gross_production_incr,
            agg_equipment_values_1min.net_production_incr
           FROM public.agg_equipment_values_1min,
            start_counting_day scd
          WHERE ((agg_equipment_values_1min.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))) AND (agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval)) AND (agg_equipment_values_1min.ts_value >= scd.start_day) AND (agg_equipment_values_1min.id_enterprise = 13) AND (agg_equipment_values_1min.id_site = 29))
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN (upper(porun.runtime_timerange) IS NULL) THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM public.production_orders_runtime porun,
            public.production_orders po
          WHERE ((porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 29)))) AND (po.id_equipment = porun.id_equipment) AND (po.id_enterprise = 13) AND (po.id_production_order = porun.id_production_order) AND (lower(porun.runtime_timerange) >= (now() - '90 days'::interval)))
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
                    WHEN (po_sequence_basis.id_order = po_sequence_basis.id_order_sec) THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST((upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval), lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), ((now())::timestamp without time zone)::timestamp with time zone)
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
                    WHEN (shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone)) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN (shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone)) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM (turnos shi
             LEFT JOIN prod_orders po ON (((po.job_start < shi.tz_end) AND (po.job_end >= shi.tz_value) AND (po.id_equipment = shi.id_equipment))))
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
           FROM (base_for_splits bfs
             LEFT JOIN presscount pc ON (((pc.tz_value >= bfs.inicio) AND (pc.tz_value < bfs.fim) AND (pc.id_equipment = bfs.id_equipment) AND (pc.id_site = bfs.id_site) AND (pc.id_area = bfs.id_area))))
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM public.equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM public.equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.tp_equipment = 3) AND (equipments_1.id_site = 29))))
        ), category_level AS (
         SELECT top_level.id_equipment,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text) AS description,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) ->> 'code'::text))::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text)
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
                    WHEN (dc."position" = 24) THEN 1
                    WHEN (dc."position" = ANY (ARRAY[2, 9])) THEN 2
                    WHEN (dc."position" = ANY (ARRAY[5, 8])) THEN 3
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) >= (COALESCE(e.stop_threshold_time, 0))::double precision)) THEN 4
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) < COALESCE((e.stop_threshold_time)::double precision, 'Infinity'::double precision))) THEN 5
                    WHEN (dc."position" = 7) THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM ((public.equipment_events ee
             LEFT JOIN public.equipments e ON (((ee.id_equipment = e.id_equipment) AND (e.id_enterprise = 13) AND (e.tp_equipment = 3) AND (e.id_site = 29))))
             LEFT JOIN downtime_codes dc ON (((ee.cd_category)::text = dc.description)))
          WHERE ((ee.status = 10) AND (ee.ts_event >= (now() - '90 days'::interval)) AND (tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange((now() - '4 days'::interval), now())) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))))
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
          WHERE (COALESCE(sb.nextts, now()) >= ( SELECT (start_counting_day.start_day - '1 day'::interval)
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
           FROM (stops_raw st
             LEFT JOIN base_for_splits bfs ON (((tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim)) AND (bfs.id_equipment = st.id_equipment))))
          ORDER BY st.id_equipment, GREATEST(st.tz_event, bfs.inicio), bfs.inicio
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
                    WHEN (st.downtimereason = 0) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 1) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 2) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 3) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 4) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 5) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 6) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_6
           FROM (base_for_splits stpf
             LEFT JOIN split_bfs st ON (((st.tz_event < stpf.fim) AND (st.tz_end > stpf.inicio) AND (stpf.id_equipment = st.id_equipment))))
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
           FROM (stops_final f
             LEFT JOIN press_quantity pqty ON (((f.id_equipment = pqty.id_equipment) AND ((f.cd_shift)::text = (pqty.cd_shift)::text) AND (f.ts_value_production = pqty.ts_value_production) AND (f.id_order = pqty.id_order) AND (f.inicio = pqty.inicio) AND (f.fim = pqty.fim) AND (f.id_shift = pqty.id_shift) AND (f.turno_hrs = pqty.turno_hrs))))
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN (sum(l.label_amount) IS NULL) THEN (0)::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM (base_for_splits bfs
             LEFT JOIN labels l ON (((l.tz_value >= bfs.inicio) AND (l.tz_value < (bfs.fim - '00:00:01'::interval)) AND (l.id_equipment = bfs.id_equipment))))
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            (date_part('epoch'::text, (f.fim - f.inicio)))::bigint AS shift_duration,
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
           FROM (final_and_press f
             LEFT JOIN packed_quantity pack ON (((f.inicio = pack.inicio) AND (f.fim = pack.fim) AND (f.id_equipment = pack.id_equipment) AND (f.id_order = (pack.label_job)::bigint))))
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            (pack.label_job)::bigint AS id_order,
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
           FROM (final_and_press f
             JOIN packed_quantity pack ON (((f.inicio = pack.inicio) AND (f.fim = pack.fim) AND (f.id_equipment = pack.id_equipment) AND (pack.net_label IS NOT NULL) AND (pack.net_label <> (0)::double precision) AND (f.id_order <> (pack.label_job)::bigint))))
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            (ppf.shift_duration)::double precision AS shift_duration,
            (((ppf.shift_duration)::double precision / (3600)::double precision))::numeric(10,2) AS shift_duration_s,
            (((((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_6) / (3600)::double precision))::numeric(10,2) AS total_dt_s,
            ((((ppf.shift_duration)::double precision - (((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_6)) / (3600)::double precision))::numeric(10,2) AS running_s,
            (((ppf.dt_0 + ppf.dt_4) / (3600)::double precision))::numeric(10,2) AS dt_0,
            ((ppf.dt_1 / (3600)::double precision))::numeric(10,2) AS dt_1,
            ((ppf.dt_2 / (3600)::double precision))::numeric(10,2) AS dt_2,
            ((ppf.dt_3 / (3600)::double precision))::numeric(10,2) AS dt_3,
            ((ppf.dt_6 / (3600)::double precision))::numeric(10,2) AS dt_4,
            COALESCE((ppf.press_count)::double precision, (0)::double precision) AS prss_qty,
            COALESCE((ppf.net_sensor)::double precision, (0)::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, (0)::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM (((press_packed_final ppf
             LEFT JOIN public.equipments eq ON (((ppf.id_equipment = eq.id_equipment) AND (eq.id_enterprise = 13) AND (eq.tp_equipment = 3))))
             LEFT JOIN public.shifts shi ON (((shi.id_shift = ppf.id_shift) AND (shi.id_enterprise = 13))))
             LEFT JOIN po_sequence pos ON (((ppf.id_order = pos.id_order) AND (tstzrange(ppf.shift_start_time, (ppf.shift_start_time + '12:00:00'::interval)) && pos.runtime_timerange_new))))
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM public.equipment_boxes_cust_13 ebc
          WHERE ((ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))) AND (ebc.ts_value >= (now() - '4 days'::interval)))
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
           FROM ((turnos t
             LEFT JOIN labels_data ld ON (((t.id_equipment = ld.id_equipment) AND (ld.ts_value >= t.tz_value) AND (ld.ts_value < t.tz_end))))
             LEFT JOIN public.equipments eq ON ((eq.id_equipment = t.id_equipment)))
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
           FROM (final_jobs fj
             LEFT JOIN final_labels fl ON ((((fl.cd_equipment)::text = (fj.linie)::text) AND ((fl.id_order)::integer = fj.auftrag) AND (fl.ts_value_production = fj.tag) AND ((fl.cd_shift)::text = (fj.shicht)::text))))
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
           FROM (final_labels fl
             LEFT JOIN final1 f1 ON ((((fl.cd_equipment)::text = (f1.linie)::text) AND ((fl.id_order)::integer = f1.auftrag) AND (fl.ts_value_production = f1.tag) AND ((fl.cd_shift)::text = (f1.shicht)::text))))
          WHERE ((fl.sum_labels IS NOT NULL) AND (f1.id_order IS NULL))
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
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Frühschicht'::text) THEN 1
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Spätschicht'::text) THEN 2
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Nachtschicht'::text) THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, COALESCE(final10.auftrag, (0)::bigint)) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, (0)::bigint) AS auftrag_key,
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
          WHERE (final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval))
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    (final11.auftrag_startzeit)::timestamp without time zone AS auftrag_startzeit,
    final11.running_h,
    final11.shift_start_time,
    final11.data_type,
    final11.id_order_label
   FROM final11;


--
-- Name: v_sap_report_data_sync_customer_13; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_sap_report_data_sync_customer_13 AS
 WITH dias AS (
         SELECT (generate_series(((timezone('Europe/Zurich'::text, now()))::date - '4 days'::interval), ((timezone('Europe/Zurich'::text, now()))::date)::timestamp without time zone, '1 day'::interval))::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(((timezone('Europe/Zurich'::text, ers.ts_value))::time without time zone)::interval, 'HH24:MI'::text), '-', to_char(((timezone('Europe/Zurich'::text, ers.ts_end))::time without time zone)::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN (ers.ts_end > now()) THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM public.equipment_oee_shift ers,
            start_counting_day scd,
            public.shifts shi
          WHERE ((ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 13)))) AND (ers.ts_value_production >= scd.start_day) AND (ers.ts_value <= now()) AND (shi.id_shift = ers.id_shift))
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN (eq.tp_equipment = 3) THEN e.id_parentequipment
                    WHEN (eq.tp_equipment = 2) THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM public.equipments e,
            public.equipments eq
          WHERE ((e.id_parentequipment = eq.id_equipment) AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 13) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            public.equipments eq
          WHERE (e.id_equipment_line = eq.id_equipment)
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM public.equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM public.equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.id_site = 13) AND (equipments_1.tp_equipment = 3))))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min.id_equipment,
            agg_equipment_values_1min.id_site,
            agg_equipment_values_1min.id_area,
            agg_equipment_values_1min.ts_value AS tz_value,
            agg_equipment_values_1min.gross_production_incr,
            agg_equipment_values_1min.net_production_incr
           FROM public.agg_equipment_values_1min,
            start_counting_day scd
          WHERE ((agg_equipment_values_1min.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 13) AND (equipments.tp_equipment = 3)))) AND (agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval)) AND (agg_equipment_values_1min.ts_value >= scd.start_day) AND (agg_equipment_values_1min.id_enterprise = 13) AND (agg_equipment_values_1min.id_site = 13))
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN (upper(porun.runtime_timerange) IS NULL) THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM public.production_orders_runtime porun,
            public.production_orders po
          WHERE ((porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 13)))) AND (po.id_equipment = porun.id_equipment) AND (po.id_enterprise = 13) AND (po.id_production_order = porun.id_production_order) AND (lower(porun.runtime_timerange) >= (now() - '90 days'::interval)))
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
                    WHEN (po_sequence_basis.id_order = po_sequence_basis.id_order_sec) THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST((upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval), lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), ((now())::timestamp without time zone)::timestamp with time zone)
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
                    WHEN (shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone)) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN (shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone)) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM (turnos shi
             LEFT JOIN prod_orders po ON (((po.job_start < shi.tz_end) AND (po.job_end >= shi.tz_value) AND (po.id_equipment = shi.id_equipment))))
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
           FROM (base_for_splits bfs
             LEFT JOIN presscount pc ON (((pc.tz_value >= bfs.inicio) AND (pc.tz_value < bfs.fim) AND (pc.id_equipment = bfs.id_equipment) AND (pc.id_site = bfs.id_site) AND (pc.id_area = bfs.id_area))))
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM public.equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM public.equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.tp_equipment = 3) AND (equipments_1.id_site = 13))))
        ), category_level AS (
         SELECT top_level.id_equipment,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text) AS description,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) ->> 'code'::text))::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text)
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
                    WHEN (dc."position" = 24) THEN 1
                    WHEN (dc."position" = ANY (ARRAY[2, 9])) THEN 2
                    WHEN (dc."position" = ANY (ARRAY[5, 8])) THEN 3
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) >= (COALESCE(e.stop_threshold_time, 0))::double precision)) THEN 4
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) < COALESCE((e.stop_threshold_time)::double precision, 'Infinity'::double precision))) THEN 5
                    WHEN (dc."position" = 7) THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM ((public.equipment_events ee
             LEFT JOIN public.equipments e ON (((ee.id_equipment = e.id_equipment) AND (e.id_enterprise = 13) AND (e.tp_equipment = 3) AND (e.id_site = 13))))
             LEFT JOIN downtime_codes dc ON (((ee.cd_category)::text = dc.description)))
          WHERE ((ee.status = 10) AND (ee.ts_event >= (now() - '90 days'::interval)) AND (tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange((now() - '4 days'::interval), now())) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 13) AND (equipments.tp_equipment = 3)))))
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
          WHERE (COALESCE(sb.nextts, now()) >= ( SELECT (start_counting_day.start_day - '1 day'::interval)
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
           FROM (stops_raw st
             LEFT JOIN base_for_splits bfs ON (((tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim)) AND (bfs.id_equipment = st.id_equipment))))
          ORDER BY st.id_equipment, GREATEST(st.tz_event, bfs.inicio), bfs.inicio
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
                    WHEN (st.downtimereason = 0) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 1) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 2) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 3) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 4) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 5) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 6) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_6
           FROM (base_for_splits stpf
             LEFT JOIN split_bfs st ON (((st.tz_event < stpf.fim) AND (st.tz_end > stpf.inicio) AND (stpf.id_equipment = st.id_equipment))))
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
           FROM (stops_final f
             LEFT JOIN press_quantity pqty ON (((f.id_equipment = pqty.id_equipment) AND ((f.cd_shift)::text = (pqty.cd_shift)::text) AND (f.ts_value_production = pqty.ts_value_production) AND (f.id_order = pqty.id_order) AND (f.inicio = pqty.inicio) AND (f.fim = pqty.fim) AND (f.id_shift = pqty.id_shift) AND (f.turno_hrs = pqty.turno_hrs))))
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN (sum(l.label_amount) IS NULL) THEN (0)::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM (base_for_splits bfs
             LEFT JOIN labels l ON (((l.tz_value >= bfs.inicio) AND (l.tz_value < (bfs.fim - '00:00:01'::interval)) AND (l.id_equipment = bfs.id_equipment))))
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            (date_part('epoch'::text, (f.fim - f.inicio)))::bigint AS shift_duration,
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
           FROM (final_and_press f
             LEFT JOIN packed_quantity pack ON (((f.inicio = pack.inicio) AND (f.fim = pack.fim) AND (f.id_equipment = pack.id_equipment) AND (f.id_order = (pack.label_job)::bigint))))
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            (pack.label_job)::bigint AS id_order,
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
           FROM (final_and_press f
             JOIN packed_quantity pack ON (((f.inicio = pack.inicio) AND (f.fim = pack.fim) AND (f.id_equipment = pack.id_equipment) AND (pack.net_label IS NOT NULL) AND (pack.net_label <> (0)::double precision) AND (f.id_order <> (pack.label_job)::bigint))))
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            (ppf.shift_duration)::double precision AS shift_duration,
            (((ppf.shift_duration)::double precision / (3600)::double precision))::numeric(10,2) AS shift_duration_s,
            (((((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_6) / (3600)::double precision))::numeric(10,2) AS total_dt_s,
            ((((ppf.shift_duration)::double precision - (((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_6)) / (3600)::double precision))::numeric(10,2) AS running_s,
            (((ppf.dt_0 + ppf.dt_4) / (3600)::double precision))::numeric(10,2) AS dt_0,
            ((ppf.dt_1 / (3600)::double precision))::numeric(10,2) AS dt_1,
            ((ppf.dt_2 / (3600)::double precision))::numeric(10,2) AS dt_2,
            ((ppf.dt_3 / (3600)::double precision))::numeric(10,2) AS dt_3,
            ((ppf.dt_6 / (3600)::double precision))::numeric(10,2) AS dt_4,
            COALESCE((ppf.press_count)::double precision, (0)::double precision) AS prss_qty,
            COALESCE((ppf.net_sensor)::double precision, (0)::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, (0)::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM (((press_packed_final ppf
             LEFT JOIN public.equipments eq ON (((ppf.id_equipment = eq.id_equipment) AND (eq.id_enterprise = 13) AND (eq.tp_equipment = 3))))
             LEFT JOIN public.shifts shi ON (((shi.id_shift = ppf.id_shift) AND (shi.id_enterprise = 13))))
             LEFT JOIN po_sequence pos ON (((ppf.id_order = pos.id_order) AND (tstzrange(ppf.shift_start_time, (ppf.shift_start_time + '12:00:00'::interval)) && pos.runtime_timerange_new))))
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM public.equipment_boxes_cust_13 ebc
          WHERE ((ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM public.equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 13) AND (equipments.tp_equipment = 3)))) AND (ebc.ts_value >= (now() - '4 days'::interval)))
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
           FROM ((turnos t
             LEFT JOIN labels_data ld ON (((t.id_equipment = ld.id_equipment) AND (ld.ts_value >= t.tz_value) AND (ld.ts_value < t.tz_end))))
             LEFT JOIN public.equipments eq ON ((eq.id_equipment = t.id_equipment)))
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
           FROM (final_jobs fj
             LEFT JOIN final_labels fl ON ((((fl.cd_equipment)::text = (fj.linie)::text) AND ((fl.id_order)::integer = fj.auftrag) AND (fl.ts_value_production = fj.tag) AND ((fl.cd_shift)::text = (fj.shicht)::text))))
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
           FROM (final_labels fl
             LEFT JOIN final1 f1 ON ((((fl.cd_equipment)::text = (f1.linie)::text) AND ((fl.id_order)::integer = f1.auftrag) AND (fl.ts_value_production = f1.tag) AND ((fl.cd_shift)::text = (f1.shicht)::text))))
          WHERE ((fl.sum_labels IS NOT NULL) AND (f1.id_order IS NULL))
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
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Frühschicht'::text) THEN 1
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Spätschicht'::text) THEN 2
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Nachtschicht'::text) THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, COALESCE(final10.auftrag, (0)::bigint)) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, (0)::bigint) AS auftrag_key,
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
          WHERE (final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval))
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    (final11.auftrag_startzeit)::timestamp without time zone AS auftrag_startzeit,
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
   FROM public.v_sap_report_data_sync_customer_13_deb;


--
-- Name: areas id_area; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas ALTER COLUMN id_area SET DEFAULT nextval('public.areas_id_area_seq'::regclass);


--
-- Name: capture_observations id_capture_observation; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capture_observations ALTER COLUMN id_capture_observation SET DEFAULT nextval('public.capture_observations_id_capture_observation_seq'::regclass);


--
-- Name: client_descriptors id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_descriptors ALTER COLUMN id SET DEFAULT nextval('public.client_descriptors_id_seq'::regclass);


--
-- Name: clients id_client; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients ALTER COLUMN id_client SET DEFAULT nextval('public.clients_id_client_seq'::regclass);


--
-- Name: enterprises id_enterprise; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enterprises ALTER COLUMN id_enterprise SET DEFAULT nextval('public.enterprises_id_enterprise_seq'::regclass);


--
-- Name: equipment_events source_seq; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_events ALTER COLUMN source_seq SET DEFAULT nextval('public.equipment_events_source_seq_seq'::regclass);


--
-- Name: equipment_values id_equipment; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_values ALTER COLUMN id_equipment SET DEFAULT nextval('public.equipment_values_id_equipment_seq'::regclass);


--
-- Name: equipment_values source_seq; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_values ALTER COLUMN source_seq SET DEFAULT nextval('public.equipment_values_source_seq_seq'::regclass);


--
-- Name: equipments id_equipment; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipments ALTER COLUMN id_equipment SET DEFAULT nextval('public.equipments_id_equipment_seq'::regclass);


--
-- Name: hist_production_orders id_production_order; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hist_production_orders ALTER COLUMN id_production_order SET DEFAULT nextval('public.hist_production_orders_id_production_order_seq'::regclass);


--
-- Name: knex_migrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knex_migrations ALTER COLUMN id SET DEFAULT nextval('public.knex_migrations_id_seq'::regclass);


--
-- Name: knex_migrations_lock index; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knex_migrations_lock ALTER COLUMN index SET DEFAULT nextval('public.knex_migrations_lock_index_seq'::regclass);


--
-- Name: labels id_label; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.labels ALTER COLUMN id_label SET DEFAULT nextval('public.labels_id_label_seq'::regclass);


--
-- Name: mirror_replay_dlq id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mirror_replay_dlq ALTER COLUMN id SET DEFAULT nextval('public.mirror_replay_dlq_id_seq'::regclass);


--
-- Name: packml_register id_packml_register; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packml_register ALTER COLUMN id_packml_register SET DEFAULT nextval('public.packml_register_id_packml_register_seq'::regclass);


--
-- Name: product_families id_product_family; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_families ALTER COLUMN id_product_family SET DEFAULT nextval('public.product_families_id_product_family_seq'::regclass);


--
-- Name: products id_product; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN id_product SET DEFAULT nextval('public.products_id_product_seq'::regclass);


--
-- Name: sample_boxes id_box; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sample_boxes ALTER COLUMN id_box SET DEFAULT nextval('public.sample_boxes_id_box_seq'::regclass);


--
-- Name: scanned_boxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scanned_boxes ALTER COLUMN id SET DEFAULT nextval('public.scanned_boxes_id_seq'::regclass);


--
-- Name: shift_hours id_shift_hour; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_hours ALTER COLUMN id_shift_hour SET DEFAULT nextval('public.shift_hours_id_shift_hour_seq'::regclass);


--
-- Name: shifts id_shift; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shifts ALTER COLUMN id_shift SET DEFAULT nextval('public.shifts_id_shift_seq'::regclass);


--
-- Name: sites id_site; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites ALTER COLUMN id_site SET DEFAULT nextval('public.sites_id_site_seq'::regclass);


--
-- Name: teams id_team; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams ALTER COLUMN id_team SET DEFAULT nextval('public.teams_id_team_seq'::regclass);


--
-- Name: user_logs id_user_logs; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_logs ALTER COLUMN id_user_logs SET DEFAULT nextval('public.user_logs_id_user_logs_seq'::regclass);


--
-- Name: users id_user; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id_user SET DEFAULT nextval('public.users_id_user_seq'::regclass);


--
-- Name: area_oee_daily area_runtime_1day_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_oee_daily
    ADD CONSTRAINT area_runtime_1day_pk PRIMARY KEY (id_area, ts_value);


--
-- Name: area_oee_shift area_runtime_shift_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_oee_shift
    ADD CONSTRAINT area_runtime_shift_pk PRIMARY KEY (id_area, ts_value);


--
-- Name: areas_history areas_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas_history
    ADD CONSTRAINT areas_history_pkey PRIMARY KEY (history_id);


--
-- Name: areas areas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT areas_pkey PRIMARY KEY (id_area);


--
-- Name: box_production_bridges box_production_bridges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.box_production_bridges
    ADD CONSTRAINT box_production_bridges_pkey PRIMARY KEY (id_enterprise, source_cd, target_cd);


--
-- Name: box_scans box_scans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.box_scans
    ADD CONSTRAINT box_scans_pkey PRIMARY KEY (box_scan_id);


--
-- Name: capture_observations capture_observations_id_enterprise_topic_count_index_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capture_observations
    ADD CONSTRAINT capture_observations_id_enterprise_topic_count_index_key UNIQUE (id_enterprise, topic, count_index);


--
-- Name: capture_observations capture_observations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capture_observations
    ADD CONSTRAINT capture_observations_pkey PRIMARY KEY (id_capture_observation);


--
-- Name: client_descriptors client_descriptors_enterprise_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_descriptors
    ADD CONSTRAINT client_descriptors_enterprise_uniq UNIQUE (id_enterprise);


--
-- Name: client_descriptors client_descriptors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_descriptors
    ADD CONSTRAINT client_descriptors_pkey PRIMARY KEY (id);


--
-- Name: clients clients_nm_client_id_enterprise_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_nm_client_id_enterprise_unique UNIQUE (nm_client, id_enterprise);


--
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id_client);


--
-- Name: clients clients_un; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_un UNIQUE (nm_client, id_enterprise);


--
-- Name: dashboard_config dashboard_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboard_config
    ADD CONSTRAINT dashboard_config_pkey PRIMARY KEY (id_enterprise, dashboard_id, version);


--
-- Name: data_quality_event data_quality_event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_quality_event
    ADD CONSTRAINT data_quality_event_pkey PRIMARY KEY (id);


--
-- Name: downtime_reason downtime_reason_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.downtime_reason
    ADD CONSTRAINT downtime_reason_pkey PRIMARY KEY (id);


--
-- Name: enterprises_history enterprises_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enterprises_history
    ADD CONSTRAINT enterprises_history_pkey PRIMARY KEY (history_id);


--
-- Name: enterprises enterprises_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enterprises
    ADD CONSTRAINT enterprises_pkey PRIMARY KEY (id_enterprise);


--
-- Name: equipment_downtime_reason equipment_downtime_reason_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_downtime_reason
    ADD CONSTRAINT equipment_downtime_reason_pkey PRIMARY KEY (id_equipment, id_reason);


--
-- Name: equipment_events_cpac_shadow equipment_events_cpac_shadow_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_events_cpac_shadow
    ADD CONSTRAINT equipment_events_cpac_shadow_pkey PRIMARY KEY (id_equipment, ts_event);


--
-- Name: equipment_events_man equipment_events_man_id_equipment_ts_event_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_events_man
    ADD CONSTRAINT equipment_events_man_id_equipment_ts_event_key UNIQUE (id_equipment, ts_event);


--
-- Name: CONSTRAINT equipment_events_man_id_equipment_ts_event_key ON equipment_events_man; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON CONSTRAINT equipment_events_man_id_equipment_ts_event_key ON public.equipment_events_man IS 'F3 cutover fixup H5: correct per-equipment uniqueness. Replaces the incorrect global ts_event unique (equipment_events_man_ts_event_key) which silently dropped same-minute cross-line manual events. Repoint replicator ON CONFLICT to (id_equipment, ts_event); then drop the global unique (Step 2 below).';


--
-- Name: equipment_events_man equipment_events_man_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_events_man
    ADD CONSTRAINT equipment_events_man_pkey PRIMARY KEY (id_equipment_event);


--
-- Name: equipment_events equipment_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_events
    ADD CONSTRAINT equipment_events_pkey PRIMARY KEY (id_equipment, ts_event);


--
-- Name: equipment_events_raw equipment_events_raw_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_events_raw
    ADD CONSTRAINT equipment_events_raw_pkey PRIMARY KEY (id_equipment, ts_event, source_seq);


--
-- Name: equipment_oee_daily equipment_runtime_1day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_daily
    ADD CONSTRAINT equipment_runtime_1day_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_oee_hourly equipment_runtime_1hour_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_hourly
    ADD CONSTRAINT equipment_runtime_1hour_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_oee_monthly equipment_runtime_1month_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_monthly
    ADD CONSTRAINT equipment_runtime_1month_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_oee_weekly equipment_runtime_1week_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_weekly
    ADD CONSTRAINT equipment_runtime_1week_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_oee_shift equipment_runtime_shift_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_shift
    ADD CONSTRAINT equipment_runtime_shift_pk PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_scrap_reason equipment_scrap_reason_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_scrap_reason
    ADD CONSTRAINT equipment_scrap_reason_pkey PRIMARY KEY (id_equipment, id_reason);


--
-- Name: equipment_values equipment_values_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_values
    ADD CONSTRAINT equipment_values_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_values_raw equipment_values_raw_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_values_raw
    ADD CONSTRAINT equipment_values_raw_pkey PRIMARY KEY (id_equipment, ts_value, source_seq);


--
-- Name: equipments_history equipments_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipments_history
    ADD CONSTRAINT equipments_history_pkey PRIMARY KEY (history_id);


--
-- Name: equipments equipments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipments
    ADD CONSTRAINT equipments_pkey PRIMARY KEY (id_equipment);


--
-- Name: hist_production_orders hist_po_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hist_production_orders
    ADD CONSTRAINT hist_po_pkey PRIMARY KEY (id_production_order);


--
-- Name: idempotency_keys idempotency_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotency_keys
    ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (idempotency_key);


--
-- Name: knex_migrations_lock knex_migrations_lock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knex_migrations_lock
    ADD CONSTRAINT knex_migrations_lock_pkey PRIMARY KEY (index);


--
-- Name: knex_migrations knex_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.knex_migrations
    ADD CONSTRAINT knex_migrations_pkey PRIMARY KEY (id);


--
-- Name: label_formats label_formats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_formats
    ADD CONSTRAINT label_formats_pkey PRIMARY KEY (id_enterprise, label_key);


--
-- Name: labels labels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.labels
    ADD CONSTRAINT labels_pkey PRIMARY KEY (id_label);


--
-- Name: language_packs language_packs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.language_packs
    ADD CONSTRAINT language_packs_pkey PRIMARY KEY (language_tag);


--
-- Name: mirror_replay_cursor mirror_replay_cursor_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mirror_replay_cursor
    ADD CONSTRAINT mirror_replay_cursor_pkey PRIMARY KEY (source);


--
-- Name: mirror_replay_dlq mirror_replay_dlq_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mirror_replay_dlq
    ADD CONSTRAINT mirror_replay_dlq_pkey PRIMARY KEY (id);


--
-- Name: oee_targets oee_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oee_targets
    ADD CONSTRAINT oee_targets_pkey PRIMARY KEY (id);


--
-- Name: packml_register packml_register_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packml_register
    ADD CONSTRAINT packml_register_pkey PRIMARY KEY (id_packml_register);


--
-- Name: pages pages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pages
    ADD CONSTRAINT pages_pkey PRIMARY KEY (id_page);


--
-- Name: po_box_counter po_box_counter_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.po_box_counter
    ADD CONSTRAINT po_box_counter_pkey PRIMARY KEY (id_production_order);


--
-- Name: product_families product_families_id_enterprise_nm_product_family_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_families
    ADD CONSTRAINT product_families_id_enterprise_nm_product_family_unique UNIQUE (id_enterprise, nm_product_family);


--
-- Name: product_families product_families_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_families
    ADD CONSTRAINT product_families_pkey PRIMARY KEY (id_product_family);


--
-- Name: product_families product_family_un; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_families
    ADD CONSTRAINT product_family_un UNIQUE (id_enterprise, nm_product_family);


--
-- Name: hist_production_orders production_orders_id_enterprise_id_order_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hist_production_orders
    ADD CONSTRAINT production_orders_id_enterprise_id_order_unique UNIQUE (id_enterprise, id_order);


--
-- Name: production_orders production_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_orders
    ADD CONSTRAINT production_orders_pkey PRIMARY KEY (id_production_order);


--
-- Name: production_orders_runtime production_orders_runtime_id_equipment_runtime_timerange_excl; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_orders_runtime
    ADD CONSTRAINT production_orders_runtime_id_equipment_runtime_timerange_excl EXCLUDE USING gist (id_equipment WITH =, runtime_timerange WITH &&);


--
-- Name: production_orders_runtime production_orders_runtime_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_orders_runtime
    ADD CONSTRAINT production_orders_runtime_pkey PRIMARY KEY (id_production_order_runtime);


--
-- Name: hist_production_orders production_orders_un; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hist_production_orders
    ADD CONSTRAINT production_orders_un UNIQUE (id_enterprise, id_order);


--
-- Name: production_targets production_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_targets
    ADD CONSTRAINT production_targets_pkey PRIMARY KEY (id_equipment, id_site);


--
-- Name: products products_id_enterprise_cd_product_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_id_enterprise_cd_product_unique UNIQUE (id_enterprise, cd_product);


--
-- Name: products products_nm_product_id_enterprise_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_nm_product_id_enterprise_unique UNIQUE (nm_product, id_enterprise);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id_product);


--
-- Name: products products_un; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_un UNIQUE (nm_product, id_enterprise);


--
-- Name: products products_un_cd; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_un_cd UNIQUE (id_enterprise, cd_product);


--
-- Name: sample_boxes sample_boxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sample_boxes
    ADD CONSTRAINT sample_boxes_pkey PRIMARY KEY (id_box);


--
-- Name: scanned_boxes scanned_boxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scanned_boxes
    ADD CONSTRAINT scanned_boxes_pkey PRIMARY KEY (id);


--
-- Name: scanned_boxes scanned_boxes_un; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scanned_boxes
    ADD CONSTRAINT scanned_boxes_un UNIQUE (box_order_number, id_production_order);


--
-- Name: scrap_reason scrap_reason_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scrap_reason
    ADD CONSTRAINT scrap_reason_pkey PRIMARY KEY (id);


--
-- Name: scrap_targets scrap_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scrap_targets
    ADD CONSTRAINT scrap_targets_pkey PRIMARY KEY (id_equipment, id_site);


--
-- Name: shifts_exception_period shift_exception_period_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shifts_exception_period
    ADD CONSTRAINT shift_exception_period_pk PRIMARY KEY (id_equipment, ts_begin);


--
-- Name: shift_hours shift_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_hours
    ADD CONSTRAINT shift_hours_pkey PRIMARY KEY (id_shift_hour);


--
-- Name: shifts shifts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shifts
    ADD CONSTRAINT shifts_pkey PRIMARY KEY (id_shift);


--
-- Name: site_oee_daily site_runtime_1day_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_oee_daily
    ADD CONSTRAINT site_runtime_1day_pk PRIMARY KEY (id_site, ts_value);


--
-- Name: site_oee_shift site_runtime_shift_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_oee_shift
    ADD CONSTRAINT site_runtime_shift_pk PRIMARY KEY (id_site, ts_value);


--
-- Name: sites_history sites_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites_history
    ADD CONSTRAINT sites_history_pkey PRIMARY KEY (history_id);


--
-- Name: sites sites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_pkey PRIMARY KEY (id_site);


--
-- Name: teams teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_pkey PRIMARY KEY (id_team);


--
-- Name: tenant_translations tenant_translations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_translations
    ADD CONSTRAINT tenant_translations_pkey PRIMARY KEY (id_enterprise, language_tag, app, namespace, key);


--
-- Name: translations translations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.translations
    ADD CONSTRAINT translations_pkey PRIMARY KEY (language_tag, app, namespace, key);


--
-- Name: twin_backfill_po_log twin_backfill_po_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.twin_backfill_po_log
    ADD CONSTRAINT twin_backfill_po_log_pkey PRIMARY KEY (id_production_order);


--
-- Name: users uid_firebase_un; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uid_firebase_un UNIQUE (id_user_firebase);


--
-- Name: area_live_day uns_area_current_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_live_day
    ADD CONSTRAINT uns_area_current_day_pkey PRIMARY KEY (id_area);


--
-- Name: area_live_shift uns_area_current_shift_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_live_shift
    ADD CONSTRAINT uns_area_current_shift_pkey PRIMARY KEY (id_area);


--
-- Name: equipment_live_day uns_equipment_current_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_day
    ADD CONSTRAINT uns_equipment_current_day_pkey PRIMARY KEY (id_equipment);


--
-- Name: equipment_live_hour uns_equipment_current_hour_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_hour
    ADD CONSTRAINT uns_equipment_current_hour_pkey PRIMARY KEY (id_equipment);


--
-- Name: equipment_live_job uns_equipment_current_job_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_job
    ADD CONSTRAINT uns_equipment_current_job_pkey PRIMARY KEY (id_equipment);


--
-- Name: equipment_live_metrics uns_equipment_current_metrics_id_equipment_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_metrics
    ADD CONSTRAINT uns_equipment_current_metrics_id_equipment_key UNIQUE (id_equipment);


--
-- Name: equipment_live_metrics uns_equipment_current_metrics_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_metrics
    ADD CONSTRAINT uns_equipment_current_metrics_pk PRIMARY KEY (id_equipment);


--
-- Name: equipment_live_month uns_equipment_current_month_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_month
    ADD CONSTRAINT uns_equipment_current_month_pkey PRIMARY KEY (id_equipment);


--
-- Name: equipment_live_shift uns_equipment_current_shift_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_shift
    ADD CONSTRAINT uns_equipment_current_shift_pkey PRIMARY KEY (id_equipment);


--
-- Name: equipment_live_week uns_equipment_current_week_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_week
    ADD CONSTRAINT uns_equipment_current_week_pkey PRIMARY KEY (id_equipment);


--
-- Name: site_live_day uns_site_current_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_live_day
    ADD CONSTRAINT uns_site_current_day_pkey PRIMARY KEY (id_site);


--
-- Name: user_logs user_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_logs
    ADD CONSTRAINT user_logs_pkey PRIMARY KEY (id_user_logs);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (id_user_role);


--
-- Name: users users_id_user_firebase_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_id_user_firebase_unique UNIQUE (id_user_firebase);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id_user);


--
-- Name: areas_history_key_valid_from_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX areas_history_key_valid_from_idx ON public.areas_history USING btree (id_area, valid_from);


--
-- Name: box_scans_ent_ingested_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX box_scans_ent_ingested_idx ON public.box_scans USING btree (id_enterprise, ingested_at DESC);


--
-- Name: box_scans_equipment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX box_scans_equipment_idx ON public.box_scans USING btree (id_equipment, ts_value DESC);


--
-- Name: box_scans_po_seq_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX box_scans_po_seq_idx ON public.box_scans USING btree (id_production_order, label_seq);


--
-- Name: client_descriptors_tenant_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX client_descriptors_tenant_code_idx ON public.client_descriptors USING btree (tenant_code);


--
-- Name: clients_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX clients_id_enterprise_idx ON public.clients USING btree (id_enterprise);


--
-- Name: data_quality_event_dedup_un; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX data_quality_event_dedup_un ON public.data_quality_event USING btree (id_enterprise, COALESCE(id_equipment, 0), grain, bucket_ts, rule);


--
-- Name: data_quality_event_rule_detected_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX data_quality_event_rule_detected_idx ON public.data_quality_event USING btree (rule, detected_at DESC);


--
-- Name: downtime_reason_code_active_un; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX downtime_reason_code_active_un ON public.downtime_reason USING btree (id_enterprise, code) WHERE active;


--
-- Name: eem_id_equipment_ts_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX eem_id_equipment_ts_idx ON public.equipment_events_man USING btree (id_equipment, ts_event DESC);


--
-- Name: enterprises_history_key_valid_from_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX enterprises_history_key_valid_from_idx ON public.enterprises_history USING btree (id_enterprise, valid_from);


--
-- Name: equipment_downtime_reason_reason_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_downtime_reason_reason_idx ON public.equipment_downtime_reason USING btree (id_reason);


--
-- Name: equipment_events_cpac_shadow_id_equipment_ts_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX equipment_events_cpac_shadow_id_equipment_ts_event_idx ON public.equipment_events_cpac_shadow USING btree (id_equipment, ts_event);


--
-- Name: equipment_events_cpac_shadow_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX equipment_events_cpac_shadow_key ON public.equipment_events_cpac_shadow USING btree (id_equipment, ts_event);


--
-- Name: equipment_events_cpac_shadow_ts_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_events_cpac_shadow_ts_event_idx ON public.equipment_events_cpac_shadow USING btree (ts_event DESC);


--
-- Name: equipment_events_pk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX equipment_events_pk ON public.equipment_events USING btree (id_equipment, ts_event);


--
-- Name: equipment_events_raw_ts_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_events_raw_ts_event_idx ON public.equipment_events_raw USING btree (ts_event DESC);


--
-- Name: equipment_events_ts_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_events_ts_event_idx ON public.equipment_events USING btree (ts_event DESC);


--
-- Name: equipment_runtime_1hour_id_equipment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_runtime_1hour_id_equipment_idx ON public.equipment_oee_hourly USING btree (id_equipment);


--
-- Name: equipment_runtime_1hour_ts_value_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_runtime_1hour_ts_value_idx ON public.equipment_oee_hourly USING btree (ts_value DESC);


--
-- Name: equipment_runtime_shift_1month_pk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX equipment_runtime_shift_1month_pk ON public.equipment_oee_shift_monthly USING btree (id_equipment, ts_value, id_shift);


--
-- Name: equipment_runtime_shift_1week_pk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX equipment_runtime_shift_1week_pk ON public.equipment_oee_shift_weekly USING btree (id_equipment, ts_value, id_shift);


--
-- Name: equipment_runtime_shift_ts_range_id_equipment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_runtime_shift_ts_range_id_equipment_idx ON public.equipment_oee_shift USING gist (id_equipment, ts_range);


--
-- Name: equipment_runtime_shift_ts_value_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_runtime_shift_ts_value_idx ON public.equipment_oee_shift USING btree (ts_value DESC);


--
-- Name: equipment_scrap_reason_reason_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_scrap_reason_reason_idx ON public.equipment_scrap_reason USING btree (id_reason);


--
-- Name: equipment_values_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_enterprise_idx ON public.equipment_values USING btree (id_enterprise);


--
-- Name: equipment_values_id_equipment_ts_value_ideal_production_speed_i; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_ideal_production_speed_i ON public.equipment_values USING btree (id_equipment, ts_value DESC, ideal_production_speed) WHERE (ideal_production_speed IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_state_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, state) WHERE (state IS NOT NULL);


--
-- Name: equipment_values_raw_ts_value_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_raw_ts_value_idx ON public.equipment_values_raw USING btree (ts_value DESC);


--
-- Name: equipment_values_time_bucket_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_time_bucket_idx ON public.equipment_values USING btree (id_equipment, public.time_bucket('00:01:00'::interval, ts_value));


--
-- Name: equipment_values_ts_value_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_ts_value_idx ON public.equipment_values USING btree (ts_value DESC);


--
-- Name: equipments_cd_equipment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipments_cd_equipment_idx ON public.equipments USING btree (cd_equipment);


--
-- Name: equipments_history_key_valid_from_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipments_history_key_valid_from_idx ON public.equipments_history USING btree (id_equipment, valid_from);


--
-- Name: equipments_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipments_id_enterprise_idx ON public.equipments USING btree (id_enterprise);


--
-- Name: equipments_nm_equipment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipments_nm_equipment_idx ON public.equipments USING btree (nm_equipment);


--
-- Name: idempotency_keys_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idempotency_keys_created_at_idx ON public.idempotency_keys USING btree (created_at);


--
-- Name: idx_capture_obs_enterprise; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_capture_obs_enterprise ON public.capture_observations USING btree (id_enterprise);


--
-- Name: idx_er1d_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1d_equipment ON public.equipment_oee_daily USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_er1d_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1d_recalc ON public.equipment_oee_daily USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_er1h_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1h_equipment ON public.equipment_oee_hourly USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_er1h_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1h_recalc ON public.equipment_oee_hourly USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_er1mo_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1mo_equipment ON public.equipment_oee_monthly USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_er1mo_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1mo_recalc ON public.equipment_oee_monthly USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_er1w_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1w_equipment ON public.equipment_oee_weekly USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_er1w_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1w_recalc ON public.equipment_oee_weekly USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_ers_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ers_equipment ON public.equipment_oee_shift USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_ers_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ers_recalc ON public.equipment_oee_shift USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_ers_shift; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ers_shift ON public.equipment_oee_shift USING btree (id_shift);


--
-- Name: idx_labels_enterprise; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_labels_enterprise ON public.labels USING btree (id_enterprise);


--
-- Name: idx_labels_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_labels_equipment ON public.labels USING btree (id_equipment);


--
-- Name: idx_oee_targets_enterprise; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oee_targets_enterprise ON public.oee_targets USING btree (id_enterprise);


--
-- Name: idx_oee_targets_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oee_targets_equipment ON public.oee_targets USING btree (id_equipment);


--
-- Name: idx_production_targets_enterprise; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_production_targets_enterprise ON public.production_targets USING btree (id_enterprise);


--
-- Name: idx_sample_boxes_equip; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sample_boxes_equip ON public.sample_boxes USING btree (id_equipment);


--
-- Name: idx_sample_boxes_po; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sample_boxes_po ON public.sample_boxes USING btree (id_production_order);


--
-- Name: idx_scanned_boxes_equip; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scanned_boxes_equip ON public.scanned_boxes USING btree (id_equipment);


--
-- Name: idx_scanned_boxes_po; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scanned_boxes_po ON public.scanned_boxes USING btree (id_production_order);


--
-- Name: idx_scanned_boxes_ts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scanned_boxes_ts ON public.scanned_boxes USING btree (ts_value DESC);


--
-- Name: idx_scrap_targets_enterprise; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_scrap_targets_enterprise ON public.scrap_targets USING btree (id_enterprise);


--
-- Name: idx_shifts_exception_begin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_shifts_exception_begin ON public.shifts_exception_period USING btree (ts_begin);


--
-- Name: idx_shifts_exception_equip; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_shifts_exception_equip ON public.shifts_exception_period USING btree (id_equipment);


--
-- Name: idx_teams_area; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_teams_area ON public.teams USING btree (id_area);


--
-- Name: idx_teams_enterprise; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_teams_enterprise ON public.teams USING btree (id_enterprise);


--
-- Name: idx_teams_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_teams_equipment ON public.teams USING btree (id_equipment);


--
-- Name: idx_user_roles_enterprise; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_roles_enterprise ON public.user_roles USING btree (id_enterprise);


--
-- Name: mirror_replay_dlq_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mirror_replay_dlq_source_idx ON public.mirror_replay_dlq USING btree (source, created_at DESC);


--
-- Name: packml_topic_active_un; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX packml_topic_active_un ON public.packml_register USING btree (packml_topic) WHERE active;


--
-- Name: po_id_equipment_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX po_id_equipment_status_idx ON public.production_orders USING btree (id_equipment, status);


--
-- Name: productfamilies_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX productfamilies_id_enterprise_idx ON public.product_families USING btree (id_enterprise);


--
-- Name: production_orders_id_enterprise_id_order_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX production_orders_id_enterprise_id_order_key ON public.production_orders USING btree (id_enterprise, id_order);


--
-- Name: production_orders_id_equipment_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX production_orders_id_equipment_run_idx ON public.production_orders USING btree (id_equipment) WHERE (status = 2);


--
-- Name: products_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX products_id_enterprise_idx ON public.products USING btree (id_enterprise);


--
-- Name: scanned_boxes_id_equipment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scanned_boxes_id_equipment_idx ON public.scanned_boxes USING btree (id_equipment);


--
-- Name: scanned_boxes_id_equipment_ts_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scanned_boxes_id_equipment_ts_idx ON public.scanned_boxes USING btree (id_equipment, ts_value);


--
-- Name: scanned_boxes_id_production_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scanned_boxes_id_production_order_idx ON public.scanned_boxes USING btree (id_production_order);


--
-- Name: scrap_reason_code_active_un; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scrap_reason_code_active_un ON public.scrap_reason USING btree (id_enterprise, code) WHERE active;


--
-- Name: shift_hours_begin_end_site_area_equip_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX shift_hours_begin_end_site_area_equip_uidx ON public.shift_hours USING btree (begin_time, end_time, id_site, id_area, COALESCE(id_equipment, 0));


--
-- Name: sites_history_key_valid_from_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sites_history_key_valid_from_idx ON public.sites_history USING btree (id_site, valid_from);


--
-- Name: tenant_translations_read_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tenant_translations_read_idx ON public.tenant_translations USING btree (id_enterprise, app, language_tag, namespace);


--
-- Name: translations_read_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX translations_read_idx ON public.translations USING btree (app, language_tag, namespace);


--
-- Name: uq_box_scans_po_label; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_box_scans_po_label ON public.box_scans USING btree (id_production_order, label_seq) WHERE (scan_type = 'production'::text);


--
-- Name: uq_box_scans_scan_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_box_scans_scan_uuid ON public.box_scans USING btree (scan_uuid);


--
-- Name: uq_pr_device_key_global; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_pr_device_key_global ON public.packml_register USING btree (device_key) WHERE (device_key IS NOT NULL);


--
-- Name: uq_pr_enterprise_device_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_pr_enterprise_device_key ON public.packml_register USING btree (id_enterprise, device_key) WHERE (device_key IS NOT NULL);


--
-- Name: user_screen_config_tenant_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_screen_config_tenant_key ON public.user_screen_config USING btree (id_enterprise, id_user, screen);


--
-- Name: users_email_enterprise_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_enterprise_uniq ON public.users USING btree (lower((user_email)::text), id_enterprise) WHERE ((user_email IS NOT NULL) AND ((user_email)::text <> ''::text));


--
-- Name: users_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_id_enterprise_idx ON public.users USING btree (id_enterprise);


--
-- Name: users_id_user_cognito_un; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_id_user_cognito_un ON public.users USING btree (id_user_cognito) WHERE (id_user_cognito IS NOT NULL);


--
-- Name: users_id_user_cognito_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_id_user_cognito_uniq ON public.users USING btree (id_user_cognito) WHERE (id_user_cognito IS NOT NULL);


--
-- Name: box_scans trg_box_scans_no_mutate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_box_scans_no_mutate BEFORE DELETE OR UPDATE ON public.box_scans FOR EACH ROW EXECUTE FUNCTION public.box_scans_no_mutate();


--
-- Name: equipment_events_raw trg_equipment_events_raw_no_mutate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_equipment_events_raw_no_mutate BEFORE DELETE OR UPDATE ON public.equipment_events_raw FOR EACH ROW EXECUTE FUNCTION public.bronze_raw_no_mutate();


--
-- Name: equipment_values_raw trg_equipment_values_raw_no_mutate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_equipment_values_raw_no_mutate BEFORE DELETE OR UPDATE ON public.equipment_values_raw FOR EACH ROW EXECUTE FUNCTION public.bronze_raw_no_mutate();


--
-- Name: areas trg_scd2_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_scd2_history BEFORE UPDATE ON public.areas FOR EACH ROW EXECUTE FUNCTION public.log_dimension_history();


--
-- Name: enterprises trg_scd2_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_scd2_history BEFORE UPDATE ON public.enterprises FOR EACH ROW EXECUTE FUNCTION public.log_dimension_history();


--
-- Name: equipments trg_scd2_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_scd2_history BEFORE UPDATE ON public.equipments FOR EACH ROW EXECUTE FUNCTION public.log_dimension_history();


--
-- Name: sites trg_scd2_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_scd2_history BEFORE UPDATE ON public.sites FOR EACH ROW EXECUTE FUNCTION public.log_dimension_history();


--
-- Name: areas trg_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON public.areas FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: downtime_reason trg_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON public.downtime_reason FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: enterprises trg_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON public.enterprises FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: equipment_downtime_reason trg_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON public.equipment_downtime_reason FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: equipment_scrap_reason trg_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON public.equipment_scrap_reason FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: equipments trg_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON public.equipments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: scrap_reason trg_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON public.scrap_reason FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: sites trg_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_set_updated_at BEFORE UPDATE ON public.sites FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: areas areas_id_enterprise_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT areas_id_enterprise_foreign FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise);


--
-- Name: areas areas_id_site_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT areas_id_site_foreign FOREIGN KEY (id_site) REFERENCES public.sites(id_site);


--
-- Name: downtime_reason downtime_reason_id_enterprise_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.downtime_reason
    ADD CONSTRAINT downtime_reason_id_enterprise_fkey FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise);


--
-- Name: downtime_reason downtime_reason_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.downtime_reason
    ADD CONSTRAINT downtime_reason_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.downtime_reason(id);


--
-- Name: equipment_downtime_reason equipment_downtime_reason_id_equipment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_downtime_reason
    ADD CONSTRAINT equipment_downtime_reason_id_equipment_fkey FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_downtime_reason equipment_downtime_reason_id_reason_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_downtime_reason
    ADD CONSTRAINT equipment_downtime_reason_id_reason_fkey FOREIGN KEY (id_reason) REFERENCES public.downtime_reason(id);


--
-- Name: equipment_scrap_reason equipment_scrap_reason_id_equipment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_scrap_reason
    ADD CONSTRAINT equipment_scrap_reason_id_equipment_fkey FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_scrap_reason equipment_scrap_reason_id_reason_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_scrap_reason
    ADD CONSTRAINT equipment_scrap_reason_id_reason_fkey FOREIGN KEY (id_reason) REFERENCES public.scrap_reason(id);


--
-- Name: equipments equipments_id_area_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipments
    ADD CONSTRAINT equipments_id_area_foreign FOREIGN KEY (id_area) REFERENCES public.areas(id_area);


--
-- Name: equipments equipments_id_enterprise_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipments
    ADD CONSTRAINT equipments_id_enterprise_foreign FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise);


--
-- Name: equipments equipments_id_equipment_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipments
    ADD CONSTRAINT equipments_id_equipment_foreign FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: equipments equipments_id_site_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipments
    ADD CONSTRAINT equipments_id_site_foreign FOREIGN KEY (id_site) REFERENCES public.sites(id_site);


--
-- Name: box_scans fk_box_scans_area; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.box_scans
    ADD CONSTRAINT fk_box_scans_area FOREIGN KEY (id_area) REFERENCES public.areas(id_area);


--
-- Name: box_scans fk_box_scans_enterprise; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.box_scans
    ADD CONSTRAINT fk_box_scans_enterprise FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise);


--
-- Name: box_scans fk_box_scans_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.box_scans
    ADD CONSTRAINT fk_box_scans_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: box_scans fk_box_scans_production_order; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.box_scans
    ADD CONSTRAINT fk_box_scans_production_order FOREIGN KEY (id_production_order) REFERENCES public.production_orders(id_production_order);


--
-- Name: box_scans fk_box_scans_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.box_scans
    ADD CONSTRAINT fk_box_scans_site FOREIGN KEY (id_site) REFERENCES public.sites(id_site);


--
-- Name: box_scans fk_box_scans_voids; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.box_scans
    ADD CONSTRAINT fk_box_scans_voids FOREIGN KEY (voids_box_scan_id) REFERENCES public.box_scans(box_scan_id);


--
-- Name: equipment_oee_daily fk_ert1day_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_daily
    ADD CONSTRAINT fk_ert1day_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_oee_hourly fk_ert1hour_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_hourly
    ADD CONSTRAINT fk_ert1hour_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_oee_monthly fk_ert1month_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_monthly
    ADD CONSTRAINT fk_ert1month_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_oee_weekly fk_ert1week_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_weekly
    ADD CONSTRAINT fk_ert1week_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_oee_shift fk_ertshift_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_oee_shift
    ADD CONSTRAINT fk_ertshift_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: po_box_counter fk_po_box_counter_enterprise; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.po_box_counter
    ADD CONSTRAINT fk_po_box_counter_enterprise FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise);


--
-- Name: po_box_counter fk_po_box_counter_production_order; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.po_box_counter
    ADD CONSTRAINT fk_po_box_counter_production_order FOREIGN KEY (id_production_order) REFERENCES public.production_orders(id_production_order);


--
-- Name: production_targets fk_prodtgt_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_targets
    ADD CONSTRAINT fk_prodtgt_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_live_day fk_uecd_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_day
    ADD CONSTRAINT fk_uecd_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_live_month fk_uecmo_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_month
    ADD CONSTRAINT fk_uecmo_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_live_shift fk_uecs_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_shift
    ADD CONSTRAINT fk_uecs_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_live_week fk_uecw_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_week
    ADD CONSTRAINT fk_uecw_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: labels labels_id_enterprise_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.labels
    ADD CONSTRAINT labels_id_enterprise_foreign FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: labels labels_id_equipment_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.labels
    ADD CONSTRAINT labels_id_equipment_foreign FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: packml_register packml_register_id_equipment_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packml_register
    ADD CONSTRAINT packml_register_id_equipment_foreign FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: hist_production_orders production_orders_id_client_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hist_production_orders
    ADD CONSTRAINT production_orders_id_client_foreign FOREIGN KEY (id_client) REFERENCES public.clients(id_client) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: production_orders production_orders_id_client_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_orders
    ADD CONSTRAINT production_orders_id_client_foreign FOREIGN KEY (id_client) REFERENCES public.clients(id_client) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: hist_production_orders production_orders_id_equipment_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hist_production_orders
    ADD CONSTRAINT production_orders_id_equipment_foreign FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: production_orders production_orders_id_equipment_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_orders
    ADD CONSTRAINT production_orders_id_equipment_foreign FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: production_orders production_orders_id_label_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_orders
    ADD CONSTRAINT production_orders_id_label_foreign FOREIGN KEY (id_label) REFERENCES public.labels(id_label) ON UPDATE RESTRICT ON DELETE SET NULL;


--
-- Name: hist_production_orders production_orders_id_product_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hist_production_orders
    ADD CONSTRAINT production_orders_id_product_foreign FOREIGN KEY (id_product) REFERENCES public.products(id_product) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: production_orders production_orders_id_product_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_orders
    ADD CONSTRAINT production_orders_id_product_foreign FOREIGN KEY (id_product) REFERENCES public.products(id_product) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: hist_production_orders production_orders_id_user_operator_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hist_production_orders
    ADD CONSTRAINT production_orders_id_user_operator_foreign FOREIGN KEY (id_user_operator) REFERENCES public.users(id_user) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: production_orders production_orders_id_user_operator_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.production_orders
    ADD CONSTRAINT production_orders_id_user_operator_foreign FOREIGN KEY (id_user_operator) REFERENCES public.users(id_user) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: sample_boxes sample_boxes_id_enterprise_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sample_boxes
    ADD CONSTRAINT sample_boxes_id_enterprise_foreign FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: sample_boxes sample_boxes_id_equipment_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sample_boxes
    ADD CONSTRAINT sample_boxes_id_equipment_foreign FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: scrap_reason scrap_reason_id_enterprise_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scrap_reason
    ADD CONSTRAINT scrap_reason_id_enterprise_fkey FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise);


--
-- Name: scrap_reason scrap_reason_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scrap_reason
    ADD CONSTRAINT scrap_reason_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.scrap_reason(id);


--
-- Name: shift_hours shift_hours_id_shift_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_hours
    ADD CONSTRAINT shift_hours_id_shift_fkey FOREIGN KEY (id_shift) REFERENCES public.shifts(id_shift);


--
-- Name: shifts shifts_id_enterprise_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shifts
    ADD CONSTRAINT shifts_id_enterprise_fkey FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise);


--
-- Name: sites sites_id_enterprise_foreign; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_id_enterprise_foreign FOREIGN KEY (id_enterprise) REFERENCES public.enterprises(id_enterprise);


--
-- Name: equipment_live_job uns_equipment_current_job_id_equipment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_live_job
    ADD CONSTRAINT uns_equipment_current_job_id_equipment_fkey FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_oee_hourly; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.equipment_oee_hourly ENABLE ROW LEVEL SECURITY;

--
-- Name: equipment_oee_shift; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.equipment_oee_shift ENABLE ROW LEVEL SECURITY;

--
-- Name: equipments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.equipments ENABLE ROW LEVEL SECURITY;

--
-- Name: production_orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.production_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: production_orders_runtime; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.production_orders_runtime ENABLE ROW LEVEL SECURITY;

--
-- Name: production_targets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.production_targets ENABLE ROW LEVEL SECURITY;

--
-- Name: equipment_oee_hourly tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.equipment_oee_hourly USING ((public.is_all_tenant() OR (EXISTS ( SELECT 1
   FROM public.equipments e
  WHERE ((e.id_equipment = equipment_oee_hourly.id_equipment) AND (e.id_enterprise = public.current_tenant()))))));


--
-- Name: equipment_oee_shift tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.equipment_oee_shift USING ((public.is_all_tenant() OR (EXISTS ( SELECT 1
   FROM public.equipments e
  WHERE ((e.id_equipment = equipment_oee_shift.id_equipment) AND (e.id_enterprise = public.current_tenant()))))));


--
-- Name: equipments tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.equipments USING ((public.is_all_tenant() OR (id_enterprise = public.current_tenant())));


--
-- Name: production_orders tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.production_orders USING ((public.is_all_tenant() OR (id_enterprise = public.current_tenant())));


--
-- Name: production_orders_runtime tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.production_orders_runtime USING ((public.is_all_tenant() OR (EXISTS ( SELECT 1
   FROM public.equipments e
  WHERE ((e.id_equipment = production_orders_runtime.id_equipment) AND (e.id_enterprise = public.current_tenant()))))));


--
-- Name: production_targets tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation ON public.production_targets USING ((public.is_all_tenant() OR (id_enterprise = public.current_tenant())));


--
-- PostgreSQL database dump complete
--

\unrestrict 2kWdUZ5czkc5UcnOMR6js9F0CrkNdrGqi7dz8kxTA863iZqLrPZ4CMf63E6cAT2

