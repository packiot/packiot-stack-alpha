-- t271 — historian promoted-enterprise ALLOW-LIST: close the EV/EE cold cross-tenant leak.
-- Reversible (see rollback.sql). Applied on the hist-gateway (db postgres).
BEGIN;

-- 1) The allow-list: the SOLE tenant-isolation gate for the COLD side of ev_all / ev_all_events.
CREATE TABLE IF NOT EXISTS hist_promoted_enterprise (
  id_enterprise int PRIMARY KEY,
  ev_promoted   boolean NOT NULL DEFAULT false,
  ee_promoted   boolean NOT NULL DEFAULT false,
  provenance    text    NOT NULL,
  note          text,
  promoted_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE hist_promoted_enterprise IS
  'Historian promotion ALLOW-LIST — the SOLE tenant-isolation gate for the COLD side of ev_all (EV) and ev_all_events (EE). An id is promoted ONLY when cold partition enterprise=<id> is VERIFIED to belong to the current F3 tenant of that id: cold DISTINCT id_equipment is a subset of core.equipments(id) AND core.equipments(id) is non-empty (a genuine remap, not a raw-legacy passthrough whose numeric id merely collides with an F3 tenant). ev_all/ev_all_events INNER JOIN this on the cold side, so a non-promoted id (including a future F3 tenant assigned a colliding low id) gets ZERO cold rows. The full raw-legacy archive stays queryable for reference via hist / hist_ee (NOT tenant-facing). Extend ONLY via a verified promotion (scripts/historian-events-reunload.sh for EE); never hand-add an unverified id.';

-- Seed derived live 2026-09-14 via the ownership test (cold id_equipment ⊆ core.equipments(id)):
--   ent3  CPACK    — cold EV {47..108}(62)      == core.equipments(3);  EE cold {47..108} too  → ev+ee
--   ent4  Incoplast— cold EV {990015..990018}(4)== core.equipments(4);  EE still legacy-33 (unmapped) → ev only
-- Counter-examples NOT promoted (raw-legacy id collisions):
--   ent6  cold {134..852} vs core.equipments(6)=∅ (MONTEBELLO draft); ent13 cold {0..865} vs ∅ (NEOPAC draft);
--   ent2  cold {160..184} ⊄ core.equipments(2)={3,4,5}; ent1000000 cold {111..113} vs core.equipments=∅.
INSERT INTO hist_promoted_enterprise (id_enterprise, ev_promoted, ee_promoted, provenance, note) VALUES
  (3, true,  true,  'f3_remapped', 'CPACK — legacy 1→F3 3; cold id_equipment {47..108} == core.equipments(3)'),
  (4, true,  false, 'f3_remapped', 'Incoplast — legacy 33→F3 4; cold EV {990015..990018} == core.equipments(4). EE NOT promoted: legacy-33 EE equipment un-remapped (needs external map).')
ON CONFLICT (id_enterprise) DO UPDATE
  SET ev_promoted=EXCLUDED.ev_promoted, ee_promoted=EXCLUDED.ee_promoted,
      provenance=EXCLUDED.provenance, note=EXCLUDED.note;

-- 2) EV — gate the cold side of ev_all by the allow-list. Align hist_cutover to the
--    ev_promoted set: prune non-promoted rows (a boundary for a non-served enterprise
--    would wrongly clip its HOT history) AND seed any newly-promoted enterprise's row
--    (a missing boundary for a SERVED enterprise double-counts). The seed scans the
--    cold parquet, so it MUST be a top-level statement (pg_duckdb can't scan in a fn).
DELETE FROM hist_cutover
 WHERE id_enterprise NOT IN (SELECT id_enterprise FROM hist_promoted_enterprise WHERE ev_promoted);
INSERT INTO hist_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT h.id_enterprise, max(h.ts_value), now()
  FROM hist h
  JOIN hist_promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ev_promoted
 WHERE h.id_enterprise IS NOT NULL
 GROUP BY h.id_enterprise
ON CONFLICT (id_enterprise) DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

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
    FROM hist h
    JOIN hist_promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ev_promoted;

-- 3) EE — hist_ee now globs the FULL archive (both prefixes) so isolation is 100% the
--    allow-list, not a path-exclusion. equipment_events_legacy_unpromoted/ becomes mere
--    reference storage, not a security boundary.
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
FROM read_parquet(
       ARRAY['s3://packiot-staging-historian-639178078294/equipment_events/*/*/*/*-legacy.parquet',
             's3://packiot-staging-historian-639178078294/equipment_events_legacy_unpromoted/*/*/*/*-legacy.parquet'],
       hive_partitioning => true) r;

-- align ev_events_cutover to the ee_promoted set (prune + seed; reads the hot FDW, cheap).
DELETE FROM ev_events_cutover
 WHERE id_enterprise NOT IN (SELECT id_enterprise FROM hist_promoted_enterprise WHERE ee_promoted);
INSERT INTO ev_events_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT lv.id_enterprise, min(lv.ts_event)::timestamp, now()
  FROM live.equipment_events lv
  JOIN hist_promoted_enterprise p ON p.id_enterprise = lv.id_enterprise AND p.ee_promoted
 WHERE lv.id_enterprise IS NOT NULL
 GROUP BY lv.id_enterprise
ON CONFLICT (id_enterprise) DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

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
    JOIN hist_promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ee_promoted
    LEFT JOIN ev_events_cutover c ON c.id_enterprise = h.id_enterprise
   WHERE c.cutover_ts IS NULL OR h.ts_event < c.cutover_ts;

COMMIT;
