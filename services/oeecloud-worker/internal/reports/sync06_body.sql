-- Condition 0: Verifica um record que existia, deixou de existir e voltou a existir
--seta esse caso para um N e seta o to_delete como FALSE
--Isso criava problemas, pois acabava criando inumeros inputs da logica 4
	    update production_data_sync_enterprise_06
	    set to_delete = false,
	    	trans_status = 'N',
	    	logics = 0,
			real_update = now()
        WHERE shiftstartdate > NOW() - INTERVAL '23 day'
        AND to_delete IS true
        and packiotid IN (select packiotid FROM get_data_sync_enterprsie_06b(21) where to_delete is false);
    
-- Condition 1: Insert records where packiotid does not exist in the table
    INSERT INTO production_data_sync_enterprise_06 (site, line, shift, shiftstartdate, job, item, totalavailablehrsinmin, dtimehrsplannedinmin, dtimehrsunplannedinmin, unplanneddt_proinmin, unplanneddt_resinmin, unplanneddt_mntinmin, setuphoursinmin, runhoursinmin, presscnt, packcnt, jobstatus, jobstartdate, jobcompleteddate, createddate, updateddate, packiotid, supervisorapproval, supervisorapproveddate, supervisornotes, nm_user_validation, id_validation, ts_creation, to_delete, last_update, packml_topic, trans_status,logics,real_update)
    SELECT 
        site, 
        line, 
        shift, 
        shiftstartdate, 
        job, 
        item, 
        totalavailablehrsinmin, 
        dtimehrsplannedinmin, 
        dtimehrsunplannedinmin, 
        unplanneddt_proinmin, 
        unplanneddt_resinmin, 
        unplanneddt_mntinmin, 
        setuphoursinmin, 
        runhoursinmin, 
        presscnt, 
        packcnt, 
        case when jobstatus = 'in_progress' then 'in progress' else jobstatus end as jobstatus, 
        jobstartdate, 
        jobcompleteddate, 
        createddate, 
        updateddate, 
        packiotid, 
        supervisorapproval, 
        supervisorapproveddate, 
        supervisornotes, 
        nm_user_validation, 
        id_validation, 
        ts_creation, 
        to_delete, 
        last_update_prod_data as last_update, 
        packml_topic, 
        CASE WHEN to_delete IS TRUE THEN 'D' ELSE 'N' END AS trans_status,
		1 as logics,
		now() as real_update
    FROM get_data_sync_enterprsie_06b(21)
    WHERE packiotid NOT IN (
        SELECT packiotid 
        FROM production_data_sync_enterprise_06
        WHERE shiftstartdate >= NOW() - INTERVAL '23 day'
    );

    -- Condition 2: Insert rows where to_delete is true and the row does not already exist
    INSERT INTO production_data_sync_enterprise_06 (site, line, shift, shiftstartdate, job, item, totalavailablehrsinmin, dtimehrsplannedinmin, dtimehrsunplannedinmin, unplanneddt_proinmin, unplanneddt_resinmin, unplanneddt_mntinmin, setuphoursinmin, runhoursinmin, presscnt, packcnt, jobstatus, jobstartdate, jobcompleteddate, createddate, updateddate, packiotid, supervisorapproval, supervisorapproveddate, supervisornotes, nm_user_validation, id_validation, ts_creation, to_delete, last_update, packml_topic, trans_status,logics,real_update)
    SELECT 
        site, 
        line, 
        shift, 
        shiftstartdate, 
        job, 
        item, 
        totalavailablehrsinmin, 
        dtimehrsplannedinmin, 
        dtimehrsunplannedinmin, 
        unplanneddt_proinmin, 
        unplanneddt_resinmin, 
        unplanneddt_mntinmin, 
        setuphoursinmin, 
        runhoursinmin, 
        presscnt, 
        packcnt, 
        case when jobstatus = 'in_progress' then 'in progress' else jobstatus end as jobstatus, 
        jobstartdate, 
        jobcompleteddate, 
        createddate, 
        updateddate, 
        packiotid, 
        supervisorapproval, 
        supervisorapproveddate, 
        supervisornotes, 
        nm_user_validation, 
        id_validation, 
        ts_creation, 
        to_delete, 
        last_update_prod_data as last_update, 
        packml_topic, 
        'D' AS trans_status,
		2 as logics,
		now() as real_update
    FROM get_data_sync_enterprsie_06b(21)
    WHERE packiotid NOT IN (
        SELECT packiotid 
        FROM production_data_sync_enterprise_06
        WHERE shiftstartdate >= NOW() - INTERVAL '23 day'
        AND to_delete IS TRUE
    )
    AND to_delete IS TRUE;

    -- Condition 4: If packiotid is marked as 'D' but not deleted, insert with status 'N'
    INSERT INTO production_data_sync_enterprise_06 (site, line, shift, shiftstartdate, job, item, totalavailablehrsinmin, dtimehrsplannedinmin, dtimehrsunplannedinmin, unplanneddt_proinmin, unplanneddt_resinmin, unplanneddt_mntinmin, setuphoursinmin, runhoursinmin, presscnt, packcnt, jobstatus, jobstartdate, jobcompleteddate, createddate, updateddate, packiotid, supervisorapproval, supervisorapproveddate, supervisornotes, nm_user_validation, id_validation, ts_creation, to_delete, last_update, packml_topic, trans_status,logics,real_update)
    SELECT 
        site, 
        line, 
        shift, 
        shiftstartdate, 
        job, 
        item, 
        totalavailablehrsinmin, 
        dtimehrsplannedinmin, 
        dtimehrsunplannedinmin, 
        unplanneddt_proinmin, 
        unplanneddt_resinmin, 
        unplanneddt_mntinmin, 
        setuphoursinmin, 
        runhoursinmin, 
        presscnt, 
        packcnt, 
        case when jobstatus = 'in_progress' then 'in progress' else jobstatus end as jobstatus, 
        jobstartdate, 
        jobcompleteddate, 
        createddate, 
        updateddate, 
        packiotid, 
        supervisorapproval, 
        supervisorapproveddate, 
        supervisornotes, 
        nm_user_validation, 
        id_validation, 
        ts_creation, 
        to_delete, 
        last_update_prod_data as last_update, 
        packml_topic, 
        'N' AS trans_status,
		4 as logics,
		now() as real_update
    FROM get_data_sync_enterprsie_06b(21)
    WHERE packiotid IN (
        SELECT packiotid 
        FROM production_data_sync_enterprise_06
        WHERE shiftstartdate >= NOW() - INTERVAL '23 day'
        AND to_delete IS TRUE
    )
    AND to_delete IS NOT TRUE;

    -- Condition 5: If packiotid and jobstatus = 'completed' and last_update is different, insert with status 'U'
    INSERT INTO production_data_sync_enterprise_06 (site, line, shift, shiftstartdate, job, item, totalavailablehrsinmin, dtimehrsplannedinmin, dtimehrsunplannedinmin, unplanneddt_proinmin, unplanneddt_resinmin, unplanneddt_mntinmin, setuphoursinmin, runhoursinmin, presscnt, packcnt, jobstatus, jobstartdate, jobcompleteddate, createddate, updateddate, packiotid, supervisorapproval, supervisorapproveddate, supervisornotes, nm_user_validation, id_validation, ts_creation, to_delete, last_update, packml_topic, trans_status,logics,real_update)
    SELECT 
        gds.site, 
        gds.line, 
        gds.shift, 
        gds.shiftstartdate, 
        gds.job, 
        gds.item, 
        gds.totalavailablehrsinmin, 
        gds.dtimehrs
