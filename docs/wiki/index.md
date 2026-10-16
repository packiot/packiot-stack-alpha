---
title: Packiot docs
layer: 0
owner_area: platform
last_verified: 2026-10-13
---
# Packiot docs

Packiot is an **industrial IoT / OEE platform**. A small box in each factory reads counters
and machine states from the PLCs, the cloud turns them into **OEE** (Availability ×
Performance × Quality), and three apps put the result in front of people: dashboards for
plant managers, a tablet app for machine operators, and admin tools for our Customer
Success team.

## Start where you are

| I am… | Start here | Then |
|---|---|---|
| **Customer Success or the automation team** | [Use Packiot — start here](use/index.md) | [Set up a client](use/setting-up-a-client.md) · [Customize a client](use/customize/index.md) · [Troubleshoot OEE](use/troubleshooting-oee.md) |
| **An engineer, new to Packiot** | [Your first week](learn/first-week.md) | [Understand Packiot](understand/index.md) · [Develop](build/index.md#develop) |
| **QA / testing** | [Sandbox for testing](use/sandbox-for-testing.md) | [Operator app](understand/components/operator-app.md) · [Barcode app](understand/components/barcode-app.md) |
| **Product or management** | [Test environments, explained](learn/test-environments.md) | [Sandbox for testing](use/sandbox-for-testing.md#the-reset-rule) |
| **On call, something is broken** | [Runbooks](build/operate/runbooks.md) | [Environments](understand/architecture/environments.md) · [Observability](understand/components/observability.md) |
| **Integrating with an API** | [API reference](reference/api/index.md) | [Service catalog](reference/service-catalog.md) · [Tenancy & security](understand/architecture/tenancy-and-security.md) |

## How these docs are organised

The site is split by **what you are trying to do**, not by team:

| Section | It answers | Style |
|---|---|---|
| [**1 · Learn**](learn/index.md) | "Teach me, step by step" | Guided tutorials you follow from start to finish |
| [**2 · Use Packiot**](use/index.md) | "How do I do this in the product?" | Plain-language how-tos for Customer Success and the automation team |
| [**3 · Build & operate**](build/index.md) | "How do I change or run the platform?" | Engineering how-tos and runbooks |
| [**4 · Understand**](understand/index.md) | "How does it work, and why?" | Architecture → subsystems → components, with the decisions behind them |
| [**5 · Reference**](reference/index.md) | "Look it up" | APIs (generated from the code), service catalog, database, configuration, glossary, ADRs |

!!! info "Where else to look"
    - **Interactive API docs:** the read-only Swagger portal at
      [api.staging.packiot.app/docs](https://api.staging.packiot.app/docs/) (SSO). The
      [API reference](reference/api/index.md) here is generated from the same specs.
    - **Each repository's README** explains how to run and change that one service; the
      [service catalog](reference/service-catalog.md) links every README, wiki page, API spec
      and dashboard together.
    - **Decisions** live in the [ADR index](reference/adr-index.md).
