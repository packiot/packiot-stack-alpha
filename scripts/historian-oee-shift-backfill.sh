#!/usr/bin/env bash
# historian-oee-shift-backfill.sh — legacy packiot40 equipment_runtime_shift -> historian COLD.
#
# Item A of docs/plans/historian-derived-history-backfill-2021.md. The historian's
# equipment_oee_shift cold Parquet only had year=2026; the DERIVED shift-OEE grain for 2021-2025
# was never archived. Recomputing it from cold raw is impractical (the shift rollup runs in the
# analytics DB, not DuckDB, and analytics is ~3-month hot). Legacy's equipment_runtime_shift IS
# the authentic historical shift-OEE (computed live by legacy over 2021-2025), so this copies it
# with the legacy->F3 id_equipment remap (the #167 packml-topic map) into the cold archive the
# existing gold.equipment_oee_shift read_parquet view already globs (*.parquet, cold-only — no
# hot union, so NO boundary/double-count concern, unlike EV/EE/PO).
set -euo pipefail
export HOME="${HOME:-/tmp}"
log(){ echo "[oee-shift-backfill] $*"; }
DUCKDB=""; for c in /opt/packiot/duckdb/duckdb "$HOME/.duckdb/cli/latest/duckdb" /root/.duckdb/cli/latest/duckdb "$(command -v duckdb||true)"; do [ -x "$c" ] && DUCKDB="$c" && break; done
[ -z "$DUCKDB" ] && { log "duckdb not found"; exit 3; }
ENVFILE="${SRC_PG_ENVFILE:-/opt/packiot/.env}"
envget(){ grep -m1 "^$1=" "$ENVFILE" 2>/dev/null | cut -d= -f2- || true; }
LPW="${LEGACY_DB_PASSWORD:-$(envget LEGACY_DB_PASSWORD)}"
APW="${ANALYTICS_DB_PASSWORD:-$(envget POSTGRES_PASSWORD)}"
LEG_HOST="${LEGACY_DB_HOST:-$(envget LEGACY_DB_HOST)}"; LEG_HOST="${LEG_HOST:-18.220.223.110}"
LEG_USER="${LEGACY_DB_USER:-$(envget LEGACY_DB_USER)}"; LEG_USER="${LEG_USER:-awslambda}"
LEG_DB="${LEGACY_DB_NAME:-$(envget LEGACY_DB_NAME)}"; LEG_DB="${LEG_DB:-packiot40}"
AN_HOST="${DB_HOST:-10.10.10.89}"
BUCKET="${HISTORIAN_BUCKET:-packiot-staging-historian-639178078294}"
TENANTS="${SHIFT_COPY_TENANTS:-1:3}"
LAG_DAYS="${SHIFT_COPY_LAG_DAYS:-1}"
MONTHS_BACK="${SHIFT_COPY_MONTHS_BACK:-60}"    # ~60 reaches 2021; idempotent
# END caps the newest month. Legacy still computes CPACK shift-OEE to now (post-F3-cutover), so
# legacy-copy keeps the cold archive CONTINUOUS to `now`, like EV/PO — no hot union needed.
# (The original ad-hoc equipment_oee_shift/year=2026/month=8/data-2026-08.parquet was REMOVED and
# replaced by the fuller data-2026-08-legacy.parquet, so a to-now END no longer double-writes 2026.)
END="${SHIFT_COPY_END:-$(date -u -d "today -${LAG_DAYS} days" +%Y-%m-%d)}"
for pair in $TENANTS; do
  LEGENT="${pair%%:*}"; F3ENT="${pair##*:}"
  for k in $(seq 0 "$MONTHS_BACK"); do
    Y="$(date -u -d "$(date -u +%Y-%m-01) -${k} months" +%Y)"; M="$(date -u -d "$(date -u +%Y-%m-01) -${k} months" +%-m)"
    MSTART="$(printf '%04d-%02d-01' "$Y" "$M")"; MEND="$(date -u -d "$MSTART +1 month" +%Y-%m-%d)"
    EFF_END="$MEND"; [ "$MEND" \> "$END" ] && EFF_END="$END"
    { [ "$MSTART" \> "$EFF_END" ] || [ "$MSTART" = "$EFF_END" ]; } && { log "ent=$LEGENT $Y-$M below lag boundary, skip"; continue; }
    DEST="s3://${BUCKET}/equipment_oee_shift/enterprise=${F3ENT}/year=${Y}/month=${M}/data-${Y}-$(printf %02d "$M")-legacy.parquet"
    log "ent=$LEGENT->F3 $F3ENT month=$Y-$M window=[$MSTART,$EFF_END) -> $DEST"
    # Bounded DuckDB (2026-09-25): unbounded, DuckDB defaults to 80 pct of RAM (~6.4 GB on the 8 GB app
    # host shared with ~45 containers). The first nightly run (02:30) exhausted memory and thrashed the host
    # for ~1.5 h (read-api/operator/csadmin down, rollups stalled). Now it spills to temp_directory instead.
    mkdir -p "${DUCKDB_TMP:-/var/tmp/historian-duckdb}"
    "$DUCKDB" <<SQL
