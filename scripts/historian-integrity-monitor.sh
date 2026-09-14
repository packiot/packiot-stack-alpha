#!/usr/bin/env bash
# historian-integrity-monitor.sh — aggregator for the scheduled historian gateway
# integrity checks (run by historian-integrity-monitor.timer on the app box). Runs all
# three and returns non-zero if ANY fails, so systemd marks the unit failed (→ alert).
#
#   1. historian-cutover-coverage-check.sh  — R1/t271 (HARD): ev_union_boundary set == ev_promoted allow-list
#   2. historian-staleness-monitor.sh       — R4/R5  (HARD): no missed cutover-refresh hook (double-count risk)
#   3. historian-ee-coverage-check.sh        — R7     (SOFT): ev_all_events hot-coverage caveat
#
# SEVERITY TIERS: R1 (cross-tenant leak) and R4 (double-count) are correctness-breaking
# ⇒ HARD: they fail the unit so systemd alerts. R7 flags a CONSERVATIVE under-coverage
# gap (missing rows, never wrong rows) ⇒ SOFT/alert-only: its finding is logged loudly
# every run but does NOT fail the unit (so a known, slow-to-fix coverage gap can't mask a
# NEW double-count/leak by keeping the timer permanently red).
#
#   GATEWAY_CONTAINER  docker container (default hist-gateway); forwarded to each check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GATEWAY_CONTAINER="${GATEWAY_CONTAINER:-hist-gateway}"
overall=0

run() {
  local tier="$1" name="$2"; shift 2
  echo "──────────────────────────────────────── ${name} [${tier}]"
  if "$@"; then
    echo "[PASS] ${name}"
  elif [ "$tier" = HARD ]; then
    echo "[FAIL] ${name} — HARD (fails the unit)" >&2; overall=1
  else
    echo "[WARN] ${name} — SOFT (alert-only, logged; unit stays green)" >&2
  fi
  echo
}

run HARD "cutover-coverage (R1)"  "$HERE/historian-cutover-coverage-check.sh"
run HARD "staleness (R4/R5)"      "$HERE/historian-staleness-monitor.sh"
run SOFT "ee-coverage (R7)"       "$HERE/historian-ee-coverage-check.sh"

if [ "$overall" -eq 0 ]; then
  echo "historian integrity: OK (no correctness-breaking condition; see any [WARN] above)"
else
  echo "historian integrity: HARD CHECK FAILED — double-count or cross-tenant-leak risk" >&2
fi
exit "$overall"
