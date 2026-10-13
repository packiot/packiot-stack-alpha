---
title: Message brokers (Mosquitto and RabbitMQ)
layer: 3
owner_area: ingestion
last_verified: 2026-09-28
---
# Message brokers (Mosquitto and RabbitMQ)

> **Layer 3 · Component** — the two brokers on the staging app host: Mosquitto (MQTT, carries
> Sparkplug B from edge publishers to the decoder) and RabbitMQ (AMQP, carries decoded envelopes
> from the decoder to the stream-engine). For people who operate or debug the ingest path.
> Up: [Ingestion subsystem](../subsystems/ingestion.md)

## Responsibility

Mosquitto is the **MQTT hop**: every Sparkplug B publisher inside the stack (the sparkplug-agents,
`plc-sim`, `bispharma-twin`, `s7-reader`) publishes to it and the
[sparkplug-decoder](sparkplug-decoder.md) subscribes to all of it. RabbitMQ is the **durable bus**
between the decoder (and [ingest-shim / oeecloud-fanout](ingest-shim-and-fanout.md)) and the
[stream-engine](stream-engine.md): one topic exchange `oee`, one queue triple per tenant, a retry
loop and a dead-letter path. Neither broker transforms data. Their job is to hold messages until a
consumer takes them.

## At a glance

| | Mosquitto | RabbitMQ |
|---|---|---|
| Image | `eclipse-mosquitto:2` | `rabbitmq:3.13-management` |
| Compose service (staging) | `mosquitto` (`compose.staging.yml`) | `rabbitmq` (container `stack-rabbitmq-1` under project `stack`) |
| Static IP on `packiot-net` | `172.18.0.24` | `172.18.0.5` |
| Host ports | `127.0.0.1:1883` only | `127.0.0.1:5672` (AMQP), `127.0.0.1:15672` (management) |
| In-network ports | 1883 | 5672, 15672, 15692 (Prometheus plugin) |
| Config | `configs/mosquitto/mosquitto.conf` (mounted read-only) | `monitoring/rabbitmq/rabbitmq.conf`, `enabled_plugins`, generated `definitions.json` |
| Persistence | volume `mosquitto-data` (retained NBIRTHs) | volume `rabbitmq-data` (Mnesia + message store) |
| Auth | anonymous (`allow_anonymous true`) | users from `definitions.json` (admin + 2 least-privilege users) |
| Healthcheck | `mosquitto_pub` of a `healthcheck/ping` message, 30 s | `rabbitmq-diagnostics ping`, 30 s |
| Depended on by | sparkplug-decoder, agents, plc-sim, bispharma-twin, s7-reader | sparkplug-decoder, stream-engine, ingest-shim, oeecloud-fanout |

Both brokers exist in `compose.production.yml` too (the new-stack production host). Production
Mosquitto uses `configs/mosquitto/mosquitto.prod.conf`, which adds a mutual-TLS listener on 8883
(`require_certificate true`, `use_identity_as_username true`). The legacy production platform uses
Google Cloud Pub/Sub instead, not these brokers.

## Inputs & outputs

### Mosquitto topics

| Topic pattern | Producer | Consumer |
|---|---|---|
| `spBv1.0/<GROUP>/<N-type>/<edge_node>`, N-type = `NBIRTH`, `NDATA`, `NDEATH` | agents, `plc-sim`, twins | sparkplug-decoder |
| `spBv1.0/<GROUP>/<D-type>/<edge_node>/<device>`, D-type = `DBIRTH`, `DDATA`, `DDEATH` | agents / readers | sparkplug-decoder |
| `spBv1.0/<GROUP>/NCMD/<edge_node>` (`Node Control/Rebirth`) | sparkplug-decoder, only if `ET_REQUEST_REBIRTH_ENABLED=true` (off on staging) | the edge node |
| `spBv1.0/<GROUP>/DCMD/<edge_node>` | sparkplug-decoder command channel (`EDGE_COMMANDS_ENABLED`, off) | the PLC-side node |
| `healthcheck/ping` | the container healthcheck | nobody |

