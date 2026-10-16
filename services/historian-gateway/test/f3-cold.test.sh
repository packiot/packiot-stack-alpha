#!/usr/bin/env bash
# Local test of 20-f3-cold.sql (ADR-0065 P2) on the real gateway image (pgduckdb/pgduckdb:16-main) + a postgres:16
# "analytics", on a private docker network. The minimal 10-historian-gateway.sh objects the union needs are created by
# hand (live_pg FDW, live.equipment_values, ev_union_boundary, promoted_enterprise, cold.equipment_values over legacy
# parquet). Usage: bash services/historian-gateway/test/f3-cold.test.sh
#
# Data (one row per hour, days relative to today D):
#   ent 3 (legacy-promoted): legacy copy D-40..D-2 (cutover = last legacy row), F3 export D-40..D-3, hot D-20..now
#   ent 5 (no legacy):       F3 export D-40..D-3 (verified), hot only D-20..now (older partitions "dropped")
#   ent 7 (no export yet):   hot D-20..now, no manifest rows
# Expected: every (tenant, day) comes from exactly ONE branch and the union equals the ground truth per tenant.
set -uo pipefail
cd "$(dirname "$0")/.."
DUCKDB="${DUCKDB:-$(command -v duckdb || echo "$HOME/.duckdb/cli/latest/duckdb")}"
N=f3test-$$; A=$N-an; G=$N-gw; T=$(mktemp -d); chmod 777 "$T"
cleanup() { docker rm -f "$A" "$G" >/dev/null 2>&1; docker network rm "$N" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
docker network create "$N" >/dev/null
docker run -d --name "$A" --network "$N" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=packiot_analytics postgres:16-alpine >/dev/null
docker run -d --name "$G" --network "$N" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=packiot_historian -v "$T:/data" pgduckdb/pgduckdb:16-main >/dev/null
for c in "$A" "$G"; do for i in $(seq 1 90); do docker exec "$c" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done; done
sleep 3
QA() { docker exec -i "$A" psql -U postgres -d packiot_analytics -X -At -v ON_ERROR_STOP=1 "$@"; }
QG() { docker exec -i "$G" psql -U postgres -d packiot_historian -X -At -v ON_ERROR_STOP=1 "$@"; }

QA -q <<'SQL'
CREATE SCHEMA ops; CREATE SCHEMA silver;
CREATE ROLE histgw_ro LOGIN PASSWORD 'ro';
CREATE TABLE silver.equipment_values (ts_value timestamptz, id_enterprise int, id_site int, id_area int, id_equipment int,
  gross_production_incr real, net_production_incr real, speed real);
CREATE TABLE ops.cold_export (relation text, id_enterprise int, period_lo timestamptz, period_hi timestamptz, uri text,
  rows bigint, sum_net float8, sum_gross float8, exported_at timestamptz DEFAULT now(), verified_at timestamptz);
GRANT USAGE ON SCHEMA silver, ops TO histgw_ro; GRANT SELECT ON silver.equipment_values TO histgw_ro;
-- the migration under test (the analytics half of P2)
GRANT SELECT ON ops.cold_export TO histgw_ro;
-- hot: D-20 .. now for every tenant
INSERT INTO silver.equipment_values SELECT g, e, 1, 1, e * 10, 2, 1, 5
  FROM unnest(ARRAY[3, 5, 7]) e, generate_series(date_trunc('day', now()) - interval '20 days', now() - interval '1 hour', interval '1 hour') g;
-- manifest: ent 3 + 5 verified D-40 .. D-3 (one row per day)
INSERT INTO ops.cold_export (relation, id_enterprise, period_lo, period_hi, uri, rows, verified_at)
SELECT 'silver.equipment_values', e, d, d + interval '1 day', 'file', 24, now()
  FROM unnest(ARRAY[3, 5]) e, generate_series(date_trunc('day', now()) - interval '40 days', date_trunc('day', now()) - interval '3 days', interval '1 day') d;
SQL
# parquet: F3 export (ent 3 + 5, D-40..D-3) and the legacy copy (ent 3, D-40..D-2); DuckDB does not create parents
mkdir -p "$T/silver"   # DuckDB does not create missing parents of a partitioned COPY target
"$DUCKDB" <<SQL >/dev/null
SET TimeZone = 'UTC';
CREATE TABLE f3 AS SELECT g AS ts_value, e AS id_enterprise, 1 AS id_site, 1 AS id_area, e * 10 AS id_equipment,
  2::REAL AS gross_production_incr, 1::REAL AS net_production_incr, 5::REAL AS speed,
  e AS enterprise, year(g) AS year, month(g) AS month, day(g) AS day
  FROM (SELECT unnest([3, 5]) AS e), generate_series(date_trunc('day', now()) - INTERVAL 40 DAY, date_trunc('day', now()) - INTERVAL 2 DAY - INTERVAL 1 HOUR, INTERVAL 1 HOUR) t(g);
COPY f3 TO '$T/silver/equipment_values' (FORMAT parquet, PARTITION_BY (enterprise, year, month, day), FILENAME_PATTERN 'f3', OVERWRITE_OR_IGNORE);
CREATE TABLE leg AS SELECT g::TIMESTAMP AS ts_value, 3 AS enterprise, year(g) AS year, month(g) AS month, 30 AS id_equipment,
  2.0 AS gross_production_incr, 0.0 AS gross_production_val, 1.0 AS net_production_incr, 0.0 AS net_production_val, 5.0 AS speed
  FROM generate_series((date_trunc('day', now()) - INTERVAL 40 DAY)::TIMESTAMP, (date_trunc('day', now()) - INTERVAL 1 DAY - INTERVAL 1 HOUR)::TIMESTAMP, INTERVAL 1 HOUR) t(g);
COPY leg TO '$T/equipment_values' (FORMAT parquet, PARTITION_BY (enterprise, year, month), FILENAME_PATTERN 'data-legacy', OVERWRITE_OR_IGNORE);
SQL
# DuckDB names partition files <pattern><index>.parquet → rename to what the exporter/legacy copy write
find "$T/silver" -name 'f30.parquet' -execdir mv {} f3.parquet \;
find "$T/equipment_values" -name 'data-legacy0.parquet' -execdir mv {} data-x-legacy.parquet \;
chmod -R a+rX "$T"

# the minimal 10-historian-gateway.sh state the union depends on
QG -q <<SQL
CREATE EXTENSION IF NOT EXISTS pg_duckdb; CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SERVER live_pg FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host '$A', port '5432', dbname 'packiot_analytics');
CREATE USER MAPPING FOR postgres SERVER live_pg OPTIONS (user 'histgw_ro', password 'ro');
CREATE SCHEMA live; CREATE SCHEMA cold; CREATE SCHEMA silver; CREATE SCHEMA gold;
ALTER DATABASE packiot_historian SET search_path = cold, public;
SET search_path = cold, public;
CREATE FOREIGN TABLE live.equipment_values (ts_value timestamptz, id_enterprise integer, id_site integer, id_area integer,
  id_equipment integer, gross_production_incr real, net_production_incr real, speed real)
  SERVER live_pg OPTIONS (schema_name 'silver', table_name 'equipment_values');