plannedinmin, 
        gds.dtimehrsunplannedinmin, 
        gds.unplanneddt_proinmin, 
        gds.unplanneddt_resinmin, 
        gds.unplanneddt_mntinmin, 
        gds.setuphoursinmin, 
        gds.runhoursinmin, 
        gds.presscnt, 
        gds.packcnt, 
        case when gds.jobstatus = 'in_progress' then 'in progress' else gds.jobstatus end as jobstatus, 
        gds.jobstartdate, 
        gds.jobcompleteddate, 
        gds.createddate, 
        gds.updateddate, 
        gds.packiotid, 
        gds.supervisorapproval, 
        gds.supervisorapproveddate, 
        gds.supervisornotes, 
        gds.nm_user_validation, 
        gds.id_validation, 
        gds.ts_creation, 
        gds.to_delete, 
        gds.last_update_prod_data as last_update, 
        gds.packml_topic, 
        CASE WHEN gds.to_delete IS TRUE THEN 'D' ELSE 'U' END AS trans_status,
		5 as logics,
		now() as real_update
    FROM get_data_sync_enterprsie_06b(21) gds
    LEFT JOIN production_data_sync_enterprise_06 pds
    ON gds.packiotid = pds.packiotid
    AND gds.jobstatus != 'in_progress'
	AND extract(epoch from now() - gds.jobcompleteddate) > 4500 --para criar um U apenas 1h e 15min após o fim da OP
    AND gds.last_update_prod_data > pds.last_update
    WHERE gds.packiotid IN (
        SELECT packiotid 
        FROM production_data_sync_enterprise_06
        WHERE shiftstartdate >= NOW() - INTERVAL '23 day'
        GROUP BY 1
        HAVING COUNT(DISTINCT trans_status) = 1
        AND MAX(trans_status) = 'N'
    )
    AND gds.last_update_prod_data != pds.last_update 
    AND gds.jobstatus = 'completed';

    -- Condition 6: If trans_status = 'U' and last_update is different, insert a new row with status 'U'
    INSERT INTO production_data_sync_enterprise_06 (site, line, shift, shiftstartdate, job, item, totalavailablehrsinmin, dtimehrsplannedinmin, dtimehrsunplannedinmin, unplanneddt_proinmin, unplanneddt_resinmin, unplanneddt_mntinmin, setuphoursinmin, runhoursinmin, presscnt, packcnt, jobstatus, jobstartdate, jobcompleteddate, createddate, updateddate, packiotid, supervisorapproval, supervisorapproveddate, supervisornotes, nm_user_validation, id_validation, ts_creation, to_delete, last_update, packml_topic, trans_status,logics,real_update)
    WITH unique_u_packiotid AS (
  		SELECT *,
         ROW_NUMBER() OVER (PARTITION BY packiotid ORDER BY last_update DESC) AS rn
  		FROM production_data_sync_enterprise_06
  		WHERE trans_status = 'U'
    	AND shiftstartdate >= NOW() - INTERVAL '23 day'
		), final_unique_ids as (
		SELECT *
		FROM unique_u_packiotid
		WHERE rn = 1
		ORDER BY packiotid
		)
		SELECT 
        gds.site, 
        gds.line, 
        gds.shift, 
        gds.shiftstartdate, 
        gds.job, 
        gds.item, 
        gds.totalavailablehrsinmin, 
        gds.dtimehrsplannedinmin, 
        gds.dtimehrsunplannedinmin, 
        gds.unplanneddt_proinmin, 
        gds.unplanneddt_resinmin, 
        gds.unplanneddt_mntinmin, 
        gds.setuphoursinmin, 
        gds.runhoursinmin, 
        gds.presscnt, 
        gds.packcnt, 
        gds.jobstatus, 
        gds.jobstartdate, 
        gds.jobcompleteddate, 
        gds.createddate, 
        gds.updateddate, 
        gds.packiotid, 
        gds.supervisorapproval, 
        gds.supervisorapproveddate, 
        gds.supervisornotes, 
        gds.nm_user_validation, 
        gds.id_validation, 
        gds.ts_creation, 
        gds.to_delete, 
        gds.last_update_prod_data as last_update, 
        gds.packml_topic, 
        'U' AS trans_status,
		6 as logics,
		now() as real_update
    FROM get_data_sync_enterprsie_06b(21) gds
    LEFT JOIN final_unique_ids pds
    ON gds.packiotid = pds.packiotid
    AND pds.trans_status = 'U'
    AND pds.shiftstartdate >= NOW() - INTERVAL '23 day'
    AND gds.last_update_prod_data > pds.last_update
    WHERE pds.site IS NOT null
	and gds.to_delete is not true;

