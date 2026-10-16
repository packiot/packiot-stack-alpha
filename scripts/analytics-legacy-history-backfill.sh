#!/usr/bin/env bash
# analytics-legacy-history-backfill.sh — STAGE legacy (packiot40) OEE history into
# packiot_analytics ops.bf_* tables, for T1 of
# docs/plans/unified-hot-cold-serving-grain-tiered-retention.md.
#
# WHY: analytics keeps client-facing grains long (ops.retention_policy) but only has
# them since the stack went live (~Jun/Jul 2026). Legacy computed the same grains
# live for 2021→; they are the authentic history. Copying them INTO analytics means
# every serving.* function / bi.* view / Superset chart / front4 screen shows years
# of history with zero code change and full RLS ("seamless by construction").
#
# TWO STEPS (deliberately separate — stage is cheap + inspectable, merge is the only write
# to live tables and runs in ONE transaction with validation gates):
#   1. this script (app box, DuckDB): legacy → transform → ops.bf_<grain> staging tables
#   2. db/backfill/merge-legacy-history.sql (DB box, psql): gates + ops.bf_merge()
#      (ON CONFLICT DO NOTHING — never overwrites pipeline rows); MODE=dry rolls back.
#
# TRANSFORM (same contract as the parity-proven historian archive, +OEE clamp):
#   ids   : equipment by packml topic (C-PACK→CPACK), area/site by name,
#           shift by (cd_shift, current area) — 20 serving fns JOIN core.shifts on id_shift;
#           id_shift_hour/id_team → NULL (unused by serving; CPACK has no teams).
#   values: factors clamped [0,1]; oee clamped [0,1] (legacy had 2.4% >1, current never);
#           net = LEAST(net,gross); oee_q = net/gross when gross>0.
#   flags : recalc_needed=false (the pipeline must NEVER recompute these — their raw is gone,
#           a recompute would zero them); computed_at=now(); source_watermark NULL.
#   window: strictly BELOW the earliest row analytics already has for the tenant per grain
#           (pipeline rows own their range); hourly also >= now()-13 months (its keep).
#
# Usage (on the app box, root): scripts/analytics-legacy-history-backfill.sh
#   env: LEG_ENT=1 F3_ENT=3 GRAINS="shift hourly daily weekly monthly shift_weekly shift_monthly area_shift area_daily site_shift po"
#
# The `po` grain stages clients + production_orders + production_orders_runtime:
#   * PO/runtime ids = LEGACY_ID_OFFSET (1e8) + legacy id — legacy ids collide with other
#     tenants' current ids; 1e8+ stays inside int4 (serving row types still declare integer)
#     and above every current id, and reads as provenance.
#   * clients keep legacy ids (21928+ vs current 1; like the products dimension backfill).
#   * only STARTED POs (ts_start < boundary); never-started legacy POs would pollute the
#     operator "available POs" picker. Historic status 2/4 -> 3 (finished): a 2023 "running"
#     PO would collide with the partial unique index (one running PO per equipment).
#   * id_user_operator/id_label/id_equipment_executed -> NULL (no such rows in analytics).
#
# The `events` grain stages equipment_events (auto) + equipment_events_man (operator):
#   * auto id_equipment_event = EVENT_ID_OFFSET (9e15) + legacy id — current ids span
#     1..1.79e15 (bigint); the downtime split/justify paths key on this id, so a collision
#     would let an edit to a 2023 downtime touch a live row.
#   * manual id is an IDENTITY (int4) → omitted, the identity assigns fresh ids; legacy
#     duplicate (equipment, ts_event) entries deduped keeping the latest last_update.
#   * floor = now()-5 years (silver.equipment_events keep; older chunks would be dropped).
#   * after merge: CALL serving.refresh_downtime_events_resolved(from,to) per month
#     (db/backfill/refresh-downtime-resolved-history.sql) — v3 downtimes read that table.
set -euo pipefail
export HOME="${HOME:-/root}"
log(){ echo "[legacy-history-backfill] $*"; }
DUCKDB=""; for c in /opt/packiot/duckdb/duckdb "$HOME/.duckdb/cli/latest/duckdb" /root/.duckdb/cli/latest/duckdb "$(command -v duckdb||true)"; do [ -x "$c" ] && DUCKDB="$c" && break; done
[ -z "$DUCKDB" ] && { log "duckdb not found"; exit 3; }
ENVFILE="${SRC_PG_ENVFILE:-/opt/packiot/.env}"
envget(){ grep -m1 "^$1=" "$ENVFILE" 2>/dev/null | cut -d= -f2- || true; }
LPW="${LEGACY_DB_PASSWORD:-$(envget LEGACY_DB_PASSWORD)}"
APW="${ANALYTICS_DB_PASSWORD:-$(envget POSTGRES_PASSWORD)}"
LEG_HOST="${LEGACY_DB_HOST:-18.220.223.110}"; LEG_USER="${LEGACY_DB_USER:-awslambda}"; LEG_DB="${LEGACY_DB_NAME:-packiot40}"
AN_HOST="${DB_HOST:-10.10.10.89}"
LEG_ENT="${LEG_ENT:-1}"; F3_ENT="${F3_ENT:-3}"
GRAINS="${GRAINS:-shift hourly daily weekly monthly shift_weekly shift_monthly area_shift area_daily site_shift po events}"
LEGACY_ID_OFFSET="${LEGACY_ID_OFFSET:-100000000}"
EVENT_ID_OFFSET="${EVENT_ID_OFFSET:-9000000000000000}"
EVENTS_FLOOR="$(date -u -d '5 years ago' +%Y-%m-%d)"
HOURLY_FLOOR="$(date -u -d '13 months ago' +%Y-%m-%d)"

