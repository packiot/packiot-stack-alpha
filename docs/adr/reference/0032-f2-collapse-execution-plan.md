# ADR-0032 — F3 read-plane collapse: readiness assessment + staged execution plan

**Companion to:** [ADR-0032 — Collapse to single flow (F3)](../0032-collapse-to-single-flow-f3.md)
**Status:** Reference / runbook · **Type:** DESIGN + VERIFICATION ONLY — this document prepares the flip; it does **not** execute it.
**Date:** 2026-07-23 · **Scope:** STAGING ONLY. Prod untouched. Execution is USER-gated.
**Author:** tech-lead (prepared so the USER can execute on sign-off).

> **This is not a decision doc and it changes no state.** It is the pre-flight checklist + ordered runbook + go/no-go verdict for executing ADR-0032 §6. Every live figure below was gathered SELECT-only (`BEGIN READ ONLY` where writeable) against the staging DB EC2 `i-064bb36d1c454d861` (`10.10.10.89`, container `timescaledb`) on **2026-07-24 ~00:49 UTC**.

---

## 0. Terminology — what "the atomic flip / step-3" actually is

The umbrella task calls this "the F2 read-plane collapse (the atomic flip / step-3)." Three overlapping names collapse to one deferred action, so pin them down first:

| Name in flight | What it precisely refers to | Where defined |
|---|---|---|
| "the atomic flip" | The moment **F1 telemetry compute stops and F3 becomes the sole telemetry-compute flow** — i.e. ADR-0032 **§6 Step 4** (stop F1 emit + disable F1 `pg_cron`/cagg compute), which is only safe *after* §6 Step 1 (read-plane re-point to F3) is green. | ADR-0032 §6 |
| "ADR-0032 step-3" | Loose shorthand in the session-88 ledger for "the deferred F3 flip." It is **not** ADR-0024's step 3 (that is the *action* cutover / Phase 2 — a separate, later, still-gated program). | `session_88_pickup.md` |
| "F2 collapse" | Retiring the F2 `shadow_go_port` leg (§6 Steps 2–3 + the Step-5 `DROP SCHEMA`). F2 is pure validation scaffolding with **zero read consumers**. | ADR-0032 §2.4 |

**The whole thing this doc prepares = ADR-0032 §6 Steps 1→5**, ending at the directive's Phase-1 (mirror-bridged) safe state. **Phase 2 (edge-api-direct / ADR-0024 step 3 action cutover) stays OUT of scope** — it earns its own gate after Phase 1 bakes clean.

**What it unblocks downstream** (why the USER wants it prepared):

