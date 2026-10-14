# Packiot wiki: style guide and page templates

The wiki (`docs/wiki/`, served at wiki.packiot.app by mkdocs-material) is organised by
**what the reader is trying to do** (the [Diátaxis](https://diataxis.fr/) model), split by
audience. Put every page in exactly one section; if a page does two jobs, split it.

| Section | Folder | Reader's question | Page type | Audience |
|---|---|---|---|---|
| Home | `docs/wiki/index.md` | Where do I start? | entry | everyone |
| 1 · Learn | `learn/` | Teach me, step by step | **tutorial**: one guided path, ends with something working | new engineers, new CS staff |
| 2 · Use Packiot | `use/` | How do I do this in the product? | **how-to**, plain language, no jargon | Customer Success, automation team |
| 3 · Build & operate | `build/develop/`, `build/operate/` | How do I change or run the platform? | **how-to** / runbook: one task, commands, verification | engineers, on call |
| 4 · Understand | `understand/` (`architecture/`, `subsystems/`, `components/`) | How does it work, and why? | **explanation**, in the layers below | engineers |
| 5 · Reference | `reference/` (+ generated `reference/api/`) | Look it up | **reference**: facts, tables, generated pages | everyone |

Inside **Understand**, pages keep the layering: architecture (layer 1) → subsystems
(layer 2) → components (layer 3). Each links down for detail and up for context, so a
reader can stop at any layer and still hold a correct picture.

**Cross-linking contract** (the docs are one system, not four):

- Every service has a row in `reference/service-catalog.md` linking its README, component
  page, API reference and dashboard. Adding a service means adding the row.
- Every component page links its README and, if it serves HTTP, its API reference page.
- Every README links back to its component page and the service catalog.
- Every OpenAPI spec sets `externalDocs` to its component page.
- API reference pages are **generated** from `docs/api/openapi/*.openapi.json` by
  `scripts/wiki-openapi-to-md.py` at build time. Never hand-edit them; change the spec in
  code and run `make openapi` (edge-api: `npm run openapi:export`).
- Moving a page: add an entry to the `redirects` plugin in `wiki/mkdocs.yml` so old URLs
  keep working.

How-to and tutorial pages use this shape: **Goal** (one sentence) → **Before you start**
→ numbered **Steps** (each with the command and what you should see) → **Check it
worked** → **If it went wrong** → **Next**.

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

In **Understand**, `layer` is 1–3 as above; in Learn, Use and Build it is `0` (entry) or
`guide`; in Reference it is `4`. Generated API pages carry `generated: true`.

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
## History & decisions — key ADRs / incidents that shaped it (link ADRs as ../../reference/adr-index.md or the ADR file)
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
