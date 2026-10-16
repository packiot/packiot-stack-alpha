-- t-ent5-area-day-begin-align — Bispharma (ent 5) areas carry their SITE's week/day begin.
-- STAGING-ONLY (ent 5 exists on staging). Idempotent.
--
-- SYMPTOM (2026-09-29 config audit): the two ent 5 areas disagree with their sites, and the
-- values are SWAPPED between them:
--   area 2000020 (site SP 2000009):        week_begin -3000 / day_begin 21600 (06:00)
--                                          site: 18000 / 18000 (05:00)
--   area 2000021 (site bisnagoSP 2000010): week_begin 18000 / day_begin 18000 (05:00)
--                                          site: 21600 / 21600 (06:00)
-- The SITE values are the truth: shift instances start at 05:00 (SP) and 06:00 (bisnago), and
-- the hourly ts_value_production labels already split the day at the site's day_begin (SP 05:00 hour is
-- the new day, bisnago 05:00 hour is the previous day). So the stored OEE data is consistent.
-- But some readers prefer the AREA value, and they disagree with everything else:
--   piot_get_day_begin_by_equipment (UNION site/area ORDER BY id_area → the area row wins),
--   piot_get_day_begin_by_area / piot_get_shift_hour_begin_by_area, the area-grain rollups,
--   serving.downtime_events(_v2,_v3) day fields.
-- FIX: copy the site's week_begin/day_begin onto its areas. No stored OEE row is relabelled
-- (they already follow the site). Other tenants untouched (id_enterprise = 5 only).
-- BACKUP: ops._bkp_ent5_csadmin_fixes_20260929 kind='area'. ROLLBACK: rollback.sql.
BEGIN;

CREATE TABLE IF NOT EXISTS ops._bkp_ent5_csadmin_fixes_20260929 (kind text, row jsonb, backed_up_at timestamptz DEFAULT now());
INSERT INTO ops._bkp_ent5_csadmin_fixes_20260929 (kind, row)
  SELECT 'area', to_jsonb(a) FROM core.areas a
   WHERE a.id_enterprise = 5
     AND NOT EXISTS (SELECT 1 FROM ops._bkp_ent5_csadmin_fixes_20260929 b
                      WHERE b.kind = 'area' AND (b.row->>'id_area')::int = a.id_area);

UPDATE core.areas a
   SET week_begin = s.week_begin, day_begin = s.day_begin
  FROM core.sites s
 WHERE s.id_site = a.id_site AND a.id_enterprise = 5
   AND (a.week_begin IS DISTINCT FROM s.week_begin OR a.day_begin IS DISTINCT FROM s.day_begin);

-- Guard: every ent 5 area now matches its site.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.areas a JOIN core.sites s USING (id_site)
              WHERE a.id_enterprise = 5
                AND (a.week_begin IS DISTINCT FROM s.week_begin OR a.day_begin IS DISTINCT FROM s.day_begin)) THEN
    RAISE EXCEPTION 'ent 5 area/site week_begin/day_begin still differ';
  END IF;
END $$;

COMMIT;
