# ADR-0032 — Collapse the staging three-flow parallel-run to the refactored flow (F3) as the sole telemetry-compute flow

**Status:** Proposed · **Date:** 2026-07-20 · **Scope:** STAGING ONLY (no prod change; any prod-touching step is explicitly gated below) · **Decision owner:** tech-lead (pending USER review — this ADR is the plan; execution is deferred until the USER signs off)

**Builds on / honors:**
- [ADR-0013](0013-shadow-mirror-service.md) — defines the 3-flow model and the shadow-mirror operator-action replay this ADR *preserves*.
- [ADR-0016](0016-staging-consolidation-master-plan.md) — the consolidation endgame (promote `packiot_shadow`, retire F2 + dual-emit + comparators). This ADR executes the *parallel-run teardown* half of ADR-0016, but **stops short of the atomic flip** (edge-api still writes F1; shadow-mirror stays).
- [ADR-0024](0024-phased-mirror-retirement.md) — the load-bearing sequencing authority. This ADR is the **concrete staging execution of ADR-0024's "data direct from client, actions still mirror-replayed" intermediate safe state** (step 2 done, step 3 NOT done). It does *not* supersede ADR-0024; it instantiates it.
- [ADR-0022](0022-pre-flip-behavior-correctness-validation.md) — the correctness bar the collapse rests on; its Incoplast-behavior gap is a named risk here.

**Relates to:**
- [ADR-0025](0025-three-flow-po-state-reconciliation.md) — the three-flow prod-authoritative PO reconciler simplifies to single-target when F2 dies; it is *not* fully retired here (retires with the action mirror, ADR-0024 step 3).
- [ADR-0026](0026-api-layer-consolidation.md) / [ADR-0027](0027-refdata-api-surface-1-read-contract.md) — the read-plane consolidation. **Critical coupling: refdata-api reads F1 (`packiot.public`) today.** Re-pointing the read plane to F3 is the hard gate before F1 telemetry compute can stop (see §5).

