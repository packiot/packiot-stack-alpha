#!/usr/bin/env bash
# backfill-silver-gap-from-legacy.sh — fill a CPACK silver.equipment_values ingest gap on STAGING from the legacy
# database (packiot40, read-only), converted to STAGING semantics, then mirror it into the sandbox twin.
#
# 2026-10-09: staging had no CPACK (analytics ent 3; legacy ent 1) raw values from 2026-10-02 17:55:50 to
# 2026-10-06 16:32:36 UTC (the window ending at the 10-06 disk-full restart); legacy had them. Events for those days
# already matched legacy. STAGING DATA ONLY: prod is promoted from its own data (transplant), never replayed here.
#
# WHY NOT A RAW COPY (scripts/analytics-silver-hole-backfill.sh, the 08-27 hole): staging silver is not legacy's
# equipment_values. Measured on the clean days around this gap (10-01, 10-02 < 17:55, 10-07, 10-08):
#   * staging fills only the descriptor-mapped role columns per machine (L3-BREYER: net only; L8-TCX: net only),
#     legacy fills gross AND net everywhere, and sometimes the staging role is legacy's OTHER column
#     (L6-TEXA net = legacy gross; legacy's own L6-TEXA net is ~9 % lower);
#   * some staging roles are a different signal than any legacy column (L8-TEXA net = 2x legacy, L6-PTH, L10-PTH
#     gross, CER400 gross = birth lumps) — copying would put a wrong number there;
#   * line rows (tp=3, deriver) = the lead machine's gross + the net machine's net, row scrap = gross - net (#1650);
#   * legacy writes 1/min heartbeats for idle machines, staging writes only on change; staging has no *_quality,
#     check_number/source_seq are ingest lineage; id_shift/id_shift_hour are stamped by the engine's resolver.
# So every staging (equipment, column) gets a SOURCE chosen by calibration, or stays NULL:
#   incr  : candidates = legacy {gross,net,scrap}_incr of the equipment itself, its lead_machine and net_machine;
#           accepted when Σ legacy / Σ staging is within ±7 % on every calibration period with ≥ 500 units (≥ 2 such
#           periods), or — for tiny volumes — the same column of the same equipment within 5 + 5 % in total.
#           Legacy undercounts ~1–3 % (known, 10-02 validation), so sums land slightly below staging's own level.
#   line scrap (tp=3, staging fills scrap): per row gross - net when the line-day has gross, else NULL (#1650 rule).
#   *_val : the accepted source's counter, when it matches staging's counter as-of (median |Δ| ≤ 250, 10-07);
#   *_total: same value, only where staging fills *_total for that equipment/column.
#   speed : legacy speed when staging fills speed and the as-of median |Δ| ≤ max(5, 15 % of staging's median);
#   state : legacy state when staging fills state and the as-of agreement is ≥ 90 % (legacy uses 10 where staging
#           uses 6 on several machines — those stay NULL).
#   id_site/id_area/tp_equipment = staging's own values for the equipment; id_shift/id_shift_hour =
#   piot_get_shift_hour_begin_by_equipment() (reproduces the engine stamps 2920/2920 on 10-07);
#   ts_value_production = UTC date (engine session is UTC); ingested_at = the run marker; source_seq NULL.
# A row is written only when at least one accepted column has a value (drops legacy's empty heartbeats).
# Equipment ids are mapped by packml topic (C-PACK→CPACK), never by surrogate id: 62↔62, bijective (10-09).
#
# THE 10-06 EDGE: the first staging sample per machine after the restart (16:32:36–16:33:06) carried the whole
# outage as one increment (stale upstream baseline) and was zeroed on 10-09 (ops._fix_line_scrap_20261009,
# kind='unbacked', #1652/#1655, policy #1544). With the gap backfilled, that production now lives in the backfilled
# rows, so those rows STAY ZERO (restoring them would count the outage twice). STEP=edge prints the comparison.
#
# STEPS (STEP=all runs stage → merge → caggs → twin; each is resumable):
#   stage : app box, DuckDB. Legacy is attached READ_ONLY with default_transaction_read_only=on and
#           statement_timeout=15min (credentials from the legacy-replicator container env, never printed).
#           Writes ops._bf_gap_<TAG>_plan (calibration, every candidate) and ops._bf_gap_<TAG>_rows (staged rows).
#   merge : one INSERT … ON CONFLICT DO NOTHING per equipment-day with LITERAL bounds (stable bounds make DML on
#           compressed chunks match 0 rows, 10-09), lock_timeout 10s; inserted rows counted by READ-BACK
#           (ingested_at = marker) into ops._bf_gap_<TAG>_log. Never decompress_chunk; inserts take row locks only.
#           DRY_RUN=1: each equipment-day in a rolled-back transaction (counts only).
#   caggs : refresh the silver continuous aggregates for every touched day (1min level before the hierarchical 1hour).
#   twin  : ops.sbx_mirror_silver_day(lo, hi, NULL) per day, exactly the gap window (p_decompress=false), then caggs.
#   edge  : read-only: Σ backfilled role per machine vs the zeroed 10-06 restart increments.
# Gold is NOT touched here: use docs/runbooks/history-recompute.md (rows older than the engine windows).
#
#   On the staging app box (root):  STEP=stage bash backfill-silver-gap-from-legacy.sh
#                                    nohup env STEP=merge bash backfill-silver-gap-from-legacy.sh > bf.log 2>&1 &
# Undo (per equipment-day; literal bounds; twin ent 2000003 the same with id_equipment + 2000000):
#   DELETE FROM silver.equipment_values WHERE id_equipment = <eq> AND ts_value >= '<day>' AND ts_value < '<day+1>'
#     AND ingested_at = '<marker from ops._bf_gap_<TAG>_log>' AND source_seq IS NULL;   then STEP=caggs.
set -euo pipefail
export HOME="${HOME:-/root}"
STEP="${STEP:-all}"; DRY_RUN="${DRY_RUN:-0}"; TAG="${TAG:-20261009}"
FROM_TS="${FROM_TS:-2026-10-02 17:55:50+00}"   # last staging row before the gap (exclusive)
TO_TS="${TO_TS:-2026-10-06 16:32:36+00}"       # first staging row after the gap (exclusive)
LEG_ENT="${LEG_ENT:-1}"; ENT="${ENT:-3}"; TWIN_ENT="${TWIN_ENT:-2000003}"; TWIN_OFF="${TWIN_OFF:-2000000}"
# calibration periods (staging live on both systems), and the day used for the as-of counter/speed/state checks
CAL="${CAL:-('p1','2026-10-01 00:00:00+00','2026-10-02 00:00:00+00'),('p2','2026-10-02 00:00:00+00','2026-10-02 17:55:00+00'),('p3','2026-10-07 00:00:00+00','2026-10-08 00:00:00+00'),('p4','2026-10-08 00:00:00+00','2026-10-09 00:00:00+00')}"
ASOF_FROM="${ASOF_FROM:-2026-10-07 01:00+00}"; ASOF_TO="${ASOF_TO:-2026-10-08 00:00+00}"
PLAN="ops._bf_gap_${TAG}_plan"; ROWS="ops._bf_gap_${TAG}_rows"; LOG="ops._bf_gap_${TAG}_log"
AN_HOST="${DB_HOST:-10.10.10.89}"
APW="${ANALYTICS_DB_PASSWORD:-$(grep -m1 '^POSTGRES_PASSWORD=' /opt/packiot/.env | cut -d= -f2-)}"
log(){ echo "[$(date -u +%T)] $*"; }
PSQL(){ PGPASSWORD="$APW" psql -h "$AN_HOST" -U postgres -d packiot_analytics -X -v ON_ERROR_STOP=1 -At "$@" < /dev/null; }
P(){ PSQL -c "SET statement_timeout='10min'; SET lock_timeout='10s'; $1" | tail -1; }
Q(){ PSQL -F ' ' -c "SET statement_timeout='10min'; $1" | sed 1d; }

