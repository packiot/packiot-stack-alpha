# ADR-0023 — Concurrent PO-across-lines: segment-derived running state

**Status:** Proposed · **Date:** 2026-07-15 · **Builds on:** task #32 (PO staleness gate), task #34 (runtime durability / one-open-segment), ADR-0011 (durability boundary), ADR-0014 (OEE math extraction) · **Supersedes nothing** · **Feasibility:** task #36 trace

## Context — the asymmetry we are resolving

A Production Order needs to run on **2+ lines simultaneously**, with per-line quantities summing to the order total. The feasibility trace (#36) established that the platform is *half-ready*, and the split is clean along one seam.

**Already concurrent-shaped (the count engine):**
- `production_orders_runtime` carries its **own `id_equipment`** — many rows per PO, one per (equipment × time segment). Multi-line segments are already storable and are how lines/sectors fan out today.
- `recalc.go` sums `production_orders_runtime` by `GROUP BY id_production_order` with **no `id_equipment` scope** → PO gross/net = sum across all line segments. **Counts already sum correctly.**
- `compute.go` writes per-segment runtime columns keyed `(id_equipment, lower(runtime_timerange))`, joining `equipments` per segment. Per-line runtime rows are already correct.
- `findRuntimesByProductionOrder` (edge-api DAO) reads all segments of a PO with no equipment filter — already segment-shaped.

**Blocks concurrency (the header-identity layer):**
- `production_orders.id_equipment` is a **scalar NOT NULL** — one PO is structurally one machine.
- `production_orders_id_equipment_run_idx` = `UNIQUE(id_equipment) WHERE status=2`.
- **Every** "running PO on E" read resolves through the header: `production_orders WHERE id_equipment=E AND status=2`. No cross-equipment verb exists anywhere.
- `recalc.go` OEE% denominator uses the header's **single** `ideal_production_speed` → counts sum right, **OEE% is wrong** for multi-line.
- Dead hook: `production_orders.id_equipment_executed` (nullable, DDL-only, **never read**).

**Core insight:** "the running PO on equipment E" must be recast from **header-identity** (`po.id_equipment=E AND status=2`) to **segment-ownership** (the PO owning the OPEN `production_orders_runtime` segment on E — `por.id_equipment=E AND upper_inf(runtime_timerange)`). The header's `id_equipment` demotes to **home/primary line**. This is exactly the layer the in-flight #32 gate already reads as its "advisory" layer — we promote it to authoritative.

## Two load-bearing pre-req corrections

1. **RESOLVED (dba audit 2026-07-15) — the non-overlap EXCLUDE IS present, valid, and enforcing on F2, F3, AND prod.** `contype='x'`, `convalidated=t`, def = `EXCLUDE USING gist (id_equipment WITH =, runtime_timerange WITH &&)`. The "plain non-unique GIST index" reading at `edge-node-red/db/00-schema.sql:5184` was a **`pg_get_indexdef` rendering artifact** — Postgres prints an exclusion constraint's backing index as a bare `CREATE INDEX … USING gist (…)`, dropping the `WITH =`/`WITH &&`/`EXCLUDE`; only `pg_get_constraintdef` shows the truth. Migration `20230817162628` is applied and enforced everywhere. **Phase 0 does NOT add the constraint — it already exists.** Two residual gaps survive it: (a) it does **not** prevent a *lone* unbounded segment — a zombie is one open range, not an overlapping pair, and the EXCLUDE only rejects overlaps (the close-first *code*, not the constraint, is what bounds finished segments); (b) it keys on `id_equipment WITH =`, and `NULL = NULL` is never true, so open segments with `id_equipment IS NULL` **bypass the guard entirely** (prod carries 2 such "running_no_open" rows). Prod also carries **13 durable orphan zombies** (oldest 1,482 days) — a *data-quality* cleanup for prod-cutover, not a constraint-add; of the 13, **4 have `ts_end IS NULL`** and need a last-activity fallback ts, NOT `GREATEST(lower, ts_end)` (which collapses to an empty range on NULL).
2. **"Open segment" = unbounded-upper `runtime_timerange`, not `ts_end IS NULL`.** There is no `ts_end` column on the runtime table; header `ts_start`/`ts_end` are trigger-derived. The trigger scopes its header UPDATE `WHERE id_equipment = new.id_equipment` — a latent hazard (Rewire T8).

## 1. The core model change — segment-derived running state

| Concept | Today (header identity) | Target (segment-derived) |
|---|---|---|
| Running PO on E | `po.id_equipment=E AND po.status=2` | PO owning E's open segment: `por.id_equipment=E AND upper_inf(por.runtime_timerange)`, joined to owner PO |
| Per-equipment "one running thing" | `UNIQUE(id_equipment) WHERE status=2` (header) | **the runtime EXCLUDE** `(id_equipment WITH =, runtime_timerange WITH &&)` — this constraint *is* the #34 one-open-segment invariant |
| PO overall status | scalar `status` | **rollup of N segment states**; `id_equipment` = home/primary line |

**Header status ← N segment states.** `status` becomes a derived rollup: running(2) ⟺ ≥1 open segment; paused(4) ⟺ no open segment + last transition = pause + not finished; finished(3) ⟺ all segments closed + explicitly ended; available(1) ⟺ no segments yet. **Ending the PO on one line must NOT flip the header to finished while another line is still open** — the header transitions only when the last open segment closes. This is the single most important behavioral change.

**`UNIQUE(id_equipment) WHERE status=2`** is retired as the running-PO authority but **retained as a secondary guard on the home line**. The temp-status-4 "juggle" in `DecideStart`/`execStart` becomes vestigial under the EXCLUDE — **keep it verbatim until cutover** for F1/F2/F3 parity.

**Migration is code + trigger + flag, not schema** (dba confirmed the runtime table already carries everything).

## 2. Rewire inventory

| # | Site | File · method | Becomes |
|---|---|---|---|
| R1 | Worker running-PO resolver | `pocontrol.go:runningPO` (194) | PO owning open segment on E: `WHERE por.id_equipment=$1 AND upper_inf(range)` |
| T2 | **Worker end/pause — LATENT BUG** | `pocontrol.go:execEnd` stmt 1 (260) | `UPDATE por SET range=[lo,ts) WHERE id_production_order=$3 AND upper IS NULL` **has no `id_equipment`** → closes ALL lines' segments. Must add `AND id_equipment=$E`. Time-bomb the moment concurrent ships. |
| T3 | edge-api start guard | DAO `getRunningFromEquipment` (271) | segment-derived open-segment owner on E |
| T4 | edge-api /current | DAO `getRunningOrder` (388) | segment-derived; may return a PO homed elsewhere |
| T5 | edge-api date-conflict | DAO `getOrderDateConflict` (402) | resolve against segments on E |
| T6 | edge-api lifecycle writes | DAO `start`/`stop`/`setup`/`changeTime` | header status via rollup, not per-equip flip |
| T7 | **#32 gate HEAD** | DAO `timelineHead` (436) | `running_po_id` = open-segment owner; orphan check repointed to the runtime row's id_equipment |
| T8 | Recalc trigger | `set_recalc_needed_from_production_order_runtime()` | drop `id_equipment` clause — key by `id_production_order` alone |
| T9 | Hasura / OEE parity views | `19-hasura-full-parity.sql`, `20-oee-engine-parity.sql` | segment-derived views — **largest blast radius**; per-tenant |
| T10 | reports / BigQuery | `reports/`, `cq-logs-bigquery` | read segments; MVP may leave as-is (home line) with documented gap |
| T11 | Operator SPA | `findCurrentPo` | line-picker + multi-line PO view |

**Already correct (no change):** `runtimesConflict` (already `por.id_equipment`-scoped ✓), `findRuntimesByProductionOrder` (✓), `compute.go` (✓), recalc count sums (✓ — only denominator wrong).

**Implementation lever:** R1, T3–T7 all resolve "running PO on E." Extract **one segment-derived SQL fragment** and reuse it in DAO + worker + gate. One flag, one definition.

## 3. #32 gate interaction — EXTEND, do not redo

The gate is already ~90% segment-aware (`TimelineHead` returns `{runningPoId, openPoId, openCount, openOwnerEquipment, headTs}`). Two surgical repoints, both behind the same segment-derived flag:
1. **`timelineHead.running_po_id`** — source from the open-segment owner, not the header subselect. STALE_HEAD then compares against the PO actually running on B wherever homed.
2. **`classifyDrift` orphan predicate** — repoint from owner's *header* id_equipment to the *runtime row's* id_equipment. "Segment on B owned by a PO homed on A" is a **healthy running shape**, not an orphan. Real orphan narrows to `openPoId == null`.

Everything else (4-gate ladder, degrade-to-allow, `po_gate_degraded_total`, temporal/horizon logic) untouched. **Flip gate + DAO + worker together, per tenant** — mixed header/segment derivation false-rejects.

## 4. OEE denominator fix (recalc.go)

**Bug (lines 84–95):** denominator uses the header's single `ideal_speed`; counts already sum across segments. **Fix:** move the ideal-speed multiply *inside* per-segment aggregation, join `equipments` on the segment's `id_equipment` (`ca.id_equipment`), then sum capacity:

```
capacity = Σ_segments ( (segment.available_time / 60) × segment_line_ideal_speed )
OEE      = net / capacity
```

Prefer the already-materialized per-segment `production_orders_runtime.ideal_production` if populated. **Parity story:** for single-segment POs the segment id == header id → **byte-identical denominator**. Provably parity-preserving on the existing corpus; only differs for ≥2 segments (the new capability). Add a dedicated per-line OEE assertion for the multi-line rows.

## 5. Control-plane, routing, UI

**New verb (edge-api): "also-run-PO-X-on-line-B"** — opens a 2nd runtime segment for a PO already running elsewhere; does NOT touch header `id_equipment`. `INSERT production_orders_runtime (id_production_order=X, id_equipment=B, runtime_timerange=[now,), recalc_needed=true)`; guard rejects if B already has an open segment (EXCLUDE backstops).

**Routing:**
- **MVP (operator-driven):** operator SPA issues the verb to edge-api directly; Node-RED/PackML unchanged. Reversible, low blast radius. **Recommended.**
- **Full (PLC-driven):** edge-node-red publishes X's start on B's topic; deferred past MVP.

**`uns_equipment_current_job` (PK = id_equipment):** naturally fine — same PO on A and B = two rows, one per line.

**Operator UI:** line-picker for "also run on B"; multi-line PO view; `findCurrentPo` must tolerate a PO homed elsewhere. The dormant `attention_get_other_line_op` seam is the natural hook.

**`id_equipment_executed` decision:** **segments-only; leave it inert.** The authoritative "which lines executed this PO" is the set of `production_orders_runtime.id_equipment` rows — richer and already populated. May later serve as a backward-compat convenience column for header-reading consumers during transition, but never the source of truth.

## 6. Target-quantity semantics

**One header target, produced across lines — no schema change.** Per-line contribution is already at segment granularity (`gross_production` per `id_equipment`). Per-line **sub-targets** = a separate ADR (allocation policy, not a correctness requirement).

## 7. Sequencing & phased build plan

| Phase | Ships | Flag | Validation | Rollback |
|---|---|---|---|---|
| **0 — Foundation (in flight)** | #32 gate 1.5 + #34 close-first/backfill + **enforce real runtime EXCLUDE** + fix trigger T8 | `PO_STALENESS_GATE_ENABLED` | `po_gate_degraded_total`→0; overlap-SELECT = 0 rows | drop EXCLUDE; flag off = inert |
| **1 — Segment-derived running-model** | shared "open-segment owner on E" resolver; repoint R1, T3–T7 + gate (§3); **fix T2 latent bug** | `PO_RUNNING_MODEL_SEGMENT_DERIVED` (new, per-tenant) — gate+DAO+worker flip together | comparator: single-line byte-identical | flag off → header path |
| **2 — OEE denominator** | recalc.go per-segment capacity | reuse Phase-1 flag or `OEE_DENOM_PER_SEGMENT` | comparator: single-segment OEE% byte-identical | flag off → header ideal |
| **3 — Control-plane verb (MVP)** | edge-api "also-run-on-B" (opens 2nd segment) | `CONCURRENT_PO_ENABLED` per-tenant | PO on A+B, Σ segment-gross == PO gross, per-line OEE, header rolls up | flag off → 404 |
| **4 — Operator UI** | line-picker, multi-line view, cross-home `findCurrentPo` | UI flag per tenant | per-line start/stop; no single-line regression | hide UI |
| **5 — Hasura/reports (full)** | T9 views + T10 exports segment-derived; optional PLC routing | per-tenant | Hasura "current PO" matches DAO | keep header-identity views alongside |

**MVP = Phases 0–4, one pilot tenant, operator-driven, one header target.** **Full = Phase 5.**

## 8. Risks

1. **Running-PO recast is the dangerous change** — blast radius = every operator screen + gate + pocontrol + Hasura. Mitigation: one shared resolver, single per-tenant flag, gate+DAO+worker flipped together, header-identity default fallback, parity comparator asserting single-line byte-identity first.
2. **T2 latent bug** (`execEnd` closes by `id_production_order` alone) — must land in Phase 1 with a test that opens A+B and ends only B.
3. **Runtime EXCLUDE — CONFIRMED present/valid/enforcing on F2+F3+prod (dba 2026-07-15); prod overlap-clean (0/0).** No constraint-add needed. Residual: it does not bound *lone* zombies (that's the close-first *code*), and it bypasses `id_equipment IS NULL` rows (2 in prod). Prod-cutover work is a *data-quality* cleanup of 13 durable orphans + 2 NULL-equipment rows — a prod write, deferred.
4. **Header status rollup regressions** — any consumer reading `status` as "this machine's state" may misread. Audit `status`-readers alongside T9.
5. **Gate flag-skew false-rejects** — flip gate + callers atomically per tenant.
6. **Comparator blind spot** — multi-line OEE% is net-new math with no tsp12 precedent. Add a dedicated per-line OEE assertion.

## Decisions (resolved 2026-07-15)

1. **Routing for MVP** — ✅ **Operator-driven.** Operator SPA calls a new edge-api verb that opens a 2nd runtime segment directly; no Node-RED/PackML change. PLC-driven fanout deferred past MVP.
2. **Per-line sub-targets** — ✅ **Separate ADR.** MVP ships one header target produced across lines; per-line contribution already tracked via segment `gross_production`. Sub-targets revisited only on tenant demand.
3. **Pilot tenant** — ✅ **CPACK** (ent 1, tp=3 lines, clean parity baseline).
4. **The EXCLUDE pre-req** — ✅ **Read-only prod overlap-audit approved.** dba runs SELECT-only (`pg_constraint` check + overlap scan on closed segments) on prod to confirm whether the one-open-segment invariant is actually enforced today. Folds into #34.
