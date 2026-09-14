-- t271 ROLLBACK — restore the pre-allow-list historian gateway state.
-- Reverses 01-up.sql: removes the cold-side allow-list gate, restores the full
-- (single-prefix) hist_ee glob, re-seeds the two cutover tables to the FULL cold set,
-- and drops the allow-list table. Run on the hist-gateway (db postgres).
BEGIN;

-- 1) EV cold side back to ungated (FROM hist, no allow-list join).
CREATE OR REPLACE VIEW ev_all AS
  SELECT lv.ts_value, lv.id_enterprise,
         EXTRACT(YEAR  FROM lv.ts_value)::int AS year,
         EXTRACT(MONTH FROM lv.ts_value)::int AS month,
         lv.id_equipment, lv.gross_production_incr, lv.net_production_incr, lv.speed
    FROM live.equipment_values lv
    LEFT JOIN hist_cutover c ON c.id_enterprise = lv.id_enterprise
   WHERE c.cutover_ts IS NULL OR lv.ts_value > c.cutover_ts
  UNION ALL
  SELECT h.ts_value, h.id_enterprise, h.year, h.month, h.id_equipment,
         h.gross_production_incr, h.net_production_incr, h.speed
    FROM hist h;

-- 2) hist_ee back to the promoted-prefix-only glob.
CREATE OR REPLACE VIEW hist_ee AS
SELECT r['ts_event']::timestamp         AS ts_event,
       r['enterprise']::int             AS id_enterprise,
       r['year']::int                   AS year,
       r['month']::int                  AS month,
       r['id_equipment']::int           AS id_equipment,
       r['ts_end']::timestamp           AS ts_end,
       r['duration']::int               AS duration,
       r['status']::int                 AS status,
       r['planned_downtime']::boolean   AS planned_downtime,
       r['cd_category']::varchar        AS cd_category,
       r['desc_category']::varchar      AS desc_category,
       r['cd_subcategory']::varchar     AS cd_subcategory,
       r['desc_subcategory']::varchar   AS desc_subcategory,
       r['txt_downtime_notes']::varchar AS txt_downtime_notes
FROM read_parquet('s3://packiot-staging-historian-639178078294/equipment_events/*/*/*/*-legacy.parquet',
                  hive_partitioning => true) r;

-- 3) EE cold side back to ungated (no allow-list join).
CREATE OR REPLACE VIEW ev_all_events AS
  SELECT lv.ts_event::timestamp                    AS ts_event,
         lv.id_enterprise,
         EXTRACT(YEAR  FROM lv.ts_event)::int       AS year,
         EXTRACT(MONTH FROM lv.ts_event)::int       AS month,
         lv.id_equipment, lv.ts_end::timestamp AS ts_end, lv.duration, lv.status,
         lv.planned_downtime, lv.cd_category, lv.desc_category, lv.cd_subcategory,
         lv.desc_subcategory, lv.txt_downtime_notes
    FROM live.equipment_events lv
  UNION ALL
  SELECT h.ts_event, h.id_enterprise, h.year, h.month, h.id_equipment,
         h.ts_end, h.duration, h.status, h.planned_downtime,
         h.cd_category, h.desc_category, h.cd_subcategory, h.desc_subcategory,
         h.txt_downtime_notes
    FROM hist_ee h
    LEFT JOIN ev_events_cutover c ON c.id_enterprise = h.id_enterprise
   WHERE c.cutover_ts IS NULL OR h.ts_event < c.cutover_ts;

-- 4) Re-seed the cutover tables to the FULL cold set (the pre-allow-list state).
--    NOTE: the EV refresh scans the cold parquet (minutes) — must be top-level (no fn).
INSERT INTO hist_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT id_enterprise, max(ts_value), now() FROM hist WHERE id_enterprise IS NOT NULL GROUP BY id_enterprise
ON CONFLICT (id_enterprise) DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

INSERT INTO ev_events_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT id_enterprise, min(ts_event)::timestamp, now() FROM live.equipment_events WHERE id_enterprise IS NOT NULL GROUP BY id_enterprise
ON CONFLICT (id_enterprise) DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

-- 5) Drop the allow-list.
DROP TABLE IF EXISTS hist_promoted_enterprise;

COMMIT;
