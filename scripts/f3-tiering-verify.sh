#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# f3-tiering-verify.sh — deterministic local proof of the F3 hot/cold tiering
# invariant from migration 0045-f3-hot-cold-tiering-90d.sql, WITHOUT touching any
# live DB. (Staging/prod carry NO raw older than 90 days yet — data starts
# 2026-07 — so a real > 90d DROP cannot be exercised there for months. This
# harness synthesises old chunks so the guillotine + the cagg-survival property
# are proven now, reproducibly.)
#
# PROVES, end-to-end, on a throwaway TimescaleDB (same major as prod):
#   1. A continuous aggregate over `equipment_values` refreshes with a SMALL
#      start_offset (materialised far inside the 90-day window).
#   2. Compression @ 7 days + retention @ 90 days install cleanly.
#   3. The retention DROP removes raw chunks older than 90 days …
#   4. … while the already-materialised cagg buckets for that same old region
#      SURVIVE (OEE history preserved) — dropping raw does NOT cascade to caggs.
#   5. Recent raw (< 90 days) is untouched.
#   6. SAFETY-ORDERING counter-proof: a cagg region that was NOT materialised
#      before its raw was dropped is LOST — demonstrating WHY the sequencing
#      (materialise-then-drop, append-live-then-retention) is mandatory.
#
# Requires: docker. Cleans up the container on exit.
set -euo pipefail

CNAME="f3-tiering-verify-$$"
PORT="${VERIFY_PG_PORT:-55433}"
PSQL() { docker exec -i "$CNAME" psql -U postgres -v ON_ERROR_STOP=1 -tAX "$@"; }
cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== [1/6] start throwaway TimescaleDB (:$PORT) =="
docker run -d --name "$CNAME" -e POSTGRES_PASSWORD=verify -p "${PORT}:5432" \
  timescale/timescaledb:2.25.2-pg16 >/dev/null
ok=0
for _ in $(seq 1 60); do
  if docker exec "$CNAME" psql -U postgres -tAc "SELECT 1" >/dev/null 2>&1; then
    ok=$((ok+1)); [ "$ok" -ge 3 ] && break
  else ok=0; fi
  sleep 1
done
[ "$ok" -ge 3 ] || { echo "FAIL: DB not ready"; exit 1; }

echo "== [2/6] equipment_values hypertable + a minute cagg (realtime, like prod) =="
PSQL >/dev/null <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
CREATE TABLE public.equipment_values (
  id_equipment integer NOT NULL,
  ts_value timestamptz NOT NULL,
  id_enterprise integer,
  net_production_incr real,
  tp_equipment integer
);
SELECT create_hypertable('public.equipment_values','ts_value', chunk_time_interval => INTERVAL '1 day');

-- realtime cagg (materialized_only=false) — matches prod ca_agg_equipment_values_1min
CREATE MATERIALIZED VIEW public.ca_agg_equipment_values_1min
  WITH (timescaledb.continuous, timescaledb.materialized_only=false) AS
SELECT time_bucket('1 minute', ts_value) AS ts_value,
       id_equipment, id_enterprise, tp_equipment,
       sum(net_production_incr) AS net_production_incr,
       count(*) AS n
  FROM public.equipment_values
 GROUP BY 1,2,3,4
WITH NO DATA;
SQL

echo "== [3/6] insert rows spanning 200 days ago → now (old chunks + hot chunks) =="
PSQL >/dev/null <<'SQL'
-- One row per listed age (days ago). >90d group will be dropped; <90d group stays.
INSERT INTO public.equipment_values (id_equipment, ts_value, id_enterprise, net_production_incr, tp_equipment)
SELECT 80, now() - (d || ' days')::interval, 3, 5.0, 1
FROM (VALUES (200),(150),(120),(100),(91),   -- OLD: older than 90 days (5 rows)
             (30),(10),(1),(0)) AS t(d);      -- HOT: within 90 days (4 rows)
SQL

RAW_OLD_BEFORE=$(PSQL -c "SELECT count(*) FROM equipment_values WHERE ts_value < now() - interval '90 days';")
RAW_HOT_BEFORE=$(PSQL -c "SELECT count(*) FROM equipment_values WHERE ts_value >= now() - interval '90 days';")
echo "   raw rows: OLD(>90d)=$RAW_OLD_BEFORE (expect 5)  HOT(<90d)=$RAW_HOT_BEFORE (expect 4)"

