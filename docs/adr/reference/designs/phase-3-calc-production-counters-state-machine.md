# Calc Production Counters — State Machine Reference

Companion doc to `phase-3-calc-production-counters-port-plan.md`. This file
describes the JS state machine as it exists in Node-RED today so the Go port
in `services/edge-transformer/internal/transforms/calc_production_counters/`
can be written and reviewed against a clear specification of intent.

**Source:** `services/edge-transformer/internal/transforms/calc_production_counters/source.js` (extracted from `edge-node-red/subflows/SparkPlug_v1.10.39.1.json` node id `1175dbcfce9b9ffa`).

**998 LOC of JS** condense to **~11 logical phases**. The port implements them phase-by-phase, with a golden-fixture test per phase.

---

## 0. Runtime contract

The JS function runs in Node-RED's `function` node sandbox. It receives:

| Symbol | Provided by | Notes |
|---|---|---|
| `msg` | Upstream node | Sparkplug-decoded message; carries `topic`, `payload`, `timestamp`, `cmd_trigger`, `SparkPlug_timezone`, `SparkPlug_add_metrics` |
| `flow.get(k) / flow.set(k, v)` | Node-RED runtime | Per-tab persistent store |
| `global.get(k) / global.set(k, v)` | Node-RED runtime | Cross-tab persistent store — this is where all the accumulated counter state lives |
| `node.warn / node.error / node.log` | Node-RED runtime | Logs |

Return value:
- `msg` object → downstream tab receives it (published to AMQP)
- `null` / no return → drop silently

**Port mapping**: `msg` → `Message` struct + `Decision.EnrichedMsg`. `global.*` → the `State` interface. Return value → `Decision.SendDownstream`.

---

## 1. Phases (top-level flow)

