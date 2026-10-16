# 10 — Decision Log

The guide told you *what* the stack does and *why*, in prose. This page is the index
to the primary sources: the **Architecture Decision Records** (ADRs). Each ADR is a
dated record of one choice — the context that forced it, the options weighed, the
decision, and its consequences. When the guide says "we chose X," the *argument* for
X lives in one of these.

Read an ADR when you need to know not just what was decided but *why the
alternatives lost* — that is the knowledge that keeps a system from being re-litigated
every six months.

## The records

| ADR | Decision | Status |
|-----|----------|--------|
| [0001](../adr/0001-edge-persistence-intermittent-connectivity.md) | Edge persistence for PLC data under intermittent connectivity | Proposed |
| [0002](../adr/0002-firebase-auth-emulator-staging.md) | Firebase Auth emulator for staging↔prod auth parity | Proposed |
| [0003](../adr/0003-production-deployment-parent-stack.md) | Production deployment of the parent stack | Proposed |
| [0004](../adr/0004-edge-nodered-config-centralization.md) | Edge-nodered config centralization per client | Proposed |
| [0005](../adr/0005-edge-nodered-self-hosted-runner-deploys.md) | Edge-nodered self-hosted runner deploys per factory | Proposed |
| [0006](../adr/0006-workflow-infrastructure-refactor.md) | CI/CD workflow infrastructure refactor | Proposed |
| [0007](../adr/0007-frontend-write-topology.md) | Frontend write topology (sync-local or queued-remote) | Deferred |
| [0008](../adr/0008-phase-2-comparator-split.md) | Comparator service + deferred data layer | Proposed |
| **[0009](../adr/0009-edge-transformer-go-service-and-nodered-split.md)** | **The edge-transformer / Node-RED responsibility split** — [Ch. 3](03-the-edge.md), [Ch. 7](07-customizations-and-real-factories.md) | Accepted, implemented |
| **[0010](../adr/0010-sparkplug-decode-in-go-end-state.md)** | **SparkPlug B decode in Go** — [Ch. 3](03-the-edge.md) | Accepted, implemented |
| **[0011](../adr/0011-durability-boundary-and-store-and-forward.md)** | **Durability boundary + store-and-forward outbox** — [Ch. 3](03-the-edge.md) | Accepted, implemented |
| **[0012](../adr/0012-schema-refactor-and-multitenancy-pool.md)** | **Schema refactor: tenant pools + naming unification** — [Ch. 5](05-the-database.md) | Accepted, in execution |
| [0013](../adr/0013-shadow-mirror-service.md) | Shadow-mirror service for operator-action parity — [Ch. 6](06-apis-and-operator.md) | Accepted, implemented |
| **[0014](../adr/0014-extract-oee-math-from-database-to-app.md)** | **Extract OEE math from PostgreSQL into Go** — [Ch. 4](04-the-engine.md) | Accepted, implemented |
| [0015](../adr/0015-customer-facing-query-api.md) | Customer-facing composable query API — [Ch. 6](06-apis-and-operator.md) | Proposed |
| **[0016](../adr/0016-staging-consolidation-master-plan.md)** | **Staging consolidation to one flow (the flip)** — [Ch. 9](09-the-endgame.md) | Accepted, runbook prepared |
| **[0017](../adr/0017-endgame-process-separation-and-enterprise-hardening.md)** | **Endgame: process separation + enterprise hardening** — [Ch. 9](09-the-endgame.md) | Accepted |
| **[0018](../adr/0018-operator-frontend-integration-makeover.md)** | **Operator/frontend makeover: retire the Node-RED BFF** — [Ch. 6](06-apis-and-operator.md) | Proposed, executed |
| **[0019](../adr/0019-edge-customization-capabilities.md)** | **Edge customization capabilities (the Incoplast requirements)** — [Ch. 7](07-customizations-and-real-factories.md) | Proposed |

Bold rows are the load-bearing decisions — the ones the guide leans on most. The
earlier records (0001–0008) are largely foundational and predate the current
architecture's shape; they are kept for the historical trail.

## How to read a status

ADR statuses tell you how much to trust a record as *current reality*:

- **Proposed** — a decision written down, not yet ratified. The reasoning is sound
  but the world may not match it yet.
- **Accepted** — ratified and being acted on.
- **Accepted, implemented** — done; the code matches the record.
- **Accepted, in execution** — a multi-phase decision partway through.
- **Deferred** — a decision consciously postponed (the record explains why).

When a status and the running system seem to disagree, trust the system and the
live state notes over the ADR's status line — ADRs are decisions, not live dashboards.

## Beyond the ADRs

The ADRs are the *decisions*. Two other bodies of reference material sit alongside
them:

- **[`adr/reference/`](../adr/reference/)** — the operational artifacts that *execute*
  those decisions: the flip runbook, gate boards, as-executed migration SQL, schema
  and naming maps, and prod captures used as ground truth for the ports.
- **[`audits/`](../audits/)** — point-in-time investigations (prod-vs-staging
  comparisons, subsystem reviews) that informed decisions.

Together, the guide (the story), the ADRs (the decisions), and the reference material
(the execution) are the complete record of how this stack was reasoned into
existence.

---

← Back to [the guide index](../README.md).
