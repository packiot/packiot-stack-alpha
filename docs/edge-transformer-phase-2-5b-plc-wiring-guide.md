# Phase 2.5b — Wiring PLC tabs to the publisher (real-data auto-publish)

**Goal:** make real PLC data flow through the `Publish to edge.plc-normalized` tab automatically — without manual inject clicks. Once shipped, edge-transformer's shadow handler sees real factory traffic.

**Prereq (DONE):** Phase 2.5 Step 3 — the publisher tab is live in staging, verified end-to-end via SSM inject. See [Phase 2.5 publisher guide](./edge-transformer-phase-2-5-publisher-guide.md).

**Status:** READY to implement. All design decisions pre-made in this doc.

**Risk profile:** MEDIUM-HIGH. Modifies live `flows/Sparkplug.json` which currently publishes to the legacy `oee` exchange. A wiring bug could break the existing GCP PubSub or AMQP publish paths that real factories depend on. **Do this fresh + with local-dev validation.** See [recover-validate-then-merge zettel](../../notes/systems/recover-validate-then-merge-stranded-work.md).

---

## 1. The tap point — already identified

Sparkplug.json's data flow converges at junction `870ca5bd82dd2be3` BEFORE the `pack-queue`:

```
sim-http-in → sim-prep-func ─┐
                             │
SparkPlug subflow ───────────┼──→ JUNCTION 870ca5bd82dd2be3 ──→ pack-queue ──→ amqp-pub-oee-amqplib (legacy)
                             │
status node ─────────────────┘
```

**The junction's output is the canonical "decoded Sparkplug payload"** — the same shape `amqp-pub-oee-amqplib` already consumes. We tap HERE.

Adding a link-out at this junction means our new publisher tab receives the same data the legacy path does — no contention, no duplication risk, no PLC-side change.

---

## 2. The shape adapter — required (Sparkplug shape ≠ publisher input shape)

The junction's msg.payload is a Sparkplug B object:

```js
{
    "metrics": [
        {
            "name": "CPACK/SC/L25/MST/Admin/ProdConsumedCount/0/UnitOUT",
            "value": 12345,
            "timestamp": 1782849957000,
            // ... other fields
        },
        // ... more metrics
    ],
    "timestamp": 1782849957000,
    "seq": 42
}
```

The publisher's envelope-builder expects per-metric msgs:

```js
{
    "equipment_id": 84,
    "parameter": "counter_consumed",
    "value": 12345,
    "datatype": "int64",
    "timestamp": 1782849957000  // optional
}
```

So we need a **fan-out adapter** function that:
1. Iterates `msg.payload.metrics`
2. For each metric, looks up the equipment_id via packml_register (or uses topic-prefix derivation)
3. Maps the metric name to a canonical parameter name
4. Emits one msg per metric

### Adapter function (~40 LOC)

```js
// Sparkplug → normalized-payload fan-out.
// Input:  msg.payload = Sparkplug B object with .metrics array
// Output: one msg per metric, shaped for the envelope-builder downstream.

if (!msg.payload || !Array.isArray(msg.payload.metrics)) {
    return null;  // not a sparkplug payload; drop
}

const out = [];
const sourceTs = msg.payload.timestamp;

for (const m of msg.payload.metrics) {
    if (!m.name || typeof m.name !== 'string') continue;
    
    // Derive tenant + equipment from topic prefix (mirrors amqp-pub-oee-amqplib's
    // pattern). Format: <ENT>/<SITE>/<AREA>/<LINE>/<UNIT>/<area>/<MetricName>
    const parts = m.name.split('/');
    if (parts.length < 7) continue;  // malformed; skip
    
    const tenant = parts[0].toLowerCase();
    // Equipment ID resolution: in Phase 3, this should come from packml_register
    // (loaded into flow.context at startup). For Phase 2.5b shadow, derive from
    // the line + unit segment as a hashable string + use a lookup table OR
    // accept that equipment_id may be null for unmapped equipment.
    const lookupKey = parts.slice(0, 5).join('/');  // ENT/SITE/AREA/LINE/UNIT
    const equipmentMap = flow.get('equipment_map') || {};  // populated elsewhere
    const equipmentId = equipmentMap[lookupKey];
    
    if (typeof equipmentId !== 'number') {
        // Skip unmapped equipment in shadow mode; Phase 3 will load packml_register
        continue;
    }
    
    // Parameter name = the metric name's last segment (per Sparkplug convention)
    const parameter = parts[parts.length - 1];
    
    out.push({
        payload: {
            equipment_id: equipmentId,
            parameter: parameter,
            value: m.value,
            datatype: m.dataType || 'auto',
            timestamp: m.timestamp || sourceTs
        }
    });
}

return [out];  // array-of-arrays: Node-RED fan-out signature
```

