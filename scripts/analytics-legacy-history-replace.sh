#!/usr/bin/env bash
# analytics-legacy-history-replace.sh — RE-STAGE CPACK gold history from legacy with the
# 2026-09-29 "no clamps distorting data" transform, for db/backfill/replace-legacy-history.sql.
#
# WHY (2026-09-29 layer audit vs legacy):
#   * the T1 backfill (analytics-legacy-history-backfill.sh) only filled BELOW the earliest
#     analytics row, so 2026-07-23..08-31 kept stale early new-stack output (July L3/L4/L8
#     ≈2.8× legacy, August 3–98%), and weeks 2026-01-19..07-20 stayed zero skeletons;
#   * it CLAMPED: factors to [0,1], net = LEAST(net, gross) (May net down to 0.49 of legacy),
#     while keeping legacy scrap; hourly rows got oee_a = oee_p = 0 with oee > 0 (53,895).
# WINDOW: everything before production day 2026-09-01 (the silver feed hole ended
#   2026-09-01 00:29 UTC; from production day 09-01 on, gold is the engine's, from real feed).
# TRANSFORM (engine semantics): net/gross/times as measured; scrap = gross − net (signed);
#   A = min(running/available, 1); P = gross·available/(ideal·running); Q = net/gross;
#   oee = A·P·Q; any factor > 10 is impossible → NULL (oee NULL too).
# Staged into ops.bf2_<table>; nothing live is touched here.
set -euo pipefail
export HOME="${HOME:-/root}"
log(){ echo "[history-replace] $*"; }
DUCKDB=""; for c in /opt/packiot/duckdb/duckdb "$HOME/.duckdb/cli/latest/duckdb" /root/.duckdb/cli/latest/duckdb "$(command -v duckdb||true)"; do [ -x "$c" ] && DUCKDB="$c" && break; done
[ -z "$DUCKDB" ] && { log "duckdb not found"; exit 3; }
ENVFILE="${SRC_PG_ENVFILE:-/opt/packiot/.env}"
envget(){ grep -m1 "^$1=" "$ENVFILE" 2>/dev/null | cut -d= -f2- || true; }
: "${LEGACY_DB_PASSWORD:?LEGACY_DB_PASSWORD required (Secrets Manager databaseCredentials; the .env value is stale)}"
APW="${ANALYTICS_DB_PASSWORD:-$(envget POSTGRES_PASSWORD)}"
LEG_HOST="${LEGACY_DB_HOST:-18.220.223.110}"; LEG_USER="${LEGACY_DB_USER:-awslambda}"; LEG_DB="${LEGACY_DB_NAME:-packiot40}"
AN_HOST="${DB_HOST:-10.10.10.89}"
LEG_ENT="${LEG_ENT:-1}"; F3_ENT="${F3_ENT:-3}"
BOUNDARY="${BOUNDARY:-2026-09-01}"   # first production day owned by the engine
HOURLY_FLOOR="$(date -u -d '13 months ago' +%Y-%m-%d)"
GRAINS="${GRAINS:-shift hourly daily weekly monthly area_shift area_daily site_shift}"

# grain -> legacy table | gold table | key kind | window column | features
spec(){ case "$1" in
  shift)      echo "equipment_runtime_shift|equipment_oee_shift|eq|ts_value_production|shift,cd,range" ;;
  hourly)     echo "equipment_runtime_1hour|equipment_oee_hourly|eq|ts_value_production|team" ;;
  daily)      echo "equipment_runtime_1day|equipment_oee_daily|eq|ts_value|" ;;
  weekly)     echo "equipment_runtime_1week|equipment_oee_weekly|eq|ts_value|week" ;;
  monthly)    echo "equipment_runtime_1month|equipment_oee_monthly|eq|ts_value|" ;;
  area_shift) echo "area_runtime_shift|area_oee_shift|area|ts_value_production|shift,range" ;;
  area_daily) echo "area_runtime_1day|area_oee_daily|area|ts_value|" ;;
  site_shift) echo "site_runtime_shift|site_oee_shift|site|ts_value_production|shift,range" ;;
  *) log "unknown grain $1"; exit 2 ;; esac; }