# grain -> legacy table | gold target | key kind (eq/area/site) | features
spec(){ case "$1" in
  shift)         echo "equipment_runtime_shift|gold.equipment_oee_shift|eq|gross,shift,cd,range" ;;
  hourly)        echo "equipment_runtime_1hour|gold.equipment_oee_hourly|eq|gross,team" ;;
  daily)         echo "equipment_runtime_1day|gold.equipment_oee_daily|eq|gross" ;;
  weekly)        echo "equipment_runtime_1week|gold.equipment_oee_weekly|eq|gross" ;;
  monthly)       echo "equipment_runtime_1month|gold.equipment_oee_monthly|eq|gross" ;;
  shift_weekly)  echo "equipment_runtime_shift_1week|gold.equipment_oee_shift_weekly|eq|shift" ;;
  shift_monthly) echo "equipment_runtime_shift_1month|gold.equipment_oee_shift_monthly|eq|shift" ;;
  area_shift)    echo "area_runtime_shift|gold.area_oee_shift|area|gross,shift,range" ;;
  area_daily)    echo "area_runtime_1day|gold.area_oee_daily|area|gross" ;;
  site_shift)    echo "site_runtime_shift|gold.site_oee_shift|site|gross,shift,range" ;;
  po)            echo "production_orders|core.production_orders|po|" ;;
  events)        echo "equipment_events|silver.equipment_events|events|" ;;
  *) log "unknown grain $1"; exit 2 ;; esac; }

SQL="$(mktemp)"; trap 'rm -f "$SQL"' EXIT
cat > "$SQL" <<EOF
INSTALL postgres; LOAD postgres;
ATTACH 'host=${LEG_HOST} port=5432 dbname=${LEG_DB} user=${LEG_USER} password=${LPW}' AS leg (TYPE postgres, READ_ONLY);
ATTACH 'host=${AN_HOST} port=5432 dbname=packiot_analytics user=postgres password=${APW}' AS an (TYPE postgres);
-- ── id maps ──────────────────────────────────────────────────────────────────
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
-- legacy shift id -> cd_shift (current shifts table ∪ every (id,cd) pair legacy ever wrote)
CREATE TEMP TABLE leg_cd AS
  SELECT id_shift AS leg_shift, max(cd_shift) AS cd FROM (
    SELECT * FROM postgres_query('leg','SELECT id_shift, cd_shift::text AS cd_shift FROM shifts WHERE id_enterprise=${LEG_ENT}')
    UNION ALL
    SELECT * FROM postgres_query('leg','SELECT DISTINCT s.id_shift, s.cd_shift::text FROM equipment_runtime_shift s JOIN equipments e USING (id_equipment) WHERE e.id_enterprise=${LEG_ENT} AND s.cd_shift IS NOT NULL')
  ) GROUP BY 1;
CREATE TEMP TABLE cur_shift AS
  SELECT * FROM postgres_query('an','SELECT cd_shift::text AS cd, id_area, id_shift FROM core.shifts WHERE id_enterprise=${F3_ENT}');
SELECT (SELECT count(*) FROM map_eq) eq_mapped, (SELECT count(*) FROM map_area) areas_mapped,
       (SELECT count(*) FROM map_site) sites_mapped, (SELECT count(*) FROM leg_cd) leg_shift_ids, (SELECT count(*) FROM cur_shift) cur_shifts;
EOF

