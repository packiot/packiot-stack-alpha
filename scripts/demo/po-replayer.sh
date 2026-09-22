#!/usr/bin/env bash
#
# po-replayer.sh — DEMO AID: keep production orders rotating across a tenant's lines
# so the Orders view shows live production flowing (create-and-start → run → finish → next).
#
# This is a demonstration/rehearsal tool, NOT a client workflow — the client creates
# real POs from the Orders UI. It exists so a demo/staging environment looks "alive"
# without a human clicking through the PO lifecycle by hand.
#
# For line-metered tenants (e.g. Bispharma ent5) it only carries REAL production once
# the per-PO line-counter attribution fix (PR #1387) is deployed — before that, line-POs
# capture gross=net=0 (the exact gap that PR fixes). See
# docs/clients/bispharma-per-po-line-counter-reconciliation.md.
#
# ─── SAFETY ─────────────────────────────────────────────────────────────────────────
#   • Mutates a LIVE tenant via edge-api. Only run against an environment you're
#     authorized to (staging/demo). Every PO it creates is prefixed DEMO- and tagged
#     with idOrder in a reserved band (see ID_ORDER_BASE) so `--cleanup` can find them.
#   • The api key is read from EDGE_API_KEY — NEVER hardcode it. Fetch it into the env,
#     e.g.:  export EDGE_API_KEY="$(your-secret-manager get ...)"
#   • On SIGINT/SIGTERM it finishes the POs it opened, so it never leaves a line stuck
#     in a running DEMO order.
#
# ─── USAGE ──────────────────────────────────────────────────────────────────────────
#   EDGE_API_KEY=... LINES="40001:2000009:2000020 40003:2000009:2000020" ./po-replayer.sh
#   ./po-replayer.sh --once        # one PO per line, finish them, exit
#   ./po-replayer.sh --cleanup     # finish every running DEMO PO on the configured lines, exit
#   ./po-replayer.sh --dry-run     # print the calls without making them
#
# ─── CONFIG (env-overridable) ───────────────────────────────────────────────────────
set -euo pipefail

: "${API_BASE:=http://127.0.0.1:8080}"      # edge-api base (on-box: localhost:8080)
: "${ID_ENTERPRISE:=5}"                      # tenant (ent5 = Bispharma staging)
: "${CYCLE_SECONDS:=600}"                    # how long each PO runs before it's finished
: "${POLL_SECONDS:=30}"                      # loop cadence
: "${PO_QUANTITY:=50000}"                    # order target quantity
: "${ID_ORDER_BASE:=990000000}"              # reserved idOrder band for demo POs (cleanup filter)
# LINES = whitespace-separated "idEquipment:idSite:idArea" triples. Resolve site/area per
# line once (SELECT id_equipment,id_site,id_area FROM core.equipments WHERE tp_equipment=3
# AND id_enterprise=<ent>) and pass them in. No default — must be explicit.
: "${LINES:=}"

MODE="loop"
case "${1:-}" in
  --once)    MODE="once" ;;
  --cleanup) MODE="cleanup" ;;
  --dry-run) MODE="dryrun" ;;
  "" )       MODE="loop" ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

[[ -z "${EDGE_API_KEY:-}" ]] && { echo "ERROR: set EDGE_API_KEY (do not hardcode)" >&2; exit 1; }
[[ -z "$LINES" ]] && { echo "ERROR: set LINES=\"idEquipment:idSite:idArea ...\"" >&2; exit 1; }

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
now_utc() { date -u '+%Y-%m-%d %H:%M:%S'; }

# api <method> <path> <json-body?>  — token in query, JSON body optional. Echoes body, sets HTTP_CODE.
api() {
  local method="$1" path="$2" body="${3:-}"
  local url="${API_BASE}${path}"
  case "$url" in *\?*) url="${url}&token=${EDGE_API_KEY}";; *) url="${url}?token=${EDGE_API_KEY}";; esac
  if [[ "$MODE" == "dryrun" ]]; then
    log "DRY $method ${path%%\?*}  ${body:-}"; HTTP_CODE=200; echo '{}'; return 0
  fi
  local out
  out=$(curl -sS -X "$method" "$url" -H 'Content-Type: application/json' \
        ${body:+-d "$body"} -w $'\n%{http_code}')
  HTTP_CODE="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
}

# running_po_id <idEquipment> — echoes the current running PO id for a line (empty if none).
# The greps are expected to miss (idle line) — swallow that so `set -e` doesn't exit.
running_po_id() {
  local eq="$1" resp id
  resp=$(api GET "/api/production-orders/current?idEnterprise=${ID_ENTERPRISE}&idEquipment=${eq}") || true
  id=$(grep -oE '"id_production_order":[0-9]+' <<<"$resp" | grep -oE '[0-9]+' | head -1) || true
  printf '%s' "$id"
}

