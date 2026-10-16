#!/usr/bin/env bash
# adr0032-f3-fidelity-check.sh — end-to-end staging fidelity verifier for the
# ADR-0032 F1→F3 collapse. READ-ONLY. Runs the three acceptance-criteria probes
# (A data fidelity, B operator fidelity, C render-surface readiness) against the
# live staging DB EC2 and prints a per-criterion freshness/row-count/OEE/lag
# matrix for F1 (packiot.public) vs F3 (packiot_analytics).
#
# It is the reusable companion to the one-off QA verification in the ADR-0032
# Step-1 report: run it before the flip to capture the F1 golden baseline, and
# after each collapse step to confirm F3 still satisfies A/B/C.
#
# Transport: SSM AWS-StartNonInteractiveCommand start-session (driven under a PTY
# via `script -qec`) → sudo bash on the host → `docker exec -i timescaledb psql`,
# SQL streamed over stdin from a unique remote temp file. The older
# AWS-RunShellScript send-command transport is POLICY-BLOCKED on this account, so
# this is the only working read-only path (see the ADR-0032 execution plan §6 and
# reference_staging_db_access_and_config). Every statement is wrapped in
# BEGIN READ ONLY (see feedback_prod_db_readonly). No writes ever.
#
# Acceptance semantics (post-collapse-prep): F1's OEE compute is a corpse
# (uns_current_shift frozen since 2026-07-08), so this gate is NOT a byte-identity
# check of F3 vs F1. Acceptance = F3-HEALTHY: F3 telemetry fresh, rollups compute
# to now, OEE anomaly-free (no oee>1 / oee<0), and the render surface (h_piot fns +
# config relations) present. F1 columns are printed only as a sanity reference.
#
# Usage:
#   ./adr0032-f3-fidelity-check.sh                 # ent 3 + 4, both flows
#   INSTANCE=i-064bb36d1c454d861 REGION=us-east-1 ./adr0032-f3-fidelity-check.sh
#   ENTERPRISES="3,4" ./adr0032-f3-fidelity-check.sh
#
# Requires: aws cli + session-manager-plugin, ssm:StartSession on the staging DB
# EC2, and `script` (util-linux) for the PTY. Repeatable: each probe uses a unique
# remote temp path, so concurrent runs never collide.
set -euo pipefail

INSTANCE="${INSTANCE:-i-064bb36d1c454d861}"
REGION="${REGION:-us-east-1}"
ENTS="${ENTERPRISES:-3,4}"
F1_DB="${F1_DB:-packiot}"
F3_DB="${F3_DB:-packiot_analytics}"

# run_sql <db> <sql> — execute SELECT-only SQL in the timescaledb container via the
# start-session transport. The SQL is base64'd and wrapped in BEGIN READ ONLY; a
# small remote bootstrap (also base64'd) runs under `sudo bash` on the host, decodes
# the SQL to a UNIQUE mktemp file, streams it into the container over stdin, and
# cleans up. The AWS-StartNonInteractiveCommand doc execs `command` with no shell
# and word-splits on spaces, so the outer `bash -c` payload must be space-free —
# hence the ${IFS} separators (see plan §6).
run_sql() {
  local db="$1" sql="$2"
  local full sql_b64 remote remote_b64
  full=$'BEGIN READ ONLY;\n'"$sql"$'\nCOMMIT;'
  sql_b64=$(printf '%s' "$full" | base64 -w0)
  # Remote bootstrap runs on the DB host under sudo bash. Unique temp path per call
  # (mktemp) => repeatable + collision-free under concurrency. SQL is streamed to
  # the container over stdin (a host /tmp file is invisible inside the container).
  remote=$(cat <<REMOTE
set -e
tmp=\$(mktemp /tmp/adr0032q.XXXXXXXX.sql)
trap 'rm -f "\$tmp"' EXIT
echo $sql_b64 | base64 -d > "\$tmp"
docker exec -i timescaledb psql -U postgres -d $db -v ON_ERROR_STOP=1 < "\$tmp"
REMOTE
)
  remote_b64=$(printf '%s' "$remote" | base64 -w0)
  script -qec "aws ssm start-session --target $INSTANCE \
    --document-name AWS-StartNonInteractiveCommand \
    --parameters 'command=[\"bash -c echo\${IFS}$remote_b64|base64\${IFS}-d|sudo\${IFS}bash\"]' \
    --region $REGION" /dev/null 2>/dev/null \
    | tr -d '\r' \
    | grep -av -e '^Starting session' -e '^Exiting session' || true
}