for g in $GRAINS; do
  IFS='|' read -r LT TGT KIND FEAT <<<"$(spec "$g")"
  if [ "$KIND" = events ]; then
    cat >> "$SQL" <<EOF
-- ── events: equipment_events (auto) + equipment_events_man (operator) ──
SET VARIABLE bnd = (SELECT b FROM postgres_query('an', \$\$SELECT min(ts_event)::text AS b FROM silver.equipment_events WHERE id_enterprise=${F3_ENT}\$\$));
DROP TABLE IF EXISTS an.ops.bf_equipment_events;
CREATE TABLE an.ops.bf_equipment_events AS
  SELECT t.* EXCLUDE (id_equipment, id_equipment_event, id_enterprise),
         me.new_id AS id_equipment, t.id_equipment_event + ${EVENT_ID_OFFSET} AS id_equipment_event, ${F3_ENT} AS id_enterprise
  FROM postgres_query('leg', \$\$SELECT * FROM equipment_events WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise=${LEG_ENT}) AND ts_event >= '${EVENTS_FLOOR}'\$\$) t
  JOIN map_eq me ON me.leg_id = t.id_equipment
  WHERE getvariable('bnd') IS NULL OR t.ts_event::timestamptz < getvariable('bnd')::timestamptz;
SET VARIABLE bndm = (SELECT b FROM postgres_query('an', \$\$SELECT min(m.ts_event)::text AS b FROM silver.equipment_events_man m JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise=${F3_ENT}\$\$));
DROP TABLE IF EXISTS an.ops.bf_equipment_events_man;
CREATE TABLE an.ops.bf_equipment_events_man AS
  SELECT t.* EXCLUDE (id_equipment, id_equipment_event, id_enterprise), me.new_id AS id_equipment, ${F3_ENT} AS id_enterprise
  FROM postgres_query('leg', \$\$SELECT * FROM equipment_events_man WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise=${LEG_ENT}) AND ts_event >= '${EVENTS_FLOOR}'\$\$) t
  JOIN map_eq me ON me.leg_id = t.id_equipment
  WHERE getvariable('bndm') IS NULL OR t.ts_event::timestamptz < getvariable('bndm')::timestamptz
  -- legacy enforced uniqueness only on the id, so operators could enter the same downtime
  -- twice (194 dup (equipment, ts_event) pairs on CPACK); the target is UNIQUE on that pair.
  -- Keep the most recently updated entry (tie → highest legacy id) — deterministic.
  QUALIFY row_number() OVER (PARTITION BY me.new_id, t.ts_event ORDER BY t.last_update DESC NULLS LAST, t.id_equipment_event DESC) = 1;
SELECT 'events' AS grain, (SELECT count(*) FROM an.ops.bf_equipment_events) auto_events, (SELECT count(*) FROM an.ops.bf_equipment_events_man) manual_events,
       (SELECT min(ts_event)::varchar FROM an.ops.bf_equipment_events) min_ts, getvariable('bnd') AS boundary_auto, getvariable('bndm') AS boundary_man;
EOF
    continue
  fi
  if [ "$KIND" = po ]; then
    cat >> "$SQL" <<EOF
-- ── po: clients + production_orders + production_orders_runtime ──
SET VARIABLE bnd = (SELECT b FROM postgres_query('an', \$\$SELECT min(ts_start)::text AS b FROM core.production_orders WHERE id_enterprise=${F3_ENT}\$\$));
DROP TABLE IF EXISTS an.ops.bf_clients;
CREATE TABLE an.ops.bf_clients AS
  SELECT id_client, nm_client, ${F3_ENT} AS id_enterprise
  FROM postgres_query('leg', \$\$SELECT id_client, nm_client FROM clients WHERE id_enterprise=${LEG_ENT}\$\$);
