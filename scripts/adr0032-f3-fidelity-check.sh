#!/usr/bin/env bash
# adr0032-f3-fidelity-check.sh — end-to-end staging fidelity verifier for the
# ADR-0032 F1→F3 collapse. READ-ONLY. Runs the three acceptance-criteria probes
# (A data fidelity, B operator fidelity, C render-surface readiness) against the
# live staging DB EC2 and prints a per-criterion freshness/row-count/OEE/lag
# matrix for F1 (packiot.public) vs F3 (packiot_shadow).
#
# It is the reusable companion to the one-off QA verification in the ADR-0032
# Step-1 report: run it before the flip to capture the F1 golden baseline, and
# after each collapse step to confirm F3 still satisfies A/B/C.
#
# Transport: SSM RunShellScript → docker exec timescaledb psql. Every statement
# is wrapped in BEGIN READ ONLY (see feedback_prod_db_readonly). No writes ever.
#
# Usage:
#   ./adr0032-f3-fidelity-check.sh                 # ent 3 + 4, both flows
#   INSTANCE=i-064bb36d1c454d861 REGION=us-east-1 ./adr0032-f3-fidelity-check.sh
#   ENTERPRISES="3,4" ./adr0032-f3-fidelity-check.sh
#
# Requires: aws cli with ssm:SendCommand on the staging DB EC2.
set -euo pipefail

INSTANCE="${INSTANCE:-i-064bb36d1c454d861}"
REGION="${REGION:-us-east-1}"
ENTS="${ENTERPRISES:-3,4}"
F1_DB="${F1_DB:-packiot}"
F3_DB="${F3_DB:-packiot_shadow}"

# run_sql <db> <sql> — execute SELECT-only SQL in the timescaledb container via SSM.
run_sql() {
  local db="$1" sql="$2"
  local full sql_b64 remote cmd_id st
  full=$'BEGIN READ ONLY;\n'"$sql"$'\nCOMMIT;'
  sql_b64=$(printf '%s' "$full" | base64 -w0)
  remote="echo $sql_b64 | base64 -d > /tmp/adr0032q.sql; docker cp /tmp/adr0032q.sql timescaledb:/tmp/adr0032q.sql >/dev/null; docker exec -i timescaledb psql -U postgres -d $db -v ON_ERROR_STOP=1 -f /tmp/adr0032q.sql"
  cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
    --comment "ADR-0032 F3 fidelity check (READ ONLY)" \
    --parameters commands="[\"$remote\"]" --region "$REGION" \
    --query 'Command.CommandId' --output text)
  for _ in $(seq 1 90); do
    st=$(aws ssm list-command-invocations --command-id "$cmd_id" --region "$REGION" \
         --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo Pending)
    case "$st" in Success|Failed|TimedOut|Cancelled) break;; esac
    sleep 2
  done
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE" \
    --region "$REGION" --query 'StandardOutputContent' --output text
  if [ "$st" != Success ]; then
    aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE" \
      --region "$REGION" --query 'StandardErrorContent' --output text >&2
    echo "!! SSM status=$st for db=$db" >&2
  fi
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
echo "Done. Compare F1 vs F3 heads: F3 telemetry should be >= F1 fresh (F1 OEE compute is retired);"
echo "F3 h_piot_fn_count << F1 until the read-plane port lands (Step 1); operator heads should track within minutes."
