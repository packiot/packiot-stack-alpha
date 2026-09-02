--
-- PostgreSQL database dump
--

\restrict Psvd81LZIgPS5EhIMAMzAjvJchVlEpfO4Dd9urO8GwzduLOFga8KvHHbsb61yew

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


SET default_tablespace = '';

SET default_table_access_method = heap;

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

 SELECT
	LOWER(desc_category) AS reason,
	SUM(duration) AS total_time,
	id_enterprise,
	id_equipment
FROM
	equipment_events
WHERE
	id_equipment = idEquipment
	AND desc_category IS NOT NULL
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
		duration >= (select stop_threshold_time from equipments e where e.id_equipment = ee.id_equipment)
			or
		duration is null
		)
	and (select tp_equipment from equipments where id_equipment = ee.id_equipment)=3
order by ts_event desc;
$$;


--
-- Name: h_downtimes_table_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_downtimes_table_2 (
    id_equipment_event bigint,
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    id_equipment integer,
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
    id_shift integer,
    id_enterprise integer
);


--
-- Name: h_piot_get_downtimes_equipment_level(text, text, text, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_equipment_level(in_ids_sites text, in_ids_areas text, in_ids_equipments text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now()) RETURNS SETOF public.h_downtimes_table_2
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := in_ids_sites::int[];
	ids_areas int[] := in_ids_areas::int[];
	ids_equips int[] := in_ids_equipments::int[];
begin
return query
--select 
--ts_event - date_trunc('week', ts_event),
--(extract('epoch' from (ts_event - date_trunc('week', ts_event)))-(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = aaa.id_equipment)))::int4 aaaaa,
--* from
--(
select 
	id_equipment_event, ts_event, ts_end, id_equipment, (select nm_equipment from equipments where id_equipment=aa.id_equipment), cd_machine, duration, cd_category, cd_category txt_category, --change to description when available
	cd_subcategory,	cd_subcategory txt_subcategory,
	txt_downtime_notes,	id_order , cd_shift, id_shift, id_enterprise 
from
	(select
		id_equipment_event,
		ts_event,
		ts_end,
		id_equipment,
		(select id_area from equipments e where e.id_equipment = ee.id_equipment) id_area,
		(select id_site from equipments e where e.id_equipment = ee.id_equipment) id_site,
		cd_machine,
		duration,
		cd_category,
		cd_category txt_category, --change to description when available
		cd_subcategory,
		cd_subcategory txt_subcategory, --change to description when available
		txt_downtime_notes,
		(select id_order from production_orders po where po.id_production_order  = (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)),
		(select cd_shift 
			from shifts sh
			where 
				id_shift = 
					(
						select id_shift from equipment_runtime_shift ers where
							ee.ts_event <@ ers.ts_range 
							and id_enterprise = ee.id_enterprise
							and id_equipment = ee.id_equipment
					)
		) cd_shift,
		(select id_shift from equipment_runtime_shift ers where
			ee.ts_event <@ ers.ts_range 
			and id_enterprise = ee.id_enterprise
			and id_equipment = ee.id_equipment
		) id_shift,			
	--	(select cd_shift from shift_hours sh where (extract('epoch' from (ts_event - date_trunc('week', ts_event))))::int4 <@ int4range((sh.begin_time+(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = ee.id_equipment))), (sh.end_time+(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = ee.id_equipment)))) and ((select id_area from equipments where id_equipment = ee.id_equipment) = sh.id_area)),
	--	(select id_shift from shift_hours sh where (extract('epoch' from (ts_event - date_trunc('week', ts_event))))::int4 <@ int4range((sh.begin_time+(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = ee.id_equipment))), (sh.end_time-(select week_begin from enterprises where id_enterprise=(select id_enterprise from equipments where id_equipment = ee.id_equipment)))) and ((select id_area from equipments where id_equipment = ee.id_equipment) = sh.id_area)),
		id_enterprise 
	from
		equipment_events ee
	where 
		status = 10
--		and ts_event >= date_trunc('month',now()-interval '1 day')
--		and ts_event < now()
		and ts_event >= _tsstart
		and ts_event < _tsend
		and 
			(
			duration >= (select stop_threshold_time from equipments e where e.id_equipment = ee.id_equipment)
				or
			duration is null
			)
		and (select tp_equipment from equipments where id_equipment = ee.id_equipment)=3
	) aa
where
	id_equipment = any(ids_equips)
	and id_area= any(ids_areas)
	and id_site = any(ids_sites)
--	id_equipment = 42
--	and id_area= 30
--	and id_site = 30
order by ts_event desc;
--)aaa
--where cd_shift='Noturno'
end
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
		left join equipment_runtime_shift ers on
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
		and ((not microstops_view and (ee.duration >= eq.stop_threshold_time or ee.duration is null )) or microstops_view  or cd_category is not null)
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
		left join equipment_runtime_shift ers on
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
		and ( ee.duration >= eq.stop_threshold_time or ee.duration is null )
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
		left join equipment_runtime_shift ers on
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
		and ((not microstops_view and (ee.duration >= eq.stop_threshold_time or ee.duration is null )) or microstops_view  or cd_category is not null)
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
		left join equipment_runtime_shift ers on
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
		and ((not microstops_view and (ee.duration >= eq.stop_threshold_time or ee.duration is null )) or microstops_view  or (cd_category is not null and cd_category <> '') )
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
-- Name: h_piot_get_downtimes_events_3(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_events_3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false) RETURNS SETOF public.h_downtimes_table_with_sector_3
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
		left join equipment_runtime_shift ers on
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
		and ((not microstops_view and (ee.duration >= eq.stop_threshold_time or ee.duration is null )) or microstops_view  or cd_category is not null)
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
		left join equipment_runtime_shift ers on
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
		and ((not microstops_view and (ee.duration >= eq.stop_threshold_time or ee.duration is null )) or microstops_view  or (cd_category is not null and cd_category <> '') )
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
    downtimes_per_category text[]
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
	join equipment_runtime_shift ers 
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
				) < e.stop_threshold_time
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
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_runtime_shift ev
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
		downtimes_per_category
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
	    	)) filter (where extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) < e.stop_threshold_time
	    	and cd_category is null 
	    	and extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) >0 ) ) over() duration_microstops,
	    sum( 
	    	sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)
	    	)) filter (where cd_category is not null) ) over () duration_justified,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.cd_category is not null and ee.planned_downtime = true) ) over () duration_planned,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.planned_downtime = false or ee.cd_category is null ) ) over () duration_unplanned
	    from equipment_events ee
	join equipments e on ee.id_equipment =e.id_equipment 
	join equipment_runtime_shift ers 
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
		from equipment_runtime_shift ers 
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
-- Name: h_piot_get_downtimes_per_category_equipment_level_new_4_test(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_per_category_equipment_level_new_4_test(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_get_downtimes_per_category_equipment_level_new
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
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_runtime_shift ev
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
		downtimes_per_category
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
	    	)) filter (where extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) < e.stop_threshold_time
	    	and cd_category is null 
	    	and extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)) >0 ) ) over() duration_microstops,
	    sum( 
	    	sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event)
	    	)) filter (where cd_category is not null) ) over () duration_justified,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.cd_category is not null and ee.planned_downtime = true) ) over () duration_planned,
	    sum( sum(extract(epoch from least(upper(ers.ts_range), coalesce(ee.ts_end, now())) - greatest(ers.ts_value, ee.ts_event) )) filter (where ee.planned_downtime = false or ee.cd_category is null ) ) over () duration_unplanned
	    from equipment_events ee
	join equipments e on ee.id_equipment =e.id_equipment 
	join equipment_runtime_shift ers 
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
		from equipment_runtime_shift ers 
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
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_runtime_shift ev
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
		from equipment_runtime_shift ers 
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
-- Name: h_piot_get_downtimes_resumo_2(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_resumo_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_get_downtimes_resumo_table
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
	min_ts_prod timestamptz := (select min(ts_value_production) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value_production) from equipment_runtime_shift ev
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
		from equipment_runtime_shift ers 
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
-- Name: h_piot_get_downtimes_sector_2(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_downtimes_sector_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), sector_view boolean DEFAULT false) RETURNS SETOF public.h_downtimes_table_with_sector_2
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
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
							ee.ts_event <@ ers.ts_range
--							and ers.id_enterprise = ee.id_enterprise
							and ers.id_equipment = ee.id_equipment
		left join shifts sh on ers.id_shift = sh.id_shift
		left join equipments peq on peq.id_equipment = eq.id_parentequipment
		left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
