---
title: Reference
layer: 4
owner_area: platform
last_verified: 2026-10-13
---
# Reference

> **Look it up.** Facts, not explanations. Where a page is generated from code it says so,
> and you should change the code, not the page. Up: [Packiot docs](../index.md)

| Page | What's in it | Source of truth |
|---|---|---|
| [API reference](api/index.md) | Every HTTP operation of every API: parameters, bodies, responses, examples | OpenAPI specs in code, generated at build time |
| [Service catalog](service-catalog.md) | Every service with its README, wiki page, API spec, dashboards and source | This page (kept in sync in review) |
| [Repositories](repositories.md) | Every repository, which branch deploys where | `.gitmodules`, workflows |
| [Database reference](database-reference.md) | Schemas, key tables, ownership | `db/migrations/` |
| [Configuration](configuration.md) | Environment variables across services | Compose files and code |
| [Glossary](glossary.md) | Every Packiot word | — |
| [ADR index](adr-index.md) | Architecture decisions and their status | `docs/adr/` |
