# edge-transformer — operator notes

**Status (skeleton):** boots, declares per-tenant topology, runs N consume
goroutines, shadow-dispatches every message (log + ack), serves
`/healthz` + `/metrics` on port 9102.

## What it will do (ADR-0009 Phase 2+)

This service replaces Node-RED's role as the deterministic transform
layer on each factory's edge-stack:

```
PLCs → edge-node-red (Sparkplug + auth + UI only)
        │ AMQP publish to plc.normalized.<tenant>
        ▼
       edge-transformer (THIS SERVICE)
        │ - Calc_Counters etc., ported from Node-RED subflows
        │ - publish transformed payload to outbox.cloud_api.<tenant>
        ▼
       outbox drain loop (Phase 3) → cloud edge-api / Hasura
```

See [ADR-0009](../../../docs/adr/0009-edge-transformer-go-service-and-nodered-split.md)
for the full architectural picture and the responsibility split between
edge-node-red and edge-transformer.

## Pattern reuse

Everything in this service is lifted from one of:

- `services/oeecloud-worker/` — per-tenant queue topology, per-tenant
  Prometheus labels, AMQP Channel-per-goroutine discipline, AWS Secrets
  Manager credential flow, distroless Docker image, `--healthcheck`
  binary subcommand.
- `services/mirror-worker-go/` — DLQ + exponential backoff (Phase 3),
  reanimator loop (Phase 3).

ADR-0009 Errata Correction 2 calls this out explicitly: **any pattern
from these two services MUST NOT be re-implemented** in edge-transformer.

## Local dev

```bash
# 1. Run a RabbitMQ on localhost (any way you like — Docker / homebrew / nix).
# 2. Provide a client.yaml:
cat > /tmp/client.yaml <<'EOF'
tenant_id: dev
customer: Local Dev
environment: staging
EOF

# 3. Run:
cd services/edge-transformer
CREDS_SOURCE=env \
RABBITMQ_USER=guest RABBITMQ_PASSWORD=guest \
RABBITMQ_HOST=localhost RABBITMQ_PORT=5672 \
CLIENT_YAML_PATH=/tmp/client.yaml \
go run ./cmd/edge-transformer
```

You should see:

- `edge-transformer starting` with the loaded config.
- `client config loaded` with `tenants=[dev]`.
- `amqp topology declared` with `tenant_queues=1`.
- `consuming` with `queues=[edge-transformer-q-dev]`.
- `health server listening` on `:9102`.

Publish a test message to confirm shadow handling:

```bash
# Using rabbitmqadmin (install via your package manager or RabbitMQ image):
rabbitmqadmin publish exchange=plc.normalized routing_key=plc.normalized.dev payload='{"hello":"world"}'
```

The log line `shadow: received message (no-op)` confirms the round-trip.

## Health + metrics

```bash
curl -s localhost:9102/healthz | jq .
curl -s localhost:9102/metrics | grep edge_transformer
```

Notable metrics (per ADR-0009 reuse rule + PR #56 lesson — all per-tenant):

| Metric                                              | Labels                       |
|-----------------------------------------------------|------------------------------|
| `edge_transformer_amqp_deliveries_total`            | routing_key, tenant, result  |
| `edge_transformer_handler_duration_seconds`         | routing_key, tenant          |
| `edge_transformer_handler_shadow_observed_total`    | tenant                       |
| `edge_transformer_amqp_delivered_total` (global)    | —                            |

## What's NOT here yet (Phase 2+)

- Real handlers (Calc_Counters, etc.). Today every routing key is shadow.
- Outbox pattern (Phase 3) — outbound HTTP calls live in Node-RED for now.
- DLQ + reanimator (Phase 3) — mirror-worker-go's PR #77 + #84 pattern.
- Compose entry in `compose.staging.yml` — commented placeholder only.
- Deploy pipeline integration — Phase 2 work.