The decoder subscribes to `spBv1.0/#` at QoS 0 (`internal/mqtt/subscriber.go`, `TopicFilterAll`).
`<GROUP>` is the Sparkplug group id and becomes the tenant: `CPACK` → `cpack`,
`BISPHARMASTAGING` → `bispharmastaging`, `SBXCPACK` → `sbxcpack`.

Publishers on staging and how each is switched on:

| Publisher | Group | Gate |
|---|---|---|
| `plc-sim` | CPACK (synthetic) | compose profile `plc-sim` |
| `sparkplug-agent-cpack` | CPACK (real tee, HTTP front-door `:9104`) | compose profile `cpack-tee` |
| `sparkplug-agent-shared` | one pipeline per `docs/clients/tenants/*.yaml` | compose profile `shared-tee` |
| `bispharma-twin` | BISPHARMASTAGING | `BISPHARMA_TWIN_ENABLED` in the host `.env` (default false) |
| `s7-reader` (+ `s7-softplc`) | INCOPLAST (demo tags) | compose profile `s7` |

Which profiles are active is set by `COMPOSE_PROFILES` in `/opt/packiot/.env` on the host, not in
git. The publishers themselves are described in [sparkplug-agent](sparkplug-agent.md) and
[simulators and twins](simulators-and-twins.md). `plc-sim` and `sparkplug-agent-cpack` publish the same CPACK namespace under different edge
nodes: running both double-sources ent 3. The compose file comments call this out.

### RabbitMQ exchanges and queues (`/` vhost)

| Exchange | Type | Declared by | Purpose |
|---|---|---|---|
| `oee` | topic, durable | stream-engine (and fanout) at connect | the main bus |
| `oee-retry` | topic | stream-engine | dead-letter target of every main queue |
| `oee-failed` | topic | stream-engine | terminal; stream-engine publishes here after `MAX_RETRIES` |
| `oee-unroutable` | fanout | `definitions.json` | alternate exchange of `oee` (policy `oee-ae`) |
| `edge.plc-normalized` (+ `-retry`, `dlx.`) | topic | sparkplug-decoder, only when `AMQP_SOURCE_ENABLED=true` (false on staging) | retired Node-RED input path |
| `edge.commands` (+ `-retry`, `-failed`) | topic | sparkplug-decoder command consumer, only when `EDGE_COMMANDS_ENABLED=true` (false) | operator → PLC write path |

| Queue | Arguments | Bound to | Consumer |
|---|---|---|---|
| `stream-engine-q` | DLX `oee-retry` | `oee` / `sparkplug.data` (exact) | stream-engine |
| `stream-engine-q-retry-30s` | TTL 30 000 ms, DLX `oee` | `oee-retry` / `#` | nobody (expires back to `oee`) |
| `stream-engine-q-failed` | none | `oee-failed` / `#` | humans |
| `stream-engine-q-<t>` | DLX `oee-retry` (+ `x-single-active-consumer` if `WORKER_POOL_SAC_ENABLED`) | `oee` / `sparkplug.data.<t>` | stream-engine |
| `stream-engine-q-<t>-retry-30s` | TTL 30 000 ms, DLX `oee` | `oee-retry` / `sparkplug.data.<t>` | nobody |
| `stream-engine-q-<t>-failed` | none | `oee-failed` / `sparkplug.data.<t>` | humans |
| `oeecloud-fanout-cpack-to-sbxcpack` | none | `oee` / `sparkplug.data`, `sparkplug.data.cpack` | oeecloud-fanout |
| `oee-unroutable-q` | none | `oee-unroutable` | humans (alert) |

`<t>` is every tenant that is **both** active in `packml_register` **and** listed in
`WORKER_TENANT_ALLOWLIST` (staging: `cpack,sbxcpack,bispharmastaging`). Queue names come from code
(`services/stream-engine/internal/amqp/topology.go`), so there is nothing to create by hand.
`docs/ops/rabbitmq-topology.md` lists the canonical 14-queue set.

Routing keys in use:

| Routing key | Published by |
|---|---|
| `sparkplug.data.<tenant>` | sparkplug-decoder (`F3_PER_TENANT_ROUTING=true` on staging) |
| `sparkplug.data` | sparkplug-decoder when per-tenant routing is off |
| `sparkplug.data.sbxcpack` | oeecloud-fanout (CPACK clone) |
| `sparkplug.data.incoplast` | ingest-shim (staging config) |

