# Production-Cutover Readiness Review — Packiot OEE-Engine Migration

**Date:** 2026-07-15 · **Scope:** CPACK (ent 1, tp=3 lines) — moving live OEE source-of-truth off legacy `tsp12` compute-in-Postgres to the new Go stack.
**Purpose:** Read-only readiness assessment to feed a rollout-scoping session.
**Verdict:** 🟡 **READY TO SCOPE. NOT ready to execute.** No blocker to *planning*; several hard blockers before *any prod write*.

---

## 0. The framing correction (read this first)

**The "flip" that is imminent is NOT the production cutover.** Two distinct events are easy to conflate:

| | Staging consolidation flip | **Production cutover** |
|---|---|---|
| ADR | ADR-0016 (flip-runbook) | ADR-0003 Phase 3 / roadmap Phase F / `0012-phase5-prod-readiness` |
| What flips | F3/`packiot_shadow` promoted to the one staging DB | CPACK's **live customer** OEE source-of-truth: `tsp12` pg_cron/triggers → Go stack |
| Customer impact | none (synthetic + mirrored data) | **direct — paying factory OEE** |
| Status | correctness gate cleared by #276 sign-off; near-term | **not started** |

The #276 sign-off retires the migration's hardest **technical** risk — "does the Go Calc compute correct OEE" — but does so **only on staging, against mirrored/replayed prod data**. Production cutover is a separate, later, and barely-begun program.

---

## 1. What "production cutover" actually means here

Grounded in `0012-phase5-prod-readiness §2`, ADR-0003, and roadmap Phase F, the prod cutover is **not** a big-bang DB swap (that was *staging*, promoting a separate `packiot_shadow`). For prod it is an **in-place expand-contract on the live prod DB**:

1. **Real prod parallel-run** (ADR-0003 Phase 2, never executed) — Go stack computes OEE against real CPACK data while `tsp12` stays authoritative; a comparator diffs Go-vs-`tsp12` **on real prod**.
2. **Writer-by-writer cutover** — each OEE writer (rollups, PO runtime, shift resolver, report writers, cagg adoption) moves from pg_cron/`piot_*` to the Go engine-worker, **each behind a ≥72h dual-run bake with a façade**; legacy pg_cron writers **stay alive until per-writer parity holds**.
3. **Downstream consumers re-pointed** (front4→refdata-api, PowerBI, reports/BigQuery) via same-shape façades; PowerBI gate re-run per wave.
4. **Factory MQTT cutover** — the real factory SparkPlug stream points at a per-factory `edge-transformer` (first time the new Calc engine sees a real CPACK PLC).
5. **Legacy decommission** — EB edge-api, GCP PubSub, prod oeecloud-node-red, prod `piot_*` — **each behind a 30-day frozen-read window + EBS snapshot**.

→ "Flip production" = a **months-long, writer-and-factory-at-a-time, reversible expand-contract**, not a switch. The OOM cure is a *consequence* of steps 2/5, realized gradually.

---

## 2. Prerequisites — PROVEN / IN-PROGRESS / OPEN

| # | Prerequisite | State | Note |
|---|---|---|---|
| P1 | Go Calc correctness (determinism + behavior) | ✅ **PROVEN (staging only)** | #276 sign-off + V3 behavior suite |
| P2 | **Prod parallel-run (F1/F2/F3-equiv on PROD data)** | 🔴 **OPEN — critical gap** | Prod stack is a **dry-run vs empty local DB**; no publisher, no comparator on prod. ADR-0003 Phase 2 never executed; ADR-0009 data-layer decision doesn't exist |
| P3 | Comparator on **real prod** compute | 🟠 PARTIAL | Today it diffs *mirrored/replayed* data on staging; no Go-vs-`tsp12` diff on the prod box |
| P4 | New-stack prod deploy + scaling | 🟠 IN-PROGRESS / OPEN | Deployed dry-run; **Calc holds in-memory per-topic counter state → no HA replica; restart loses baselines** (R5) |
| P5 | Downstream-consumer continuity | 🔴 OPEN | **G6 (prod Hasura creds) RED**, closes 2026-08-01; front4/PowerBI/BigQuery read paths unresolved |
| P6 | Elevated prod DB role (G8) | 🔴 OPEN | `migration_role` (DDL + `alter_job`) doesn't exist; `awslambda` is SELECT-only forever |
| P7 | Prod SparkPlug payload capture (G7) | 🔴 OPEN | Needs factory access; the validation corpus for the factory MQTT cutover |
| P8 | 75 GB invalidation-queue fix | 🔴 OPEN | `agg_equipment_values_1min_t_invalidation` = 75 GB / 495M rows, growing; must precede cagg adoption; needs G8 |
| P9 | Acute prod-DB stability (OOM) | 🔴 OPEN | Recurring backend OOM; **do not defer onto the migration** |

