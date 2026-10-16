#!/usr/bin/env bash
# historian-ev-daily-rollup.sh — per-day gross/net rollup of the COLD equipment_values archive.
#
# WHY: read-api's /v1/historian/production-series returns DAILY totals, but it used to build
# them at query time from the per-second cold rows (a CPACK month is ~6-8 M rows / ~80 MB of
# parquet). 30 days took ~25 s against a 60 s timeout, so any window past ~2-3 months failed.
# This job pre-aggregates the cold archive to one row per (day, equipment) — a few KB per
# month — so long windows read the rollup instead (read-api historian.go, daily path).
#
# WHAT: for each EV-promoted enterprise, writes
#   s3://$BUCKET/equipment_values_daily/enterprise=E/year=Y/month=M/daily-YYYY-MM.parquet
# covering only WHOLE UTC days strictly before U = date(cutover_ts), then records U in
# cold.ev_daily_watermark. Everything from U on is served HOT (analytics hourly rollup via FDW,
# retained 13 months), so the boundary is day-aligned and exact: no partial day is split.
#
# SPIKE GUARD: the same rule as the cold.equipment_values view (t-historian-serving-guards). An
# increment is dropped when it is physically impossible:
#   * negative;
#   * > 10,000 and at least half the machine's lifetime totalizer (legacy wrote the totalizer
#     into the increment column: POLYTYPE net 2022-10..2023-09, ~1e12/month);
#   * > 10,000 and not backed by totalizer movement since the previous row (the 2024-07-22
#     replay: +74,367 every ~40 s with the totalizer frozen); a counter reset keeps its
#     increment when it does not exceed the new totalizer;
#   * > 1,000 at more than 5,000 units/min, when the machine has >= 3 such rows in the same
#     hour (a sustained burst). A single fast row is a reconnect catch-up (real production
#     stamped at once) and is kept.
# Measured on 10 CPACK months: 2022-05, 2025-03, 2025-09, 2026-05 are byte-identical; the
# garbage months drop back to normal (2024-07-22: 79 M -> 4.4 M; 2023-01 net 5.7e10 -> 9.6e7).
#
# MODES: default = incremental (current + MONTHS_BACK previous months, idempotent overwrite);
#        FULL=1 = every month present in the cold archive (one-time backfill / rebuild).
# The watermark only advances in FULL mode or when a previous FULL run already set it, so an
# incremental run can never claim coverage for months it never built.
set -euo pipefail
export HOME="${HOME:-/root}"
log(){ echo "[ev-daily] $*"; }
DUCKDB=""; for c in /opt/packiot/duckdb/duckdb "$HOME/.duckdb/cli/latest/duckdb" /root/.duckdb/cli/latest/duckdb "$(command -v duckdb||true)"; do [ -x "$c" ] && DUCKDB="$c" && break; done
[ -z "$DUCKDB" ] && { log "duckdb not found"; exit 3; }
BUCKET="${HISTORIAN_BUCKET:-packiot-staging-historian-639178078294}"
GW="${GATEWAY_CONTAINER:-hist-gateway}"
MONTHS_BACK="${EV_DAILY_MONTHS_BACK:-1}"
FULL="${FULL:-0}"
TMP="${DUCKDB_TMP:-/var/tmp/historian-duckdb}"; mkdir -p "$TMP"
gw(){ docker exec "$GW" psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -At -c "$1"; }

