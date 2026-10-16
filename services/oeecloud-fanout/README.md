# oeecloud-fanout

Clones one tenant's decoded SparkPlug stream into a sandbox tenant (staging: CPACK → SBXCPACK,
enterprise 2000003).

## What it does

oeecloud-fanout consumes the decoder's envelopes from the `oee` topic exchange, keeps only those whose
SparkPlug group is the source group (`CPACK`), rewrites the first segment of every metric name to the
target group (`SBXCPACK`), and republishes the envelope on `sparkplug.data.sbxcpack`. stream-engine
then writes the copy into the sandbox twin's analytics rows, so the twin sees CPACK's live counters.
The tenant is not a field in the envelope: consumers derive it from the first metric name's first
segment, so rewriting that segment re-tenants the whole message. Timestamps, values, counters and
`source_type` are kept exactly (decoded with `json.Number`); only equipment-id fields
(`id_equipment`, `equipment_id`, absent on today's wire) are removed. The per-metric `id` (a PackML
parameter id) is kept. Nothing in the code is CPACK-specific: source, target, queue and keys are env.

## Where it fits

```text
sparkplug-decoder ──sparkplug.data.cpack (or sparkplug.data)──▶ oee (topic)
                                                                 │ a copy per bound queue
              ┌──────────────────────────────────────────────────┤
              ▼                                                  ▼
  stream-engine-q-cpack (ent 3)                  oeecloud-fanout-cpack-to-sbxcpack
                                                                 │ group CPACK → SBXCPACK
                                                                 ▼ publish sparkplug.data.sbxcpack
                                                           oee (topic)
                                                                 ▼
                                    stream-engine-q-sbxcpack → sandbox twin (ent 2000003)
```

## Status and environments

| Environment | Where | Image | Ports | Health |
|---|---|---|---|---|
| dev (ADR-0060) | `dev/services/oeecloud-fanout.yml` · `oeecloud-fanout`; source group = the seed's anonymized group `DEV_SEED_GROUP` | built from `services/oeecloud-fanout/Dockerfile` (Go 1.25 → distroless) | 9102 in-network only | `GET /health` |
| staging | `compose.staging.yml` · `oeecloud-fanout` (no profile); enabled by `FANOUT_CPACK_TO_SBXCPACK_ENABLED` in `/opt/packiot/.env` | same, built on deploy | 9102 in-network only | `GET /health`; healthcheck `oeecloud-fanout --healthcheck` |
| production | not in `compose.production.yml` (staging only; the generated `configs/fanout/sbxcpack.yml` says so too) | — | — | — |

While disabled it serves a healthy `/health` and binds no queue.

## Interfaces

### HTTP

No OpenAPI spec (no API beyond health).

| Method | Path | Auth | What |
|---|---|---|---|
| GET | `/health` | none | JSON snapshot; 503 when unhealthy |

### Messaging

| Direction | Exchange | Queue / routing key |
|---|---|---|
| in | `oee` (topic) | durable queue `FANOUT_QUEUE` (`oeecloud-fanout-cpack-to-sbxcpack`), declared by the service, bound to `sparkplug.data` and `sparkplug.data.cpack` |
| out | `oee` | `sparkplug.data.sbxcpack`, with publisher confirms |

- **Delivery:** at least once. The source is acked only after a confirmed republish; a nack or confirm
  timeout requeues it (250 ms back-off). A crash between confirm and ack produces a duplicate clone;
  downstream writes are upserts.
- **Other tenants:** the plain `sparkplug.data` binding carries every tenant, so a message whose group is
  not the source is acked without republishing. An undecodable envelope is acked and dropped (warning
  sampled 1 in 64).
- **No loop:** the target key matches neither binding, and the group check rejects target-group messages.
- Staging's decoder publishes per-tenant keys (`F3_PER_TENANT_ROUTING: "true"` in `compose.staging.yml`),
  so traffic arrives on `sparkplug.data.cpack`; the plain binding keeps the fan-out working if that flag
  is turned off.

### Database