CREATE TEMP TABLE an_products AS SELECT * FROM postgres_query('an', 'SELECT id_product FROM core.products');
DROP TABLE IF EXISTS an.ops.bf_production_orders;
CREATE TABLE an.ops.bf_production_orders AS
  SELECT t.id_production_order + ${LEGACY_ID_OFFSET} AS id_production_order, ${F3_ENT} AS id_enterprise,
         ms.new_id AS id_site, ma.new_id AS id_area, me.new_id AS id_equipment,
         CASE WHEN ap.id_product IS NOT NULL THEN t.id_product END AS id_product, t.id_client,
         CASE WHEN t.status IN (2,4) THEN 3 ELSE t.status END AS status,
         t.production_programmed, t.production_ordered, t.id_order, NULL::int AS id_user_operator,
         NULL::int AS id_equipment_executed, t.production_real, t.production_final, t.ts_start, t.ts_end,
         t.equipment_setup, true AS oee_processed,
         GREATEST(LEAST(COALESCE(t.oee,0),1),0) AS oee,
         t.stopped_time, t.planned_downtime, t.qt_stops, true AS erp_processed, t.ts_creation,
         t.txt_production_order_notes, t.txt_production_order_description, t.conversion_factor,
         LEAST(t.net_production, t.gross_production) AS net_production, t.speed, t.ideal_production_speed,
         t.id_order_text, false AS recalc_needed, t.last_update, t.multiplier, t.gross_production,
         t.available_time, t.running_time, t.custom_field, t.ideal_production, t.ts_start_tz, t.ts_end_tz,
         NULL::int AS id_label,
         CASE WHEN t.gross_production>0 THEN GREATEST(LEAST(LEAST(t.net_production,t.gross_production)/t.gross_production,1),0)
              ELSE GREATEST(LEAST(COALESCE(t.oee_quality,0),1),0) END AS oee_q,
         GREATEST(LEAST(COALESCE(t.oee_availability,0),1),0) AS oee_a,
         GREATEST(LEAST(COALESCE(t.oee_performance,0),1),0) AS oee_p
  FROM postgres_query('leg', \$\$SELECT * FROM production_orders WHERE id_enterprise=${LEG_ENT} AND ts_start IS NOT NULL\$\$) t
  JOIN map_eq me ON me.leg_id = t.id_equipment
  JOIN map_area ma ON ma.leg_id = t.id_area
  JOIN map_site ms ON ms.leg_id = t.id_site
  LEFT JOIN an_products ap ON ap.id_product = t.id_product
  WHERE getvariable('bnd') IS NULL OR t.ts_start::timestamptz < getvariable('bnd')::timestamptz;
DROP TABLE IF EXISTS an.ops.bf_production_orders_runtime;
CREATE TABLE an.ops.bf_production_orders_runtime AS
  SELECT r.id_production_order + ${LEGACY_ID_OFFSET} AS id_production_order, r.runtime_timerange::varchar AS runtime_timerange,
         GREATEST(LEAST(COALESCE(r.oee,0),1),0) AS oee, false AS recalc_needed,
         GREATEST(LEAST(COALESCE(r.oee_p,0),1),0) AS oee_p, GREATEST(LEAST(COALESCE(r.oee_a,0),1),0) AS oee_a,
         CASE WHEN r.gross_production>0 THEN GREATEST(LEAST(LEAST(r.net_production,r.gross_production)/r.gross_production,1),0)
              ELSE GREATEST(LEAST(COALESCE(r.oee_q,0),1),0) END AS oee_q,
         r.available_time, r.running_time, r.stopped_time, r.planned_downtime, r.ideal_production,
         r.idle_time, r.idle_starved, r.idle_blocked,
         r.id_production_orders_runtime + ${LEGACY_ID_OFFSET} AS id_production_orders_runtime,
         me.new_id AS id_equipment, r.id_production_order_runtime + ${LEGACY_ID_OFFSET} AS id_production_order_runtime,
         LEAST(r.net_production, r.gross_production) AS net_production, r.gross_production, r.downtime,
         r.changeover_time, r.speed, r.last_update, r.multiplier
  FROM postgres_query('leg', \$\$SELECT r.* FROM production_orders_runtime r JOIN production_orders p USING (id_production_order) WHERE p.id_enterprise=${LEG_ENT}\$\$) r
  JOIN map_eq me ON me.leg_id = r.id_equipment
  WHERE (r.id_production_order + ${LEGACY_ID_OFFSET}) IN (SELECT id_production_order FROM an.ops.bf_production_orders);
SELECT 'po' AS grain, (SELECT count(*) FROM an.ops.bf_clients) clients, (SELECT count(*) FROM an.ops.bf_production_orders) pos,
       (SELECT count(*) FROM an.ops.bf_production_orders_runtime) runtimes,
       (SELECT min(ts_start)::varchar FROM an.ops.bf_production_orders) min_ts, getvariable('bnd') AS boundary;
