---
title: Environments
layer: 1
owner_area: platform
last_verified: 2026-09-28
---
# Environments

> **Layer 1 · Architecture.** Where each environment runs, how you reach it, and what is
> live where. Up: [Architecture overview](overview.md)

## Overview

| Environment | What runs | Where | Deployed by |
|---|---|---|---|
| **Local** | The stack in Docker Compose (`the dev/ environment (ADR-0060; formerly compose.development.yml)`) with simulators | your machine | `make` / `docker compose` |
| **Staging** | The full new stack with real client data (CPACK co-tee, Bispharma live box, sandbox 2000003) | AWS us-east-1, EC2 (app host + DB host + NAT) | push/merge to `staging` → `deploy-staging.yml` |
| **Production (legacy)** | `packiot40` (tsp12): Postgres + Hasura + Node-RED oeecloud | legacy production hosts | outside this repo |
| **Production (new stack)** | Single-flow deployment (`compose.production.yml`, `public` schema) | AWS, production account resources in `terraform/production` | `production` branch; promotion is gated |
| **Edge** | Per-factory boxes (readers, sparkplug-agent, optional offline apps) | client sites; hybrid-activated SSM managed instances | edge-api box operations / SSM rail |

## Staging hosts

| Host | Instance | Role |
|---|---|---|
| `packiot-staging-app` | `i-06c9547a2c7091ab7` | All application containers (brokers, decoder, stream-engine, APIs, frontends' nginx, observability, historian gateway). Also the only host allowed to read the legacy DB secret. |
| `packiot-staging-db` | `i-064bb36d1c454d861` (private `10.10.10.89`) | TimescaleDB container `timescaledb` with `packiot_analytics` (and the old `packiot` DB). |
| `packiot-staging-nat` | `i-0d85d171e8e6abaeb` | NAT for private subnets. |

Access is through **AWS SSM** (`aws ssm send-command` / Session Manager). There are no SSH
keys to share. Containers created by compose carry their project/working-dir/config-files
labels; recreate a single service from those labels rather than from memory (see
[Runbooks](../operations/runbooks.md)).

## Staging URLs

| URL | What |
|---|---|
| `front.staging.packiot.app`, `staging.packiot.com` | front4 (product app, served by AWS Amplify from its `staging` branch) |
| `operator.staging.packiot.app`, `operator-sbx.staging.packiot.app` | operator app (CPACK / sandbox) |
| `csadmin.staging.packiot.app`, `customize.staging.packiot.app` | CS Admin, Customization Hub |
| `barcode.staging.packiot.app` | barcode app (sandbox tenant) |
| `bi.staging.packiot.app` | Superset |
| `auth.staging.packiot.app` | oauth2-proxy sign-in |
| `ingest.staging.packiot.app:8449`, `cpack-ingest.staging.packiot.app:8447` | HTTPS raw-tag front doors (`POST /v1/tags`) for edge readers → shared / CPACK sparkplug-agent; not behind CloudFront |
| `wiki.packiot.app` | this wiki |

Grafana, Adminer/CloudBeaver and other internal consoles are listed in
[Observability](../components/observability.md) and [Platform](../subsystems/platform.md).

## Data sources per tenant (staging)

| Tenant | Source of telemetry | Source of POs / operator actions |
|---|---|---|
| CPACK (3) | CPACK factory box co-tee into the cloud broker | legacy replication (analytics-sync) + apps |
| Bispharma (5) | live Bispharma box | apps |
| Sandbox (2000003) | mirror of CPACK | replication of CPACK + test writes; self-healing reset |
| Incoplast (4) | historical | — |

## Gotchas

- GitHub push events can reach Actions several minutes late; wait before dispatching a deploy
  by hand, or you will deploy twice.
- The historian gateway container is not managed by the deploy workflow; recreate it with its
  own env file (see [historian gateway](../components/historian-gateway.md)).
- Never run heavy Docker operations (large commits, storage-driver changes) on the shared app
  host; sandbox simulator boxes run as containers there.
