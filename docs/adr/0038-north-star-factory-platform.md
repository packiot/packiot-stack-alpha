# ADR-0038 — North-Star target architecture: the full-fledged factory platform

**Status:** Proposed · **Date:** 2026-07-22 · **Scope:** program-wide (all repos) · **Decision owner:** chief architect (pending USER sign-off) · **Altitude:** this ADR sits **above** the others. It is the *why* and the *roadmap*; the numbered ADRs below it are the *how* for each pillar. Where a lower ADR and this one appear to conflict, the lower ADR wins on mechanism and this one wins on direction.

**Governs (pillar-level decisions this north-star frames):**
- [ADR-0026](0026-api-layer-consolidation.md) — API-layer consolidation (edge-api writes / refdata-api reads, retire Hasura + primary-api + back4-api).
- [ADR-0029](0029-front4-dashboard-composition-and-metric-layer.md) — front4 dashboard composition engine + calc/metric/graph layer.
- [ADR-0032](0032-collapse-to-single-flow-f3.md) — collapse the staging three-flow parallel-run to the refactored flow (F3).
- [ADR-0034](0034-adopt-cognito-amplify-auth.md) — adopt AWS Cognito (via Amplify Auth) as the identity provider, replacing Firebase *(concurrent — `feat/adr-0034-cognito-amplify`)*.
- ADR-0035 — Redis cache layer for the read plane *(concurrent — `feat/task-redis-cache-layer`; ADR doc not yet written)*.
- [ADR-0036](0036-data-architecture-medallion.md) — medallion data architecture (streaming bronze/silver/gold on Timescale + immutable historian + offline lakehouse) *(concurrent — `feat/adr-0036-0037-data-arch-oee-correctness`)*.
- [ADR-0037](0037-oee-correctness-remediation.md) — OEE-correctness remediation (findings a–h; e.g. P3-2 missing-at-all-levels → data-quality alarm, P3-4 zero/NULL `ideal_speed`) *(concurrent — same branch)*.

> **Numbering & authoring note.** ADR-0034, ADR-0036, and ADR-0037 already exist as docs on their concurrent feature branches (not yet merged to `staging`); ADR-0035 (Redis) is decided as a task (`feat/task-redis-cache-layer`) but its standalone ADR doc is not yet written. 0038 is deliberately clear of all four. This doc cross-references them by their canonical filenames so the links resolve once those PRs land; if a number shifts on merge, fix the link, not the intent.

---

## 1. Vision statement

**Packiot is becoming a full-fledged factory system: a mature ISA-95 Level-3 / MESA-11 MES + OEE platform, delivered as multi-tenant SaaS for manufacturing.**

"Full-fledged" is a specific, testable claim, not a slogan. It means the platform covers the **Manufacturing Operations Management (MOM)** functional set an ISA-95 Level-3 system is expected to own — connectivity down to the PLC, a trustworthy historian, correct OEE, production-order and loss management, quality, traceability, scheduling, KPI/targets, visualization, alerting, and reporting — **each as a first-class, config-driven, multi-tenant capability**, not a per-customer fork. Today Packiot is a very strong *OEE/telemetry* product with several MES pillars either maturing or missing. This ADR names the target, rates honestly where we are against it, states the principles the mature platform must obey, and sequences the work: **finish the foundation, then close the missing pillars in a defensible order.**

The bar we are holding ourselves to: a manufacturing customer should be onboardable from a declarative config + seed (no code fork), should get correct OEE they can trust for decisions, should manage the full production/quality/downtime loop, and should be isolated from every other tenant by construction — on **one cloud, one identity, one data spine**.

---

## 2. Why a north-star ADR now

The program has shipped a large body of consolidation work (ADR-0026 through ADR-0037) — API collapse, three-flow → F3, front4 de-forking, auth unification, data-architecture and OEE-correctness redesigns. These are individually sound but were each argued locally. Two risks follow from that:

1. **No shared definition of "done."** Without a stated target it is impossible to say whether the platform is 60% or 95% of a real MES, or which of a dozen candidate efforts matters most next.
2. **Foundation vs. features confusion.** Some pending work *completes the substrate every future pillar stands on* (F3 collapse, medallion, OEE-correctness, single-cloud/auth); other work *adds new pillars* (quality/SPC, traceability, scheduling, andon). Doing them in the wrong order builds pillars on sand.