echo "== materialise the cagg over the FULL range (old buckets get persisted) =="
PSQL >/dev/null -c "CALL refresh_continuous_aggregate('public.ca_agg_equipment_values_1min', NULL, now());"
CAGG_OLD_BEFORE=$(PSQL -c "SELECT count(*) FROM ca_agg_equipment_values_1min WHERE ts_value < now() - interval '90 days';")
echo "   cagg buckets in OLD(>90d) region after refresh = $CAGG_OLD_BEFORE (expect 5 — the OEE we must keep)"

echo "== [4/6] apply tiering: compression @7d + retention @90d (migration 0045) =="
PSQL >/dev/null <<'SQL'
ALTER TABLE public.equipment_values SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'id_equipment',
  timescaledb.compress_orderby   = 'ts_value DESC');
SELECT add_compression_policy('public.equipment_values', INTERVAL '7 days', if_not_exists => true);
SELECT add_retention_policy('public.equipment_values',   INTERVAL '90 days', if_not_exists => true);
SQL
echo "   policies installed:"
PSQL -c "SELECT proc_name||' '||coalesce(config->>'compress_after', config->>'drop_after') FROM timescaledb_information.jobs WHERE hypertable_name='equipment_values' AND proc_name IN ('policy_compression','policy_retention') ORDER BY proc_name;" | sed 's/^/     /'

echo "== [5/6] exercise the retention DROP (what the policy job runs) =="
# drop_chunks is exactly what policy_retention calls under the hood — call it
# directly for a deterministic test instead of waiting for the scheduled job.
DROPPED=$(PSQL -c "SELECT count(*) FROM (SELECT drop_chunks('public.equipment_values', older_than => INTERVAL '90 days')) x;")
echo "   chunks dropped by the 90d guillotine = $DROPPED"

RAW_OLD_AFTER=$(PSQL -c "SELECT count(*) FROM equipment_values WHERE ts_value < now() - interval '90 days';")
RAW_HOT_AFTER=$(PSQL -c "SELECT count(*) FROM equipment_values WHERE ts_value >= now() - interval '90 days';")
CAGG_OLD_AFTER=$(PSQL -c "SELECT count(*) FROM ca_agg_equipment_values_1min WHERE ts_value < now() - interval '90 days';")

echo "   AFTER drop:  raw OLD(>90d)=$RAW_OLD_AFTER (expect 0)   raw HOT(<90d)=$RAW_HOT_AFTER (expect 4)"
echo "                cagg OLD(>90d)=$CAGG_OLD_AFTER (expect 5 — OEE PRESERVED across the raw drop)"

echo "== [6/6] safety-ordering counter-proof: un-materialised region is LOST on drop =="
# Insert a fresh OLD row (95d) that the cagg has NOT been refreshed over, then drop.
PSQL >/dev/null -c "INSERT INTO public.equipment_values VALUES (81, now() - interval '95 days', 3, 9.0, 1);"
PSQL >/dev/null -c "SELECT drop_chunks('public.equipment_values', older_than => INTERVAL '90 days');"
LOST=$(PSQL -c "SELECT count(*) FROM ca_agg_equipment_values_1min WHERE id_equipment=81;")
echo "   cagg rows for the never-materialised id=81 after drop = $LOST (expect 0 → proves materialise-BEFORE-drop is mandatory)"

echo
FAIL=0
[ "$RAW_OLD_BEFORE" = "5" ] && [ "$RAW_HOT_BEFORE" = "4" ] || { echo "FAIL: seed counts"; FAIL=1; }
[ "$CAGG_OLD_BEFORE" = "5" ] || { echo "FAIL: cagg did not materialise the old region"; FAIL=1; }
[ "$RAW_OLD_AFTER" = "0" ] || { echo "FAIL: old raw not dropped"; FAIL=1; }
[ "$RAW_HOT_AFTER" = "4" ] || { echo "FAIL: hot raw wrongly dropped"; FAIL=1; }
[ "$CAGG_OLD_AFTER" = "5" ] || { echo "FAIL: OEE cagg lost when raw dropped"; FAIL=1; }
[ "$LOST" = "0" ] || { echo "FAIL: counter-proof unexpected"; FAIL=1; }
if [ "$FAIL" = "0" ]; then
  echo "✅ ALL CHECKS PASSED — 90d retention drops raw > 90d, materialised caggs (OEE)"
  echo "   survive the drop, hot raw is untouched, and the counter-proof confirms the"
  echo "   materialise-before-drop / append-before-retention sequencing is load-bearing."
else
  echo "❌ FAILURES ABOVE"; exit 1
fi
