# Packiot wiki: style guide and page templates

The wiki (`docs/wiki/`, served at wiki.packiot.app by mkdocs-material) is written in
**layers**. Every page belongs to exactly one layer and links down to the next layer for
detail and up to the previous one for context. A reader should be able to stop at any
layer and still hold a correct (if less detailed) picture.

| Layer | Folder | Answers | Typical length |
|---|---|---|---|
| 0 Start here | `docs/wiki/` (index, glossary, reading paths) | What is Packiot? Where do I start? | short |
| 1 Architecture | `docs/wiki/architecture/` | How does the whole system fit together? | medium |
| 2 Subsystems | `docs/wiki/subsystems/` | What does this part of the system own; what are its parts; how do they talk? | medium |
| 3 Components | `docs/wiki/components/` | How does this one deployable unit work, down to config, SQL, jobs and failure modes? | long |
| 4 Reference & operations | `docs/wiki/reference/`, `docs/wiki/operations/` | Look something up; do a task step by step | any |

## Non-negotiable rules

1. **Verify every fact in the source.** Read the code, compose files, migrations, Terraform
   and workflows. Do not copy claims from older docs without checking them; older docs
   (`docs/archive/wiki-v1/`, `docs/guide/`, `docs/wiki/` numbered pages) are often stale.
   If you cannot verify something, leave it out or mark it `!!! warning "Unverified"`.
2. **Cite sources.** Every layer-3 page ends with a *Source map* table of repo paths.
   Inline, refer to code as `` `services/stream-engine/internal/rollup/shift.go` ``.
3. **Staging vs production.** Say which environment a fact applies to. Staging is the
   new stack (Docker Compose on EC2 + Timescale). Production still runs the legacy
   platform (packiot40 / "tsp12", Hasura, Node-RED oeecloud) for most clients.
   Never describe a staging-only thing as production.
4. **No secrets.** Never paste keys, passwords, tokens, api_keys or full connection
   strings. Name the secret (e.g. Secrets Manager `databaseCredentials`) instead.
5. **Diagrams are text.** mkdocs-material would load Mermaid from a CDN, which the site
   forbids (served behind oauth2 with a strict origin). Use fenced ` ```text ` blocks with
   box-and-arrow ASCII. Keep them ≤ 100 columns.
6. **Relative links only**, from the page's own folder, e.g. `../components/stream-engine.md`.
   Link to headings with `#anchor`. Links must resolve: the build is link-checked.
7. **Plain English, precise.** Short sentences. Define a term on first use or link to
   the glossary. Prefer tables for config, ports, env vars and comparisons.
8. **Write only in the paths you were assigned.** Do not edit other pages; note
   cross-links you need in your report instead.

## Page front matter

Every page starts with:

```markdown
---
title: <Human title>
layer: <0|1|2|3|4>
owner_area: <edge|ingestion|compute|analytics-db|historian|legacy-bridge|serving|frontends|identity|platform>
last_verified: 2026-09-28
---
# <Human title>

> **Layer N · <Layer name>** — one sentence saying what this page covers and who it is for.
> Up: [<parent page>](<relative link>)
```

## Layer 2 template (subsystem page)

```markdown
## Purpose            — what this subsystem is for, in 3–5 sentences
## Boundaries         — what it owns, what it explicitly does NOT own
## Components         — table: component | what it does | runtime | layer-3 link
## How it works       — the main flow(s), with one text diagram
## Interfaces         — inbound/outbound: protocol, topic/queue/table/endpoint, producer→consumer
## Data it owns       — tables/topics/files and their lifecycle
## Configuration that matters — the few knobs that change behaviour
## Failure modes & signals    — what breaks, how you notice (metric/log/symptom), where to look
## History & decisions — key ADRs / incidents that shaped it (link ADRs as ../reference/adr-index.md or the ADR file)
## Go deeper          — links to the layer-3 pages
```

## Layer 3 template (component page)

```markdown
## Responsibility     — one paragraph; the single thing this component is accountable for
## At a glance        — table: language/runtime, repo path, container/service name, image,
                        host (staging), ports, depends on, depended on by
## Inputs & outputs   — exact topics/queues/tables/endpoints read and written
## Internal design    — modules/packages, main loops/jobs (name, interval, what each tick does),
                        request handling, key algorithms; include the actual SQL/logic essentials
## Configuration      — table of every env var: name | default | staging value | effect
## Data & invariants  — what it guarantees (idempotency, ordering, tenancy fences, clamps)
## Observability      — metrics, log lines worth grepping, dashboards, health checks
## Failure modes      — known failure → symptom → cause → fix (include real incidents with dates)
## Operating it       — deploy, restart, backfill/repair procedures, safe vs unsafe actions
## Tests              — unit/golden/e2e and how to run them
## Source map         — table: path | what's there
```

Sections may be skipped only if genuinely not applicable (say so in one line).

## Conventions

- Tenants: CPACK = analytics enterprise 3 (legacy enterprise 1); Bispharma = 5;
  sandbox twin of CPACK = 2000003 (ids +2,000,000); Incoplast = 4.
- Equipment types: tp_equipment 1 = machine, 2 = sector, 3 = line.
- Time: shift/hour rows are UTC `timestamptz`; factory local time is America/Sao_Paulo (BRT).
- Say "analytics DB" (`packiot_analytics`, the new stack's TimescaleDB) vs
  "legacy DB" (`packiot40`/tsp12) vs "historian" (`packiot_historian` gateway + S3 parquet).