-- Condition 7: If trans_status = 'U' and last_update is different, insert a new row with status 'U'
--falta aqui fazer o update dos dados para o caso das OP que estão in progress
--condição
--packiotid existe, jobstatus esta em in_progress, e last_update aumentou
UPDATE production_data_sync_enterprise_06
SET 
	shiftstartdate = subquery.shiftstartdate, 
	job = subquery.job, 
	item = subquery.item, 
	totalavailablehrsinmin = subquery.totalavailablehrsinmin, 
	dtimehrsplannedinmin = subquery.dtimehrsplannedinmin, 
	dtimehrsunplannedinmin = subquery.dtimehrsunplannedinmin, 
	unplanneddt_proinmin = subquery.unplanneddt_proinmin, 
	unplanneddt_resinmin = subquery.unplanneddt_resinmin, 
	unplanneddt_mntinmin = subquery.unplanneddt_mntinmin, 
	setuphoursinmin = subquery.setuphoursinmin, 
	runhoursinmin = subquery.runhoursinmin, 
	presscnt = subquery.presscnt, 
	packcnt = subquery.packcnt, 
	jobstatus = subquery.jobstatus, 
	jobstartdate = subquery.jobstartdate, 
	jobcompleteddate = subquery.jobcompleteddate, 
	createddate = subquery.createddate, 
	updateddate = subquery.updateddate, 
	packiotid = subquery.packiotid, 
	supervisorapproval = subquery.supervisorapproval, 
	supervisorapproveddate = subquery.supervisorapproveddate, 
	supervisornotes = subquery.supervisornotes, 
	nm_user_validation = subquery.nm_user_validation, 
	id_validation = subquery.id_validation, 
	ts_creation = subquery.ts_creation, 
	to_delete = subquery.to_delete, 
	last_update = subquery.last_update_prod_data, 
	packml_topic = subquery.packml_topic,
	logics = 7,
	real_update = now()