stage(){
  DUCKDB=""; for c in /opt/packiot/duckdb/duckdb "$HOME/.duckdb/cli/latest/duckdb" /root/.duckdb/cli/latest/duckdb "$(command -v duckdb||true)"; do [ -x "$c" ] && DUCKDB="$c" && break; done
  [ -z "$DUCKDB" ] && { log "duckdb not found"; exit 3; }
  # the replicator's own legacy credentials (read into this shell only; never echoed)
  while IFS= read -r kv; do k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in LEGACY_DB_HOST|LEGACY_DB_PORT|LEGACY_DB_NAME|LEGACY_DB_USER|LEGACY_DB_PASSWORD) export "$k=$v";; esac
  done < <(docker inspect legacy-replicator --format '{{range .Config.Env}}{{println .}}{{end}}')
  : "${LEGACY_DB_PASSWORD:?legacy-replicator has no LEGACY_DB_PASSWORD}"
  SQL="$(mktemp)"; trap 'rm -f "$SQL"' RETURN
  cat > "$SQL" <<EOF
INSTALL postgres; LOAD postgres;
ATTACH 'host=${LEGACY_DB_HOST} port=${LEGACY_DB_PORT:-5432} dbname=${LEGACY_DB_NAME} user=${LEGACY_DB_USER} password=${LEGACY_DB_PASSWORD} options=''-c default_transaction_read_only=on -c statement_timeout=900000''' AS leg (TYPE postgres, READ_ONLY);
ATTACH 'host=${AN_HOST} port=5432 dbname=packiot_analytics user=postgres password=${APW}' AS an (TYPE postgres);
SELECT * FROM postgres_query('leg', 'SELECT current_setting(''default_transaction_read_only'') AS legacy_read_only');
CREATE TEMP TABLE per AS SELECT p, lo::TIMESTAMPTZ lo, hi::TIMESTAMPTZ hi FROM (VALUES ${CAL}) t(p, lo, hi);
-- equipment map by packml topic (business key), 1:1 enforced below
CREATE TEMP TABLE m AS SELECT DISTINCT l.id_equipment leg_id, f.id_equipment new_id
  FROM postgres_query('leg','SELECT DISTINCT id_equipment, packml_topic FROM packml_register WHERE id_enterprise=${LEG_ENT} AND active=true AND id_equipment IS NOT NULL') l
  JOIN postgres_query('an','SELECT DISTINCT id_equipment, packml_topic FROM core.packml_register WHERE id_enterprise=${ENT} AND active=true') f
    ON replace(l.packml_topic,'C-PACK','CPACK') = f.packml_topic;
