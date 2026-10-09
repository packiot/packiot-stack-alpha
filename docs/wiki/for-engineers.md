---
title: For engineers
layer: 0
owner_area: platform
last_verified: 2026-09-29
---
# For engineers

> **Layer 0 · Engineering entry point.** The technical side of the wiki: architecture,
> subsystems, components, reference and operations, with ADR links. If you are on the
> automation or Customer Success team, start at [Start here](index.md) instead.

## What Packiot is

Packiot is an **industrial IoT / OEE platform** for manufacturing. It reads counters, speed
and state from the PLCs that run factory machines, turns that raw signal into **OEE**
(Overall Equipment Effectiveness = Availability × Performance × Quality), and serves it to
three audiences: plant managers (dashboards and reports), machine operators (the shop-floor
app where they start production orders and justify downtime) and Packiot's Customer
Success team (the admin tools that onboard a new factory).

Two platforms exist side by side today:

| | New stack (this repo) | Legacy platform |
|---|---|---|
| Where | Staging on AWS EC2 (Docker Compose), historian on S3 | Production (`packiot40`, a.k.a. tsp12) |
| Compute | Go services (`sparkplug-decoder`, `stream-engine`) | Node-RED `oeecloud` + PostgreSQL triggers/procedures |
| Storage | TimescaleDB `packiot_analytics` + historian (DuckDB over S3 Parquet) | PostgreSQL + Hasura |
| Status | Receives real client data (CPACK, Bispharma) in parallel; not yet the system of record for most clients | Serves production clients |

The legacy platform is the **reference** ("oracle") the new stack is validated against, and
the source it replicates from during the migration. See
[Architecture overview](architecture/overview.md#where-the-migration-stands).

## How this wiki is layered

Each layer answers a different question and links down for detail. You can stop at any
layer and still have a correct picture.

```text
 Layer 0  Start here           what is it, where do I begin              (index, guides, glossary)
    │
 Layer 1  Architecture         how the whole system fits together        architecture/
    │
 Layer 2  Subsystems           what each part owns, how parts talk       subsystems/
    │
 Layer 3  Components           how one service works, to the last knob   components/
    │
 Layer 4  Reference & ops      look it up · do the task                  reference/  operations/
```

## Reading paths

| You are… | Read, in order |
|---|---|
| **New engineer** | [Architecture overview](architecture/overview.md) → [A counter's journey](architecture/data-journey.md) → [Domain model](architecture/domain-model.md) → the subsystem you'll work on → its component pages |
| **Customer Success** | Plain-language guides first: [Setting up a new client](guide/setting-up-a-client.md) and [Customizing a client](guide/customize/index.md). Technical detail: [Domain model](architecture/domain-model.md) → [Onboarding a client (technical)](operations/onboarding-a-client.md) → [Edge subsystem](subsystems/edge.md) |
| **Data / DBA** | [Analytics DB](subsystems/analytics-db.md) → [Database reference](reference/database-reference.md) → [DBA guide](operations/dba-guide.md) → [Historian](subsystems/historian.md) |
| **On call / ops** | [Environments](architecture/environments.md) → [Platform](subsystems/platform.md) → [Runbooks](operations/runbooks.md) → [Observability](components/observability.md) |
| **Frontend** | [Frontends](subsystems/frontends.md) → [Identity](subsystems/identity.md) → [Serving & APIs](subsystems/serving-apis.md) → [API endpoints](reference/api-endpoints.md) |
| **Security review** | [Tenancy & security](architecture/tenancy-and-security.md) → [Identity](subsystems/identity.md) → [edge-api](components/edge-api.md) |

## The map

| Layer 1 · Architecture | Layer 2 · Subsystems |
|---|---|
| [Overview](architecture/overview.md) | [Edge](subsystems/edge.md) · [Ingestion](subsystems/ingestion.md) · [Compute](subsystems/compute.md) |
| [A counter's journey](architecture/data-journey.md) | [Analytics DB](subsystems/analytics-db.md) · [Historian](subsystems/historian.md) · [Legacy bridge](subsystems/legacy-bridge.md) |
| [Domain model](architecture/domain-model.md) | [Serving & APIs](subsystems/serving-apis.md) · [Frontends](subsystems/frontends.md) · [Identity](subsystems/identity.md) |
| [Tenancy & security](architecture/tenancy-and-security.md) · [Environments](architecture/environments.md) | [Platform & operations](subsystems/platform.md) |

Terms you don't know are in the [glossary](glossary.md). How to write for this wiki:
`docs/WIKI-STYLE.md` in the repo.
