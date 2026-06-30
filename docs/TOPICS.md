# Topics + Patterns

> The architectural conventions every service follows. These are NOT one-off design choices — they're the load-bearing patterns that recur across the codebase. Search this doc before inventing something new; reuse before reinvention.

> *Each topic has a one-line summary, an industry framing (so the pattern is recognizable outside Packiot), and a code-pointer to a service that exemplifies it.*

---

## A. Patterns we explicitly REUSE (no re-inventing allowed)

These are the patterns that EVERY new service must use, not implement its own version of. The reuse rule (ADR-0009 implementation rule #11): if a need feels "almost like" one of these but slightly different, the burden of proof is on you to justify why the existing pattern doesn't fit.

### A.1 — Per-tenant queue + label pattern

**One queue + one Prometheus label set per customer tenant.** No shared queues. No global metrics counters without tenant labels.

| Aspect | Live example |
|---|---|
| Queue per tenant | `edge-transformer-q-cpack`, `oeecloud-worker-q-cpack` |
| Prometheus label | every metric has `tenant=cpack` label |
| Reference impl | `services/oeecloud-worker/internal/amqp/topology.go` (Strategy C Phase 2a) |
| Failure mode if skipped | [silent-metric-coverage-gap zettel](../../notes/systems/silent-metric-coverage-gap.md) — PR #56 |

Industry framing: same as Kubernetes' namespace isolation, AWS account-per-environment, multi-tenant SaaS query-per-tenant.

### A.2 — DLQ + bounded backoff + reanimator triad

**Three pieces, always together.** Every message-consuming service has this trio.

| Piece | What it does | Reference impl |
|---|---|---|
| **DLQ** | Failed-after-N-retries messages parked, not lost | `services/mirror-worker-go/internal/dlq_retry.go` |
| **Bounded backoff** | Retry attempts use exponential delay (bit-shift trick); cap at `MAX_RETRIES=5` | PR #77 |
| **Reanimator loop** | Periodically resets DLQ rows whose root cause is now resolved | PR #84 |

Industry framing: AWS SQS DLQ + redrive, Kafka `--reset-offsets`, Stripe webhook retry-resume.

### A.3 — AMQP channel discipline

**One Channel per consumer goroutine, shared Connection.** AMQP channels are NOT goroutine-safe.

| Aspect | Live example |
|---|---|
| Pattern | `errgroup` spawns N goroutines, each with own Channel from shared Connection |
| Reference impl | `services/oeecloud-worker/internal/amqp/consumer.go` |
| Failure mode if skipped | Random "channel closed" errors during message bursts |

Industry framing: PostgreSQL `pgx.Pool` (one Conn per goroutine), Redis `redis.Client` (connection pool).

### A.4 — AMQP DLX + alternate-exchange catches

**Every queue declares a DLX. Every exchange declares an alternate.** Catches messages that don't route + messages that get retried-out.

| Aspect | Live example |
|---|---|
| DLX | `dlx.edge.plc-normalized`, declared with queue arg `x-dead-letter-exchange` |
| Alternate-exchange | Catch-all for unroutable msgs; see zettel |
| Failure mode if skipped | Silent message loss |

Industry framing: similar to systemd's `OnFailure=` units, k8s `finalizers`.

### A.5 — Comparator validation before logic cutover

**Two implementations run in parallel; outputs diffed; ≥7 days zero-diff (≥30 for OEE-critical) before flip.**

| Aspect | Live example |
|---|---|
| Pattern doc | [ADR-0008 phase 2](./adr/0008-phase-2-comparator-split.md) |
| Reference impl | `services/mirror-worker-go/internal/comparator/` |
| Why it's load-bearing | Caught a real bug ([intent-already-satisfied-classifier-extension zettel](../../notes/systems/intent-already-satisfied-classifier-extension.md)) within hours of going live |

Industry framing: Stripe's "dark deploys", Etsy's "shadow runs", GitHub's "Scientist" library.

### A.6 — Idempotency-Key dedup on outbound writes

**Client-generated UUID per request; server dedups in 24h window.** Per the Stripe Idempotent Requests spec.

Reference impl: `mirror-worker-go` uses this for cross-system replay.

Industry framing: Stripe's `Idempotency-Key` header is the canonical reference.

### A.7 — Single image, two modes via env var

**One Docker image; mode-selection env var picks the boot path.** Avoids two-image two-CI-pipeline two-version-skew vectors.

| Service | Env var | Modes |
|---|---|---|
| `edge-api` | (per ADR-0007 design — when frontend write topology lands) | `cloud_router` vs `factory_local` |
| `edge-transformer` | `EDGE_TRANSFORMER_MODE` | `factory` vs `dev_replay` |

Industry framing: Kubernetes' `kubelet` + `kube-apiserver` (technically one binary tree, different boot configs).

---

## B. Conventions every PR is expected to honor

### B.1 — Staging is canonical

Push to `main` or `master` is **forbidden** (the `feedback_leave_main_master_branches_alone` rule). `edge-api/master` is the legacy Elastic Beanstalk production trigger; touching it deploys to real customers.

For all 4 submodules + parent: **staging branch is canonical.** Push to a submodule's staging → auto-bumps parent's pin → auto-deploys to staging EC2.

### B.2 — Submodule-driven deploy via bump workflow

Push to a submodule's staging branch opens a PR on the parent that bumps the submodule pointer. The parent PR requires the `Validate compose files` check + auto-merges. See [`CONTRIBUTING.md`](../CONTRIBUTING.md) for the full sequence.

### B.3 — PR-gated staging on the parent

Parent staging is protected by the `Protect staging` ruleset (id 18079945): require PR (0 reviewers), require check, no force-push, no deletion. PRs MUST go through the gate; direct push is blocked.

### B.4 — Per-environment secret prefix

AWS Secrets Manager IDs follow `packiot/<env>/<service-name>` convention:
- `packiot/staging/rabbitmq-edge-transformer-creds`
- `packiot/production/db`

CI tooling pattern-matches this prefix. **Don't put production creds under `staging/*`** even temporarily.

### B.5 — Recover-validate-then-merge for ANY stranded work

Found uncommitted code in someone's branch? `git stash`? UU state? Apply → inspect → **TEST IN DEV** → then merge. See [recover-validate-then-merge-stranded-work zettel](../../notes/systems/recover-validate-then-merge-stranded-work.md).

This is THE rule whose violation broke staging on 2026-06-30 (PR #9 cascade). The lesson is permanent.

### B.6 — Lint advisory mode (ratcheting)

New linters ship with `continue-on-error: true` at STEP level so existing baseline violations don't block PRs. Annotations still surface in PR diffs. Flip to enforcing AFTER cleanup. See `lint-advisory-mode-ratcheting-pattern` zettel.

Code: `edge-node-red/.github/workflows/lint-flows.yml`.

### B.7 — ADRs for every architectural change

Michael Nygard format. Live in `docs/adr/NNNN-title.md`. Status: Proposed → Accepted | Deferred | Superseded.

ADR PR is SEPARATE from the implementation PR. The reviewer can question the architecture without the code distraction; the implementation gets reviewed against an already-accepted ADR.

### B.8 — Zettels for non-trivial lessons

Every production bug / non-obvious design discovery becomes a zettel in the team's `~/notes/` vault. Zettels capture the **pattern** (recognizable next time), not the **fix** (specific to this codebase).

Discovery → fix → zettel is the full loop. Skipping the zettel costs the team the institutional memory.

---

## C. Concepts you must know to navigate

### C.1 — SparkPlug B + the per-tenant namespace

SparkPlug B is the MQTT-based protocol PLCs use. Topic structure:
```
<group_id>/<message_type>/<edge_node_id>/<device_id>/...
e.g.   CPACK/SC/L25/MST/Admin/ProdConsumedCount/0/UnitOUT
```

**The first segment (`group_id`) IS the tenant.** Everywhere in the codebase, `tenant = topic.split('/')[0].toLowerCase()`. This is load-bearing — used for queue routing, metric labels, secret-namespace.

### C.2 — Continuous aggregates (TimescaleDB caggs)

`equipment_runtime_*` tables are TimescaleDB *continuous aggregates* on `equipment_values`. They're not instantaneous — there's a 1-2 min lag between raw insert and 1-min cagg visibility.

If you're debugging "why don't I see my data in the dashboard?" — first check whether the cagg has caught up.

### C.3 — Per-factory vs cloud-central services

| Runs at factory | Runs in cloud |
|---|---|
| edge-node-red | edge-api (control plane) |
| edge-transformer (NEW) | oeecloud-worker (consumer) |
| RabbitMQ | mirror-worker-go (staging-only) |
| operator SPA | TimescaleDB + Hasura |
| (future) local TSDB | Authentik SSO |

The deploy mechanisms are DIFFERENT:
- Cloud services: deploy-staging.yml workflow on staging push
- Factory services: per-factory self-hosted runners (ADR-0005)

### C.4 — Operator UI vs CS Admin UI

Two separate UIs, two separate users:
- **Operator UI**: factory-floor users. Justifies events, starts/stops POs, scans boxes. Per-factory; lives next to edge-node-red.
- **CS Admin UI**: Customer Success team. Onboards new factories, manages shifts, manages catalogs. Lives in the cloud.

DTOs are STRICTLY separated — CS Admin must NOT include production-runtime computed fields; operator UI must NOT include setup fields.

### C.5 — Hasura is the GraphQL gateway

All external (operator UI, dashboards, BI) reads go through Hasura, not direct DB. Hasura connects DIRECTLY to PostgreSQL (NOT pgbouncer — Hasura uses prepared statements; collision with pgbouncer's transaction mode → error 42P05). See `pgbouncer-pgx-prepared-statement-collision` zettel.

### C.6 — RabbitMQ is the in-factory message bus

Replaces the older Node-RED → direct HTTP pattern. Every factory has a local RabbitMQ container. Messages flow:
- Node-RED → publishes to `edge.plc-normalized` (Phase 2.5+)
- edge-transformer → consumes per-tenant queue
- edge-transformer → publishes outbound to cloud edge-api OR to GCP PubSub (legacy path)

---

## D. Failure-mode patterns to recognize

When debugging a bug, recognize which class it belongs to:

| Pattern | Symptom | Class |
|---|---|---|
| Bug cascade | Fix one bug, the next error message appears (different bug, was hidden) | `bug-cascade-discovery-during-verification` |
| Silent metric coverage gap | A bug happened but you didn't know — no alert fired | `silent-metric-coverage-gap` |
| Stateful config loader | Source file changed but runtime didn't pick it up | `stateful-config-loaders-ignore-source-edits` |
| Sole-writer chain hazard | Two writers race because the "sole-writer" rule wasn't enforced anywhere | `sole-writer-invariant-chain-hazard` |
| Recovered WIP cascade | Stranded code merged without local test broke prod | `recover-validate-then-merge-stranded-work` |
| Non-deterministic LIMIT 1 | `ORDER BY X DESC LIMIT 1` where X has ties; the picked row varies | `sql-non-deterministic-order-by-limit-1` |
| Idempotent script rot | A build-time patch script is now a no-op (patches at source) but lives on | `idempotent-build-script-retirement-pattern` |
| Reference-audit miss | Deleted "obvious dead code" by name; turned out to be the canonical version | `reference-audit-before-component-deletion` |

If you're debugging and your symptom doesn't fit any pattern above — **that's worth a new zettel** once you understand the root cause.

---

## E. External systems we depend on

| System | Where | What we depend on |
|---|---|---|
| **GCP PubSub** | Cloud | Message bus for factory→cloud (legacy path; being replaced by direct AMQP) |
| **AWS Secrets Manager** | us-east-1 | All runtime secrets, per-env namespaced |
| **AWS EC2** | us-east-1 | Staging app EC2 (i-06c9547a2c7091ab7), staging DB EC2 (i-064bb36d1c454d861), production EC2 (i-02d255a1c21fb1da3) |
| **AWS Route 53** | us-east-1 | `api4.packiot.com`, `dev.packiot.com`, `staging.packiot.app`, `prod.packiot.app` |
| **AWS Backup** | us-east-1 | Daily EBS snapshots (staging + ts2pg12); tiered retention plans on production |
| **Firebase Auth** | Google | Operator UI auth (being replaced by Firebase Auth Emulator in staging — ADR-0002) |
| **Authentik** | Self-hosted on staging + prod app EC2 | SSO gate for Grafana, Hasura console, operator |
| **Hasura Cloud / self-hosted** | Self-hosted (cloud) | GraphQL gateway |
| **TimescaleDB** | tsp12 (cloud), ts2pg12 (staging) | All time-series storage |

---

## F. Where to read MORE

- [`INDEX.md`](./INDEX.md) — documentation hub (start here if you're new)
- [`BUSINESS-RULES.md`](./BUSINESS-RULES.md) — domain knowledge (OEE math, shifts, equipment hierarchy)
- [`adr/`](./adr/) — every architectural decision
- [`../README.md`](../README.md) — how to run the stack
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — workflow (PR gates, branch protection, deploy chain)
- Team's `~/notes/` vault — zettelkasten of patterns (institutional memory)

---

*Topics doc is the **map of the meta**. If you're about to invent a new pattern: check here first. If you find one missing: PR it in.*
