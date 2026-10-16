-- Fixture for run.sh: the objects the operator Events functions read, with the column types of the dev seed
-- (ghcr.io/packiot/devseed:2026-10-14 = staging's schema, generated from pg_attribute; constraints omitted) and the
-- LIVE calendar helpers (pg_get_functiondef of the same seed). core.packml_register is a view over topic_routing on
-- staging; here a plain table with the columns the functions read.
CREATE SCHEMA core; CREATE SCHEMA silver; CREATE SCHEMA gold; CREATE SCHEMA serving;
DO $$ BEGIN
  CREATE ROLE readapi_ro; CREATE ROLE superset_ro; CREATE ROLE bi_owner; CREATE ROLE prod_reflector;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE TABLE core.areas (
  id_area integer,
  nm_area character varying(255),
  id_infeedcounter integer,
  id_outfeedcounter integer,
  id_rejectscounter integer,
  id_site integer,
  week_begin integer,
  day_begin integer,
  week_size integer,
  id_enterprise integer,
  active boolean,
  valid_from timestamp with time zone,
  valid_to timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone
);
CREATE TABLE core.enterprises (
  id_enterprise integer,
  nm_enterprise character varying(255),
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
  valid_from timestamp with time zone,
  valid_to timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone
);
CREATE TABLE core.equipments (
  id_equipment integer,
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
  active boolean,
  valid_from timestamp with time zone,
  valid_to timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  gross_machine bigint,
  scrap_machine bigint,
  exclude_idle_from_availability boolean,
  idle_timeout_seconds integer,
  downtime_from_lead_machine boolean,
  net_machine bigint,
  gross_counter text,
  net_counter text,
  fill_missing_meter boolean
);
CREATE TABLE core.production_orders (
  id_production_order bigint,
  id_enterprise integer,
  id_site integer,
  id_area integer,
  id_equipment integer,
  id_product integer,
  id_client integer,
  status integer,
  production_programmed bigint,
  production_ordered bigint,
  id_order integer,
  id_user_operator integer,
  id_equipment_executed integer,
  production_real bigint,
  production_final bigint,
  ts_start timestamp with time zone,
  ts_end timestamp with time zone,
  equipment_setup jsonb,
  oee_processed boolean,
  oee real,
  stopped_time integer,
  planned_downtime integer,
  qt_stops integer,
  erp_processed boolean,
  ts_creation timestamp with time zone,
  txt_production_order_notes character varying(255),
  txt_production_order_description character varying(255),
  conversion_factor real,
  net_production double precision,
  speed real,
  ideal_production_speed integer,
  id_order_text character varying(255),
  recalc_needed boolean,
  last_update timestamp with time zone,
  nm_production_order character varying,
  multiplier double precision,
  gross_production double precision,
  available_time double precision,
  running_time double precision,
  custom_field jsonb,
  ideal_production integer,
  ts_start_tz timestamp with time zone,
  ts_end_tz timestamp with time zone,
  id_label bigint,
  oee_q double precision,
  oee_a double precision,
  oee_p double precision,
  po_uuid uuid
);
CREATE TABLE core.shift_hours (
  id_shift_hour integer,
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
CREATE TABLE core.sites (
  id_site integer,
  nm_site character varying(255),
  id_enterprise integer,
  week_begin integer,
  day_begin integer,
  timezone character varying(255),
  language_tag character varying(255),
  week_size integer,
  email_alert_users jsonb,
  active boolean,
  valid_from timestamp with time zone,
  valid_to timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone
);
CREATE TABLE gold.production_orders_runtime (
  id_production_order bigint,
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
  multiplier double precision,
  no_data_time integer,
  out_of_service_time integer
);
CREATE TABLE silver.equipment_events (
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
  ignore_cost boolean,
  ingested_at timestamp with time zone,
  source_seq bigint
);
CREATE TABLE silver.equipment_events_low_speed (
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
CREATE TABLE silver.equipment_events_man (
  id_equipment integer,
  ts_event timestamp with time zone,
  status integer,
  id_equipment_event integer,
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
  last_update timestamp with time zone,
  ignore_cost boolean
);
CREATE TABLE core.packml_register (packml_topic varchar, id_equipment integer, id_unit integer, active boolean DEFAULT true,
  id_enterprise integer);
CREATE TYPE serving.pending_downtime_row AS (id_equipment_event bigint, ts_event timestamptz, ts_end timestamptz,
  duration integer, id_equipment integer, id_enterprise integer, packml_topic varchar);
CREATE TYPE serving.events_timeline_row AS (id_equipment_event bigint, ts_event timestamptz, ts_end timestamptz,
  duration integer, id_equipment integer, id_enterprise integer, txt_downtime_notes varchar, cd_machine varchar,
  cd_category varchar, cd_subcategory varchar, change_over boolean, desc_category varchar, desc_subcategory varchar,
  packml_topic varchar, event_type text, id_order_text varchar, id_production_order bigint,
  production_programmed bigint, custom_field jsonb);
CREATE OR REPLACE FUNCTION public.piot_get_day_begin_by_equipment(in_id_equipment integer, in_ts_value timestamp with time zone)
 RETURNS TABLE(ts_value timestamp with time zone, ts_value_production date)
 LANGUAGE plpgsql
 STABLE
AS $function$
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
$function$

;
CREATE OR REPLACE FUNCTION public.piot_get_shift_hour_begin_by_equipment(in_id_equipment integer, ts_value timestamp with time zone)
 RETURNS TABLE(ts_begin timestamp with time zone, ts_end timestamp with time zone, shift_size integer, ts_range tstzrange, id_shift integer, id_shift_hour integer)
 LANGUAGE plpgsql
 STABLE
AS $function$
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
    v_week_base + sh.begin_time * interval '1 second' + coalesce(sh.shift_size, sh.end_time - sh.begin_time) * interval '1 second',
    coalesce(sh.shift_size, sh.end_time - sh.begin_time),
    tstzrange(v_week_base + sh.begin_time * interval '1 second',
              v_week_base + sh.begin_time * interval '1 second' + coalesce(sh.shift_size, sh.end_time - sh.begin_time) * interval '1 second'),
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
$function$

;
