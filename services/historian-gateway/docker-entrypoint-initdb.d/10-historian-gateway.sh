#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# historian-gateway init — runs once on a fresh pg_duckdb data volume.
#
# Builds the TRANSPARENT HOT+COLD UNION that lets front4 / Superset / any tool
# query old timestamps with plain SQL:
#
#   ev_all  =  live.equipment_values   (postgres_fdw -> the timescaledb hypertable, HOT)
#           UNION ALL
#              hist                     (pg_duckdb  -> S3 Parquet historian,        COLD)
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
#   * hist (the *-legacy.parquet set) for ent3 spans 2021-11-05 .. 2026-09-04
#     (max_ts == TODAY, NOT pre-cutover), 335.7M rows.
#   * live.equipment_values for ent3 starts 2026-07-23 (its F3 cutover) .. now.
#   * On 2026-09-03 BOTH sides hold ent3 rows: hist=196,671 / live=155,465.
#   => a plain UNION ALL returned 352,136 rows for that one day == DOUBLE-COUNT.
# (The *-legacy.parquet on staging is the deep-remap backfill of the STILL-LIVE
#  legacy packiot40 source, so it extends to ~now — it is NOT bounded at a cutover.
#  See docs / the analytics-rename-overnight-report; the "why does legacy reach
#  today" root-cause is an operational question, but the gateway must be correct
#  regardless of how far legacy extends.)
#
# THE FIX — legacy-priority, per-enterprise cutover:
#   cutover(e) = max(hist.ts_value) for enterprise e   (materialized in hist_cutover)
#     COLD owns  ts_value <= cutover(e)   (the full verified archive)
#     HOT  owns  ts_value >  cutover(e)   (only the live tail newer than the archive)
# These are DISJOINT at the cutover instant, so no row is counted twice, and the
# live tail fills forward from where the archive ends (no gap). Enterprises with
# NO historian data (live-only new tenants) have no hist_cutover row -> the LEFT
# JOIN keeps ALL their live rows and hist contributes nothing (also no dup).
#
#   HARDPROOF of the fix (read-only, staging, ent3 2026-09-03):
#     HOT(live, ts>cutover) = 0    COLD(hist, all) = 196,671    total = 196,671
#     (was 352,136 under the plain UNION ALL) — double-count eliminated.
#     Live still fills forward: 50,594 ent3 rows exist with ts>cutover (today).
#
# INVARIANT (load-bearing): every enterprise present in the historian MUST have a
# hist_cutover row, and cutover(e) MUST equal max(hist.ts_value). The inline seed
# below (and the top-level refresh-hist-cutover.sql) compute exactly that. RE-RUN the
# cutover refresh (refresh-hist-cutover.sql) after EVERY historian backfill/append
# that extends the cold store (otherwise a stale cutover lets the newly-archived
# window be served by BOTH sides again). A missing row for an in-historian enterprise
# re-introduces the double-count (LEFT JOIN NULL keeps all live AND all hist).
#
# DO NOT wrap this refresh in a PL/pgSQL function: pg_duckdb CANNOT execute a DuckDB
# scan (the `hist` parquet read) inside a function body — it throws "DuckDB execution
# is not supported inside functions", silently leaving hist_cutover stale → double
# count. A broken `refresh_hist_cutover()` plpgsql function of exactly this shape was
# found live on staging (never in this repo) and DROPPED 2026-09-08. The refresh MUST
# stay a TOP-LEVEL statement (the inline seed here + refresh-hist-cutover.sql).
#
# ── PARTITION PRUNING (T3/T6 — added 2026-09-04) ──────────────────────────────
# The historian is hive-partitioned enterprise=/year=/month=, one *-legacy.parquet
# per enterprise-month. DuckDB prunes ONLY on the partition columns (year/month),
# NOT on ts_value: HARDPROOF via EXPLAIN ANALYZE on staging —
#     WHERE ts_value BETWEEN <one day>                -> Total Files Read: 59, 170.76s
#     WHERE year=2026 AND month=9 AND ts_value ...    -> Total Files Read: 1,   0.57s
#     WHERE (year/month RANGE, Jinja-shape) AND ts... -> Total Files Read: 1,   0.74s
# So a bounded ev_all query prunes the cold side ONLY IF the query carries a
# year/month predicate. ev_all therefore SURFACES year + month (cold: the partition
# columns; hot: EXTRACT), and consumers must add a year/month predicate alongside
# their ts_value range. Two supported ways:
#   * Superset: the ev_all virtual dataset injects the year/month range from the
#     dashboard time filter via Jinja ({{ from_dttm }}/{{ to_dttm }}). See
#     configs/superset/assets/datasets/historian_union/ev_all.yaml.
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
# the SOLE enforcer, so the ev_all dataset MUST stay out of SQL Lab and every
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
) SERVER live_pg OPTIONS (schema_name 'public', table_name 'equipment_values');
-- HOT equipment_events (downtime/OEE-reconstruction) — see the EE section at the
-- bottom (ev_all_events). Imported here so live.equipment_events exists before it.
-- NOTE: equipment_events is NOT part of the analytics clean-schema column-prune, so
-- an IMPORT (vs a pinned table) is safe here; ev_all_events selects a fixed subset.
IMPORT FOREIGN SCHEMA public LIMIT TO (equipment_events) FROM SERVER live_pg INTO live;

