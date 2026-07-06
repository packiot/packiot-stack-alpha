-- ADR-0012 Wave 2 prep — prod writer function definitions (ground truth)
--
-- Captured 2026-07-02 from prod tsp12 via pg_get_functiondef (SELECT-only,
-- BEGIN READ ONLY). These 9 bodies (8 names; get_data_sync_enterprsie_06
-- has 2 overloads) are the complete writer set for the 3 live Wave 1/2
-- objects. Wave 2 edits these to dual-write the customer_reports pool
-- tables — read each here BEFORE editing; check ADR-0014's port list
-- first (single-port rule: anything scheduled for a Go port gets ported
-- once, directly to pool shape).

-- ===FUNC=== c33_speed_per_job_insert_into_report()
CREATE OR REPLACE PROCEDURE public.c33_speed_per_job_insert_into_report()
 LANGUAGE plpgsql
AS $procedure$
    INSERT INTO report_speed_enterprsie_33(
        id_equipment, id_order, id_product, production_programmed, production_final, avg_speed, final_net, job_start, product_type)
    (WITH data AS (
        SELECT id_equipment, ts_value, speed, net_production_incr 
        FROM equipment_values
        WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = 33 AND tp_equipment = 3)
        AND id_enterprise = 33
        AND ts_value >= NOW() - INTERVAL '5 day' 
        AND speed >= 150
        AND net_production_val IS NOT NULL
        ORDER BY ts_value
    ), speed AS (
        SELECT po.id_equipment, po.id_order, po.id_product, po.production_programmed, po.production_final, po.ts_start AS job_start,
            CASE 
                WHEN SUBSTRING(po.txt_production_order_description, (length(po.txt_production_order_description) - position(reverse('KG') in reverse(po.txt_production_order_description)))+2) = '' 
                THEN SUBSTRING(po.txt_production_order_description, (length(po.txt_production_order_description) - position(reverse(' ') in reverse(po.txt_production_order_description)))+2)
                ELSE SUBSTRING(po.txt_production_order_description, (length(po.txt_production_order_description) - position(reverse('KG') in reverse(po.txt_production_order_description)))+2)
            END AS product_type,
            AVG(d.speed)::NUMERIC(4,1) AS avg_speed,
            SUM(d.net_production_incr)::BIGINT AS final_net,
            (SUM(d.net_production_incr) / po.production_final) AS indice
        FROM production_orders po
        JOIN data d ON po.id_equipment = d.id_equipment
        WHERE d.ts_value >= po.ts_start 
        AND d.ts_value < po.ts_end 
        AND po.id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = 33 AND tp_equipment = 3)
        AND po.ts_start >= NOW() - INTERVAL '5 day' 
        AND po.status > 2
        AND po.id_order NOT IN (SELECT id_order FROM report_speed_enterprsie_33)
        GROUP BY po.id_equipment, po.id_order, po.id_product, po.production_programmed, po.production_final, po.ts_start, product_type
    )
    SELECT id_equipment, id_order, id_product, production_programmed, production_final, avg_speed, final_net, job_start, product_type
    FROM speed 
    WHERE indice BETWEEN 0.25 AND 4);
END;
$procedure$


-- ===FUNC=== get_data_sync_enterprsie_06(numdays integer)
CREATE OR REPLACE FUNCTION public.get_data_sync_enterprsie_06(numdays integer DEFAULT NULL::integer)
 RETURNS SETOF data_sync_enterprise_06
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
    ((rse.shift_duration_h-rse.setup_duration_h-rse.dt_plan_h)*60)::NUMERIC(10,2) as TotalHoursinMin,
    ((rse.dt_plan_h)*60)::NUMERIC(10,2) as DTimeHrsPlannedinMin,
    ((rse.dt_unplan_h)*60)::NUMERIC(10,2) as DTimeHrsUnPlannedinMin,
    ((rse.setup_duration_h)*60)::NUMERIC(10,2) as SetupHoursinMin,
    ((rse.running)*60)::NUMERIC(10,2) as RunHoursinMin,
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
 	eqvs.last_update
from equipment_validation_shift eqvs --(aqui paga do relatorio)
left join report_shift_enterprsie_06 rse
on rse.index1 = eqvs.index1
and rse.day >= now() - interval '41 day'
left join equipments eq
on eqvs.cd_equipment = eq.nm_equipment and eq.id_enterprise = 6 and eq.tp_equipment = 3
left join sites s
on eq.id_site = s.id_site
left join production_orders po
on po.id_equipment = eq.id_equipment 
and po.id_order = eqvs.id_order
and po.id_enterprise = 6
and po.last_update >= now() - interval '3 month'
left join production_orders_runtime por
on por.id_equipment = eq.id_equipment 
and po.id_production_order = por.id_production_order 
and lower(por.runtime_timerange) at time zone 'America/Montreal' = rse.job_sequence
and por.runtime_timerange && tstzrange(now() - interval '3 month', now())
left join packml_register pr
on pr.id_equipment = eq.id_equipment
where eqvs.ts_value_production >= now() - interval '40 day'
order by rse.line, rse.day desc, rse.shift_number desc, rse.job_sequence desc
)
        select 
        	index1 as PackIOTID,
            Site,
            line,
            shift,
            ShiftStartDate,
            job,
            TotalHoursinMin,
            DTimeHrsPlannedinMin,
            DTimeHrsUnPlannedinMin,
            SetupHoursinMin,
            RunHoursinMin,
            PressCnt,
            PackCnt,
            packml_topic,
            JobStatus,
            JobStartDate,
            JobCompletedDate,
            CreatedDate,
            UpdatedDate,			
    		cd_product as Item,				--esse eh a info do produto que a celine pediu
    		ts_user_validation as SupervisorApprovedDate,		--timestamp do horario da valiação os dados
 			txt_validation_notes as SupervisorNotes,	--o note que o supervisor escreveu na validacao dos dados
 			validation as Approved,				-- true para validado
 			nm_user_validation,		--login do usuário que validou os dados no operator
 			id_validation,			--esse é um id sequencial que em na tabela validation (acho que não precisa)
 			ts_creation,			--timestamp do hoario que a linha de dados foi criada na tabela validation (acho que não precisa)
 			to_delete,				--true para linhas de dados que deixaram de existir
 			last_update				--se houve algum update nos ultimos 21 dias, este horario se reflete aqui. A diferença deste é que olha linha por linha de dados enquanto o UpdatedDate anterior muda por OP
        from data_sync
        --where day >= StartDate
        --and day <= EndDate
        where day >= (now() at time zone 'America/Montreal')::date - coalesce(NumDays,21)*(interval '1 day')
        and day <= (now() at time zone 'America/Montreal')::date

