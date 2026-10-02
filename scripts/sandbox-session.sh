#!/usr/bin/env bash
# sandbox-session.sh — hands-on sessions in the SANDBOX-CPACK twin (ent 2000003) with a
# GRACE PERIOD, then an automatic self-heal back to a live CPACK-staging reflection.
#
# How a session works (db/migrations/t-sandbox-grace-hold):
#   1. Make any change in the twin (operator-sbx PO start/stop/justify/split, csadmin
#      edits, front4 settings…). edge-api logs it → the twin is HELD from that moment:
#      legacy-replicator-sbx stops replaying CPACK's own actions into it and every heal
#      (nightly, E2E, --heal) refuses to wipe it. Live telemetry keeps flowing.
#   2. Every further change pushes the deadline: heal is due GRACE after your LAST change
#      (default 4 h), or at a manual "extend" time, whichever is later.
#   3. When due, the 5-min timer (systemd sandbox-grace-heal.timer) heals: config
#      re-clone + ops.sandbox_reflect → CPACK staging again, then the hold releases and
#      the replicator resumes mirroring live actions.
#
# Usage:
#   sandbox-session.sh status            # held? last change, heal due at, last heal
#   sandbox-session.sh extend 8h         # keep my changes at least 8 h from now
#   sandbox-session.sh grace 2h          # change the grace period (after the last change)
#   sandbox-session.sh heal-now          # I'm done: heal immediately (forced)
#   sandbox-session.sh tick              # timer entrypoint: heal only if due
#   sandbox-session.sh nightly           # nightly tidy: heal unless a session is held
#
# Runs the SQL on the staging app box: directly under SANDBOX_LOCAL=1 (the timer / the
# self-hosted runner), else via SSM from a workstation (same path as
# provision-sandbox-tenant.sh).
set -euo pipefail

SENT="${SANDBOX_ENTERPRISE:-2000003}"
APP_INSTANCE="${APP_INSTANCE:-i-06c9547a2c7091ab7}"
REGION="${REGION:-us-east-1}"
ANALYTICS_DB="${ANALYTICS_DB:-packiot_analytics}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# run_sql <sql>: psql -At on the analytics DB, output on stdout, non-zero on SQL error.
run_sql() {
  local sqlb rem out
  sqlb=$(printf '%s' "$1" | base64 -w0)
  rem=$(cat <<REMOTE
set +e; set -f; set -a; . /opt/packiot/.env 2>/dev/null; set +a; set +f; set -e
echo $sqlb | base64 -d | docker run --rm -i --network stack_packiot-net -e PGPASSWORD="\$POSTGRES_PASSWORD" \
  postgres:16-alpine psql -h "\$POSTGRES_HOST_UPSTREAM" -p 5432 -U "\$POSTGRES_USER" -d "$ANALYTICS_DB" \
  -v ON_ERROR_STOP=1 -At -F' | ' 2>&1
REMOTE
)
  if [ -n "${SANDBOX_LOCAL:-}" ]; then
    printf '%s' "$rem" | sudo bash
  else
    local remb; remb=$(printf '%s' "$rem" | base64 -w0)
    out=$(script -qec "aws ssm start-session --target $APP_INSTANCE \
      --document-name AWS-StartNonInteractiveCommand \
      --parameters 'command=[\"bash -c echo\${IFS}$remb|base64\${IFS}-d|sudo\${IFS}bash\"]' \
      --region $REGION" /dev/null 2>/dev/null | tr -d '\r' | grep -av -e '^Starting session' -e '^Exiting session' || true)
    printf '%s\n' "$out"
    case "$out" in *ERROR:*) return 3 ;; esac
  fi
}

STATUS_SQL="SELECT 'held: ' || held, 'last change: ' || coalesce(last_change || ' at ' || to_char(last_change_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '-'),
  'grace: ' || grace, 'heal due at: ' || coalesce(to_char(heal_due_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '-') || CASE WHEN heal_due THEN ' (DUE NOW)' ELSE '' END,
  'last heal: ' || coalesce(to_char(last_heal_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC — ' || last_heal_status, '-')
  || CASE WHEN healing_since IS NOT NULL THEN ' | healing since ' || healing_since ELSE '' END
  FROM ops.sandbox_hold_status WHERE id_enterprise = $SENT;"

heal() {  # heal <force 0|1> <why>
  local rc=0
  SANDBOX_HEAL_FORCE="$1" SKIP_FANOUT_EMIT="${SKIP_FANOUT_EMIT:-1}" bash "$HERE/provision-sandbox-tenant.sh" --heal || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[sandbox-session] heal FAILED (rc=$rc, $2) — hold stays on; the next tick retries" >&2
    run_sql "SELECT ops.sandbox_heal_end($SENT, false, $(printf "'%s'" "$2 rc=$rc"));" >/dev/null || true
    return "$rc"
  fi
  echo "[sandbox-session] healed ($2):"
  run_sql "$STATUS_SQL"
}

interval_arg() {  # "8h" | "90m" | "2 days" → a postgres interval literal
  local v="${1:?missing duration, e.g. 8h, 90m, 2d}"
  v=$(printf '%s' "$v" | sed -E 's/^([0-9]+)h$/\1 hours/; s/^([0-9]+)m$/\1 minutes/; s/^([0-9]+)d$/\1 days/')
  printf "'%s'" "${v//\'/}"
}

case "${1:-status}" in
  status)
    run_sql "$STATUS_SQL" ;;
  extend)
    run_sql "UPDATE ops.sandbox_state SET hold_until = greatest(coalesce(hold_until, now()), now() + interval $(interval_arg "${2:-}")), updated_at = now() WHERE id_enterprise = $SENT;" >/dev/null
    run_sql "$STATUS_SQL" ;;
  grace)
    run_sql "UPDATE ops.sandbox_state SET grace = interval $(interval_arg "${2:-}"), updated_at = now() WHERE id_enterprise = $SENT;" >/dev/null
    run_sql "$STATUS_SQL" ;;
  heal-now)
    heal 1 "heal-now" ;;
  tick)
    due=$(run_sql "SELECT coalesce((SELECT heal_due FROM ops.sandbox_hold_status WHERE id_enterprise = $SENT), false);" | tail -1 | tr -d ' ')
    if [ "$due" = "t" ]; then heal 0 "grace period over"; else echo "[sandbox-session] tick: nothing due"; fi ;;
  nightly)
    held=$(run_sql "SELECT ops.sandbox_held($SENT) AND NOT coalesce((SELECT heal_due FROM ops.sandbox_hold_status WHERE id_enterprise = $SENT), false);" | tail -1 | tr -d ' ')
    if [ "$held" = "t" ]; then
      echo "[sandbox-session] nightly: a hands-on session is HELD — skipping (it heals when its grace period ends)"
      run_sql "$STATUS_SQL"
    else
      heal 0 "nightly"
    fi ;;
  *)
    sed -n '2,27p' "$0"; exit 2 ;;
esac