The function executes phases sequentially. Any phase can set `send_msg=false` to short-circuit output. Phases marked ⚠ have subtle state dependencies the port must preserve.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 1  Parse timestamp + guard against SETUP mode                     │
│    unit_mode = read global.modes[topic] → if SETUP(6), skip everything   │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 2  Trigger dispatch (which counter fired)                         │
│    trigger = detect from topic substring:                                │
│      "ProdProcessedCount" | "ProdConsumedCount" | "ProdDefectiveCount"   │
│    Read the OTHER TWO counters from global state (the "last" values).    │
│    Determine send_msg = true iff new > last, OR reset if new < last.     │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 3  Compute increments (before TRIG-suffix corrections)            │
│    ProdConsumedIncremet = ProdConsumedCount - ProdConsumedCount_Last     │
│    ProdProcessedIncremet = ProdProcessedCount - ProdProcessedCount_Last  │
│    ProdDefectiveIncremet = ProdDefectiveCount - ProdDefectiveCount_Last  │
│    Attach all six values (count + last + increment) to msg for debug.    │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 4 ⚠ TRIG suffix corrections (customer-specific overrides)         │
│    Only runs when send_msg==true and topic contains "***TRIG".           │
│    Nested if-chain based on additional suffix flags:                     │
│                                                                          │
│      ***TRIG_CS  → force Defective = Consumed - Processed                │
│      ***TRIG_CI  → force Consumed = Processed + Defective                │
│      ***TRIG_C=I → Consumed := Processed  (input mirrors output)         │
│      ***TRIG_C=O → Processed := Consumed  (output mirrors input)         │
│      ***TRIG_CO  → complex: uses ___IN_INCR / ___IN_SCRAP state          │
│                    to reconstruct Processed from Consumed + Scrap        │
│                                                                          │
│    Also: NaN guards default to 0. Two "count_zeros" branches only        │
│    run if the prior didn't fire (order matters).                         │
│                                                                          │
│    After corrections, recompute all three Incremet values.               │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 5  Persist new counter values                                     │
│    global.set(TopicProdConsumedCount, ProdConsumedCount);                │
│    global.set(TopicProdProcessedCount, ProdProcessedCount);              │
│    global.set(TopicProdDefectiveCount, ProdDefectiveCount);              │
│    Negative values write 0 instead (v1.10.2 defensive).                  │
│                                                                          │
│    Custom counter for Parameter*30770*=true units also gets +Increment.  │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 6  Compute ProdSpeed (parts per minute)                           │
│    Two paths:                                                            │
│      A) External-speed path: Parameter*30761* set → read Status/CurMach- │
│         Speed directly from state, don't derive.                         │
│      B) Derived path: ProdSpeed = ProdConsumedIncremet /                 │
│                                    (now - ___TS[last]) * 60000           │
│         Store new timestamp for next iteration's derivation.             │
│                                                                          │
│    Multiply all three Incremets AND ProdSpeed by Parameter*30710*        │
│    (unit conversion factor, default 1).                                  │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 7  Read threshold config (for status determination)               │
│    machspeed         = Status/MachSpeed         (nominal PLC speed)      │
│    threshold_quant   = Status/Parameter*30750*  (% of machspeed)         │
│    threshold_mode    = Status/Parameter30758    (0=instant, 4=5min avg)  │
│    (all optional; default 0 if unset)                                    │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 8  Emit unit metrics (one per counter with increment > 0)         │
│    For each of {Consumed, Processed, Defective}:                         │
│      if Increment > 0 AND value >= 0 AND ProdSpeed < 3 * machspeed:      │
│        emit metric with {timestamp, name, value=Increment, counter,      │
│                          curspeed, plus msg.SparkPlug_add_metrics}       │
│        set send_msg = true                                               │
│        set ProdConsumed_set / ProdProcessed_set                          │
│                                                                          │
│    Consumed-metric block ALSO evaluates threshold logic:                 │
│      if ProdSpeed >= threshold_val:                                      │
│         status = 6 (Holding)                                             │
│         status_topic_name = TopicProdConsumedCount                       │
│                                                                          │
│    ***STATESPEED_THIS suffix moves threshold logic to Processed block    │
│    instead of Consumed (customer-config).                                │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 9 ⚠ Line/sector aggregation                                       │
│    Parameter30700 config array on the LINE topic determines which        │
│    machines contribute to line-level Consumed vs Processed:              │
│      topic_line_val = split(",")                                         │
│      if topicArray[7] == topic_line_val[0]      → this is the "first" ma-│
│                                                    chine, contributes    │
│                                                    to LINE Consumed      │
│      if topicArray[7] == topic_line_val[LAST]   → this is the "last" ma- │
│                                                    chine, contributes    │
│                                                    to LINE Processed     │
│                                                                          │
│    Also handles the "::sector" naming convention: if line contains       │
│    "SEC::LINE", split and iterate BOTH per-line and per-sector.          │
│                                                                          │
│    Scrap gets summed: Line Defective = Line Consumed - Line Processed,   │
│    smoothed across a 20ms debounce.                                      │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 10 Status metric                                                  │
│    If status == 6 (Holding threshold crossed):                           │
│      emit Status/StateCurrent = 6 as a metric                            │
│      register topic in global ___STATUS_TOPICS array for periodic        │
│      re-evaluation by a downstream timer node.                           │
│    Parameter*30763* on the line disables auto-status if the PLC          │
│    emits its own state events.                                           │
└────────────────────────────┬─────────────────────────────────────────────┘
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  PHASE 11 Return msg                                                     │
│    If send_msg == true:                                                  │
│      return msg  (with msg.metrics array populated)                      │
│    Else: return null (Node-RED drops)                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Input topic anatomy

The function assumes a very specific 8-segment topic shape:

```
CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit***TRIG_CS
──┬── ─┬ ──┬─── ─┬ ──┬─── ─┬─── ─────┬────── ─┬  ─┬── ─────┬────
 [0]  [1]  [2]  [3] [4]   [5]      [6]      [7]  [8]      └── suffix

[0] Enterprise    "CPACK"
[1] Site          "SC"
[2] Area          "LINHAS"
[3] Line/sector   "L5" (may contain "::" for sector::line)
[4] Unit          "BREYER"
[5] Admin/Status  section
[6] Metric name   "ProdConsumedCount" | "ProdProcessedCount" | "ProdDefectiveCount"
[7] Machine index in line array (matched against Parameter30700 CSV)
[8] Special: "Unit" always, but the ***SUFFIX gets attached HERE

Suffix parsing:
   base topic = everything before "***"
   trigger    = everything after "***"
   Common trigger values:
     TRIG          — process (this is a real trigger event)
     TRIG_CS       — force Defective = Consumed - Processed
     TRIG_CI       — force Consumed = Processed + Defective
     TRIG_C=I      — set Consumed := Processed
     TRIG_C=O      — set Processed := Consumed
     TRIG_CO       — complex reconstruction from prior state
     STATESPEED_THIS — move threshold logic to Processed metric block
```