This ADR resolves both: it fixes the target (the MES pillar set), publishes an evidence-cited maturity map, and gives an order-of-operations — **foundation before pillars** — with the rationale for each step.

---

## 3. Pillar framework — the MES functional map

Fifteen pillars, drawn from the ISA-95 Level-3 activity model and the MESA-11 functional set, specialized to an OEE-first manufacturing SaaS:

| # | Pillar | What it owns |
|---|---|---|
| P1 | **Connectivity / Edge** | Reading the factory floor: SparkPlug B, OPC-UA, S7, Modbus; per-client config; PLC write-back |
| P2 | **Historian / Data-foundation** | Time-series capture + the rollup/aggregate spine (raw → 1min → 1hour → shift/day…) |
| P3 | **OEE / Performance** | Availability × Performance × Quality, per grain, correct and trustworthy |
| P4 | **Production / Order-mgmt** | PO lifecycle (available/running/finished/paused), setup, concurrent-line runs |
| P5 | **Downtime / Loss-mgmt** | Event capture, reason taxonomy, justification/split, the six-big-losses model |
| P6 | **Quality / SPC** | Defect classification, first-pass yield, control charts, in-tolerance monitoring |
| P7 | **Traceability / Genealogy** | Lot/batch/serial genealogy, material consumption, as-built record |
| P8 | **Scheduling / Sequencing** | Finite-capacity scheduling, sequencing/dispatch, planned vs. actual |
| P9 | **Targets / KPI** | Ideal speed, shift/period targets, proportional "where you should be now" |
| P10 | **Dashboards / Viz** | Tenant-composed operational dashboards + ops/observability boards |
| P11 | **Alerting / Andon** | OEE-threshold alarms, andon signalling, data-quality alarms |
| P12 | **Reporting / Analytics / ML** | Batch reports, offline analytics/lakehouse, predictive/ML |
| P13 | **Multi-tenancy / Security** | Tenant isolation for reads and writes; identity; per-env isolation |
| P14 | **Onboarding / Config** | Seed-first tenant provisioning; config-driven not fork-driven |
| P15 | **Observability / Ops** | Metrics/logs/traces, RED, deploy/runtime health of the platform itself |

---

## 4. Maturity map — honest, evidence-cited

Ratings: **STRONG** (production-grade, tested) · **MATURING** (real, but a known redesign/hardening is in flight) · **THIN** (partial/ad-hoc; a fragment exists) · **MISSING** (no implementation).

| Pillar | Rating | One-line justification |
|---|---|---|
| P1 Connectivity/Edge | **STRONG** | 4 protocols really implemented in Go + config-driven client YAML |
| P2 Historian/Data-foundation | **MATURING** | Full cagg spine exists; medallion redesign (0036) + Go-port mid-flight |
| P3 OEE/Performance | **MATURING** | OEE computed and parity-checked; 3 correctness findings → 0037 |
| P4 Production/Order-mgmt | **STRONG** *(→ MATURING at edges)* | Full PO lifecycle usecases; guards ad-hoc not a formal state machine |
| P5 Downtime/Loss-mgmt | **STRONG** *(→ MATURING at edges)* | Reason taxonomy + justify/split flow; taxonomy is static seed, no 6-losses model |
| P6 Quality/SPC | **THIN** | Scrap counts only; no defect classes / FPY / control charts |
| P7 Traceability/Genealogy | **MISSING** | `samples`/`scanned_boxes` counts; no lot/batch/serial genealogy |
| P8 Scheduling/Sequencing | **MISSING** | PO *tracking* only; no finite scheduler / sequencing / dispatch |
| P9 Targets/KPI | **MATURING** | Targets emitted + proportional-target ruling (0029 D5); tp=1/2 backend fix pending |
| P10 Dashboards/Viz | **STRONG** | Typed composition engine + registry + golden-master parity; provisioned Grafana |
| P11 Alerting/Andon | **THIN** | Infra Alertmanager only; no OEE-threshold / andon / data-quality business alarms |
| P12 Reporting/Analytics/ML | **MATURING** *(→ THIN on ML)* | Per-customer report writers + BigQuery→S3 path; predictive/ML absent |
| P13 Multi-tenancy/Security | **MATURING** *(split)* | Read plane STRONG (server-derived tenant); write plane THIN (shared api_key) |
| P14 Onboarding/Config | **MATURING** | Hierarchical CRUD + client YAML + seeds; three loosely-coupled mechanisms |
| P15 Observability/Ops | **STRONG** | Prometheus/Grafana/Loki/Tempo/Alertmanager + RED + blackbox all deployed |

