-- t282 — historian-gateway #270 GLUE (sweep R2/R5/R6/R8/R9).
--
-- TARGET DB: the hist-gateway pg_duckdb instance ONLY (container `hist-gateway`,
--   image pgduckdb/pgduckdb:16-main, db `postgres`, user `postgres`). NOT the
--   analytics DB. Confirm: SELECT * FROM pg_extension WHERE extname='pg_duckdb';
--
-- Companion (run FIRST, on packiot_analytics): 02-analytics-histgw-ro.sql mints the
-- least-privilege remote role this migration repoints the browser mapping to (R9).
--
-- All items are documentation / column-pin / metadata glue — ZERO data risk, fully
-- reversible (rollback-01-gateway.sql). Kept 1:1 with the gateway init script
-- services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh
-- (a fresh boot must reproduce this state). Secret: pass -v histgw_ro_pass='<secret>'.
\set ON_ERROR_STOP on

-- ════════════════════════════════════════════════════════════════════════════
-- R2 — COLD ID-SPACE PROVENANCE. Make R1's collision rule enforceable by
-- inspection: record EVERY enterprise id that has a cold partition on S3 in the
-- allow-list table with an accurate provenance, so `SELECT id_enterprise,
-- provenance, ev_promoted, ee_promoted FROM hist_promoted_enterprise` is the
-- complete, auditable map of "which ids carry cold data and whether it is served".
-- Non-promoted rows (ev/ee_promoted=false) are DOCUMENTARY ONLY — ev_all /
-- ev_all_events INNER-JOIN on the promoted flags, so these rows never change what
-- is served. Provenance derived live 2026-09-14 from `aws s3 ls .../equipment_values/`
-- ∪ `.../equipment_events*/` cross-referenced with core.enterprises / core.equipments:
--   f3_remapped              — verified F3 remap, cold id_equipment ⊆ core.equipments(id) (PROMOTED)
--   f3_native                — the tenant's OWN recent data archived by the staging append (promotion pending verification)
--   legacy_collision_live_f3 — a LIVE F3 tenant id whose cold partition is RAW-LEGACY data (NOT that tenant's) — the allow-list is what stops this leaking TODAY
--   legacy_passthrough       — raw-legacy cold, no live F3 tenant yet — the future-assignment blocklist (never assign a NEW tenant one of these ids without a verified promotion)
INSERT INTO hist_promoted_enterprise (id_enterprise, ev_promoted, ee_promoted, provenance, note) VALUES
  (5,       false, false, 'f3_native',                'Bispharma-Staging — F3-native EV cold from the staging append (HIST_ENTS "3 5"). Promotion PENDING an ownership verification (GAP-10/R1 follow-up).'),
  (2,       false, false, 'legacy_collision_live_f3', 'Simulator Corp (live F3, 3 equip) — cold EV {160..184} ⊄ core.equipments(2)={3,4,5}; raw-legacy collision. Allow-list denies its cold (correct).'),
  (1000000, false, false, 'legacy_collision_live_f3', 'PACKIOT-ADMIN (live F3, 0 equip) — cold EV {111..113} vs core.equipments=∅; raw-legacy. Not served.'),
  (0,       false, false, 'legacy_passthrough',       'Raw-legacy EV cold (id 0 = NULL-ish/unassigned). No live F3 tenant. Do NOT assign a new tenant this id.'),
  (6,       false, false, 'legacy_passthrough',       'MONTEBELLO draft (F3 id 6, core.equipments(6)=∅) — cold EV {134..852} is raw-legacy. Verify ownership before any promotion.'),
  (10,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (13,      false, false, 'legacy_passthrough',       'NEOPAC draft (F3 id 13, core.equipments(13)=∅) — cold EV {0..865} is raw-legacy.'),
  (30,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (31,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (33,      false, false, 'legacy_passthrough',       'Raw-legacy EE-only cold (Incoplast legacy id — remaps to F3 4; EE not yet re-unloaded).'),
  (35,      false, false, 'legacy_passthrough',       'Raw-legacy EV cold; no live F3 tenant.'),
  (36,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (37,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (38,      false, false, 'legacy_passthrough',       'Raw-legacy EV cold; no live F3 tenant.'),
  (99,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (100,     false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (101,     false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (102,     false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (111,     false, false, 'legacy_passthrough',       'Raw-legacy EV cold; no live F3 tenant.'),
  (112,     false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (113,     false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (116,     false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (117,     false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (118,     false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (10016,   false, false, 'legacy_passthrough',       'Raw-legacy EV cold; no live F3 tenant.')
ON CONFLICT (id_enterprise) DO UPDATE
  SET provenance = EXCLUDED.provenance, note = EXCLUDED.note
  -- NEVER downgrade a promoted id's flags via this documentation upsert.
  WHERE hist_promoted_enterprise.ev_promoted = false
    AND hist_promoted_enterprise.ee_promoted = false;

-- Cross-reference the collision rule from the boundary table (the join key).
COMMENT ON TABLE hist_cutover IS
  'T2b EV legacy-priority disjointness boundary. cutover_ts = max(hist.ts_value) per '
  'enterprise; in ev_all COLD owns ts_value<=cutover_ts, HOT owns >cutover_ts. '
  'Boundary set MUST equal hist_promoted_enterprise WHERE ev_promoted (see '
  'scripts/historian-cutover-coverage-check.sh). PROVENANCE of every cold id — and '
  'the R1 collision blocklist (ids that carry cold data and MUST NOT be reassigned/'
  'promoted without a verified ownership test) — lives in hist_promoted_enterprise '
  '(provenance column). LOAD-BEARING: refresh via refresh-hist-cutover.sql (a '
  'TOP-LEVEL statement — pg_duckdb cannot scan parquet in a function) after every '
  'cold-store append, else the newly-archived window double-counts.';

-- ════════════════════════════════════════════════════════════════════════════
-- R5 — hist_meta(last_append_at): a cheap timestamp the append pipeline stamps so
-- the staleness monitor (R4, scripts/historian-staleness-monitor.sh) can detect a
-- missed refresh hook by comparing last_append_at vs hist_cutover.refreshed_at,
-- WITHOUT a full cold max() parquet scan. Stamped by scripts/stamp-hist-meta.sql
-- from the append job's post-run hook (historian-staging-run-append.sh).
CREATE TABLE IF NOT EXISTS hist_meta (
  id_enterprise    int PRIMARY KEY,
  last_append_at   timestamptz NOT NULL,          -- when the cold store last grew for this enterprise
  last_append_rows bigint,                        -- rows written in that append run (observability)
  window_end       timestamptz,                   -- exclusive upper bound of the appended window
  source           text        NOT NULL DEFAULT 'historian-append',
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE hist_meta IS
  'Per-enterprise last-append stamp for the COLD store. Written by the append job''s '
  'post-run hook (stamp-hist-meta.sql), mirrors the S3 _watermark/enterprise=<id>/'
  'last-append.json. Purpose: let historian-staleness-monitor.sh flag a MISSED '
  'refresh-hist-cutover hook cheaply — if last_append_at > hist_cutover.refreshed_at '
  'for an ev_promoted enterprise, the cold store grew AFTER the last boundary refresh '
  '⇒ ev_all is double-counting the newly-archived window (sweep R4/R5).';
COMMENT ON COLUMN hist_meta.last_append_at IS 'Timestamp the cold store last grew for this enterprise (append run wall-clock).';
COMMENT ON COLUMN hist_meta.window_end IS 'Exclusive upper bound of the last appended window (from the append watermark).';

-- ════════════════════════════════════════════════════════════════════════════
-- R8 — PIN live.equipment_events to the exact columns ev_all_events serves (prune-
-- proof, matching the equipment_values pattern). The table was a full 26-col IMPORT;
-- ev_all_events references only 12 remote columns, so drop the other 14. After this,
-- a remote drop/rename of any un-served EE column can never break this foreign table
-- (postgres_fdw ships only declared+referenced columns). ev_all_events references
-- none of the dropped columns, so this does not touch the view.
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS id_equipment_event;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS idle;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS idle_processed;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS forced_creation_system;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS fault;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS fault_processed;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS cd_machine;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS change_over;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS cd_category_client;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS cd_subcategory_client;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS last_update;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS ignore_cost;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS ingested_at;
ALTER FOREIGN TABLE live.equipment_events DROP COLUMN IF EXISTS source_seq;
COMMENT ON FOREIGN TABLE live.equipment_events IS
  'HOT side of ev_all_events. postgres_fdw foreign table onto '
  'packiot_analytics.silver.equipment_events via server live_pg. PINNED to the 12 '
  'columns ev_all_events serves (was a 26-col IMPORT) — prune-proof like '
  'live.equipment_values: a remote drop/rename of an un-served EE column cannot break '
  'this table (postgres_fdw ships only declared columns). Also holds the CPACK Phase-C '
  'deep-history backfill — see ev_events_cutover for why EE is hot-anchored.';

-- ════════════════════════════════════════════════════════════════════════════
-- R6 — encode the year/month PRUNE CONTRACT unmissably on the union views, so a NEW
-- consumer cannot full-scan the archive by accident. (DuckDB prunes ONLY on the
-- year/month partition columns, never ts_value: 59 files/171s vs 1 file/0.57s.)
COMMENT ON VIEW ev_all IS
  'PRUNE CONTRACT (READ FIRST): a bounded query MUST carry a year AND month predicate '
  '(e.g. year=2026 AND month=9) — ts_value alone does NOT prune the cold parquet '
  '(hardproof: 59 files/171s without vs 1 file/0.57s with year/month). No year/month '
  '⇒ FULL-ARCHIVE SCAN. Keep ev_all OUT of Superset SQL Lab. Every consumer query MUST '
  'also carry an id_enterprise=<literal> tenant fence (no Postgres RLS here). '
  '── THE hot+cold EV serving surface, no double-count. LEGACY-PRIORITY (T2b): COLD '
  '(hist, ev_promoted only) owns ts_value<=cutover_ts, HOT (live.equipment_values) owns '
  '>cutover_ts, cutover_ts=max(hist.ts_value) per enterprise (hist_cutover). Surfaces '
  'year/month (hot=EXTRACT, cold=partition cols). read-api /v1/historian + Superset '
  'ev_all dataset.';
COMMENT ON VIEW ev_all_events IS
  'PRUNE CONTRACT (READ FIRST): a bounded query MUST carry a year AND month predicate — '
  'ts_event alone does NOT prune the cold parquet. No year/month ⇒ FULL-ARCHIVE SCAN. '
  'Carry an id_enterprise=<literal> tenant fence on every query (no RLS here). '
  '── THE hot+cold EE serving surface, no double-count. HOT-ANCHORED (mirror of ev_all): '
  'HOT (live.equipment_events) owns its whole covered range, COLD (hist_ee, ee_promoted '
  'only) fills ts_event<cutover_ts, cutover_ts=min(hot ts_event) per enterprise '
  '(ev_events_cutover). Completeness caveat: the overlap window is handed to hot, so '
  'equipment cold-but-not-hot there is under-covered — guarded by '
  'scripts/historian-ee-coverage-check.sh (R7). Surfaces year/month for cold pruning.';
COMMENT ON COLUMN ev_all.year IS 'Reading year. Cold = hive partition column (PRUNE KEY); hot = EXTRACT(YEAR FROM ts_value). Omitting it ⇒ full cold scan.';
COMMENT ON COLUMN ev_all.month IS 'Reading month. Cold = hive partition column (PRUNE KEY); hot = EXTRACT(MONTH FROM ts_value). Carry alongside year.';
COMMENT ON COLUMN ev_all_events.year IS 'Event year. Cold = hive partition column (PRUNE KEY); hot = EXTRACT. Omitting it ⇒ full cold scan.';
COMMENT ON COLUMN ev_all_events.month IS 'Event month. Cold = hive partition column (PRUNE KEY); hot = EXTRACT. Carry alongside year.';

-- ════════════════════════════════════════════════════════════════════════════
-- R9 — repoint the cloudbeaver_histro FDW identity from the remote SUPERUSER
-- (postgres) to the least-privilege histgw_ro role minted by 02-analytics-histgw-ro.sql
-- on packiot_analytics. Defense-in-depth: a compromised gateway browser session can no
-- longer ride a superuser into the analytics DB. The main `postgres` local role mapping
-- is intentionally left on the remote postgres (used by the trusted read-api/Superset
-- server-side paths). :'histgw_ro_pass' MUST equal the password given to 02-…-ro.sql
-- and stored in the gateway .env as HISTGW_RO_PASS.
ALTER USER MAPPING FOR cloudbeaver_histro SERVER live_pg
  OPTIONS (SET user 'histgw_ro', SET password :'histgw_ro_pass');
