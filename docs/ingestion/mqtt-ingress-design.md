# ADR-0032 Path B — Faithful "direct-from-PLC" public TLS MQTT ingress

**Status:** DESIGN / PROPOSAL — not applied, no live infra change, public port NOT opened
**Date:** 2026-07-21 · **Scope:** STAGING ONLY (prod untouched; every prod-touching step is gated)
**Author:** infra+ingestion architect · **Decision owner:** tech-lead → USER sign-off before any execution

**Relates to:** [ADR-0032](../adr/0032-collapse-to-single-flow-f3.md) (single-flow F3 collapse) ·
[ADR-0010](../adr/0010-sparkplug-decode-in-go-end-state.md) (Go decode + Calc port) ·
[ADR-0011](../adr/0011-durability-boundary-and-store-and-forward.md) (MQTT subscriber hardening) ·
[ADR-0019](../adr/0019-edge-customization-capabilities.md) C1 (edge command / DCMD write path — the reason a shared public broker is dangerous).

---

## 0. TL;DR

The HTTPS `ingest-shim` (Incoplast live, CPACK #541 merged) gets real factory data into F3, but it
**republishes the customer's already-decoded SparkPlug-JSON straight onto the `oee` exchange, bypassing
`edge-transformer` entirely.** That means the Go **Calc** never runs on shim traffic — the
Calc-derived signals (`MachSpeed`, `Parameter30700` line-machine CSV, threshold/glitch logic, the
delta+cumulative counter shape from `CALC_CUTOVER_REFACTORED`) are **not prod-faithful** for any tenant on
the shim. That is the "un-blessed Calc gap" behind Incoplast's `OEE=0` / `status_type=0` symptoms.

**Path B** closes the gap by letting a factory's Node-RED publish SparkPlug B **directly to
`edge-transformer`'s MQTT decode→StateStore→Calc→triple-emit path** — the *exact* path `plc-sim` uses —
over a **public, TLS-secured, per-tenant-authenticated MQTT broker**.

**Recommended topology:** a **separate edge-facing Mosquitto broker (`mqtt-ingress`) with a native TLS
listener on 8883, per-tenant mTLS + topic ACLs, one-way MQTT-bridging inbound `spBv1.0/#` DATA topics into
the existing internal broker.** `edge-transformer` is unchanged.

**The load-bearing open question (for USER):** the internal decode path consumes **binary protobuf
SparkPlug B** (with retained NBIRTH alias establishment). The shim tee taps the **JSON** form. So Path B
requires the customer Node-RED to emit **protobuf** — which their PLCs/flows may or may not be able to do at
the tee seam. See §5 + §8-Q1. If they can only produce JSON, we recommend variant **B2** (a JSON→Calc
ingress on `edge-transformer`), also specified below.

---

## 1. Why this exists — the finding, confirmed against source

| | HTTPS shim (Path A, live) | MQTT direct (Path B, this doc) |
|---|---|---|
| Customer sends | SparkPlug-**JSON** (POST) | SparkPlug B **protobuf** over MQTT |
| Entry service | `ingest-shim` (`:8444`) | `mqtt-ingress` broker → internal `mosquitto` |
| Decode / alias resolve | **none** — republished verbatim | `edge-transformer` `sparkplug.Decode` + `StateStore` |
| **Go Calc runs?** | **NO** — lands on worker's legacy JSON decode | **YES** — `USE_GO_PORT` + `CALC_CUTOVER_REFACTORED` |
| RabbitMQ target | `oee` / `sparkplug.data.<tenant>` (direct) | `oee` via `sparkplug-decoder`'s `analyticspub`/outbox |
| Faithful `MachSpeed`/`P30700`/delta-counter shape | **NO** | **YES** |

Source evidence:
- `services/ingest-shim/cmd/ingest-shim/main.go` header + `internal/httpserver/server.go` — it reads the body,
  scope-guards on the topic/group first segment, stamps `source_type`, and `Publisher.Publish`es **verbatim**
  to `oee`/`sparkplug.data.<tenant>`. **No `sparkplug.Decode`, no `StateStore`, no Calc.** It is a pure
  authenticated transport front-door so RabbitMQ stays internal.
- `services/edge-transformer/cmd/edge-transformer/main.go` — the MQTT `sparkplugHandler`
  (`main.go:416`) decodes, resolves aliases via `sparkplug.StateStore`, runs the Calc Production Counters port
  (`runShadow`/`buildCutoverMetrics`, `main.go:858-1017`), and triple-emits. This is the "Go Calc brain."
- `services/edge-transformer/internal/sparkplug/decoder.go:77` — `Decode(body)` is
  `proto.Unmarshal` — **"Sparkplug B is binary-only over the wire … NOT the JSON representation."**
- `services/edge-transformer/cmd/plc-sim/main.go` — `sparkplug.EncodeSim(...)` → `proto.Marshal`,
  `c.Publish("spBv1.0/CPACK/NBIRTH/<edge>", 0, true, body)` (retained NBIRTH establishes aliases) then
  `spBv1.0/CPACK/NDATA/<edge>` (alias-only). **This is exactly the wire shape a real PLC/Node-RED must
  reproduce for Path B.**

**Consequence:** ADR-0032 §1 calls both tenants "convergent on one processor," but that is only true for
CPACK (`plc-sim` → protobuf → edge-transformer). **Incoplast on the shim does NOT converge on
edge-transformer** — it skips the Calc. ADR-0032's own §5.2 risk table flags "Incoplast behavior
unvalidated (ADR-0022 gap) … flag it un-blessed." Path B is the mechanism that *un-flags* it.

---

## 2. Topology — options weighed, recommendation

### The three options

**(a) Public TLS listener (8883) directly on the existing internal `mosquitto`.**
Cheapest (one `listener 8883` block + certs). **Rejected as primary.** The internal broker is a *shared bus*:
`plc-sim`, `s7-reader`, `edge-transformer`, and — when `EDGE_COMMANDS_ENABLED` flips — the **DCMD
machine-write publisher** (ADR-0019 C1, `spBv1.0/<group>/DCMD/<edge>`, which `plc-sim` *subscribes* to)
all live there. Exposing that bus publicly makes an ACL misconfiguration a **direct machine-write / PLC-command
exposure**, and lets a public client see retained NBIRTHs of every tenant. Defense-in-depth says the public
surface must not be the shared internal bus.

**(b) Separate edge-facing broker (`mqtt-ingress`) that one-way MQTT-bridges inbound DATA into internal `mosquitto`.** ✅ **RECOMMENDED.**
A second Mosquitto container owns the *only* public listener (8883, native TLS + mTLS + ACL). A Mosquitto
**bridge** forwards `spBv1.0/#` **one-way (`topic … in`)** from the edge broker into the internal broker.
`edge-transformer` consumes the internal broker **unchanged**. Isolation properties:
- The public broker carries **only inbound tenant DATA** — the bridge does not forward DCMD/NCMD, and the
  edge broker's ACL forbids external clients from writing command topics at all (belt + suspenders).
- A compromised/misbehaving external client can never reach `plc-sim`, the DCMD topics, or another tenant's
  retained state — those live only on the internal broker, which stays loopback-bound.
- **Zero change to `edge-transformer`.** The bridge is transparent; bridged messages are byte-identical to
  what `plc-sim` publishes.

**(c) TLS-terminating stream proxy (nginx `stream`) in front of internal `mosquitto`.**
The stack already uses this exact idiom for AMQPS (`security_groups.tf:33` — "factory edge clients publishing
to RabbitMQ via Nginx TLS proxy"). It works for transport encryption, **but** a layer-4 stream proxy cannot
enforce MQTT-level per-tenant auth or **topic ACLs** — you'd still need Mosquitto ACLs behind it, and you'd
lose the client-cert identity unless you PROXY-protocol it through. So (c) collapses back to (a)'s shared-bus
exposure with TLS offloaded. **Rejected as primary**, but its SG/nginx-stream mechanics are the reference for
how we expose the port (see §3.4). Note: an ALB cannot front MQTT (ALB is HTTP/L7); only an **NLB (L4)** or
direct SG:8883 can — and NLB TCP-passthrough keeps TLS/mTLS end-to-end to the broker.

### Recommended staging topology

```
 Factory Node-RED (CPACK / Incoplast)
   │  protobuf SparkPlug B, mqtt-out over TLS(+mTLS)
   │  topic: spBv1.0/<GROUP>/{NBIRTH,NDATA,DBIRTH,DDATA,...}/<edge>[/<device>]
   ▼
 SG:8883 (customer egress CIDRs only)  ── or NLB:8883 TCP-passthrough
   ▼
 mqtt-ingress  (NEW Mosquitto, TLS+mTLS+ACL, public listener 8883)
   │  Mosquitto bridge:  topic  spBv1.0/#  in  0   (ONE-WAY, DATA only)
   ▼
 mosquitto  (existing internal broker, 172.18.0.24, loopback-bound 1883)   ◀── plc-sim also here
   │  spBv1.0/#
   ▼
 edge-transformer (172.18.0.23)  — UNCHANGED
   decode(protobuf) → StateStore(alias) → Calc(USE_GO_PORT, CALC_CUTOVER_REFACTORED)
   → triple-emit (ADR-0032: refactored-only)
   ▼
 RabbitMQ `oee` → oeecloud-worker → packiot_analytics (F3)
```

### Prod-evolution note
In prod each factory typically runs its own on-site broker (or the flow speaks to a cloud broker). The
`mqtt-ingress`-broker-with-one-way-bridge pattern maps cleanly onto (i) a per-factory Mosquitto bridging up
to a regional cloud broker, or (ii) **AWS IoT Core** as the managed public front (IoT Core does mTLS +
per-thing policies natively; a Mosquitto bridge or a small consumer subscribes IoT Core → internal). Keep
the internal broker + `edge-transformer` contract identical so the public front is swappable. Do **not** put
this on the ALB — MQTT needs L4 (NLB) or a broker-native TLS listener.

---

## 3. Security posture — this is a PUBLIC broker, treated seriously

### 3.1 Attack surface → mitigation

| # | Attack | Mitigation |
|---|--------|-----------|
| A1 | Anonymous/unauthenticated connect | `allow_anonymous false` on the edge broker; mTLS **required** (`require_certificate true`) or password_file fallback. The internal broker's `allow_anonymous true` is acceptable ONLY because it stays loopback-bound. |
| A2 | Cross-tenant topic spoofing (CPACK publishing `INCOPLAST/#` or vice-versa) | Per-tenant `acl_file`: each identity may write **only** `spBv1.0/<ITS_GROUP>/#`. Identity derived from the client cert CN (`use_identity_as_username true`). |
| A3 | **Command-topic injection → machine write** (external client publishing `spBv1.0/<group>/DCMD/#` or `NCMD`) | (i) ACL denies write to `.../DCMD/#` and `.../NCMD/#` for every external identity; (ii) the bridge forwards DATA topics only; (iii) `EDGE_COMMANDS_ENABLED=false` today anyway. Three independent guards on the one path that can move a PLC. |
| A4 | Credential theft on the wire | TLS 1.2+ mandatory; with **mTLS there is no shared bearer secret** to steal (contrast the shim's `X-Ingest-Key`). |
| A5 | Connection flood / DoS | SG source-IP allowlist (customer egress only) is the primary gate; `max_connections`, `max_inflight_messages`, `max_queued_messages` cap resource use; `max_keepalive` bounds idle sockets. Mosquitto has no native connect-rate-limit → rely on SG + host-level (fail2ban optional). |
| A6 | Oversized / malformed payloads | `max_packet_size 65536` (already set internally); `edge-transformer` `Decode` returns an error (counted, not a crash) on bad protobuf; the bounded ingest queue drops-with-metric under overload (subscriber.go). |
| A7 | Retained-message poisoning (planting a bad NBIRTH) | ACL write-scope confines retained writes to the tenant's own subtree; a bad NBIRTH only corrupts that tenant's alias table, which `edge-transformer`'s per-publisher seq-gap counter surfaces. |
| A8 | Sequence/alias replay or gaps | `sparkplug.StateStore.OnSeqGap` already counts per-publisher gaps → Prometheus/`/healthz`; no new work, just observe. |
| A9 | Public exposure of the *shared* bus | Solved structurally by topology (b): the public broker is a separate process; internal broker stays loopback. |

### 3.2 TLS — cert strategy (OPEN QUESTION for USER, see §8-Q2)
Mosquitto's native TLS listener needs the server **private key on disk** — so **ACM is out** (ACM never
exports private keys; it is only for AWS-managed endpoints like ALB/NLB-with-TLS, and we want mTLS terminated
*at the broker*). Realistic options:
- **Self-managed CA (recommended for staging).** We already ship this pattern: the shim tee-doc hands the
  customer a `ca.crt`; the operator-adapter uses `/opt/packiot/operator-adapter/certs/tls.{crt,key}`. Reuse it:
  one internal CA signs the broker **server** cert *and* the per-tenant **client** certs (mTLS). Customer trusts
  our `ca.crt` for the server, presents its client cert for identity. Zero external dependency, and mTLS falls
  out for free.
- **Let's Encrypt (DNS-01)** for a real `mqtt-ingress.staging.packiot.com` server cert if we want the customer
  to skip trusting a custom CA. Client identity still needs our own CA (LE doesn't issue client certs). More
  moving parts; defer unless the customer's Node-RED balks at a self-signed server CA.

**Recommendation:** self-managed CA on staging (fastest, already-established idiom, gives mTLS). Revisit LE
for prod public identity.

### 3.3 Per-tenant AUTH — mTLS vs username/password
- **mTLS (recommended).** Client cert `CN=CPACK` / `CN=INCOPLAST`; `use_identity_as_username true` makes the
  CN the ACL key. Identity, transport security, and ACL key are one artifact; nothing bearer-shaped crosses
  the wire. Cost: customer must mount cert+key in a Node-RED `tls-config` node.
- **Username/password (fallback).** `password_file` per tenant, TLS-wrapped. Simpler for the customer, but a
  long-lived shared secret (rotate + Secrets-Manager it). Use only if the customer Node-RED can't do client
  certs.

Either way: **secrets via AWS Secrets Manager / mounted files, never hardcoded** (honors the standing rule).
Per-tenant password (if used) lives in `packiot/staging/mqtt-ingress-<tenant>-creds`, fetched at provision
time — not committed, not in compose env.

### 3.4 Network exposure (staging only)
- **New SG rule:** `ingress tcp 8883` on `aws_security_group.app`, `cidr_blocks = [<customer egress CIDRs>]`
  — **NOT `0.0.0.0/0`.** The shim's tee-doc already asks the factory for its egress IP "to restrict it"; make
  that mandatory here since a broker is a richer target than a single POST endpoint. (Precedent: the AMQPS
  5671 rule at `security_groups.tf:33`.)
- Internal broker keeps `127.0.0.1:1883` binding — **do not** publish the internal broker's port. Only the
  edge broker's 8883 is public.
- **This SG change is a PROPOSAL — do not `terraform apply`; do not open the port** until certs, ACL, and
  bake plan are signed off.

---

## 4. edge-transformer wiring — confirmed unchanged

Nothing in `edge-transformer` changes. It already:
- subscribes `spBv1.0/#` (`TopicFilterAll`, subscriber.go:50) on `MQTT_BROKER_URL=tcp://mosquitto:1883`;
- decodes protobuf, resolves aliases per publisher, runs Calc, triple-emits.

The tenant's SparkPlug **group** (`CPACK`, `INCOPLAST`) is the topic's 2nd segment and resolves to
`id_equipment` via **`packml_register`** exactly as `plc-sim` does (`lower(split_part(topic,'/',1))` tenant
discovery; the collapsed 4-segment line topic → tp=3 line, per `plc-sim/main.go:52` `TopicForRegister`). The
same seeded `packml_register` rows that route `plc-sim`'s `CPACK/SC/LINHAS/L*` and the shim's `INCOPLAST/...`
topics route the real tee's messages — **no new routing work** provided the real tee's topic strings match the
seeded register keys (verify per tenant; Incoplast had a known topic-shape mismatch — see the
`feedback_bug_incoplast_topic_shape_mismatch` memory).

**ADR-0032 collapse setting:** for the single-flow end-state, `edge-transformer` runs
`SHADOW_EMIT_PRODUCTION=false`, `SHADOW_EMIT_REFACTORED=true`, `CALC_CUTOVER_REFACTORED=true` → emits the
**`refactored` (F3) leg only**. Path B traffic inherits that setting automatically; no per-source config.

---

## 5. plc-sim + shim coexistence / migration

### 5.1 CPACK (ent 3) — avoid the double-feed
`plc-sim` publishes `spBv1.0/CPACK/{NBIRTH,NDATA}/<edge>` on the **internal** broker. A real CPACK tee would
bridge `spBv1.0/CPACK/#` into that **same** internal broker. Both reaching `edge-transformer` ⇒ **two feeds
for ent 3 ⇒ double-count** (the same single-writer-per-row violation class as the two-writer line
double-count bug, `feedback_bug_two_writer_line_double_count`). Therefore the CPACK cutover is a **swap, not
an add**:
- **Disable `plc-sim` before the real CPACK tee goes live** (comment the service / scale to 0), so ent 3 has a
  single source. Partial overlap (real tee for some lines, sim for the rest) is fragile topic-partitioning —
  go all-real or all-sim per tenant.
- Because `plc-sim` only simulates a subset of CPACK lines (L8/L5-BREYER/L5-TEXA/L3-PTH/L4-TEXA), the real tee
  is strictly *more* complete once it's the sole feed.

### 5.2 Incoplast (ent 4) — MIGRATE off the shim to MQTT? **Recommendation: YES — it is the whole point.**
Incoplast on the shim skips Calc → its `MachSpeed`/`Parameter30700`/threshold-derived signals are absent, which
is a contributing cause of the `OEE=0` / `status_type=0` "un-blessed" symptoms (ADR-0032 §5.2). Routing
Incoplast through `edge-transformer`'s Calc is exactly what makes it prod-faithful. **So migrating Incoplast to
Path B is recommended** — with one hard dependency and a fork:

- **Dependency:** Path B needs **protobuf**. The shim tee taps Incoplast's **JSON** (`tee-node-setup.md`:
  "the payload is already the SparkPlug-JSON object … right before `pubsub-out`"). To use Path B the flow must
  emit protobuf (tap earlier, at the SparkPlug DDATA/DBIRTH assembly before JSON stringify, or add a
  sparkplug-encode node). Whether their flow can do that at the seam is **Q1 for the USER.**
- **Variant B2 (fallback if JSON is all they can emit): a JSON→Calc ingress on `edge-transformer`.** Add a
  small ingress (a new internal MQTT topic carrying the JSON, or an HTTP/JSON endpoint on edge-transformer)
  that unmarshals the SparkPlug-JSON into `sparkplug.ResolvedMetric`s and feeds the **same StateStore→Calc→
  triple-emit** path. This closes the Calc gap **without forcing the customer to switch to protobuf** — it
  reuses their existing shim tee, just re-pointed into edge-transformer instead of straight onto `oee`.
  Cost: ~2–3 days Go (a JSON decode path parallel to `sparkplug.Decode`) + tests; benefit: zero customer-side
  protobuf work and it also un-blesses any future JSON-only tenant. **B2 is the pragmatic faithful path if Q1
  is "JSON only."**
- **No double-feed:** migrating Incoplast is also a **swap** — when it publishes via MQTT (or B2), turn OFF the
  HTTPS shim for Incoplast (`ingest-shim` scope is Incoplast-only, so this is "stop the shim service" once
  CPACK is also migrated, or scope it down). Never run shim-Incoplast and MQTT-Incoplast simultaneously.

**Net:** the shim (`#541` CPACK + live Incoplast) is the **interim real-data feed**; Path B (protobuf) or B2
(JSON-into-Calc) is the **faithful end-state**. Migrate per tenant, swap-not-add, retire the shim last.

---

## 6. Customer-side delta — the Node-RED tee change

Today (shim): `… SparkPlug assembly → [tee: change(set headers)+http request POST] → pubsub-out`.
Path B replaces the HTTP tee with an **`mqtt out`** node.

### 6.1 mqtt-out node config (protobuf, mTLS)
```
Broker:        mqtt-ingress.staging.packiot.com : 8883
Protocol:      MQTT v3.1.1, TLS enabled → tls-config node:
                 CA cert:      ca.crt            (our self-managed CA — same file family as the shim's ca.crt)
                 Client cert:  <tenant>.crt      (CN = CPACK | INCOPLAST)   ← mTLS identity
                 Client key:   <tenant>.key
                 Verify server certificate: ON (staging: ON with our CA; do NOT ship "verify off")
Client ID:     <tenant>-nodered-<edge>          (unique per edge; clean session true)
Keepalive:     30    QoS: 0    Clean session: true
Topic (data):  spBv1.0/<GROUP>/NDATA/<edgeNode>       (per-message; DDATA/<device> for sub-devices)
Payload:       the protobuf-encoded SparkPlug B **Buffer** — NOT the JSON string
```

### 6.2 The two gotchas
1. **Payload must be protobuf `Buffer`, not JSON.** If the tee seam only has the JSON object, either move the
   tee upstream (before JSON conversion) or insert a SparkPlug-encode function
   (`node-red-contrib-mqtt-sparkplug-plus` / Tahu-style, `proto.Marshal`). This is the crux of Q1.
2. **NBIRTH first, retained.** NDATA carries **alias-only** metric references; `edge-transformer`'s
   `StateStore` resolves them from the **retained NBIRTH** alias map (mirrors `plc-sim`: retained NBIRTH then
   alias-only NDATA). The tee MUST publish the NBIRTH (`retain=true`) on connect / on alias-set change, or every
   NDATA fails alias resolution and the seq-gap counter climbs. (B2/JSON avoids this — JSON carries names.)

### 6.3 Cert provisioning (mirrors the established self-signed-CA idiom)
1. We generate, per tenant, a client cert+key signed by our CA (`openssl req/x509`, CN=`<GROUP>`), reusing the
   cert-gen pattern already used for the shim/operator-adapter certs under `/opt/packiot/*/certs`.
2. Hand the customer: `ca.crt` (they already have the shim's — same CA if we consolidate), `<tenant>.crt`,
   `<tenant>.key` (over a secure channel; the key never leaves via git/chat).
3. Customer mounts the three in a Node-RED `tls-config` node.
Proposed inert config lives under `docs/ingestion/proposed/` (see §7) — **not** wired into any compose file.

---

## 7. Proposed (inert) artifacts in this PR

All under `docs/ingestion/proposed/` — **design references, NOT wired into `compose.staging.yml`, not applied:**
- `mqtt-ingress.mosquitto.conf` — edge broker: TLS 8883, `allow_anonymous false`, `require_certificate true`,
  `use_identity_as_username true`, limits, bridge stanza (`topic spBv1.0/# in 0`).
- `mqtt-ingress.acl` — per-tenant write-scope to `spBv1.0/<GROUP>/#`, explicit DCMD/NCMD deny.
- `compose.mqtt-ingress.snippet.yml` — the proposed `mqtt-ingress` service block (commented header:
  "PROPOSAL — do not merge into compose.staging.yml until §8 sign-off").
- `security-group-8883.snippet.tf` — the proposed SG ingress (customer CIDRs, not 0.0.0.0/0).
- `nodered-tee-mqtt.md` — the customer-facing mqtt-out + cert setup (the eventual replacement for
  `~/incoplast-ingest/tee-node-setup.md`).

Keeping them out of the live compose/terraform is deliberate: this PR must be reviewable and mergeable with
**zero** chance of opening a public port.

---

## 8. Effort, sequencing, and OPEN QUESTIONS

### Effort (staging stand-up)
| Item | Effort | Notes |
|------|--------|-------|
| `mqtt-ingress` broker service + TLS/ACL/bridge config | ~1 day | New Mosquitto container; config is the bulk |
| CA + server cert + per-tenant client certs + tooling | ~0.5 day | Reuse shim/operator-adapter cert idiom |
| SG 8883 rule (customer-CIDR) + optional NLB | ~0.5 day | Terraform proposal; **gated** apply |
| Bridge validation (bridged msg == plc-sim msg, byte-level) | ~0.5 day | Prove transparency before any customer points at it |
| Customer Node-RED protobuf tee | **wildcard** | Trivial if flow already has protobuf; a real task if JSON-only → then do **B2** instead |
| **Variant B2** (JSON→Calc ingress on edge-transformer) | ~2–3 days Go | Only if Q1 = "JSON only"; removes all customer protobuf work |

### Sequencing vs the #541 shim
1. **Now:** shim stays the interim real-data feed (CPACK #541 + Incoplast live). No disruption.
2. Stand up `mqtt-ingress` on staging (broker + certs + bridge), **port still closed** — validate the bridge
   internally (publish a protobuf test frame to the edge broker from inside the VPC, confirm it reaches
   `edge-transformer` and produces Calc metrics identical to `plc-sim`).
3. Open SG 8883 to **one** customer's egress CIDR; provision that tenant's client cert; customer switches its
   Node-RED tee to mqtt-out (or we stand up B2 and re-point their JSON tee).
4. **Bake in parallel** briefly, then **swap** (never add): disable `plc-sim` for CPACK / stop the shim for
   Incoplast so the tenant has a single source. Confirm F3 Calc-derived signals are present + parity vs the
   shim baseline.
5. Repeat per tenant. **Retire `ingest-shim` last**, once every tenant is on the MQTT/B2 path.
6. This is entirely inside ADR-0032's "data direct from client" step-2 intent; it does **not** touch the
   operator write path (shadow-mirror stays) and does **not** touch prod.

### OPEN QUESTIONS for the USER
- **Q1 (blocking design choice):** Can the real CPACK/Incoplast Node-RED (and PLCs) emit **protobuf
  SparkPlug B** at the tee seam — or only the decoded **JSON** (as the shim taps today)? If JSON-only, we ship
  **variant B2** (JSON→Calc ingress) instead of the pure protobuf MQTT tee. This is the single biggest fork.
- **Q2 (cert strategy):** Self-managed CA (fast, mTLS-native, already our idiom) vs Let's Encrypt DNS-01
  server cert (customer skips trusting a custom CA, but more moving parts, still need our CA for client certs)?
  Recommendation: self-managed CA for staging.
- **Q3 (auth mechanism):** mTLS client certs (recommended) vs per-tenant username/password? Depends partly on
  whether the customer Node-RED can present client certs.
- **Q4 (exposure):** Confirm each tenant's **egress CIDR** so SG 8883 is IP-scoped (never 0.0.0.0/0). Direct
  SG:8883 on the app EC2 (like the shim's 8444) vs a dedicated NLB:8883 passthrough?
- **Q5 (CPACK real feed):** Is there an actual CPACK factory Node-RED to tee on staging, or does CPACK stay on
  `plc-sim` (synthetic) and only Incoplast migrates first? ADR-0032 treats staging CPACK as synthetic-by-design;
  Path B for CPACK may be a prod-only concern.

---

## 9. Decision requested
Adopt **topology (b) — a separate `mqtt-ingress` broker (TLS 8883 + mTLS + ACL) one-way-bridging DATA into the
internal broker** — as the faithful Path B end-state, delivered as **protobuf-MQTT (B1)** or, if Q1 is
"JSON-only," **JSON-into-Calc on edge-transformer (B2)**. Migrate Incoplast off the HTTPS shim to close the
un-blessed Calc gap; keep the shim as the interim feed and retire it last; swap-not-add per tenant to avoid
double-feed. **All execution deferred to USER sign-off on Q1–Q5. No infra applied; no public port opened.**