FROM (
    SELECT *
    FROM get_data_sync_enterprsie_06b(21)
    WHERE jobstatus = 'in_progress'
	OR extract(epoch from now() - jobcompleteddate) <= 4500 --edu 10-march-2025 para pegar completed na ultima hora...coloquei 1h e 15min por conta do script
) AS subquery
WHERE production_data_sync_enterprise_06.packiotid = subquery.packiotid
and production_data_sync_enterprise_06.trans_status = 'N'
and production_data_sync_enterprise_06.shiftstartdate >= now() - interval '23 day';


--this part below will always update the jobstatus e o inicio e fim do job para casos onde o job já terminou
--porem o status dele aparecendo na tabela estava ainda como in-progress
/*UPDATE production_data_sync_enterprise_06 psde
SET
	jobstatus = CASE
        WHEN po.status = 3 THEN 'completed'
        WHEN po.status = 4 THEN 'paused'
        ELSE psde.jobstatus  -- keep the current jobstatus if it's neither 3 nor 4
    END,    
    jobstartdate = po.ts_start,
    jobcompleteddate = po.ts_end
FROM production_orders po
WHERE
    po.id_order = psde.job
    AND po.status > 2
    AND po.id_enterprise = 6
    AND po.ts_start >= now() - interval '1 month'
    AND tstzrange(po.ts_start - interval '10 hour', po.ts_end) @> psde.jobstartdate
    AND psde.shiftstartdate >= now() - interval '15 day'
    AND psde.site = 'MONTREAL'
    AND po.ts_end IS NOT NULL
    AND po.ts_end != COALESCE(psde.jobcompleteddate, now());

*/

with po_runtimes as (
   s
elect
   	eq.cd_equipment,
   	po.id_order,
   	--case when upper(por.runtime_timerange) is null then 'in progress' else 'completed' end as status, --change EW 10-march-2025
   	case 	when po.status = 3 then 'completed'
   			when po.status = 4 then 'paused' 
   			when po.status = 2 and upper(por.runtime_timerange) is null then 'in progress' 
   			when po.status = 2 and upper(por.runtime_timerange) is not null then 'paused'
   			when po.status = 1 then 'available' 
   			else 'runtime_does_not_exist' end as status,
   	por.id_production_order,
   	lower(por.runtime_timerange) as ts_start, 
   	upper(por.runtime_timerange) as ts_end,
   	por.runtime_timerange
   from production_orders_runtime por
   left join production_orders po
   on po.id_production_order = por.id_production_order
   and po.id_enterprise = 6
   left join equipments eq 
   on eq.id_equipment = por.id_equipment
   where por.id_equipment in (select id_equipment from equipments where id_enterprise = 6 and tp_equipment = 3)
   and por.runtime_timerange && tstzrange(now()- interval '90 day', now())
   order by por.id_equipment, por.runtime_timerange
   ), final as (
   select 
   	pds.line, 
   	pds.shiftstartdate, 
   	pds.job,
   	pds.jobstatus, 
   	por.status::varchar(20),
   	pds.jobstartdate, 
   	por.ts_start,
   	pds.jobcompleteddate,
   	por.ts_end
   from production_data_sync_enterprise_06 pds
   left join po_runtimes por
   on por.cd_equipment = pds.line
   and por.id_order = pds.job
   and tstzrange(pds.shiftstartdate - interval '1 min', shiftstartdate) && tstzrange(por.ts_start - interval '12 hour',coalesce(por.ts_end,now()) + interval '12 hour')
   where pds.shiftstartdate >= now()- interval '90 day'
   and pds.job is not null
   order by line, shiftstartdate
   ), final2 as (
   select 
   	f.line,
   	f.shiftstartdate,
   	f.job,
   	case 
   		when f.status is null and po.ts_end is not null then 'completed'::varchar(20)
   		when f.status is null and po.ts_start is not null and po.ts_end is null then 'in_progress'::varchar(20)
   		else f.status end as status,
   	case when f.ts_start is null then po.ts_start else f.ts_start end as ts_start,
   	case when f.ts_end is null then po.ts_end else f.ts_end end as ts_end,
   	f.jobstatus,
   	f.jobstartdate,
   	f.jobcompleteddate
   	   	--po.ts_start, po.ts_end 
   from final f
   left join production_orders po 
   on f.job = po.id_order 
   and po.id_enterprise = 6
   and f.status is null
   ), final3 as (
   select distinct line, shiftstartdate,job,status,ts_start, ts_end
   from final2
   where status != jobstatus 
   or ts_start != coalesce(jobstartdate,now()) --inseri coalesce pois estava deixando de fora os casos = NULL 2025-05-13
   or ts_end != coalesce(jobcompleteddate,now())
   order by line, shiftstartdate, job
), final4 AS (
    SELECT 
        ROW_NUMBER() OVER (PARTITION BY line, shiftstartdate, job ORDER BY ts_start DESC) AS row_num,
        line, 
        shiftstartdate, 
        job, 
        status, 
        ts_start, 
        ts_end
    FROM final3
    )
