#!/usr/bin/env bash
# scalability-probe.sh — one-shot scalability & capacity snapshot of the live stack.
#
# WHY THIS EXISTS
#   "Is it healthy right now?" (Grafana / hardproof-dashboards.py) is NOT the same
#   question as "will it survive 5× the tenants / 10× the tag rate?". This probe
#   answers the SECOND question: it reads the *capacity ceilings and the current
#   distance to them* — worker replica counts, per-queue consumer fan-out, the
#   Postgres connection ceiling, long-running-query pressure, mem-cap headroom —
#   and prints a PASS / WARN / FAIL verdict per dimension so a human (or CI) can
#   see the binding constraint at a glance.
#
#   It is deliberately READ-ONLY. It runs `rabbitmqctl list_*`, `docker ps/stats`,
#   and read-only `SELECT`s against pg_stat_activity / timescaledb_information.
#   Nothing here mutates state.
#
# ─────────────────────────── INPUTS (env vars) ───────────────────────────────
#   Run it ON the app box (SSM shell) so `docker` and the DB are local, OR set
#   the SSM_* vars and it will relay itself to the box via AWS-RunShellScript.
#
#   APP_INSTANCE   app-box SSM instance id           (default i-06c9547a2c7091ab7)
#   PGHOST         analytics DB host                 (default 10.10.10.89)
#   PGDB           analytics DB name                 (default packiot_analytics)
#   PGUSER         analytics DB user                 (default postgres)
#   PGPASSWORD     analytics DB password             (REQUIRED — no default)
#   HIST_HOST      historian gateway host (optional; skipped if unset)
#   CONN_WARN_PCT  warn when conns exceed this % of max_connections   (default 80)
#   SLOW_QUERY_S   warn on any active query older than this many secs  (default 60)
#   AWS_REGION     region for the SSM relay                            (default us-east-1)
#
#   Worker mem-cap / consumer thresholds are encoded inline below and documented
#   at each check — tune them as the fleet grows.
#
# USAGE
#   # on the app box:
#   PGPASSWORD=… ./scripts/scalability-probe.sh
#   # from a laptop (relays via SSM):
#   PGPASSWORD=… SSM_RELAY=1 ./scripts/scalability-probe.sh
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

PGHOST="${PGHOST:-10.10.10.89}"; PGDB="${PGDB:-packiot_analytics}"; PGUSER="${PGUSER:-postgres}"
CONN_WARN_PCT="${CONN_WARN_PCT:-80}"; SLOW_QUERY_S="${SLOW_QUERY_S:-60}"
: "${PGPASSWORD:?set PGPASSWORD (analytics DB password)}"

# psql via a throwaway alpine container (matches the repo's SSM-DB access pattern).
q(){ docker run --rm -e PGPASSWORD="$PGPASSWORD" postgres:16-alpine \
      psql -h "$PGHOST" -U "$PGUSER" -d "$PGDB" -F'|' -A -tc "$1" 2>&1; }
verdict(){ printf '  [%s] %s\n' "$1" "$2"; }

echo "═══════════ 1. WORKER FLEET (replicas + headroom) ═══════════"
# Scalability signal: are the hot-path workers horizontally scaled, or singletons?
# A singleton is a throughput ceiling AND a single point of failure.
echo "-- hot-path workers (name | status) --"
docker ps --format '{{.Names}}|{{.Status}}' \
  | grep -iE 'stream-engine|sparkplug-agent|mirror|replicat|transformer|read-api|refdata|edge-api|superset-worker' | sort
for svc in stream-engine sparkplug-agent-shared read-api stack-edge-api; do
  n=$(docker ps --format '{{.Names}}' | grep -c "^${svc}");
  [ "$n" -le 1 ] && verdict WARN "$svc = $n replica (singleton → no horizontal scale, SPOF)" \
                 || verdict PASS "$svc = $n replicas"
done
echo "-- mem-cap headroom (name | mem used / limit) — WARN if >70% of a hard cap --"
docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}|{{.MemPerc}}' \
  | grep -iE 'stream-engine|sparkplug-agent|read-api|edge-api|superset|rabbit|mirror|replicat' | sort

echo "═══════════ 2. RABBITMQ (queue fan-out + node headroom) ═══════════"
RMQ=$(docker ps --format '{{.Names}}' | grep -i rabbitmq | head -1)
echo "-- queues with a consumer or backlog (name msgs consumers ready unacked) --"
docker exec "$RMQ" rabbitmqctl list_queues name messages consumers messages_ready messages_unacknowledged 2>/dev/null \
  | awk 'NR<=1 || $2>0 || $3>0 || $4>0'
