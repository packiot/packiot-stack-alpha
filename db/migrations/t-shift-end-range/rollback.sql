-- rollback for t-shift-end-range: the constraint and the getter fallback. The data repairs are NOT reverted
-- (they replace NULL/open ends with the values the rows' own ranges and shift spans already implied).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE gold.equipment_oee_shift DROP CONSTRAINT IF EXISTS chk_equipment_oee_shift_range_consistent;
ALTER TABLE core.shift_hours DROP CONSTRAINT IF EXISTS chk_shift_hours_bounds;
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
$function$;
COMMIT;
