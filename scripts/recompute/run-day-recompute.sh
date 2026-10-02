#!/usr/bin/env bash
# run-day-recompute.sh — run a rendered history-recompute template, one transaction per UTC day.
#
# The template comes from `go run ./cmd/recompute-render` (services/stream-engine) — re-render it
# from CURRENT code before every repair; never reuse an old file. Runbook:
# docs/runbooks/history-recompute.md.
#
# DRY RUN BY DEFAULT: every day ends in ROLLBACK and prints the eligible counts. Only --commit
# writes. Stops at the first day that errors or does not reach COMMIT/ROLLBACK.
#
# Usage:
#   scripts/recompute/run-day-recompute.sh --template T.sql --flag-sql F.sql [--commit] [--log L] DAY...
#   scripts/recompute/run-day-recompute.sh --template T.sql --no-flag ... DAY...
#     DAY        YYYY-MM-DD (UTC); the window is [DAY 00:00, DAY+1 00:00) UTC
#     --flag-sql scope SQL that sets recalc_needed=true on the hour/shift rows to rebuild; may use
#                __FROM__/__TO__. Spliced INSIDE the day's transaction (after the engine locks), so
#                no live pass can drain a half-flagged day. See scripts/recompute/flag-example.sql.
#     --no-flag  only rebuild rows that are already flagged in the window
#     --commit   COMMIT each day (default: ROLLBACK)
#     --log      append one line per day (default: recompute-<UTC timestamp>.log in the cwd)
#
# Transport: SSM AWS-RunShellScript on the DB host → `docker exec timescaledb psql`. The SQL
# travels gzip+base64 in the command (no credentials anywhere — psql runs as the container's
# local postgres). One SSM command per day: the SSM execution timeout is 1 h, so a long multi-day
# run must be started with nohup from a shell that outlives your session, never one big command.
#
# Env: DB_INSTANCE (default i-064bb36d1c454d861, staging DB host), REGION (us-east-1),
#      DB (packiot_analytics), WAIT (seconds to wait per day, default 3000).
set -euo pipefail

DB_INSTANCE="${DB_INSTANCE:-i-064bb36d1c454d861}"
REGION="${REGION:-us-east-1}"
DB="${DB:-packiot_analytics}"
WAIT="${WAIT:-3000}"

tpl=""; flag=""; noflag=0; mode=ROLLBACK; log="recompute-$(date -u +%Y%m%dT%H%M%SZ).log"; days=()
while [ $# -gt 0 ]; do
  case "$1" in
    --template) tpl="$2"; shift 2;;
    --flag-sql) flag="$2"; shift 2;;
    --no-flag)  noflag=1; shift;;
    --commit)   mode=COMMIT; shift;;
    --log)      log="$2"; shift 2;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0;;
    -*)         echo "unknown option $1" >&2; exit 2;;
    *)          days+=("$1"); shift;;
  esac
done
[ -n "$tpl" ] && [ -f "$tpl" ] || { echo "--template <rendered file> required" >&2; exit 2; }
grep -q '^-- @@FLAG_SQL@@$' "$tpl" || { echo "$tpl has no flag marker — not a recompute-render template" >&2; exit 2; }
grep -q '^__END__;$' "$tpl" || { echo "$tpl has no __END__ placeholder — not a recompute-render template" >&2; exit 2; }
if [ "$noflag" = 0 ]; then
  [ -n "$flag" ] && [ -f "$flag" ] || { echo "--flag-sql <file> or --no-flag required" >&2; exit 2; }
fi
[ "${#days[@]}" -gt 0 ] || { echo "at least one DAY required" >&2; exit 2; }
for day in "${days[@]}"; do
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -u -d "$day" >/dev/null 2>&1 \
    || { echo "bad DAY $day (want YYYY-MM-DD)" >&2; exit 2; }
done

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
echo "# $(date -u +%FT%TZ) mode=$mode template=$tpl flag=${flag:-none} db=$DB instance=$DB_INSTANCE" >> "$log"
[ "$mode" = COMMIT ] || echo "DRY RUN (ROLLBACK). Re-run with --commit to write." >&2

ssm_psql() { # $1 = sql file; prints psql stdout+stderr
  local b64 params id st
  b64=$(gzip -9c "$1" | base64 -w0)
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":["3600"]}))' \
    "echo $b64 | base64 -d | gunzip | docker exec -i timescaledb psql -U postgres -d $DB -v ON_ERROR_STOP=1 -At -F'|' 2>&1")
  id=$(aws ssm send-command --region "$REGION" --instance-ids "$DB_INSTANCE" --document-name AWS-RunShellScript \
       --parameters "$params" --query Command.CommandId --output text)
  for _ in $(seq 1 "$WAIT"); do
    st=$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$DB_INSTANCE" \
         --query Status --output text 2>/dev/null || echo Pending)
    case "$st" in Success|Failed|Cancelled|TimedOut) break;; esac
    sleep 1
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$DB_INSTANCE" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text
}

for day in "${days[@]}"; do
  from="$day 00:00:00+00"; to="$(date -u -d "$day + 1 day" +%F) 00:00:00+00"
  : > "$work/flag.sql"
  [ "$noflag" = 0 ] && sed -e "s/__FROM__/$from/g" -e "s/__TO__/$to/g" "$flag" > "$work/flag.sql"
  # Splice the flag SQL at the marker, fill the window, close with COMMIT or ROLLBACK.
  awk -v f="$work/flag.sql" '$0 == "-- @@FLAG_SQL@@" { while ((getline l < f) > 0) print l; next } { print }' "$tpl" \
    | sed -e "s/__FROM__/$from/g" -e "s/__TO__/$to/g" -e "s/^__END__;\$/$mode;/" > "$work/day.sql"
  t0=$(date +%s)
  out=$(ssm_psql "$work/day.sql" || true)
  ended=$(printf '%s\n' "$out" | grep -c "^$mode\$" || true)
  err=$(printf '%s\n' "$out" | grep -m1 -E 'ERROR|FATAL' || true)
  counts=$(printf '%s\n' "$out" | grep -E '^n_' | tr '\n' ' ')
  echo "$day mode=$mode ended=$ended secs=$(( $(date +%s) - t0 )) $counts $err" | tee -a "$log"
  if [ -n "$err" ] || [ "$ended" -lt 1 ]; then
    echo "STOPPED at $day" | tee -a "$log"
    exit 1
  fi
done
echo DONE | tee -a "$log"
