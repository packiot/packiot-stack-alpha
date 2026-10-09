-- ============================================================================
-- Task #221 — serving.machine_speed CANONICAL REDESIGN (silver-backed, grain-aware)
-- ----------------------------------------------------------------------------
-- Replaces the FLAT 1-min view serving.machine_speed with a grain-aware SETOF
-- function that carries the shift/team dimension the front4 MachineSpeed page
-- needs (GENERAL / SHIFTS / TEAMS + HOUR / DAY grain), sourced from the SILVER
-- medallion — NOT from ca_agg_equipment_values_1hour.
--
--   HOUR grain  →  silver.equipment_categorical_1hour  (drop-in for the legacy
--                  ca_agg_equipment_values_1hour source: same id_shift/id_team/
--                  net|gross|scrap_incr/ts_value dims, plus DECOMPOSABLE speed
--                  via sum_speed/cnt_speed instead of a pre-averaged column).
--   DAY  grain  →  equipment_oee_shift  (canonical shift-grain OEE rows; the
--                  legacy DAY branch already read this — no ca_agg dependency).
--
-- Same return shape + arg signature as the legacy h_piot_machine_speed, so the
-- front4 MachineSpeed page (refdata `machine-speed` dataset) is UNCHANGED:
--   RETURNS SETOF (id_enterprise int, id_equipment int, nm_equipment varchar,
--                  info jsonb[])  where each info element is
--   { info_per_period:{net,gross,scrap,target,speed,speed_target},
--     info_per_shift_or_team:[ {id_shift,cd_shift,cd_team,id_team,net,gross,
--       scrap,scrap_percentage,scrap_target,target,speed,speed_target}, ... ],
--     ts_value:<timestamptz> }
--
-- INTENTIONAL CANONICAL FIXES vs the legacy function (documented for review):
--   1. HOUR source ca_agg_equipment_values_1hour → silver.equipment_categorical_1hour
--      (removes machine_speed's last dependency on the ca_agg cascade — the #221 goal).
--   2. HOUR window is bounded HALF-OPEN to [date_trunc('hour',from), to). The legacy
--      min_ts_prod/max_ts_prod logic leaked the ENTIRE next production-day (a 1-day
--      window returned 43 hourly periods spanning past the requested `to`); the clean
--      bound returns exactly the requested hours (24 for a full day).
--   3. HOUR per-shift/team speed = TRUE decomposable average sum(sum_speed)/sum(cnt_speed).
--      The legacy HOUR branch used a duration-weighted quirk `avg(duration*speed)/60`
--      (silver has no duration column); the DAY branch already used a plain average, so
--      this makes the two grains CONSISTENT.
--
-- Additive/expand: legacy public.h_piot_machine_speed is left LIVE until the new
-- path is proven + read-api is repointed + deployed. Rollback recreates the flat view.
-- ============================================================================

-- The flat 1-min view has ZERO db dependents and ZERO live repo consumers (only
-- unlanded worktrees) — verified via pg_depend/pg_rewrite. Drop it so the canonical
-- name serving.machine_speed resolves to the grain-aware function.
DROP VIEW IF EXISTS serving.machine_speed;

CREATE OR REPLACE FUNCTION serving.machine_speed(
    in_id_enterprise integer,
    in_id_sites      text,
    in_id_areas      text,
    in_id_equipments text,
    in_id_shifts     text,
    in_id_teams      text,
    in_begin_time    timestamptz,
    in_end_time      timestamptz,
    time_grain       text DEFAULT 'DAY',
    group_by_element text DEFAULT 'GENERAL'
)
RETURNS SETOF public.h_machine_speed
LANGUAGE plpgsql
STABLE
AS $function$
declare
    ids_sites int[] := (select array_agg(id_site)
                        from sites s
                        where s.id_enterprise = in_id_enterprise
                          and case when cardinality(in_id_sites::int[]) = 0 then true
                                   else id_site = any(in_id_sites::int[]) end);
    ids_areas int[] := (select array_agg(id_area)
                        from areas s
                        where s.id_enterprise = in_id_enterprise
                          and case when cardinality(in_id_areas::int[]) = 0 then true
                                   else id_area = any(in_id_areas::int[]) end);
    ids_equips int[] := (select array_agg(id_equipment)
                         from equipments s
                         where s.id_enterprise = in_id_enterprise
                           and s.tp_equipment = 3
                           and case when cardinality(in_id_equipments::int[]) = 0 then true
                                    else id_equipment = any(in_id_equipments::int[]) end);
    ids_shifts int[] := (
        select array_agg(id_shift) from shifts s
        where s.id_enterprise = in_id_enterprise
          and case
                when cardinality(string_to_array(in_id_shifts, ',')) = 0 then true
                when left(in_id_shifts, 1) != '{' then cd_shift = any(string_to_array(in_id_shifts, ',')::varchar[])
                else case
                        when replace(replace(in_id_shifts, '{', ''), '}', '') != ''
                        then id_shift = any(string_to_array(replace(replace(in_id_shifts, '{', ''), '}', ''), ',')::int[])
                        else true
                     end
              end);
    ids_teams int[] := (select array_agg(id_team)
                        from teams s
                        where s.id_enterprise = in_id_enterprise
                          and case when cardinality(in_id_teams::int[]) = 0 then true
                                   else id_team = any(in_id_teams::int[]) end);
begin
IF UPPER(time_grain) = 'HOUR' THEN
    RETURN QUERY
    select
        id_enterprise, id_equipment, nm_equipment,
        array_agg(jsonb_build_object(
            'info_per_period', info_per_period,
            'info_per_shift_or_team', info_per_shift,
            'ts_value', ts_value_production
        ) order by ts_value_production) as info
    from (
        select
            case when date_trunc('hour', now()) = ts_value then now() else ts_value end as ts_value_production,
            id_enterprise, id_equipment, nm_equipment,
            jsonb_build_object(
                'net',    sum(coalesce(net, 0))::float8,
                'gross',  sum(coalesce(gross, 0))::float8,
                'scrap',  sum(coalesce(scrap, 0))::float8,
                'target', sum(coalesce(target, 0))::int8,
                'speed',  case when sum(cnt_speed) > 0 then sum(sum_speed) / sum(cnt_speed) end,
                'speed_target', avg(ideal_speed)
            ) as info_per_period,
            array_agg(obj order by coalesce(shift_position, team_position)) as info_per_shift
        from (
            select
                case when date_trunc('hour', now()) = ers.ts_value then now() else ers.ts_value end::timestamptz as ts_value,
                ers.id_enterprise, e.id_equipment, e.nm_equipment,
                case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
                case group_by_element when 'TEAMS'  then t.sequence_position end as team_position,
                sum(coalesce(ers.net_production_incr, 0))   net,
                sum(coalesce(ers.gross_production_incr, 0)) gross,
                sum(coalesce(ers.scrap_incr, 0))            scrap,
                avg(coalesce(pt.vl_hour, 0))                target,
                sum(ers.sum_speed)                          sum_speed,
                sum(ers.cnt_speed)                          cnt_speed,
                avg(coalesce(ers.ideal_production_speed, e.production_speed, 0)) as ideal_speed,
                jsonb_build_object(
                    'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift end,
                    'cd_shift', case group_by_element when 'SHIFTS' then s.cd_shift end,
                    'cd_team',  case group_by_element when 'TEAMS'  then t.cd_team end,
                    'id_team',  case group_by_element when 'TEAMS'  then t.id_team end,
                    'net',   sum(coalesce(ers.net_production_incr, 0)),
                    'gross', sum(coalesce(ers.gross_production_incr, 0)),
                    'scrap', sum(coalesce(ers.scrap_incr, 0)),
                    'scrap_percentage', sum(coalesce(ers.scrap_incr, 0)) / nullif(sum(coalesce(ers.gross_production_incr, 0)), 0),
                    'scrap_target', avg(st.vl_shift),
                    'target', avg(coalesce(pt.vl_hour, 0)),
                    'speed', case when sum(ers.cnt_speed) > 0 then sum(ers.sum_speed) / sum(ers.cnt_speed) end,
                    'speed_target', avg(coalesce(ers.ideal_production_speed, e.production_speed, 0))
                ) obj
            from
                silver.equipment_categorical_1hour ers
                left join production_targets pt using (id_equipment)
                left join equipments e using (id_equipment)
                left join shifts s using (id_shift)
                left join teams t using (id_team)
                left join scrap_targets st on (ers.id_equipment = st.id_equipment)
            where
                ers.ts_value >= date_trunc('hour', in_begin_time)
                and ers.ts_value < in_end_time
                and ers.id_enterprise = in_id_enterprise
                and ers.id_area = any(ids_areas)
                and ers.id_site = any(ids_sites)
                and ers.id_equipment = any(ids_equips)
                and ers.id_shift = any(ids_shifts)
            group by
                ers.id_enterprise, ers.ts_value, e.id_equipment, e.nm_equipment,
                case group_by_element when 'SHIFTS' then ers.id_shift else null end,
                case group_by_element when 'SHIFTS' then s.cd_shift else null end,
                case group_by_element when 'SHIFTS' then s.sequence_position else null end,
                case group_by_element when 'TEAMS' then t.sequence_position else null end,
                t.id_team, t.cd_team
        ) aa
        group by ts_value, id_enterprise, id_equipment, nm_equipment order by ts_value
    ) s0
    group by id_enterprise, id_equipment, nm_equipment;

ELSE  -- DAY grain (canonical equipment_oee_shift; unchanged source, clean window)
    RETURN QUERY
    select
        id_enterprise, id_equipment, nm_equipment,
        array_agg(jsonb_build_object(
            'info_per_period', info_per_period,
            'info_per_shift_or_team', info_per_shift,
            'ts_value', ts_value_production
        ) order by ts_value_production) as info
    from (
        select
            case when date_trunc('day', now()) = date_trunc('day', ts_value_production) then now() else ts_value_production end as ts_value_production,
            id_enterprise, id_equipment, nm_equipment,
            jsonb_build_object(
                'net',    sum(coalesce(net, 0))::float8,
                'gross',  sum(coalesce(gross, 0))::float8,
                'scrap',  sum(coalesce(scrap, 0))::float8,
                'target', sum(coalesce(target, 0))::int8,
                'speed',  avg(speed),
                'speed_target', avg(ideal_speed)
            ) as info_per_period,
            array_agg(obj order by coalesce(shift_position, team_position)) as info_per_shift
        from (
            select
                date_trunc('day', ers.ts_value_production)::timestamptz as ts_value_production,
                e.id_enterprise, e.id_equipment, e.nm_equipment,
                case group_by_element when 'SHIFTS' then s.sequence_position end as shift_position,
                case group_by_element when 'TEAMS'  then t.sequence_position end as team_position,
                sum(coalesce(ers.net, 0))    net,
                sum(coalesce(ers.gross, 0))  gross,
                sum(coalesce(ers.scrap, 0))  scrap,
                sum(coalesce(ers.target, 0))::int8 target,
                avg(ers.speed) as speed,
                avg(coalesce(ers.ideal_speed, e.production_speed, 0)) as ideal_speed,
                jsonb_build_object(
                    'id_shift', case group_by_element when 'SHIFTS' then ers.id_shift end,
                    'cd_shift', case group_by_element when 'SHIFTS' then ers.cd_shift end,
                    'cd_team',  case group_by_element when 'TEAMS'  then t.cd_team end,
                    'id_team',  case group_by_element when 'TEAMS'  then t.id_team end,
                    'net',   sum(coalesce(ers.net, 0)),
                    'gross', sum(coalesce(ers.gross, 0)),
                    'scrap', sum(coalesce(ers.scrap, 0)),
                    'scrap_percentage', sum(coalesce(ers.scrap, 0)) / nullif(sum(coalesce(ers.gross, 0)), 0),
                    'scrap_target', avg(st.vl_shift),
                    'target', sum(coalesce(ers.target, 0)),
                    'speed', avg(coalesce(ers.speed, 0)),
                    'speed_target', avg(coalesce(ers.ideal_speed, e.production_speed, 0))
                ) obj
            from
                equipment_oee_shift ers
                join equipments e using (id_equipment)
                join shifts s using (id_shift)
                left join teams t using (id_team)
                left join scrap_targets st on (ers.id_equipment = st.id_equipment)
            where
                ers.ts_value >= date_trunc('day', in_begin_time)
                and ers.ts_value < in_end_time
                and e.id_enterprise = in_id_enterprise
                and e.id_area = any(ids_areas)
                and e.id_site = any(ids_sites)
                and e.id_equipment = any(ids_equips)
                and ers.id_shift = any(ids_shifts)
                and (ers.id_team is null or ers.id_team = any(ids_teams))
            group by
                e.id_enterprise, e.id_equipment, e.nm_equipment,
                date_trunc('day', ers.ts_value_production),
                case group_by_element when 'SHIFTS' then ers.id_shift else null end,
                case group_by_element when 'SHIFTS' then ers.cd_shift else null end,
                case group_by_element when 'SHIFTS' then s.sequence_position else null end,
                case group_by_element when 'TEAMS' then t.id_team else null end,
                case group_by_element when 'TEAMS' then t.cd_team else null end,
                case group_by_element when 'TEAMS' then t.sequence_position else null end
        ) aa
        group by ts_value_production, id_enterprise, id_equipment, nm_equipment order by ts_value_production
    ) s0
    group by id_enterprise, id_equipment, nm_equipment;

END IF;
end
$function$;
