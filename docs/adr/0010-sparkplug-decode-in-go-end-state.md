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
- ~~Performance vs Node-RED (deferred to ADR-0010 Phase 1)~~ **PARTIAL: Go side benchmarked — see "Phase 1 progress" section below. Node-RED side requires live capture.**
- Bit-exact parity with Node-RED's decoded output (deferred to ADR-0010 Phase 1; requires capturing real factory MQTT payloads)
- MQTT subscriber reliability (deferred to ADR-0010 Phase 2)

### Phase 1 progress — decode benchmarks (2026-06-30)

Realistic NBIRTH/NDATA fixtures (using actual CPACK packml_register topic names — same as Phase 2.5b consumes) + benchmarks shipped in same PR:

- `internal/sparkplug/fixtures_test.go` — `newNBIRTH(N)`, `newNDATA(N, seq)` builders + `TestFixtureShapes` which asserts NDATA is ≥2× smaller than NBIRTH (measured: 4.36×)
- `internal/sparkplug/benchmark_test.go` — Decode/Encode benchmarks at 1/10/100/1000 metric batch sizes

Run:

```bash
cd services/edge-transformer
go test -bench=. -benchmem -benchtime=2s ./internal/sparkplug/
```

**Results (Intel i5-1135G7 @ 2.4 GHz, single-core):**

| Benchmark | Time / op | Throughput | Allocations |
|---|---|---|---|
| Decode NBIRTH(1)    | 1.74 μs | 48.3 MB/s | 392 B, 11 allocs |
| Decode NBIRTH(10)   | 12.5 μs | 57.9 MB/s | 2.8 KB, 78 allocs |
| Decode NBIRTH(100)  | 116 μs  | 60.3 MB/s | 25.8 KB, 711 allocs |
| Decode NBIRTH(1000) | 1.19 ms | 59.5 MB/s | 252 KB, 7014 allocs |
| Decode NDATA(1)     | 1.61 μs | 15.6 MB/s | 312 B, 9 allocs |
| Decode NDATA(10)    | 11.0 μs | 15.4 MB/s | 2.0 KB, 58 allocs |
| Decode NDATA(100)   | 95.6 μs | 16.8 MB/s | 18.3 KB, 511 allocs |
| Decode NDATA(1000)  | 985 μs  | 17.1 MB/s | 178 KB, 5014 allocs |
| Encode NBIRTH(100)  | 74.8 μs | 93.7 MB/s | 8.2 KB, **1 alloc** |
| Encode NDATA(100)   | 64.6 μs | 24.9 MB/s | 1.8 KB, **1 alloc** |

**Production-load translation**:

