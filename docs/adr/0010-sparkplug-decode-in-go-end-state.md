# ADR 0010 — Sparkplug B decode in Go (end-state for protocol processing)

**Status:** Proposed (DRAFT — awaiting team review)
**Date:** 2026-06-30
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team
**Supersedes:** none
**Extends:** [ADR-0009](./0009-edge-transformer-go-service-and-nodered-split.md) — this ADR completes the trajectory ADR-0009 began but stops short of.
**Companion spike:** `services/edge-transformer/internal/sparkplug/` shipped in the same PR as this ADR — proves the decode path is feasible.

---

## Context

### What ADR-0009 leaves unfinished

ADR-0009 introduces the **edge-transformer** Go service and moves transforms + HTTP endpoints out of Node-RED. But Phase 2 of that ADR explicitly **keeps the Sparkplug B protocol decode inside Node-RED**:

> Phase 2 — RabbitMQ bridge + Go skeleton (~5 days)
> [...]
> New Node-RED `amqp-pub-plc-normalized` flow at the protocol-node output edge: takes the raw OPC-UA / SparkPlug message, wraps it in the normalized envelope (defined Phase 2), publishes to the exchange

The reasoning was pragmatic — port one thing at a time, prove the boundary, keep the existing Sparkplug subflow as a stable upstream. But this leaves the **heaviest non-customization work** still inside the low-code layer:

- The `SparkPlug_v1.10.39.1` subflow is ~571 LOC of decode + protobuf glue + state-machine
- It uses a community Node-RED node (`node-red-contrib-sparkplug-payload`) maintained by a single contributor
- The decode happens in JavaScript on Node.js's event loop — single-threaded, GC-pressured, slow for binary parse
- It cannot be unit-tested in isolation
- Replacing it requires the same risky "visual diff a JSON blob" review as any other Node-RED change

This is **exactly the class of work ADR-0009's principle says should live in code, not low-code**. The principle (from ADR-0009 Phase 5):

> Node-RED's role shrinks to **protocol + customization**.

But "protocol" itself is two things:
1. **The MQTT transport** (TCP, TLS, client ID, subscribe pattern) — well-served by an MQTT library in any language
2. **The Sparkplug B payload decode** (proto2 protobuf unmarshal, datatype-tagged values, timestamp/seq tracking) — well-served by a protobuf library in any language

Neither is **customization**. Both are heavy lifting. Both should be in Go.

### What we want (the end state)

```
Factory floor
   │
   │ Sparkplug B over MQTT
   │ (PLCs publish via factory MQTT broker)
   ▼
edge-transformer (Go service running on the factory edge)
   │
   ├─► MQTT subscriber (paho.mqtt.golang)
   │   Connects to factory broker, subscribes to spBv1.0/+/+/+/+ (or equivalent),
   │   handles QoS / Last Will / persistent session.
   │
   ├─► sparkplug.Decode(body) (this ADR's domain)
   │   Parses raw MQTT body via Eclipse Tahu's canonical sparkplug_b.proto.
   │   Returns *sparkplug.Payload — typed Go struct with Metrics[].
   │
   ├─► Normalizer
   │   Maps Sparkplug metric → normalized envelope v1.0 (per ADR-0009).
   │   Equipment-ID resolution via packml_register or client.yaml.
   │
   ├─► Transform pipeline (ADR-0009 Phase 3)
   │   Calc_Counters, time/shift math, datatype enforcement, etc.
   │
   └─► RabbitMQ publisher
       Publishes normalized envelope to edge.plc-normalized.<tenant>
       (same exchange topology shipped by ADR-0009 Phase 2 / Phase 2.5b)
   ▲
   │ Node-RED CONSUMES from RabbitMQ (selectively) for per-customer customization
   │ tabs that need access to live data.

Node-RED's role at end state:
   - PLC-specific data shaping (when the off-the-shelf decoder can't handle it)
   - Per-tenant customizations (rules, alerts, dashboards)
   - Absolutely necessary nodes (operator HTTP endpoints that won't migrate)
   NOT the Sparkplug subflow. NOT the AMQP publisher. NOT any decode.

Simulator:
   - Used ONLY for synthetic test data
   - Generates fake Sparkplug-shaped payloads for staging + local-dev
   - NEVER a production data path
```

