# Documentation Hub

> The single entry point for engineers, ops, and product touching the Packiot stack. Start here.

---

## 🚀 If you're new, read these in order

1. **[`OVERVIEW.md`](./OVERVIEW.md)** ← **START HERE.** Narrative-form intro to what Packiot is and why the codebase is shaped the way it is. ~20 min read; everything else makes more sense after this.
2. **[`BUSINESS-RULES.md`](./BUSINESS-RULES.md)** — the domain knowledge (OEE math, shifts, equipment hierarchy, CS Admin onboarding). Non-obvious from reading code.
3. **[`TOPICS.md`](./TOPICS.md)** — the recurring architectural patterns (per-tenant isolation, comparator validation, pattern reuse). Reference card.
4. **[`../README.md`](../README.md)** — how to run the stack locally
5. **The ADR index** (below) — every architectural decision, in chronological order. ADR-0009 is the canonical current-direction roadmap.

---

## 🏗 Architecture overview

```
                              ┌───────────────────────────┐
        PLC ──── SparkPlug ──▶│   edge-node-red (Node-RED) │
                              │   - protocol decode (Sparkplug B / OPC-UA)
                              │   - per-customer customization tabs
                              │   - publishes to local RabbitMQ
                              └─────────────┬─────────────┘
                                            │ AMQP
                                            ▼
                              ┌───────────────────────────┐
                              │  local RabbitMQ            │
                              │  edge.plc-normalized       │
                              └─────────────┬─────────────┘
                                            │
                                            ▼
                              ┌───────────────────────────┐
                              │  edge-transformer (Go)     │
                              │  - per-tenant consumers    │
                              │  - standardized transforms │
                              │  - HTTP to cloud edge-api  │
                              └─────────────┬─────────────┘
                                            │ HTTPS
                                            ▼
                              ┌───────────────────────────┐
                              │  CLOUD (us-east-1)         │
                              │  - edge-api (NestJS)       │
                              │  - oeecloud-worker (Go)    │
                              │  - mirror-worker-go (Go)   │
                              │  - TimescaleDB + Hasura    │
                              │  - operator (React SPA)    │
                              └───────────────────────────┘
```

**The three load-bearing patterns** every change should respect:

1. **Per-tenant isolation everywhere** — queues, metrics labels, AWS secrets prefix. A bug in one tenant's path should never block another's. See [silent-metric-coverage-gap zettel](../../notes/systems/silent-metric-coverage-gap.md) for the worst-case-when-you-skip-this story.
2. **Comparator validation before any logic cutover** — when porting a transform from one implementation to another (Node-RED → Go, JS → Go, etc.), both sides run in parallel and outputs are diffed. ≥7d for low-risk, ≥30d for OEE-critical. See [ADR-0008](./adr/0008-phase-2-comparator-split.md) for the canonical example.
3. **Pattern reuse over invention** — when a class of problem (queueing, retry, DLQ, idempotency) has been solved in `oeecloud-worker` or `mirror-worker-go`, the new service uses that pattern verbatim. See [ADR-0009 Errata Correction 2](./adr/0009-edge-transformer-go-service-and-nodered-split.md#correction-2--load-bearing-reuse-rule-new-implementation-rule-11).

---

## 📜 Architecture Decision Records (ADRs)

Every architectural decision lives as a numbered ADR in [`docs/adr/`](./adr/). Michael Nygard format: Context → Decision → Consequences. Status: Proposed | Accepted | Deferred | Superseded.

| ADR | Title | Status |
|---|---|---|
| [0001](./adr/0001-edge-persistence-intermittent-connectivity.md) | Edge persistence for intermittent connectivity | Proposed |
| [0002](./adr/0002-firebase-auth-emulator-staging.md) | Firebase Auth Emulator in staging | Accepted |
| [0003](./adr/0003-production-deployment-parent-stack.md) | Production deployment of parent stack | Accepted (Phase 1) |
| [0004](./adr/0004-edge-nodered-config-centralization.md) | edge-node-red config centralization | Proposed |
| [0005](./adr/0005-edge-nodered-self-hosted-runner-deploys.md) | Per-factory self-hosted runner deploys | Proposed |
| [0006](./adr/0006-workflow-infrastructure-refactor.md) | Workflow infrastructure refactor | Accepted |
| [0007](./adr/0007-frontend-write-topology.md) | Frontend write topology (offline tolerance) | **Deferred** |
| [0008](./adr/0008-phase-2-comparator-split.md) | Phase-2 comparator split (mirror-worker-go) | Accepted + Implemented |
| [0009](./adr/0009-edge-transformer-go-service-and-nodered-split.md) | edge-transformer Go service + Node-RED split | Proposed + In progress |

**To write a new ADR:** copy the template `0009-*.md`, increment the number, set Status=Proposed. Open as a PR. After team discussion lands, change to Accepted (or Rejected with rationale).

---

## 📚 Operational guides + plans

Living documents that aren't ADRs — runbooks, port plans, schemas:

| Doc | Purpose |
|---|---|
| [`edge-nodered-customization-shapes.md`](./edge-nodered-customization-shapes.md) | Catalog of customization patterns observed in real customer Node-RED instances; drives ADR-0009 design |
| [`edge-nodered-repo-refactor.md`](./edge-nodered-repo-refactor.md) | File-by-file disposition for the edge-node-red repo refactor (ADR-0009 operational companion) |
| [`edge-transformer-phase-2-runbook.md`](./edge-transformer-phase-2-runbook.md) | Step-by-step runbook for executing Phase 2 of ADR-0009 |
| [`edge-transformer-phase-2-5-publisher-guide.md`](./edge-transformer-phase-2-5-publisher-guide.md) | How to wire the Node-RED publisher to edge.plc-normalized exchange |
| [`edge-transformer-phase-2-5b-plc-wiring-guide.md`](./edge-transformer-phase-2-5b-plc-wiring-guide.md) | How to wire Sparkplug.json's data flow into the publisher |
| [`phase-3-calc-production-counters-port-plan.md`](./phase-3-calc-production-counters-port-plan.md) | The first Calc Production Counters function's Go port plan + comparator strategy |
| [`production-out-of-scope.md`](./production-out-of-scope.md) | Authoritative list of legacy production resources we DON'T touch |
| [`caching-review-2026-06-29.md`](./caching-review-2026-06-29.md) | Caching opportunities review (7 recommendations) |

---

## 🤝 Contracts + schemas

| Doc | Purpose |
|---|---|
| [`clients/_schema.yaml`](./clients/_schema.yaml) | Schema for per-customer `client.yaml` config (ADR-0004) |
| [`clients/_normalized-payload-schema.yaml`](./clients/_normalized-payload-schema.yaml) | The message contract between Node-RED publisher → Go consumer (`edge.plc-normalized` exchange) |
| [`clients/cpack.example.yaml`](./clients/cpack.example.yaml) | Full-schema populated example for the CPack tenant |

---

## 💼 Product-facing briefs

In [`product/`](./product/) — written for PM, CS, Sales (no engineering jargon):

| Doc | For |
|---|---|
| [`product/edge-transformer-pm-brief.md`](./product/edge-transformer-pm-brief.md) | PM brief for the edge-transformer refactor — 5 business decisions, KPIs, competitive context |
| [`product/remote-operations-pm-brief.md`](./product/remote-operations-pm-brief.md) | PM brief for the (deferred) remote-operations / offline-tolerance work |

---

## 🧠 Why we did it this way (the meta)

The team learns intentionally. After every significant debug or design, capture the pattern in a repo doc or ADR. The zettelkasten captures **patterns**, not solutions — making the same kind of bug easier to recognize next time.

**Patterns most relevant to this codebase** (search the vault for):

- `bug-cascade-discovery-during-verification` — multiple root causes per visible symptom; read error-text *shift* as progress
- `recover-validate-then-merge-stranded-work` — handling uncommitted WIP without breaking prod
- `stateful-config-loaders-ignore-source-edits` — node-red-flow-manager's caching gotcha (session-64 lesson)
- `silent-metric-coverage-gap` — per-tenant metric label discipline; how PR #56 broke silently for hours
- `idempotent-build-script-retirement-pattern` — when patches are at source, the script becomes deletable
- `lint-advisory-mode-ratcheting-pattern` — ship-the-rule vs enforce-the-rule
- `reference-audit-before-component-deletion` — never delete by filename; audit by identifier
- `docs-deferred-with-revival-conditions-pattern` — how this very repo handles parked work (see ADR-0007)
- `agent-sandbox-tighter-than-main-session` — Claude Code sub-agent permission gap

If you're a new engineer joining, ask the team for the latest zettel-index URL — it's the institutional memory in compressed form.

---

## 📋 Glossary

| Term | Definition |
|---|---|
| **ADR** | Architecture Decision Record. Michael Nygard format. Lives in `docs/adr/`. |
| **CS Admin** | The internal tool Customer Success uses to onboard new factory clients (enterprise → site → area → equipment → shifts → packml_register). |
| **DLQ / DLX** | Dead Letter Queue / Dead Letter Exchange. RabbitMQ pattern for failed-after-retry messages. Inspected via Grafana per-tenant panels. |
| **edge-nodered** | Per-factory Node-RED instance. Handles PLC protocol + per-customer customization. Publishes to local RabbitMQ. |
| **edge-transformer** | Per-factory Go service (new, ADR-0009). Consumes from local RabbitMQ; runs standardized transforms; publishes to cloud. |
| **OEE** | Overall Equipment Effectiveness. Quality × Availability × Performance. The number every factory cares about. |
| **packml_register** | SparkPlug topic-routing table. Maps `packml_topic` string → `id_equipment`. Source of truth for tenant-discovery in oeecloud-worker. |
| **PackML** | The PLC parameter ID convention (30700, 30701, 30702, ...). See README for the table. |
| **per-tenant pattern** | Architectural rule: one queue/channel/metric-label set per customer tenant. See oeecloud-worker Strategy C Phase 2a. |
| **PR-gated staging** | Branch protection: parent's staging branch requires PR + `Validate compose files` check before merge. |
| **shadow mode** | A new consumer running in parallel with the existing path, logging+acking but writing nothing. The first phase of any Go port. |
| **submodule** | edge-api, edge-node-red, operator, edge-node-red are git submodules under packiot-stack-alpha. Push to a submodule's staging branch auto-bumps the parent. |
| **TimescaleDB / TSDB** | The PostgreSQL extension for time-series. Hosts `equipment_values`, `equipment_events`, `equipment_runtime_*` aggregates. |
| **tsp12** | The production prod-data TimescaleDB hostname. SELECT-only access per the prod-DB-readonly rule. |

---

## 🛠 Contributing

See [`../CONTRIBUTING.md`](../CONTRIBUTING.md) for the workflow (submodule deploy chain, branch protection, PR templates).

Quick rules:
- **Staging is canonical** for all 4 submodules + parent. Don't touch `main` or `master` branches.
- **PR-gated merges** to staging via the `Validate compose files` check.
- **Each ADR change is its own PR** — don't bundle code + ADR.
- **Zettels for non-trivial lessons** — capture the *pattern*, not the fix.

---

## 🔗 External

- **GitHub repo**: https://github.com/packiot/packiot-stack-alpha
- **Submodules**:
  - https://github.com/packiot/edge-api
  - https://github.com/packiot/edge-node-red
  - https://github.com/packiot/operator4 (formerly `operator`)
  - https://github.com/packiot/oeecloud-node-red (legacy — decommissioned 2026-06-24)
- **Staging UI**:
  - Grafana: https://grafana.staging.packiot.app
  - Hasura: https://hasura.staging.packiot.app
  - Operator: https://operator.staging.packiot.app
  - Authentik SSO: https://auth.staging.packiot.app
- **AWS** (us-east-1):
  - Staging app EC2: `i-06c9547a2c7091ab7`
  - Production app EC2 (new stack, session 71): `i-02d255a1c21fb1da3`

---

*Last updated as part of session 72 documentation polish. Owner: platform team. Questions → [open an issue](https://github.com/packiot/packiot-stack-alpha/issues/new/choose).*
