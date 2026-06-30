# Phase 2.5 — Node-RED Publisher to `edge.plc-normalized`

**Goal:** make `edge-node-red` publish normalized PLC payloads to the `edge.plc-normalized` exchange so the edge-transformer shadow handler receives real PLC events, not just synthetic test publishes.

**Status:** READY to implement. All upstream prerequisites met (Phase 2 verified end-to-end via sustained-load test).

**Cross-refs:**
- [ADR-0009](./adr/0009-edge-transformer-go-service-and-nodered-split.md) — architecture
- [Phase 2 runbook](./edge-transformer-phase-2-runbook.md) — what came first
- [Normalized payload schema v1.0](./clients/_normalized-payload-schema.yaml) — message contract
- [Recover-validate-then-merge zettel](../../notes/systems/recover-validate-then-merge-stranded-work.md) — discipline this guide follows

---

## Why the HTTP-management-API pattern (not node-red-contrib-amqp)

Reuses what already works. `flows/HTTPIngestion.json`'s `Relay to RabbitMQ` function (29 LOC) already publishes to the RMQ HTTP management API. The pattern:

```js
var u = env.get('RABBITMQ_USER');
var p = env.get('RABBITMQ_PASSWORD');
var auth = Buffer.from(u+':'+p).toString('base64');
msg.url = 'http://rabbitmq:15672/api/exchanges/%2F/oee/publish';
msg.headers = {'Content-Type':'application/json','Authorization':'Basic '+auth};
msg.payload = JSON.stringify({properties:{}, routing_key: <key>, payload_encoding:'string', payload: JSON.stringify(rmqPayload)});
return msg;
```

Why this beats adding `node-red-contrib-amqp`:

| Concern | HTTP-API pattern | node-red-contrib-amqp |
|---|---|---|
| Dockerfile rebuild | ❌ Not needed | ✅ Required (new dep) |
| New runtime dep | ❌ None | ✅ AMQP client library |
| Pattern proven in repo | ✅ "Relay to RabbitMQ" | ❌ New territory |
| Restart risk (PR #9 lesson) | Low | Medium-high |
| Throughput at expected load (≤15 msg/s/factory) | Fine (HTTP overhead is microseconds) | Fine |
| Throughput at 100+ msg/s/factory | Slower (HTTP overhead per msg) | Faster (persistent AMQP conn) |
| Persistent connection | No (HTTP per msg) | Yes |

For Phase 2.5 (shadow mode, single tenant, <15 msg/s), the HTTP pattern is the right call. Switch to `node-red-contrib-amqp` when throughput-or-latency demands prove it necessary.

---

## Step 1 — Pre-flight checks (verify nothing has rotted)

Before opening the PR, verify:

```bash
# A. edge-transformer is still healthy + consuming
ssh / SSM to staging app EC2:
docker ps | grep edge-transformer    # expect "(healthy)"
docker logs --tail 5 edge-transformer | grep "consuming"  # last line should be "consuming"

# B. edge.plc-normalized exchange still declared
docker exec stack-rabbitmq-1 rabbitmqctl list_exchanges name type | grep edge.plc

# C. Lint-flows.js still passes the existing flows
cd ~/github/packiot/edge-node-red
node scripts/lint-flows.js flows.json    # expect 9 errors (Calc_Counters family — known baseline)
```

If any of A-C fail: investigate before adding new flow code. The recovery-validate-then-merge zettel applies.

---

## Step 2 — Local dev validation (BEFORE committing)

Per [recover-validate-then-merge-stranded-work zettel](../../notes/systems/recover-validate-then-merge-stranded-work.md), test locally first:

```bash
cd ~/github/packiot/edge-node-red

# Make sure local dev stack is up
make up

# Verify it boots cleanly + Node-RED is accessible at http://localhost:1880
# Open Node-RED UI → confirm existing tabs load + no startup errors
```

If `make up` fails or Node-RED won't load — abort. Don't add new flow code on top of a broken local stack.

---

## Step 3 — The new tab (drop-in design)

Create `flows/Publish to edge.plc-normalized.json` (per-tab file convention; flow-manager dual-write reminder per session 64 zettel).

### Tab contents

```
[Tab: "Publish to edge.plc-normalized"]
  │
  ├── Inject (manual only)  ── trigger button for testing
  │       payload = { test sample } / {{equipment}} placeholder
  │
  ├── Link in (named "plc-normalized.in")  ── future PLC tab → here
  │
  └─→ [Function: "Build normalized envelope"]
        │
        └─→ [Function: "Publish to edge.plc-normalized"]
              │
              └─→ [HTTP Request: POST]
                    │
                    └─→ [Debug] + [Catch → error log]
```

### "Build normalized envelope" function (~30 LOC)

```js
// Builds a schema-v1.0 normalized payload envelope.
// Input:  msg.payload = { equipment_id, parameter, value, datatype, timestamp? }
// Output: msg.payload = full envelope ready for AMQP publish.

const tenant = env.get('CLIENT_TENANT_ID') || 'cpack';
const inst   = env.get('HOSTNAME') || 'edge-nodered-staging';

const eq = msg.payload && msg.payload.equipment_id;
if (typeof eq !== 'number') {
    node.warn('skipping — missing/invalid equipment_id');
    return null;  // drops msg, no downstream publish
}

const sourceTs = msg.payload.timestamp
    ? new Date(msg.payload.timestamp).toISOString().replace('Z','000Z')
    : new Date().toISOString().replace('Z','000Z');
const ingestTs = new Date().toISOString().replace('Z','000Z');
const msgId    = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);

msg.payload = {
    schema_version: '1.0',
    envelope: {
        tenant: tenant,
        source: { type: 'nodered', instance: inst, tab: 'Publish to edge.plc-normalized' },
        message_id: msgId,
        trace_id:   msgId,
        ordering_key: 'equipment_' + eq,
        ingested_at:      ingestTs,
        source_timestamp: sourceTs
    },
    type: 'plc.value',
    payload: {
        equipment_id: eq,
        parameter:    msg.payload.parameter || 'unknown',
        value:        msg.payload.value,
        datatype:     msg.payload.datatype || 'int64',
        quality:      'good'
    }
};

// Tenant comes from envelope, used in the publish step
msg._tenant = tenant;
return msg;
```

### "Publish to edge.plc-normalized" function (~15 LOC)

```js
const u = env.get('RABBITMQ_USER');
const p = env.get('RABBITMQ_PASSWORD');
const auth = Buffer.from(u + ':' + p).toString('base64');

const tenant = msg._tenant;
const envelope = msg.payload;  // built by previous node

msg.url = 'http://rabbitmq:15672/api/exchanges/%2F/edge.plc-normalized/publish';
msg.headers = {
    'Content-Type':  'application/json',
    'Authorization': 'Basic ' + auth
};
msg.payload = JSON.stringify({
    properties: { content_type: 'application/json', delivery_mode: 2 },
    routing_key: 'edge.plc-normalized.' + tenant,
    payload_encoding: 'string',
    payload: JSON.stringify(envelope)
});
msg.method = 'POST';
return msg;
```

### HTTP Request node config
- Method: POST (uses `msg.method`)
- URL: from `msg.url`
- Return: parsed JSON
- Use auth: false (header set explicitly in function)

### Inject node config (testing)
- Topic: empty
- Payload (JSON):
  ```json
  {"equipment_id": 84, "parameter": "counter_consumed", "value": 12345, "datatype": "int64"}
  ```
- Repeat: NONE (manual only — no scheduled triggers)

### Catch node
- Wires from any error in the above chain → debug + Loki log line with `level: error`

---

## Step 4 — Wiring into PLC tabs (Phase 2.5b)

The above tab is fully self-contained but doesn't auto-publish. To wire it to real PLC data:

For each PLC tab (`flows/PLCs.json`, `flows/Sparkplug.json`), add a **link out** node downstream of the PLC value extraction, named `plc-normalized.out`.

The existing tab's `Link in (plc-normalized.in)` will receive whatever the PLC tabs send.

Mapping from PLC msg structure to the envelope's `payload`:

| PLC source field | Envelope payload field | Notes |
|---|---|---|
| `msg.topic` (Sparkplug) | parse for equipment_id via packml_register lookup | Use existing topic→equipment helper |
| `msg.payload.value` | `value` | Direct copy |
| `msg.payload.timestamp` | `source_timestamp` | Use PLC ts if present |
| (computed) | `parameter` | Map from PackML param ID or tag name |

**Discipline reminder:** this wiring step modifies LIVE PLC flows. Test locally with the simulator before deploying. Per the lint rules: no function >200 LOC, no flow.set of big JSON, no http nodes in customization tabs.

---

## Step 5 — Verification after deploy

After PR merge + deploy completes:

```bash
# A. Container still healthy
docker ps | grep edge-nodered      # "(healthy)"
docker ps | grep edge-transformer  # "(healthy)"

# B. Manual trigger from Node-RED UI
# Open https://nodered.staging.packiot.app → click inject node → watch debug

# C. Confirm message reached edge-transformer
docker logs --since 60s edge-transformer | grep "shadow: received"
# Should see N entries, one per inject click

# D. Confirm queue is draining
docker exec stack-rabbitmq-1 rabbitmqctl list_queues name messages consumers \
  | grep edge-transformer-q-cpack
# Should show: edge-transformer-q-cpack <N> 1
```

---

## Step 6 — Rollback path (if it breaks edge-nodered)

If publish-tab additions break edge-nodered (PR #9 cascade lesson):

```bash
# Single-PR revert
gh pr create --title "revert: phase 2.5 publisher" --body "..." --base staging
gh pr merge --auto --squash
```

The tab is fully self-contained — no cross-tab dependencies in Step 3. The link-in nodes from Step 4 would orphan but not break.

For Step 4 specifically: keep wiring changes in a SECOND PR after Step 3 has been live for ≥24h. Catches any subtle interactions.

---

## Implementation rules (load-bearing — flow-manager + lint context)

1. **flow-manager dual-write rule**: every flow edit updates BOTH `flows.json` AND `flows/Publish to edge.plc-normalized.json`. Session-64 zettel `stateful-config-loaders-ignore-source-edits` is why.
2. **Lint compliance**: the two functions (~30 + ~15 LOC) are well under the 200 LOC limit. No `flow.set` of big JSON. No `http in` (we use `http request` out — different node type, not subject to the customization-tab rule, but the new tab is platform-owned regardless).
3. **NO scheduled inject**: the test inject is manual-only. Auto-publishing comes via Step 4 (link-in from PLC tabs), not via scheduled triggers in this tab.
4. **Env var defaults preserved**: function code uses `env.get('RABBITMQ_USER')` matching the existing Relay pattern. No new env vars needed (the container already has them).
5. **Idempotency-via-message_id**: the envelope's `message_id` is generated client-side per the schema. The Go service's dedup window (24h) catches retries.

---

## Effort estimate

| Step | Effort | Notes |
|---|---|---|
| Pre-flight checks | 10 min | |
| Local dev validation | 15 min | First `make up` may have rust |
| Write the new tab (Step 3) | 45 min | Node-RED UI work + tab JSON validation |
| Test publish + verify | 15 min | Per Step 5 |
| PR + merge + monitor | 30 min | Staging deploy + tail logs |
| Step 4 (wire to PLC tabs) | 1-2 hours | Per PLC tab; do as separate PR |

**Total to ship Step 3 (manual-publish proves the wiring): ~2 hours.**
**Total to ship Step 4 (auto-publish from PLC tabs): +2-4 hours, separate PR.**

---

## Open questions to settle before starting

1. **Where in the PLC tabs do we tap the message?** Need to confirm with the existing `flows/Sparkplug.json` author — there may be a natural "after value extraction" point or we may need to add the link-out at a specific node.
2. **`CLIENT_TENANT_ID` env var convention**: does this exist already (some other service uses it)? If not, we'll add it via Compose. Could also be derived from `client.yaml` if the Node-RED side starts loading that.
3. **Do operators care that publishes are visible in the Node-RED debug pane?** If yes, leave the debug node. If they consider it noise, comment it out.
4. **Should the publisher be feature-flagged for safe rollout?** E.g., `PUBLISH_TO_EDGE_TRANSFORMER=true` env var; if false, the function returns null. Recommended for the first deploy.

---

## Once this lands

Phase 2.5 done → edge-transformer is receiving real PLC events in shadow mode → Phase 3 (Calc Production Counters port per `docs/phase-3-calc-production-counters-port-plan.md`) becomes the next concrete step.
