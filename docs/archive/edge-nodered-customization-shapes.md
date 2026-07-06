# Edge-Node-RED Customization Shapes — Phase 0 Catalog

**Purpose:** Inventory the shapes of customization observed in real customer Node-RED instances, so the new Go layer + config layer (ADR-0009) can be designed to accommodate them without forcing CS teams to keep writing thousand-line `function` nodes.

**Source data:** One real customer's flows.json (3.0 MB, 1,003 nodes, 4 tabs). The `Client` tab — 478 nodes, 155 function nodes, 15,870 LOC of JavaScript — was treated as the canonical customization surface. The operator-UI tabs (legacy vendored copies of the operator SPA's old code) were ignored per the 2026-06-30 conversation.

**Status:** Draft 1 from a single customer instance. To be augmented as more customer YAMLs become available.

---

## TL;DR — the eight shapes

| Shape | Frequency in this customer | Suggested home in new architecture |
|---|---|---|
| **PLC tag mapping** | 37 OPC-UA items + 25 clients | `client.yaml` → `equipment_mapping:` |
| **State-machine writes** (context/global mutators) | 89 function nodes (57% of all functions) | Node-RED low-code (small bounded functions) OR Go layer (if pattern crystallizes) |
| **Config blobs disguised as functions** | 3 functions, ~9,100 LOC | `clients/<id>/data/*.yaml` |
| **Time/shift logic** | 20 function nodes | Go layer — standardized library |
| **Scheduled triggers** | 41 inject nodes (14 real schedules) | `client.yaml` → `schedules:` |
| **Custom routing/switch logic** | 37 switch + 19 change nodes | Node-RED low-code |
| **Simple payload transforms** | 19 transform functions | Node-RED low-code OR Go layer (case-by-case) |
| **External integrations** | 7 http-request nodes | `client.yaml` → `integrations:` + pre-built Go connectors |

The strongest signals:

1. **The "customization is logic" assumption is wrong.** ~9,100 of the 15,870 LOC (58%) is pure data masquerading as code. Five-minute YAML conversion eliminates it.
2. **The state-machine pattern is real and load-bearing.** 89 functions write to flow/global context. This is how customers build per-equipment finite state machines on top of PLC inputs. The new architecture must support this; the question is whether it stays in Node-RED or moves to a Go state-machine engine.
3. **Customizations are individually small.** Median function: 20 LOC. P90: 146 LOC. The "scary Node-RED function" is rare — the 8,113-line monster is an outlier (and it's just data).

---

## Function size distribution (Client tab)

```
       0 -    10 LOC :  36 functions  (23%)
      11 -    30 LOC :  76 functions  (49%)    ← the realistic customization
      31 -   100 LOC :  22 functions  (14%)
     101 -   300 LOC :  18 functions  (12%)
     301 -  1000 LOC :   2 functions  ( 1%)
    1001 + 99999 LOC :   1 function   ( 1%)    ← 8,113-line error_codes dictionary
                       ───────────────
                       155 functions    15,870 LOC total
```

72% of functions fit in under 30 lines — well within "low-code" territory. The long tail is what we need to break up: the >300 LOC functions are almost always either (a) config in disguise, or (b) accumulated state-machine logic that's outgrown its container.

---

## Shape 1 — PLC tag mapping

**What it is:** Wiring customer-specific PLC tags (OPC-UA node IDs, in this customer's case) to the system's equipment/parameter model.

**Evidence:**
- 37 `OpcUa-Item` nodes — each pointing at an OPC-UA node ID like `ns=6;s=::bci_ini:stBci.Statistics.ProdConsumedCount` and assigning a datatype
- 25 `OpcUa-Client` nodes managing connections
- Wiring done visually in Node-RED via drag-and-connect

**Why it's customization, not generic:** Every customer's PLC vendor uses different namespace conventions, naming, and tag organization. The B&R / Allen-Bradley / Siemens divides up the world differently. There is no universal mapping.

**Proposed config-layer expression** (`client.yaml`):
```yaml
plc:
  protocol: opcua
  endpoints:
    - name: line-25
      url: opc.tcp://10.0.0.1:4840
      security: None
      polling_interval: 1s
equipment_mapping:
  - source: "ns=6;s=::bci_ini:stBci.Statistics.ProdConsumedCount"
    equipment_id: 84
    parameter: counter_consumed
    datatype: int64
  - source: "ns=6;s=::bci_ini:stBci.Statistics.ProdProcessedCount"
    equipment_id: 84
    parameter: counter_processed
    datatype: int64
```

**What stays in Node-RED:** the OPC-UA Item nodes themselves — Node-RED's OPC-UA node ecosystem is mature. But the mapping (which tag → which equipment) is config-driven; the Node-RED nodes get generated from the YAML at startup.

---

## Shape 2 — State-machine writes (the biggest pattern)

**What it is:** Mutating Node-RED's flow- or global-scope context to track per-equipment state across messages. Patterns observed:

```js
context.set('JOBs___LAST_DB_BATCH', msg.payload)
flow.set('Line25_LastState', 'RUNNING')
global.set('Line25.Counters.Last', msg.now)
```

**Evidence:** 89 of the 155 function nodes (57%) start with a `context.set` or `global.set`. The customer is building bespoke finite-state machines on top of PLC inputs: "if counter went up by N in the last 30s AND we're in state X, transition to state Y."

**Why it's customization:** the FSM logic is deeply customer-specific — depends on their process, their machine vendors, their definition of "running" vs "downtime" for THEIR equipment.

**The hard question:** does this stay in Node-RED forever, or does the new Go layer eventually offer a declarative state-machine DSL? **Recommendation: stays in Node-RED for now**, but with the following discipline:
- Each state machine lives in its own subflow (one per equipment) rather than spreading across the tab
- Subflow contract is well-defined: inputs from RabbitMQ (normalized PLC events), outputs to RabbitMQ (state transitions)
- Subflow size capped at, say, ~200 LOC total — if it exceeds, it's a Go-layer feature request

This shape is the one most likely to RESIST migration to Go and the most legitimate use of Node-RED's low-code surface.

---

## Shape 3 — Config blobs disguised as functions

**What it is:** Massive `flow.set('config_thing', { ... })` or `msg.config = { ... }` calls embedded in function nodes. Pure data, zero logic.

**Evidence (in this customer):**

| Function name | LOC | What it actually is |
|---|---|---|
| `set error list json` | 8,113 | Per-machine error code → category mapping (dictionary keyed by machine name) |
| `SETTINGS JSON 0.52` | 789 | Enterprise/site/line catalog + thresholds + UI labels |
| `general PackML config (initial) ****` | 232 | Default PackML parameter values (parameter ID → default) |
| **Total** | **9,134 LOC** | **= 58% of all JS in the Client tab** |

These are config files written in JavaScript because Node-RED has no first-class config-loading mechanism.

**Proposed home:** YAML files under `clients/<id>/data/`. The Go layer loads them at startup; Node-RED loads the same files via a single small init function (one per file, ~5 LOC each).

**Sample conversion** — `data/error-codes.yaml`:
```yaml
Mini120HC:
  109:
    machine: CTS
    category: WEBTRS
    subcategory: "KNF Rotative Axis Acopos: Encoder Fault {TSN_109}"
    category_desc: "Web Transportation"
  110:
    machine: CTS
    category: WEBTRS
    subcategory: "KNF Rotative Axis Acopos: Init Fault {TSN_110}"
    category_desc: "Web Transportation"
  # ... 8000+ more entries, but now diffable, reviewable, lintable
```

**Immediate win:** even before any Go service exists, moving these 9,134 LOC to YAML cleans up the customer's flows.json by **58%**.

---

## Shape 4 — Time/shift logic

**What it is:** Date math, timezone handling, "is now within shift X?", "is today a weekend?".

**Evidence:** 20 function nodes whose first lines reference `Date`, `moment`, `getHours()`, etc. Examples likely include: cross-midnight shift detection, holiday calendar checks, "compute shift bucket from epoch ms".

**Why it should move to Go:** time math in JavaScript is famously bug-prone (timezone DST handling, integer-vs-float milliseconds, locale issues). This is standardized logic that every customer needs the same way.

**Proposed home:** Go library exposing helpers via the normalized payload:
```go
// In edge-transformer:
payload.ShiftBucket = shiftcalc.BucketFor(payload.Timestamp, equipment.SiteTimezone, equipment.ShiftConfig)
payload.IsWeekend  = shiftcalc.IsWeekend(payload.Timestamp, equipment.SiteTimezone, holidays.For(client))
```

Node-RED customization layer receives `msg.shift_bucket` and `msg.is_weekend` already computed; no per-customer time code.

---

## Shape 5 — Scheduled triggers

**What it is:** Periodic actions — polling external APIs, computing rollups, sending health pings, evaluating weekend logic.

**Evidence:** 41 `inject` nodes in the Client tab. Breakdown:
- 27 manual-only (debug/testing — can probably be cleaned up)
- 14 real schedules:
  - intervals: 30s, 60s, 110s, 120s, 120s, 150s, 180s, 600s, 600s
  - cron: `00 22 * * 5` (Friday 22:00), `00 23 * * 5` (Friday 23:00), `00 23 * * 0` (Sunday 23:00)
- 2 once-at-startup

**Why config-driven works:** scheduling is a contract, not logic. The Go layer (or Node-RED via generated inject nodes) reads a YAML schedule and fires at the right time.

**Proposed config-layer expression**:
```yaml
schedules:
  - name: shift-validity-poll
    interval: 30s
    action: poll_shift_api          # ↓ either built-in Go action OR a named Node-RED hook
  - name: weekend-detection
    cron: "0 22 * * 5"
    action: trigger_weekend_mode
  - name: counter-rollup
    interval: 600s
    action: rollup_counters
```

**Pattern:** the YAML names an `action`. The action is either a built-in Go feature OR a named hook into a Node-RED customization tab. CS engineers can wire actions in low-code; Go provides the dispatch.

---

## Shape 6 — Custom routing / switch logic

**What it is:** Decision trees on PLC values, equipment state, time-of-day — "if this counter, route to that subflow".

**Evidence:** 37 `switch` nodes + 19 `change` nodes. These are PURE Node-RED idioms — visual, low-code, easy for non-developers to modify. No JavaScript involved.

**Why it stays in Node-RED:** this is exactly what Node-RED is good at. Visual routing of typed messages. Trying to express "if msg.payload.line === 'L25' AND msg.payload.state === 'IDLE' for >30s, route to subflow X" in YAML quickly becomes worse than Node-RED's drag-and-connect.

**Boundary rule:** routing logic with no side effects → Node-RED. Routing that triggers state mutations → see Shape 2 (state-machine pattern).

---

## Shape 7 — Simple payload transforms

**What it is:** Reformatting messages between system boundaries. Rename fields, build sub-objects, drop unused keys.

**Evidence:** 19 functions that loop over data (`for`, `.forEach`, `.map`). Mostly small (median ~25 LOC).

**Boundary rule:**
- **Stays in Node-RED:** customer-specific reformatting (e.g., this customer wants `temperature` in Celsius but the PLC sends Fahrenheit, or this customer's box scanner emits a different key name)
- **Moves to Go:** transforms that are identical across customers (PackML parameter parsing, the normalized-payload schema enforcement)

The line is "is this transform on customer-customizable territory, or system-wide?" Easy review heuristic.

---

## Shape 8 — External integrations

**What it is:** Outbound HTTP calls to per-customer third-party systems (their ERP, their custom analytics, their auth provider).

**Evidence:** Only 7 `http request` nodes in the Client tab (the others are in the operator-UI tabs which are out of scope). Of those 7:
- 5 polls of `back4-api-dev` for shift validity
- 1 ping to `api4.packiot.com/devices/ping`
- 1 job_report POST to `back4-api-main`

Sparse but real — every customer will have some.

**Proposed config-layer expression**:
```yaml
integrations:
  shift_validity:
    enabled: true
    type: http_poll
    url_env: SHIFT_API_URL
    method: GET
    interval: 30s
    parse: json
    on_response: set_shift_state    # ↓ Node-RED hook or Go handler
  device_ping:
    enabled: true
    type: heartbeat
    url: https://api4.packiot.com/devices/ping
    interval: 60s
  # ...
```

The Go layer ships pre-built connectors for the common shapes: `http_poll`, `http_webhook_in`, `heartbeat`, `cloud_api_call`. Customer config selects the shape and supplies parameters.

For genuinely bespoke integrations, the Node-RED customization tab can implement them — but they must use the configured credentials pattern (`url_env: X`) rather than hardcoding URLs.

---

## Cross-shape observations

### Observation A — most customization is NOT logic-heavy

If we strip out the config blobs (9,134 LOC), the actual "customization logic" in this customer is **6,736 LOC across 152 functions** — about **44 LOC per function on average**. That's well within reviewable low-code territory.

The story "Node-RED accumulates thousand-line spaghetti" is only half right. It accumulates **thousand-line CONFIG**. Solving the config problem alone solves the bulk of the readability/diff issue.

### Observation B — the Calc_Counters monster is NOT here

Earlier analysis showed `Calc_Counters` functions (1000+ LOC, duplicated 5+ times) in the customer's flows.json. They're all in the operator-UI tabs — which we're not migrating. The Client tab has **zero** OEE/counter calc functions.

**Implication:** Calc_Counters is a TEAM concern (in the baseline edge-nodered's standardized transforms), not a customer-customization concern. Phase 3 of ADR-0009 ports the team's Calc_Counters to Go — it's standardized logic, not per-customer.

### Observation C — schedules are surprisingly few

Only 14 real schedules in 478 nodes. Schedules look like they'll fit a YAML schema with room to spare; we won't hit the "scheduling DSL grew its own DSL" trap.

### Observation D — the state-machine pattern is the load-bearing one

If any single observation should drive ADR-0009's architecture, it's this: **customers use Node-RED to build per-equipment state machines, and 89 functions in this customer alone are part of that pattern**. This is what Node-RED is FOR; this is why we keep it.

The Go layer's job is to provide the inputs (normalized PLC events) and consume the outputs (state-transition events). The state machines themselves stay in Node-RED.

---

## What this catalog does NOT yet tell us

Honest limitations of this Phase 0 draft:

1. **One customer's worth of data.** Patterns might not generalize. Need 2-3 more customer YAMLs to validate.
2. **Doesn't include the operator-UI tabs.** Those are intentionally out of scope (legacy vendoring being phased out separately).
3. **No SparkPlug B customer studied yet.** This customer is OPC-UA; the baseline edge-nodered targets SparkPlug. Need a SparkPlug customer YAML to confirm the protocol abstraction holds.
4. **No insight into runtime behavior** — message rates, peak loads, error patterns. Phase 0 is static analysis only; Phase 0.5 would be a few hours of production tracing.

These gaps don't block Phase 1 (schema design) — the shapes are clear enough — but they should be closed before Phase 3 (Go transformer build).

---

## Next: Phase 1

Phase 1 takes this catalog and produces:
- `docs/clients/_schema.yaml` — the formal client.yaml schema covering every shape above
- `docs/clients/cpack.example.yaml` — a sample populated config for one real customer

Both will reference the shapes by name (e.g., `# shape 1: PLC tag mapping`) so the cross-reference between catalog and schema is explicit.
