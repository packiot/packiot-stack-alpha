# ADR-0053 — On-prem ingest edge (relocate the pre-RabbitMQ stack to the box)

- **Status:** Proposed — REDIRECTED by proof: mTLS/8883 uplink is firewall-blocked for HTTPS-only factories (bispharma); use the HTTPS path (raw-level reader spool already ships; decoded-level needs a new HTTPS ingress)
- **Date:** 2026-09-01
- **Relates:** ADR-0011 P2 (the SQLite outbox), ADR-0045 (thin-reader shared-ingest),
  ADR-0019 C3 (edge-operator SPA), ADR-0052 (edge autonomy — device side), the
  reader store-and-forward spool, the `ingest-shim` (HTTPS→RabbitMQ ingress)
- **Deciders:** (pending)

> Every claim below is grounded in the live system, not assumption — the proof is
> inline. The core realization: the buffer this design needs **already exists and
> is tested**; what changes is *where the ingest stack runs*.

---

## 1. Context & the idea

Today (ADR-0045) the factory box is a **thin reader**: it polls PLCs and POSTs raw
counts to a **cloud** agent; agent → mosquitto → edge-transformer(decode) →
RabbitMQ → worker → DB all run in the cloud. The only outage protection on the box
is the reader spool, which buffers **raw HTTP batches** only.

**The idea (this ADR):** move the **pre-RabbitMQ** portion of the pipeline —
agent + mosquitto + edge-transformer, *with its on-disk outbox* — **onto the
factory box**. The internet crossing shifts from "reader → cloud agent (HTTP)" to
"box outbox → cloud RabbitMQ ingress." During an internet outage the on-box stack
keeps ingesting **and decoding**, buffers the decoded stream locally, and drains —
in order, crash-consistently — when the link returns. This is an **on-prem ingest
edge**: everything up to the message bus runs on-site; the bus and everything
after it stay in the cloud.

## 2. Proof the hard parts already exist / are feasible

| Question | Proof | Verdict |
|---|---|---|
| Is there a durable store-and-forward *before RabbitMQ* to buffer an outage? | `internal/outbox/outbox.go` (ADR-0011 P2): "local disk-persistent queue **between MQTT ingestion and downstream RabbitMQ publish**… decode → write outbox FIRST → drain goroutine publishes with confirms → delete on confirm, retry on failure… crash-consistent." **SQLite** (modernc, pure-Go, WAL), FIFO, bounded (drop-oldest). Tested (`outbox_test.go`). Uplink reuses it: buffer on broker-down, **rebirth-before-drain** on reconnect. | **exists + tested** — this *is* the "sqlite before RabbitMQ" |
| Can the box run our ingest images? | `mi-0114` = **x86_64/amd64**, Docker 29.7.2, 4 CPUs; it already runs the reader container. Our agent/transformer are pure-Go **amd64** binaries (same as the cloud app box). | **yes** — same arch, Docker present |
| Can the box reach cloud RabbitMQ without exposing AMQP? | `ingest-shim` — "HTTPS→RabbitMQ ingress… **RabbitMQ stays internal (no public AMQP port)**… the shim is the only public surface (X-Ingest-Key auth, publisher-confirm, 202-on-durable-accept)"; **Incoplast's on-prem Node-RED already POSTs SparkPlug-JSON to it over the public internet** onto the `oee` exchange the worker consumes. | **yes** — via the existing HTTPS shim, not raw AMQP |
| Is the drain transport swappable (AMQP today → HTTPS shim on the edge)? | outbox drain uses a `publishFn` abstraction ("abstracts the transport so rebirth-then-drain is unit-testable"). | **yes** — pluggable |

**Notably, a partial version already runs in production:** Incoplast generates
SparkPlug on-prem and POSTs to the shim. This ADR *generalizes* that — ship **our**
agent+transformer+outbox on-prem instead of a client's bespoke Node-RED.


## 2a. GATING CONSTRAINT (proven live) — factory egress is HTTPS-only

Before building the mTLS uplink, I tested outbound egress **from the bispharma
factory box** (`mi-0114`, LAN `192.168.5.91`):

| Target | Result |
|---|---|
| `ingest.prod:8883`, `ingest.staging:8883`, `8.8.8.8:8883` (MQTT/TLS) | **BLOCKED** (all three, identically) |
| `ingest.staging:8449` (reader HTTPS path) | OPEN |
| `:443` | OPEN |

