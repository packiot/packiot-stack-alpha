#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# historian-gateway init — runs once on a fresh pg_duckdb data volume.
#
# Builds the TRANSPARENT HOT+COLD UNION that lets front4 / Superset / any tool
# query old timestamps with plain SQL:
#
#   silver.equipment_values  =  live.equipment_values   (postgres_fdw -> the timescaledb hypertable, HOT)
#           UNION ALL
#              equipment_values                     (pg_duckdb  -> S3 Parquet historian,        COLD)
#
# WHY A SEPARATE GATEWAY (not pg_duckdb inside the timescaledb instance):
#   * The staging/prod DB image is Alpine/musl (timescale/timescaledb:*-pg15);
#     pg_duckdb ships glibc and bundles DuckDB (large C++) — no musl build.
#   * Keeps heavy historian scans off the operational OLTP instance.
#   Consumers repoint ONE connection host to this gateway; SQL is unchanged.
#
# ── LEGACY-PRIORITY UNION (T2b — corrected 2026-09-04) ────────────────────────
# ORIGINAL (WRONG) INVARIANT: the header used to claim the cold side reads ONLY
# *-legacy.parquet which is "pre-cutover by construction", so a plain UNION ALL
# never double-counts. HARDPROOF DISPROVED THIS on staging:
#   * equipment_values (the *-legacy.parquet set) for ent3 spans 2021-11-05 .. 2026-09-04
#     (max_ts == TODAY, NOT pre-cutover), 335.7M rows.
#   * live.equipment_values for ent3 starts 2026-07-23 (its F3 cutover) .. now.
#   * On 2026-09-03 BOTH sides hold ent3 rows: equipment_values=196,671 / live=155,465.
#   => a plain UNION ALL returned 352,136 rows for that one day == DOUBLE-COUNT.
# (The *-legacy.parquet on staging is the deep-remap backfill of the STILL-LIVE
#  legacy packiot40 source, so it extends to ~now — it is NOT bounded at a cutover.
#  See docs / the analytics-rename-overnight-report; the "why does legacy reach
#  today" root-cause is an operational question, but the gateway must be correct
#  regardless of how far legacy extends.)
#
# THE FIX — legacy-priority, per-enterprise cutover:
#   cutover(e) = max(equipment_values.ts_value) for enterprise e   (materialized in ev_union_boundary)
#     COLD owns  ts_value <= cutover(e)   (the full verified archive)
#     HOT  owns  ts_value >  cutover(e)   (only the live tail newer than the archive)
# These are DISJOINT at the cutover instant, so no row is counted twice, and the
# live tail fills forward from where the archive ends (no gap). Enterprises with
# NO historian data (live-only new tenants) have no ev_union_boundary row -> the LEFT
# JOIN keeps ALL their live rows and equipment_values contributes nothing (also no dup).
#
#   HARDPROOF of the fix (read-only, staging, ent3 2026-09-03):
#     HOT(live, ts>cutover) = 0    COLD(equipment_values, all) = 196,671    total = 196,671
#     (was 352,136 under the plain UNION ALL) — double-count eliminated.
#     Live still fills forward: 50,594 ent3 rows exist with ts>cutover (today).
#
# INVARIANT (load-bearing): every enterprise present in the historian MUST have a
# ev_union_boundary row, and cutover(e) MUST equal max(equipment_values.ts_value). The inline seed
# below (and the top-level refresh-equipment_values-cutover.sql) compute exactly that. RE-RUN the
# cutover refresh (refresh-equipment_values-cutover.sql) after EVERY historian backfill/append
# that extends the cold store (otherwise a stale cutover lets the newly-archived
# window be served by BOTH sides again). A missing row for an in-historian enterprise
# re-introduces the double-count (LEFT JOIN NULL keeps all live AND all equipment_values).
#
# DO NOT wrap this refresh in a PL/pgSQL function: pg_duckdb CANNOT execute a DuckDB
# scan (the `equipment_values` parquet read) inside a function body — it throws "DuckDB execution
# is not supported inside functions", silently leaving ev_union_boundary stale → double
# count. A broken `refresh_ev_union_boundary()` plpgsql function of exactly this shape was
# found live on staging (never in this repo) and DROPPED 2026-09-08. The refresh MUST
# stay a TOP-LEVEL statement (the inline seed here + refresh-equipment_values-cutover.sql).
#
# ── PARTITION PRUNING (T3/T6 — added 2026-09-04) ──────────────────────────────
# The historian is hive-partitioned enterprise=/year=/month=, one *-legacy.parquet
# per enterprise-month. DuckDB prunes ONLY on the partition columns (year/month),
# NOT on ts_value: HARDPROOF via EXPLAIN ANALYZE on staging —
#     WHERE ts_value BETWEEN <one day>                -> Total Files Read: 59, 170.76s
#     WHERE year=2026 AND month=9 AND ts_value ...    -> Total Files Read: 1,   0.57s
#     WHERE (year/month RANGE, Jinja-shape) AND ts... -> Total Files Read: 1,   0.74s
# So a bounded silver.equipment_values query prunes the cold side ONLY IF the query carries a
# year/month predicate. silver.equipment_values therefore SURFACES year + month (cold: the partition
# columns; hot: EXTRACT), and consumers must add a year/month predicate alongside
# their ts_value range. Two supported ways:
#   * Superset: the silver.equipment_values virtual dataset injects the year/month range from the
#     dashboard time filter via Jinja ({{ from_dttm }}/{{ to_dttm }}). See
#     configs/superset/assets/datasets/historian_union/silver.equipment_values.yaml.
#   * read-api / tools: call ev_between(p_start, p_end) (below) which injects the
#     year/month range for you, or add the year/month predicate yourself.
#
# ── LIVE-FDW pushdown (T3) ────────────────────────────────────────────────────
# The FDW server is created with use_remote_estimate + fetch_size + async_capable so
# the planner asks the remote for real costs (enables aggregate/join pushdown
# consideration) and streams larger batches. NOTE: after the T2b fix the HOT side is
# INHERENTLY a small recent tail (ts > cutover), so the historical "2-day DISTINCT
# timed out at 60s" no longer applies to bounded dashboard queries. Only add a
# materialized live_recent window if the post-cutover tail itself grows large.
#
# TENANT RLS: pg_duckdb CANNOT evaluate a PG session GUC / STABLE function during
# pushdown (they get shipped into DuckDB, which has no PG context). So the tenant
# MUST arrive as a LITERAL/param. Superset's native RLS injects it as a literal;
# read-api adds `id_enterprise = <id>` from its already-known tenant. Do NOT rely
# on a `current_setting()`-based policy for the cold path. There is NO Postgres RLS
# co-enforcer on this gateway (unlike the bi.* analytics layer) — Superset RLS is
# the SOLE enforcer, so the silver.equipment_values dataset MUST stay out of SQL Lab and every
# guest/authoring query MUST carry the id_enterprise clause. See the Superset assets.
#
# Required env (see compose.historian-gateway.yml):
#   FDW_HOST FDW_PORT FDW_DB FDW_USER FDW_PASS   — the live timescaledb
#   HISTORIAN_BUCKET AWS_REGION                   — S3 historian
#   HIST_AWS_KEY HIST_AWS_SECRET                  — scoped read-only S3 key
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- HOT: live timescaledb hypertable via postgres_fdw (chunk-exclusion pushdown
-- happens on the remote when a ts_value predicate is supplied).
-- use_remote_estimate: ask the remote planner for real row/cost estimates so
--   postgres_fdw will CONSIDER pushing aggregates/joins down instead of pulling
--   rows locally (the cause of the prior slow live-side aggregates).
-- fetch_size: stream 50k-row batches (default 100) to cut round-trips on the tail.
-- async_capable: let the executor run the FDW scan concurrently with the cold scan
--   in the UNION (PG14+).
CREATE SERVER IF NOT EXISTS live_pg FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '${FDW_HOST}', port '${FDW_PORT:-5432}', dbname '${FDW_DB}',
           use_remote_estimate 'true', fetch_size '50000', async_capable 'true');
