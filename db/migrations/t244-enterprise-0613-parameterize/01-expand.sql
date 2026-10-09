-- ============================================================================
-- t244 — enterprise-06/13 parameterization redesign :: Phase 0+1 EXPAND
-- ADDITIVE ONLY. Creates serving.* generic objects + config ALONGSIDE legacy.
-- Legacy objects are NOT touched. 100% reversible via rollback.sql.
-- ============================================================================
SET client_min_messages = warning;

-- ---------------------------------------------------------------------------
-- Phase 0 :: per-tenant report config (core.client_descriptors.descriptor->'reports')
-- ---------------------------------------------------------------------------
INSERT INTO core.client_descriptors (id_enterprise, tenant_code, descriptor, status)
VALUES (6, 'MONTEBELLO', jsonb_build_object('reports', '{"timezone": "America/Montreal", "site_scope": [20], "area_exclude": [24], "family": "oee_en", "cutover": "2025-02-20T16:00:00+00:00"}'::jsonb), 'draft')
ON CONFLICT (id_enterprise) DO UPDATE
  SET descriptor = jsonb_set(coalesce(core.client_descriptors.descriptor, '{}'::jsonb), '{reports}', '{"timezone": "America/Montreal", "site_scope": [20], "area_exclude": [24], "family": "oee_en", "cutover": "2025-02-20T16:00:00+00:00"}'::jsonb, true),
      updated_at = now();

INSERT INTO core.client_descriptors (id_enterprise, tenant_code, descriptor, status)
VALUES (13, 'NEOPAC', jsonb_build_object('reports', '{"timezone": "Europe/Budapest", "site_scope": [29], "family": "sap_de", "sap_sync": {"timezone": "Europe/Zurich", "site_scope": [13]}}'::jsonb), 'draft')
ON CONFLICT (id_enterprise) DO UPDATE
  SET descriptor = jsonb_set(coalesce(core.client_descriptors.descriptor, '{}'::jsonb), '{reports}', '{"timezone": "Europe/Budapest", "site_scope": [29], "family": "sap_de", "sap_sync": {"timezone": "Europe/Zurich", "site_scope": [13]}}'::jsonb, true),
      updated_at = now();

-- ---------------------------------------------------------------------------
-- Phase 0 :: config resolver + typed accessors (serving schema)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION serving.report_config(p_id_enterprise integer)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
  -- defaults overlaid by descriptor->'reports' (shallow jsonb merge, right wins)
  SELECT '{"timezone":"UTC","site_scope":[],"area_exclude":[],"family":"oee_en"}'::jsonb
       || coalesce(
            (SELECT cd.descriptor->'reports'
               FROM core.client_descriptors cd
              WHERE cd.id_enterprise = p_id_enterprise
                AND coalesce(cd.descriptor->'reports','null'::jsonb) <> 'null'::jsonb
              ORDER BY cd.version DESC NULLS LAST, cd.id DESC
              LIMIT 1),
            '{}'::jsonb);
$fn$;

