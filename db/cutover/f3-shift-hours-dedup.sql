-- ─────────────────────────────────────────────────────────────────────────────
-- F3 CUTOVER FIX 2 (MED): shift_hours 4× duplication (CPACK ent-3 + sandbox twin)
--
-- Symptom: every (id_shift, day_week) for shifts 16..30 (CPACK ent-3) AND their
-- sandbox twins 2000016..2000030 had count=4 — 840 rows where 210 were expected
-- (7 weekdays × 30 shifts). 630 exact-duplicate rows total across the table.
--
-- Root cause: the table's UNIQUE CONSTRAINT `shift_hours_un` is on
--   (begin_time, end_time, id_site, id_area, id_equipment)
-- and every shift_hours row carries id_equipment = NULL (that column is set by
-- the OEE engine at runtime, never at onboarding). In SQL, NULL <> NULL, so the
-- constraint NEVER fires for onboarding rows — re-running the shift-hours seed
-- silently appends a full duplicate set each time. Four seed runs → 4× rows.
--
-- Fix, two parts:
--   (a) Dedup: keep the lowest id_shift_hour per FULL-ROW-identical group,
--       delete the rest. Full-row partition (not just the unique key) guarantees
--       we only ever drop byte-identical duplicates, never a distinct schedule.
--   (b) Make re-accumulation structurally impossible: replace the NULL-defeated
--       constraint with a NULL-SAFE unique INDEX using COALESCE(id_equipment,0).
--       (A constraint cannot carry an expression — hence a unique index.)
--
-- Safety verified before applying on live F3:
--   * 0 dup-groups map to >1 distinct id_shift/shift_size/duration (no distinct
--     schedule is ever merged).
--   * 0 (begin,end,site,area,coalesce(equip,0)) tuples map to >1 id_shift, so the
--     new index is legitimately unique after dedup.
-- Idempotent: re-running the dedup deletes nothing; IF EXISTS / IF NOT EXISTS.
-- ─────────────────────────────────────────────────────────────────────────────

-- (a) Dedup — keep MIN(id_shift_hour) per full-row-identical group.
DELETE FROM shift_hours sh
USING (
  SELECT id_shift_hour,
         row_number() OVER (
           PARTITION BY id_shift, cd_shift, begin_time, end_time, id_enterprise,
                        id_site, id_area, day_number, day_week, shift_size,
                        id_equipment, duration
           ORDER BY id_shift_hour
         ) AS rn
    FROM shift_hours
) d
WHERE sh.id_shift_hour = d.id_shift_hour
  AND d.rn > 1;

-- (b) Replace the NULL-defeated unique constraint with a NULL-safe unique index.
ALTER TABLE shift_hours DROP CONSTRAINT IF EXISTS shift_hours_un;
CREATE UNIQUE INDEX IF NOT EXISTS shift_hours_begin_end_site_area_equip_uidx
    ON shift_hours (begin_time, end_time, id_site, id_area, COALESCE(id_equipment, 0));