-- Keep options current on an existing server (idempotent re-init after an image bump).
ALTER SERVER live_pg OPTIONS (SET host '${FDW_HOST}', SET port '${FDW_PORT:-5432}',
           SET dbname '${FDW_DB}');
DROP USER MAPPING IF EXISTS FOR ${POSTGRES_USER} SERVER live_pg;
CREATE USER MAPPING FOR ${POSTGRES_USER} SERVER live_pg
  OPTIONS (user '${FDW_USER}', password '${FDW_PASS}');
CREATE SCHEMA IF NOT EXISTS live;
-- PINNED foreign table (NOT `IMPORT FOREIGN SCHEMA`): declare ONLY the columns the
-- gateway serves. The remote equipment_values carries ~58 cols, most of them dead
-- (quality/faults/analogs/state/…); the analytics clean-schema cutover PRUNES those.
-- A pinned import is prune-proof — dropping a dead column on the remote can never
-- break this foreign table (postgres_fdw only ships referenced columns). Types match
-- the remote (gross/net/speed = real; ids = int; ts_value = timestamptz).
DROP FOREIGN TABLE IF EXISTS live.equipment_values;
CREATE FOREIGN TABLE live.equipment_values (
  ts_value              timestamptz,
  id_enterprise         integer,
  id_site               integer,
  id_area               integer,
  id_equipment          integer,
  gross_production_incr real,
  net_production_incr   real,
  speed                 real
-- t231 medallion split (STAGING): the live fact hypertable now lives in the
-- `silver` schema on packiot_analytics (was `public`). A fresh gateway init must
-- foreign-mount from silver. (On an already-running gateway the live re-point is
-- `ALTER FOREIGN TABLE live.equipment_values OPTIONS (SET schema_name 'silver')`.)
) SERVER live_pg OPTIONS (schema_name 'silver', table_name 'equipment_values');
-- HOT equipment_events (downtime/OEE-reconstruction) — see the EE section at the
-- bottom (silver.equipment_events). Declared here so live.equipment_events exists before it.
-- t282/R8: PINNED foreign table (NOT `IMPORT FOREIGN SCHEMA`) — declare ONLY the 12
-- columns silver.equipment_events serves, matching the equipment_values pattern. Prune-proof: a
-- remote drop/rename of an un-served EE column can never break this table (postgres_fdw
-- ships only declared columns). The remote silver.equipment_events carries ~26 cols;
-- the other 14 (id_equipment_event/idle/fault/cd_machine/…client/last_update/…) are dead
-- to the union. Types match the remote. t231: mounted from `silver` (was `public`).
DROP FOREIGN TABLE IF EXISTS live.equipment_events;
CREATE FOREIGN TABLE live.equipment_events (
  ts_event          timestamptz,
  id_enterprise     integer,
  id_equipment      integer,
  ts_end            timestamptz,
  duration          integer,
  status            integer,
  planned_downtime  boolean,
  cd_category       varchar,
  desc_category     varchar,
  cd_subcategory    varchar,
  desc_subcategory  varchar,
  txt_downtime_notes varchar
) SERVER live_pg OPTIONS (schema_name 'silver', table_name 'equipment_events');

-- ── COLD serving schema (t287) — SYMMETRIC with the hot `live` FDW schema ─────
-- All historian serving objects (the hot∪cold union views silver.equipment_values / silver.equipment_events,
-- the pg_duckdb read_parquet cold-source views equipment_values / equipment_events, the disjointness
-- boundary tables ev_union_boundary / ee_union_boundary, the R1 allow-list
-- promoted_enterprise and the R5 stamp cold_append_watermark) live in `cold`, NOT public.
-- public is left holding ONLY the pg_duckdb / postgres_fdw extension objects
-- (read_parquet, duckdb.*, the DuckDB aggregates). We set search_path = cold, public
-- so the objects below are CREATED in cold by their bare names AND their unqualified
-- inter-references (equipment_values, ev_union_boundary, …) resolve to cold at creation (then bind by
-- OID), while read_parquet still resolves from public. The DB-level search_path also
-- lets the gateway-internal, unqualified-name scripts (refresh-equipment_values-cutover.sql,
-- refresh-ee-cutover.sql, stamp-equipment_values-meta.sql, the staleness/coverage monitors)
-- resolve cold on their own fresh psql sessions. EXTERNAL consumers (read-api,
-- Superset) address cold.silver.equipment_values explicitly and do not rely on this GUC.
CREATE SCHEMA IF NOT EXISTS cold;
-- Medallion serving surface — mirrors packiot_analytics so historian names correlate 1:1
-- (ADR-0057). silver.equipment_values / .equipment_events are the hot∪cold union views;
-- gold holds OEE. live + cold are internal physical-tier schemas (FDW hot / Parquet cold).
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
ALTER DATABASE "${POSTGRES_DB}" SET search_path = cold, public;
SET search_path = cold, public;

-- COLD: S3 Parquet historian via pg_duckdb. Scoped read-only key (instance-role
-- credential_chain is unavailable: the DB enforces IMDSv2 and DuckDB's aws
-- extension cannot fetch v2 creds through the docker hop).
SELECT duckdb.create_simple_secret('S3','${HIST_AWS_KEY}','${HIST_AWS_SECRET}','','${AWS_REGION:-us-east-1}');

-- Only *-legacy.parquet == the deep-remapped legacy backfill. Surfaces the hive
-- partition columns year/month so a bounded query can PRUNE (T3, see header).
-- Serving surface = {gross, net, speed} (canonical, narrow — a production-series
-- server, not a raw mirror). `speed` is present in every *-legacy.parquet on disk,
-- so it is surfaced without a re-unload.
CREATE OR REPLACE VIEW equipment_values AS
SELECT r['ts_value']::timestamp               AS ts_value,
       r['enterprise']::int                   AS id_enterprise,
       r['year']::int                         AS year,
       r['month']::int                        AS month,
       r['id_equipment']::int                 AS id_equipment,
       r['gross_production_incr']::double precision AS gross_production_incr,
       r['net_production_incr']::double precision   AS net_production_incr,
       r['speed']::double precision           AS speed
FROM read_parquet('s3://${HISTORIAN_BUCKET}/equipment_values/*/*/*/*-legacy.parquet',
                  hive_partitioning => true) r;