SET memory_limit='${DUCKDB_MEMORY_LIMIT:-1200MB}'; SET threads=${DUCKDB_THREADS:-1}; SET s3_uploader_thread_limit=${DUCKDB_S3_UPLOAD_THREADS:-2};
SET temp_directory='${DUCKDB_TMP:-/var/tmp/historian-duckdb}'; SET preserve_insertion_order=false;
INSTALL httpfs; LOAD httpfs; INSTALL postgres; LOAD postgres;
CREATE SECRET s3sec (TYPE S3, PROVIDER credential_chain, REGION 'us-east-1');
ATTACH 'host=${LEG_HOST} port=5432 dbname=${LEG_DB} user=${LEG_USER} password=${LPW}' AS leg (TYPE postgres, READ_ONLY);
ATTACH 'host=${AN_HOST} port=5432 dbname=packiot_analytics user=postgres password=${APW}' AS an (TYPE postgres, READ_ONLY);
CREATE TEMP TABLE map AS SELECT DISTINCT l.id_equipment AS leg_id, f.id_equipment AS f3_id
 FROM postgres_query('leg','SELECT DISTINCT id_equipment, packml_topic FROM packml_register WHERE id_enterprise=${LEGENT} AND active=true AND id_equipment IS NOT NULL') l
 JOIN postgres_query('an','SELECT DISTINCT id_equipment, packml_topic FROM core.packml_register WHERE id_enterprise=${F3ENT} AND active=true AND id_equipment IS NOT NULL') f
   ON replace(l.packml_topic,'C-PACK','CPACK')=f.packml_topic;
COPY (
  SELECT s.id_runtime_shift, s.ts_value, map.f3_id AS id_equipment, s.oee, s.recalc_needed,
    GREATEST(LEAST(COALESCE(s.oee_p,0),1),0) AS oee_p, GREATEST(LEAST(COALESCE(s.oee_a,0),1),0) AS oee_a,
    CASE WHEN s.gross>0 THEN GREATEST(LEAST(s.net/s.gross,1),0) ELSE COALESCE(s.oee_q,0) END AS oee_q,
    s.available_time, s.running_time, s.stopped_time, s.planned_downtime, s.ideal_production,
    s.idle_time, s.idle_starved, s.idle_blocked, s.id_shift, s.id_shift_hour, s.id_team, s.duration,
    s.ts_range::varchar AS ts_range, s.gross, LEAST(s.net, s.gross) AS net, s.downtime, s.changeover_time,
    s.target, s.ts_end, s.manually_customized, s.invalidated, s.scrap, s.speed, s.cd_shift,
    s.ts_value_production, s.target_customized, s.proportional_target, s.ideal_speed,
    now()::timestamptz AS computed_at, NULL::timestamptz AS source_watermark,
    ${F3ENT} AS id_enterprise, ${F3ENT} AS enterprise, ${Y} AS year, ${M} AS month
  FROM (SELECT * FROM postgres_query('leg','SELECT * FROM equipment_runtime_shift WHERE ts_value>=''${MSTART}'' AND ts_value<''${EFF_END}''')) s
  JOIN map ON map.leg_id = s.id_equipment
) TO '${DEST}' (FORMAT parquet, COMPRESSION ZSTD, ROW_GROUP_SIZE ${DUCKDB_ROW_GROUP_SIZE:-20000}, OVERWRITE_OR_IGNORE);
SQL
  done
done
log "done tenants=[${TENANTS}] months_back=${MONTHS_BACK} end<${END} (cold-only view; no boundary refresh needed)"
