# ADR-0024 — Phased mirror retirement: decouple the data-cutover from the action-cutover

**Status:** Proposed · **Date:** 2026-07-16 · **Builds on:** ADR-0003 (phased cutover), ADR-0013 (shadow-mirror-service), ADR-0016 (staging consolidation), ADR-0017 (endgame process separation), ADR-0022 (pre-flip behavior validation), the prod-cutover-readiness review (S0–S7) · **Depends on:** task #32 (PO staleness/durability gate) as a hard prerequisite for the intermediate state · **Refines, does not supersede:** the "mirror retires at the flip" language in the glossary / ADR-0017 / endgame roadmap.

## Context — the mirror is two scaffolds, not one, and they carry unequal risk

The migration runs two distinct replication scaffolds, and the docs already name them separately even though they are usually spoken of as one thing that "retires at the flip":

| Scaffold | Service | What it carries | Source → sink |
|---|---|---|---|
| **Data mirror** | `mirror-worker-go` | the raw counter/event stream (`equipment_values`, `equipment_events`) | prod → staging shadow (and, for the parallel-run, feeds the new compute) |
| **Action mirror** | `shadow-mirror` | operator **decisions** — PO lifecycle (start/stop/setup/replace), justifications, commands — replayed from the `user_logs` audit trail | prod's operator writes → shadow flows |

The current plan treats these as a single unit that is stood up together (ADR-0022 V1 wires "its two mirrors") and torn down together "at the flip" (glossary: "pure migration scaffolding, retires at the flip"; ADR-0017: "prod→staging mirror until prod migrates, then retires"). **That atomic framing hides the single most important asymmetry in the whole endgame:**

- **The data/compute path is PROVEN.** The #276 Calc cutover is signed off on the determinism gate; F2==F3 is byte-exact on the event-derived core `{count, running_time, duration}`; the #21 identity sentinel now guards it in CI; the F2/F3 divergence has been fully characterized (ADR/#43, #45) as by-design raw-vs-cutover, not a regression. We *trust* this path.
- **The action path is NOT proven.** Operator-action durability under partition (offline, flaky-wifi, wrong-PO-on-reconnect) is the open, still-baking work: the #32 server staleness gate (live but mid-bake), the #31 client durable write-queue (built, not enabled), the #46 gate-exposed retry/zombie issues. We do *not* yet trust this path end-to-end on a real client.

Retiring both scaffolds in one atomic "flip" therefore forces the **proven** and the **unproven** paths to cut over on the same day — coupling the low-risk change to the high-risk one and losing the ability to isolate a failure to one path. That is the wrong risk posture.

## Decision

**Retire the two mirrors independently, in risk order — cut the path you trust first, keep the scaffold under the path you don't until it is proven on the real client.** The "flip" becomes three ordered cutovers, not one event:

1. **Compute cutover** — the Go OEE engine becomes source-of-truth (writer-by-writer, ADR-0003 Phase / readiness S4). *Proven by #276.* Neither mirror retires here.
2. **Data cutover (retire the DATA mirror)** — the client's real PLC/SparkPlug stream points at the per-factory `edge-transformer` (readiness **S6**). From this point the new stack receives machine data **directly from the client**, so `mirror-worker-go`'s data replication is redundant → **retire the data mirror.** The action mirror stays.
3. **Action cutover (retire the ACTION mirror)** — the operator/edge path cuts over so operator decisions flow **operator SPA → new gate-protected edge-api → new DB** directly (no legacy round-trip). Only now is `shadow-mirror` redundant → **retire the action mirror last.**

The intermediate state after step 2 and before step 3 — **"data direct from the client, actions still mirror-replayed"** — is an explicit, supported, *safe* topology, not an accident. It is the state in which the migration spends most of its risk-buy-down on the action path.

## The load-bearing subtlety — why the intermediate state is *safe* (and why #32 is a prerequisite)

The moment you run **direct real-time data** alongside **mirror-lagged actions**, you introduce a temporal-coherence hazard: machine counts arrive live from the PLC while the PO-control decision that governs their attribution lags through the legacy → `user_logs` → `shadow-mirror` path. If a PO switches on the client but the switch is still in flight through the action mirror, live counts land against the **old** PO. **This is exactly the "counts on the wrong PO" failure** the whole #32 durability arc exists to prevent.

Therefore:

- **The #32 staleness/durability gate is a hard prerequisite for the data-cutover (step 2).** It is the mechanism that makes "data direct + action mirror-lagged" safe — it rejects (or degrades-to-allow with a review trail) an action whose assumed head no longer matches the authoritative head, so a late-arriving replayed action cannot silently rewrite a moved timeline.
- **You must not retire the data mirror (step 2) until the gate is baked on the target client.** Cutting data direct without the gate live would open precisely the wrong-PO window on a paying factory.
- The action mirror + the gate are **complementary, not redundant**: the mirror keeps actions flowing during the window; the gate keeps those flowing actions from corrupting live-attributed data when they arrive stale.

This also explains *why the action path is the long pole*: it is not merely "another cutover" — it is the one carrying the hard distributed-systems problem (durability + ordering + staleness under partition), and it is correct to leave it on the proven mirror scaffold, behind the gate, until its own durability story (server gate #32 + client queue #31) is fully validated on the real client.

## Consequences

**Positive**
- **Failure isolation.** A problem after the data cutover is provably in the data/ingestion path (the new `edge-transformer` seeing real PLC topology for the first time — readiness R1/R7); a problem after the action cutover is provably in the durability path. No conflation.
- **Smaller, individually-reversible steps.** Each mirror retirement is its own expand-contract with its own frozen-read/rollback window (readiness S7 discipline, per-component), rather than one big-bang teardown.
- **Correct risk ordering.** The proven path sheds its scaffold first; the unproven path keeps it longest. Risk is retired in the order it was bought down.
- **Makes the plan honest** about the fact that the action path — not the compute path — is the true long pole of the endgame.

**Negative / costs**
- **A longer window running both a direct feed and a mirror.** More moving parts for longer, and the temporal-coherence hazard above is live for the whole window (mitigated by #32, but it must be *watched* — `po_gate_degraded_total{reason}` and the structured-409 review tray are the instruments).
- **Two decommission events instead of one**, each needing its own gate + snapshot + frozen-read window.
- **Requires the client topology to support it**: the client's PLC feed and operator feed must be independently re-pointable (data to the per-factory `edge-transformer`, actions still to the legacy operator/edge-api path) — confirm this is physically true per factory before committing the split for that factory.

## Sequencing & gates (per factory, CPACK first)

| Step | Retires | Gate (go/no-go) |
|---|---|---|
| Compute cutover | nothing | #276 determinism + per-writer ≥72h parity (readiness S4) |
| **Data cutover** | **data mirror** (`mirror-worker-go` for that factory) | real-factory data parity vs the legacy path over a month-boundary (readiness S6/R1) **AND #32 gate baked live on that factory** (the prerequisite) |
| **Action cutover** | **action mirror** (`shadow-mirror` for that factory) | #32 + #31 durability proven on the real client (offline/flaky-wifi drills clean; `po_gate_degraded_total`→0; review-tray empty of false-rejects) over a bake window |
| Legacy decommission | EB edge-api, PubSub, prod node-red, `piot_*` | 30-day frozen-read clean + EBS snapshot per component (readiness S7) |

**Open questions for a later pass**
1. Can every target factory re-point PLC-data and operator-actions **independently**? (Physical/network precondition for the split.) — confirm per factory.
2. Does the action cutover want a brief **dual-write** (operator writes to both legacy and new edge-api, reconciled) rather than a hard switch, to make step 3 itself reversible? — decide at action-cutover design time.
3. Where does the `shadow-mirror` `EnsureActivePOs` reconciler fit once actions are direct — does it retire with the action mirror, or does a residual reconcile role survive for late-arriving legacy events during the frozen-read window? (Ties to the #46 zombie-reconcile-PO finding.)

## Relationship to existing decisions
- **Refines** ADR-0017 / the endgame roadmap / glossary's "mirror retires at the flip" — that language is now understood as *shorthand for two ordered retirements*, not one atomic event.
- **Depends on** #32 (ADR-adjacent) — the gate is the enabling mechanism for the intermediate state; this ADR should not be executed past step 1 until #32 is baked.
- **Consumes** the readiness-doc S4/S6/S7 sequence and slots the mirror retirements explicitly into S6 (data) and a new action-cutover step before S7.
- **Informed by** #46 (the gate-exposed stale-reconcile behavior is direct evidence that the action/reconcile path carries live, unfinished risk that must not ride out on the same day as the data path).