ENTS="${EV_DAILY_ENTERPRISES:-$(gw "SELECT id_enterprise FROM cold.promoted_enterprise WHERE ev_promoted ORDER BY 1" | tr '\n' ' ')}"
for E in $ENTS; do
  CUT="$(gw "SELECT cutover_ts::date FROM cold.ev_union_boundary WHERE id_enterprise=$E")"
  [ -z "$CUT" ] && { log "ent=$E has no ev_union_boundary row, skip"; continue; }
  HAVE="$(gw "SELECT covered_until FROM cold.ev_daily_watermark WHERE id_enterprise=$E")"
  if [ "$FULL" = 1 ]; then
    MONTHS="$(aws s3 ls "s3://$BUCKET/equipment_values/enterprise=$E/" --recursive \
      | sed -n 's#.*year=\([0-9]*\)/month=\([0-9]*\)/.*-legacy\.parquet$#\1 \2#p' | sort -u -k1,1n -k2,2n)"
  else
    [ -z "$HAVE" ] && { log "ent=$E has no watermark yet: run once with FULL=1"; continue; }
    MONTHS=""
    for k in $(seq "$MONTHS_BACK" -1 0); do
      MONTHS="$MONTHS$(date -u -d "$(date -u +%Y-%m-01) -${k} months" '+%Y %-m')"$'\n'
    done
  fi
  log "ent=$E cutover_day=$CUT (cold rollup covers days < it) full=$FULL"
  while read -r Y M; do
    [ -z "$Y" ] && continue
    MSTART="$(printf '%04d-%02d-01' "$Y" "$M")"
    [ "$MSTART" \< "$CUT" ] || { log "ent=$E $Y-$M starts on/after the cutover day, skip"; continue; }
    SRC="s3://$BUCKET/equipment_values/enterprise=$E/year=$Y/month=$M/*-legacy.parquet"
    DEST="s3://$BUCKET/equipment_values_daily/enterprise=$E/year=$Y/month=$M/daily-$Y-$(printf %02d "$M").parquet"
    log "ent=$E $Y-$M -> $DEST"
    "$DUCKDB" <<SQL
SET memory_limit='${DUCKDB_MEMORY_LIMIT:-1000MB}'; SET threads=${DUCKDB_THREADS:-1}; SET temp_directory='$TMP';
SET preserve_insertion_order=false; SET TimeZone='UTC';
INSTALL httpfs; LOAD httpfs; INSTALL icu; LOAD icu;
CREATE SECRET s3sec (TYPE S3, PROVIDER credential_chain, REGION 'us-east-1');
COPY (
  WITH l AS (
    SELECT ts_value, id_equipment, gross_production_incr AS gi, gross_production_val AS gv,
           net_production_incr AS ni, net_production_val AS nv,
           lag(gross_production_val) OVER wp AS pgv, lag(net_production_val) OVER wp AS pnv,
           epoch(ts_value) - epoch(lag(ts_value) OVER wp) AS dt
      FROM read_parquet('$SRC')
     WHERE CAST(ts_value AS DATE) < DATE '$CUT'
    WINDOW wp AS (PARTITION BY id_equipment ORDER BY ts_value)
  ), f AS (
    SELECT *, (gi > 1000 AND gi * 60.0 / greatest(coalesce(dt, 60), 1) > 5000) AS g_fast,
              (ni > 1000 AND ni * 60.0 / greatest(coalesce(dt, 60), 1) > 5000) AS n_fast
      FROM l
  ), h AS (
    SELECT *, count(*) FILTER (WHERE g_fast) OVER wh AS g_fast_h, count(*) FILTER (WHERE n_fast) OVER wh AS n_fast_h
      FROM f
    WINDOW wh AS (PARTITION BY id_equipment, date_trunc('hour', ts_value))
  )
  SELECT CAST(ts_value AS DATE) AS day, $E AS enterprise, $Y AS year, $M AS month, id_equipment,
         sum(CASE WHEN gi < 0 OR (gi > 10000 AND gv > 0 AND gi >= 0.5 * gv)
                    OR (gi > 10000 AND pgv IS NOT NULL AND CASE WHEN gv < pgv THEN gi > gv + 1 ELSE (gv - pgv) < 0.5 * gi END)
                    OR (g_fast AND g_fast_h >= 3)
                  THEN NULL ELSE gi END) AS gross_production,
         sum(CASE WHEN ni < 0 OR (ni > 10000 AND nv > 0 AND ni >= 0.5 * nv)
                    OR (ni > 10000 AND pnv IS NOT NULL AND CASE WHEN nv < pnv THEN ni > nv + 1 ELSE (nv - pnv) < 0.5 * ni END)
                    OR (n_fast AND n_fast_h >= 3)
                  THEN NULL ELSE ni END) AS net_production,
         count(*) AS n_rows
    FROM h
   GROUP BY 1, 5
) TO '$DEST' (FORMAT PARQUET);
SQL
  done <<< "$MONTHS"
  if [ "$FULL" = 1 ] || [ -n "$HAVE" ]; then
    gw "INSERT INTO cold.ev_daily_watermark (id_enterprise, covered_until, refreshed_at) VALUES ($E, DATE '$CUT', now())
        ON CONFLICT (id_enterprise) DO UPDATE SET covered_until = EXCLUDED.covered_until, refreshed_at = now()" >/dev/null
    log "ent=$E watermark covered_until=$CUT"
  fi
done
