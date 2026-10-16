#!/usr/bin/env bash
# Render RabbitMQ definitions.json (durable least-privilege users) for an env.
#
#   scripts/render-rabbitmq-definitions.sh production
#
# rabbitmq.conf sets load_definitions, which re-imports users/permissions on EVERY
# broker boot, so a container recreate can never lose the least-priv users (the
# 2026-07-10 boot-only-provisioning trap). This builds the real file from the
# committed template (monitoring/rabbitmq/definitions.template.json) + passwords:
#   admin             ← RABBITMQ_USER / RABBITMQ_PASSWORD in /opt/packiot/.env
#   stream-engine     ← packiot/<env>/rabbitmq-stream-engine-creds     .password
#   sparkplug-decoder ← packiot/<env>/rabbitmq-sparkplug-decoder-creds .password
# Output: /opt/packiot/rabbitmq/definitions.json (outside any CI workspace — a
# workspace copy got cleaned and dockerd then mounted a DIRECTORY, 2026-09-25).
# It contains secrets: written 0644 only because the rabbitmq container user must
# read it; the directory lives on the app host, never in git. Nothing is printed.
#
# Same logic as deploy-staging.yml's inline step (staging keeps its own copy).
set -euo pipefail
ENV_NAME="${1:?usage: $0 <production|staging>}"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-/opt/packiot/.env}"
OUT_DIR="${OUT_DIR:-/opt/packiot/rabbitmq}"

sm() { aws secretsmanager get-secret-value --secret-id "$1" --region "$REGION" \
         --query SecretString --output text | jq -r '.password'; }

AU=$(grep -E '^RABBITMQ_USER=' "$ENV_FILE" | cut -d= -f2-)
AP=$(grep -E '^RABBITMQ_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
OP=$(sm "packiot/${ENV_NAME}/rabbitmq-stream-engine-creds")
SDP=$(sm "packiot/${ENV_NAME}/rabbitmq-sparkplug-decoder-creds")
for v in AU AP OP SDP; do
  if [ -z "${!v}" ] || [ "${!v}" = "null" ]; then
    echo "render-rabbitmq-definitions: missing value for $v — refusing to write a broken definitions.json" >&2
    exit 1
  fi
done

install -d -m 0755 "$OUT_DIR"
jq --arg au "$AU" --arg ap "$AP" --arg op "$OP" --arg sdp "$SDP" '
  .users |= map(
    if .name=="__ADMIN__" then .name=$au | .password=$ap
    elif .name=="stream-engine" then .password=$op
    elif .name=="sparkplug-decoder" then .password=$sdp
    else . end) |
  .permissions |= map(if .user=="__ADMIN__" then .user=$au else . end)
' "$ROOT/monitoring/rabbitmq/definitions.template.json" > "$OUT_DIR/definitions.json.tmp"
chmod 0644 "$OUT_DIR/definitions.json.tmp"
mv -f "$OUT_DIR/definitions.json.tmp" "$OUT_DIR/definitions.json"
echo "render-rabbitmq-definitions ($ENV_NAME): $(jq '.users|length' "$OUT_DIR/definitions.json") users, $(jq '.permissions|length' "$OUT_DIR/definitions.json") permission sets"
