#!/usr/bin/env bash
# powerbi-evidence-prod-read.sh — regenerate the prod-read fidelity
# evidence for the PowerBI gate sign-off (06-state §5 gate #1).
#
# For each ported report writer, computes the would-be rows AGAINST
# PROD INPUTS (SELECT-only, BEGIN READ ONLY, awslambda role) and
# compares them with prod's live report table — the same comparison
# that scored 1197/1197 (shift06) and 63/68 (speed33) at port time.
#
# HARD RULE honored: prod is SELECT-only, always. Everything runs in
# one READ ONLY transaction; a write attempt aborts the tx.
#
# Output: docs/powerbi-evidence-prod-read.md (evidence for the human
# sign-off — attach to the gate checklist).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
OUT="${REPO_ROOT}/docs/powerbi-evidence-prod-read.md"

SECRET=$(aws secretsmanager get-secret-value --secret-id databaseCredentials \
    --region us-east-1 --query SecretString --output text)
export PGHOST=$(jq -r .DB_HOST <<<"$SECRET") \
       PGPORT=$(jq -r .DB_PORT <<<"$SECRET") \
       PGUSER=$(jq -r .DB_USER <<<"$SECRET") \
       PGPASSWORD=$(jq -r .DB_PASSWORD <<<"$SECRET") \
       PGDATABASE=$(jq -r .DB_NAME <<<"$SECRET")

echo "[1/2] running read-only fidelity comparison on prod (${PGDATABASE})..."
RESULT=$(psql -tA -v ON_ERROR_STOP=1 <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout = '10min';

-- ── speed33: port's computed set vs prod's live table (5-day window) ──
WITH data AS (
    SELECT id_equipment, ts_value, speed, net_production_incr
    FROM equipment_values
    WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = 33 AND tp_equipment = 3)
      AND id_enterprise = 33
      AND ts_value >= NOW() - INTERVAL '5 day'
      AND speed >= 150
      AND net_production_val IS NOT NULL
), computed AS (
    SELECT po.id_order,
           AVG(d.speed)::NUMERIC(4,1) AS avg_speed,
           SUM(d.net_production_incr)::BIGINT AS final_net
    FROM production_orders po
    JOIN data d ON po.id_equipment = d.id_equipment
    WHERE d.ts_value >= po.ts_start AND d.ts_value < po.ts_end
      AND po.id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = 33 AND tp_equipment = 3)
      AND po.ts_start >= NOW() - INTERVAL '5 day'
      AND po.status > 2
    GROUP BY po.id_equipment, po.id_order, po.id_product, po.production_programmed,
             po.production_final, po.ts_start
), live AS (
    SELECT id_order, avg_speed, final_net
    FROM report_speed_enterprsie_33
    WHERE job_start >= NOW() - INTERVAL '5 day'
)
SELECT 'SPEED33 computed=' || (SELECT count(*) FROM computed)
    || ' live=' || (SELECT count(*) FROM live)
    || ' joined=' || count(*)
    || ' exact=' || count(*) FILTER (WHERE c.avg_speed = l.avg_speed AND c.final_net = l.final_net)
FROM computed c JOIN live l USING (id_order);

-- ── shift06: live compute chain (06c) vs prod's live table (21 days) ──
WITH computed AS (
    SELECT md5(t::text) AS h
    FROM get_report_shift_enterprsie_06c(
        ((now() AT TIME ZONE 'America/Montreal')::date - 21),
        ((now() AT TIME ZONE 'America/Montreal')::date + 1)) t
), live AS (
    SELECT md5(r::text) AS h FROM report_shift_enterprsie_06 r
)
SELECT 'SHIFT06 computed=' || (SELECT count(*) FROM computed)
    || ' live=' || (SELECT count(*) FROM live)
    || ' exact=' || (SELECT count(*) FROM computed c JOIN live l USING (h));

ROLLBACK;
SQL
)

echo "[2/2] writing $OUT"
python3 - "$OUT" <<PYEOF
import sys, datetime
out = sys.argv[1]
result = """$RESULT"""
lines = [l.strip() for l in result.splitlines() if l.strip()]
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%MZ')
with open(out, "w") as f:
    f.write("# PowerBI gate — prod-read fidelity evidence\n\n")
    f.write(f"- Generated: {stamp} by scripts/powerbi-evidence-prod-read.sh\n")
    f.write("- Method: ported writers' computation re-run against PROD inputs\n")
    f.write("  (BEGIN READ ONLY, awslambda), compared with prod's live report\n")
    f.write("  tables. Port-time baselines: shift06 1197/1197 rows (1180 exact,\n")
    f.write("  98.6% — remainder is the moving-base artifact class), speed33 63/68.\n\n")
    for l in lines:
        f.write(f"- \`{l}\`\n")
    f.write("\n- Non-exact remainders are expected from the moving-base artifact\n")
    f.write("  class (prod keeps writing while we read; see PORTING.md artifact\n")
    f.write("  taxonomy). Sign-off threshold: joined/exact ratios consistent with\n")
    f.write("  port-time baselines.\n")
print("evidence written")
PYEOF

echo "done"