$function$


-- ===FUNC=== get_data_sync_enterprsie_06(startdate date, enddate date)
CREATE OR REPLACE FUNCTION public.get_data_sync_enterprsie_06(startdate date, enddate date)
 RETURNS SETOF data_sync_enterprise_06
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
    rse.shift_start_time at time zone 'UTC' as ShiftStartDate,
    eqvs.id_order as job,
    ((rse.shift_duration_h-rse.setup_duration_h-rse.dt_plan_h)*60)::NUMERIC(10,2) as TotalHoursinMin,
    ((rse.dt_plan_h)*60)::NUMERIC(10,2) as DTimeHrsPlannedinMin,
    ((rse.dt_unplan_h)*60)::NUMERIC(10,2) as DTimeHrsUnPlannedinMin,
    ((rse.setup_duration_h)*60)::NUMERIC(10,2) as SetupHoursinMin,
    ((rse.running)*60)::NUMERIC(10,2) as RunHoursinMin,
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
    (po.custom_field ->> 'cd_product')::varchar(25) AS cd_product,
 	eqvs.txt_validation_notes,
 	eqvs.validation::bool,
 	eqvs.ts_user_validation,
 	eqvs.nm_user_validation::varchar(15),
 	eqvs.id_validation::bigint,
 	eqvs.ts_creation,
 	eqvs.to_delete,
 	eqvs.last_update
from equipment_validation_shift eqvs --(aqui paga do relatorio)
left join report_shift_enterprsie_06 rse
on rse.index1 = eqvs.index1
and rse.day >= now() - interval '41 day'
left join equipments eq
on eqvs.cd_equipment = eq.nm_equipment and eq.id_enterprise = 6 and eq.tp_equipment = 3
left join sites s
on eq.id_site = s.id_site
left join production_orders po
on po.id_equipment = eq.id_equipment 
and po.id_order = eqvs.id_order
and po.id_enterprise = 6
and po.last_update >= now() - interval '3 month'
left join production_orders_runtime por
on por.id_equipment = eq.id_equipment 
and po.id_production_order = por.id_production_order 
and lower(por.runtime_timerange) at time zone 'America/Montreal' = rse.job_sequence
and por.runtime_timerange && tstzrange(now() - interval '3 month', now())
left join packml_register pr
on pr.id_equipment = eq.id_equipment
where eqvs.ts_value_production >= now() - interval '40 day'
order by rse.line, rse.day desc, rse.shift_number desc, rse.job_sequence desc
)
        select 
        	index1 as PackIOTID,
            Site,
            line,
            shift,
            ShiftStartDate,
            job,
            TotalHoursinMin,
            DTimeHrsPlannedinMin,
            DTimeHrsUnPlannedinMin,
            SetupHoursinMin,
            RunHoursinMin,
            PressCnt,
            PackCnt,
            packml_topic,
            JobStatus,
            JobStartDate,
            JobCompletedDate,
            CreatedDate,
            UpdatedDate,			
    		cd_product as Item,				--esse eh a info do produto que a celine pediu
    		ts_user_validation as SupervisorApprovedDate,		--timestamp do horario da valiação os dados
 			txt_validation_notes as SupervisorNote,	--o note que o supervisor escreveu na validacao dos dados
 			validation,				-- true para validado
 			nm_user_validation,		--login do usuário que validou os dados no operator
 			id_validation,			--esse é um id sequencial que em na tabela validation (acho que não precisa)
 			ts_creation,			--timestamp do hoario que a linha de dados foi criada na tabela validation (acho que não precisa)
 			to_delete,				--true para linhas de dados que deixaram de existir
 			last_update				--se houve algum update nos ultimos 21 dias, este horario se reflete aqui. A diferença deste é que olha linha por linha de dados enquanto o UpdatedDate anterior muda por OP
        from data_sync
        where day >= StartDate
        and day <= EndDate

$function$


-- ===FUNC=== get_data_sync_enterprsie_06b(numdays integer)
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


-- ===FUNC=== piot_cust_speed_product_client_33()
CREATE OR REPLACE FUNCTION public.piot_cust_speed_product_client_33()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
	DECLARE
		r RECORD;
		r_ca RECORD;
	begin
		FOR r in
		select po.*
		from production_orders po
		where id_enterprise = 33
		--and status = 3
		--and ts_start >= now() - interval '300 hour'
		and status = 2
		and ts_start >= now() - interval '3 day'
		and txt_production_order_notes is null
		loop
