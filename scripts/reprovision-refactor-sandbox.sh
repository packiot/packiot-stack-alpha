#!/usr/bin/env bash
# Reprovision the packiot_refactor sandbox DB on staging DB EC2.
#
# ADR-0012 sandbox: a throwaway DB inside the running timescaledb container
# on staging DB EC2 (i-064bb36d1c454d861). Used to prove out the schema
# refactor design (multi-tenancy pool + façades + renames + drops) before
# writing real knex migrations against the production edge-api schema.
#
# Idempotent — safe to re-run. Use --reset to blow away any existing
# sandbox and rebuild from scratch.
#
# Requires: aws CLI configured, IAM permission to ssm:SendCommand +
# ssm:GetCommandInvocation on i-064bb36d1c454d861.
#
# Zero new AWS resources — sandbox lives inside the existing timescaledb
# container's Docker volume. If the DB EC2 is rebuilt, re-run this script
# to reproduce the sandbox state.

set -euo pipefail

DB_EC2="i-064bb36d1c454d861"
REGION="us-east-1"
CONTAINER="timescaledb"
SANDBOX_DB="${SANDBOX_DB:-packiot_refactor}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PARITY_SQL="${REPO_ROOT}/edge-node-red/db/17-hasura-metadata-parity.sql"
POC_SQL="${REPO_ROOT}/docs/adr/reference/migrations/0012-poc-customer-dashboards.sql"
PHASE1_SQL="${REPO_ROOT}/docs/adr/reference/migrations/0012-phase1-renames-and-drops.sql"
PHASE2_SQL="${REPO_ROOT}/docs/adr/reference/migrations/0012-phase2-cagg-consolidation.sql"
PHASE3_WRITER_SQL="${REPO_ROOT}/docs/adr/reference/migrations/0012-phase3-writer-tables.sql"
LIVE_FEED_SQL="${REPO_ROOT}/docs/adr/reference/migrations/0012-sandbox-live-feed.sql"
SWEEP_A_SQL="${REPO_ROOT}/docs/adr/reference/migrations/0012-sandbox-naming-sweep-a.sql"
SWEEP_B_SQL="${REPO_ROOT}/docs/adr/reference/migrations/0012-sandbox-naming-sweep-b.sql"

usage() {
    cat <<EOF
Usage: $0 [--reset] [--db-name NAME] [--skip-poc] [--skip-phase1] [--skip-phase2]

Provision the ADR-0012 sandbox DB on staging DB EC2. Idempotent.

  --reset          DROP sandbox DB first if it exists, then rebuild.
  --db-name NAME   Which DB to provision (default: \$SANDBOX_DB=$SANDBOX_DB).
                   Use packiot_refactor for the design sandbox, packiot_analytics
                   for the live-data proof-of-concept target.
  --skip-poc       Skip loading customer_dashboards POC.
  --skip-phase1    Skip Phase 1 renames + drops.
  --skip-phase2    Skip Phase 2 CAgg consolidation lab.
  --skip-live-feed Skip the packiot_analytics → sandbox live feed (fdw + job).
  --skip-sweep     Skip the h_*/v_* naming sweep (A + B).
  -h, --help       Show this help.

Environment:
  DB_EC2      = ${DB_EC2}
  REGION      = ${REGION}
  CONTAINER   = ${CONTAINER}
  SANDBOX_DB  = ${SANDBOX_DB}
EOF
}

RESET=false
SKIP_POC=false
SKIP_PHASE1=false
SKIP_PHASE2=false
SKIP_LIVE_FEED=false
SKIP_SWEEP=false
while [ $# -gt 0 ]; do
    case "$1" in
        --reset) RESET=true; shift;;
        --db-name) SANDBOX_DB="$2"; shift 2;;
        --skip-poc) SKIP_POC=true; shift;;
        --skip-phase1) SKIP_PHASE1=true; shift;;
        --skip-phase2) SKIP_PHASE2=true; shift;;
        --skip-live-feed) SKIP_LIVE_FEED=true; shift;;
        --skip-sweep) SKIP_SWEEP=true; shift;;
        -h|--help) usage; exit 0;;
        *) echo "unknown arg: $1"; usage; exit 1;;
    esac
done

# --- helpers -----------------------------------------------------------

ssm_run() {
    local cmd="$1"
    local params_file
    params_file=$(mktemp)
    python3 -c "import json,sys; print(json.dumps({'commands':[sys.argv[1]]}))" "$cmd" > "$params_file"
    local cid
    cid=$(aws ssm send-command --region "$REGION" --instance-ids "$DB_EC2" \
        --document-name AWS-RunShellScript --parameters "file://$params_file" \
        --query "Command.CommandId" --output text)
    rm -f "$params_file"
    # Poll until non-InProgress
    while true; do
        local status
        status=$(aws ssm get-command-invocation --region "$REGION" \
            --command-id "$cid" --instance-id "$DB_EC2" \
            --query Status --output text 2>&1)
        [ "$status" != "InProgress" ] && [ "$status" != "Pending" ] && break
        sleep 2
    done
    aws ssm get-command-invocation --region "$REGION" \
        --command-id "$cid" --instance-id "$DB_EC2" \
        --query 'StandardOutputContent' --output text
    local stderr
    stderr=$(aws ssm get-command-invocation --region "$REGION" \
        --command-id "$cid" --instance-id "$DB_EC2" \
        --query 'StandardErrorContent' --output text)
    if [ -n "$stderr" ] && [ "$stderr" != "None" ]; then
        echo "  [stderr] $stderr" >&2
    fi
    local final_status
    final_status=$(aws ssm get-command-invocation --region "$REGION" \
        --command-id "$cid" --instance-id "$DB_EC2" \
        --query Status --output text)
    if [ "$final_status" != "Success" ]; then
        echo "  [error] SSM command finished with status: $final_status" >&2
        return 1
    fi
}