- NDATA(100) decode = **~10,500 batches/sec/core** = **~1.04M metrics/sec/core**
- CPACK staging produces ~0.8 msg/s × ~100 metrics ≈ 80 metrics/sec
- **~13,000× headroom** on a single Go core for staging-scale load
- Even worst-case factory load (~300 metrics/sec, per Phase 2.5b's Q4 estimate) sits at ~3% of one core

**What this means for the ADR**: the "Go decoder is fast enough" argument is now grounded in measurement, not estimate. The decoder is never the bottleneck. The architectural concern at end-state production load is the MQTT subscriber connection management + alias-table state (Phase 2 work), not the decode hot path.

### Cross-implementation parity harness (2026-06-30, same PR)

Added `testdata/parity/` — a Node.js harness that decodes Go-produced Sparkplug bytes using **the exact library Node-RED wraps** (`sparkplug-payload` from `eclipse-tahu/tahu/javascript/core/`). Isolated behind a `//go:build parity` tag so the default `go test` doesn't require Node.js.

Setup:

```bash
cd testdata/parity && npm install
```

Run:

```bash
go test -tags parity -run TestParity -v ./internal/sparkplug/
```

**Result — 2026-06-30**: PARITY CONFIRMED. The Go decoder encodes bytes that Node.js `sparkplug-payload` decodes into the identical logical shape (3 metrics, correct timestamp/seq/aliases, first metric decoded as `type=Int64 value=12345`, last metric as `type=String value="RUNNING"`).

Notable JS-side quirks the harness normalizes:

- `sparkplug-payload` uses Long.js (via protobufjs) for uint64 fields — arrive as `{high, low, unsigned}` objects, not numbers. The harness's `toNum()` normalizer coerces them back to JS-safe numbers or strings.
- `sparkplug-payload` maps `DataType` enum ints back to string names (`"Int64"` instead of `4`). Direct-int comparison against Go's DataType_Int64 requires mapping through the enum name.

Neither is a compatibility issue — both sides read the same protobuf wire bytes; they surface them in language-idiomatic shapes.

### Multi-core parallel decode (2026-06-30, same PR)

`benchmark_test.go` gained two `b.RunParallel` variants:

| Benchmark | ns/op | Throughput |
|---|---|---|
| Decode NDATA(100) single-core | 106 μs | 15.13 MB/s |
| Decode NDATA(100) parallel-8  | 52.5 μs (effective per-goroutine) | **30.62 MB/s aggregate** |
| Decode NBIRTH(100) single-core| 138 μs | 50.82 MB/s |
| Decode NBIRTH(100) parallel-8 | 77.4 μs | **90.65 MB/s aggregate** |

**Interpretation**: 8-core aggregate throughput is 2-2× single-core, NOT 8×. Bottlenecks are GC pressure (5-7 allocs per metric adds up under sustained load) + memory bandwidth on the i5-1135G7 mobile chip. This is fine for Phase 2 sizing — even the constrained 2× headroom on a mobile-class CPU is plenty for factory-scale load.

The architectural takeaway for Phase 2: **subscriber-per-tenant is embarrassingly parallel** (each Sparkplug publisher owns its alias table; no shared state). So we can shard decoders across cores without contention if we ever need to. But we probably won't need to.

### Still pending in Phase 1

- Node-RED side benchmark (`node --prof` on staging — captures the JS decode CPU cost for direct comparison)
- Parity validation against **real captured factory payloads** (the Go-encoded-then-JS-decoded direction is proven; the JS-encoded-then-Go-decoded direction is the same wire spec; real factory bytes still need capture)
- GC-pressure characterization under sustained load (24h soak with pprof memory profiling)

---

## Phase 2 progress — MQTT subscriber scaffold (2026-06-30, same PR)

Shipped `internal/mqtt/` scaffold following the internal/amqp/consumer.go shape per ADR-0009 reuse rule:

- `subscriber.go` — `Subscriber` type with paho.mqtt.golang client lifecycle, reconnect-with-backoff (delegated to paho's AutoReconnect + our OnConnectionLost handler), atomic counters, `/health`-JSON `SnapshotJSON` method, Prometheus hooks via `SetMetrics`
- `Topic` struct + `ParseTopic()` — canonicalizes the Sparkplug B topic pattern `spBv1.0/<GroupID>/<MessageType>/<EdgeNodeID>[/<DeviceID>]`
- `Config` + `DefaultConfig()` — Sparkplug-spec-friendly defaults (QoS 0, KeepAlive 30s, clean session enforced)
- `Handler` signature — receives parsed topic + raw body; called for every message; nil-safe

**Tests** (7 pass in default `go test`):
- `TestParseTopic` — 7 subtests (node-level NDATA, device-level DDATA, NBIRTH, wrong namespace, too few parts, too many parts, empty)
- `TestDefaultConfig` — spec-friendly defaults locked in
- `TestSubscriberSnapshotShape` — /health JSON keys documented
- `TestSubscriberHandlerNilSafe` — nil handler is no-op contract
- `TestSubscriberRunRejectsBadConfig` — Run precondition checks
- `Example_wiring` — runnable documentation showing MQTT body → sparkplug.Decode → dispatch by MessageType (NBIRTH/DBIRTH build alias table; NDATA/DDATA resolve aliases; NDEATH/DDEATH invalidate the table)

**Dependency**: `github.com/eclipse/paho.mqtt.golang@v1.5.1` (canonical Go MQTT client, Eclipse-hosted, active).

**Not yet in scope (Phase 2 remaining, next PR)**:

- Wire the subscriber into `main.go` under an errgroup goroutine alongside the AMQP consumer
- Per-tenant config from `client.yaml` (open Q1) — how many brokers per factory, TLS settings per broker
- AWS Secrets Manager credential fetching (mirrors the AMQP consumer's `secrets` package pattern)
- ~~Sparkplug alias-table state machine~~ **DONE — see below**
- Integration test with a local mosquitto container (behind `mqtt_integration` build tag)
- Shadow-mode plumbing that publishes the decoded normalized envelope to the same `edge.plc-normalized.<tenant>` exchange that Phase 2.5b's Node-RED publisher produces — enables ADR-0008-style comparator validation

### Phase 2 progress — alias-table state machine (2026-06-30, same PR)

Shipped `internal/sparkplug/aliastable.go` + `aliastable_test.go`. The load-bearing state machine that answers ADR-0010's open Q3: how does the decoder track per-publisher alias→name mappings across NBIRTH/NDATA/NDEATH.

**Design**:

- `PublisherKey{GroupID, EdgeNodeID, DeviceID}` — three-tuple identity for scope (DeviceID empty for node-level messages).
- `StateStore` — the concurrent-safe in-memory table. `sync.RWMutex` for reader/writer isolation.
- `Ingest(key, msgType, payload) (*ResolvedPayload, error)` — single-entry API. Returns `nil, nil` for BIRTH/DEATH/CMD; returns resolved metrics for DATA; returns typed errors on protocol violations.
- `ResolvedPayload{Metrics: []ResolvedMetric{Name, Alias, Timestamp, Datatype, Value}}` — the caller-friendly output view.
- `Snapshot()` — /health diagnostic surface (per-publisher alias count + last-seq + last-birth-at + last-message-at).
- `OnSeqGap(callback)` — Prometheus hook for sequence-number gap detection.

**Contract errors** (all returnable from Ingest):

- `ErrNoBirth` — DATA arrived before any BIRTH established the table
- `ErrUnknownAlias{PublisherKey, Alias}` — DATA references an alias not in the current table
- `ErrUnknownMessageType` — topic MessageType is outside Sparkplug B's 8 valid types

**Locked-in semantics**:

1. **Rebirth replaces prior table** — a second NBIRTH for the same key wipes the alias map (Sparkplug spec: BIRTH is a full snapshot).
2. **Death invalidates completely** — post-NDEATH DATA returns ErrNoBirth until a fresh BIRTH.
3. **Datatype fallback** — DATA metrics may omit datatype (fixed per alias at BIRTH); the state machine restores from the BIRTH-established value.
4. **Publishers are isolated** — two edge nodes may legally use alias=1 for different names. The (Group,Node,Device) key guarantees no cross-contamination.
5. **Sequence-number wraparound is not a gap** — Sparkplug wraps seq at 256. `(255→0)` is NOT a gap; `(1→5)` IS.

**Tests** (all pass with `-race`):

| Test | Behavior verified |
|---|---|
| `TestBirthEstablishesAliases` | NBIRTH populates map, returns nil ResolvedPayload |
| `TestDataResolvesAliases` | NDATA aliases → names + values (Int64, Float, String) |
| `TestDataBeforeBirthFails` | ErrNoBirth returned |
| `TestDataUnknownAliasFails` | ErrUnknownAlias carries the offending alias + key |
| `TestUnknownMessageTypeFails` | Unknown MessageType returns ErrUnknownMessageType |
| `TestDeathInvalidates` | Post-NDEATH DATA returns ErrNoBirth |
| `TestBirthRefreshesTable` | Second NBIRTH replaces prior aliases wholesale |
| `TestSequenceGapFiresCallback` | Gap triggers OnSeqGap with expected + got |
| `TestSequenceWraparoundIsNotAGap` | 255→0 does NOT fire callback |
| `TestDatatypeFallbackFromBirth` | DATA without datatype uses BIRTH's |
| `TestPublishersAreIsolated` | Two publishers can reuse alias 1 without cross-talk |
| `TestConcurrentPublishers` | 20 goroutines × 100 messages, race detector clean |
| `TestSnapshotShape` | /health JSON keys stable |
| `TestResetRemovesPublisher` | Reset() removes publisher entry |

**Not yet in scope**: main.go wiring is now the last blocker for end-to-end shadow-mode operation. Everything else in Phase 2 (config, secrets, mosquitto integration test, shadow publish) either has an existing template (secrets/config mirror the AMQP consumer pattern) or is optional (mosquitto for local dev only).

**Architectural decisions locked in via the scaffold**:

1. **Clean-session MQTT** — Sparkplug B requires it. Persistent sessions would fight the broker's retained-message semantics.
2. **QoS 0 default** — Sparkplug spec's convention for DATA messages. Higher QoS would double-count.
3. **`TopicFilterAll = "spBv1.0/+/+/+/+"`** as the default subscription — matches every Sparkplug message. Downstream Handler decides what to process.
4. **Per-publisher alias-table state lives in the Handler, not the Subscriber** — the Subscriber is a dumb pipe. Handler owns the state machine. Justifies the per-tenant subscriber sharding described in Phase 1's parallel benchmark analysis.
5. **Handler errors don't propagate to the broker** — no "nack" in QoS 0. Errors are logged + counted; broker doesn't retry. This is Sparkplug B's contract; if we need retry, that's a downstream concern (DLX on the RMQ egress).

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
