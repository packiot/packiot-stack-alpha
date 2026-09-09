-- ============================================================================
-- t244c :: Piece C — genericize serving.data_sync shift dependency
-- Repoints the join from prod-only public.report_shift_enterprsie_06 (built by
-- update_report_shift_enterprsie_06(), absent on staging => 42P01) to the
-- new-stack pool customer_reports.shift (written by stream-engine reports/shift06
-- Shift06), fenced by customer_id = p_id_enterprise. All rse.* columns needed
-- (index1, day, line, shift_number, job_sequence, shift_duration_h,
-- setup_duration_h, dt_plan_h, dt_unplan_h, running, prss_qty, packed_qty,
-- pro_h, res_h, mnt_h) exist in customer_reports.shift. Self-contained on staging.
-- ADDITIVE: pure CREATE OR REPLACE (signature unchanged).
-- ============================================================================
SET client_min_messages = warning;
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
left join customer_reports.shift rse
on rse.index1 = eqvs.index1
and rse.customer_id = p_id_enterprise
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