> **Numbering:** `0030` is intentionally unallocated (see ADR-0031's numbering note); `0031` is taken. This is `0032`.

---

## 1. Directive & interpretation (validated against the repo)

**USER directive (verbatim):** *"keep just one flow. the packiot refactor one and get data from cpack and incoplast directly from the plc. the operator will still use shadow mirror for operator actions."*

**Interpretation, corrected against the actual staging stack:**

The staging stack runs a **triple-emit parallel-run** for migration validation. One PLC/tee event is stamped with three `source_type` values by `edge-transformer` and fanned by `oeecloud-worker` into three destinations:

| Flow | `source_type` | Destination | Role |
|------|---------------|-------------|------|
| **F1** | `""` (empty) | `packiot.public` (the **operational DB**) | Legacy oeecloud engine faithfully reproduced. edge-api writes here; **Hasura + refdata-api + operator + front4 READ here.** |
| **F2** | `"go"` | `packiot.shadow_go_port` (schema in the same DB) | ADR-0010 Go-decode shadow. Deliberately raw/un-cut-over — the tsp12 divergence *control*. |
| **F3** | `"refactored"` | `packiot_shadow` (**separate database**) | ADR-0012/0014 refactored end-state: Go Calc (`CALC_CUTOVER_REFACTORED=true`), extracted OEE math, `customer_dashboards` pool, `ca_*` CAggs. **This is "the refactor one."** |

**Two corrections the directive's framing needs (and this ADR makes explicit):**

1. **F3 is a separate *shadow database*, not the operational DB.** "Keep just one flow" in the full-flip sense (ADR-0016: *promote `packiot_shadow`, retire shadow-mirror*) would make edge-api write F3 directly and make shadow-mirror pointless. **The directive keeps shadow-mirror** — which is decisive: it describes the **intermediate state**, not the full flip. So "sole flow" here means **sole telemetry-compute flow**. F1's *operational substrate* role (edge-api control plane, `user_logs`, and — until re-pointed — the read plane) survives; only F1's *legacy OEE compute* and F2 *in its entirety* retire.

2. **"Directly from the PLC" = the SparkPlug → `edge-transformer` (Go Calc) → `oeecloud-worker` (refactored) → `packiot_shadow` path**, replacing the cross-flow mirror fan-out as F3's telemetry source. On staging there is no physical CPACK/Incoplast PLC, so "the PLC" is emulated:
   - **CPACK (ent 3):** `plc-sim` (synthetic SparkPlug B, absolute totalizers — faithful, do not "fix") → `mosquitto` → `edge-transformer`. This *is* ADR-0024's data-cutover ("real client PLC feeds the per-factory transformer") emulated on staging.
   - **Incoplast (ent 4):** the **real factory tee** → `ingest-shim` (:8444, HTTPS→RabbitMQ) → `oeecloud-worker`. Already a live real-PLC feed.

This ADR is therefore ADR-0024 **step 2 (data cutover / retire the data mirror) executed on staging, plus the parallel-run teardown (F2 + comparators)** — with **step 3 (action cutover) deliberately NOT done**, exactly as the directive requires.

### 1.1 Acceptance gate & simplification latitude (staging only)

This is a **staging** change; **prod is untouched** (staging exists to mirror prod's data/operator/front behavior). The collapse is accepted iff, after F3 becomes the sole flow, staging still passes **three fidelity criteria**:

- **(A) DATA fidelity** — F3 produces correct OEE: `equipment_values → equipment_runtime_shift/_1hour/_1day rollups → uns_* views` match the faithful/prod-correct output for CPACK (ent 3) + Incoplast (ent 4).
- **(B) OPERATOR fidelity** — PO control + downtimes still land in F3 via the operator durable-write-queue (#31) → edge-api → `user_logs` → **shadow-mirror → packiot_shadow (F3)** path.
- **(C) FRONT fidelity** — front4 (now hosted on **AWS Amplify**) renders correctly reading F3 (through refdata-api / its read path), and Grafana boards render off the F3 datasource.

**Beyond preserving A/B/C, there is full architectural latitude to simplify aggressively** — rip out F1 legacy compute, F2 `shadow_go_port`, the F1/F2 comparators + reconcilers, and any cross-flow replay that only existed to feed the parallel-run. The single-flow end state should be the *cleanest* topology that still satisfies A/B/C, not a minimal diff. (The one guardrail: the operator write path in criterion B must survive intact — the directive keeps shadow-mirror.)

---

## 2. Current topology (grounded in `compose.staging.yml` + service source)

### 2.1 Telemetry ingress (three physical sources, one fan-out)

```
                                   ┌─────────────────────────────────────────────┐
 plc-sim (172.18.0.200, synthetic  │                                             │
   CPACK SparkPlug B) ─── MQTT ───▶ mosquitto(.24) ──▶ edge-transformer(.23)      │
                                   │   USE_GO_PORT=true                           │
                                   │   SHADOW_EMIT_PRODUCTION=true  → source ""   │  triple-emit
                                   │   SHADOW_EMIT_REFACTORED=true  → "refactored"│  (one reality,
                                   │   (F2 "go" leg also stamped)                 │   three tags)
                                   │   CALC_CUTOVER_REFACTORED=true (F3 Calc)     │
                                   └───────────────┬─────────────────────────────┘
                                                   │ RabbitMQ `oee` exchange
 Incoplast real factory tee ──HTTPS──▶ ingest-shim(.29) ──sparkplug.data.incoplast──┤
                                                   │                                 │
                                                   ▼                                 ▼
                                          oeecloud-worker(.20)  ──CONSUME_LANES=4──▶ writers
                                            source ""        → packiot.public         (F1)
                                            source "go"      → packiot.shadow_go_port  (F2)
                                            source "refactored" → packiot_shadow.public (F3)
                                            LEGACY_INGEST_ENABLED=true (Incoplast → F1/F3)
                                            BAKE_COMPARATOR_ENABLED=true (F1 vs F3 diff)
```

- **`edge-transformer`** (`services/edge-transformer`, `.23`): MQTT subscriber (`MQTT_ENABLED=true`), Go Calc port live (`USE_GO_PORT=true`, `CALC_CUTOVER_REFACTORED=true`). Emits all three `source_type` legs. Flow routing lives in `internal/shadowpub/publisher.go`; the F3 Calc-shape branch gates on `st == "refactored"`.
- **`oeecloud-worker`** (`services/oeecloud-worker`, `.20`): AMQP consumer; flow routing table in `internal/flows/flows.go`; per-flow writers in `internal/writers/`; the F1-vs-F3 comparator in `internal/bake/` (`BAKE_COMPARATOR_ENABLED`, `BAKE_ENTERPRISE_IDS="3,4"`). Shift resolver, events deriver, PO recalc, UNS derivers all fan per-flow.
- **`ingest-shim`** (`.29`): Incoplast real-tee HTTPS ingress → `oee`/`sparkplug.data.incoplast`.
- **`plc-sim`** (`.200`): synthetic SparkPlug B; THE staging MQTT ingest (simulates a subset of CPACK lines — L8/L5-BREYER/L5-TEXA/L3-PTH/L4-TEXA — with absolute totalizers).

### 2.2 CPACK "prod-anchored" data path (the data mirror)

- **`mirror-worker-go`** (`.21`): pulls **prod CPACK (ent 1)** `user_logs` + `equipment_values`, replays operator actions to staging edge-api (→ ent 3), and **fans `equipment_values` deltas to all three flows** (`SHADOW_VALUE_FANOUT=true`, `POSTGRES_SHADOW_DB_NAME=packiot_shadow`). Also runs the ADR-0025 prod-authoritative PO reconciler (`RECONCILE_FINISHER_ENABLED=true`, `RECONCILE_EVENTS_CLOSE_SWEEP_ENABLED=true`), scoped to CPACK/ent 1 only. **This is ADR-0024's "data mirror."**

### 2.3 Operator write path (the action mirror — PRESERVED)

```
operator SPA (durable-write-queue #31) ──┐
                                          ├─▶ edge-api(.3) ──▶ packiot.public.user_logs (F1)
operator-adapter(.30, Incoplast tee) ────┘                          │
                                                                    ▼
                                          shadow-mirror(.25) tails user_logs ──▶ shadow_go_port (F2)
                                            SHADOW_MIRROR_ENABLED=true         └▶ packiot_shadow.public (F3)
```

- **`shadow-mirror`** (`.25`): tails `packiot.public.user_logs`, replays PO lifecycle / downtimes / operator-edited events to **F2 + F3** (the tables the data-plane `source_type` routing does not cover). 10 handlers, ~90% of daily operator volume. **This is ADR-0024's "action mirror" — the directive keeps it.**
- **`operator-adapter`** (`.30`): Incoplast's bespoke operator UI tees actions here → edge-api → `user_logs`, so shadow-mirror can carry them to F3.

### 2.4 Read plane (the coupling that governs the whole collapse)

The read/render surface is the **standard stack** — no exotic consumers. Each currently reads a specific flow's DB/schema:

- **Grafana** (`.7`): provisions **two** postgres datasources — `Packiot PostgreSQL` (uid `packiot-postgres`, `database=$POSTGRES_DB=packiot` → **F1**) and `Packiot Shadow (F3)` (uid `packiot-postgres-shadow`, `database=packiot_shadow` → **F3**). Dashboards bound to the F1 datasource UID read F1; the F3 datasource already exists. Re-point = migrate boards to `packiot-postgres-shadow`.
- **`refdata-api`** (`.26`): `DB_NAME=packiot` → **reads F1 (`packiot.public`)** via pgbouncer. Every ADR-0027 Surface-1 dataset is a `public`-schema view/function/table (`v_operator_*`, `h_piot_*`, `equipments`, `shifts`, …). **Not schema-qualified to `packiot_shadow`.**
- **front4** (on **AWS Amplify**): reads via refdata-api / Hasura against F1 today. Re-point follows refdata-api.
- **`hasura`** (`.2`) / **reports**: read `packiot.public` (F1) directly.
- **`operator` PWA**: runtime-caches `GET /v1/*` from refdata-api (F1-backed) under `refdata-v1-reads`.

**No consumer reads F2 (`shadow_go_port`).** Grep of `services/` confirms `shadow_go_port` appears only in the parallel-run plumbing (mirror-worker-go, shadow-mirror, oeecloud-worker, edge-transformer) and the `09-bake-flow-parity` dashboard — never a render/report consumer. **F2 is pure validation scaffolding and is safe to drop.**

---

## 3. Target architecture — single telemetry-compute flow (F3)

```
CPACK: plc-sim ──MQTT──▶ mosquitto ──▶ edge-transformer (Go Calc, refactored emit ONLY)
Incoplast: real tee ──▶ ingest-shim ────────────────┐
                                                     ▼
                                       oeecloud-worker (refactored lane ONLY)
                                                     ▼
                                          packiot_shadow.public  ◀── THE telemetry flow (F3)
                                                     ▲
operator SPA / operator-adapter ──▶ edge-api ──▶ packiot.public.user_logs
                                                     │
                                       shadow-mirror ┘  (F3 target ONLY — F2 leg removed)
```

**What feeds F3 (target):**
- CPACK telemetry: `plc-sim → edge-transformer(refactored) → oeecloud-worker(refactored) → packiot_shadow`.
- Incoplast telemetry: `real tee → ingest-shim → oeecloud-worker(refactored) → packiot_shadow`.
- Operator actions: `edge-api user_logs → shadow-mirror(F3 only) → packiot_shadow`. **Preserved verbatim.**

**What is GONE:**
- F1 legacy-compute *emission* (`source_type=""` telemetry leg) and the F2 `source_type="go"` leg entirely.
- The F1-vs-F3 comparator + `09-bake-flow-parity` dashboard (nothing left to diff).
- The `shadow_go_port` (F2) schema — dead, drop after a freeze window.
- The mirror-worker-go *telemetry fan-out* to F1/F2 (superseded by the direct PLC path for F3).

**What SURVIVES (and why):**
- `packiot.public` as **operational substrate** — edge-api control plane, `user_logs`, and (until §5 re-point completes) the read plane. It is no longer a *compared flow*; it becomes the operator-ingress + reference-data home that feeds F3.
- `shadow-mirror` — the operator action mirror (directive).
- `mirror-worker-go` **operator-replay + reconcile** role — see §4.2 (open decision).

---

## 4. What retiring F1 + F2 entails (per service / schema)

### 4.1 Service & flag changes

| Component | Change | Env / code | Reversible? |
|-----------|--------|-----------|-------------|
| `edge-transformer` | Stop F1 + F2 emit legs; emit `refactored` only | `SHADOW_EMIT_PRODUCTION=false`; remove/false the `"go"` leg; keep `SHADOW_EMIT_REFACTORED=true`, `CALC_CUTOVER_REFACTORED=true` | Yes — flip envs back, redeploy |
| `oeecloud-worker` | Stop F1/F2 lanes; keep refactored writer | Trim `internal/flows/flows.go` routing to `refactored`; `BAKE_COMPARATOR_ENABLED=false`; drop F1 Incoplast leg (`LEGACY_INGEST_ENABLED` → refactored-only) | Yes — env + revert routing |
| `oeecloud-worker` | Per-flow derivers (shift resolver, events, PO recalc, UNS) → F3 only | Already fan per-flow; drop F1/F2 targets | Yes |
| `shadow-mirror` | Drop F2 target; keep F3 | `PG_SHADOW_DB_NAME=packiot_shadow` stays; remove `shadow_go_port` writes in `internal/replay/handlers/*` | Yes — code revert |
| `mirror-worker-go` | Drop telemetry fan-out to F1/F2 | `SHADOW_VALUE_FANOUT=false` (or F3-only); reconciler F2 target dropped | Yes |
| `09-bake-flow-parity` dashboard | Retire (or repurpose to F3 health) | grafana provisioning | Yes |
| `shadow_go_port` schema (F2) | **Freeze first, drop later** | DDL — gated, last step | Drop is irreversible; freeze is not |

### 4.2 Open decision — `mirror-worker-go`'s split role

`mirror-worker-go` does **two** jobs; the directive kills one and touches the other:

1. **Telemetry fan-out** (`SHADOW_VALUE_FANOUT`) → **RETIRE.** F3 telemetry now comes from the direct PLC path ("data direct from the client"), and F1/F2 are gone.
2. **Prod-CPACK operator replay + ADR-0025 reconcile** → **KEEP (recommended), simplified to single-target.** Staging CPACK (ent 3) has *no live operator*; this replay is what seeds `packiot.public.user_logs`, which shadow-mirror then carries to F3. Killing it would starve F3 of CPACK operator actions. **Recommendation:** keep the replay + reconciler, drop only its F2 fan target, and let the reconciler operate F1→F3. (Per ADR-0025/0024 this reconciler fully retires only at the *action cutover* — step 3 — which this ADR does not do.)

   *Alternative (surface for USER):* retire `mirror-worker-go` entirely and drive CPACK operator actions via the operator SPA / simulator. Rejected as default — larger change, loses prod-anchored CPACK operator realism.

### 4.3 Data F1/F2 produced that F3 must still produce — gap check

The Go writer/shift-resolver is already the **sole writer** across all schemas (ADR-0014: `piot_set_shift_before_insert` retired, Go resolver sole shift writer on `public` + `packiot_shadow`), and OEE math is app-side, so **F3 already produces the full compute surface** — retiring F1/F2 *write* paths is a routing-table trim, not a schema-replication project. The **only** thing F1 uniquely still serves is the **read plane** (§5) and the **operator ingress / `user_logs`** (kept). No telemetry-output gap.

### 4.4 Consistency with ADR-0024

**Consistent, not superseding.** ADR-0024 splits the flip into three risk-ordered cutovers: (1) compute cutover [done, #276], (2) data cutover / retire data mirror, (3) action cutover / retire action mirror. This ADR executes **step 2 on staging + the parallel-run teardown**, and explicitly **freezes at ADR-0024's named intermediate safe state** ("data direct from client, actions still mirror-replayed"). It does **not** touch step 3 (shadow-mirror stays). ADR-0024's hard prerequisite — **the #32 staleness/durability gate baked on the target** — is inherited as Gate G0 below.

---

## 5. Risks & reversibility

### 5.1 THE load-bearing risk — the read plane is still bound to F1

`refdata-api` (and behind it: operator PWA, and via Hasura, front4) reads **`packiot.public` (F1)**. If F1's telemetry compute stops **before** the read plane is re-pointed to `packiot_shadow` (F3), every OEE read goes **stale/blank** — a customer-visible outage on staging demo surfaces. Neither ADR-0026 nor ADR-0027 re-points refdata-api; **this ADR must, and gates on it.**

Complication: F3's schema is *intentionally divergent* (`customer_dashboards` schema, `ca_*` CAgg names, retired matview families — ADR-0014). Re-pointing refdata-api is **not** a connection-string swap — each Surface-1 dataset's SQL must be re-validated against `packiot_shadow`'s objects. This is the real work and the real risk.

### 5.2 Other risks

| Risk | Mitigation |
|------|-----------|
| Comparator alarms fire when F1 stops emitting | Retire comparator + dashboard **in the same step** as F1 emit stop; silence `09-bake-flow-parity` first |
| Incoplast behavior unvalidated (ADR-0022 gap) | Do not treat Incoplast F3 as flip-ready; this ADR only removes the *parallel-run*, not the behavior gate. Keep Incoplast on F3 telemetry but flag it un-blessed |
| CPACK staging fidelity drops (plc-sim is a *subset* of lines) | Accept for parallel-run teardown; note F3 CPACK telemetry becomes synthetic-only once mirror fan-out stops. If real-prod-anchored CPACK telemetry is still wanted on staging, keep `mirror-worker-go` fan-out *to F3 only* as an interim (decision in §4.2) |
| `shadow_go_port` dropped while some ad-hoc query still reads it | Freeze (revoke writes, keep readable) for ≥7 days before `DROP SCHEMA`; grep confirms no service reads it |
| prod accidentally touched | **None of these steps touch prod.** Prod cutover is a separate, later, gated program (ADR-0016/0017 endgame). Any prod SELECT for verification stays `BEGIN READ ONLY` via the awslambda role |

### 5.3 Reversibility posture

Every telemetry-collapse step is a **flag flip or routing revert + redeploy** (see §4.1 "Reversible?" column). The only irreversible act is `DROP SCHEMA shadow_go_port`, deliberately sequenced **last** and preceded by a freeze window + EBS snapshot. Rollback of the whole collapse = restore the three `SHADOW_EMIT_*`/`BAKE_COMPARATOR`/`SHADOW_VALUE_FANOUT` envs and the `flows.go` routing, redeploy — the triple-emit resumes.

---

## 6. Sequenced execution plan (each step reversible, each gated)

**Scope reminder: STAGING ONLY. Do not execute until USER sign-off.** Prod steps are marked 🔒GATED and are out of scope for this ADR.

**G0 — prerequisite (ADR-0024):** confirm the **#32 staleness/durability gate is baked on the CPACK + Incoplast staging tenants** (`po_gate_degraded_total`→0, `PO_STALENESS_GATE_ENTERPRISES="3,4"` live). *Verify:* Grafana `v2-po-staleness-gate` — 409-rate 0, liveness non-zero.

**Step 1 — Re-point the READ/RENDER plane to F3 (the long pole; do FIRST). Satisfies acceptance criterion (C).**
- Port each `refdata-api` Surface-1 dataset SQL to `packiot_shadow` objects; run behind a `DB_NAME`/flow-routing switch so it can serve F1 or F3.
- Migrate Grafana boards from the `packiot-postgres` (F1) datasource to the existing `packiot-postgres-shadow` (F3) datasource.
- Verify front4 (Amplify) + operator PWA render correctly off the re-pointed refdata-api.
- *Verify gate:* dataset-level parity — every Surface-1 read + Grafana panel returns byte-stable shape + values from F3 vs F1 for ent 3 & 4 over ≥48h; front4 dashboards render; operator PWA `/v1/*` cached screens unchanged. **This is criterion (C).**
- *Reversible:* point `refdata-api` + Grafana datasource back at `packiot`.

**Step 2 — Silence + retire the comparator and F2 dashboard.**
- `BAKE_COMPARATOR_ENABLED=false` on `oeecloud-worker`; unprovision/retire `09-bake-flow-parity`.
- *Verify:* no comparator metrics/alarms; no dashboard errors.
- *Reversible:* re-enable env + re-provision.

**Step 3 — Stop the F2 emit + write path (drop `shadow_go_port` writes, keep schema).**
- `edge-transformer`: remove the `"go"` emit leg. `oeecloud-worker`: drop the `go`/`shadow_go_port` route in `flows.go`. `shadow-mirror`: drop `shadow_go_port` handlers. `mirror-worker-go`: drop F2 fan target.
- *Verify:* `shadow_go_port` row counts flatline (no new writes); F3 unaffected; shadow-mirror still writing F3.
- *Reversible:* revert routing, redeploy.

**Step 4 — Cut F3 telemetry over to the direct-PLC path; stop F1 telemetry emit.**
- `edge-transformer`: `SHADOW_EMIT_PRODUCTION=false` (stop F1 leg); keep `SHADOW_EMIT_REFACTORED=true` + `CALC_CUTOVER_REFACTORED=true`.
- `oeecloud-worker`: refactored-only routing; Incoplast leg refactored-only (was `LEGACY_INGEST` → F1/F3).
- `mirror-worker-go`: `SHADOW_VALUE_FANOUT=false` (or F3-only per §4.2 decision).
- **Do NOT run this before Step 1's gate is green** — F1 telemetry going stale with reads still on F1 = outage.
- *Verify:* **criterion (A)** — F3 `equipment_values → equipment_runtime_shift/_1hour/_1day → uns_* views` correct + fresh (< 2s) from the PLC path for ent 3 & 4; F1 telemetry tables stop advancing (expected); read plane (now on F3) healthy. **criterion (B)** — drive a PO start/stop + downtime via the operator queue and confirm it lands in `packiot_shadow` via shadow-mirror.
- *Reversible:* restore `SHADOW_EMIT_PRODUCTION=true` + fan-out, redeploy — F1 resumes.

**Step 5 — Freeze `shadow_go_port`, then drop (irreversible — last).**
- Revoke writes / leave readable ≥7 days; take EBS snapshot of the DB EC2; then `DROP SCHEMA shadow_go_port CASCADE`.
- *Verify:* no service references it (grep clean); snapshot recorded.
- *Reversible:* only via snapshot restore — hence the freeze window.

**Preserved throughout:** `shadow-mirror` (operator actions → F3), `mirror-worker-go` operator-replay + reconciler (§4.2), `operator-adapter`, edge-api → `user_logs`. **The operator write path never changes.**

🔒**GATED / OUT OF SCOPE (later program):** promoting `packiot_shadow` to the operational DB (the true ADR-0016 flip), retiring `shadow-mirror` (ADR-0024 step 3 action cutover), Hasura retirement + front4 re-point (ADR-0026/0028/0029), and any prod cutover (ADR-0017 endgame).

---

## 7. Consumers — standard-stack re-point census

No exotic consumers: the render/read surface is the standard stack. Enumerate each, the flow it reads today, and its re-point to F3 (`packiot_shadow`). This whole set is **Step 1** and satisfies acceptance criterion **(C)**.

| Consumer | Reads today | Re-point action |
|----------|-------------|-----------------|
| **Grafana** (datasource + boards) | F1 via `packiot-postgres` datasource | Migrate boards to the existing `packiot-postgres-shadow` (F3) datasource; make F3 the default. Notable — dashboards are the most numerous binding |
| **refdata-api** | F1 `packiot.public` | **Re-point `DB_NAME`/routing to `packiot_shadow`; port each Surface-1 dataset SQL to F3's objects.** The hard-pole item |
| **front4** (AWS Amplify) | F1 via refdata-api / Hasura | Inherits refdata re-point; verify Amplify build renders off F3 (criterion C) |
| **operator PWA** (`/v1/*` cache) | F1 via refdata-api | Inherits refdata re-point; response shapes must stay byte-stable |
| **Hasura / reports** | F1 `packiot.public` directly | Re-point at `packiot_shadow`, or retire Hasura per ADR-0026 once front4 no longer needs it |
| **F2 `shadow_go_port` readers** | none | Safe to drop (§2.4) |

---

## 8. Decision

Adopt the collapse **as the staging execution of ADR-0024's intermediate "data-direct, actions-mirrored" state plus the F2/comparator teardown**, sequenced per §6, **gated on Step 1 (read/render-plane re-point to F3)** and **G0 (#32 gate baked)**. The success bar is the three staging-fidelity criteria of §1.1: **(A)** F3 OEE data correct, **(B)** operator writes land in F3 via shadow-mirror, **(C)** front4 (Amplify) + Grafana render off F3. Beyond A/B/C, simplify aggressively — F1 legacy compute, F2 `shadow_go_port`, the comparators/reconcilers, and parallel-run replay all go. Preserve the operator write path (`shadow-mirror` + `mirror-worker-go` operator replay). Defer the true flip, action cutover, and all prod change to the existing endgame ADRs. **Prod is untouched.** Execute only after USER review.
