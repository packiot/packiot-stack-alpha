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

2. **"Directly from the PLC" = every PLC's SparkPlug lands on `edge-transformer`, which is the single source-agnostic processor → `oeecloud-worker` (refactored) → `packiot_shadow`.** `edge-transformer` subscribes to `spBv1.0/+/+/+/+` (`main.go:416`); it does **not** care what is publishing — a real CPACK PLC, a real Incoplast PLC, or the `plc-sim` simulator all decode → alias-resolve → Calc → emit identically. This is exactly the directive's intent, and it is already the design.

   **The synthetic-vs-real distinction is a staging test-fixture detail, NOT an architectural concern and NOT a decision to be made.** What differs today is only *transport* and *who is publishing on staging*:
   - **CPACK (ent 3):** on staging, `plc-sim` (synthetic SparkPlug B, absolute totalizers — faithful, do not "fix") publishes to `mosquitto`, which `edge-transformer` consumes. In prod the real CPACK PLCs publish to that same broker the identical way. `plc-sim` is a stand-in for the live factory feed we simply don't have tee'd to the *staging* broker — it is not a different code path and requires no "build a CPACK tee" decision.
   - **Incoplast (ent 4):** the real factory tee → `ingest-shim` (:8444) republishes the SparkPlug **verbatim** onto the **same `oee` exchange + `sparkplug.data` routing key `oeecloud-worker` already consumes** (confirmed in the shim's header). So it converges on the identical processing pipe; `ingest-shim` is only a public HTTPS front-door so RabbitMQ stays internal.

   **Convergence, stated plainly:** both tenants already funnel into one processor → one worker → F3. The pure single-flow target is precisely "every PLC → `edge-transformer` → F3," with `ingest-shim` reduced to a transport adapter in front of it. There is *no* second brain and *no* CPACK-tee gap.

This ADR is therefore ADR-0024 **step 2 (data cutover / retire the data mirror) executed on staging, plus the parallel-run teardown (F2 + comparators)** — with **step 3 (action cutover) deliberately NOT done**, exactly as the directive requires (but see §4.5 for the optional second phase that *does* close step 3).

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
- **front4** (on **AWS Amplify**): reads via refdata-api against F1 today. Its GraphQL client is hardcoded to **prod** Hasura Cloud (`gqlpiot.packiot.com`), NOT staging Hasura — so staging Hasura is irrelevant to front4's re-point; it follows **refdata-api** only.
- **`operator` PWA**: runtime-caches `GET /v1/*` from refdata-api (F1-backed) under `refdata-v1-reads`. **refdata-only, zero Hasura.**
- **staging `hasura` (`.2`) — OUT of the F3 read-plane.** Verified (12h/10,520-query audit, #86): staging Hasura's **sole consumer is `edge-node-red`** (operator/reference reads: `v_operator_*`, `equipments`, `language_packs`, `piot_*` fns) — *not* OEE telemetry output. Those reads belong on `packiot.public`, which **survives as the Phase-1 operator substrate**, so staging Hasura is **NOT re-tracked to F3** (doing so would be wrong). It retires out-of-band (per `docs/audits/hasura-review-2026.md`), not via this collapse.
- **`reports` / `cq-logs-bigquery`**: `reports/` is LaTeX-only (no DB); `cq-logs-bigquery` reads only `cq_logs` (a `packiot.public` log table). **Neither reads `uns_metrics` or any F1-only OEE object** — the Step-5 `uns_metrics` drop caveat (§2.5) is therefore **already satisfied**.

**No consumer reads F2 (`shadow_go_port`).** Grep of `services/` confirms `shadow_go_port` appears only in the parallel-run plumbing (mirror-worker-go, shadow-mirror, oeecloud-worker, edge-transformer) and the `09-bake-flow-parity` dashboard — never a render/report consumer. **F2 is pure validation scaffolding and is safe to drop.**

### 2.5 Live DB census + F3-completeness proof (SELECT-only ground truth, 2026-07-20)

Verified on staging DB EC2 `i-064bb36d1c454d861` (`10.10.10.89`, container `timescaledb`), BEGIN READ ONLY:

- **F1 and F2 are the SAME database** (`packiot`), different schemas: `public` (F1: 215 tables / 123 views / 10 matviews) and `shadow_go_port` (F2: 40 tables / 7 views). **Only F3 is a separate DB** (`packiot_shadow`: 71 tables / 31 views + `customer_reports`/`customer_dashboards`). Comparator scaffolding also lives in `packiot`: schemas `parity_go`, `parity_legacy`, `shadow_diff`.
- **F1 is already half-retired.** Compute is pg_cron + cagg policies (not triggers): `cron.job #1 oee_compute_uns_metrics()` is the **only still-active** F1 compute; `#3 piot_proc_refresh_runtime()` is **already INACTIVE**. Evidence: `uns_equipment_current_shift.last_updated` max = **2026-07-08 (stale 12 days)** while raw `equipment_values` is fresh — F1's *derived* compute is effectively frozen; only raw ingestion still runs.
- **F3 produces the FULL correct model — criterion (A) proven live** (+ re-confirmed by QA §2.6). Fresh: `equipment_values` (1.35M) → own cagg cascade (jobs 1001–1017) → `equipment_runtime_shift` (8892)/`_1hour` (77080) → `uns_*` + `production_orders_runtime` (4242). **CPACK ent 3:** 62 equipments, 8556 runtime_shift. **Incoplast ent 4:** 4 equipments, 336 runtime_shift (F1 has ZERO ent4 runtime rows → F3 is *more* complete). **QA CORRECTION to the earlier "62 uns_current fresh" claim:** only `uns_equipment_current_metrics` is fresh to now; `uns_equipment_current_{shift,hour,day,job}` are **frozen 2026-07-03 (begin/end NULL) in BOTH F1 and F3** — a stack-wide dead deriver (pre-existing, flow-symmetric → NOT an F3 regression, but a hardening item: the refdata `live-equipment-{shift,day,job,month}` tiles read these). (`uns_site_current_*`=0 in *both* flows — not an F3 regression.)
- **F3 is fully self-contained** — 0 foreign servers, 0 foreign tables, 0 cross-flow views, 0 app functions calling `dblink`/referencing `packiot.public`/`shadow_go_port`. **Nothing on the F3 side must be resolved before dropping F1/F2.** This materially de-risks the drop.
- **Two extra retirement targets the earlier facets missed:**
  - **`packiot_refactor`** — an *unexpected 4th live database* (92 tables / 77 views, `refactor_sync`+`shadow_src` schemas). It's the naming-sweep + PowerBI-façade **design sandbox** (`scripts/reprovision-refactor-sandbox.sh`), but it is **live-fed** (equipment_values fresh, 1.0M rows) — consuming ingest + disk for no product purpose. Retire it too.
  - The comparator schemas `parity_go` / `parity_legacy` / `shadow_diff` — drop with the collapse.
- **The one data object F3 lacks: `uns_metrics`** (9.79M rows in F1). **Assessed NOT a fidelity gap** — the Go worker's `writeUnsMetrics` is commented out ("lost its only producer") and no product repo reads bare `uns_metrics`. **Caveat now SATISFIED:** verified `reports/` (LaTeX, no DB) and `cq-logs-bigquery` (reads only `cq_logs`) do not read `uns_metrics` — no reports/BigQuery consumer, so the Step-5 drop is pre-cleared.

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
| `edge-transformer` | Stop F1 emit leg (env); stop F2 leg (**code — see note**); emit `refactored` only | `SHADOW_EMIT_PRODUCTION=false`; keep `SHADOW_EMIT_REFACTORED=true`, `CALC_CUTOVER_REFACTORED=true`. ⚠️ **The F2 `"go"` leg is HARDCODED** (`main.go:1316`, `sourceTypes := []string{"go"}` — no flag). Suppressing it is the **one code change** the collapse needs: add a `SHADOW_EMIT_GO` gate (default `true`), so F2 becomes a reversible env flip like the others | Yes — once gated, flip envs back |
| `ingest-shim` (Incoplast) | Fan only the `refactored` source_type | `FANOUT_SOURCE_TYPES=refactored`. ⚠️ **Config-driven, but the stale default/comment says `legacy`** (assumes F1 survives) — for an **F3** collapse it MUST be `refactored`, or Incoplast collapses to F1, not F3 | Yes — env |
| `oeecloud-worker` | Stop F1/F2 lanes; keep refactored writer | Trim `internal/flows/flows.go` routing to `refactored`; `BAKE_COMPARATOR_ENABLED=false`; drop F1 Incoplast leg (`LEGACY_INGEST_ENABLED` → refactored-only); `CONSUME_LANES` 4→2 (triple-volume no longer arrives) | Yes — env + revert routing |
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

### 4.5 The operator write path — two end-states (why the mirror exists, and when it can go)

**Why `shadow-mirror` is needed at all.** It is *not* intrinsic cruft — it exists to bridge exactly one gap: **edge-api writes operator actions to `packiot.public` (F1's database), while F3 is a separate database (`packiot_shadow`).** Operator actions (PO start/stop, downtimes) enter through edge-api — the mature write path with the durable-write-queue + #32 staleness gate — and land in `packiot.public.user_logs`. Because F3 is a *different DB*, something must carry those writes across the DB boundary; `shadow-mirror` is that carrier (it tails `user_logs` and replays into `packiot_shadow`). **The mirror is the deliberate strangler-fig seam that lets the collapse leave the battle-tested operator write stack completely untouched while telemetry and reads move to F3.**

That gap admits **two end-states**, and this ADR now specifies both so the USER can choose *when* to take the second:

**Phase 1 — mirror-bridged (this ADR; the directive's explicit ask).**
Keep edge-api writing `packiot.public`; keep `shadow-mirror` bridging `user_logs → packiot_shadow`. F1's database survives in a **thin operator-ingress + audit role** (its OEE *compute* is already dead). Blast radius: **zero** to the operator write path. This is the safe, directive-compliant state and the endpoint of §6.

**Phase 2 — edge-api-direct (OPTIONAL, later, gated on Phase-1 baking clean).**
Re-point edge-api to write operator actions **directly to `packiot_shadow` (F3)**, then **delete `shadow-mirror`** and retire `packiot.public` as an operator store. This is the *true* single database — no bridge, no `user_logs` replay hop. It is ADR-0024's **step 3 (action cutover)** and ADR-0016's flip territory.

| | Phase 1 (mirror-bridged) | Phase 2 (edge-api-direct) |
|---|---|---|
| edge-api write target | `packiot.public` (F1 DB) — unchanged | `packiot_shadow` (F3 DB) |
| `shadow-mirror` | **kept** (bridges F1→F3) | **deleted** |
| `packiot.public` role | operator ingress + `user_logs` audit | retired as operator store |
| Blast radius | none to write path | rewires the load-bearing durable write path |
| ADR-0024 step | step 2 (intermediate safe state) | step 3 (action cutover) |
| Reversibility | flag/routing reverts | requires edge-api config + verified user_logs cutover; heavier |
| When | **now** (post USER sign-off) | **only after** Phase 1 bakes ≥1 shift cycle clean, as a separate decision |

**Recommendation:** ship Phase 1 now (matches the directive, surgical). Treat Phase 2 as a **named, deferred follow-up** — coherent and desirable as the eventual end-state, but a bigger change to the one component we most want to leave alone during a data-plane migration. Do **not** couple Phase 2 to this collapse; it earns its own gate once F3-sole has proven itself. The §6 sequence ends at Phase 1; Phase 2 is listed under 🔒GATED.

**Prerequisite that Phase 2 must satisfy before it can be taken:** the durable-write-queue + #32 staleness gate semantics (today applied at the `packiot.public` write) must be re-proven against the `packiot_shadow` write, and the `user_logs` audit history (currently F1's) must have a decided home — either replicated into F3 or kept in F1 as an append-only audit even after the operational cutover.

---

## 5. Risks & reversibility

### 5.1 THE load-bearing risk — the read plane is still bound to F1

`refdata-api` (and behind it: operator PWA, and via Hasura, front4) reads **`packiot.public` (F1)**. If F1's telemetry compute stops **before** the read plane is re-pointed to `packiot_shadow` (F3), every OEE read goes **stale/blank** — a customer-visible outage on staging demo surfaces. Neither ADR-0026 nor ADR-0027 re-points refdata-api; **this ADR must, and gates on it.**

Complication — **REFRAMED by the live parity harness (PR #536), and bigger than first written.** The divergence is **ABSENCE, not RENAME**: every object that *exists* in F3 keeps its exact F1 name (the `ca_*`/rename-map is an *unapplied proposal*), so **no dataset needs SQL rewriting** — but **38 of the read objects don't exist in `packiot_shadow` at all.** F3 is a **telemetry-compute DB, not an analytics-read DB**: it has `equipment_values → runtime rollups → uns_*` (the 23 "live/current" datasets are SERVABLE_BOTH and REF parity is 6/6 byte-exact), but it lacks the entire **`h_piot_*` analytics function library** (OEE-score, overview-*, mission-control, downtimes-summary, …) plus config/report relations (`oee_targets`, `scrap_targets`, `v_report_downtimes`, `dashboard_config`, `user_roles`, `v_menu_per_user_role`), and its `users` table is empty for ent 3/4. So Step-1's read re-point is a **schema-replication + seeding** effort, not SQL adaptation.

**Partition RESOLVED (analysis complete):** the 38 = **PORT 32** (26 analytics `h_piot_*` fns + 6 config relations) · **RETIRE 6** (5 dead fns never imported by front4/operator + `v_report_downtimes`, staging) · **SEED 1** (`users` rows ent 3/4). The "legacy-fork-only retire class" turned out **empty** — every analytics fn a retiring Overview fork calls is *also* fed by a composition hook or a **standalone live page** (`/OEE`, `/downtimes`, `/mission-control`, …) that ADR-0029 does NOT retire. **Recursive-gap CLEARED:** F3 already maintains the area/site rollups the OEE-score fns read (oeecloud-worker `rollup/entity_grains.go`, schema-parameterized to `packiot_shadow`) → **zero function-body rewrites**; ports are mechanical replays of `edge-node-red/db/19-hasura-full-parity.sql` (+ `20`).

**Key discovery — the 26 analytics fns are NOT on the *minimal* collapse's critical path:** the operator surface already renders off F3 (its routes are provisioned), and front4's analytics currently read **prod Hasura Cloud** (`gqlpiot.packiot.com`), not refdata — so a refdata→F3 re-point alone wouldn't touch front4 analytics. The 26 fns are prerequisites for the **front4→refdata analytics cutover (Phase G)**.

**USER DECISION (2026-07-20): option (b) — "everything off F3" in one shot.** The collapse's scope now INCLUDES the Phase-G front4-analytics cutover, not just the minimal operator+Grafana re-point. Therefore Step 1 now has two build halves, both in flight: **(i)** port the 32 objects (26 analytics + 6 config) + seed into `packiot_shadow` via `edge-node-red/db/29-f3-analytics-port.sql`; **(ii)** flip front4's analytics off prod-Hasura onto refdata→F3 (transport-layer: GraphQL→REST, shape-parity verified, built behind `REFDATA_ENABLED` default-off until the customer-facing flip). The flip gate is the **full-contract** parity harness (all 38 SERVABLE_BOTH) **plus** front4 shape-parity vs the Hasura baseline. The 5 RETIRE fns + `v_report_downtimes` are unbound from `datasets.go` (staging).

**Concrete mechanics (live-verified):** refdata reaches F1 through **pgbouncer**, whose `[databases]` maps **only** `packiot = host=10.10.10.89:5432` — there is **no `packiot_shadow` pool at all**. So Step 1 is not just `DB_NAME=packiot_shadow` on refdata; it needs a **new pgbouncer pool** (`packiot_shadow = host=… dbname=packiot_shadow`) first. **The read-plane surface is exactly three things: refdata-api + the pgbouncer pool + Grafana** — staging Hasura is NOT in it (see §2.4: edge-node-red-only, stays on `packiot.public`), and front4/operator inherit the refdata re-point. (PowerBI/SAP surface is **prod-only** — empty on staging — so no staging action.)

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

**G0b — prerequisite (ADR-0025, #51):** confirm the **`mirror-worker-go` reconciler shadow-fan-out to F3 is live and healthy** *before* Step 4 stops F1 telemetry. Today F1 owned the prod-authoritative PO/event closes; F3-sole inherits them only through the reconciler's F3 fan (the finisher's live scope was F1-only, #480 — the F3 fan is #51). If F3 is not receiving those closes, stopping F1 leaves F3's PO/event lifecycle un-reconciled. *Verify:* reconciler F3-target metrics advancing (closes applied to `packiot_shadow`), no `recalc_needed` backlog growth on ent 3/4. **This is a hard gate on Step 4, not just Step 1.**

**Step 1 — Re-point the READ/RENDER plane to F3 (the long pole; do FIRST). Satisfies acceptance criterion (C).**
- **Add a pgbouncer pool** `packiot_shadow = host=10.10.10.89 … dbname=packiot_shadow` (today pgbouncer maps only `packiot`/F1 — there is no F3 pool). This is the literal precondition, not `DB_NAME` alone.
- Port each `refdata-api` Surface-1 dataset SQL to `packiot_shadow` objects; run behind a `DB_NAME`/flow-routing switch so it can serve F1 or F3.
- **Do NOT re-track staging Hasura** — it's edge-node-red-only against the retained operator substrate (§2.4), not the OEE read plane. No Hasura work in Step 1.
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

**Step 4 — Cut F3 telemetry over to the direct-PLC path; stop F1 telemetry emit + compute.**
- `edge-transformer`: `SHADOW_EMIT_PRODUCTION=false` (stop F1 leg); keep `SHADOW_EMIT_REFACTORED=true` + `CALC_CUTOVER_REFACTORED=true`.
- `oeecloud-worker`: refactored-only routing; Incoplast leg refactored-only (was `LEGACY_INGEST` → F1/F3); `CONSUME_LANES` 4→2.
- `ingest-shim`: `FANOUT_SOURCE_TYPES=refactored` (⚠️ stale default is `legacy`/F1 — must be set explicitly or Incoplast lands in F1).
- `mirror-worker-go`: `SHADOW_VALUE_FANOUT=false` (or F3-only per §4.2 decision).
- **Stop F1/F2 compute (reversible via `alter_job(…, scheduled => true)`):** disable pg_cron `#1 oee_compute_uns_metrics` (F1's last active compute; `#3` already off); unschedule F1 cagg jobs **1000–1014** and F2 jobs **1015–1021**. (F3's own cascade jobs 1001–1017 stay.)
- **Do NOT run this before Step 1's gate (and G0b, #51 reconciler) is green** — F1 telemetry going stale with reads still on F1 = outage; F3 without the reconciler fan-out loses prod-authoritative PO/event closes.
- *Verify:* **criterion (A)** — F3 `equipment_values → equipment_runtime_shift/_1hour/_1day → uns_* views` correct + fresh (< 2s) from the PLC path for ent 3 & 4; F1 telemetry tables stop advancing (expected); read plane (now on F3) healthy. **criterion (B)** — drive a PO start/stop + downtime via the operator queue and confirm it lands in `packiot_shadow` via shadow-mirror.
- *Reversible:* restore `SHADOW_EMIT_PRODUCTION=true` + fan-out, redeploy — F1 resumes.

**Step 5 — Freeze, then drop dead schemas/DBs (irreversible — last, after EBS snapshot).**
Order (no-consumer first; F1 is NOT dropped here — it stays as the Phase-1 operator substrate, and drops only in the optional Phase 2 / §4.5):
1. Revoke writes on `shadow_go_port`, leave readable ≥7 days, then `DROP SCHEMA shadow_go_port CASCADE` (F2 — pure validation shadow, zero product consumer).
2. `DROP SCHEMA parity_go / parity_legacy / shadow_diff CASCADE` (comparator scaffolding retires with the collapse).
3. Stop the live feed to **`packiot_refactor`** (the naming-sweep/PowerBI-façade sandbox DB), then `DROP DATABASE packiot_refactor` — it consumes ingest+disk for no product purpose.
4. **`uns_metrics` audit gate:** before any thought of dropping F1's `uns_metrics` (9.79M rows), confirm the `reports`/BigQuery pipeline does not read it. (F1 itself stays frozen-but-alive in Phase 1 regardless.)
- *Verify:* no service references the dropped objects (grep clean); EBS snapshot recorded before each `DROP`.
- *Reversible:* only via snapshot restore — hence the freeze window.

**Preserved throughout:** `shadow-mirror` (operator actions → F3), `mirror-worker-go` operator-replay + reconciler (§4.2), `operator-adapter`, edge-api → `user_logs`. **The operator write path never changes.**

🔒**GATED / OUT OF SCOPE (later program):** **Phase 2 — edge-api-direct (§4.5):** re-point edge-api to write operator actions directly to `packiot_shadow` and delete `shadow-mirror` (ADR-0024 step 3 action cutover) — the optional true-single-DB end-state, gated on Phase 1 baking clean and its own prerequisites (§4.5). Also gated: promoting `packiot_shadow` to the operational DB (the true ADR-0016 flip), Hasura retirement + front4 re-point (ADR-0026/0028/0029), and any prod cutover (ADR-0017 endgame).

---

## 7. Consumers — standard-stack re-point census

No exotic consumers: the render/read surface is the standard stack. Enumerate each, the flow it reads today, and its re-point to F3 (`packiot_shadow`). This whole set is **Step 1** and satisfies acceptance criterion **(C)**.

| Consumer | Reads today | Re-point action |
|----------|-------------|-----------------|
| **Grafana** (datasource + boards) | F1 via `packiot-postgres` datasource | **DONE (PR #537):** `$datasource` template var (default F1, switchable to F3) on 9 boards; 6 OEE boards F3-clean. `12-replay-and-fanout` + `13-database-reach` left on F1/F2 (retire with the collapse). **Operator-log panels (`user_logs`) STAY on F1** — that's the retained operator substrate, not a gap (Phase-1 correct). One `uns_metrics` panel → repoint to `uns_equipment_current_metrics` |
| **refdata-api** | F1 `packiot.public` | **Re-point `DB_NAME`/routing to `packiot_shadow`; port each Surface-1 dataset SQL to F3's objects.** The hard-pole item |
| **front4** (AWS Amplify) | F1 via refdata-api / Hasura | Inherits refdata re-point; verify Amplify build renders off F3 (criterion C) |
| **operator PWA** (`/v1/*` cache) | F1 via refdata-api | Inherits refdata re-point; response shapes must stay byte-stable |
| **staging Hasura** (`.2`) | F1 — but **edge-node-red-only** (operator/reference reads), NOT OEE | **No action** — stays on `packiot.public` (operator substrate). NOT re-tracked to F3. Retires out-of-band (audit Option D) |
| **reports / cq-logs-bigquery** | reports=no DB (LaTeX); cq-logs reads `cq_logs` only | **No action** — neither reads `uns_metrics`/F1-only OEE; Step-5 drop pre-cleared |
| **F2 `shadow_go_port` readers** | none | Safe to drop (§2.4) |

---

## 8. Decision

Adopt the collapse **as the staging execution of ADR-0024's intermediate "data-direct, actions-mirrored" state plus the F2/comparator teardown**, sequenced per §6, **gated on Step 1 (read/render-plane re-point to F3)**, **G0 (#32 gate baked)**, and **G0b (#51 reconciler F3 fan-out live)**. The success bar is the three staging-fidelity criteria of §1.1: **(A)** F3 OEE data correct, **(B)** operator writes land in F3 via shadow-mirror, **(C)** front4 (Amplify) + Grafana render off F3. Ingestion is already uniform — every PLC (real or `plc-sim`) funnels through `edge-transformer`/`ingest-shim` into one worker → F3 (§1.2); there is no CPACK-tee gap. Beyond A/B/C, simplify aggressively — F1 legacy compute, F2 `shadow_go_port`, the comparators/reconcilers, and parallel-run replay all go.

The operator write path is delivered in **two end-states (§4.5): Phase 1 (mirror-bridged) now** — keep edge-api→`user_logs`→`shadow-mirror`→F3, zero blast radius, matches the directive; **Phase 2 (edge-api-direct) later and optional** — re-point edge-api straight at `packiot_shadow` and delete the mirror, the true single DB, gated on Phase 1 baking clean. This ADR's §6 sequence ends at Phase 1. Defer the true flip, Phase 2 action cutover, and all prod change to the existing endgame ADRs. **Prod is untouched.** Execute only after USER review.
