#!/usr/bin/env bash
# historian-ee-coverage-check.sh — R7. Guard the ev_all_events HOT-ANCHORED
# completeness caveat.
#
# WHY (10-historian-gateway.sh EE header): ev_all_events hands the whole overlap
# window to HOT (cutover_ts = min(hot ts_event); COLD kept only ts_event<cutover_ts).
# That assumes HOT fully covers the overlap for ALL equipment of a promoted tenant. If a
# promoted tenant's hot deep-history backfill is PARTIAL, an equipment that appears in
# COLD but NOT in HOT is UNDER-covered — its post-cutover events are dropped (cold is
# clipped, hot has nothing). This is the conservative failure mode (a gap, never a
# double-count), but it silently loses downtime history, so it must be watched.
#
# THE CHECK: per ee_promoted enterprise, the set of id_equipment present in COLD
# (hist_ee, bounded to recent months for a cheap prune) MUST be a subset of the set
# present in HOT (live.equipment_events). Any cold-only equipment ⇒ under-coverage.
#
# Runs ON the app box, off-hours, from the historian-integrity-monitor.timer.
# Alert-only: exit 1 lists the under-covered (enterprise, equipment) pairs.
#   GATEWAY_CONTAINER   docker container (default hist-gateway)
#   EE_COVERAGE_MONTHS  how many months of cold to scan (default 3)
set -euo pipefail
CONTAINER="${GATEWAY_CONTAINER:-hist-gateway}"
MONTHS="${EE_COVERAGE_MONTHS:-3}"
psql() { docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
rc=0

echo "== historian EE hot-coverage reconciliation =="

# Build the year/month prune predicate for the last $MONTHS months (keeps the cold scan
# to a few parquet files).
YM_PRED=""
for i in $(seq 0 $((MONTHS-1))); do
  y="$(date -u -d "$i month ago" +%Y)"; m="$(date -u -d "$i month ago" +%-m)"
  YM_PRED="${YM_PRED}${YM_PRED:+ OR }(year=${y} AND month=${m})"
done

EE_ENTS="$(psql -tAc "SELECT id_enterprise FROM hist_promoted_enterprise WHERE ee_promoted ORDER BY 1" | sed '/^$/d')"
if [ -z "$EE_ENTS" ]; then
  echo "  no ee_promoted enterprises — nothing to reconcile."; exit 0
fi

for E in $EE_ENTS; do
  # The enterprise's EE cutover: cold events with ts_event >= cutover_ts fall in the
  # HOT-owned window (ev_all_events clips cold there). ONLY equipment with cold events
  # in THAT window that hot lacks are truly under-covered — equipment whose cold events
  # are all pre-cutover are correctly cold-served, so exclude them (precision filter).
  CUT="$(psql -tAc "SELECT cutover_ts FROM ev_events_cutover WHERE id_enterprise=${E}" | sed '/^$/d')"
  [ -z "$CUT" ] && { echo "  ent=${E}: no ev_events_cutover row — skipping."; continue; }
  UNDER="$(psql -tAc "
    WITH cold AS (
      SELECT DISTINCT id_equipment FROM hist_ee
       WHERE id_enterprise=${E} AND (${YM_PRED})
         AND ts_event >= TIMESTAMP '${CUT}' AND id_equipment IS NOT NULL),
         hot AS (
      SELECT DISTINCT id_equipment FROM live.equipment_events WHERE id_enterprise=${E})
    SELECT string_agg(cold.id_equipment::text, ',')
      FROM cold LEFT JOIN hot USING (id_equipment)
     WHERE hot.id_equipment IS NULL;" | sed '/^$/d')"
  if [ -n "$UNDER" ]; then
    echo "EE COVERAGE GAP: enterprise=${E} has cold-only equipment (present in COLD, absent in HOT) — UNDER-covered in ev_all_events:" >&2
    echo "  id_equipment=[$UNDER]" >&2
    echo "  Cause: partial hot deep-history backfill. Fix: extend the hot backfill for these equipment, or re-anchor ev_events_cutover." >&2
    rc=1
  else
    echo "  ent=${E}: OK — every cold equipment (last ${MONTHS} mo) is present in hot."
  fi
done

[ "$rc" -eq 0 ] && echo "historian EE hot-coverage OK."
exit "$rc"
