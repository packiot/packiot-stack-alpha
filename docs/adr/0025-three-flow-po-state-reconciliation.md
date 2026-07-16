# ADR-0025 — Three-flow prod-authoritative PO-state reconciliation

**Status:** Proposed · **Date:** 2026-07-16 · **Builds on:** #480 (mirror-worker-go reconciler finisher — the F1 slice + widened origin scope), #49 (shadow PO-transition-drop root cause), ADR-0012 (schema refactor + 3-flow fan-out plumbing), ADR-0013 (shadow-mirror-service) · **Departs from:** ADR-0013's "shadow-mirror is a pure `user_logs` tail-follower" · **Relates to:** ADR-0024 (this reconciler retires with the action mirror).

## Context — the shadow flows have no way to learn that a PO closed

The migration keeps three renderings of production-order state:
- **F1** (`packiot.public`) — the legacy/authoritative-shaped flow. It learns prod PO state through **two** channels: `mirror-worker-go`'s reconciler (which *creates/starts* mirror POs, bridging the ~95% of prod POs that never emit a `user_log`) **and** out-of-band writes (batch remediation, prod resets).
- **F2/F3** (`shadow_go_port`, `packiot_shadow.public`) — the Go compute flows. They learn PO state through **exactly one** channel: `shadow-mirror` replaying `public.user_logs`.

Per ADR-0013, `shadow-mirror` is a **pure `user_logs` tail-follower** — deliberately simple, ordered, replay-only. That was the right call for what it was built for. But two findings this cycle show it is **structurally insufficient to keep the shadow flows faithful**:

1. **#46 — the F1 zombie (PO 17106).** A prod PO ended via a SparkPlug stop (no `user_log`); the create-only reconciler had no finisher, so the staging mirror PO stuck `status=2` with an open segment forever. #480 fixes this **for F1** (a prod-authoritative finisher).
2. **#49 — the 4 shadow zombies.** Four reconcile POs were *closed on F1 out-of-band* (paused/reset) — writes that bypass edge-api and therefore emit **no `user_log`**. `shadow-mirror`, being a tail-follower, had nothing to replay, so F2/F3 stayed `status=2` with open segments **still live-accumulating real running_time** → inflating shadow OEE. F2==F3 (determinism intact); only correctness-vs-F1 diverges.

**The common root:** any PO-state transition that does not pass through edge-api's `user_logs` audit trail is **invisible to the shadow flows**, and ~95% of prod PO closes are exactly that (PLC SparkPlug stops). Pure replay cannot close this gap — you cannot replay an event that was never emitted.

## Decision

**Extend prod-authoritative PO-state reconciliation to all three flows.** The mirror gains a **close/pause direction**, driven by prod authority rather than by `user_logs`, and fanned to F1 + F2 + F3 — closing the existing shadow zombies and preventing recurrence.

Concretely, in two layers already half-built:
1. **F1 (shipped inert): #480's finisher.** Orphans = `mirror-origin staging POs (status=2) MINUS prod-active(status=2)`, scoped to the prod-mirrored enterprise (CPACK / ent 1), closed at prod last-activity ts with the four safety layers (prod-active exclusion, mirror-origin, fresh authoritative re-read, grace window). Flag `RECONCILE_FINISHER_ENABLED`, default off.
2. **F2/F3 (this ADR): fan the finisher's close to the shadow flows.** When the finisher closes an F1 orphan, apply the same header+segment correction to the F2/F3 rows for that PO (by **natural key** `(id_enterprise, id_order)` — surrogate ids differ per flow), reusing the ADR-0012 3-flow fan-out plumbing (the same mechanism `InsertEquipmentValueDelta` uses to write all three schemas). Faithful-to-F1 semantics: seal the segment at F1's `ts_end` for a paused/finished PO; delete the open segment where F1 has none (available/reset).

This makes `shadow-mirror`/`mirror-worker-go` a **prod-authoritative state reconciler for POs**, not only a `user_logs` tail-follower — the deliberate ADR-0013 departure.

## Why depart from ADR-0013

