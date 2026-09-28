---
title: Architecture overview
layer: 1
owner_area: platform
last_verified: 2026-09-28
---
# Architecture overview

> **Layer 1 · Architecture.** The whole Packiot system on one page: the planes, the main
> data path, the control path, and how the new stack relates to the legacy platform.
> Up: [Home](../index.md)

## The system in one picture

```text
 FACTORY (per client)                          CLOUD — new stack (staging, AWS us-east-1)
 ┌──────────────────────────┐   HTTPS POST      ┌──────────────┐ Sparkplug ┌──────────────┐
 │ PLCs (S7, Modbus, OPC-UA)│   /v1/tags        │ sparkplug-   │  B / MQTT │ mosquitto    │
 │     │ polled              │── (raw tags) ───▶│ agent        │──────────▶│ (MQTT broker)│
 │     ▼                    │   :8449 / :8447   │ (shared,     │           └──────┬───────┘
 │ thin reader (edge box,   │                   │ multi-tenant)│                  │ MQTT
 │ SSM-managed, disk spool) │                   └──────────────┘           ┌──────▼──────────┐
 │ [optional offline apps]  │  (alt. shape: agent on the box → mTLS MQTT) │ sparkplug-      │
 └──────────────────────────┘                                            │ decoder (Go)    │
                                                                         │ decode · route  │
                                                                         │ counters · guard│
                                                                         └───────┬─────────┘
                                                             outbox → AMQP      │
                                                                        ┌───────▼─────────┐
                                                                        │ RabbitMQ (bus)  │
                                                                        └───────┬─────────┘
                                                                        ┌───────▼─────────┐
 LEGACY (production)                                                    │ stream-engine   │
 ┌───────────────────┐   replicate POs, operator actions, dims          │ (Go) writers +  │
 │ packiot40 / tsp12 │───────────────────────▶ analytics-sync ─────────▶│ rollups, events,│
 │ Postgres + Hasura │   (legacy-replicator)                            │ PO control      │
 └───────────────────┘                                                  └───────┬─────────┘
         ▲ oracle for validation                                                │ SQL
         │                                          ┌───────────────────────────▼───────────┐
         │                                          │ packiot_analytics (TimescaleDB)        │
         │                                          │ bronze → silver → gold → serving       │
         │                                          │ core (dims) · config · identity · ops  │
         │                                          └───────┬──────────────────────┬─────────┘
         │                                    FDW (live)    │                      │ reads/writes
         │                          ┌───────────────────────▼───┐        ┌─────────▼──────────┐
         │                          │ historian gateway         │        │ read-api (Go, reads)│
         │                          │ pg_duckdb: live + cold S3 │◀───────│ edge-api (NestJS,   │
         │                          │ Parquet (2021 → now)      │  long  │  writes + admin)    │
         │                          └───────────────────────────┘ ranges │ superset (BI)       │
         │                                                               └─────────┬──────────┘
         │                                                                         │ HTTPS
         │                                    ┌─────────────────────────────────────▼──────────┐
         │                                    │ front4 · operator · csadmin · customize ·      │
         │                                    │ barcode app      (behind CloudFront + Cognito) │
         │                                    └────────────────────────────────────────────────┘
```

Read it as two loops that meet in the database:

- **The data loop** (left → down): a machine's counter travels from the PLC to a reader on the
  edge box, over HTTPS to the cloud's Sparkplug agent, through MQTT to the decoder, is queued,
  written as raw facts, and rolled up into OEE.
- **The action loop** (bottom → up): people act through the frontends (start a production
  order, justify a stop, onboard a line); `edge-api` validates and writes those actions,
  and the next rollup tick folds them into the numbers everyone reads.

## The planes