SELECT CASE WHEN count(*) = count(DISTINCT leg_id) AND count(*) = count(DISTINCT new_id) THEN 'map 1:1 ' || count(*)
            ELSE error('equipment map is not 1:1: ' || count(*) || ' pairs') END AS map_check FROM m;
CREATE TEMP TABLE fe AS SELECT * FROM postgres_query('an','SELECT id_equipment, tp_equipment, lead_machine, net_machine FROM core.equipments WHERE id_enterprise=${ENT}');
-- staging's own per-equipment shape over the calibration periods
CREATE TEMP TABLE shape AS SELECT * FROM postgres_query('an', \$\$
  SELECT id_equipment eq, mode() WITHIN GROUP (ORDER BY tp_equipment) tp_equipment, mode() WITHIN GROUP (ORDER BY id_site) id_site,
         mode() WITHIN GROUP (ORDER BY id_area) id_area,
         count(gross_production_total) gt, count(net_production_total) nt, count(scrap_total) st,
         count(gross_production_val) gv, count(net_production_val) nv, count(scrap_val) sv, count(speed) spd, count(state) stt
    FROM silver.equipment_values WHERE id_enterprise=${ENT} AND ((ts_value >= '2026-10-01 00:00+00' AND ts_value < '${FROM_TS}') OR (ts_value >= '${TO_TS}' AND ts_value < '2026-10-09 00:00+00'))
   GROUP BY 1\$\$);
CREATE TEMP TABLE lcal AS SELECT m.new_id src_eq, t.ts_value, t.g, t.n, t.s FROM postgres_query('leg', \$\$SELECT id_equipment, ts_value, gross_production_incr g, net_production_incr n, scrap_incr s FROM equipment_values
   WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise=${LEG_ENT}) AND ts_value >= '2026-10-01 00:00+00' AND ts_value < '2026-10-09 00:00+00'
     AND NOT (ts_value >= '${FROM_TS}' AND ts_value < '${TO_TS}')\$\$) t JOIN m ON m.leg_id = t.id_equipment;
