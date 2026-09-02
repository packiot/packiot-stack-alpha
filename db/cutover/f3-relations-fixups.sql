-- =============================================================================
-- F3 (packiot_analytics) relation / index / function fixups
-- =============================================================================
-- Target DB: packiot_analytics (F3, single-plane staging).
-- Property: ADDITIVE ONLY. Never touches telemetry (equipment_values, caggs, uns_*
--           data). Safe to re-run: every statement is CREATE OR REPLACE / IF NOT
--           EXISTS / idempotent.
--
-- Fixes three cutover gaps found by the F3 audit:
--   H2  production_information relation missing  -> edge-api GET
--       /api/production-orders/current 500s.
--   H5  equipment_events_man has a GLOBAL ts_event unique instead of per-equipment
--       -> legacy replicator ON CONFLICT (ts_event) silently drops same-minute
--       cross-line manual events.
--   M4  three h_piot_* reporting functions return 0 rows for tenants that have data.
--
-- Applied + verified live on staging (i-06c9547a2c7091ab7) against ent 3 (CPACK).
-- =============================================================================

-- =============================================================================
-- H2 — production_information view (edge-api /api/production-orders/current)
-- -----------------------------------------------------------------------------
-- ProductionInformationDAO runs `SELECT * FROM production_information
-- WHERE id_enterprise=$1 AND id_equipment=$2`. The relation did not exist in F3
-- (nor in F1 packiot — there was no original to port), so the endpoint 500'd for
-- any equipment with a running PO.
--
-- The endpoint merges the running order (production_orders) with live current-shift
-- metrics. Reconstructed from the endpoint/DTO contract
-- (CurrentProductionOrderOutputDto: total_produced, total_rejected, oee,
-- shift_start, shift_end) using the live current-shift snapshot
-- uns_equipment_current_shift, joined to equipments for id_enterprise.
-- =============================================================================
CREATE OR REPLACE VIEW public.production_information AS
SELECT
    e.id_enterprise,
    ucs.id_equipment,
    ucs.gross_production::double precision AS total_produced,
    ucs.scrap::double precision           AS total_rejected,
    ucs.oee,
    ucs.begin_time                        AS shift_start,
    ucs.end_time                          AS shift_end
FROM uns_equipment_current_shift ucs
JOIN equipments e ON e.id_equipment = ucs.id_equipment;

COMMENT ON VIEW public.production_information IS
  'F3 cutover fixup H2: per-equipment live current-shift metrics for edge-api '
  'GET /api/production-orders/current. Reconstructed from endpoint/DTO contract '
  '(no F1 original existed). Source: uns_equipment_current_shift + equipments.';


