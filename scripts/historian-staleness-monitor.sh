#!/usr/bin/env bash
# historian-staleness-monitor.sh — R4/R5. Detect a MISSED cutover-refresh hook before
# it corrupts served numbers (ev_all double-count of a newly-archived window).
#
# THE INVARIANT (see 10-historian-gateway.sh): after every cold-store append, the
# append job's post-run hook MUST re-run refresh-hist-cutover.sql so
# hist_cutover.cutover_ts = max(cold ts) for each ev_promoted enterprise. If that hook
# is skipped, the newly-archived window is served by BOTH the hot and cold branches of
# ev_all = double-count.
#
# TWO detectors, cheapest first:
#   (A) TIMESTAMP (R5, metadata-only — no parquet scan): compare hist_meta.last_append_at
#       (stamped by the append hook) vs hist_cutover.refreshed_at per ev_promoted
#       enterprise. last_append_at > refreshed_at ⇒ the store grew after the last refresh.
#   (B) AUTHORITATIVE BACKSTOP (bounded cold scan): for each ev_promoted enterprise, the
#       cold max(ts_value) over the CURRENT + PREVIOUS month partitions (prunable to ≤2
#       parquet files, T3) must NOT exceed hist_cutover.cutover_ts. Catches a missed hook
#       even if hist_meta was never stamped (e.g. an uncodified manual replay).
#
# Runs ON the app box (has `docker exec hist-gateway`), off-hours, from the
# historian-integrity-monitor.timer. Exit 0 = fresh; exit 1 = staleness/double-count risk.
#   GATEWAY_CONTAINER   docker container (default hist-gateway)
#   STALENESS_MARGIN    grace before flagging (default '5 minutes')
set -euo pipefail
CONTAINER="${GATEWAY_CONTAINER:-hist-gateway}"
MARGIN="${STALENESS_MARGIN:-5 minutes}"
psql() { docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
rc=0

echo "== historian staleness monitor =="

# ── (A) timestamp check — hist_meta.last_append_at vs hist_cutover.refreshed_at ──
A_VIOL="$(psql -tAc "
  SELECT string_agg(format('ent=%s append=%s > refreshed=%s',
                           p.id_enterprise, m.last_append_at, c.refreshed_at), '; ')
    FROM hist_promoted_enterprise p
    JOIN hist_meta     m ON m.id_enterprise = p.id_enterprise
    JOIN hist_cutover  c ON c.id_enterprise = p.id_enterprise
   WHERE p.ev_promoted
     AND m.last_append_at > c.refreshed_at + interval '${MARGIN}';" | sed '/^$/d')"
if [ -n "$A_VIOL" ]; then
  echo "STALENESS VIOLATION (A/timestamp): cold appended AFTER the last cutover refresh — refresh hook missed, ev_all double-counting:" >&2
  echo "  $A_VIOL" >&2
  echo "  Fix: run services/historian-gateway/refresh-hist-cutover.sql on the gateway." >&2
  rc=1
else
  echo "  (A) timestamp check OK: no ev_promoted enterprise appended after its cutover refresh."
fi

# ── (B) bounded authoritative backstop — cold max(ts) over current+prev month ────
Y="$(date -u +%Y)"; M="$(date -u +%-m)"
PY="$(date -u -d '1 month ago' +%Y)"; PM="$(date -u -d '1 month ago' +%-m)"
B_VIOL="$(psql -tAc "
  WITH cold AS (
    SELECT id_enterprise, max(ts_value) AS cold_max
      FROM hist
     WHERE ((year=${Y} AND month=${M}) OR (year=${PY} AND month=${PM}))
       AND id_enterprise IN (SELECT id_enterprise FROM hist_promoted_enterprise WHERE ev_promoted)
     GROUP BY id_enterprise)
  SELECT string_agg(format('ent=%s cold_max=%s > cutover=%s',
                           cold.id_enterprise, cold.cold_max, c.cutover_ts), '; ')
    FROM cold JOIN hist_cutover c ON c.id_enterprise = cold.id_enterprise
   WHERE cold.cold_max > c.cutover_ts;" | sed '/^$/d')"
if [ -n "$B_VIOL" ]; then
  echo "STALENESS VIOLATION (B/cold-scan): cold max(ts) exceeds the recorded cutover boundary — ev_all double-counting the gap:" >&2
  echo "  $B_VIOL" >&2
  echo "  Fix: run services/historian-gateway/refresh-hist-cutover.sql on the gateway." >&2
  rc=1
else
  echo "  (B) bounded cold-scan OK (year/month=${Y}-${M},${PY}-${PM}): cold max within the cutover boundary."
fi

[ "$rc" -eq 0 ] && echo "historian staleness OK: no missed refresh hook detected."
exit "$rc"
