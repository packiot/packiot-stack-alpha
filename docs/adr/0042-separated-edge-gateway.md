# ADR-0042 — Separated Edge Gateway: split the client edge into a connectivity plane, a Go SparkPlug agent, and a governed client CI/CD

**Status:** Proposed · **Date:** 2026-07-23 · **Scope:** edge (client-side edge stack) + the client-delivery pipeline · **Decision owner:** chief architect (pending USER sign-off) · **Altitude:** this ADR is the *how* for the north-star's P1 Connectivity/Edge pillar and its principle #7 (edge/cloud durable split); it sits under [ADR-0038](0038-north-star-factory-platform.md) and refines the edge trajectory [ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md)/[ADR-0010](0010-sparkplug-decode-in-go-end-state.md)/[ADR-0011](0011-durability-boundary-and-store-and-forward.md) began.

**Synthesis note.** This ADR records the *converged* decision of four independent design-squad lenses — an edge/SparkPlug architect, a Go-implementation lens, a DevOps/client-CI-CD lens, and a customization/operator-migration lens. The analysis is complete; this document is the decision of record, not a re-investigation. Where a claim cites a file (`services/edge-transformer/cmd/s7-reader/main.go`, `internal/sparkplug/`, `internal/outbox/`), the lens grounded it against the live tree.

---

## 1. Context

### 1.1 The monolithic client edge today

Every client factory runs one `edge-node-red` instance that is, per [ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md)'s Phase-0 catalog, "the universe inside which all edge work happens" — PLC/OPC-UA/S7/Modbus protocol I/O, per-client state machines and reformatting, scheduled jobs, an operator HTTP surface, **and** the SparkPlug B encode/session logic that puts factory data on the wire. One real customer's `flows.json` measured 3.0 MB / 1,003 nodes, of which the `Client` tab alone was 478 nodes / 15,870 LOC of JavaScript — 58% of it pure config masquerading as code.

ADR-0009 split *transforms + HTTP* out into the cloud `edge-transformer` (Go). ADR-0010 moved SparkPlug *decode* into Go at the cloud. ADR-0011 drew the durability boundary at "the moment data enters Packiot-owned software." What none of them finished is the **client-side transmission plane**: on a real client edge, the thing that *assigns aliases, mints NBIRTH/DBIRTH, tracks the rolling sequence, and publishes SparkPlug over the WAN* still lives welded to the connectivity logic — either inside Node-RED's `SparkPlug_v1.10.39.1` subflow, or (for a real S7 line) inside a single Go binary that does both jobs at once.

### 1.2 The customization spectrum — CPACK-light vs Incoplast-heavy

The two live tenants bracket the whole design space:

- **CPACK is already on target.** Its operator surface is the shared **operator4 SPA** talking to ~21 REST endpoints; zero bespoke UI. Its telemetry is stock SparkPlug. CPACK is what "config-driven, not fork" looks like when it works.
- **Incoplast is the heavy case.** Its edge carries **~107 connectivity/telemetry nodes** (tags, protocol shaping, an on-prem ERP/DB sync — [ADR-0019](0019-edge-customization-capabilities.md) G1) *and* a **389-node `mui_*` operator UI fork** that talks **direct to Hasura/GraphQL** and drags **two drifting UI versions**. That fork is the fork-tax the platform exists to retire ([ADR-0018](0018-operator-frontend-integration-makeover.md), [ADR-0029](0029-front4-dashboard-composition-and-metric-layer.md)).