CREATE TABLE promoted_enterprise (id_enterprise int PRIMARY KEY, ev_promoted boolean NOT NULL DEFAULT false);
INSERT INTO promoted_enterprise VALUES (3, true);
CREATE TABLE ev_union_boundary (id_enterprise int PRIMARY KEY, cutover_ts timestamp NOT NULL, refreshed_at timestamptz NOT NULL DEFAULT now());
INSERT INTO ev_union_boundary VALUES (3, (date_trunc('day', now()) - interval '1 day' - interval '1 hour')::timestamp);
CREATE OR REPLACE VIEW equipment_values AS
SELECT r['ts_value']::timestamp AS ts_value, r['enterprise']::int AS id_enterprise, r['year']::int AS year, r['month']::int AS month,
       r['id_equipment']::int AS id_equipment, r['gross_production_incr']::double precision AS gross_production_incr,
       r['net_production_incr']::double precision AS net_production_incr, r['speed']::double precision AS speed
  FROM read_parquet('/data/equipment_values/*/*/*/*-legacy.parquet', hive_partitioning => true) r;
SQL
OUT=$(docker exec -i -e HISTORIAN_F3_ROOT=/data "$G" psql -U postgres -d packiot_historian -X -At -v ON_ERROR_STOP=1 < docker-entrypoint-initdb.d/20-f3-cold.sql 2>&1); RC=$?
echo "$OUT" | grep -E 'f3_union_boundary|ERROR' | sed 's/^/   /'
FAILED=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; FAILED=1; fi; }
ok "P0 20-f3-cold.sql applies" "$RC" "0"
ok "P1 boundaries only for exported tenants (3, 5)" "$(QG -c "SELECT string_agg(id_enterprise::text, ',' ORDER BY 1) FROM f3_union_boundary")" "3,5"
ok "P1 boundary = end of the verified archive (D-2)" "$(QG -c "SELECT bool_and(cutover_ts = date_trunc('day', now()) - interval '2 days') FROM f3_union_boundary")" "t"
# ground truth per tenant: ent 3 = legacy (D-40..D-1h-of-D-1) + hot after its cutover; ent 5 = F3 D-40..D-3 + hot D-2..now; ent 7 = hot
for e in 3 5 7; do
  case $e in
    3) WANT=$(( 39*24 + $(QA -c "SELECT count(*) FROM silver.equipment_values WHERE id_enterprise = 3 AND ts_value > date_trunc('day', now()) - interval '1 day' - interval '1 hour'") )) ;;
    5) WANT=$(( 38*24 + $(QA -c "SELECT count(*) FROM silver.equipment_values WHERE id_enterprise = 5 AND ts_value >= date_trunc('day', now()) - interval '2 days'") )) ;;
    7) WANT=$(QA -c "SELECT count(*) FROM silver.equipment_values WHERE id_enterprise = 7") ;;
  esac
  ok "U$e union rows = ground truth (no gap, no double count)" "$(QG -c "SELECT count(*) FROM silver.equipment_values WHERE id_enterprise = $e")" "$WANT"
  ok "U$e every hour once" "$(QG -c "SELECT count(*) = count(DISTINCT ts_value) FROM silver.equipment_values WHERE id_enterprise = $e")" "t"
