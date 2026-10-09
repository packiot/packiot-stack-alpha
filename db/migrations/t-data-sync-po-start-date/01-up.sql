-- t-data-sync-po-start-date — serving.data_sync reads core.production_orders.ts_start, not the never-written ts_start_tz.
--
-- WHY: serving.data_sync (ENT-06 ERP/SAP production data-sync; persisted by stream-engine reports/sync06_body.sql
-- into customer_reports.production_data_sync.updateddate) computes
--     UpdatedDate = CASE WHEN po.status = 2 THEN po.last_update
--                        ELSE coalesce(po.ts_start_tz, po.last_update, eqvs.ts_creation) END
-- core.production_orders.ts_start_tz / ts_end_tz are NULL in ALL 62,657 rows on staging (schema review 2026-10-06:
-- POTS 62657 total, ts_start_tz non-null 0; pg_stats null_frac 1.000 for both). Nothing in the new stack writes them:
-- they are a legacy-F1 column kept for object parity (the stream-engine / edge-api / replicator PO writers set
-- ts_start / ts_end only). So the coalesce ALWAYS fell through to po.last_update.
--
-- BUSINESS EFFECT (before this migration): for every non-running PO (available / completed / paused) the ERP feed
-- reported UpdatedDate = the PO's last_update — i.e. the time ANY column of the PO header was last touched
-- (a reconciler re-flag, a recompute, an operator note) — instead of the PO START the legacy contract defines
-- (t278a column comment: ts_start_tz = 'PO start localised to the tenant/site timezone'). UpdatedDate therefore
-- drifted forward every time the engine touched a finished PO, and two shifts of the same finished job could carry
-- different UpdatedDates depending on when sync06 inserted them.
--
-- MODEL: ts_start_tz is timestamptz — an instant, exactly like ts_start ("localised" only ever meant how the legacy
-- client rendered it). po.ts_start IS that instant, populated for every started PO (the
-- production_orders_ts_start_ts_end CHECK forces ts_start for status 2/3/4). Status 1 (never started) has
-- ts_start NULL and keeps falling through to last_update → ts_creation exactly as before. Status 2 is unchanged.
--
-- WHAT CHANGES: one token in one expression. Re-created from the NEWEST definition
-- (db/migrations/t244c-serving-self-containment/03-shift-generic.sql — no later migration redefines
-- serving.data_sync; t278e only COMMENTs it). Signature, RETURNS TABLE columns/types, LANGUAGE, volatility and
-- the unqualified-name resolution (no SET search_path, as before) are identical, so CREATE OR REPLACE keeps the
-- owner, grants and comment and nothing that calls it (sync06) needs to change.
--
-- DOWNSTREAM: sync06 detects changes on last_update_prod_data, never on updateddate, so this does NOT trigger a
-- wave of 'U' rows. Rows already in customer_reports.production_data_sync keep their old updateddate; only rows
-- sync06 inserts from now on carry the PO start. No backfill here (external ERP contract — owner decision).
--
-- NOT DONE HERE (separate later step): dropping core.production_orders.ts_start_tz / ts_end_tz. Still referenced
-- after this migration by: read-api `production-orders-rich` dataset (services/read-api/cmd/refdata-api/datasets.go:1104
-- + testdata/contract.golden.json:945,947 — an API contract field, exported as always-NULL), the column COMMENTs
-- (t278a-core-object-docs), and rollback-only/historical SQL (t244c rollback.sql:1661, t244 01-expand.sql:211,
-- db/cutover/*, docs/adr captures, scripts/analytics-legacy-history-backfill.sh:169 — legacy F1 → F3 copy).
--
-- GUARD: refuses to run if the live body is neither the t244c body nor this one (an out-of-band hotfix would be
-- silently overwritten otherwise) — re-derive from pg_get_functiondef in that case.
-- Idempotent: CREATE OR REPLACE; the guard accepts the already-migrated body.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL client_min_messages = warning;
SET LOCAL check_function_bodies = off;

DO $$ DECLARE src text; BEGIN
  SELECT p.prosrc INTO src FROM pg_proc p
   WHERE p.oid = to_regprocedure('serving.data_sync(integer, integer)');
  IF src IS NULL THEN
    RAISE EXCEPTION 't-data-sync-po-start-date: serving.data_sync(integer, integer) does not exist';
  END IF;
  IF position('customer_reports.shift rse' IN src) = 0
     OR (position('coalesce(po.ts_start_tz,po.last_update,eqvs.ts_creation)' IN src) = 0
         AND position('coalesce(po.ts_start,po.last_update,eqvs.ts_creation)' IN src) = 0) THEN
    RAISE EXCEPTION 't-data-sync-po-start-date: live serving.data_sync differs from the t244c body; re-derive this migration from pg_get_functiondef before applying';
  END IF;
END $$;

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
    case when po.status = 2 then po.last_update else coalesce(po.ts_start,po.last_update,eqvs.ts_creation) end as UpdatedDate,  -- t-data-sync-po-start-date: was the never-written tz twin column
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

COMMIT;
