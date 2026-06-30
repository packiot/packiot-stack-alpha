# edge-transformer Phase 2 — Ready-to-Go Runbook

**Purpose:** A concrete, copy-paste runbook for executing Phase 2 of ADR-0009 once the user-only prerequisites are done. Eliminates ambiguity at execution time.

**Status:** Awaiting prerequisites (see Section 1).

**Cross-references:**
- [ADR-0009](./adr/0009-edge-transformer-go-service-and-nodered-split.md) — architectural rationale
- [edge-nodered-repo-refactor.md](./edge-nodered-repo-refactor.md) — operational companion
- [_normalized-payload-schema.yaml](./clients/_normalized-payload-schema.yaml) — the contract Node-RED publishes / Go consumes

---

## 1. Prerequisites (USER ACTIONS — Phase 2 blocked until done)

| Task | Who | Status | Notes |
|---|---|---|---|
| Rotate leaked Firebase API key | User | ☐ | `AIzaSyCRK02fBbgho-VSQrjt5bIZzzVdoIgpRGo` was in `transform_flows.py` history; rotate in Firebase console + update AWS Secrets Manager (staging + prod) |
| Provision `packiot/staging/rabbitmq-edge-transformer-creds` secret | User | ☐ | Two-key JSON: `{username, password}`. See Section 2.A. |
| Provision RabbitMQ user `edge-transformer` with least-priv perms | User | ☐ | See Section 2.B for exact regex grants. |
| Review + merge PRs #101, #103, #105 (parent) + #8, #9, #10, #11, #12 (nodered) | User | ☐ | All planning + cleanup artifacts. Phase 2 builds on these. |

---

## 2. AWS provisioning details

### 2.A — Secret structure

Create the secret using the proven `jq --arg` pattern (avoids the shell-escape traps documented in zettel `secrets-manager-pat-shell-escape-traps`):

```bash
read -s -p "RMQ password for edge-transformer: " RMQ_PASS && echo
jq -cn \
  --arg u "edge-transformer" \
  --arg p "$RMQ_PASS" \
  '{username: $u, password: $p}' > /tmp/et.json

aws secretsmanager create-secret \
  --name packiot/staging/rabbitmq-edge-transformer-creds \
  --region us-east-1 \
  --secret-string file:///tmp/et.json \
  --query ARN --output text

shred -u /tmp/et.json && unset RMQ_PASS
```

Verify:

```bash
aws secretsmanager get-secret-value \
  --secret-id packiot/staging/rabbitmq-edge-transformer-creds \
  --region us-east-1 --query SecretString --output text | jq -r 'keys'
# expected: ["password","username"]
```

### 2.B — RabbitMQ user with least-priv

On the staging RabbitMQ management UI (or via `rabbitmqctl`):

```bash
# Create user with the same password as the AWS secret
rabbitmqctl add_user edge-transformer "<password-from-secret>"
rabbitmqctl set_user_tags edge-transformer service  # custom tag for audit

# Vhost: assume /
rabbitmqctl set_permissions -p / edge-transformer \
  '^(edge-transformer\..*|outbox\..*)$' \
  '^(edge-transformer\..*|outbox\..*|edge\.plc-normalized)$' \
  '^(edge\.plc-normalized|edge-transformer\..*|outbox\..*)$'

# Verify
rabbitmqctl list_permissions -p /
```

The permission triple is `configure | write | read` — the regex restricts edge-transformer to:
- **Configure** its own queues (`edge-transformer.*`) + outbox queues (`outbox.*`)
- **Write** to the shared `edge.plc-normalized` exchange + its own outbox queues + own queues (for republishing during retry)
- **Read** from `edge.plc-normalized` + its own queues + outbox

It CANNOT touch other tenants' queues, the management API, or other exchanges. Bounded blast radius.

---

## 3. Code execution sequence

Once Section 1 + 2 are complete, the actual code work is small. Five steps, each a separate PR.

### Step 3.1 — Uncomment edge-transformer in compose.staging.yml

The block was added (commented) in PR #103. Uncomment + push:

```bash
cd /home/podesta/github/packiot/packiot-stack-alpha
git checkout staging && git pull
git checkout -b feat/edge-transformer-wire-up

# Find the commented block:
grep -n "edge-transformer" compose.staging.yml
# Manually uncomment the block. Verify with:
docker compose -f compose.staging.yml config --quiet

git add compose.staging.yml
git commit -m "feat(compose): wire edge-transformer service (ADR-0009 Phase 2.1)"
git push -u origin feat/edge-transformer-wire-up
gh pr create --base staging --title "..." --body "..."
```

