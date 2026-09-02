-- sap13_body.sql — verbatim embed of prod's
-- upsert_sap_report_data_sync_customer_13() (capture:
-- docs/adr/reference/captures/0012-wave2-prod-writer-funcs.sql:876-1461).
-- ADR-0012 Wave 2 Family C. Three surgical transforms ONLY:
--   1. write target -> customer_reports.sap_data_sync (pool)
--   2. customer_id injected into projection (__CUSTOMER_ID__ placeholder,
--      substituted from config -- no hardcoded tenant in new code)
--   3. ON CONFLICT extended to the pool key
--      (customer_id, linie, tag, shicht, auftrag_key) -- THE back4-api
--      cutover contract (issue #223)
-- Everything else is FROZEN legacy SQL, tenant literals included --
-- legacy names (frozen) per docs/adr/reference/naming-ledger.md.
  INSERT INTO customer_reports.sap_data_sync (
    customer_id,
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
	from agg_equipment_values_1min, start_counting_day scd
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
    __CUSTOMER_ID__ AS customer_id,
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
  ON CONFLICT (customer_id, linie, tag, shicht, auftrag_key)
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
