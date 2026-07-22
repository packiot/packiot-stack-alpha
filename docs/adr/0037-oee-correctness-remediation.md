# ADR-0037 — OEE Correctness Remediation: prioritized findings, each slotted into a medallion layer

**Status:** Proposed · **Date:** 2026-07-22 · **Scope:** DESIGN ONLY (this ADR is the prioritized remediation backlog + where each fix belongs; no code ships with it). STAGING-first; prod-touching steps gated. · **Decision owner:** data/platform architect (pending USER review).

**Companion ADR:** [ADR-0036 — Data Architecture: streaming Bronze/Silver/Gold medallion](0036-data-architecture-medallion.md). **0036 is the structural home for every fix below.** Each finding here names the medallion **layer** (Bronze / Silver / Gold) it belongs in — those layers are *defined* in 0036. The two ADRs are a pair: 0036 builds the layers, 0037 fills them, in priority order.

**Builds on / relates to:**
- [ADR-0014](0014-extract-oee-math-from-database-to-app.md) — extracting OEE math to the app is what *created* the F1(legacy pg)/F3(Go) two-implementation surface these findings live on.
- [ADR-0029 (decisions resolved 2026-07-20)](0029-decisions-resolved-2026-07-20.md) — its **D5 / #80 ruling** ("backend prorates the proportional_target") is the *assumption finding (a) violates* on the F3 read plane. This ADR corrects the record.
- [ADR-0032](0032-collapse-to-single-flow-f3.md) — the collapse to F3 just made F3 the *read plane*, which is what turns finding (a) from "shadow curiosity" into "live-misleading." Correctness now matters because F3 is what users see.
- The #456 two-writer double-count post-mortem (`.../feedback_bug_two_writer_line_double_count.md`) and the int4-overflow / EventMint-scope bug (`.../feedback_bug_eventmint_deriver_scope_mismatch.md`) — findings (h) and (b) are the *same bug classes* recurring; this ADR generalizes them.

> **Numbering:** `0035` is a concurrent Redis-cache ADR; `0036` is this ADR's companion. This is `0037`.

---

## 1. Thesis

**Most of these findings are not independent bugs — they are symptoms of one structural absence: there is no Silver validation layer (ADR-0036 §4) and no reprocess-able Bronze (ADR-0036 §3).** When invariants (`0≤A,P,Q,OEE≤1`, `net≤gross`, counter monotonicity, single-writer-per-tenant) have no designated home, they get implemented ad hoc in whichever of the two OEE engines — F1 (legacy pg, `edge-node-red/db/20-oee-engine-parity.sql`) or F3 (Go, `services/oeecloud-worker/` + `services/edge-transformer/`) — happened to touch the code, and the two **diverge**. Every P1/P2 finding below is a divergence or an absence. **The fix is not N point patches; it is standing up ADR-0036's layers and moving each finding into the right one.** The point patches are the *interim* mitigations; the layer is the durable cure.

The findings below are **verified against the code** and re-cite the exact file/line.

---

## 2. Priority 1 — urgent (live-misleading on the F3 read plane, or silent data corruption)

### (a) F3 writes `proportional_target` FULL-SHIFT, not elapsed-prorated — for all tp — **[Silver]**

**Finding.** In F3, `rollup/shift.go:191` writes:

```sql
proportional_target = COALESCE(pt.vl_day * ((sh.shift_size - ev.ts_planned) / (3600 * 24)), 0)
```

This uses **`sh.shift_size`** — the *full* shift duration — so mid-shift a machine's target shows the **entire shift's** target, not the fraction earned by elapsed time. It is applied uniformly to **all** `tp_equipment`.

The **legacy F1 engine prorates by elapsed time**:
- tp=1/tp=2 base loop (`20-oee-engine-parity.sql:13092-13111`): `proportional_target = target * (extract(epoch from (least(now(), r.ts_end) - r.ts_value)) / nullif(r_shift.shift_size, 0))` — elapsed, capped at shift end, **single writer** (the comment at `:13099-13101` explicitly warns the post-loop block stays commented to avoid the two-writer double-count).
- tp=3 line (`:13322-13325`): `proportional_target = target * (extract(epoch from now() - e.ts_value) / r_shift.shift_size)` — elapsed.

