#!/usr/bin/env bash
# consolidate-event-chunks.sh — merge silver.equipment_events' historical 1-day chunks
# into one chunk per month (run ON the DB box; idempotent; safe to re-run / resume).
#
# WHY (2026-09-24): the T1 history backfill left 1,599 one-day chunks (~1,570
# compressed). Every query that can't exclude chunks pays per-chunk planning/executor
# cost: operator justify/split timed out (>20 s, per-backend catalog warm-up ~10-13 s)
# and a whole-history aggregate built 1,567 decompress + 3,136 hash-agg nodes → 7 GB in
# one backend → kernel OOM-kill → cluster crash-recovery.
#
# HOW: for each fully-historical month (oldest first), CALL merge_chunks(<that month's
# compressed chunks>) — Timescale keeps them compressed. Safety:
#   * merge needs an AccessExclusiveLock per chunk; any query that can't chunk-exclude
#     holds a share lock on EVERY chunk → the merge would wait and convoy new queries
#     behind it. So lock_timeout=3s + retry with backoff: a convoy is capped at 3 s.
#   * row count per month verified before/after — any mismatch STOPS the run.
#   * stops if host MemAvailable < 2 GB. Months with <2 compressed chunks are skipped.
#   * never touches the last KEEP_RECENT_MONTHS months (live inserts, uncompressed chunks).
# Afterwards set FINAL=1 to apply compress_chunk_time_interval='30 days' so the
# compression policy rolls future daily chunks into monthly compressed chunks.
#
# Usage (DB box, root):  bash consolidate-event-chunks.sh            # merge
#                        MAX_MONTHS=2 bash consolidate-event-chunks.sh  # canary
#                        FINAL=1 bash consolidate-event-chunks.sh     # + future-proofing
set -uo pipefail
DB="${DB:-packiot_analytics}"; C="${PG_CONTAINER:-timescaledb}"
KEEP_RECENT_MONTHS="${KEEP_RECENT_MONTHS:-2}"; MAX_MONTHS="${MAX_MONTHS:-999}"
RETRIES="${RETRIES:-20}"
q(){ docker exec "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -At -c "$1"; }
log(){ echo "[$(date -u +%T)] $*"; }
memok(){ [ "$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)" -ge 2048 ]; }

log "chunks before: $(q "SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_name='equipment_events'")"
MONTHS=$(q "SELECT DISTINCT date_trunc('month', range_start)::date FROM timescaledb_information.chunks
             WHERE hypertable_name='equipment_events'
               AND range_start < date_trunc('month', now()) - interval '$((KEEP_RECENT_MONTHS - 1)) months'
             ORDER BY 1")
done_n=0
for M in $MONTHS; do
  [ "$done_n" -ge "$MAX_MONTHS" ] && break
  memok || { log "STOP: MemAvailable < 2 GB"; exit 3; }
  # merge_chunks only merges TIME-ADJACENT chunks; sparse legacy months have day gaps (a
  # day without events has no chunk) → split the month into runs of contiguous chunks
  # (a run breaks where range_start != previous range_end) and merge each run of >= 2.
  RUNS=$(q "WITH c AS (SELECT chunk_schema, chunk_name, range_start, range_end,
                              CASE WHEN range_start = lag(range_end) OVER (ORDER BY range_start) THEN 0 ELSE 1 END AS brk
                         FROM timescaledb_information.chunks
                        WHERE hypertable_name='equipment_events' AND is_compressed
                          AND range_start >= '$M' AND range_start < '$M'::date + interval '1 month'),
                 g AS (SELECT *, sum(brk) OVER (ORDER BY range_start) AS grp FROM c)
            SELECT string_agg(quote_literal(format('%I.%I', chunk_schema, chunk_name)), ',' ORDER BY range_start)
              FROM g GROUP BY grp HAVING count(*) >= 2 ORDER BY min(range_start)")
  [ -z "$RUNS" ] && { log "$M: no contiguous run of >= 2 compressed chunks — skip"; continue; }
  BEFORE=$(q "SELECT count(*) FROM silver.equipment_events WHERE ts_event >= '$M' AND ts_event < '$M'::date + interval '1 month'")
  N=0; FAILED=0
  while IFS= read -r CHUNKS; do
    [ -z "$CHUNKS" ] && continue
    ok=0
    for a in $(seq 1 "$RETRIES"); do
      if OUT=$(q "SET lock_timeout='3s'; CALL merge_chunks(ARRAY[$CHUNKS]::regclass[])" 2>&1); then ok=1; break; fi
      if echo "$OUT" | grep -q 'lock timeout'; then sleep $((a < 6 ? a * 5 : 30)); continue; fi
      log "$M: merge ERROR (not a lock timeout): $(echo "$OUT" | tail -1)"; break
    done
    if [ "$ok" = 1 ]; then N=$((N + $(echo "$CHUNKS" | tr ',' '\n' | wc -l))); else FAILED=1; fi
  done <<< "$RUNS"
  AFTER=$(q "SELECT count(*) FROM silver.equipment_events WHERE ts_event >= '$M' AND ts_event < '$M'::date + interval '1 month'")
  [ "$BEFORE" = "$AFTER" ] || { log "STOP: $M row count changed $BEFORE -> $AFTER"; exit 4; }
  [ "$N" -eq 0 ] && { log "$M: nothing merged (failed=$FAILED)"; continue; }
  log "$M: merged $N chunks in contiguous runs (rows $AFTER verified, failed_runs=$FAILED)"
  done_n=$((done_n + 1))
done
log "chunks after: $(q "SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_name='equipment_events'")"

if [ "${FINAL:-0}" = 1 ]; then
  # Future-proofing: the compression policy merges adjacent daily chunks into up-to-30-day
  # compressed chunks as it compresses them (compress_chunk_time_interval).
  q "ALTER TABLE silver.equipment_events SET (timescaledb.compress_chunk_time_interval = '30 days')"
  log "compress_chunk_time_interval = 30 days set"
fi
