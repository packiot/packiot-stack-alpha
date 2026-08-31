#!/usr/bin/env bash
# provision-sandbox-edge-box.sh — stand up a safe, self-contained edge stack on a
# hybrid SSM managed instance so CS engineers can exercise Box Ops (health · logs
# · restart · deploy · connect/port-forward) end-to-end against a REAL box without
# touching a client. Idempotent: re-running just re-applies `docker compose up -d`.
#
# The stack (docs/clients/sandbox-edge/compose.edge.yml): edge-nodered (:1880 —
# the Connect/port-forward target, like a real edge), plc-reader (a counter log
# emitter for the Logs view), edge-cache (a restart target). All public images.
#
# The box must have docker + the SSM agent (install docker with get.docker.com if
# absent). It resolves in Box Ops via its `enterprise` tag — the CPACK sandbox is
# enterprise 2000003 (mi-0114b66366e2d6613 at time of writing). Usage:
#   MI=mi-0114b66366e2d6613 ./scripts/provision-sandbox-edge-box.sh
set -euo pipefail
MI="${MI:?set MI=<managed-instance-id> (the sbxcpack box, enterprise 2000003)}"
REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
B64="$(base64 -w0 "$HERE/docs/clients/sandbox-edge/compose.edge.yml")"

read -r -d '' CMDS <<JSON || true
{ "commands": [
  "command -v docker >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq ca-certificates curl && curl -fsSL https://get.docker.com | sh; systemctl enable --now docker; }",
  "mkdir -p /opt/packiot",
  "echo '$B64' | base64 -d > /opt/packiot/compose.edge.yml",
  "cd /opt/packiot && docker compose -f compose.edge.yml up -d",
  "docker ps --format '{{.Names}} | {{.Status}}'"
]}
JSON
ID=$(aws ssm send-command --region "$REGION" --instance-ids "$MI" \
  --document-name AWS-RunShellScript --parameters "$CMDS" \
  --query 'Command.CommandId' --output text)
echo ">> SendCommand $ID — poll: aws ssm get-command-invocation --command-id $ID --instance-id $MI --region $REGION"