# Send a local SQL file to the sandbox via base64-gzipped SSM.
# Handles files up to ~8 KB gzipped (SSM command size limit).
apply_sql_file() {
    local local_path="$1"
    local remote_path="/tmp/refactor_$(basename "$local_path")"
    if [ ! -f "$local_path" ]; then
        echo "  [skip] $local_path not found"
        return 0
    fi
    local size
    size=$(gzip -9 -c "$local_path" | base64 -w0 | wc -c)
    if [ "$size" -gt 8000 ]; then
        echo "  [error] $local_path exceeds ~8 KB gzipped-base64 (SSM cmd limit)" >&2
        return 1
    fi
    local b64
    b64=$(gzip -9 -c "$local_path" | base64 -w0)
    ssm_run "echo '$b64' | base64 -d | gunzip > $remote_path && docker cp $remote_path $CONTAINER:$remote_path && docker exec $CONTAINER psql -U postgres -d $SANDBOX_DB -f $remote_path 2>&1 | tail -40"
}

# --- preflight ---------------------------------------------------------

echo "[1/5] preflight checks..."
aws sts get-caller-identity --query Account --output text >/dev/null || {
    echo "  aws sts get-caller-identity failed — check AWS creds" >&2
    exit 1
}
aws ssm describe-instance-information --region "$REGION" \
    --query "InstanceInformationList[?InstanceId=='$DB_EC2'].PingStatus" \
    --output text | grep -q Online || {
    echo "  DB EC2 $DB_EC2 not reachable via SSM" >&2
    exit 1
}
[ -f "$PARITY_SQL" ] || { echo "  parity stub not found at $PARITY_SQL"; exit 1; }
echo "  OK"

# --- reset if requested ------------------------------------------------

if $RESET; then
    echo "[2/5] --reset given: dropping existing $SANDBOX_DB..."
    ssm_run "docker exec $CONTAINER psql -U postgres -c \"DROP DATABASE IF EXISTS $SANDBOX_DB;\""
fi

# --- create + extension ------------------------------------------------

echo "[3/5] create $SANDBOX_DB + enable TimescaleDB..."
ssm_run "docker exec $CONTAINER psql -U postgres -c \"CREATE DATABASE $SANDBOX_DB OWNER postgres;\" 2>&1 | tail -3"
ssm_run "docker exec $CONTAINER psql -U postgres -d $SANDBOX_DB -c \"CREATE EXTENSION IF NOT EXISTS timescaledb;\" 2>&1 | tail -3"

# --- load base schema --------------------------------------------------

echo "[4/5] load base schema (Hasura metadata parity stub)..."
apply_sql_file "$PARITY_SQL"

# --- POC + Phase 1 -----------------------------------------------------

if ! $SKIP_POC; then
    echo "[5a/5] apply customer_dashboards POC..."
    apply_sql_file "$POC_SQL"
fi

if ! $SKIP_PHASE1; then
    echo "[5b/5] apply Phase 1 renames + drops..."
    apply_sql_file "$PHASE1_SQL"
fi

if ! $SKIP_PHASE2; then
    echo "[5c/5] apply Phase 2 CAgg consolidation lab..."
    apply_sql_file "$PHASE2_SQL"
fi

# Phase 3 writer-target tables — only needed on packiot_analytics (the
# live-data POC target). The design sandbox packiot_refactor doesn't
# receive live writes, so it doesn't need equipment_values as a real
# table (the stub already has agg_equipment_values_1min which is enough
# for façade + rename experiments).
if [ "$SANDBOX_DB" = "packiot_analytics" ]; then
    echo "[5d/5] apply Phase 3 writer-target tables (packiot_analytics only)..."
    apply_sql_file "$PHASE3_WRITER_SQL"
fi

# Live feed + naming sweep are DESIGN-SANDBOX ONLY (packiot_refactor).
# The feed pulls FROM packiot_analytics (self-feed would loop), and the
# sweep must not disturb packiot_analytics's Phase-4 wave rehearsals.
if [ "$SANDBOX_DB" = "packiot_refactor" ]; then
    if ! $SKIP_LIVE_FEED; then
        echo "[5e/5] apply shadow live feed (fdw + refactor_sync job + ca_equipment_values_1min)..."
        apply_sql_file "$LIVE_FEED_SQL"
    fi
    if ! $SKIP_SWEEP; then
        echo "[5f/5] apply naming sweep A (h_* families)..."
        apply_sql_file "$SWEEP_A_SQL"
        echo "[5g/5] apply naming sweep B (v_* families + typo fix)..."
        apply_sql_file "$SWEEP_B_SQL"
    fi
    # PowerBI gate alignment (real staging shapes; file lands via the
    # phase5-readiness PR — apply_sql_file skips gracefully if absent).
    echo "[5h/5] apply PowerBI gate alignment..."
    apply_sql_file "${REPO_ROOT}/docs/adr/reference/migrations/0012-sandbox-gate-alignment.sql"
fi

# --- final summary -----------------------------------------------------

echo ""
echo "[done] sandbox summary:"
ssm_run "docker exec $CONTAINER psql -U postgres -d $SANDBOX_DB -tAc \"SELECT COUNT(*) AS tables FROM pg_tables WHERE schemaname='public';\""
ssm_run "docker exec $CONTAINER psql -U postgres -d $SANDBOX_DB -tAc \"SELECT pg_size_pretty(pg_database_size('$SANDBOX_DB')) AS sandbox_size;\""

echo ""
echo "Sandbox is reproducible. To reset + rebuild: $0 --reset"
