# Scope — twin "PO emission from here on out" (CPACK/sandbox)

> Plan/scope only. Goal: the twin should reliably reflect **new** CPACK POs going
> forward, with **proper (original) dates**, while historical POs stay in
> analytics + historian. Investigation done 2026-09-20.

## The mechanism already exists (and preserves dates)
The **`legacy-replicator`** (`services/analytics-sync`, the ADR operator-action
twin) is what "twins out" POs — it is NOT a data mirror, it replays legacy CPACK
**operator actions** (PO start/stop, downtimes, justifications):
- `internal/replicate/handlers.go`: `sqlUpdatePOStart` → `UPDATE core.production_orders
  SET status=2, ts_start=$1, last_update=now()`; `sqlUpdatePOStop` → `status=$1,
  ts_end=$2, production_real=$3`. **`ts_start`/`ts_end` = the legacy EVENT timestamp**
  (original date); only `last_update` is replay-time. → **dates are preserved.**
- `internal/replicate/reconcile.go`: a periodic PO reconciler (backfill/finish).
- Cursor in `ops.mirror_replay_cursor`; failures land in `ops.mirror_replay_dlq`.
- Runs continuously: observed 5-min passes — `PO reconcile pass done, legacy_pos:239,
  inserted:0, finished:0, unresolved:0` (idle/up-to-date within its window).
- `legacy-replicator-sbx` = a 2nd instance re-tenanting into sandbox ent 2000003
  (`REPLICATE_SBX_ENABLED`); core POs for ent3 ↔ ent2000003 are date-parity twins
  (both 54 core POs, Jun 11–Aug 18).

**So there is no date bug and no missing mechanism.** cpack/sandbox POs carry
proper original dates; the earlier "replay-time dates" note was a mis-scoped query
(that count was all tenants, not cpack).

## The real gap — ROOT CAUSE (triaged 2026-09-20, corrects the earlier guess)
**DLQ = 1,374 rows, all from a single Sep-9 batch, retries exhausted (5).** NOT
"unresolved equipment" — the real failure:
- **1,369× `conflicting key value violates exclusion constraint
  "production_orders_runtime_id_equipment_runtime_timerange"`** — the replay tries
  to insert a PO runtime window that **OVERLAPS an existing window for the same
  equipment** (the constraint that forbids a machine running two POs at once).
- 5× `production_orders_ts_start_ts_end` check (ts_start > ts_end — bad range).
- Categories: 1,268 `order-changed`, 90 `order-created-started`, 16 `order-started`.
- **681 distinct id_orders**, and sampled ids (894309, 894357, 894583, 894658,
  894659) are **NOT in the twin** (`core.production_orders` ent3/2000003 count=0) →
  **genuinely missing POs, not duplicates.** The twin is missing 681 POs.

**Why overlaps:** the `order-changed` handler appears to INSERT a new
`gold.production_orders_runtime` window per change (and started events for POs
whose prior window wasn't closed), instead of UPDATING the existing window or
superseding/closing the conflicting one first. So the replay collides with the
exclusion constraint and DLQs. This is a **replicator LOGIC bug**, not a data or
equipment-resolution gap — so it CANNOT be fixed by a blind DLQ re-drain (that
would just re-hit the constraint, or worse, force bad overlapping windows).

## Fix approach (S2/S3 — now a code task, gated, needs tests)
- **S2 (code, analytics-sync `internal/replicate/handlers.go`):** make
  `order-changed`/`order-started` **idempotent + overlap-safe** — resolve the
  existing runtime window by `id_production_order` and UPDATE it; when a genuinely
  new window would overlap a prior one for the equipment, **close/supersede the
  prior** (`sqlSupersedeRunningPO`/`sqlCloseWindowsForEquipment` already exist —
  wire them into this path) before insert. Add a unit/golden test that replays the
  DLQ shape (an `order-changed` for an equipment with an open window) and asserts
  no exclusion-constraint violation + the window updates in place.
- **S3 (drain):** only AFTER S2 ships — retry `ops.mirror_replay_dlq` (the retry
  loop exists); the 681 missing POs then land with their original `ts_start`.
- **Newest twin PO = Aug 18** is consistent with this: the Sep-9 batch of Jul/Aug
  legacy PO events DLQ'd on the overlap, so nothing past that window materialized.

## Staged plan (each step gated)
| # | Step | Risk |
|---|---|---|
| S1 | **Triage the DLQ**: group `ops.mirror_replay_dlq` by failure reason + age; confirm the dominant cause (expect unresolved-equipment) | read-only |
| S2 | **Fix the resolver gap**: the +offset/packml-base-topic equipment resolution (same class as the sandbox `//`-topic de-link in `provision-sandbox-tenant.sh`) — de-link/neutralize the malformed packml rows so replayed actions resolve | DB write, scoped to twin tenants |
| S3 | **Drain/retry the DLQ**: replay the 1,374 backlog once the resolver is fixed → missing POs land with their original dates | replay pipeline |
| S4 | **Confirm the cursor advances**: verify new legacy PO events (post-Aug-18) replay within one pass; newest twin PO tracks legacy | read-only |
| S5 | **Monitor**: alert on DLQ depth > N and cursor lag > T (so "from here on out" stays healthy) | observability |

## Verify-after (assertions)
- `ops.mirror_replay_dlq` count → ~0 (or only genuinely-unreplayable).
- newest cpack `production_orders.ts_start` tracks legacy (lag < 1 pass).
- a spot-check PO's `ts_start` == its legacy original (dates preserved end-to-end).
- cpack↔sandbox PO parity holds after the drain.

## Note
Historical POs (pre-twin) are the legacy-replicator's job too (it backfills via the
reconciler within its window); the **full multi-year history lives in legacy + the
historian cold**, not necessarily materialized as twin `production_orders`. If the
product needs the *full* historical PO set in the new-stack analytics (not just the
replay window), that's a separate backfill decision — flag it.
