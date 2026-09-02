# ADR-0049 — OEE Correctness: count-spike guard, availability floor, A×P×Q reconciliation

**Status:** Proposed (code SHIPPED behind flags — safe defaults) · **Date:** 2026-08-21
· **Scope:** the Go OEE compute — `services/stream-engine` (rollup) + `services/sparkplug-decoder` (Calc). Does NOT touch the `uns_*` snapshot refreshers.
· **Follows:** ADR-0037 (OEE correctness remediation — output clamp / DQ substrate), ADR-0045 (first-boot totalizer spike), ADR-0036 (medallion / Silver invariant).
· **Decision owner:** data/platform architect (pending USER review + staging rollout).

> **Currency note.** All three fixes ship behind flags. The count-spike **reset-heal** defaults **ON** (`CALC_RESET_HEAL_ENABLED=true`) because the reset-spike is a confirmed correctness fault and the heal is strictly safer; the **availability floor** (`OEE_AVAIL_FLOOR_ENABLED`) and **canonical A×P×Q** (`OEE_CANONICAL_APQ_ENABLED`) default **OFF** so the served numbers do not move until the USER sequences them on staging. Flag-off ⇒ byte-identical to today's rollup (golden fixtures + F2↔F3 identity comparator untouched).

---

## Context — the audit

A senior OEE audit of ent 3 (CPACK-Staging), corroborated by a data engineer and re-verified live against `packiot_analytics` on 2026-08-21, found three coexisting data-correctness faults. Live evidence (25-day window, producing shifts, `net>0`):

| Metric | Value | Meaning |
|---|---|---|
| Producing shifts | 418 | denominator |
| Shifts with `\|oee − oee_a·oee_p·oee_q\| > 0.01` | **251 (60%)** | Fault 3 — identity broken |
| mean `\|Δ\|` | **0.265** | headline vs components diverge by ~27 pts |
| Shifts with `net > full-shift ideal_production` | 45 (**10.8%**) | Fault 1 — count spikes |
| avg `oee_a` / max `oee_a` | **0.214 / 1.0** | Fault 2 — chronic availability under-count |

Worst historical spike (pre-ADR-0045, hour grain): L4 `2026-07-29 14:00` — `net = 1,206,602` against an hourly ideal of `67` (**ratio 18,081×**), `running_time = 0`, stored `oee = 1.0` (fake), `oee_a·oee_p·oee_q = 0`.

Per-line availability (25 d) shows `running_time` chronically ≈ 20–25 % of `available_time` while counts are huge — e.g. L8 `avg oee_a = 0.143`, `avg net = 116,099`. A machine making 116 k parts/shift cannot be running only 14 % of the time.

---

## Fault 1 — totalizer/count SPIKES at shift/PO boundaries

### Root cause

`net_production_incr` / `gross_production_incr` in `equipment_values` are **deltas** the Calc differences from a per-topic baseline held in process-local memory. Any event that invalidates the baseline (first observation, agent rebirth, PLC restart, publisher/source switch) makes `incr = cur − 0 = cur` — the *entire absolute totalizer* dumped as one increment. The rollup faithfully `SUM`s that phantom (`shift.go:92-93`, `hour.go:58-59`), so one bucket's `net` lands far above the physical max and the top-down `oee = LEAST(net/ideal, 1)` clamps to a fake `1.0`.

ADR-0045 (`b60804c`) killed the **first-observation** case (absent baseline → seed + emit 0; `calc.go:355-369`) and added the write-time increment clamp (`increment_clamp.go`). But two holes remained:

1. **Genuine resets still spike.** `handleCounterDrop` (`calc.go:684-689`) reseats `prev → 0` on any non-rollover drop, so the increment becomes `cur − 0 = cur`. A source switch to an ~830 k totalizer that is *lower* than the prior baseline is a "drop" → treated as a reset → mints an ~830 k phantom. The baseline was **present**, so the ADR-0045 first-obs seed never fires.
2. **The clamp leans on a magic constant.** The write-time clamp's rate-independent catch (`increment_clamp.go:108`) only fires when `value ≥ absolute ≥ spikeFloor` (default 1000) — a magic constant, and it misses partial rebirths where `value < absolute`. Its physical bound `K·rate·Δt` fails open when no `production_speed` is configured or on the first post-restart sample (no Δt).

The live tripwire: the Silver clamp (`silver.go`) still remediates `INVARIANT_CLAMPED_NET_GT_GROSS` (995) and `INVARIANT_CLAMPED_NEGATIVE` (2038) every minute — spikes and reset-desync still reach the Gold rows and are cleaned downstream instead of at the source.

### Design & decision

