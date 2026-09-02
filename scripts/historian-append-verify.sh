#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# historian-append-verify.sh — local dry-run proof for historian-append.sh
# ══════════════════════════════════════════════════════════════════════════════
#
# Proves the ONGOING incremental-append job end-to-end WITHOUT touching prod or S3:
#   1. stands up a throwaway TimescaleDB (same image as prod) with the F3
#      `equipment_values` schema as a HYPERTABLE (so postgres_query is exercised
#      the Timescale-safe way, exactly like prod);
#   2. inserts one synthetic day for enterprise=3 — including a first-boot SPIKE
#      row and the divergent-type columns (id_order_quality varchar,
#      ts_value_production_quality date) that force the explicit projection;
#   3. runs the REAL scripts/historian-append.sh against it, writing Parquet to a
#      local dir (HISTORIAN_LOCAL_DIR) in the SAME enterprise/year/month/day layout;
#   4. reconciles: DuckDB reads the hive-partitioned Parquet (the Athena stand-in —
#      partition projection is just hive-partition discovery) and the row count for
#      the day must equal the source count;
#   5. re-runs to prove IDEMPOTENCY (overwrite, not duplicate);
#   6. flips HISTORIAN_SPIKE_GUARD=true and proves the spike increment is zeroed.
#
# Requires: docker, the DuckDB CLI. Cleans up the container on exit.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DUCKDB="${DUCKDB:-$(command -v duckdb || echo "$HOME/.duckdb/cli/latest/duckdb")}"
PORT="${VERIFY_PG_PORT:-55432}"
CNAME="historian-verify-$$"
WORK="$(mktemp -d)"
DAY="2026-08-10"; NEXT="2026-08-11"
ENT=3

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "== [1/6] start throwaway TimescaleDB (:$PORT) =="
docker run -d --name "$CNAME" -e POSTGRES_PASSWORD=verify -p "${PORT}:5432" \
  timescale/timescaledb:2.25.2-pg16 >/dev/null
# The timescaledb image double-boots (temp init server, then a restart). Require
# 3 CONSECUTIVE successful queries so we don't connect during the restart window.
ok=0
for i in $(seq 1 60); do
  if docker exec "$CNAME" psql -U postgres -tAc "SELECT 1" >/dev/null 2>&1; then
    ok=$((ok+1)); [ "$ok" -ge 3 ] && break
  else
    ok=0
  fi
  sleep 1
done
[ "$ok" -ge 3 ] || { echo "FAIL: DB did not become ready"; exit 1; }

echo "== [2/6] load F3 equipment_values schema + synthetic day =="
docker exec -i "$CNAME" psql -U postgres -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
-- Exact F3 shape (incl. trailing ingested_at/source_seq the projection drops,
-- and the divergent id_order_quality varchar / ts_value_production_quality date).
CREATE TABLE public.equipment_values (
  id_equipment integer NOT NULL, ts_value timestamptz NOT NULL,
  id_enterprise integer, id_site integer, id_area integer,
  net_production_incr real, gross_production_incr real, scrap_incr real, speed real,
  id_order varchar(255), conversion_factor real, number_cavities integer,
  faults jsonb, analogs jsonb, signal_quality integer,
  net_production_val real, gross_production_val real, scrap_val real,
  id_shift integer, id_team integer, id_shift_hour integer,
  box_code varchar(255), transaction_code varchar(255), state integer, mode integer,
  id_production_order integer, ts_value_production date,
  id_equipment_line_infeed integer, id_equipment_line_outfeed integer,
  net_production_incr_quality integer, gross_production_incr_quality integer,
  scrap_incr_quality integer, speed_quality integer, id_order_quality varchar(255),
  conversion_factor_quality integer, number_cavities_quality integer,
  net_production_val_quality integer, gross_production_val_quality integer,
  scrap_val_quality integer, id_shift_quality integer, state_quality integer,
  mode_quality integer, id_production_order_quality integer,
  ts_value_production_quality date, id_equipment_line_connected integer,
  position_in_equipment_line integer, is_equipment_line_infeed integer,
  is_equipment_line_outfeed integer, process_scrap_incr real, process_scrap_val real,
  process_scrap_incr_quality integer, process_scrap_val_quality integer,
  tp_equipment integer, sub_mode varchar(255), ideal_production_speed integer,
  check_number bigint, ingested_at timestamptz DEFAULT now(), source_seq bigint
);
SELECT create_hypertable('public.equipment_values', 'ts_value');

-- 1000 normal rows across 5 machines on DAY, enterprise 3.
INSERT INTO public.equipment_values
  (id_equipment, ts_value, id_enterprise, net_production_incr, net_production_val,
   speed, id_order, faults, id_order_quality, ts_value_production_quality, tp_equipment)
SELECT (g%5)+80, TIMESTAMPTZ '2026-08-10 00:00:00+00' + (g*'80 seconds'::interval),
       3, 5.0, 100.0+g, 120.5, 'PO-'||g, '{"f":1}'::jsonb, '1', DATE '2026-08-10', 1
FROM generate_series(0,999) g;