**Impact.** Now that ADR-0032 flipped F3 to be the **read plane**, every dashboard/refdata tile reading `proportional_target` mid-shift is **inflated to the full-shift value** — a machine 10% into its shift shows 100% of the shift target as "expected so far," making live pace look far behind. This **directly violates the ADR-0029 D5 / #80 ruling**, which decided the *backend* prorates the target (front4 was changed to trust the backend). The backend (F3) does not prorate. The ruling's assumption is false in the shipped code.

**Layer & fix — Silver.** Proration is a *conforming/validation* transform → Silver. Change `shift.go:191` to the **elapsed-prorated, shift-end-capped, single-writer** formula that matches F1's base loop (`:13092-13111`), applied uniformly to all tp. Because F3 is the read plane, this is the highest-visibility fix. With ADR-0036's Bronze in place, **replay** corrects historical `proportional_target` too, not just going forward.

### (b) Out-of-order / late message → phantom production (no monotonicity guard) — **[Silver, + Bronze reprocess]**

**Finding.** The count Calc treats **any** payload lower than the previous value as a counter *reset*, rebaselines to 0, and re-emits the full new value as an increment. `calc_production_counters/calc.go:221-256`:

```go
case CounterKindProcessed:
    curProcessed = msg.Payload
    if prevProcessed < curProcessed { sendMsg = true }        // normal increment
    if prevProcessed > curProcessed {                          // ← ANY decrease = "reset"
        prevProcessed = 0                                      //   rebaseline to zero
        resetLineScrap = true
        sendMsg = true                                         //   → next increment = FULL curProcessed
    }
```

There is **no timestamp-monotonicity check.** RabbitMQ **reorders** messages across `nack`/`requeue` (redelivery, multiple consumer lanes) — so a *late* message carrying an *older, smaller* totalizer reading arrives *after* a newer, larger one, looks like `prev > cur`, is misread as a reset, and the *next* legitimately-larger reading then emits as a **full-value increment from zero → phantom production**. This is the **same bug class** as the int4-overflow incident (`feedback_bug_eventmint_deriver_scope_mismatch.md`): unbounded values from a scope/ordering mismatch.

**Layer & fix — Silver (with Bronze reprocess).** Add a **per-counter timestamp-monotonicity guard**: a message whose `ts_value` is not strictly newer than the last-processed `ts_value` for that (equipment, counter) is **not** allowed to trigger the reset path — it is either dropped as late or buffered/reordered before delta computation. This is a Silver cleaning rule (delta/reset disambiguation, ADR-0036 §4). Historical phantom production is corrected by **replaying Silver over Bronze** (ADR-0036 §3.3) once the guard is in.

---

## 3. Priority 2 — correctness defects (systematically wrong OEE, not yet as loud as P1)

### (c) Changeover excluded from Availability (Six-Big-Losses violation) — **[Silver]**

**Finding.** `13-downtime-reasons-seed.sql:45-47` seeds:

```json
{ "code": "CHANGEOVER", "description": {"en-US": "Changeover / Setup"},
  "planned_downtime": true, "change_over": true, "idle": false }
```

`planned_downtime=true` means changeover time is subtracted from **Planned Production Time** (the availability denominator: `ts_total - ts_planned`, e.g. `shift.go:168`, `20-…:13276`). In the **Six Big Losses** OEE model, **changeover/setup is an Availability loss** (unplanned-ish downtime *within* production time), **not** planned downtime removed from the clock. Flagging it planned **removes the loss from the measurement** → Availability (and OEE) reads artificially high; the loss the metric exists to expose becomes invisible.

