-- t283 — evict configuration tables out of core → config
--
-- WHY: core is the DOMAIN schema (enterprises, sites, areas, equipments, shifts,
-- production_orders …). oee_targets / scrap_targets / production_targets are
-- CONFIGURATION rows a CS engineer sets during onboarding, not domain entities —
-- they belong in the existing `config` schema (symmetric with client_descriptors).
--
-- SAFETY (all traced against live staging packiot_analytics, 2026-09-14):
--   * config is ALREADY on the DB-level default search_path for ALL roles
--     (pg_db_role_setting setrole=NULL): "…, config, ops, serving, …, core, public"
--     and config PRECEDES core — so every BARE-name reader/writer keeps resolving
--     (now to config instead of core). stream-engine RunProvision sets the same
--     path explicitly (provision.go). read-api/edge-api inherit the DB default.
--   * VIEWS + FKs bind by OID, not name → they survive SET SCHEMA untouched:
--       - bi.production_targets (SELECT … FROM production_targets) → stays valid
--       - fk_prodtgt_equipment (production_targets.id_equipment → equipments) →
--         cross-schema FK config→core is legal and stays VALIDATED.
--   * The ONLY schema-qualified reference in any routine body is
--     h_piot_set_scrap_target's two `INSERT INTO core.scrap_targets` — repointed
--     below. Every other routine (h_piot_set_production_target,
--     piot_create_equipment_oee_{hourly,shift}, serving.machine_speed,
--     serving.mission_control_area, serving.single_period_by_team[_v4]) uses BARE
--     names → search_path handles them.
--   * read-api datasets (targets group) use BARE names → unaffected.
--   * NO public.* shim exists for these tables (port-parity's public.production_targets
--     ref is already-dead harness code, not a live consumer).
--
-- Runtime custom-target tables (equipment_runtime_1{day,week,month}) are a DIFFERENT
-- family and are NOT touched.
--
-- Atomic: SET SCHEMA + function repoint in one tx.

BEGIN;

ALTER TABLE core.oee_targets        SET SCHEMA config;
ALTER TABLE core.scrap_targets      SET SCHEMA config;
ALTER TABLE core.production_targets SET SCHEMA config;

-- Repoint the sole schema-qualified writer. Body identical to the pre-move
-- definition except `core.scrap_targets` → `config.scrap_targets` (x2).
-- RETURNS SETOF scrap_targets (bare) resolves to config.scrap_targets (same OID
-- as before the move) so the return type is unchanged and REPLACE succeeds.
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
	INSERT INTO config.scrap_targets
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
	INSERT INTO config.scrap_targets
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
