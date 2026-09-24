#!/usr/bin/env bash
# deploy-db-agent.sh — (re)deploy the Grafana Alloy agent on the analytics DB box.
#
# The DB box runs ONLY timescaledb + this agent. The agent PUSHES (the DB box
# accepts no inbound): container logs → app-box gateway :3101 (Loki relay) and host
# metrics → app-box gateway :3102 (Prometheus remote-write relay). Before this
# script existed the container was started by hand and its run flags lived only on
# the box (codified 2026-09-23, T0 of docs/plans/unified-hot-cold-serving-grain-
# tiered-retention.md).
#
# Run from a workstation with AWS creds (uses SSM; no SSH):
#   scripts/deploy-db-agent.sh                # staging defaults
#   DB_INSTANCE=i-... APP_PRIVATE_IP=10.x.x.x scripts/deploy-db-agent.sh
#
# Idempotent: rewrites /opt/alloy/db-agent.alloy and recreates the container.
# Verify afterwards (app box): absent(node_filesystem_avail_bytes{instance="db-box"}) == empty.
set -euo pipefail

DB_INSTANCE="${DB_INSTANCE:-i-064bb36d1c454d861}"
APP_PRIVATE_IP="${APP_PRIVATE_IP:-10.10.0.228}"
REGION="${AWS_REGION:-us-east-1}"
IMAGE="${ALLOY_IMAGE:-grafana/alloy:v1.5.1}"
CFG="$(cd "$(dirname "$0")/.." && pwd)/monitoring/alloy/db-agent.alloy"

B64=$(base64 -w0 < "$CFG")
REMOTE=$(cat <<EOF
set -e
mkdir -p /opt/alloy
echo '$B64' | base64 -d > /opt/alloy/db-agent.alloy
docker pull -q $IMAGE >/dev/null
docker rm -f alloy-db >/dev/null 2>&1 || true
docker run -d --name alloy-db --restart unless-stopped \\
  --pid host \\
  -e ALLOY_LOKI_GATEWAY=http://$APP_PRIVATE_IP:3101/loki/api/v1/push \\
  -e ALLOY_PROM_GATEWAY=http://$APP_PRIVATE_IP:3102/api/v1/metrics/write \\
  -e ALLOY_DEPLOY_MODE=docker \\
  -v /var/run/docker.sock:/var/run/docker.sock:ro \\
  -v /opt/alloy/db-agent.alloy:/etc/alloy/db-agent.alloy:ro \\
  -v /:/host/root:ro,rslave \\
  -v /proc:/host/proc:ro \\
  -v /sys:/host/sys:ro \\
  $IMAGE run --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy/data /etc/alloy/db-agent.alloy
sleep 8
docker ps --filter name=alloy-db --format '{{.Names}} {{.Status}}'
docker logs --tail 15 alloy-db 2>&1 | grep -iE 'error|level=warn' || echo 'no errors in last 15 log lines'
EOF
)

ID=$(aws ssm send-command --region "$REGION" --instance-ids "$DB_INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters "$(jq -nc --arg c "$REMOTE" '{commands:[$c]}')" \
  --query Command.CommandId --output text)
for _ in $(seq 1 45); do
  S=$(aws ssm get-command-invocation --region "$REGION" --command-id "$ID" --instance-id "$DB_INSTANCE" --query Status --output text 2>/dev/null || true)
  case "$S" in Success|Failed|Cancelled|TimedOut) break ;; esac
  sleep 2
done
aws ssm get-command-invocation --region "$REGION" --command-id "$ID" --instance-id "$DB_INSTANCE" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' --output text