**The factory firewall blocks outbound 8883.** Therefore the agent-on-box →
`ssl://ingest:8883` MQTT uplink — the natural way to reuse the agent's outbox —
**is not viable for bispharma** (nor any factory with the same egress policy;
CPACK's firewall *does* allow 8883, which is why its edge works). Any on-prem edge
here **must cross the internet over HTTPS.** This is a per-site network fact to
verify FIRST for every candidate box — it decides the whole transport.

**Consequence for this ADR:** the outbox's store-and-forward is still the right
buffer, but its drain must be **HTTPS**, not AMQP/MQTT. Two HTTPS realizations:

1. **Raw-tags level — ALREADY SHIPPED.** The reader spool (this session) buffers
   raw-tag batches on the box and replays them over HTTPS (8449) to the cloud
   shared-agent on reconnect. For an HTTPS-only factory this **already is** the
   on-prem outage buffer — just at the pre-decode level.
2. **Decoded level — needs a new cloud HTTPS ingress.** To buffer *decoded* data
   on-box (agent+transformer+outbox on the box), the outbox must drain over HTTPS
   to a cloud ingress that accepts the agent/transformer output. The existing
   `ingest-shim` accepts SparkPlug-**JSON** → `oee` → worker (Incoplast's
   pipeline), which is a *different* format than our agent's SparkPlug-B →
   mosquitto → decoder. So this path needs either (a) an HTTPS→mosquitto ingress
   for SparkPlug-B, or (b) the on-box transformer to emit the shim's JSON format.
   Neither exists — it is a real sub-build, not a config.

## 3. Architecture

```
FACTORY BOX (on-prem, amd64 + Docker)          CLOUD
┌──────────────────────────────────────┐      ┌───────────────────────────────┐
│ reader → agent (SparkPlug encode)     │      │ ingest-shim (HTTPS, X-Ingest-  │
│   → mosquitto → edge-transformer      │      │   Key, publisher-confirm)      │
│       (decode)                        │ HTTPS│   → RabbitMQ (oee exchange)    │
│       → OUTBOX (SQLite, FIFO,         │─────▶│   → worker/stream-engine       │
│         crash-consistent)             │ POST │   → equipment_values / OEE     │
│       drain on reconnect, in order    │      │   → refdata / dashboards       │
└──────────────────────────────────────┘      └───────────────────────────────┘
     outage: outbox retains decoded              (RabbitMQ never public)
     stream; drains when link returns
```

## 4. What it delivers vs. what it does not

**Delivers (proven mechanism):**
- **Data-plane outage durability, done right** — not raw HTTP batches (the reader
  spool) but a **decoded, seq/alias-correct SparkPlug stream** that drains in FIFO
  order with publisher confirms. No loss up to outbox capacity; crash-consistent.
- A **foundation for offline reads** — with decode happening on-box, a local read
  layer/DB can serve last-known state from on-prem data (the ADR-0019 C3 need).
- **Reuses the shim** — the public ingress + auth + confirm path already exists and
  is battle-tested by Incoplast.

**Does NOT deliver (be honest, per the ADR-0052 lesson):**
- **Offline reads/OEE by itself.** Dashboards + current-PO reads come from
  `equipment_values`/refdata *after* RabbitMQ (cloud). Local reads still need a
  local DB + refdata on the box — a separate build (ADR-0019 C3's local-read
  layer). This ADR gives the *durable capture* half; not the *serve* half.
- **A thin edge.** It re-fattens the box (agent + mosquitto + transformer + outbox)
  — the exact weight ADR-0045 shed. Same images, box already runs Docker, but it's
  more to deploy/upgrade/monitor on-site.
- **Unbounded buffering.** The outbox is FIFO drop-oldest; a multi-day outage past
  capacity drops oldest. Size it per the client's worst-case outage.

## 5. Relationship to the other pieces (so we don't duplicate)

- **Supersedes the reader spool** for any box we make fat — the outbox is the
  principled version (decoded, ordered, confirmed) of the same store-and-forward.
- **Complements ADR-0019 C3** — C3 puts the *operator SPA* on the edge; this puts
  the *ingest/decode stack* on the edge. Together they are the full on-prem edge.
- **Unrelated to C1** (the PLC command downlink). Outage durability is a *data-
  plane* concern; C1 is a *control-to-PLC* concern. This ADR is the right lever.
- **Generalizes the Incoplast shim pattern** from a bespoke client Node-RED to our
  standard generated edge bundle.

## 6. Feasibility deltas to build (not the buffer — that's done)

1. **Package an on-prem edge bundle** — agent + mosquitto + edge-transformer as a
   box compose profile (the generator already emits the reader bundle; extend it).
2. **Point the outbox drain at the shim** — swap the drain `publishFn` to an
   HTTPS→ingest-shim publisher (X-Ingest-Key, confirm-on-202) for the edge profile;
   keep AMQP for the cloud profile. One transport, config-selected.
3. **Size + monitor the outbox** — capacity per client outage profile; surface
   depth/age as a health signal (the "make absence legible" rule).
4. **(Optional, for offline reads)** a local read layer/DB — defer to ADR-0019 C3.

## 7. Open questions

1. Which clients' outage profile justifies the fatter edge (vs the reader spool)?
   Per-client, like ADR-0019 C3 — not a default.
2. Outbox sizing: worst-case outage duration × message rate → disk budget.
3. Do we run mosquitto on-box, or can the agent write to the transformer's outbox
   in-process (drop a hop)? — a simplification worth prototyping.
4. Security review of the shim as the per-box ingress (key rotation, per-box scope)
   — it's already the public surface for Incoplast; extend the model deliberately.

## 8. Recommendation

Sound and mostly-built: the **buffer exists (SQLite outbox), the box runs the
images (amd64+Docker), and the internet ingress exists (HTTPS shim, in production
for Incoplast)**. The delta is *packaging + a drain-transport swap*, not new
plumbing. Pursue it **design-first and per-client** — it's the right, principled
answer to internet-outage *data* durability, and the foundation for offline reads
when a client needs them. Prototype on the bispharma box (amd64, already ours)
behind a flag before any client default.
