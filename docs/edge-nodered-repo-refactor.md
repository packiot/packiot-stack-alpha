# edge-node-red Repo Refactor Plan — Operational Companion to ADR-0009

**Audience:** Engineer(s) doing the refactor.
**Sister doc:** [ADR-0009](./adr/0009-edge-transformer-go-service-and-nodered-split.md) (the "why").
**This doc:** the "what at the repo level" — every current file, its disposition, the order things change.
**Date:** 2026-06-30
**Status:** Draft — to be reviewed alongside ADR-0009

---

## Section 1 — Inconsistencies between ADR-0009 plan and current reality

These are gaps I found after looking at the actual `edge-node-red` repo. **All ten should be reconciled into ADR-0009 before engineering starts.**

### Inconsistency 1 — `transform_flows.py` is doing TWO things, not one

What ADR-0009 assumed: per-customer config substitution that disappears with `client.yaml`.

What the script actually does (per its own docstring + content):

```
1. Firebase API key in HTTP request node URLs → $(FIREBASE_API_KEY) env var
2. Hardcoded Hasura URLs in all function nodes → env.get('HASURA_URL')
3. SparkPlug Calc_Counters: remove hardcoded 2022-03-24 timestamp bug
4. SparkPlug Calc_Counters: strip dead debug vars
```

Items 1 + 2 are config substitution — gone with `client.yaml`.
**Items 3 + 4 are live bug patches** to the SparkPlug Calc_Counters function that **were never fixed at source**.

**Impact:** until Phase 3 (Calc_Counters moves to Go), we still need a transform step OR we fix the bugs in `flows.json` directly. Recommendation: **fix the bugs in source first** — eliminates `transform_flows.py` immediately, simplifies the build pipeline, doesn't depend on the Go port landing.

ADR-0009 update needed: add a Phase 1.5 "fix the source bugs that transform_flows.py was masking + delete the script."

### Inconsistency 2 — Hardcoded Firebase API key in source

`transform_flows.py` line 34: `FIREBASE_KEY = "AIzaSyCRK02fBbgho-VSQrjt5bIZzzVdoIgpRGo"` — a real Firebase API key committed to the repo (used as a SEARCH STRING to find-and-replace in flows.json). This is leaked-credential territory.

**Impact:** unrelated to ADR-0009 but discovered in the same audit. **Rotate that key + remove from repo + use env var directly in flows.json**.

ADR-0009 update needed: not strictly, but note in the refactor plan that Phase 0.5 = security cleanup (rotate the key, sanitize repo history).

### Inconsistency 3 — `hasura/` directory ships metadata FROM edge-nodered

The team's edge-nodered repo has `hasura/metadata.json`. This is Hasura metadata (table tracking, relationships, permissions) that production loads via `hasura-init` container in compose.production.yml.

What ADR-0009 assumed: GraphQL tab in edge-nodered goes away → Hasura goes away → done.

What's actually true: Hasura serves more than just the GraphQL tab — it's used by other services (operator SPA, possibly the cloud edge-api for some queries). Removing the GraphQL TAB from edge-nodered does NOT mean removing Hasura.

**Impact:** the `hasura/metadata.json` file shouldn't live in edge-nodered's repo at all — it's not edge-nodered's concern. Move to `packiot-stack-alpha` repo OR a dedicated `hasura-metadata` repo.

ADR-0009 update needed: add a step in the refactor — "extract hasura/ from edge-node-red to the platform repo."

### Inconsistency 4 — Custom Node-RED node `pubsub-queue` becomes obsolete (NOT a Go re-implementation)

`nodes/pubsub-queue-0.0.64.tgz` — a packaged Node-RED node for GCP PubSub publishing with local SQLite-backed queueing (the `sparkplug_queue.sqlite` file). This is custom code from the 2022-era architecture when factories had no local message broker.

**Correction (2026-06-30 after user review):** my original analysis suggested re-implementing the SQLite local queue inside the Go service. That's a regression past the platform you already have. The correct answer separates two concerns the custom node accidentally bundled:

**Concern 1 — PLC data durability across transformer outage:**
- Node-RED publishes to **local RabbitMQ** (persistent queues, mirrored). Every factory already runs RabbitMQ.
- Edge-transformer consumes from `plc.normalized.<tenant>`. If transformer crashes, RabbitMQ holds messages until it's back.
- **No SQLite needed.** RabbitMQ IS the durable queue.