The mistake would be to treat these as two architectures. They are **one architecture at two points on a spectrum** — the difference must reduce to *config + server-side ACL*, never a code fork (north-star principle #2).

### 1.3 The load-bearing observation — s7-reader already welds it

The decisive grounding is that **the agent already exists in embryo.** `services/edge-transformer/cmd/s7-reader/main.go` reads a Siemens S7 PLC and *republishes its tags as SparkPlug B over MQTT* — its own header says it makes "a real S7 line … look to the rest of the stack exactly like plc-sim / a native SparkPlug PLC." It calls `poller.EncodeBirth`/`EncodeData`, publishes `spBv1.0/<group>/NBIRTH/<node>` (retained) and `spBv1.0/<group>/NDATA/<node>`, drops `birthed=false` to force a re-birth on read failure, and loads its tag map from `client.yaml` (`internal/clientconfig`). That is a PLC-reader **welded to** a SparkPlug transmitter in one binary.

The same welding lives in `cmd/plc-sim` (synthetic totalizers → SparkPlug) and, in JavaScript, in the Node-RED SparkPlug subflow. **The transmission plane is real, proven, and tested** (`internal/sparkplug/parity_test.go` confirms Go-encoded bytes decode identically under the JS `sparkplug-payload` lib Node-RED wraps). What it is *not* is **separated, productized, or reusable** as the client edge's transmission tier.

This ADR is therefore a **decoupling + productization**, not a greenfield build.

---

## 2. Decision

### 2.1 Split the client edge into three tiers along a rate-of-change × degree-of-customization seam

```
Factory floor (PLCs: S7 / OPC-UA / Modbus / native SparkPlug)
   │  raw fieldbus
   ▼
┌────────────────────────────────────────────────────────────────────┐
│ TIER 1 — CONNECTIVITY PLANE  (Node-RED, per-client, low-code)       │
│   PLC/OPC-UA/S7/Modbus I/O + per-client shaping/ERP reads            │
│   Emits RAW normalized tags. SparkPlug-IGNORANT.                     │
│   MUST NOT publish spBv1.0/*  · never sees an alias / seq / protobuf │
└──────────────────────────────┬─────────────────────────────────────┘
   │  raw-tag JSON over INTERNAL loopback MQTT
   │  topic: edge/raw/<tenant>/<node>/<device>   (tag-SUFFIX names + quality)
   ▼
┌────────────────────────────────────────────────────────────────────┐
│ TIER 2 — TRANSMISSION PLANE  (Go SparkPlug agent, uniform)          │
│   Owns ALL SparkPlug: alias ASSIGN, NBIRTH/DBIRTH, rolling seq +     │
│   rebirth-on-gap, NDEATH-via-MQTT-LWT, report-by-exception,          │
│   store-and-forward (outbox), protobuf encode, mTLS publish          │
└──────────────────────────────┬─────────────────────────────────────┘
   │  SparkPlug B over the OT/IT WAN (mTLS, per-tenant)
   ▼
┌────────────────────────────────────────────────────────────────────┐
│ CLOUD — edge-transformer  (decode + Calc — UNCHANGED)               │
│   spBv1.0/+/+/+/+ → decode → alias-resolve → Calc → F3              │
└────────────────────────────────────────────────────────────────────┘
```

The seam is **rate-of-change × degree-of-customization**:

- **Tier 1 (Node-RED)** does the messy, per-client, *changes-weekly* I/O — exactly the low-code state-machine work ADR-0009 proved should stay in Node-RED.
- **Tier 2 (Go agent)** does the uniform, protocol-rigid, *changes-never* SparkPlug session — exactly the heavy, testable, standards-bound work ADR-0009/0010 proved should be in Go.

This is the same "logic-type seam, not customer-vs-team seam" ADR-0009 chose, pushed one tier further: ADR-0009 split *transforms* out of Node-RED; this ADR splits the *SparkPlug session* out too, leaving Node-RED as a pure tag provider.

### 2.2 The agent is a DECOUPLING, not a greenfield

`services/edge-transformer/cmd/sparkplug-agent` **is `s7-reader` with the PLC input swapped for the internal raw-tag feed.** It reuses, verbatim where possible:

| Reused component | From | Role in the agent |
|---|---|---|
| `internal/sparkplug` (encode + `parity_test.go`) | ADR-0010 spike | Protobuf encode; parity vs the JS `sparkplug-payload` lib |
| `internal/outbox` (SQLite buffer) | ADR-0011 Phase 3 | Store-and-forward across a WAN outage |
| the MQTT-subscriber shape (`internal/mqtt`) | ADR-0010 Phase 2 | Consume the internal raw-tag topic |
| `internal/clientconfig` (`client.yaml` loader) | ADR-0004/0009 | Per-tenant topic prefix, tag map, endpoints |

**Genuinely net-new** (the only new code the split needs):

1. **Raw-tag JSON ingest** — parse the Tier-1 loopback message shape.
2. **The alias-ASSIGN allocator** — today's producers *encode a table they own*; the agent must **allocate** the name↔alias map from incoming raw tags and freeze it into NBIRTH/DBIRTH.
3. **RBE dirty-tracking** — report-by-exception: only publish NDATA for tags whose value changed since last publish.
4. **The bdSeq / NBIRTH / NDATA / NDEATH session state machine** — the producer-side mirror of the consumer-side `aliastable.go` StateStore ADR-0010 already shipped.

**The one genuinely-new SparkPlug concern is NDEATH-via-LWT.** No producer in the tree registers an MQTT Last-Will today (s7-reader publishes a retained NBIRTH and re-births on recovery, but never arranges for the broker to announce its *death*). A productized transmission agent MUST register an NDEATH payload as the MQTT Last-Will-and-Testament at connect time, so an ungraceful agent loss is announced to the cloud as a birth/death state transition — the observability half of ADR-0011's asymmetric-responsibility rule (we make OT-side loss *observable*).

### 2.3 The Node-RED → Go contract

The internal hop is a **plain-JSON raw-tag message over a loopback MQTT topic**:

- **Topic:** `edge/raw/<tenant>/<node>/<device>`.
- **Payload:** the tag **SUFFIX** name (e.g. `Speed`, `Count.Good`), a value, a quality flag, and an *optional* type hint. The agent **prepends the `packml_topic` prefix from `client.yaml`** — Node-RED never spells a full SparkPlug path.
- **CI-lintable invariants** (the contract's teeth):
  - Tier 1 **MUST NOT** publish `spBv1.0/*` (that namespace belongs to the agent alone).
  - Tier 1 **never** constructs an alias, a sequence number, or a protobuf byte.
  - Every raw tag Tier 1 emits is a suffix; the prefix is config, not code.

This is the ADR-0009 boundary discipline (the RMQ-normalized-envelope contract) restated for the *encode* seam: a governed, lint-enforced interface so the low-code plane cannot silently re-absorb the protocol job.

### 2.4 Why encode-at-edge / decode-at-cloud is INTENTIONAL (not a redundant round-trip)

A fair objection: Tier 1 emits JSON, the agent encodes to SparkPlug, the cloud decodes back — why not ship the JSON straight to the cloud and skip the protobuf dance? Because the SparkPlug crossing buys five things JSON-over-WAN does not, and it buys them **only at the OT/IT WAN boundary**:

1. **Birth/death session state** — NBIRTH/DBIRTH/NDEATH give the cloud a *stateful* view of what's alive, not a stream of disconnected readings.
2. **Sequence-gap detection** — the rolling `seq` lets the cloud *know* it missed data (the `OnSeqGap` hook `aliastable.go` already fires), satisfying ADR-0011's "make OT-side loss observable."
3. **~4× alias compression** — NDATA carries alias-only values; ADR-0010 measured NDATA ≥ 4.36× smaller than NBIRTH. Over a metered/flaky factory WAN that is real money and real resilience.
4. **Store-and-forward integrity** — a buffered, seq-stamped, self-describing stream replays cleanly after an outage.
5. **ONE ingest contract for every tenant** — native-PLC, s7-reader, plc-sim, and the new agent all look **identical** to `edge-transformer` (`spBv1.0/+/+/+/+`). This is the [ADR-0032](0032-collapse-to-single-flow-f3.md) thesis made client-side: the cloud has one source-agnostic processor because the edge speaks one protocol.

The **internal hop stays plain JSON** precisely because none of these payoffs exist on a loopback — there is no WAN to compress, no session to track across a reliable localhost socket, no second tenant on the wire. **Standardize only at the crossing that needs standardizing.** Encode at the OT/IT WAN boundary; leave localhost cheap. mTLS is applied per-tenant on the WAN, never on the loopback.

### 2.5 Store-and-forward: encode-then-buffer

Reuse the `internal/outbox` SQLite buffer (ADR-0011 Phase 3) at the agent. The load-bearing ordering decision: **ENCODE first, then buffer.** Buffering post-encode preserves sequence integrity across an outage — the buffered NDATA carry their assigned seq and aliases, so a drained backlog is a valid SparkPlug stream, not a pile of re-encodable JSON that would re-number on replay.

The one subtlety this creates: **REBIRTH-before-drain after a long outage.** Buffered NDATA reference an alias table the *reconnected* receiver may no longer hold (the cloud saw an NDEATH, or restarted, and dropped the table). So on reconnect after a non-trivial gap the agent MUST re-publish NBIRTH/DBIRTH (re-establish the table) **before** draining the outbox. This mirrors the consumer-side rule `aliastable.go` already enforces (`ErrNoBirth` on DATA-before-BIRTH; a second NBIRTH replaces the table wholesale).

### 2.6 Operator-migration seams — the CPACK-light / Incoplast-heavy answer

Two *kinds* of customization exist, and they route to **different planes**:

- **(a) Connectivity / telemetry** customization (tags, protocol, SparkPlug shape, ERP DB reads — Incoplast's ~107 nodes) **STAYS** in the Tier-1 connectivity plane, low-code and config-driven per tenant. This is exactly the work ADR-0019 gave homes to (G1 ERP sync, G4 command path).
- **(b) Operator / business** customization (Incoplast's 389-node `mui_*` operator UI) **MIGRATES onto OUR operator4 SPA.** Migration is *bring Incoplast onto the same SPA*, **not** port flows. CPACK proves the target already runs.

Four operator-migration seams carry (b) — each mirrors an existing, decided pattern:

1. **Per-tenant `OperatorConfig` + widget registry** — mirror [ADR-0029](0029-front4-dashboard-composition-and-metric-layer.md)'s composition engine: a **total / never-throws** schema. A shop-floor screen must **never** show a stack trace; an unknown widget renders an empty tile, not a crash.
2. **Config-driven form schema** for client-specific fields (Incoplast's scrap-DETAILS capture) — a declarative form spec per tenant, not a bespoke React form.
3. **Server-side anti-corruption adapters** for integrations — SyteLine ERP import and per-site shift validation via the **back4 `/integration/*` Family-A shims already built** ([ADR-0031](0031-back4-api-retirement-shims-datasets-and-hasura-sequence.md)); PO/downtime writes via the **operator-adapter → edge-api 8 routes**; scrap via the **data-tee, not an operator route**. The client's quirks are absorbed at the server boundary, never leaked into the SPA.
4. **Per-tenant `capabilities.operator.mode: edge` descriptor** — same artifact, deployed at the edge (ADR-0019 G3: the operator SPA is a static nginx container whose `/api/*` + `/v1/*` proxy targets point factory-local for offline-first floor use).

**Principle:** ONE operator stack. Per-tenant difference = `OperatorConfig` + form schema + server-side ACL. Never a fork. CPACK-light and Incoplast-heavy run the **identical** architecture; Incoplast's behavior is preserved, its fork-tax retired.

### 2.7 Reference positioning

The design is a recognizable, open, Go-native realization of the enterprise-IoT reference stack:

- The **agent** is an open **Cirrus Link MQTT-Transmission** — the store-and-forward SparkPlug transmitter (ADR-0011 already cites Cirrus Link Store & Forward as the norm we're joining).
- Its **tag provider** is a governed **Ignition-Edge-style** Node-RED — kept separate *on purpose*, so the low-code plane never touches the protocol.
- **`client.yaml`** plays **HighByte's** contextualization role — declarative modeling of tags → equipment, one source of truth ([ADR-0004](0004-edge-nodered-config-centralization.md)).

We are joining the standard, not inventing it — the same framing ADR-0011 used for store-and-forward.

---

## 3. Component-responsibility table

| Concern | Tier 1 — Node-RED (connectivity) | Tier 2 — Go agent (transmission) | Cloud — edge-transformer |
|---|---|---|---|
| PLC/OPC-UA/S7/Modbus I/O | ✅ owns | — | — |
| Per-client tag shaping / ERP reads | ✅ owns (low-code) | — | — |
| Raw-tag emit (suffix + quality) | ✅ emits JSON | — | — |
| `packml_topic` prefix | — (config only) | ✅ prepends from `client.yaml` | — |
| Alias assignment (name↔alias) | ✗ never | ✅ **allocator (net-new)** | — (resolves, doesn't assign) |
| NBIRTH / DBIRTH mint | ✗ never | ✅ owns | — |
| Rolling `seq` + rebirth-on-gap | ✗ never | ✅ owns | detects gaps (`OnSeqGap`) |
| NDEATH via MQTT LWT | ✗ never | ✅ **owns (genuinely new)** | consumes as death event |
| Report-by-exception (dirty-track) | ✗ never | ✅ **owns (net-new)** | — |
| Protobuf encode | ✗ never | ✅ `internal/sparkplug` | decode |
| Store-and-forward (outbox) | — | ✅ `internal/outbox`, encode-then-buffer | — |
| mTLS WAN publish | ✗ never | ✅ per-tenant cert | — |
| SparkPlug decode + alias-resolve | — | — | ✅ unchanged |
| Calc / OEE | — | — | ✅ unchanged (F3) |
| Operator UI | — (no in-flow UI) | — | operator4 SPA (per-tenant `OperatorConfig`) |

Invariant, CI-enforced: **the `spBv1.0/*` namespace is written by Tier 2 alone**; Tier 1 publishing it fails the flow-lint.

---

## 4. Two deployment modes

The identical `{agent image, connectivity flow, client.yaml}` triple runs in two modes. One image pair, two compose overlays — the ADR-0007/0009 "single image, boot-mode selection" discipline.

### 4.1 Mode A — STAGING VALIDATION

```
CPACK real Node-RED ──tee (existing HTTPS front-door)──▶ raw tags
        │
        ▼
nodered-cpack  ──edge/raw/cpack/*──▶  sparkplug-agent-cpack ──spBv1.0──▶ INTERNAL mosquitto
                                                                             │
                                                                             ▼
                                                          edge-transformer → FULL prod Calc → F3
```

- New `nodered-<tenant>` + `sparkplug-agent-<tenant>` services in `compose.staging.yml`, fed by a **tee of CPACK's real Node-RED** (raw tags over the existing HTTPS front-door), publishing to the **internal mosquitto** already on staging → the **full prod Calc** via `edge-transformer`.
- **No public MQTT ingress needed.** **CPACK prod is untouched.**
- This directly **resolves the standing "CPACK real-data bypasses the Calc" gap**: today CPACK staging telemetry is `plc-sim` synthetic (ADR-0032 §2.1); Mode A pipes *real* CPACK tags through the *real* Calc without touching the client.

### 4.2 Mode B — CLIENT EDGE

- The **same image pair** via a new `compose.edge.yml`, running at the client factory.
- A **durable store-and-forward boundary** to the cloud — either a mosquitto bridge **or** the agent's own `internal/outbox`, publishing over **mTLS** (ADR-0011's durability line, now realized client-side).
- This is the productized deliverable a real client runs. Mode A validates it on staging before any client sees it.

---

## 5. Client CI/CD pipeline — the goal of this ADR

A client update is a **gated PR against versioned artifacts**, *never* a live Node-RED flow-edit on a running factory. This is the operational heart of the ADR.

### 5.1 Versioned artifacts

Per tenant, a `clients/<tenant>/` directory holds:

- the **agent image** pin (semver, signed),
- the **connectivity flow JSON** (the Tier-1 Node-RED export),
- the **`client.yaml`** (topic prefix, tag map, endpoints, `OperatorConfig`),
- a signed **`release.yaml`** pinning the `{agent, flows, config}` **triple** as one atomic, reproducible release.

**A new tenant is a new `clients/<tenant>/` directory — never a code fork** (north-star #2).

### 5.2 The pipeline

```
Build ─▶ Test ─▶ PARITY-GATE ─▶ Release ─▶ Pull-to-edge
```

| Stage | What runs | Gate |
|---|---|---|
| **Build** | agent image + package the triple | reproducible build |
| **Test** | `go test` (agent) + the SparkPlug **`parity_test`** + `client.yaml` **schema-lint** + **customization-flow-lint** (no `spBv1.0/*` in Tier 1, no inline secrets, ADR-0009 governance rules) | all green |
| **PARITY-GATE** | **replay the tenant's real PLC data through the staging harness** (Mode A), diff **F3 vs prod** via the `internal/bake` comparator — the same instrument that gated the #276 Calc cutover | byte/tolerance parity per ADR-0022 |
| **Release** | semver tag + sign the `release.yaml` triple | signed |
| **Pull-to-edge** | GitOps reconcile loop at the factory pulls the pinned release, **health-gated**, **auto-rollback** on failed healthcheck | `/healthz` green post-deploy |

The **parity-gate is the load-bearing stage** — it reuses `services/oeecloud-worker/internal/bake` (the comparator that proved the two-writer line double-count and gated #276) as a *release* gate, not just a run-time watchdog. A client's flows/config/agent version cannot ship unless *that client's own real data* still computes the same OEE through F3.

### 5.3 The rule

> A client update is a **gated PR**, never a live flow-edit. A new tenant is a **new `clients/<tenant>/` dir**, never a code fork.

This is what turns "the most contentious service in the platform" (ADR-0009 §Context — nobody trusts editing Node-RED) into a reviewed, tested, reversible, per-tenant artifact stream.

---

## 6. Security model

| Control | Mechanism | Why |
|---|---|---|
| **Per-tenant mTLS** | client cert with `CN=<tenant>` on the WAN publish | the transport asserts identity; no shared broker password |
| **Tenant isolation** | **CN-keyed topic ACL** — the broker authorizes `spBv1.0/<tenant>/#` from the cert's CN only | the client **never names its own tenant**; the cert asserts it. This is north-star principle #5 (tenant isolation everywhere) applied to the edge publish plane — the *write*-side analogue of refdata's server-derived `id_enterprise`. One misconfiguration must not let one factory publish as another. |
| **Network scoping** | factory-egress-IP security-group scoping | only known factory egress IPs reach the ingress |
| **Secrets by reference** | `*_ref` fields in `client.yaml` → AWS Secrets Manager; **flow-lint rejects inline secrets** | ADR-0004 Layer-2 + ADR-0019 G1's cautionary tale (Incoplast's cleartext ERP creds). Never a secret in git. |

The isolation invariant is the sharp edge: **the client never spells its tenant on the wire; the mTLS CN does, and the broker ACL enforces it.** A tenant that could name itself could impersonate another — the exact failure north-star #5 exists to make unrepresentable.

---

## 7. Validation loop — "is our stack computing real data right?"

A continuous, layered validation harness that runs **both** as a live watchdog and as the release parity-gate (§5.2):

- **DQ board** — a data-quality dashboard surfacing per-tenant ingest health.
- **Prometheus rules** — `SparkplugSeqGapStream` (seq-gap), `IngestSilent` (silent ingest), `EngineStalled` (engine stalled) — the `monitoring/prometheus/rules.yml` family, now fed from the agent tier too.
- **Bake comparator** — `internal/bake`, F3 vs prod, per §5.2.
- **Tempo trace extended UP into the agent** — one trace spanning `agent-assemble → cloud decode → Calc → F3`, **per-reading**, so a wrong number is traceable from the tag that produced it to the OEE cell it lands in.

This is the ADR-0011 "observable, not zero" doctrine and the north-star P15 observability pillar carried to the agent tier: every OT-side loss is *seen* (seq-gap + NDEATH), every reading is *traceable*, every release is *parity-gated* against the client's own real data.

---

## 8. Consequences

### Positive

- **The client edge becomes a productized, versioned, testable artifact** — the SparkPlug session leaves the low-code plane (finishing the ADR-0009/0010 trajectory client-side); Node-RED shrinks to a pure, governed tag provider.
- **One ingest contract for every tenant** — native-PLC, s7-reader, plc-sim, and the agent are indistinguishable to the cloud (ADR-0032 thesis, client-side). Onboarding a new protocol never touches the cloud hot path.
- **The CPACK-real-data-bypasses-Calc gap closes** (Mode A) without touching CPACK prod.
- **Client updates become gated PRs with a real-data parity gate** — the #276-grade comparator now guards *every client release*, not just the big cutover.
- **Tenant isolation on the edge write plane by construction** (mTLS CN + ACL) — the write-side analogue of the strong read-plane isolation, advancing north-star #5.
- **Incoplast's fork-tax retires** — 389 `mui_*` nodes + two drifting UI versions collapse onto the shared operator4 SPA via config, not a port.
- **Maximum reuse** — agent = s7-reader with a swapped input; `internal/{sparkplug,outbox,mqtt,clientconfig}` all reused (ADR-0009 Rule 11: pattern reuse over invention).

### Negative / trade-offs

- **Two edge containers instead of one** (Node-RED + agent) at every factory — more operational surface, mitigated by the shared compose stack + shared observability (ADR-0009 accepted the same cost for edge-transformer).
- **A new internal MQTT hop** — one more link that can fail; mitigated because it is loopback (no WAN, no TLS, no cross-tenant) and health-gated.
- **The alias-ASSIGN allocator + RBE + session state machine are net-new code** — the highest-risk new surface; mitigated by the `parity_test` reuse and the Mode-A staging validation before any client runs Mode B.
- **NDEATH-via-LWT is a genuinely new SparkPlug concern** — no prior producer registers a Last-Will; needs careful test coverage (an ungraceful kill must produce a cloud-visible death).
- **client.yaml becomes even more load-bearing** — now the SSoT for tag map *and* topic prefix *and* OperatorConfig; ADR-0009's mitigation (schema-lint, CI, versioning) is inherited and extended.

### Neutral

- **Matches the enterprise-IoT reference architecture** (Cirrus Link MQTT-Transmission + Ignition-Edge tag provider + HighByte contextualization). We join the standard.

---

## 9. Phased roadmap

| Phase | Deliverable | Reuses | Gate |
|---|---|---|---|
| **P0 — Agent MVP** | `cmd/sparkplug-agent`: raw-tag JSON ingest → alias-ASSIGN allocator → NBIRTH/DBIRTH → seq + rebirth → NDEATH-LWT → encode → publish. Net-new code only; everything else reused. | `internal/{sparkplug,outbox,mqtt,clientconfig}`; s7-reader as the template | `parity_test` green; a raw-tag stream produces valid SparkPlug the cloud decodes identically |
| **P1 — Staging CPACK validation (Mode A)** | `nodered-cpack` + `sparkplug-agent-cpack` in `compose.staging.yml`, fed by the CPACK real-Node-RED tee → internal mosquitto → full Calc → F3. | Mode A; internal mosquitto; edge-transformer (unchanged) | F3-from-agent == F3-from-plc-sim/prod via `internal/bake`; closes the real-data-bypasses-Calc gap |
| **P2 — Client CI/CD + edge deployment (Mode B)** | `compose.edge.yml`; the `clients/<tenant>/` artifact triple + signed `release.yaml`; the Build→Test→Parity-Gate→Release→Pull-to-edge pipeline; mTLS + CN-ACL + egress-SG. | §5 pipeline; §6 security; ADR-0011 durability boundary | a client release ships only through the gated PR + parity-gate; auto-rollback proven |
| **P3 — Incoplast operator migration onto the SPA** | Incoplast's 389 `mui_*` nodes retired; operator4 SPA + per-tenant `OperatorConfig` + form schema; server-side ACL adapters (SyteLine, shift-validation via back4 `/integration/*` shims; PO/downtime via operator-adapter→edge-api; scrap via data-tee). | ADR-0029 composition engine; ADR-0031 shims; ADR-0018/0019 operator homes | behavior parity vs the `mui_*` fork; zero bespoke UI remaining |

Ordering rationale: **prove the agent in isolation (P0) → prove it on real client data without risk (P1) → productize the delivery (P2) → migrate the hardest tenant's business layer last (P3).** Each phase is independently valuable and independently reversible; P1 alone closes a known gap even if P2/P3 slip.

---

## 10. Open questions

1. **NDEATH-via-LWT payload + bdSeq discipline.** The Last-Will must carry a valid NDEATH with the *current* `bdSeq` so the cloud correlates death→birth. How is `bdSeq` persisted across an agent restart (so a crash-restart increments correctly rather than replaying)? Recommend: persist `bdSeq` in the outbox SQLite alongside the buffer; the LWT is (re)registered on every connect with the persisted value. Confirm before P0 ships.

2. **Encode-then-buffer vs buffer-then-encode.** §2.5 decides encode-then-buffer for seq integrity, but that pins alias assignments into buffered messages — if a long outage spans a tag-map change (a client redeploy), buffered NDATA reference a stale table. Recommend: on any `client.yaml` tag-map change, drain-or-discard the outbox and force a fresh NBIRTH; never let a redeploy silently re-map buffered aliases. Confirm the drain-vs-discard policy.

3. **Per-tenant agent vs multi-tenant agent.** Mode A runs one agent per tenant (`sparkplug-agent-<tenant>`). At scale on a shared edge box, is it one agent process per tenant (clean isolation, more processes) or one agent multiplexing tenants (fewer processes, shared blast radius)? Recommend one-per-tenant for isolation (matches the mTLS-CN-per-tenant model and the ADR-0010 "subscriber-per-tenant is embarrassingly parallel" finding); revisit only if process count becomes an operational cost.

4. **DBIRTH granularity.** SparkPlug models an EdgeNode (NBIRTH) with optional Devices (DBIRTH). Does each PLC/line map to a Device under one EdgeNode, or does each get its own EdgeNode? This governs alias-table scoping and rebirth blast radius (a rebirth re-publishes a whole node's table). Recommend: one EdgeNode per agent, one Device per PLC/line (DBIRTH per line), so a single line's rebirth doesn't re-birth the whole factory. Confirm against the `packml_register` topology model.

---

## 11. Cross-reference table

| ADR | Relationship to this ADR |
|---|---|
| [ADR-0038](0038-north-star-factory-platform.md) | **Governs.** This ADR is the *how* for P1 Connectivity/Edge + principle #7 (edge/cloud durable split), #2 (config-driven not fork), #5 (tenant isolation — extended to the edge write plane). |
| [ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md) | **Extends.** The logic-type seam (standardized→Go, per-client→Node-RED) pushed one tier further: the SparkPlug *session* leaves Node-RED too. Inherits Rule 11 (reuse over invention) + governance lint. |
| [ADR-0010](0010-sparkplug-decode-in-go-end-state.md) | **Mirrors, producer-side.** 0010 put *decode* in Go at the cloud; this puts *encode + session* in Go at the edge. Reuses `internal/sparkplug` + the alias-table state-machine design. |
| [ADR-0011](0011-durability-boundary-and-store-and-forward.md) | **Realizes client-side.** The durability boundary + `internal/outbox` store-and-forward, now at the agent, over mTLS; encode-then-buffer + rebirth-before-drain honor its rules. |
| [ADR-0019](0019-edge-customization-capabilities.md) | **Homes the connectivity customization.** G1 ERP sync + G3 edge-operator SPA + G4 command channel are the Tier-1 / operator-migration mechanisms this ADR routes to. |
| [ADR-0018](0018-operator-frontend-integration-makeover.md) | **Frames the operator migration.** Retire the Node-RED BFF; one read/write split — the target Incoplast's `mui_*` fork migrates onto. |
| [ADR-0029](0029-front4-dashboard-composition-and-metric-layer.md) | **The pattern the operator migration mirrors.** Per-tenant `OperatorConfig` + widget registry = the composition engine's total/never-throws schema, applied to the operator SPA. |
| [ADR-0032](0032-collapse-to-single-flow-f3.md) | **The one-flow thesis, client-side.** Every PLC (real / s7-reader / plc-sim / agent) looks identical to one source-agnostic `edge-transformer` → F3. |
| [ADR-0038 #5 / ADR-0031](0031-back4-api-retirement-shims-datasets-and-hasura-sequence.md) | **Server-side anti-corruption seam.** Incoplast integrations land via the back4 `/integration/*` Family-A shims already built. |
| [ADR-0004](0004-edge-nodered-config-centralization.md) | **The SSoT.** `client.yaml` supplies the topic prefix, tag map, endpoints, secrets-by-reference, and `OperatorConfig` — HighByte's contextualization role. |
| [ADR-0022](0022-pre-flip-behavior-correctness-validation.md) | **The parity bar.** The CI parity-gate replays a client's real data and holds it to the behavior-correctness standard. |

---

## Decision log

| Date | Decision | Decider |
|---|---|---|
| 2026-07-23 | Four design-squad lenses (edge/SparkPlug · Go · DevOps-client-CI/CD · customization/operator) converged; ADR drafted. Status: Proposed. | chief architect + Claude |
| TBD | USER review + sign-off | |
| TBD | P0 agent MVP PR | |
| TBD | P1 Mode-A staging CPACK validation | |
