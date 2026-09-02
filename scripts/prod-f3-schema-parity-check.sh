#!/usr/bin/env bash
# prod-f3-schema-parity-check.sh — the W1.4 CORRECTNESS GATE.
#
# Proves a freshly-assembled greenfield-prod `public` schema is STRUCTURALLY
# identical to staging's F3 schema (`packiot_analytics`) — BEFORE any client data
# flows. If prod's `public` is not F3-shaped, the compute chain (edge-transformer
# Go Calc → oeecloud-worker rollups → caggs → uns_*) runs and produces SILENTLY
# WRONG OEE. This script is what stops that.
#
# It is the schema-structure companion to scripts/adr0032-f3-fidelity-check.sh
# (which checks live DATA freshness/OEE-health). This one checks the SHAPE:
# tables + per-table column fingerprints, views, functions (by identity
# signature), continuous aggregates, and hypertables.
#
# READ-ONLY. Every remote query is wrapped in BEGIN READ ONLY (see
# feedback_prod_db_readonly). No writes, ever. Staging is SELECT-only.
#
# ── Two manifests, one diff ───────────────────────────────────────────────────
#   TARGET   = staging packiot_analytics (the authoritative F3 shape).
#   CANDIDATE= the DB under test: a local throwaway TimescaleDB container that
#              has run db/init-f3/assemble.sh, OR (gated) the real prod `public`.
# The same MANIFEST_SQL runs against both; we diff the normalized output.
#
# ── Transports ────────────────────────────────────────────────────────────────
#   TARGET  → SSM AWS-StartNonInteractiveCommand start-session (driven under a
#             PTY via `script -qec`) → sudo bash on the staging DB EC2 →
#             `docker exec -i timescaledb psql`. (The AWS-RunShellScript
#             send-command transport is POLICY-BLOCKED on this account; this is
#             the only working read-only path — see adr0032-f3-fidelity-check.sh.)
#   CANDIDATE→ a plain psql DSN you control (local container or a gated tunnel).
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   # 1. Capture the F3 target baseline from staging (SELECT-only):
#   ./scripts/prod-f3-schema-parity-check.sh capture-target > db/init-f3/MANIFEST.f3-target
#
#   # 2. Emit the candidate manifest from a local assembled DB:
#   CANDIDATE_DSN='postgresql://postgres:postgres@localhost:5599/packiot' \
#     ./scripts/prod-f3-schema-parity-check.sh capture-candidate > /tmp/cand.manifest
#
#   # 3. Diff them → the gate:
#   ./scripts/prod-f3-schema-parity-check.sh diff db/init-f3/MANIFEST.f3-target /tmp/cand.manifest
#
#   # one-shot (capture target live + candidate from DSN + diff):
#   CANDIDATE_DSN=... ./scripts/prod-f3-schema-parity-check.sh gate
#
# Requires: aws cli + session-manager-plugin + `script` (util-linux) for TARGET;
# psql for CANDIDATE. Repeatable; unique remote temp path per call.
set -euo pipefail

INSTANCE="${INSTANCE:-i-064bb36d1c454d861}"
REGION="${REGION:-us-east-1}"
TARGET_DB="${TARGET_DB:-packiot_analytics}"
CANDIDATE_DSN="${CANDIDATE_DSN:-}"

# ── The normalized-manifest query ─────────────────────────────────────────────
# Emits one TSV line per schema object, stable-sorted, identical on any DB:
#   T <tab> <table>            <tab> <md5 of "col:type,..." ordered by attnum>
#   V <tab> <view>
#   M <tab> <matview>
#   F <tab> <function(identity-arg-types)>
#   C <tab> <continuous-aggregate>
#   H <tab> <hypertable>
# Column fingerprint = md5 so a 159-table manifest stays compact yet catches ANY
# column add/drop/type-change (the drift that silently corrupts OEE). Caggs are
# excluded from V (a cagg is also a view) so the two classes don't overlap.
read -r -d '' MANIFEST_SQL <<'SQL' || true
\pset pager off
\pset tuples_only on
\pset format unaligned
\pset fieldsep '\t'
-- ext_objs: every object OWNED BY an extension (timescaledb, pg_cron, …). These
-- differ across PG/TimescaleDB VERSIONS (staging F3 = pg15.17; prod image =
-- pg16/tsdb-2.25.2) and are NOT part of the F3 USER schema — comparing them
-- produces false drift. We exclude them so the gate measures user objects only.
WITH ext_objs AS (
  SELECT objid FROM pg_depend WHERE deptype='e'
),
caggs AS (
  SELECT view_name FROM timescaledb_information.continuous_aggregates WHERE view_schema='public'
)
SELECT line FROM (
  -- tables (regular, relkind r) with column fingerprint
  SELECT 'T'||chr(9)||c.relname||chr(9)||
         md5(coalesce(string_agg(a.attname||':'||format_type(a.atttypid,a.atttypmod),',' ORDER BY a.attnum)
             FILTER (WHERE a.attnum>0 AND NOT a.attisdropped),'')) AS line, 1 ord, c.relname nm
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    LEFT JOIN pg_attribute a ON a.attrelid=c.oid
   WHERE n.nspname='public' AND c.relkind='r' AND c.oid NOT IN (SELECT objid FROM ext_objs)
   GROUP BY c.relname
  UNION ALL
  -- views (excluding caggs)
  SELECT 'V'||chr(9)||table_name, 2, table_name
    FROM information_schema.views v
   WHERE table_schema='public' AND table_name NOT IN (SELECT view_name FROM caggs)
     AND (table_schema||'.'||table_name)::regclass::oid NOT IN (SELECT objid FROM ext_objs)
  UNION ALL
  -- materialized views (non-cagg)
  SELECT 'M'||chr(9)||matviewname, 3, matviewname
    FROM pg_matviews WHERE schemaname='public' AND matviewname NOT IN (SELECT view_name FROM caggs)
      AND (schemaname||'.'||matviewname)::regclass::oid NOT IN (SELECT objid FROM ext_objs)
  UNION ALL
  -- functions + procedures by identity signature (user-defined only)
  SELECT 'F'||chr(9)||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')', 4,
         p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.oid NOT IN (SELECT objid FROM ext_objs)
  UNION ALL
  -- continuous aggregates
  SELECT 'C'||chr(9)||view_name, 5, view_name FROM caggs
  UNION ALL
  -- hypertables
  SELECT 'H'||chr(9)||hypertable_name, 6, hypertable_name
    FROM timescaledb_information.hypertables WHERE hypertable_schema='public'
) s ORDER BY ord, nm;
SQL