**On the sim-fidelity gaps (#16/#22):** they correctly *don't* affect the real prod path (real PLCs feed real density) — but that means the **line topology has never been validated at prod density anywhere**, and the real prod path (P2) doesn't exist yet, so the line-vs-prod story stays unproven until the prod parallel-run runs.

---

## 3. Risks + mitigations (ranked)

- **R1 — No prod parallel-run (CRITICAL).** The entire correctness case rests on staging + mirrored data; the real CPACK line topology has never flowed through the new `edge-transformer`. → Execute ADR-0003 Phase 2 + decide ADR-0009; Go-vs-`tsp12` comparator on real prod, read-only, over ≥1 month-boundary before any write cutover. **Critical path.**
- **R2 — DATA-SCAR (CRITICAL).** A write cutover shipped with a latent bug writes dirty OEE history to a *paying* factory; fix-forward leaves scarred history that can't be aged out. → This is *why* prod is expand-contract: keep legacy pg_cron writers parallel until per-writer parity; ≥72h bake/writer; a documented **recompute/cleanup runbook** driving the `recalc_needed` cascade; tight flip→observe→fix gating; frozen-read window as undo horizon. *(This lesson came directly from the staging cutover: the two-writer bug left a self-clearing "scar" in the shadow store — on prod it wouldn't self-clear.)* **Owner: qa + dba.**
- **R3 — Rollback (HIGH).** Prod rollback is per-writer façade-reversal — instant *only if* legacy compute is still live. `piot_*` retirement is the irreversible step. → Never retire legacy until its Go replacement has a full month-boundary of parity; snapshot before every drop.
- **R4 — Prod DB load during dual-run (HIGH).** The box already OOMs; running legacy pg_cron **and** the Go engine-worker against the same DB during overlap **adds** load before the durable relief lands. → Do the **acute** OOM fixes now, independent of the migration (`shared_buffers` 49.6→32 GB, `max_parallel_workers_per_gather` 8→2-4, autovacuum caps, pgbouncer). **The migration is the long-term cure but the overlap window is riskier, not safer.** **Owner: devops + tech-lead (PG12→13 decision).**
- **R5 — Single-instance Calc in-memory state (HIGH).** No HA replica per tenant; a restart (deploy, crash, OOM) drops counter baselines → glitched OEE until state rebuilds. Staging tolerates it; a paying factory doesn't. → Decide before prod: Redis-backed shared state, OR single-instance-per-factory + fast restart + boot-time rebuild + restart-glitch monitor. **Owner: backend + devops.**
- **R6 — Downstream breakage (MEDIUM).** Hasura/PowerBI/reports/BigQuery read `tsp12` today. → Enumerate every consumer's read path before flipping source-of-truth; same-shape façade per renamed object; PowerBI gate re-run per wave.
- **R7 — CPACK line topology (MEDIUM).** Covered by R1; resolves by construction once the real prod parallel-run feeds real PLC density.
- **R8 — `proportional_target` proration asymmetry → being INTENTIONALLY REMOVED (ADR-0029 #80 P3).** History (verified live 2026-07-18, #83, SELECT-only `pg_proc`): base `piot_get_equipment_runtime_shift_production` (tp=1 machines / tp=2 sectors) kept the elapsed-proration write #2 **COMMENTED** → emitted a **full-shift** `proportional_target` (write #1 `vl_target` was the sole writer); `_tp_eq3` (tp=3 lines) had write #2 **ACTIVE** → elapsed-prorated. That asymmetry is the reason front4 shipped a tp=1/2 client override. **Resolution (2026-07-20, this change):** the base fn's **write #1** was rewritten to be elapsed-prorated — `proportional_target = target * (extract(epoch from (least(now(), ts_end) - ts_value)) / nullif(shift_size,0))` — matching `_tp_eq3`'s active write #2 formula, **capped at the shift end** via `least(now(), ts_end)` so a completed shift still yields the full target (the base loop spans multiple shifts, unlike `_tp_eq3`'s current-shift-only post-loop write, so the cap is required to avoid `elapsed>shift_size` inflation). The commented write #2 block **stays COMMENTED** — the fix is in write #1, NOT by uncommenting write #2. **Single-writer-per-column invariant preserved:** `proportional_target` is still written **exactly once** in the base fn (verified on staging: 1 active write, block-comments stripped). Do **NOT** uncomment base write #2 — that would double-write the column and resurrect #80/#276. Staging verification 2026-07-20: deployed-fn run on tp=3 line 52 → `60000 × 6857/29400 = 13994.88` (matched exactly, frac 0.233, no oee>1.0); deployed write #1 statement on tp=1 machine 78 → `50000 × 6858/29400 = 11662.75` (matched, frac 0.233). → **Consequence for cutover:** the Calc/Go port must now **prorate `proportional_target` for ALL tp** (machines, sectors, lines) as a **single writer** — the previous "must preserve the asymmetry" guidance is **superseded**. **PROD GATE:** this DDL is applied to staging only; prod needs it applied via `migration_role` + user auth. front4's tp=1/2 client override must remain until prod carries this change. Secondary: base fn reads cagg `ca_agg_equipment_values_1hour_fast` in prod vs `ca_agg_equipment_values_1hour` in the file — unrelated to this change; verify vs the shadow schema before any cagg change. **Owner: dba + backend.**

---

## 4. Sequencing + gates

| Step | What | Gate (go/no-go) |
|---|---|---|
| **S0** | Acute prod OOM mitigation *(independent of migration — do now)* | OOM/restart frequency drops; host logs confirm victim/signal + containerization |
| **S1** | Complete staging flip (ADR-0016) + 30-day soak | G1–G5 green + #276 baked over more shifts + V3 converged for ent 3 **and** 4 |
| **S2** | **Stand up the real prod parallel-run** (ADR-0003 Ph2; decide ADR-0009; un-dry-run prod stack) | **Go-vs-`tsp12` parity green over ≥1 full month-boundary on real prod data — the critical-path gate; nothing writes to prod before it** |
| **S3** | Provision G8 `migration_role` + 75 GB invalidation fix + pool DDL/backfill | role live; invalidation queue steady; backfill parity |
| **S4** | Writer-by-writer cutover with façades, legacy pg_cron kept parallel | per-writer ≥72h parity + PowerBI gate + recompute-runbook rehearsed |
| **S5** | Downstream consumer flips (front4→refdata-api needs G6) | each consumer verified on new source |
| **S6** | Factory MQTT cutover (per-factory edge-transformer + R5 decision) | real-factory parity vs the just-decommissioned legacy path |
| **S7** | Legacy decommission (EB, PubSub, prod node-red, `piot_*`) | 30-day frozen-read clean + EBS snapshot per component |

---

## 5. Readiness verdict

**READY TO SCOPE. NOT ready to execute.**

- The migration's hardest technical risk — Go Calc correctness — is genuinely retired *for CPACK on the determinism + behavior gate* (#276, V3). Real, load-bearing, and it unblocks scoping.
- But **production cutover has not begun:** the prod stack is a boot-validation **dry-run against an empty local DB**, there is **no prod parallel-run**, **no comparator against real prod compute**, three prerequisites (**G6/G7/G8**) are RED and human/infra-gated, and two prod-specific concerns (**single-instance Calc state**, **downstream continuity**) are unresolved for a paying tenant.

**Critical path:** **S2** — stand up the real-prod, read-only parallel-run and prove the Go stack faithful against *real* prod data over a month-boundary. All the staging evidence is necessary but, by construction, cannot substitute for it (mirrored ≠ live PLC topology at prod density).

**Biggest unknown:** the real prod DB under dual-run — whether the new compute path *relieves* or *briefly compounds* the OOM during overlap — coupled with the real CPACK line topology's behavior through the new `edge-transformer` (never once exercised). Both collapse to "we won't know until S2 runs."

**Do-now, independent of the migration:** the S0 acute OOM fixes. Treating the migration as the OOM cure is correct long-term but dangerous as a reason to defer the acute mitigation.

---

## 6. Specialist deep-dives to commission (for the scoping session)

- **dba** — prod expand-contract writer sequence; 75 GB invalidation drain; dual-run DB-load model; the recompute/`recalc_needed` cleanup runbook (R2); acute OOM GUC set + PG12→13 upgrade feasibility (TimescaleDB 2.11 / Hasura / pg-promise compat).
- **devops-platform** — un-dry-run the prod stack + wire the ADR-0009 data layer; edge-transformer HA/Redis decision (R5); rollback mechanics per writer; confirm prod-host OOM victim/signal + containerization.
- **qa** — the real-prod Go-vs-`tsp12` comparator + gates (S2); per-writer bake acceptance; V4 pre-flip behavior-correctness report extended to the prod parallel-run.

---

*Source ADRs/audits: `docs/adr/0003`, `0014`, `0016` (+ flip-runbook), `0017`, `0022` (+ v3-verdict), `reference/0012-phase5-prod-readiness`; `docs/audits/prod-tsp12-oom-attribution-2026-07-13`; `docs/overview/06`, `07`; `services/edge-transformer/internal/transforms/calc_production_counters/state.go`.*