done
ok "U5 the archived days come from the F3 parquet (D-40..D-3 complete)" "$(QG -c "SELECT count(*) FROM silver.equipment_values WHERE id_enterprise = 5 AND ts_value < date_trunc('day', now()) - interval '20 days'")" "$((20*24))"
ok "U3 legacy priority unchanged (no F3 rows for ent 3)" "$(QG -c "SELECT count(*) FROM silver.equipment_values WHERE id_enterprise = 3 AND year IS NOT NULL AND ts_value < date_trunc('day', now()) - interval '2 days' AND id_equipment = 30")" "$((38*24))"
# an unverified day pulls the boundary back to that day (hot keeps serving it — still no gap where hot has data)
QA -c "UPDATE ops.cold_export SET verified_at = NULL WHERE id_enterprise = 5 AND period_lo = date_trunc('day', now()) - interval '5 days'" >/dev/null
docker exec -i "$G" psql -U postgres -d packiot_historian -X -At -v ON_ERROR_STOP=1 < refresh-f3-cutover.sql >/dev/null
ok "R1 refresh: boundary = first unverified day" "$(QG -c "SELECT cutover_ts = date_trunc('day', now()) - interval '5 days' FROM f3_union_boundary WHERE id_enterprise = 5")" "t"
ok "R1 union still exact while hot holds those days" "$(QG -c "SELECT count(*) FROM silver.equipment_values WHERE id_enterprise = 5 AND ts_value >= date_trunc('day', now()) - interval '20 days'")" "$(QA -c "SELECT count(*) FROM silver.equipment_values WHERE id_enterprise = 5")"
[ "$FAILED" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
