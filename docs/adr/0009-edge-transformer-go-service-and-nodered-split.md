# ADR 0009 — Edge transformer (Go) service + Node-RED responsibility split

**Status:** Proposed
**Date:** 2026-06-30
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team
**Supersedes:** none
**Extends:** [ADR-0004](./0004-edge-nodered-config-centralization.md) (the `client.yaml` direction this ADR consumes), [ADR-0005](./0005-edge-nodered-self-hosted-runner-deploys.md) (per-factory deploy story this ADR's new service rides on)
**Complements:** [ADR-0007](./0007-frontend-write-topology.md) (the API-surface split; this ADR is the data-plane analogue), [ADR-0008](./0008-comparator-validation-go-ports.md) (the porting-discipline template Phase 3 reuses)

---

## Context

### What we have today

`edge-node-red` is a Node-RED instance that lives at every factory. It is the universe inside which all edge work happens — protocol nodes, customer-specific transforms, scheduled jobs, HTTP endpoints for the operator SPA, and a `[API]` tab of standardized endpoints that the team baseline ships to every customer. After more than three years of accretion it has become the single most contentious service in the platform:

- Engineers don't trust changing it (visual diffs are unreviewable; nothing has unit tests)
- CS engineers don't trust changing it (engineering keeps tightening the rules around it)
- Both teams keep paying for it (it's the only piece that touches the PLC + the only piece that knows the customer's quirks)

A Phase 0 audit landed earlier today (`docs/edge-nodered-customization-shapes.md`). One real customer's `flows.json` (3.0 MB, 1,003 nodes, 4 tabs, `Client` tab = 478 nodes / 155 function nodes / **15,870 LOC of JavaScript**) was decomposed into eight customization shapes. The headline finding:

> **9,134 of the 15,870 LOC (58%) is pure config data masquerading as JavaScript** — three function nodes (`set error list json`, `SETTINGS JSON 0.52`, `general PackML config`) sitting at 8,113 / 789 / 232 lines respectively. Of the remaining 6,736 LOC of *actual* customization logic, 89 of 155 function nodes (57%) are state-machine writes (`flow.set`, `global.set`) — the one pattern Node-RED is genuinely good at.

Function size distribution:

```
       0 -    10 LOC :  36 functions  (23%)
      11 -    30 LOC :  76 functions  (49%)    ← realistic low-code
      31 -   100 LOC :  22 functions  (14%)
     101 -   300 LOC :  18 functions  (12%)
     301 -  1000 LOC :   2 functions  ( 1%)
    1001 +     LOC   :   1 function   ( 1%)    ← 8,113-line error_codes dictionary
```

In parallel, the team baseline ships a `[API]` tab with **~20 HTTP endpoints** that are mostly thin proxies (3–6 downstream nodes each — auth, validate, DB call, respond). These are identical across customers. They exist in Node-RED for the same historical reason everything does: it's where the PLC was already wired up.

Adjacent pain (out of scope for this ADR but worth naming for context):
- `Calc_Counters` family — 1000+ LOC function nodes, duplicated 5+ times in operator-UI tabs of the same customer. Pure standardized counter math. The Phase 0 catalog flagged these as a **team baseline** concern, not a per-customer concern (Observation B).
- Config sprawl already addressed by ADR-0004: same fact lived in 4+ places (GitHub Secrets / compose env / `transform_flows.py` / packml_register inserts). ADR-0004 picks `client.yaml` as the single source of truth. This ADR is the runtime that *reads* it.

### What we want

Three things, in priority order:

1. **A clean home for the things that are identical across customers.** Today they're scattered across `[API]` tab endpoints, time/shift helpers cloned per-customer, and inline payload transforms. They should be a real Go service with unit tests and Prometheus metrics, deployed alongside Node-RED at every factory.
2. **A defensible boundary for the things that are genuinely per-customer.** State machines, custom routing, customer-specific reformatting — these stay in Node-RED, but bounded. Governance rules (size limits, no inline HTTP, no inline config blobs) enforced in CI, not via Slack pings.
3. **A config layer that closes ADR-0004's loop.** `client.yaml` becomes the place where mappings, schedules, integrations, and feature flags live — read by *both* the new Go service AND Node-RED's init function, not duplicated.

### Why now

- **Phase 0 catalog landed today.** We have actual numbers from a real customer, not a guess. Designing without that data was the previous reason this refactor stalled.
- **ADR-0004 + ADR-0005 just shipped (PR #89).** The config-loading and per-factory-deploy infrastructure this ADR depends on is decided.
- **oeecloud-worker rewrite is the operational template.** Sessions 62–66 took the cloud Node-RED to Go (PR #56 was the silent-coverage-gap fix that closed it out). The team now has muscle memory for: comparator-validated ports, per-tenant RabbitMQ routing, Prometheus dashboards, and the "observe-then-port-vs-port-then-deprecate" decision pattern (zettel of the same name).
- **mirror-worker-go gave us the DLQ + reanimator pattern** (PR #77 + PR #84). Any failure mode this new service inherits — partial transforms, downstream unreachable, schema drift — has a recipe to mirror.

The cost of *not* doing this now: the next customer onboarding either inherits the existing pile (and grows it), or someone hand-rolls a sixth one-off solution. We've made that mistake enough times to have a memory file for it (`feedback_bugs_bootstrap.md`).

---

## Decision

Split `edge-node-red`'s responsibilities along a **logic-type seam**, not a customer-vs-team seam:

- **Node-RED stays** as the low-code customization layer. It owns: (a) PLC protocol nodes (OPC-UA Items, SparkPlug clients, Modbus/S7 readers — Node-RED's ecosystem here is the best on the market and worth keeping), (b) per-customer state machines (Shape 2 in the catalog — 89 functions, 57% of customization logic, this is the load-bearing pattern), (c) small bounded function nodes for customer-specific routing and reformatting (Shapes 6 + 7).
- **A new Go service `edge-transformer`** owns: standardized transforms (time/shift math, payload normalization, the Calc_Counters family), the 20 HTTP endpoints currently in the `[API]` tab (~14 ported, ~6 eliminated), built-in connectors for the integration shapes (`http_poll`, `heartbeat`, `cloud_api_call`), and the scheduled-action dispatcher.
- **A per-customer config layer** (`clients/<id>/client.yaml` + `data/*.yaml`) replaces the `flow.set('config', { ... })` blobs and scattered configuration. Loaded once at startup by *both* services. ADR-0004's schema is the contract.
- **Both services deployed per-factory** under the ADR-0005 self-hosted-runner model, as siblings in the same compose stack.

### Disposition of the 20 `[API]` tab endpoints

A line-by-line audit during Phase 4 will produce the final list, but the rough split is:

| Disposition | Count | Examples |
|---|---|---|
| **Port to Go** (`edge-transformer` exposes the same HTTP path) | ~14 | `/po/start`, `/po/stop`, `/downtimes/justify`, `/scanned-boxes/post`, `/equipment/status`, `/shift/current` — anything that's a thin proxy to edge-api or local TSDB |
| **Eliminate** (operator SPA calls cloud edge-api directly, behind ADR-0007 router) | ~6 | Endpoints that exist purely because the SPA was historically pointed at the factory's Node-RED for everything — once ADR-0007's mixed-topology router is live, the SPA goes direct |

The 14 ported endpoints become Go handlers with explicit `*_test.go` files and Prometheus `http_request_duration_seconds` labels per route. No Node-RED `[API]` tab in the steady state.

### Single image, two boot modes (mirror of ADR-0007)

`edge-transformer` ships as one Docker image. A boot-time env var `EDGE_TRANSFORMER_MODE` selects:

- `factory`: full pipeline — consume from RabbitMQ `plc.normalized.<tenant>.#`, run transforms, publish to downstream destinations, expose HTTP endpoints on `:8080`.
- `dev_replay`: read pcap-style recorded message batches from disk, run pipeline against them, exit. Used by Phase 3 comparator validation (ADR-0008 pattern).

The two modes share 100% of the transform code; only the I/O perimeter differs. This is the same shape as ADR-0007's `cloud_router` vs `factory_local` split for edge-api, and the same shape as oeecloud-worker's online vs replay modes today.

### Architectural shape

```
┌────────────────────────────────────────────────────────────────────────┐
│  Factory floor — PLC layer                                             │
│   B&R / Allen-Bradley / Siemens / Schneider over OPC-UA / SparkPlug    │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ OPC-UA / SparkPlug B / S7 / Modbus
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│  edge-node-red  (THIN — keeps only what's irreducibly per-customer)    │
│                                                                         │
│   ─ PLC protocol nodes (Shape 1: OPC-UA Items / SparkPlug clients)     │
│     ↳ Config-nodes auto-generated from client.yaml.equipment_mapping   │
│   ─ Per-equipment state-machine subflows (Shape 2)                     │
│     ↳ One subflow per equipment, ≤200 LOC, declared contract           │
│   ─ Customer-specific routing + reformatting (Shapes 6, 7)             │
│     ↳ Switch nodes, small function nodes, change nodes                 │
│   ─ Init function loads data tables from client.yaml.data_tables       │
│                                                                         │
│   What used to be here but ISN'T anymore:                              │
│   ✗ The 9,134 LOC of config-in-functions  → client.yaml + data/*.yaml  │
│   ✗ The 20 [API] tab endpoints            → edge-transformer (Go)      │
│   ✗ Time/shift math (Shape 4)             → edge-transformer.shiftcalc │
│   ✗ Standardized inject schedules         → edge-transformer scheduler │
│   ✗ HTTP integrations (Shape 8)           → edge-transformer connectors│
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ AMQP publish
                                   │ exchange: edge.plc-normalized (topic)
                                   │ routing key: plc.normalized.<tenant>.equipment.<id>
                                   │ payload: per docs/clients/_normalized-payload-schema.yaml v1.0
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│  RabbitMQ (already deployed per-factory)                               │
│   Queues:                                                              │
│   ─ transformer.in.<tenant>          (per-tenant, durable, prefetch=N) │
│   ─ transformer.dlq.<tenant>         (DLX target)                      │
│   ─ transformer.retry.<tenant>       (reanimator-loop source)          │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │ AMQP consume (errgroup, 1 goroutine per tenant)
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│  edge-transformer  (Go, EDGE_TRANSFORMER_MODE=factory)                 │
│                                                                         │
│   Pipeline:                                                             │
│    1. Decode normalized PLC envelope (protobuf or JSON; TBD Phase 2)   │
│    2. Apply scaling/offsets (client.yaml.equipment_mapping)            │
│    3. Enrich with shift bucket (shiftcalc + client.yaml.shifts)        │
│    4. Run Calc_Counters family (standardized OEE math)                 │
│    5. Fan out:                                                          │
│       ─ → GCP PubSub  (cloud OEE bus, oeecloud-worker downstream)      │
│       ─ → local TSDB  (ADR-0001 offline-tolerant store)                │
│       ─ → RMQ edge.events.<tenant>  (state-machine input back to N-R)  │
│   HTTP API on :8080 — the 14 ported [API] tab endpoints                │
│   Scheduler — fires built-in actions or "nodered:<flow>" hooks         │
│   DLQ + reanimator — same topology as mirror-worker-go (PR #77 + #84)  │
│                                                                         │
│   Single Docker image; second mode `dev_replay` reads recorded         │
│   batches from disk for comparator validation (ADR-0008).              │
└────────────────────────────────────────────────────────────────────────┘
```

### Why this seam, not others

Three other seams were considered and rejected:

- **By-customer:** "give each customer their own Go service" — wrong granularity; multiplies operational surface by N customers, and the *standardized* work is what we wanted to consolidate, not fragment further.
- **By-protocol:** "Go service per protocol (OPC-UA-Go, SparkPlug-Go)" — Node-RED's existing protocol nodes are mature and battle-tested. Re-implementing OPC-UA client logic in Go would burn ~3 months for zero customer-visible improvement.
- **All-Go (kill Node-RED):** the seductive option. Rejected because Shape 2 (state machines) is real work that CS engineers need to author *without* an engineering deploy. The Node-RED low-code surface is the one Packiot has, and customers' onboarding velocity depends on it. Replacing that with a Go DSL is at least a year of work and a permanent CS-team retraining cost.

The logic-type seam (standardized → Go, per-customer → Node-RED) lines up with team ownership (platform engineers → Go, CS → Node-RED), with testability (Go gets unit tests, Node-RED gets contract tests at the RMQ boundary), and with the actual evidence in the Phase 0 catalog.

---

## Consequences

### Positive

- **The 58% config-as-code problem disappears.** 9,134 LOC of JS becomes YAML. Diffable, reviewable, lintable, version-controlled. No new infrastructure needed beyond `client.yaml` (ADR-0004 already shipped it).
- **The team baseline shrinks dramatically.** `[API]` tab gone, time/shift functions gone, Calc_Counters gone. What's left in the baseline is the protocol shell + the generated config-node templates — probably ≤100 nodes.
- **CS team velocity goes up, not down.** They keep the low-code surface for the work that's genuinely customization (state machines, custom routing). They lose the *bad* parts: pasting config into function nodes, copy-pasting endpoints from other customers, debugging time-math.
- **Standardized transforms get unit tests for the first time in Packiot's history.** Today, OEE math has zero unit tests; it's validated by "does the dashboard look right". Phase 3 adds `*_test.go` files with comparator-validated fixtures (ADR-0008).
- **Per-tenant Prometheus labels come for free.** oeecloud-worker's Strategy C Phase 2a pattern (per-tenant AMQP channels + per-tenant metric labels) ports directly. Same Grafana dashboard template.
- **Reuses everything we've already paid for**: RabbitMQ at every factory, DLQ + reanimator (PR #77 + #84), per-factory self-hosted runner deploys (ADR-0005), comparator validation discipline (ADR-0008), AWS Backup + EBS snapshot policy (PR #78).

### Negative / Trade-offs

- **Two services instead of one at every factory.** Operational surface grows (one more container to monitor, one more deploy unit, one more place a config error can land). Mitigation: shared compose stack, shared observability stack, shared deploy pipeline — incremental operational cost is roughly the cost of one Grafana row.
- **Phase 3 is a 3–4 week port of code that "already works".** During the port, both paths exist in parallel; bugs introduced in the Go port don't surface until cutover. Mitigation: ADR-0008 comparator validation — every ported transform runs both implementations in shadow mode and asserts byte-equality on outputs, same way mirror-worker-go's value-sync was validated.
- **`client.yaml` becomes the most important file per customer.** A typo in `equipment_mapping` silently misroutes PLC data; a wrong `scale` factor produces wrong OEE for weeks. Mitigation: `scripts/validate-client-yaml.sh` (CI-enforced), startup-time schema check that hard-fails if equipment IDs don't exist in `packml_register`, dry-run mode that reports the diff between current YAML and the live customer's flow.
- **Customizations now spread across two artifacts (Node-RED subflows + client.yaml).** The CS engineer needs to know which one to edit for which change. Mitigation: onboarding doc (Phase 5 deliverable) with a decision tree; the `customization_flows:` section in client.yaml *declares* which subflows exist, giving a single map.
- **Boundary erosion risk.** Without enforcement, someone will paste an HTTP call into a Node-RED function node again "just this once" because they're under deadline. Mitigation: CI lint rules (max 200 LOC per function, no `http.request` import, no `flow.set` of >50-line JSON literals); reviewer culture (the *load-bearing* mitigation — see Implementation rules below).
- **State machines in Node-RED don't get unit tests.** Shape 2 stays in Node-RED, where the testing story is "deploy to staging and watch". Mitigation: contract tests at the RMQ boundary (publish synthetic PLC events, assert downstream events) — this is testable without testing the Node-RED internals.
- **Phase 3's Calc_Counters port is genuinely scary.** It's the OEE math customers' billing-relevant numbers depend on. Mitigation: longest comparator-validation window of any phase (≥30 days of parallel runs before cutover), same recipe as the oeecloud-worker cutover sessions 62–66.

---

## Phased rollout

**Phase 0 — Customization-shape catalog (DONE, this session, 2026-06-30)**
- `docs/edge-nodered-customization-shapes.md` shipped
- 1 real customer analyzed; 8 shapes identified; the 9,134-LOC config-in-functions number measured
- Phase 0.5 (live runtime tracing) and Phase 0.75 (2–3 additional customer YAMLs) are deferred until Phase 3 needs them; the shapes are clear enough to design against

**Phase 1 — Config schema (STARTED, this session)**
- `docs/clients/_schema.yaml` shipped (the formal `client.yaml` schema; 9 sections matching the 8 shapes + identity)
- `docs/clients/cpack.example.yaml` shipped (populated example for one real customer)
- Remaining: `scripts/validate-client-yaml.sh` (jsonschema-based), schema versioning policy, conversion tooling for the 9,134 LOC of CPack's config blobs into `data/*.yaml` files (mostly mechanical — a Node.js script that reads `flows.json`, finds the named function nodes, parses the JS literals out, writes YAML)
- ~2 days remaining

**Phase 2 — RabbitMQ bridge + Go skeleton (~5 days)**
- New exchange `edge.plc-normalized` (topic) declared via Terraform / IaC at every factory's RabbitMQ
- Per-tenant queues `transformer.in.<tenant>` with DLX → `transformer.dlq.<tenant>`, same topology as `sparkplug.data.<tenant>` from oeecloud-worker Phase 2a
- New Node-RED `amqp-pub-plc-normalized` flow at the protocol-node output edge: takes the raw OPC-UA / SparkPlug message, wraps it in the normalized envelope (defined Phase 2), publishes to the exchange with `routing_key = plc.normalized.<tenant>.equipment.<id>`
- Go skeleton in `services/edge-transformer/` — `main.go`, `internal/amqp/`, `internal/transform/`, `internal/http/`, `Dockerfile`, `cmd/replay/`. Same layout as `services/oeecloud-worker/`
- First end-to-end smoke: protocol → N-R wrapper → RMQ → Go skeleton (logs message) → ack. No real transforms yet.
- Single tenant (CPack) on staging only.

**Phase 3 — Port team baseline standardized transforms (~3–4 weeks)**
- One PR per transform family, comparator-validated (ADR-0008 pattern: both N-R and Go run in parallel, outputs compared at the RMQ boundary, ≥7 days of zero-diff before cutover; ≥30 days for Calc_Counters specifically)
- Transform families to port:
  - Time / shift math (Shape 4) — small, low-risk; ships first to build muscle memory
  - Payload normalization (parameter ID lookup, datatype enforcement, unit conversion)
  - Counter family (`Calc_Counters` and friends — the OEE-critical one)
  - Fan-out to GCP PubSub (mirrors current N-R `amqp-pub-oee` flow)
  - Fan-out to local TSDB (ADR-0001 destination)
- Each family ships its own `*_test.go` with fixtures drawn from real recorded RMQ batches
- At end of Phase 3: the data-plane path runs through Go end-to-end on staging; Node-RED's role shrinks to protocol + customization

**Phase 4 — Migrate the 20 HTTP endpoints (~2 weeks)**
- Audit `[API]` tab — produce the final port-vs-eliminate list (rough split: ~14 port, ~6 eliminate)
- For ported endpoints: implement Go handlers under `internal/http/`, expose at the same path, add Prometheus middleware, write per-endpoint tests
- For eliminated endpoints: confirm the operator SPA route either already goes to cloud edge-api or can be switched (ADR-0007's cloud_router middleware is the receiving end)
- Cutover: update operator SPA `EDGE_API_BASE_URL` to point at `edge-transformer:8080` for the ported set; N-R `[API]` tab deleted in the same PR
- Per-endpoint shadow window: 48h of parallel traffic with diff logging before flipping the SPA

**Phase 5 — Customization-tab governance + onboarding doc (~3 days)**
- CI lint rules in the parent repo's PR workflow:
  - `scripts/lint-customization-flows.sh` enforces: max 200 LOC per function, no `http.request` / `http.get` imports, no `flow.set` / `global.set` of literals >50 lines, every subflow declares its `inputs:` / `outputs:` contract
  - `scripts/validate-client-yaml.sh` runs on every PR touching `clients/`
- Onboarding doc `docs/onboarding/new-customer.md` — step-by-step: write `client.yaml`, convert any config blobs to `data/*.yaml`, declare state-machine subflows under `customization_flows:`, validate, ship
- The doc explicitly references the Phase 0 catalog by shape so the CS engineer can match their problem to a shape and know which file to touch

**Total: ~8–10 weeks of focused work**, plus the comparator-validation tail (Calc_Counters specifically needs ≥30 days of parallel runs before cutover, so calendar time is longer than engineer-days).

---

## Implementation rules (load-bearing — reviewers should enforce)

These are the rules whose violation creates the next generation of the problem this ADR is solving. Every reviewer is responsible for blocking PRs that break them.

1. **Max 200 LOC per Node-RED function node.** CI-enforced via `scripts/lint-customization-flows.sh`. The 8,113-line `set error list json` outlier is exactly what we're refusing to allow back in.
2. **No `flow.set()` / `global.set()` of JSON literals >50 lines.** If you have a config object that big, it belongs in `client.yaml` `data_tables:` and a file under `clients/<id>/data/`. Lint-enforced.
3. **No `http in` / `http out` / `http request` nodes in customization flows.** Use `integrations:` in `client.yaml` and let the Go layer's connector handle it. The standard `[API]` tab is gone; if you're adding an HTTP endpoint, you're adding it in Go.
4. **Every Phase 3+ port is comparator-validated** per ADR-0008. No "we tested it on staging" — both implementations run in parallel, outputs diffed at the RMQ boundary, ≥7 days zero-diff (≥30 for OEE-critical math) before cutover. The oeecloud-worker rewrite is the template.
5. **All standardized transforms in Go have unit tests.** PR is rejected without `*_test.go`. The bar is "fixture-driven test covering the transform's contract" — not 100% coverage, but no untested transforms.
6. **`edge-transformer` is a single Docker image with mode selection via env var.** Matches ADR-0007's edge-api dual-binary pattern. Two images = two CI pipelines = two version-skew vectors. Don't.
7. **Every customization subflow declares its `inputs:` / `outputs:` contract in `client.yaml`.** Validated at load time. A subflow with no declared contract refuses to load; this is the only mechanism that prevents the contract from rotting silently.
8. **Per-tenant Prometheus labels are mandatory on every metric**, matching oeecloud-worker's PR #53 pattern. A single-label metric in a multi-tenant service is the silent-coverage-gap zettel waiting to happen (see PR #56 retrospective).
9. **DLQ + reanimator loop ships in Phase 2, not "later".** Same topology as mirror-worker-go (PR #77 + PR #84). If we ship `edge-transformer` without a DLQ, the first transient downstream outage will eat messages and we'll learn the lesson again. Reuse the existing code, don't re-derive.
10. **`client.yaml` schema changes are MAJOR-version bumps.** Customers with old schemas keep working; new schemas opt in. Semver discipline on a config schema is the difference between "a file the CS team owns" and "a brittle interface that engineering blocks releases on".

---

## Open questions for review

- **Q1 — Envelope format for `plc.normalized.<tenant>`: protobuf or JSON?** Protobuf is faster, schema-versioned, painful to debug in `rabbitmqctl list_messages`. JSON is slow, schema-via-convention, trivial to debug. oeecloud-worker landed on JSON; the message rates we've measured (CPack peak ~15 msg/s) don't justify protobuf yet. **Recommendation: JSON for Phase 2, revisit at Phase 3 if Calc_Counters processing pegs CPU.** *(Update 2026-06-30: the v1.0 schema landed as `docs/clients/_normalized-payload-schema.yaml` — JSON-shaped, 5 payload types, envelope + extensions + topic-routing topology. Consumers and publishers MUST conform to this file; changes per its own versioning policy at the bottom.)*

- **Q2 — Where does `edge-transformer` connect to the cloud?** Today edge-nodered POSTs to `back4-api` and `edge-api` cloud endpoints. The natural answer is "edge-transformer takes those calls over". But ADR-0007 is also routing critical writes through a cloud edge-api proxy — does `edge-transformer` send to cloud edge-api, or directly to cloud TSDB? **Likely answer: cloud edge-api, to keep ADR-0007's routing as the single API surface.** Confirm with the team before Phase 4.

- **Q3 — Do customization subflow contracts need a typed schema, or is "this subflow consumes routing-key X" enough?** A full schema (with field types per input message) catches more bugs at load time but is more work to write. **Recommendation: routing-key-only for Phase 2–4; revisit if subflow input bugs become a real cost.**

- **Q4 — How does the Node-RED protocol layer learn about `client.yaml` changes without a restart?** Option A: restart Node-RED on every `client.yaml` change (simple, ~30s downtime per change). Option B: file-watcher in the init function that re-loads data tables but not protocol nodes (complex, partial). **Recommendation: Option A for Phase 2; revisit if the change frequency justifies the complexity.**

- **Q5 — What's the migration path for the 8,113-line `error_codes` blob specifically?** Mechanically converting JS-object-literal → YAML is straightforward, but the customer might have semi-recently edited it and we don't want to lose changes. **Action: snapshot the current literal first; convert via script; diff against the customer's last 3 deploys to catch in-flight edits.**

- **Q6 — When do we re-evaluate "Node-RED stays"?** This ADR keeps Node-RED based on Shape 2 (state machines, 89 of 155 functions in the one customer studied). If after 2-3 more customer audits the state-machine pattern doesn't hold up — say it's actually <20% in other customers — the all-Go option resurfaces. **Action: re-do Phase 0 analysis on customer #2 and customer #3 during Phase 3.**

---

## References

- [ADR-0001](./0001-edge-persistence-local-timescaledb.md) — local TimescaleDB at the factory; one of `edge-transformer`'s fan-out destinations
- [ADR-0004](./0004-edge-nodered-config-centralization.md) — `client.yaml` direction this ADR consumes
- [ADR-0005](./0005-edge-nodered-self-hosted-runner-deploys.md) — per-factory deploy story `edge-transformer` rides on
- [ADR-0007](./0007-frontend-write-topology.md) — API-surface split for writes (this ADR is the data-plane analogue); structural reference for the single-image-two-modes pattern
- [ADR-0008](./0008-comparator-validation-go-ports.md) — porting-discipline template Phase 3 reuses (and Phase 4 for the endpoints)
- `docs/edge-nodered-customization-shapes.md` — Phase 0 catalog, the empirical foundation of this ADR's "what stays in Node-RED" decisions
- `docs/clients/_schema.yaml` — formal `client.yaml` schema
- `docs/clients/cpack.example.yaml` — populated example for one real customer
- `services/oeecloud-worker/` — the operational template: Go service replacing Node-RED, same per-tenant RMQ pattern, same Prometheus per-tenant labels, same comparator validation
- `services/mirror-worker-go/` — DLQ + reanimator topology this ADR's Phase 2 copies verbatim (PR #77 + PR #84)
- Phase 0 zettel cluster (link from `~/notes/`): `node-red-as-stream-processor-anti-pattern`, `observe-then-port-vs-port-then-deprecate`, `silent-metric-coverage-gap`, `stateful-config-loaders-ignore-source-edits`
- [Node-RED flow contract patterns](https://nodered.org/docs/user-guide/messages) — the message-typing convention subflow contracts should follow
- [Watermill (Go message-router library)](https://watermill.io/) — reference for the per-tenant consumer pattern, even if we don't adopt the library directly

---

## Errata 2026-06-30 (post-draft review)

Cross-reference with [edge-nodered-repo-refactor.md](../edge-nodered-repo-refactor.md) surfaced 10 file-level inconsistencies between this ADR's assumptions and the actual `edge-node-red` repo state. The most important corrections are absorbed below; the full list lives in Section 6 of the refactor doc.

### Correction 1 — Phase 3 estimate stays at 3-4 weeks (NOT bumped to 4-5)

The original draft (Phase 3 section above) implicitly suggested the Go service would need a local-disk queue for outage tolerance — mirroring what the legacy `pubsub-queue` Node-RED node provided via SQLite. **That was a regression past existing infrastructure.** The corrected architecture:

- **PLC data durability** → RabbitMQ at the factory owns this. Node-RED publishes to `plc.normalized.<tenant>` with `persistent: true`; RabbitMQ's persistent queues survive transformer restarts. **No SQLite in Go.**
- **Outbound API call replay** → Outbox pattern (RabbitMQ queue `outbox.cloud_api.<tenant>` + drain loop), reusing `mirror-worker-go`'s DLQ + reanimator triad verbatim (PRs #77 + #84).

Phase 3 estimate restored to 3-4 weeks. The `pubsub-queue` custom node is simply DELETED in Phase 2, replaced by `node-red-contrib-amqp`.

### Correction 2 — Load-bearing reuse rule (NEW implementation rule #11)

Add to the Implementation Rules section:

> **Rule 11 — Pattern reuse over invention.** Any pattern from `oeecloud-worker` or `mirror-worker-go` (per-tenant queues, per-tenant Prometheus labels, DLQ + exponential backoff, reanimator loop, comparator validation, single-image dual-mode boot, AWS Secrets Manager flow) **MUST NOT be re-implemented** in edge-transformer. If a need feels "almost like" one of these but slightly different, the burden of proof is on the engineer to justify in the PR description why the existing pattern doesn't fit — not to invent a new one.

This rule is load-bearing because the cost of pattern drift is invisible until production: oeecloud-worker's silent-metric-coverage-gap (PR #56) is the worst-case example — a tenant routing change broke silently for hours because metrics weren't per-tenant. The fix was "use the per-tenant pattern that was already there." See [edge-nodered-repo-refactor.md Section 1.5](../edge-nodered-repo-refactor.md) for the full pattern inventory (12 entries).

### Correction 3 — Configuration architecture is TWO layers, not one

The original draft implied `client.yaml` is THE config layer. The corrected picture:

- **Layer 1 — `client.yaml`** (non-secret config: equipment mappings, schedules, integrations, customization flow paths). Versioned in git per-customer.
- **Layer 2 — AWS Secrets Manager** (the actual secrets: DB passwords, API keys, certificate bytes). Already exists in `edge-node-red/entrypoint.sh`'s `AWS_SECRET_ID` flow; the new architecture builds on top, doesn't replace.

Naming convention: every `*_env: VAR_NAME` field in `client.yaml` must have a matching key in the AWS secret JSON. CI lint checks both sides.

### Corrections 4-10 (operational, in refactor doc)

Folded into Phase 1 / Phase 1.5 scope without changing the ADR's overall structure:

- **Phase 0.5** — rotate the leaked Firebase API key (`AIzaSyCRK02fBbgho-VSQrjt5bIZzzVdoIgpRGo`) found hardcoded in `transform_flows.py`; sanitize repo history. Independent of the refactor; do this week.
- **Phase 1** — extract `hasura/metadata.json` from `edge-node-red` to `packiot-stack-alpha` (Hasura metadata isn't edge-nodered's concern).
- **Phase 1** — consolidate the 3 SparkPlug subflow versions (`SparkPlug_v1.10.37`, `v1.10.39`, `v1.10.39.1`) to a single canonical version.
- **Phase 1** — add `scripts/lint-flows.js` + `.github/workflows/lint-flows.yml` enforcing governance rules (max LOC per function, no `flow.set` of big JSON, no `http in/out` in customization tabs).
- **Phase 1** — delete the 5+ `.backup` files committed to `edge-node-red`'s repo root + update `.gitignore`.
- **Phase 1.5** — fix the Calc_Counters timestamp bug + dead-debug-var bug at SOURCE in `flows.json` + `flows/Sparkplug.json`; replace hardcoded Hasura URLs / Firebase key with `env.get()` at source; then DELETE `transform_flows.py` entirely.
- **Phase 2** — add `compose.dev.yml` analog for `edge-transformer` (matches the existing `edge-node-red` dev tooling).
- **Implementation rule (new)** — every flow edit must update BOTH `flows.json` AND `flows/<tab>.json` until `node-red-flow-manager` is removed/disabled (per session 64 zettel `stateful-config-loaders-ignore-source-edits`).

### What this revision saved us from

The Phase 3 SQLite regression would have added ~1 week of avoidable Go work and a new infrastructure layer that duplicates RabbitMQ's guarantees. The corrected design is simpler AND more aligned with the rest of the platform. The lesson, for anyone reviewing future ADRs: **before adding new infrastructure, check what's already there.** The boring answer that reuses proven patterns is almost always the right one.

---

## Decision log

| Date | Decision | Decider |
|---|---|---|
| 2026-06-30 | Phase 0 catalog completed; ADR drafted | Emmanuel + Claude |
| 2026-06-30 | Phase 1 (schema + example) committed in parallel with this ADR | Emmanuel + Claude |
| 2026-06-30 | Errata applied post-review (10 inconsistencies; correction: no Go-local-SQLite; reuse-rule load-bearing) | Emmanuel + Claude |
| TBD | Reviewed by platform team | |
| TBD | Reviewed by CS team (governance rules + onboarding doc) | |
| TBD | Accepted | |
| TBD | Phase 2 PR opened | |
| TBD | Phase 3 cutover (Calc_Counters specifically) — requires ≥30d zero-diff | |
