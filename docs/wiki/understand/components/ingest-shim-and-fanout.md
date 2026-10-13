---
title: ingest-shim and oeecloud-fanout
layer: 3
owner_area: ingestion
last_verified: 2026-09-28
---
# ingest-shim and oeecloud-fanout

> **Layer 3 · Component** — two small Go services that put messages on the `oee` exchange without
> going through the decoder: `ingest-shim` (HTTPS in, AMQP out) and `oeecloud-fanout` (clones
> CPACK's stream into the sandbox tenant). Also explains what "edge-transformer" means today.
> Up: [Ingestion subsystem](../subsystems/ingestion.md)

## Responsibility

- **ingest-shim** accepts an already-built JSON envelope over authenticated HTTPS and republishes it
  to RabbitMQ. It is the path for an edge that cannot speak MQTT/AMQP to the cloud and produces the
  envelope itself (the Incoplast Node-RED tee). It does **no counter math**: whatever increments
  the edge sends go straight to the [stream-engine](stream-engine.md).
- **oeecloud-fanout** (staging only) consumes CPACK's decoded envelopes, rewrites the tenant from
  `CPACK` to `SBXCPACK`, and republishes them, so the sandbox twin (enterprise 2000003) gets the
  same data as CPACK (enterprise 3).
- **edge-transformer** is not a separate service. It is the old name of the
  [sparkplug-decoder](sparkplug-decoder.md) (the network alias `edge-transformer` and many metric
  names remain). `services/edge-transformer/` contains only an orphaned test file.

## At a glance

| | ingest-shim | oeecloud-fanout |
|---|---|---|
| Language / runtime | Go, distroless | Go, distroless |
| Repo path | `services/ingest-shim` | `services/oeecloud-fanout` |
| Compose service (staging) | `ingest-shim`, IP `172.18.0.29` | `oeecloud-fanout`, IP `172.18.0.41` |
| Ports | 8444 HTTPS API (published on `127.0.0.1:8444` only), 9105 metrics | 9102 `/health` (in-network) |
| Limits | 128 MB, 0.25 CPU | 128 MB, 0.25 CPU |
| Credentials | Secrets Manager `packiot/staging/rabbitmq-sparkplug-decoder-creds` (publisher) | Secrets Manager `packiot/staging/rabbitmq-stream-engine-creds` |
| Depends on | RabbitMQ; TLS cert/key at `/opt/packiot/ingest-shim/certs` | RabbitMQ |
| Depended on by | the edge tee that POSTs to it | stream-engine queue `stream-engine-q-sbxcpack` |
| Production | defined in `compose.production.yml` | staging only (never in production) |

## Inputs & outputs

### ingest-shim

| | |
|---|---|
| In | `POST /ingest/sparkplug` with header `X-Ingest-Key`, JSON body ≤ 1 MiB |
| In | `GET /healthz` (TLS) |
| Out | AMQP publish to exchange `EXCHANGE` (`oee`) with routing key `ROUTING_KEY`, persistent, publisher confirms, `traceparent` in headers |

Response codes (`internal/httpserver/server.go`):

| Code | When | Metric outcome (`ingest_shim_requests_total{outcome}`) |
|---|---|---|
| 202 | every copy confirmed by the broker | `published` |
| 400 | empty, too large, unparseable, or no topic/group found | `rejected_bad` |
| 401 | missing or wrong `X-Ingest-Key` (constant-time compare) | `rejected_auth` |
| 403 | first segment of `topic`/`group`/`group_id`/first metric name ≠ `SCOPE_GROUP` | `rejected_scope` |
| 503 | any publish copy nacked / timed out | `publish_failed` |

### oeecloud-fanout

| | |
|---|---|
| In | queue `oeecloud-fanout-cpack-to-sbxcpack`, bound on `oee` to every key in `FANOUT_SOURCE_ROUTING_KEYS` |
| Out | publish to `oee` with `FANOUT_TARGET_ROUTING_KEY` (`sparkplug.data.sbxcpack`), persistent, confirms |

## Internal design

### ingest-shim

1. Authenticate `X-Ingest-Key`. The shim refuses to start without `INGEST_API_KEY` and without TLS
   files (no plaintext public listener).
2. Read the body (limit `MAX_BODY_BYTES`).
3. **Scope guard**: find the group from `topic`, `group`, `group_id`, or the first metric name;
   refuse anything whose first segment is not `SCOPE_GROUP` (case-insensitive).
4. **Fan-out**: for each token in `FANOUT_SOURCE_TYPES`, set the envelope's top-level
   `source_type` (`legacy` → `""`, others verbatim) and publish. On staging only `refactored` is
   published, so every accepted request is one message for the analytics DB. A failure on any
   copy returns 503 so the sender retries the whole request; the stream-engine writes are upserts.
5. A reconnect loop with jittered exponential backoff heals broker drops; `/healthz` reports the
   publisher state.

### oeecloud-fanout

For each delivery, `internal/retenant.Retenant`:

1. Decodes the body with `json.Number` (large integers round-trip exactly).
2. If no metric belongs to the source group, the message is "not ours": ack, do nothing. This
   filter is what makes it safe to bind the shared `sparkplug.data` key.
3. Rewrites the first segment of every metric name `CPACK/…` → `SBXCPACK/…`, clears any
   `id_equipment` / `equipment_id` fields (none on today's wire), and keeps the per-metric `id`
   (PackML parameter id, needed for PO control).
4. Publishes to `sparkplug.data.sbxcpack` and waits for the confirm, then acks the source.
   Nack/timeout → `Nack(requeue=true)` after a 250 ms pause. Undecodable bodies are acked and
   dropped (counted, sampled log).

It cannot loop: the target key matches neither source binding. It cannot double-count CPACK: the
clone goes to a different tenant, queue and equipment id range (+2 000 000).

When `FANOUT_CPACK_TO_SBXCPACK_ENABLED` (or `FANOUT_ENABLED`) is not `true`, the service only serves
`/health` and binds nothing.

## Configuration

### ingest-shim

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `AWS_REGION` | `us-east-1` | `us-east-1` | |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-oeecloud-creds` | `packiot/staging/rabbitmq-sparkplug-decoder-creds` | publisher user |
| `CREDS_SOURCE` | unset | — | `env` = read `RABBITMQ_USER/PASSWORD` from env |
| `RABBITMQ_HOST` / `RABBITMQ_PORT` | `rabbitmq` / 5672 | same | |
| `EXCHANGE` | `oee` | `oee` | |
| `ROUTING_KEY` | `sparkplug.data` | `sparkplug.data.incoplast` | |
| `CONFIRM_TIMEOUT_MS` | 5000 | — | publish confirm wait |
| `HTTP_ADDR` / `METRICS_ADDR` | `:8444` / `:9105` | same | |
| `INGEST_API_KEY` | none (required) | from host `.env` | shared secret for `X-Ingest-Key` |
| `SCOPE_GROUP` | `INCOPLAST` | `INCOPLAST` | the only admitted Sparkplug group |
| `FANOUT_SOURCE_TYPES` | `legacy,go,refactored` | `refactored` | one publish per token |
| `MAX_BODY_BYTES` | 1048576 | — | |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | none (required) | `/certs/server.crt` / `/certs/server.key` | |
| `LOG_LEVEL` | `info` | `info` | |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | `http://tempo:4317` | tracing |

### oeecloud-fanout

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `FANOUT_ENABLED` / `FANOUT_CPACK_TO_SBXCPACK_ENABLED` | `false` | `${FANOUT_CPACK_TO_SBXCPACK_ENABLED:-false}` from the host `.env` | master gate |
| `FANOUT_SOURCE_GROUP` / `FANOUT_TARGET_GROUP` | `CPACK` / `SBXCPACK` | same | |
| `FANOUT_SOURCE_ROUTING_KEYS` | `sparkplug.data,sparkplug.data.<source>` | `sparkplug.data,sparkplug.data.cpack` | bindings |
| `FANOUT_TARGET_ROUTING_KEY` | `sparkplug.data.<target>` | `sparkplug.data.sbxcpack` | |
| `FANOUT_QUEUE` | `oeecloud-fanout-cpack-to-sbxcpack` | same | |
| `SOURCE_EXCHANGE` | `oee` | `oee` | |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-oeecloud-creds` | `packiot/staging/rabbitmq-stream-engine-creds` | |
| `PREFETCH` / `PUBLISH_CONFIRM_TIMEOUT_MS` / `HEALTH_PORT` | 50 / 5000 / 9102 | 50 / 5000 / 9102 | |

The sandbox twin is live on staging (its lead machines get their data from this fan-out, per the
comment on `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` in `compose.staging.yml`), so the host `.env` has the
gate on.

## Data & invariants

- ingest-shim never changes metric content, only `source_type`. Counter correctness for that path is
  the sender's job; the stream-engine's increment sanity clamp is the only cloud-side guard.
- ingest-shim never logs the API key or the payload.
- The fan-out preserves timestamps, values, counters and `source_type` byte-for-byte.
- Delivery is at-least-once on both services; duplicates are safe for Silver (upserts) but add rows in
  Bronze (append-only).

## Observability

| Signal | Service |
|---|---|
| `ingest_shim_requests_total{outcome}`, `http_request_duration_seconds` on `:9105` | ingest-shim |
| `/healthz` (TLS, self-probed by `ingest-shim --healthcheck`) | ingest-shim |
| `/health` JSON (delivered / republished / skipped / dropped / failed counters) | oeecloud-fanout |
| Queue depth of `oeecloud-fanout-cpack-to-sbxcpack` | RabbitMQ (`rabbitmq-detailed` scrape) |
| Logs: `published`, `publish failed`, `fanout: republish failed, nacked+requeued` | both |

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Incoplast publishes to a key nobody consumes | messages accumulate in `oee-unroutable-q`, alert `OeeUnroutableMessages` | `incoplast` is not in staging's `WORKER_TENANT_ALLOWLIST`; its queue triple was removed in the 2026-09-14 cleanup (0 lifetime publishes) | add `incoplast` to the allowlist when that feed goes live, or stop the shim |
| Edge bundle pointed at a dead port (found before firing, production host) | a "successful" deploy would have delivered nothing | the tee used `:8446`, terraform opened `:8883`, the live shim listened on `:8444` | PR #679 aligned the bundle on the running shim port. Check what is actually listening (`ss -ltnp`, `docker ps`) rather than config |
| Static AWS keys in the shared `.env` (2026-08-27) | shim / fanout / decoder lose Secrets Manager access | env credentials override the instance role for every AWS SDK call | keep static keys out of the shared `.env` |
| Sandbox line OEE 0 while CPACK is fine | sandbox gross flows, availability 0 | twin tenant missing from a per-enterprise rollup list (fixed 2026-09 by adding 2000003 to line-lead) | keep every list that names 3 also naming 2000003 on staging |
| Fan-out disabled after a deploy | sandbox data stops | `.env` flag lost | set `FANOUT_CPACK_TO_SBXCPACK_ENABLED=true` in `/opt/packiot/.env`, recreate the container |

## Operating it

- **Enable / disable the fan-out**: edit `/opt/packiot/.env` and recreate (`docker compose up -d
  oeecloud-fanout`); `docker restart` keeps the old environment.
- **Rotate the ingest key**: change `INGEST_API_KEY` in `.env`, recreate `ingest-shim`, hand the new
  value to the edge tee.
- **Certificates**: replace the files in `/opt/packiot/ingest-shim/certs` and recreate.
- **Test the shim** from the host: `curl -k -H "X-Ingest-Key: …" https://127.0.0.1:8444/ingest/sparkplug -d @envelope.json`
  (a group other than `SCOPE_GROUP` must return 403).

## Tests

- `cd services/ingest-shim && go test ./...` and `cd services/oeecloud-fanout && go test ./...`
  (`internal/retenant` has the transform tests).
- CI: `.github/workflows/go-services.yml` runs `go test -race` for `services/ingest-shim`.

## Source map

| Path | What's there |
|---|---|
| `services/ingest-shim/cmd/ingest-shim/main.go` | wiring, TLS listener, healthcheck subcommand |
| `services/ingest-shim/internal/httpserver/server.go` | auth, scope guard, fan-out publish |
| `services/ingest-shim/internal/amqp/publisher.go` | confirmed publisher + reconnect loop |
| `services/ingest-shim/internal/config/config.go` | env configuration |
| `services/oeecloud-fanout/cmd/oeecloud-fanout/main.go` | wiring, disabled idle mode |
| `services/oeecloud-fanout/internal/amqp/fanout.go` | topology, consume, republish |
| `services/oeecloud-fanout/internal/retenant/retenant.go` | the re-tenant transform |
| `services/oeecloud-fanout/internal/config/config.go` | env configuration |
| `services/oeecloud-fanout/README.md` | design notes |
| `compose.staging.yml` (`ingest-shim`, `oeecloud-fanout`) | staging wiring |
| `services/edge-transformer/internal/agent/agentcfg/register_cpack_full_test.go` | orphaned test file (no module) |
