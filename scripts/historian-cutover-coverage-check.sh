#!/usr/bin/env bash
# historian-cutover-coverage-check.sh — CI / boot assertion for the hist_cutover invariant.
#
# INVARIANT (t271, load-bearing — see services/historian-gateway/docker-entrypoint-initdb.d/
# 10-historian-gateway.sh): the hist_cutover boundary set MUST equal the EV-promoted
# allow-list (promoted_enterprise WHERE ev_promoted). equipment_values_all serves cold ONLY for
# ev_promoted enterprises (INNER JOIN the allow-list) and clips the HOT side of any
# enterprise that has a hist_cutover row, so:
#   * a PROMOTED enterprise MISSING its cutover row => its hot+cold overlap DOUBLE-COUNTS
#     (proven historically: ent3 352,136 -> 196,671 after the boundary was seeded); and
#   * a hist_cutover row for a NON-promoted enterprise => that tenant's hot history is
#     wrongly CLIPPED at a boundary whose cold is never served (silent data loss).
# Both directions are violations. (Pre-t271 this check compared the full *-legacy S3
# archive to hist_cutover; that is obsolete — the cold archive is no longer served
# wholesale, only the promoted subset is.)
#
# METADATA-ONLY BY DESIGN: reads only the two tiny tables — NEVER scans the Parquet.
#
# Run ON the gateway box (has `docker exec hist-gateway`), from the append/promotion
# post-run hook or in CI via SSM. Exit 0 = aligned; exit 1 = violation (lists the ids).
#
#   GATEWAY_CONTAINER  docker container name (default: hist-gateway)
set -euo pipefail
CONTAINER="${GATEWAY_CONTAINER:-hist-gateway}"

# EV-promoted allow-list.
promoted="$(docker exec -i "$CONTAINER" psql -U postgres -d packiot_historian -tAc \
  'SELECT id_enterprise FROM promoted_enterprise WHERE ev_promoted ORDER BY 1' | sed '/^$/d' | sort -un)"
# Current hist_cutover boundary set.
cut_ents="$(docker exec -i "$CONTAINER" psql -U postgres -d packiot_historian -tAc \
  'SELECT id_enterprise FROM hist_cutover ORDER BY 1' | sed '/^$/d' | sort -un)"

missing="$(comm -23 <(printf '%s\n' "$promoted") <(printf '%s\n' "$cut_ents") | sed '/^$/d')"  # promoted but no cutover row
extra="$(comm -13 <(printf '%s\n' "$promoted") <(printf '%s\n' "$cut_ents") | sed '/^$/d')"     # cutover row but not promoted

rc=0
if [ -n "$missing" ]; then
  echo "COVERAGE VIOLATION: ev_promoted enterprise(s) with NO hist_cutover row (DOUBLE-COUNT risk):" >&2
  printf '  enterprise=%s\n' $missing >&2
  echo "Fix: run services/historian-gateway/refresh-equipment_values-cutover.sql on the gateway." >&2
  rc=1
fi
if [ -n "$extra" ]; then
  echo "COVERAGE VIOLATION: hist_cutover row(s) for NON-ev_promoted enterprise(s) (hot-CLIP risk):" >&2
  printf '  enterprise=%s\n' $extra >&2
  echo "Fix: DELETE FROM hist_cutover WHERE id_enterprise NOT IN (SELECT id_enterprise FROM promoted_enterprise WHERE ev_promoted);" >&2
  rc=1
fi
[ "$rc" -eq 0 ] && echo "hist_cutover coverage OK: boundary set == ev_promoted allow-list ($(printf '%s\n' "$promoted" | sed '/^$/d' | wc -l | tr -d ' ') enterprise(s))."
exit "$rc"