The scaffold's `ParseTopic` only handles the base case (`IN`/`OUT`/`SCRAPED`) — the port MUST extend it to handle the compound TRIG_* suffixes above.

---

## 3. Global-state keys the function reads/writes

The JS function is heavily stateful — everything hangs off `global.get(topic_key)` with topic keys derived from the input topic. This is what the port's `State` interface must abstract:

| Key pattern | Read | Write | Purpose |
|---|---|---|---|
| `<topic>/Admin/ProdConsumedCount` | ✓ | ✓ | Current cumulative Consumed count |
| `<topic>/Admin/ProdProcessedCount` | ✓ | ✓ | Current cumulative Processed count |
| `<topic>/Admin/ProdDefectiveCount` | ✓ | ✓ | Current cumulative Defective count |
| `<topic>/Admin/*___IN_INCR` | ✓ | ✓ | Last Consumed increment (for TRIG_CO reconstruction) |
| `<topic>/Admin/*___IN_SCRAP` | ✓ | ✓ | Last Defective increment (for TRIG_CO reconstruction) |
| `<unit>/Status/UnitModeCurrent` | ✓ | | PackML mode (skip if 6=SETUP) |
| `<unit>/Status/CurMachSpeed` | ✓ | ✓ | Current speed (external or derived) |
| `<unit>/Status/CurMachSpeed___TS` | ✓ | ✓ | Timestamp for speed derivation |
| `<unit>/Status/MachSpeed` | ✓ | | Nominal PLC speed (for threshold) |
| `<unit>/Status/Parameter*30710*` | ✓ | | Counter multiplier |
| `<unit>/Status/Parameter*30750*` | ✓ | | Threshold quantity (% of machspeed) |
| `<unit>/Status/Parameter30758` | ✓ | | Threshold mode (0=instant, 4=5min-avg) |
| `<unit>/Status/Parameter*30761*` | ✓ | | External-speed override flag |
| `<unit>/Status/Parameter*30770*` | ✓ | | Custom counter enable flag |
| `<unit>/Status/Parameter*30772*` | ✓ | ✓ | Custom counter accumulator |
| `<line>/Admin/ProdDefectiveCount` | ✓ | ✓ | Line-level scrap accumulator |
| `<line>/Admin/ProdDefectiveCount___PREVIOUS` | ✓ | ✓ | Line-level scrap previous (for debounced delta) |
| `<line>/Admin/ProdDefectiveCount___TS` | ✓ | ✓ | Line-level scrap timestamp (for 20ms debounce) |
| `<line>/Status/Parameter30700` | ✓ | | CSV of machine indices in line |
| `<line>/Status/Parameter*30763*` | ✓ | | Disable auto-status flag |
| `<threshold_mode>_6_Consumed_last_TS` | ✓ | ✓ | Threshold-mode-4 rolling window start |
| `<threshold_mode>_6_Consumed_last_counter_value` | ✓ | ✓ | Threshold-mode-4 counter snapshot |
| `___STATUS_TOPICS` | ✓ | ✓ | Global array of topics to re-check for status |
| `modes` | ✓ | | Global array of {topic, is_set} objects |

**Port implication**: The `State` interface's current shape (Modes, PackMLConfig, CounterCumulative) is too narrow. The port PR needs to extend it with:

```go
type State interface {
    // ... existing ...

    // Speed tracking
    LastSpeedTimestamp(unitTopic string) (time.Time, error)
    SetLastSpeedTimestamp(unitTopic string, ts time.Time) error
    CurMachSpeed(unitTopic string) (float64, error)
    SetCurMachSpeed(unitTopic string, v float64) error

    // Line-level aggregation
    LineScrapCount(lineTopic string) (int64, error)
    SetLineScrapCount(lineTopic string, v int64) error
    LineScrapPrevious(lineTopic string) (int64, error)
    SetLineScrapPrevious(lineTopic string, v int64) error
    LineScrapTimestamp(lineTopic string) (time.Time, error)
    SetLineScrapTimestamp(lineTopic string, ts time.Time) error

    // Threshold mode-4 rolling window
    ThresholdWindowStart(threshMode string) (time.Time, int64, error)
    SetThresholdWindowStart(threshMode string, ts time.Time, counter int64) error

    // Status topic registry
    StatusTopics() ([]string, error)
    AddStatusTopic(topic string) error

    // Generic parameter access (30700, 30710, 30750, 30758, 30761, 30763, 30770, 30772)
    Parameter(unitTopic string, id string) (any, error)
    SetParameter(unitTopic string, id string, v any) error
}
```

That's a big expansion but faithful to what the JS actually needs. The port PR should do this in ONE go, not scattered.

---

## 4. Non-obvious semantics the port must preserve

### 4.1 The "reset" branch (send_msg=true, count_last=0)

If `new_count < last_count`, the JS assumes the PLC restarted the counter and resets `last=0`, `reset_line_scrap_counter=true`. Port must replicate this exactly — losing the reset behavior would silently double-count on PLC restart.

### 4.2 The 3x-machspeed guard

Every metric emission checks `ProdSpeed < 3 * machspeed`. This is a sanity check for glitched PLC values. Port must keep it — dropping outliers is the *intended* behavior.

### 4.3 The 20ms debounce on line scrap

`if (... && ProdDefectiveCount___TS + 20 <= timestamp)` — the JS debounces line-level scrap updates at 20 **milliseconds**. That's suspiciously tight (looks like it should be 20 SECONDS = 20000ms). The port should replicate the JS literal AND add a `TODO: verify if this is a bug` comment for later human review. Do NOT "fix" it silently — behavior parity first.

### 4.4 The NaN dance

Multiple `isNaN(x) ? 0 : x` guards. In JS this catches `undefined` reads from `global.get()`. In Go, the equivalent is `int64` zero-value + explicit `ok` from map read. Port must ensure "missing state key" → 0, matching JS semantics, NOT return an error.

### 4.5 The `count_zeros` chain in Phase 4

The TRIG_CS and TRIG_CI branches share a `count_zeros` counter that gates the second branch. If TRIG_CS fires, TRIG_CI is skipped. The port MUST preserve this exclusion — replicating it as two independent `if` statements would double-write and produce wrong Defective values.

### 4.6 The `set_msg = false / true` toggles in Phase 8

Phase 8 STARTS by setting `send_msg = false`, then each metric emission that succeeds sets it back to `true`. Meaning: if ALL three counters fail the guards, the message is dropped even though Phase 2 said "send". This is the intended silent-drop path for low-volume/high-noise cases.

### 4.7 The Node-RED `msg` object is mutated in-place

`msg.metrics = []`, `msg.ProdConsumedCount = ...`, `msg.machspeed = ...` — the JS builds up the enriched msg by mutation. The port's `Decision.EnrichedMsg` is a map — populate it with the SAME keys the JS attaches. The comparator will diff on these exact key names.

---

## 5. What the port intentionally DOES NOT preserve

Per the port plan §7, these get simplified:

| JS behavior | Port behavior | Why |
|---|---|---|
| Commented-out Montebello custom counter hack (lines 306-317) | Deleted | Dead code, has been for months |
| `global.set("______DEBUG_AAAA*", ...)` diagnostic writes | Deleted, replaced with `logger.Debug` calls behind a flag | Node-RED debug pane was a poor man's log; Go has structured logs |
| Silent JavaScript `undefined` type coercion in arithmetic | Explicit zero-value handling with `ok` from map reads | Safer + easier to test |
| `// @ts-ignore` comments | Replaced with explicit type conversion + test coverage | Go doesn't allow this escape hatch |

Anything else must match line-for-line semantics. When in doubt, the comparator's 30-day soak is the arbiter — a mismatch there halts cutover regardless of "but this looks like a bug in the JS."

---

