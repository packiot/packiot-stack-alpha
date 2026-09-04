#!/usr/bin/env bash
# historian-events-backfill.sh — archive legacy equipment_events -> S3 historian
# (closes the OEE-reconstruction coverage gap: downtime -> Availability + reasons).
# Same pattern as historian-backfill-raw.sh but: table=equipment_events, time col
# =ts_event, prefix=equipment_events/. Partition enterprise(=legacy id)/year/month.
# Read-only on legacy, throttled, resumable, -legacy.parquet filenames.
set -uo pipefail
export HOME=/tmp
DUCKDB="/.duckdb/cli/latest/duckdb"
BUCKET="packiot-staging-historian-639178078294"
LOG="/opt/packiot/historian-events-backfill.log"
THROTTLE="${THROTTLE:-2}"
TMP="/tmp/hev"; mkdir -p "$TMP"
PW="$(grep -E '^LEGACY_DB_PASSWORD=' /opt/packiot/.env | cut -d= -f2)"
CONN="host=18.220.223.110 port=5432 dbname=packiot40 user=awslambda password=$PW sslmode=disable"
Q(){ "$DUCKDB" -noheader -list -c "SET home_directory='/tmp'; INSTALL postgres; LOAD postgres; ATTACH '$CONN' AS legacy (TYPE postgres, READ_ONLY); $1" 2>>"$LOG"; }
log(){ echo "$(date -u +%Y-%m-%dT%H:%M:%S) $*" >> "$LOG"; }
log "=== EVENTS BACKFILL START ==="

part_done(){ aws s3 ls "s3://$BUCKET/equipment_events/enterprise=$1/year=$2/month=$3/" 2>/dev/null | grep -q 'legacy.parquet'; }

copy_month(){ # E d1 d2 Y Mo
  local E=$1 d1=$2 d2=$3 Y=$4 Mo=$5
  if part_done "$E" "$Y" "$Mo"; then return 0; fi
  local lf="$TMP/part.parquet"; rm -f "$lf"
  local q="SET home_directory='/tmp'; INSTALL postgres; LOAD postgres; ATTACH '$CONN' AS legacy (TYPE postgres, READ_ONLY);
COPY (SELECT * FROM postgres_query('legacy', \$SQ\$SELECT * FROM equipment_events WHERE id_enterprise=$E AND ts_event >= '$d1' AND ts_event < '$d2'\$SQ\$)) TO '$lf' (FORMAT PARQUET, COMPRESSION ZSTD);
SELECT count(*) FROM '$lf';"
  local n; n="$("$DUCKDB" -noheader -list -c "$q" 2>>"$LOG" | tail -1)"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then log "ent=$E $Y-$Mo COPY-FAIL($n)"; rm -f "$lf"; return 1; fi
  if [ "$n" -eq 0 ]; then rm -f "$lf"; return 0; fi
  aws s3 cp "$lf" "s3://$BUCKET/equipment_events/enterprise=$E/year=$Y/month=$Mo/data-$Y-$(printf %02d "$Mo")-legacy.parquet" >/dev/null 2>>"$LOG" \
    && log "ent=$E $Y-$Mo rows=$n OK" || log "ent=$E $Y-$Mo UPLOAD-FAIL"
  rm -f "$lf"; sleep "$THROTTLE"
}

# derive per-enterprise date range from legacy (read-only)
Q "COPY (SELECT * FROM postgres_query('legacy', \$\$SELECT id_enterprise, min(ts_event)::date, max(ts_event)::date FROM equipment_events WHERE id_enterprise IS NOT NULL GROUP BY 1 ORDER BY 1\$\$)) TO '/tmp/ev_inv.csv' (HEADER)" >/dev/null
tail -n +2 /tmp/ev_inv.csv | while IFS=, read -r E FIRST LAST; do
  [ -z "$E" ] && continue
  sm="${FIRST%-*}"; em="${LAST%-*}"
  cur="$sm-01"
  log "--- ent=$E $sm .. $em ---"
  while [[ "${cur:0:7}" < "$em" || "${cur:0:7}" == "$em" ]]; do
    Y="${cur:0:4}"; Mo=$((10#${cur:5:2}))
    nxt="$(date -d "$cur +1 month" +%Y-%m-01)"
    copy_month "$E" "$cur" "$nxt" "$Y" "$Mo"
    cur="$nxt"
  done
done
log "=== EVENTS BACKFILL DONE ==="
