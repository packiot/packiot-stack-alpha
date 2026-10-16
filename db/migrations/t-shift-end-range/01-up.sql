-- t-shift-end-range — schema P1 (2026-10-07): every shift row has an end, and ts_range always equals [ts_value, ts_end).
--
-- ROOT CAUSE (staging probes 2026-10-07, read-only): gold.equipment_oee_shift rows are created by
-- piot_create_equipment_oee_shift() from piot_get_shift_hour_begin_by_equipment(), which computed
-- ts_end = begin + shift_size. A tenant whose core.shift_hours.shift_size is NULL (enterprise 120: all 7 rows; it is
-- set by no function, onboarding leaves it empty) got ts_end NULL and an OPEN-ENDED ts_range, so every shift of
-- those equipments overlapped every later one (the "overlapping shift pairs" of the 10-07 schema review).
-- In every populated row (5 tenants, 381 rows) shift_size = end_time - begin_time exactly, so the span is the
-- exact fallback, not a guess.
-- Separately, 20,088 legacy rows (tenant 3 + its twin, 2021-11..2022-03) carry a correct finite ts_range but
-- ts_end NULL: readers that use ts_value/ts_end (rollup line_lead.go/availability.go) and readers that use ts_range
-- (downtime-by-shift SQL) disagreed on those shifts.
--
-- FIX: getter falls back to the span; NULL shift_size backfilled; the two row groups repaired; a CHECK makes the
-- invariant hold from now on (NOT VALID first, then VALIDATE: the full scan runs under SHARE UPDATE EXCLUSIVE,
-- which does not block the rollup's reads or writes). Rows are NOT re-flagged for recompute (legacy history is
-- 2021-22, enterprise 120 has no data; re-flagging old shifts stalled the rollup on 10-01).
-- No-overlap EXCLUDE is a separate migration (t-shift-no-overlap): its GiST build needs a write pause.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

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
$function$;

-- engine-side column, never set for enterprise 120; equal to the span everywhere it is set
UPDATE core.shift_hours SET shift_size = end_time - begin_time
 WHERE shift_size IS NULL AND begin_time IS NOT NULL AND end_time IS NOT NULL;

-- legacy rows: the finite range is the truth, ts_end was never written
UPDATE gold.equipment_oee_shift SET ts_end = upper(ts_range)
 WHERE ts_end IS NULL AND ts_range IS NOT NULL AND NOT upper_inf(ts_range);

-- open-ended rows (NULL shift_size): end = start + the shift's span
UPDATE gold.equipment_oee_shift e
   SET ts_end   = e.ts_value + (sh.end_time - sh.begin_time) * interval '1 second',
       ts_range = tstzrange(e.ts_value, e.ts_value + (sh.end_time - sh.begin_time) * interval '1 second')
  FROM core.shift_hours sh
 WHERE sh.id_shift_hour = e.id_shift_hour AND e.ts_end IS NULL AND upper_inf(e.ts_range);

DO $$ DECLARE n bigint; b bigint; BEGIN
  SELECT count(*) INTO n FROM gold.equipment_oee_shift WHERE ts_end IS NULL OR ts_range IS DISTINCT FROM tstzrange(ts_value, ts_end, '[)');
  IF n > 0 THEN RAISE EXCEPTION 't-shift-end-range: % shift row(s) still inconsistent after repair; nothing committed', n; END IF;
  SELECT count(*) INTO b FROM core.shift_hours WHERE begin_time IS NULL OR end_time IS NULL OR end_time <= begin_time;
  IF b > 0 THEN RAISE EXCEPTION 't-shift-end-range: % shift_hours row(s) without valid bounds; fix them first, nothing committed', b; END IF;
END $$;

-- a shift definition without valid bounds now fails where it is entered (CS Admin onboarding), not later in the
-- shift creator job (one bad tenant row would otherwise fail the creator's INSERT for every tenant)
ALTER TABLE core.shift_hours DROP CONSTRAINT IF EXISTS chk_shift_hours_bounds;
ALTER TABLE core.shift_hours ADD CONSTRAINT chk_shift_hours_bounds
  CHECK (begin_time IS NOT NULL AND end_time IS NOT NULL AND end_time > begin_time) NOT VALID;

ALTER TABLE gold.equipment_oee_shift DROP CONSTRAINT IF EXISTS chk_equipment_oee_shift_range_consistent;
ALTER TABLE gold.equipment_oee_shift ADD CONSTRAINT chk_equipment_oee_shift_range_consistent
  CHECK (ts_end IS NOT NULL AND ts_range = tstzrange(ts_value, ts_end, '[)')) NOT VALID;
COMMIT;

BEGIN;
SET LOCAL lock_timeout = '3s';
ALTER TABLE gold.equipment_oee_shift VALIDATE CONSTRAINT chk_equipment_oee_shift_range_consistent;
ALTER TABLE core.shift_hours VALIDATE CONSTRAINT chk_shift_hours_bounds;
COMMENT ON CONSTRAINT chk_equipment_oee_shift_range_consistent ON gold.equipment_oee_shift IS
  'ts_range is [ts_value, ts_end): one truth for the rollup (ts_value/ts_end) and the downtime SQL (ts_range). t-shift-end-range.';
COMMIT;