WITH RankedSpeeds AS (
    SELECT 
        id_equipment,
        id_product,

        avg_speed,
        COUNT(*) OVER (PARTITION BY id_equipment, id_product) AS freq,
        ROW_NUMBER() OVER (PARTITION BY id_equipment, id_product ORDER BY avg_speed DESC) AS speed_rank
    FROM 
        report_speed_enterprsie_33
), FINAL AS (
SELECT 
	eq.nm_equipment,
    rs.id_equipment,
    rs.id_product,
    rs.freq,
    STRING_AGG(rs.avg_speed::int::TEXT, ', ' ORDER BY rs.avg_speed DESC) AS top_speeds -- Concatenates top speeds
FROM 
    RankedSpeeds rs
LEFT JOIN 
	equipments eq
ON eq.id_equipment = rs.id_equipment
AND eq.id_enterprise = 33
WHERE 
    rs. speed_rank <= 3
GROUP BY 
    eq.nm_equipment,rs.id_equipment, rs.id_product, rs.freq
ORDER BY 
    rs.id_product,rs.id_equipment
), final2 as (
SELECT f.*, p.txt_product,
concat('Este produto já foi produzido ',
		freq, 
		case when freq = 1 THEN ' vez na ' ELSE ' vezes na ' END,
		f.nm_equipment,
		case when freq = 1 THEN ' sendo que a velocidade média de produção foi de: '  ELSE ' sendo que as maiores velocidades médias de produção foram de: ' END,
		top_speeds, ' m/min.') as texto,
concat(f.nm_equipment,'; Quantidade repetições: ',freq,'; Velocidades: ', top_speeds, ' m/min') as texto2
FROM FINAL f
LEFT JOIN products p 
ON p.id_product = f.id_product
AND p.id_enterprise = 33
)
SELECT 
    STRING_AGG(texto2, ' | ') AS final_result -- Concatenates all rows into one string
 into r_ca
 from final2
	where id_product = r.id_product;
if found THEN
				update production_orders po
					set txt_production_order_notes = r_ca.final_result
					where id_order = r.id_order
						and id_enterprise = 33;
				-- If no rows found, set the note to 'no runs yet'
			ELSE
				-- If no rows found, set the note to 'no runs yet'
				UPDATE production_orders po
					SET txt_production_order_notes = 'no runs yet'
					WHERE id_order = r.id_order
					AND id_enterprise = 33;
			end if;
		end loop;
	
	end
$function$


-- ===FUNC=== update_equipment_validation_shift()
CREATE OR REPLACE PROCEDURE public.update_equipment_validation_shift()
 LANGUAGE plpgsql
AS $procedure$
begin
--delete from report_shift_enterprsie_06
--where day >= (now() at time zone 'America/Montreal')::date - interval '6 day';

insert into equipment_validation_shift(index1, index2, id_enterprise, id_equipment, 
cd_equipment, ts_value_production, cd_shift, shift_hrs, id_order, txt_validation_notes, 
validation, ts_user_validation, nm_user_validation,ts_creation,to_delete,last_update, shift_start_time)
(with new_shift_validation_data as (
select concat(
	TO_CHAR(eq.id_equipment, 'FM0000'),
	TO_CHAR(coalesce(rp.job,0), 'FM0000000'),
	TO_CHAR(rp.shift_start_time,'YYYYMMDDHH24')) as index1,
--((coalesce(shift_duration_h*3600,0))::int + (coalesce(setup_duration_h*3600,0))::int +(coalesce(2*running*3600,0))::int + 
--(coalesce(dt_plan_h*3600,0))::int -(coalesce(0.5*dt_unplan_h*3600,0))::int + coalesce(prss_qty::int,0) + coalesce(packed_qty::int,0)) as index2,
	jsonb_build_object(
   	   '0', line,
       '1', (shift_duration_h)::numeric(10,4),
       '2', (dt_duration_h)::numeric(10,4),
       '3', (setup_duration_h)::numeric(10,4),
       '4', (running)::numeric(10,4),
       '5', prss_qty::int,
       '6', packed_qty::int,
       '7', (dt_unplan_h)::numeric(10,4),
       '8', (dt_plan_h)::numeric(10,4),
       '9', (pro_h)::numeric(10,4),
       '10', (res_h)::numeric(10,4),
       '11', (mnt_h)::numeric(10,4)
   ) AS index2,
eq.id_enterprise,
eq.id_equipment,
eq.cd_equipment,
rp.day as ts_value_production,
rp.shift as cd_shift,
rp.turno_hrs as shift_hrs,
rp.job as id_order,
null::jsonb as txt_validation_notes,
false as validation,
null::timestamptz as ts_user_validation,
null::varchar as nm_user_validation,
rp.shift_start_time
from public.get_report_shift_enterprsie_06c((now() at time zone 'America/Montreal' - interval '21 day')::date, (now() at time zone 'America/Montreal')::date) rp
left join equipments eq 
on eq.cd_equipment = rp.line
and eq.id_enterprise = 6
and eq.tp_equipment = 3
order by 5,6,job_sequence
)
select 
	nsvd.index1,
	nsvd.index2,
	nsvd.id_enterprise,
	nsvd.id_equipment,
	nsvd.cd_equipment,
	nsvd.ts_value_production,
	nsvd.cd_shift,
	nsvd.shift_hrs,
	nsvd.id_order,
	nsvd.txt_validation_notes,
	nsvd.validation,
	nsvd.ts_user_validation,
	nsvd.nm_user_validation,
	now() as ts_creation,
	false as to_delete,
	now() as last_update,
	shift_start_time at time zone 'America/Montreal' as shift_start_time
from new_shift_validation_data nsvd
	where nsvd.index1 not in (
					select index1
					from equipment_validation_shift
					where ts_value_production >= now() - interval '23 day'
					));
				
commit;

UPDATE equipment_validation_shift
SET to_delete = true,
	last_update = now()
WHERE index1 in (
				with validation as (
				select *
				from equipment_validation_shift evs 
				where ts_value_production >= now() - interval '21 day'
				--and ts_value_production <= now() - interval '1 day'
				and ts_creation <= now() - interval '5 hour' --pra garantir que o report ja estava atualizado, q rodou ao menos 2 vezes.
				), report as (
				select --concat(
					--TO_CHAR(eq.id_equipment, 'FM0000'),
					--TO_CHAR(coalesce(rp.job,0), 'FM0000000'),
					--TO_CHAR(rp.shift_start_time,'YYYYMMDDHH24')) as index1,
				*
				from report_shift_enterprsie_06 rp 
				left join equipments eq 
				on eq.cd_equipment = rp.line 
				and eq.id_enterprise = 6
				where day >= now()- interval '21 day'
				--and day <= now() - interval '1 day'
				)
				select 
				--r.index1 as index_report,
				v.index1
				from validation v 
				left join report r
				on v.index1 = r.index1
				where r.index1 is null
				and v.to_delete is false
				);