CREATE TEMP TABLE scal AS SELECT * FROM postgres_query('an', \$\$SELECT id_equipment eq, ts_value, gross_production_incr g, net_production_incr n, scrap_incr s FROM silver.equipment_values
   WHERE id_enterprise=${ENT} AND ts_value >= '2026-10-01 00:00+00' AND ts_value < '2026-10-09 00:00+00' AND NOT (ts_value >= '${FROM_TS}' AND ts_value < '${TO_TS}')\$\$);
CREATE TEMP TABLE lsum AS SELECT c.src_eq, per.p, c.col, sum(c.v) v FROM (UNPIVOT lcal ON g, n, s INTO NAME col VALUE v) c JOIN per ON c.ts_value >= per.lo AND c.ts_value < per.hi GROUP BY ALL;
CREATE TEMP TABLE ssum AS SELECT c.eq, per.p, c.col, sum(c.v) v, count(c.v) nn FROM (UNPIVOT scal ON g, n, s INTO NAME col VALUE v) c JOIN per ON c.ts_value >= per.lo AND c.ts_value < per.hi GROUP BY ALL;
CREATE TEMP TABLE tgt AS SELECT eq, col, sum(nn) nn, sum(v) stg_tot FROM ssum GROUP BY ALL HAVING sum(nn) > 0;
CREATE TEMP TABLE cand AS SELECT DISTINCT fe.id_equipment eq, x.src_eq FROM fe, LATERAL (SELECT unnest([fe.id_equipment, fe.lead_machine, fe.net_machine]) src_eq) x WHERE x.src_eq IS NOT NULL;
CREATE TEMP TABLE score AS
SELECT t.eq, t.col tcol, c.src_eq, sc.col scol,
       count(*) FILTER (WHERE abs(s.v) >= 500) nper,
       max(abs(coalesce(l.v, 0) / s.v - 1)) FILTER (WHERE abs(s.v) >= 500) worst,
       avg(abs(coalesce(l.v, 0) / s.v - 1)) FILTER (WHERE abs(s.v) >= 500) mean,
       any_value(t.stg_tot) stg_tot, sum(l.v) leg_tot
FROM tgt t JOIN cand c ON c.eq = t.eq CROSS JOIN (VALUES ('g'),('n'),('s')) sc(col)
JOIN ssum s ON s.eq = t.eq AND s.col = t.col
LEFT JOIN lsum l ON l.src_eq = c.src_eq AND l.col = sc.col AND l.p = s.p
GROUP BY ALL;
CREATE TEMP TABLE score2 AS SELECT *, coalesce((nper >= 2 AND worst <= 0.07)
        OR (nper = 0 AND src_eq = eq AND scol = tcol AND abs(coalesce(leg_tot,0) - stg_tot) <= 5 + 0.05 * abs(stg_tot)), false) AS ok FROM score;
CREATE TEMP TABLE pick AS SELECT * FROM score2 WHERE ok
  QUALIFY row_number() OVER (PARTITION BY eq, tcol ORDER BY coalesce(mean, 0), (src_eq = eq) DESC, (scol = tcol) DESC) = 1;
-- as-of agreement of the counters (*_val), speed and state on a clean day
CREATE TEMP TABLE lv AS SELECT m.new_id src_eq, t.* EXCLUDE (id_equipment) FROM postgres_query('leg', \$\$SELECT id_equipment, ts_value, gross_production_val g, net_production_val n, scrap_val s, speed, state FROM equipment_values
   WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise=${LEG_ENT}) AND ts_value >= '${ASOF_FROM}'::timestamptz - interval '1 hour' AND ts_value < '${ASOF_TO}'\$\$) t JOIN m ON m.leg_id = t.id_equipment;
CREATE TEMP TABLE sv AS SELECT * FROM postgres_query('an', \$\$SELECT id_equipment eq, ts_value, gross_production_val g, net_production_val n, scrap_val s, speed, state FROM silver.equipment_values
   WHERE id_enterprise=${ENT} AND ts_value >= '${ASOF_FROM}' AND ts_value < '${ASOF_TO}'\$\$);
