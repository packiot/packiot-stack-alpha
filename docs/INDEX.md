# Documentation index

> **New here? [`GUIDE.md`](GUIDE.md) is the front door** — one linear
> walk from PLC signal to PowerBI dashboard, with the code map, the
> glossary, and routes into everything below.
>
> Start here. New to the project? Read `overview/` top to bottom
> (managers: just 00; engineers: all of it, then 05's guided tour).
>
> Structure rule: **overview/** = the durable story · **adr/** = why
> decisions were made · **adr/reference/** = captured legacy ground
> truth · **guides/** = how to do things · **audits/** = point-in-time
> findings (dated, never updated) · **archive/** = superseded (kept
> for history, do not cite).

## overview/ — read first

| Doc | For | One line |
|---|---|---|
| [00-executive-summary](overview/00-executive-summary.md) | management | what, why, proof, what remains |
| [01-architecture](overview/01-architecture.md) | engineers | prod flow vs new stack, DB layers, the engine's jobs |
| [02-what-was-done](overview/02-what-was-done.md) | both | the journey by ADR; the port table; incidents |
| [03-prod-vs-new-differences](overview/03-prod-vs-new-differences.md) | reviewers/auditors | EVERY deliberate divergence, justified |
| [04-verification](overview/04-verification.md) | engineers | the 0/32,848 methodology; harness usage; artifact classes |
| [05-onboarding](overview/05-onboarding.md) | new team members | first-week guided tour + golden rules |
| [06-state-and-continuation](overview/06-state-and-continuation.md) | whoever continues | live snapshot: fleet status, URLs, dashboards, DB validation, remaining tasks |
| [07-endgame-roadmap](overview/07-endgame-roadmap.md) | whoever continues | THE sequenced plan to the finish line: phases A-G (flip → stabilize → Hasura → schema → process split → prod), handoff protocol |

## Contracts & living references (stable paths — linked from CI/PR template)

- [PORTING.md](PORTING.md) — the nine-step law for porting legacy code (**enforced in review**)
- [consumer-idempotency-checklist.md](consumer-idempotency-checklist.md) — ADR-0011 reviewer checklist
- [BUSINESS-RULES.md](BUSINESS-RULES.md) — domain rules (PO lifecycle, shifts, equipment types)
- [TOPICS.md](TOPICS.md) — messaging topics/routing keys
- [clients/](clients/) — per-tenant config schemas

## adr/ — decisions (numbered, immutable once accepted)

The spine:
[0010](adr/0010-sparkplug-decode-in-go-end-state.md) (ingest in Go) ·
[0011](adr/0011-durability-boundary-and-store-and-forward.md) (durability rules) ·
[0012](adr/0012-schema-refactor-and-multitenancy-pool.md) (schema waves) ·
[0014](adr/0014-extract-oee-math-from-database-to-app.md) (the engine port) ·
[0016](adr/0016-staging-consolidation-master-plan.md) (consolidation master plan) →
[0017](adr/0017-endgame-process-separation-and-enterprise-hardening.md) (endgame: process split + enterprise hardening).
Full list: `ls docs/adr/`.

### adr/reference/ — ground truth, by kind ([taxonomy](adr/reference/README.md))

Living at top level: **[0016-flip-runbook](adr/reference/0016-flip-runbook.md)**
· [naming-ledger](adr/reference/naming-ledger.md)
· [0016-endstate-schema-map](adr/reference/0016-endstate-schema-map.md)
· [0012-phase4-execution-plan](adr/reference/0012-phase4-execution-plan.md).
Filed: `captures/` (immutable legacy bodies — every port cites one)
· `designs/` (port designs & inventories) · `migrations/`
(as-executed staging SQL).

## guides/ — how-to

- [edge-transformer-phase-2-runbook](guides/edge-transformer-phase-2-runbook.md) · [publisher guide](guides/edge-transformer-phase-2-5-publisher-guide.md) · [PLC wiring](guides/edge-transformer-phase-2-5b-plc-wiring-guide.md)
- [manual-smoke-check](guides/manual-smoke-check.md) — 10-minute hop-by-hop liveness triage (layers 0-5; freshness finds WHERE, the comparator finds WHETHER)
- [powerbi-compatibility-test-plan](guides/powerbi-compatibility-test-plan.md) — the 37+1-object flip gate
- [adr-0010-phase-3-shadow-mode-panels](guides/adr-0010-phase-3-shadow-mode-panels.md) — plus live boards in `grafana/dashboards/` (the flip gate reads `/d/bake-flow-parity`)

## audits/ — dated findings (historical record; check dates before acting)

- [hasura-review-2026](audits/hasura-review-2026.md) — 165 tables tracked, 4% used → retirement case
- [prod-staging-3flow-comparison-2026-07](audits/prod-staging-3flow-comparison-2026-07.md)
- [3-flow-parity-status](audits/3-flow-parity-status.md) · [caching-review-2026-06-29](audits/caching-review-2026-06-29.md)
- [prod-packml-register-llll-corruption](audits/prod-packml-register-llll-corruption.md)

## product/ · archive/

`product/` — product-side notes. `archive/` — superseded documents
(the old OVERVIEW.md, pre-0016 migration plans, edge-nodered refactor
notes, out-of-scope ledger). Kept for history; do not cite in new work.