-- aqui verifica se existe algum index como delete e que não deveria e volta o to_delete para false
UPDATE equipment_validation_shift
SET to_delete = false,
	last_update = now()
WHERE index1 in (		
with validation as (
				select *
				from equipment_validation_shift evs 
				where ts_value_production >= now() - interval '21 day'
				--and ts_value_production <= now() - interval '1 day'
				and ts_creation <= now() - interval '5 hour' --pra garantir que o report ja estava atualizado
				), report as (
				select --concat(
					--TO_CHAR(eq.id_equipment, 'FM0000'),
					--TO_CHAR(coalesce(rp.job,0), 'FM0000000'),
					--TO_CHAR(rp.shift_start_time,'YYYYMMDDHH24')) as index1,
				*
				from report_shift_enterprsie_06 rp 
				left join equipments eq 
				on eq.cd_equipment = rp.line 
				and eq.id_enterprise = 6
				where day >= now()- interval '21 day'
				--and day <= now() - interval '1 day'
				)
				select 
				--r.index1 as index_report,
				v.index1
				from validation v 
				left join report r
				on v.index1 = r.index1
				where r.index1 is not null
				and v.to_delete is true
				);				

commit;

UPDATE equipment_validation_shift evs
SET index2 = rr.index2,
    last_update = now()
FROM report_shift_enterprsie_06 rr
WHERE evs.index1 = rr.index1
AND rr.index1 IN (
    WITH report AS (
        SELECT rp.index1, rp.index2 
        FROM report_shift_enterprsie_06 rp
        WHERE rp.day >= now() - INTERVAL '22 days'
    )
    SELECT ev.index1
    FROM equipment_validation_shift ev
    LEFT JOIN report r ON r.index1 = ev.index1
    WHERE ev.ts_value_production >= now() - INTERVAL '21 days'
    --AND ev.ts_creation >= now() - INTERVAL '3 hours'
    AND r.index2 != ev.index2
    AND ev.to_delete IS false);
		