- **B1 Bronze append-only cutover** (task #3 / PR #594) — "cutover gated post-collapse" per session-88. `equipment_values_raw`/`equipment_events_raw` + the `BRONZE_RAW_APPEND` dual-write seam are built (default off); the cutover waits on the collapse so it flips on a single settled flow, not a triple-emit.
- **Retention immutability (ADR-0036 R1)** rests on the same single-flow Bronze.
- **The true ADR-0016 flip** and **Phase 2 action cutover** both sit downstream of a clean Phase-1 bake.

---

## 1. Current read-plane state — who reads F1 (`packiot`) vs F3 (`packiot_shadow`) today

The render/read surface is the **standard stack** — no exotic consumers (ADR-0032 §2.4/§7 census, re-verified). Two facts frame everything:

- **F1 and F2 share one database** (`packiot`): schema `public` = F1, schema `shadow_go_port` = F2. **Only F3 is a separate DB** (`packiot_shadow`).
- **The read-plane build is essentially DONE and staged** — `compose.staging.yml` on `origin/staging` already carries `REFDATA_FLOW: f3`, the pgbouncer `packiot_shadow` pool, and the F3 analytics objects are live-present (§3). What remains is *deploying/confirming the flip + passing the parity gate*, not building it.

| Consumer | Reads today (runtime reality) | Re-point mechanism | Build status |
|---|---|---|---|
| **refdata-api** (`.26`) | Compose declares `REFDATA_FLOW: f3` → `packiot_shadow`. **Must confirm the running staging container matches** (deploy-state check, §4 G-DEPLOY). Default-safe code: anything ≠ exact lowercase `f3` resolves to F1. | `REFDATA_FLOW` env (`flow.go` `resolveFlow`) + `DB_NAME_F3=packiot_shadow` + pgbouncer `packiot_shadow` pool | **BUILT + STAGED** |
| **front4** (AWS Amplify) | Analytics still read **prod Hasura Cloud** (`gqlpiot.packiot.com`); operator/live datasets follow refdata. Phase-G analytics cutover built behind `VITE_REFDATA_ENABLED` / `REFDATA_ANALYTICS_ENABLED` (`src/lib/dashboard/hooks/*`). | Inherits refdata re-point; analytics flip = the front4 flag | **BUILT, flag default-off** |
| **operator PWA** (`/v1/*` cache) | Inherits refdata (F1 today until refdata flips). Zero Hasura. | Follows refdata; response shapes must stay byte-stable | inherits refdata |
| **Grafana** (`.7`) | Two datasources provisioned: `packiot-postgres` (F1) + `packiot-postgres-shadow` (F3). Boards carry a `$datasource` template var (PR #537); 6 OEE boards F3-clean. | Migrate board bindings F1→F3 datasource UID | **BUILT** |
| **staging Hasura** (`.2`) | F1 `packiot.public` — **edge-node-red-only** (operator/reference reads), NOT OEE telemetry. | **NO ACTION** — stays on the retained operator substrate; retires out-of-band | out of scope (correct) |
| **reports / cq-logs-bigquery** | reports = LaTeX (no DB); cq-logs reads `cq_logs` only. Neither reads `uns_metrics`/F1-only OEE. | **NO ACTION** — Step-5 drop pre-cleared | out of scope (correct) |
| **F2 `shadow_go_port` readers** | **none** (grep-confirmed; only parallel-run plumbing + one dashboard) | — safe to drop | — |

**Net:** the read plane's *only* load-bearing re-point is **refdata-api + its pgbouncer pool + Grafana**. All three are built. front4/operator inherit refdata. Hasura + reports are correctly excluded.

---

## 2. Live topology state (2026-07-24) — nothing has collapsed yet

All three flows are still emitting — exactly as expected for a deferred flip:

| Flow | `equipment_values` max ts (UTC) | 24h rows | Verdict |
|---|---|---|---|
| **F1** `packiot.public` | `2026-07-24 00:48:50` | 225,134 | fresh — triple-emit live |
| **F2** `shadow_go_port` | `2026-07-24 00:48:47` | — | fresh — F2 leg still on |
| **F3** `packiot_shadow.public` | `2026-07-24 00:48:07` | 158,745 | fresh — F3 leg live |

The stack is in the pre-collapse steady state. **The flip is a deliberate, un-taken action.**

---

## 3. Prerequisite readiness matrix (live-verified where cheap)

Legend: ✅ met · ⚠️ partial / needs confirmation · ⛔ not met / blocking · ⬜ needs a non-DB check before flip

### 3.1 Criterion (A) — DATA fidelity: F3 produces correct, fresh OEE

| Check | Live finding (2026-07-24) | Status |
|---|---|---|
| F3 telemetry fresh | `equipment_values` max ts = **now** (`00:48:07`); 158,745 rows/24h | ✅ |
| F3 rollup engine live | `equipment_runtime_shift.computed_at` max = **now** (`00:49:25`) → cagg cascade actively computing | ✅ |
| F3 runtime rows | `equipment_runtime_shift` = **9,474** (was 8,892 at ADR time — grew) | ✅ |
| F1 derived compute already dead | `uns_equipment_current_shift.last_updated` frozen **2026-07-08** (16 days) — F1's derived compute is a corpse; only raw ingest + cron#1 `uns_metrics` still run | ✅ (de-risks stopping F1) |
| **recalc backlog (F3)** | `production_orders_runtime.recalc_needed=true` = **1,162 of 6,070** (~19%); `equipment_runtime_shift` recalc = **1,466**. Span `2026-07-21 → now`; **593 older than 1 day** (persistent stale tail), 20 flagged in the last hour. **Dominated by ent 2 (plc-sim synthetic, ~1,100); ent 3 (CPACK) small, ent 4 (Incoplast) negligible.** | ⚠️ |

**Reading of the recalc backlog:** the reconciler is keeping up on *recent* items but leaves a ~600-row stale tail, almost entirely on the **synthetic sim tenant (ent 2)** — not on the flip's fidelity targets (ent 3 CPACK + ent 4 Incoplast). It is a hardening item, not a hard blocker for the ent-3/4 acceptance bar, **but it must be confirmed draining (not growing) before Step 4** because F3-sole inherits PO/event closes only through the reconciler (see G0b).

### 3.2 Read-plane build (Step 1 — the long pole)

| Item | Live/repo finding | Status |
|---|---|---|
| pgbouncer `packiot_shadow` pool | `compose.staging.yml` command sed-injects a `[databases]` line `packiot_shadow = host … dbname=packiot_shadow` before launch (additive; F1 pool byte-identical) | ✅ built |
| refdata `REFDATA_FLOW`/`DB_NAME_F3` | `REFDATA_FLOW: f3`, `DB_NAME_F3: packiot_shadow` set; `flow.go` fail-safe (only exact `f3` flips); 5 per-dataset `sqlF3` overrides (most datasets need none — divergence is *absence*, not rename) | ✅ built, ⬜ deploy-confirm |
| **F3 analytics port** (ADR-0032 §5.1 "PORT 32") | **DONE — live-verified:** `packiot_shadow` has **91 `h_piot_*` functions** and **all 6 config relations** present (`oee_targets, scrap_targets, dashboard_config, user_roles, v_menu_per_user_role, v_report_downtimes`). The §5.1 "38 objects missing from F3" gap is **closed**. | ✅ |
| `users` seed ent 3/4 | `packiot_shadow.users` ent3/4 = **1 row** (ADR expected empty → needed SEED). Thin — confirm 1 row is sufficient for the auth/role reads front4/operator make, else seed more. | ⚠️ |
| Grafana F3 datasource + `$datasource` var | both datasources provisioned; template var on boards (PR #537) | ✅ built |
| front4 Phase-G analytics flag | `REFDATA_ANALYTICS_ENABLED` / `VITE_REFDATA_ENABLED` wired in dashboard hooks, default-off | ✅ built |
| **Fidelity gate harness** | `scripts/adr0032-f3-fidelity-check.sh` — A/B/C per-tenant F1-vs-F3 matrix, READ-ONLY. **Transport PORTED (2026-07-26)** from the policy-blocked `AWS-RunShellScript` send-command to the `AWS-StartNonInteractiveCommand` start-session path (base64 SQL → `sudo bash` → unique remote `mktemp` → `docker exec -i timescaledb psql` over stdin, `BEGIN READ ONLY`). **Ran green read-only** — see the acceptance note below. | ✅ built + ported + green |

### 3.3 Hard gates from ADR-0032 §6

| Gate | What it requires | Live status | Verdict |
|---|---|---|---|
| **G0** (ADR-0024) | #32 staleness/durability gate baked on ent 3+4: `po_gate_degraded_total→0`, `PO_STALENESS_GATE_ENTERPRISES="3,4"` live | Not DB-observable — needs Grafana `v2-po-staleness-gate` (409-rate 0, liveness non-zero) | ⬜ verify pre-flip |
| **G0b** (ADR-0025 / #51) | mirror-worker-go reconciler **F3 fan-out** live + healthy *before* Step 4; no recalc backlog growth on ent 3/4 | recalc backlog exists (§3.1) with a stale tail, but concentrated on ent 2 (sim), not ent 3/4. Reconciler draining recent items. | ⚠️ confirm draining |
| **G-DEPLOY** (this doc) | The **running** staging refdata container is actually on `REFDATA_FLOW=f3` and green — or is intentionally still F1 pending the Step-1 parity gate | compose declares f3; deploy-state not confirmed from the DB. | ⬜ confirm |
| **Step-1 parity gate** | Every Surface-1 dataset + Grafana panel byte-stable F3-vs-F1 for ent 3&4 over **≥48h**; front4 + operator render off F3 | harness built; 48h window must be run + captured | ⬜ run + green |
| **F1 compute inventory** | Know exactly what to stop | Live: cron `#1 oee-compute` = **active** (F1's last live compute → `uns_metrics`, 10.4M rows); `#3 oee-refresh-runtime` = **inactive**; `#2/#5/#8` = housekeeping (keep). F3 cagg jobs independent. | ✅ mapped |

---

## 4. Staged execution plan (each step reversible until Step 5)

**Scope: STAGING ONLY. Do not execute until USER sign-off.** This is ADR-0032 §6 made operational with explicit rollback + gates. The **point of no return is Step 5** (the `DROP`s); everything before is a flag/routing revert + redeploy.

### Pre-flight (do all before Step 1)
- **P1.** Confirm **G-DEPLOY**: check the running refdata container's effective `REFDATA_FLOW`. If the intent is "flip now," it moves to `f3`; if it is already `f3`, capture that as the starting truth.
- **P2.** Confirm **G0** on Grafana `v2-po-staleness-gate` (ent 3,4): 409-rate 0, liveness non-zero.
- **P3.** ✅ **DONE (2026-07-26):** transport ported `send-command`→`start-session` (§6); harness ran green read-only. **Then run it each step to capture the F3 A/B/C matrix, ent 3&4.**

  > **⚠️ Gate acceptance = F3-HEALTHY, not F1-identical.** F1's OEE compute is a corpse — `uns_current_shift` frozen since 2026-07-08, and F1 itself carries anomalous rows (2026-07-26 run: F1 ent-3 = **88 `oee>1` + 18 `oee<0`**, median 0.09; F3 ent-3 = **0 anomalies**, median 0.59, telemetry fresh to *now*). Byte-identity vs F1 is therefore **the wrong yardstick** and would fail on F1's own corpse artifacts. **PASS ⇔** for ent 3&4: F3 `equipment_values` max_ts ≈ now · F3 rollups compute to now (`uns_equipment_current_metrics` fresh) · F3 OEE anomaly-free (`oee_gt1=0`, `oee_neg=0`) · render surface present (≥91 `h_piot_*` fns + the 6 config relations) · operator PO/event heads track F1 within minutes. F1 columns in the matrix are a **sanity reference only**.
- **P4.** Take an **EBS snapshot** of the staging DB volume (cheap insurance; mandatory before Step 5, harmless now).

### Step 1 — Re-point READ/RENDER plane to F3 (the long pole; do FIRST). Satisfies criterion (C).
- Ensure pgbouncer `packiot_shadow` pool is live (it is, via the compose command).
- Ensure refdata effective `REFDATA_FLOW=f3` (deploy/redeploy refdata-api).
- Migrate Grafana boards from `packiot-postgres` (F1) to `packiot-postgres-shadow` (F3) datasource; repoint the one `uns_metrics` panel to `uns_equipment_current_metrics`. **Leave operator-log (`user_logs`) panels on F1** — that is the retained operator substrate, not a gap.
- **Do NOT re-track staging Hasura** (edge-node-red-only; stays on `packiot.public`).
- **Verification gate (criterion C):** run the fidelity harness — every Surface-1 read + Grafana panel byte-stable F3-vs-F1 for ent 3&4 **over ≥48h**; front4 (Amplify) dashboards render; operator PWA `/v1/*` cached screens unchanged; confirm `users` seed suffices for role/menu reads.
- **Rollback:** point refdata `REFDATA_FLOW=f1` + Grafana datasource back to `packiot`. Instant, zero data impact.

### Step 2 — Silence + retire the F1↔F3 comparator and F2 dashboard.
- `BAKE_COMPARATOR_ENABLED=false` on `oeecloud-worker`; unprovision `09-bake-flow-parity`.
- **Verify:** no comparator metrics/alarms; no dashboard errors.
- **Rollback:** re-enable env + re-provision.

### Step 3 — Stop the F2 (`shadow_go_port`) emit + write path (keep the schema).
- `edge-transformer`: gate off the `"go"` leg (⚠️ **the one code change the collapse needs** — the F2 leg is hardcoded at `main.go:1316` `sourceTypes := []string{"go"}`; add a `SHADOW_EMIT_GO` env gate default `true`, then set it `false`). `oeecloud-worker`: drop the `go` route in `flows.go`. `shadow-mirror`: drop `shadow_go_port` handlers. `mirror-worker-go`: drop the F2 fan target.
- **Verify:** `shadow_go_port.equipment_values` row count flatlines (no new writes); F3 unaffected; shadow-mirror still writing F3.
- **Rollback:** revert routing/env, redeploy.

### Step 4 — THE ATOMIC FLIP: cut F3 telemetry to the direct-PLC path; stop F1 telemetry emit + compute.
> **HARD ORDER GUARD: do NOT run Step 4 until Step 1's 48h gate is GREEN and G0b (reconciler F3 fan-out draining) is confirmed.** F1 going stale with reads still on F1 = a customer-visible outage on staging demo surfaces; F3 without the reconciler fan loses prod-authoritative PO/event closes.

- `edge-transformer`: `SHADOW_EMIT_PRODUCTION=false` (stop F1 leg); keep `SHADOW_EMIT_REFACTORED=true` + `CALC_CUTOVER_REFACTORED=true`.
- `ingest-shim`: `FANOUT_SOURCE_TYPES=refactored` (⚠️ **stale default is `legacy`/F1** — must be set explicitly or Incoplast lands in F1, not F3).
- `oeecloud-worker`: refactored-only routing; Incoplast leg refactored-only; `CONSUME_LANES` 4→2 (triple volume no longer arrives).
- `mirror-worker-go`: `SHADOW_VALUE_FANOUT=false` (per §4.2 keep its operator-replay + reconciler roles, F3-only).
- **Stop F1/F2 compute (reversible via `alter_job(…, scheduled => true)`):** disable pg_cron **#1 `oee-compute`** (F1's last active compute — live-confirmed active); `#3` already inactive; unschedule F1 cagg jobs and F2 jobs. **Keep housekeeping cron #2/#5/#8. Keep all F3 cascade jobs.**
- **Verification gate (A+B):**
  - **(A)** F3 `equipment_values → runtime_shift/_1hour/_1day → uns_*` correct + fresh (< 2s) from the PLC path for ent 3&4; F1 telemetry tables stop advancing (expected).
  - **(B)** drive a PO start/stop + downtime through the operator queue → confirm it lands in `packiot_shadow` via shadow-mirror.
  - Read plane (now on F3) healthy; re-run the fidelity harness — F3 A/B/C still green vs the P3 baseline.
- **Rollback:** restore `SHADOW_EMIT_PRODUCTION=true` + fan-out + `alter_job(scheduled=>true)` on the F1 jobs, redeploy — triple-emit resumes.

### Step 5 — POINT OF NO RETURN: freeze, then drop dead schemas/DBs (after EBS snapshot).
Order (no-consumer first; **F1 is NOT dropped here** — it survives as the Phase-1 operator substrate; it drops only in the optional Phase 2):
1. Revoke writes on `shadow_go_port`, leave readable **≥7 days**, then `DROP SCHEMA shadow_go_port CASCADE` (F2 — zero product consumer).
2. `DROP SCHEMA parity_go / parity_legacy / shadow_diff CASCADE` (comparator scaffolding).
3. Stop the live feed to **`packiot_refactor`** (the naming-sweep/PowerBI-façade sandbox DB, live-fed for no product purpose), then `DROP DATABASE packiot_refactor`.
4. **`uns_metrics` audit gate:** before dropping F1's `uns_metrics` (10.4M rows), re-confirm reports/BigQuery don't read it (pre-cleared in ADR-0032 §2.5). F1 itself stays frozen-but-alive in Phase 1 regardless.
- **Verify:** grep clean (no service references dropped objects); EBS snapshot recorded before each `DROP`.
- **Rollback:** snapshot restore only — hence the ≥7-day freeze window.

### Preserved throughout
`shadow-mirror` (operator actions → F3), `mirror-worker-go` operator-replay + reconciler, `operator-adapter`, edge-api → `user_logs`. **The operator write path never changes** in Phase 1.

### 🔒 GATED / OUT OF SCOPE
Phase 2 edge-api-direct (ADR-0024 step 3), promoting `packiot_shadow` to operational (true ADR-0016 flip), Hasura retirement + front4 full re-point, any prod cutover.

### 🧷 Ride-along hardening — carry these three into the flip runbook (do NOT execute here)
These are not new gates; they are pre-flip insurance items that MUST be explicit in the executed runbook so they aren't skipped under time pressure:

1. **EBS snapshot before the point of no return.** Take a fresh snapshot of the staging DB volume immediately before Step 4 (the atomic flip) and again before each Step-5 `DROP` (ties to P4 · R10). Rollback of Steps 1–4 is flag/routing revert; rollback of Step 5 is *snapshot-restore only*. No snapshot ⇒ no Step 5.
2. **Thin ent 3/4 `users` seed.** `packiot_shadow.users` for ent 3/4 = **1 row** (R8). Before treating Step 1 as green, confirm that single seed covers the role/menu reads front4/operator make under `f3` (`v_menu_per_user_role` / `user_roles` must not come back empty in the gate); seed more rows if they do.
3. **ent 4 / Incoplast is NOT flip-ready — the flip carries ent 3 (CPACK) only.** Incoplast F3 behavior is un-blessed (R6, ADR-0022 gap) and its F3 rollups are still thin (2026-07-26: ent-4 `producing_shifts=0` on F3). Keep ent-4 telemetry flagged un-blessed; the acceptance bar and the Step-4 flip are scoped to **ent 3**. Do not gate the flip on ent-4 parity, and do not treat ent-4 F3 as production-ready.

---

## 5. Risks + prerequisites NOT yet met

| # | Risk / gap | Severity | Mitigation / what's needed |
|---|---|---|---|
| R1 | **Read plane goes stale/blank if Step 4 runs before Step 1's 48h gate is green.** F1's derived compute is already dead (`uns_current_shift` frozen 16d); stopping cron#1 + caggs freezes the rest. | **High** | Hard order guard on Step 4 (§4). Non-negotiable sequencing. |
| R2 | **G0b reconciler stale tail.** ~593 recalc rows >1 day old; F3-sole inherits PO/event closes only via the reconciler fan. | Medium | Confirm reconciler F3 fan **draining, not growing on ent 3/4** before Step 4. Backlog is ~all ent 2 (sim) — lower risk to the ent-3/4 bar, but verify. |
| R3 | **G0 not live-verified here** (needs Prometheus/Grafana, not the DB). | Medium | Check `v2-po-staleness-gate` (ent 3,4) in pre-flight P2. |
| R4 | **G-DEPLOY unconfirmed** — compose says `f3` but running-container state not proven from the DB. | Medium | Confirm effective refdata env before treating Step 1 as done (P1). |
| R5 | **Fidelity harness transport is blocked.** `adr0032-f3-fidelity-check.sh` uses `AWS-RunShellScript` send-command (policy-blocked on this account). | Medium | Port to `AWS-StartNonInteractiveCommand` start-session transport (working pattern in §6) before the flip; otherwise the A/B/C gate can't run as written. |
| R6 | **Incoplast (ent 4) behavior unvalidated** (ADR-0022 gap). | Medium | Collapse only removes the parallel-run, not the behavior gate. Keep Incoplast F3 telemetry flagged **un-blessed**; do not treat as flip-ready for prod. |
| R7 | **CPACK staging becomes synthetic-only** once mirror fan-out stops (plc-sim is a *subset* of lines). | Low (staging) | Accept for teardown, or keep `mirror-worker-go` fan-out **to F3 only** as interim (§4.2). Real L6 CPACK tee (session-88 wave-2) supersedes this when live. |
| R8 | **Thin `users` seed** — `packiot_shadow.users` ent3/4 = 1 row. | Low | Confirm 1 row covers the role/menu reads front4/operator make under f3; seed more if `v_menu_per_user_role`/`user_roles` come back empty in the Step-1 gate. |
| R9 | **`equipment_runtime_shift` future-dated `ts_value`** (`2026-08-22`, ~30d ahead) on F3 — plc-sim clock artifact. | Low | Cosmetic/sim-only; note it so it isn't misread as a fidelity defect during the gate. |
| R10 | **Step 5 `DROP`s irreversible.** | High if mis-sequenced | Freeze ≥7 days + EBS snapshot before each drop; F1 explicitly NOT dropped in Phase 1. |

---

## 6. Ops appendix — the working SSM transport (send-command is blocked)

`AWS-RunShellScript` (send-command) is **policy-blocked** on this account. The verified read-only path used for every figure in this doc:

- Transport: `AWS-StartNonInteractiveCommand` session document via `aws ssm start-session`, driven under `script -qec` (PTY).
- The doc **execs the `command` element directly (no shell) and word-splits it on spaces.** To run a pipeline you must invoke bash yourself and keep the script a single space-free word using `${IFS}`:
  ```
  aws ssm start-session --target i-064bb36d1c454d861 \
    --document-name AWS-StartNonInteractiveCommand \
    --parameters 'command=["bash -c echo${IFS}<REMOTE_B64>|base64${IFS}-d|sudo${IFS}bash"]' \
    --region us-east-1
  ```
  where `<REMOTE_B64>` is base64 of a remote script that pipes SQL into the container over **stdin** (a host-written `/tmp` file is invisible to `docker exec` — the container has its own `/tmp`):
  ```
  echo <SQL_B64> | base64 -d | docker exec -i timescaledb psql -U postgres -d <db>
  ```
- DB user is `postgres`; `sudo` is required (`ssm-user` is not in the docker group). Always `BEGIN READ ONLY` for audits.

Porting `adr0032-f3-fidelity-check.sh` to this transport is pre-flight task **P3 / R5**.

---

## 7. Readiness verdict

**Verdict: CONDITIONALLY READY — the build is done; the flip is gated on four verifications, none of which is a build blocker.**

- **The long pole (Step 1 read-plane) is BUILT and STAGED.** The §5.1 "38 objects missing from F3" gap that was the original blocker is **closed** — `packiot_shadow` live-carries 91 `h_piot_*` analytics functions + all 6 config relations, refdata `f3` plumbing + pgbouncer pool + Grafana F3 datasource + front4 flag all exist.
- **Criterion (A) infrastructure is proven live** — F3 telemetry and rollups compute to *now*; F1's own derived compute is already a corpse, which *de-risks* stopping it.
- **Nothing has collapsed** — triple-emit is fully live, so the flip is a clean, un-taken, reversible action through Step 4.

**Before the USER executes, close these four (all verification, ~none building):**
1. **G-DEPLOY (P1)** — confirm the running refdata container's effective `REFDATA_FLOW`.
2. **G0 (P2)** — confirm the #32 staleness gate on Grafana for ent 3,4.
3. **G0b (R2)** — confirm the reconciler F3 fan-out is draining (not growing) on ent 3/4; the current stale tail is ~all synthetic ent 2.
4. **Step-1 48h parity gate (P3)** — port the fidelity harness off the blocked send-command transport, capture the F1 baseline, run the ≥48h A/B/C matrix green.

Two small hardening items ride along: confirm/expand the ent 3/4 `users` seed (R8), and note the sim-only future-dated shift rows (R9) so they aren't misread during the gate.

**On sign-off, execution follows §4 Steps 1→5 in order, with Step 4 hard-gated behind the Step-1 48h gate + G0b, and Step 5 (the only irreversible act) last behind a ≥7-day freeze + EBS snapshot.** Completing through Step 4 unblocks the **B1 Bronze append-only cutover (#594)** and the ADR-0036 retention-immutability work.
