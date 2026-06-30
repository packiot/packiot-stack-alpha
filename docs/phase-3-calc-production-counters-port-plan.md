# Phase 3 — `Calc Production Counters` Port Plan

**Status:** Prep doc — Phase 3 cannot start until Phase 2 (per PR #106 runbook) is complete.
**Cross-references:**
- [ADR-0009](./adr/0009-edge-transformer-go-service-and-nodered-split.md) — Phase 3 in context
- [ADR-0008](./adr/0008-phase-2-comparator-split.md) — comparator validation pattern
- [Phase 2 runbook](./edge-transformer-phase-2-runbook.md) — what comes first
- [Normalized payload schema](./clients/_normalized-payload-schema.yaml) — the contract

---

## 1. Why this function first

Phase 3 is "port standardized transforms from Node-RED to Go, comparator-validated." Choosing the first port wisely matters — it has to be:
- **Real value** — not a strawman; the function actually runs in production
- **Single canonical version** — not a tangle of vendored variants
- **Pure-ish** — minimal I/O, mostly logic (so the port is about logic correctness, not protocol weirdness)
- **High visibility** — the team will see it work; momentum matters

`Calc Production Counters` fits all four:

| Criterion | Status |
|---|---|
| Real value | ✅ Runs on every PLC `ProdProcessedCount` / `ProdConsumedCount` / `ProdScrappedCount` event — production counting accuracy depends on it |
| Single canonical | ✅ One copy in `subflows/SparkPlug_v1.10.39.1.json` (id `1175dbcfce9b9ffa`); referenced by the active subflow chain in `flows.json` |
| Pure-ish | ⚠ Reads from `global.*` + `flow.*` state (state-machine pattern from Phase 0 Shape #2). Port must handle this — see Section 4. |
| High visibility | ✅ It's literally the function the team has bug-fixed 4+ times (per `git log -- subflows/SparkPlug_v1.10.39.1.json`); removing it from Node-RED's footprint is a quality-of-life win |

**Size:** 998 LOC of JavaScript. Dense. The biggest single function in the repo.

**Identifier for tracking:** function node id `1175dbcfce9b9ffa` (the canonical instance). The 3 other instances in `flows.json` with similar names (`Calc Production Counters` and `Calc Production Counters (Alt)`) are older/duplicate copies; Phase 3 cleanup also removes them once the Go port is the sole writer.

---

## 2. What the function does (decoded from the source)

The full source is preserved at `services/edge-transformer/internal/transforms/calc_production_counters/source.js` (will land alongside the Go port). High-level summary:

### Inputs (from `msg`)
- `msg.topic` — SparkPlug topic string in the form `<ENT>/<SITE>/<AREA>/<LINE>/<UNIT>/Admin/<COUNTER_TYPE>/<INDEX>/Unit***<TRIG>`
  - The `***<TRIG>` suffix identifies trigger type: `IN`, `OUT`, `SCRAPED`, `TRIG`, etc.
  - Suffix is stripped before further routing
- `msg.payload` — the counter value (integer)
- `msg.timestamp` — PLC sample time (post-2026-06 bug fix; pre-fix it used a hardcoded 2022 date)

### Inputs (from state)
- `global.get("modes")` — array of `{topic, is_set, type}` per-unit mode entries; used to skip processing when unit is in SETUP mode (mode=6)
- `flow.get("packml_config")` — per-unit config including counter trigger flags
- Several other `flow.*` / `global.*` reads scattered throughout — see Section 4

### Outputs
- `msg.payload = send_msg` — boolean, whether downstream should process this message
- `msg.send_msg = send_msg` — redundant duplicate for downstream nodes that read this field
- Returns `msg` if `send_msg == true`; returns nothing (drops the message) otherwise

### Core decision tree (simplified)
```
1. Parse topic → extract trigger type + topic prefix
2. Look up unit mode from global.modes; if SETUP (6), pass through unchanged
3. Branch by counter type:
   a. ProdProcessedCount  → counter math A
   b. ProdConsumedCount   → counter math B
   c. ProdScrappedCount   → counter math C
   d. Reset events        → reset-related state mutation
4. Check various send-or-not conditions per counter type
5. Set msg.payload + msg.send_msg with final decision
6. Return msg only if send_msg = true
```

The "counter math" branches are where most of the 998 LOC lives. Each branch has its own state machine reading/writing `flow.*` variables for cumulative counters, threshold checks, and reset detection.

---

## 3. Port target — Go module shape

Lives at `services/edge-transformer/internal/transforms/calc_production_counters/`:

```
calc_production_counters/
├── calc.go              ← public API: Calc(msg Message, state State) (Decision, error)
├── calc_test.go         ← table-driven tests against fixture corpus
├── decision_tree.go     ← the routing logic (parse topic, branch by counter type)
├── counter_math.go      ← the per-counter-type math (3 functions: processed, consumed, scrapped)
├── state.go             ← Go-side mirror of global.modes / flow.packml_config
├── source.js            ← preserved Node-RED original (for reference + comparator diff)
└── testdata/
    ├── fixtures/        ← captured real msg.* inputs + expected outputs from Node-RED
    └── golden/          ← per-fixture expected Decision output
```

### Public API
```go
package calc_production_counters

// Message mirrors the relevant fields of the normalized payload type=plc.value
type Message struct {
    Topic       string          // SparkPlug topic
    Payload     int64           // counter value
    Timestamp   time.Time       // PLC sample time
    Tenant      string          // for state-key namespacing
}

// State is the read-side projection of global.modes + flow.packml_config etc.
// Backed by the same Redis or in-memory store used elsewhere; see state.go.
type State interface {
    Modes(unitTopic string) (mode int, isSet bool)
    PackMLConfig(unitTopic string) (Config, error)
    CounterCumulative(unitTopic string, kind CounterKind) (int64, error)
    SetCounterCumulative(unitTopic string, kind CounterKind, v int64) error
}

// Decision is the function's output.
type Decision struct {
    SendDownstream bool                // was msg.send_msg
    EnrichedMsg    map[string]any      // any added fields for downstream
    StateUpdates   []StateMutation     // applied AFTER SendDownstream evaluated
}

// Calc is the main entry point.
func Calc(msg Message, state State) (Decision, error)
```

Notes on design:
- **State is an interface, not a global** — testable, swappable, locks the seam where we can mock in tests
- **StateMutation is explicit + post-decision** — the JS function inlines `flow.set()` calls mid-logic; Go formalizes them so we can audit what state changes happen, retry safely, and roll back on error
- **Decision is data, not effects** — Calc() doesn't write to RabbitMQ or call HTTP. The caller (handler in edge-transformer) does that. Pure-function discipline.

---

## 4. Handling the state-machine reads (the hardest part)

The JS function does ~15-20 `global.get` / `flow.get` calls. In Node-RED, these read from the per-flow / per-global context store. In Go, we need an equivalent.

**Two options:**

**Option A — Shared Redis-backed store**
- edge-transformer reads/writes state via Redis using the same keys Node-RED uses
- Pro: trivial state-sharing between Node-RED and Go during the comparator window
- Pro: no migration cost when Node-RED retires
- Con: requires Node-RED to ALSO be backed by Redis (today it uses in-process memory or LocalFileSystem). Plumbing.

**Option B — Snapshot-on-publish (read-only on Go side)**
- Node-RED's publisher (Phase 2 envelope-builder) embeds the relevant state in `msg.envelope.state_snapshot` at publish time
- Go side reads the snapshot from the message; never queries shared state
- Pro: no shared infrastructure
- Pro: state is captured atomically with the trigger event (no race)
- Con: envelope size grows (state is ~5-20 KB per message)
- Con: schema change to add `envelope.state_snapshot` (would be a v1.x minor bump)

**Recommendation: Option B.** The envelope schema additions are backward-compatible. The performance cost is bounded (state snapshot is small). The architectural simplicity is worth it. It also matches the "publisher does the protocol translation" boundary we drew in ADR-0009.

If Option B's snapshot turns out too large in practice, we can switch to A later — the State interface in Section 3 is the seam.

---

## 5. Comparator validation plan (ADR-0008 pattern reuse)

Per ADR-0008's comparator pattern (proven on mirror-worker-go), the port is validated by running both implementations in parallel and diffing outputs.

### 5.1 — Topology

```
PLC msg → Node-RED (current)  → output_NodeRed
                              ↓
                          comparator service ← edge-transformer (Go port)  → output_Go
                              ↓
                          diff metric: counter_calc_divergence_total
                              ↓
                          alert if > 0 over 60-second window
```

### 5.2 — Fixture corpus

Build a fixture corpus of real `msg` inputs captured from staging over 24 hours. Each fixture is:

```json
{
  "input": { "topic": "...", "payload": 12345, "timestamp": "..." },
  "state": { "modes": [...], "packml_config": {...} },
  "expected": { "send_msg": true, "enriched_msg": {...} }
}
```

Stored at `services/edge-transformer/internal/transforms/calc_production_counters/testdata/fixtures/`. Aim for ≥500 fixtures across all counter types + edge cases (resets, mode-change boundaries).

### 5.3 — Test gate

Unit tests in `calc_test.go` run all fixtures; any divergence is a test failure. CI green is the prerequisite for opening the port PR.

### 5.4 — Live comparator window

After the port lands:
- ≥7 days zero-diff for the warmup period (low-risk transforms)
- ≥30 days zero-diff for OEE-affecting transforms (this one IS OEE-affecting)

Only then flip: Go becomes authoritative, Node-RED function gets the comment `// REPLACED BY edge-transformer/calc_production_counters; remove in next subflow update`.

### 5.5 — Rollback path

If the comparator detects divergence after cutover, the rollback is a single env flag:

```
COMPARATOR_AUTHORITATIVE_OWNER=nodered     # rollback
COMPARATOR_AUTHORITATIVE_OWNER=edge-transformer  # forward
```

Both implementations keep running until the cutover is permanent (typically 30+ days post-flip).

---

## 6. Effort estimate

| Phase | Effort | Notes |
|---|---|---|
| Source extraction + analysis | 0.5 days | Done in this doc |
| Fixture corpus capture | 1 day | Tcpdump-style capture from staging during business hours |
| Go skeleton implementation | 2 days | calc.go, decision_tree.go, state.go, the API surface |
| `counter_math.go` port (the real work) | 4 days | The 800-ish LOC of branching counter logic |
| `calc_test.go` against fixture corpus | 1 day | Table-driven tests; iterate until 100% pass |
| ADR-0008 comparator wiring | 1 day | Reuse mirror-worker-go's comparator service |
| 7-day warmup window | 7 days | Wait + monitor |
| 30-day comparator window | 30 days | Wait + monitor — overlaps other work |
| Cutover PR + cleanup | 0.5 days | Flip flag; remove Node-RED function in next deploy |

**Total active engineering: ~9 days** (excluding the 30-day comparator soak).

**Per ADR-0009 Phase 3 estimate: 3-4 weeks** — includes this function plus the smaller transforms (`Check PLC Status`, etc.) that follow the same pattern. Once Calc Production Counters is ported, the others are mostly clones of the same Go-skeleton + test-fixture + comparator process.

---

## 7. Open questions for the porting engineer

To answer at the start of Phase 3:

1. **Option A or B for state handling** (Section 4)? Default: B (snapshot). Justify changes.
2. **Where does the fixture corpus live long-term?** In the edge-transformer repo (versioned with the code), in a separate `fixtures` repo (shared across transforms), or in S3 (binary blobs)? Recommendation: in-repo for ≤500 fixtures, evaluate at 5000+.
3. **Should we port `Check PLC Status` (424 LOC) in parallel?** Pro: doubles throughput. Con: doubles risk surface. Recommendation: sequential; complete Calc Production Counters first, then move on.
4. **Does the cutover from Node-RED to Go need a deploy freeze window?** Probably not — the flag flip is atomic and rollback is one env var. But coordinate with operators.
5. **What's the alerting threshold for `counter_calc_divergence_total`?** Default: any divergence over 60 seconds pages oncall. Tighter (1 minute zero-tolerance) for OEE-critical transforms. Confirm with operators.

---

## 8. Pre-Phase-3 checklist (work that has to land first)

Before opening the first port PR:

- [ ] PR #103 (services/edge-transformer/ Go scaffold) merged
- [ ] Phase 2 complete per PR #106 runbook (RMQ topology declared, publisher flow live, shadow mode validated for ≥1 hour)
- [ ] Fixture corpus captured from staging (≥500 fixtures across counter types)
- [ ] Comparator service exists for edge-transformer transforms (likely a new package under `services/edge-transformer/internal/comparator/` — pattern-lift from mirror-worker-go)

Once all checked: open `feat/calc-production-counters-go-port` against staging.