### Evidence per pillar

**P1 Connectivity/Edge — STRONG.** All four industrial protocols are implemented with real pure-Go clients, tests, and parity harnesses in `services/edge-transformer/internal/`: SparkPlug B (`sparkplug/decoder.go`, `aliastable.go`, generated `sparkplug_b.pb.go`, `parity_test.go` against the JS `sparkplug-payload` lib), OPC-UA (`opcua/client.go` wrapping `gopcua/opcua`), S7 (`s7/client.go` wrapping `robinson/gos7`, plus a pure-Go soft-PLC `s7/softplc/softplc.go` for hardware-free E2E), Modbus TCP (`modbus/client.go` wrapping `goburrow/modbus`). A downstream PLC command/write channel exists (`internal/command/`). Config-driven-not-fork: `docs/clients/_schema.yaml` (v1.0 client schema, single source of truth per customer, replaces `flow.set()` blobs + per-customer GitHub Secrets + 37+ hand-dragged OPC-UA nodes), with live `docs/clients/cpack.yaml` + `incoplast.yaml` loaded by `internal/clientconfig/loader.go`. *Points off perfection:* Ethernet/IP is enum-only (`_schema.yaml:33`, no package); OPC-UA security defaults to `None` (certs deferred); the runtime loader honors only a config skeleton today (Phase-2 port in flight, honestly tracked in `incoplast.yaml`'s gap checklist).

**P2 Historian/Data-foundation — MATURING.** The rollup spine is real: raw `equipment_values` → 1min/1hour continuous aggregates → `equipment_runtime_shift/_1hour/_1day/_1week/_1month`, and the full UNS matrix (`edge-node-red/db/11-uns-tables.sql`, 577 lines — `uns_{equipment,area,site}_current_{hour,day,week,month,shift}` + `uns_equipment_current_metrics`). Compute is mid-migration from Postgres/Node-RED functions (`edge-node-red/db/14-oee-uns-compute.sql`) into the Go worker (`services/oeecloud-worker/internal/uns/`, `internal/writers/uns_current_metrics.go`), guarded by a shadow-schema comparator (`mirror-worker-go/internal/comparator/`) and `parity-check.sql`. Not STRONG for two concrete reasons: authoritative compute still substantially lives in the DB (Node-RED/pg functions, mid-port), and the *raw tier is not yet a true historian* — `create_hypertable('equipment_values', …)` carries **no retention or compression policy** (grep finds none in the repo) and the writer overwrites in place (`ON CONFLICT (ts_value, id_equipment) DO UPDATE`, `oeecloud-worker/internal/writers/equipment_values.go`), so sub-second collisions silently drop samples and Bronze is effectively ephemeral. The **medallion redesign (ADR-0036)** — an immutable/retained Bronze, an explicit Silver invariant layer, caggs as the Silver→Gold streaming transform, + an offline lakehouse — is written precisely to close this (ADR-0036 §3).

**P3 OEE/Performance — MATURING.** OEE math (Availability × Performance × Quality) exists both as the DB engine (`edge-node-red/db/20-oee-engine-parity.sql`) and the Go rollup port (`services/oeecloud-worker/internal/rollup/`: `compute.go`, `shift.go`, `hour.go`, `day.go`, `recalc.go`, with a dirty-flag/`recalc_needed` re-processing mechanism). It is byte-parity-checked against the legacy engine (the F1/F2/F3 comparison discipline in ADR-0032). It is MATURING, not STRONG, because **ADR-0037** exists precisely to remediate correctness findings surfaced by domain review (the two-writer line double-count that produced `oee>1.0`, and the `proportional_target` tp-awareness gap resolved in ADR-0029 D5 / the `0029-decisions-resolved` ruling). Correct-by-parity is not the same as correct-by-invariant; ADR-0037 closes that.

**P4 Production/Order-mgmt — STRONG (→ MATURING at the edges).** Full lifecycle usecases in `edge-api/src/usecases/production-orders/` (`create`, `create-and-start`, `start`, `stop`, `setup`, `change-status`, `change-time`, `replace`, `current`), an explicit status enum (`enums/production-orders/status.ts`: available=1/running=2/finished=3/paused=4), and concurrent-PO-across-lines handling (ADR-0023). Edge is that transition guards are ad-hoc single-method checks throwing generic errors, not a formal state machine.

**P5 Downtime/Loss-mgmt — STRONG (→ MATURING at the edges).** A flagged Category→Subcategory reason taxonomy seeded per equipment (`edge-node-red/db/13-downtime-reasons-seed.sql`: EQUIP_FAIL/PROC_ISSUE/CHANGEOVER/IDLE/PLANNED with `planned_downtime`/`change_over`/`idle` flags, machine-attribution for line stops), plus a justify/split/manual-event usecase set (`edge-api/src/usecases/downtimes/`) with status-gated justification. Below STRONG-plus because the taxonomy is a static SQL seed (not tenant-editable through CRUD) and there is no explicit **six-big-losses** loss model tying downtime → the OEE loss waterfall.

**P6 Quality/SPC — THIN.** Scrap/reject *quantity* is first-class — `scrap_incr`/`scrap_val` columns across the whole `agg_*` rollup chain, a `scrap_targets` table, the `v_13_overview_partial_scrap_rate` view, and an edge `Defective = Consumed − Processed` counter (`edge-transformer/internal/transforms/calc_production_counters/line_aggregation.go`) — and it feeds the Quality factor of OEE; `samples`/`scanned_boxes` capture box scans. But it is *counts only*: grepping all six repos for `control chart`, `first_pass_yield`, `defect_class`, `nonconformance`, `Cp`/`Cpk` returns **no matches**. No defect classification, no first-pass-yield, no control charts (X̄-R / p / np), no in-tolerance/Cp-Cpk monitoring.

**P7 Traceability/Genealogy — MISSING.** `samples` and `scanned_boxes` are quantity/scan counters (`id_box`, `increment`, `box_order_number`), not genealogy. Grepping all six repos for `lot`, `batch`, `genealogy`, `serial`, `material_consumption`, `as-built` yields **only `knex_migrations.batch`** (a migration sequence integer — irrelevant). No lot/batch/serial model, no material-consumption / as-built record, no upstream/downstream genealogy link.

**P8 Scheduling/Sequencing — MISSING.** PO *tracking* is rich (`production_orders`, `production_orders_runtime`, `pocontrol/decide.go`, `production_targets`/`oee_targets`), but grepping for `finite scheduling`/`APS`/`gantt`/`planned_order` returns **no matches**; every `dispatch`/`sequenc*` hit is message-bus infrastructure, not production planning. POs are executed as received — there is **no finite-capacity scheduler, no sequencing/dispatch engine, no planned-vs-actual schedule, no APS.**

**P9 Targets/KPI — MATURING.** Targets (ideal speed 30701, shift/period targets, `proportional_target`) are emitted and consumed; the `0029-decisions-resolved` ruling establishes tp-aware proportional targets (tp=3 lines prorate correctly server-side; tp=1/2 need the backend fix). MATURING because the machine/sector backend proration fix (P3-backend-correctness follow-up) is not yet shipped.

**P10 Dashboards/Viz — STRONG.** The front4 composition engine (`front4/src/lib/dashboard/`) is a typed, never-throwing config schema (`schema.ts`, 353 lines) + widget registry (`registry.jsx`) + shared-poll hook layer (`hooks/`) + per-tenant config documents (`configs/*.config.js`) with golden-master parity tests — deliberately replacing 8 hand-forked `Overview*` pages (ADR-0029). Separately, ~13 provisioned ops dashboards in `grafana/provisioning/dashboards/` (+ a `dashboards-v2/` set).

**P11 Alerting/Andon — THIN.** *Infrastructure/pipeline* alerting is genuinely solid: `monitoring/prometheus/rules.yml` carries 20+ rules including `IngestSilent`, `EngineStalled`, `WritePathDry`, `MQTTDisconnected`, `SparkplugSeqGapStream`, `MirrorOeeDivergence`, `POStalenessGateRejectingWrites`, routed through `alertmanager`; `back4-api/src/cronJobs/devicesMonitoring/` sends escalating device-offline emails. But the *business* layer is absent: grepping all six repos for `andon` returns **zero matches**; there is no OEE-threshold alarm, no andon signalling, no operator-facing alert UI in front4, and — as ADR-0037 itself documents (findings P3-2 "missing-at-all-levels → data-quality alarm, not silent 0", P3-4 "zero/NULL `ideal_speed` … emit a data-quality alarm") — **metric-level data-quality alarms are TODOs, not yet built.** Andon is a core MES shop-floor expectation and is effectively absent at the business layer.

**P12 Reporting/Analytics/ML — MATURING (→ THIN on ML).** Per-customer report writers exist (speed33/shift06/sync06/sap13/boxes, ADR-0017's `reports-worker`), and the offline export path is moving BigQuery → S3/Athena (ADR-0026 §6, folded into ADR-0036's gold-offline tier). Predictive/ML is absent — a green-field want, not a regression.

**P13 Multi-tenancy/Security — MATURING (split posture).** **Read plane is STRONG:** `services/refdata-api/cmd/refdata-api/auth_firebase.go` verifies a per-user RS256 JWT (no secret in the relying party), resolves `uid → id_enterprise` server-side (`SELECT ... FROM users WHERE id_user_firebase=$1 AND active`), injects `customer_id` as `$1` in every query, and fails closed (unknown uid → 401, never a default tenant). A cross-tenant read is unrepresentable. **Write plane is THIN:** edge-api still authorizes by a **shared per-enterprise `api_key` matched against a client-supplied `idEnterprise` query param** (`edge-api/src/middleware/auth.middleware.ts` + `data/DAO/auth-middleware/auth-apikey-dao.ts`) — the caller *names* the tenant, the opposite of the read model. The write-side SQL fence is **designed but not shipped** (ADR-0033 §5, carried verbatim into ADR-0034 Cognito §5). Net: MATURING, gated on ADR-0034 execution.

**P14 Onboarding/Config — MATURING.** Complete hierarchical CRUD (`edge-api/src/usecases/`: enterprises → sites → areas → equipments → shifts/shift-hours → packml-register/packml-config), a config-driven client YAML (`docs/clients/`, schema-versioned, replacing thousands of LOC of Node-RED), and SQL seeds (downtime reasons). Seed-first is the resolved onboarding direction (`0029-decisions-resolved` Q1/Q2). MATURING, not STRONG, because it spans three loosely-coupled mechanisms (YAML + edge-api CRUD + raw SQL seeds) rather than one orchestrated provisioning flow.

**P15 Observability/Ops — STRONG.** `compose.staging.yml` runs the full stack: `prometheus`, `grafana`, `loki`/`promtail`, `tempo` (traces), `alertmanager`, `blackbox-exporter`, `cadvisor`, `node-exporter`, `postgres-exporter` — with RED-method service dashboards. This is genuinely production-grade.

> **Evidence-notes.** The P6/P7/P8/P11 "MISSING/THIN" ratings assert a *negative* (a capability is absent). These are confirmed by a cross-repo grep survey over `packiot-stack-alpha`, `edge-api`, `edge-node-red`, `front4`, `back4-api`, `primary-api` (excluding `node_modules`, `.wt-*` worktrees, and vendored library code): no `control_chart`/`first_pass_yield`/`defect_class`, no `lot`/`genealogy`/`serial`/`material_consumption` (only `knex_migrations.batch`), no `finite scheduling`/`APS`/`gantt`/`planned_order`, no `andon`. See §Appendix for the exact search terms.

---

## 5. Architectural principles for the mature platform

These are the invariants every pillar-level ADR must honor. They are what makes fifteen capabilities *one platform* rather than fifteen products.

1. **One data spine.** All telemetry converges on a single compute flow (F3, ADR-0032) shaped as a **medallion** (bronze raw → silver conformed → gold serving, ADR-0036). No pillar invents a parallel store; every pillar reads/writes a defined layer of the spine. *(Kills the three-flow sprawl and the DB-vs-Go double-brain.)*

2. **Config-driven, not fork-per-client.** A new tenant is a **config document + seed**, never a code fork. On the edge that is the client YAML (`docs/clients/`); in the UI that is the dashboard composition config (ADR-0029); in onboarding that is CS-Admin CRUD + seeds. The 8-fork `Overview*` regression is the anti-pattern this principle exists to prevent.

3. **Streaming-medallion for live, lakehouse for offline.** Operational/live metrics flow through the streaming medallion (sub-minute, TimescaleDB caggs); heavy historical analytics + ML live in the offline lakehouse (S3 + Athena/Glue gold tier, ADR-0036). Two read shapes, one lineage — never one query engine forced to serve both.

4. **Trustworthy metrics by invariant, not by parity.** A metric is correct when it satisfies stated invariants (single-writer-per-row, `0 ≤ oee ≤ 1`, targets prorated to elapsed time), not merely when it byte-matches the legacy engine. Parity got us determinism; ADR-0037 gets us *correctness*. Every metric ships with its invariant.

5. **Tenant isolation everywhere — reads and writes.** The read model (JWT → server-derived `id_enterprise` → tenant-bound `$1`, `auth_firebase.go`) is the template; the write plane must adopt the identical shape (the ADR-0033/0034 write-side SQL fence). The client never names its own tenant. This is the single most important security invariant — one misconfiguration leaks one factory to another.

6. **CQRS read/write split.** Writes (few, business-logic-heavy, gated, audited) go through edge-api; reads (many, flexible, horizontally scalable, cacheable via Redis/ADR-0035) go through refdata-api (ADR-0026). One service each keeps both healthy and keeps tenant-isolation to two auditable authorities, not many.

7. **Edge/cloud split with a durable boundary.** The edge (`edge-transformer` + edge-node-red) owns protocol I/O, store-and-forward, and PLC write-back; the cloud owns compute, history, and serving. The boundary is a durable queue, not a synchronous call — a factory survives a cloud outage (ADR-0011).

8. **Seed-first onboarding.** New tenants come up from declarative baselines (config + SQL seed + CS-Admin CRUD) before any operation; self-service authoring UIs are additive later (the `user_screen_config` override seam, `0029-decisions-resolved` Q1/Q2). Fastest correct path to a live tenant.

9. **Single cloud (AWS).** The platform runs on **one cloud: one IAM, one billing, no cross-cloud seams, no service-account keys shuttling between providers.** Every remaining Google Cloud dependency is being exited (see §6 Milestone A0): Firebase → Cognito (ADR-0034), PubSub → RabbitMQ + GCP-Compute oeecloud-node-red → AWS `oeecloud-worker` (already done in the new stack), BigQuery → S3 + Athena + Glue (ADR-0036 gold-offline tier). One-cloud is not incidental — it removes an entire class of cross-cloud identity/latency/billing failure modes and is itself a maturity step for the full-fledged-factory vision.

---

## 6. Sequenced roadmap — foundation before pillars

The order is deliberate and defensible: **you cannot build correct Quality/SPC, Traceability, Scheduling, or Andon on top of an untrustworthy, multi-flow, dual-cloud, weakly-fenced substrate.** Phase A hardens the ground; Phase B builds the missing pillars on it.

### Phase A — finish the foundation

| Step | Work | ADR | State | Why it's foundation |
|---|---|---|---|---|
| A0 | **GCP exit → single cloud (AWS)** | 0034 + 0036 | near-done | Removes cross-cloud seams before new pillars assume one IAM. Firebase→Cognito (in progress), PubSub→RabbitMQ + oeecloud-node-red→`oeecloud-worker` (**done**), BigQuery→S3/Athena/Glue (folded into 0036 gold-offline). Lands on one IAM/billing, no SA keys. |
| A1 | **F3 collapse** (sole telemetry-compute flow) | 0032 | ✅ executed (staging) | One data spine. Every downstream pillar reads one flow, not three. |
| A2 | **Medallion data architecture** | 0036 | in progress | Bronze/silver/gold shapes the historian so live + offline analytics have defined layers to plug into. |
| A3 | **OEE-correctness remediation** | 0037 | in progress | Metrics-by-invariant. Quality/SPC and Andon thresholds are worthless on wrong OEE. |
| A4 | **Cognito auth + write-side fence** | 0034 (0033 model) | in progress | Completes tenant-isolation on writes; unblocks Hasura retirement (0026); enables single-cloud (A0). |
| A5 | **Redis read-plane cache** | 0035 | concurrent | Read plane scales to per-tenant dashboard/report load without hammering the spine. |
| A6 | **Composition engine → all Overview forks** | 0029 | in progress | Config-driven UI. Kills the last 8-fork anti-pattern; every new pillar gets a tile, not a fork. |

**Exit criterion for Phase A:** one cloud, one data spine (F3/medallion), invariant-correct OEE, tenant-fenced reads *and* writes under one IdP, a cache-backed read plane, and a config-driven UI. At that point the substrate is trustworthy and every new pillar has a defined place to write, a defined place to read, and a defined place to render.

### Phase B — close the missing pillars

Each is a mini-charter: *what it is · the ISA-95 expectation · where it plugs into the spine · rough scope.* The **recommended order and its rationale** follow the charters.

#### B1 — Quality / SPC *(recommended first)*
- **What it is.** Move from scrap *counts* to a quality *system*: defect classification (defect classes/codes per equipment), first-pass yield, and statistical process control (X̄-R / p / np / Cp-Cpk control charts) with in-tolerance monitoring.
- **ISA-95 expectation.** Quality Operations Management — capture quality test/defect data against the production request, classify nonconformances, feed the Quality factor of OEE with *reasons*, not just a number.
- **Where it plugs in.** Extends the existing scrap/`samples`/`scanned_boxes` capture on the F3 spine; adds `defect_class` + `quality_result` silver tables; control charts render as new composition-engine widgets (P10) and feed Andon thresholds (B4). The Quality factor of OEE (P3) becomes explainable.
- **Rough scope.** Defect taxonomy seed (mirrors the downtime-reason pattern, `13-downtime-reasons-seed.sql`), quality-result capture usecases in edge-api, SPC compute in the rollup/gold tier, SPC widgets in front4.

#### B2 — Alerting / Andon
- **What it is.** Business-level alarms: OEE-threshold alerts, andon signalling (line-down / call-for-help), and the domain-review-flagged **data-quality alarms** (stale metric, silent equipment, out-of-range).
- **ISA-95 expectation.** Real-time operations monitoring + escalation — the andon board is the canonical MES shop-floor signal.
- **Where it plugs in.** Consumes gold-tier metrics + SPC (B1) on the spine; reuses the *infrastructure* Alertmanager pattern (P15) but at the *business* layer; renders as andon widgets (P10) and push notifications.
- **Rough scope.** Threshold/rule config (per-tenant, seed-first), an evaluation job in the engine-worker, notification transport, andon widgets. Data-quality alarms are the highest-value, lowest-cost slice — build them first within B2.

#### B3 — Traceability / Genealogy
- **What it is.** Lot/batch/serial genealogy: material-consumption records, upstream/downstream lineage, as-built history — "which lot of raw material went into which finished box on which machine at which time."
- **ISA-95 expectation.** Product Definition + Production Performance genealogy — the backbone of recall/audit in regulated manufacturing.
- **Where it plugs in.** New `lot`/`batch` + `material_consumption` dimension tables keyed off `production_orders` (P4) and `scanned_boxes` (P7 fragment) on the spine; genealogy queries served by refdata-api; genealogy view as a new front4 surface.
- **Rough scope.** Larger — a genuine new data model + capture path (edge + operator) + query surface. Sequenced after B1/B2 because it's the biggest lift and least blocking for the OEE-first customer base.

#### B4 — Scheduling / Sequencing
- **What it is.** Move from PO *tracking* to PO *planning*: finite-capacity scheduling, sequencing/dispatch, planned-vs-actual, a schedule board.
- **ISA-95 expectation.** Detailed Production Scheduling (Level-3) — turning a production request into a sequenced, capacity-feasible dispatch list.
- **Where it plugs in.** Sits *above* PO-mgmt (P4): produces the ordered PO queue edge-api already executes; consumes actuals from the spine to close the planned-vs-actual loop; renders as a schedule/Gantt surface.
- **Rough scope.** The largest and most product-shaped (a real APS is its own product). Last because it can layer cleanly on a mature P4 + trustworthy actuals, and because customers can operate (with external planning) without it far longer than without quality/andon.

#### Recommended order and rationale
**B1 Quality/SPC → B2 Alerting/Andon → B3 Traceability → B4 Scheduling.**

- **Foundation before pillars** (already argued): all of Phase B waits on A1–A4. Wrong OEE (pre-A3) makes SPC and thresholds lie.
- **B1 first** because it has the highest ratio of *manufacturing value* to *new substrate*: it extends existing scrap/sample capture rather than inventing a data model, it makes the OEE Quality factor (already shipped) *explainable*, and it directly produces the signals B2 needs. It is the shortest path to a visibly more complete MES.
- **B2 second** because andon/thresholds are cheap once B1's signals + the gold tier exist, and the **data-quality-alarm** slice (flagged by domain review) protects every *other* pillar by catching bad data early — high leverage, low cost.
- **B3 third**: genealogy is a large new data model with lower urgency for the current OEE-first customer base; it benefits from a mature quality system (defects attach to lots) already existing.
- **B4 last**: finite scheduling is effectively its own product, layers cleanly on a mature P4 + trustworthy actuals, and is the capability customers can substitute externally the longest.

---

## 7. Cross-references (the pillar-level decisions this north-star governs)

| ADR | Pillar(s) | Role under this north-star |
|---|---|---|
| [0026](0026-api-layer-consolidation.md) | P13, P4, P10, P12 | CQRS read/write split; retire Hasura/primary/back4 → two auditable tenant authorities |
| [0029](0029-front4-dashboard-composition-and-metric-layer.md) | P10, P9 | Config-driven UI composition engine; proportional-target ruling |
| [0032](0032-collapse-to-single-flow-f3.md) | P2, P3 | One data spine (F3) — the substrate all pillars read |
| [0034](0034-adopt-cognito-amplify-auth.md) | P13, single-cloud | AWS Cognito IdP + write-side fence; part of the GCP exit |
| 0035 *(concurrent)* | P13, P10, P12 | Redis read-plane cache — read scaling |
| 0036 *(concurrent)* | P2, P12, single-cloud | Medallion (bronze/silver/gold); BigQuery→S3/Athena/Glue gold-offline |
| 0037 *(concurrent)* | P3 | OEE-correctness remediation — metrics-by-invariant |

Lower-numbered supporting ADRs referenced above (0011 durability boundary, 0017 process separation, 0021 multitenancy model, 0023 concurrent-PO, 0033 unified-JWT model) remain valid; this ADR does not supersede them, it frames them.

---

## Appendix — negative-evidence search terms (P6/P7/P8/P11)

Absence-of-implementation ratings were grounded by searching all of `packiot-stack-alpha`, `edge-api`, `edge-node-red`, `front4`, `back4-api`, `primary-api` for:

- **Quality/SPC:** `control chart`, `SPC`, `first_pass_yield`, `defect_class`, `nonconformance`, `Cp`/`Cpk`, `in_tolerance` → only scrap/reject *counts* + `samples`/`scanned_boxes` found.
- **Traceability:** `lot`, `batch`, `genealogy`, `serial`, `material_consumption`, `as-built` → only `samples`/`scanned_boxes` counters found; no genealogy model.
- **Scheduling:** `finite scheduling`, `sequencing`, `dispatch`, `planned_order`, `gantt`, `APS` → only `production_orders` *tracking* found.
- **Andon:** `andon`, `alert rule`/`alarm` (business), `oee threshold`, `notification setting` → `andon` returns **zero matches**; infra alerting is rich (`monitoring/prometheus/rules.yml` incl. `IngestSilent`/`EngineStalled`, `alertmanager`, back4 device-email) but no business/andon/metric-data-quality layer (the latter are ADR-0037 P3-2/P3-4 TODOs).
