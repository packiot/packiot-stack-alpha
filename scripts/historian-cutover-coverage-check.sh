#!/usr/bin/env bash
# historian-cutover-coverage-check.sh — CI / boot assertion for the hist_cutover invariant.
#
# INVARIANT (load-bearing, see services/historian-gateway/docker-entrypoint-initdb.d/
# 10-historian-gateway.sh): every enterprise that has at least one *-legacy.parquet in the
# COLD archive MUST have a row in hist_cutover. The ev_all view is a LEFT JOIN of the live
# (HOT) FDW against hist_cutover; a MISSING cutover row makes the join keep ALL of that
# enterprise's live rows AND ALL of its cold rows in the archived window => silent
# hot/cold DOUBLE-COUNT (proven: ent3 352,136 -> 196,671 after the boundary was seeded).
#
# WHY A SEPARATE CHECK (not folded into refresh-hist-cutover.sql): the refresh runs an
# UNFILTERED `INSERT ... SELECT id_enterprise, max(ts_value) FROM hist GROUP BY 1 ON
# CONFLICT DO UPDATE`, so immediately AFTER it every hist enterprise trivially has a row —
# a post-refresh in-SQL assertion would always pass and is near-useless. The real failure
# modes are (a) a NEW *-legacy prefix appended without a subsequent refresh, and (b) a
# hand-run refresh that was accidentally filtered (`WHERE id_enterprise = N`). Both leave
# hist_cutover STALE relative to the archive on disk — which is exactly what this check
# detects, by comparing the S3 archive against the CURRENT hist_cutover, independent of
# any refresh.
#
# METADATA-ONLY BY DESIGN: it lists S3 keys (`aws s3 ls`) and reads the tiny hist_cutover
# table — it NEVER scans the Parquet. (A `SELECT DISTINCT id_enterprise FROM hist` costs a
# full ~96s cold scan and, wrapped in CTAS, crashes the pg_duckdb backend — do not do that.)
#
# Run ON the gateway box (has both `aws` and `docker exec hist-gateway`), e.g. from the
# append job's post-run hook right after refresh-hist-cutover.sql, or in CI via SSM.
# Exit 0 = covered; exit 1 = coverage violation (lists the offending enterprises).
#
#   HISTORIAN_BUCKET   S3 historian bucket (default: derive per env)
#   GATEWAY_CONTAINER  docker container name (default: hist-gateway)
set -euo pipefail

BUCKET="${HISTORIAN_BUCKET:?set HISTORIAN_BUCKET (e.g. packiot-staging-historian-639178078294)}"
CONTAINER="${GATEWAY_CONTAINER:-hist-gateway}"

# 1) Enterprises present in the COLD archive == those with >=1 *-legacy.parquet under
#    equipment_values/. (data-*.parquet daily appends are Athena-only, NOT on the cold
#    ev_all glob, so an enterprise with ONLY data-*.parquet is correctly NOT required to
#    have a cutover row — e.g. the enterprise=5 append-only partition.)
s3_ents="$(aws s3 ls "s3://$BUCKET/equipment_values/" --recursive \
  | grep -- '-legacy.parquet' \
  | grep -oE 'enterprise=[0-9]+' | grep -oE '[0-9]+' | sort -un)"

# 2) Enterprises that currently have a hist_cutover row.
cut_ents="$(docker exec -i "$CONTAINER" psql -U postgres -d postgres -tAc \
  'SELECT id_enterprise FROM hist_cutover ORDER BY 1' | sed '/^$/d' | sort -un)"

# 3) missing = in the cold archive but NOT in hist_cutover.
missing="$(comm -23 <(printf '%s\n' "$s3_ents") <(printf '%s\n' "$cut_ents") | sed '/^$/d')"

n_arch="$(printf '%s\n' "$s3_ents" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ -n "$missing" ]; then
  echo "COVERAGE VIOLATION: cold-archive enterprise(s) with NO hist_cutover row (ev_all DOUBLE-COUNT risk):" >&2
  printf '  enterprise=%s\n' $missing >&2
  echo "Fix: run services/historian-gateway/refresh-hist-cutover.sql (UNFILTERED) on the gateway." >&2
  exit 1
fi
echo "hist_cutover coverage OK: all $n_arch cold-archive enterprise(s) have a cutover row."