**Layer & fix — Silver.** One-flag change: `planned_downtime: false` for `CHANGEOVER` (keep `change_over: true` so it's still categorized/reported as changeover). Changeover then correctly sits **inside** Planned Production Time and depresses Availability as a real loss. This is a Silver dimensional-conforming rule (how a downtime reason maps to the availability model). *Caveat to validate:* confirm no tenant contractually treats planned changeover as excluded; if so, make it per-tenant policy in Silver rather than a global flag.

### (d) Performance is an uncapped residual `oee/(A×Q)` → oee>1 up to 5349 — **[Silver clamp + Gold alert]**

**Finding.** Performance is never measured directly; it is **back-solved** as the residual `oee_p = oee / (oee_a × oee_q)`:
- F1: `20-oee-engine-parity.sql:13282` — `oee_p = coalesce(e.oee / nullif(e.oee_a * e.oee_q, 0), 0)`
- F3: `grains.go:103` — `oee_p = COALESCE(e.oee / NULLIF(e.oee_a * e.oee_q, 0), 0)`

Since `oee = net / ideal_production` and `ideal_production` depends on `ideal_speed` (`e.ideal_speed`, param 30701), a **mis-set / too-low `ideal_speed`** makes `net > ideal_production` → `oee > 1` → `oee_p > 1`. The golden tests document values as high as **5349** being model-permitted. A performance/OEE of 5349× is nonsense presented as fact.

**Layer & fix — Silver clamp + Gold alert.**
- **Silver:** cap `oee_p` (and `oee`) at 1.0 via the `[0,1]` invariant (finding (e)); **and** measure performance *directly* where possible (`avg_speed / ideal_speed`, as the dead dev-UNS already does — `14-oee-uns-compute.sql:77`: `LEAST(agg.avg_speed / agg.ideal_speed, 1.0)`) rather than as a residual, so a bad `ideal_speed` can't silently inflate it.
- **Gold:** **alert on `oee > 1`** (or `oee_p > 1`) — it is a reliable *signal of a mis-set 30701 ideal_speed*, i.e. a data-quality tripwire, not something to silently clamp away. Clamp for the served value, alert for the operator to fix the config.

### (e) No `[0,1]` / `net ≤ gross` / non-negativity invariants anywhere — **[Silver]**

**Finding.** There is **no** enforcement of the basic OEE invariants (`0 ≤ A,P,Q,OEE ≤ 1`; `net ≤ gross`; all counters/times `≥ 0`) on the served path. The **only** `[0,1]` clamps in the codebase are the **dead** dev-UNS `LEAST(...,1.0)` in `14-oee-uns-compute.sql:77,95` — and that function is a compose-dev sidecar explicitly **replaced by pg_cron in staging/prod** (`14-…:14-16`). So in the flows that actually serve users, nothing bounds these values. Findings (a)/(b)/(d)/(f)/(g) are all *instances* of "an invariant that would have caught this doesn't exist."

**Layer & fix — Silver (the core deliverable).** This **is** the Silver invariant contract of ADR-0036 §4: assert, in one place applied to every writer, `0 ≤ A,P,Q,OEE ≤ 1`, `net ≤ gross`, non-negativity — *before* Gold. Violations are clamped for serving **and** surfaced as data-quality events (tie to (d)'s alert). This single finding, done properly, subsumes several others.

### (f) Counter rollover conflated with reset → undercount — **[Silver]**

**Finding.** The same `prev > cur ⇒ reset-to-zero` logic in (b) (`calc.go:227-231, 237-241, 247-251`) cannot distinguish a **PLC counter rollover** (a fixed-width totalizer wrapping past its max back toward 0 — genuine production continues) from a **reset** (operator/PLC zeroing the counter — no production). Both look like `prev > cur`. On rollover, treating it as a reset **discards the production between the last reading and the wrap** → undercount.

**Layer & fix — Silver.** Add a **per-equipment `counter_max`** (the totalizer's wrap width). When `prev > cur` **and** the drop is consistent with a wrap (`prev` near `counter_max`, `cur` small), compute the increment as `(counter_max - prev) + cur` (rollover) instead of rebaselining (reset). This is a Silver counter-math rule; it belongs next to the monotonicity guard (b) in `counter_math.go`. Requires a per-equipment `counter_max` in refdata.

### (g) Sub-second `ON CONFLICT` overwrite → undercount on fast lines — **[Bronze]**

**Finding.** `equipment_values` keys on `UNIQUE(ts_value, id_equipment)` with `ts_value` truncated to 1-second resolution; every writer does `ON CONFLICT (ts_value, id_equipment) DO UPDATE` (`internal/writers/equipment_values.go:359,392,425,456,486`). Two samples from the same equipment **within one second overwrite each other** → on fast lines, sub-second production is silently lost.

**Layer & fix — Bronze.** This is **resolved structurally by ADR-0036 §3.4**: a proper append-only Bronze either carries a finer-grained (sub-second) `ts_value` or a monotonic ingest sequence / synthetic row id as a tiebreak, so **no raw sample is ever lost to a key collision.** This is the clearest example of "the structural fix (immutable Bronze) subsumes the point patch" — don't band-aid the conflict clause; fix it by making Bronze append-only.

### (h) Single-writer-per-tenant not structurally enforced — **[Silver, structural]**

**Finding.** Per-tenant write serialization relies on **in-process `memState`** (`edge-transformer/.../calc_production_counters/state.go`) while the worker runs **`CONSUME_LANES=4`** (multiple concurrent consumers). Nothing at the *data layer* guarantees one writer per tenant/counter. The **#456 two-writer double-count** (`feedback_bug_two_writer_line_double_count.md`: legacy line derivation 65k + new Calc line emission 44k = 109k, oee>1.0) is exactly what happens when two writers touch one row — it was fixed by *suppressing* one emitter, but the *structural* guarantee is still absent. The `shift.go:219` non-blocking advisory lock and the `LEAST(...)` over-mint guards (`shift.go:176-181`) are *symptomatic defenses* against the same missing invariant.

**Layer & fix — Silver (structural).** Make single-writer-per-tenant a **structural invariant**, not an in-process convention: consistent-hash tenants/counters to lanes so a given (tenant, counter, grain-row) is only ever handled by one lane; or enforce at the DB with the write path owning a per-(tenant,row) advisory lock; or partition queues by tenant. This is the "single-writer-per-tenant" clause of the ADR-0036 §4 Silver contract. Until structural, keep the interim guards (they're cheap insurance).

---

## 4. Priority 3 — data-model gaps & hygiene (wrong-by-omission, lower blast radius)

| # | Finding | Evidence | Layer | Fix |
|---|---------|----------|-------|-----|
| P3-1 | **`scrap_targets` never computed** — table exists but is only *read* by a Hasura view; no engine writes it. | `10-missing-tables.sql:122` defines `scrap_targets`; no writer in `services/` or `20-…sql`. | Silver→Gold | Model scrap target as a **rate** (PPM or %) and **prorate** it like proportional_target (finding a), then write it in the rollup. A scrap *count* target is meaningless without a production base; a rate is comparable across run lengths. |
| P3-2 | **Missing per-equipment `production_target` → 0, no fallback** — if an equipment has no `production_targets` row, target silently becomes 0 (no area/site fallback). | `20-…:13084` selects `vl_day` into `r_target` with no fallback; F3 `shift.go:193` inner-joins `production_targets` (rows with no target row get **no** proportional_target at all). | Silver | Add **area→site fallback** resolution for `production_target` (mirror the shift system's area-first/site-fallback pattern from CLAUDE.md). Missing-at-all-levels → data-quality alarm, not silent 0. |
| P3-3 | **`vl_shift` stored but never read** — dead target column. | `production_targets.vl_shift` (`10-missing-tables.sql:112`) written but no read path uses it (rollup derives shift target from `vl_day` proration instead). | Gold/hygiene | Either wire `vl_shift` as the authoritative shift target (replacing the `vl_day/24×…` proration) or drop it. Decide one; don't leave a stored-but-ignored column masquerading as config. |
| P3-4 | **`ideal_speed` 0/NULL silently yields 0 performance/OEE** — no alarm. | `shift.go:179` `NULLIF(e.ideal_speed,0)`, `14-…:76-78` `ELSE 0.0`; a 0/NULL nameplate speed makes `ideal_production=0` → `oee=0` silently. | Silver→Gold alert | Emit a **data-quality alarm** when `ideal_speed` is 0/NULL for equipment that is producing (net>0). Pairs with (d)'s oee>1 alert — both are "30701 mis-set" tripwires (too-low → oee>1; zero → oee=0). |
| P3-5 | **Denominator not standardized** — "elapsed" vs "planned production time" vs "scheduled" used inconsistently across grains. | Availability uses `ts_total - ts_planned` (`shift.go:168`); proportional_target uses `shift_size` (a); different grains re-derive. | Silver | Standardize the elapsed denominator on **scheduled-productive time** (planned production time = scheduled − planned-downtime) everywhere, defined once in Silver, so every metric shares one clock. |

---

## 5. Prioritized remediation sequence

Ordered by (visibility × correctness impact) ÷ effort, and by ADR-0036 layer dependency (Bronze/Silver scaffolding first where a fix needs replay):

1. **(a) proportional_target elapsed-prorate** — *P1, Silver, one formula.* Highest visibility (F3 is the read plane; violates the #80 ruling live). Ship first; `shift.go:191`.
2. **(b) monotonicity guard** — *P1, Silver+Bronze.* Stops silent phantom-production corruption; `calc.go`. Land **with/after ADR-0036 Bronze B0/B1** so the corrupted history can be replayed out.
3. **(e) `[0,1]`/`net≤gross`/non-negativity invariants** — *P2, Silver core.* The Silver contract itself; subsumes (d)-clamp, guards (a)/(b)/(f) regressions. Build as ADR-0036 §4's deliverable.
4. **(d) performance cap + direct-measure + oee>1 alert** — *P2, Silver+Gold.* Rides on (e)'s clamp; adds the direct measure + tripwire. `grains.go:103`, alert in Gold.
5. **(c) changeover → Availability** — *P2, Silver, one flag.* `13-downtime-reasons-seed.sql:47`. Cheap; validate no tenant depends on old behavior.
6. **(h) single-writer-per-tenant structural** — *P2, Silver structural.* Higher effort (lane hashing / partitioning); interim guards stay meanwhile.
7. **(f) rollover vs reset (`counter_max`)** — *P2, Silver.* Needs a refdata `counter_max`; pairs with (b) in `counter_math.go`.
8. **(g) sub-second collision** — *P2, Bronze.* Resolved by ADR-0036 §3.4 append-only Bronze (B1); not a standalone patch.
9. **P3-1…P3-5** — *P3, model/hygiene.* Schedule after P1/P2; P3-2 (target fallback) and P3-4 (ideal_speed alarm) are the highest-value of the batch.

**Bronze/Silver dependency:** items needing **replay** to fix *history* (a, b, d) are only fully resolved once ADR-0036's Bronze (immutable, retained) + reprocessing loop exist. Items 1–9 can each ship forward-only first, but the *retroactive* correction of already-wrong history is an ADR-0036 capability. **This is the core coupling: ADR-0037's fixes are durable only inside ADR-0036's layers.**

---

## 6. Consequences

**Positive:** the F3 read plane stops being live-misleading (a); silent corruption classes (b, f, g) close; OEE values become bounded and trustworthy (d, e); the Six-Big-Losses model is correctly implemented (c); the recurring two-writer bug class gets a structural cure (h). Crucially, once ADR-0036 Bronze lands, **history is corrected by replay**, not just the future.

**Negative / risks:** clamping/altering formulas will **change numbers users have seen** — some tenants may have baselined against the (wrong) high OEE; roll out per-tenant with comms. The monotonicity guard (b) and rollover logic (f) change delta semantics — validate against golden tests (`calc_test.go`, `golden_test.go`, `day_clamp_golden_test.go`) before flipping. Replaying long windows is I/O-heavy (ADR-0036 §7 risk) — throttle via the existing `recalc_needed` batching. Changeover reflag (c) needs a tenant-policy check.

**Verification:** each fix must (i) pass/extend the existing golden tests, (ii) show the invariant now holds on staging for CPACK (ent 3) + Incoplast (ent 4), and (iii) where it changes history, demonstrate a bounded replay corrects the affected window. Prod stays SELECT-only for us; any prod formula/schema change goes through the normal prod-apply gate.

---

## 7. The one-sentence coupling

**Most findings here are the absence of a Silver validation layer plus a non-reprocess-able Bronze — so [ADR-0036](0036-data-architecture-medallion.md) is the structural home, and this ADR is the prioritized list of what to put in it.**
