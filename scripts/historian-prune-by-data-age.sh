#!/usr/bin/env bash
# historian-prune-by-data-age.sh — cap the STAGING historian (S3 cold archive) to the last
# KEEP_MONTHS months of DATA. Half of the post-promotion staging cost cap (the other half is
# db/retention/profiles/staging-capped.sql for analytics) — see
# docs/plans/unified-hot-cold-serving-grain-tiered-retention.md §7.
#
# WHY NOT AN S3 LIFECYCLE RULE: lifecycle expiration counts OBJECT age (upload time), not the
# age of the data inside. A 2021 partition backfilled yesterday is a 1-day-old object; a
# partition rewritten daily never expires. Data-age capping must delete partitions by their
# enterprise=/year=/month= KEY.
#
# SAFETY:
#   * DRY RUN by default — lists what would go (objects, bytes, per prefix/year). Deletes only
#     with APPLY=1 AND CONFIRM="delete-staging-history".
#   * REFUSES production: bucket name must contain "staging" and ENVIRONMENT must not be
#     production. Production keeps the archive forever (tiering only).
#   * Deletes WHOLE months strictly before the cutoff month (first day of now − KEEP_MONTHS).
#   * Union safety: EV/PO boundaries are anchored at MAX(cold ts) and EE at MIN(hot ts), so
#     deleting OLD partitions moves no boundary (no double-count, no gap) — the cutover
#     refreshes are still re-run afterwards (REFRESH=1 on the app box) as belt-and-braces.
#
# Usage:  scripts/historian-prune-by-data-age.sh                      # dry run, 3 months
#         APPLY=1 CONFIRM=delete-staging-history scripts/historian-prune-by-data-age.sh
set -euo pipefail
BUCKET="${HISTORIAN_BUCKET:-packiot-staging-historian-639178078294}"
KEEP_MONTHS="${KEEP_MONTHS:-3}"
PREFIXES="${PREFIXES:-equipment_values equipment_events equipment_events_legacy_unpromoted production_orders equipment_oee_shift}"
REGION="${AWS_REGION:-us-east-1}"
APPLY="${APPLY:-0}"; REFRESH="${REFRESH:-1}"
log(){ echo "[historian-prune] $*"; }

case "$BUCKET" in *staging*) ;; *) log "REFUSING: bucket '$BUCKET' is not a staging bucket (production keeps history forever)"; exit 2 ;; esac
[ "${ENVIRONMENT:-}" = production ] && { log "REFUSING: ENVIRONMENT=production"; exit 2; }
if [ "$APPLY" = 1 ] && [ "${CONFIRM:-}" != "delete-staging-history" ]; then
  log "APPLY=1 requires CONFIRM=delete-staging-history"; exit 2
fi

CUT="$(date -u -d "$(date -u +%Y-%m-01) -${KEEP_MONTHS} months" +%Y-%m)"
CUT_KEY=$(( 10#${CUT%-*} * 12 + 10#${CUT#*-} ))
log "bucket=$BUCKET keep=${KEEP_MONTHS}mo → delete partitions with (year,month) < $CUT  mode=$([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
total_n=0; total_b=0
for pfx in $PREFIXES; do
  aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix "$pfx/" \
      --query 'Contents[].[Key,Size]' --output text 2>/dev/null | grep -v '^None' > "$TMP/all" || true
  # keep only keys whose year=/month= partition is strictly before the cutoff month
  awk -v cut="$CUT_KEY" '{
      y=""; m="";
      if (match($1, /year=[0-9]+/))  y=substr($1, RSTART+5, RLENGTH-5);
      if (match($1, /month=[0-9]+/)) m=substr($1, RSTART+6, RLENGTH-6);
      if (y != "" && m != "" && (y*12 + m) < cut) print $1 "\t" $2 "\t" y
    }' "$TMP/all" > "$TMP/del.$pfx"
  n=$(wc -l < "$TMP/del.$pfx"); b=$(awk -F'\t' '{s+=$2} END {print s+0}' "$TMP/del.$pfx")
  years=$(awk -F'\t' '{c[$3]++} END {for (y in c) printf "%s:%d ", y, c[y]}' "$TMP/del.$pfx" | tr ' ' '\n' | sort | tr '\n' ' ')
  log "  $pfx: $n objects, $((b / 1024 / 1024)) MiB  [$years]"
  total_n=$((total_n + n)); total_b=$((total_b + b))
  if [ "$APPLY" = 1 ] && [ "$n" -gt 0 ]; then
    cut -f1 "$TMP/del.$pfx" | split -l 1000 - "$TMP/batch.$pfx."
    for f in "$TMP"/batch."$pfx".*; do
      jq -Rn '{Objects: [inputs | {Key: .}], Quiet: true}' < "$f" > "$f.json"
      aws s3api delete-objects --region "$REGION" --bucket "$BUCKET" --delete "file://$f.json" >/dev/null
    done
    log "  $pfx: deleted $n objects"
  fi
done
log "TOTAL: $total_n objects, $((total_b / 1024 / 1024)) MiB $([ "$APPLY" = 1 ] && echo deleted || echo 'would be deleted (dry run)')"

if [ "$APPLY" = 1 ] && [ "$REFRESH" = 1 ]; then
  GW="${GATEWAY_CONTAINER:-hist-gateway}"
  if docker inspect "$GW" >/dev/null 2>&1; then
    for f in refresh-equipment_values-cutover.sql refresh-ee-cutover.sql refresh-po-cutover.sql; do
      docker exec -i "$GW" psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -q -f - < "/opt/packiot/historian/$f"
    done
    log "cutover boundaries refreshed (EV+EE+PO); verify: scripts/historian-cutover-coverage-check.sh"
  else
    log "not on the app box — run the three refresh-*-cutover.sql on hist-gateway next"
  fi
fi
