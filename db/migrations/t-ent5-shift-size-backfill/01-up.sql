-- t-ent5-shift-size-backfill — populate ent5's shift_size so its shift buckets close.
--
-- ROOT CAUSE (one gap, two symptoms): core.shift_hours.shift_size is a runtime field the
-- OEE engine seeds (per CLAUDE.md, "set by the OEE engine, NOT CS Admin"). For ent5
-- (Bispharma) it was never populated — 36/36 rows NULL (CPACK: 105/105 set). The shift
-- provisioner piot_get_shift_hour_begin_by_equipment builds the bucket window as
--   tstzrange(week_base+begin, week_base+begin + shift_size*'1s')
-- so a NULL shift_size makes the upper bound NULL → every ent5 equipment_oee_shift row is
-- OPEN-ENDED [start,) with NULL ts_end + NULL duration (all 17,387 of them). That single
-- gap causes BOTH:
--   (1) Downtimes fan out ~53x — serving.refresh_downtime_events_resolved joins each stop
--       to `ee.ts_event <@ ers.ts_range`, and every open shift since the line came online
--       contains the instant. (2) Mission Control per-line OEE = 0 / "no runtimes" —
--       NULL duration ⇒ zero shift denominator.
--
-- FIX (ent5-scoped, no shared-code change): populate shift_size = end_time-begin_time
-- (verified: identical to CPACK, and the resulting bucket ends tile the day exactly —
-- 01:00->08:00->16:30->01:00, 7+8.5+8.5=24h, no gaps/overlaps), then close the already-
-- seeded open rows the same way. Future rows close automatically via the provisioner.

-- 1) the runtime field the engine should have seeded.
UPDATE core.shift_hours sh
   SET shift_size = sh.end_time - sh.begin_time
  FROM core.shifts s
 WHERE s.id_shift = sh.id_shift
   AND s.id_enterprise = 5
   AND sh.shift_size IS NULL
   AND sh.end_time IS NOT NULL AND sh.begin_time IS NOT NULL;

-- 2) close the existing open shift buckets (ts_end / ts_range / duration) from the shift calendar.
UPDATE gold.equipment_oee_shift o
   SET ts_end   = o.ts_value + (sh.end_time - sh.begin_time) * interval '1 second',
       ts_range = tstzrange(o.ts_value, o.ts_value + (sh.end_time - sh.begin_time) * interval '1 second'),
       duration = sh.end_time - sh.begin_time
  FROM core.shift_hours sh, core.equipments e
 WHERE sh.id_shift_hour = o.id_shift_hour
   AND e.id_equipment = o.id_equipment
   AND e.id_enterprise = 5
   AND upper(o.ts_range) IS NULL;

-- 3) re-flag the current + recent ent5 shift buckets so line-lead recomputes their OEE now
--    that they have a bounded window + duration.
UPDATE gold.equipment_oee_shift o
   SET recalc_needed = true
  FROM core.equipments e
 WHERE e.id_equipment = o.id_equipment
   AND e.id_enterprise = 5
   AND o.ts_value >= now() - interval '2 days';