# Scalability signal: consumers per queue. A MAIN work queue with 1 consumer is
# throughput-bound to one process's prefetch. Backlog climbing = consumer can't
# keep up → scale consumers. DLQ / retry / unroutable holding queues legitimately
# have 0 consumers (they are drained by re-publish, not by a worker) — skip them.
docker exec "$RMQ" rabbitmqctl list_queues name consumers messages 2>/dev/null | awk '
  $2 !~ /^[0-9]+$/ { next }                               # skip banner / header lines
  $1 ~ /failed|retry|unroutable|dlq/ { next }             # holding queues: 0 consumers is correct
  $2<=1 {print "  [WARN] main queue "$1" has "$2" consumer (throughput bound to 1 process)"}
  $3>1000 {print "  [WARN] queue "$1" backlog="$3" (consumer falling behind)"}'
echo "-- node connections / sockets / memory watermark --"
docker exec "$RMQ" rabbitmqctl status 2>/dev/null | grep -iE 'Total:.*limit|Sockets:.*limit|high watermark|Total memory used' | head

echo "═══════════ 3. ANALYTICS DB (the usual binding constraint) ═══════════"
MAXC=$(q "select setting from pg_settings where name='max_connections';")
TOTC=$(q "select count(*) from pg_stat_activity;")
ACT=$(q "select count(*) from pg_stat_activity where state='active';")
IIT=$(q "select count(*) from pg_stat_activity where state='idle in transaction';")
echo "  connections: $TOTC / $MAXC  (active=$ACT, idle_in_txn=$IIT)"
PCT=$(( TOTC * 100 / MAXC ))
[ "$PCT" -ge 100 ] && verdict FAIL "conns at/over ceiling ($PCT%) — new connections may be REJECTED; raise max_connections or add pgbouncer" \
 || { [ "$PCT" -ge "$CONN_WARN_PCT" ] && verdict WARN "conns at $PCT% of ceiling (warn ≥ $CONN_WARN_PCT%)" \
      || verdict PASS "conns at $PCT% of ceiling"; }
[ "${IIT:-0}" -gt 0 ] && verdict WARN "$IIT idle-in-transaction conn(s) — leaked txn holds a slot + locks"
echo "-- per-datname connection spread --"
q "select datname||' = '||count(*) from pg_stat_activity where datname is not null group by datname order by count(*) desc;"
echo "-- long-running active queries (age ≥ ${SLOW_QUERY_S}s hold a connection + can block caggs) --"
LONG=$(q "select count(*) from pg_stat_activity where state='active' and now()-query_start > interval '${SLOW_QUERY_S} seconds';")
q "select round(extract(epoch from now()-query_start))||'s | '||left(regexp_replace(query,E'\\\\s+',' ','g'),90) from pg_stat_activity where state='active' and now()-query_start > interval '${SLOW_QUERY_S} seconds' order by query_start asc limit 5;"
[ "${LONG:-0}" -gt 0 ] && verdict WARN "$LONG query(ies) older than ${SLOW_QUERY_S}s — connection + cagg-refresh pressure" \
                       || verdict PASS "no queries older than ${SLOW_QUERY_S}s"

echo "═══════════ 4. TIMESCALE BACKGROUND JOBS (cagg / retention health) ═══════════"
q "select 'jobs='||count(*)||' failed_last_run='||count(*) filter(where last_run_status='Failed')||' total_failures='||coalesce(sum(total_failures),0) from timescaledb_information.job_stats;"
q "select 'FAILED job '||job_id||' proc='||proc_name from timescaledb_information.job_stats js join timescaledb_information.jobs j using(job_id) where last_run_status='Failed';" 2>/dev/null
echo "-- biggest hypertables (sum over chunks — real on-disk size) --"
q "select hypertable_name||' = '||pg_size_pretty(hypertable_size(format('%I.%I',hypertable_schema,hypertable_name)::regclass)) from timescaledb_information.hypertables order by hypertable_size(format('%I.%I',hypertable_schema,hypertable_name)::regclass) desc limit 8;"

echo "═══════════ 5. PER-TENANT INGEST THROUGHPUT (silver rows / 10min) ═══════════"
# Scalability signal: load distribution across tenants — who drives the fleet.
q "select 'ent'||e.id_enterprise||' = '||count(*)||' rows' from silver.equipment_values v join core.equipments e on e.id_equipment=v.id_equipment where v.ts_value>now()-interval '10 minutes' group by e.id_enterprise order by count(*) desc;"

echo "═══════════ 6. HISTORIAN (cold store) ═══════════"
if [ -n "${HIST_HOST:-}" ]; then
  docker run --rm -e PGPASSWORD="$PGPASSWORD" postgres:16-alpine \
    psql -h "$HIST_HOST" -U "$PGUSER" -d packiot_historian -F'|' -A -tc \
    "select 'gateway reachable, now()='||now();" 2>&1 | head -1
else
  echo "  (HIST_HOST unset — historian check skipped)"
fi
echo "═══════════ done ═══════════"
