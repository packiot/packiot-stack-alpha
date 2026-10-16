#!/usr/bin/env bash
# Local test for scripts/historian-cold-export.sh (ADR-0065 P1): a throwaway postgres:16 + the local DuckDB CLI,
# exporting to a temp directory instead of S3.  Usage: bash scripts/test/historian-cold-export.test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
DUCKDB="${DUCKDB:-$(command -v duckdb || echo "$HOME/.duckdb/cli/latest/duckdb")}"
[ -x "$DUCKDB" ] || { echo "duckdb CLI not found"; exit 2; }
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
C=coldexport-test-$$; T=$(mktemp -d)
cleanup() { docker rm -f "$C" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
docker run -d --name "$C" -p "127.0.0.1:$PORT:5432" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=packiot_analytics postgres:16-alpine >/dev/null || exit 2
for i in $(seq 1 60); do docker exec "$C" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2
Q() { docker exec -i "$C" psql -U postgres -d packiot_analytics -X -At -v ON_ERROR_STOP=1 "$@"; }
Q -q <<'SQL'
CREATE SCHEMA ops; CREATE SCHEMA silver;
CREATE TABLE ops.cold_export (relation text NOT NULL, id_enterprise integer NOT NULL, period_lo timestamptz NOT NULL,
  period_hi timestamptz NOT NULL, uri text NOT NULL, rows bigint NOT NULL, sum_net double precision, sum_gross double precision,
  exported_at timestamptz NOT NULL DEFAULT now(), verified_at timestamptz, PRIMARY KEY (relation, id_enterprise, period_lo));
CREATE TABLE ops.cold_export_exempt (id_enterprise integer PRIMARY KEY, reason text NOT NULL);
INSERT INTO ops.cold_export_exempt VALUES (2000003, 'twin');
CREATE TABLE silver.equipment_values (id_equipment int, ts_value timestamptz, id_enterprise int, net_production_incr real,
  gross_production_incr real, state int) PARTITION BY RANGE (ts_value);
CREATE TABLE silver.equipment_values_all PARTITION OF silver.equipment_values FOR VALUES FROM (MINVALUE) TO (MAXVALUE);
CREATE TABLE silver.equipment_events (id_equipment int, ts_event timestamptz, ts_end timestamptz, duration int, id_enterprise int, cd_category text);
-- 6 days back to now, hourly values / 6-hourly events, tenants 3, 5 and the exempt twin
INSERT INTO silver.equipment_values SELECT 7, g, e, 10.5, 12.25, 6 FROM unnest(ARRAY[3, 5, 2000003]) e,
  generate_series(date_trunc('day', now()) - interval '6 days', now(), interval '1 hour') g;
INSERT INTO silver.equipment_events SELECT 7, g, g + interval '10 min', 600, e, 'X' FROM unnest(ARRAY[3, 5, 2000003]) e,
  generate_series(date_trunc('day', now()) - interval '6 days', now(), interval '6 hours') g;
SQL
run() {
  ENVFILE=/dev/null AN_HOST=127.0.0.1 AN_PORT=$PORT AN_USER=postgres ANALYTICS_DB_PASSWORD=x COLD_EXPORT_ROOT="$T/cold" \
  COLD_EXPORT_TMP="$T/work" PSQL_CMD="docker exec -i $C psql -U postgres -d packiot_analytics" DUCKDB="$DUCKDB" \
  timeout 300 bash scripts/historian-cold-export.sh 2>&1 | sed 's/^\[cold-export [^]]*\] //'
}
FAILED=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; FAILED=1; fi; }

OUT=$(run); echo "$OUT" | sed 's/^/   /'
CLOSED=$(Q -c "SELECT count(DISTINCT (id_enterprise, (ts_value AT TIME ZONE 'UTC')::date)) FROM silver.equipment_values WHERE ts_value < date_trunc('day', now() - interval '48 hours') AND id_enterprise <> 2000003")
ok "T1 every closed tenant-day of values exported + verified" "$(Q -c "SELECT count(verified_at) FROM ops.cold_export WHERE relation = 'silver.equipment_values'")" "$CLOSED"
ok "T1 events too" "$(Q -c "SELECT count(verified_at) = count(*) AND count(*) > 0 FROM ops.cold_export WHERE relation = 'silver.equipment_events'")" "t"
ok "T1 one file per manifest row" "$(find "$T/cold" -name f3.parquet | wc -l | tr -d ' ')" "$(Q -c "SELECT count(*) FROM ops.cold_export")"
ok "T4 the exempt twin is never exported" "$(find "$T/cold" -path '*enterprise=2000003*' | wc -l | tr -d ' ')" "0"
ok "T5 nothing inside the 48 h close window" "$(Q -c "SELECT bool_and(period_hi <= now() - interval '48 hours') FROM ops.cold_export")" "t"
F=$(find "$T/cold" -path '*equipment_values/enterprise=5*' -name f3.parquet | head -1)
ok "T1 a file holds exactly its day (24 hourly rows)" "$("$DUCKDB" -noheader -csv -c "SELECT count(*) FROM read_parquet('$F')")" "24"
ok "T2 second run has no work" "$(run | grep -c 'to export' )|$(run | grep -E 'equipment_values: 0 tenant-day' | wc -l | tr -d ' ')" "2|1"
Q -c "UPDATE silver.equipment_values SET net_production_incr = 99 WHERE id_enterprise = 5 AND ts_value = date_trunc('day', now()) - interval '5 days' + interval '3 hours'" >/dev/null
ok "T3 a late correction re-exports exactly that day" "$(run | grep -oE 'equipment_values: [0-9]+ tenant-day' | grep -oE '[0-9]+')" "1"
ok "T3 manifest carries the corrected sum (23*10.5 + 99)" "$(Q -c "SELECT sum_net FROM ops.cold_export WHERE relation = 'silver.equipment_values' AND id_enterprise = 5 AND period_lo = date_trunc('day', now()) - interval '5 days'")" "340.5"
# a manifest row that lies (verified, wrong rows) is noticed and replaced
Q -c "UPDATE ops.cold_export SET rows = rows + 1 WHERE relation = 'silver.equipment_events' AND id_enterprise = 3 AND period_lo = date_trunc('day', now()) - interval '4 days'" >/dev/null
ok "T6 a manifest/hot mismatch is re-exported" "$(run | grep -oE 'equipment_events: [0-9]+ tenant-day' | grep -oE '[0-9]+')" "1"
[ "$FAILED" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