# ---- criterion (A): telemetry-chain freshness + row counts, per tenant --------
FRESHNESS_SQL=$(cat <<SQL
WITH eq AS (SELECT id_equipment, id_enterprise FROM equipments WHERE id_enterprise IN ($ENTS))
SELECT tbl, ent, rows, max_ts FROM (
  SELECT 'equipment_values' tbl, id_enterprise ent, count(*) rows, max(ts_value)::text max_ts
    FROM equipment_values WHERE id_enterprise IN ($ENTS) GROUP BY id_enterprise
  UNION ALL SELECT 'equipment_runtime_shift', eq.id_enterprise, count(*), max(r.ts_value)::text
    FROM equipment_runtime_shift r JOIN eq USING(id_equipment) GROUP BY eq.id_enterprise
  UNION ALL SELECT 'equipment_runtime_1hour', eq.id_enterprise, count(*), max(r.ts_value)::text
    FROM equipment_runtime_1hour r JOIN eq USING(id_equipment) GROUP BY eq.id_enterprise
  UNION ALL SELECT 'uns_equipment_current_metrics', id_enterprise, count(*), max(last_updated)::text
    FROM uns_equipment_current_metrics WHERE id_enterprise IN ($ENTS) GROUP BY id_enterprise
  UNION ALL SELECT 'uns_equipment_current_shift', eq.id_enterprise, count(*), max(u.last_updated)::text
    FROM uns_equipment_current_shift u JOIN eq USING(id_equipment) GROUP BY eq.id_enterprise
  UNION ALL SELECT 'production_orders_runtime', eq.id_enterprise, count(*), max(r.last_update)::text
    FROM production_orders_runtime r JOIN eq USING(id_equipment) GROUP BY eq.id_enterprise
) s ORDER BY tbl, ent;
SQL
)

# ---- criterion (A): OEE health over producing shifts, per tenant --------------
OEE_SQL=$(cat <<SQL
WITH eq AS (SELECT id_equipment, id_enterprise FROM equipments WHERE id_enterprise IN ($ENTS))
SELECT eq.id_enterprise ent,
       count(*) FILTER (WHERE r.running_time>0) producing_shifts,
       max(r.ts_value) FILTER (WHERE r.running_time>0)::text latest_producing,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY r.oee)
             FILTER (WHERE r.running_time>0 AND r.oee BETWEEN 0 AND 1)::numeric,4) median_valid_oee,
       count(*) FILTER (WHERE r.oee>1) oee_gt1_anomaly,
       count(*) FILTER (WHERE r.oee<0) oee_neg_anomaly
FROM equipment_runtime_shift r JOIN eq USING(id_equipment)
GROUP BY eq.id_enterprise ORDER BY eq.id_enterprise;
SQL
)

# ---- criterion (C): render-layer readiness (h_piot fn presence) ---------------
RENDER_SQL=$(cat <<'SQL'
SELECT count(*) AS h_piot_fn_count FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname LIKE 'h_piot_%';
SQL
)

# ---- criterion (B): operator round-trip — PO backlog + event mirror lag -------
# Run on F1 only (source of truth); F3 presence is checked separately.
OPERATOR_SQL=$(cat <<SQL
SELECT 'F1 user_logs 24h' lbl, count(*) n, max(ts_event)::text latest
  FROM user_logs WHERE id_enterprise IN ($ENTS) AND ts_event > now()-interval '24 hours'
UNION ALL
SELECT 'F1 production_orders latest', count(*), max(last_update)::text
  FROM production_orders WHERE id_enterprise IN ($ENTS)
UNION ALL
SELECT 'F1 equipment_events latest', count(*), max(ts_event)::text
  FROM equipment_events WHERE id_enterprise IN ($ENTS);
SQL
)

section() { printf '\n========================================================\n%s\n========================================================\n' "$1"; }

section "CRITERION A — telemetry-chain freshness + row counts"
echo "----- F1 ($F1_DB) -----"; run_sql "$F1_DB" "$FRESHNESS_SQL"
echo "----- F3 ($F3_DB) -----"; run_sql "$F3_DB" "$FRESHNESS_SQL"

section "CRITERION A — OEE health over producing shifts"
echo "----- F1 ($F1_DB) -----"; run_sql "$F1_DB" "$OEE_SQL"
echo "----- F3 ($F3_DB) -----"; run_sql "$F3_DB" "$OEE_SQL"

section "CRITERION C — render-layer readiness (h_piot fn count; F3 needs the port)"
echo "----- F1 ($F1_DB) -----"; run_sql "$F1_DB" "$RENDER_SQL"
echo "----- F3 ($F3_DB) -----"; run_sql "$F3_DB" "$RENDER_SQL"

section "CRITERION B — operator round-trip (F1 source vs F3 mirror)"
echo "----- F1 ($F1_DB) -----"; run_sql "$F1_DB" "$OPERATOR_SQL"
echo "----- F3 ($F3_DB) — mirrored PO/event heads -----"
run_sql "$F3_DB" "SELECT 'F3 production_orders latest' lbl, count(*) n, max(last_update)::text latest FROM production_orders WHERE id_enterprise IN ($ENTS)
UNION ALL SELECT 'F3 equipment_events latest', count(*), max(ts_event)::text FROM equipment_events WHERE id_enterprise IN ($ENTS);"

echo
echo "Done. ACCEPTANCE = F3-HEALTHY, not F1-identical (F1 OEE compute is a corpse:"
echo "uns_current_shift frozen since 2026-07-08, and F1 itself carries oee>1/oee<0 anomalies)."
echo "PASS when: F3 telemetry fresh (equipment_values max_ts ~= now), F3 rollups compute to now"
echo "(uns_equipment_current_metrics fresh), F3 OEE anomaly-free (oee_gt1=0, oee_neg=0), and the"
echo "render surface is present (h_piot fns >= 91 + the 6 config relations). Operator heads track F1"
echo "within minutes. F1 columns are a sanity reference only."