### Equipment map population

The `flow.get('equipment_map')` lookup needs to be populated. Two options:

**A — Hardcoded in client.yaml** (Phase 2.5b minimum)
- Add a `flows/load-equipment-map.json` tab with a single inject (run-once at startup) that reads `flow.config.equipments` and writes it as `flow.set('equipment_map', { ... })`.
- The map is `{ "ENT/SITE/AREA/LINE/UNIT": equipment_id }` keyed.

**B — packml_register exports** (Phase 3 work)
- Load from packml_register table via Hasura at startup.
- Update on change events.
- Properly canonical; matches what oeecloud-worker does.

**Recommendation: A for Phase 2.5b**, B for Phase 3.

---

## 3. The wiring change (Node-RED link-in/link-out bidirectional refs)

Node-RED's `link in` and `link out` nodes maintain BIDIRECTIONAL references via their respective `links` arrays. To wire our new link-out (in Sparkplug.json) to our existing link-in (in the publisher tab):

### Change 1: Add link-out node in `flows/Sparkplug.json`

```json
{
    "id": "sp-to-publisher-link",
    "type": "link out",
    "z": "af56dfe315abf91e",
    "name": "plc-normalized.out",
    "mode": "link",
    "links": ["et-plc-link-in"],
    "x": 1100,
    "y": 380,
    "wires": []
}
```

Plus the new fan-out function node:

```json
{
    "id": "sp-to-publisher-adapter",
    "type": "function",
    "z": "af56dfe315abf91e",
    "name": "Sparkplug → publisher shape adapter",
    "func": "<the 40-LOC adapter from §2>",
    "outputs": 1,
    "x": 1100,
    "y": 320,
    "wires": [["sp-to-publisher-link"]]
}
```

Wire the JUNCTION's output (currently `[["ee3657de34f00a89"]]` for pack-queue) to ALSO send to our adapter:

```json
// junction 870ca5bd82dd2be3:
"wires": [["ee3657de34f00a89", "sp-to-publisher-adapter"]]
```

Note: Node-RED wires are array-of-arrays per output port. Adding the second entry to the first port means the junction's single output fans to BOTH the existing pack-queue path AND our new adapter — clean tee, no contention.

### Change 2: Update link-in in `flows/Publish to edge.plc-normalized.json`

The existing link-in node needs its `links` array updated to know about the new link-out:

```json
{
    "id": "et-plc-link-in",
    "type": "link in",
    "links": ["sp-to-publisher-link"],   // ← was []
    ...
}
```

### Change 3: Apply same edits to `flows.json` (dual-write per flow-manager)