### Why now (after ADR-0009, not as part of it)

The right time for this conversation is **after Phase 2.5b validates the RMQ boundary** (2026-06-30 — done) and **after the team is comfortable with the edge-transformer Go service** (~6 weeks of Phase 3 transforms in production).

Doing this **inside ADR-0009** would have made that ADR enormous and untestable. The senior move is to ship the boundary (Phase 2.5b), prove transforms can be ported (Phase 3), and only then take on the protocol-decode migration when both halves are familiar.

That said, capturing this end-state **now** matters because:
1. It explains why ADR-0009 Phase 2's "Node-RED publishes to RMQ" is *intentionally transitional*, not the destination
2. It gives the team a target to design Phase 3-4 work against (avoid patterns that would make protocol-decode-in-Go harder later)
3. It surfaces the open architectural questions early (per-tenant MQTT credentials, TLS at the edge, MQTT bridge vs. direct subscribe)

---

## Decision

**Move Sparkplug B payload decoding from Node-RED into edge-transformer (Go).**

Specifically:

1. **Vendor Eclipse Tahu's canonical `sparkplug_b.proto`** (proto2 spec, Eclipse Public License 2.0) under `services/edge-transformer/internal/sparkplug/internal/`.
2. **Generate Go bindings** via `protoc-gen-go` (committed to the repo, regenerated via `go generate`).
3. **Expose a thin `sparkplug` package** at `services/edge-transformer/internal/sparkplug/` with a single public function: `Decode(body []byte) (*Payload, error)`.
4. **Add a MQTT subscriber package** at `services/edge-transformer/internal/mqtt/` (paho.mqtt.golang) that connects to the factory broker, subscribes to the Sparkplug topic pattern, and feeds raw bodies into the decoder.
5. **The Node-RED Sparkplug subflow is removed** in the cutover PR (per-customer tabs that consume Sparkplug data are migrated to consume from RabbitMQ instead).
6. **Simulator stays in Node-RED** but generates fake Sparkplug-shaped payloads only; never a production data source.

### The spike

A companion spike lands in the same PR as this ADR:

- `services/edge-transformer/internal/sparkplug/decoder.go` — the thin wrapper
- `services/edge-transformer/internal/sparkplug/decoder_test.go` — 3 tests:
  - `TestDecodeRoundTrip` — encode a known payload, decode, assert structural equality + `proto.Equal`
  - `TestDecodeMalformed` — empty / garbage / truncated inputs all handled gracefully
  - `TestDataTypeEnumStable` — confirms enum integers match Sparkplug B wire format

The spike proves the decode is **lossless and standards-compliant**. What it does NOT prove yet:
- Performance vs Node-RED (deferred to ADR-0010 Phase 1)
- Bit-exact parity with Node-RED's decoded output (deferred to ADR-0010 Phase 1; requires capturing real factory MQTT payloads)
- MQTT subscriber reliability (deferred to ADR-0010 Phase 2)

### Why this seam, not others

Alternatives considered:

- **Leave decode in Node-RED forever.** Rejected — perpetuates the "low-code does heavy lifting" anti-pattern ADR-0009 is trying to retire.
- **Decode in Node-RED, but in a Go-shaped subflow with rigorous tests.** Rejected — Node-RED function nodes can't import Go. Would mean inventing a worse abstraction.
- **Stand up a separate Go MQTT-to-RMQ bridge service.** Rejected — that IS edge-transformer. Splitting them creates two services to deploy + monitor on every factory edge.
- **Use an MQTT broker plugin (e.g., HiveMQ Sparkplug extension).** Rejected — outsources the decode to broker infrastructure we don't control + locks us to a specific broker.

