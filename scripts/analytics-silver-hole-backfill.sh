#!/usr/bin/env bash
# analytics-silver-hole-backfill.sh — stage legacy raw equipment_values for a silver feed hole.
# 2026-09-29 layer audit: silver.equipment_values has NO rows for any tenant from
# 2026-08-27 17:58 to 2026-09-01 00:29 UTC (CPACK legacy: 707,182 rows in that window).
# Stages CPACK rows into ops.bf2_silver_values with ids remapped (equipment via packml topic,
# area/site by name); db/backfill/merge-silver-hole.sql inserts them (ON CONFLICT DO NOTHING)
# and refreshes the continuous aggregates. Gold for those days is the legacy replay, untouched.
set -euo pipefail
export HOME="${HOME:-/root}"
DUCKDB=""; for c in /opt/packiot/duckdb/duckdb "$HOME/.duckdb/cli/latest/duckdb" /root/.duckdb/cli/latest/duckdb "$(command -v duckdb||true)"; do [ -x "$c" ] && DUCKDB="$c" && break; done
[ -z "$DUCKDB" ] && { echo "duckdb not found"; exit 3; }
: "${LEGACY_DB_PASSWORD:?LEGACY_DB_PASSWORD required (Secrets Manager databaseCredentials)}"
APW="${ANALYTICS_DB_PASSWORD:-$(grep -m1 '^POSTGRES_PASSWORD=' /opt/packiot/.env | cut -d= -f2-)}"
FROM_TS="${FROM_TS:-2026-08-27 17:58:00+00}"; TO_TS="${TO_TS:-2026-09-01 00:30:00+00}"
LEG_ENT="${LEG_ENT:-1}"; F3_ENT="${F3_ENT:-3}"
# Optional scoping (PTH recovery, 2026-09-29): ONLY_TOPICS = SQL list of analytics packml topics,
# e.g. "'CPACK/SC/LINHAS/L8/PTH','CPACK/SC/LINHAS/L10/PTH'"; STAGE_TABLE = ops.<name> to stage into.
ONLY_TOPICS="${ONLY_TOPICS:-}"; STAGE_TABLE="${STAGE_TABLE:-bf2_silver_values}"
TOPIC_FILTER=""; [ -n "$ONLY_TOPICS" ] && TOPIC_FILTER="WHERE m.new_id IN (SELECT id_equipment FROM postgres_query('an', \$\$SELECT id_equipment FROM core.packml_register WHERE id_enterprise=${F3_ENT} AND packml_topic IN (${ONLY_TOPICS})\$\$))"
"$DUCKDB" <<EOF
INSTALL postgres; LOAD postgres;
ATTACH 'host=${LEGACY_DB_HOST:-18.220.223.110} port=5432 dbname=packiot40 user=${LEGACY_DB_USER:-awslambda} password=${LEGACY_DB_PASSWORD}' AS leg (TYPE postgres, READ_ONLY);
ATTACH 'host=${DB_HOST:-10.10.10.89} port=5432 dbname=packiot_analytics user=postgres password=${APW}' AS an (TYPE postgres);
CREATE TEMP TABLE map_eq AS
  SELECT DISTINCT l.id_equipment AS leg_id, f.id_equipment AS new_id, f.id_area AS new_area, f.id_site AS new_site
  FROM postgres_query('leg','SELECT DISTINCT id_equipment, packml_topic FROM packml_register WHERE id_enterprise=${LEG_ENT} AND active=true AND id_equipment IS NOT NULL') l
  JOIN postgres_query('an','SELECT DISTINCT p.id_equipment, p.packml_topic, e.id_area, e.id_site FROM core.packml_register p JOIN core.equipments e USING (id_equipment) WHERE p.id_enterprise=${F3_ENT} AND p.active=true') f
    ON replace(l.packml_topic,'C-PACK','CPACK') = f.packml_topic;
DROP TABLE IF EXISTS an.ops.${STAGE_TABLE};
CREATE TABLE an.ops.${STAGE_TABLE} AS
  SELECT t.* EXCLUDE (id_equipment, id_enterprise, id_site, id_area, id_equipment_line_infeed, id_equipment_line_outfeed,
                      id_equipment_line_connected, id_production_order, id_shift, id_team, id_shift_hour),
         m.new_id AS id_equipment, ${F3_ENT} AS id_enterprise, m.new_site AS id_site, m.new_area AS id_area,
         mi.new_id AS id_equipment_line_infeed, mo.new_id AS id_equipment_line_outfeed, mc.new_id AS id_equipment_line_connected,
         NULL::int AS id_production_order, NULL::int AS id_shift, NULL::int AS id_team, NULL::int AS id_shift_hour
  FROM postgres_query('leg', \$\$SELECT * FROM equipment_values WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise=${LEG_ENT}) AND ts_value >= '${FROM_TS}' AND ts_value < '${TO_TS}'\$\$) t
  JOIN map_eq m ON m.leg_id = t.id_equipment
  LEFT JOIN map_eq mi ON mi.leg_id = t.id_equipment_line_infeed
  LEFT JOIN map_eq mo ON mo.leg_id = t.id_equipment_line_outfeed
  LEFT JOIN map_eq mc ON mc.leg_id = t.id_equipment_line_connected
  ${TOPIC_FILTER};
SELECT count(*) staged, count(DISTINCT id_equipment) equipments, min(ts_value)::varchar, max(ts_value)::varchar,
       round(sum(gross_production_incr)) gross, round(sum(net_production_incr)) net FROM an.ops.${STAGE_TABLE};
EOF