**Expected outcome:** PR opens; CI passes; merge triggers staging deploy; edge-transformer container boots in shadow mode (logs `oeecloud-worker starting` then health-server idle on `:9102`). No PLC traffic yet because the publisher side isn't wired.

### Step 3.2 — Declare the RabbitMQ topology (Terraform OR manual)

The exchange `edge.plc-normalized` + per-tenant DLX `dlx.edge.plc-normalized` need to exist before publishers / consumers start. Two options:

**Option A — Terraform-managed (preferred):** add to `terraform/staging/rabbitmq.tf`:

```hcl
resource "rabbitmq_exchange" "plc_normalized" {
  name  = "edge.plc-normalized"
  vhost = "/"
  settings {
    type        = "topic"
    durable     = true
    auto_delete = false
  }
}

resource "rabbitmq_exchange" "plc_normalized_dlx" {
  name  = "dlx.edge.plc-normalized"
  vhost = "/"
  settings {
    type        = "topic"
    durable     = true
    auto_delete = false
  }
}
```

`terraform apply` in the staging workspace.

**Option B — Manual (if Terraform RabbitMQ provider isn't set up):** via management UI or `rabbitmqadmin declare exchange ...`. Document in a runbook follow-up.

### Step 3.3 — Add Node-RED publisher flow

Build a new tab `RabbitMQPublish` in `edge-node-red` that:
1. Receives via `link in` nodes from `flows/PLCs.json` + `flows/Sparkplug.json`
2. Wraps the message in the normalized envelope (per `_normalized-payload-schema.yaml v1.0`)
3. Publishes to `edge.plc-normalized` with routing key `plc.normalized.<tenant>.equipment.<id>`
4. Starts DISABLED by default; enable per-tenant via env flag for safe rollout

**Sketch of the envelope-builder function node (~30 LOC):**

```js
const { ulid } = global.get('ulid') || { ulid: () => Date.now().toString(36) + Math.random().toString(36).slice(2,10) };

const equipmentId = msg.equipment_id || msg.payload?.equipment_id;
if (!equipmentId) {
    node.warn('cannot publish — missing equipment_id');
    return null;
}

const tenant = env.get('CLIENT_TENANT_ID') || 'unknown';

msg.payload = {
    schema_version: '1.0',
    envelope: {
        tenant,
        source: {
            type: 'nodered',
            instance: env.get('HOSTNAME') || 'unknown',
            tab: msg._sourceTab || 'unknown'
        },
        message_id: ulid(),
        trace_id: msg.trace_id || ulid(),
        ordering_key: `equipment_${equipmentId}`,
        ingested_at: new Date().toISOString(),
        source_timestamp: msg.source_timestamp || new Date().toISOString()
    },
    type: msg.payloadType || 'plc.value',
    payload: msg.payload
};

// Routing key for the topic exchange
msg.topic = `plc.normalized.${tenant}.equipment.${equipmentId}`;

return msg;
```

Wired into `node-red-contrib-amqp` (added to package.json).

### Step 3.4 — Verify end-to-end shadow

After steps 3.1-3.3 are deployed to staging:

```bash
# 1. Verify the exchange exists
ssh staging-app-ec2
docker exec stack-rabbitmq-1 rabbitmqctl list_exchanges name type | grep edge.plc-normalized

# 2. Verify edge-transformer queue is bound
docker exec stack-rabbitmq-1 rabbitmqctl list_bindings | grep edge-transformer

# 3. Watch edge-transformer logs for incoming messages
docker logs -f edge-transformer 2>&1 | grep -E "shadow|message received|tenant"

# 4. Trigger a test publish from Node-RED (use the inject node we'll add for testing)
# Expected: log line "shadow: received message from tenant=cpack, type=plc.value, msg_id=..."
```

**Success criteria for Phase 2:**
- All 5 payload types observed in shadow logs over a 1-hour window
- Zero ACK failures
- Per-tenant Prometheus metrics visible at `:9102/metrics` (verify with `curl :9102/metrics | grep tenant=`)
- No DLX entries (shadow doesn't fail)

### Step 3.5 — Document the new operational shape

Update `services/edge-transformer/README.md` with:
- The actual deployed URL / IP allocation
- Grafana dashboard link (when added)
- Runbook: "what to do if the queue depth grows"

---

## 4. Phase 1 closeout — known deferrals + rationale

For completeness, here's what was DELIBERATELY left out of Phase 1, with rationale (so future engineers don't redo this analysis):

### Deferral 4.1 — Move `hasura/metadata.json` out of `edge-node-red`

**Original recommendation:** move to `packiot-stack-alpha` because "Hasura metadata isn't edge-nodered's concern."

**Reversal after live-state analysis (2026-06-30):** keep it in `edge-node-red` for now. Reasons:

1. **Actual usage:** parent's `compose.staging.yml` line 157 mounts `./edge-node-red/hasura/metadata.json:/metadata.json:ro`. The file is owned by the submodule, imported by the parent. Moving it inverts the ownership but doesn't reduce coupling.
2. **Coupling reality:** the metadata describes the schema Hasura serves, which is the same schema `edge-node-red`'s (now-disappearing-in-Phase-4) GraphQL tab queries. They ARE genuinely coupled during the transition window.
3. **Dev-workflow cost:** moving means `edge-node-red`'s `compose.dev.yml` either depends on the parent being checked out at a known path (fragile), or local-copies the file (defeats the purpose).
4. **Cost > benefit right now.** Keep file in place. Revisit after Phase 4 (when GraphQL tab is removed and the coupling argument finally goes away).

This contradicts Inconsistency #3 in [edge-nodered-repo-refactor.md](./edge-nodered-repo-refactor.md); that section's recommendation is now **superseded** by the rationale above.

### Deferral 4.2 — Add `node-red-flow-manager` removal

The session-64 zettel `stateful-config-loaders-ignore-source-edits` documents the pain of node-red-flow-manager. ADR-0009 contains a rule that flow edits must update both files until flow-manager is removed. Actually REMOVING it is in scope for the long term but not for Phase 2 — too disruptive to the dev workflow + the per-tab files are baked into the deploy pipeline.

### Deferral 4.3 — Lint-flows.js `ignore` marker mechanism

The lint script (PR #8) doesn't yet honor `// lint-flows: ignore <rule-id>` markers. Documented as v2 feature in `docs/governance-rules.md`. Add the marker mechanism the first time a legitimate exception is needed, not preemptively.

---

## 5. Things that are NOT Phase 2 (defer to Phase 3+)

These are out of scope for Phase 2's "shadow mode goes live" goal:

- **Calc_Counters port to Go** (Phase 3) — biggest single value driver but biggest scope. Each Calc_Counters function needs ADR-0008 comparator validation. Plan: pick the smallest variant first, port it, run comparator for ≥7 days, then flip. Repeat for each.
- **Migrating the 20 HTTP endpoints from API tab** (Phase 4) — depends on either eliminating endpoints (operator SPA calls cloud directly) or moving them into edge-transformer's HTTP server.
- **Customization governance + onboarding doc** (Phase 5) — depends on having ≥1 real Phase 3-ported transform in Go to point to as "this is how it looks."

---

## 6. Open questions deferred to execution time

These don't need answering now, but flag them when execution begins:

- **Is staging RabbitMQ on a per-tenant vhost basis, or shared /?** If per-tenant, Section 2.B's permissions need adjustment.
- **Where does the edge-transformer publish its outbound HTTP results — directly to cloud-api or via the cloud edge-api proxy (per ADR-0007)?** ADR-0007 is deferred; for Phase 2, edge-transformer can call cloud edge-api directly.
- **Does the staging Grafana already have a per-service pattern we should follow?** Reuse the oeecloud-worker / mirror-worker-go panel layout when adding edge-transformer panels.
- **Should the publisher flow be enabled per-tenant or globally?** Recommendation: per-tenant via an env flag, so we can canary on one customer before opening it up.

---

## 7. Acceptance criteria — when is Phase 2 done?

Phase 2 is complete when ALL of these are true:

- [ ] All prerequisites in Section 1 done (secret, RMQ user, all PRs merged)
- [ ] edge-transformer container running healthy in staging (`docker ps` shows `(healthy)`)
- [ ] RabbitMQ exchange `edge.plc-normalized` declared + edge-transformer queue bound
- [ ] Node-RED publisher flow deployed + enabled for ≥1 tenant
- [ ] Shadow logs show all 5 payload types received from at least one tenant
- [ ] Per-tenant Prometheus metrics visible at `:9102/metrics`
- [ ] No entries in `dlx.edge.plc-normalized` after 1-hour observation window
- [ ] Grafana dashboard for edge-transformer added (mirror oeecloud-worker layout)
- [ ] `services/edge-transformer/README.md` updated with deployed state + runbook links

Once all checked, ADR-0009 status moves from "Phase 2 in-progress" to "Phase 3 ready." The next session opens by selecting the first Calc_Counters function to port.