create_and_start() {
  local eq="$1" site="$2" area="$3" idorder="$4" ts; ts=$(now_utc)
  local body
  body=$(printf '{"idEnterprise":%s,"idSite":%s,"idArea":%s,"idEquipment":%s,"idOrder":%s,"productionOrderQuantity":%s,"timestamp":"%s","nmProductionOrder":"DEMO-%s-%s"}' \
    "$ID_ENTERPRISE" "$site" "$area" "$eq" "$idorder" "$PO_QUANTITY" "$ts" "$eq" "$idorder")
  api POST "/api/production-orders/create-and-start" "$body" >/dev/null
  if [[ "$HTTP_CODE" =~ ^2 ]]; then log "line $eq  ▶ create-and-start idOrder=$idorder (HTTP $HTTP_CODE)"
  else log "line $eq  ✗ create-and-start FAILED (HTTP $HTTP_CODE)"; fi
}

finish_po() {
  local eq="$1" poid="$2" ts; ts=$(now_utc)
  local body
  body=$(printf '{"timestamp":"%s","stopType":"finish","idEnterprise":%s,"idEquipment":%s,"idProductionOrder":%s,"productionOrderQuantity":%s}' \
    "$ts" "$ID_ENTERPRISE" "$eq" "$poid" "$PO_QUANTITY")
  api POST "/api/production-orders/stop" "$body" >/dev/null
  if [[ "$HTTP_CODE" =~ ^2 ]]; then log "line $eq  ⏹ finish PO $poid (HTTP $HTTP_CODE)"
  else log "line $eq  ✗ finish PO $poid FAILED (HTTP $HTTP_CODE)"; fi
}

# --- cleanup: finish every running DEMO PO on the configured lines ---
cleanup() {
  log "cleanup: finishing running DEMO POs on configured lines"
  for triple in $LINES; do
    IFS=: read -r eq _site _area <<<"$triple"
    local poid; poid=$(running_po_id "$eq")
    [[ -n "$poid" ]] && finish_po "$eq" "$poid" || log "line $eq  · no running PO"
  done
}

declare -A OPENED_AT   # idEquipment -> epoch when this replayer opened its current PO
ORDER_SEQ=0
NEXT_ORDER=0
# next_order sets NEXT_ORDER in THIS shell (not a subshell — $(next_order) would lose
# the ORDER_SEQ increment, minting a duplicate idOrder that create rejects).
next_order() { ORDER_SEQ=$((ORDER_SEQ+1)); NEXT_ORDER=$(( ID_ORDER_BASE + ORDER_SEQ )); }

# on exit (incl. Ctrl-C), finish what we opened
finish_opened() {
  trap - INT TERM EXIT
  log "shutting down — finishing POs this replayer opened"
  for eq in "${!OPENED_AT[@]}"; do
    local poid; poid=$(running_po_id "$eq")
    [[ -n "$poid" ]] && finish_po "$eq" "$poid"
  done
  exit 0
}

if [[ "$MODE" == "cleanup" ]]; then cleanup; exit 0; fi

log "po-replayer start · ent=$ID_ENTERPRISE · cycle=${CYCLE_SECONDS}s · mode=$MODE · lines=$(wc -w <<<"$LINES")"
trap finish_opened INT TERM

# main loop: keep each line carrying a fresh DEMO PO; finish + rotate at CYCLE_SECONDS.
while :; do
  epoch=$(date +%s)
  for triple in $LINES; do
    IFS=: read -r eq site area <<<"$triple"
    poid=$(running_po_id "$eq")
    if [[ -z "$poid" ]]; then
      next_order; create_and_start "$eq" "$site" "$area" "$NEXT_ORDER"
      OPENED_AT["$eq"]=$epoch
    else
      opened=${OPENED_AT[$eq]:-$epoch}; OPENED_AT["$eq"]=$opened
      if (( epoch - opened >= CYCLE_SECONDS )); then
        finish_po "$eq" "$poid"
        next_order; create_and_start "$eq" "$site" "$area" "$NEXT_ORDER"
        OPENED_AT["$eq"]=$epoch
      fi
    fi
  done
  if [[ "$MODE" == "once" ]]; then
    log "--once: letting POs run one cycle (${CYCLE_SECONDS}s) then finishing"
    sleep "$CYCLE_SECONDS"
    cleanup
    exit 0
  fi
  sleep "$POLL_SECONDS"
done
