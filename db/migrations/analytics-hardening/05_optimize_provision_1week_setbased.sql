-- Optimize piot_create_equipment_runtime_1week: RBAR (279×231 = 64k iterations,
-- 14.3s, dominated by per-row piot_get_day_begin_by_equipment) -> set-based with
-- INLINED day_begin (coalesce(area.day_begin, site.day_begin) + tz). 261ms = ~55x.
-- Byte-equivalent: old-SELECT EXCEPT new-SELECT = 0/0 over all 279 equipment
-- (proven) + live row-count unchanged (10095). Applied 2026-09-04.
-- NOTE: the analogous 1hour/shift set-based rewrites were MEASURED to regress
-- (88s vs 29s for 1hour) — RBAR wins for 100%-conflict-rate upserts — so NOT applied.
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1week()
 RETURNS void LANGUAGE plpgsql AS $function$
begin
  insert into equipment_oee_weekly (id_equipment, ts_value)
  select distinct e.id_equipment,
         date_trunc('week', (date_trunc('day', (now() + interval '1 day' * g.i)::timestamptz at time zone s.timezone
              - interval '1 second' * coalesce(a.day_begin, s.day_begin)))::date)
  from equipments e
  join enterprises et on e.id_enterprise = et.id_enterprise and et.active
  join sites s on s.id_site = e.id_site
  left join areas a on a.id_area = e.id_area
  cross join generate_series(-200,30) g(i)
  where e.id_area is not null and e.id_site is not null
  on conflict do nothing;
end $function$;
