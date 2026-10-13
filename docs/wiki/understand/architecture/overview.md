---
title: Architecture overview
layer: 1
owner_area: platform
last_verified: 2026-10-13
---
# Architecture overview

> **Layer 1 · Architecture.** The whole Packiot system on one page: the planes, the main
> data path, the action path, and how the new stack relates to the legacy platform.
> Up: [Understand Packiot](../index.md)

## The system in one picture

Everything right of the factory is the **new stack on staging**. Production clients still
run on the legacy platform (bottom left); see [Where the migration stands](#where-the-migration-stands).

```text
 FACTORY (per client)                       CLOUD — new stack (staging, AWS us-east-1)
 ┌─────────────────────────┐ HTTPS POST     ┌───────────────┐ Sparkplug B ┌────────────┐
 │ PLCs (S7/Modbus/OPC-UA) │ raw tags       │ sparkplug-    │  over MQTT  │ mosquitto  │
 │    │ polled             │──────────────▶ │ agent-shared  │────────────▶│ (broker)   │
 │    ▼                    │ :8449 /v1/tags │ (multi-tenant)│             └─────┬──────┘
 │ reader on the edge box  │ :8447 /v2/tags └───────────────┘                   │
 │ (or CPACK's factory     │ (CPACK)                                    ┌──────▼───────┐
 │  Node-RED tee)          │                                            │ sparkplug-   │
 └─────────────────────────┘                                            │ decoder (Go) │
                                                                        │ increments,  │
                                                                        │ outbox       │
                                                                        └──────┬───────┘
                                                                  AMQP         │
                                                               ┌───────────────▼──────┐
                                                               │ RabbitMQ  exchange   │
                                                               │ `oee`, queue per     │
                                                               │ tenant               │
                                                               └───────────────┬──────┘
 LEGACY (production)                                           ┌───────────────▼──────┐
 ┌──────────────────┐  POs, operator actions, dims             │ stream-engine (Go)   │
 │ packiot40/tsp12  │──▶ legacy-replicator / analytics-sync ─┐ │ writers + rollups,   │
 │ Postgres+Hasura  │                                        │ │ events, PO compute   │
 └──────────────────┘                                        │ └───────────────┬──────┘
        ▲ oracle for validation                              ▼                 ▼ SQL
        │                              ┌─────────────────────────────────────────────┐
        │                              │ packiot_analytics (TimescaleDB, DB host)    │
        │                              │ bronze → silver → gold → serving            │
        │                              │ core · config · identity · ops              │
        │                              └──────┬──────────────────────────┬───────────┘
        │                          FDW (live) │                          │ SQL
        │                     ┌───────────────▼──────────┐     ┌─────────▼──────────┐
        │                     │ historian gateway        │────▶│ read-api  (reads)  │
        │                     │ live + cold S3 Parquet   │     │ edge-api  (writes, │
        │                     │ (2021 → now)             │     │   admin)           │
        │                     └──────────────────────────┘     │ Superset  (BI)     │
        │                                                      └─────────┬──────────┘
        │                                                                │ HTTPS
        │                                      ┌─────────────────────────▼──────────┐
        │                                      │ front4 · operator · csadmin ·      │
        │                                      │ customize · barcode app            │
        │                                      └────────────────────────────────────┘
```

Read it as two loops that meet in the database:

- **The data loop** (top → down): a machine's counter travels from the PLC to a reader at the
  factory, over HTTPS to the cloud's shared Sparkplug agent, through MQTT to the decoder, is
  queued per tenant, written as raw facts, and rolled up into OEE.
- **The action loop** (bottom → up): people act through the frontends (start a production
  order, justify a stop, onboard a line); `edge-api` validates and writes those actions,
  and the next rollup tick folds them into the numbers everyone reads. For CPACK on staging
  the actions come from legacy instead (see [A counter's journey](data-journey.md#what-can-change-the-number-after-it-lands)).

## The planes

| Plane | What it owns | Main parts | Layer 2 |
|---|---|---|---|
| **Edge** | Reading PLCs, turning readings into a Sparkplug B session, crossing the WAN; offline operation | PLC readers, sparkplug-agent (shared in the cloud or on the box), edge box | [Edge](../subsystems/edge.md) |
| **Ingestion** | Getting telemetry from MQTT into the analytics DB durably and per tenant | mosquitto, sparkplug-decoder, RabbitMQ, ingest-shim, stream-engine writers | [Ingestion](../subsystems/ingestion.md) |
| **Compute** | Every derived number: rollups (hour/shift/day/…), events and downtime, PO runtime | stream-engine jobs | [Compute](../subsystems/compute.md) |
| **Storage** | The system of record for the new stack, and long history | analytics DB, historian | [Analytics DB](../subsystems/analytics-db.md), [Historian](../subsystems/historian.md) |
| **Legacy bridge** | Replicating what still originates in legacy (POs, operator actions, dimensions) | analytics-sync, legacy-replicator | [Legacy bridge](../subsystems/legacy-bridge.md) |
| **Serving** | APIs the apps call: reads, writes/admin, BI | read-api, edge-api, operator-gateway, barcode-service, Superset | [Serving & APIs](../subsystems/serving-apis.md) |
| **Experience** | The five web apps | front4, operator, csadmin, customize, barcode app | [Frontends](../subsystems/frontends.md) |
| **Identity** | Who you are and which tenant you may touch | Cognito, oauth2-proxy, api-keys, Postgres RLS | [Identity](../subsystems/identity.md) |
| **Platform** | Hosts, compose, CI/CD, Terraform, observability, this wiki | EC2, GitHub Actions, Prometheus/Grafana/Loki/Tempo | [Platform](../subsystems/platform.md) |

Every service has a row in the [service catalog](../../reference/service-catalog.md). Every
HTTP API publishes an OpenAPI document (the Go services at `GET /openapi.json`, edge-api at
`/packiot/docs-json`), browsable in the staging portal `https://api.staging.packiot.app/docs/`
(cs-admin SSO) and rendered as generated pages under [API reference](../../reference/api/index.md).

## Design principles you will see everywhere

1. **Read, write and compute are separate services.** Reads go through `read-api` (and
   `serving.*` SQL); writes and admin actions go through `edge-api`; all derived numbers are
   computed by `stream-engine` jobs. The database stores and constrains; it does not host the
   OEE logic (unlike legacy, where triggers and stored procedures did the math).
2. **Raw first, derive later, recompute anytime.** Raw telemetry lands in bronze/silver
   untouched by business rules; OEE grains in gold are recomputed from silver by idempotent
   jobs driven by `recalc_needed` flags. A bug fix means "fix the SQL, re-flag, recompute",
   never hand-editing numbers.
3. **Store what was measured.** Since 2026-09-29 the data keeps out-of-range facts (gross
   below net, Performance above 1) instead of clamping them; the UI decides how to show them.
   See [Domain model › OEE](domain-model.md#oee).
4. **The tenant comes from the credential, never from the request.** Every API resolves the
   caller's enterprise server-side (api-key or Cognito JWT) and fences reads and writes to it;
   Postgres row-level security backs it up. See [Tenancy & security](tenancy-and-security.md).
5. **Durable at every hop.** Readers spool to disk when offline, the agent and the decoder
   write an outbox before publishing (the decoder also checkpoints its counter baselines
   there), RabbitMQ persists, writers are idempotent on natural keys. A restart loses nothing.
6. **Prove parity with the oracle.** The new stack is validated against legacy using the
   comparisons legacy can be trusted for (raw meters, hourly rows); see
   [Domain model › comparing with legacy](domain-model.md#comparing-with-legacy).

## Where the migration stands

| Aspect | State (2026-10-13) |
|---|---|
| Write flows | One flow into `packiot_analytics` (`bronze`/`silver`/`gold`/`core`/… schemas). The old parallel F1/F2 shadow flows are gone; `mirror-worker-go` was retired on 2026-08-13 (compose profile `legacy-comparator`, off). |
| Clients on the new stack (staging) | CPACK (enterprise 3: factory tee into the shared agent, plus legacy-replicated POs and operator actions), Bispharma (5: live box), Incoplast (4: an HTTPS tee path through ingest-shim is configured), sandbox twin 2000003. |
| History | CPACK history back to 2021 in the historian (cold Parquet copied from legacy), served together with live data. |
| Production | **Still the legacy platform for every client.** The new-stack production environment is defined (`compose.production.yml`, `terraform/production`, `deploy-production.yml` on push to `production`) and its EC2 hosts exist, but promotion has not happened: the release is the draft PR #1653 (`release/prod-promotion-2026-10` → `production`). |
| Logins | Cognito user pool `us-east-1_0T9t1sTwt`, in-app (Amplify) plus oauth2-proxy at the nginx edge. Firebase login is retired on staging. |
| PackML naming | Metrics are still identified by their PackML topic (`packml_register`, a view over `core.topic_routing`). ADR-0061 (removing PackML from the cloud) is in progress; birth-bound device binding is wired but switched off on staging. |

## Go deeper

- Follow one value end to end: [A counter's journey](data-journey.md)
- The vocabulary and math: [Domain model](domain-model.md)
- Hosts, URLs and environments: [Environments](environments.md)
- Security model: [Tenancy & security](tenancy-and-security.md)