-- COLD: S3 Parquet historian via pg_duckdb. Scoped read-only key (instance-role
-- credential_chain is unavailable: the DB enforces IMDSv2 and DuckDB's aws
-- extension cannot fetch v2 creds through the docker hop).
SELECT duckdb.create_simple_secret('S3','${HIST_AWS_KEY}','${HIST_AWS_SECRET}','','${AWS_REGION:-us-east-1}');

-- Only *-legacy.parquet == the deep-remapped legacy backfill. Surfaces the hive
-- partition columns year/month so a bounded query can PRUNE (T3, see header).
-- Serving surface = {gross, net, speed} (canonical, narrow — a production-series
-- server, not a raw mirror). `speed` is present in every *-legacy.parquet on disk,
-- so it is surfaced without a re-unload.
CREATE OR REPLACE VIEW hist AS
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

-- ── Per-enterprise cutover boundary (T2b) ────────────────────────────────────
-- cutover_ts = max(hist.ts_value) for the enterprise. COLD owns ts <= cutover_ts,
-- HOT owns ts > cutover_ts. Small table (one row per historian enterprise), read
-- on the HOT side only (a pure PG join — no DuckDB involvement, so the cold scan
-- stays a prunable DuckDBScan).
CREATE TABLE IF NOT EXISTS hist_cutover (
  id_enterprise int PRIMARY KEY,
  cutover_ts    timestamp NOT NULL,
  refreshed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE hist_cutover IS
  'T2b legacy-priority boundary: cutover_ts = max(hist.ts_value) per enterprise. '
  'COLD owns ts<=cutover_ts, HOT owns ts>cutover_ts. MUST be refreshed by '
  'the cutover refresh at init and after every historian backfill/append that '
  'extends the cold store, else the newly-archived window double-counts.';

-- Refresh cutover_ts = max(hist.ts_value) per enterprise. This is a FULL one-pass
-- scan of the legacy parquet (minutes on the 336M-row CPACK partition) — NOT cheap,
-- so it runs ONCE here at first-boot and must be re-run OUT-OF-BAND after each
-- backfill (companion 11-refresh-hist-cutover.sql, driven by the append job's
-- post-run hook), NEVER per query.
--
-- IMPORTANT (pg_duckdb limitation): this scan reads the `hist` parquet view, and
-- pg_duckdb CANNOT execute a DuckDB scan inside a PL/pgSQL function ("DuckDB
-- execution is not supported inside functions"). So the refresh MUST be a
-- TOP-LEVEL statement, not a function call. Seed it inline here:
INSERT INTO hist_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT id_enterprise, max(ts_value), now()
  FROM hist
 WHERE id_enterprise IS NOT NULL
 GROUP BY id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

-- ── Unified hot+cold, LEGACY-PRIORITY (T2b) + partition columns (T3) ──────────
-- HOT: live rows STRICTLY NEWER than this enterprise's historian coverage.
--   LEFT JOIN so a live-only enterprise (no cutover row) keeps ALL its live rows.
--   (If an IN-HISTORIAN enterprise is missing its cutover row, this keeps all its
--    live rows AND hist keeps all its rows -> double-count. The inline cutover seed
--    at init + refresh-hist-cutover.sql after each backfill upholds the "every
--    historian enterprise has a row" invariant that prevents this.)
-- COLD: the full deep-remapped historian archive (all rows are <= cutover_ts by
--   construction, so no filter is needed and the DuckDBScan stays prunable).
CREATE OR REPLACE VIEW ev_all AS
  SELECT lv.ts_value,
         lv.id_enterprise,
         EXTRACT(YEAR  FROM lv.ts_value)::int  AS year,
         EXTRACT(MONTH FROM lv.ts_value)::int  AS month,
         lv.id_equipment,
         lv.gross_production_incr,
         lv.net_production_incr,
         lv.speed
    FROM live.equipment_values lv
    LEFT JOIN hist_cutover c ON c.id_enterprise = lv.id_enterprise
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
    FROM hist h;

-- ── ev_between(p_start, p_end): pruning helper for read-api / tools (T3) ──────
-- Same rows as `SELECT * FROM ev_all WHERE ts_value >= p_start AND ts_value < p_end`
-- but injects the year/month RANGE predicate on the cold side so DuckDB prunes to
-- the spanning partitions (HARDPROOF: 1 file / 0.7s vs 59 files / 171s). Callers
-- still add their own id_enterprise = <literal> predicate (RLS).
CREATE OR REPLACE FUNCTION ev_between(p_start timestamptz, p_end timestamptz)
RETURNS TABLE (ts_value timestamp, id_enterprise int, year int, month int,
               id_equipment int, gross_production_incr double precision,
               net_production_incr double precision, speed double precision)
LANGUAGE sql STABLE AS \$fn\$
  SELECT lv.ts_value,
         lv.id_enterprise,
         EXTRACT(YEAR FROM lv.ts_value)::int,
         EXTRACT(MONTH FROM lv.ts_value)::int,
         lv.id_equipment, lv.gross_production_incr, lv.net_production_incr, lv.speed
    FROM live.equipment_values lv
    LEFT JOIN hist_cutover c ON c.id_enterprise = lv.id_enterprise
   WHERE (c.cutover_ts IS NULL OR lv.ts_value > c.cutover_ts)
     AND lv.ts_value >= p_start AND lv.ts_value < p_end
  UNION ALL
  SELECT h.ts_value, h.id_enterprise, h.year, h.month,
         h.id_equipment, h.gross_production_incr, h.net_production_incr, h.speed
    FROM hist h
   WHERE ( h.year >  EXTRACT(YEAR FROM p_start)::int
        OR (h.year = EXTRACT(YEAR FROM p_start)::int AND h.month >= EXTRACT(MONTH FROM p_start)::int) )
     AND ( h.year <  EXTRACT(YEAR FROM p_end)::int
        OR (h.year = EXTRACT(YEAR FROM p_end)::int AND h.month <= EXTRACT(MONTH FROM p_end)::int) )
     AND h.ts_value >= p_start::timestamp AND h.ts_value < p_end::timestamp;
\$fn\$;

-- ═══════════════════════════════════════════════════════════════════════════
-- equipment_events (EE) — downtime / OEE-reconstruction hot+cold union
--                         (task #227 / historian-clean-schema-redesign §8-EE)
-- ═══════════════════════════════════════════════════════════════════════════
-- The EE cold archive was backfilled with LEGACY enterprise ids; it is re-keyed
-- to the F3 id-space ON DISK (scripts/historian-events-reunload.sh, same "partition
-- key IS the F3 id, no in-view CASE" convention as EV). Only VERIFIED-F3-remapped
-- partitions live under equipment_events/ — un-promoted legacy partitions are held
-- under equipment_events_legacy_unpromoted/ (their legacy ids collide numerically
-- with real F3 tenant ids, so serving them would be a CROSS-TENANT LEAK). As more
-- tenants are promoted, re-unload their partition to F3 + move it into
-- equipment_events/; no view change needed (the glob is F3-only by construction).
--
-- ── WHY THE EE BOUNDARY IS THE **MIRROR** OF hist_cutover ──────────────────────
-- hist_cutover (EV) is COLD-anchored: cold is the full archive, hot is the live
-- tail, cutover = max(cold ts), COLD owns ts<=cutover / HOT owns ts>cutover.
-- EE is the OPPOSITE. db/cutover/f3-phasec-history-backfill.sql loaded ~197k CPACK
-- pre-cutover events INTO the hot F3 store (ent-3) WITH irreplaceable operator
-- reasons/notes — surfaced in v_report_downtimes. So for EE the HOT store holds the
-- deep history AND the live tail (continuous from its earliest event), and the cold
-- archive OVERLAPS it. A naïve hot ∪ cold DOUBLE-COUNTS the overlap (HARDPROOF,
-- staging ent-3, window 2026-04-01..2026-09-08: naïve=432,801 vs correct=316,688;
-- 116,113 rows double-counted). So EE is HOT-ANCHORED:
--   ev_events_cutover.cutover_ts = min(hot ts_event) per enterprise
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
FROM read_parquet('s3://${HISTORIAN_BUCKET}/equipment_events/*/*/*/*-legacy.parquet',
                  hive_partitioning => true) r;

CREATE TABLE IF NOT EXISTS ev_events_cutover (
  id_enterprise int PRIMARY KEY,
  cutover_ts    timestamp NOT NULL,
  refreshed_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ev_events_cutover IS
  'EE disjointness boundary. UNLIKE hist_cutover (cold-anchored: cutover=max(cold ts)), '
  'this is HOT-ANCHORED: cutover_ts = min(hot ts_event) per enterprise. COLD owns '
  'ts_event < cutover_ts, HOT owns ts_event >= cutover_ts. Refresh reads the hot FDW '
  '(a cheap PG aggregate — NOT a parquet scan), so it MAY run in a function/simple '
  'statement (companion refresh-ee-cutover.sql). Re-run after any change to the hot '
  'EE earliest event (e.g. a further deep-history backfill).';

-- Seed cutover = min(hot ts_event) per enterprise (reads the FDW, not parquet).
INSERT INTO ev_events_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT id_enterprise, min(ts_event)::timestamp, now()
  FROM live.equipment_events
 WHERE id_enterprise IS NOT NULL
 GROUP BY id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();

-- Hot+cold EE union, HOT-ANCHORED (see header). HOT keeps ALL live rows; COLD
-- (LEFT JOIN cutover) keeps its pre-hot window, or ALL rows for a cold-only tenant
-- (no cutover row). year/month surfaced so a bounded query prunes the cold parquet.
CREATE OR REPLACE VIEW ev_all_events AS
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
    FROM hist_ee h
    LEFT JOIN ev_events_cutover c ON c.id_enterprise = h.id_enterprise
   WHERE c.cutover_ts IS NULL OR h.ts_event < c.cutover_ts;
SQL

echo "[historian-gateway] init complete: ev_all (EV hot+cold) + ev_all_events (EE hot+cold), hist_cutover + ev_events_cutover seeded, ev_between() ready"