-- ── Promotion ALLOW-LIST (t271) — the SOLE cold-side tenant-isolation gate ────
-- The cold S3 archive is keyed by RAW-LEGACY enterprise ids whose numeric values
-- COLLIDE with F3 tenant ids (e.g. legacy partition enterprise=6 holds a DIFFERENT
-- company's data than the draft F3 tenant 6 / MONTEBELLO). The tenant fence is a
-- caller-supplied `id_enterprise = <literal>`, so without a gate a query for a
-- colliding id serves another company's legacy production (HARDPROOF 2026-09-14:
-- silver.equipment_values id_enterprise=6 for 2024-01 returned 16,731,194 legacy rows).
--
-- FIX: an explicit allow-list. An id is promoted ONLY when the cold partition
-- enterprise=<id> is VERIFIED to belong to the current F3 tenant of that id —
-- cold DISTINCT id_equipment ⊆ core.equipments(id) AND core.equipments(id) is
-- non-empty (a genuine remap, not a raw-legacy passthrough). silver.equipment_values / silver.equipment_events
-- INNER JOIN this on the COLD side, so a non-promoted id (incl. a future F3 tenant
-- given a colliding low id) gets ZERO cold rows. The full raw-legacy archive stays
-- queryable for reference via equipment_values / equipment_events (NOT tenant-facing). Extend ONLY via a
-- verified promotion (scripts/historian-events-reunload.sh for EE); NEVER hand-add
-- an unverified id. Derivation is DELIBERATELY materialized (an explicit audited
-- list), not an auto-recomputed query, so a misfiring derivation cannot silently
-- re-open the leak.
CREATE TABLE IF NOT EXISTS promoted_enterprise (
  id_enterprise int PRIMARY KEY,
  ev_promoted   boolean NOT NULL DEFAULT false,
  ee_promoted   boolean NOT NULL DEFAULT false,
  provenance    text    NOT NULL,
  note          text,
  promoted_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE promoted_enterprise IS
  'Historian promotion allow-list — the SOLE tenant-isolation gate for the COLD side of silver.equipment_values (EV) and silver.equipment_events (EE). Promoted iff cold id_equipment ⊆ core.equipments(id) AND core.equipments(id) non-empty (verified F3 remap, not a raw-legacy id-collision). silver.equipment_values/silver.equipment_events INNER JOIN this on the cold side. Full raw-legacy archive stays queryable via equipment_values/equipment_events (not tenant-facing). Extend only via a verified promotion; never hand-add an unverified id.';
-- Seed derived live 2026-09-14 via the ownership test (cold id_equipment ⊆ core.equipments(id)):
--   ent3 CPACK    — cold EV/EE {47..108} == core.equipments(3), legacy-1→3 → ev+ee
--   ent4 Incoplast— cold EV {990015..990018} == core.equipments(4), legacy-33→4 → ev only
--                   (EE still legacy-33, equipment un-remapped → not promotable without an external map)
-- Counter-examples NOT promoted (raw-legacy id collisions): ent6 {134..852} vs core.equipments(6)=∅
--   (MONTEBELLO draft); ent13 {0..865} vs ∅ (NEOPAC draft); ent2 {160..184} ⊄ {3,4,5}; ent1000000 vs ∅.
INSERT INTO promoted_enterprise (id_enterprise, ev_promoted, ee_promoted, provenance, note) VALUES
  (3, true,  true,  'f3_remapped', 'CPACK — legacy 1→F3 3; cold id_equipment {47..108} == core.equipments(3)'),
  (4, true,  false, 'f3_remapped', 'Incoplast — legacy 33→F3 4; cold EV {990015..990018} == core.equipments(4). EE not promoted (legacy-33 EE un-remapped).')
ON CONFLICT (id_enterprise) DO UPDATE
  SET ev_promoted=EXCLUDED.ev_promoted, ee_promoted=EXCLUDED.ee_promoted,
      provenance=EXCLUDED.provenance, note=EXCLUDED.note;

-- t282/R2 — COLD ID-SPACE PROVENANCE (documentary; ev/ee_promoted=false ⇒ the views
-- ignore these rows). Records EVERY id that has a cold S3 partition so
-- `SELECT id_enterprise, provenance, ev_promoted FROM promoted_enterprise` is the
-- complete, auditable R1 collision blocklist. Provenance derived live 2026-09-14 from
-- `aws s3 ls .../equipment_values|equipment_events*/` ⋈ core.enterprises/core.equipments.
INSERT INTO promoted_enterprise (id_enterprise, ev_promoted, ee_promoted, provenance, note) VALUES
  (5,       false, false, 'f3_native',                'Bispharma-Staging — F3-native EV cold from the staging append. Promotion PENDING ownership verification.'),
  (2,       false, false, 'legacy_collision_live_f3', 'Simulator Corp (live F3) — cold EV {160..184} ⊄ core.equipments(2); raw-legacy collision. Allow-list denies its cold.'),
  (1000000, false, false, 'legacy_collision_live_f3', 'PACKIOT-ADMIN (live F3, 0 equip) — cold EV {111..113} raw-legacy. Not served.'),
  (0,       false, false, 'legacy_passthrough',       'Raw-legacy EV cold (id 0 unassigned). No live F3 tenant. Never assign a new tenant this id.'),
  (6,       false, false, 'legacy_passthrough',       'MONTEBELLO draft (core.equipments(6)=∅) — cold EV {134..852} raw-legacy.'),
  (10,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (13,      false, false, 'legacy_passthrough',       'NEOPAC draft (core.equipments(13)=∅) — cold EV {0..865} raw-legacy.'),
  (30,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (31,      false, false, 'legacy_passthrough',       'Raw-legacy EV+EE cold; no live F3 tenant.'),
  (33,      false, false, 'legacy_passthrough',       'Raw-legacy EE-only cold (Incoplast legacy id → F3 4; EE not yet re-unloaded).'),
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
  WHERE promoted_enterprise.ev_promoted = false
    AND promoted_enterprise.ee_promoted = false;

-- t282/R5 — cold_append_watermark: append-stamp table for the cheap staleness monitor (R4). The
-- append post-run hook (stamp-equipment_values-meta.sql) writes last_append_at; the monitor flags a
-- missed refresh hook when last_append_at > ev_union_boundary.refreshed_at (no parquet scan).
CREATE TABLE IF NOT EXISTS cold_append_watermark (
  id_enterprise    int PRIMARY KEY,
  last_append_at   timestamptz NOT NULL,
  last_append_rows bigint,
  window_end       timestamptz,
  source           text        NOT NULL DEFAULT 'historian-append',
  updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE cold_append_watermark IS
  'Per-enterprise last-append stamp for the COLD store (mirrors the S3 _watermark). '
  'Written by the append post-run hook (stamp-equipment_values-meta.sql). Lets '
  'historian-staleness-monitor.sh flag a MISSED refresh-equipment_values-cutover hook cheaply: '
  'last_append_at > ev_union_boundary.refreshed_at ⇒ cold grew after the last refresh ⇒ '
  'silver.equipment_values double-counting the newly-archived window (sweep R4/R5).';

-- ── Per-enterprise cutover boundary (T2b) ────────────────────────────────────
-- cutover_ts = max(equipment_values.ts_value) for the enterprise. COLD owns ts <= cutover_ts,
-- HOT owns ts > cutover_ts. Small table (one row per historian enterprise), read
-- on the HOT side only (a pure PG join — no DuckDB involvement, so the cold scan
-- stays a prunable DuckDBScan).
CREATE TABLE IF NOT EXISTS ev_union_boundary (
  id_enterprise int PRIMARY KEY,
  cutover_ts    timestamp NOT NULL,
  refreshed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ev_union_boundary IS
  'T2b legacy-priority boundary: cutover_ts = max(equipment_values.ts_value) per enterprise. '
  'COLD owns ts<=cutover_ts, HOT owns ts>cutover_ts. MUST be refreshed by '
  'the cutover refresh at init and after every historian backfill/append that '
  'extends the cold store, else the newly-archived window double-counts.';

-- Refresh cutover_ts = max(equipment_values.ts_value) per enterprise. This is a FULL one-pass
-- scan of the legacy parquet (minutes on the 336M-row CPACK partition) — NOT cheap,
-- so it runs ONCE here at first-boot and must be re-run OUT-OF-BAND after each
-- backfill (companion 11-refresh-equipment_values-cutover.sql, driven by the append job's
-- post-run hook), NEVER per query.
--
-- IMPORTANT (pg_duckdb limitation): this scan reads the `equipment_values` parquet view, and
-- pg_duckdb CANNOT execute a DuckDB scan inside a PL/pgSQL function ("DuckDB
-- execution is not supported inside functions"). So the refresh MUST be a
-- TOP-LEVEL statement, not a function call. Seed it inline here:
-- t271: seed ONLY promoted enterprises. A cutover row for a non-served (non-promoted)
-- enterprise would wrongly clip that tenant's HOT history, so the boundary set MUST
-- track the ev_promoted allow-list.
INSERT INTO ev_union_boundary (id_enterprise, cutover_ts, refreshed_at)
SELECT h.id_enterprise, max(h.ts_value), now()
  FROM equipment_values h
  JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ev_promoted
 WHERE h.id_enterprise IS NOT NULL
 GROUP BY h.id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

-- ── Unified hot+cold, LEGACY-PRIORITY (T2b) + partition columns (T3) ──────────
-- HOT: live rows STRICTLY NEWER than this enterprise's historian coverage.
--   LEFT JOIN so a live-only enterprise (no cutover row) keeps ALL its live rows.
--   (If an IN-HISTORIAN enterprise is missing its cutover row, this keeps all its
--    live rows AND equipment_values keeps all its rows -> double-count. The inline cutover seed
--    at init + refresh-equipment_values-cutover.sql after each backfill upholds the "every
--    historian enterprise has a row" invariant that prevents this.)
-- COLD: the promoted historian archive only (t271 — INNER JOIN the allow-list so a
--   raw-legacy / colliding id serves 0 cold rows). Promoted cold rows are all
--   <= cutover_ts by construction, so no extra ts filter is needed and the
--   DuckDBScan stays prunable.
CREATE OR REPLACE VIEW silver.equipment_values AS
  SELECT lv.ts_value,
         lv.id_enterprise,
         EXTRACT(YEAR  FROM lv.ts_value)::int  AS year,
         EXTRACT(MONTH FROM lv.ts_value)::int  AS month,
         lv.id_equipment,
         lv.gross_production_incr,
         lv.net_production_incr,
         lv.speed
    FROM live.equipment_values lv
    LEFT JOIN ev_union_boundary c ON c.id_enterprise = lv.id_enterprise
   WHERE c.cutover_ts IS NULL OR lv.ts_value > c.cutover_ts
  UNION ALL
  SELECT h.ts_value,
         h.id_enterprise,
         h.year,
         h.month,
         h.id_equipment,
         h.gross_production_incr,
         h.net_production_incr,
         h.speed
    FROM cold.equipment_values h
    JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ev_promoted;

-- ═══════════════════════════════════════════════════════════════════════════
-- production_orders (PO) — per-PO OEE headline hot+cold union (historian PO archive).
--   Analytics keeps ~3 months of POs; the full history (legacy 2021-12 →) is archived
--   to cold by scripts/historian-po-backfill.sh (legacy->F3 remap). COLD-anchored
--   (EV-style): legacy holds the deep history, analytics (hot FDW) the recent tail.
-- ═══════════════════════════════════════════════════════════════════════════
-- Promotion gate: reuse promoted_enterprise (the SOLE cold-side tenant fence). Add a
-- po_promoted flag (idempotent for both fresh init and an already-running gateway).
ALTER TABLE promoted_enterprise ADD COLUMN IF NOT EXISTS po_promoted boolean NOT NULL DEFAULT false;
-- CPACK (ent3) cold POs are the legacy 1->3 remap (id_equipment {47..108} == core.equipments(3)),
-- the same verified ownership as ev/ee_promoted. Promote it for PO.
UPDATE promoted_enterprise SET po_promoted = true WHERE id_enterprise = 3;

-- HOT PO: PINNED foreign table (only the served PO fields) from analytics core.production_orders.
DROP FOREIGN TABLE IF EXISTS live.production_orders;
CREATE FOREIGN TABLE live.production_orders (
  ts_start          timestamptz,
  ts_end            timestamptz,
  id_enterprise     integer,
  id_equipment      integer,
  id_order          bigint,
  status            integer,
  gross_production  double precision,
  net_production    double precision,
  oee_a             double precision,
  oee_p             double precision,
  oee_q             double precision,
  oee               double precision,
  running_time      integer,
  stopped_time      integer,
  available_time    integer,
  planned_downtime  integer
) SERVER live_pg OPTIONS (schema_name 'core', table_name 'production_orders');

-- COLD PO: S3 Parquet (only *-legacy.parquet == the deep-remapped legacy backfill), surfacing
-- the hive partition columns year/month so a bounded query can PRUNE (T3).
CREATE OR REPLACE VIEW production_orders AS
SELECT r['ts_start']::timestamp               AS ts_start,
       r['ts_end']::timestamp                 AS ts_end,
       r['enterprise']::int                   AS id_enterprise,
       r['year']::int                         AS year,
       r['month']::int                        AS month,
       r['id_equipment']::int                 AS id_equipment,
       r['id_order']::bigint                  AS id_order,
       r['status']::int                       AS status,
       r['gross_production']::double precision AS gross_production,
       r['net_production']::double precision  AS net_production,
       r['oee_a']::double precision           AS oee_a,
       r['oee_p']::double precision           AS oee_p,
       r['oee_q']::double precision           AS oee_q,
       r['oee']::double precision             AS oee,
       r['running_time']::int                 AS running_time,
       r['stopped_time']::int                 AS stopped_time,
       r['available_time']::int               AS available_time,
       r['planned_downtime']::int             AS planned_downtime
FROM read_parquet('s3://${HISTORIAN_BUCKET}/production_orders/*/*/*/*-legacy.parquet',
                  hive_partitioning => true) r;

-- Per-enterprise cutover boundary (cold-anchored): cutover_ts = max(cold.production_orders.ts_start).
-- COLD owns ts_start <= cutover, HOT owns ts_start > cutover. Read on the HOT side only (pure PG
-- join, no DuckDB — keeps the cold scan a prunable DuckDBScan). MUST be refreshed by
-- refresh-po-cutover.sql at init and after every PO backfill, else the newly-archived window
-- double-counts. Seed inline here (a TOP-LEVEL parquet scan — never a function).
CREATE TABLE IF NOT EXISTS po_union_boundary (
  id_enterprise int PRIMARY KEY,
  cutover_ts    timestamp NOT NULL,
  refreshed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE po_union_boundary IS
  'Cold-anchored PO boundary: cutover_ts = max(production_orders.ts_start) per enterprise. '
  'COLD owns ts_start<=cutover_ts, HOT owns >. MUST be refreshed (refresh-po-cutover.sql) at '
  'init and after every PO backfill that extends the cold store, else silver.production_orders '
  'double-counts the newly-archived window. Only po_promoted enterprises get a row.';
INSERT INTO po_union_boundary (id_enterprise, cutover_ts, refreshed_at)
SELECT h.id_enterprise, max(h.ts_start), now()
  FROM production_orders h
  JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.po_promoted
 WHERE h.id_enterprise IS NOT NULL
 GROUP BY h.id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

-- Unified hot+cold, LEGACY-PRIORITY (cold-anchored) + partition columns.
-- HOT: live POs strictly newer than this enterprise's historian coverage (LEFT JOIN so a
--   live-only enterprise with no cutover row keeps all its live POs).
-- COLD: promoted historian archive only (INNER JOIN po_promoted); all <= cutover by construction.
CREATE OR REPLACE VIEW silver.production_orders AS
  SELECT lp.ts_start, lp.ts_end, lp.id_enterprise,
         EXTRACT(YEAR  FROM lp.ts_start)::int AS year,
         EXTRACT(MONTH FROM lp.ts_start)::int AS month,
         lp.id_equipment, lp.id_order, lp.status,
         lp.gross_production, lp.net_production, lp.oee_a, lp.oee_p, lp.oee_q, lp.oee,
         lp.running_time, lp.stopped_time, lp.available_time, lp.planned_downtime
    FROM live.production_orders lp
    LEFT JOIN po_union_boundary c ON c.id_enterprise = lp.id_enterprise
   WHERE c.cutover_ts IS NULL OR lp.ts_start > c.cutover_ts
  UNION ALL
  SELECT h.ts_start, h.ts_end, h.id_enterprise, h.year, h.month,
         h.id_equipment, h.id_order, h.status,
         h.gross_production, h.net_production, h.oee_a, h.oee_p, h.oee_q, h.oee,
         h.running_time, h.stopped_time, h.available_time, h.planned_downtime
    FROM cold.production_orders h
    JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.po_promoted;

-- ── ev_between(): REMOVED (t269 / necessity audit) ───────────────────────────
-- Was a year/month-pruning helper, but a SQL function body cannot execute pg_duckdb's
-- read_parquet (pushdown ships to DuckDB which has no PG function context) → calling it
-- errors "Function 'public.read_parquet' only works with DuckDB execution". read-api /
-- tools use the `silver.equipment_values` VIEW (which inlines the same predicates) instead — this helper
-- had ZERO live callers and was a footgun (looks callable, always errors). Dropped.

-- ═══════════════════════════════════════════════════════════════════════════
-- equipment_events (EE) — downtime / OEE-reconstruction hot+cold union
--                         (task #227 / historian-clean-schema-redesign §8-EE)
-- ═══════════════════════════════════════════════════════════════════════════
-- The EE cold archive was backfilled with LEGACY enterprise ids whose values
-- collide numerically with real F3 tenant ids, so serving them unfiltered is a
-- CROSS-TENANT LEAK. t271: isolation is now the promoted_enterprise ALLOW-LIST
-- (silver.equipment_events INNER JOINs it on ee_promoted), NOT a path split. equipment_events globs the
-- FULL archive (both equipment_events/ and the former _unpromoted/ prefix); the
-- allow-list decides what silver.equipment_events serves. To promote a tenant: verify cold
-- id_equipment ⊆ core.equipments(id), re-key its partition to the F3 id on disk
-- (scripts/historian-events-reunload.sh, "partition key IS the F3 id, no in-view
-- CASE"), then set ee_promoted=true for that id (the reunload script does both).
--
-- ── WHY THE EE BOUNDARY IS THE **MIRROR** OF ev_union_boundary ──────────────────────
-- ev_union_boundary (EV) is COLD-anchored: cold is the full archive, hot is the live
-- tail, cutover = max(cold ts), COLD owns ts<=cutover / HOT owns ts>cutover.
-- EE is the OPPOSITE. db/cutover/f3-phasec-history-backfill.sql loaded ~197k CPACK
-- pre-cutover events INTO the hot F3 store (ent-3) WITH irreplaceable operator
-- reasons/notes — surfaced in v_report_downtimes. So for EE the HOT store holds the
-- deep history AND the live tail (continuous from its earliest event), and the cold
-- archive OVERLAPS it. A naïve hot ∪ cold DOUBLE-COUNTS the overlap (HARDPROOF,
-- staging ent-3, window 2026-04-01..2026-09-08: naïve=432,801 vs correct=316,688;
-- 116,113 rows double-counted). So EE is HOT-ANCHORED:
--   ee_union_boundary.cutover_ts = min(hot ts_event) per enterprise
--   COLD owns ts_event <  cutover_ts   (the pre-hot window only)
--   HOT  owns ts_event >= cutover_ts   (its whole covered range — every hot row
--                                        is >= its own min, so hot keeps ALL rows)
-- Disjoint at a single instant per enterprise => no double-count, no gap.
-- HARDPROOF (staging ent-3): union 316,688 == cold_kept 53,959 + hot_kept 262,729.
--
-- NOTE (completeness caveat, for analytics-owner coordination): handing the
-- overlap window to hot assumes hot fully covers it for all equipment. Equipment
-- present in cold-but-not-hot for that window would be under-covered (NOT double-
-- counted — the conservative failure mode). Revisit if a promoted tenant's hot
-- deep-history backfill is known-partial.
CREATE OR REPLACE VIEW equipment_events AS
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
-- t271: glob the FULL EE archive — BOTH the promoted prefix AND the former
-- equipment_events_legacy_unpromoted/ holdout. Isolation is now the allow-list
-- (silver.equipment_events INNER JOINs promoted_enterprise on ee_promoted), NOT the
-- path split. The _unpromoted prefix is retired as a security boundary and is now
-- merely reference storage; equipment_events is the full reference surface.
FROM read_parquet(
       ARRAY['s3://${HISTORIAN_BUCKET}/equipment_events/*/*/*/*-legacy.parquet',
             's3://${HISTORIAN_BUCKET}/equipment_events_legacy_unpromoted/*/*/*/*-legacy.parquet'],
       hive_partitioning => true) r;

CREATE TABLE IF NOT EXISTS ee_union_boundary (
  id_enterprise int PRIMARY KEY,
  cutover_ts    timestamp NOT NULL,
  refreshed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ee_union_boundary IS
  'EE disjointness boundary. UNLIKE ev_union_boundary (cold-anchored: cutover=max(cold ts)), '
  'this is HOT-ANCHORED: cutover_ts = min(hot ts_event) per enterprise. COLD owns '
  'ts_event < cutover_ts, HOT owns ts_event >= cutover_ts. Refresh reads the hot FDW '
  '(a cheap PG aggregate — NOT a parquet scan), so it MAY run in a function/simple '
  'statement (companion refresh-ee-cutover.sql). Re-run after any change to the hot '
  'EE earliest event (e.g. a further deep-history backfill).';

-- Seed cutover = min(hot ts_event) per enterprise (reads the FDW, not parquet).
-- t271: only ee_promoted enterprises — the cutover gates the promoted cold side only.
INSERT INTO ee_union_boundary (id_enterprise, cutover_ts, refreshed_at)
SELECT lv.id_enterprise, min(lv.ts_event)::timestamp, now()
  FROM live.equipment_events lv
  JOIN promoted_enterprise p ON p.id_enterprise = lv.id_enterprise AND p.ee_promoted
 WHERE lv.id_enterprise IS NOT NULL
 GROUP BY lv.id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

-- Hot+cold EE union, HOT-ANCHORED (see header). HOT keeps ALL live rows; COLD
-- (LEFT JOIN cutover) keeps its pre-hot window, or ALL rows for a cold-only tenant
-- (no cutover row). year/month surfaced so a bounded query prunes the cold parquet.
CREATE OR REPLACE VIEW silver.equipment_events AS
  SELECT lv.ts_event::timestamp                    AS ts_event,
         lv.id_enterprise,
         EXTRACT(YEAR  FROM lv.ts_event)::int       AS year,
         EXTRACT(MONTH FROM lv.ts_event)::int       AS month,
         lv.id_equipment,
         lv.ts_end::timestamp                       AS ts_end,
         lv.duration,
         lv.status,
         lv.planned_downtime,
         lv.cd_category,
         lv.desc_category,
         lv.cd_subcategory,
         lv.desc_subcategory,
         lv.txt_downtime_notes
    FROM live.equipment_events lv
  UNION ALL
  SELECT h.ts_event, h.id_enterprise, h.year, h.month, h.id_equipment,
         h.ts_end, h.duration, h.status, h.planned_downtime,
         h.cd_category, h.desc_category, h.cd_subcategory, h.desc_subcategory,
         h.txt_downtime_notes
    FROM cold.equipment_events h
    JOIN promoted_enterprise p ON p.id_enterprise = h.id_enterprise AND p.ee_promoted
    LEFT JOIN ee_union_boundary c ON c.id_enterprise = h.id_enterprise
   WHERE c.cutover_ts IS NULL OR h.ts_event < c.cutover_ts;

-- ═══════════════════════════════════════════════════════════════════════════
-- OBJECT DOCUMENTATION (COMMENT ON …) — born-documented gateway.
-- Mirrors db/migrations/t-histdb-object-docs/01-comments.sql. Idempotent; the
-- two boundary-table COMMENTs above are subsumed here (last-write-wins).
-- Keep the two in sync when a view/column changes.
-- ═══════════════════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════════ schemas
COMMENT ON SCHEMA cold IS
  'Historian COLD-store + hot∪cold union serving schema (t287; SYMMETRIC with `live`, the hot FDW schema). Holds the union VIEWS silver.equipment_values (EV) / silver.equipment_events (EE), the pg_duckdb read_parquet COLD source views equipment_values / equipment_events, the per-enterprise disjointness boundary TABLES ev_union_boundary / ee_union_boundary, the R1 tenant-isolation allow-list promoted_enterprise, and the R5 append-stamp cold_append_watermark. Query surface for read-api /v1/historian (cold.silver.equipment_values / cold.silver.equipment_events) and the Superset silver.equipment_values virtual dataset. No RLS engine here — tenant fence is a caller-supplied id_enterprise literal.';
COMMENT ON SCHEMA public IS
  'pg_duckdb + postgres_fdw EXTENSION objects only (read_parquet, duckdb.*, the DuckDB aggregates). The historian serving objects live in schema `cold` (t287). Do NOT create historian objects here.';
COMMENT ON SCHEMA live IS
  'Foreign-table schema: postgres_fdw window onto the HOT live timescaledb (server live_pg → packiot_analytics.silver on 10.10.10.89). live.equipment_values / live.equipment_events are the hot side of the silver.equipment_values / silver.equipment_events unions. Pinned/narrow imports — the FDW only ships referenced columns, so remote column prunes cannot break these.';

-- ═══════════════════════════════════════════════════════ live.equipment_values
COMMENT ON FOREIGN TABLE live.equipment_values IS
  'HOT side of silver.equipment_values. postgres_fdw foreign table onto packiot_analytics.silver.equipment_values (the live production-series hypertable) via server live_pg. PINNED column set (declared, not IMPORT-ed): only the 8 serving columns are mounted, so dropping a dead column on the remote can never break this table (postgres_fdw ships only referenced columns). A ts_value predicate pushes down to remote chunk-exclusion.';
COMMENT ON COLUMN live.equipment_values.ts_value IS 'Reading timestamp (timestamptz). Pushdown predicate for remote chunk-exclusion on the hot side.';
COMMENT ON COLUMN live.equipment_values.id_enterprise IS 'Tenant id. THE tenant fence for the hot side — callers must supply id_enterprise as a literal.';
COMMENT ON COLUMN live.equipment_values.id_site IS 'Site id (hierarchy: enterprise→site→area→equipment).';
COMMENT ON COLUMN live.equipment_values.id_area IS 'Area id.';
COMMENT ON COLUMN live.equipment_values.id_equipment IS 'Equipment id producing the reading.';
COMMENT ON COLUMN live.equipment_values.gross_production_incr IS 'Gross production increment for the reading interval (real).';
COMMENT ON COLUMN live.equipment_values.net_production_incr IS 'Net (good) production increment for the reading interval (real).';
COMMENT ON COLUMN live.equipment_values.speed IS 'Instantaneous line/machine speed at the reading (real).';

-- ═══════════════════════════════════════════════════════ live.equipment_events
COMMENT ON FOREIGN TABLE live.equipment_events IS
  'HOT side of silver.equipment_events. postgres_fdw foreign table onto packiot_analytics.silver.equipment_events (downtime / OEE-reconstruction events) via server live_pg. t282/R8: PINNED to the 12 columns silver.equipment_events serves (was a 26-col IMPORT) — prune-proof like live.equipment_values: a remote drop/rename of an un-served EE column cannot break this table. Also holds the CPACK Phase-C deep-history backfill (pre-cutover events loaded INTO hot with irreplaceable operator reasons) — see ee_union_boundary for why EE is hot-anchored.';
COMMENT ON COLUMN live.equipment_events.id_equipment IS 'Equipment id the event belongs to.';
COMMENT ON COLUMN live.equipment_events.ts_event IS 'Event start timestamp (timestamptz). min(ts_event) per enterprise = the EE cutover boundary (ee_union_boundary).';
COMMENT ON COLUMN live.equipment_events.status IS 'Event/machine status code (e.g. running/stopped). Surfaced by silver.equipment_events.';
COMMENT ON COLUMN live.equipment_events.txt_downtime_notes IS 'Free-text operator downtime note. Irreplaceable — the reason the Phase-C history was loaded into hot rather than left cold-only.';
COMMENT ON COLUMN live.equipment_events.cd_category IS 'Downtime category code (canonical).';
COMMENT ON COLUMN live.equipment_events.cd_subcategory IS 'Downtime subcategory code (canonical).';
COMMENT ON COLUMN live.equipment_events.planned_downtime IS 'True if the downtime is planned (excluded from availability loss).';
COMMENT ON COLUMN live.equipment_events.ts_end IS 'Event end timestamp; NULL/open while the event is ongoing.';
COMMENT ON COLUMN live.equipment_events.duration IS 'Event duration in seconds.';
COMMENT ON COLUMN live.equipment_events.id_enterprise IS 'Tenant id. THE tenant fence for the hot EE side.';
COMMENT ON COLUMN live.equipment_events.desc_category IS 'Human-readable downtime category description.';
COMMENT ON COLUMN live.equipment_events.desc_subcategory IS 'Human-readable downtime subcategory description.';

-- ═══════════════════════════════════════════════════════════════════ equipment_values (COLD EV)
COMMENT ON VIEW equipment_values IS
  'COLD side of silver.equipment_values. pg_duckdb view over the S3 Parquet historian: read_parquet(''s3://<HISTORIAN_BUCKET>/equipment_values/*/*/*/*-legacy.parquet'', hive_partitioning=>true). *-legacy.parquet = the deep-remapped legacy backfill (F3 id-space; on staging the CPACK partition is 336M rows spanning 2021→~today). Surfaces the hive partition columns year/month so a bounded query PRUNES the cold scan (T3: ts_value alone does NOT prune — DuckDB prunes only on partition cols; 59 files/171s vs 1 file/0.57s with a year/month predicate). Serving surface is narrow: {gross, net, speed}. NOTE: a query touching this view must run under the SIMPLE query protocol (pg_duckdb does not apply the S3 secret on the prepared-statement path) and CANNOT be wrapped in a SQL/PLpgSQL function (DuckDB has no PG function context — ev_between was dropped for exactly this).';
COMMENT ON COLUMN equipment_values.ts_value IS 'Reading timestamp (parquet r[''ts_value'']::timestamp). Cold side is unfiltered in silver.equipment_values — all cold rows are <= the enterprise cutover_ts by construction.';
COMMENT ON COLUMN equipment_values.id_enterprise IS 'Tenant id from the parquet (hive enterprise= partition remapped to F3 id-space). Tenant fence literal prunes to one enterprise= partition.';
COMMENT ON COLUMN equipment_values.year IS 'Hive partition column (year=). PRUNE key — carry a year predicate to avoid a full-archive scan.';
COMMENT ON COLUMN equipment_values.month IS 'Hive partition column (month=). PRUNE key — carry a month predicate alongside year.';
COMMENT ON COLUMN equipment_values.id_equipment IS 'Equipment id from the parquet.';
COMMENT ON COLUMN equipment_values.gross_production_incr IS 'Gross production increment (parquet, double precision).';
COMMENT ON COLUMN equipment_values.net_production_incr IS 'Net (good) production increment (parquet, double precision).';
COMMENT ON COLUMN equipment_values.speed IS 'Speed (parquet, double precision). Present in every *-legacy.parquet, surfaced without a re-unload.';

-- ═══════════════════════════════════════════════════════════════════ equipment_events (COLD EE)
COMMENT ON VIEW equipment_events IS
  'COLD side of silver.equipment_events. pg_duckdb view over read_parquet(''s3://<HISTORIAN_BUCKET>/equipment_events/*/*/*/*-legacy.parquet'', hive_partitioning=>true). Only VERIFIED-F3-remapped partitions live under equipment_events/ — un-promoted legacy partitions are held under equipment_events_legacy_unpromoted/ and NOT globbed (their legacy ids collide with real F3 tenant ids ⇒ serving them would be a CROSS-TENANT LEAK). Surfaces year/month for partition pruning. Same pg_duckdb constraints as equipment_values (simple protocol, no function wrapping).';
COMMENT ON COLUMN equipment_events.ts_event IS 'Event start timestamp (parquet). In silver.equipment_events the cold side is kept only where ts_event < the enterprise cutover_ts (EE is HOT-anchored — see ee_union_boundary).';
COMMENT ON COLUMN equipment_events.id_enterprise IS 'Tenant id from the parquet hive enterprise= partition (F3-remapped). Tenant fence + partition prune key.';
COMMENT ON COLUMN equipment_events.year IS 'Hive partition column (year=). PRUNE key.';
COMMENT ON COLUMN equipment_events.month IS 'Hive partition column (month=). PRUNE key.';
COMMENT ON COLUMN equipment_events.id_equipment IS 'Equipment id from the parquet.';
COMMENT ON COLUMN equipment_events.ts_end IS 'Event end timestamp (parquet).';
COMMENT ON COLUMN equipment_events.duration IS 'Event duration in seconds (parquet).';
COMMENT ON COLUMN equipment_events.status IS 'Event/machine status code (parquet).';
COMMENT ON COLUMN equipment_events.planned_downtime IS 'True if the downtime is planned (parquet).';
COMMENT ON COLUMN equipment_events.cd_category IS 'Downtime category code (parquet).';
COMMENT ON COLUMN equipment_events.desc_category IS 'Downtime category description (parquet).';
COMMENT ON COLUMN equipment_events.cd_subcategory IS 'Downtime subcategory code (parquet).';
COMMENT ON COLUMN equipment_events.desc_subcategory IS 'Downtime subcategory description (parquet).';
COMMENT ON COLUMN equipment_events.txt_downtime_notes IS 'Free-text operator downtime note (parquet).';

-- ═══════════════════════════════════════════════════════════════════ silver.equipment_values (EV union)
COMMENT ON VIEW silver.equipment_values IS
  'PRUNE CONTRACT (READ FIRST, t282/R6): a bounded query MUST carry a year AND month predicate (e.g. year=2026 AND month=9) — ts_value alone does NOT prune the cold parquet (59 files/171s without vs 1 file/0.57s with). No year/month ⇒ FULL-ARCHIVE SCAN. Keep silver.equipment_values OUT of Superset SQL Lab. Every query MUST also carry an id_enterprise=<literal> tenant fence (no RLS here). ── THE hot+cold EV serving surface, no double-count. LEGACY-PRIORITY (T2b): COLD (equipment_values, ev_promoted only) owns ts_value <= cutover_ts, HOT (live.equipment_values) owns ts_value > cutover_ts, cutover_ts = max(equipment_values.ts_value) per enterprise (ev_union_boundary). Implemented as: live LEFT JOIN ev_union_boundary WHERE cutover_ts IS NULL OR ts_value > cutover_ts  UNION ALL  equipment_values JOIN allow-list. Invariant: every ev_promoted enterprise MUST have a ev_union_boundary row. Surfaces year/month (hot via EXTRACT, cold = partition cols). read-api /v1/historian/production-series + Superset silver.equipment_values virtual dataset.';
COMMENT ON COLUMN silver.equipment_values.ts_value IS 'Reading timestamp. Hot for ts_value > enterprise cutover_ts, cold for <=.';
COMMENT ON COLUMN silver.equipment_values.id_enterprise IS 'Tenant id. THE tenant fence — every consumer query MUST filter id_enterprise = <literal> (no Postgres RLS on this gateway).';
COMMENT ON COLUMN silver.equipment_values.year IS 'Reading year. Cold = hive partition column (PRUNE KEY); hot = EXTRACT(YEAR FROM ts_value). Omitting it ⇒ full cold scan.';
COMMENT ON COLUMN silver.equipment_values.month IS 'Reading month. Cold = hive partition column (PRUNE KEY); hot = EXTRACT(MONTH FROM ts_value). Carry alongside year.';
COMMENT ON COLUMN silver.equipment_values.id_equipment IS 'Equipment id producing the reading.';
COMMENT ON COLUMN silver.equipment_values.gross_production_incr IS 'Gross production increment (double precision; hot real widened to match cold).';
COMMENT ON COLUMN silver.equipment_values.net_production_incr IS 'Net (good) production increment (double precision).';
COMMENT ON COLUMN silver.equipment_values.speed IS 'Instantaneous speed (double precision).';

-- ═══════════════════════════════════════════════════════════════════ silver.equipment_events (EE union)
COMMENT ON VIEW silver.equipment_events IS
  'PRUNE CONTRACT (READ FIRST, t282/R6): a bounded query MUST carry a year AND month predicate — ts_event alone does NOT prune the cold parquet. No year/month ⇒ FULL-ARCHIVE SCAN. Carry an id_enterprise=<literal> tenant fence on every query (no RLS here). ── THE hot+cold EE (downtime/OEE-event) serving surface, no double-count. HOT-ANCHORED (the MIRROR of silver.equipment_values/ev_union_boundary): the Phase-C backfill loaded deep-history events INTO the hot store, so HOT (live.equipment_events) owns its whole covered range; COLD (equipment_events, ee_promoted only) fills ONLY ts_event < cutover_ts, cutover_ts = min(hot ts_event) per enterprise (ee_union_boundary). HARDPROOF staging ent-3: union 316,688 == cold_kept 53,959 + hot_kept 262,729. Completeness caveat: the overlap window is handed to hot, so equipment cold-but-not-hot there is under-covered — guarded by scripts/historian-ee-coverage-check.sh (R7). Surfaces year/month for cold pruning.';
COMMENT ON COLUMN silver.equipment_events.ts_event IS 'Event start timestamp. Hot for ts_event >= enterprise cutover_ts, cold for <.';
COMMENT ON COLUMN silver.equipment_events.id_enterprise IS 'Tenant id. THE tenant fence — every consumer query MUST filter id_enterprise = <literal>.';
COMMENT ON COLUMN silver.equipment_events.year IS 'Event year. Cold = hive partition column (PRUNE KEY); hot = EXTRACT. Omitting it ⇒ full cold scan.';
COMMENT ON COLUMN silver.equipment_events.month IS 'Event month. Cold = hive partition column (PRUNE KEY); hot = EXTRACT. Carry alongside year.';
COMMENT ON COLUMN silver.equipment_events.id_equipment IS 'Equipment id the event belongs to.';
COMMENT ON COLUMN silver.equipment_events.ts_end IS 'Event end timestamp.';
COMMENT ON COLUMN silver.equipment_events.duration IS 'Event duration in seconds.';
COMMENT ON COLUMN silver.equipment_events.status IS 'Event/machine status code.';
COMMENT ON COLUMN silver.equipment_events.planned_downtime IS 'True if the downtime is planned (excluded from availability loss).';
COMMENT ON COLUMN silver.equipment_events.cd_category IS 'Downtime category code.';
COMMENT ON COLUMN silver.equipment_events.desc_category IS 'Downtime category description.';
COMMENT ON COLUMN silver.equipment_events.cd_subcategory IS 'Downtime subcategory code.';
COMMENT ON COLUMN silver.equipment_events.desc_subcategory IS 'Downtime subcategory description.';
COMMENT ON COLUMN silver.equipment_events.txt_downtime_notes IS 'Free-text operator downtime note (the irreplaceable Phase-C history).';

-- ═══════════════════════════════════════════════════════════════════ ev_union_boundary
COMMENT ON TABLE ev_union_boundary IS
  'T2b EV legacy-priority disjointness boundary. cutover_ts = max(equipment_values.ts_value) per enterprise; in silver.equipment_values COLD owns ts_value <= cutover_ts, HOT owns ts_value > cutover_ts. Small (one row per historian enterprise), read on the hot side only (pure PG join — no DuckDB, so the cold scan stays a prunable DuckDBScan). LOAD-BEARING INVARIANT: every enterprise present in the historian MUST have a row here = max(equipment_values.ts_value). MUST be refreshed (services/historian-gateway/refresh-equipment_values-cutover.sql — a TOP-LEVEL statement, NOT a function: pg_duckdb cannot scan parquet inside a function body) after EVERY historian backfill/append that extends the cold store, else the newly-archived window is served by BOTH sides = double-count.';
COMMENT ON COLUMN ev_union_boundary.id_enterprise IS 'Tenant id (PK). One row per enterprise present in the cold historian.';
COMMENT ON COLUMN ev_union_boundary.cutover_ts IS 'max(equipment_values.ts_value) for the enterprise. The EV boundary: cold owns <= this, hot owns > this.';
COMMENT ON COLUMN ev_union_boundary.refreshed_at IS 'When this boundary row was last recomputed (defaults now()). Stale after a cold-store append until the refresh re-runs.';

-- ═══════════════════════════════════════════════════════════════════ ee_union_boundary
COMMENT ON TABLE ee_union_boundary IS
  'EE disjointness boundary. UNLIKE ev_union_boundary (cold-anchored: cutover=max(cold ts)), this is HOT-ANCHORED: cutover_ts = min(hot ts_event) per enterprise. The Phase-C backfill loaded CPACK deep-history events INTO the hot F3 store (with irreplaceable operator reasons), so hot owns its whole covered range and cold (equipment_events) fills only the pre-hot window. In silver.equipment_events COLD owns ts_event < cutover_ts, HOT owns ts_event >= cutover_ts. Refresh (services/historian-gateway/refresh-ee-cutover.sql) reads the hot FDW (a cheap PG aggregate — NOT a parquet scan), so it MAY run in a function/simple statement. Re-run after any change to the hot EE earliest event (e.g. a further deep-history backfill).';
COMMENT ON COLUMN ee_union_boundary.id_enterprise IS 'Tenant id (PK). One row per enterprise present in the hot EE store.';
COMMENT ON COLUMN ee_union_boundary.cutover_ts IS 'min(hot ts_event) for the enterprise. The EE boundary: cold owns < this, hot owns >= this.';
COMMENT ON COLUMN ee_union_boundary.refreshed_at IS 'When this boundary row was last recomputed (defaults now()).';
SQL

# ── Read-only CloudBeaver browser role (cloudbeaver_histro) ───────────────────
# OPTIONAL, env-gated. When CLOUDBEAVER_HISTRO_PASSWORD is set, create a
# NOSUPERUSER SELECT-only role so staff can browse the gateway from CloudBeaver
# (dbeaver.staging.packiot.app) the same way they browse packiot_analytics — WITHOUT
# reusing the postgres superuser. It gets:
#   * USAGE + SELECT on cold (silver.equipment_values/silver.equipment_events/equipment_values*/cutover tables, t287) and
#     live (the FDW foreign tables) + default privileges for future tables.
#   * a live_pg FDW USER MAPPING (foreign tables need a per-role mapping; without it
#     a hot select throws "user mapping not found"). Maps to the same remote FDW
#     creds as the postgres mapping — the served foreign tables are pinned to 8
#     read-only columns, so the remote identity only ever reads those.
# CAVEAT (documented, by design): pg_duckdb gates read_parquet on superuser OR
# membership in duckdb.postgres_role (unset here, postmaster-context). So the COLD
# path (equipment_values, equipment_events, and the cold rows of silver.equipment_values/silver.equipment_events) errors for this
# role: "DuckDB execution is not allowed because you have not been granted the
# duckdb.postgres_role". Hot FDW tables + schema/cutover browsing — the main goal —
# work fully. To also grant cold reads, set duckdb.postgres_role=cloudbeaver_histro
# in the gateway config (needs a restart) — deliberately NOT done (keeps heavy S3
# scans off an anonymous-ish browser role).
if [ -n "${CLOUDBEAVER_HISTRO_PASSWORD:-}" ]; then
  # t282/R9: repoint the browser FDW identity to the least-privilege remote role
  # histgw_ro (SELECT on the 2 silver facts only) instead of the remote postgres
  # SUPERUSER, so a compromised browser session can't ride superuser into the
  # analytics DB. Falls back to the FDW superuser (with a warning) if HISTGW_RO_PASS
  # is not provisioned yet — mint it via db/migrations/t282-…/02-analytics-histgw-ro.sql.
  if [ -n "${HISTGW_RO_PASS:-}" ]; then
    BROWSER_FDW_USER=histgw_ro; BROWSER_FDW_PASS="${HISTGW_RO_PASS}"
  else
    echo "[historian-gateway] WARNING: HISTGW_RO_PASS unset — cloudbeaver_histro FDW mapping falls back to the remote superuser (sweep R9 not applied)"
    BROWSER_FDW_USER="${FDW_USER}"; BROWSER_FDW_PASS="${FDW_PASS}"
  fi
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
       -v histro_pw="${CLOUDBEAVER_HISTRO_PASSWORD}" \
       -v fdw_user="${BROWSER_FDW_USER}" -v fdw_pass="${BROWSER_FDW_PASS}" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cloudbeaver_histro') THEN
    CREATE ROLE cloudbeaver_histro LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
END $$;
ALTER ROLE cloudbeaver_histro PASSWORD :'histro_pw';
COMMENT ON ROLE cloudbeaver_histro IS
  'Read-only CloudBeaver browser for the historian gateway. NOSUPERUSER: hot FDW '
  '(live.*) + schema/cutover browsing only; cold pg_duckdb read_parquet '
  '(equipment_values/equipment_events/silver.equipment_values cold path) requires superuser or duckdb.postgres_role '
  'membership (unset) and will error.';
-- t287: the historian SELECT surface moved to `cold`; grant it alongside public/live.
GRANT USAGE ON SCHEMA cold, public, live, silver, gold TO cloudbeaver_histro;
GRANT SELECT ON ALL TABLES IN SCHEMA cold, public, live, silver, gold TO cloudbeaver_histro;
ALTER DEFAULT PRIVILEGES IN SCHEMA cold GRANT SELECT ON TABLES TO cloudbeaver_histro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cloudbeaver_histro;
ALTER DEFAULT PRIVILEGES IN SCHEMA live  GRANT SELECT ON TABLES TO cloudbeaver_histro;
-- Foreign tables need a per-role user mapping (else "user mapping not found").
GRANT USAGE ON FOREIGN SERVER live_pg TO cloudbeaver_histro;
DROP USER MAPPING IF EXISTS FOR cloudbeaver_histro SERVER live_pg;
CREATE USER MAPPING FOR cloudbeaver_histro SERVER live_pg
  OPTIONS (user :'fdw_user', password :'fdw_pass');
SQL
  echo "[historian-gateway] cloudbeaver_histro read-only role + FDW mapping ready"
else
  echo "[historian-gateway] CLOUDBEAVER_HISTRO_PASSWORD unset — skipping read-only browser role"
fi

echo "[historian-gateway] init complete: silver.equipment_values (EV hot+cold) + silver.equipment_events (EE hot+cold), ev_union_boundary + ee_union_boundary seeded"