UPDATE production_data_sync_enterprise_06 pds
SET 
    jobstatus = res.status,
    jobstartdate = res.ts_start,
    jobcompleteddate = res.ts_end,
	logics = 10,
	real_update = now()
FROM final4 res
WHERE pds.line = res.line
  AND pds.shiftstartdate = res.shiftstartdate
  AND pds.job = res.job
  AND res.row_num = 1;

--this part below will always update the validation data 
update production_data_sync_enterprise_06
set
    supervisorapproval = true,
    supervisorapproveddate = evs.ts_user_validation,
    supervisornotes = evs.txt_validation_notes,
    nm_user_validation = evs.nm_user_validation, 
    id_validation = evs.id_validation,
	real_update = now()
from equipment_validation_shift evs
where 
    evs.ts_value_production >= now() - interval '21 day'
    and evs.validation = true
    and production_data_sync_enterprise_06.shiftstartdate >= now() - interval '21 day'
    and (production_data_sync_enterprise_06.supervisorapproveddate is null or production_data_sync_enterprise_06.supervisorapproveddate != evs.ts_user_validation)
    and production_data_sync_enterprise_06.packiotid = evs.index1;


-- abaixo faz a criação do novo status, onde coloca os status WD, que seriam dados deletados pois foram updated
--faz também referência ao indice geral anterior, no caso dos dados que foram deletados.
WITH calculated_data AS (
    SELECT 
        indice_geral,
        LAG(indice_geral) OVER (
            PARTITION BY packiotid
            ORDER BY 
                line, 
                shiftstartdate, 
                jobstartdate, 
                CASE trans_status
                    WHEN 'N' THEN 1
                    WHEN 'U' THEN 2
                    WHEN 'D' THEN 3
                END,
                indice_geral
        ) AS p_indice_geral,
        CASE
            WHEN LEAD(indice_geral) OVER (
                PARTITION BY packiotid
                ORDER BY 
                    line, 
                    shiftstartdate, 
                    jobstartdate, 
                    CASE trans_status
                        WHEN 'N' THEN 1
                        WHEN 'U' THEN 2
                        WHEN 'D' THEN 3
                    END,
                    indice_geral
            ) IS NOT NULL THEN 'H'
            ELSE trans_status
        END AS f_trans_status
    FROM production_data_sync_enterprise_06
    WHERE shiftstartdate >= now() - interval '60 day'
        --AND site = 'MONTREAL'
)
UPDATE production_data_sync_enterprise_06
SET 
    prev_indice_geral = calculated_data.p_indice_geral,
    final_trans_status = calculated_data.f_trans_status,
	logics = 9,
	real_update = now()
FROM calculated_data
WHERE production_data_sync_enterprise_06.indice_geral = calculated_data.indice_geral
AND (production_data_sync_enterprise_06.final_trans_status is null or production_data_sync_enterprise_06.final_trans_status != calculated_data.f_trans_status);

--abaixo faz update de item number
WITH results AS (
    SELECT 
        id_order, 
        custom_field->>'cd_product' AS cd_product
    FROM production_orders
    WHERE id_enterprise = 6 
    AND id_order IN (
        SELECT DISTINCT job
        FROM production_data_sync_enterprise_06 pdse 
        WHERE shiftstartdate >= now() - interval '30 day'
        AND item IS NULL
        AND job IS NOT NULL
    )
)
UPDATE production_data_sync_enterprise_06 pdse
SET item = results.cd_product,
	real_update = now()
FROM results
WHERE pdse.item IS NULL
AND pdse.job IS NOT NULL
AND pdse.job = results.id_order
and results.cd_product is not null;