The right seam is **between MQTT body bytes and decoded Sparkplug struct** — exactly the boundary the spike validates.

---

## Consequences

### Positive

- **Performance**: Go protobuf decode is 10-100× faster than JavaScript-level decode through Node-RED's event loop (to be benchmarked in ADR-0010 Phase 1).
- **Testability**: The decode function is a single Go function. Unit-tested in isolation. CI runs it on every PR.
- **Type safety**: Sparkplug Metric struct surfaces the canonical fields (`Name`, `Timestamp`, `Datatype`, oneof `Value`) with Go types. No JS object inspection.
- **Replaceability**: The decode is now decoupled from MQTT transport. If we ever need to ingest Sparkplug from a queue/file/HTTP source, the same decoder applies.
- **Removes a community-Node-RED-node dependency** that's maintained by a single contributor.
- **Restores the "code = heavy lifting, low-code = customization" principle** ADR-0009 established but couldn't complete.

### Negative / Trade-offs

- **More Go code to maintain.** ~500 LOC of decode wrapper + ~800 LOC of MQTT subscriber + comparator-validation harness. Acceptable per ADR-0009's premise (we're already growing Go for transforms).
- **MQTT credentials per factory** — each edge needs broker creds. AWS Secrets Manager per factory, same pattern as ADR-0005's deploy story.
- **TLS-at-the-edge** — factory MQTT brokers often use self-signed certs. paho.mqtt.golang supports custom TLS config; we expose this via `client.yaml`.
- **Cutover risk** — moving the protocol path is more disruptive than moving a transform. Mitigated by 60-day comparator-validation window (decode in BOTH Node-RED and Go, diff outputs, only cut over after zero diffs).

### Neutral