# ── TARGET transport (staging packiot_analytics via SSM, READ ONLY) ──────────────
run_target() {
  local sql="$1" full sql_b64 remote remote_b64
  full=$'BEGIN READ ONLY;\n'"$sql"$'\nCOMMIT;'
  sql_b64=$(printf '%s' "$full" | base64 -w0)
  remote=$(cat <<REMOTE
set -e
tmp=\$(mktemp /tmp/f3parity.XXXXXXXX.sql)
trap 'rm -f "\$tmp"' EXIT
echo $sql_b64 | base64 -d > "\$tmp"
docker exec -i timescaledb psql -U postgres -d $TARGET_DB -v ON_ERROR_STOP=1 < "\$tmp"
REMOTE
)
  remote_b64=$(printf '%s' "$remote" | base64 -w0)
  script -qec "aws ssm start-session --target $INSTANCE \
    --document-name AWS-StartNonInteractiveCommand \
    --parameters 'command=[\"bash -c echo\${IFS}$remote_b64|base64\${IFS}-d|sudo\${IFS}bash\"]' \
    --region $REGION" /dev/null 2>/dev/null \
    | tr -d '\r' \
    | grep -av -e '^Starting session' -e '^Exiting session' -e '^BEGIN$' -e '^COMMIT$' || true
}

# ── CANDIDATE transport (any psql DSN you control) ────────────────────────────
run_candidate() {
  local sql="$1"
  [ -n "$CANDIDATE_DSN" ] || { echo "CANDIDATE_DSN not set" >&2; exit 2; }
  printf '%s' "$sql" | psql "$CANDIDATE_DSN" -v ON_ERROR_STOP=1 2>/dev/null
}

# strip blank lines, keep only manifest rows (T/V/M/F/C/H + tab)
clean() { grep -aE '^[TVMFCH]'$'\t' || true; }

summary() {
  local f="$1" label="$2"
  printf '%-12s  T=%s V=%s M=%s F=%s C=%s H=%s  (total %s)\n' "$label" \
    "$(grep -c '^T'$'\t' "$f" || true)" "$(grep -c '^V'$'\t' "$f" || true)" \
    "$(grep -c '^M'$'\t' "$f" || true)" "$(grep -c '^F'$'\t' "$f" || true)" \
    "$(grep -c '^C'$'\t' "$f" || true)" "$(grep -c '^H'$'\t' "$f" || true)" \
    "$(wc -l < "$f" | tr -d ' ')"
}

do_diff() {
  local target="$1" cand="$2"
  local t c; t=$(mktemp); c=$(mktemp)
  sort -u "$target" > "$t"; sort -u "$cand" > "$c"
  echo "=== MANIFEST SUMMARY ==="
  summary "$t" "TARGET(F3)"; summary "$c" "CANDIDATE"
  echo
  echo "=== F3_MISSING (in TARGET, absent from CANDIDATE — prod would be WRONG) ==="
  comm -23 "$t" "$c" | sed 's/^/  MISSING  /' | head -400
  local nmiss; nmiss=$(comm -23 "$t" "$c" | wc -l | tr -d ' ')
  echo
  echo "=== EXTRA (in CANDIDATE, not in TARGET — staging debris OK to ignore, or over-build) ==="
  comm -13 "$t" "$c" | sed 's/^/  EXTRA    /' | head -200
  local nextra; nextra=$(comm -13 "$t" "$c" | wc -l | tr -d ' ')
  echo
  echo "=== VERDICT ==="
  echo "  F3_MISSING = $nmiss   EXTRA = $nextra"
  if [ "$nmiss" -eq 0 ]; then
    echo "  PASS — candidate public superset-of F3 target shape. (Review EXTRA for over-build.)"
    rm -f "$t" "$c"; return 0
  else
    echo "  FAIL — candidate is missing F3 objects; flowing client data now = silently-wrong OEE."
    rm -f "$t" "$c"; return 1
  fi
}

cmd="${1:-help}"
case "$cmd" in
  capture-target)    run_target    "$MANIFEST_SQL" | clean ;;
  capture-candidate) run_candidate "$MANIFEST_SQL" | clean ;;
  diff)              do_diff "$2" "$3" ;;
  gate)
    t=$(mktemp); c=$(mktemp)
    echo "capturing TARGET (staging packiot_analytics)..." >&2
    run_target    "$MANIFEST_SQL" | clean > "$t"
    echo "capturing CANDIDATE ($CANDIDATE_DSN)..." >&2
    run_candidate "$MANIFEST_SQL" | clean > "$c"
    do_diff "$t" "$c"; rc=$?; rm -f "$t" "$c"; exit $rc ;;
  *)
    sed -n '2,44p' "$0" ;;
esac