SQL="$(mktemp)"; trap 'rm -f "$SQL"' EXIT
cat > "$SQL" <<EOF
INSTALL postgres; LOAD postgres;
ATTACH 'host=${LEG_HOST} port=5432 dbname=${LEG_DB} user=${LEG_USER} password=${LEGACY_DB_PASSWORD}' AS leg (TYPE postgres, READ_ONLY);
ATTACH 'host=${AN_HOST} port=5432 dbname=packiot_analytics user=postgres password=${APW}' AS an (TYPE postgres);
CREATE TEMP TABLE map_eq AS
  SELECT DISTINCT l.id_equipment AS leg_id, f.id_equipment AS new_id, f.id_area AS new_area
  FROM postgres_query('leg','SELECT DISTINCT id_equipment, packml_topic FROM packml_register WHERE id_enterprise=${LEG_ENT} AND active=true AND id_equipment IS NOT NULL') l
  JOIN postgres_query('an','SELECT DISTINCT p.id_equipment, p.packml_topic, e.id_area FROM core.packml_register p JOIN core.equipments e USING (id_equipment) WHERE p.id_enterprise=${F3_ENT} AND p.active=true') f
    ON replace(l.packml_topic,'C-PACK','CPACK') = f.packml_topic;
CREATE TEMP TABLE map_area AS
  SELECT l.id_area AS leg_id, f.id_area AS new_id, f.id_area AS new_area
  FROM postgres_query('leg','SELECT a.id_area, a.nm_area FROM areas a JOIN sites s USING (id_site) WHERE s.id_enterprise=${LEG_ENT}') l
  JOIN postgres_query('an','SELECT a.id_area, a.nm_area FROM core.areas a JOIN core.sites s USING (id_site) WHERE s.id_enterprise=${F3_ENT}') f USING (nm_area);
CREATE TEMP TABLE map_site AS
  SELECT l.id_site AS leg_id, f.id_site AS new_id, f.first_area AS new_area
  FROM postgres_query('leg','SELECT id_site, nm_site FROM sites WHERE id_enterprise=${LEG_ENT}') l
  JOIN postgres_query('an','SELECT s.id_site, s.nm_site, min(a.id_area) first_area FROM core.sites s JOIN core.areas a USING (id_site) WHERE s.id_enterprise=${F3_ENT} GROUP BY 1,2') f USING (nm_site);
CREATE TEMP TABLE leg_cd AS
  SELECT id_shift AS leg_shift, max(cd_shift) AS cd FROM (
    SELECT * FROM postgres_query('leg','SELECT id_shift, cd_shift::text AS cd_shift FROM shifts WHERE id_enterprise=${LEG_ENT}')
    UNION ALL
    SELECT * FROM postgres_query('leg','SELECT DISTINCT s.id_shift, s.cd_shift::text FROM equipment_runtime_shift s JOIN equipments e USING (id_equipment) WHERE e.id_enterprise=${LEG_ENT} AND s.cd_shift IS NOT NULL')
  ) GROUP BY 1;
CREATE TEMP TABLE cur_shift AS
  SELECT * FROM postgres_query('an','SELECT cd_shift::text AS cd, id_area, id_shift FROM core.shifts WHERE id_enterprise=${F3_ENT}');
SELECT 'maps' k, (SELECT count(*) FROM map_eq) eq, (SELECT count(*) FROM map_area) areas, (SELECT count(*) FROM map_site) sites, (SELECT count(*) FROM cur_shift) cur_shifts;
EOF