where
		status <> 6
		and ts_event > _tsstart::timestamp - interval '1 months'
		and (ee.ts_end < _tsend::timestamp + interval '1 months' or ee.ts_end is null)
		and tstzrange(ts_event::timestamp, ee.ts_end::timestamp, '[)') && tstzrange ((_tsstart at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin,(_tsend at time zone (st.timezone))::timestamp + interval '1 second' * st.day_begin, '[)')
		and ( ee.duration >= eq.stop_threshold_time or ee.duration is null )
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
				(case when sector_view
					then (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ppeq.id_equipment )
					else (select id_production_order from production_orders_runtime por where ee.ts_event <@ por.runtime_timerange and id_equipment = ee.id_equipment)
				end)
		),
		sh.cd_shift,
		ers.id_shift,
		ee.id_enterprise
	from
		equipment_events_man ee
		left join equipments eq on eq.id_equipment = ee.id_equipment
		left join sites st on eq.id_site = st.id_site
		left join equipment_runtime_shift ers on
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
		and ( ee.duration >= eq.stop_threshold_time or ee.duration is null )
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
	min_ts_prod timestamp := (select min(ts_value) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::date)::date 
								and ev.ts_value_production <= date_trunc('day', _tsend::date)::date) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamp := (select max(ts_end) from equipment_runtime_shift ev
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
		left join equipment_runtime_shift ers on
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
		and ((not microstops_view and (ee.duration >= eq.stop_threshold_time or ee.duration is null )) or microstops_view )
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
		left join equipment_runtime_shift ers on
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
		and ( ee.duration >= eq.stop_threshold_time or ee.duration is null )
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
-- Name: h_pending_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_pending_events (
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    id_equipment integer,
    id_enterprise integer,
    packml_topic character varying,
    ignore_cost boolean
);


--
-- Name: h_piot_get_equipment_pending_downtime(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_equipment_pending_downtime(in_packml_topic character varying[]) RETURNS SETOF public.h_pending_events
    LANGUAGE sql STABLE
    AS $$
SELECT ts_event, ts_end, duration, e.id_equipment, e.id_enterprise, p.packml_topic, ignore_cost
    FROM equipment_events ee
    JOIN equipments e ON ee.id_equipment = e.id_equipment
    join packml_register p on p.id_equipment = e.id_equipment
    WHERE p.packml_topic = ANY (in_packml_topic)
        AND ee.ts_event >= now() - interval '4 days'
        AND ee.status != 6
        AND (ee.duration >= e.stop_threshold_time or ee.duration is null)
        and ee.cd_category is null
    ORDER BY ts_event DESC;
$$;


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
        AND (ee.duration >= e.stop_threshold_time or ee.duration is null)
        and ee.cd_category is null
    ORDER BY ts_event DESC;
   $$;


--
-- Name: h_pending_events_with_event_id_cpack; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_pending_events_with_event_id_cpack (
    id_equipment_event bigint,
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    duration integer,
    id_equipment integer,
    id_enterprise integer,
    packml_topic character varying
);


--
-- Name: h_piot_get_equipment_pending_downtime_with_event_id_cpack(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_equipment_pending_downtime_with_event_id_cpack(in_packml_topic character varying[]) RETURNS SETOF public.h_pending_events_with_event_id_cpack
    LANGUAGE sql STABLE
    AS $$
	SELECT id_equipment_event, ts_event, ts_end, duration, e.id_equipment, e.id_enterprise, p.packml_topic
    FROM equipment_events ee
    JOIN equipments e ON ee.id_equipment = e.id_equipment
    join packml_register p on p.id_equipment = e.id_equipment
    WHERE p.packml_topic = ANY (in_packml_topic)
        AND (ee.ts_end >= now() - interval '8 hours' OR ee.ts_end IS NULL)
        AND ee.status != 6
        AND (ee.duration >= e.stop_threshold_time or ee.duration is null)
        and ee.cd_category is null
    ORDER BY ts_event DESC;
   $$;


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
-- Name: h_piot_get_events_timeline(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline(in_packml_topic character varying[]) RETURNS SETOF public.h_events_timeline
    LANGUAGE sql STABLE
    AS $$
SELECT
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
  p.packml_topic,
  'downtime' :: text as event_type
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND ee.ts_event >= now() - interval '4 days'
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
UNION 
SELECT
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	e.id_equipment,
	e.id_enterprise,
	eels.txt_downtime_notes,
	eels.cd_machine,
	eels.cd_category,
	eels.cd_subcategory,
	eels.change_over,
	p.packml_topic,
	'low_speed' :: text as event_type
FROM
	equipment_events_low_speed eels
	JOIN equipments e ON eels.id_equipment = e.id_equipment
	JOIN packml_register p ON p.id_equipment = e.id_equipment
WHERE
	p.packml_topic = ANY (in_packml_topic)
	AND eels.ts_event >= now() - interval '4 days'
	AND eels.status = 1 OR eels.status = 2
UNION
SELECT
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
  p.packml_topic,
  'manual' :: text as event_type
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment = e.id_equipment
  JOIN packml_register p on p.id_equipment = e.id_equipment
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND eem.ts_event >= now() - interval '4 days'
   -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
 
$$;


--
-- Name: h_events_timeline2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline2 (
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
    event_type text
);


--
-- Name: h_piot_get_events_timeline2(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline2(in_packml_topic character varying[]) RETURNS SETOF public.h_events_timeline2
    LANGUAGE sql STABLE
    AS $$
SELECT
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
  desc_category,
  desc_subcategory,
  p.packml_topic,
  'downtime' :: text as event_type
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
UNION 
SELECT
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
	'low_speed' :: text as event_type
FROM
	equipment_events_low_speed eels
	JOIN equipments e ON eels.id_equipment = e.id_equipment
	JOIN packml_register p ON p.id_equipment = e.id_equipment
WHERE
	p.packml_topic = ANY (in_packml_topic)
	AND eels.ts_event >= now() - interval '1 days'
	AND eels.status = 1 OR eels.status = 2
UNION
SELECT
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
  'manual' :: text as event_type
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment = e.id_equipment
  JOIN packml_register p on p.id_equipment = e.id_equipment
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND eem.ts_event >= now() - interval '1 days'
   -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
 
$$;


--
-- Name: h_events_timeline3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline3 (
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
-- Name: h_piot_get_events_timeline3(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline3(in_packml_topic character varying[]) RETURNS SETOF public.h_events_timeline3
    LANGUAGE sql STABLE
    AS $$

select
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
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND 
  ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null or ee.cd_category is not null))
  AND ee.status != 6
  and ee.cd_category is not null
  
UNION 
SELECT
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
SELECT
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
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null or ee.cd_category is not null))
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
-- Name: h_events_timeline3_with_event_id_cpack; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline3_with_event_id_cpack (
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
-- Name: h_piot_get_events_timeline3_with_event_id_cpack(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline3_with_event_id_cpack(in_packml_topic character varying[]) RETURNS SETOF public.h_events_timeline3_with_event_id_cpack
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
  AND 
  (ee.ts_end >= now() - interval '8 hours' or ee.ts_end is null)
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null or ee.cd_category is not null))
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
	AND eels.ts_end >= now() - interval '9 hours'
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
  AND eem.ts_event >= now() - interval '8 hours'
   -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
 
$$;


--
-- Name: h_events_timeline4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline4 (
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
    custom_field jsonb,
    cd_category_client integer,
    cd_subcategory_client integer
);


--
-- Name: h_piot_get_events_timeline4(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline4(in_packml_topic character varying[]) RETURNS SETOF public.h_events_timeline4
    LANGUAGE sql STABLE
    AS $$

select
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
  po.custom_field,
  cd_category_client,
  cd_subcategory_client
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND 
  ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
  
UNION 
SELECT
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
	po.custom_field,
	null,
	null
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
SELECT
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
  po.custom_field,
	null,
	null
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
-- Name: h_events_timeline5; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_events_timeline5 (
    ts_event timestamp with time zone,
    ts_end timestamp with time zone,
    fault integer,
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
    custom_field jsonb,
    cd_category_client integer,
    cd_subcategory_client integer,
    ignore_cost boolean
);


--
-- Name: h_piot_get_events_timeline5(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline5(in_packml_topic character varying[]) RETURNS SETOF public.h_events_timeline5
    LANGUAGE sql STABLE
    AS $$

select
  ts_event,
  ee.ts_end,
  ee.fault,
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
  po.custom_field,
  cd_category_client,
  cd_subcategory_client,
  ignore_cost
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND 
  ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
  
UNION 
SELECT
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	eels.fault,
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
	po.custom_field,
	null,
	null,
	null
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
SELECT
  eem.ts_event as ts_event,
  eem.ts_end as ts_end,
  eem.fault,
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
  po.custom_field,
	null,
	null,
	eem.ignore_cost
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
            (ee.duration >= e.stop_threshold_time)
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
  ) :: integer >= e.stop_threshold_time -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC;
$$;


--
-- Name: h_piot_get_events_timeline_from_po_2(integer, text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline_from_po_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, _id_production_order integer DEFAULT NULL::integer) RETURNS SETOF public.h_events_equipment_timeline_2
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
	_id_prod_order int := (_id_production_order);
begin
	return query

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
	e.id_equipment = any(ids_equips)
    and e.id_area= any(ids_areas)
    and e.id_site = any(ids_sites)
--    ee.id_equipment = _id_equipment
--  	 case when _id_production_order is not null then ee.id_equipment = (select id_equipment from production_orders where id_production_order = _id_production_order) else true end
    and (_id_prod_order is null or 
    	ee.id_equipment = (select id_equipment from production_orders where id_production_order = _id_prod_order)
    )
	and (_id_prod_order is null or 
    	ee.ts_event::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_prod_order ) )
    )
    and (
            (ee.duration >= e.stop_threshold_time)
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
    e.id_equipment = any(ids_equips)
    and e.id_area= any(ids_areas)
    and e.id_site = any(ids_sites)
--    and case when _id_prod_order is not null then e.id_equipment = (select id_equipment from production_orders where id_production_order = _id_prod_order) else true end
  and 
    (_id_prod_order is null or 
    e.id_equipment = (select id_equipment from production_orders where id_production_order = _id_prod_order)
    )
--  eem.ts_event_start >= now() - interval '24 hour'
--  (select runtime_timerange from production_orders_runtime por where id_production_order=_id_prod_order) @> eem.ts_event_start
  and 
    (_id_prod_order is null or 
  eem.ts_event::timestamptz <@ any( array(select runtime_timerange from production_orders_runtime where id_production_order = _id_prod_order ) )
    )
  AND extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer >= e.stop_threshold_time -- AND eem.status != 6 -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER by ts_event DESC;


end $$;


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
-- Name: h_piot_get_events_timeline_full(integer, text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline_full(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, _id_production_order integer DEFAULT NULL::integer) RETURNS SETOF public.h_events_timeline_full
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
	_id_prod_order int := (_id_production_order);
begin
	return query	
--	create table h_events_timeline_full as 
	select
		ev.*
	from
		v_events ev
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
	ORDER by ts_timeline DESC;
end $$;


--
-- Name: h_piot_get_events_timeline_full_with_filter(integer, text, text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline_full_with_filter(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_event_types text, _id_production_order integer DEFAULT NULL::integer) RETURNS SETOF public.h_events_timeline_full
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
	id_event_types int[] := (
							select array_agg(event_type) 
							from (select distinct  event_type from v_events) s1
							 where case
							 		when cardinality(in_event_types::int[]) = 0 then true
							 		else event_type = any( in_event_types::int[])
							 	 end
							 );
	_id_prod_order int := (_id_production_order);
begin
	return query	
--	create table h_events_timeline_full as 
	select
		ev.*
	from
		v_events ev
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
	    and event_type = any(id_event_types)
	ORDER by ts_timeline DESC;
end $$;


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
-- Name: h_piot_get_events_timeline_full_with_filter_2(integer, text, text, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_events_timeline_full_with_filter_2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_event_types text, _id_production_order integer DEFAULT NULL::integer) RETURNS SETOF public.h_events_timeline_full2
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
--	id_event_types int[] := (
--							select array_agg(event_type) 
--							from (select distinct  event_type from v_events) s1
--							 where case
--							 		when cardinality(in_event_types::int[]) = 0 then true
--							 		else event_type = any( in_event_types::int[])
--							 	 end
--							 );
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
	    and event_type = any(id_event_types)
	ORDER by ts_timeline DESC;
end $$;


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
	min_ts_prod timestamptz := (select min(ts_value) from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc('day', _tsstart::timestamp) 
								and ev.ts_value_production <= date_trunc('day', _tsend::timestamp)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_end) from equipment_runtime_shift ev
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
-- Name: h_piot_get_hasura_test(character varying[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_hasura_test(in_packml_topic character varying[]) RETURNS SETOF public.hasura_test
    LANGUAGE sql STABLE
    AS $$

select
  ts_event,
  ee.ts_end,
  ee.fault,
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
  po.custom_field,
  cd_category_client,
  cd_subcategory_client,
  ignore_cost
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  join packml_register p on p.id_equipment = e.id_equipment
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  p.packml_topic = ANY (in_packml_topic)
  AND 
  ee.ts_event >= now() - interval '1 days'
  AND ((ee.duration >= e.stop_threshold_time) or (ee.ts_end is null))
  AND ee.status != 6
  and ee.cd_category is not null
  
UNION 
SELECT
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	eels.fault,
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
	po.custom_field,
	null,
	null,
	null
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
SELECT
  eem.ts_event as ts_event,
  eem.ts_end as ts_end,
  eem.fault,
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
  po.custom_field,
	null,
	null,
	eem.ignore_cost
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
-- Name: h_piot_mission_control; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_mission_control (
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
    id_production_order bigint,
    id_order integer,
    production_programmed bigint,
    po_net_production double precision,
    nm_client character varying,
    duration double precision,
    expected_time double precision,
    curshift_lastspeed double precision,
    curshift_grosprod double precision,
    curshift_netprod double precision,
    prev1shift_netprod double precision,
    prev2shift_netprod double precision,
    curshift_scrap double precision,
    planned_duration double precision,
    planned_duration_percent double precision,
    change_over_duration double precision,
    change_over_duration_percent double precision,
    unplanned_duration double precision,
    unplanned_duration_percent double precision,
    total_stopped_time double precision
);


--
-- Name: h_piot_get_mission_control(integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_mission_control(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) RETURNS SETOF public.h_piot_mission_control
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
	SELECT sh_info.id_site,
    sh_info.id_area,
    a2.nm_area,
    sh_info.id_equipment AS id_line,
    e2.nm_equipment AS nm_line,
    e2.id_enterprise,
    uecs.oee AS currshift_oee,
    sh.cd_shift AS curr_shift_name,
    sh2.cd_shift AS prev1_shift_name,
    sh3.cd_shift AS prev2_shift_name,
    po.id_production_order,
    po.id_order,
    po.production_programmed,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value > po.ts_start) AS po_net_production,
    c.nm_client,
    date_part('epoch'::text, now() - po.ts_start) AS duration,
    date_part('epoch'::text, po.production_programmed::double precision / NULLIF(avg(aevm.speed), 0::double precision) * '00:01:00'::interval) AS expected_time,
    avg(aevm.speed) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range AND aevm.speed IS NOT null and aevm.state <> 10 ) AS curshift_lastspeed,
    sum(aevm.gross_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range) AS curshift_grosprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range) AS curshift_netprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.prev1_shift_range) AS prev1shift_netprod,
    sum(aevm.net_production_incr) FILTER (WHERE aevm.ts_value <@ sh_info.prev2_shift_range) AS prev2shift_netprod,
    GREATEST(0::double precision, sum(aevm.scrap_incr) FILTER (WHERE aevm.ts_value <@ sh_info.curshift_range)) AS curshift_scrap,
    stoppedtime.planned_duration,
    stoppedtime.planned_duration_percent,
    stoppedtime.change_over_duration,
    stoppedtime.change_over_duration_percent,
    stoppedtime.unplanned_duration,
    stoppedtime.unplanned_duration_percent,
    stoppedtime.total_stopped_time
   FROM (select * from ca_agg_equipment_values_1hour where
         	id_enterprise = in_id_enterprise
            and id_site = any (ids_sites)
            and id_area = any (ids_areas)
            and id_equipment = any (ids_equips)
     )aevm
     RIGHT JOIN ( SELECT ers.id_equipment,
            e.id_area,
            e.id_site,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[1] AS current_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[1] AS curshift_range,
            max(uecs2.oee) AS currshift_oee,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[2] AS prev1_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[2] AS prev1_shift_range,
            (array_agg(ers.id_shift_hour ORDER BY ers.ts_value DESC))[3] AS prev2_shift,
            (array_agg(ers.ts_range ORDER BY ers.ts_value DESC))[3] AS prev2_shift_range
           FROM (select * from equipment_runtime_shift where id_equipment = any (ids_equips)) ers
             LEFT JOIN equipments e USING (id_equipment)
             LEFT JOIN uns_equipment_current_shift uecs2 ON uecs2.id_equipment = ers.id_equipment
          WHERE ers.ts_value < now() AND ers.ts_value > (now() - '3 days'::interval) AND e.tp_equipment = 3
          GROUP BY ers.id_equipment, e.id_area, e.id_site) sh_info USING (id_equipment)
     LEFT JOIN uns_equipment_current_shift uecs USING (id_equipment)
     LEFT JOIN ( SELECT ev.id_equipment,
            pos.id_production_order,
            pos.id_order,
            pos.id_client,
            pos.production_programmed,
            pos.production_real,
            pos.ts_start,
            last(ev.id_production_order, ev.ts_value) FILTER (WHERE ev.id_production_order IS NOT NULL) AS last_po_order
           FROM (select * from ca_agg_equipment_values_1hour where
         	id_enterprise = in_id_enterprise
            and id_site = any (ids_sites)
            and id_area = any (ids_areas)
            and id_equipment = any (ids_equips)
     		) ev
             LEFT JOIN production_orders pos USING (id_equipment, id_production_order)
          WHERE ev.tp_equipment = 3 AND pos.status = 2
          GROUP BY ev.id_equipment, pos.id_production_order, pos.id_order, pos.id_client, pos.production_programmed, pos.production_real, pos.ts_start) po USING (id_equipment)
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN shift_hours sh(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh.id_shift_hour = sh_info.current_shift
     LEFT JOIN shift_hours sh2(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh2.id_shift_hour = sh_info.prev1_shift
     LEFT JOIN equipments e2(id_equipment_1, cd_equipment, nm_equipment, "position", tp_equipment, id_area, id_site, id_enterprise, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons) ON e2.id_equipment_1 = aevm.id_equipment
     LEFT JOIN areas a2 ON a2.id_area = aevm.id_area
     LEFT JOIN shift_hours sh3(id_shift_hour, id_shift, cd_shift, begin_time, end_time, id_enterprise, id_site, id_area, day_number, day_week, shift_size, id_equipment_1, duration) ON sh3.id_shift_hour = sh_info.prev2_shift
     LEFT JOIN ( SELECT dsum.id_equipment,
            dsum.planned_duration,
            dsum.total_stopped_time,
            dsum.planned_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS planned_duration_percent,
            dsum.change_over_duration,
            dsum.change_over_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS change_over_duration_percent,
            dsum.unplanned_duration,
            dsum.unplanned_duration / NULLIF(dsum.total_stopped_time, 0::double precision) AS unplanned_duration_percent
           FROM ( SELECT durationsum.id_equipment,
                    durationsum.planned_duration,
                    durationsum.change_over_duration,
                    durationsum.unplanned_duration,
                    durationsum.planned_duration + durationsum.change_over_duration + durationsum.unplanned_duration AS total_stopped_time
                   FROM ( SELECT durations.id_equipment,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE
                                    WHEN durations.change_over = true THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS change_over_duration,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE
                                    WHEN durations.change_over = false AND durations.planned_downtime = true THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS planned_duration,
                            COALESCE(date_part('epoch'::text, sum(
                                CASE
                                    WHEN durations.change_over = false AND durations.planned_downtime = false THEN durations.duration
                                    ELSE NULL::interval
                                END)), 0::double precision) AS unplanned_duration
                           FROM ( SELECT ee.planned_downtime,
                                    ee.change_over,
                                    ee.id_equipment,
                                    ee.status,
                                    ee.ts_event,
                                    ee.ts_end,
                                    sum(
CASE
 WHEN ee.ts_event >= (date_trunc('day'::text, now()) + '00:00:01'::interval * e3.day_begin::double precision) THEN
 CASE
  WHEN ee.ts_end IS NULL THEN now() - ee.ts_event
  ELSE ee.ts_end - ee.ts_event
 END
 ELSE
 CASE
  WHEN ee.ts_end IS NULL THEN now() - ee.ts_event
  ELSE
  CASE
   WHEN ee.ts_end > (date_trunc('day'::text, now()) + '00:00:01'::interval * e3.day_begin::double precision) THEN ee.ts_end - ee.ts_event
   ELSE NULL::interval
  END
 END
END) AS duration
                                   FROM equipment_events ee
                                     LEFT JOIN ( SELECT equipments.id_equipment,
    equipments.tp_equipment
   FROM equipments) e2_1 ON e2_1.id_equipment = ee.id_equipment
                                     LEFT JOIN ( SELECT enterprises.id_enterprise,
    enterprises.day_begin
   FROM enterprises) e3 ON e3.id_enterprise = ee.id_enterprise
                                  WHERE ee.ts_event >= (now() - '4 days'::interval) AND e2_1.tp_equipment = 3 AND ee.status = 10
                                  GROUP BY ee.id_equipment, e2_1.id_equipment, ee.ts_event, e2_1.tp_equipment, e3.id_enterprise, e3.day_begin) durations
                          GROUP BY durations.id_equipment) durationsum) dsum) stoppedtime(id_equipment_1, planned_duration, total_stopped_time, planned_duration_percent, change_over_duration, change_over_duration_percent, unplanned_duration, unplanned_duration_percent) ON stoppedtime.id_equipment_1 = sh_info.id_equipment
  WHERE aevm.ts_value >= (now() - '4 days'::interval)
  GROUP BY sh_info.id_site, sh_info.id_area, sh_info.id_equipment, sh_info.currshift_oee, sh.cd_shift, sh2.cd_shift, sh3.cd_shift, po.id_production_order, po.id_order, po.ts_start, c.nm_client, po.production_programmed, e2.nm_equipment, a2.nm_area, e2.id_enterprise, stoppedtime.planned_duration, stoppedtime.planned_duration_percent, stoppedtime.change_over_duration, stoppedtime.change_over_duration_percent, stoppedtime.unplanned_duration, stoppedtime.unplanned_duration_percent, stoppedtime.total_stopped_time, uecs.oee;
end
$$;


--
-- Name: h_piot_mission_control_area_new; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_mission_control_area_new (
    ts_value_production date,
    id_enterprise integer,
    id_area integer,
    nm_area character varying,
    gross_production double precision,
    net_production double precision,
    scrap double precision,
    oee_area_raw double precision,
    oee_area double precision
);


--
-- Name: h_piot_get_mission_control_area(integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_mission_control_area(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text) RETURNS SETOF public.h_piot_mission_control_area_new
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
	return query
	with last_shift as (
	select
		ls_1.id_area,
		ls_1.id_shift_hour,
		ls_1.ts_value_production,
		sum(ls_1.ideal_production) as ideal_production
	from
		(
		select
			safev.id_area,
			safev.ts_value,
			safev.id_shift_hour,
			safev.ideal_production,
			safev.ts_value_production,
			row_number(*) over (partition by safev.id_area
		order by
			safev.ts_value desc) as rn
		from
			shift_agg_from_events_v2 safev
		where
			safev.ts_value_production > (now() - '2 days'::interval)) ls_1
	where
		ls_1.rn = 1
	group by
		ls_1.id_area,
		ls_1.id_shift_hour,
		ls_1.ts_value_production
),
areas_sum as (
	select
		vmc.id_enterprise,
		vmc.id_area,
		vmc.nm_area,
		sum(vmc.curshift_grosprod) as gross_production,
		sum(vmc.curshift_netprod) as net_production,
		sum(vmc.curshift_scrap) as scrap
	from
		(
			select
				*
			from
				public.h_piot_get_mission_control(in_id_enterprise,
				in_id_sites,
				in_id_areas,
				in_id_equipments)
		) vmc
	group by
		vmc.id_enterprise,
		vmc.id_area,
		vmc.nm_area
)
select
	ls.ts_value_production,
	sa.id_enterprise,
	sa.id_area,
	sa.nm_area,
	sa.gross_production,
	sa.net_production,
	sa.scrap,
	sa.net_production / nullif(ls.ideal_production, 0::numeric)::double precision as oee_area_raw,
	coalesce(least(1::double precision, greatest(0::double precision, sa.net_production / nullif(ls.ideal_production, 0::numeric)::double precision)), 0::double precision) as oee_area
from
	areas_sum sa
	left join last_shift ls using (id_area);


end $$;


--
-- Name: h_piot_mission_control_area_uns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_mission_control_area_uns (
    id_enterprise integer,
    id_area integer,
    nm_area character varying,
    gross_production real,
    net_production real,
    scrap real,
    oee real
);


--
-- Name: h_piot_get_mission_control_area_uns(integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_mission_control_area_uns(in_id_enterprise integer, in_id_areas text, in_id_sites text) RETURNS SETOF public.h_piot_mission_control_area_uns
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
	
select
	uacs.id_enterprise,
	uacs.id_area,
	uacs.nm_area,
	uacs.gross_production,
	uacs.net_production,
	uacs.scrap,
	uacs.oee
from
	uns_area_current_shift uacs
where
    uacs.id_site = any (ids_sites)
    and uacs.id_area = any (ids_areas);

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
	
select
	uacs.id_enterprise,
	uacs.id_area,
	uacs.nm_area,
	uacs.gross_production,
	uacs.net_production,
	uacs.scrap,
	uacs.oee,
	uacs.target,
	uacs.net_production + ((uacs.net_production/nullif(uacs.running_time , 0)) * (duration - elapsed_time)) as projected_production,
	oeet.vl_shift
from
	uns_area_current_shift uacs
	left join oee_targets oeet on (uacs.id_area = oeet.id_area and oeet.id_equipment is null)
where
    uacs.id_site = any (ids_sites)
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
                   FROM (select * from agg_equipment_values_1min_t aaa
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
-- Name: h_piot_mission_control_uns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_mission_control_uns (
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
    status_time integer
);


--
-- Name: h_piot_get_mission_control_uns(integer, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_get_mission_control_uns(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text) RETURNS SETOF public.h_piot_mission_control_uns
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
	    uecm.speed,
	    uecs.gross_production AS curshift_grosprod,
	    uecs.net_production AS curshift_netprod,
	    uecs.prev1_net_production AS prev1shift_netprod,
	    uecs.prev2_net_production AS prev2shift_netprod,
	    uecs.scrap AS curshift_scrap,
	    uecs.planned_downtime,
	    uecs.planned_duration_perc as planned_duration_percent,
	    uecs.change_over_duration,
	    uecs.change_over_duration_perc as change_over_duration_percent,
	    uecs.unplanned_downtime as unplanned_duration,
	    uecs.unplanned_duration_perc,
	    uecs.stopped_time,
	    uecm.status_24h,
	    uecm.status,
	    uecm.status_time
    	from uns_equipment_current_job uecj
        join uns_equipment_current_shift uecs on (uecs.id_equipment=uecj.id_equipment)
        join uns_equipment_current_metrics uecm on (uecm.id_equipment=uecj.id_equipment)
        where
        	uecm.id_site = any (ids_sites)
       		and uecm.id_area = any (ids_areas)
       		and uecm.id_equipment = any (ids_equips);
     
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
	from uns_equipment_current_job uecj
	join uns_equipment_current_shift uecs on (uecs.id_equipment=uecj.id_equipment)
	join uns_equipment_current_metrics uecm on (uecm.id_equipment=uecj.id_equipment)
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
	equipment_runtime_shift ers
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
    array_agg text[]
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
									else (select min(ts_value) from equipment_runtime_shift ev
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
										from equipment_runtime_1hour ev
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
									from equipment_runtime_shift ev
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
						equipment_runtime_shift ers
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
								equipment_runtime_shift_1week ers
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
								equipment_runtime_shift_1month ers
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
								equipment_runtime_1hour erh 
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
-- Name: h_piot_home(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_home(in_id_enterprise integer) RETURNS SETOF public.h_piot_home_table
    LANGUAGE plpgsql STABLE
    AS $$
begin
	return query 
with last_minute_status as(
	select 
	id_equipment, 
	CASE
		WHEN COALESCE(gross, 0.0::double precision) >= (aa.minimum_ideal_performance_threshold * aa.production_speed::double precision) THEN 'running'::text
		WHEN COALESCE(gross, 0.0::double precision) < (aa.minimum_ideal_performance_threshold * aa.production_speed::double precision) AND COALESCE(gross, 0.0::double precision) >= (aa.minimum_performance_threshold * aa.production_speed::double precision) THEN 'lowSpeed'::text
		WHEN COALESCE(gross, 0::double precision) < (aa.minimum_performance_threshold * aa.production_speed::double precision) THEN 'stopped'::text
		ELSE 'unknown'
	END status
	from
	(
		select * from
		(select 
		    id_equipment,
		    sum(gross_production_incr) gross
		from ca_agg_equipment_values_1s caevs 
		where
			ts_value >= now()- interval '1 minutes' and tp_equipment = 3
			and id_enterprise = in_id_enterprise
		group by id_equipment) aaa
		left JOIN equipments e2(id_equipment_1, cd_equipment, nm_equipment, "position", tp_equipment, id_area, id_site, id_enterprise, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons) ON e2.id_equipment_1 = aaa.id_equipment
	) aa
)
--select * from last_minute_status
select distinct id_enterprise, jsonb_agg(sites) as sites from 
(
select distinct
	id_enterprise,
	id_site,
	jsonb_build_object(
   		'areas', jsonb_agg(areas),
		'id_site', id_site,
		'nm_site', (select nm_site from sites where id_site=area_data.id_site)
		) as sites
		from 
(
select distinct
   	id_enterprise,
   	id_site,
   	id_area,
	jsonb_build_object(
   		'id_area', equipment_data.id_area,
		'nm_area', (select nm_area from areas where id_area=equipment_data.id_area),
		'gross', equipment_data.gross,
		'net', equipment_data.net,
		'scrap',  equipment_data.scrap,
		'oee', coalesce(
					(select (oee_componentes->>'oee')::float8 from h_piot_oee_score_fix1(
						id_enterprise, --in_id_enterprise,
					    '{}'::TEXT, --in_id_equipments,
					    CONCAT('{',equipment_data.id_area ,'}')::TEXT,--in_id_areas,
					    CONCAT('{',id_site,'}')::TEXT,--in_id_sites,
					    '{}'::TEXT,--in_ids_shifts,
					    date_trunc('day', now()), --in_begin_time,
					    now(), --in_end_time,
					    'DAY',
					    'AREA' --nav_level text DEFAULT :,
			   		 ))
				, 0),
		'lines', equipment_data.lines
		) as areas
   from 
   (
		select distinct
			id_enterprise,
			e2.id_area,
			e2.id_site,
			sum(coalesce(aevm.gross, 0)) over (partition by id_area) gross,
			sum(coalesce(aevm.net, 0)) over (partition by id_area) net,
			sum(coalesce(aevm.gross, 0)-coalesce(aevm.net, 0) ) over (partition by id_area) scrap,
			jsonb_agg(jsonb_build_object(
					 		'id_equipment', aevm.id_equipment,
				            'nm_equipment', e2.nm_equipment,
				            'gross', coalesce(aevm.gross, 0),
				            'net', coalesce(aevm.net, 0),
				            'scrap',  coalesce(aevm.gross, 0) - coalesce(aevm.net, 0)
				            ,'status', coalesce((select status from last_minute_status where id_equipment=aevm.id_equipment), 'unknown')
			)) over (partition by id_area) as lines
		from 
	   		(
				select
					id_equipment,
					sum(net_production_incr) net,
					sum(gross_production_incr) gross
				from v_agg_equipment_values_1hour
				where
					tp_equipment=3
					and ts_value_production = date_trunc('day', now())
					and id_enterprise = in_id_enterprise
				group by id_equipment, id_area
			)aevm
     		LEFT JOIN equipments e2(id_equipment_1, cd_equipment, nm_equipment, "position", tp_equipment, id_area, id_site, id_enterprise, id_parentequipment, stop_threshold_time, production_speed, alerts, performance_alert_threshold, id_equipment_type, minimum_performance_threshold, require_downtime_reason, sector_equipment_infeed, sector_equipment_outfeed, status_type, id_counter_status, id_equipment_state_status, id_equipment_state_idle, id_equipment_state_starved, id_equipment_state_blocked, id_equipment_status_mirror, id_packed_counter, cd_sector, id_equipment_state_fault, downtime_reasons, minimum_ideal_performance_threshold, custom, scrap_reasons) ON e2.id_equipment_1 = aevm.id_equipment
			group by e2.id_area, aevm.id_equipment, e2.nm_equipment, gross, net, e2.id_site, e2.id_enterprise
	) equipment_data
	group by id_area, lines, gross, net, scrap, id_site, id_enterprise 
	) area_data
group by id_enterprise, id_site
) site_data
group by id_enterprise;
return;
end
$$;


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
					left join uns_area_current_day uacd using (id_area)
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
								left join uns_equipment_current_metrics uecm using (id_equipment, id_enterprise, nm_equipment, id_area)
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
    info text[]
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
									else (select min(ts_value) from equipment_runtime_shift ev
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
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_runtime_shift ev
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
		equipment_runtime_shift ers
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
-- Name: h_piot_oee_progress_chart_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_progress_chart_data (
    id_enterprise bigint,
    ts timestamp with time zone,
    shift_oee jsonb,
    shift_change_overs jsonb,
    avg_production double precision,
    oee numeric,
    average_order_size numeric,
    oee_disponibilidade double precision,
    oee_qualidade double precision,
    oee_desempenho double precision
);


--
-- Name: h_piot_oee_progress_data(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_progress_data(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_piot_oee_progress_chart_data
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
begin 
	-- the finest time grain is day
	return query 
	select 
		rts.id_enterprise::int8,
		rts.ts::timestamptz,
		jsonb_object_agg(id_shift, round((100*net_production/nullif(ideal_production, 0))::numeric, 3)) shift_oee, 
		jsonb_object_agg(id_shift, change_overs) shift_change_overs, 
		coalesce(sum(avg_production), 0)::float8 as avg_production,
		round(coalesce(100*sum(rts.net_production)/nullif(sum(rts.ideal_production), 0), 0)::numeric, 3)::numeric as oee,
		coalesce(round((sum(avg_production)/(sum(ops_count) + 1))::numeric, 3 ) , 0)::numeric average_order_size,
		(sum(running_time) )/nullif(sum(available_time)- sum(planned_downtime),0)::float8 as oee_disponibilidade,
		(sum(net_production) ) /nullif(sum(gross_production), 0)::float8 as oee_qualidade,
		case 
			when ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
			/ nullif(	
						--- OEE_A
						( 
							(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
							* -- OEE_Q
							(sum(net_production)/nullif(sum(gross_production), 0) ) 
						)
					, 0) ) <= 1.0 
					and ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
						/ nullif(	
									--- OEE_A
									( 
										(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
										* -- OEE_Q
										(sum(net_production)/nullif(sum(gross_production), 0) ) 
									)
								, 0) ) >= 0.0				
				then ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
			/ nullif(	
						--- OEE_A
						( 
							(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
							* -- OEE_Q
							(sum(net_production)/nullif(sum(gross_production), 0) ) 
						)
					, 0) ) 
			when ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
			/ nullif(	
						--- OEE_A
						( 
							(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
							* -- OEE_Q
							(sum(net_production)/nullif(sum(gross_production), 0) ) 
						)
					, 0) ) > 1.0 then 1.0
			when ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
			/ nullif(	
						--- OEE_A
						( 
							(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
							* -- OEE_Q
							(sum(net_production)/nullif(sum(gross_production), 0) ) 
						)
					, 0) ) < 0.0 then 0.0
			else null
		end::float8 as oee_desempenho
	from 
	(
		select 
				e.id_enterprise,
				t.ts,
				sh.cd_shift id_shift,
				avg(net) as avg_production,
				sum(ers.net) net_production ,
				sum(ers.gross) gross_production ,
				sum(ers.ideal_production) ideal_production,
				sum(ers.changeover_time) as change_overs,
				sum(ers.duration) duration,
				sum(e.production_speed) production_speed,
				count(e.id_equipment) ids,
				sum(ers.available_time) as available_time,
				sum(ers.planned_downtime) planned_downtime,
				sum(ers.running_time) running_time,
				coalesce(count(por.id_production_orders_runtime), 0) as ops_count
		from equipment_runtime_shift ers
		join equipments e on ers.id_equipment = e.id_equipment 
		join sites s on e.id_site = s.id_site  
		join shifts sh on sh.id_shift = ers.id_shift 
		left join production_orders_runtime por 
			on por.id_equipment = ers.id_equipment 
			and ers.ts_range && por.runtime_timerange 
		right join (
					select ts.ts
					from generate_series(date_trunc(time_grain::text, in_begin_time::timestamptz)::date,
												   (date_trunc(time_grain, in_end_time::timestamptz))::date,
												   ('1'||time_grain)::interval) ts(ts) 
					) t on t.ts::date = date_trunc('day', ers.ts_value at time zone s.timezone )::date
		where ers.ts_value >= in_begin_time::timestamptz and ers.ts_value < in_end_time::timestamptz
		and e.tp_equipment = 3
		and e.id_enterprise = in_id_enterprise
		and e.id_site = any( ids_sites )
		and e.id_area = any ( ids_areas )
		and ers.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
		group by 
			e.id_enterprise,
			sh.cd_shift,
			t.ts
	) rts
	group by rts.id_enterprise, rts.ts;
end
$$;


--
-- Name: h_piot_oee_progress_data1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_progress_data1 (
    id_enterprise integer,
    cd_equipment text,
    cd_shift text,
    jsonb_agg jsonb
);


--
-- Name: h_piot_oee_progress_data_teste1(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_progress_data_teste1(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_progress_data1
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
					nm_site::text as cd_equipment,
					null::text as cd_shift,
					jsonb_agg(
						jsonb_build_object(
								'ts', s1.ts,
								'oee', (oee_a) * (oee_q) * (oee_p),
								'oee_a',  (oee_a),
								'oee_q', (oee_q), 
								'oee_p', (oee_p)
						)
					) 
				from 
				(
				select 
					--(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_site from sites where id_site = s.id_site) as nm_site,
					ts_value as ts,
					oee_a,
					oee_p,
					oee_q,
					oee
					from site_runtime_1day s
					where id_site = any( in_id_sites::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
				) s1
				group by 1, 2, 3
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					nm_site::text as cd_equipment,
					cd_shift::text as cd_shift,
					jsonb_agg(
						jsonb_build_object(
								'ts', s1.ts,
								'oee', (oee_a) * (oee_q) * (oee_p),
								'oee_a',  (oee_a),
								'oee_q', (oee_q), 
								'oee_p', (oee_p)
						)
					) 
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_site from sites where id_site = s.id_site) as nm_site,
					ts_value as ts,
					oee_a,
					oee_p,
					oee_q,
					oee
					from site_runtime_shift s
					where id_site = any( in_id_sites::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
				) s1
				group by 1, 2, 3
				order by 3;
		end if;
	ELSEif nav_level = 'AREA' THEN
		if not is_shift_filtered then
			return query
			select 
					in_id_enterprise as id_enterprise,
					nm_area::text as cd_equipment,
					null::text as cd_shift,
					jsonb_agg(
						jsonb_build_object(
								'ts', s1.ts,
								'oee', (oee_a) * (oee_q) * (oee_p),
								'oee_a',  (oee_a),
								'oee_q', (oee_q), 
								'oee_p', (oee_p)
						)
					)
				from 
				(
				select 
					(select nm_area from areas where id_area = s.id_area) as nm_area,
					ts_value as ts,
					oee_a,
					oee_p,
					oee_q,
					oee
					from area_runtime_1day s
					where id_area = any( in_id_areas::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
				) s1
				group by 1, 2, 3
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					nm_area::text as cd_equipment,
					cd_shift::text as cd_shift,
					jsonb_agg(
						jsonb_build_object(
								'ts', s1.ts,
								'oee', (oee_a) * (oee_q) * (oee_p),
								'oee_a',  (oee_a),
								'oee_q', (oee_q), 
								'oee_p', (oee_p)
						)
					) 
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select nm_area from areas where id_area = s.id_area) as nm_area,
					ts_value as ts,
					oee_a,
					oee_p,
					oee_q,
					oee
					from area_runtime_shift s
					where id_area = any( in_id_areas::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
				) s1
				group by 1, 2, 3
				order by 3;
		end if;
	ELSEif nav_level = 'EQUIPMENT' THEN
		if not is_shift_filtered then
			return query
			select 
					in_id_enterprise as id_enterprise,
					cd_equipment::text as cd_equipment,
					null::text as cd_shift,
					jsonb_agg(
						jsonb_build_object(
								'ts', s1.ts,
								'oee', (oee_a) * (oee_q) * (oee_p),
								'oee_a',  (oee_a),
								'oee_q', (oee_q), 
								'oee_p', (oee_p)
						)
					)
				from 
				(
				select 
					(select cd_equipment from equipments where id_equipment = s.id_equipment) as cd_equipment,
					ts_value as ts,
					oee_a,
					oee_p,
					oee_q,
					oee
					from equipment_runtime_1day s
					where id_equipment = any( in_id_equipments::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
				) s1
				group by 1, 2, 3
				order by 3;
		ELSE
			return query 
				select 
					in_id_enterprise as id_enterprise,
					cd_equipment::text as cd_equipment,
					cd_shift::text as cd_shift,
					jsonb_agg(
						jsonb_build_object(
								'ts', s1.ts,
								'oee', (oee_a) * (oee_q) * (oee_p),
								'oee_a',  (oee_a),
								'oee_q', (oee_q), 
								'oee_p', (oee_p)
						)
					) 
				from
				(select 
					(select cd_shift from shifts where id_shift = s.id_shift) as cd_shift,
					(select cd_equipment from equipments where id_equipment = s.id_equipment) as cd_equipment,
					ts_value as ts,
					oee_a,
					oee_p,
					oee_q,
					oee
					from equipment_runtime_shift s
					where id_equipment = any( in_id_equipments::int[])
						-- here I use the piot_get_day_begin_by_site function to normalize by the production day
						and ts_value_production >=  date_trunc('day',in_begin_time::timestamp)::date
						and ts_value_production < date_trunc('day',least(in_end_time,now())::timestamp+ interval '1 day')::date
				) s1
				group by 1, 2, 3
				order by 3;
		end if;
	end if;
end
$$;


--
-- Name: h_piot_oee_progress_with_teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_progress_with_teams (
    id_enterprise integer,
    nm_entity character varying,
    oee_progress text[]
);


--
-- Name: h_piot_oee_progress_new(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_progress_new(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false, is_team_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_progress_with_teams
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
					when is_shift_filtered then sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then null::varchar --cd_team
					else null::varchar
				end cd_team,
				case
					when is_shift_filtered then null::int4 --team_sequence_position
					else null::int4
				end team_sequence_position
		    from site_runtime_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join sites ent on (ent.id_site = s.id_site)
		    where
		    	ent.id_site = any(ids_sites::int[])
		        and s.ts_value_production >= date_trunc('day', in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day', in_end_time::timestamp+ interval '1 day')::date 
		    group by ts_value, ent.id_enterprise, sft.cd_shift, ent.nm_site,sequence_position, ent.id_site, s.id_site, sft.sequence_position 
		)
	select
		id_enterprise, nm_entity,
			array_agg(jsonb_build_object(
				'ts_value_production', ts_value_production, 
				'oee_data', oee_data
			) order by ts_value_production) oee_progress
	from (
		select
			id_enterprise, nm_entity, ts_value_production, array_agg(oee_data order by sequence_position, team_sequence_position) oee_data
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production, sequence_position, team_sequence_position,
				jsonb_build_object(
						--'ts_value_production', ts_value_production,
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
		group by id_enterprise, nm_entity, ts_value_production
	)s2
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
					when is_shift_filtered then sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then null::varchar --cd_team
					else null::varchar
				end cd_team,
				case
					when is_shift_filtered then null::int4 --team_sequence_position
					else null::int4
				end team_sequence_position
		    from area_runtime_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join areas ent on (ent.id_area = s.id_area)
		    where
		    	ent.id_site = any(ids_sites::int[])
		    	and ent.id_area = any(ids_areas::int[])
		        and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date 
		    group by ts_value, ent.id_enterprise, sft.cd_shift, ent.nm_area,sequence_position, ent.id_site, s.id_area, sft.sequence_position
		)
		select
		id_enterprise, nm_entity,
			array_agg(jsonb_build_object(
				'ts_value_production', ts_value_production, 
				'oee_data', oee_data
			) order by ts_value_production) oee_progress
	from (
		select
			id_enterprise, nm_entity, ts_value_production, array_agg(oee_data order by sequence_position, team_sequence_position) oee_data
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production, sequence_position, team_sequence_position,
				jsonb_build_object(
						--'ts_value_production', ts_value_production,
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
		group by id_enterprise, nm_entity, ts_value_production
	)s2
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
					when is_shift_filtered then sequence_position
					else null::int4
				end sequence_position,
				case
					when is_team_filtered then null::varchar --cd_team
					else null::varchar
				end cd_team,
				case
					when is_shift_filtered then null::int4 --team_sequence_position
					else null::int4
				end team_sequence_position
		    from equipment_runtime_shift s
		    join shifts sft using (id_shift)
		    left join teams tms using (id_team)
		    join equipments ent on (ent.id_equipment = s.id_equipment and ent.tp_equipment=3)
		    where
		    	ent.id_site = any(ids_sites::int[])
		    	and ent.id_area = any(ids_areas::int[])
		    	and ent.id_equipment = any(ids_equips::int[])
		        and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
		        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date 
		    group by ts_value, ent.id_enterprise, sft.cd_shift, ent.nm_equipment,sequence_position, ent.id_site, s.id_equipment, sft.sequence_position
		)
		select
		id_enterprise, nm_entity,
			array_agg(jsonb_build_object(
				'ts_value_production', ts_value_production, 
				'oee_data', oee_data
			) order by ts_value_production) oee_progress
	from (
		select
			id_enterprise, nm_entity, ts_value_production, array_agg(oee_data order by sequence_position, team_sequence_position) oee_data
		from
		(
			select
				id_enterprise, nm_entity, ts_value_production, sequence_position, team_sequence_position,
				jsonb_build_object(
						--'ts_value_production', ts_value_production,
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
		group by id_enterprise, nm_entity, ts_value_production
	)s2
	group by id_enterprise, nm_entity;
	
	end if;
        
end
$$;


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
		    from site_runtime_shift s
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
		    from area_runtime_shift s
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
		    from equipment_runtime_shift s
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
						from site_runtime_1day where id_site = s1.id_site 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0) as oee_p
					from site_runtime_1day s
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
						from site_runtime_shift where id_site = s1.id_site 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0) as oee_p
					from site_runtime_shift s
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
						from area_runtime_1day where id_area = s1.id_area 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0) as oee_p
					from area_runtime_1day s
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
						from area_runtime_shift where id_area = s1.id_area 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0) as oee_p
					from area_runtime_shift s
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
						from equipment_runtime_1day where id_equipment = s1.id_equipment 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0) as oee_p
					from equipment_runtime_1day s
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
						from equipment_runtime_shift where id_equipment = s1.id_equipment 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce((sum(net)::float/nullif(sum(ideal_production),0))/nullif(((sum(net)::float/nullif(sum(gross),0)) * (sum(running_time)::float/nullif(sum(available_time),0))),0),0) as oee_p
					from equipment_runtime_shift s
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
						from site_runtime_1day where id_site = s1.id_site 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						/
					(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0))
					as oee_p
					from site_runtime_1day s
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
						from site_runtime_shift where id_site = s1.id_site 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						/
					(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0))
					as oee_p
					from site_runtime_shift s
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
						from area_runtime_1day where id_area = s1.id_area 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						/
					nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0)), 0)
					as oee_p
					from area_runtime_1day s
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
						from area_runtime_shift where id_area = s1.id_area 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						/
					nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0)), 0)
					as oee_p
					from area_runtime_shift s
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
						from equipment_runtime_1day where id_equipment = s1.id_equipment 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						/
					(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0))
					as oee_p
					from equipment_runtime_1day s
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
						from equipment_runtime_shift where id_equipment = s1.id_equipment 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						/
					(coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0))
					as oee_p
					from equipment_runtime_shift s
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
    shifts text[],
    childs text[]
);


--
-- Name: h_piot_oee_score_full(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_full(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_full_table
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
begin  	
	-- if navigation level is sites, query for site
	if false THEN--nav_level = 'SITE' THEN
		return query

	select distinct 
		parent_data.id_enterprise, parent_data.nav_name, parent_data.oee_componentes, parent_data.oee_info,
		sft.shifts,
		chds.childs
	from 
		public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,nav_level,false) parent_data
		join sites prt on (parent_data.id_enterprise=prt.id_enterprise and parent_data.nav_name = prt.nm_site)
		--Parent per shift
			join (
				select parent_id, case when is_shift_filtered then array_agg(shift) else null end as shifts
				from 
					(
						select 
							parent_id,
							jsonb_build_object(						
								--'nav_name', nav_name,
								'shift', shift,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info
							) as shift
						from 
							(
								select a1.* , a.id_site as parent_id
								from public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,nav_level,is_shift_filtered) a1
								join sites a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_site)
							) sub1
						group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info
					) s1
				group by parent_id
			) sft on parent_id = prt.id_site	
		--Childs		
			join (
			select parent_id, array_agg(child) childs
				from 
					(
						select 
							parent_id,
							nav_name,
							jsonb_build_object(						
								'nav_name', nav_name,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info,
								'shifts', sub1.childs
							) as child
						from 
							(
--								--OK
								select 
									a1.id_enterprise, a1.nav_name, a1.shift, a1.oee_timeline, a1.oee_componentes, a1.oee_info
									, cld_shift.parent_id, cld_shift.childs as childs
								from public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,child_nav_level,false) a1
								join areas a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
								join (
								select parent_id, case when is_shift_filtered then array_agg(child) else null end as childs, nav_name
									from 
										(
											select 
												parent_id,
												nav_name,
												jsonb_build_object(						
													'nav_name', nav_name,
													'shift', shift,
													'oee_componentes', oee_componentes,
													'oee_info', oee_info
												) as child
											from 
												(
													select a1.* , a.id_site as parent_id
													from public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,child_nav_level,is_shift_filtered) a1
													join areas a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
												) sub1
											group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info
										) s1
									group by parent_id, nav_name 
									) cld_shift on (cld_shift.nav_name = a.nm_area)	
								--OK								
							) sub1
						group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info, sub1.childs	
						) s1
				group by parent_id
				) chds on chds.parent_id = prt.id_site;
			
			
	else 
		return query
		
	select distinct 
		parent_data.id_enterprise, parent_data.nav_name, parent_data.oee_componentes, parent_data.oee_info
		,
		sft.shifts
		,chds.childs
	from 
		public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,nav_level,false) parent_data
		left join sites prt on (nav_level = 'SITE' and parent_data.id_enterprise=prt.id_enterprise and parent_data.nav_name = prt.nm_site)
		left join areas a on (nav_level = 'AREA' and parent_data.id_enterprise=a.id_enterprise and parent_data.nav_name = a.nm_area)
		left join equipments e on (nav_level = 'EQUIPMENT' and parent_data.id_enterprise=e.id_enterprise and parent_data.nav_name = e.nm_equipment)
		--Parent per shift
			join (
				select parent_id, case when is_shift_filtered then array_agg(shift) else null end as shifts
				from 
					(
						select 
							parent_id,
							jsonb_build_object(						
								--'nav_name', nav_name,
								'shift', shift,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info
							) as shift
						from 
							(
								select a1.* , 
								(
									case nav_level 
										when 'SITE' then prt.id_site
										when 'AREA' then a.id_area
										when 'EQUIPMENT' then e.id_equipment
									end
								) as parent_id
								from public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,nav_level,is_shift_filtered) a1
								left join sites prt on (nav_level = 'SITE' and a1.id_enterprise=prt.id_enterprise and a1.nav_name = prt.nm_site)
								left join areas a on (nav_level = 'AREA' and a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
								left join equipments e on (nav_level = 'EQUIPMENT' and a1.id_enterprise=e.id_enterprise and a1.nav_name = e.nm_equipment)
							) sub1
						group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info
					) s1
				group by parent_id
			) sft on 
				(case nav_level 
					when 'SITE' then parent_id = prt.id_site
					when 'AREA' then parent_id = a.id_area
					when 'EQUIPMENT' then parent_id = e.id_equipment
				end)	
		--Childs		
			left join (
			select parent_id, array_agg(child) childs
				from 
					(
					
--					3333333
						
					select 
							parent_id,
							nav_name,
							jsonb_build_object(						
								'nav_name', nav_name,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info,
								'shifts', childs 
							) as child
						from 
							(
		--OK
							
--							2222222222222
								select 
									a1.id_enterprise, a1.nav_name, a1.shift, a1.oee_timeline, a1.oee_componentes, a1.oee_info
									,
									cld_shift.parent_id, cld_shift.childs as childs--,
														--case :child_nav_level 
														--	--when 'SITE' then a.id_site
														--	when 'AREA' then a.id_site
														--	when 'EQUIPMENT' then e.id_area
														--end  as parent_id2
								from public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,child_nav_level,false) a1
--								join areas a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
								left join areas a on (nav_level = 'SITE' and a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
								left join equipments e on (nav_level = 'AREA' and a1.id_enterprise=e.id_enterprise and a1.nav_name = e.nm_equipment)
								left join (
								
--								111
								select parent_id, case when is_shift_filtered then array_agg(child) else null end as childs, nav_name
									from 
										(
											select 
												parent_id,
												nav_name,
												jsonb_build_object(						
													'nav_name', nav_name,
													'shift', shift,
													'oee_componentes', oee_componentes,
													'oee_info', oee_info
												) as child
											from 
												(
													select 
														a1.* ,
														case nav_level 
															when 'SITE' then s.id_site
															when 'AREA' then a.id_area
															when 'EQUIPMENT' then null
														end  as parent_id
													from public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,child_nav_level,is_shift_filtered) a1
													--join areas a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
													left join (select st.*, nm_area from sites st join areas using(id_site) ) s on (nav_level = 'SITE' and a1.id_enterprise=s.id_enterprise and a1.nav_name = s.nm_area)
--													left join areas a on (:nav_level = 'AREA' and a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
													left join (select st.*, nm_equipment from areas st join equipments using(id_area) ) a on (nav_level = 'AREA' and a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_equipment)
--													left join equipments e on (:nav_level = 'AREA' and a1.id_enterprise=e.id_enterprise and a1.nav_name = e.nm_equipment)
--													left join (select st.*, nm_area from sites st join areas using(id_site) ) s on (:nav_level = 'SITE' and a1.id_enterprise=s.id_enterprise and a1.nav_name = s.nm_area)
												) sub1
											group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info		
										) s1
									group by parent_id, nav_name 
									
									) cld_shift on --true
--									AQUIIIIIIIIIIIIIIIIIIIIIIII FALTA ARRUMAR ESSE ON DO JOIN
									(case nav_level 
										when 'SITE' then cld_shift.nav_name = a.nm_area
										when 'AREA' then cld_shift.nav_name = e.nm_equipment
										else TRUE
									end)
								--OK		
									
									
									
							) sub1
						group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info, sub1.childs
						
						) s1
				group by parent_id	
				) chds on (case nav_level 
								when 'SITE' then chds.parent_id = prt.id_site
								when 'AREA' then chds.parent_id = a.id_area
								when 'EQUIPMENT' then chds.parent_id = e.id_equipment
							end) ;
	end if;
end
$$;


--
-- Name: h_piot_oee_score_full_2(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_full_2(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_full_table
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
begin  	
	-- if navigation level is sites, query for site
	if false THEN--nav_level = 'SITE' THEN
		return query

	select distinct 
		parent_data.id_enterprise, parent_data.nav_name, parent_data.oee_componentes, parent_data.oee_info,
		sft.shifts,
		chds.childs
	from 
		public.h_piot_oee_score_single(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,nav_level,false) parent_data
		join sites prt on (parent_data.id_enterprise=prt.id_enterprise and parent_data.nav_name = prt.nm_site)
		--Parent per shift
			join (
				select parent_id, case when is_shift_filtered then array_agg(shift) else null end as shifts
				from 
					(
						select 
							parent_id,
							jsonb_build_object(						
								--'nav_name', nav_name,
								'shift', shift,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info
							) as shift
						from 
							(
								select a1.* , a.id_site as parent_id
								from public.h_piot_oee_score_single(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,nav_level,is_shift_filtered) a1
								join sites a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_site)
							) sub1
						group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info
					) s1
				group by parent_id
			) sft on parent_id = prt.id_site	
		--Childs		
			join (
			select parent_id, array_agg(child) childs
				from 
					(
						select 
							parent_id,
							nav_name,
							jsonb_build_object(						
								'nav_name', nav_name,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info,
								'shifts', sub1.childs
							) as child
						from 
							(
--								--OK
								select 
									a1.id_enterprise, a1.nav_name, a1.shift, a1.oee_timeline, a1.oee_componentes, a1.oee_info
									, cld_shift.parent_id, cld_shift.childs as childs
								from public.h_piot_oee_score_single(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,child_nav_level,false) a1
								join areas a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
								join (
								select parent_id, case when is_shift_filtered then array_agg(child) else null end as childs, nav_name
									from 
										(
											select 
												parent_id,
												nav_name,
												jsonb_build_object(						
													'nav_name', nav_name,
													'shift', shift,
													'oee_componentes', oee_componentes,
													'oee_info', oee_info
												) as child
											from 
												(
													select a1.* , a.id_site as parent_id
													from public.h_piot_oee_score_single(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,child_nav_level,is_shift_filtered) a1
													join areas a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
												) sub1
											group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info
										) s1
									group by parent_id, nav_name 
									) cld_shift on (cld_shift.nav_name = a.nm_area)	
								--OK								
							) sub1
						group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info, sub1.childs	
						) s1
				group by parent_id
				) chds on chds.parent_id = prt.id_site;
			
			
	else 
		return query
		
	select distinct 
		parent_data.id_enterprise, parent_data.nav_name, parent_data.oee_componentes, parent_data.oee_info
		,
		sft.shifts
		,chds.childs
	from 
		public.h_piot_oee_score_single(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,nav_level,false) parent_data
		left join sites prt on (nav_level = 'SITE' and parent_data.id_enterprise=prt.id_enterprise and parent_data.nav_name = prt.nm_site)
		left join areas a on (nav_level = 'AREA' and parent_data.id_enterprise=a.id_enterprise and parent_data.nav_name = a.nm_area)
		left join equipments e on (nav_level = 'EQUIPMENT' and parent_data.id_enterprise=e.id_enterprise and parent_data.nav_name = e.nm_equipment)
		--Parent per shift
			join (
				select parent_id, case when is_shift_filtered then array_agg(shift) else null end as shifts
				from 
					(
						select 
							parent_id,
							jsonb_build_object(						
								--'nav_name', nav_name,
								'shift', shift,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info
							) as shift
						from 
							(
								select a1.* , 
								(
									case nav_level 
										when 'SITE' then prt.id_site
										when 'AREA' then a.id_area
										when 'EQUIPMENT' then e.id_equipment
									end
								) as parent_id
								from public.h_piot_oee_score_single(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,nav_level,is_shift_filtered) a1
								left join sites prt on (nav_level = 'SITE' and a1.id_enterprise=prt.id_enterprise and a1.nav_name = prt.nm_site)
								left join areas a on (nav_level = 'AREA' and a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
								left join equipments e on (nav_level = 'EQUIPMENT' and a1.id_enterprise=e.id_enterprise and a1.nav_name = e.nm_equipment)
							) sub1
						group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info
					) s1
				group by parent_id
			) sft on 
				(case nav_level 
					when 'SITE' then parent_id = prt.id_site
					when 'AREA' then parent_id = a.id_area
					when 'EQUIPMENT' then parent_id = e.id_equipment
				end)	
		--Childs		
			left join (
			select parent_id, array_agg(child) childs
				from 
					(
					
--					3333333
						
					select 
							parent_id,
							nav_name,
							jsonb_build_object(						
								'nav_name', nav_name,
								'oee_componentes', oee_componentes,
								'oee_info', oee_info,
								'shifts', childs 
							) as child
						from 
							(
		--OK
							
--							2222222222222
								select 
									a1.id_enterprise, a1.nav_name, a1.shift, a1.oee_timeline, a1.oee_componentes, a1.oee_info
									,
									cld_shift.parent_id, cld_shift.childs as childs--,
														--case :child_nav_level 
														--	--when 'SITE' then a.id_site
														--	when 'AREA' then a.id_site
														--	when 'EQUIPMENT' then e.id_area
														--end  as parent_id2
								from public.h_piot_oee_score_single(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,child_nav_level,false) a1
--								join areas a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
								left join areas a on (nav_level = 'SITE' and a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
								left join equipments e on (nav_level = 'AREA' and a1.id_enterprise=e.id_enterprise and a1.nav_name = e.nm_equipment)
								left join (
								
--								111
								select parent_id, case when is_shift_filtered then array_agg(child) else null end as childs, nav_name
									from 
										(
											select 
												parent_id,
												nav_name,
												jsonb_build_object(						
													'nav_name', nav_name,
													'shift', shift,
													'oee_componentes', oee_componentes,
													'oee_info', oee_info
												) as child
											from 
												(
													select 
														a1.* ,
														case nav_level 
															when 'SITE' then s.id_site
															when 'AREA' then a.id_area
															when 'EQUIPMENT' then null
														end  as parent_id
													from public.h_piot_oee_score_fix1a(in_id_enterprise,in_id_equipments,in_id_areas,in_id_sites,in_ids_shifts,in_begin_time,in_end_time,time_grain,child_nav_level,is_shift_filtered) a1
													--join areas a on (a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
													left join (select st.*, nm_area from sites st join areas using(id_site) ) s on (nav_level = 'SITE' and a1.id_enterprise=s.id_enterprise and a1.nav_name = s.nm_area)
--													left join areas a on (:nav_level = 'AREA' and a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_area)
													left join (select st.*, nm_equipment from areas st join equipments using(id_area) ) a on (nav_level = 'AREA' and a1.id_enterprise=a.id_enterprise and a1.nav_name = a.nm_equipment)
--													left join equipments e on (:nav_level = 'AREA' and a1.id_enterprise=e.id_enterprise and a1.nav_name = e.nm_equipment)
--													left join (select st.*, nm_area from sites st join areas using(id_site) ) s on (:nav_level = 'SITE' and a1.id_enterprise=s.id_enterprise and a1.nav_name = s.nm_area)
												) sub1
											group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info		
										) s1
									group by parent_id, nav_name 
									
									) cld_shift on --true
--									AQUIIIIIIIIIIIIIIIIIIIIIIII FALTA ARRUMAR ESSE ON DO JOIN
									(case nav_level 
										when 'SITE' then cld_shift.nav_name = a.nm_area
										when 'AREA' then cld_shift.nav_name = e.nm_equipment
										else TRUE
									end)
								--OK		
									
									
									
							) sub1
						group by parent_id, nav_name, shift, oee_timeline, oee_componentes, oee_info, sub1.childs
						
						) s1
				group by parent_id	
				) chds on (case nav_level 
								when 'SITE' then chds.parent_id = prt.id_site
								when 'AREA' then chds.parent_id = a.id_area
								when 'EQUIPMENT' then chds.parent_id = e.id_equipment
							end) ;
	end if;
end
$$;


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
begin  	
		
	
	
	if nav_level = 'SITE' THEN
	return query
		
	--	//Rever a velocidade ideal
with basic_data as
    ( select ts_value, ent.id_enterprise, sft.cd_shift, ent.nm_area as nm_entity, s.id_area as id_entity, parent.nm_site as nm_parent, sequence_position, ent.id_site as id_parent, avg(net) net, avg(e.ideal_speed)ideal_speed, avg(scrap) scrap, avg(running_time)running_time, avg(ideal_production)ideal_production, avg(available_time)available_time, avg(gross)gross
     from area_runtime_shift s
     join shifts sft using (id_shift)
     join areas ent on (ent.id_area= s.id_area)
     join sites parent on (ent.id_site= parent.id_site)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_area
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_area)
          where e.id_site = any(in_id_sites::int[])
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_area, ts_value_production ) e on (e.id_area = s.id_area
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_site = any(in_id_sites::int[]) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
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
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
              ( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  order by sequence_position) as shifts
               from
                   ( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
                        ( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
                             ( select id_enterprise, id_parent, cd_shift, nm_entity, id_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
     from equipment_runtime_shift s
     join shifts sft using (id_shift)
     join equipments ent on (ent.id_equipment= s.id_equipment)
     join areas parent on (ent.id_area= parent.id_area)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_equipment
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_equipment)
          where e.id_equipment = any(in_id_equipments::int[])
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_equipment, ts_value_production ) e on (e.id_equipment = s.id_equipment
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_area = any(in_id_areas::int[]) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
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
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	(select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
              ( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  order by sequence_position) as shifts
               from
                   ( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
                        ( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
                             ( select id_enterprise, id_parent, cd_shift, nm_entity, id_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
     from equipment_runtime_shift s
     join shifts sft using (id_shift)
     join equipments parent on (parent.id_equipment= s.id_equipment)
     --join areas parent on (ent.id_site= parent.id_site)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_equipment
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_equipment)
          where e.id_equipment = any(in_id_equipments::int[])
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_equipment, ts_value_production ) e on (e.id_equipment = s.id_equipment
                                                          and e.ts_value_production = e.ts_value_production)
     where parent.id_equipment = any(in_id_equipments::int[]) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
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
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
-- Name: h_piot_oee_score_full_4(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_full_4(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_full_table
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
begin  	
		
	
	
	if nav_level = 'SITE' THEN
	return query
		
	--	//Rever a velocidade ideal
with basic_data as
    ( select ent.id_enterprise, sft.cd_shift, ent.nm_area as nm_entity, s.id_area as id_entity, parent.nm_site as nm_parent, sequence_position, ent.id_site as id_parent, net, ideal_speed, scrap, running_time, ideal_production, available_time, gross
     from area_runtime_shift s
     join shifts sft using (id_shift)
     join areas ent on (ent.id_area= s.id_area)
     join sites parent on (ent.id_site= parent.id_site)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_area
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_area)
          where e.id_site = any(in_id_sites::int[])
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_area, ts_value_production ) e on (e.id_area = s.id_area
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_site = any(in_id_sites::int[]) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
         and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
         and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date )
--Start of query
select id_enterprise,nav_name,oee_componentes,oee_info,shifts,childs from (
select id_enterprise,
	nm_entity::text as nav_name,
	id_parent,
    jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes,
    jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info,
    shifts
from
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
              ( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  order by sequence_position) as shifts
               from
                   ( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
                        ( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
                             ( select id_enterprise, id_parent, cd_shift, nm_entity, id_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
        
        
        
        
        else
        return query
        
		
	--	//Rever a velocidade ideal
with basic_data as
    ( select ent.id_enterprise, sft.cd_shift, ent.nm_equipment as nm_entity, s.id_equipment as id_entity, parent.nm_area as nm_parent, sequence_position, parent.id_area as id_parent, net, e.ideal_speed, scrap, running_time, ideal_production, available_time, gross
     from equipment_runtime_shift s
     join shifts sft using (id_shift)
     join equipments ent on (ent.id_equipment= s.id_equipment)
     join areas parent on (ent.id_site= parent.id_site)
     left join
         ( select ts_value_production, avg(coalesce(ideal_production_speed, e.production_speed)) as ideal_speed, e.id_equipment
          from ca_agg_equipment_values_1hour caevh
          join equipments e using (id_equipment)
          where e.id_equipment = any(in_id_equipments::int[])
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_equipment, ts_value_production ) e on (e.id_equipment = s.id_equipment
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_site = any(in_id_sites::int[]) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
        and ent.tp_equipment =3 
     	and s.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
        and s.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date )
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
( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
	from
    	( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
        	( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
            	( select id_enterprise, id_parent, cd_shift, nm_parent as nm_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
              ( select id_enterprise, nm_entity, id_parent, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(ideal_production),0) as ideal_production, coalesce(sum(running_time),0) as running_time, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  order by sequence_position) as shifts
               from
                   ( select id_enterprise, nm_entity, sequence_position, id_parent, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(gross), 0)gross, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object( 'nav_name', nm_entity, 'oee_componentes', oee_componentes, 'oee_info', oee_info, 'shift', cd_shift ) as child_shift from
                        ( select id_enterprise, nm_entity, cd_shift, sequence_position, id_parent, coalesce(sum(gross), 0) gross, coalesce(sum(net), 0) net, coalesce(avg(ideal_speed), 0) ideal_speed, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(scrap), 0)scrap, coalesce(sum(running_time), 0) running_time, coalesce(sum(available_time), 0)available_time, jsonb_build_object('oee_q', sum(oee_q), 'oee_a', sum(oee_a), 'oee_p', sum(oee_p), 'oee', sum(oee)) as oee_componentes, jsonb_build_object('running_time', coalesce(sum(running_time), 0), 'available_time', coalesce(sum(available_time), 0), 'total_prod', coalesce(sum(net), 0), 'scrap', coalesce(sum(scrap), 0), 'ideal_speed', coalesce(avg(ideal_speed), 0), 'avg_speed', coalesce(sum(oee_p) * avg(ideal_speed), 0) ) as oee_info from
                             ( select id_enterprise, id_parent, cd_shift, nm_entity, id_entity, sequence_position, coalesce(sum(net),0) as net, coalesce(sum(gross),0) as gross, coalesce(avg(ideal_speed), 0) as ideal_speed, coalesce(sum(scrap),0) as scrap, coalesce(sum(running_time),0) as running_time, coalesce(sum(ideal_production), 0) ideal_production, coalesce(sum(available_time),0) as available_time, coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q, coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee, coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
       end if;
        
        
end
$$;


--
-- Name: h_piot_oee_score_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_score_data (
    id_enterprise integer,
    nm_equipment text,
    oee double precision,
    oee_disponibilidade double precision,
    running_time numeric,
    operational_time numeric,
    oee_qualidade double precision,
    total_prod double precision,
    scrap double precision,
    oee_desempenho double precision,
    prod_possible double precision,
    oee_timeline text[]
);


--
-- Name: h_piot_oee_score_lines(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_lines(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, begin_time timestamp with time zone, end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_piot_oee_score_data
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
begin 
	-- the finest time grain is day
	return query 
	select 
		id_enterprise::int4,
		nm_equipment::text,
		sum(net_production)/nullif(sum(ideal_production), 0)::float8 as oee,
		-- OEE COMPONENTS
		-- OEE DISPONIBILIDADE
		(sum(running_time) )/nullif(sum(available_time)- sum(planned_downtime),0)::float8 as oee_disponibilidade,
		sum(running_time) as running_time,
		sum(available_time)- sum(planned_downtime) as operational_time,
		-- OEE QUALIDADE 
		(sum(net_production) ) /nullif(sum(gross_production), 0)::float8 oee_qualidade,
		sum(net_production)::float8 total_prod,
		(sum(gross_production)-sum(net_production))::float8 scrap,
		-- calculating oee_p from others componentes and final oee
		case 
			when ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
			/ nullif(	
						--- OEE_A
						( 
							(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
							* -- OEE_Q
							(sum(net_production)/nullif(sum(gross_production), 0) ) 
						)
					, 0) ) <= 1.0 
					and ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
						/ nullif(	
									--- OEE_A
									( 
										(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
										* -- OEE_Q
										(sum(net_production)/nullif(sum(gross_production), 0) ) 
									)
								, 0) ) >= 0.0				
				then ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
			/ nullif(	
						--- OEE_A
						( 
							(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
							* -- OEE_Q
							(sum(net_production)/nullif(sum(gross_production), 0) ) 
						)
					, 0) ) 
			when ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
			/ nullif(	
						--- OEE_A
						( 
							(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
							* -- OEE_Q
							(sum(net_production)/nullif(sum(gross_production), 0) ) 
						)
					, 0) ) > 1.0 then 1.0
			when ((sum(rts.net_production)/nullif(sum(rts.ideal_production), 0) ) 
			/ nullif(	
						--- OEE_A
						( 
							(sum(running_time)/nullif( sum(available_time)-sum(planned_downtime), 0) )
							* -- OEE_Q
							(sum(net_production)/nullif(sum(gross_production), 0) ) 
						)
					, 0) ) < 0.0 then 0.0
			else null
		end::float8 as oee_desempenho,
		sum(gross_production)::float8 as prod_possible,
		array_agg(round( ((net_production)::float/(ideal_production))::numeric, 3) order by ts_value asc) as oee_timeline
	from 
	(
		select 
				e.id_enterprise,
				ers.ts_value::date,
				e.nm_equipment,
				avg(net) as avg_production,
				sum(ers.net) net_production ,
				sum(ers.gross) gross_production ,
				sum(ers.ideal_production) ideal_production,
				sum(ers.changeover_time) as change_overs,
				sum(ers.duration) duration,
				sum(e.production_speed) production_speed,
				count(e.id_equipment) ids,
				sum(ers.available_time) as available_time,
				sum(ers.planned_downtime) planned_downtime,			
				sum(ers.running_time) running_time,
				coalesce(count(por.id_production_orders_runtime), 0) as ops_count
		from equipment_runtime_shift ers
		join equipments e on ers.id_equipment = e.id_equipment 
		join sites s on e.id_site = s.id_site 
		left join production_orders_runtime por 
			on por.id_equipment = ers.id_equipment 
			and ers.ts_range && por.runtime_timerange 
		where ers.ts_value >= begin_time::timestamptz and ers.ts_value < end_time::timestamptz
		and e.tp_equipment = 3
		and e.id_enterprise = in_id_enterprise
		and e.id_site = any( ids_sites )
		and e.id_area = any ( ids_areas )
		and ers.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
		group by 
			e.id_enterprise,
			ers.ts_value::date,
			e.nm_equipment
	) rts
	group by rts.id_enterprise, nm_equipment;
end
$$;


--
-- Name: h_piot_oee_score_new(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_new(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_data_test1
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
						from site_runtime_1day where id_site = s1.id_site 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee_p,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						*
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0)
					as oee
					from site_runtime_1day s
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
						from site_runtime_shift where id_site = s1.id_site 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee_p,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						*
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0)
					as oee
					from site_runtime_shift s
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
						from area_runtime_1day where id_area = s1.id_area 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee_p,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						*
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0)
					as oee
					from area_runtime_1day s
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
						from area_runtime_shift where id_area = s1.id_area 
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
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee_p,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						*
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0)
					as oee_p
					from area_runtime_shift s
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
					cd_equipment::text as nav_name,
					null::text as shift,
					(select array_agg(oee::float8 order by ts_value)
						from equipment_runtime_1day where id_equipment = s1.id_equipment 
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
					(select cd_equipment from equipments where id_equipment = s.id_equipment) as cd_equipment,
					s.id_equipment,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee_p,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						*
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0)
					as oee
					from equipment_runtime_1day s
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
					cd_equipment::text as nav_name,
					cd_shift::text as shift,
					(select array_agg(oee::float8 order by ts_value_production)
						from equipment_runtime_shift where id_equipment = s1.id_equipment 
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
					(select cd_equipment from equipments where id_equipment = s.id_equipment) as cd_equipment,
					id_equipment,
					coalesce(sum(net),0) as total_prod,
					coalesce(sum(scrap),0) as scrap,
					coalesce(sum(running_time),0) as running_time,
					coalesce(sum(ideal_production),0) as prod_possible,
					coalesce(sum(available_time),0) as available_time,
					coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee_p,
					coalesce(sum(net)::float/nullif(sum(ideal_production),0),0)
						*
					coalesce(sum(running_time)::float/nullif(sum(available_time),0),0)
						*
					coalesce(sum(net)::float/nullif(sum(gross),0),0)
					as oee
					from equipment_runtime_shift s
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
-- Name: h_piot_oee_score_teams_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_oee_score_teams_table (
    id_enterprise integer,
    nav_name text,
    oee_componentes jsonb,
    oee_info jsonb,
    shifts text[],
    teams text[],
    childs text[]
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
			equipment_runtime_shift s
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
				coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
				coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p,
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
							coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
							coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
				coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
				coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p,
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
							coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
							coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
						coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
						coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
						coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
						coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
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
									coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
									coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
									coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
									coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
-- Name: h_piot_oee_score_with_teams_2(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_with_teams_2(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_teams_table
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
		sft.cd_shift,
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
		sft.sequence_position,
		case nav_level
			when 'EQUIPMENT' then _equipments.id_equipment
			when 'AREA' then _areas.id_area
			when 'SITE' then _sites.id_site
		end as id_parent,
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
		equipment_runtime_shift s
		join shifts sft using (id_shift)
		left join teams tms using (id_team)
		join equipments _equipments on (_equipments.id_equipment= s.id_equipment)
		join areas _areas on (_equipments.id_area = _areas.id_area)
		join sites _sites on (_equipments.id_site = _sites.id_site)
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
		ts_value,
		_equipments.id_enterprise,
		sft.cd_shift,
		case nav_level
			when 'EQUIPMENT' then _equipments.nm_equipment
			when 'AREA' then _areas.nm_area
			when 'SITE' then _sites.nm_site
		end,
		sft.sequence_position,
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
				coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
				coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p,
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
							coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
							coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
				coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
				coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p,
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
							coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
							coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
						coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
						coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
						coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
						coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
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
									coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
									coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
									coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
									coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
-- Name: h_piot_oee_score_with_teams_3(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_oee_score_with_teams_3(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_ids_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false) RETURNS SETOF public.h_piot_oee_score_teams_table
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
			equipment_runtime_shift s
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
				coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
				coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p,
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
							coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
							coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
				coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
				coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
				coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p,
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
							coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
							coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
							coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
						coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
						coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
						coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
						coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p, array_agg(child_shift order by sequence_position) as shifts
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
									coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
									coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
									coalesce(sum(net)::float/nullif(sum(gross),0),0) as oee_q,
									coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) as oee_a,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) as oee,
									coalesce(sum(net)::float/nullif(sum(ideal_production),0),0) / nullif((coalesce(sum(running_time)::float/nullif(sum(available_time),0),0) * coalesce(sum(net)::float/nullif(sum(gross),0),0)),0) as oee_p
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
-- Name: h_overview_i_events_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_overview_i_events_2 (
    id_enterprise integer,
    start text,
    "end" text,
    duration character varying,
    reason character varying,
    sub_category character varying,
    cd_sector character varying,
    machine character varying,
    notes character varying,
    colorcolumn text
);


--
-- Name: h_piot_overview_i_get_events_2(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_overview_i_get_events_2(idequipment integer) RETURNS SETOF public.h_overview_i_events_2
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
left join equipments pe on (e.id_parentequipment=pe.id_equipment)
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
-- Name: h_overview_i_shift_production; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_overview_i_shift_production (
    id_enterprise integer,
    id_equipment integer,
    cd_equipment character varying,
    current_shift_production double precision,
    current_shift_scrap double precision,
    current_shift_scrap_percentage double precision
);


--
-- Name: h_piot_overview_i_shift_production(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_overview_i_shift_production(idequipment integer) RETURNS SETOF public.h_overview_i_shift_production
    LANGUAGE sql STABLE
    AS $$
select 
    ev.id_enterprise,
    ev.id_equipment,
    e.cd_equipment,
    coalesce(
             sum(net_production_incr)
                 filter (where ev.ts_value <@ ers.ts_range),
             0
             ) as "current_shift_production",
    coalesce(
             sum(scrap_incr)
                 filter (where ev.ts_value <@ ers.ts_range),
             0
             ) as "current_shift_scrap",
    coalesce(
             (sum(scrap_incr)
                 filter (where ev.ts_value <@ ers.ts_range))::float / 
              nullif(sum(net_production_incr)
                 filter (where ev.ts_value <@ ers.ts_range), 0)::float
                 ,
             0
             ) as "current_shift_scrap_percentage"
from v_agg_equipment_values_1hour_full ev
join equipment_runtime_shift ers on ev.id_equipment = ers.id_equipment and now() <@ ers.ts_range and ev.id_shift_hour = ers.id_shift_hour
join equipments e on e.id_equipment = ev.id_equipment 
where ev.tp_equipment=3
and ev.id_equipment = idequipment
group by ev.id_enterprise, ev.id_equipment, e.cd_equipment;
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
from equipment_runtime_1hour vaevh
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
from equipment_runtime_1hour vaevh
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
    production_flow text[]
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
	min_ts_prod timestamptz := (select min(ts_value) from equipment_runtime_shift ev
									where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production <= date_trunc(time_grain::text, (in_end_time::timestamptz + ('1'||time_grain::text)::interval)::timestamptz) )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ) 
								);
	max_ts_prod timestamptz := (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_runtime_shift ev
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
						equipment_runtime_shift ers
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
-- Name: h_piot_production_orders_merged_new_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_orders_merged_new_table (
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
    id_equipment integer
);


--
-- Name: h_piot_production_orders_merged_new_function(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_orders_merged_new_function(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_production_orders_merged_new_table
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
--CREATE TABLE public.h_piot_production_orders_merged_new_table
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
    po.id_equipment
   FROM production_orders po
     LEFT JOIN clients c USING (id_client)
     LEFT JOIN products p USING (id_product)
     LEFT JOIN equipments e USING (id_equipment)
  WHERE po.status <> 1
 	and e.id_site = ANY(ids_sites)
 	and e.id_area = ANY(ids_areas)
 	and id_equipment = ANY(ids_equips)
-- 	and ids_shifts = ANY(ids_shifts)
 	and ts_start >= _tsstart and ts_start < _tsend;
 return;
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
-- Name: h_piot_production_orders_with_runtimes2(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_orders_with_runtimes2(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_production_orders_with_runtimes_table2
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
-- Name: h_piot_production_orders_with_runtimes3(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_orders_with_runtimes3(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_production_orders_with_runtimes_table2
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
  WHERE --po.status <> 1
 	--and
 	 e.id_site = ANY(ids_sites)
 	and e.id_area = ANY(ids_areas)
 	and id_equipment = ANY(ids_equips)
 	and (ts_start >= _tsstart and ts_start < _tsend or po.status = 1);
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
-- Name: h_piot_production_orders_with_runtimes_table_5; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_orders_with_runtimes_table_5 (
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
    production_programmed bigint,
    ts_end timestamp with time zone,
    id_equipment integer,
    runtimes json
);


--
-- Name: h_piot_production_orders_with_runtimes5(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_orders_with_runtimes5(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_production_orders_with_runtimes_table_5
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
	po.production_programmed,
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
-- Name: h_piot_production_orders_with_runtimes_table6; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_production_orders_with_runtimes_table6 (
    id_enterprise integer,
    status integer,
    id_production_order bigint,
    id_order integer,
    nm_client character varying,
    nm_product character varying,
    txt_product character varying,
    production_ordered bigint,
    production_programmed bigint,
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
-- Name: h_piot_production_orders_with_runtimes6(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_production_orders_with_runtimes6(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text) RETURNS SETOF public.h_piot_production_orders_with_runtimes_table6
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
	po.production_programmed,
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
    array_agg text[]
);


--
-- Name: h_piot_single_period_equipment_chart_3(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_single_period_equipment_chart_3(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_single_period_equipment_chart_table_3
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_shifts::int[]) = 0 then true
						 		else id_shift = any( in_id_shifts::int[])
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
									else (select min(ts_value) from equipment_runtime_shift ev
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
										(select case when max(ts_value)>now() then now() else max(ts_value) end from ca_agg_equipment_values_1hour ev
										where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
										and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
										and ev.id_enterprise = in_id_enterprise
										and ev.id_area = any( ids_areas)
										and ev.id_site = any( ids_sites )
										and ev.id_equipment = any( ids_equips )
										and ev.id_shift = any( ids_shifts ))
								else (select max(ts_value) from equipment_runtime_shift ev
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
		array_agg(obj order by sequence_position )
		from (
			select 
				ts_value::timestamptz,
				ers.id_enterprise,
				s.sequence_position ,
				sum(coalesce(net_production_incr, 0)) net, sum(coalesce(gross_production_incr, 0)) gross, sum(coalesce(scrap_incr, 0)) scrap, avg(coalesce(pt.vl_hour, 0)) target,
				jsonb_build_object(							
					'id_shift', id_shift,
					'cd_shift', s.cd_shift,
					'cd_team', t.cd_team,
					'id_team', t.id_team,
					'net', sum(coalesce(net_production_incr, 0)),
					'gross', sum(coalesce(gross_production_incr, 0)),
					'scrap', sum(coalesce(scrap_incr, 0)),
					'target', avg(coalesce(pt.vl_hour, 0))
				) obj
			from 
				ca_agg_equipment_values_1hour ers
				join production_targets pt using (id_equipment)
				left join shifts s using (id_shift)
				left join teams t using (id_team)
			where
				ts_value >= min_ts_prod
				and ts_value <= max_ts_prod
				and ers.id_enterprise = in_id_enterprise
				and ers.id_area = any( ids_areas)
				and ers.id_site = any( ids_sites )
				and ers.id_equipment =  any( ids_equips )
				and ers.id_shift = any( ids_shifts )
			group by ers.id_enterprise, id_shift, ts_value, s.cd_shift, s.sequence_position, t.id_team, t.cd_team
			) aa 
		group by ts_value, id_enterprise order by ts_value;

ELSE return QUERY 


select
	case when date_trunc(time_grain, now()) = date_trunc(time_grain, ts_value_production) then now() else ts_value_production end ts_value_production,
	id_enterprise,
	sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
	array_agg(obj order by sequence_position)
from (
	select 
		date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
		e.id_enterprise,
		s.sequence_position,
		sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target,
		jsonb_build_object(							
			'id_shift', ers.id_shift,
			'cd_shift', ers.cd_shift,
			'cd_team', t.cd_team,
			'id_team', t.id_team,
			'net', sum(coalesce(net, 0)),
			'gross', sum(coalesce(gross, 0)),
			'scrap', sum(coalesce(scrap, 0)),
			'target', sum(coalesce(target, 0))
		) obj
	from 
		equipment_runtime_shift ers
		join equipments e using (id_equipment) 
		join shifts s using (id_shift)
		left join teams t using (id_team)
	where
--				ts_value >= '2022-03-01' and id_equipment in (1)
--				and ts_value < '2022-04-30'
					ts_value >= min_ts_prod
		and ts_value <= max_ts_prod
		and e.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and e.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
	group by e.id_enterprise, ers.id_shift, date_trunc(time_grain, ts_value_production), ers.cd_shift, s.sequence_position, t.id_team, t.cd_team
	) aa 
group by ts_value_production, id_enterprise order by ts_value_production;


--select
--	case when date_trunc(time_grain, now()) = date_trunc(time_grain, ts_value_production) then now() else ts_value_production end ts_value_production,
--	id_enterprise,
--	sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
--	array_agg(obj order by sequence_position)
--from (
--	select 
--		date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
--		e.id_enterprise,
--		s.sequence_position,
--		sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target,
--		jsonb_build_object(							
--			'id_shift', ers.id_shift,
--			'cd_shift', ers.cd_shift,
--			'cd_team', t.cd_team,
--			'id_team', t.id_team,
--			'net', sum(coalesce(net, 0)),
--			'gross', sum(coalesce(gross, 0)),
--			'scrap', sum(coalesce(scrap, 0)),
--			'target', sum(coalesce(target, 0))
--		) obj
--	from 
--		equipment_runtime_shift ers
--		join equipments e using (id_equipment) 
--		join shifts s using (id_shift)
--		left join teams t using (id_team)
--	where
--		ts_value >= min_ts_prod
--		and ts_value < max_ts_prod
--		and e.id_enterprise = in_id_enterprise
----		and e.id_area = any( ids_areas)
----		and e.id_site = any( ids_sites )
----		and e.id_equipment = any( ids_equips )
----		and ers.id_shift = any( ids_shifts )
--	group by e.id_enterprise, ers.id_shift, date_trunc(time_grain, ts_value_production), ers.cd_shift, s.sequence_position, t.cd_team, t.id_team
--	) aa 
--group by ts_value_production, id_enterprise order by ts_value_production;
		
END IF;

end
$$;


--
-- Name: h_piot_single_period_with_teams(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_single_period_with_teams(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_single_period_equipment_chart_table_3
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_shifts::int[]) = 0 then true
						 		else id_shift = any( in_id_shifts::int[])
						 	 end);
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
									else (select min(ts_value) from equipment_runtime_shift ev
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
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
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
		array_agg(obj order by sequence_position )
		from (
			select 
				ts_value::timestamptz,
				ers.id_enterprise,
				s.sequence_position ,
				sum(coalesce(net_production_incr, 0)) net, sum(coalesce(gross_production_incr, 0)) gross, sum(coalesce(scrap_incr, 0)) scrap, avg(coalesce(pt.vl_hour, 0)) target,
				jsonb_build_object(							
					'id_shift', id_shift,
					'cd_shift', s.cd_shift,
					'cd_team', t.cd_team,
					'id_team', t.id_team,
					'net', sum(coalesce(net_production_incr, 0)),
					'gross', sum(coalesce(gross_production_incr, 0)),
					'scrap', sum(coalesce(scrap_incr, 0)),
					'target', avg(coalesce(pt.vl_hour, 0))
				) obj
			from 
				ca_agg_equipment_values_1hour ers
				join production_targets pt using (id_equipment)
				left join shifts s using (id_shift)
				left join teams t using (id_team)
			where
				ts_value >= min_ts_prod
				and ts_value <= max_ts_prod
				and ers.id_enterprise = in_id_enterprise
				and ers.id_area = any( ids_areas)
				and ers.id_site = any( ids_sites )
				and ers.id_equipment =  any( ids_equips )
				and ers.id_shift = any( ids_shifts )
			group by ers.id_enterprise, id_shift, ts_value, s.cd_shift, s.sequence_position, t.id_team, t.cd_team
			) aa 
		group by ts_value, id_enterprise order by ts_value;

ELSE return QUERY 


select
	case when date_trunc(time_grain, now()) = date_trunc(time_grain, ts_value_production) then now() else ts_value_production end ts_value_production,
	id_enterprise,
	sum(coalesce(net, 0))::float8 net, sum(coalesce(gross, 0))::float8 gross, sum(coalesce(scrap, 0))::float8 scrap, sum(coalesce(target, 0))::int8 target,
	array_agg(obj order by sequence_position)
from (
	select 
		date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
		e.id_enterprise,
		s.sequence_position,
		sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target,
		jsonb_build_object(							
			'id_shift', ers.id_shift,
			'cd_shift', ers.cd_shift,
			'cd_team', t.cd_team,
			'id_team', t.id_team,
			'net', sum(coalesce(net, 0)),
			'gross', sum(coalesce(gross, 0)),
			'scrap', sum(coalesce(scrap, 0)),
			'target', sum(coalesce(target, 0))
		) obj
	from 
		equipment_runtime_shift ers
		join equipments e using (id_equipment) 
		join shifts s using (id_shift)
		left join teams t using (id_team)
	where
		ts_value >= min_ts_prod
		and ts_value <= max_ts_prod
		and e.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and e.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
		and (ers.id_team is null or ers.id_team = any(ids_teams) ) 
	group by e.id_enterprise, ers.id_shift, date_trunc(time_grain, ts_value_production), ers.cd_shift, s.sequence_position, t.id_team, t.cd_team
	) aa 
group by ts_value_production, id_enterprise order by ts_value_production;
		
END IF;

end
$$;


--
-- Name: h_piot_single_period_with_teams_2(integer, text, text, text, text, text, timestamp with time zone, timestamp with time zone, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_single_period_with_teams_2(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, group_by_element text DEFAULT 'GENERAL'::text) RETURNS SETOF public.h_single_period_equipment_chart_table_3
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_shifts::int[]) = 0 then true
						 		else id_shift = any( in_id_shifts::int[])
						 	 end);
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
									else (select min(ts_value) from equipment_runtime_shift ev
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
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_runtime_shift ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
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
		array_agg(obj order by shift_or_team_position )
		from (
			select 
				ts_value::timestamptz,
				ers.id_enterprise,
				case group_by_element when 'SHIFTS' then s.sequence_position end as shift_or_team_position,
				sum(coalesce(net_production_incr, 0)) net, sum(coalesce(gross_production_incr, 0)) gross, sum(coalesce(scrap_incr, 0)) scrap, avg(coalesce(pt.vl_hour, 0)) target,
				jsonb_build_object(							
					'id_shift', case group_by_element when 'SHIFTS' then id_shift END,
					'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift END,
					'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
					'id_team', case group_by_element when 'TEAMS' then t.id_team END,
					'net', sum(coalesce(net_production_incr, 0)),
					'gross', sum(coalesce(gross_production_incr, 0)),
					'scrap', sum(coalesce(scrap_incr, 0)),
					'target', avg(coalesce(pt.vl_hour, 0))
				) obj
			from 
				ca_agg_equipment_values_1hour ers
				join production_targets pt using (id_equipment)
				left join shifts s using (id_shift)
				left join teams t using (id_team)
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
	array_agg(obj order by shift_or_team_position)
from (
	select 
		date_trunc(time_grain, ts_value_production)::timestamptz as ts_value_production,
		e.id_enterprise,
		case when group_by_element = 'SHIFTS' then s.sequence_position when group_by_element = 'TEAMS' then t.sequence_position end as shift_or_team_position,
		sum(coalesce(net, 0)) net, sum(coalesce(gross, 0)) gross, sum(coalesce(scrap, 0)) scrap, sum(coalesce(target, 0))::int8 target,
		jsonb_build_object(							
			'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift END,
			'cd_shift', case group_by_element when 'SHIFTS' then ers.cd_shift END,
			'cd_team', case group_by_element when 'TEAMS' then t.cd_team END,
			'id_team', case group_by_element when 'TEAMS' then t.id_team END,
			'net', sum(coalesce(net, 0)),
			'gross', sum(coalesce(gross, 0)),
			'scrap', sum(coalesce(scrap, 0)),
			'target', sum(coalesce(target, 0))
		) obj
	from 
		equipment_runtime_shift ers
		join equipments e using (id_equipment) 
		join shifts s using (id_shift)
		left join teams t using (id_team)
	where
		ts_value >= min_ts_prod
		and ts_value <= max_ts_prod
		and e.id_enterprise = in_id_enterprise
		and e.id_area = any( ids_areas)
		and e.id_site = any( ids_sites )
		and e.id_equipment = any( ids_equips )
		and ers.id_shift = any( ids_shifts )
		and (ers.id_team is null or ers.id_team = any(ids_teams) ) 
--	group by e.id_enterprise, case group_by_element when 'SHIFTS' then ers.id_shift else null END, date_trunc(time_grain, ts_value_production), case group_by_element when 'SHIFTS' then ers.cd_shift else null END, case group_by_element when 'SHIFTS' then s.sequence_position else null END, case group_by_element when 'TEAMS' then t.id_team else null END, case group_by_element when 'TEAMS' then t.cd_team END
	group by e.id_enterprise, date_trunc(time_grain, ts_value_production),
		case group_by_element when 'SHIFTS' then ers.id_shift else null END,
		case group_by_element when 'SHIFTS' then ers.cd_shift else null END,
		case group_by_element when 'SHIFTS' then s.sequence_position else null END,
		case group_by_element when 'TEAMS' then t.id_team else null END,
		case group_by_element when 'TEAMS' then t.cd_team else null end
		,case group_by_element when 'TEAMS' then t.sequence_position else null END
		) aa 
group by ts_value_production, id_enterprise order by ts_value_production;
		
END IF;

end
$$;


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
									else (select min(ts_value) from equipment_runtime_shift ev
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
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_runtime_shift ev
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
		equipment_runtime_shift ers
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
    array_agg text[]
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
									else (select min(ts_value) from equipment_runtime_shift ev
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
								else (select case when max(ts_value)>now() then now() else max(ts_value) end from equipment_runtime_shift ev
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
			equipment_runtime_shift ers
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
-- Name: h_total_production_chart_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_total_production_chart_data (
    ts timestamp without time zone,
    net_production_incr bigint,
    net_production_acc bigint,
    gross_production_acc bigint,
    scrap bigint,
    scrap_acc bigint,
    trendline1 bigint,
    target bigint,
    togoal double precision,
    id_enterprise integer,
    shift_net_prod json
);


--
-- Name: h_piot_total_production_area_chart_day(integer, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_area_chart_day(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_shifts text, begin_time timestamp with time zone, end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_data
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := in_ids_sites::int[];
	ids_areas int[] := in_ids_areas::int[];
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
begin
	if time_grain = 'HOUR'
		then return query
		with production_info as 
		(
				select 
					id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max( id_area) as id_area,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
				from 
				(
					select 
						vaevdf.id_enterprise,
						id_shift,
						array_agg( vaevdf.id_site) id_site,
						array_agg( vaevdf.id_area) as id_area,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
					from
						v_agg_area_values_1hour_full vaevdf
					where
						vaevdf.ts_value_production >= date_trunc('DAY'::text, begin_time::timestamptz) 
						and vaevdf.ts_value_production < date_trunc('DAY'::text, end_time::timestamptz)
						and vaevdf.id_enterprise = in_id_enterprise
						and vaevdf.id_area = any( ids_areas)
						and vaevdf.id_site = any( ids_sites )
						and vaevdf.id_shift = any( ids_shifts )
					GROUP by 
							vaevdf.ts_value,
							vaevdf.id_enterprise,
							vaevdf.id_shift 
				) d0
				group by 
					ts_value, id_enterprise
		)
		select 
			t.ts::timestamp, 
			pi.net_production_incr::bigint,
			(sum(gross_production_incr) over ( partition by pi.part_end order by t.ts asc))::bigint as gross_production_acc,
			(sum(net_production_incr) over (partition by pi.part_end order by t.ts asc))::bigint as net_production_acc,
			(pi.scrap_incr)::bigint scrap,
			(sum(pi.scrap_incr) over ( partition by pi.part_end order by t.ts asc))::bigint as scrap_acc,
			(greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) ))::bigint trendline1,
			(sum(t.targets) over (order by t.ts))::bigint as target,
			(case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then (coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 ))::float8
			end) as toGoal, t.id_enterprise,
			case 
				when ts < max_ts 
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		( 
			select 
					ts.*,
					regr_params.*,
					tgs.*
			from generate_series(date_trunc('DAY'::text, begin_time::timestamptz)::timestamp without time zone - interval '1day',
								   (date_trunc('day', end_time::timestamptz+interval '1 day')-interval '1 hour')::timestamp without time zone,
								   '01:00:00'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_area) as areas_ids, max(id_enterprise) as id_enterprise
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_day)/24 )::bigint
						else sum(ptd.target)/24
					end as targets
				from production_targets pt2 
				left join production_targets_day ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_area = any(areas_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, min_ts, max_ts, intercep1, slop1, areas_ids, tgs.targets, id_enterprise
		) t
		left join production_info pi on pi.ts_value = t.ts
		order by ts asc;
	elsif (time_grain = 'DAY')
		then return query 
			-- USING A DAY GRAIN
		with production_info as 
		(
				select
					id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max( id_area) as id_area,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
				from 
				(
					select 
						vaevdf.id_enterprise,
						id_shift,						
						array_agg( vaevdf.id_site) id_site,
						array_agg( vaevdf.id_area) as id_area,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
					from
						v_agg_area_values_1day_full vaevdf
					where
						vaevdf.ts_value >= date_trunc('DAY'::text, begin_time::timestamptz) 
						and vaevdf.ts_value < date_trunc('DAY'::text, end_time::timestamptz)
						and vaevdf.id_enterprise = in_id_enterprise
						and vaevdf.id_area = any( ids_areas)
						and vaevdf.id_site = any( ids_sites )
						and vaevdf.id_shift = any( ids_shifts ) 
					GROUP by 
							vaevdf.ts_value,
							vaevdf.id_enterprise,
							id_shift
				) d0
				group by 
					ts_value, id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by pi.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal, t.id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*
			from generate_series(date_trunc('DAY'::text, begin_time::timestamptz)::timestamp without time zone - interval '1day',
		 					  (date_trunc('day', end_time::timestamptz+interval '1 day')-interval '1 hour')::timestamp without time zone,
		 					  '1day'::interval) ts(ts) 
		cross join
		(
			select 
				regr_intercept(net_production_acc,rn) intercep1,
				regr_slope(net_production_acc, rn) slop1,
				min(d0.ts_value) as min_ts,
				max(d0.ts_value) as max_ts,
				max(id_area) as areas_ids , max(id_enterprise) as id_enterprise
			from production_info d0
		) regr_params
		join lateral 
		(
			-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_day) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_day ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_area = any(areas_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					areas_ids,
					tgs.targets, id_enterprise
		) t
		left join production_info pi on pi.ts_value = t.ts
		order by ts asc;
	elsif (time_grain = 'WEEK')
		then return query
		-- USING WEEK GRAIN
		with production_info as 
		(
				select
					id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max( id_area) as id_area,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
				from 
				(
					select 
						vaevdf.id_enterprise,
						id_shift,
						array_agg( vaevdf.id_site) id_site,
						array_agg( vaevdf.id_area) as id_area,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
					from
						v_agg_area_values_1week_full vaevdf
					where
						vaevdf.ts_value >= date_trunc('week'::text, begin_time::timestamptz) 
						and vaevdf.ts_value < date_trunc('week'::text, end_time::timestamptz)
						and vaevdf.id_enterprise = in_id_enterprise
						and vaevdf.id_area = any( ids_areas)
						and vaevdf.id_site = any( ids_sites )
						and vaevdf.id_shift = any( ids_shifts ) 
					GROUP by 
							vaevdf.ts_value,
							vaevdf.id_enterprise,
							vaevdf.id_shift
				) d0
				group by 
					ts_value, id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by pi.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal, t.id_enterprise,
			case 
				when ts < max_ts
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*
			from generate_series(date_trunc('week'::text, begin_time::timestamptz)::timestamp without time zone,
								   (date_trunc('week', end_time::timestamptz))::timestamp without time zone,
								   '1week'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_area) as areas_ids, max(id_enterprise) as id_enterprise
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_week) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_week ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_area = any(areas_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					areas_ids,
					tgs.targets, id_enterprise
		) t
		left join production_info pi on pi.ts_value::date = t.ts::date
		order by ts asc;
	else
		return query 
		-- USING MONTH GRAIN
		with production_info as 
		(
			select
				id_enterprise,
				ts_value, 
				1 as part_end,
				row_number() over (order by ts_value) as rn, 
				max( id_area) as id_area,
				sum(net_production_incr) net_production_incr,
				sum(gross_production_incr) gross_production_incr,
				sum(scrap_incr) scrap_incr,
				json_object(
							array_agg(id_shift::text order by id_shift),
							array_agg(net_production_sh_acc::text order by id_shift)
							) as shift_net_prod,
				sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
				sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
				from 
				(
					select 
						vaevdf.id_enterprise,
						vaevdf.id_shift,
						array_agg( vaevdf.id_site) id_site,
						array_agg( vaevdf.id_area) as id_area,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
					from
						v_agg_area_values_1month_full vaevdf
					where
						vaevdf.ts_value >= date_trunc('month'::text, begin_time::timestamptz) 
						and vaevdf.ts_value < date_trunc('month'::text, end_time::timestamptz)
						and vaevdf.id_enterprise = in_id_enterprise
						and vaevdf.id_area = any( ids_areas)
						and vaevdf.id_site = any( ids_sites )
						and vaevdf.id_shift = any( ids_shifts ) 
					GROUP by 
							vaevdf.ts_value,
							vaevdf.id_enterprise,id_shift
							
				) d0
				group by 
					ts_value,  id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by pi.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal, t.id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*
			from generate_series(date_trunc('month'::text, begin_time::timestamptz)::timestamp without time zone,
								   (date_trunc('month', end_time::timestamptz))::timestamp without time zone,
								   '1month'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_area) as areas_ids , max(id_enterprise) as id_enterprise
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_month) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_month ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_area = any(areas_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					areas_ids,
					tgs.targets, id_enterprise
		) t
		left join production_info pi on pi.ts_value::date = t.ts::date
		order by ts asc;
		
	end if;

--return;
end
$$;


--
-- Name: h_piot_total_production_equipment_chart_day(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_equipment_chart_day(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, begin_time timestamp with time zone, end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_data
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := in_ids_sites::int[];
	ids_areas int[] := in_ids_areas::int[];
	ids_equips int[] := in_ids_equipments::int[];
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
begin
	if time_grain = 'HOUR'
		then return query
		-- HOUR GRAIN
with production_info as 
		(
				select 
					id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max( id_equipment) as id_equipment,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
				from 
				(
					select 
						vaevdf.id_enterprise,
						id_shift,
						array_agg( vaevdf.id_site) id_site,
						array_agg( vaevdf.id_area) as id_area,
						array_agg( id_equipment) as id_equipment,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
					from
						v_agg_equipment_values_1hour_full vaevdf
					where
						vaevdf.ts_value_production >= date_trunc('DAY'::text, begin_time::timestamptz) 
						and vaevdf.ts_value_production < date_trunc('DAY'::text, end_time::timestamptz)
						AND vaevdf.tp_equipment = 3
						and vaevdf.id_enterprise =in_id_enterprise
						and vaevdf.id_area = any(ids_areas)
						and vaevdf.id_site = any(ids_sites )
						and vaevdf.id_equipment = any(ids_equips )
						and vaevdf.id_shift = any(ids_shifts )
					GROUP by 
							vaevdf.ts_value,
							vaevdf.id_enterprise,
							vaevdf.id_shift 
				) d0
				group by 
					id_enterprise,
					ts_value
		)
		select 
			t.ts::timestamp, 
			pi.net_production_incr::bigint,
			(sum(gross_production_incr) over ( partition by pi.part_end order by t.ts asc))::bigint as gross_production_acc,
			(sum(net_production_incr) over (partition by pi.part_end order by t.ts asc))::bigint as net_production_acc,
			(pi.scrap_incr)::bigint scrap,
			(sum(pi.scrap_incr) over ( partition by pi.part_end order by t.ts asc))::bigint as scrap_acc,
			(greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) ))::bigint trendline1,
			(sum(t.targets) over (order by t.ts))::bigint as target,
			(case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then (coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 ))::float8
			end) as toGoal,in_id_enterprise, 
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		( 
			select 
					ts.*,
					regr_params.*,
					tgs.*
			from generate_series(date_trunc('DAY'::text,begin_time::timestamptz)::timestamp without time zone - interval '1day',
								   (date_trunc('day',end_time::timestamptz+interval '1 day')-interval '1 hour')::timestamp without time zone,
								   '01:00:00'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_equipment) as equips_ids--, max(id_enterprise) as id_enterprise 
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_day)/24 )::bigint
						else sum(ptd.target)/24
					end as targets
				from production_targets pt2 
				left join production_targets_day ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_equipment = any(equips_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, min_ts, max_ts, intercep1, slop1, equips_ids, tgs.targets--, id_enterprise
		) t
		left join production_info pi on pi.ts_value = t.ts
		order by ts asc;
	
	elsif (time_grain = 'DAY')
		then return query 
			-- USING A DAY GRAIN
		-- DAY GRAIN
with production_info as 
		(
			select 
					id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max( id_equipment) as id_equipment,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
			from 
			(
				select 
						vaevdf.id_enterprise,
						id_shift,
						array_agg( vaevdf.id_site) id_site,
						array_agg( vaevdf.id_area) as id_area,
						array_agg( id_equipment) as id_equipment,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
				from
					v_agg_equipment_values_1day_full vaevdf
				where
					vaevdf.ts_value >= date_trunc('DAY'::text, begin_time::timestamptz) 
					and vaevdf.ts_value < date_trunc('DAY'::text, end_time::timestamptz)
					AND vaevdf.tp_equipment = 3
					and vaevdf.id_enterprise = in_id_enterprise
					and vaevdf.id_area = any( ids_areas)
					and vaevdf.id_site = any( ids_sites )
					and vaevdf.id_equipment = any( ids_equips )
					and vaevdf.id_shift = any( ids_shifts ) 
				GROUP by 
						vaevdf.ts_value,
						vaevdf.id_enterprise,
						id_shift
		) d0
		group by 
			ts_value, id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by pi.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal,
			in_id_enterprise as id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*
			from generate_series(date_trunc('DAY'::text, begin_time::timestamptz)::timestamp without time zone - interval '1day',
		 					  (date_trunc('day', end_time::timestamptz+interval '1 day')-interval '1 hour')::timestamp without time zone,
		 					  '1day'::interval) ts(ts) 
		cross join
		(
			select 
				regr_intercept(net_production_acc,rn) intercep1,
				regr_slope(net_production_acc, rn) slop1,
				min(d0.ts_value) as min_ts,
				max(d0.ts_value) as max_ts,
				max(id_equipment) as equips_ids
			from production_info d0
		) regr_params
		join lateral 
		(
			-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_day) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_day ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_equipment = any(equips_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					equips_ids,
					tgs.targets
		) t
		left join production_info pi on pi.ts_value = t.ts
		order by ts asc;
	
	elsif (time_grain = 'WEEK')
		then return query
		-- USING WEEK GRAIN
		-- WEEK GRAIN
with production_info as 
		(
			select
				id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max( id_equipment) as id_equipment,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
			from 
			(
				select 
					vaevdf.id_enterprise,
					id_shift,
					array_agg( vaevdf.id_site) id_site,
					array_agg( vaevdf.id_area) as id_area,
					array_agg( id_equipment) as id_equipment,
					sum(vaevdf.gross_production_incr) gross_production_incr,
					sum(vaevdf.net_production_incr) net_production_incr,
					sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
					sum(vaevdf.scrap_incr) scrap_incr,
					vaevdf.ts_value
				from
					v_agg_equipment_values_1week_full vaevdf
				where
					vaevdf.ts_value >= date_trunc('week'::text, begin_time::timestamptz) 
					and vaevdf.ts_value < date_trunc('week'::text, end_time::timestamptz)
					AND vaevdf.tp_equipment = 3
					and vaevdf.id_enterprise = in_id_enterprise
					and vaevdf.id_area = any( ids_areas)
					and vaevdf.id_site = any( ids_sites )
					and vaevdf.id_equipment = any( ids_equips )
					and vaevdf.id_shift = any( ids_shifts ) 
				GROUP by 
						vaevdf.ts_value,
						vaevdf.id_enterprise, 
						vaevdf.id_shift
			) d0
			group by 
				ts_value, id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by pi.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal,
			in_id_enterprise as id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*
			from generate_series(date_trunc('week'::text, begin_time::timestamptz)::timestamp without time zone,
								   (date_trunc('week', end_time::timestamptz))::timestamp without time zone,
								   '1week'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_equipment) as equips_ids
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_week) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_week ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_equipment = any(equips_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					equips_ids,
					tgs.targets
		) t
		left join production_info pi on pi.ts_value::date = t.ts::date
		order by ts asc;
	else
		return query 
		-- MONTH GRAIN
with production_info as 
		(
			select
				id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max( id_equipment) as id_equipment,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
			from 
			(
				select 
					vaevdf.id_enterprise,
					id_shift,
					array_agg( vaevdf.id_site) id_site,
					array_agg( vaevdf.id_area) as id_area,
					array_agg( id_equipment) as id_equipment,
					sum(vaevdf.gross_production_incr) gross_production_incr,
					sum(vaevdf.net_production_incr) net_production_incr,
					sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
					sum(vaevdf.scrap_incr) scrap_incr,
					vaevdf.ts_value
				from
					v_agg_equipment_values_1month_full vaevdf
				where
					vaevdf.ts_value >= date_trunc('month'::text, begin_time::timestamptz) 
					and vaevdf.ts_value < date_trunc('month'::text, end_time::timestamptz)
					AND vaevdf.tp_equipment = 3
					and vaevdf.id_enterprise = in_id_enterprise
					and vaevdf.id_area = any( ids_areas)
					and vaevdf.id_site = any( ids_sites )
					and vaevdf.id_equipment = any( ids_equips )
					and vaevdf.id_shift = any( ids_shifts ) 
				GROUP by 
						vaevdf.ts_value,
						vaevdf.id_enterprise, 
						vaevdf.id_shift
			) d0
			group by 
				ts_value, id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by pi.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by pi.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal,
			in_id_enterprise as id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*
			from generate_series(date_trunc('month'::text, begin_time::timestamptz)::timestamp without time zone,
								   (date_trunc('month', end_time::timestamptz))::timestamp without time zone,
								   '1month'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_equipment) as equips_ids
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_month) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_month ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_equipment = any(equips_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					equips_ids,
					tgs.targets
		) t
		left join production_info pi on pi.ts_value::date = t.ts::date
		order by ts asc;
		
	end if;

--return;
end
$$;


--
-- Name: h_piot_total_production_equipment_chart_day_test1(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_equipment_chart_day_test1(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_data
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_shifts::int[]) = 0 then true
						 		else id_shift = any( in_id_shifts::int[])
						 	 end);
	min_ts_prod timestamptz := (select min(ts_value) from v_agg_equipment_values_1hour_full ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								AND ev.tp_equipment = 3
								and ev.id_enterprise = in_id_enterprise
								and ev.id_area = any( ids_areas)
								and ev.id_site = any( ids_sites )
								and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) );
begin 
	return query 
	select 
		ts::timestamp without time zone as ts,
--		to_char)::varchar || 'T!' as ts,
		coalesce(net_incr, 0)::int8 net_production_incr,
		coalesce(net_acc, lag(net_acc) over (order by ts) )::int8 net_production_acc, 
		case 
			when ts <= max(ts_value) over()
				then coalesce(gross_acc, lag(gross_acc) over (order by ts) )
		end::int8 as gross_production_acc,
		coalesce(scrap_incr, 0)::int8 scrap_incr,
		case 
			when ts <= max(ts_value) over()
				then coalesce(scrap_acc, lag(scrap_acc) over (order by ts) )
		end::int8 as scrap_acc,
		coalesce((regr_slope((net_acc), (secs))  over () * extract(epoch from ts - min(ts) over()))
		 		  + regr_intercept((net_acc), (secs)) over ()
		 		  , 0)::int8 trendline1,
		 coalesce(sum(sum(tgs.targets)) over (order by ts), 0)::int8 target,
		 case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(sum(tgs.targets)) over (order by ts) )
							   /nullif(net_acc, 0), 0 )
	 	 end::float8 as toGoal,
		 in_id_enterprise::int4 as id_enterprise,
		 shift_info::json as shift_net_prod
	from 
	(
		select 
			id_enterprise, ts, max(secs) secs, max(ts_value) ts_value,
			sum(net_production_incr) as net_incr,
			sum(gross_production_incr) as gross_incr,
			sum(scrap_incr) as scrap_incr,
			jsonb_agg( jsonb_build_object('shift', cd_shift, 
									  	  'scrap', scrapacc_sh, 
									  	  'net', netacc_sh)	order by cd_shift) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from
		(
		select 
			id_enterprise, 1 part,
			cd_shift,
			case time_grain
				when 'HOUR' then 
					ts_value
				else 
					date_trunc(time_grain, ts_value_production) 
			end ts_value,
			extract(epoch from 
					case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end
					- min(case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end) over ()
			) secs,
			coalesce(sum(net_production_incr), 0) net_production_incr,
			coalesce(sum(gross_production_incr), 0) gross_production_incr,
			coalesce(sum(scrap_incr), 0) scrap_incr,
			sum(sum(net_production_incr)) over part netacc_sh,
			sum(sum(scrap_incr)) over part scrapacc_sh,
			sum(sum(net_production_incr)) over T_part netacc,
			sum(sum(gross_production_incr)) over T_part grossacc,
			sum(sum(scrap_incr)) over T_part scrapacc
		from v_agg_equipment_values_1hour_full ev 
		join shifts s using (id_enterprise, id_shift) 
		where 
			(ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
			and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			AND ev.tp_equipment = 3
			and ev.id_enterprise = in_id_enterprise
			and ev.id_area = any( ids_areas)
			and ev.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
			and ev.id_shift = any( ids_shifts )
		group by id_enterprise, 
				id_shift, cd_shift,
				case time_grain when 'HOUR' then ts_value	else date_trunc(time_grain, ts_value_production) end
		window part as 
			( 
			partition by case time_grain when 'HOUR' then id_enterprise else id_shift	end				
			order by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		, T_part as 
			(
			partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d
		right join
		(
			select ts
			from generate_series(date_trunc(time_grain::text, in_begin_time::timestamptz)::timestamp without time zone,
								 case time_grain
								 	when 'HOUR' 
								 		then date_trunc(time_grain::text, 
								 						in_end_time::timestamptz) 
								 							+  (min_ts_prod - date_trunc('day', in_begin_time::timestamptz))
								 	else
										(date_trunc(time_grain, in_end_time::timestamptz))::timestamp without time zone	
								 end,
			 					 ('1'||time_grain)::interval) ts(ts)
			where case time_grain when 'HOUR' then ts >= min_ts_prod else true end
		) ts on ts.ts = d.ts_value
		group by id_enterprise, ts	
	) vals
	join lateral 
		(
			-- For day chart the target uses the vl_day 
			select
				case 
					when time_grain = 'HOUR' 
						then coalesce(sum(ptd.target)/24, sum(pt2.vl_day)/24, 0)
					when time_grain = 'DAY' 
						then coalesce(sum(ptd.target), sum(pt2.vl_day), 0)
					when time_grain = 'WEEK' 
						then coalesce(sum(ptw.target), sum(pt2.vl_week), 0)
					when time_grain = 'MONTH'
						then coalesce(sum(ptm.target), sum(pt2.vl_month), 0)
					else 0
				end::int8 as targets
			from production_targets pt2 
			left join production_targets_day ptd 
				on ptd.ts_target::date = vals.ts::date 
				and ptd.id_equipment = pt2.id_equipment 
			left join production_targets_week ptw 
				on ptw.ts_target::date = vals.ts::date
				and ptw.id_equipment = pt2.id_equipment 
			left join production_targets_month ptm 
				on ptm.ts_target::date = vals.ts::date
				and ptm.id_equipment = pt2.id_equipment 
			where pt2.id_equipment = any( ids_equips)
			and pt2.id_site = any(ids_sites )
			and pt2.id_area = any(ids_areas)
		) tgs on true
	group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_acc, scrap_incr, ts_value;
end
$$;


--
-- Name: h_total_production_chart_data_tz_fix; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_total_production_chart_data_tz_fix (
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
    shift_net_prod json
);


--
-- Name: h_piot_total_production_equipment_chart_day_test1_tz_fix(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_equipment_chart_day_test1_tz_fix(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_data_tz_fix
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_shifts::int[]) = 0 then true
						 		else id_shift = any( in_id_shifts::int[])
						 	 end);
	min_ts_prod timestamptz := (select min(ts_value) from v_agg_equipment_values_1hour_full ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								AND ev.tp_equipment = 3
								and ev.id_enterprise = in_id_enterprise
								and ev.id_area = any( ids_areas)
								and ev.id_site = any( ids_sites )
								and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) );
begin 
	return query 
	select 
		(timezone('utc', ts)::timestamptz)::varchar,
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
		coalesce(greatest(0,
						  (regr_slope((net_acc), (secs))  over () * extract(epoch from ts - min(ts) over()))
		 		  			+ regr_intercept((net_acc), (secs)) over ())
		 		  , 0)::int8 trendline1,
		 coalesce(sum(sum(tgs.targets)) over (order by ts), 0)::int8 target,
		 case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(sum(tgs.targets)) over (order by ts) )
							   /nullif(net_acc, 0), 0 )
	 	 end::float8 as toGoal,
		 in_id_enterprise::int4 as id_enterprise,
		 shift_info::json as shift_net_prod
	from 
	(
		select 
			id_enterprise, ts, max(secs) secs, max(ts_value) ts_value,
			sum(net_production_incr) as net_incr,
			sum(gross_production_incr) as gross_incr,
			sum(scrap_incr) as scrap_incr,
			jsonb_agg( jsonb_build_object('shift', cd_shift, 
									  	  'scrap', scrapacc_sh, 
									  	  'net', netacc_sh)	order by cd_shift) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from
		(
		select 
			id_enterprise, 1 part,
			cd_shift,
			case time_grain
				when 'HOUR' then 
					ts_value
				else 
					date_trunc(time_grain, ts_value_production) 
			end ts_value,
			extract(epoch from 
					case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end
					- min(case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end) over ()
			) secs,
			coalesce(sum(net_production_incr), 0) net_production_incr,
			coalesce(sum(gross_production_incr), 0) gross_production_incr,
			coalesce(sum(scrap_incr), 0) scrap_incr,
			sum(sum(net_production_incr)) over part netacc_sh,
			sum(sum(scrap_incr)) over part scrapacc_sh,
			sum(sum(net_production_incr)) over T_part netacc,
			sum(sum(gross_production_incr)) over T_part grossacc,
			sum(sum(scrap_incr)) over T_part scrapacc
		from ca_agg_equipment_values_1hour ev --_full ev 
		join shifts s using (id_enterprise, id_shift) 
		where 
			(ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
			and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			AND ev.tp_equipment = 3
			and ev.id_enterprise = in_id_enterprise
			and ev.id_area = any( ids_areas)
			and ev.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
			and ev.id_shift = any( ids_shifts )
		group by id_enterprise, 
				id_shift, cd_shift,
				case time_grain when 'HOUR' then ts_value	else date_trunc(time_grain, ts_value_production) end
		window part as 
			( 
			partition by case time_grain when 'HOUR' then id_enterprise else id_shift	end				
			order by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		, T_part as 
			(
			partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d
		right join
		(
			select ts
			from generate_series(date_trunc(time_grain::text, in_begin_time::timestamptz)::timestamp without time zone,
								 case time_grain
								 	when 'HOUR' 
								 		then date_trunc(time_grain::text, 
								 						in_end_time::timestamptz) 
								 							+  (min_ts_prod - date_trunc('day', in_begin_time::timestamptz))
								 	else
										(date_trunc(time_grain, in_end_time::timestamptz))::timestamp without time zone	
								 end,
			 					 ('1'||time_grain)::interval) ts(ts)
			where case time_grain when 'HOUR' then ts >= min_ts_prod else true end
		) ts on ts.ts = d.ts_value
		group by id_enterprise, ts	
	) vals
	join lateral 
		(
			-- For day chart the target uses the vl_day 
		
		
			select
				case 
					when time_grain = 'HOUR' 
						then coalesce(sum(ptd.target)/24, sum(pt2.vl_day)/24, 0)
					when time_grain = 'DAY' 
						then coalesce(sum(ptd.target), sum(pt2.vl_day), 0)
					when time_grain = 'WEEK' 
						then coalesce(sum(ptw.target), sum(pt2.vl_week), 0)
					when time_grain = 'MONTH'
						then coalesce(sum(ptm.target), sum(pt2.vl_month), 0)
					else 0
				end::int8 as targets
			from production_targets pt2 
			left join production_targets_day ptd 
				on ptd.ts_target::date = vals.ts::date 
				and ptd.id_equipment = pt2.id_equipment 
			left join production_targets_week ptw 
				on ptw.ts_target::date = vals.ts::date
				and ptw.id_equipment = pt2.id_equipment 
			left join production_targets_month ptm 
				on ptm.ts_target::date = vals.ts::date
				and ptm.id_equipment = pt2.id_equipment 
			where pt2.id_equipment = any( ids_equips)
			and pt2.id_site = any(ids_sites )
			and pt2.id_area = any(ids_areas)
		) tgs on true
	group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value;
end
$$;


--
-- Name: h_piot_total_production_equipment_chart_day_test1_tz_fix2(integer, text, text, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_equipment_chart_day_test1_tz_fix2(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_data_tz_fix
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_shifts::int[]) = 0 then true
						 		else id_shift = any( in_id_shifts::int[])
						 	 end);
	min_ts_prod timestamptz := (select min(ts_value) from v_agg_equipment_values_1hour_full ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								AND ev.tp_equipment = 3
								and ev.id_enterprise = in_id_enterprise
								and ev.id_area = any( ids_areas)
								and ev.id_site = any( ids_sites )
								and ev.id_equipment = any( ids_equips )
								and ev.id_shift = any( ids_shifts ) );
begin 
	return query 
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
				then coalesce(gross_incr - net_incr, 0) --coalesce(scrap_incr, 0)::int8 
			else null
		end::int8 scrap_incr,
		case 
			when ts <= now()
				then coalesce(sum(gross_incr) over (order by ts) - sum(net_incr) over (order by ts), 0)
		end::int8 as scrap_acc,
		coalesce(greatest(0,
						  (regr_slope((net_acc), (secs))  over () * extract(epoch from ts - min(ts) over()))
		 		  			+ regr_intercept((net_acc), (secs)) over ())
		 		  , 0)::int8 trendline1,
		 coalesce(sum(sum(tgs.targets)) over (order by ts), 0)::int8 target,
		 case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(sum(tgs.targets)) over (order by ts) )
							   /nullif(net_acc, 0), 0 )
	 	 end::float8 as toGoal,
		 in_id_enterprise::int4 as id_enterprise,
		 shift_info::json as shift_net_prod
	from 
	(
		select 
			id_enterprise, coalesce (d.ts_value, ts.ts) ts, max(secs) secs, max(ts_value) ts_value,
			sum(net_production_incr) as net_incr,
			sum(gross_production_incr) as gross_incr,
			sum(scrap_incr) as scrap_incr,
			jsonb_agg( jsonb_build_object('shift', cd_shift, 
									  	  'scrap', scrapacc_sh, 
									  	  'net', netacc_sh)	order by cd_shift) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from
		(
		select 
			id_enterprise, 1 part,
			cd_shift,
			case time_grain
				when 'HOUR' then 
					case ev.ts_value when date_trunc('hour', now()) then now()::timestamptz 
					else 
					ev.ts_value -- + interval '1 hour'
					end
				else 
--					date_trunc(time_grain, ts_value_production) 
					case ev.ts_value when date_trunc(time_grain, now()) then now()::timestamptz 
						else 
						ev.ts_value_production -- + interval '1 hour'
					end
				end ts_value,
			extract(epoch from 
					case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end
					- min(case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end) over ()
			) secs,
			coalesce(sum(net_production_incr), 0) net_production_incr,
			coalesce(sum(gross_production_incr), 0) gross_production_incr,
			coalesce(sum(scrap_incr), 0) scrap_incr,
			sum(sum(net_production_incr)) over part netacc_sh,
			sum(sum(scrap_incr)) over part scrapacc_sh,
			sum(sum(net_production_incr)) over T_part netacc,
			sum(sum(gross_production_incr)) over T_part grossacc,
			sum(sum(scrap_incr)) over T_part scrapacc
		from ca_agg_equipment_values_1hour ev --_full ev 
		join shifts s using (id_enterprise, id_shift) 
		where 
			(ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
			and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
			AND ev.tp_equipment = 3
			and ev.id_enterprise = in_id_enterprise
			and ev.id_area = any( ids_areas)
			and ev.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
			and ev.id_shift = any( ids_shifts )
		group by id_enterprise, 
				id_shift, cd_shift, ev.ts_value, ev.ts_value_production,
				case time_grain when 'HOUR' then ts_value	else date_trunc(time_grain, ts_value_production) end
		window part as 
			( 
			partition by case time_grain when 'HOUR' then id_enterprise else id_shift	end				
			order by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		, T_part as 
			(
			partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d
		full outer join--right join
		(
			select ts
			from generate_series(date_trunc(time_grain::text, in_begin_time::timestamptz)::timestamp without time zone,
								 case time_grain
								 	when 'HOUR' 
								 		then date_trunc(time_grain::text, 
								 						in_end_time::timestamptz) 
								 							+  (min_ts_prod - date_trunc('day', in_begin_time::timestamptz))
								 	else
										(date_trunc(time_grain, in_end_time::timestamptz))::timestamp without time zone	
								 end,
			 					 ('1'||time_grain)::interval) ts(ts)
			where case time_grain when 'HOUR' then ts >= min_ts_prod else true end
		) ts on ts.ts = d.ts_value
		group by id_enterprise, ts, d.ts_value 
	) vals
	join lateral 
		(
			-- For day chart the target uses the vl_day 
			select
				case 
					when time_grain = 'HOUR' 
						then coalesce(sum(ptd.target)/24, sum(pt2.vl_day)/24, 0)
					when time_grain = 'DAY' 
						then coalesce(sum(ptd.target), sum(pt2.vl_day), 0)
					when time_grain = 'WEEK' 
						then coalesce(sum(ptw.target), sum(pt2.vl_week), 0)
					when time_grain = 'MONTH'
						then coalesce(sum(ptm.target), sum(pt2.vl_month), 0)
					else 0
				end::int8 as targets
			from production_targets pt2 
			left join production_targets_day ptd 
				on ptd.ts_target::date = vals.ts::date 
				and ptd.id_equipment = pt2.id_equipment 
			left join production_targets_week ptw 
				on ptw.ts_target::date = vals.ts::date
				and ptw.id_equipment = pt2.id_equipment 
			left join production_targets_month ptm 
				on ptm.ts_target::date = vals.ts::date
				and ptm.id_equipment = pt2.id_equipment 
			where pt2.id_equipment = any( ids_equips)
			and pt2.id_site = any(ids_sites )
			and pt2.id_area = any(ids_areas)
		) tgs on true
	group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value
	order by ts;
end
$$;


--
-- Name: h_piot_total_production_equipment_from_runtime(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_equipment_from_runtime(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_data_tz_fix
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_shifts::int[]) = 0 then true
						 		else id_shift = any( in_id_shifts::int[])
						 	 end);
	min_ts_prod timestamptz := (select min(ts_value) from equipment_runtime_1hour ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select max(ts_value) from equipment_runtime_1hour ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return query 
	select 
		(timezone('utc', ts::timestamptz)::timestamptz)::varchar,
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
						max(net_acc) over()  +   
								((       max(net_acc) over()     *     extract(epoch from ts - max(ts) filter (where ts <= now()) over())     )
								/ nullif(max(secs) filter (where ts <= now()) over(), 0) ) )::int8, 0)
		 	end	  		  trendline1,
--		 case 
--			when ts <= now() 
--				then coalesce(sum(target) over (order by ts), 0)
--			else null
--		end::int8 target,
--		coalesce(sum(target) over (order by ts), 0)::int8 target,
		 coalesce(sum(target), 0)::int8 target,
		 case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(target) )
							   /nullif(net_acc, 0), 0 )
	 	 end::float8 as toGoal,
		 id_enterprise,
		 shift_info::json as shift_net_prod
	from 
	(
		select 
			id_enterprise, coalesce (d.ts_value, ts.ts) ts, max(secs) secs, max(ts_value) ts_value,
			sum(net_production_incr) as net_incr,
			sum(gross_production_incr) as gross_incr,
			sum(scrap_incr) as scrap_incr,
			sum(target) as target,
			jsonb_agg( jsonb_build_object('shift', cd_shift, 
									  	  'scrap', scrapacc_sh, 
									  	  'net', netacc_sh)	order by cd_shift) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from
		(
		select 
			e.id_enterprise,
			cd_shift,
			case ev.ts_value
				when date_trunc('hour', now()) then now()::timestamptz 
				else ev.ts_value -- + interval '1 hour'
			end ts_value,
			extract(epoch from case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end
					- min(case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end) over ()
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
		from equipment_runtime_1hour ev
			join equipments e using (id_equipment)
			left JOIN LATERAL piot_get_shift_hour_by_equipment_fixed(e.id_enterprise, e.id_equipment, ev.ts_value) f ON true
		where 
			(ev.ts_value >= min_ts_prod::timestamp--date_trunc(time_grain::text, min_ts_prod::timestamptz) 
			and ev.ts_value < max_ts_prod::timestamp--date_trunc(time_grain::text, max_ts_prod::timestamptz)
			) 
			AND e.tp_equipment = 3
--			and e.id_equipment in (1, 6, 11, 42)
--			and ev.id_enterprise = in_id_enterprise
--			and ev.id_area = any( ids_areas)
--			and ev.id_site = any( ids_sites )
--			and ev.id_equipment = 1
			and ev.id_equipment = any( ids_equips )
--			and ev.id_shift = any( ids_shifts )
		group by e.id_enterprise, 
				ev.ts_value, ev.ts_value_production, cd_shift,  --id_shift, cd_shift, 
				case time_grain when 'HOUR' then ts_value	else date_trunc(time_grain, ts_value_production) end
		window part as 
			( 
			partition by case time_grain when 'HOUR' then e.id_enterprise else null	end--id_shift	end				
			order by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		, T_part as 
			(
			partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d
			
			
			full outer join--right join
		(
			select ts
			from generate_series(min_ts_prod::timestamptz,
--								 case time_grain
--								 	when 'HOUR' 
--								 		then date_trunc(time_grain::text, 
--								 						in_end_time::timestamptz) 
--								 							+  (min_ts_prod - date_trunc('day', in_begin_time::timestamptz))
--								 	else
--										(date_trunc(time_grain, in_end_time::timestamptz))::timestamp without time zone	
--								 end,
								max_ts_prod::timestamptz,
			 					 ('1'||time_grain)::interval) ts(ts)
			where case time_grain when 'HOUR' then ts >= min_ts_prod else true end
		) ts on ts.ts = d.ts_value
		
		
		
		
		group by id_enterprise, ts, d.ts_value
		) vals
	group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value, target
	order by ts;



ELSE return QUERY 
	
--	Por Dia, mes ...
	
	select 
		'batata'::varchar,
		--(timezone('utc', ts)::timestamptz)::varchar,
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
		coalesce(greatest(0,
						  (regr_slope((net_acc), (secs))  over () * extract(epoch from ts - min(ts) over()))
		 		  			+ regr_intercept((net_acc), (secs)) over ())
		 		  , 0)::int8 trendline1,
		 coalesce(sum(target), 0)::int8 target,
		 case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(target) )
							   /nullif(net_acc, 0), 0 )
	 	 end::float8 as toGoal,
		 in_id_enterprise::int4 as id_enterprise,
		 shift_info::json as shift_net_prod
	from 
	(
		select 
			id_enterprise, coalesce (d.ts_value, ts.ts) ts, max(secs) secs, max(ts_value) ts_value,
			sum(net_production_incr) as net_incr,
			sum(gross_production_incr) as gross_incr,
			sum(scrap_incr) as scrap_incr,
			sum(target) as target,
			jsonb_agg( jsonb_build_object('shift', cd_shift, 
									  	  'scrap', scrapacc_sh, 
									  	  'net', netacc_sh)	order by cd_shift) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from
		(
		select 
			id_enterprise, 1 part,
			cd_shift,
			case time_grain
				when 'HOUR' then 
					case ev.ts_value when date_trunc('hour', now()) then now()::timestamptz 
					else 
					ev.ts_value -- + interval '1 hour'
					end
				else 
--					date_trunc(time_grain, ts_value_production) 
					case ev.ts_value when date_trunc(time_grain, now()) then now()::timestamptz 
						else 
						ev.ts_value_production -- + interval '1 hour'
					end
				end ts_value,
			extract(epoch from 
					case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end
					- min(case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end) over ()
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
		from equipment_runtime_shift ev --_full ev 
		join equipments e using (id_equipment) 
		where 
			(ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamp) 
			and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamp)) 
			AND e.tp_equipment = 3
--			and id_equipment in (1, 6)
--			and ev.id_enterprise = in_id_enterprise
--			and ev.id_area = any( ids_areas)
--			and ev.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
--			and ev.id_shift = any( ids_shifts )
		group by id_enterprise, 
				id_shift, cd_shift, ev.ts_value, ev.ts_value_production,
				case time_grain when 'HOUR' then ts_value	else date_trunc(time_grain, ts_value_production) end
		window part as 
			( 
			partition by case time_grain when 'HOUR' then id_enterprise else id_shift	end				
			order by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		, T_part as 
			(
			partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d
		full outer join--right join
		(
			select ts
			from generate_series(min_ts_prod,
--								 case time_grain
--								 	when 'HOUR' 
--								 		then date_trunc(time_grain::text, 
--								 						in_end_time::timestamptz) 
--								 							+  (min_ts_prod - date_trunc('day', in_begin_time::timestamptz))
--								 	else
--										(date_trunc(time_grain, in_end_time::timestamptz))::timestamp without time zone	
--								 end,
								max_ts_prod,
			 					 ('1'||time_grain)::interval) ts(ts)
			where case time_grain when 'HOUR' then ts >= min_ts_prod else true end
		) ts on ts.ts = d.ts_value
		group by id_enterprise, ts, d.ts_value
		) vals
	group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value
	order by ts;
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
-- Name: h_piot_total_production_equipment_from_runtime_test(integer, text, text, text, text, timestamp without time zone, timestamp without time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_equipment_from_runtime_test(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_from_runtime
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
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_id_shifts::int[]) = 0 then true
						 		else id_shift = any( in_id_shifts::int[])
						 	 end);
	min_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then min(ts_value) else min(ts_value_production) end from equipment_runtime_1hour ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								);
	max_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then max(ts_value) else max(ts_value_production) end from equipment_runtime_1hour ev
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								);
begin 
IF UPPER(time_grain) = 'HOUR' THEN 
	return query 
	select 
		(timezone('utc', ts::timestamptz)::timestamptz(0))::varchar,
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
--		case  
--	 		when ts < date_trunc('hour', now()) then null
--	 		else
--	 		coalesce(greatest(0,
--						max(net_acc) over()  +   
--								((       max(net_acc) over()     *     extract(epoch from date_trunc('hour',ts) - date_trunc('hour', max(ts) filter (where ts <= now()::timestamptz(0)) over()))     )
--								/ 
--									nullif(
--										case when now()>=min(ts) over() and now()<=max(ts) over() then 
--								 			extract(epoch from now()- min(ts) over ())::int8
--								 		else 
--								 			nullif(max(secs) filter (where ts <= now()::timestamptz) over(), 0)::int8
--								 		end
--										, 0)
--								) )::int8, 0)
--		 	end trendline1,
--		 	case 
--	 		when ts < date_trunc('hour', now()) then null
--	 		else
--	 		coalesce(greatest(0,
--						max(net_acc) over()  +   
--								((       max(net_acc) over()     *     extract(epoch from ts - date_trunc('hour', max(ts) filter (where ts <= now()::timestamptz(0)) over()))     )
--								/ nullif(max(secs) filter (where ts <= now()::timestamptz(0)) over(), 0) ) )::int8, 0)
--		 	end trendline1,
--		 	case 
--	 		when ts < now()::timestamptz(0) then null
--	 		else
--	 		coalesce(greatest(0,
--						max(net_acc) over()  +   
--								((       max(net_acc) over()     *     extract(epoch from ts - date_trunc('hour', max(ts) filter (where ts <= now()::timestamptz(0)) over()))     )
--								/ nullif(max(secs) filter (where ts <= now()::timestamptz(0)) over(), 0) ) )::int8, 0)
--		 	end	  		  trendline1,
--	 	case 
--	 		when ts < now() then null
--	 		else
--	 		coalesce(greatest(0,
--						max(net_acc) over()  +   
--								((       max(net_acc) over()     *     extract(epoch from ts - date_trunc('hour', max(ts) filter (where ts <= now()) over()))     )
--								/ nullif(max(secs) filter (where ts <= now()) over(), 0) ) )::int8, 0)
--		 	end	  		  trendline1,
		case 
	 		when ts < now() then null
	 		else
				coalesce(greatest(0,
						  (regr_slope((net_acc), (secs))  filter (where ts< now()::timestamptz(0)) over () * extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over()))
		 		  			+ max(net_acc) over())
		 		  , 0)::int8 end trendline1,
--		case 
--	 		when ts < now() then null
--	 		else
--	 		coalesce(greatest(0,
--						max(net_acc) over()  +   
--								((       max(net_acc) over()     *     extract(epoch from ts - max(ts) filter (where max(net_acc) over()) over())     )
--								/ nullif(max(secs) filter (where ts < now()) over(), 0) ) )::int8, 0)
--		 	end	  		  trendline1,
		coalesce(sum(target) over (order by ts), 0)::int8 target,
		 case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(target) )
							   /nullif(net_acc, 0), 0 )
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
			jsonb_agg( jsonb_build_object('shift', cd_shift, 
									  	  'scrap', scrapacc_sh, 
									  	  'net', netacc_sh)	order by cd_shift) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from
		(
		select 
			e.id_enterprise,
			cd_shift,
			case ev.ts_value
				when date_trunc('hour', now()) then now()::timestamptz 
				else ev.ts_value -- + interval '1 hour'
			end ts_value,
			extract(epoch from case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end
					- min(case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end) over ()
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
		from equipment_runtime_1hour ev
			join equipments e using (id_equipment)
			left JOIN LATERAL piot_get_shift_hour_by_equipment_fixed(e.id_enterprise, e.id_equipment, ev.ts_value) f ON true
		where 
			(ev.ts_value >= min_ts_prod::timestamp--date_trunc(time_grain::text, min_ts_prod::timestamptz) 
			and ev.ts_value <= max_ts_prod::timestamp--date_trunc(time_grain::text, max_ts_prod::timestamptz)
			) 
			AND e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
--			and ev.id_shift = any( ids_shifts )
		group by e.id_enterprise, 
				ev.ts_value, ev.ts_value_production, cd_shift,  --id_shift, cd_shift, 
				case time_grain when 'HOUR' then ts_value	else date_trunc(time_grain, ts_value_production) end
		window part as 
			( 
			partition by case time_grain when 'HOUR' then e.id_enterprise else null	end--id_shift	end				
			order by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		, T_part as 
			(
			partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d	
			full outer join--right join
		(
			select ts
			from generate_series(min_ts_prod::timestamptz,
								max_ts_prod::timestamptz,
			 					 ('1'||time_grain)::interval) ts(ts)
			where case time_grain when 'HOUR' then ts >= min_ts_prod else true end
				and  ts <> date_trunc('hour', now()) 
		) ts on ts.ts = d.ts_value
		group by id_enterprise, ts, d.ts_value
		) vals
	group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value, target
	order by ts;
ELSE return QUERY 
--	Por Dia, mes ...
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
--		coalesce(greatest(0,
--						  (regr_slope((net_acc), (secs))  over () * extract(epoch from ts - min(ts) over()))
--		 		  			+ regr_intercept((net_acc), (secs)) over ())
--		 		  , 0)::int8 trendline1,
--		case 
--	 		when ts < now() then null
--	 		else
--				coalesce(greatest(0,
--						  (regr_slope((net_acc), (secs))  filter (where ts< now()::timestamptz) over () * extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over()))
--		 		  			+ max(net_acc) over())
--		 		  , 0)::int8 end trendline1,
		case 
	 		when ts < now() then null
	 		else
				coalesce(greatest(0,
						  (
						  (max(net_acc) filter(where ts <= now()::timestamptz) over()/nullif(extract (epoch from max(ts) filter(where ts <= now()::timestamptz) over()-min(ts) over() ),0))
						  * extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over()))
		 		  			+ max(net_acc) over())
		 		  , 0)::int8 end trendline1,
		 coalesce(sum(target) over (order by ts), 0)::int8 target,
		 case 
			when ts <= max(ts_value) over () 
				then coalesce( (net_acc - sum(target) )
							   /nullif(net_acc, 0), 0 )
	 	 end::float8 as toGoal,
		 in_id_enterprise::int4 as id_enterprise,
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
			jsonb_agg( jsonb_build_object('shift', cd_shift, 
									  	  'scrap', scrapacc_sh, 
									  	  'net', netacc_sh)	order by cd_shift) shift_info,
			sum(max(netacc)) over ( partition by id_enterprise order by ts)::int8 net_acc,
			sum(max(scrapacc)) over ( partition by id_enterprise order by ts)::int8 scrap_acc,
			sum(max(grossacc)) over ( partition by id_enterprise order by ts)::int8 gross_acc
		from
		(
		select 
			id_enterprise, 1 part,
			cd_shift,
			case time_grain
				when 'HOUR' then 
					case ev.ts_value when date_trunc('hour', now()) then now()::timestamptz 
					else 
					ev.ts_value_production -- + interval '1 hour'
					end
				else 
					case ev.ts_value_production when date_trunc(time_grain, now())::date then now()::timestamptz 
						else 
						ev.ts_value_production -- + interval '1 hour'
					end
				end ts_value,
			extract(epoch from 
					case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end
					- min(case time_grain when 'HOUR' then ts_value else date_trunc(time_grain, ts_value_production) end) over ()
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
		from equipment_runtime_shift ev --_full ev 
		join equipments e using (id_equipment) 
		where 
			(ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamp) 
			and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamp)) 
			AND e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
			and ev.id_shift = any( ids_shifts )
		group by id_enterprise, 
				id_shift, cd_shift, ev.ts_value, ev.ts_value_production,
				case time_grain when 'HOUR' then ts_value	else date_trunc(time_grain, ts_value_production) end
		window part as 
			( 
			partition by case time_grain when 'HOUR' then id_enterprise else id_shift	end				
			order by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		, T_part as 
			(
			partition by case time_grain when 'HOUR' then 	ts_value else date_trunc(time_grain, ts_value_production) end
			)
		) d
		full outer join--right join
		(
			select ts
			from generate_series(min_ts_prod,
								max_ts_prod,
			 					 ('1'||time_grain)::interval) ts(ts)
			where case time_grain when 'HOUR' then ts >= min_ts_prod else ts<>date_trunc(time_grain, now()) end
		) ts on ts.ts = d.ts_value
		group by id_enterprise, ts, d.ts_value
		) vals
		group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value, target
	order by ts;
END IF;
end
$$;


--
-- Name: h_piot_total_production_sites_chart_day(integer, text, text, timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_sites_chart_day(in_id_enterprise integer, in_ids_sites text, in_ids_shifts text, begin_time timestamp with time zone, end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_data
    LANGUAGE plpgsql STABLE
    AS $$
declare
	ids_sites int[] := in_ids_sites::int[];
	ids_shifts int[] := (select array_agg(id_shift) 
						 from shifts s
						 where s.id_enterprise=in_id_enterprise 
						 and case
						 		when cardinality(in_ids_shifts::int[]) = 0 then true
						 		else id_shift = any( in_ids_shifts::int[])
						 	 end);
begin
	if time_grain = 'HOUR'
		then return query		
		with production_info as 
		(	
			select
				id_enterprise,
				ts_value, 
				1 as part_end,
				row_number() over (order by ts_value) as rn, 
				max( id_site) as id_site,
				sum(net_production_incr) net_production_incr,
				sum(gross_production_incr) gross_production_incr,
				sum(scrap_incr) scrap_incr,
				json_object(
							array_agg(id_shift::text order by id_shift),
							array_agg(net_production_sh_acc::text order by id_shift)
							) as shift_net_prod,
				sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
				sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
			from 
			(
				select 
					vaevdf.id_enterprise,
					id_shift,
					array_agg( vaevdf.id_site) id_site,
					sum(vaevdf.gross_production_incr) gross_production_incr,
					sum(vaevdf.net_production_incr) net_production_incr,
					sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
					sum(vaevdf.scrap_incr) scrap_incr,
					vaevdf.ts_value
				from
					v_agg_site_values_1hour_full vaevdf
				where
					vaevdf.ts_value_production >= date_trunc('DAY'::text, begin_time::timestamptz) 
					and vaevdf.ts_value_production < date_trunc('DAY'::text, end_time::timestamptz)
					and vaevdf.id_enterprise = in_id_enterprise
					and vaevdf.id_site = any( ids_sites )
					and vaevdf.id_shift = any( ids_shifts ) 
				GROUP by 
						vaevdf.ts_value,
						vaevdf.id_enterprise,
						vaevdf.id_shift 
			) d0
			group by 
				ts_value, id_enterprise
		)
		select 
			t.ts::timestamp, 
			pi.net_production_incr::bigint,
			(sum(gross_production_incr) over ( partition by t.part_end order by t.ts asc))::bigint as gross_production_acc,
			(sum(net_production_incr) over (partition by t.part_end order by t.ts asc))::bigint as net_production_acc,
			(pi.scrap_incr)::bigint scrap,
			(sum(pi.scrap_incr) over ( partition by t.part_end order by t.ts asc))::bigint as scrap_acc,
			(greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) ))::bigint trendline1,
			(sum(t.targets) over (order by t.ts))::bigint as target,
			(case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then (coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 ))::float8
			end) as toGoal, in_id_enterprise as id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		( 
			select 
					ts.*,
					regr_params.*,
					tgs.*,
					case
						when ts.ts <= max_ts then 1
						else null
					end as part_end
			from generate_series(date_trunc('DAY'::text, begin_time::timestamptz)::timestamp without time zone - interval '1day',
								   (date_trunc('day', end_time::timestamptz+interval '1 day')-interval '1 hour')::timestamp without time zone,
								   '01:00:00'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_site) as sites_ids
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_day)/24 )::bigint
						else sum(ptd.target)/24
					end as targets
				from production_targets pt2 
				left join production_targets_day ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_site = any(sites_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, min_ts, max_ts, intercep1, slop1, sites_ids, tgs.targets, part_end
		) t
		left join production_info pi on pi.ts_value = t.ts
		order by ts asc;
	elsif (time_grain = 'DAY')
		then return query 
			-- USING A DAY GRAIN
		with production_info as 
		(
				select 
					id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max(id_site) as id_site,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
				from 
				(
					select 
						vaevdf.id_enterprise,
						id_shift,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						array_agg( vaevdf.id_site) id_site,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
					from
						v_agg_site_values_1day_full vaevdf
					where
						vaevdf.ts_value >= date_trunc('DAY'::text, begin_time::timestamptz) 
						and vaevdf.ts_value < date_trunc('DAY'::text, end_time::timestamptz)
						and vaevdf.id_enterprise = in_id_enterprise
						and vaevdf.id_site = any( ids_sites )
						and vaevdf.id_shift = any(ids_shifts )
					GROUP by 
							vaevdf.ts_value,
							vaevdf.id_enterprise,
							id_shift 
				) d0
				group by 
					ts_value, id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by t.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by t.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by t.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal, in_id_enterprise as id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*,
					case
						when ts.ts <= max_ts then 1
						else null
					end as part_end
			from generate_series(date_trunc('DAY'::text, begin_time::timestamptz)::timestamp without time zone,
		 					  (date_trunc('day', end_time::timestamptz))::timestamp without time zone,
		 					  '1day'::interval) ts(ts) 
		cross join
		(
			select 
				regr_intercept(net_production_acc,rn) intercep1,
				regr_slope(net_production_acc, rn) slop1,
				min(d0.ts_value) as min_ts,
				max(d0.ts_value) as max_ts,
				max(id_site) as sites_ids 
			from production_info d0
		) regr_params
		join lateral 
		(
			-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_day) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_day ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_site = any(sites_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					sites_ids,
					tgs.targets,
					part_end
		) t
		left join production_info pi on pi.ts_value = t.ts
		order by ts asc;
	elsif (time_grain = 'WEEK')
		then return query
		-- USING WEEK GRAIN
		with production_info as 
		(
			select 
					id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max(id_site) as id_site,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
				from 
				(
					select 
						vaevdf.id_enterprise,
						id_shift,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						array_agg( vaevdf.id_site) id_site,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
					from
						v_agg_site_values_1week_full vaevdf
					where
						vaevdf.ts_value >= date_trunc('week'::text, begin_time::timestamptz) 
						and vaevdf.ts_value < date_trunc('week'::text, end_time::timestamptz)
						and vaevdf.id_enterprise = in_id_enterprise
						and vaevdf.id_site = any( ids_sites )
						and vaevdf.id_shift = any(ids_shifts )
					GROUP by 
							vaevdf.ts_value,
							vaevdf.id_enterprise,
							vaevdf.id_shift
				) d0
				group by 
					ts_value,  id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by t.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by t.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by t.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal, in_id_enterprise as id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*,
					case
						when ts.ts <= max_ts then 1
						else null
					end as part_end
			from generate_series(date_trunc('week'::text, begin_time::timestamptz)::timestamp without time zone,
								   (date_trunc('week', end_time::timestamptz))::timestamp without time zone,
								   '1week'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_site) as sites_ids
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_week) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_week ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_site = any(sites_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					sites_ids,
					tgs.targets,
					part_end
		) t
		left join production_info pi on pi.ts_value::date = t.ts::date
		order by ts asc;
	
	else
		return query 	
		-- USING MONTH GRAIN
		with production_info as 
		(
			select 
					id_enterprise,
					ts_value, 
					1 as part_end,
					row_number() over (order by ts_value) as rn, 
					max(id_site) as id_site,
					sum(net_production_incr) net_production_incr,
					sum(gross_production_incr) gross_production_incr,
					sum(scrap_incr) scrap_incr,
					json_object(
								array_agg(id_shift::text order by id_shift),
								array_agg(net_production_sh_acc::text order by id_shift)
								) as shift_net_prod,
					sum(sum(gross_production_incr)) over ( order by d0.ts_value asc) as gross_production_acc,
					sum(sum(net_production_incr)) over ( order by d0.ts_value asc) as net_production_acc
				from 
				(
					select 
						vaevdf.id_enterprise,
						id_shift,
						sum(sum(vaevdf.net_production_incr)) over (partition by id_shift order by ts_value) net_production_sh_acc,
						array_agg( vaevdf.id_site) id_site,
						sum(vaevdf.gross_production_incr) gross_production_incr,
						sum(vaevdf.net_production_incr) net_production_incr,
						sum(vaevdf.scrap_incr) scrap_incr,
						vaevdf.ts_value
					from
						v_agg_area_values_1month_full vaevdf
					where
						vaevdf.ts_value >= date_trunc('month'::text, begin_time::timestamptz) 
						and vaevdf.ts_value < date_trunc('month'::text, end_time::timestamptz)
						and vaevdf.id_enterprise = in_id_enterprise
						and vaevdf.id_site = any( ids_sites )
						and vaevdf.id_shift = any(ids_shifts )
					GROUP by 
							vaevdf.ts_value,
							vaevdf.id_enterprise
				) d0
				group by 
					ts_value, id_enterprise
		)
		select 
			t.ts::timestamp ts, 
			pi.net_production_incr::bigint net_production_incr,
			sum(gross_production_incr) over (partition by t.part_end order by t.ts asc)::bigint as gross_production_acc,
			sum(net_production_incr) over (partition by t.part_end order by t.ts asc)::bigint as net_production_acc,
			pi.scrap_incr::bigint as scrap,
			sum(pi.scrap_incr) over (partition by t.part_end order by t.ts asc)::bigint as scrap_acc,
			greatest(0, t.intercep1 + t.slop1 * ( row_number() over(order by t.ts)+1) )::bigint trendline1,
			sum(t.targets) over (order by t.ts)::bigint as target,
			case 
				when sum(net_production_incr) over ( order by t.ts asc) is not null 
					then coalesce((sum(net_production_incr) over (order by t.ts asc) -
								   sum(t.targets) over (order by t.ts) )/nullif(sum(net_production_incr) over ( order by t.ts asc), 0), 0 )
			end::float8 as toGoal, in_id_enterprise as id_enterprise,
			case 
				when ts < max_ts or (ts< max_ts and pi.ts_value is null)
					then coalesce(((lag(shift_net_prod) over (order by ts asc))::jsonb || pi.shift_net_prod::jsonb)::json, shift_net_prod)
				when ts = max_ts
					then shift_net_prod
			end as shift_net_prod
		from 
		(
			select 
					ts.ts,
					regr_params.*,
					tgs.*,
					case
						when ts.ts <= max_ts then 1
						else null
					end as part_end
			from generate_series(date_trunc('month', begin_time::timestamptz)::timestamp without time zone,
								   (date_trunc('month', end_time::timestamptz))::timestamp without time zone,
								   '1month'::interval) ts(ts) 
			cross join
			(
				select 
					regr_intercept(net_production_acc,rn) intercep1,
					regr_slope(net_production_acc, rn) slop1,
					min(d0.ts_value) as min_ts,
					max(d0.ts_value) as max_ts,
					max(id_site) as sites_ids
				from production_info d0
			) regr_params
			join lateral 
			(
				-- For day chart the target uses the vl_day 
				select
					case 
						when sum(ptd.target) is null then ( sum(pt2.vl_month) )::bigint
						else sum(ptd.target)
					end as targets
				from production_targets pt2 
				left join production_targets_month ptd on ptd.ts_target::date = max_ts::date
				where pt2.id_site = any(sites_ids)
			) tgs on true
			where ts >= min_ts 
			group by ts, 
					min_ts,
					max_ts,
					intercep1,
					slop1,
					sites_ids,
					tgs.targets,
					part_end
		) t
		left join production_info pi on pi.ts_value::date = t.ts::date
		order by ts asc;
		
	end if;

--return;
end
$$;


--
-- Name: h_piot_total_production_teams(integer, text, text, text, text, text, timestamp without time zone, timestamp without time zone, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.h_piot_total_production_teams(in_id_enterprise integer, in_id_sites text, in_id_areas text, in_id_equipments text, in_id_shifts text, in_id_teams text, in_begin_time timestamp without time zone, in_end_time timestamp without time zone, partitionby text, time_grain text DEFAULT 'DAY'::text) RETURNS SETOF public.h_total_production_chart_from_runtime
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
	min_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then min(ts_value) else min(ts_value_production) end from equipment_runtime_1hour ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								and e.id_area = any( ids_areas )
								and e.id_site = any( ids_sites )
								);
	max_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then max(ts_value) else max(ts_value_production) end from equipment_runtime_1hour ev join equipments e using (id_equipment)
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
			equipment_runtime_1hour ev
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
			scrap, net, gross, 
			target,
			ts_value_production
		from
			equipment_runtime_shift ev
			join equipments e using (id_equipment) 
			left join teams t using (id_team) 
		where 
			(ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamp) 
				and ev.ts_value_production <= date_trunc(time_grain::text, in_end_time::timestamp)) 
			AND e.tp_equipment = 3
			and e.id_enterprise = in_id_enterprise
			and e.id_area = any( ids_areas)
			and e.id_site = any( ids_sites )
			and ev.id_equipment = any( ids_equips )
			and ev.id_shift = any( ids_shifts )
--			and ev.id_team = any( ids_teams )
			and (case when ids_teams is not null then ev.id_team = any( ids_teams ) else true end)
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
		case 
			when ts < now() then null
			else
			coalesce(greatest(0,
				(
					(max(net_acc) filter(where ts <= now()::timestamptz) over()/nullif(extract (epoch from max(ts) filter(where ts <= now()::timestamptz) over()-min(ts) over() ),0))
					* extract(epoch from ts - max(ts) filter (where ts <= now()::timestamptz) over()))
		 		  	+ max(net_acc) over())
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
				id_enterprise, coalesce (d.ts_value, ts.ts) ts, max(secs) secs, max(ts_value) ts_value,
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
						ts_value_production when date_trunc(time_grain, now())::date then now()::timestamptz 
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
				from generate_series(min_ts_prod,
									max_ts_prod,
				 					 ('1'||time_grain)::interval) ts(ts)
				where ts<>date_trunc(time_grain, now())
			) ts on ts.ts = d.ts_value
			group by id_enterprise, ts, d.ts_value
		) vals
		group by id_enterprise, ts, net_acc, secs, shift_info, scrap_acc, net_incr, gross_incr, gross_acc, scrap_incr, ts_value, target
	order by ts;


END IF;
end
$$;


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
	min_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then min(ts_value) else min(ts_value_production) end from equipment_runtime_1hour ev join equipments e using (id_equipment)
								where (ev.ts_value_production >= date_trunc(time_grain::text, in_begin_time::timestamptz) 
								and ev.ts_value_production < date_trunc(time_grain::text, in_end_time::timestamptz)) 
								and ev.id_equipment = any( ids_equips )
								and e.id_area = any( ids_areas )
								and e.id_site = any( ids_sites )
								);
	max_ts_prod timestamptz := (select case when UPPER(time_grain) = 'HOUR' then max(ts_value) else max(ts_value_production) end from equipment_runtime_1hour ev join equipments e using (id_equipment)
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
			equipment_runtime_1hour ev
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
			equipment_runtime_shift ev
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
				insert into area_runtime_1day(id_area, ts_value)
					select r.id_area, ts_value_production from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_area_runtime_1hour(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_area_runtime_1hour() RETURNS void
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
			for i in 0..720 
			loop -- 30 days - 720 hours
				insert into area_runtime_1hour(id_area, ts_value)
					select r.id_area, date_trunc('hour', now() + interval '1 hour' * (i)) 
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_area_runtime_1month(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_area_runtime_1month() RETURNS void
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
			for i in 0..3
			loop -- 3 months
				insert into area_runtime_1month(id_area, ts_value)
					select r.id_area, date_trunc('month', ts_value_production) from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 month' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_area_runtime_1week(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_area_runtime_1week() RETURNS void
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
			for i in 0..12
			loop -- 12 weeks
				insert into area_runtime_1week(id_area, ts_value)
					select r.id_area, date_trunc('week', ts_value_production) from piot_get_day_begin_by_area(r.id_area, time_now + interval '1 week' * (i))
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
				insert into area_runtime_shift(id_area, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
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
				insert into equipment_runtime_1day(id_equipment, ts_value)
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
				
				insert into equipment_runtime_1hour (id_equipment, ts_value, target, ts_value_production)
				
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
							target = CASE WHEN equipment_runtime_1hour.target_customized = false and (equipment_runtime_1hour.target <> EXCLUDED.target or equipment_runtime_1hour.target is null) THEN EXCLUDED.target ELSE equipment_runtime_1hour.target END,
							ts_value_production = EXCLUDED.ts_value_production
							where
								equipment_runtime_1hour.id_equipment  = r.id_equipment
								and equipment_runtime_1hour.ts_value = excluded.ts_value;
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
				insert into equipment_runtime_1month(id_equipment, ts_value)
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
			for i in -200..30 
			loop -- 30 days
				insert into equipment_runtime_1week(id_equipment, ts_value)
					select r.id_equipment, date_trunc('week', ts_value_production) from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


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
				insert into equipment_runtime_shift(id_equipment, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
				select r.id_equipment, e.*, (select ts_value_production from piot_get_day_begin_by_equipment(r.id_equipment, time_now + interval '1 hour' * (i * 4)) limit 1) 
					from piot_get_shift_hour_begin_by_equipment(r.id_equipment, time_now + interval '1 hour' * (i * 4)) e
						left join shifts_exception_period sep on (r.id_equipment  = sep.id_equipment and e.ts_begin>=sep.ts_begin and e.ts_begin<sep.ts_end)
						where sep.id_equipment is null
					on conflict do NOTHING;
			end loop;

			update equipment_runtime_shift u
				set target = p.target_shift
			from (
				select id_equipment, ts_value_production, coalesce((duration/3600)*vl_hour,0) as target_shift --coalesce(vl_day/count(*), 0) as target_shift
				from equipment_runtime_shift ers
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
			insert into equipment_runtime_shift_1month(ts_value, id_equipment, id_shift, duration, target)
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
						from equipment_runtime_shift_1month ers
						where 
							id_equipment = r.id_equipment
							and ts_value >= date_trunc('month', now())
						group by
							date_trunc('month', ts_value), id_equipment, id_shift
						order by ts_value
						)s0
					)s1
					left join equipment_runtime_1month erw using (ts_value, id_equipment)
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
			insert into equipment_runtime_shift_1week(ts_value, id_equipment, id_shift, duration, target)
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
						from equipment_runtime_shift_1week ers
						where 
							id_equipment = r.id_equipment
							and ts_value >= date_trunc('week', now())
						group by
							date_trunc('week', ts_value), id_equipment, id_shift
						order by ts_value
						)s0
					)s1
					left join equipment_runtime_1week erw using (ts_value, id_equipment)
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
				insert into site_runtime_1day(id_site, ts_value)
					select r.id_site, ts_value_production from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 day' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_site_runtime_1hour(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_site_runtime_1hour() RETURNS void
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
			for i in 0..720 
			loop -- 30 days - 720 hours
				insert into site_runtime_1hour(id_site, ts_value)
					select r.id_site, date_trunc('hour', now() + interval '1 hour' * (i)) 
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_site_runtime_1month(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_site_runtime_1month() RETURNS void
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
			for i in 0..3
			loop -- 3 months
				insert into site_runtime_1month(id_site, ts_value)
					select r.id_site, date_trunc('month', ts_value_production) from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 month' * (i))
					on conflict do NOTHING;
			end loop;
		end loop;
	end
$$;


--
-- Name: piot_create_site_runtime_1week(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_create_site_runtime_1week() RETURNS void
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
			for i in 0..12
			loop -- 12 weeks
				insert into site_runtime_1week(id_site, ts_value)
					select r.id_site, date_trunc('week', ts_value_production) from piot_get_day_begin_by_site(r.id_site, time_now + interval '1 week' * (i))
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
				insert into site_runtime_shift(id_site, ts_value, ts_end, duration, ts_range, id_shift, id_shift_hour, ts_value_production)
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
-- Name: piot_get_day_begin_offset_by_equipment(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_day_begin_offset_by_equipment(in_id_equipment integer) RETURNS integer
    LANGUAGE plpgsql STABLE
    AS $$
declare
	in_id_site int := (select id_site from equipments s where s.id_equipment=in_id_equipment );
	in_id_area int := (select id_area from equipments s where s.id_equipment=in_id_equipment );
	in_id_enterprise int := (select id_enterprise from equipments s where s.id_equipment=in_id_equipment );
	r RECORD;
begin
 	select day_begin into r from
	(
	select 
			s.day_begin,
			null as id_area, id_site
		from sites s
		where id_site = in_id_site
	union all 
	select 
			a.day_begin,
			a.id_area, s.id_site
		from areas a
		join sites s on a.id_site = s.id_site
		where a.id_area = in_id_area
	order by id_area, id_site limit 1
	) s1;
	return r.day_begin;
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
-- Name: h_piot_edge_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_edge_settings (
    id_enterprise integer,
    edge_id integer,
    packml_setting text[]
);


--
-- Name: piot_get_edge_setting(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_edge_setting() RETURNS SETOF public.h_piot_edge_settings
    LANGUAGE plpgsql STABLE
    AS $$
begin
	return query
	
--TODO: the function is not sending the positions of the equipments to the line when it has sectors.
	
with topics as (
	select 
		*
	from
		packml_register pr
		left join equipments e using(id_enterprise, id_equipment)
),
speed as(
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(packml_topic,'/Status/MachSpeed'),
			production_speed
		)
	from topics t
	where production_speed is not null
--	group by t.id_enterprise
),
minimum_performance_threshold  as(
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(packml_topic,'/Status/Parameter[30750]'),--30750
			minimum_performance_threshold
		)
	from topics t
	where minimum_performance_threshold  is not null
),
equipments_order as(
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(t.packml_topic,'/Status/Parameter[30700]'),
			array_agg(c.id_unit order by c.line_unit_seq)
		)
	from 
		topics t
		join topics c on (t.id_equipment=c.id_parentequipment)
	group by t.packml_topic, t.id_enterprise
),
event_trigger_type as(
	-- Attention: this parameter is probably incorrectly configured in the database for most of the equipments!!! Most of them are = 1
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(packml_topic,'/Status/Parameter[30750]'),
			status_type
		)
	from topics t
	where status_type is not null
),
state_change_threshold_time as(
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(packml_topic,'/Status/Parameter[30751]'),
			state_change_threshold_time 
		)
	from topics t
	where state_change_threshold_time  is not null
),
lead_machine as(
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(packml_topic,'/Status/Parameter[30702]'),
			lead_machine 
		)
	from topics t
	where lead_machine is not null
),
speed_calculated_by_packiot as(
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(packml_topic,'/Status/Parameter[30761]'),
			speed_calculated_by_packiot
		)
	from topics t
	where speed_calculated_by_packiot is not null
),
event_generated_by_packiot as(
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(packml_topic,'/Status/Parameter[30763]'),
			event_generated_by_packiot
		)
	from topics t
	where event_generated_by_packiot is not null
),
conversion_factor as(
	select 
		t.id_enterprise,
		jsonb_build_object(
			concat(packml_topic,'/Status/Parameter[30710]'),
			conversion_factor
		)
	from topics t
	where conversion_factor is not null
)
select 
	id_enterprise,
	null::int4 as edge_id, --not in USE BUT READY to USE
	array_agg( jsonb_build_object) as packml_setting-- over (partition id_enterprise)
from (
	select * from speed s
	union all
	select * from minimum_performance_threshold
	union all
	select * from equipments_order
	union all
	select * from event_trigger_type
	union all
	select * from state_change_threshold_time
	union all
	select * from lead_machine
	union all
	select * from speed_calculated_by_packiot
	union all
	select * from event_generated_by_packiot
	union all
	select * from conversion_factor
)s0 group by id_enterprise;


end;
$$;


--
-- Name: h_equipment_chart_data_1day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_equipment_chart_data_1day (
    id_enterprise integer,
    id_site integer,
    id_area integer,
    id_equipment integer,
    ts_value timestamp without time zone,
    gross_production double precision,
    net_production double precision,
    gross_production_incr double precision,
    net_production_incr double precision
);


--
-- Name: piot_get_equipment_chart_data(timestamp with time zone, timestamp with time zone, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_equipment_chart_data(begin_time timestamp with time zone, end_time timestamp with time zone, grain character varying) RETURNS SETOF public.h_equipment_chart_data_1day
    LANGUAGE plpgsql STABLE
    AS $$
 begin
	 if (grain = 'hour' and DATE_PART('day',end_time-begin_time)<=2) or DATE_PART('day',end_time-begin_time) <2  then
	 
	 
	 
	 	return query 
			SELECT s0.id_enterprise,
			    s0.id_site,
			    s0.id_area,
			    s0.id_equipment,
			    s0.ts_value,
			    s0.gross_production,
			    s0.net_production,
			    s0.gross_production_partial AS gross_production_incr,
			    s0.net_production_partial AS net_production_incr
			FROM (
				SELECT t.id_enterprise,
			    	t.id_site,
			        t.id_area,
			        t.id_equipment,
			        ts.ts AS ts_value,
			        COALESCE(t.gross_production, 0::double precision) AS gross_production,
			        COALESCE(t.net_production, 0::double precision) AS net_production,
			        t.gross_production_partial,
			        t.net_production_partial
			     FROM generate_series(date_trunc('DAY'::text, begin_time)::timestamp without time zone, (date_trunc('day', end_time+interval '1 day')-interval '1 hour')::timestamp without time zone, '01:00:00'::interval) ts(ts)
			     LEFT JOIN (
			     	SELECT dta.id_enterprise,
			        	dta.id_site,
			            dta.id_area,
			            dta.id_equipment,
			            dta.ts_value,
			            dta.gross_production_partial,
			            dta.net_production_partial,
			            dta.net_production,
			            dta.gross_production
			        FROM (
			        	select
			        		dp.id_enterprise,
			            	dp.id_site,
			                dp.id_area,
			                dp.id_equipment,
			                dp.ts_value,
			                dp.gross_production_partial,
			                dp.net_production_partial,
			                sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
			                sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
			                FROM (
			                	select
			                		vaevdf.id_enterprise,
			                    	vaevdf.id_site,
			                        vaevdf.id_area,
			                        vaevdf.id_equipment,
			                        sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
			                        sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
			                        vaevdf.ts_value
			                    from
			                    	v_agg_equipment_values_1hour_full vaevdf
			                    where
			                    	vaevdf.ts_value >= date_trunc('DAY'::text, begin_time) AND vaevdf.tp_equipment = 3
			                    GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
			                    ORDER BY vaevdf.ts_value
			                ) dp
			                GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
			                ORDER BY dp.id_equipment, dp.ts_value
			        ) dta
			     ) t ON t.ts_value = ts.ts
			  ) s0
			  WHERE s0.ts_value >= date_trunc('DAY'::text, begin_time)
			  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value;
	
	elsif (grain = 'day' and DATE_PART('day',end_time-begin_time)<=90) or DATE_PART('day',end_time-begin_time) < 7 then

	 	return query 
			SELECT s0.id_enterprise,
			    s0.id_site,
			    s0.id_area,
			    s0.id_equipment,
			    s0.ts_value,
			    s0.gross_production,
			    s0.net_production,
			    s0.gross_production_partial AS gross_production_incr,
			    s0.net_production_partial AS net_production_incr
			FROM (
				SELECT t.id_enterprise,
			    	t.id_site,
			        t.id_area,
			        t.id_equipment,
			        ts.ts AS ts_value,
			        COALESCE(t.gross_production, 0::double precision) AS gross_production,
			        COALESCE(t.net_production, 0::double precision) AS net_production,
			        t.gross_production_partial,
			        t.net_production_partial
				FROM generate_series(
					date_trunc('day'::text, begin_time)::timestamp without time zone,
					(date_trunc('day', end_time+ interval '1 day')-interval '1 hour')::timestamp without time zone,
					'1 day'::interval
					) ts(ts)
				LEFT JOIN (
			     	SELECT dta.id_enterprise,
			        	dta.id_site,
			            dta.id_area,
			            dta.id_equipment,
			            dta.ts_value,
			            dta.gross_production_partial,
			            dta.net_production_partial,
			            dta.net_production,
			            dta.gross_production
			        FROM (
			        	select
			        		dp.id_enterprise,
			            	dp.id_site,
			                dp.id_area,
			                dp.id_equipment,
			                dp.ts_value,
			                dp.gross_production_partial,
			                dp.net_production_partial,
			                sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
			                sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
			                FROM (
			                	select
			                		vaevdf.id_enterprise,
			                    	vaevdf.id_site,
			                        vaevdf.id_area,
			                        vaevdf.id_equipment,
			                        sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
			                        sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
			                        vaevdf.ts_value
			                    from
			                    	v_agg_equipment_values_1day_full vaevdf
			                    where
			                    	vaevdf.ts_value >= date_trunc('day'::text, begin_time) AND vaevdf.tp_equipment = 3
			                    GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
			                    ORDER BY vaevdf.ts_value
			                ) dp
			                GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
			                ORDER BY dp.id_equipment, dp.ts_value
			        ) dta
			     ) t ON t.ts_value = ts.ts
			  ) s0
--			  WHERE s0.ts_value >= date_trunc('week'::text, begin_time)
			  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value;
			 
			 
			 
			 
	elsif (grain = 'week' and DATE_PART('day',end_time-begin_time)<=365) or (DATE_PART('day',end_time-begin_time)<30) then
	 
	 	return query
			SELECT s0.id_enterprise,
			    s0.id_site,
			    s0.id_area,
			    s0.id_equipment,
			    s0.ts_value,
			    s0.gross_production,
			    s0.net_production,
			    s0.gross_production_partial AS gross_production_incr,
			    s0.net_production_partial AS net_production_incr
			FROM (
				SELECT t.id_enterprise,
			    	t.id_site,
			        t.id_area,
			        t.id_equipment,
			        ts.ts AS ts_value,
			        COALESCE(t.gross_production, 0::double precision) AS gross_production,
			        COALESCE(t.net_production, 0::double precision) AS net_production,
			        t.gross_production_partial,
			        t.net_production_partial
			     FROM generate_series(date_trunc('week'::text, begin_time)::timestamp without time zone, (date_trunc('week', end_time+interval '7 day')-interval '1 hour')::timestamp without time zone, '1 week'::interval) ts(ts)
			     LEFT JOIN (
			     	SELECT dta.id_enterprise,
			        	dta.id_site,
			            dta.id_area,
			            dta.id_equipment,
			            dta.ts_value,
			            dta.gross_production_partial,
			            dta.net_production_partial,
			            dta.net_production,
			            dta.gross_production
			        FROM (
			        	select
			        		dp.id_enterprise,
			            	dp.id_site,
			                dp.id_area,
			                dp.id_equipment,
			                dp.ts_value,
			                dp.gross_production_partial,
			                dp.net_production_partial,
			                sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
			                sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
			                FROM (
			                	select
			                		vaevdf.id_enterprise,
			                    	vaevdf.id_site,
			                        vaevdf.id_area,
			                        vaevdf.id_equipment,
			                        sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
			                        sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
			                        vaevdf.ts_value
			                    from
			                    	v_agg_equipment_values_1week_full vaevdf
			                    where
			                    	vaevdf.ts_value >= date_trunc('week'::text, begin_time) AND vaevdf.tp_equipment = 3
			                    GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
			                    ORDER BY vaevdf.ts_value
			                ) dp
			                GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
			                ORDER BY dp.id_equipment, dp.ts_value
			        ) dta
			     ) t ON t.ts_value = ts.ts
			  ) s0
			  WHERE s0.ts_value >= date_trunc('week'::text, begin_time)
			  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value;
			 
			  
	else
	 
	 	return query
			SELECT s0.id_enterprise,
			    s0.id_site,
			    s0.id_area,
			    s0.id_equipment,
			    s0.ts_value,
			    s0.gross_production,
			    s0.net_production,
			    s0.gross_production_partial AS gross_production_incr,
			    s0.net_production_partial AS net_production_incr
			FROM (
				SELECT t.id_enterprise,
			    	t.id_site,
			        t.id_area,
			        t.id_equipment,
			        ts.ts AS ts_value,
			        COALESCE(t.gross_production, 0::double precision) AS gross_production,
			        COALESCE(t.net_production, 0::double precision) AS net_production,
			        t.gross_production_partial,
			        t.net_production_partial
			     FROM generate_series(date_trunc('month'::text, begin_time)::timestamp without time zone, (date_trunc('month', end_time+interval '7 day')-interval '1 hour')::timestamp without time zone, '1 month'::interval) ts(ts)
			     LEFT JOIN (
			     	SELECT dta.id_enterprise,
			        	dta.id_site,
			            dta.id_area,
			            dta.id_equipment,
			            dta.ts_value,
			            dta.gross_production_partial,
			            dta.net_production_partial,
			            dta.net_production,
			            dta.gross_production
			        FROM (
			        	select
			        		dp.id_enterprise,
			            	dp.id_site,
			                dp.id_area,
			                dp.id_equipment,
			                dp.ts_value,
			                dp.gross_production_partial,
			                dp.net_production_partial,
			                sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
			                sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
			                FROM (
			                	select
			                		vaevdf.id_enterprise,
			                    	vaevdf.id_site,
			                        vaevdf.id_area,
			                        vaevdf.id_equipment,
			                        sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
			                        sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
			                        vaevdf.ts_value
			                    from
			                    	v_agg_equipment_values_1month_full vaevdf
			                    where
			                    	vaevdf.ts_value >= date_trunc('month'::text, begin_time) AND vaevdf.tp_equipment = 3
			                    GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
			                    ORDER BY vaevdf.ts_value
			                ) dp
			                GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
			                ORDER BY dp.id_equipment, dp.ts_value
			        ) dta
			     ) t ON t.ts_value = ts.ts
			  ) s0
			  WHERE s0.ts_value >= date_trunc('month'::text, begin_time)
			  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value;
			 
			 
	end if;
end;
 $$;


--
-- Name: piot_get_equipment_chart_data_1day(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_equipment_chart_data_1day(begin_time timestamp with time zone, end_time timestamp with time zone) RETURNS SETOF public.h_equipment_chart_data_1day
    LANGUAGE sql STABLE
    AS $$
-- Enter function body here
select
	s0.id_enterprise,
    s0.id_site,
    s0.id_area,
    s0.id_equipment,
    s0.ts_value,
    s0.gross_production,
    s0.net_production,
    s0.gross_production_partial AS gross_production_incr,
    s0.net_production_partial AS net_production_incr
   FROM ( SELECT t.id_enterprise,
            t.id_site,
            t.id_area,
            t.id_equipment,
            ts.ts AS ts_value,
            COALESCE(t.gross_production, 0::double precision) AS gross_production,
            COALESCE(t.net_production, 0::double precision) AS net_production,
            t.gross_production_partial,
            t.net_production_partial
           FROM generate_series(date_trunc('DAY'::text, begin_time)::timestamp without time zone, date_trunc('DAY'::text, end_time)::timestamp without time zone, '1 day'::interval) ts(ts)
             LEFT JOIN ( SELECT dta.id_enterprise,
                    dta.id_site,
                    dta.id_area,
                    dta.id_equipment,
                    dta.ts_value,
                    dta.gross_production_partial,
                    dta.net_production_partial,
                    dta.net_production,
                    dta.gross_production
                   FROM ( SELECT dp.id_enterprise,
                            dp.id_site,
                            dp.id_area,
                            dp.id_equipment,
                            dp.ts_value,
                            dp.gross_production_partial,
                            dp.net_production_partial,
                            sum(dp.net_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS net_production,
                            sum(dp.gross_production_partial) OVER (PARTITION BY dp.id_equipment ORDER BY dp.ts_value) AS gross_production
                           FROM ( SELECT vaevdf.id_enterprise,
                                    vaevdf.id_site,
                                    vaevdf.id_area,
                                    vaevdf.id_equipment,
                                    sum(vaevdf.gross_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS gross_production_partial,
                                    sum(vaevdf.net_production_incr) OVER (PARTITION BY vaevdf.id_equipment, vaevdf.ts_value) AS net_production_partial,
                                    vaevdf.ts_value
                                   FROM v_agg_equipment_values_1day_full vaevdf
                                  WHERE vaevdf.ts_value >= date_trunc('DAY'::text, begin_time) AND vaevdf.tp_equipment = 3
                                  GROUP BY vaevdf.ts_value, vaevdf.id_enterprise, vaevdf.id_site, vaevdf.id_area, vaevdf.id_equipment, vaevdf.gross_production_incr, vaevdf.net_production_incr
                                  ORDER BY vaevdf.ts_value) dp
                          GROUP BY dp.ts_value, dp.id_enterprise, dp.id_site, dp.id_area, dp.id_equipment, dp.gross_production_partial, dp.net_production_partial
                          ORDER BY dp.id_equipment, dp.ts_value) dta) t ON t.ts_value = ts.ts) s0
  WHERE s0.ts_value >= date_trunc('DAY'::text, begin_time)
  ORDER BY s0.id_enterprise, s0.id_equipment, s0.ts_value
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
-- Name: h_shift_hours_per_equipment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_shift_hours_per_equipment (
    id_enterprise integer,
    id_equipment integer,
    shift_hours jsonb
);


--
-- Name: piot_get_shift_hours_by_enterprise_packml_topic(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_get_shift_hours_by_enterprise_packml_topic(in_topic text) RETURNS SETOF public.h_shift_hours_per_equipment
    LANGUAGE sql STABLE
    AS $$

select 
	id_enterprise, id_equipment, array_agg(sh_per_equip) as shift_hours
from 
	(
	select eq.id_enterprise, eq.id_equipment,
		jsonb_build_object(
			'id_shift_hour', sh.id_shift_hour,
			'id_shift', sh.id_shift,
			'cd_shift', sh.cd_shift,
			'begin_time', sh.begin_time,
			'end_time', sh.end_time,
			'id_site', sh.id_site,
			'id_area', sh.id_area,
			'day_number',sh.day_number,
			'day_week', sh.day_week,
			'shift_size', sh.shift_size,
			'duration', sh.duration
		) sh_per_equip
	from (select * from equipments where id_enterprise = (select id_enterprise from packml_register where packml_topic = in_topic)) eq
	join piot_get_shift_hours_by_equipment(eq.id_enterprise , eq.id_equipment) sh on true 
	group by eq.id_enterprise, eq.id_equipment, sh.id_shift_hour, sh.id_shift, sh.cd_shift, sh.begin_time, sh.end_time, sh.id_site, sh.id_area, sh.day_number, sh.day_week, sh.shift_size, sh.duration
)eqs
group by id_enterprise, id_equipment;



	
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
-- Name: h_piot_split_downtime; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_split_downtime (
    id_equipment integer,
    ts_event timestamp with time zone,
    status integer,
    txt_downtime_notes character varying,
    idle character varying,
    cd_machine character varying,
    cd_category character varying,
    cd_subcategory character varying,
    change_over boolean,
    planned_downtime boolean,
    ts_end timestamp with time zone,
    duration integer,
    id_enterprise integer
);


--
-- Name: piot_split_downtime(bigint, timestamp with time zone, character varying, character varying, character varying, character varying, character varying, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_split_downtime(_id_equipment_event bigint, _begin_time timestamp with time zone, _notes character varying, _idle character varying, _cd_machine character varying, _cd_category character varying, _cd_subcategory character varying, _change_over boolean, _planned_downtime boolean) RETURNS SETOF public.h_piot_split_downtime
    LANGUAGE plpgsql
    AS $$
begin
	with original_events as(select * from equipment_events ee where id_equipment_event = (_id_equipment_event)),
	event_to_insert as (
		select
			original_events.id_equipment,
			_begin_time as ts_event,
			original_events.status,
			_notes as txt_downtime_notes,
			_idle as idle,
			_cd_machine as cd_machine,
			_cd_category as cd_category,
			_cd_subcategory as cd_subcategory,
			_change_over as change_over,
			_planned_downtime as planned_downtime,
			original_events.ts_end,
			EXTRACT(EPOCH FROM (original_events.ts_end - _begin_time))::int as duration,
			original_events.id_enterprise,
			true as forced_creation_system
		from
			original_events
	)
	insert into equipment_events (id_equipment, ts_event, status, txt_downtime_notes, idle, cd_machine, cd_category, cd_subcategory , change_over, planned_downtime, ts_end , duration, id_enterprise, forced_creation_system) select * from event_to_insert
	;
	return query
	select
			id_equipment,
			ts_event,
			status,
			txt_downtime_notes,
			idle,
			cd_machine,
			cd_category,
			cd_subcategory,
			change_over,
			planned_downtime,
			ts_end,
			duration,
			id_enterprise
		from
			equipment_events ee where id_equipment_event = (_id_equipment_event);
	return query
	with original_events as(select * from equipment_events ee )
	update equipment_events
	set
		ts_end = (_begin_time),
		duration = EXTRACT(EPOCH FROM (_begin_time - ts_event))::int,
		forced_creation_system = true
	where id_equipment_event = (_id_equipment_event)
	returning 
		id_equipment,
		ts_event,
		status,
		txt_downtime_notes,
		idle,
		cd_machine,
		cd_category,
		cd_subcategory,
		change_over,
		planned_downtime,
		ts_end,
		duration,
		id_enterprise;
return;
end
$$;


--
-- Name: h_piot_edited_po; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.h_piot_edited_po (
    id_production_order bigint
);


--
-- Name: piot_switch_po_number(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.piot_switch_po_number(in_production_order_running integer, in_new_production_order integer) RETURNS SETOF public.h_piot_edited_po
    LANGUAGE plpgsql
    AS $$
begin
	update production_orders_runtime por set
		id_production_order = in_new_production_order,
		recalc_needed = true
	where id_production_order = in_production_order_running;
	update production_orders po_new set
		id_product = po_old.id_product,
	    id_client = po_old.id_client,
	    status = po_old.status,
	    production_programmed = po_old.production_programmed,
	    production_ordered = po_old.production_ordered,
	    production_real = po_old.production_real,
	    production_final = po_old.production_final,
	    ts_start = po_old.ts_start,
	    ts_end = po_old.ts_end,
	    oee_processed = po_old.oee_processed,
	    oee_quality = po_old.oee_quality,
	    oee_performance = po_old.oee_performance,
	    oee_availability = po_old.oee_availability,
	    oee = po_old.oee,
	    available_time = po_old.available_time,
	    running_time = po_old.running_time,
	    stopped_time = po_old.stopped_time,
	    planned_downtime = po_old.planned_downtime,
	    ideal_production = po_old.ideal_production,
	    qt_stops = po_old.qt_stops,
	    erp_processed = po_old.erp_processed,
	    gross_production = po_old.gross_production,
	    ts_creation = po_old.ts_creation,
	    ts_start_tz = po_old.ts_start_tz,
	    ts_end_tz = po_old.ts_end_tz,
	    txt_production_order_notes = po_old.txt_production_order_notes,
	    txt_production_order_description = po_old.txt_production_order_description,
	    conversion_factor = po_old.conversion_factor,
	    net_production = po_old.net_production,
	    speed = po_old.speed,
	    ideal_production_speed = po_old.ideal_production_speed
		from (select * from production_orders where id_production_order = in_production_order_running limit 1) po_old
	where po_new.id_production_order = in_new_production_order;
	return query
	--Coloca status 3 na ordem original (Encerrada)
	update production_orders po set
		status = 3
	where po.id_production_order = in_production_order_running
	returning po.id_production_order;
	return;
end
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
-- Name: area_runtime_1day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_runtime_1day (
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
-- Name: area_runtime_1hour; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_runtime_1hour (
    ts_value timestamp(0) with time zone NOT NULL,
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
    id_area integer NOT NULL,
    target double precision,
    gross real,
    net real,
    downtime integer,
    changeover_time integer,
    scrap real,
    proportional_target double precision,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000');


--
-- Name: area_runtime_1month; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_runtime_1month (
    ts_value date NOT NULL,
    id_area integer NOT NULL,
    oee real,
    recalc_needed boolean DEFAULT true,
    oee_p real,
    oee_a real,
    oee_q real,
    available_time bigint,
    running_time bigint,
    stopped_time bigint,
    planned_downtime bigint,
    ideal_production double precision,
    idle_time bigint,
    idle_starved bigint,
    idle_blocked bigint,
    target double precision,
    gross real,
    net real,
    downtime bigint,
    changeover_time bigint,
    proportional_target double precision,
    scrap double precision,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
);


--
-- Name: area_runtime_1week; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_runtime_1week (
    ts_value date NOT NULL,
    id_area integer NOT NULL,
    oee real,
    recalc_needed boolean DEFAULT true,
    oee_p real,
    oee_a real,
    oee_q real,
    available_time bigint,
    running_time bigint,
    stopped_time bigint,
    planned_downtime bigint,
    ideal_production double precision,
    idle_time bigint,
    idle_starved bigint,
    idle_blocked bigint,
    target double precision,
    gross real,
    net real,
    downtime bigint,
    changeover_time bigint,
    scrap real,
    proportional_target double precision,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
);


--
-- Name: area_runtime_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.area_runtime_shift (
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
    source_watermark timestamp with time zone
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000');


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
-- Name: equipment_runtime_1day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_runtime_1day (
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
    source_watermark timestamp with time zone
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000');


--
-- Name: equipment_runtime_1hour; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_runtime_1hour (
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
    source_watermark timestamp with time zone
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000');


--
-- Name: equipment_runtime_1month; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_runtime_1month (
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
-- Name: equipment_runtime_1week; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_runtime_1week (
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
-- Name: equipment_runtime_shift_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.equipment_runtime_shift_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: equipment_runtime_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_runtime_shift (
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
    source_watermark timestamp with time zone
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000');


--
-- Name: equipment_runtime_shift_1month; Type: TABLE; Schema: public; Owner: -
--
-- G6 durable-hardening (oeecloud-worker): the shift_1month / shift_1week rollup
-- grains are written by piot_create_equipment_runtime_shift_1{month,week}() and
-- corrected by the worker's not-metered pass (unmetered.go: unmeteredMachineTables),
-- but they were absent from this snapshot and had to be hand-created on new-prod —
-- so a fresh F3 DB-init lacked them and RunUnmetered failed with 42P01. Born here
-- now, shaped exactly like their parent equipment_runtime_shift (LIKE ... INCLUDING
-- ALL: every column, default, and constraint). IF NOT EXISTS keeps this a no-op on
-- any DB where they were already hand-created.
--

CREATE TABLE IF NOT EXISTS public.equipment_runtime_shift_1month (LIKE public.equipment_runtime_shift INCLUDING ALL);


--
-- Name: equipment_runtime_shift_1week; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE IF NOT EXISTS public.equipment_runtime_shift_1week (LIKE public.equipment_runtime_shift INCLUDING ALL);


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
    active boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone
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
-- Name: hist_equipment_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hist_equipment_events (
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
    cd_category_client integer,
    cd_subcategory_client integer,
    last_update timestamp with time zone,
    ignore_cost boolean
);


--
-- Name: hist_equipment_values; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hist_equipment_values (
    id_equipment integer,
    ts_value timestamp with time zone,
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
    check_number bigint
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
-- Name: hist_user_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hist_user_logs (
    id_user_logs bigint,
    ts_event timestamp with time zone,
    id_enterprise integer,
    id_site integer,
    id_area integer,
    id_equipment integer,
    nm_user character varying(255),
    cd_user integer,
    category character varying(255),
    subcategory character varying(255),
    description text,
    ts_log timestamp with time zone,
    ip character varying(255),
    payload jsonb
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
    id_rejectcounter integer,
    active boolean,
    attributed boolean,
    id_unit integer,
    line_unit_seq character varying,
    device_nm character varying
);


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
    CONSTRAINT production_orders_speed_check CHECK (((ideal_production_speed IS NULL) OR (ideal_production_speed > 0))),
    CONSTRAINT production_orders_ts_start_ts_end CHECK ((((ts_start < ts_end) AND (status = ANY (ARRAY[3, 4]))) OR ((status = 1) AND (ts_start IS NULL)) OR ((status = 1) AND (ts_end IS NULL)) OR ((status = 2) AND (ts_start IS NOT NULL))))
);


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
    multiplier double precision
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02', autovacuum_vacuum_threshold='5000', autovacuum_analyze_threshold='5000');


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
-- Name: report_shift_enterprise_06; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.report_shift_enterprise_06 (
    ts_value timestamp with time zone,
    valor integer
);


--
-- Name: report_speed_enterprise_33; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.report_speed_enterprise_33 (
    ts_value timestamp with time zone,
    valor integer
);


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
-- Name: site_runtime_1day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_runtime_1day (
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
-- Name: site_runtime_1hour; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_runtime_1hour (
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
-- Name: site_runtime_1month; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_runtime_1month (
    ts_value date NOT NULL,
    id_site integer NOT NULL,
    oee real,
    recalc_needed boolean DEFAULT true,
    oee_p real,
    oee_a real,
    oee_q real,
    available_time bigint,
    running_time bigint,
    stopped_time bigint,
    planned_downtime bigint,
    ideal_production double precision,
    idle_time bigint,
    idle_starved bigint,
    idle_blocked bigint,
    target double precision,
    gross real,
    net real,
    downtime bigint,
    changeover_time bigint,
    scrap real,
    speed real,
    proportional_target double precision,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
);


--
-- Name: site_runtime_1week; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_runtime_1week (
    ts_value date NOT NULL,
    id_site integer NOT NULL,
    oee real,
    recalc_needed boolean DEFAULT true,
    oee_p real,
    oee_a real,
    oee_q real,
    available_time bigint,
    running_time bigint,
    stopped_time bigint,
    planned_downtime bigint,
    ideal_production double precision,
    idle_time bigint,
    idle_starved bigint,
    idle_blocked bigint,
    target double precision,
    gross real,
    net real,
    downtime bigint,
    changeover_time bigint,
    scrap real,
    speed real,
    proportional_target double precision,
    computed_at timestamp with time zone,
    source_watermark timestamp with time zone
);


--
-- Name: site_runtime_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_runtime_shift (
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
    source_watermark timestamp with time zone
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
-- Name: uns_area_current_day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_area_current_day (
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
-- Name: uns_area_current_hour; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_area_current_hour (
    id_area integer NOT NULL,
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
    last_24_hours jsonb
);


--
-- Name: uns_area_current_month; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_area_current_month (
    id_area integer NOT NULL,
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
    proportional_ideal_production real
);


--
-- Name: uns_area_current_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_area_current_shift (
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
-- Name: uns_area_current_week; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_area_current_week (
    id_area integer NOT NULL,
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
    proportional_ideal_production real
);


--
-- Name: uns_equipment_current_day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_equipment_current_day (
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
-- Name: uns_equipment_current_hour; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_equipment_current_hour (
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
-- Name: uns_equipment_current_job; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_equipment_current_job (
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
-- Name: uns_equipment_current_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_equipment_current_metrics (
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
-- Name: uns_equipment_current_month; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_equipment_current_month (
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
-- Name: uns_equipment_current_shift; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_equipment_current_shift (
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
-- Name: uns_equipment_current_week; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_equipment_current_week (
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
-- Name: uns_site_current_day; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_site_current_day (
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
-- Name: uns_site_current_hour; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_site_current_hour (
    id_site integer NOT NULL,
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
    last_24_hours jsonb
);


--
-- Name: uns_site_current_month; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_site_current_month (
    id_site integer NOT NULL,
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
    proportional_ideal_production real
);


--
-- Name: uns_site_current_week; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.uns_site_current_week (
    id_site integer NOT NULL,
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
    proportional_ideal_production real
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
    active boolean DEFAULT true
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
    v.sites,
    v.areas,
    v.lines,
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
     JOIN public.equipment_runtime_shift shift ON ((eventos.id_equipment = shift.id_equipment)))
     JOIN public.equipments e ON ((eventos.id_equipment = e.id_equipment)))
     JOIN public.production_orders po ON ((eventos.id_equipment = po.id_equipment)))
     JOIN public.production_orders_runtime por ON ((po.id_production_order = por.id_production_order)))
  WHERE ((eventos.status = 10) AND (e.event_should_be_displayed = true) AND (eventos.ts_event >= lower(shift.ts_range)) AND (eventos.ts_event <= upper(shift.ts_range)) AND (eventos.duration >= e.stop_threshold_time) AND (por.runtime_timerange @> lower(shift.ts_range)));


--
-- Name: areas id_area; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas ALTER COLUMN id_area SET DEFAULT nextval('public.areas_id_area_seq'::regclass);


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
-- Name: area_runtime_1day area_runtime_1day_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_runtime_1day
    ADD CONSTRAINT area_runtime_1day_pk PRIMARY KEY (id_area, ts_value);


--
-- Name: area_runtime_1hour area_runtime_1hour_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_runtime_1hour
    ADD CONSTRAINT area_runtime_1hour_pk PRIMARY KEY (id_area, ts_value);


--
-- Name: area_runtime_1month area_runtime_1month_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_runtime_1month
    ADD CONSTRAINT area_runtime_1month_pk PRIMARY KEY (id_area, ts_value);


--
-- Name: area_runtime_1week area_runtime_1week_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_runtime_1week
    ADD CONSTRAINT area_runtime_1week_pk PRIMARY KEY (id_area, ts_value);


--
-- Name: area_runtime_shift area_runtime_shift_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.area_runtime_shift
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
-- Name: equipment_runtime_1day equipment_runtime_1day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_1day
    ADD CONSTRAINT equipment_runtime_1day_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_runtime_1hour equipment_runtime_1hour_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_1hour
    ADD CONSTRAINT equipment_runtime_1hour_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_runtime_1month equipment_runtime_1month_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_1month
    ADD CONSTRAINT equipment_runtime_1month_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_runtime_1week equipment_runtime_1week_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_1week
    ADD CONSTRAINT equipment_runtime_1week_pkey PRIMARY KEY (id_equipment, ts_value);


--
-- Name: equipment_runtime_shift equipment_runtime_shift_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_shift
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
-- Name: label_formats label_formats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.label_formats
    ADD CONSTRAINT label_formats_pkey PRIMARY KEY (id_enterprise, label_key);


--
-- Name: language_packs language_packs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.language_packs
    ADD CONSTRAINT language_packs_pkey PRIMARY KEY (language_tag);


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
-- Name: shift_hours shift_hours_un; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shift_hours
    ADD CONSTRAINT shift_hours_un UNIQUE (begin_time, end_time, id_site, id_area, id_equipment);


--
-- Name: shifts shifts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shifts
    ADD CONSTRAINT shifts_pkey PRIMARY KEY (id_shift);


--
-- Name: site_runtime_1day site_runtime_1day_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_runtime_1day
    ADD CONSTRAINT site_runtime_1day_pk PRIMARY KEY (id_site, ts_value);


--
-- Name: site_runtime_1hour site_runtime_1hour_pk_1; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_runtime_1hour
    ADD CONSTRAINT site_runtime_1hour_pk_1 PRIMARY KEY (id_site, ts_value);


--
-- Name: site_runtime_1month site_runtime_1month_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_runtime_1month
    ADD CONSTRAINT site_runtime_1month_pk PRIMARY KEY (id_site, ts_value);


--
-- Name: site_runtime_1week site_runtime_1week_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_runtime_1week
    ADD CONSTRAINT site_runtime_1week_pk PRIMARY KEY (id_site, ts_value);


--
-- Name: site_runtime_shift site_runtime_shift_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_runtime_shift
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
-- Name: users uid_firebase_un; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uid_firebase_un UNIQUE (id_user_firebase);


--
-- Name: uns_area_current_day uns_area_current_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_area_current_day
    ADD CONSTRAINT uns_area_current_day_pkey PRIMARY KEY (id_area);


--
-- Name: uns_area_current_hour uns_area_current_hour_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_area_current_hour
    ADD CONSTRAINT uns_area_current_hour_pkey PRIMARY KEY (id_area);


--
-- Name: uns_area_current_month uns_area_current_month_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_area_current_month
    ADD CONSTRAINT uns_area_current_month_pkey PRIMARY KEY (id_area);


--
-- Name: uns_area_current_shift uns_area_current_shift_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_area_current_shift
    ADD CONSTRAINT uns_area_current_shift_pkey PRIMARY KEY (id_area);


--
-- Name: uns_area_current_week uns_area_current_week_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_area_current_week
    ADD CONSTRAINT uns_area_current_week_pkey PRIMARY KEY (id_area);


--
-- Name: uns_equipment_current_day uns_equipment_current_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_day
    ADD CONSTRAINT uns_equipment_current_day_pkey PRIMARY KEY (id_equipment);


--
-- Name: uns_equipment_current_hour uns_equipment_current_hour_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_hour
    ADD CONSTRAINT uns_equipment_current_hour_pkey PRIMARY KEY (id_equipment);


--
-- Name: uns_equipment_current_job uns_equipment_current_job_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_job
    ADD CONSTRAINT uns_equipment_current_job_pkey PRIMARY KEY (id_equipment);


--
-- Name: uns_equipment_current_metrics uns_equipment_current_metrics_id_equipment_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_metrics
    ADD CONSTRAINT uns_equipment_current_metrics_id_equipment_key UNIQUE (id_equipment);


--
-- Name: uns_equipment_current_metrics uns_equipment_current_metrics_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_metrics
    ADD CONSTRAINT uns_equipment_current_metrics_pk PRIMARY KEY (id_equipment);


--
-- Name: uns_equipment_current_month uns_equipment_current_month_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_month
    ADD CONSTRAINT uns_equipment_current_month_pkey PRIMARY KEY (id_equipment);


--
-- Name: uns_equipment_current_shift uns_equipment_current_shift_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_shift
    ADD CONSTRAINT uns_equipment_current_shift_pkey PRIMARY KEY (id_equipment);


--
-- Name: uns_equipment_current_week uns_equipment_current_week_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_week
    ADD CONSTRAINT uns_equipment_current_week_pkey PRIMARY KEY (id_equipment);


--
-- Name: uns_site_current_day uns_site_current_day_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_site_current_day
    ADD CONSTRAINT uns_site_current_day_pkey PRIMARY KEY (id_site);


--
-- Name: uns_site_current_hour uns_site_current_hour_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_site_current_hour
    ADD CONSTRAINT uns_site_current_hour_pkey PRIMARY KEY (id_site);


--
-- Name: uns_site_current_month uns_site_current_month_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_site_current_month
    ADD CONSTRAINT uns_site_current_month_pkey PRIMARY KEY (id_site);


--
-- Name: uns_site_current_week uns_site_current_week_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_site_current_week
    ADD CONSTRAINT uns_site_current_week_pkey PRIMARY KEY (id_site);


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
-- Name: clients_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX clients_id_enterprise_idx ON public.clients USING btree (id_enterprise);


--
-- Name: data_quality_event_dedup_un; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX data_quality_event_dedup_un ON public.data_quality_event USING btree (id_enterprise, COALESCE(id_equipment, 0), grain, bucket_ts, rule);


--
-- Name: data_quality_event_ent_detected_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX data_quality_event_ent_detected_idx ON public.data_quality_event USING btree (id_enterprise, detected_at DESC);


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
-- Name: equipment_events_man_ts_event_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX equipment_events_man_ts_event_key ON public.equipment_events_man USING btree (ts_event);


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

CREATE INDEX equipment_runtime_1hour_id_equipment_idx ON public.equipment_runtime_1hour USING btree (id_equipment);


--
-- Name: equipment_runtime_1hour_ts_value_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_runtime_1hour_ts_value_idx ON public.equipment_runtime_1hour USING btree (ts_value DESC);


--
-- Name: equipment_runtime_shift_ts_range_id_equipment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_runtime_shift_ts_range_id_equipment_idx ON public.equipment_runtime_shift USING gist (id_equipment, ts_range);


--
-- Name: equipment_runtime_shift_ts_value_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_runtime_shift_ts_value_idx ON public.equipment_runtime_shift USING btree (ts_value DESC);


--
-- Name: equipment_scrap_reason_reason_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_scrap_reason_reason_idx ON public.equipment_scrap_reason USING btree (id_reason);


--
-- Name: equipment_values_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_enterprise_idx ON public.equipment_values USING btree (id_enterprise);


--
-- Name: equipment_values_id_equipment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_idx ON public.equipment_values USING btree (id_equipment, ts_value);


--
-- Name: equipment_values_id_equipment_ts_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC);


--
-- Name: equipment_values_id_equipment_ts_value_conversion_factor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_conversion_factor_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, conversion_factor) WHERE (conversion_factor IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_id_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_id_order_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, id_order) WHERE (id_order IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_id_production_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_id_production_order_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, id_production_order) WHERE (id_production_order IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_id_shift_hour_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_id_shift_hour_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, id_shift_hour) WHERE (id_shift_hour IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_id_shift_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_id_shift_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, id_shift) WHERE (id_shift IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_id_team_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_id_team_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, id_team) WHERE (id_team IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_ideal_production_speed_i; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_ideal_production_speed_i ON public.equipment_values USING btree (id_equipment, ts_value DESC, ideal_production_speed) WHERE (ideal_production_speed IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_mode_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_mode_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, mode) WHERE (mode IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_number_cavities_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_number_cavities_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, number_cavities) WHERE (number_cavities IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_signal_quality_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_signal_quality_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, signal_quality) WHERE (signal_quality IS NOT NULL);


--
-- Name: equipment_values_id_equipment_ts_value_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_equipment_ts_value_state_idx ON public.equipment_values USING btree (id_equipment, ts_value DESC, state) WHERE (state IS NOT NULL);


--
-- Name: equipment_values_id_production_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX equipment_values_id_production_order_idx ON public.equipment_values USING btree (id_production_order) WHERE (id_production_order IS NOT NULL);


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
-- Name: idx_er1d_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1d_equipment ON public.equipment_runtime_1day USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_er1d_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1d_recalc ON public.equipment_runtime_1day USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_er1h_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1h_equipment ON public.equipment_runtime_1hour USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_er1h_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1h_recalc ON public.equipment_runtime_1hour USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_er1mo_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1mo_equipment ON public.equipment_runtime_1month USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_er1mo_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1mo_recalc ON public.equipment_runtime_1month USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_er1w_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1w_equipment ON public.equipment_runtime_1week USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_er1w_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_er1w_recalc ON public.equipment_runtime_1week USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_ers_equipment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ers_equipment ON public.equipment_runtime_shift USING btree (id_equipment, ts_value DESC);


--
-- Name: idx_ers_recalc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ers_recalc ON public.equipment_runtime_shift USING btree (recalc_needed) WHERE (recalc_needed = true);


--
-- Name: idx_ers_shift; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ers_shift ON public.equipment_runtime_shift USING btree (id_shift);


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
-- Name: scrap_reason_code_active_un; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX scrap_reason_code_active_un ON public.scrap_reason USING btree (id_enterprise, code) WHERE active;


--
-- Name: sites_history_key_valid_from_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sites_history_key_valid_from_idx ON public.sites_history USING btree (id_site, valid_from);


--
-- Name: uq_box_scans_po_label; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_box_scans_po_label ON public.box_scans USING btree (id_production_order, label_seq) WHERE (scan_type = 'production'::text);


--
-- Name: uq_box_scans_scan_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_box_scans_scan_uuid ON public.box_scans USING btree (scan_uuid);


--
-- Name: user_screen_config_tenant_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_screen_config_tenant_key ON public.user_screen_config USING btree (id_enterprise, id_user, screen);


--
-- Name: users_id_enterprise_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_id_enterprise_idx ON public.users USING btree (id_enterprise);


--
-- Name: box_scans trg_box_scans_no_mutate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_box_scans_no_mutate BEFORE DELETE OR UPDATE ON public.box_scans FOR EACH ROW EXECUTE FUNCTION public.box_scans_no_mutate();


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
-- Name: equipment_runtime_1day fk_ert1day_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_1day
    ADD CONSTRAINT fk_ert1day_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_runtime_1hour fk_ert1hour_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_1hour
    ADD CONSTRAINT fk_ert1hour_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_runtime_1month fk_ert1month_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_1month
    ADD CONSTRAINT fk_ert1month_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_runtime_1week fk_ert1week_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_1week
    ADD CONSTRAINT fk_ert1week_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: equipment_runtime_shift fk_ertshift_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_runtime_shift
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
-- Name: uns_area_current_week fk_uacw_area; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_area_current_week
    ADD CONSTRAINT fk_uacw_area FOREIGN KEY (id_area) REFERENCES public.areas(id_area);


--
-- Name: uns_equipment_current_day fk_uecd_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_day
    ADD CONSTRAINT fk_uecd_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: uns_equipment_current_month fk_uecmo_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_month
    ADD CONSTRAINT fk_uecmo_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: uns_equipment_current_shift fk_uecs_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_shift
    ADD CONSTRAINT fk_uecs_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- Name: uns_equipment_current_week fk_uecw_equipment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_week
    ADD CONSTRAINT fk_uecw_equipment FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


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
-- Name: uns_equipment_current_job uns_equipment_current_job_id_equipment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.uns_equipment_current_job
    ADD CONSTRAINT uns_equipment_current_job_id_equipment_fkey FOREIGN KEY (id_equipment) REFERENCES public.equipments(id_equipment);


--
-- PostgreSQL database dump complete
--

\unrestrict Psvd81LZIgPS5EhIMAMzAjvJchVlEpfO4Dd9urO8GwzduLOFga8KvHHbsb61yew

