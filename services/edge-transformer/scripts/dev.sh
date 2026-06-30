#!/usr/bin/env bash
# dev.sh — local-laptop convenience wrapper. Runs the transformer against
# a local RabbitMQ on localhost:5672 with guest/guest, reading the example
# client.yaml. CREDS_SOURCE=env bypasses the AWS Secrets Manager call so
# the binary boots without IAM creds.
#
# Counterpart to services/oeecloud-worker/scripts/parity-check.sql —
# meant for the same "I want to run this on my laptop without faffing"
# audience.
#
# TODO(ADR-0009 Phase 2): add a parity-check.sh that compares the
# shadow handler's observed counter against the Node-RED publisher's
# expected rate (analogous to oeecloud-worker's parity-check.sql).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CLIENT_YAML="${CLIENT_YAML_PATH:-$ROOT_DIR/docs/client.example.yaml}"
if [[ ! -f "$CLIENT_YAML" ]]; then
    echo "client.yaml not found at $CLIENT_YAML" >&2
    echo "Either set CLIENT_YAML_PATH or create $CLIENT_YAML" >&2
    exit 1
fi

cd "$ROOT_DIR"

CREDS_SOURCE="${CREDS_SOURCE:-env}" \
RABBITMQ_USER="${RABBITMQ_USER:-guest}" \
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-guest}" \
RABBITMQ_HOST="${RABBITMQ_HOST:-localhost}" \
RABBITMQ_PORT="${RABBITMQ_PORT:-5672}" \
CLIENT_YAML_PATH="$CLIENT_YAML" \
LOG_LEVEL="${LOG_LEVEL:-debug}" \
EDGE_TRANSFORMER_MODE="${EDGE_TRANSFORMER_MODE:-dev_replay}" \
HEALTH_PORT="${HEALTH_PORT:-9102}" \
go run ./cmd/edge-transformer