-- =============================================================================
-- H5 — equipment_events_man per-equipment uniqueness
-- -----------------------------------------------------------------------------
-- F3 carried a GLOBAL unique index equipment_events_man_ts_event_key ON (ts_event)
-- (drift: F1's real design made ts_event the PK; F3 moved PK to the surrogate
-- id_equipment_event but kept a bare global unique on ts_event). With a global
-- unique on ts_event, the legacy replicator's `ON CONFLICT (ts_event) DO NOTHING/
-- UPDATE` treats two different machines that stop in the same minute as a
-- conflict -> the second line's manual event is silently dropped/overwritten.
--
-- FIX: add the correct per-(id_equipment, ts_event) unique. Safe: ts_event was
-- globally unique so (id_equipment, ts_event) has no duplicates. No FK references
-- the old global unique (verified: pg_constraint confrelid lookup = 0 rows).
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.equipment_events_man'::regclass
      AND conname  = 'equipment_events_man_id_equipment_ts_event_key'
  ) THEN
    ALTER TABLE public.equipment_events_man
      ADD CONSTRAINT equipment_events_man_id_equipment_ts_event_key
      UNIQUE (id_equipment, ts_event);
  END IF;
END $$;

COMMENT ON CONSTRAINT equipment_events_man_id_equipment_ts_event_key
  ON public.equipment_events_man IS
  'F3 cutover fixup H5: correct per-equipment uniqueness. Replaces the incorrect '
  'global ts_event unique (equipment_events_man_ts_event_key) which silently '
  'dropped same-minute cross-line manual events. Repoint replicator ON CONFLICT '
  'to (id_equipment, ts_event); then drop the global unique (Step 2 below).';

-- --- Step 2 (COORDINATED — do NOT run standalone) --------------------------
-- The global unique MUST be dropped for the fix to take effect: while it exists,
-- a same-minute cross-line insert still collides on ts_event. BUT dropping it
-- before the replicator is repointed breaks the running replicator (its
-- `ON CONFLICT (ts_event)` would have no matching arbiter -> hard error).
-- Apply the following LINE TOGETHER WITH the replicator change that repoints
-- ON CONFLICT to (id_equipment, ts_event):
--
--   DROP INDEX IF EXISTS public.equipment_events_man_ts_event_key;
--
-- Left in place (not dropped) by this migration so it can be applied live without
-- breaking the currently-deployed replicator.


-- =============================================================================
-- M4 — h_piot_* functions returning 0 rows for tenants that have data
-- -----------------------------------------------------------------------------
-- Three reporting functions returned 0 rows for CPACK (ent 3) while sibling
-- functions returned data. Each had a different real root cause; all fixed to be
-- consistent with the working siblings and to stay tenant-scoped.
-- =============================================================================

-- M4.1 — h_piot_oee_score_full_3
-- Root cause: filtered directly on the raw input arrays
-- (`id_x = any(in_id_x::int[])`). With the common empty-array call `'{}'`,
-- `= any('{}')` matches nothing -> 0 rows. The function also never scoped by
-- in_id_enterprise, so a naive "empty => all" would leak cross-tenant.
-- Fix (mirrors sibling h_piot_oee_score_with_teams): resolve tenant-scoped
-- ids_sites/ids_areas/ids_equips in a declare block (empty input => all WITHIN
-- the tenant) and filter downstream on those resolved arrays.
CREATE OR REPLACE FUNCTION public.h_piot_oee_score_full_3(in_id_enterprise integer, in_id_equipments text, in_id_areas text, in_id_sites text, in_ids_shifts text, in_begin_time timestamp with time zone, in_end_time timestamp with time zone, time_grain text DEFAULT 'DAY'::text, nav_level text DEFAULT 'EQUIPMENT'::text, is_shift_filtered boolean DEFAULT false)
 RETURNS SETOF h_piot_oee_score_full_table
 LANGUAGE plpgsql
 STABLE
AS $function$
declare 
	child_nav_level varchar := (
								select 
									case nav_level 
										when 'SITE' then 'AREA'
										when 'AREA' then 'EQUIPMENT'
										else NULL
									end
								);
	-- F3 cutover fixup M4: tenant-scoped scope arrays. Empty input array => "all within tenant"
	-- (mirrors sibling h_piot_oee_score_with_teams). Prevents `= any('{}')` matching nothing.
	ids_sites int[] := (select array_agg(id_site) from sites
						where id_enterprise = in_id_enterprise
							and (cardinality(in_id_sites::int[]) = 0 or id_site = any(in_id_sites::int[])));
	ids_areas int[] := (select array_agg(id_area) from areas
						where id_enterprise = in_id_enterprise
							and (cardinality(in_id_areas::int[]) = 0 or id_area = any(in_id_areas::int[])));
	ids_equips int[] := (select array_agg(id_equipment) from equipments
						where id_enterprise = in_id_enterprise
							and tp_equipment = 3
							and (cardinality(in_id_equipments::int[]) = 0 or id_equipment = any(in_id_equipments::int[])));
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
          where e.id_site = any(ids_sites)
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_area, ts_value_production ) e on (e.id_area = s.id_area
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_site = any(ids_sites) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
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
          where e.id_equipment = any(ids_equips)
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_equipment, ts_value_production ) e on (e.id_equipment = s.id_equipment
                                                          and e.ts_value_production = e.ts_value_production)
     where ent.id_area = any(ids_areas) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
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
          where e.id_equipment = any(ids_equips)
              and caevh.ts_value_production >= date_trunc('day',in_begin_time::timestamp)::date
              and caevh.ts_value_production < date_trunc('day',in_end_time::timestamp+ interval '1 day')::date
          group by e.id_equipment, ts_value_production ) e on (e.id_equipment = s.id_equipment
                                                          and e.ts_value_production = e.ts_value_production)
     where parent.id_equipment = any(ids_equips) -- here I use the piot_get_day_begin_by_site function to normalize by the production day
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
$function$

;

-- M4.2 — h_piot_get_mission_control_area_uns_2
-- Root cause: source table uns_area_current_shift is a fact snapshot whose
-- denormalized id_enterprise / id_site / nm_area columns are left NULL by the
-- worker (only id_area + metrics are populated). The old body filtered on the
-- snapshot's NULL id_site (`NULL = any(...)` => NULL => every row dropped) and
-- returned NULL enterprise/nm_area. Fix: join the canonical `areas` dimension by
-- id_area for those attributes and for tenant scoping; metrics stay from the
-- snapshot. (The empty-array handling in the declare block was already correct.)
CREATE OR REPLACE FUNCTION public.h_piot_get_mission_control_area_uns_2(in_id_enterprise integer, in_id_areas text, in_id_sites text)
 RETURNS SETOF h_piot_mission_control_area_uns_2
 LANGUAGE plpgsql
 STABLE
AS $function$
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
	-- F3 cutover fixup M4: uns_area_current_shift is a fact snapshot whose denormalized
	-- id_enterprise / id_site / nm_area columns are left NULL by the worker. The old body
	-- filtered on the snapshot's NULL id_site (NULL = any(...) => NULL => 0 rows) and returned
	-- NULL enterprise/nm_area. Join the canonical `areas` dimension by id_area for those
	-- attributes and for tenant scoping; keep metrics from the snapshot.
select
	a.id_enterprise,
	uacs.id_area,
	a.nm_area,
	uacs.gross_production,
	uacs.net_production,
	uacs.scrap,
	uacs.oee,
	uacs.target,
	uacs.net_production + ((uacs.net_production/nullif(uacs.running_time , 0)) * (uacs.duration - uacs.elapsed_time)) as projected_production,
	oeet.vl_shift
from
	uns_area_current_shift uacs
	join areas a on (a.id_area = uacs.id_area)
	left join oee_targets oeet on (uacs.id_area = oeet.id_area and oeet.id_equipment is null)
where
    a.id_enterprise = in_id_enterprise
    and a.id_site = any (ids_sites)
    and uacs.id_area = any (ids_areas);
end $function$
;

-- M4.3 — h_piot_get_downtimes_per_category
-- Root cause: the row-level WHERE kept uncategorized events only when
-- `duration < e.stop_threshold_time`, but stop_threshold_time is NULL for ALL
-- equipment in both F1 and F3 (never populated; column has no default). So
-- `duration < NULL` => NULL => every uncategorized stop was dropped and the
-- function returned 0 rows for EVERY tenant. Fix: treat an unconfigured (NULL)
-- threshold as "no upper bound" via coalesce(..., 'infinity') so uncategorized
-- microstops are kept (consistent with sibling
-- h_piot_get_downtimes_per_category_equipment_level_new_4, which never row-gates
-- on the threshold — it uses it only inside a sub-aggregate FILTER). The
-- negative-duration guard (duration > 0) and future configured thresholds are
-- preserved.
CREATE OR REPLACE FUNCTION public.h_piot_get_downtimes_per_category(in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_shifts text, _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()), _tsend timestamp without time zone DEFAULT now(), in_ids_teams text DEFAULT '{}'::text)
 RETURNS SETOF h_piot_get_downtimes_per_category_table
 LANGUAGE plpgsql
 STABLE
AS $function$
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
				-- F3 cutover fixup M4: stop_threshold_time is NULL for ALL equipment (F1 & F3),
				-- so `< NULL` => NULL => every uncategorized stop was dropped and the function
				-- returned 0 rows for every tenant. Treat an unconfigured (NULL) threshold as
				-- "no upper bound" so uncategorized microstops are kept (consistent with sibling
				-- h_piot_get_downtimes_per_category_equipment_level_new_4, which never row-gates on it).
				) < coalesce(e.stop_threshold_time, 'infinity'::double precision)
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
$function$
;
