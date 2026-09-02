# ADR-0037 — OEE Correctness Remediation: prioritized findings, each slotted into a medallion layer

**Status:** Proposed (Step 0 + output-clamp SHIPPED — see §8) · **Date:** 2026-07-22 · **Updated:** 2026-07-23 · **Scope:** DESIGN ONLY *as originally written*; the instrument-before-remediate substrate (§4A) and the served-path output clamp have since shipped and are live-verified against `packiot_shadow` (§8). STAGING-first; prod-touching steps gated. · **Decision owner:** data/platform architect (pending USER review).

> **⏱ Currency note (2026-07-23).** Two of this ADR's load-bearing decisions have **shipped and are live-verified on `packiot_shadow`**: (1) the **`data_quality_event` substrate** (§4A) exists, is wired into the rollup tick, and is **populated (1606 rows, 2026-07-22→23)**; (2) the **output-invariant clamp** (findings (d)/(e), #576) bounds the served path — `equipment_runtime_shift` now has **0 of 9412** rows with `oee>1` (`max_oee = max_oee_p = 1.00`). The huge `oee` figures cited below (5349 / 8142 / 13918 / 10¹⁸) are **pre-clamp** — kept as the *justification* that motivated the fix, not the current served reality. The **ingest/Calc-side** cleaning findings (a monotonicity/rollover/single-writer — (a)/(b)/(f)/(h)) remain **open**, correctly gated behind ADR-0036's Bronze/collapse. Full ledger: **[§8 — Status as of 2026-07-23](#8-status-as-of-2026-07-23)**. Narrative below is annotated in place, not rewritten.

**Companion ADR:** [ADR-0036 — Data Architecture: streaming Bronze/Silver/Gold medallion](0036-data-architecture-medallion.md). **0036 is the structural home for every fix below.** Each finding here names the medallion **layer** (Bronze / Silver / Gold) it belongs in — those layers are *defined* in 0036. The two ADRs are a pair: 0036 builds the layers, 0037 fills them, in priority order.

**Builds on / relates to:**
- [ADR-0014](0014-extract-oee-math-from-database-to-app.md) — extracting OEE math to the app is what *created* the F1(legacy pg)/F3(Go) two-implementation surface these findings live on.
- [ADR-0029 (decisions resolved 2026-07-20)](0029-decisions-resolved-2026-07-20.md) — its **D5 / #80 ruling** ("backend prorates the proportional_target") is the *assumption finding (a) violates* on the F3 read plane. This ADR corrects the record.
- [ADR-0032](0032-collapse-to-single-flow-f3.md) — the collapse to F3 just made F3 the *read plane*, which is what turns finding (a) from "shadow curiosity" into "live-misleading." Correctness now matters because F3 is what users see.
- The #456 two-writer double-count post-mortem (`.../feedback_bug_two_writer_line_double_count.md`) and the int4-overflow / EventMint-scope bug (`.../feedback_bug_eventmint_deriver_scope_mismatch.md`) — findings (h) and (b) are the *same bug classes* recurring; this ADR generalizes them.
- [ADR-0038 — North-Star target architecture](0038-north-star-factory-platform.md) — its **P11 Alerting/Andon → B2** pillar is "THIN/MISSING (business alarms)." The **`data_quality_event` substrate decided in §4A below is the concrete seed of B2** — the first business-alarm surface the platform grows. 0038 sets the destination; §4A lays the first stone.
- [ADR-0039 — Entity lifecycle & deletion strategy](0039-entity-lifecycle-deletion-strategy.md) — findings **P3-2** (missing `production_target`, no area/site fallback) and **P3-4** (0/NULL `ideal_speed`) are partly *entity-integrity* gaps: config that should never be absent for a producing equipment. 0039 owns the entity contract (temporal columns, one delete path, restored FKs) that keeps that config present; this ADR alarms when it isn't (rule `METRIC_MISSING_ALL_LEVELS` / `IDEAL_SPEED_NULL_WHILE_PRODUCING`, §4A).

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

### (d) Performance is an uncapped residual `oee/(A×Q)` → oee>1 up to 5349 — **[Silver clamp + Gold alert]** — ⏱ **clamp SHIPPED 2026-07-23 (#576)**

**Finding.** Performance is never measured directly; it is **back-solved** as the residual `oee_p = oee / (oee_a × oee_q)`:
- F1: `20-oee-engine-parity.sql:13282` — `oee_p = coalesce(e.oee / nullif(e.oee_a * e.oee_q, 0), 0)`
- F3: `grains.go:103` — `oee_p = COALESCE(e.oee / NULLIF(e.oee_a * e.oee_q, 0), 0)`

Since `oee = net / ideal_production` and `ideal_production` depends on `ideal_speed` (`e.ideal_speed`, param 30701), a **mis-set / too-low `ideal_speed`** makes `net > ideal_production` → `oee > 1` → `oee_p > 1`. The golden tests document values as high as **5349** being model-permitted. A performance/OEE of 5349× is nonsense presented as fact.

**Layer & fix — Silver clamp + Gold alert.**
- **Silver:** cap `oee_p` (and `oee`) at 1.0 via the `[0,1]` invariant (finding (e)); **and** measure performance *directly* where possible (`avg_speed / ideal_speed`, as the dead dev-UNS already does — `14-oee-uns-compute.sql:77`: `LEAST(agg.avg_speed / agg.ideal_speed, 1.0)`) rather than as a residual, so a bad `ideal_speed` can't silently inflate it.
- **Gold:** **alert on `oee > 1`** (or `oee_p > 1`) — it is a reliable *signal of a mis-set 30701 ideal_speed*, i.e. a data-quality tripwire, not something to silently clamp away. Clamp for the served value, alert for the operator to fix the config.

> **Update (2026-07-23, SHIPPED — #576).** The **served-value clamp is live** at the Go rollup tick, and the **tripwire is wired**: `equipment_runtime_shift` now shows **0 of 9412** rows with `oee>1` (`max_oee = max_oee_p = 1.00`) — the "up to 5349 / 8142" blow-ups are **no longer served**. The clamp emits `data_quality_event` rows so the clamp *and* the alert both fire (`INVARIANT_CLAMPED_OEE`/`OEE_P`/`OEE_Q` clamp actions + `OEE_GT_1` detect tripwire — §4A). **Still open:** the *direct* performance measure (`avg_speed / ideal_speed` instead of the residual) — the clamp bounds the residual but doesn't yet replace it, so a mis-set `ideal_speed` is now *caught and clamped* rather than *measured around*.

### (e) No `[0,1]` / `net ≤ gross` / non-negativity invariants anywhere — **[Silver]** — ⏱ **served-path clamp SHIPPED 2026-07-23 (#576)**

> **Update (2026-07-23) — "anywhere" is now false for the SERVED path.** The output invariants (`0 ≤ A,P,Q,OEE ≤ 1`, `net ≤ gross`, non-negativity) are now **enforced at the rollup tick** on the served heap tables (#576) and every clamp/violation writes a `data_quality_event` row (§4A). The served path is bounded — `equipment_runtime_shift`: **0/9412** `oee>1`. **Reword the finding as:** *output* invariants are now enforced at the Silver→Gold rollup boundary; what remains missing is the **ingest/Calc-side cleaning** half — the monotonicity guard (b), rollover/reset disambiguation (f), and structural single-writer (h) that stop bad values *entering* rather than clamping them *on exit*. The finding's diagnosis stands; its "nothing bounds these values" conclusion no longer holds at the read plane.

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

## 4A. The data-quality event substrate — where the alarms these findings demand actually land — **[Gold-adjacent] · NEW DECISION → BUILT + WIRED 2026-07-23**

> **Update (2026-07-23, SHIPPED + WIRED — live-verified on `packiot_shadow`).** This is no longer a "NEW DECISION" — **`data_quality_event` exists, is written by the rollup tick, and is populated: 1606 rows over 2026-07-22→23.** The live table splits into two families of `rule`: **clamp actions** — `INVARIANT_CLAMPED_OEE` / `INVARIANT_CLAMPED_OEE_P` / `INVARIANT_CLAMPED_OEE_Q` / `INVARIANT_CLAMPED_NEGATIVE` (emitted when #576 clamps a served value) — and **detect tripwires** — `OEE_GT_1` / `NET_GT_GROSS` / `NEGATIVE_METRIC` (emitted when a check trips without necessarily clamping). The live enum is thus a **superset** of the sketch below (which listed only the detect side plus the two config-gap rules `IDEAL_SPEED_NULL_WHILE_PRODUCING` / `METRIC_MISSING_ALL_LEVELS`). **"Instrument-before-remediate" is live**, not planned.

Findings **(d)** (`oee > 1` → *"alert on it"*), **P3-2** (missing target → *"data-quality alarm, not silent 0"*), and **P3-4** (0/NULL `ideal_speed` → *"emit a data-quality alarm"*) each **end in an alarm** — but **no table exists to emit that alarm into.** An alarm with no sink is a TODO, not a decision. Three findings already reached for the same missing thing; this section supplies it once, as a first-class substrate, so the rest of the backlog stops re-inventing it inline.

### Decision — a single `data_quality_event` table (gold-adjacent)

DECIDE one tenant-scoped, grain-tagged event table that every invariant/validation check writes a row into when it trips. It sits **beside Gold** (not inside a runtime rollup row) so a served metric and the fact that it was flagged are separable — a dashboard can show the number *and* a "this value is suspect" badge.

```sql
-- Gold-adjacent data-quality event sink (design sketch; windows/enum tuned in S-phase).
-- Written by the rollup tick; read by the P11-B2 alarm/andon surface (ADR-0038).
CREATE TABLE data_quality_event (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_enterprise  int         NOT NULL,               -- tenant (multitenancy fence, ADR-0012 pool)
  id_equipment   int         NOT NULL,               -- entity at fault
  bucket         text        NOT NULL,               -- grain: 'shift' | '1hour' | '1day' | ...
  ts_range       tstzrange   NOT NULL,               -- grain window the violation was observed in
  rule           dq_rule     NOT NULL,               -- which invariant tripped (enum below)
  observed_value double precision,                   -- the offending value (e.g. oee=8142, ideal_speed=NULL→NULL)
  severity       dq_severity NOT NULL DEFAULT 'warn',-- 'info' | 'warn' | 'critical'
  detected_at    timestamptz NOT NULL DEFAULT now()  -- when the check saw it
);

CREATE TYPE dq_rule AS ENUM (
  'OEE_GT_1',                          -- (d)/(e): oee or oee_p > 1 — mis-set 30701 ideal_speed tripwire
  'NET_GT_GROSS',                      -- (e): net production exceeds gross — impossible, guard breach
  'NEGATIVE_METRIC',                   -- (e): a count/time went < 0
  'IDEAL_SPEED_NULL_WHILE_PRODUCING',  -- P3-4: 0/NULL nameplate speed while net>0 → silent oee=0
  'METRIC_MISSING_ALL_LEVELS'          -- P3-2: no production_target at equipment/area/site → silent 0
);
```

> **As-built enum (2026-07-23).** The **live** `data_quality_event` carries the sketch's detect rules **plus a clamp-action family** the sketch didn't name: `INVARIANT_CLAMPED_OEE`, `INVARIANT_CLAMPED_OEE_P`, `INVARIANT_CLAMPED_OEE_Q`, `INVARIANT_CLAMPED_NEGATIVE` (written when #576 clamps), alongside `OEE_GT_1`, `NET_GT_GROSS`, `NEGATIVE_METRIC` (detect). The two config-gap rules (`IDEAL_SPEED_NULL_WHILE_PRODUCING`, `METRIC_MISSING_ALL_LEVELS`) pair with the still-open P3-4/P3-2 fixes. So "clamp *and* record" is the shipped behavior: a clamped value is both bounded *and* leaves a `INVARIANT_CLAMPED_*` audit row.

`bucket` + `ts_range` pin the violation to a specific grain row so it round-trips to the exact `equipment_runtime_*` window (and survives the **reprocessing/replay** of ADR-0036 §3.3 — a re-computed window re-emits its DQ events idempotently).

### Who writes it, and when — inside the existing rollup tick

The check runs where the numbers are already in hand: the **existing rollup tick** in `services/oeecloud-worker/internal/rollup/` (the same `shift.go`/`hour.go`/`grains.go` pass that computes `oee`, `oee_a/p/q`, `proportional_target`). It is the Silver→Gold boundary — the moment a value is about to be served — so it is the correct, single place to assert the invariants of finding (e) and, on breach, `INSERT` a `data_quality_event` rather than (or in addition to) silently clamping. **No new service, no new consumer of the message bus** — one function called from the tick that already runs.

### This is the seed of the north-star P11-B2 business-alarm pillar

[ADR-0038 §P11 / B2](0038-north-star-factory-platform.md) rates the **business** alerting/andon layer THIN→MISSING (infra Alertmanager exists; OEE-threshold / andon / **metric data-quality** alarms do not — the grep for `andon` returns zero). `data_quality_event` is the **first table of that pillar**: the alarm *evaluation* here produces rows; B2 later adds threshold config, notification transport, and andon widgets *on top of the same table*. Building it now, as the sink for these findings, means B2 is grown, not greenfielded — the highest-value, lowest-cost slice ADR-0038 itself names ("data-quality alarms first within B2").

### Sequencing — **instrument BEFORE remediate** (hard rule)

**The DQ substrate + its alarms ship BEFORE the clamp / `ideal_speed` / proration fixes** (findings (a), (d)-clamp, (e), P3-2, P3-4). The order is not incidental — it is the safety property:

1. **Make the corruption visible and measurable first.** Emit `data_quality_event` rows for every `OEE_GT_1`, `IDEAL_SPEED_NULL_WHILE_PRODUCING`, etc. *while the served numbers are still the (wrong-but-high) values users see today.* This produces a **baseline census** of exactly which tenants/equipment/windows are affected and by how much.
2. **Only then change the served value.** Clamping OEE to 1.0 or fixing proration (a) will *lower* numbers tenants may have baselined against (see §6 "Negative/risks": some tenants baselined on the inflated OEE). Instrumenting first means the drop is *explained by data* ("you had N `OEE_GT_1` events from a mis-set ideal_speed; here they are") instead of appearing as an unexplained regression, and lets the per-tenant rollout + comms be driven off the census rather than guesswork.

The rule generalizes: **a data-quality substrate is an observability change (safe, additive, reversible); a clamp/formula change is a served-value change (visible, needs comms).** Ship the observability change first, always. This orders the remediation sequence in §5.

### Empirical justification — the live-evidence scale (a systemic invariant vacuum, not "3 edge cases")

The audit ran these checks against the **live DB**; the scale reframes the findings from a handful of edge cases into a *missing-invariant regime*:

| Signal (live-DB observed) | Scale | What it proves |
|---|---|---|
| `ideal_speed` NULL-or-0, **shift** grain | **90.3%** of rows | The 30701 config gap (P3-4) is the *norm*, not the exception — the availability/performance base is unset for the vast majority of shift rows. |
| `ideal_speed` NULL-or-0, **hourly** grain | **96.8%** of rows | Same gap, worse at finer grain. `IDEAL_SPEED_NULL_WHILE_PRODUCING` would fire on nearly every producing hour. |
| `oee` maximum, **shift** grain | **8,142** | Not the golden-test-permitted 5349 (finding (d)) — an actual served-tier value three orders of magnitude over 1.0. |
| `oee` maximum, **hourly** grain | **13,918** | Finer grain, larger blow-up — the uncapped residual (d)/(e) compounds. |
| `oee` maximum, **F1 (legacy pg)** | **8.2 × 10¹⁸** | Approaching int/float overflow territory — the *same class* as the int4-overflow incident (`feedback_bug_eventmint_deriver_scope_mismatch.md`); an unbounded metric with no `[0,1]` guard. |
| `oee > 1` distribution | **concentrated on `tp=3` lines** | The **#456 two-writer double-count fingerprint** (`feedback_bug_two_writer_line_double_count.md`): line-level rows double-written (legacy derivation + Calc emission) → oee>1 clusters exactly where finding (h) predicts. |

**Read together:** 90–97% of rows missing a required input, OEE served up to 10¹⁸, and the overflow clustering on the precise entity class a known two-writer bug touches — this is not three isolated defects. It is **finding (e) restated as data**: there is no `[0,1]` / `net≤gross` / non-negativity invariant *anywhere on the served path*, so the values are unbounded by construction. The `data_quality_event` table is what makes that vacuum *countable* (one `SELECT count(*) … GROUP BY rule` is the ongoing census), and the instrument-before-remediate rule is what makes closing it *safe*.

> **Update (2026-07-23) — these figures are the PRE-clamp baseline; the served path is now bounded.** The `oee` maxima above (8,142 shift / 13,918 hourly / 8.2×10¹⁸ on F1) were the *motivating* census — the corruption that justified the fix. After the #576 output clamp, the **served** `equipment_runtime_shift` shows **0 of 9412** rows with `oee>1` (`max_oee = max_oee_p = 1.00`). The `data_quality_event` census the last paragraph calls for is now **real and running** (1606 rows, 2026-07-22→23) — including `INVARIANT_CLAMPED_*` rows that record each value the clamp bounded. The `ideal_speed` NULL/0 config gap (90–97%) is **not** yet closed — that is the still-open P3-4 config-hygiene work; the clamp bounds the *symptom* (unbounded oee), not the *cause* (unset nameplate speed).

---

## 5. Prioritized remediation sequence

Ordered by (visibility × correctness impact) ÷ effort, and by ADR-0036 layer dependency (Bronze/Silver scaffolding first where a fix needs replay). **Step 0 is the instrument-before-remediate gate (§4A):** stand up `data_quality_event` + the invariant *checks* (emit-only) **before** any clamp/formula step below, so corruption is measured while the served numbers are still what tenants see today. The clamps and proration fixes (1, 3, 4) are then rolled out per-tenant off the census those events produce.

0. **`data_quality_event` substrate + emit-only invariant checks** — *§4A, Gold-adjacent, observability-only.* Additive, reversible, changes no served value. Ships FIRST. Seeds ADR-0038 P11-B2. — ✅ **SHIPPED (2026-07-23):** table live + wired, 1606 rows; and step **4 (d) output clamp** shipped alongside it (#576). Steps 1–2, 6–8 (proration, monotonicity, single-writer, rollover, sub-second) remain **open** (ingest/Calc-side, gated behind ADR-0036 Bronze/collapse).
1. **(a) proportional_target elapsed-prorate** — *P1, Silver, one formula.* Highest visibility (F3 is the read plane; violates the #80 ruling live). Ship first *among value-changing fixes*; `shift.go:191`.
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

---

## 8. Status as of 2026-07-23

Live-verified against `packiot_shadow`. The **instrument-before-remediate Step 0 and the output clamp have shipped**; the ingest/Calc-side cleaning findings remain open (correctly gated behind ADR-0036's Bronze/collapse). ✅ shipped · ◑ partial · ⛔ open.

| Finding / step | Layer | Live status 2026-07-23 | Evidence |
|---|---|---|---|
| **§4A `data_quality_event` substrate** (Step 0) | Gold-adjacent | ✅ **SHIPPED + WIRED** | table populated **1606 rows** (2026-07-22→23); written by the rollup tick |
| **(d)/(e) output `[0,1]`/`net≤gross`/non-neg clamp** (#576) | Silver→Gold | ✅ **SHIPPED — served path bounded** | `equipment_runtime_shift`: **0/9412** `oee>1`; `max_oee = max_oee_p = 1.00`. Emits `INVARIANT_CLAMPED_*` + `OEE_GT_1`/`NET_GT_GROSS`/`NEGATIVE_METRIC` rows |
| **instrument-before-remediate ordering** (§4A/§5 Step 0) | process | ✅ **LIVE** | detect + clamp-action DQ rows co-populated |
| **(d) direct performance measure** (`avg_speed/ideal_speed` vs residual) | Silver | ◑ **PARTIAL** | residual is now *clamped*, not yet *replaced* by a direct measure |
| **(a) proportional_target elapsed-prorate** | Silver | ⛔ **OPEN** | `shift.go:191` still full-shift; not covered by this verification pass |
| **(b) monotonicity guard / (f) rollover / (h) single-writer** | Silver + Bronze | ⛔ **OPEN** | ingest/Calc-side cleaning; gated with ADR-0036 Bronze B1 (append-only) |
| **(g) sub-second `ON CONFLICT` overwrite** | Bronze | ⛔ **OPEN** | resolved only by ADR-0036 B1 append-only Bronze — PK still `(id_equipment, ts_value)`, overwrite still live (ADR-0036 §10) |
| **(c) changeover → Availability flag** | Silver | ⛔ **OPEN** | `13-downtime-reasons-seed.sql` still `planned_downtime:true`; not covered this pass |
| **P3-1…P3-5 model/hygiene** (incl. P3-4 `ideal_speed` gap 90–97%) | Silver→Gold | ⛔ **OPEN** | config-gap census countable via DQ table; fixes not yet shipped |

**Net:** the **observability + served-value-safety** half of this ADR is live (DQ substrate + output clamp = the served path can no longer show `oee>1`). The **root-cause cleaning** half — proration, monotonicity, rollover, single-writer, sub-second, and the `ideal_speed` config gap — is still open, and much of it is *durability-coupled* to ADR-0036's unshipped Bronze (B0 retention + B1 append-only). Instrument-first worked exactly as designed: corruption is now measured (and clamped) before the deeper formula fixes land.
