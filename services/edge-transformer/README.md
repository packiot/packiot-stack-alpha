# edge-transformer

Per-factory Go service that consumes from a local RabbitMQ exchange
(`plc.normalized.<tenant>`), runs deterministic Go transforms previously
implemented as Node-RED subflows, and publishes transformed payloads onward.

**Status: ADR-0009 Phase 2 SKELETON — shadow mode.** The binary boots,
connects, declares per-tenant topology, runs N per-tenant consume
goroutines (one Channel per tenant, shared Connection), and dispatches
every delivery to a no-op handler that logs and acks. No transforms, no
DB, no outbound publishes.

See [`docs/README.md`](./docs/README.md) for the operator-facing intro and
[`ADR-0009`](../../docs/adr/0009-edge-transformer-go-service-and-nodered-split.md)
for the architectural context.

## Reuse rule (ADR-0009 Errata Correction 2)

Every architectural element in this service is lifted verbatim from
`services/oeecloud-worker/` or `services/mirror-worker-go/`. Pattern
drift between these services is the single biggest risk this rule
exists to prevent — see PR #56's silent-metric-coverage-gap for the
worst-case example.

If a future PR introduces a new pattern that "feels almost like" an
existing one, the burden of proof is on that PR's author to justify
why — not on the reviewer to spot the drift.

## Quick start (local)

```bash
# From the parent stack repo:
docker compose -f compose.staging.yml up -d edge-transformer  # Phase 2 — not yet wired

# Direct (laptop, no Docker — requires Go 1.24+):
cd services/edge-transformer
CREDS_SOURCE=env \
RABBITMQ_USER=guest RABBITMQ_PASSWORD=guest \
RABBITMQ_HOST=localhost RABBITMQ_PORT=5672 \
CLIENT_YAML_PATH=./docs/client.example.yaml \
go run ./cmd/edge-transformer
```

## Endpoints

| Path        | Port  | Purpose                                                    |
|-------------|-------|------------------------------------------------------------|
| `/healthz`  | 9102  | JSON snapshot, 200/503; called by Docker `HEALTHCHECK`     |
| `/health`   | 9102  | Alias for `/healthz` (parity with oeecloud-worker)         |
| `/metrics`  | 9102  | Prometheus scrape target                                   |

Port 9102 is deliberate — oeecloud-worker uses 9101, so the two services
can colocate on a single host without port collision.