for g in $GRAINS; do
  IFS='|' read -r LT GT KIND WCOL FEAT <<<"$(spec "$g")"
  case "$KIND" in
    eq)   KEYCOL=id_equipment; MAP=map_eq;   ENTF="id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise=${LEG_ENT})" ;;
    area) KEYCOL=id_area;      MAP=map_area; ENTF="id_area IN (SELECT a.id_area FROM areas a JOIN sites s USING (id_site) WHERE s.id_enterprise=${LEG_ENT})" ;;
    site) KEYCOL=id_site;      MAP=map_site; ENTF="id_site IN (SELECT id_site FROM sites WHERE id_enterprise=${LEG_ENT})" ;;
  esac
  # weekly rows are keyed by week start: the week containing the boundary belongs to the engine
  WEND="'${BOUNDARY}'"; [[ ",$FEAT," == *",week,"* ]] && WEND="(DATE '${BOUNDARY}' - 7)"
  WIN="${WCOL}::date < ${WEND}"; [ "$g" = hourly ] && WIN="$WIN AND ts_value >= '${HOURLY_FLOOR}'"
  A="CASE WHEN t.available_time > 0 THEN LEAST(t.running_time::double / t.available_time, 1) ELSE 0 END"
  P="CASE WHEN t.ideal_production > 0 AND t.running_time > 0 THEN t.gross::double * t.available_time / (t.ideal_production * t.running_time) ELSE 0 END"
  Q="CASE WHEN t.gross > 0 THEN t.net::double / t.gross ELSE 0 END"
  R="m.new_id AS ${KEYCOL}, false AS recalc_needed, t.net AS net, (t.gross - t.net) AS scrap,
     CASE WHEN ($A) > 10 THEN NULL ELSE ($A) END AS oee_a,
     CASE WHEN ($P) > 10 THEN NULL ELSE ($P) END AS oee_p,
     CASE WHEN ($Q) > 10 THEN NULL ELSE ($Q) END AS oee_q,
     CASE WHEN ($P) > 10 OR ($Q) > 10 OR ($A)*($P)*($Q) > 10 THEN NULL ELSE ($A)*($P)*($Q) END AS oee"
  EXCL="${KEYCOL}, oee, recalc_needed, oee_p, oee_a, oee_q, net, scrap"
  JOINS=""
  if [[ ",$FEAT," == *",shift,"* ]]; then
    CDX="lc.cd"; [[ ",$FEAT," == *",cd,"* ]] && CDX="COALESCE(t.cd_shift::varchar, lc.cd)"
    R="$R, cs.id_shift AS id_shift, NULL::int AS id_shift_hour, NULL::int AS id_team"
    JOINS="LEFT JOIN leg_cd lc ON lc.leg_shift = t.id_shift LEFT JOIN cur_shift cs ON cs.cd = ${CDX} AND cs.id_area = m.new_area"
    EXCL="$EXCL, id_shift, id_shift_hour, id_team"
  fi
  [[ ",$FEAT," == *",team,"* ]] && { R="$R, NULL::int AS id_team"; EXCL="$EXCL, id_team"; }
  [[ ",$FEAT," == *",range,"* ]] && { R="$R, t.ts_range::varchar AS ts_range"; EXCL="$EXCL, ts_range"; }
  [ "$g" = shift ] && EXCL="$EXCL, id_runtime_shift"
  cat >> "$SQL" <<EOF
-- ── ${g}: leg.${LT} -> gold.${GT} (${WIN}) ──
DROP TABLE IF EXISTS an.ops.bf2_${GT};
CREATE TABLE an.ops.bf2_${GT} AS
  SELECT t.* EXCLUDE (${EXCL}), ${R}, now()::timestamptz AS computed_at, NULL::timestamptz AS source_watermark
  FROM postgres_query('leg', \$\$SELECT * FROM ${LT} WHERE ${ENTF} AND ${WIN}\$\$) t
  JOIN ${MAP} m ON m.leg_id = t.${KEYCOL}
  ${JOINS};
SELECT '${g}' AS grain, count(*) staged, min(ts_value)::varchar min_ts, max(ts_value)::varchar max_ts,
       round(sum(gross)) gross, round(sum(net)) net, count(*) FILTER (WHERE oee IS NULL) oee_null FROM an.ops.bf2_${GT};
EOF
done
log "staging grains=[${GRAINS}] before production day ${BOUNDARY} (hourly floor ${HOURLY_FLOOR})"
"$DUCKDB" -c ".read $SQL"
log "staged. Next: psql -d packiot_analytics -v mode=dry -f db/backfill/replace-legacy-history.sql"