CREATE OR REPLACE FUNCTION serving.report_tz(p_id_enterprise integer, p_profile text DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(
    CASE WHEN p_profile IS NOT NULL
         THEN serving.report_config(p_id_enterprise)->p_profile->>'timezone' END,
    serving.report_config(p_id_enterprise)->>'timezone',
    'UTC');
$fn$;

CREATE OR REPLACE FUNCTION serving.report_sites(p_id_enterprise integer, p_profile text DEFAULT NULL)
RETURNS integer[] LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(
    CASE WHEN p_profile IS NOT NULL THEN
      (SELECT array_agg(x::int)
         FROM jsonb_array_elements_text(serving.report_config(p_id_enterprise)->p_profile->'site_scope') AS t(x))
    END,
    (SELECT array_agg(x::int)
       FROM jsonb_array_elements_text(serving.report_config(p_id_enterprise)->'site_scope') AS t(x)),
    ARRAY[]::int[]);
$fn$;

CREATE OR REPLACE FUNCTION serving.report_areas_excluded(p_id_enterprise integer)
RETURNS integer[] LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(
    (SELECT array_agg(x::int)
       FROM jsonb_array_elements_text(serving.report_config(p_id_enterprise)->'area_exclude') AS t(x)),
    ARRAY[]::int[]);
$fn$;

CREATE OR REPLACE FUNCTION serving.report_cutover(p_id_enterprise integer)
RETURNS timestamptz LANGUAGE sql STABLE AS $fn$
  SELECT coalesce(
    (serving.report_config(p_id_enterprise)->>'cutover')::timestamptz,
    '2025-02-20 16:00:00+00'::timestamptz);
$fn$;

-- ---------------------------------------------------------------------------
-- Phase 1 :: pool target table (mirrors production_data_sync_enterprise_06 + customer_id)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS customer_reports.production_data_sync (
    customer_id             integer,
    site                    character varying,
    line                    character varying,
    shift                   character varying,
    shiftstartdate          timestamp with time zone,
    job                     bigint,
    item                    character varying,
    totalavailablehrsinmin  numeric(10,2),
    dtimehrsplannedinmin    numeric(10,2),
    dtimehrsunplannedinmin  numeric(10,2),
    unplanneddt_proinmin    numeric(10,2),
    unplanneddt_resinmin    numeric(10,2),
    unplanneddt_mntinmin    numeric(10,2),
    setuphoursinmin         numeric(10,2),
    runhoursinmin           numeric(10,2),
    presscnt                bigint,
    packcnt                 bigint,
    jobstatus               character varying,
    jobstartdate            timestamp with time zone,
    jobcompleteddate        timestamp with time zone,
    createddate             timestamp with time zone,
    updateddate             timestamp with time zone,
    packiotid               character varying,
    supervisorapproval      boolean,
    supervisorapproveddate  timestamp with time zone,
    supervisornotes         jsonb,
    nm_user_validation      character varying,
    id_validation           bigint,
    ts_creation             timestamp with time zone,
    to_delete               boolean,
    last_update             timestamp with time zone,
    packml_topic            character varying,
    indice_geral            bigint,
    trans_status            character varying,
    logics                  integer,
    real_update             timestamp with time zone,
    prev_indice_geral       bigint,
    final_trans_status      character varying
);

-- ---------------------------------------------------------------------------
-- Phase 1 :: generic compute functions (serving schema)
-- NOTE: intentionally NO 'SET search_path' — mirrors legacy resolution against
-- the session medallion path (equipments->core, equipment_events->silver, ...).
-- ---------------------------------------------------------------------------
-- data_sync joins the per-enterprise materialized table report_shift_enterprsie_06,
-- which is absent on staging (present on prod). The LEGACY fn has the same reference
-- and also fails at runtime on staging. Disable body validation so CREATE succeeds
-- everywhere; runtime behavior is identical to legacy.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION serving.data_sync(p_id_enterprise integer, p_numdays integer DEFAULT NULL::integer)
RETURNS TABLE(site character varying, line character varying, shift character varying,
    shiftstartdate timestamp with time zone, job bigint, item character varying,
    totalavailablehrsinmin numeric(10,2), dtimehrsplannedinmin numeric(10,2), dtimehrsunplannedinmin numeric(10,2),
    unplanneddt_proinmin numeric(10,2), unplanneddt_resinmin numeric(10,2), unplanneddt_mntinmin numeric(10,2),
    setuphoursinmin numeric(10,2), runhoursinmin numeric(10,2), presscnt bigint, packcnt bigint,
    jobstatus character varying, jobstartdate timestamp with time zone, jobcompleteddate timestamp with time zone,
    createddate timestamp with time zone, updateddate timestamp with time zone, packiotid character varying,
    supervisorapproval boolean, supervisorapproveddate timestamp with time zone, supervisornotes jsonb,
    nm_user_validation character varying, id_validation bigint, ts_creation timestamp with time zone,
    to_delete boolean, last_update timestamp with time zone, packml_topic character varying,
    last_update_prod_data timestamp with time zone)
LANGUAGE sql STABLE AS $function$
SELECT
  c1::character varying,
  c2::character varying,
  c3::character varying,
  c4::timestamp with time zone,
  c5::bigint,
  c6::character varying,
  c7::numeric(10,2),
  c8::numeric(10,2),
  c9::numeric(10,2),
  c10::numeric(10,2),
  c11::numeric(10,2),
  c12::numeric(10,2),
  c13::numeric(10,2),
  c14::numeric(10,2),
  c15::bigint,
  c16::bigint,
  c17::character varying,
  c18::timestamp with time zone,
  c19::timestamp with time zone,
  c20::timestamp with time zone,
  c21::timestamp with time zone,
  c22::character varying,
  c23::boolean,
  c24::timestamp with time zone,
  c25::jsonb,
  c26::character varying,
  c27::bigint,
  c28::timestamp with time zone,
  c29::boolean,
  c30::timestamp with time zone,
  c31::character varying,
  c32::timestamp with time zone
FROM (
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
    --rse.shift_start_time at time zone serving.report_tz(p_id_enterprise) as ShiftStartDate, 
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
on eqvs.cd_equipment = eq.nm_equipment and eq.id_enterprise = p_id_enterprise and eq.tp_equipment = 3
left join sites s
on eq.id_site = s.id_site
left join production_orders po
on po.id_equipment = eq.id_equipment 
and po.id_order = eqvs.id_order
and po.id_enterprise = p_id_enterprise
and po.last_update >= now() - interval '5 month'  --de 3 pra 4 edu 10-fev-25)
left join production_orders_runtime por
on por.id_equipment = eq.id_equipment 
and po.id_production_order = por.id_production_order 
and lower(por.runtime_timerange) at time zone serving.report_tz(p_id_enterprise) = rse.job_sequence
and por.runtime_timerange && tstzrange(now() - interval '6 month', now())--de 4 pra 5 edu 10-fev-25)
left join packml_register pr
on pr.id_equipment = eq.id_equipment
and pr.id_enterprise = p_id_enterprise
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
        where day >= (now() at time zone serving.report_tz(p_id_enterprise))::date - coalesce(p_numdays,21)*(interval '1 day')
        and day <= (now() at time zone serving.report_tz(p_id_enterprise))::date
) AS s(c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13,c14,c15,c16,c17,c18,c19,c20,c21,c22,c23,c24,c25,c26,c27,c28,c29,c30,c31,c32)
$function$;