Both per-tab files AND flows.json must be updated. The wildcard cp in entrypoint (fixed by PR #16) ensures the per-tab file lands in the container, but flow-manager loads from per-tab files. Belt-and-suspenders rule: update both.

---

## 4. Pre-flight checks (BEFORE the PR)

```bash
# A. Re-confirm Phase 2.5 Step 3 is still working
ssh staging:
  curl -X POST http://localhost:1880/inject/et-test-inject
  # expect: OK + edge-transformer log line within 3s

# B. Verify SparkPlug subflow is still on canonical v1.10.39.1
docker exec stack-edge-nodered-1 ls /data/subflows/ | grep SparkPlug
# expect: only SparkPlug_v1.10.39.1.json (per PR #12 consolidation)

# C. Check current msg-rate on the legacy `oee` exchange
# (so we know what magnitude of fan-out to expect from the junction)
docker exec stack-rabbitmq-1 rabbitmqctl list_exchanges name messages_published_in_rate \
  | grep -E "^oee|^edge"
# typical: oee ~5-15 msg/s during business hours
```

---

## 5. Local dev validation (REQUIRED — per recover-validate-then-merge zettel)

```bash
cd ~/github/packiot/edge-node-red
make up  # local stack with PubSub emulator

# Open Node-RED at http://localhost:1880
# 1. Verify the publisher tab is visible
# 2. Verify the new link-out + adapter are in Sparkplug tab
# 3. Trigger the simulator (sim-http-in)
# 4. Watch the debug pane for the publish result
# 5. Check local rabbitmq:15672 for messages in edge.plc-normalized exchange
```

**Don't push until local validation passes.** PR #9 was the lesson; PR #14's near-miss with the entrypoint enumeration was the reinforcement.

---

## 6. PR + verification

After local validation:

1. PR with title `feat: Phase 2.5b — wire Sparkplug to edge.plc-normalized publisher`
2. PR body includes: actual local-test screenshot of debug pane, msg flow diagram, rollback statement
3. Monitor the auto-bump + staging deploy
4. Run verification via SSM:
   ```bash
   /tmp/verify_phase_2_5.sh  # extend to count messages over 60s window
   ```
5. Expected: edge-transformer logs N shadow-handler invocations matching N PLC messages over the window

---

## 7. Rollback path

If staging deploy breaks (any service goes unhealthy, OR the legacy oee exchange stops receiving msgs):

```bash
gh pr create --title "revert: phase 2.5b — wire Sparkplug to publisher" --base staging
gh pr merge --auto --squash
```

The wiring change is contained to 3 nodes added to Sparkplug.json + 1 field update to the publisher tab's link-in. Revert is fully reversible. No state to clean up.

---

## 8. Effort estimate

| Step | Effort | Notes |
|---|---|---|
| Pre-flight checks | 10 min | |
| Equipment-map loader (option A) | 30 min | New tiny tab; one inject + one function |
| Wire the adapter + link-out in Sparkplug | 30 min | Careful JSON; verify wires |
| Local dev validation | 30 min | First `make up` may need rust knocked off |
| PR + monitor staging | 30 min | |
| Verification + observation window | 1 hour | Watch shadow logs over 30+ min |

**Total: ~3 hours focused work.**

---

## 9. What it unblocks

Once Phase 2.5b lands:
- Real PLC data continuously flowing through edge.plc-normalized → edge-transformer shadow handler
- Phase 3 (Calc Production Counters port) becomes implementable + testable against real data
- The comparator pattern (ADR-0008) can run side-by-side: Go-ported transforms vs Node-RED's existing transforms; 30-day soak window starts the clock

---

## 10. Open questions to settle DURING implementation

1. **Equipment map staleness** — what happens when a new equipment is provisioned in CS Admin but the flow.context map isn't refreshed? Option A means a restart is needed. Document.
2. **Unmapped equipment handling** — adapter currently drops (`continue`). Should it log + drop, or emit a "unknown" placeholder for visibility?
3. **Datatype passthrough** — `m.dataType` may not match the schema enum exactly. Add a normalize step or accept "auto" as the type for now.
4. **High-frequency PLCs** — at the worst case (CPack peak ~15 msg/s × ~20 metrics avg = 300 msg/s), can the HTTP-management-API publish keep up? Test the worst-case rate locally before deploying.
5. **What's in `flows.json` for HTTP Ingestion** — that tab is in flows.json but NOT in /repo-data/flows/. After PR #16 (wildcard cp), it stays missing from /data/flows/ on next deploy. Either restore the per-tab file or formally retire the tab. (Out of scope for this guide but worth tracking.)

---

## TL;DR for execution

```
Phase 2.5b implementation, in order:

  1. Pre-flight: confirm staging healthy
  2. Add equipment-map loader (small new tab)
  3. Add the adapter function + link-out to Sparkplug.json (3 nodes)
  4. Update link-in in publisher tab (1 field)
  5. Update flows.json dual-write
  6. Local `make up` + verify simulator triggers shadow logs
  7. PR + merge + monitor
  8. Verify shadow handler sees real PLC msgs over 30+ min
  9. If anything looks off: revert per §7

DON'T do this tired. The Sparkplug tab is a production-critical path.
```