## 6. Fixture strategy

Golden tests will pair `testdata/fixtures/<scenario>/input.json` with `testdata/fixtures/<scenario>/expected.json`. Initial 12 scenarios (minimum viable coverage):

1. `01_processed_increment_happy` — basic Processed count increment, all guards pass
2. `02_consumed_increment_happy` — basic Consumed increment
3. `03_defective_increment_happy` — basic Defective increment
4. `04_reset_on_counter_rollback` — new < last → reset + send with 0-based increment
5. `05_setup_mode_skips` — unit_mode=6 → drop
6. `06_trig_cs_forces_defective` — ***TRIG_CS → Defective computed
7. `07_trig_ci_forces_consumed` — ***TRIG_CI → Consumed computed
8. `08_trig_c_equals_i` — ***TRIG_C=I → mirrored
9. `09_trig_co_full_reconstruction` — ***TRIG_CO with prior IN_INCR + IN_SCRAP state
10. `10_speed_over_3x_machspeed_drops` — glitch guard
11. `11_line_first_machine_aggregates_consumed` — Parameter30700 first-in-CSV
12. `12_status_holding_threshold_crossed` — status=6 emission

These get captured from live staging traffic in Task #43 (fixture-capture binary). Each fixture is a self-contained (msg, initial_state, expected_msg, expected_state) tuple.

---

## 7. Estimated port complexity

| Phase | LOC estimate | Test coverage estimate | Risk |
|---|---|---|---|
| 1 timestamp + SETUP guard | ~30 | 2 fixtures | Low |
| 2 trigger dispatch | ~80 | 3 fixtures | Low |
| 3 increments | ~20 | Covered by 2 | Low |
| 4 TRIG-suffix corrections | ~120 | 6 fixtures | **HIGH** — customer-specific, easy to regress |
| 5 persist | ~40 | Covered by 2 | Low |
| 6 speed | ~60 | 2 fixtures | Medium — timestamp arithmetic |
| 7 threshold config | ~30 | 1 fixture | Low |
| 8 metric emission | ~150 | 3 fixtures | Medium — guards + status logic |
| 9 line aggregation | ~180 | 4 fixtures | **HIGH** — split/join topic strings, off-by-one risks |
| 10 status metric | ~50 | 1 fixture | Medium — global array mutation |
| 11 return | ~10 | Covered | Low |
| **State interface extension** | ~200 | Unit tests | Medium — mostly rote |
| **Total** | **~970 LOC** | ~24 fixtures + ~30 unit tests | Two HIGH-risk zones |

Realistic port timeline: **~3 weeks focused work** + comparator harness + 30-day soak. Matches the Phase 4 migration plan §5 estimate.

---

## 8. Open questions to resolve during the port

1. **Should the port emit metrics in the same ORDER as the JS?** JS iteration order is insertion-order for `msg.metrics[]`. Comparator should not care about order (it's a set-compare), but if downstream depends on order, we must match.

2. **What happens when State reads return errors mid-Phase?** Current scaffold's State returns errors. But the JS silently treats undefined as 0. Should errors → 0 + log, or errors → abort + no send?

3. **How to model the ___STATUS_TOPICS global array cleanly?** It's used by a timer node elsewhere in Node-RED, not by this function itself. Port could expose an emit-status-topic-update callback rather than a direct state write.

4. **Custom counter Parameter*30772* has no read path from OEE database.** Its ONLY consumers are Node-RED operator UI tabs. Does the Go port need to maintain it, or can it stay in a Node-RED sidecar during Phase 4?

Answering these BEFORE the port starts is cheaper than answering them during. Bring to next design review.

---

## 9. Cross-references

- Port plan overview: `docs/adr/reference/designs/phase-3-calc-production-counters-port-plan.md`
- Phase 4 cutover: `docs/archive/adr-0010-phase-4-migration-plan.md`
- ADR-0010: `docs/adr/0010-sparkplug-decode-in-go-end-state.md`
- Reference JS source: `services/edge-transformer/internal/transforms/calc_production_counters/source.js`
- Go scaffold: `services/edge-transformer/internal/transforms/calc_production_counters/{calc.go,state.go,decision_tree.go}`