RESET check_function_bodies;

CREATE OR REPLACE FUNCTION serving.downtime_sync(p_id_enterprise integer)
RETURNS TABLE(nm_site character varying, nm_equipment character varying, id_order integer, sector character varying,
    cd_shift character varying, ts_event timestamp with time zone, ts_end timestamp with time zone, duration integer,
    cd_machine character varying, cd_category_client integer, cd_category character varying, desc_category character varying,
    cd_subcategory_client integer, cd_subcategory character varying, desc_subcategory character varying,
    txt_downtime_notes character varying, pack_id bigint, packml_topic character varying, last_update timestamp with time zone,
    dt_type text, dt_subtype text, mnt_trigger boolean, methodtype text)
LANGUAGE sql STABLE AS $function$
with stops as (
select 
	(select stop_threshold_time from equipments where id_equipment = eqev.id_equipment and id_enterprise = p_id_enterprise) as stop_threshold_time,
	eqev.*,
	false as manual_stop
from equipment_events eqev
	where eqev.id_enterprise = p_id_enterprise
	and eqev.ts_event >= now() - interval '15 day'
	and status = 10
	and id_equipment in (select id_equipment from equipments where id_enterprise = p_id_enterprise and event_should_be_displayed = true)
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
	where id_enterprise = p_id_enterprise
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
	and id_equipment not in (select id_equipment from equipments where id_site = any(serving.report_sites(p_id_enterprise)) and tp_equipment = 3)
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
	where id_enterprise = p_id_enterprise
	and id_line = any(select e.id_equipment from equipments e where id_enterprise = p_id_enterprise) 
	and last_update >= now() - interval '6 hour'
order by last_update desc
--order by nm_equipment, MethodType
limit 5000
$function$;


CREATE OR REPLACE FUNCTION serving.report_shift(p_id_enterprise integer, startdate date, enddate date)
RETURNS TABLE(line character varying, shift character varying, turno_hrs text, day date, job bigint, shift_duration_h numeric, dt_duration_h numeric, setup_duration_h numeric, running numeric, prss_qty double precision, packed_qty double precision, shift_number integer, job_sequence timestamp without time zone, dt_plan_h numeric, dt_unplan_h numeric, shift_start_time timestamp without time zone, index1 text, id_equipment integer, pro_h numeric, res_h numeric, mnt_h numeric, discart_h numeric, index2 jsonb)
LANGUAGE sql STABLE AS $function$
--novo report 
--versao anterior de 2023-10-05 funcionando, salva por eduardo
--novo report 
with dias as (
SELECT 
	--(generate_series((now() at time zone serving.report_tz(p_id_enterprise))::date - interval '21 day', (now() at time zone serving.report_tz(p_id_enterprise))::date,'1 day'))::date as start_day
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
	concat(to_char(((ts_value at time zone serving.report_tz(p_id_enterprise))::time),'HH24:MI'),'-', to_char(((ts_end at time zone serving.report_tz(p_id_enterprise))::time),'HH24:MI')) as turno_hrs,
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
where id_equipment in (select id_equipment from equipments where id_enterprise = p_id_enterprise and tp_equipment = 3 and id_area <> all(serving.report_areas_excluded(p_id_enterprise)))
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
and e.id_equipment in (select id_equipment from equipments where id_enterprise = p_id_enterprise and tp_equipment in (1,2))
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
where id_equipment in (select id_equipment from equipments where id_enterprise = p_id_enterprise and tp_equipment = 3)
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
	where id_equipment in (select id_equipment from equipments where id_enterprise = p_id_enterprise and tp_equipment = 3)
	and ts_value >= now()- interval '30 day'
	and ts_value >= startdate - interval '1 day'
	and ts_value <= enddate + interval '1 day'
	and id_enterprise = p_id_enterprise
	and id_site in (select id_site from sites where id_enterprise = p_id_enterprise)
	and id_area in (select id_area from areas where id_enterprise = p_id_enterprise and id_area <> all(serving.report_areas_excluded(p_id_enterprise)))
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
where porun.id_equipment in (select id_equipment from equipments where id_enterprise = p_id_enterprise and tp_equipment = 3 and id_area <> all(serving.report_areas_excluded(p_id_enterprise)))
and po.id_equipment = porun.id_equipment
and po.id_enterprise = p_id_enterprise
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
	where ca.id_equipment in (select id_equipment from equipments where id_enterprise = p_id_enterprise and cast(custom::json#>>'{Label,has_labels}' as BOOLEAN) is true and id_area <> all(serving.report_areas_excluded(p_id_enterprise)))
	and ca.id_enterprise = p_id_enterprise
	and ca.id_site in (select id_site from sites where id_enterprise = p_id_enterprise)
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
	tsrange(po.job_start at time zone serving.report_tz(p_id_enterprise), po.ts_end_progress at time zone serving.report_tz(p_id_enterprise)) as ran,
	ts_end_progress
from prod_orders po
where po.id_equipment in (select id_equipment from equipments where id_enterprise = p_id_enterprise and tp_equipment = 3)
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
	tsrange(tz_start at time zone serving.report_tz(p_id_enterprise),tz_end at time zone serving.report_tz(p_id_enterprise)) as tz_range
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
	tsrange(ts_start at time zone serving.report_tz(p_id_enterprise),now() at time zone serving.report_tz(p_id_enterprise)) as tz_range
from production_orders po 
where id_site = any(serving.report_sites(p_id_enterprise))
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
				and id_enterprise = p_id_enterprise and id_area <> all(serving.report_areas_excluded(p_id_enterprise)) and nm_equipment not like '%PRESS%')
and eqv.status = 10
and eqv.id_enterprise = p_id_enterprise
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
	lower(pos.runtime_timerange_new) at time zone serving.report_tz(p_id_enterprise) as job_sequence, --mudar
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
	ppf.shift_start_time at time zone serving.report_tz(p_id_enterprise) as shift_start_time,
	concat(
	TO_CHAR(eq.id_equipment, 'FM0000'),
	TO_CHAR(coalesce(ppf.id_order,0), 'FM0000000'),
	TO_CHAR(ppf.shift_start_time at time zone serving.report_tz(p_id_enterprise),'YYYYMMDDHH24')) as index1
from press_packed_final ppf
left join equipments eq
on ppf.id_equipment = eq.id_equipment
and eq.id_enterprise = p_id_enterprise
and eq.tp_equipment = 3
left join shifts shi
on shi.id_shift = ppf.id_shift
and shi.id_enterprise = p_id_enterprise
left join po_sequence pos
on ppf.id_order = pos.id_order --mudar
and tstzrange(ppf.shift_start_time,ppf.shift_start_time +interval '12 hour') && pos.runtime_timerange_new --mudar
), validation as (
SELECT evs.*,
(txt_validation_notes->'LastConfirm'->>'ts_confirm')::timestamp at time zone 'UTC' at time zone serving.report_tz(p_id_enterprise) as ts_confirma,
		case when txt_validation_notes is not null then 
  			concat(
  		to_char((txt_validation_notes->'LastConfirm'->>'ts_confirm')::timestamp at time zone 'UTC' at time zone serving.report_tz(p_id_enterprise),'YYYY-MM-DD HH24:MI'),' | ',
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
		(value->>'ts_confirm')::timestamp at time zone 'UTC' at time zone serving.report_tz(p_id_enterprise) as ts_confirma,
		case when txt_validation_notes is not null then 
  			concat(
  		to_char((value->>'ts_confirm')::timestamp at time zone 'UTC' at time zone serving.report_tz(p_id_enterprise),'YYYY-MM-DD HH24:MI'),' | ',
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
$function$;


CREATE OR REPLACE FUNCTION serving.production_data_sync(p_id_enterprise integer)
RETURNS TABLE(uniqueid bigint, previousuniqueid bigint, packiotid character varying, site character varying,
    line character varying, shift character varying, shiftstartdate timestamp without time zone, job integer,
    item character varying, totalavailablehrsinmin numeric(10,2), dtimehrsplannedinmin numeric(10,2),
    dtimehrsunplannedinmin numeric(10,2), unplanneddt_proinmin numeric(10,2), unplanneddt_resinmin numeric(10,2),
    unplanneddt_mntinmin numeric(10,2), setuphoursinmin numeric(10,2), runhoursinmin numeric(10,2),
    presscnt integer, packcnt integer, jobstatus character varying, jobstartdate timestamp without time zone,
    jobcompleteddate timestamp without time zone, transstatus character varying, supervisorapproval integer,
    supervisorapproveddate timestamp without time zone, supervisornotes text, last_update timestamp with time zone)
LANGUAGE sql STABLE AS $function$
SELECT pdse.indice_geral AS uniqueid,
    pdse.prev_indice_geral AS previousuniqueid,
    pdse.packiotid,
    pdse.site,
    pdse.line,
    pdse.shift,
    date_trunc('second'::text, timezone(serving.report_tz(p_id_enterprise), pdse.shiftstartdate)) AS shiftstartdate,
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
    date_trunc('second'::text, timezone(serving.report_tz(p_id_enterprise), pdse.jobstartdate)) AS jobstartdate,
    date_trunc('second'::text, timezone(serving.report_tz(p_id_enterprise), pdse.jobcompleteddate)) AS jobcompleteddate,
    pdse.final_trans_status AS transstatus,
        CASE
            WHEN pdse.supervisorapproval IS TRUE THEN 1
            ELSE 0
        END AS supervisorapproval,
    date_trunc('second'::text, timezone(serving.report_tz(p_id_enterprise), pdse.supervisorapproveddate)) AS supervisorapproveddate,
    pdse.supervisornotes::text AS supervisornotes,
    date_trunc('second'::text, pdse.real_update) AS last_update
   FROM customer_reports.production_data_sync pdse
  WHERE pdse.customer_id = p_id_enterprise AND pdse.shiftstartdate >= (now() - '21 days'::interval) AND (pdse.final_trans_status::text <> ALL (ARRAY['H'::character varying::text, 'D'::character varying::text])) AND pdse.shiftstartdate <= serving.report_cutover(p_id_enterprise)
UNION ALL
 SELECT pdse.indice_geral AS uniqueid,
    pdse.prev_indice_geral AS previousuniqueid,
    pdse.packiotid,
    pdse.site,
    pdse.line,
    pdse.shift,
    date_trunc('second'::text, timezone(serving.report_tz(p_id_enterprise), pdse.shiftstartdate)) AS shiftstartdate,
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
    date_trunc('second'::text, timezone(serving.report_tz(p_id_enterprise), pdse.jobstartdate)) AS jobstartdate,
    date_trunc('second'::text, timezone(serving.report_tz(p_id_enterprise), pdse.jobcompleteddate)) AS jobcompleteddate,
    pdse.final_trans_status AS transstatus,
        CASE
            WHEN pdse.supervisorapproval IS TRUE THEN 1
            ELSE 0
        END AS supervisorapproval,
    date_trunc('second'::text, timezone(serving.report_tz(p_id_enterprise), pdse.supervisorapproveddate)) AS supervisorapproveddate,
    pdse.supervisornotes::text AS supervisornotes,
    date_trunc('second'::text, pdse.real_update) AS last_update
   FROM customer_reports.production_data_sync pdse
  WHERE pdse.customer_id = p_id_enterprise AND pdse.shiftstartdate >= (now() - '365 days'::interval) AND pdse.shiftstartdate > serving.report_cutover(p_id_enterprise) AND pdse.real_update >= (now() - '06:00:00'::interval)
  ORDER BY 27 DESC
$function$;


CREATE OR REPLACE FUNCTION serving.sap_site_report(p_id_enterprise integer, p_id_equipment integer)
RETURNS TABLE(line character varying, shift character varying, shift_hrs text, day date, job bigint,
    gross double precision, net double precision, gyartasi_ido numeric(10,2), beallitasi_ido numeric(10,2),
    muszaki_hiba numeric(10,2), tervezett_karb numeric(10,2), anyagproblema numeric(10,2),
    nem_indokolt_ido numeric(10,2), total_dt numeric(10,2), job_start timestamp without time zone,
    shift_start_time timestamp without time zone, shift_number integer, id_equipment integer, id_eterprise integer)
LANGUAGE sql STABLE AS $function$
WITH dias AS (
         SELECT generate_series(timezone(serving.report_tz(p_id_enterprise), now())::date - '3 days'::interval, timezone(serving.report_tz(p_id_enterprise), now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone(serving.report_tz(p_id_enterprise), equipment_oee_shift.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone(serving.report_tz(p_id_enterprise), equipment_oee_shift.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            equipment_oee_shift.ts_value AS shift_start_time,
            equipment_oee_shift.id_equipment,
            equipment_oee_shift.cd_shift,
            equipment_oee_shift.id_shift,
            equipment_oee_shift.ts_value_production,
            equipment_oee_shift.ts_value AS tz_value,
                CASE
                    WHEN equipment_oee_shift.ts_end > now() THEN now()
                    ELSE equipment_oee_shift.ts_end
                END AS tz_end
           FROM equipment_oee_shift,
            start_counting_day scd
          WHERE (equipment_oee_shift.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.tp_equipment = 3 AND equipments.id_site = any(serving.report_sites(p_id_enterprise)))) AND equipment_oee_shift.ts_value_production >= scd.start_day AND equipment_oee_shift.ts_value < now()
          ORDER BY equipment_oee_shift.id_equipment, equipment_oee_shift.ts_value
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
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise)) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
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
                  WHERE equipments_1.id_enterprise = p_id_enterprise AND equipments_1.id_site = any(serving.report_sites(p_id_enterprise)) AND equipments_1.tp_equipment = 3))
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
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise)) AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min.ts_value >= (now() - '3 days'::interval) AND agg_equipment_values_1min.ts_value >= scd.start_day AND agg_equipment_values_1min.id_enterprise = p_id_enterprise AND agg_equipment_values_1min.id_site = any(serving.report_sites(p_id_enterprise))
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
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.tp_equipment = 3 AND equipments.id_site = any(serving.report_sites(p_id_enterprise)))) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = p_id_enterprise AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
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
                  WHERE equipments_1.id_enterprise = p_id_enterprise AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = any(serving.report_sites(p_id_enterprise))))
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
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'Infinity'::double precision) THEN 5
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = p_id_enterprise AND e.tp_equipment = 3 AND e.id_site = any(serving.report_sites(p_id_enterprise))
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description AND ee.id_equipment = dc.id_equipment
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '15 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '3 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise)) AND equipments.tp_equipment = 3))
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
            COALESCE(ppf.press_count::double precision, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor::double precision, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            timezone(serving.report_tz(p_id_enterprise), ppf.shift_start_time) AS shift_start_time,
            timezone(serving.report_tz(p_id_enterprise), lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = p_id_enterprise AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = p_id_enterprise
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
    p_id_enterprise AS id_eterprise
   FROM shift_report
  WHERE shift_report.id_equipment = p_id_equipment AND shift_report.day >= (timezone(serving.report_tz(p_id_enterprise), now()) - '2 days'::interval)
$function$;


CREATE OR REPLACE FUNCTION serving.sap_report_data_sync(p_id_enterprise integer)
RETURNS TABLE(linie character varying, tag date, shicht character varying, shicht_nummer integer,
    auftrag bigint, sum_labels double precision, rumpfe double precision, gutmenge double precision,
    rustzeit numeric, produktionszeit numeric, geplante_ausfallzeit numeric, ungeplante_ausfallzeit numeric,
    matfehler_ausfallzeit numeric, no_order numeric, auftrag_startzeit timestamp without time zone,
    running_h numeric, shift_start_time timestamp with time zone, data_type text, id_order_label text)
LANGUAGE sql STABLE AS $function$
WITH dias AS (
         SELECT generate_series(timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), now())::date - '4 days'::interval, timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
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
           FROM equipment_oee_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.tp_equipment = 3 AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')))) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
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
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
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
                  WHERE equipments_1.id_enterprise = p_id_enterprise AND equipments_1.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND equipments_1.tp_equipment = 3))
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
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval) AND agg_equipment_values_1min.ts_value >= scd.start_day AND agg_equipment_values_1min.id_enterprise = p_id_enterprise AND agg_equipment_values_1min.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync'))
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
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.tp_equipment = 3 AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')))) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = p_id_enterprise AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
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
                  WHERE equipments_1.id_enterprise = p_id_enterprise AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync'))))
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
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'Infinity'::double precision) THEN 5
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
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = p_id_enterprise AND e.tp_equipment = 3 AND e.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync'))
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '4 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND equipments.tp_equipment = 3))
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
            COALESCE(ppf.press_count::double precision, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor::double precision, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = p_id_enterprise AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = p_id_enterprise
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '4 days'::interval)
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
          WHERE final10.tag >= (timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), now()) - '3 days'::interval)
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
   FROM v_sap_report_data_sync_customer_13_deb
$function$;


CREATE OR REPLACE FUNCTION serving.overview_takt(p_id_enterprise integer)
RETURNS TABLE(id_equipment integer, id_enterprise integer, id_site integer, avg_speed integer)
LANGUAGE sql STABLE AS $function$
  SELECT id_equipment, id_enterprise, id_site, avg_speed
  FROM v_13_overview_takt
  WHERE id_enterprise = p_id_enterprise
$function$;

CREATE OR REPLACE FUNCTION serving.overview_scrap_rate(p_id_enterprise integer)
RETURNS TABLE(cd_equipment character varying, id_enterprise integer, id_site integer, id_equipment integer,
              gross double precision, net double precision, scrap double precision, scrap_rate numeric)
LANGUAGE sql STABLE AS $function$
  SELECT cd_equipment, id_enterprise, id_site, id_equipment, gross, net, scrap, scrap_rate
  FROM v_13_overview_partial_scrap_rate
  WHERE id_enterprise = p_id_enterprise
$function$;