-- autolog de weekend com packed quantity = zero
UPDATE equipment_validation_shift v
SET 
		validation = true,
		ts_user_validation = now(),
		nm_user_validation = 'packiot',
		txt_validation_notes =jsonb_build_object(
       'LastConfirm', jsonb_build_object(
           'note', 'Autolog (Weekend)',
           'user', 'packiot',
           'approved', true,
           'ip_adress', '',
           'ts_confirm', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
WHERE index1 in (
				select rse.index1
				from report_shift_enterprsie_06 rse  
				left join equipment_runtime_shift ers 
				on ers.id_equipment = rse.id_equipment
				and rse.day = ers.ts_value_production
				and ers.cd_shift = rse.shift
				where rse.id_equipment in (select id_equipment from equipments where id_enterprise = 6)
				and rse.day >= now() - interval '4 day'
				and to_char(rse.day, 'dy') in ('sat','sun')
				and ers.ts_value_production >= now() - interval '5 day'
				and rse.shift_duration_h = dt_plan_h
				and now() not between ers.ts_value and ers.ts_end 
				)
AND nm_user_validation IS null;
--AND shift_start_time + interval '470 minute' <= now();

	
				
--autolog the no order		
UPDATE equipment_validation_shift v
SET 
		validation = true,
		ts_user_validation = now(),
		nm_user_validation = 'packiot',
		txt_validation_notes =jsonb_build_object(
       'LastConfirm', jsonb_build_object(
           'note', 'Autolog (No-Order)',
           'user', 'packiot',
           'approved', true,
           'ip_adress', '',
           'ts_confirm', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
WHERE index1 in (
				select index1
				from report_shift_enterprsie_06 rse 
				where id_equipment in (select id_equipment from equipments where id_enterprise = 6)
				and day >= now() - interval '5 day'
				and job is null
				and packed_qty = 0
				)
AND nm_user_validation IS null
AND shift_start_time + interval '470 minute' <= now();


--abaixo eh para setar o last_update como sendo o maior valor entre o last_update e o ts_value_creation
--isso eh feito pois em alguns casos o ts_value_creation eh feito bem depois do last_update
--como o ts_value_valitation nao pertence ao index2, ele nao atualiza o last update.

--essa parte abaixo foi comentada no dia 2025-02-06, EW, para evitar que o last_update seja alterado pela validation.
--no script do sync agora, o last update está sendo pego como o greatest entre o last_update o o ts_validation
/*UPDATE equipment_validation_shift AS evs
SET last_update = subquery.ts_user_validation
FROM (
    SELECT 
        index1,
        ts_user_validation
    FROM equipment_validation_shift
    WHERE ts_value_production >= now() - interval '21 day'
      AND ts_user_validation IS NOT NULL
      AND last_update < ts_user_validation
) AS subquery
WHERE evs.index1 = subquery.index1;

*/

--AQUI TERIA QUE ATUALIZAR OS DADOS COM BASE NO REPORT 06 E INDEX2
--NÃO IMPORTA QUE O REPORT MUDE DE 2 EM 2 HORAS, JÁ QUE NO VALIDATION NÃO VAMOS MOSTRAR DADOS			
			
--(1) colocar nesse procedimento um check de indexes baseado na tabela report_shift_enterprsie_06
--se un index existe na equipment_validation_shift e não existe mais na report_shift_enterprsie_06
--esse index teria que ser deletado da tabela equipment_validation_shift
--cuidado pois a tabela report_shift_enterprsie_06 tem um update de 2 em 2h
--ideal seria pegar apenas os indexes com o ts_creation anteriores a 2h

--(2) verificar no users_logs nos ultimos x-minutes e verificar se apareceu um novo index1 validado
--caso sim, esses dados são atualizados na tabela de equipment_validation_shift
--esse procedimento teria que rodar de 1 em 1min
-- DUVIDA: ideal seria o operador ver automaticamente que a validação foi feita. 
--Daria para update o campo validation de false para true quando o operator validar?
--Mesmo vale para o txt_validation_note, isso teria que aparecer na tabela
--DUVIDA2: e se o operador quiser "desvalidar" um evento? numa dessas teria que ter uma regra no users_logs
--se ele validou apareceia o index e um campo "validated" e se invalidou um que ja estava valido...
--aparece um novo log com o mesmo index mas com o campo como "invalidated" nesse caso teria que update a tabela equipment_validation_shift para validation = false
--criar uma logica de colsulta que olha para os ultimos x-minutos do users_log e pega apenas o ultimo evento de cada index1



end $procedure$


-- ===FUNC=== update_report_shift_enterprsie_06()
CREATE OR REPLACE PROCEDURE public.update_report_shift_enterprsie_06()
 LANGUAGE plpgsql
AS $procedure$
begin
delete from report_shift_enterprsie_06
where day >= (now() at time zone 'America/Montreal')::date - interval '6 day';

insert into report_shift_enterprsie_06(line,shift,turno_hrs,day,job,shift_duration_h, dt_duration_h, setup_duration_h,running,prss_qty,packed_qty, shift_number,job_sequence, dt_plan_h, dt_unplan_h,shift_start_time)
(select 
	line,
	shift,
	turno_hrs,
	day,
	job,
	shift_duration_h, 
	dt_duration_h, 
	setup_duration_h,
	running,
	prss_qty,
	packed_qty,
	shift_number,
	job_sequence,
	dt_plan_h,
	dt_unplan_h,
	shift_start_time
from get_report_shift_enterprsie_06());

commit;

end $procedure$


-- ===FUNC=== update_report_shift_enterprsie_06b()
CREATE OR REPLACE PROCEDURE public.update_report_shift_enterprsie_06b()
 LANGUAGE plpgsql
AS $procedure$
declare 
	min int;
begin

	min = extract(minute from now());
	
IF min > 1 then  
--IF min > 40 then  
--IF (hora >= 14 AND hora <= 15) OR (hora >= 3 AND hora <= 4) THEN
 
delete from report_shift_enterprsie_06
	where day >= (now() at time zone 'America/Montreal')::date - interval '21 day'
	and day <= (now() at time zone 'America/Montreal')::date - interval '0 day';

insert into report_shift_enterprsie_06(line,shift,turno_hrs,day,job,shift_duration_h, dt_duration_h, setup_duration_h,running,prss_qty,packed_qty, shift_number,job_sequence, dt_plan_h, dt_unplan_h,shift_start_time,index1,id_equipment,pro_h,res_h,mnt_h,discart_h,index2)
(select 
	line,
	shift,
	turno_hrs,
	day,
	job,
	shift_duration_h, 
	dt_duration_h, 
	setup_duration_h,
	running,
	prss_qty,
	packed_qty,
	shift_number,
	job_sequence,
	dt_plan_h,
	dt_unplan_h,

	shift_start_time,
	index1,
	id_equipment,
	pro_h,
	res_h,
	mnt_h,
	discart_h,
	index2
from get_report_shift_enterprsie_06c(
	((now() at time zone 'America/Montreal')::date - interval '21 day')::date,
	((now() at time zone 'America/Montreal')::date - interval '0 day')::date));

begin--eduardo
		perform piot_monitor_function('montebello_refresh_21days');
	EXCEPTION WHEN OTHERS then perform 1;
	END;

ELSE

delete from report_shift_enterprsie_06
	where day >= (now() at time zone 'America/Montreal')::date - interval '2 day'
	and day <= (now() at time zone 'America/Montreal')::date - interval '0 day';

insert into report_shift_enterprsie_06(line,shift,turno_hrs,day,job,shift_duration_h, dt_duration_h, setup_duration_h,running,prss_qty,packed_qty, shift_number,job_sequence, dt_plan_h, dt_unplan_h,shift_start_time,index1,id_equipment,pro_h,res_h,mnt_h,discart_h,index2)
(select 
	line,
	shift,
	turno_hrs,
	day,
	job,
	shift_duration_h, 
	dt_duration_h, 
	setup_duration_h,
	running,
	prss_qty,
	packed_qty,
	shift_number,
	job_sequence,
	dt_plan_h,
	dt_unplan_h,
	shift_start_time,
	index1,
	id_equipment,
	pro_h,
	res_h,
	mnt_h,
	discart_h,
	index2
from get_report_shift_enterprsie_06c(
	((now() at time zone 'America/Montreal')::date - interval '2 day')::date,
	((now() at time zone 'America/Montreal')::date - interval '0 day')::date));

begin--eduardo
		perform piot_monitor_function('montebello_refresh_2days');
	EXCEPTION WHEN OTHERS then perform 1;
	END;

end if;

--commit;


end $procedure$


-- ===FUNC=== upsert_sap_report_data_sync_customer_13()
CREATE OR REPLACE FUNCTION public.upsert_sap_report_data_sync_customer_13()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
  INSERT INTO sap_report_data_sync_customer_13 (
    linie,
    tag,
    shicht,
    shicht_nummer,
    auftrag_key,
    auftrag,
    sum_labels,
    rumpfe,
    gutmenge,
    rustzeit,
    produktionszeit,
    geplante_ausfallzeit,
    ungeplante_ausfallzeit,
    matfehler_ausfallzeit,
    no_order,
    auftrag_startzeit,
    running_h,
    shift_start_time,
    data_type,
    id_order_label
  )
  WITH dias as (
SELECT 
	(generate_series((now() at time zone 'Europe/Zurich')::date - interval '8 day', (now() at time zone 'Europe/Zurich')::date,'1 day'))::date as start_day
), start_counting_day as (
--para que os dados sejam buscados sempre a partir do ultimo domingo
select 
	min(start_day) as start_day
from dias
--where to_char(start_day, 'dy') in ('sun')
order by start_day desc
limit 1
), turnos as (--aqui pega as logicas de turnos na runtime de turnos
select 
	concat(to_char(((ers.ts_value at time zone 'Europe/Zurich')::time),'HH24:MI'),'-', to_char(((ers.ts_end at time zone 'Europe/Zurich')::time),'HH24:MI')) as turno_hrs,
	ers.ts_value as shift_start_time, --nova variavel 
	ers.id_equipment,
	shi.cd_shift as cd_shift, --alteracao feita para evitar erro de falta dessa info na troca de turno
	ers.id_shift,
	ers.ts_value_production,
	ers.ts_value as tz_value,
	case 
		when ers.ts_end > now() then now() 
		else ers.ts_end end as tz_end
from equipment_runtime_shift ers, start_counting_day scd, shifts shi 
where ers.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and tp_equipment = 3 and id_site = 13)
and ers.ts_value_production >= scd.start_day --now()::date -  interval '3 day' 
and ers.ts_value <= now()
and shi.id_shift = ers.id_shift
order by ers.id_equipment, tz_value
), equipamentos as (--aqui pega uma logica para que cada id_equipment tenha um cd_equipment de uma linha associado
select 
	e.id_equipment,
		case when eq.tp_equipment = 3 then e.id_parentequipment
		when eq.tp_equipment = 2 then eq.id_parentequipment end as id_equipment_line
from equipments e, equipments eq
where e.id_parentequipment = eq.id_equipment
and e.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment in (1,2))
), linhas as (--aqui faz a associacao final do id_equipment com o cd_equipment de uma linha
select 
	e.id_equipment,
	eq.cd_equipment,
	e.id_equipment_line,
	eq.stop_threshold_time
from equipamentos e, equipments eq
where e.id_equipment_line = eq.id_equipment
--******** parte nova para ser inserida que estava com erro nos downtimes*************
union all
select 
	id_equipment,
	cd_equipment,
	id_equipment as id_equipment_line,
	stop_threshold_time
from equipments
where id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3)
order by cd_equipment 
--***************************************************************************************
), presscount as (--dados de press-count para todos os equipamento tipo 3 da enterprise 6
	select 
	id_equipment,
	id_site,
	id_area,
	ts_value as tz_value,
	gross_production_incr,
	net_production_incr 
	from agg_equipment_values_1min_t, start_counting_day scd
	where id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3)
	and ts_value >= now()- interval '8 day'
	and ts_value >= start_day
	and id_enterprise = 13
	and id_site = 13--in (select id_site from sites where id_enterprise = 6)
	--and id_area = 58--in (select id_area from areas where id_enterprise = 6 and id_area!=24)
/*)--,labels_extract as (--pega os labels, e precisa ser hard coded pois nao existe uma logic para qual equipamento tem labels
select 
	ca.ts_value as tz_value, 
	--ca.id_equipment,
	l.id_equipment_line as id_equipment,
	ca.id_order as label_Job,
	ca.net_production  as label_amount
	from ca_equipment_boxes_1s ca, linhas l
	-- a json was created in the custom column with a logic for all equipments that have labels in the table ca_equipment_boxes_1s
	--where ca.id_equipment in (138,144,236,260,266,323,363,374,385,432,458,481,492,503,514,518,525,530,535,549,573,578)
	where ca.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 29 and cast(custom::json#>>'{Label,has_labels}' as BOOLEAN) is true and id_area not in (24))
	and ca.id_enterprise = 13
	and ca.id_site = 29--in (select id_site from sites where id_enterprise = 6)
	and ca.ts_value >= now() - interval '30 day'
	and l.id_equipment = ca.id_equipment
	order by ts_value	
*/
),labels_extract as (--pega os labels, e precisa ser hard coded pois nao existe uma logic para qual equipamento tem labels
	select 	
		null::timestamptz as tz_value,
		null::int4 as id_equipment,
		null::text as label_Job,
		null::float8 as label_amount	
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
where porun.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and tp_equipment = 3 and id_site = 13)
and po.id_equipment = porun.id_equipment
and po.id_enterprise = 13
and po.id_production_order = porun.id_production_order 
and lower(porun.runtime_timerange) >= now() - interval '90 day'
order by 1,6
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
	bfs.shift_start_time,
	sum(pc.net_production_incr) as net