EOF
    continue
  fi

  TSCHEMA="${TGT%%.*}"; TNAME="${TGT##*.}"
  case "$KIND" in
    eq)   KEYCOL=id_equipment; MAP=map_eq;   ENTF="id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise=${LEG_ENT})"
          BND="SELECT min(o.ts_value)::text AS b FROM ${TGT} o JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise=${F3_ENT}" ;;
    area) KEYCOL=id_area; MAP=map_area; ENTF="id_area IN (SELECT a.id_area FROM areas a JOIN sites s USING (id_site) WHERE s.id_enterprise=${LEG_ENT})"
          BND="SELECT min(o.ts_value)::text AS b FROM ${TGT} o JOIN core.areas a USING (id_area) JOIN core.sites s USING (id_site) WHERE s.id_enterprise=${F3_ENT}" ;;
    site) KEYCOL=id_site; MAP=map_site; ENTF="id_site IN (SELECT id_site FROM sites WHERE id_enterprise=${LEG_ENT})"
          BND="SELECT min(o.ts_value)::text AS b FROM ${TGT} o JOIN core.sites s USING (id_site) WHERE s.id_enterprise=${F3_ENT}" ;;
  esac
  FLOOR=""; [ "$g" = hourly ] && FLOOR=" AND ts_value >= '${HOURLY_FLOOR}'"
  R="m.new_id AS ${KEYCOL}, GREATEST(LEAST(COALESCE(t.oee,0),1),0) AS oee, false AS recalc_needed,
     GREATEST(LEAST(COALESCE(t.oee_p,0),1),0) AS oee_p, GREATEST(LEAST(COALESCE(t.oee_a,0),1),0) AS oee_a"
  if [[ ",$FEAT," == *",gross,"* ]]; then
    R="$R, CASE WHEN t.gross>0 THEN GREATEST(LEAST(LEAST(t.net,t.gross)/t.gross,1),0) ELSE GREATEST(LEAST(COALESCE(t.oee_q,0),1),0) END AS oee_q,
       LEAST(t.net, t.gross) AS net"
  else
    R="$R, GREATEST(LEAST(COALESCE(t.oee_q,0),1),0) AS oee_q"
  fi
  if [[ ",$FEAT," == *",shift,"* ]]; then
    CDX="lc.cd"; [[ ",$FEAT," == *",cd,"* ]] && CDX="COALESCE(t.cd_shift::varchar, lc.cd)"
    R="$R, cs.id_shift AS id_shift, NULL::int AS id_shift_hour, NULL::int AS id_team"
    JOINS="LEFT JOIN leg_cd lc ON lc.leg_shift = t.id_shift LEFT JOIN cur_shift cs ON cs.cd = ${CDX} AND cs.id_area = m.new_area"
  else
    JOINS=""
  fi
  [[ ",$FEAT," == *",team,"* ]] && R="$R, NULL::int AS id_team"
  [[ ",$FEAT," == *",range,"* ]] && R="$R, t.ts_range::varchar AS ts_range"
  EXCL="${KEYCOL}, oee, recalc_needed, oee_p, oee_a, oee_q"
  [[ ",$FEAT," == *",gross,"* ]] && EXCL="$EXCL, net"
  [[ ",$FEAT," == *",shift,"* ]] && EXCL="$EXCL, id_shift, id_shift_hour, id_team"
  [[ ",$FEAT," == *",team,"* ]] && EXCL="$EXCL, id_team"
  [[ ",$FEAT," == *",range,"* ]] && EXCL="$EXCL, ts_range"
  [ "$g" = shift ] && EXCL="$EXCL, id_runtime_shift"
  cat >> "$SQL" <<EOF
-- ── ${g}: leg.${LT} -> ${TGT} ──
SET VARIABLE bnd = (SELECT b FROM postgres_query('an', \$\$${BND}\$\$));
DROP TABLE IF EXISTS an.ops.bf_${TNAME};
CREATE TABLE an.ops.bf_${TNAME} AS
  SELECT t.* EXCLUDE (${EXCL}), ${R}, now()::timestamptz AS computed_at, NULL::timestamptz AS source_watermark
  FROM postgres_query('leg', \$\$SELECT * FROM ${LT} WHERE ${ENTF}${FLOOR}\$\$) t
  JOIN ${MAP} m ON m.leg_id = t.${KEYCOL}
  ${JOINS}
  WHERE getvariable('bnd') IS NULL OR t.ts_value::timestamptz < getvariable('bnd')::timestamptz;
SELECT '${g}' AS grain, count(*) AS staged, min(ts_value)::varchar AS min_ts, max(ts_value)::varchar AS max_ts, getvariable('bnd') AS boundary FROM an.ops.bf_${TNAME};
EOF
done

log "staging grains=[${GRAINS}] legacy ent=${LEG_ENT} -> analytics ent=${F3_ENT} (hourly floor ${HOURLY_FLOOR})"
"$DUCKDB" -c ".read $SQL"
log "staged. Next: psql -d packiot_analytics -v mode=dry -f db/backfill/merge-legacy-history.sql (then mode=apply)"
