#!/usr/bin/env bash
# historian-legacy-copy.sh — TEMPORARY scheduled COPY: legacy packiot40 -> historian COLD.
# Read-only on legacy; remaps legacy->F3 via the packml-topic join (validated == the #167
# remap); translates to the 56-col hist schema; writes *-legacy.parquet (idempotent overwrite
# of current + previous month). LIVE data is served from analytics (hot FDW); this fills COLD
# with COMPLETE (all-machine) history/recent. Retired at the #225 legacy cutover.
set -euo pipefail
export HOME="${HOME:-/tmp}"
log(){ echo "[legacy-copy] $*"; }
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
TENANTS="${LEGACY_COPY_TENANTS:-1:3}"          # legacyEnt:F3Ent  (CPACK 1->3)
LAG_DAYS="${LEGACY_COPY_LAG_DAYS:-1}"          # leave last N days to analytics (hot/live)
MONTHS_BACK="${LEGACY_COPY_MONTHS_BACK:-1}"    # current + N previous months (idempotent)
END="$(date -u -d "today -${LAG_DAYS} days" +%Y-%m-%d)"
for pair in $TENANTS; do
  LEGENT="${pair%%:*}"; F3ENT="${pair##*:}"
  for k in $(seq 0 "$MONTHS_BACK"); do
    Y="$(date -u -d "$(date -u +%Y-%m-01) -${k} months" +%Y)"; M="$(date -u -d "$(date -u +%Y-%m-01) -${k} months" +%-m)"
    MSTART="$(printf '%04d-%02d-01' "$Y" "$M")"; MEND="$(date -u -d "$MSTART +1 month" +%Y-%m-%d)"
    EFF_END="$MEND"; [ "$MEND" \> "$END" ] && EFF_END="$END"
    [ "$MSTART" \> "$EFF_END" ] || [ "$MSTART" = "$EFF_END" ] && { log "ent=$LEGENT $Y-$M below lag boundary, skip"; continue; }
    DEST="s3://${BUCKET}/equipment_values/enterprise=${F3ENT}/year=${Y}/month=${M}/data-${Y}-$(printf %02d "$M")-legacy.parquet"
    log "ent=$LEGENT->F3 $F3ENT month=$Y-$M window=[$MSTART,$EFF_END) -> $DEST"
    # Bounded DuckDB (2026-09-25): unbounded, DuckDB defaults to 80 pct of RAM (~6.4 GB on the 8 GB app
    # host shared with ~45 containers). The first nightly run (02:30) exhausted memory and thrashed the host
    # for ~1.5 h (read-api/operator/csadmin down, rollups stalled). Now it spills to temp_directory instead.
    mkdir -p "${DUCKDB_TMP:-/var/tmp/historian-duckdb}"
    # Stage the month DAY BY DAY into a file-backed DuckDB table (spills to disk) instead of one
    # month-wide postgres_query, which materializes ~4.7 M wide rows in memory and cannot fit the
    # bounded 1.2 GB budget. Output is unchanged: the same single monthly parquet at $DEST.
    STAGE_DB="${DUCKDB_TMP:-/var/tmp/historian-duckdb}/legacy-stage-${F3ENT}-${Y}-${M}.duckdb"
    rm -f "$STAGE_DB" "$STAGE_DB.wal"
    DAY_INSERTS=""; D="$MSTART"
    while [ "$D" \< "$EFF_END" ]; do
      DN="$(date -u -d "$D +1 day" +%Y-%m-%d)"; [ "$DN" \> "$EFF_END" ] && DN="$EFF_END"
      DAY_INSERTS="${DAY_INSERTS}INSERT INTO lev SELECT * FROM postgres_query('leg','SELECT * FROM equipment_values WHERE id_enterprise=${LEGENT} AND ts_value>=''${D}'' AND ts_value<''${DN}''');
"
      D="$DN"
    done
    "$DUCKDB" "$STAGE_DB" <<SQL
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
CREATE TEMP TABLE eqdim AS SELECT * FROM postgres_query('an','SELECT id_equipment,id_site,id_area FROM core.equipments WHERE id_enterprise=${F3ENT}');
CREATE TABLE lev AS SELECT * FROM postgres_query('leg','SELECT * FROM equipment_values WHERE false');
${DAY_INSERTS}
COPY (
  SELECT lev.ts_value, ${F3ENT} AS id_enterprise, eq.id_site, eq.id_area, map.f3_id AS id_equipment,
    lev.net_production_incr, lev.gross_production_incr, lev.scrap_incr, lev.speed, lev.id_order, lev.conversion_factor,
    lev.number_cavities, lev.faults, lev.analogs, lev.signal_quality, lev.net_production_val, lev.gross_production_val,
    lev.scrap_val, lev.id_shift, lev.id_team, lev.id_shift_hour, lev.box_code, lev.transaction_code, lev.state, lev.mode,
    lev.id_production_order, lev.ts_value_production, mi.f3_id AS id_equipment_line_infeed, mo.f3_id AS id_equipment_line_outfeed,
    lev.net_production_incr_quality, lev.gross_production_incr_quality, lev.scrap_incr_quality, lev.speed_quality, lev.id_order_quality,
    lev.conversion_factor_quality, lev.number_cavities_quality, lev.net_production_val_quality, lev.gross_production_val_quality,
    lev.scrap_val_quality, lev.id_shift_quality, lev.state_quality, lev.mode_quality, lev.id_production_order_quality,
    lev.ts_value_production_quality, mc.f3_id AS id_equipment_line_connected, lev.position_in_equipment_line,
    lev.is_equipment_line_infeed, lev.is_equipment_line_outfeed, lev.process_scrap_incr, lev.process_scrap_val,
    lev.process_scrap_incr_quality, lev.process_scrap_val_quality, lev.tp_equipment, lev.sub_mode, lev.ideal_production_speed,
    lev.check_number, ${F3ENT} AS enterprise, ${Y} AS year, ${M} AS month
  FROM lev
  JOIN map ON map.leg_id = lev.id_equipment
  JOIN eqdim eq ON eq.id_equipment = map.f3_id
  LEFT JOIN map mi ON mi.leg_id = lev.id_equipment_line_infeed
  LEFT JOIN map mo ON mo.leg_id = lev.id_equipment_line_outfeed
  LEFT JOIN map mc ON mc.leg_id = lev.id_equipment_line_connected
) TO '${DEST}' (FORMAT parquet, COMPRESSION ZSTD, ROW_GROUP_SIZE ${DUCKDB_ROW_GROUP_SIZE:-20000}, OVERWRITE_OR_IGNORE);
SQL
    rm -f "$STAGE_DB" "$STAGE_DB.wal"
  done
done
log "done tenants=[${TENANTS}] end<${END}"
