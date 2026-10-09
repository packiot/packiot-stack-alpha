-- t283 rollback — move the three target tables config → core and restore the
-- original core.scrap_targets qualification in h_piot_set_scrap_target.
-- Reversible, catalog-only (SET SCHEMA keeps OIDs → views/FKs stay valid).

BEGIN;

ALTER TABLE config.oee_targets        SET SCHEMA core;
ALTER TABLE config.scrap_targets      SET SCHEMA core;
ALTER TABLE config.production_targets SET SCHEMA core;

CREATE OR REPLACE FUNCTION public.h_piot_set_scrap_target(in_id_enterprise integer, in_id_equipment integer, proportional boolean DEFAULT true, in_target_day integer DEFAULT NULL::integer, in_target_week integer DEFAULT NULL::integer, in_target_month integer DEFAULT NULL::integer, in_target_shift integer DEFAULT NULL::integer, in_target_hour integer DEFAULT NULL::integer)
 RETURNS SETOF scrap_targets
 LANGUAGE plpgsql
AS $function$
begin

IF proportional THEN
	return query
	with shifts_h as (select * from piot_get_shift_hour_list_by_equipment(in_id_enterprise, in_id_equipment)),
	days_week as (select count(*) from (select distinct day_week from shifts_h) aa),
	hours_day as (select sum(shift_size)/3600 as hours_day from shifts_h group by day_number order by day_number limit 1),
	shift_per_day as (select count(*) from (select distinct id_shift from shifts_h) aa)
	INSERT INTO core.scrap_targets
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
	on conflict (id_equipment, id_site)
	DO UPDATE set
	vl_day = EXCLUDED.vl_day,
	vl_week = EXCLUDED.vl_week,
	vl_month = EXCLUDED.vl_month,
	vl_shift = EXCLUDED.vl_shift,
	vl_hour = EXCLUDED.vl_hour
	returning id_site, vl_day, vl_week, vl_month, id_equipment, id_enterprise, id_area, vl_shift, vl_hour;

else
	return query
	INSERT INTO core.scrap_targets
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
	from equipments e
	where id_equipment = in_id_equipment
	on conflict (id_equipment, id_site)
	DO UPDATE set
	vl_day = EXCLUDED.vl_day,
	vl_week = EXCLUDED.vl_week,
	vl_month = EXCLUDED.vl_month,
	vl_shift = EXCLUDED.vl_shift,
	vl_hour = EXCLUDED.vl_hour
	returning *;

END IF;
end
$function$;

COMMIT;
