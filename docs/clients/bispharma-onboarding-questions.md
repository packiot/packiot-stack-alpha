# Bispharma — onboarding questions (to confirm before OEE cutover)

**Status:** Client questionnaire · **Date:** 2026-07-29 · **Task:** #54 ·
**Companion:** [`bispharma-oee-mapping-fix.md`](bispharma-oee-mapping-fix.md) (the internal
analysis these questions resolve)

> **Why we're asking.** We validated the full Bispharma data path end-to-end on our staging
> environment — your line counters flow through to a computed OEE. Right now OEE shows the
> **Performance** dimension only; **Availability** and **Quality** read zero. That is *not* a
> data or math problem on our side — it is that we don't yet know, for certain, **what each of
> your counters means physically**. A handful of confirmations from your automation/process
> team unlocks a complete, correct OEE. Every question below maps to a specific counter we can
> already see in your Node-RED flow; we've quoted your own flow labels so it's concrete.
>
> Answering **Q1–Q4** unlocks **Quality**; **Q5** sets the reporting granularity; **Q6**
> refines **Performance** (we have a working provisional value in the meantime — see the note).

---

## Q1 — Standard lines (14 of 16): is DW0 the line's *raw infeed*? **(unlocks Quality)**

For 14 lines (L01, L03, L04, L05, L06, L07, L09, L11, L12, L13, L14, L16, L19, L20) your flow
assigns a 6-counter block. Using **L01** as the example (block 164–169), your code + comments read:

| Your counter | S7 word | Your comment | We plan to treat it as |
|---|---|---|---|
| `counter168` | `DW0` | *"first sensor, line infeed"* | **Gross / total produced** (Quality denominator) |
| `counter169` | `DW0-DW4` | *"last sensor is the only one for scrap"* | **Good / net** (Quality numerator) |

**Question:** Is **DW0** the count of units **fed into the line** (raw input), or the output of
the **first machine** in the line?

- If **raw input** → Quality = *true line yield* (good ÷ everything that entered). ✅ our default.
- If **first-machine output** → the ratio is still valid but means "good ÷ first-station output",
  a slightly narrower definition. We just need to label it correctly.

> One answer covers all 14 standard lines **unless** any line's DW0 sensor is placed
> differently — if so, tell us which lines differ.

---

## Q2 — Line L18: which machine is the line's *good-output* counter? **(unlocks Quality on L18)**

L18 is wired differently — 8 individual machine counters (543–550), **no** infeed/scrap split.
Your flow labels them:

| Counter | Machine (your label) |
|---|---|
| `DW0` | I1 Tampadeira |
| `DW8` | I3 Prensa |
| `DW12` | I4 Torno |
| `DW16` | I5 Acumulador |
| `DW20` | I6 Impressão |

(`DW4`, `DW24`, `DW28` are labelled *"livre"* / spare — we're leaving them unregistered.)

**Question:** For L18, **which machine's counter represents the line's good output** (the units
that successfully leave the line)? And is there a counter that represents the line's **infeed**?

- Until we know this, **L18 reports per-machine counts but no line-level Quality**.

---

## Q3 — Line L90: confirm entry = gross, exit = good. **(unlocks Quality on L90)**

L90 has just two counters, and your comments already name them:

| Counter | S7 word | Your comment |
|---|---|---|
| `counter684` | `DW0` | *"sensor entrada da linha"* (line entry) |
| `counter685` | `DW1` | *"sensor saída da linha"* (line exit) |

**Question:** Confirm **entry (684) = total in / gross** and **exit (685) = good out / net**, so
Quality = 685 ÷ 684. (Note L90 uses `DW1` for exit, not the `DW4` scrap convention of the
standard lines — we're keeping it separate; just confirm the meaning.)

---

## Q4 — Scrap definition sanity check **(confirms the Quality math)**

On the standard lines you compute `counter169 = DW0 - DW4`, commented *"last sensor is the only
one for scrap."*

**Question:** Does **DW4** count **rejected/scrapped** units (so `DW0 − DW4` = good), i.e. is
scrap detected at the **last** station only? If any line also rejects earlier (multiple scrap
points), tell us — it changes how we derive "good."

---

## Q5 — Reporting granularity: lines only, or lines **and** machines? **(sets scope)**

We can surface OEE at two levels:

1. **Line level** — one OEE per production line (16 lines). Simplest, matches how most plants
   run shift reports.
2. **Line + machine level** — OEE per line **and** per machine within the line (16 lines + ~91
   machine sub-counters), for drill-down into which station drags a line down.

**Question:** Which do you want at go-live? (We recommend starting **line-level** and adding
machine drill-down once the line numbers are trusted — but it's your call.)

---

## Q6 — Rated (nameplate) line speeds **(refines Performance — not a blocker)**

Performance = actual rate ÷ **rated** rate. Your flow sends counts only (no machine-speed
signal), and there's no historical rated speed on record for Bispharma.

**We are not blocking go-live on this.** During the initial bake we **self-calibrate** a
provisional ideal speed from each line's own best demonstrated throughput (p95, glitch-guarded),
so you'll see a real OEE from day one. **Caveat:** provisional Performance is measured against
the machine's *own best*, so OEE will read a bit **high**, and will **drop** when we load the
real nameplate speed. This is the standard "demonstrated capacity" approach.

**Question (refinement, anytime):** For each line, what is the **rated / nameplate speed** in
**units per minute** (or per hour)? Sending these later simply swaps the provisional value for
the engineering figure.

---

## What happens after you answer

1. Q1–Q4 → we finalize the counter role-mapping (gross/net per line) → **Availability + Quality
   light up** alongside Performance.
2. Q5 → we register lines only, or lines + machines.
3. Q6 → the provisional speed is replaced by your nameplate figures (OEE re-baselines).
4. We do a clean-from-zero validation run on staging, confirm all three OEE dimensions are
   non-zero and sane, then schedule the per-tenant cutover.

> Separately, our team needs a few **operational** inputs from you (factory public IP for the
> ingest allow-rule, the mTLS client cert approval, and the edge tee node) — those are tracked
> in the go-live runbook and are independent of the questions above.
