#!/usr/bin/env bash
# historian-po-backfill.sh — legacy packiot40 production_orders -> historian COLD (Parquet on S3).
#
# Sibling of historian-legacy-copy.sh (raw equipment_values) and historian-events-backfill.sh
# (equipment_events): fills the COLD production_orders archive that the analytics DB does NOT keep
# (analytics is ~3-month hot by design; the full PO history lives in legacy). Read-only on legacy.
# Remaps legacy->F3 id_equipment via the packml-topic join (the SAME validated #167 remap the EV
# copy uses), scopes to F3 tenant + partitions by ts_start month, writes *-legacy.parquet
# (idempotent overwrite). Legacy-computed OEE is copied with the current-stack correctness clamps
# (net<=gross, oee_q=net/gross, factors bounded [0,1]) so the archive is not worse than analytics.
#
# The served range comes from analytics (hot FDW, last ~3mo) via live.production_orders; this fills
# COLD with the COMPLETE history back to legacy's earliest (2021-12). After every run the PO cutover
# boundary MUST be refreshed (refresh-po-cutover.sql) or silver.production_orders double-counts the
# newly-archived window (same invariant as EV — see the gateway README).
set -euo pipefail
export HOME="${HOME:-/tmp}"
log(){ echo "[po-backfill] $*"; }
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
TENANTS="${PO_COPY_TENANTS:-1:3}"              # legacyEnt:F3Ent  (CPACK 1->3)
LAG_DAYS="${PO_COPY_LAG_DAYS:-1}"              # leave last N days to analytics (hot/live)
# Default deep enough to reach legacy's earliest PO (2021-12): ~60 months. Idempotent, so a
# large value is safe (empty months write an empty/no parquet and are skipped below the lag).
MONTHS_BACK="${PO_COPY_MONTHS_BACK:-60}"
END="$(date -u -d "today -${LAG_DAYS} days" +%Y-%m-%d)"
for pair in $TENANTS; do
  LEGENT="${pair%%:*}"; F3ENT="${pair##*:}"
  for k in $(seq 0 "$MONTHS_BACK"); do
    Y="$(date -u -d "$(date -u +%Y-%m-01) -${k} months" +%Y)"; M="$(date -u -d "$(date -u +%Y-%m-01) -${k} months" +%-m)"
    MSTART="$(printf '%04d-%02d-01' "$Y" "$M")"; MEND="$(date -u -d "$MSTART +1 month" +%Y-%m-%d)"
    EFF_END="$MEND"; [ "$MEND" \> "$END" ] && EFF_END="$END"
    { [ "$MSTART" \> "$EFF_END" ] || [ "$MSTART" = "$EFF_END" ]; } && { log "ent=$LEGENT $Y-$M below lag boundary, skip"; continue; }
    DEST="s3://${BUCKET}/production_orders/enterprise=${F3ENT}/year=${Y}/month=${M}/data-${Y}-$(printf %02d "$M")-legacy.parquet"
    log "ent=$LEGENT->F3 $F3ENT month=$Y-$M window=[$MSTART,$EFF_END) -> $DEST"
    "$DUCKDB" <<SQL
INSTALL httpfs; LOAD httpfs; INSTALL postgres; LOAD postgres;
CREATE SECRET s3sec (TYPE S3, PROVIDER credential_chain, REGION 'us-east-1');
ATTACH 'host=${LEG_HOST} port=5432 dbname=${LEG_DB} user=${LEG_USER} password=${LPW}' AS leg (TYPE postgres, READ_ONLY);
ATTACH 'host=${AN_HOST} port=5432 dbname=packiot_analytics user=postgres password=${APW}' AS an (TYPE postgres, READ_ONLY);
-- legacy id_equipment -> F3 id_equipment via the packml-topic map (== the EV copy's #167 remap).
CREATE TEMP TABLE map AS SELECT DISTINCT l.id_equipment AS leg_id, f.id_equipment AS f3_id
 FROM postgres_query('leg','SELECT DISTINCT id_equipment, packml_topic FROM packml_register WHERE id_enterprise=${LEGENT} AND active=true AND id_equipment IS NOT NULL') l
 JOIN postgres_query('an','SELECT DISTINCT id_equipment, packml_topic FROM core.packml_register WHERE id_enterprise=${F3ENT} AND active=true AND id_equipment IS NOT NULL') f
   ON replace(l.packml_topic,'C-PACK','CPACK')=f.packml_topic;
CREATE TEMP TABLE eqdim AS SELECT * FROM postgres_query('an','SELECT id_equipment,id_site,id_area FROM core.equipments WHERE id_enterprise=${F3ENT}');
COPY (
  SELECT lpo.ts_start, lpo.ts_end, ${F3ENT} AS id_enterprise, eq.id_site, eq.id_area, map.f3_id AS id_equipment,
    lpo.id_order, lpo.status,
    lpo.gross_production,
    -- current-stack clamps: net can never exceed gross; quality = net/gross bounded [0,1];
    -- availability/performance bounded [0,1]. Keeps the archive at least as correct as analytics.
    LEAST(lpo.net_production, lpo.gross_production)                                   AS net_production,
    GREATEST(LEAST(COALESCE(lpo.oee_availability,0),1),0)                             AS oee_a,
    GREATEST(LEAST(COALESCE(lpo.oee_performance,0),1),0)                              AS oee_p,
    CASE WHEN lpo.gross_production>0 THEN GREATEST(LEAST(lpo.net_production/lpo.gross_production,1),0) ELSE 0 END AS oee_q,
    GREATEST(LEAST(COALESCE(lpo.oee_availability,0)*COALESCE(lpo.oee_performance,0)
      *CASE WHEN lpo.gross_production>0 THEN LEAST(lpo.net_production/lpo.gross_production,1) ELSE 0 END,1),0) AS oee,
    lpo.running_time, lpo.stopped_time, lpo.available_time, lpo.planned_downtime,
    lpo.production_programmed, lpo.production_ordered, lpo.production_real, lpo.production_final,
    ${F3ENT} AS enterprise, ${Y} AS year, ${M} AS month
  FROM (SELECT * FROM postgres_query('leg','SELECT id_order, id_equipment, status, ts_start, ts_end, gross_production, net_production, oee_availability, oee_performance, running_time, stopped_time, available_time, planned_downtime, production_programmed, production_ordered, production_real, production_final FROM production_orders WHERE id_enterprise=${LEGENT} AND ts_start>=''${MSTART}'' AND ts_start<''${EFF_END}'' AND id_order IS NOT NULL')) lpo
  JOIN map ON map.leg_id = lpo.id_equipment
  JOIN eqdim eq ON eq.id_equipment = map.f3_id
) TO '${DEST}' (FORMAT parquet, COMPRESSION ZSTD, OVERWRITE_OR_IGNORE);
SQL
  done
done
log "done tenants=[${TENANTS}] months_back=${MONTHS_BACK} end<${END} — NOW RUN refresh-po-cutover.sql"
