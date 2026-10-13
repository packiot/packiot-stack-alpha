# ingest-shim

HTTPS → RabbitMQ ingress: accepts one SparkPlug-derived JSON envelope per request from a client's
Node-RED tee and publishes it to the `oee` exchange with publisher confirms.

## What it does

RabbitMQ stays internal; this shim is the only thing a client tee talks to. It checks the shared
`X-Ingest-Key` (constant-time compare, never logged), admits only envelopes whose group (the first
segment of the topic) equals `SCOPE_GROUP` (case-insensitive), and publishes the body to
`EXCHANGE`/`ROUTING_KEY`. The envelope is republished once per entry of `FANOUT_SOURCE_TYPES`, with
the top-level `source_type` stamped (`legacy` → `""`, `go`, `refactored`). A 202 is returned only
after RabbitMQ confirms every copy; any failed copy returns 503 so the tee resends (downstream writers
are idempotent). It was built for Incoplast (enterprise 4); on staging it publishes to the Incoplast
tenant routing key.

## Where it fits

```text
 Incoplast Node-RED tee
        │ HTTPS POST /ingest/sparkplug   X-Ingest-Key
        ▼
 ingest-shim :8444 (TLS) ── AMQP, publisher confirms ──▶ exchange oee
                                                         routing key sparkplug.data.incoplast (staging)
                                                                │
                                                                ▼
                                       stream-engine-q-incoplast → stream-engine → analytics DB
```

## Status and environments

| Environment | Where (compose file · service · profile) | Image | Ports | Health |
|---|---|---|---|---|
| dev | `dev/services/ingest-shim.yml` · `ingest-shim` · slice `ingest` | built from `Dockerfile` | `127.0.0.1:8444` (TLS, self-signed from `dev-tls`) | `--healthcheck` → `https://127.0.0.1:8444/healthz` |
| staging | `compose.staging.yml` · `ingest-shim` · no profile | built from `Dockerfile` | `127.0.0.1:8444` (host loopback only), metrics in-network 9105 | `--healthcheck` |
| production | defined in `compose.production.yml` · `ingest-shim` · profile `client-ingest` (new-stack production is not promoted) | built from `Dockerfile` | 8444 on all host interfaces; the production security group does not admit it | `--healthcheck` |

Image: Go 1.25 Alpine builder → `gcr.io/distroless/static-debian12:nonroot`. No nginx vhost routes to
it in either environment; the staging docs portal only fetches its `/openapi.json` in-network.

## Interfaces

### HTTP

TLS listener (`HTTP_ADDR`, default `:8444`):

| Method | Path | Auth | What |
|---|---|---|---|
| POST | `/ingest/sparkplug` | `X-Ingest-Key` | Publish one envelope. 202 `{"status":"accepted"}`; 400 bad/empty/topicless body; 413 body over `MAX_BODY_BYTES`; 401 wrong key; 403 out-of-scope group; 503 publish failed (retry) |
| GET | `/healthz` | none | 200 `{"status":"ok"}`, or 503 `{"status":"amqp_down"}` while the broker connection is down |
| GET | `/openapi.json` | none | the embedded OpenAPI document |

Plaintext metrics listener (`METRICS_ADDR`, default `:9105`): `GET /metrics`.

Spec: [`docs/api/openapi/ingest-shim.openapi.json`](../../docs/api/openapi/ingest-shim.openapi.json)
(source `internal/httpserver/openapi.json`); browse it in the API portal at
https://api.staging.packiot.app/docs/ (SSO).

### Messaging

| Direction | Exchange | Routing key | Notes |
|---|---|---|---|
| publish | `oee` (topic) | `ROUTING_KEY`: staging and dev `sparkplug.data.incoplast`; default and production `sparkplug.data` | persistent, publisher-confirmed; one publish per `FANOUT_SOURCE_TYPES` entry (staging/dev: `refactored` only) |

On staging, stream-engine binds `sparkplug.data.incoplast` because `incoplast` is in its default
`WORKER_TENANT_ALLOWLIST`. In dev nothing binds it, so messages land in `oee-unroutable-q`.

### Database

