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
# increment is dropped when it is negative, or when it is at least half the machine's lifetime
# totalizer AND above 10,000 in a single row — the signature of legacy writing the totalizer
# into the increment column (POLYTYPE 2022-10..2023-09 ~1e12, the 2024-07-22 replay, 2026-08).
# A counter reset keeps its (small) first increment because of the 10,000 floor.
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
CREATE MACRO bad(i, v) AS (i < 0 OR (v > 0 AND i >= 0.5 * v AND i > 10000));
COPY (
  SELECT CAST(ts_value AS DATE) AS day, $E AS enterprise, $Y AS year, $M AS month, id_equipment,
         sum(CASE WHEN bad(gross_production_incr, gross_production_val) THEN NULL ELSE gross_production_incr END) AS gross_production,
         sum(CASE WHEN bad(net_production_incr, net_production_val) THEN NULL ELSE net_production_incr END)       AS net_production,
         count(*) AS n_rows
    FROM read_parquet('$SRC')
   WHERE CAST(ts_value AS DATE) < DATE '$CUT'
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