| Plane | What it owns | Main parts | Layer 2 |
|---|---|---|---|
| **Edge** | Reading PLCs, turning readings into a Sparkplug B session, crossing the WAN; offline operation | PLC readers, sparkplug-agent (shared in the cloud or on the box), edge box, edge Node-RED | [Edge](../subsystems/edge.md) |
| **Ingestion** | Getting telemetry from MQTT into the analytics DB durably and per tenant | mosquitto, sparkplug-decoder, RabbitMQ, ingest-shim | [Ingestion](../subsystems/ingestion.md) |
| **Compute** | Every derived number: rollups (hour/shift/day/…), events and downtime, PO runtime | stream-engine | [Compute](../subsystems/compute.md) |
| **Storage** | The system of record for the new stack, and long history | analytics DB, historian | [Analytics DB](../subsystems/analytics-db.md), [Historian](../subsystems/historian.md) |
| **Legacy bridge** | Replicating what still originates in legacy (POs, operator actions, dimensions) | analytics-sync (legacy-replicator) | [Legacy bridge](../subsystems/legacy-bridge.md) |
| **Serving** | APIs the apps call: reads, writes/admin, BI | read-api, edge-api, operator-gateway, superset | [Serving & APIs](../subsystems/serving-apis.md) |
| **Experience** | The five web apps | front4, operator, csadmin, customize, barcode app | [Frontends](../subsystems/frontends.md) |
| **Identity** | Who you are and which tenant you may touch | Cognito, oauth2-proxy, api-keys, RLS | [Identity](../subsystems/identity.md) |
| **Platform** | Hosts, compose, CI/CD, Terraform, observability, this wiki | EC2, GitHub Actions, Prometheus/Grafana/Loki/Tempo | [Platform](../subsystems/platform.md) |

## Design principles you will see everywhere

1. **Read, write and compute are separate services.** Reads go through `read-api` (and
   `serving.*` SQL); writes and admin actions go through `edge-api`; all derived numbers are
   computed by `stream-engine` jobs. The database stores and constrains; it does not host the
   OEE logic (unlike legacy, where triggers and stored procedures did the math).
2. **Raw first, derive later, recompute anytime.** Raw telemetry lands in bronze/silver
   untouched by business rules; OEE grains in gold are recomputed from silver by idempotent
   jobs driven by `recalc_needed` flags. A bug fix therefore means "fix the SQL, re-flag,
   recompute" — never hand-editing numbers.
3. **The tenant comes from the credential, never from the request.** Every API resolves the
   caller's enterprise server-side (api-key or Cognito JWT) and fences reads and writes to it;
   the analytics DB adds row-level security for BI. See
   [Tenancy & security](tenancy-and-security.md).
4. **Durable at every hop.** The edge buffers when offline, the decoder writes an outbox
   before publishing, RabbitMQ persists, writers are idempotent on natural keys. A restart
   anywhere loses nothing.
5. **Prove parity with the oracle.** The new stack is validated against legacy using the
   comparisons that legacy can be trusted for (raw meters, hourly rows) — see
   [Domain model › comparing with legacy](domain-model.md#comparing-with-legacy).

## Where the migration stands

| Aspect | State (2026-09-28) |
|---|---|
| Write flows | One live flow into `packiot_analytics` (`silver`/`gold`/`core` schemas). The old parallel "F1/F2/F3" shadow flows are retired (`services/stream-engine/internal/flows/flows.go`). |
| Clients on the new stack | CPACK (co-tee from its factory box, plus the legacy-replicated POs/actions), Bispharma (live box), sandbox twin 2000003. |
| History | CPACK history back to 2021 in the historian (cold Parquet from legacy), served with the live data. |
| Production | Legacy (`packiot40`) remains the system of record for production clients. New-stack production (`compose.production.yml`) exists as a single-flow `public`-schema deployment; promotion is a separate, gated step. |
| Logins | Cognito (user pool `us-east-1_0T9t1sTwt`) through oauth2-proxy and app-level Amplify; Authentik references in old comments are obsolete. |

## Go deeper

- Follow one value end to end: [A counter's journey](data-journey.md)
- The vocabulary and math: [Domain model](domain-model.md)
- Hosts, URLs and environments: [Environments](environments.md)
- Security model: [Tenancy & security](tenancy-and-security.md)