-- 1 first-boot SPIKE row: incr == val >= floor(1000). Distinct ts to avoid clobber.
INSERT INTO public.equipment_values
  (id_equipment, ts_value, id_enterprise, net_production_incr, net_production_val, tp_equipment)
VALUES (80, TIMESTAMPTZ '2026-08-10 23:59:59+00', 3, 250000, 250000, 1);

-- 1 row OUTSIDE the day (must NOT be unloaded) — proves the window bound.
INSERT INTO public.equipment_values
  (id_equipment, ts_value, id_enterprise, net_production_incr, net_production_val, tp_equipment)
VALUES (80, TIMESTAMPTZ '2026-08-11 00:00:05+00', 3, 5, 500, 1);
SQL

SRC_COUNT=$(docker exec "$CNAME" psql -U postgres -tAc \
  "SELECT count(*) FROM equipment_values WHERE id_enterprise=3 AND ts_value >= '$DAY 00:00:00+00' AND ts_value < '$NEXT 00:00:00+00'")
echo "   source rows for $DAY = $SRC_COUNT (expect 1001: 1000 normal + 1 spike)"

run_append() { # $@ extra env
  env HISTORIAN_APPEND_ENABLED=true HISTORIAN_LOCAL_DIR="$WORK/out" \
      SRC_PGHOST=127.0.0.1 SRC_PGPORT="$PORT" SRC_PGUSER=postgres \
      SRC_PGPASSWORD=verify SRC_PGDATABASE=postgres DUCKDB="$DUCKDB" "$@" \
      bash "$HERE/historian-append.sh" "$ENT" "$DAY" "$NEXT"
}

echo "== [3/6] run the REAL append script (spike guard OFF) =="
run_append

PARQUET="$WORK/out/equipment_values/enterprise=3/year=2026/month=8/data-$DAY.parquet"
[ -f "$PARQUET" ] || { echo "FAIL: parquet not written at $PARQUET"; exit 1; }
echo "   wrote $(du -h "$PARQUET" | cut -f1) parquet"

echo "== [4/6] reconcile via DuckDB hive read (Athena stand-in) =="
ATHENA_COUNT=$("$DUCKDB" :memory: -noheader -list <<SQL
SELECT count(*) FROM read_parquet('$WORK/out/equipment_values/**/*.parquet',
  hive_partitioning=true) WHERE enterprise=3 AND year=2026 AND month=8;
SQL
)
NCOLS=$("$DUCKDB" :memory: -noheader -list <<SQL
SELECT count(*) FROM (DESCRIBE SELECT * FROM read_parquet('$PARQUET', hive_partitioning=false));
SQL
)
echo "   athena-equivalent count = $ATHENA_COUNT ; source = $SRC_COUNT ; in-file parquet cols = $NCOLS (expect 56; +3 hive path cols = Athena's projection)"
[ "$ATHENA_COUNT" = "$SRC_COUNT" ] || { echo "FAIL: count mismatch"; exit 1; }
[ "$NCOLS" = "56" ] || { echo "FAIL: expected 56 projected columns, got $NCOLS"; exit 1; }

echo "== [5/6] idempotency: re-run, count must stay identical =="
run_append >/dev/null
ATHENA_COUNT2=$("$DUCKDB" :memory: -noheader -list <<SQL
SELECT count(*) FROM read_parquet('$WORK/out/equipment_values/**/*.parquet',
  hive_partitioning=true) WHERE enterprise=3 AND year=2026 AND month=8;
SQL
)
echo "   after re-run count = $ATHENA_COUNT2 (expect $SRC_COUNT — overwrite, not append)"
[ "$ATHENA_COUNT2" = "$SRC_COUNT" ] || { echo "FAIL: not idempotent"; exit 1; }

echo "== [6/6] spike guard: HISTORIAN_SPIKE_GUARD=true must zero the spike incr =="
SPIKE_BEFORE=$("$DUCKDB" :memory: -noheader -list <<SQL
SELECT count(*) FROM read_parquet('$PARQUET') WHERE net_production_incr >= 250000;
SQL
)
run_append HISTORIAN_SPIKE_GUARD=true >/dev/null
SPIKE_AFTER=$("$DUCKDB" :memory: -noheader -list <<SQL
SELECT count(*) FROM read_parquet('$PARQUET') WHERE net_production_incr >= 250000;
SQL
)
GUARD_TOTAL=$("$DUCKDB" :memory: -noheader -list <<SQL
SELECT count(*) FROM read_parquet('$PARQUET');
SQL
)
echo "   spike rows: guard OFF=$SPIKE_BEFORE  guard ON=$SPIKE_AFTER (expect 1 -> 0)"
echo "   total rows with guard ON = $GUARD_TOTAL (expect $SRC_COUNT — row kept, incr zeroed)"
[ "$SPIKE_BEFORE" = "1" ] && [ "$SPIKE_AFTER" = "0" ] && [ "$GUARD_TOTAL" = "$SRC_COUNT" ] \
  || { echo "FAIL: spike guard did not behave as expected"; exit 1; }

echo
echo "✅ ALL CHECKS PASSED — incremental append writes the right partition, projects"
echo "   to 56 Glue columns, reconciles to source, is idempotent, and the spike"
echo "   backstop zeroes first-boot spikes while preserving the row."