## Internal design

### Mosquitto

- **Persistence** is on (`persistence true`, `autosave_interval 30`), so retained NBIRTH messages
  survive a broker restart and a reconnecting subscriber gets its alias table back at once
  (ADR-0011 P0-2).
- `persistent_client_expiration 1h`, `max_packet_size 65536`, `max_keepalive 3600`.
- `init: true` in compose runs `tini` as PID 1 so healthcheck children get reaped (see
  [Failure modes](#failure-modes)).

### RabbitMQ: users and definitions

`rabbitmq.conf` sets `load_definitions = /etc/rabbitmq/definitions.json`, so users, permissions,
the `oee-ae` policy and the unroutable exchange/queue are **re-imported on every boot**. The file
contains passwords, so it is generated, not committed:

1. The deploy workflow step *Generate RabbitMQ definitions* (`.github/workflows/deploy-staging.yml`)
   reads the admin user/password from `/opt/packiot/.env` and the two service passwords from
   Secrets Manager (`packiot/staging/rabbitmq-stream-engine-creds`,
   `packiot/staging/rabbitmq-sparkplug-decoder-creds`).
2. It fills `monitoring/rabbitmq/definitions.template.json` and writes
   `/opt/packiot/rabbitmq/definitions.json` atomically (`.tmp` then `mv`).
3. Compose bind-mounts that host path read-only.

When definitions are imported, `RABBITMQ_DEFAULT_USER/PASS` are ignored; the admin user comes from
the file.

| User | configure / write / read regex (summary) |
|---|---|
| admin (name from `.env`) | `.*` |
| `stream-engine` | `oee`, `oee-retry`, `oee-failed`, `stream-engine-q.*`, `oeecloud-fanout.*` |
| `sparkplug-decoder` | configure `edge-transformer.*`, `outbox.*`, `edge.plc-normalized.*`; write also `oee`; read also `oee` |

oeecloud-fanout authenticates with the `stream-engine` secret. ingest-shim authenticates with the
`sparkplug-decoder` secret (it only publishes).

### RabbitMQ: retry and dead-letter loop

```text
 publisher ──▶ oee ──(rk)──▶ stream-engine-q-<t> ──▶ stream-engine
                                   │ handler error: nack(requeue=false)
                                   ▼
                              oee-retry ──▶ …-retry-30s (TTL 30 s) ──▶ back to oee
 after MAX_RETRIES (x-death count ≥ 5): stream-engine publishes to oee-failed and acks
                              oee-failed ──▶ …-failed  (kept until someone purges it)
```

The retry count is the sum of the `x-death` header counts (`xDeathCount` in
`internal/amqp/consumer.go`). Messages the handler cannot ever succeed on (bad JSON with legacy
ingest off, double-encoded envelopes, non-numeric values, unregistered topics) are **acked and
counted**, not retried, so they never loop.

### Retention

There is no TTL or length limit on main queues: a message stays until it is acked. Retry queues
hold a message for 30 s. `*-failed` queues and `oee-unroutable-q` keep messages until a human purges
them. Messages are published persistent (`DeliveryMode: Persistent` in the decoder and ingest-shim
publishers) to durable queues, so they survive a broker restart. The decoder's SQLite outbox
(see [sparkplug-decoder](sparkplug-decoder.md#outbox)) covers the time the broker is down.

## Configuration

| Variable / file | Where | Staging value | Effect |
|---|---|---|---|
| `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` | rabbitmq env ← `.env` | from `.env` | ignored once `definitions.json` loads |
| `monitoring/rabbitmq/enabled_plugins` | mount | `[rabbitmq_management,rabbitmq_prometheus]` | management UI + `:15692/metrics` |
| `monitoring/rabbitmq/rabbitmq.conf` | mount | `load_definitions = /etc/rabbitmq/definitions.json` | re-applies users/policies each boot |
| `/opt/packiot/rabbitmq/definitions.json` | host file | generated at deploy | users, permissions, `oee-ae` policy |
| `configs/mosquitto/mosquitto.conf` | mount | listener 1883, anonymous, persistence | see above |
| `WORKER_TENANT_ALLOWLIST` | stream-engine env | `cpack,sbxcpack,bispharmastaging` | which tenant queue triples exist |
| `WORKER_POOL_SAC_ENABLED` | stream-engine env | `false` | adds `x-single-active-consumer`; immutable, needs `services/stream-engine/scripts/migrate-tenant-queues-sac.sh` |
| `F3_PER_TENANT_ROUTING` | decoder env | `true` | `sparkplug.data.<t>` vs `sparkplug.data` |

## Data & invariants

- **Tenant isolation is by routing key.** Each tenant's envelopes go only to its own queue. The
  tenant is the lowercased first segment of the first metric name, both at the publisher and in
  the worker (`tenantOf` in `internal/handlers/sparkplug.go`).
- **Unroutable messages are kept, not lost.** A message on `oee` that matches no binding goes to
  `oee-unroutable-q` via the alternate exchange. The `oee-ae` policy is in `definitions.json` since
  PR #913 (2026-08-26). The compose comment near `F3_PER_TENANT_ROUTING` that says "the `oee`
  exchange has NO alternate-exchange" predates that and is stale.
- **Order**: RabbitMQ keeps order per queue. The stream-engine keeps order per `source_type` lane
  (`CONSUME_LANES`); retries re-enter at the tail, so a retried message lands after newer ones.
  The ingest writers are idempotent upserts, so this is safe for silver (see
  [stream-engine](stream-engine.md#data-invariants)).

## Observability

| Signal | Source |
|---|---|
| Queue depth per queue | Prometheus job `rabbitmq-detailed` (`rabbitmq_detailed_queue_messages{queue=…}`), scraping `rabbitmq:15692` |
| Aggregate broker metrics | Prometheus job `rabbitmq` |
| `OeeUnroutableMessages` alert | `rabbitmq_detailed_queue_messages{queue="oee-unroutable-q"} > 0` (`monitoring/prometheus/rules.yml`) |
| `IngestSilent` alert | no stream-engine AMQP deliveries in 10 min |
| `MQTTDisconnected`, `SparkplugSeqGapStream`, `TransformerMqttDrops` | decoder-side MQTT metrics |
| Mosquitto logs | stdout (`log_type` warning/error/notice/information) → promtail/Loki |

Dashboards and the rest of the monitoring stack: [observability](observability.md).

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| **Definitions file missing at boot (2026-09-25)** | RabbitMQ exits 127 after a host reboot; all ingest down | `definitions.json` was rendered into the CI runner workspace (gitignored); a later job's checkout deleted it; at boot dockerd created a *directory* at the bind source | PR #1447: render to `/opt/packiot/rabbitmq/` outside the workspace. Live recovery: remove the directory, regenerate from the template + Secrets Manager, start the container |
| **Least-privilege users lost (2026-07-10)** | every AMQP client gets 403 for ~1.5 h | broker recreated with a fresh Mnesia after a plugin change; users had been provisioned only at runtime | `load_definitions` re-imports users on every boot |
| **Decoder up before RabbitMQ (2026-09-25)** | decoder "healthy" but publishes nothing | publisher init failed once and was disabled for the process life | PR #1447: `analyticspub.NewWithRetry` retries for 3 min, then exits so the restart policy recycles it |
| **Queue sprawl (2026-08-19, cleaned again 2026-09-14)** | ~39 then 44 queues for tenants staging does not serve | queue triples are a projection of `packml_register`; prod→staging re-cuts brought foreign tenants and `_staging` name variants | `WORKER_TENANT_ALLOWLIST`; to prune: fix the register/allowlist first, restart stream-engine, then delete orphans (deleting first races the live consumer, which re-declares them) |
| **Mosquitto zombie PIDs (2026-07-09)** | deploys blocked ~1 day: mosquitto unhealthy, dependants never start | mosquitto ran as PID 1 and never reaped `docker exec` healthcheck children; 4578 zombies hit `pids.max` | `init: true` (tini) |
| **Per-listener anonymous (2026-08-03, production)** | prod deploy failed; `:1883` refused anonymous clients | adding an `allow_anonymous false` 8883 listener changed `:1883` too | `mosquitto.prod.conf` sets anonymous globally and secures 8883 with client certificates |
| **Tenant not allowlisted** | data for a new client never reaches silver; `oee-unroutable-q` grows | no queue bound for `sparkplug.data.<t>` | add the lowercased group to `WORKER_TENANT_ALLOWLIST` and redeploy |
| **Deploy chaos test** | RabbitMQ stops for a short time during every staging deploy | the step *Chaos test — kill RMQ, prove outbox durability* stops and restarts `stack-rabbitmq-1` | expected; the decoder outbox absorbs it. Do not deploy during a data-sensitive test |

!!! warning "Unverified: duplicate retries on tenant queues"
    From the code, the shared `stream-engine-q-retry-30s` is bound to `oee-retry` with `#`, and
    each `stream-engine-q-<t>-retry-30s` is bound with `sparkplug.data.<t>`. A message
    dead-lettered from a tenant queue therefore matches **both** retry queues and returns to the
    tenant queue twice. The same applies to `oee-failed`. Silver writes are idempotent upserts,
    so values are not doubled, but Bronze (`*_raw`, append-only) would get extra rows. Not
    checked against the live broker.

The deploy step *Extend RMQ perms for edge-transformer* still targets the old user name
`edge-transformer` and is `continue-on-error`. The live users come from `definitions.json`.

## Operating it

- **Shell access**: SSM into the app host, then `docker exec stack-rabbitmq-1 rabbitmqctl …`
  (`list_queues name messages consumers`, `list_bindings`). Management API at `127.0.0.1:15672`
  from the host.
- **Delete an orphan queue safely**: only if it is empty and unused
  (`DELETE /api/queues/%2F/<name>?if-empty=true&if-unused=true`), and only after the tenant is
  out of the allowlist and stream-engine was restarted.
- **Inspect a failed message**: read from `stream-engine-q-<t>-failed` in the management UI (Get
  messages, *Ack mode: Nack requeue true*). To replay, move it back to `oee` with its routing key.
- **Regenerate definitions** after a password rotation: rerun the deploy (or the same `sed` + `jq`
  steps), then restart RabbitMQ. Clients reconnect with backoff.
- **Safe**: restarting Mosquitto (retained births restore alias tables; the decoder can also
  request rebirths if enabled). **Unsafe**: recreating RabbitMQ without the definitions file, or
  flipping `WORKER_POOL_SAC_ENABLED` without the queue migration (406 `PRECONDITION_FAILED`).

## Tests

- Deploy chaos test in `.github/workflows/deploy-staging.yml` (stop RabbitMQ, inject 5 messages,
  restart, expect `outbox_depth` back to 0).
- `services/stream-engine/internal/amqp` unit tests cover topology declaration and lane routing
  (`go test ./internal/amqp/`).

## Source map

| Path | What's there |
|---|---|
| `compose.staging.yml` (`rabbitmq`, `mosquitto`, `plc-sim`, `sparkplug-agent-*`, `bispharma-twin`) | service definitions, profiles, IPs |
| `configs/mosquitto/mosquitto.conf` | staging/dev Mosquitto config |
| `configs/mosquitto/mosquitto.prod.conf`, `mosquitto-prod-ingest.conf`, `prod-ingest.acl` | production Mosquitto (mTLS on 8883) |
| `monitoring/rabbitmq/rabbitmq.conf`, `enabled_plugins`, `definitions.template.json` | broker config, users, `oee-ae` policy |
| `.github/workflows/deploy-staging.yml` | definitions generation, perms step, chaos test |
| `services/stream-engine/internal/amqp/topology.go` | exchange/queue/binding declaration |
| `services/stream-engine/internal/amqp/consumer.go` | lanes, retry counting, failed publish, tenant discovery loop |
| `services/stream-engine/scripts/migrate-tenant-queues-sac.sh` | one-time SAC queue migration |
| `services/sparkplug-decoder/internal/mqtt/subscriber.go` | MQTT subscription (`spBv1.0/#`, QoS 0, bounded queue) |
| `monitoring/prometheus/prometheus.yml`, `rules.yml` | scrape jobs and broker alerts |
| `docs/ops/rabbitmq-topology.md` | canonical queue set and the 2026-09-14 cleanup |
| `docs/adr/0011-durability-boundary-and-store-and-forward.md`, `docs/adr/0051-packml-register-generated-only-and-unroutable-alerting.md` | design decisions |
