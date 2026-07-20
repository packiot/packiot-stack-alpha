# ADR-0029 — Decisions resolved (2026-07-20)

Amends [ADR-0029](0029-front4-dashboard-composition-and-metric-layer.md). Records the product/architecture rulings the engine was built to absorb, now decided so cutover (Phase G) can proceed.

## §10 open questions — resolved

**Q1 — Config-authoring UI: now, or seed-first?** → **Seed-first.** CS-Admin authors/edits `dashboard_config` baselines via SQL / a refdata PUT for now; a drag-tile authoring UI is a later **P3**, off the cutover critical path. Rationale: fastest path to per-tenant cutover; the `user_screen_config` override layer (ADR-0027, already built) is the future self-service seam, so adding the UI later is additive with zero rework.

**Q2 — Config ownership: CS-Admin vs customer self-service?** → **CS-Admin owns the tenant *baseline*; `user_screen_config` is the optional per-user override.** Resolution order at render (already implemented in `/v1/dashboard-config`): user override ⊕ tenant baseline. This keeps the authoring UI **P3** (a customer-facing drag-tiles surface is a later want, not a cutover blocker).

**Q3 — PlcStatusTile stub.** → **Migrate the stub as-is** (visual parity — it currently renders a hardcoded `connected`). Wiring the real `/infra-events/plc/current-status/:lineId` endpoint is a **separate later ticket**, not part of the frozen-skin migration.

## #80 `proportional_target` — ruling

Backend truth (verified, ADR-0029 D5 / #83): `_tp_eq3` (tp=3 **lines**) emits an elapsed-prorated `proportional_target`; the base fn (tp=1 **machines** / tp=2 **sectors**) emits a **full-shift** target. The metric-contract-correct value for a "where you should be *right now*" target is **elapsed-prorated for all equipment types**.

**Ruling — the front4 fix is tp-aware, not a blanket delete:**
- **tp=3 lines** → backend already prorates correctly → **delete the front4 override, consume `uns_equipment_current_shift.proportional_target` directly** (as Day/Month already do). The `não está correto` comment is stale.
- **tp=1 machines / tp=2 sectors** → backend emits full-shift, which is *not* the "right now" target → **keep the client elapsed-proration** for these (it produces the correct value the backend doesn't). The shift card fetches `equipments.tp_equipment` for its `:lineId` and branches (the earlier trace showed `:lineId` reaches the card with no tp validation, so a blind delete would regress machine/sector cards — hence tp-aware).

**Follow-up (separate, P3-backend-correctness):** make the base fn *also* elapsed-prorate machines/sectors — but **NOT** by uncommenting base write #2 (that double-writes → resurrects #80, per #83); replace write #1's full-shift calc with an elapsed-prorated one. Once that lands, front4's tp=1/2 branch can also delete its override. Until then, the tp-aware front4 fix is correct and safe.

**Implementation:** the front4 tp-aware change rides the eventual `TargetDeltaTile` `targetField` wiring (ADR-0029 D2 — the field is already a prop); queued behind the in-flight v2–v6 widget extraction to avoid a same-file conflict.