- **Eclipse Tahu license (EPL 2.0)** is compatible with our use case. The `.proto` is vendored, generated bindings inherit EPL-2.0 (the Eclipse Tahu project's choice). Confirmed with `LICENCE` file in `eclipse-tahu/tahu`.

---

## Phased rollout (post-ADR-0009)

**Phase 0 — Spike + ADR (THIS PR, 2026-06-30)**
- Spike: `internal/sparkplug/` package + 3 unit tests
- This ADR

**Phase 1 — Decoder parity validation (~1 week)**
- Capture real Sparkplug payloads from a staging or prod MQTT broker (10+ messages spanning NBIRTH/DBIRTH/NDATA/DDATA)
- Decode each with both Node-RED (existing subflow) and Go (new spike)
- Diff outputs at the JSON level; iterate until zero diff
- Benchmark: Go decode rate vs Node-RED decode rate (msg/s for a single decoder instance)

**Phase 2 — MQTT subscriber (~1 week)**
- New `internal/mqtt/` package wrapping paho.mqtt.golang
- Per-tenant client config from `client.yaml` (broker URL, creds via AWS Secrets, TLS settings)
- Subscriber feeds raw MQTT body to `sparkplug.Decode`
- Shadow mode: parallel-run with Node-RED's existing MQTT-in nodes; compare decoded outputs at the RMQ boundary

**Phase 3 — Normalizer integration (~1 week)**
- Wire `sparkplug.Decode` output into the existing edge-transformer normalizer (the one ADR-0009 Phase 3 ports transforms into)
- End-to-end shadow: Go path produces `edge.plc-normalized.<tenant>` messages identical to the Node-RED path's output
- Run for 30+ days side-by-side with comparator validation (ADR-0008 pattern)

**Phase 4 — Cutover (~3 days)**
- Disable Node-RED's MQTT-in + Sparkplug subflow
- edge-transformer becomes sole publisher to `edge.plc-normalized`
- Per-customer customization tabs that previously read from the Sparkplug subflow are migrated to consume from RabbitMQ (using existing `node-red-contrib-amqp` consumer pattern)

**Phase 5 — Retire Node-RED Sparkplug tab (~1 day)**
- Delete `flows/Sparkplug.json` + `subflows/SparkPlug_v1.10.39.1.json`
- Remove `node-red-contrib-sparkplug-payload` dep
- Phase 2.5b's adapter + link-out + publisher tab also retire (they were always transitional — the Go path replaces them entirely)
- Update governance lint to FORBID Sparkplug-decode-shaped function nodes in Node-RED

**Total: ~6 weeks of focused work**, plus a ≥30-day comparator-validation window in Phase 3.

---

## Open questions for review

1. **MQTT broker topology per factory** — Today's edge-nodered subscribes to ONE broker per factory. Phase 2's Go subscriber should match. But: what if a factory has multiple PLC vendors with separate brokers? Do we run multiple subscribers, or rely on broker-side bridging? Likely answer: one Go subscriber per broker, declared in `client.yaml` under `mqtt.brokers[]`.

2. **TLS at the edge** — Many factory brokers use self-signed certs or no TLS at all. Do we mandate TLS (and provide a "pin certificate" config) or allow opt-out (with a loud warning)? Likely answer: mandate TLS unless `client.yaml` explicitly opts out + we log a security warning at startup.

3. **Sparkplug birth/death message handling** — NBIRTH/DBIRTH establish a metric alias table; subsequent NDATA/DDATA reference metrics by alias only. The Go decoder must maintain this table per-publisher (per edge node). Where does the state live — in-memory per subscriber instance, or persisted? Likely answer: in-memory + rebuild on restart (Sparkplug spec says the BIRTH messages are repeated periodically); make this a config option.

4. **Backward-compat for existing Node-RED-consumer customer tabs** — Customers who built their tabs around the Sparkplug subflow's output shape (named function nodes accessing `msg.payload.metrics`) will break when the subflow is removed. Phase 4 must include a migration path for these tabs. Likely answer: an AMQP-in consumer tab that mimics the Sparkplug subflow's output for customer tabs that depend on it. Effectively: the customer tabs see the SAME shape, just via AMQP instead of MQTT.

5. **Simulator's role under the new architecture** — The simulator publishes via Node-RED's `/plc-data` HTTP endpoint today (Phase 2.5b verified this). Under ADR-0010 the production path is `MQTT → edge-transformer`. Should the simulator emit MQTT (so it tests the full path), or stay as the HTTP shortcut (faster but tests a different code path)? Likely answer: BOTH — keep the HTTP shortcut for fast local-dev, add an MQTT mode for end-to-end soak tests.

6. **Versioning the proto** — Eclipse Tahu may release a Sparkplug 3.0 with breaking proto changes. The vendored `.proto` should be tagged with the upstream version (e.g., `sparkplug_b@v1.0-20230815.proto`) so we know what we're decoding. Likely answer: header comment + `go generate` invocation pin the version explicitly.

7. **Does this ADR supersede the "Node-RED publisher to edge.plc-normalized" path shipped in Phase 2.5b?** Yes — Phase 5 of this rollout retires that publisher tab. Capture this in the cutover PR's description so anyone tracing history understands why Phase 2.5b is gone.

---

## References

- [ADR-0009](./0009-edge-transformer-go-service-and-nodered-split.md) — the parent ADR this completes
- [ADR-0008](./0008-phase-2-comparator-split.md) — the comparator-validation discipline Phase 3 reuses
- [Eclipse Tahu Sparkplug B spec](https://github.com/eclipse-tahu/tahu/blob/master/sparkplug_b/sparkplug_b.proto) — canonical proto2 schema
- [paho.mqtt.golang](https://github.com/eclipse/paho.mqtt.golang) — Go MQTT client we will use in Phase 2
- [Phase 2.5b PR #17](https://github.com/packiot/edge-node-red/pull/17) — the transitional Node-RED publisher this ADR plans to retire
- The decoder spike at `services/edge-transformer/internal/sparkplug/` — proves feasibility

---

## Decision log

- **2026-06-30** — Initial draft + spike. Status: Proposed (DRAFT).
- Awaiting team review. After review, Status → Accepted and Phase 1 work begins.