ADR-0013's tail-follower model is correct for **operator actions that go through edge-api** (justifications, edits, manual PO control) — those *do* emit `user_logs` and should be replayed in order. The departure is scoped precisely to **the one thing replay structurally cannot capture: PO-state transitions that never entered `user_logs`.** We are not abandoning tail-following; we are *adding* a prod-authoritative reconciliation pass alongside it, for the state class that replay is blind to. The alternative — asking every out-of-band/PLC writer to emit a synthetic `order-stopped` `user_log` — is rejected (fragile, opt-in, never covers the 95% PLC-driven case; #49 option 3).

## Design choices

1. **Drive from prod, not from F1.** The finisher diffs staging against **prod-active** (the true authority), and F1 is just one of the sinks it corrects — so F1, F2, F3 are all reconciled to the *same* prod truth, and a bug in F1 can't propagate to the shadows. (Alternative — diff F2/F3 against F1 as authority — is rejected: it makes F1 a second source of truth and would faithfully mirror an F1 error.)
2. **Natural-key fan-out.** The close targets each flow's rows by `(id_enterprise, id_order)`, never surrogate `id_production_order` (differs per flow). Reuse the resolver/id-map that already exists for the create direction.
3. **Enterprise scope = prod-mirrored only (CPACK/ent 1).** The finisher must never touch enterprises with no prod authority (simulator ent 2, Incoplast ent 4, staging ent 1) — for those, "staging-minus-prod-active" is meaningless and would finish everything. This is the load-bearing safety invariant (also enforced in #480's widened predicate).
4. **Close at prod last-activity ts, never `now()`** — no phantom stopped_time injected (a zombie open 2 weeks must not book 2 weeks of stopped time).
5. **cagg reconciliation.** Closing a segment fixes the PO/segment level, but running_time already inflated the `equipment_runtime_shift → _1hour → …` cagg chain. The first enabled run must trigger a targeted cagg refresh over the affected windows (dba-owned), or the aggregates stay wrong even after the rows are fixed.

## Consequences

**Positive**
- The shadow flows finally track PO *state*, not just PO *actions* — closing the last structural fidelity gap between F1 and F2/F3 for POs.
- The existing 4 shadow zombies (#49) get closed by the first enabled run; no separate one-time band-aid needed, and no recurrence.
- One reconciliation mechanism, prod-authoritative, fanned to all flows — no per-flow divergence.

**Negative / costs**
- `shadow-mirror`/`mirror-worker-go` is no longer a *pure* replayer — a conceptual complexity increase (mitigated: the reconciliation pass is clearly separated from the replay path, flag-gated, and prod-authoritative).
- Requires the ADR-0012 3-flow fan-out to be reachable from the finisher (it is — same plumbing as the value fan-out).
- The cagg reconciliation is a heavier operation that must be sequenced with the row closes.

## Rollout & gates

1. **#480 (F1 finisher, widened origin)** — merge inert (flag off). *Done pending review.*
2. **Fan-out to F2/F3** — this ADR's build; same flag (`RECONCILE_FINISHER_ENABLED`) governs all three flows, or a second flag for the shadow fan-out if we want to stage them.
3. **Enable on staging** — flip the flag, watch `mirror_worker_reconciler_finisher_total{outcome}` close the 10 F1 + 4 F2/F3 zombies at last-activity ts; verify F2==F3 preserved (both corrected identically) and F1/F2/F3 now match on PO state by natural key.
4. **cagg refresh** — targeted refresh of the affected `equipment_runtime_*` windows (dba).
5. **Prod** — this reconciler is part of the mirror scaffold; per **ADR-0024** it retires with the **action mirror** (the last cutover), so it runs for the whole transition and is decommissioned when operator actions cut over to the gate-protected edge-api direct.

## Open questions
1. **One flag or two** for F1-finish vs F2/F3-fan-out — stage them, or flip together? (Lean: one flag; the fan-out is the whole point.)
2. **Should the fan-out also backfill the classification transitions** (#50 — `event-justified`/`event-edited`), or keep that a strictly separate `shadow-mirror` handler-registration fix? (Lean: separate — #50 is emitted-but-unhandled, a replay fix, not a reconciliation.)
3. **cagg refresh scope** — full refresh of the affected windows vs targeted invalidation; dba to size against the r7g.large headroom.