CREATE TEMP TABLE lvl AS SELECT src_eq, ts_value, col, v FROM (UNPIVOT (SELECT src_eq, ts_value, g, n, s FROM lv) ON g, n, s INTO NAME col VALUE v);
CREATE TEMP TABLE svl AS SELECT eq, ts_value, col, v FROM (UNPIVOT (SELECT eq, ts_value, g, n, s FROM sv) ON g, n, s INTO NAME col VALUE v);
CREATE TEMP TABLE valck AS
SELECT p.eq, p.tcol, median(abs(s.v - l.v)) med FROM pick p JOIN svl s ON s.eq = p.eq AND s.col = p.tcol
ASOF JOIN lvl l ON l.src_eq = p.src_eq AND l.col = p.scol AND l.ts_value <= s.ts_value GROUP BY ALL;
CREATE TEMP TABLE spdck AS SELECT s.eq, median(abs(s.speed - l.speed)) med, median(s.speed) med_stg
  FROM sv s ASOF JOIN lv l ON l.src_eq = s.eq AND l.ts_value <= s.ts_value WHERE s.speed IS NOT NULL GROUP BY ALL;
CREATE TEMP TABLE stck AS SELECT s.eq, avg((s.state = l.state)::int) rate
  FROM sv s ASOF JOIN lv l ON l.src_eq = s.eq AND l.ts_value <= s.ts_value WHERE s.state IS NOT NULL GROUP BY ALL;
-- the plan (every target, accepted or not, for the record)
DROP TABLE IF EXISTS an.${PLAN};
CREATE TABLE an.${PLAN} AS
SELECT t.eq AS id_equipment, fe.tp_equipment, t.col AS tcol, p.src_eq, p.scol, p.nper, p.worst, p.mean, t.stg_tot, p.leg_tot,
       p.src_eq IS NOT NULL AND NOT (fe.tp_equipment = 3 AND t.col = 's') AS incr_ok,
       (fe.tp_equipment = 3 AND t.col = 's') AS line_scrap_rule,
       coalesce(vc.med <= 250, false) AND p.src_eq IS NOT NULL AND NOT (fe.tp_equipment = 3 AND t.col = 's') AS val_ok,
       coalesce(vc.med <= 250, false) AND p.src_eq IS NOT NULL AND NOT (fe.tp_equipment = 3 AND t.col = 's')
         AND CASE t.col WHEN 'g' THEN sh.gt WHEN 'n' THEN sh.nt ELSE sh.st END > 0 AS total_ok,
       vc.med AS val_med_absdiff
FROM tgt t JOIN fe ON fe.id_equipment = t.eq LEFT JOIN pick p ON p.eq = t.eq AND p.tcol = t.col
LEFT JOIN valck vc ON vc.eq = t.eq AND vc.tcol = t.col LEFT JOIN shape sh ON sh.eq = t.eq
UNION ALL
SELECT sh.eq, fe.tp_equipment, 'speed', sh.eq, 'speed', NULL, NULL, NULL, NULL, NULL,
       coalesce(sp.med <= greatest(5, 0.15 * sp.med_stg), false), false, false, false, sp.med
FROM shape sh JOIN fe ON fe.id_equipment = sh.eq LEFT JOIN spdck sp ON sp.eq = sh.eq WHERE sh.spd > 0
UNION ALL
SELECT sh.eq, fe.tp_equipment, 'state', sh.eq, 'state', NULL, NULL, NULL, NULL, NULL,
       coalesce(st.rate >= 0.9, false), false, false, false, st.rate
FROM shape sh JOIN fe ON fe.id_equipment = sh.eq LEFT JOIN stck st ON st.eq = sh.eq WHERE sh.stt > 0;
CREATE TEMP TABLE plan AS SELECT * FROM an.${PLAN};
-- legacy rows inside the gap
CREATE TEMP TABLE lg AS SELECT m.new_id src_eq, t.* EXCLUDE (id_equipment) FROM postgres_query('leg', \$\$SELECT id_equipment, ts_value,
     gross_production_incr g, net_production_incr n, scrap_incr s, gross_production_val gv, net_production_val nv, scrap_val sv, speed, state
   FROM equipment_values WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise=${LEG_ENT})
    AND ts_value > '${FROM_TS}' AND ts_value < '${TO_TS}'\$\$) t JOIN m ON m.leg_id = t.id_equipment;
