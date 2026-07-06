# What was done — the migration journey

> Audience: engineers and technically-minded stakeholders. The
> chronological story, organized by ADR. Each ADR document holds the
> full design; this page is the map.
>
> Status date: 2026-07-06.

## The ADR arc

| ADR | Title (short) | Outcome |
|---|---|---|
| 0008 | Comparator-first phase 2 | Comparator pattern established: validate against prod via SELECT-only reads, never writes |
| 0009 | edge-transformer service split | Go ingest service scaffolded; Node-RED transform layer's replacement |
| 0010 | Sparkplug decode + ingest surface in Go | Decoder (parity-checked vs the Node lib), alias StateStore, Calc counters port (39 tests, live-validated), PO control (30800s) port, MQTT as THE ingest (10.9) |
| 0011 | Durability boundary | The rule: durability starts at Mosquitto's ACK. Publisher confirms, consumer idempotency, MQTT persistence, SQLite outbox, aggregated `/healthz`, PR checklist |
| 0012 | Schema refactor waves | Wave 0 (staging parity repair, 15 objects), Wave 1 (customer_reports pools + backfill), Wave 2 (writer cutover as Go ports), Wave 3 (façade flips), Wave 4 (contract, pending soak) |
| 0013 | shadow-mirror | Operator-action replay from user_logs onto both shadow flows (11 handlers; later gained runtime-window legs + prod-truth supersede) |
| 0014 | OEE math extraction | THE big one: all `piot_*` compute → Go. P2 shift resolver (closed out on 0/46 same-row evidence; legacy trigger dropped). P3 runtime engine (see below). P4 customer report writers (speed33, shift06, sync06, boxes label-adapter) |
| 0015 | Read side (query-api) | Composable customer queries, screen config, tenancy |
| 0016 | Staging consolidation master plan | Parity defined honestly; consumer enumeration; §5 homes; §6 flip runbook; the bloat ledger |

## The P3 runtime-engine port (ADR-0014), in one table

| Piece | Legacy | New | Verification |
|---|---|---|---|
| PO compute pass | `..._runtime_test` (yes, `_test` IS production) | `rollup/compute.go` (set-based, one tx) | parity **0/13,432** |
| PO recalc pass | `..._runtime_final` | `rollup/recalc.go` | parity **0/13,162** |
| Hour grain | `..._1hour_production` | `rollup/hour.go` (flag-keeping phase V — verbatim semantics) | parity **0/198** |
| Day grain | `..._1day_production2` (the LIVE generation — the plain one is dead) | `rollup/day.go` | parity **0/1,716** |
| Shift grain | `..._shift_production` | `rollup/shift.go` | parity **0/4,340** |
| Week/month | `..._1week/_1month_production` | `rollup/grains.go` (incl. the pinned "amber bug", see [differences](03-prod-vs-new-differences.md)) | guard tests + bake |
| Area/site ×10 | 10 bodies | `rollup/entity_grains.go` (spec-driven matrix) | bake |
| Bucket provision | 17 `piot_create_*` | `rollup/provision.go` (transitional verbatim) | exact-count (47,718 = 66×722) |
| UNS refreshers | live generations only | `uns/uns.go`, `uns/current_rest.go` | fills verified live |

## The methodology (what made 0/32,848 possible)

1. **PORTING.md** — the nine-step law: capture file-safe →
   call-site-verify the LIVE generation (the dispatcher's `perform()`
   is truth; monitors lie; 4 dead generations dodged) → equivalence
   argument → port → config extraction → guard tests → flag-gated
   deploy → evidence → record.
2. **The differential harness** (`cmd/port-parity`) — identical input
   snapshots, legacy leg via `search_path`, Go leg via schema params,
   FULL JOIN diff, single-sourced SQL via `-emit`. Its shakedown
   produced a taxonomy of five measurement-artifact classes (and
   caught one real port bug: PL/pgSQL's always-true `IF FOUND` after
   aggregate `SELECT INTO`).
3. **Golden fixtures in CI** — the proven SQL constants run against
   ephemeral Postgres on every PR with exact expected outputs (the
   IF-FOUND regression is a named tripwire).
4. **The bake comparator** — continuous, full-surface, with every
   non-zero reading required to carry a named cause and expiry date.
5. **Identity invariants** — F2 vs F3 run the same engine on the same
   inputs; their fingerprints must be equal. Caught a whole missing
   subsystem leg on its first tick.

## Incidents found and fixed by the machinery (selected)

- **The explosive oscillator**: poisoned state × convergence-sync =
  ±1e38 injections/minute for 20h across three DBs. Killed at the
  state, guarded with physics-based clamps.
- **The slow oscillator**: per-tick re-injection of a *legitimate*
  -sized delta (139M/shift = 546 ticks × 254k — the "division tell").
  Cure: the sync now measures against its own attributed ledger.
- **The missing leg**: PO replays created orders but never runtime
  windows — the entire engine idled on live traffic while every
  component test passed. Cure: window legs + prod-truth supersede +
  the writer-matrix discipline.
- **Silent schedulers**: hourly jobs that never ran under sub-hourly
  deploys (first-tick starvation), silent empty-batch returns that
  imitate hangs, and a ms-vs-second timestamp mismatch that made a
  fill UPDATE match nothing. All now structurally impossible.

Full incident log with root causes and generalized rules: the
project's bug journal (260+ entries).
