# ADR-0010 Phase 4 — Migration plan: retire the Node-RED Sparkplug tab

**Status:** Prep doc — Phase 4 cannot start until Phase 3 comparator soak passes.
**Cross-references:**
- [ADR-0010](./adr/0010-sparkplug-decode-in-go-end-state.md) — the parent architectural decision
- [ADR-0008](./adr/0008-phase-2-comparator-split.md) — comparator validation pattern reused here
- [Phase 3 port plan](./phase-3-calc-production-counters-port-plan.md) — the prerequisite
- [ADR-0011](./adr/0011-durability-boundary-and-store-and-forward.md) — the durability rules Phase 4 must respect

---

## 1. Goal

At end of Phase 4, edge-transformer is the **sole** Sparkplug decoder + shadow publisher. Node-RED's SparkPlug subflow + Phase 2.5b publisher tab + `amqp-pub-oee-amqplib` are all retired. The Node-RED footprint shrinks to per-customer customization tabs only.

This is the payoff cutover of ADR-0010. It's a substantial architectural shift, so this doc lays out the sequence + gates + rollback path.

---

## 2. Prerequisites (block Phase 4 start)

Phase 4 CANNOT begin until all of the following are true. If any is false, the cutover WILL cause silent data loss.

| Prerequisite | Status | Owner |
|---|---|---|
| Phase 3 port shipped: `calc_production_counters.Calc()` returns real Decisions | 🔴 scaffold only (PR TBD) | edge-transformer |
| Phase 3 comparator running side-by-side in staging for ≥30 days | 🔴 not started | edge-transformer + comparator |
| Comparator's zero-diff rate ≥99.99% over the soak window | 🔴 pending | ADR-0008 comparator |
| ADR-0011 P2 outbox wired into main.go (not just scaffold) | 🟡 scaffold shipped in PR #131 | edge-transformer |
| ADR-0011 P0-4 aggregated /healthz has an `outbox_depth` degraded threshold | 🔴 pending | edge-transformer |
| At least one downstream consumer tab in Node-RED confirmed to work from the AMQP-consumer replacement | 🔴 pending | customer-specific |
| Backward-compat AMQP-consumer flow in Node-RED lets customer tabs still access Sparkplug data | 🔴 pending | edge-nodered |

The last two rows are the customer-facing risk. Customer tabs that read `msg.payload.metrics` from the SparkPlug subflow will break the moment the subflow is deleted. Phase 4 MUST provide a compatible replacement path.

---

## 3. Migration sequence

Each step in the sequence has a documented rollback point. If an unexpected failure appears at any step, we halt the cutover and go back to the last stable point — never forward-fix under uncertainty.

### Step 4.1 — Land the outbox wiring PR

Wire ADR-0011 P2's `internal/outbox/` into main.go: MQTT Handler → outbox.Enqueue → drain goroutine → shadowpub.Publish + confirms + retry-on-nack. Prometheus metrics for `outbox_depth`, `outbox_oldest_age_seconds`, `outbox_drain_success/failure_total`. Extend the `MultiSnapshotter` degraded-state check with `outbox_depth > 500MB` and `oldest_age > 30s`.

**Gate**: 24-hour staging soak. Publish rate stays at 100% of MQTT ingest rate (no unaccounted-for drops), outbox depth stays near zero (drain keeps up), no `outbox_degraded` events in Grafana.

**Rollback**: Revert the wiring PR. edge-transformer falls back to the current MQTT-Handler → shadowpub direct-publish path (still uses publisher confirms per ADR-0011 P0-1). Outbox package stays checked in but unused.

### Step 4.2 — Ship the Phase 3 port

Land the actual `calc_production_counters.Calc()` implementation. Comparator (ADR-0008 shape, adapted for the transformer-side) runs both the Go port and the Node-RED path in parallel. Every message is decoded by BOTH, and the comparator diffs the outputs at the `edge.plc-normalized.<tenant>` exchange.

**Gate**: 30-day zero-diff soak. Comparator's `oee_divergence_pct` must be ≤0.01% averaged over the window, with no single 5-min window exceeding 0.1%.

**Rollback**: The Go port ships behind a `USE_GO_PORT=false` env flag. If soak fails, flip the flag off and continue running Node-RED. Comparator stays on to keep the diff visible.