CREATE TEMP TABLE lng AS
SELECT p.id_equipment eq, lg.ts_value, p.tcol,
       CASE p.scol WHEN 'g' THEN lg.g WHEN 'n' THEN lg.n ELSE lg.s END AS v,
       CASE WHEN p.val_ok THEN CASE p.scol WHEN 'g' THEN lg.gv WHEN 'n' THEN lg.nv ELSE lg.sv END END AS val,
       p.total_ok
FROM plan p JOIN lg ON lg.src_eq = p.src_eq WHERE p.incr_ok AND p.tcol IN ('g','n','s');
CREATE TEMP TABLE own AS
SELECT lg.src_eq eq, lg.ts_value,
       CASE WHEN EXISTS (SELECT 1 FROM plan p WHERE p.id_equipment = lg.src_eq AND p.tcol = 'speed' AND p.incr_ok) THEN lg.speed END speed,
       CASE WHEN EXISTS (SELECT 1 FROM plan p WHERE p.id_equipment = lg.src_eq AND p.tcol = 'state' AND p.incr_ok) THEN lg.state END state
FROM lg;
CREATE TEMP TABLE wide AS
SELECT k.eq, k.ts_value,
  max(l.v)   FILTER (WHERE l.tcol='g') g,  max(l.v)   FILTER (WHERE l.tcol='n') n,  max(l.v) FILTER (WHERE l.tcol='s') s,
  max(l.val) FILTER (WHERE l.tcol='g') gv, max(l.val) FILTER (WHERE l.tcol='n') nv, max(l.val) FILTER (WHERE l.tcol='s') sv,
  max(l.val) FILTER (WHERE l.tcol='g' AND l.total_ok) gt, max(l.val) FILTER (WHERE l.tcol='n' AND l.total_ok) nt,
  max(l.val) FILTER (WHERE l.tcol='s' AND l.total_ok) st,
  max(o.speed) speed, max(o.state) state
FROM (SELECT eq, ts_value FROM lng UNION SELECT eq, ts_value FROM own WHERE speed IS NOT NULL OR state IS NOT NULL) k
LEFT JOIN lng l ON l.eq = k.eq AND l.ts_value = k.ts_value
LEFT JOIN own o ON o.eq = k.eq AND o.ts_value = k.ts_value
GROUP BY ALL;
-- line rows: scrap = gross - net per row when the line-day has gross (#1650), only where staging fills line scrap
CREATE TEMP TABLE lineday AS SELECT eq, date_trunc('day', ts_value AT TIME ZONE 'UTC') d, sum(g) sg FROM wide GROUP BY ALL;
DROP TABLE IF EXISTS an.${ROWS};
CREATE TABLE an.${ROWS} AS
SELECT w.eq AS id_equipment, w.ts_value, ${ENT} AS id_enterprise, sh.id_site, sh.id_area, sh.tp_equipment,
       w.g::FLOAT AS gross_production_incr, w.n::FLOAT AS net_production_incr,
       (CASE WHEN EXISTS (SELECT 1 FROM plan p WHERE p.id_equipment = w.eq AND p.line_scrap_rule)
             THEN CASE WHEN coalesce(ld.sg, 0) > 0 AND (w.g IS NOT NULL OR w.n IS NOT NULL) THEN coalesce(w.g, 0) - coalesce(w.n, 0) END
             ELSE w.s END)::FLOAT AS scrap_incr,
       w.gv::FLOAT AS gross_production_val, w.nv::FLOAT AS net_production_val, w.sv::FLOAT AS scrap_val,
       w.gt::DOUBLE AS gross_production_total, w.nt::DOUBLE AS net_production_total, w.st::DOUBLE AS scrap_total,
       w.speed::FLOAT AS speed, w.state::INTEGER AS state
FROM wide w JOIN shape sh ON sh.eq = w.eq
LEFT JOIN lineday ld ON ld.eq = w.eq AND ld.d = date_trunc('day', w.ts_value AT TIME ZONE 'UTC')
WHERE w.g IS NOT NULL OR w.n IS NOT NULL OR w.s IS NOT NULL OR w.speed IS NOT NULL OR w.state IS NOT NULL;
SELECT count(*) AS legacy_gap_rows, count(DISTINCT src_eq) AS legacy_equipments FROM lg;
SELECT count(*) AS staged_rows, count(DISTINCT id_equipment) AS staged_equipments, min(ts_value)::VARCHAR AS min_ts, max(ts_value)::VARCHAR AS max_ts,
       round(sum(gross_production_incr)) gross, round(sum(net_production_incr)) net FROM an.${ROWS};
EOF
  log "stage: legacy ent ${LEG_ENT} -> ent ${ENT}, window (${FROM_TS}, ${TO_TS})"
  "$DUCKDB" -c ".read $SQL"
  P "CREATE INDEX IF NOT EXISTS _bf_gap_${TAG}_rows_eq_ts ON ${ROWS} (id_equipment, ts_value)" >/dev/null
  log "plan (accepted targets):"
  Q "SELECT id_equipment, tp_equipment, tcol, src_eq, scol, round(worst::numeric,3), incr_ok, val_ok, total_ok, line_scrap_rule FROM ${PLAN} ORDER BY 1, 3"
}