from base_for_splits bfs
left join presscount pc
on pc.tz_value >= bfs.inicio and pc.tz_value < bfs.fim
and pc.id_equipment = bfs.id_equipment
and pc.id_site = bfs.id_site
and pc.id_area = bfs.id_area
--and pc.tz_value >= now() - interval '36 hour' 
group by 1,2,3,4,5,6,8,9,10
order by 1,5
), top_level AS (
         SELECT id_equipment,jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE equipments.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and tp_equipment = 3 and id_site = 13)--708 --(TL205)
        ), category_level AS (
         SELECT 
         	id_equipment,
         	--jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'position'::text AS "position",
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code')::int as position
          FROM top_level
           order by 1,2          
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position"::integer AS "position",
            category_level.description
            --id_equipment
           FROM category_level
          ORDER BY 1--(category_level."position"::integer)  
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" as code,
            case 
            	when dc."position" in (24) then 1 --Műszaki hiba--DEFECTS--UNPLANNED
            	when dc."position" in (2) then 2 --Tervezett karbantartás--MAINTENANCE-PLANNED
            	when dc."position" in (5,8) then 3--(5,8) then 3 --Anyagprobléma--MATERIAL (HU TAKE ALSO LAMINAT AS MATERIAL)
            	when dc."position" is null and extract(epoch from coalesce(ts_end,now())-ts_event) >= e.stop_threshold_time then 4 --no_reson--
            	when dc."position" is null and extract(epoch from coalesce(ts_end,now())-ts_event) < e.stop_threshold_time then  5 --microstops--
            	when dc."position" in (7) then 6 --Tervezett karbantartás--MAINTENANCE-PLANNED
            	else 0 --Beállítási idő-- 
            	end AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 
          AND ee.ts_event >= (now() - '90 days'::interval) 
          and tstzrange(ee.ts_event, coalesce(ee.ts_end, now())) && tstzrange(now()- interval '8 day', now())
          and tstzrange (ee.ts_event,  COALESCE(ee.ts_end, now())) && tstzrange(now()- interval '7 day', now())
          AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT 
            sb.id_equipment,
            sb.ts_event as tz_event,
            sb.nextts as tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
    		sb.downtimereason
          FROM stops_neopac_ch sb
          where coalesce(nextts,now()) >= (select start_day - interval '1 day' from start_counting_day)
          ORDER BY sb.cd_equipment, sb.ts_event
), split_bfs as (
--PRIMEIRO SPLIT DOS DOWNTIMES BASEADO NO BFS (SHIFTS E JOBS)
select st.id_equipment, 
greatest(st.tz_event,bfs.inicio) as tz_event,
least(coalesce(st.tz_end,now()),bfs.fim) as tz_end,
st.planned_downtime,
bfs.inicio,
st.cd_category,
st.code,
st.downtimereason
from stops_raw st
left join base_for_splits bfs
on tstzrange(st.tz_event,coalesce(tz_end,now())) && tstzrange(bfs.inicio, bfs.fim)
and bfs.id_equipment = st.id_equipment
order by 1,2,5
--********************************************************************************
--FUNCIONANDO ATEH ESSE PONTO COM AS NOVAS LOGICAS DE DTS
), stops_final as (
select 
	stpf.*,
	--DETERMINACAO DAS LOGICAS DE SOMAS DE DOWNTIME
	--PRECISA SER DEFINIDO CORRETAMENTE COM A MONTEBELLO
	--coalesce(stpf.setup_s,0) - sum(case when st.cat_dt_logics in (2,4,8,10) then st.duration_s else 0 end) as stp_s,
	coalesce(sum(case when st.downtimereason in (0) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_0,
	coalesce(sum(case when st.downtimereason in (1) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_1,
	coalesce(sum(case when st.downtimereason in (2) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_2,
	coalesce(sum(case when st.downtimereason in (3) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_3,
	coalesce(sum(case when st.downtimereason in (4) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_4,
	coalesce(sum(case when st.downtimereason in (5) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_5,
	coalesce(sum(case when st.downtimereason in (6) then extract (epoch from st.tz_end - st.tz_event) end),0) as dt_6
--from setup_final stpf
from base_for_splits stpf
left join split_bfs st
on st.tz_event < stpf.fim
and st.tz_end > stpf.inicio
--and st.tz_end >= now() - interval '36 hour'
and stpf.id_equipment = st.id_equipment
group by 1,2,3,4,5,6,7,8,9,10,11
order by 3,2,7
), final_and_press as (
select 
	f.*,
	pqty.gross,
	pqty.net
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
	case when sum(l.Label_amount) is null then 0 else sum(l.Label_amount) end as net_label,
	bfs.id_shift
from base_for_splits bfs--, linhas eq
left join labels l

on l.tz_value >= bfs.inicio and l.tz_value < bfs.fim - interval '1 second'
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
	f.net as net_sensor,
	pack.net_label as packed_qty,
	pack.label_job,
	f.id_shift,
	f.turno_hrs,
	f.shift_start_time,
	dt_0,
	dt_1,
	dt_2,
	dt_3,
	dt_4,
	dt_5,
	dt_6
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
	0 as net_sensor,
	pack.net_label as packed_qty,
	null as label_job,
	f.id_shift,
	f.turno_hrs,
	f.shift_start_time,
	dt_0,
	dt_1,
	dt_2,
	dt_3,
	dt_4,
	dt_5,
	dt_6
from final_and_press f
inner join packed_quantity pack
on f.inicio = pack.inicio
and f.fim = pack.fim
and f.id_equipment = pack.id_equipment
and pack.net_label is not null
and pack.net_label != 0
and f.id_order != pack.label_job::bigint
order by id_equipment,ts_value_production, cd_shift
--FUNCIONANDO ATEH AQUI
), shift_report as (
select 
	ppf.id_equipment,
	eq.cd_equipment as line,
	ppf.cd_shift as shift,
	ppf.turno_hrs as shift_hrs,
	ppf.ts_value_production as day,
	ppf.id_order as job,
	ppf.shift_duration::float,
	((ppf.shift_duration::float)/3600)::numeric(10,2) as shift_duration_s,
	((ppf.dt_0::float + ppf.dt_1::float + ppf.dt_2::float + ppf.dt_3::float + ppf.dt_4::float + ppf.dt_5::float + ppf.dt_6::float)/3600)::numeric(10,2) as total_dt_s,
	((ppf.shift_duration::float - (ppf.dt_0::float + ppf.dt_1::float + ppf.dt_2::float + ppf.dt_3::float + ppf.dt_4::float + ppf.dt_5::float + ppf.dt_6::float))/3600)::numeric(10,2) as running_s,
	((ppf.dt_0::float + ppf.dt_4::float + ppf.dt_5::float)/3600)::numeric(10,2) as dt_0, --Beállítási idő-- including NO REASON dt_4 and microstops dt_5 
	(ppf.dt_1::float/3600)::numeric(10,2) as dt_1, --Műszaki hiba--
	(ppf.dt_2::float/3600)::numeric(10,2) as dt_2, --Tervezett karbantartás--
	(ppf.dt_3::float/3600)::numeric(10,2) as dt_3, --Anyagprobléma--
	(ppf.dt_6::float/3600)::numeric(10,2) as dt_4, --no_reson--
	coalesce(ppf.press_count,0) as prss_qty,
	coalesce(ppf.net_sensor,0) as net_sensor,
	coalesce(ppf.packed_qty,0) as packed_qty,
	shi.sequence_position as shift_number,
	ppf.shift_start_time at time zone 'Europe/Zurich' as shift_start_time,
	lower(pos.runtime_timerange_new) at time zone 'Europe/Zurich' as job_sequence
from press_packed_final ppf
left join equipments eq
on ppf.id_equipment = eq.id_equipment
and eq.id_enterprise = 13
and eq.tp_equipment = 3
left join shifts shi
on shi.id_shift = ppf.id_shift
and shi.id_enterprise = 13
left join po_sequence pos
on ppf.id_order = pos.id_order --mudar
and tstzrange(ppf.shift_start_time,ppf.shift_start_time +interval '12 hour') && pos.runtime_timerange_new --mudar
),labels_data as (
select 
ebc.id_equipment,
ebc.ts_value,
ebc.id_order,
ebc.net_production
from equipment_boxes_cust_13 ebc 
where ebc.id_equipment in (select id_equipment from equipments where id_enterprise = 13 and id_site = 13 and tp_equipment = 3) 
and ts_value >= now() - interval '8 day'
order by 1,ts_value
), final_labels as (
select 
	eq.cd_equipment,
	t.*,
	ld.id_order,
	sum(ld.net_production) as sum_labels
from turnos t
left join labels_data ld 
on t.id_equipment = ld.id_equipment
and ld.ts_value >= t.tz_value and ld.ts_value < t.tz_end
left join equipments eq 
on eq.id_equipment = t.id_equipment 
group by 1,2,3,4,5,6,7,8,9,10
order by id_equipment, shift_start_time
), final_jobs as (
select 
prss_qty as rumpfe,
net_sensor as gutmenge,
dt_0 as rustzeit,
shift_duration_s as produktionszeit,
dt_2 as geplante_ausfallzeit,
dt_1 as ungeplante_ausfallzeit,
dt_3 as matfehler_ausfallzeit,
dt_4 as no_order,
job as auftrag,
line as linie,
shift as shicht,
shift_number as shicht_nummer,
job_sequence as auftrag_startzeit,
day as tag,
running_s as running_h,
shift_start_time
from shift_report 
--where day >= now() at time zone 'Europe/Zurich' - interval '3 day'
order by line, day,shift_number, job_sequence
), final1 as (
select fl.id_order,fl.sum_labels,fj.*
from final_jobs fj
left join final_labels fl
on fl.cd_equipment = fj.linie
and fl.id_order::int = fj.auftrag
and fl.ts_value_production = fj.tag
and fl.cd_shift = fj.shicht
), missing_jobs_labels as (
select fl.*,f1.id_order as job
from final_labels fl
left join final1 f1
on fl.cd_equipment = f1.linie
and fl.id_order::int = f1.auftrag
and fl.ts_value_production = f1.tag
and fl.cd_shift = f1.shicht
where fl.sum_labels is not null
and f1.id_order is null
), final10 as (
select 
	'normal' as data_type,
	id_order as id_order_label,
	sum_labels,
	rumpfe,
	gutmenge,
	rustzeit,
	produktionszeit,
	geplante_ausfallzeit,
	ungeplante_ausfallzeit,
	matfehler_ausfallzeit,
	no_order,
	auftrag,
	linie,
	shicht,
	shicht_nummer,
	auftrag_startzeit at time zone 'Europe/Zurich' as auftrag_startzeit,
	tag,
	running_h,
	shift_start_time
from final1
union all 
select 
	'missing_job' as data_type,
	id_order as id_order_label,
	sum_labels,
	0 as rumpfe,
	0 as gutmenge,
	0 as rustzeit,
	0 as produktionszeit,
	0 as geplante_ausfallzeit,
	0 as ungeplante_ausfallzeit,
	0 as matfehler_ausfallzeit,
	0 as no_order,
	null as auftrag,
	cd_equipment as linie,
	cd_shift as shicht,
	case when  cd_shift = 'Frühschicht' then 1 when cd_shift = 'Spätschicht' then 2 when cd_shift = 'Nachtschicht' then 3 end as shicht_nummer,
	null as auftrag_startzeit,
	ts_value_production as tag,
	0 as running_h,
	shift_start_time
from missing_jobs_labels
order by linie, tag, shicht_nummer-- case when shicht = 'Frühschicht' then 1 when shicht = 'Spätschicht' then 2 else 3 end
)
  SELECT DISTINCT ON (linie, tag, shicht, auftrag_key)  
    linie,
    tag,
    shicht,
    shicht_nummer,
    COALESCE(auftrag, 0) AS auftrag_key,
    auftrag,
    sum_labels,
    rumpfe,
    sum_labels as gutmenge, --HJ falou q eles estavam pegando gutmenge como labels
    rustzeit,
    produktionszeit,
    geplante_ausfallzeit,
    ungeplante_ausfallzeit,
    matfehler_ausfallzeit,
    no_order,
    auftrag_startzeit,
    running_h,
    shift_start_time,
    data_type,
    id_order_label
  FROM final10
  WHERE tag >= now() at time zone 'Europe/Zurich' - interval '5 day'
  --AND concat(linie, tag, shicht, auftrag) != 'TL1142025-08-05Frühschicht20083337' 
  ON CONFLICT (linie, tag, shicht, auftrag_key)
  DO UPDATE SET
    auftrag = EXCLUDED.auftrag,
    sum_labels = EXCLUDED.sum_labels,
    rumpfe = EXCLUDED.rumpfe,
    gutmenge = EXCLUDED.gutmenge,
    rustzeit = EXCLUDED.rustzeit,
    produktionszeit = EXCLUDED.produktionszeit,
    geplante_ausfallzeit = EXCLUDED.geplante_ausfallzeit,
    ungeplante_ausfallzeit = EXCLUDED.ungeplante_ausfallzeit,
    matfehler_ausfallzeit = EXCLUDED.matfehler_ausfallzeit,
    no_order = EXCLUDED.no_order,
    auftrag_startzeit = EXCLUDED.auftrag_startzeit,
    running_h = EXCLUDED.running_h,
    shift_start_time = EXCLUDED.shift_start_time,
    data_type = EXCLUDED.data_type,
    id_order_label = EXCLUDED.id_order_label;
END;
$function$