**Concern 2 — Outbound API call replay if cloud is down:**
- Use the OUTBOX pattern, reusing the proven triad from mirror-worker-go:
  - Outbox table (small SQLite, OR a dedicated per-target RabbitMQ queue like `outbox.cloud_api.<tenant>`)
  - Drain loop with exponential backoff (PR #77 template)
  - DLQ at `retry_attempts=5` (PR #77 template)
  - Reanimator that resets DLQ rows when downstream becomes reachable (PR #84 template)
- Code can be lifted nearly verbatim from `services/mirror-worker-go/internal/dlq_retry.go` + `reanimator.go`.

**Impact:** Phase 3 estimate stays at 3-4 weeks (no Go-local-queue work). The `pubsub-queue` custom node is simply DELETED in the refactor — replaced by `node-red-contrib-amqp` publishing to RabbitMQ.

ADR-0009 update needed:
- **No estimate change**: keep Phase 3 at 3-4 weeks
- **Add explicit reuse rule** (see Section 1.5 of this doc): "edge-transformer MUST reuse oeecloud-worker's per-tenant Connection+Channel pattern and mirror-worker-go's DLQ+reanimator. No new queue/retry/replay code is to be invented."
- **Architectural rule**: Node-RED's job is "publish to local RabbitMQ"; RabbitMQ owns durability; Go owns transform + cloud-bound replay-via-outbox.

### Inconsistency 5 — Existing AWS Secrets Manager flow in `entrypoint.sh`

The team's `entrypoint.sh` already pulls a `$AWS_SECRET_ID` from AWS Secrets Manager at startup and exports it as env vars. ADR-0009's `client.yaml` adds a new config layer on top of this.

What ADR-0009 assumed: `client.yaml` is THE config layer.

What's actually true: there will be TWO layers — `client.yaml` (the non-secret config — equipment mappings, schedules, integrations) and the AWS Secrets Manager JSON (the actual secrets — DB passwords, API keys, etc.). `client.yaml` references secrets via `*_env` fields; the env vars come from AWS Secrets Manager.

**Impact:** this is fine, but the relationship needs to be DOCUMENTED. ADR-0009 should make explicit that `client.yaml` does NOT replace the AWS secrets flow — it complements it.

ADR-0009 update needed: add a "Configuration architecture" subsection clarifying the two layers + naming convention (e.g., every `*_env: VAR_NAME` in client.yaml must have a matching key in the AWS secret JSON).

### Inconsistency 6 — Multiple SparkPlug subflow versions coexist

`subflows/SparkPlug_v1.10.37.json`, `SparkPlug_v1.10.39.json`, `SparkPlug_v1.10.39.1.json`. Three versions of the same subflow.

This is **subflow vendoring drift** — the same problem the customer instance had with operator UI tabs, but inside the team baseline.

**Impact:** any refactor needs to decide which version is canonical + delete the others. Otherwise the new architecture inherits a known mess.

ADR-0009 update needed: Phase 1 includes "consolidate SparkPlug subflows to single canonical version."

### Inconsistency 7 — `compose.dev.yml` runs a PubSub emulator + Hasura

The dev compose is 5,546 bytes vs the prod compose's 739 bytes — includes a full local dev stack (PubSub emulator, Hasura console). This is good — but it means the new `edge-transformer` Go service needs equivalent dev tooling, OR it boots in "no-PubSub, no-Hasura" mode for local iteration.

What ADR-0009 assumed: nothing about dev experience.

**Impact:** Phase 2 (Go skeleton) needs to include a `compose.dev.yml` analog for the transformer.

ADR-0009 update needed: explicit dev-experience requirement in Phase 2.

### Inconsistency 8 — Per-tab files vs `flows.json`

The team's edge-nodered uses **both** `flows.json` (596 KB master) AND `flows/*.json` (per-tab files). The session 64 incident (`stateful-config-loaders-ignore-source-edits` zettel) was exactly this: node-red-flow-manager loads per-tab files at startup and ignores subsequent `flows.json` edits.

What ADR-0009 assumed: clean Node-RED migration.

**Impact:** any flow-editing refactor must touch BOTH the master `flows.json` AND the corresponding `flows/<tab>.json` file, OR explicitly disable node-red-flow-manager and use single-source-of-truth `flows.json`.

ADR-0009 update needed: implementation rule — "every flow edit must update both `flows.json` and `flows/<tab>.json` until node-red-flow-manager is disabled or removed."

### Inconsistency 9 — `.config.*.json.backup` files committed

`.config.nodes.json.backup`, `.config.runtime.json.backup`, `.config.users.json.backup`, `.flows_cred.json.backup`, `.flows.json.backup` — all `.backup` files are committed to the repo. These are not gitignored.

**Impact:** unrelated to ADR-0009 but bad hygiene. Add to `.gitignore`, remove from repo.

ADR-0009 update needed: not strictly, but cleanup belongs in Phase 1.

### Inconsistency 10 — No CI for the refactor's governance rules

ADR-0009 specifies governance rules (max 200 LOC per function, no flow.set > 50 lines, no http in/out in customization tabs) but assumes "CI lints these." The team's edge-nodered repo has `.github/` but I haven't audited what CI exists today.

**Impact:** the governance rules are wishes without enforcement. Phase 1 needs to include the lint script + CI integration.

ADR-0009 update needed: Phase 1 deliverable — `.github/workflows/lint-flows.yml` + `scripts/lint-flows.js`.

---

## Section 1.5 — Reuse the staging-stack patterns (NOT reinvent)

The staging stack and oeecloud-worker / mirror-worker-go migrations have already solved several problem classes the edge-transformer will hit. **Every one of these MUST be reused, not re-implemented.** This is the boring-infrastructure principle: when your platform has already shipped a proven solution to a class of problem, the new service uses it.

The list of patterns that must be lifted verbatim into edge-transformer:

| Pattern | Source | Why reuse |
|---|---|---|
| **Per-tenant queue topology** (one queue per customer; shared Connection, per-tenant Channels via errgroup) | oeecloud-worker, Strategy C Phase 2a (commit `ccccef9`, rebased `451a45b`) | Proven at scale; per-tenant Prometheus labels included |
| **Per-tenant Prometheus metrics** (with per-tenant labels) | oeecloud-worker (after PR #56 silent-coverage-gap fix) | Avoids the silent-LogOnly-fallback failure mode; covered by zettel [[silent-metric-coverage-gap]] |
| **DLQ with bounded exponential backoff** | mirror-worker-go PR #77 | retry_attempts column + last_retry_at + cap-at-5 |
| **Reanimator loop** (resets DLQ rows when downstream becomes mappable/reachable) | mirror-worker-go PR #84 | Escape hatch for transient failures that resolve outside retry window |
| **AMQP DLX + alternate-exchange** (catch unrouted messages) | covered by zettels [[amqp-dlx-retry-topology]] + [[amqp-alternate-exchange-for-unrouted]] | Prevents silent message loss |
| **AMQP Channel-not-goroutine-safe discipline** | covered by zettel [[amqp-channel-not-goroutine-safe]] | One Channel per consumer goroutine; shared Connection |
| **Comparator validation pattern** (Go output vs Node-RED output for each transform, dual-write + diff over N hours before flip) | mirror-worker-go ADR-0008 + comparator service | The ONLY way to safely port a transform without risking customer data |
| **AWS Secrets Manager flow** for runtime credentials | already in edge-node-red entrypoint.sh; oeecloud-worker uses identical pattern | The two-config-layer architecture (Inconsistency 5) builds on top of this |
| **Single Docker image, two boot modes via env var** | ADR-0007's edge-api pattern (`EDGE_API_MODE=cloud_router|factory_local`) | Same trick for edge-transformer (`EDGE_TRANSFORMER_MODE=factory|dev_replay`) |
| **Submodule-driven deploy via bump workflow** | parent repo's deploy chain (zettel [[submodule-driven-deploy-via-bump-workflow]]) | edge-transformer ships via the same submodule pattern as the other Go services |
| **Idempotent knex migrations** (for the outbox table) | zettel [[idempotent-knex-migrations]] | Schema changes safe to re-apply |
| **Idempotency-Key dedup on outbound API calls** | mirror-worker-go uses this for cross-system replay; ADR-0007 makes it a system-wide contract | Required if cloud edge-api's critical-path middleware ever lands |

**Enforcement rule** (add to ADR-0009 implementation rules):

> *Any pattern listed above MUST NOT be re-implemented in edge-transformer. If a need feels "almost like" one of these but slightly different, the burden of proof is on the engineer to justify why the existing pattern doesn't fit — not to invent a new one. Pattern reuse decisions are tracked in the PR description.*

This rule is load-bearing because the cost of pattern drift is invisible until production: oeecloud-worker's silent-metric-coverage-gap (PR #56) is the worst-case example — a tenant routing change broke silently for hours because metrics weren't per-tenant. The fix was "use the per-tenant pattern that was already there." Don't repeat that history.

---

## Section 2 — File-by-file disposition (current edge-node-red repo)

### `flows.json` (596 KB master) + `flows/` directory (per-tab)

| File | Today | After refactor | Phase |
|---|---|---|---|
| `flows/PLCs.json` (10 nodes) | s7 in nodes, status, debug, link out | **KEEP**, simplify | 2 |
| `flows/Sparkplug.json` (17 nodes) | SparkPlug subflow + PubSub publish + catch | **EVOLVE** — keep subflow, replace PubSub publish with RabbitMQ publish to `plc.normalized.<tenant>` | 2 |
| `flows/HTTPIngestion.json` (4 nodes) | http-in /plc-data → function → http request → http response | **EVOLVE** — replace http-in with RabbitMQ consume; replace outbound http-request with RabbitMQ publish | 4 |
| `flows/Health Data and Ping.json` (15 nodes) | Loadavg, Drives, Uptime, Memory readers | **KEEP** — local system health | 2 |
| `flows/Configuration.json` (16 nodes) | env var setup, config init | **SLIM DOWN** — most config moves to client.yaml; this tab loads client.yaml + exposes via flow context | 1 |
| `flows/API.json` (95 nodes — 19 http-in endpoints) | The operator-app proxy layer | **DELETE** — 14 endpoints move to Go (edge-transformer), 6 eliminated (SPA → cloud direct). See ADR-0009 disposition table. | 4 |
| `flows/GraphQL.json` (53 nodes) | Builds GraphQL queries to Hasura for API tab responses | **DELETE** — only existed to support the API tab | 4 |
| `flows.json` (master) | Mirror of all tabs | **REGENERATE** from per-tab files after each phase; long-term: disable flow-manager, single source of truth | 1 → 4 |

### `subflows/` directory

| File | Today | After refactor | Phase |
|---|---|---|---|
| `subflows/SparkPlug_v1.10.37.json` | Old version | **DELETE** | 1 |
| `subflows/SparkPlug_v1.10.39.json` | Current | **KEEP** as canonical (or pick newest) | 1 |
| `subflows/SparkPlug_v1.10.39.1.json` | Patch version | **CONSOLIDATE** into 1.10.39 or rename to canonical | 1 |
| `subflows/Auth Midleware.json` | Auth middleware for API tab | **DELETE** (API tab gone) | 4 |
| `subflows/Create%2Fjustify events.json` | Used by API tab justify endpoint | **DELETE** (logic moves to Go) | 4 |
| `subflows/Get current shifts.json` | Used by API tab + scheduled jobs | **DELETE** (replaced by shifts: config + Go fetcher) | 4 |
| `subflows/Subflow 1.json` | Unnamed | **AUDIT + DELETE/RENAME** | 1 |

### Root-level config files

| File | Today | After refactor | Phase |
|---|---|---|---|
| `transform_flows.py` (7,574 bytes) | Pre-build flow patches (Firebase key, Hasura URLs, Calc_Counters bug fixes) | **DELETE** after fixing source bugs in Phase 1.5 + after Phase 4 (Hasura URL substitutions become irrelevant) | 1.5, then 4 |
| `flow-manager-cfg.json` | node-red-flow-manager config | **AUDIT** — possibly disable flow-manager entirely; revisit per session 64 zettel | 1 |
| `flow-manager-nodes-order.json` | Tab order persistence | **AUDIT + KEEP** if flow-manager kept; delete if not | 1 |
| `config-nodes.json` (29 lines) | Static config nodes (PLC connection params, etc.) | **REPLACE** with client.yaml-generated config nodes at startup | 1 |
| `settings.js` (568 lines) | Node-RED runtime config | **KEEP** with minor edits (admin auth, projects feature toggles) | 1 |
| `package.json` | npm deps | **EVOLVE** — add node-red-contrib-amqp (RabbitMQ output node) | 2 |
| `package-lock.json` | npm lockfile | **REGENERATE** when deps change | 2 |
| `Dockerfile` | Multi-stage image build | **EVOLVE** — add client.yaml loader stage; remove transform_flows.py invocation | 1, 4 |
| `entrypoint.sh` (6,010 bytes) | AWS Secrets Manager + env setup | **EVOLVE** — add client.yaml fetch step before node-red boot; document the two-layer config | 1 |
| `compose.yml` (739 bytes) | Prod compose | **EVOLVE** — add edge-transformer service alongside | 2 |
| `compose.dev.yml` (5,546 bytes) | Dev compose with PubSub emulator + Hasura | **EVOLVE** — add edge-transformer dev mode + remove Hasura console if local Hasura goes away | 2 |
| `Makefile` | Dev convenience commands | **EVOLVE** — add `make transformer` target, etc. | 2 |
| `.env.example` / `.env.local` | Local env vars | **EVOLVE** — document client.yaml-related vars | 1 |
| `nodes/pubsub-queue-0.0.64.tgz` | Custom GCP PubSub node with local SQLite queue (2022-era hack from when factories had no local broker) | **DELETE** — replaced by `node-red-contrib-amqp` publishing to local RabbitMQ. RabbitMQ provides the durability; no local SQLite needed. (See Inconsistency #4 corrected analysis.) | 2 |
| `db/` (directory) | Hasura schema migrations? | **AUDIT** — likely moves out of edge-nodered repo entirely | 1 |
| `hasura/metadata.json` | Hasura metadata loaded by hasura-init | **MOVE** to packiot-stack-alpha repo | 1 |
| `sparkplug_queue.sqlite` | Runtime queue persistence (used by `pubsub-queue` node) | **DELETE** — irrelevant once `pubsub-queue` is removed (Phase 2); RabbitMQ owns durability | 2 |
| `.config.*.json.backup` (5 files) | Stale Node-RED backup configs | **DELETE + gitignore** | 1 |
| `.flows_cred.json.backup` | Credentials backup | **DELETE + gitignore** | 1 |
| `.flows.json.backup` | Flows backup | **DELETE + gitignore** | 1 |

### New files to ADD

| File | Phase | Purpose |
|---|---|---|
| `flows/Customization.json` (or sub-tabs) | 5 | Sanctioned per-customer customization surface (state machines + transforms). Empty in the baseline repo; each client's tabs live in `clients/<id>/customizations/`. |
| `flows/RabbitMQPublish.json` | 2 | Clean output node — receives from PLC tabs, publishes to `plc.normalized.<tenant>` exchange. |
| `flows/ClientConfigLoader.json` | 1 | Single function node that loads `/etc/packiot/client.yaml` (mounted from host) at startup, exposes via `flow.config`. |
| `scripts/lint-flows.js` | 1 | Enforces governance rules (function LOC, no flow.set big JSON, no http in/out in customization tabs) |
| `.github/workflows/lint-flows.yml` | 1 | CI: runs lint-flows.js on every PR |
| `client.example.yaml` | 1 | Documentation copy of `docs/clients/cpack.example.yaml` for local dev |

---

## Section 3 — Phase-by-phase repo timeline

Maps ADR-0009 phases onto specific file changes in the edge-node-red repo.

### Phase 1 — Foundation cleanup + config layer (~1 week)

**Goal:** the repo is in a state where adding the Go service (Phase 2) is straightforward.

Repo changes:
- DELETE the 5+ `.backup` files; update `.gitignore`
- CONSOLIDATE the 3 SparkPlug subflow versions → 1 canonical
- DELETE `subflows/Subflow 1.json` (unnamed cruft)
- ADD `flows/ClientConfigLoader.json` — boots first, loads `/etc/packiot/client.yaml`, exposes on `flow.config`
- EVOLVE `Dockerfile` + `entrypoint.sh` to fetch `client.yaml` from a mounted volume
- ADD `scripts/lint-flows.js` + `.github/workflows/lint-flows.yml`
- AUDIT `flow-manager-cfg.json` — decide stay or go (probably stay; the per-tab-file pattern is too entrenched to migrate mid-refactor)
- MOVE `hasura/metadata.json` to packiot-stack-alpha repo

### Phase 1.5 — Fix source bugs, delete `transform_flows.py` (~2 days)

**Goal:** end the build-time-patch ritual.

Repo changes:
- Fix the Calc_Counters timestamp bug AT SOURCE in `flows.json` + `flows/Sparkplug.json`
- Strip the dead debug vars at source
- Replace hardcoded Firebase API key with `env.get('FIREBASE_API_KEY')` at source (in the affected http request nodes)
- Replace hardcoded Hasura URLs with `env.get('HASURA_URL')` at source
- ROTATE the leaked Firebase API key + sanitize git history
- DELETE `transform_flows.py`
- Update `Dockerfile` to remove `transform_flows.py` invocation
- Update `Makefile` to remove `make transform`

### Phase 2 — RabbitMQ bridge (~5 days)

**Goal:** flowing data through the new bus without changing destination behavior.

Repo changes (in edge-node-red):
- ADD `flows/RabbitMQPublish.json` — receives from PLCs + Sparkplug tabs, tees to `plc.normalized.<tenant>` exchange ALONGSIDE existing PubSub publish (no behavior change for cloud consumers)
- Update `package.json` with node-red-contrib-amqp
- Update `compose.dev.yml` to include local RabbitMQ for dev

Repo changes (in packiot-stack-alpha):
- New `services/edge-transformer/` directory — Go skeleton, consumes from `plc.normalized.<tenant>`, shadow mode
- Add edge-transformer to compose.production.yml + compose.staging.yml
- Reuse oeecloud-worker's per-tenant pattern

### Phase 3 — Port standardized transforms to Go (~3-4 weeks)

**Goal:** edge-transformer becomes functionally complete; Node-RED transform tabs become optional.

Repo changes (in edge-transformer):
- Port Calc_Counters family → Go (template ready for the comparator validation per ADR-0008)
- Port PackML parameter parsers
- Port dedup, batching
- Wire outbound API calls through the outbox pattern (RabbitMQ queue `outbox.cloud_api.<tenant>` + drain loop with DLQ + reanimator — code lifted from mirror-worker-go)

**Reuse rule reminder:** no new queue/retry/replay code is invented here. Every Go pattern in this phase exists in oeecloud-worker or mirror-worker-go already; see Section 1.5.

Repo changes (in edge-node-red):
- Per transform, after comparator validates: DELETE the Node-RED equivalent
- (Note: `pubsub-queue` node was already deleted in Phase 2 — no work here for that)

### Phase 4 — Migrate the 20 HTTP endpoints (~2 weeks)

**Goal:** the `[API]` tab is gone.

Repo changes (in edge-node-red):
- After each endpoint ports/eliminates: remove the corresponding nodes from `flows/API.json`
- Once all 20 are handled: DELETE `flows/API.json` + `flows/GraphQL.json` (the latter only existed to support the API tab)
- DELETE `subflows/Auth Midleware.json`, `subflows/Create%2Fjustify events.json`, `subflows/Get current shifts.json`
- DELETE the transform_flows.py Hasura URL substitution (irrelevant now)
- Update `Dockerfile`, `entrypoint.sh` to remove API-related env vars

Repo changes (in edge-transformer):
- Add HTTP server (gin/chi/stdlib) hosting the 14 ported endpoints
- Wire endpoints to local DB / RabbitMQ / cloud edge-api

### Phase 5 — Customization governance + onboarding (~3 days)

**Goal:** the new per-customer customization model is documented and runnable.

Repo changes (in edge-node-red):
- ADD `flows/Customization.json` as an empty-with-comments template
- ADD `clients/_template/client.yaml` symlinked from packiot-stack-alpha's schema
- README updated with the new architecture overview + governance rules
- ADD `docs/onboarding-a-new-client.md` — step-by-step

Repo changes (in packiot-stack-alpha):
- Document the schema versioning policy
- Document the breaking-change process (any change to `_schema.yaml` is a MAJOR version bump per the comment at the top)

---

## Section 4 — What's NOT in this plan

Honest scope limits:

1. **Per-customer flows in customer repos** — each customer's actual `client.yaml` + `customizations/` live in a separate per-customer repo (probably a new `packiot-clients` repo or similar). Out of scope for this doc; needs its own structure decision.
2. **CI for client.yaml validation** — schema validation script for client.yaml needs to be designed; out of scope here, belongs in the schema doc.
3. **Hasura repo extraction** — the `hasura/metadata.json` move-out needs its own small migration plan.
4. **The Firebase key rotation** — security task that should happen IMMEDIATELY, not waiting for this refactor. Mention in Phase 0.5 but execute independently.

---

## Section 5 — Net change in repo size (estimated)

If all phases complete:

| Category | Today | After |
|---|---|---|
| `flows.json` size | 596 KB | ~250 KB (-58%) |
| `flows/` (per-tab files, total) | ~660 KB | ~280 KB (-58%) |
| `subflows/` directory | 7 files | 2 files |
| `transform_flows.py` | exists | deleted |
| `hasura/` | exists | moved out |
| `.backup` cruft files | 5 files | 0 files |
| Custom node packages | 1 (`pubsub-queue`) | 0 (replaced by Go) |
| Total repo footprint | ~1.7 MB | ~600 KB (-65%) |

The 65% repo shrinkage is the headline number for engineering. The cleaner repo is also the foundation for trusted CI gates (lint-flows.js) that prevent re-accumulation.

---

## Section 6 — What ADR-0009 needs to absorb from this doc

Concrete change requests for ADR-0009 (Status: Proposed):

1. Add Phase 1.5 — "fix source bugs + delete transform_flows.py" (current: implicit; should be explicit)
2. Add Phase 0.5 — "rotate leaked Firebase key + sanitize history" (security; doesn't block but flagged)
3. **Add a load-bearing reuse rule** — see Section 1.5 of this doc. Verbatim: *"Any pattern from oeecloud-worker / mirror-worker-go (per-tenant queues, DLQ + backoff, reanimator, comparator validation, AWS Secrets Manager flow, single-image dual-mode, etc.) MUST NOT be re-implemented in edge-transformer. Burden of proof is on the engineer to justify why the existing pattern doesn't fit."*
4. **Correct the architecture clause** — edge-transformer does NOT include a local SQLite queue. RabbitMQ owns PLC-data durability; the outbox pattern (RMQ queue + drain loop + DLQ + reanimator from mirror-worker-go) owns outbound-API-call replay. Phase 3 stays at 3-4 weeks, not bumped.
5. Add implementation rule — "every flow edit must update both flows.json AND flows/<tab>.json until flow-manager is removed/disabled" (per Inconsistency 8)
6. Add "Configuration architecture" subsection clarifying client.yaml + AWS Secrets Manager are TWO layers, not one (per Inconsistency 5)
7. Add Phase 1 deliverable — extract `hasura/metadata.json` from edge-node-red to platform repo (per Inconsistency 3)
8. Add Phase 1 deliverable — `scripts/lint-flows.js` + CI (per Inconsistency 10)
9. Add Phase 2 requirement — `compose.dev.yml` analog for edge-transformer (per Inconsistency 7)
10. Add Phase 1 cleanup — consolidate 3 SparkPlug subflows to 1 (per Inconsistency 6)

I'll let you decide whether to fold these into ADR-0009 directly (with an "Errata 2026-06-30" subsection) or just keep this doc as the operational appendix.

---

## Section 7 — What this revision saved us from (the lesson)

The original Inconsistency #4 was a regression — re-implementing a local SQLite queue in Go because I latched onto what the legacy `pubsub-queue` Node-RED node was doing, instead of asking "what does the new infrastructure already provide?"

The corrected analysis recognizes that the staging stack you've built has already solved these problems:

- **PLC data durability** → solved by RabbitMQ being at every factory
- **Outbound replay** → solved by the DLQ + reanimator triad in mirror-worker-go
- **Per-tenant scaling** → solved by oeecloud-worker's Connection+Channel pattern
- **Silent failure prevention** → solved by per-tenant Prometheus labels (PR #56)
- **Safe migration** → solved by the comparator pattern (ADR-0008)

The right principle: **before adding new infrastructure, check what's already there**. The boring answer that reuses proven patterns is almost always the right one. This is what the senior eyes on the team will look for in ADR-0009 review.