merge(){
  P "CREATE TABLE IF NOT EXISTS ${LOG} (id_equipment int, day date, staged int, inserted int, marker timestamptz,
       applied_at timestamptz, PRIMARY KEY (id_equipment, day))" >/dev/null
  MARKER="$(P "SELECT coalesce((SELECT max(marker) FROM ${LOG}), now())")"   # one marker per backfill (undo key)
  log "merge: marker ${MARKER} dry_run=${DRY_RUN}"
  local n=0
  while read -r eq day staged; do
    [ -n "$eq" ] || continue
    NEXT=$(date -u -d "$day + 1 day" +%F)
    LO="'${day} 00:00:00+00'"; HI="'${NEXT} 00:00:00+00'"
    INS="INSERT INTO silver.equipment_values (id_equipment, ts_value, id_enterprise, id_site, id_area, tp_equipment,
           gross_production_incr, net_production_incr, scrap_incr, gross_production_val, net_production_val, scrap_val,
           gross_production_total, net_production_total, scrap_total, speed, state,
           id_shift, id_shift_hour, ts_value_production, ingested_at, source_seq)
         SELECT r.id_equipment, r.ts_value, r.id_enterprise, r.id_site, r.id_area, r.tp_equipment,
                r.gross_production_incr, r.net_production_incr, r.scrap_incr, r.gross_production_val, r.net_production_val, r.scrap_val,
                r.gross_production_total, r.net_production_total, r.scrap_total, r.speed, r.state,
                f.id_shift, f.id_shift_hour, (r.ts_value AT TIME ZONE 'UTC')::date, '${MARKER}'::timestamptz, NULL
           FROM ${ROWS} r
           LEFT JOIN LATERAL (SELECT s.id_shift, s.id_shift_hour FROM piot_get_shift_hour_begin_by_equipment(r.id_equipment, r.ts_value) s LIMIT 1) f ON true
          WHERE r.id_equipment = ${eq} AND r.ts_value >= ${LO} AND r.ts_value < ${HI}
         ON CONFLICT (id_equipment, ts_value) DO NOTHING"
    if [ "$DRY_RUN" = 1 ]; then
      R=$(PSQL -c "SET statement_timeout='10min'; SET lock_timeout='10s'" -c "BEGIN" -c "${INS}" -c "ROLLBACK" | grep -m1 '^INSERT' || true)
      log "  eq ${eq} ${day}: staged ${staged}, ${R} (rolled back)"; continue
    fi
    R=$(PSQL -c "SET statement_timeout='10min'; SET lock_timeout='10s'; SET timescaledb.max_tuples_decompressed_per_dml_transaction = 0" -c "${INS}" | tail -1)
    RB=$(P "SELECT count(*) FROM silver.equipment_values WHERE id_equipment = ${eq} AND ts_value >= ${LO} AND ts_value < ${HI}
             AND ingested_at = '${MARKER}' AND source_seq IS NULL")
    P "INSERT INTO ${LOG} VALUES (${eq}, '${day}', ${staged}, ${RB}, '${MARKER}', CASE WHEN ${RB} > 0 THEN now() END)
       ON CONFLICT (id_equipment, day) DO UPDATE SET staged = EXCLUDED.staged, inserted = EXCLUDED.inserted,
         marker = EXCLUDED.marker, applied_at = EXCLUDED.applied_at" >/dev/null
    n=$((n+1)); log "  eq ${eq} ${day}: staged ${staged}, ${R}, read-back ${RB}"
    sleep 0.2
  done < <(Q "SELECT r.id_equipment, (r.ts_value AT TIME ZONE 'UTC')::date, count(*) FROM ${ROWS} r
              WHERE NOT EXISTS (SELECT 1 FROM ${LOG} l WHERE l.id_equipment = r.id_equipment
                                AND l.day = (r.ts_value AT TIME ZONE 'UTC')::date AND l.inserted = l.staged)
              GROUP BY 1, 2 ORDER BY 2, 1")
  log "merge done: ${n} equipment-days this run"
  Q "SELECT day, sum(staged), sum(inserted), count(*) FILTER (WHERE inserted <> staged) AS short FROM ${LOG} GROUP BY 1 ORDER BY 1"
}

caggs(){
  local d0 d1 d
  d0=$(date -u -d "${FROM_TS%+*}" +%F); d1=$(date -u -d "${TO_TS%+*}" +%F)
  d="$d0"
  while [[ ! "$d" > "$d1" ]]; do
    for cagg in silver.ca_discrete_changes_1s silver.ca_equipment_boxes_1s silver.agg_equipment_values_1min \
                silver.equipment_metrics_1min silver.equipment_categorical_1min \
                silver.agg_equipment_values_1hour silver.equipment_categorical_1hour; do
      PSQL -c "SET statement_timeout='30min'" -c "CALL refresh_continuous_aggregate('${cagg}', '${d} 00:00:00+00', '$(date -u -d "$d + 1 day" +%F) 00:00:00+00')" >/dev/null
    done
    log "caggs refreshed: ${d}"; d=$(date -u -d "$d + 1 day" +%F)
  done
}

twin(){
  local d0 d1 d lo hi
  d0=$(date -u -d "${FROM_TS%+*}" +%F); d1=$(date -u -d "${TO_TS%+*}" +%F); d="$d0"
  while [[ ! "$d" > "$d1" ]]; do
    lo="${d} 00:00:00+00"; hi="$(date -u -d "$d + 1 day" +%F) 00:00:00+00"
    [ "$d" = "$d0" ] && lo="${FROM_TS}"            # exactly the gap: rows at the edges stay untouched
    [ "$d" = "$d1" ] && hi="${TO_TS}"
    # the gap's first instant is exclusive: shift lo by 1 s (the proc's lower bound is inclusive)
    [ "$d" = "$d0" ] && lo="$(date -u -d "${FROM_TS%+*} UTC + 1 second" '+%F %T')+00"
    PSQL -c "SET statement_timeout='30min'; SET lock_timeout='10s'" \
         -c "CALL ops.sbx_mirror_silver_day('${lo}', '${hi}', NULL, ${TWIN_OFF}, ${ENT}, ${TWIN_ENT}, false)" 2>&1 | grep -E 'NOTICE|ERROR' || true
    log "twin mirrored: [${lo}, ${hi})"; d=$(date -u -d "$d + 1 day" +%F)
  done
  caggs
}

edge(){
  Q "WITH b AS (SELECT id_equipment, sum(gross_production_incr) g, sum(net_production_incr) n FROM ${ROWS} GROUP BY 1)
     SELECT f.id_equipment, f.ts_value, f.old_gross, round(b.g) AS backfilled_gross, f.old_net, round(b.n) AS backfilled_net
       FROM ops._fix_line_scrap_20261009 f LEFT JOIN b USING (id_equipment)
      WHERE f.kind = 'unbacked' AND f.id_enterprise = ${ENT} AND f.ts_value >= '${TO_TS}' AND f.ts_value < '${TO_TS}'::timestamptz + interval '5 minutes'
      ORDER BY 1, 2"
}

case "$STEP" in
  stage) stage ;; merge) merge ;; caggs) caggs ;; twin) twin ;; edge) edge ;;
  all) stage; merge; [ "$DRY_RUN" = 1 ] || { caggs; twin; } ;;
  *) echo "STEP=stage|merge|caggs|twin|edge|all" >&2; exit 2 ;;
esac