N/A: no database access.

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `INGEST_API_KEY` | — | yes | Shared ingest key; the process refuses to start without it. Staging: `.env` |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | — | yes | TLS pair; refuses to start if either is empty. Staging: host dir `/opt/packiot/ingest-shim/certs` mounted at `/certs` |
| `HTTP_ADDR` | `:8444` | no | TLS listener; also used by `--healthcheck` |
| `METRICS_ADDR` | `:9105` | no | Plaintext `/metrics` listener |
| `RABBITMQ_HOST` / `RABBITMQ_PORT` | `rabbitmq` / `5672` | no | Broker |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-oeecloud-creds` | no | Secrets Manager id of the broker user. Staging sets `packiot/staging/rabbitmq-sparkplug-decoder-creds`; production `packiot/production/rabbitmq-sparkplug-decoder-creds` |
| `AWS_REGION` | `us-east-1` | no | Secrets Manager region |
| `CREDS_SOURCE` | unset | no | `env` skips Secrets Manager and reads `RABBITMQ_USER` / `RABBITMQ_PASSWORD` (dev only) |
| `RABBITMQ_USER` / `RABBITMQ_PASSWORD` | — | with `CREDS_SOURCE=env` | Broker credentials (dev: `sparkplug-decoder` user from `.env.dev`) |
| `EXCHANGE` | `oee` | no | Target exchange |
| `ROUTING_KEY` | `sparkplug.data` | no | Target routing key (staging: `sparkplug.data.incoplast`; production: `INGEST_ROUTING_KEY`) |
| `CONFIRM_TIMEOUT_MS` | `5000` | no | Wait for a publisher confirm before answering 503 |
| `SCOPE_GROUP` | `INCOPLAST` | no | Only this group is admitted. An empty value falls back to the default (it does not disable the guard) |
| `FANOUT_SOURCE_TYPES` | `legacy,go,refactored` | no | Comma list of flows; staging/dev: `refactored` |
| `MAX_BODY_BYTES` | `1048576` | no | Larger bodies are 413 |
| `LOG_LEVEL` | `info` | no | slog level |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset (tracing off) | no | OTLP/gRPC endpoint. Staging: `http://tempo:4317` |
| `OTEL_TRACES_SAMPLER_ARG` | `1.0` | no | Head-sampling ratio; the trace context is carried into the AMQP headers |

## Run locally

```sh
make dev SVC="ingest-shim"            # Tier 0 + dev-tls + ingest-shim on https://127.0.0.1:8444
make dev-smoke SVC="ingest-shim"      # posts one envelope and sees it on the target key via a tap queue
KEY=$(grep '^DEV_INGEST_API_KEY=' dev/.env.dev | cut -d= -f2)
curl -sk -H "X-Ingest-Key: $KEY" -d '{"metrics":[{"name":"INCOPLAST/x","value":1}]}' \
  https://127.0.0.1:8444/ingest/sparkplug
cd services/ingest-shim && go test ./...   # CI: .github/workflows/go-services.yml
```

After changing `internal/httpserver/openapi.json`, run `make openapi` and commit the export
(`.github/workflows/openapi-export.yml` fails on drift).

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`)
  rebuilds the image. The TLS files are host files; they are not managed by the workflow.
- **Metrics** (job `ingest-shim`, target `ingest-shim:9105` in `monitoring/prometheus/prometheus.yml`):
  `ingest_shim_requests_total{outcome}` with outcomes `received`, `published`, `rejected_auth`,
  `rejected_scope`, `rejected_bad`, `publish_failed`; `http_request_duration_seconds{method,route,status}`
  (with trace exemplars).
- **Dashboards:** "API — RED" (`grafana/dashboards/library/12-api.json`) and "Operator — actions &
  adapter" (`grafana/dashboards/library/07-operator.json`) chart `ingest_shim_requests_total` by outcome.
  No alert rule references it.
- **Failure modes:**
  - 503 `publish failed` and `/healthz` `amqp_down` → broker down or credentials wrong; the publisher
    reconnects with jittered exponential backoff (`internal/amqp/publisher.go`).
  - 403 out-of-scope → the tee sent a topic whose first segment is not `SCOPE_GROUP`.
  - Process exits at start → `INGEST_API_KEY` or a TLS file is missing.
  - Accepted but never processed → nothing is bound to the routing key (dev; or a tenant missing from
    stream-engine's allow-list); check `oee-unroutable-q`.

## Code layout

| Path | What |
|---|---|
| `cmd/ingest-shim/main.go` | config, TLS listener, metrics listener, tracing, `--healthcheck` |
| `internal/config/` | env config and fan-out parsing |
| `internal/httpserver/` | routes, auth, scope guard, fan-out, embedded `openapi.json` |
| `internal/amqp/` | confirmed publisher with reconnect loop |
| `internal/secrets/` | Secrets Manager / `CREDS_SOURCE=env` broker credentials |
| `internal/metrics/`, `internal/httpmetrics/` | `ingest_shim_requests_total`, RED histogram |
| `internal/tracing/`, `internal/amqptrace/` | OTLP setup; trace context into AMQP headers |
| `internal/log/` | slog setup |

## Related docs

- [ADR-0032 — collapse to single flow F3](../../docs/adr/0032-collapse-to-single-flow-f3.md)
- [ADR-0053 — on-prem ingest edge for outage autonomy](../../docs/adr/0053-on-prem-ingest-edge-for-outage-autonomy.md)
- [ADR-0060 — local development environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)
- [ADR-0061 — remove PackML from the cloud](../../docs/adr/0061-remove-packml-from-the-cloud.md)

<!-- wiki-links: added in cross-reference pass -->