### Step 4.3 — Add the AMQP-consumer replacement in Node-RED

Before removing the SparkPlug subflow, add a NEW Node-RED tab that consumes from `edge.plc-normalized.<tenant>` (the same exchange edge-transformer publishes to) and emits messages in the SAME shape the SparkPlug subflow used to. Customer tabs that read `msg.payload.metrics` see the same data structure, just via AMQP instead of MQTT.

This is the compat shim ADR-0010 open question 4 flagged.

**Gate**: 7-day soak on staging with the shim active but the SparkPlug subflow ALSO still active. Customer tabs receive the SAME messages from both paths; the comparator confirms no divergence. No customer complaint.

**Rollback**: Just delete the shim tab. Zero impact on existing paths.

### Step 4.4 — Flip customer tabs to consume from the shim

For each customer's customization tab, retarget its input from the SparkPlug subflow output to the shim's output. This is a per-customer, per-tab change, done as small independent PRs to the edge-nodered repo. Each PR:
- Retargets ONE tab's input to the shim
- Doesn't touch the SparkPlug subflow
- Ships to that customer's staging first, then production
- Includes screenshots of before/after debug pane output showing identical messages

Roll each customer separately over ~2-4 weeks. NOT a big-bang cutover.

**Gate per customer**: 48-hour production soak on the retargeted tab. Downtime + OEE metrics stay within 0.5% of baseline.

**Rollback per customer**: Revert the per-tab PR. Tab is back on SparkPlug subflow's output.

### Step 4.5 — Retire the SparkPlug subflow + Phase 2.5b publisher tab

Once ALL customer tabs are on the shim, the SparkPlug subflow + Phase 2.5b publisher have no downstream. Delete them in a single "big cleanup" PR to edge-nodered:
- Delete `flows/Sparkplug.json`
- Delete `subflows/SparkPlug_v1.10.39.1.json`
- Delete the `Publish to edge.plc-normalized` tab
- Delete the `amqp-pub-oee-amqplib` chain
- Remove `node-red-contrib-sparkplug-payload` from `package.json`

**Gate**: 24-hour staging soak. edge-transformer is the sole publisher; edge.plc-normalized traffic stays at the same rate; RabbitMQ queue drains at the same rate; no degraded /healthz events.

**Rollback**: Revert the cleanup PR. Everything comes back. Ugly but guaranteed working.

### Step 4.6 — Retire the Node-RED-side comparator

Once cutover is stable for 7 days, retire the ADR-0008 comparator's Node-RED-vs-Go diff panels (there's only one path now — nothing to diff). Keep the comparator infrastructure intact for future ADR-0008 needs (e.g., prod-vs-staging fidelity checks).

**Gate**: Comparator's diff rate stays at 0 for 7 days post-cutover (nothing to compare because Node-RED path is gone). No degraded events.

---

## 4. Data quality gates (must hold throughout)

The following invariants must be true at all times during Phase 4:

1. **No customer sees stale data.** OEE math depends on continuous PLC data ingestion. Each customer's dashboards must show ≤1-minute lag throughout the cutover. Grafana alert threshold: `up{job="customer_dashboard"} == 1` AND `dashboard_lag_seconds < 60`.

2. **No customer sees duplicated data.** During the shim-active + subflow-active overlap window (step 4.3), customer tabs receive messages from BOTH paths. The shim's output shape must be IDENTICAL to the subflow's so duplicate detection works. If a customer sees duplicate downtime events or double-counted production, halt cutover.

3. **No silent data loss.** ADR-0011 rules apply: every failure mode must fire a metric or log line. If /healthz stays at `healthy=true` while data drops, it's a bug regardless of what data it drops.

4. **Comparator diff rate stays low.** Any spike in `oee_divergence_pct > 0.1%` over a 5-minute window halts the cutover until root-caused.

---

## 5. Total timeline estimate

Sequential with soak windows:

| Step | Duration |
|---|---|
| 4.1 Outbox wiring | ~1 week (code) + 1 day (staging soak) |
| 4.2 Phase 3 port + soak | ~3-4 weeks (code) + 30 days (soak) |
| 4.3 AMQP-consumer shim in Node-RED | ~3 days (code) + 7 days (soak) |
| 4.4 Per-customer tab flip | ~2-4 weeks (all customers) |
| 4.5 SparkPlug subflow retirement | ~1 day (code) + 1 day (staging soak) |
| 4.6 Comparator retirement | ~1 day |
| **Total calendar time** | **~10-12 weeks** including all soaks |
| **Total engineer time** | **~5-7 weeks** focused work |

This is the ADR-0010 payoff investment. Attempting to compress the timeline WILL cause silent data loss — the soak windows exist because that's the length of time it takes to detect the class of divergence that matters.

---

## 6. What Phase 4 does NOT do

Not in scope:
- **Deleting the Sparkplug protobuf vendoring.** The `.proto` + generated bindings stay because edge-transformer needs them. This ADR is about the Node-RED footprint, not the Go footprint.
- **Changing the AMQP topology at RabbitMQ.** Exchanges + queues stay as they are. Only the Node-RED-side publisher goes away.
- **Migrating other customer-specific transforms** (Calc_Counters (Alt) variants, etc.). Those are separate PRs following the same Phase 3 pattern — one function per PR, comparator-validated for 30 days each.

---

## 7. Failure modes to watch for

Based on lessons from mirror-worker-go's cutover pattern (see `[[sole-writer-invariant-chain-hazard]]`):

1. **Silent chain break** — the SparkPlug subflow's output is consumed by more than the obvious customer tabs. Grep flows.json + subflows/ for `link out` nodes that reference the SparkPlug output before retiring it. Anything missed will break silently.

2. **Shim latency drift** — the AMQP-consumer shim adds RMQ round-trip latency (~5-20ms) that the direct MQTT path didn't have. Downstream customer tabs that assume synchronous message arrival may see subtle timing shifts. Test with per-customer synthetic burst before per-tab cutover.

3. **Multi-tenant cross-talk** — the shim publishes on `edge.plc-normalized.<tenant>` per-tenant, but if a customer tab subscribes to the wrong tenant's queue (config drift), they'll see other tenants' data. Grep customer configs for hardcoded tenant strings before cutover.

4. **Retained NBIRTH desync** — after cutover, edge-transformer's alias table starts empty and rebuilds from live NBIRTHs. During the ~few-minute rebuild window, some NDATA may return `ErrNoBirth`. Ensure the outbox retries handle this transient class of error correctly (retry with backoff, don't DLQ).

5. **The tenant-specific customization tabs may have DIFFERENT counter-sums than the Go port.** ADR-0008 comparator catches this at scale, but individual customer tabs may have per-customer patches that the standard port doesn't replicate. Section 4.4's per-customer soak is where this surfaces.

---

## 8. Open questions

These block the start of Phase 4 and should be resolved during Phase 3:

1. **Which comparator boundary?** ADR-0008's comparator compares outputs at the RMQ boundary (both paths produce a message; comparator diffs). But the Node-RED path today doesn't emit through the same shape as the Go port's shadow publisher. Are we adding a translation shim, or is the comparator smart enough to handle the two shapes?

2. **What's the escape hatch for customers with heavy patches?** If a customer's tab has patched Calc_Counters heavily (fixing site-specific bugs), the Go port might not replicate their patches. Do we make patches configurable in `client.yaml`, or accept per-customer forks of the Go port?

3. **When does the shim retire?** After all customers are on it (obvious), OR after we've retired ALL Node-RED customization consumption of Sparkplug data (further future)? If the latter, the shim lives indefinitely.

4. **What happens to Phase 2.5b's `equipment_id` inline const?** The Phase 3 port needs to resolve metric names to equipment IDs. Today's inline const has 42 entries; production probably has 800+ per factory. Where does the packml_register-driven lookup land — in the Go port itself, or as a shared internal package?

---

## 9. Success criteria

Phase 4 is complete when:

- edge-nodered's `subflows/SparkPlug_v1.10.39.1.json` is deleted
- edge-transformer is the sole publisher to `edge.plc-normalized`
- All customer dashboards show OEE metrics with ≤0.5% variance vs pre-cutover
- No customer has filed an incident related to the cutover
- ADR-0010 status changes from "Proposed" to "Accepted"

At that point, the ADR-0010 "heavy lifting in code, customization in low-code" thesis has been proven end-to-end.
