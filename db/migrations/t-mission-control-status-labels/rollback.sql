-- Rollback t-mission-control-status-labels: restore status_24h to the raw
-- equipment_live_metrics passthrough (re-greys front4 Mission Control — only use
-- if the label change causes a problem). Every other column is unchanged.

CREATE OR REPLACE FUNCTION serving.mission_control(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text)
 RETURNS SETOF mission_control_row
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
	ids_sites int[] := (select array_agg(id_site)
						from sites s
						where s.id_enterprise=in_id_enterprise
						and case when cardinality(in_ids_sites::int[]) = 0 then true else id_site = any( in_ids_sites::int[]) end);
	ids_areas int[] := (select array_agg(id_area)
						from areas s
						where s.id_enterprise=in_id_enterprise
						and case when cardinality(in_ids_areas::int[]) = 0 then true else id_area = any( in_ids_areas::int[]) end);
	ids_equips int[] := (select array_agg(id_equipment)
						from equipments s
						where s.id_enterprise=in_id_enterprise and s.tp_equipment=3
						and case when cardinality(in_ids_equipments::int[]) = 0 then true else id_equipment = any( in_ids_equipments::int[]) end);
begin
return query
   select
	uecm.id_site, uecm.id_area, uecm.nm_area,
		uecm.id_equipment AS id_line, uecm.nm_equipment AS nm_line, uecm.id_enterprise,
		uecs.oee AS currshift_oee, uecs.shift_name AS curr_shift_name, uecs.prev1_shift_name, uecs.prev2_shift_name,
		uecj.id_order, uecj.target AS production_programmed, uecj.net_production AS po_net_production, uecj.nm_client,
		uecj.elapsed_time AS duration, uecj.current_expected_time AS expected_time, uecm.speed::real,
		uecs.gross_production AS curshift_grosprod, uecs.net_production AS curshift_netprod,
		uecs.prev1_net_production AS prev1shift_netprod, uecs.prev2_net_production AS prev2shift_netprod,
		uecs.scrap AS curshift_scrap, uecs.planned_downtime,
		uecm.planned_perc_stops_24h as planned_duration_percent, uecs.change_over_duration,
		uecm.change_over_perc_stops_24h as change_over_duration_percent, uecs.unplanned_downtime as unplanned_duration,
		uecm.unplanned_perc_stops_24h as unplanned_duration_percent, uecs.stopped_time,
		uecm.status_24h,
		uecm.status, uecm.status_time,
		uecs.proportional_target, uecs.prev1_target, uecs.prev2_target,
		uecj.current_expected_time::float8 as job_remaining_time
	from equipment_live_job uecj
	join equipment_live_shift uecs on (uecs.id_equipment=uecj.id_equipment)
	join equipment_live_metrics uecm on (uecm.id_equipment=uecj.id_equipment)
	where uecm.id_site = any (ids_sites) and uecm.id_area = any (ids_areas) and uecm.id_equipment = any (ids_equips);
	end
$function$;