Make the guard **structural, not threshold-based**: *no valid baseline ⇒ re-seed and emit 0, never difference from zero.* ADR-0045 already does this for absent baselines; extend the **same** treatment to genuine resets/rebirths. On a non-rollover drop, seed the baseline to `cur` and drop the sample (increment 0); the next sample differences correctly against a real baseline. Idempotent across repeated resets, no magic constant, and it costs at most one sample's worth of post-reset counts (negligible — the pre-reset tail was already lost to the reset itself). 16-bit rollovers keep their true wrap delta (`handleCounterDrop`, unchanged).

**Implemented** (`calc.go`, gated `Message.ResetHeal` ← `CALC_RESET_HEAL_ENABLED`, default **true**):
the reset branches set `activeReset`, and a heal block re-seeds + drops when `ResetHeal && activeReset`, emitting `skipped_reason = "counter_reset_seed"`. Flag-off restores the legacy emit-`cur` behavior (parity + existing reset tests unchanged). The write-time increment clamp stays as defense-in-depth for reordered/double-source phantoms.

**Tests** (`calc_test.go`): `TestCalcResetHealDropsSpikeAndReseeds` (200 k source-switch → no metric, baseline re-seeded, next sample = correct +7) and `TestCalcResetHealOffKeepsLegacyEmitCur`.

**Before/after** (real spike class): L4 hour `net=1.2M / ideal=67`, source-switch reset → legacy emits the whole totalizer once (oee→fake 1.0); with reset-heal that sample emits 0 and the next differences normally, so no bucket carries a > physical-max delta.

---

## Fault 2 — availability chronically UNDER-COUNTED

### Root cause

`running_time` is credited **only** from explicit `status = 6` event overlaps (`shift.go:156-157`, `hour.go:145-146`). The state/downtime stream has large **gaps** — stretches with *no event at all* — during which the machine is demonstrably producing (its counter increments). Those gaps get zero running credit, so `oee_a = running/planned` is chronically low.

Live proof — L8 shift `2026-08-11 18:00` (net = 35,376): counters advanced in **364 of ~490 minutes** (~21,840 s of count activity), but the state stream had only 4 × `status=6` (14,580 s running) + 3 × `status=10` (1,020 s) — **~13,800 s of pure gap**. Stored `oee_a = 0.496`; count activity implies ≈ `21,840/29,400 = 0.74`.

The counters-only availability *fallback* (`availability.go`) already sessionizes count activity into running time — but it only engages when a bucket has **zero** events (`NOT EXISTS shift_ev` / still-flagged-after-E). Any bucket with even one `status` event is left on the gappy state-only running. So the exact rows that need healing (partial event coverage) are the ones the fallback skips.

### Design & decision

**Production is ground truth for availability: you cannot be stopped while your counter is incrementing.** Add a *count-floor* pass that, for opted-in equipment, RAISES `running_time` to the count-derived active time (the same idle-timeout sessionization the fallback already uses) whenever it exceeds the state-derived running — a pure `GREATEST` floor, capped at `available_time`, so a correct state-running is never lowered. Recomputes `running/stopped/downtime + oee_a`.

**Implemented** (`availability.go` `shiftAvailFloorSQL` / `hourAvailFloorSQL`, spliced into `RunShift`/`RunHour` after every running writer and before the OEE finalize; gated `OEE_AVAIL_FLOOR_ENABLED`, reusing `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS` + idle timeout). Default OFF → pass not appended → byte-identical.

**Expected after** (L8 08-11 shift): `running_time` floored 14,580 → ~21,840 s, `oee_a` 0.50 → ~0.74.

### Scoped follow-up (in this ADR, not this PR's default)

- **Generalize opt-in beyond the counters list.** The floor currently reuses the counters-only equipment list. State-driven machines with sparse event streams would benefit from the same floor; that needs a per-tenant policy decision (when is a count-gap "running" vs a genuinely stopped machine whose PLC kept a counter latched?). Recommend a dedicated opt-in list before broadening.
- **Downtime attribution.** The floor converts un-attributed gaps to running; it does not re-attribute *stopped* time to downtime reasons. Reason-level attribution during floored intervals is out of scope.
- **Root-cause the state-stream gaps at the edge** (why lines emit `status=6`/`10` with 250 h+ of gaps over 25 d) — an edge/agent investigation separate from the compute.

---

## Fault 3 — `oee` ≠ `oee_a × oee_p × oee_q`

### Root cause

Two coexisting definitions consuming different (partly corrupt) inputs:

- **Top-down headline** `oee = LEAST(net / ideal_production, 1)` (`shift.go:186`, `hour.go:183`).
- **Bottom-up components**: `oee_a = running/planned` (`shift.go:191`), `oee_q = net/gross` (`shift.go:192`), and `oee_p` a **back-solved residual** `oee/(oee_a·oee_q)` clamped to [0,1] (`shiftOeePSQL` `shift.go:201`, `hourOeePSQL` `hour.go:204`).

These are algebraically the *same* quantity when nothing clamps — they telescope:

```
A·P·Q = (run/planned)·(gross/(rate·run/60))·(net/gross)
      = net / (rate·planned/60) = net / ideal_production          (†)
```

They diverge for exactly two reasons: **(a)** each factor is independently clamped to [0,1] — when Performance genuinely exceeds 1 (a count spike, or an under-counted `running_time`), clamping `oee_p` to 1 drops the excess, so `A·P·Q < oee`; **(b)** a zero denominator (`gross=0 → Q=0`, or `running=0 → A=0`) makes the residual undefined → `oee_p=0` while the top-down `oee` is still positive. Both driver conditions are Faults 1 and 2 — the spike inflates the numerator and the availability gap deflates `running` — so Fault 3 is largely a *symptom* of the other two, amplified by the clamp.

### Design & decision

**OEE is DEFINED as the product of three genuine [0,1] factors** (ISO-22400 / the standard OEE waterfall). Store `oee = oee_a · oee_p · oee_q`, with Performance computed **directly** (`P = gross/(ideal_speed·running/60)`, clamped) rather than back-solved. Then `oee == oee_a·oee_p·oee_q` holds **by construction**, always. The former top-down `net/ideal_production` becomes a data-quality cross-check (`dq.go`), not a second headline. By (†) this changes **no value on clean data** (they were equal); it only lowers OEE exactly where a factor was clamped — i.e. where the top-down number was silently over-crediting a spike or an availability gap.

**Authoritative = A×P×Q** was chosen over "keep top-down and back-solve components" because the latter cannot satisfy all three of {`oee` = top-down, each factor ∈ [0,1], `oee` = A·P·Q} whenever the residual > 1 — something must give, and the industry standard gives up the top-down headline. Because A×P×Q makes `oee_a` **load-bearing**, it is sequenced **after** the availability floor (flipping it while `oee_a` is broken would depress the headline from ~0.43 to the ~0.09 product of the broken factors).

**Implemented**: a single reconcile pass over the whole batch (`availability.go` `shiftOeeReconcileSQL` / `hourOeeReconcileSQL`) replaces the legacy residual `oee-p` step when `OEE_CANONICAL_APQ_ENABLED=true`; it overwrites `oee_a, oee_q, oee_p, oee` with the bounded factors + their product. The algebra is centralized in **`rollup/oee.go` `CanonicalOEE`** (pure Go), which the SQL mirrors exactly. Default OFF → legacy top-down oee + residual oee_p (byte-identical).

**Tests** (`oee_test.go`, no DB): `TestCanonicalOEEIdentityHolds` (6 synthetic rows incl. a 10× count spike, zero-gross, zero-running — identity holds and every factor ∈ [0,1]); `TestCanonicalOEESpikeBounded` (spike → `oee ≤ 1`, Performance clamps to 1, identity still holds); `TestCanonicalMatchesTopDownWhenUnclamped` (proves (†) — canonical == top-down on unclamped data).

---

## Rollout sequence (staging-first, USER-orchestrated)

1. **`CALC_RESET_HEAL_ENABLED=true`** (default) — stop new reset/rebirth spikes at the source. Watch `INVARIANT_CLAMPED_*` DQ-event rates fall.
2. **`OEE_AVAIL_FLOOR_ENABLED=true`** — correct `oee_a`. Verify per-line `oee_a` rises to production-consistent levels (L8 ~0.14 → ~0.5+; producing shifts no longer at 0.01).
3. **`OEE_CANONICAL_APQ_ENABLED=true`** — flip the headline to A×P×Q. Verify `\|oee − oee_a·oee_p·oee_q\|` → 0 on all producing shifts.

Each step is independently reversible. `day/week/month/PO-runtime` grains (`grains.go`, `compute.go`) still back-solve `oee_p`; extending the reconcile there is the mechanical next step once shift+hour are validated (same transform, aggregate inputs).

## Consequences

- **Positive:** headline OEE becomes a single, standard, self-consistent definition; spikes healed at the source (less Silver-clamp churn); availability reflects actual production. All reversible, all gated, parity-safe when off.
- **Negative / watch:** enabling canonical A×P×Q will *lower* reported OEE on rows that were previously over-credited (spikes/availability gaps) — this is a correction, but stakeholders must be briefed. The availability floor trusts counts as running; a machine that latches a counter while idle would be over-credited (mitigated by per-equipment opt-in).