N/A: it does not touch a database.

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `FANOUT_ENABLED` | falls back to `FANOUT_CPACK_TO_SBXCPACK_ENABLED`, then `false` | no | master switch (`true` to consume) |
| `FANOUT_CPACK_TO_SBXCPACK_ENABLED` | `false` | no | older name of the switch; staging sets this one from `.env` |
| `FANOUT_SOURCE_GROUP` | `CPACK` | no | source SparkPlug group (case-insensitive match) |
| `FANOUT_TARGET_GROUP` | `SBXCPACK` | no | target group written into metric names |
| `FANOUT_QUEUE` | `oeecloud-fanout-cpack-to-sbxcpack` | no | durable queue name |
| `FANOUT_SOURCE_ROUTING_KEYS` | `sparkplug.data,sparkplug.data.<source lower>` | no | CSV of bindings |
| `FANOUT_TARGET_ROUTING_KEY` | `sparkplug.data.<target lower>` | no | republish key |
| `SOURCE_EXCHANGE` | `oee` | no | exchange to bind and publish on |
| `PREFETCH` | `50` | no | consumer prefetch |
| `PUBLISH_CONFIRM_TIMEOUT_MS` | `5000` | no | confirm deadline before requeue |
| `HEALTH_PORT` | `9102` | no | `/health` listener |
| `LOG_LEVEL` | `info` | no | slog level |
| `AWS_REGION` | `us-east-1` | no | Secrets Manager region |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-oeecloud-creds` | no | AMQP credentials secret; **staging sets `packiot/staging/rabbitmq-stream-engine-creds`** (the stream-engine broker user) |
| `RABBITMQ_HOST` | `rabbitmq` | no | broker host |
| `RABBITMQ_PORT` | `5672` | no | broker port |
| `CREDS_SOURCE` | unset | no | `env` = take `RABBITMQ_USER` / `RABBITMQ_PASSWORD` from env (dev only); fails closed if either is empty |
| `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | — | yes with `CREDS_SOURCE=env` | broker login (dev: user `stream-engine`) |

## Run locally

```sh
make dev SVC="oeecloud-fanout"          # Tier 0 + the fan-out
make dev-smoke SVC="oeecloud-fanout"    # a message seen on the target key through a tap queue
cd services/oeecloud-fanout && go test ./...
```

It is part of the `ingest` slice in `.github/workflows/dev-slices.yml`. It is **not** in the
`go-services.yml` matrix, so CI does not run its `go test`/`go vet` (only the dev slice).
In dev nothing consumes `stream-engine-q-sbxcpack` (stream-engine runs `LEGACY_INGEST_ENABLED=false`), so
clones accumulate there.

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`) rebuilds
  and recreates it. Enable/disable with `FANOUT_CPACK_TO_SBXCPACK_ENABLED` in `/opt/packiot/.env` and a
  recreate.
- **Signals:** no Prometheus metrics. Watch the queue depth of `oeecloud-fanout-cpack-to-sbxcpack`
  (RabbitMQ dashboard `grafana/dashboards/library/13-rabbitmq.json`) and its "republish failed" log line.
  The SRE board's `rabbitmq_connections` panel expects one connection from it.
- **A new twin:** `scripts/emit-fanout-config.sh SOURCE_GROUP TARGET_GROUP [HEALTH_PORT] [IP_LAST_OCTET]`
  writes `configs/fanout/<target>.yml` (called by `scripts/provision-sandbox-tenant.sh`). Splicing it
  into compose, picking a free IP/port and setting the `.env` flag are manual.

## Code layout

| Path | What |
|---|---|
| `cmd/oeecloud-fanout/main.go` | boot, `--healthcheck` |
| `internal/amqp/fanout.go` | declare/bind, consume, confirm-then-ack republish |
| `internal/retenant/` | pure envelope rewrite + ownership check (tests) |
| `internal/config/` | env parsing |
| `internal/secrets/` | Secrets Manager or `CREDS_SOURCE=env` broker credentials |
| `internal/health/`, `internal/log/` | `/health`, slog |

## Related docs

- [Sandbox twin runbook](../../docs/runbooks/sandbox-twin.md)
- [ADR-0021 multitenancy model](../../docs/adr/0021-multitenancy-model.md)
- [ADR-0060 dev environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [ingest-shim-and-fanout](https://wiki.packiot.app/understand/components/ingest-shim-and-fanout/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
