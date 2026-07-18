# ADR-0031 — back4-api retirement: external-contract shims, net-new refdata datasets, internal endpoint homes, and the Hasura (Wave-4) retirement sequence

**Status:** Proposed · **Date:** 2026-07-18 · **Builds on:** [ADR-0026](0026-api-layer-consolidation.md) (API-layer consolidation — this is its Wave-2/3/4 executable design), [ADR-0027](0027-refdata-api-surface-1-read-contract.md) (the single injection authority `X-Api-Key → customer_id → $1` this reuses), [ADR-0021](0021-multitenancy-model.md) (server-side tenant injection) · **Relates to:** [ADR-0028](0028-front4-refactor-modernization-roadmap.md) / [ADR-0029](0029-front4-dashboard-composition-and-metric-layer.md) (the front4 read re-point that gates Hasura retirement) · **Evidence:** `docs/audits/adr-0026-back4-api-consumer-evidence-2026-07-18.md`, `docs/audits/back4-api-endpoint-inventory.csv` (53-endpoint classification: 11 DUP · 6 READ→refdata · 22 NET-NEW · 12 EXTERNAL · 2 INFRA) · **Decision owner:** tech-lead (pending product sign-off on the external-contract retirement gates).

> **Numbering note:** this is `0031`, not `0030`. `0030` is left unallocated to avoid colliding with a doc reserved on another in-flight branch; the gap is intentional.

---

## 1. Context — what is decided, what is gated, what this ADR unblocks

ADR-0026 set the CQRS-lite end state (edge-api = writes, refdata-api = reads, retire primary-api/back4-api/Hasura). Since then:

- **Wave-1 (primary-api) is RETIRED** — `packiot/api` archived, ArgoCD apps removed.
- **refdata-api is hardened + live** at `refdata.staging.packiot.app` — Surface-1 (ADR-0027) landed the single injection authority, tenant-isolation CI gate, Firebase-JWT user axis, and ~37 datasets.
- **Wave-2 internal back4-api retirement is CLOCK-GATED** on the 40-day cross-month ALB re-mine (#87, first eligible ~2026-08-27) — the 25.6h evidence window clears only continuous consumers, never a monthly batch.

That clock gate is real but it does **not** block design, and it blocks only one of four workstreams. This ADR makes the other three unambiguous and identifies exactly what a backend-dev can build **today** on staging versus what genuinely waits on the clock, on front4, or on an external owner.

The four workstreams, and their true gate:

| Workstream | Endpoints | Real gate | Buildable now? |
|---|---|---|---|
| **A — Net-new refdata READ datasets** | 6 (→ 3 net-new + 2 existing datasets) | none — additive, gated only by `tenancy_isolation_test.go` | **YES — build first** |
| **B — External-contract shims** | 12 EXTERNAL | per-family **external owner sign-off** + golden-shape proof (NOT log silence) | shim + golden harness: **YES**; cutover: gated |
| **C — Internal net-new homes** | 22 NET-NEW | edge-api write usecases + observability-plane decision | downtime-reasons: **YES**; PO-CSV/device: partially |
| **D — Hasura (Wave-4) stop-serving** | Hasura read surface | **front4→refdata re-point complete** (ADR-0029 / #84) | NO — sequence it now, execute after front4 |

The 11 DUP admin-CRUD routes are omitted from this ADR's build work: they are already served by edge-api (Wave-1 direction), showed zero in-window hits, and their *retirement* is purely the #87 clock — nothing to build, only to observe.

---

## 2. Workstream A — the net-new refdata READ datasets (BUILD FIRST)

Six `READ→refdata` endpoints. Two already have datasets (adopt); three datasets are net-new (build). Every one slots into refdata's existing model unchanged: `$1 = customer_id` from the key, filters are body-only, and it must pass `tenancy_isolation_test.go` (params[0] == pEnterprise, `$1` referenced, byte-identical SQL across two tenants). This is the cleanest, highest-value buildable slice — pure additive datasets, zero external or consumer coordination.

### 2a. Already covered — adopt, do not rebuild

| back4-api endpoint | refdata dataset | Note |
|---|---|---|
| `GET /api/admin/downtimes/total/categories/{id}` | `downtimes-per-category` | exists (`datasets.go`); `{id}` becomes the tenant-fenced filter set, not a path arg |
| `GET /api/production/health/{id}` | `overview-production-health` | exists as `perEquipment(...)` — `{id}` is the ownership-guarded `equipment` filter |

The only work here is the front4/consumer adapter (map the old path-arg call to a `POST /v1/query {dataset,filters}` call) — belongs to the consumer re-point (Workstream D / ADR-0029), not to refdata.

### 2b. Net-new datasets — spec for direct implementation

Three datasets. Each is written to drop straight into `datasets.go`. I verified the backing SQL against the live back4-api repositories; the tenant-injection rewrite is the load-bearing change (back4-api took a bare `id_equipment`/`id_enterprise` with **no** tenant fence, or a **hardcoded** equipment list — both are the exact anti-pattern refdata exists to remove).

**(1) `oee-by-month`** — `GET /api/admin/oeeavgmonth/{id}` (`OeeRepository.getAvgOeebyMonth`).
Backing: `equipment_runtime_shift` (no `id_enterprise` column → scope through `equipments`, same shape as `liveUNS`/`custom-target-*`). back4-api's query took only `(id_equipment, date)` with no tenant fence. Rewrite:

```go
"oee-by-month": {
    group: "oee", doc: "Avg OEE per shift for an equipment's month (equipment_runtime_shift)",
    sql: `SELECT avg(r.oee) AS oee, r.cd_shift
            FROM equipment_runtime_shift r JOIN equipments e USING (id_equipment)
           WHERE e.id_enterprise = $1 AND e.id_equipment = $2
             AND date_trunc('month', r.ts_value) = date_trunc('month', $3::date)
             AND r.cd_shift IS NOT NULL
           GROUP BY r.cd_shift ORDER BY r.cd_shift`,
    params: []dsParam{pEnt, pEquip, /* new */ pDate("month")},
},
```
Needs one small param-kind addition: `pDate` — a scalar `::date` filter, validated as `YYYY-MM-DD`, bound positionally. (Trivial extension to `compileDataset`'s switch; add a `tenancy_isolation_test.go` case that it never carries a tenant.)

**(2) `suzano-analogs`** — `GET /api/admin/analogs/{id}` + `GET /analogs/{id}` (`SuzanoTagsDAO.getCurrentByMonth`).
Backing: `equipment_values.analogs->'DATA'` PPM readings. back4-api **hardcoded `id_equipment IN (404,411)`** — a Suzano-specific literal set. This is the "no hardcoded ids" directive applied: the equipment set becomes a tenant-fenced `ids("equipments")` filter (cardinality-0 = all my equipment), the enterprise self-scopes to `$1`. The PPM JSON predicate and the `America/Sao_Paulo` window are preserved:

```go
"suzano-analogs": {
    group: "tenant-custom", doc: "Analog PPM readings from equipment_values (Suzano scrap report)",
    sql: `SELECT analogs->'DATA' AS data, ts_value, id_equipment, id_enterprise, id_site, id_area
            FROM equipment_values
           WHERE id_enterprise = $1
             AND (cardinality($2::int[]) = 0 OR id_equipment = ANY($2::int[]))
             AND ts_value >= date_trunc('minute', $3::timestamp) AT TIME ZONE 'America/Sao_Paulo'
             AND analogs @> '[{"type":"PPM"}]' AND analogs IS NOT NULL
           ORDER BY ts_value ASC`,
    windowed: false,
    params: []dsParam{pEnt, ids("equipments"), pDate("from")},
},
```
Note: this is a **tenant-custom** dataset — the `analogs->'DATA'` projection is a Suzano-shaped read. Keep it in a `tenant-custom` group so it is visibly not a general-purpose dataset. The 404/411 literals do **not** move into refdata; they become the caller's filter (fenced to `$1`).

**(3) `report-downtimes`** — `GET /reportDowntimes/{datetime}` (`get-report-downtimes.service.js`).
Backing object not fully read in this pass (the service delegates to a DAO I did not open). **backend-dev to confirm the backing view/fn at build**; the contract is fixed regardless: `$1 = customer_id`, the `{datetime}` becomes a bounded `pDate`/window filter, and if the backing object is a `v_*`/`h_piot_*` it must either carry `id_enterprise` (add `WHERE id_enterprise = $1`) or be scoped through `equipments`. It **must not** ship with a client-named tenant. Flagged as the one dataset whose backing object needs a 5-minute confirmation before coding.

### 2c. Owner & gate

Owner: **backend-dev** (datasets) + **dba** (confirm `equipment_runtime_shift`/`equipment_values` scope through `equipments` without changing OEE semantics) + **qa** (extend `tenancy_isolation_test.go` for `pDate` and the three new datasets). Gate: the isolation test is green. No external, no clock, no front4. **This is step 1 of the execution order.**

---

## 3. Workstream B — the anti-corruption shim pattern for the 12 EXTERNAL-contract endpoints

### 3a. The pattern and why it is DDD's Anti-Corruption Layer

Eric Evans' **Anti-Corruption Layer (ACL)** exists for exactly this situation: an external system speaks a foreign, idiosyncratic contract, and you must integrate with it **without letting its idioms leak into your clean internal model**, and — the symmetric half that is load-bearing here — **without letting your internal model's evolution break the external consumer's parser**. The ACL is a translation membrane at the boundary.

The evidence is emphatic that these 12 endpoints are foreign contracts, not internal reads dressed as GETs. I read the live back4-api controllers; the response envelopes are **non-uniform and quirky**, each frozen to a specific external parser:

| Endpoint | Frozen envelope | Quirk that MUST survive |
|---|---|---|
| `GET /api/v1/neopac/sap-report` | `{ data: [...] }` | German SAP view columns (`v_13_site_deb_sap_report`); `lineCode`→`id_equipment` resolution; SAP-facing |
| `GET /api/v1/neopac/sap-report-sync` | `{ page, limit, results, data }` | `page`/`limit` as ints, `results = data.length`; filters `auftrag/linie/tag/shicht/shicht_nummer` (German); **live-trafficked (332 hits)** |
| `GET /api/v1/montebello/data-sync` | `{ page, results, data }` | **`page` returned as the RAW unparsed query string**, not an int — a bug the parser now depends on; `site` upper-cased |
| `GET /events_montebello` | (Montebello downtimes shape) | ent-6 fixed |
| `GET /integration/job_data_integration/{id}` | (Montebello pull shape) | `api_key` + `id_enterprise` path-match |
| `GET /integration/get-shift-validation/{id}` | (Montebello pull shape) | ent-fixed |
| `GET /events_incoplast` | `{ newData: [...] }` | envelope key is literally `newData`; timestamps re-formatted to `YYYY-MM-DDTHH:mm:ss[Z]` via moment (the literal `[Z]`) |
| `GET /jobs_incoplast` | (Incoplast jobs shape) | `api_key` query param |
| `GET /integration/job_report/{id}` | `{ job_report: [...] }` | envelope key `job_report`; `id_equipment` parsed from a `{…}`/array string; `api_key`+`id_enterprise` must match (422 on mismatch) |
| `POST /getEmbedToken` | PowerBI embed token blob | MS service-principal auth; **not a DB read** |
| `POST /refreshDataset` | PowerBI refresh ack | triggers an MS-side refresh (write-ish) |
| `POST /getRefreshDatasetToken` | PowerBI refresh-token blob | MS service-principal auth |

The envelope keys alone — `data`, `newData`, `job_report`, `{page,results,data}` — prove the point: refdata's native wire shape is a **bare JSON array of row objects** (`query.go` encodes `[]map[string]any`). If we re-point these consumers at a raw dataset, every one of them breaks. The ACL is the reshaping membrane. **The external quirks (German columns, string `page`, `[Z]` timestamps, `{newData}` key) are the contract — freezing them byte-for-byte IS the job.**

### 3b. Two shim homes — the reads go to refdata, the auth-proxy does not

The 12 split into two families with **different homes**, because they are different kinds of thing:

**Family A — ERP/BI data-sync READS → refdata-api (as a distinct `external-contract` registry).**
NEOPAC SAP (×2), Montebello (data-sync, events, `job_data_integration`, `get-shift-validation`), Incoplast (events, jobs, `job_report`). These are all **GET reads of tenant-fixed views** (`v_13_site_deb_sap_report`, `v_sap_report_data_sync_customer_13`, `v_piot_production_data_sync_cust6`, …), authenticated today by `api_key`/`x-api-key` **plus a hardcoded `id_enterprise` literal check** (`== 13`, `== 6`). That is precisely refdata's server-injected model — with the hardcoded literal removed:

- Each external consumer gets **one dedicated API key** in the key→customer_id map (ADR-0027 §2). NEOPAC's SAP key resolves to customer 13, Montebello's to 6, Incoplast's to 4. The `id_enterprise == 13` literal in the controller is **replaced** by "this key can only reach customer 13's view" — the same authority, no literal.
- The view read stays the **frozen contract view** (it *is* the external agreement; do not "clean it up"). Access guard: the resolved `customer_id` must own the view (a fixed binding per external dataset).
- A **per-consumer envelope adapter** wraps the bare row array back into `{data}` / `{page,results,data}` / `{newData}` / `{job_report}`, replays the quirks (string `page`, moment `[Z]` formatting, German passthrough), and preserves the exact HTTP status semantics (400 no-key, 401 wrong-tenant, 404 not-found, 422 id-mismatch).
- These live in a separate `externalDatasets` registry / route group in refdata (`cmd/refdata-api/external.go`), **not** the front4 `datasets` map — because they carry a frozen non-native envelope and a per-consumer adapter, which the front4 datasets deliberately do not. The tenancy CI gate still applies (every external dataset binds `$1` = its bound customer_id).

**Family B — PowerBI auth-token proxy → edge-api (integration usecase), NOT refdata.**
`getEmbedToken`, `refreshDataset`, `getRefreshDatasetToken`. These are **not DB reads** — they hold an outbound Azure-AD service-principal secret and proxy to Microsoft's PowerBI REST API to mint embed tokens and trigger dataset refreshes. Putting an **outbound credential broker** into refdata would violate refdata's charter (a stateless read plane over Postgres with no outbound secrets). Home: an **edge-api integration usecase** (`usecases/integrations/powerbi/`), because (a) it holds a secret and edge-api is the plane that already manages secrets + audit, (b) `refreshDataset` is an action (write-ish), and (c) it has zero relationship to tenant DB reads. The frozen envelope is whatever the front-end PowerBI embed SDK consumes (`{ token, tokenId, embedUrl, expiration }` shape) — captured as a golden fixture from the live response.

### 3c. Verification — the golden-response contract test (per external consumer)

For **every** external endpoint, before any cutover:

1. **Capture** the live back4-api response as a golden fixture — a prod SELECT-only read against the backing view + the observed HTTP response (headers, status, body bytes). This freezes the envelope *including* the quirks (string `page`, `[Z]` timestamps, German columns). Store under `services/refdata-api/testdata/external/<consumer>/<endpoint>.golden.json`.
2. **Contract test**: drive the shim with the same inputs and assert **byte-identity** against the golden fixture — body, `Content-Type`, and status code across the matrix (valid, wrong tenant, missing key, not-found, id-mismatch). A field renamed, a number stringified differently, or a timestamp format drift **fails the build**. This is the same discipline `tenancy_isolation_test.go` applies to isolation, now applied to shape.
3. **Diff harness**: for the live-trafficked ones (sap-report-sync especially), run the shim in **shadow** alongside back4-api for a window and byte-diff real responses before flipping DNS/route.

### 3d. The retirement gate — owner sign-off, NEVER log silence

This is the rule the evidence forced: `sap-report-sync` is **ACTIVE** (332 hits, `integration-packiot` UA) — a live external SAP contract that would look identical to "dead" in the 25.6h window, and its sibling `sap-report` (the pure SAP-facing report) may fire monthly/quarterly and read as dead when it is merely cadenced. Therefore an EXTERNAL endpoint retires **only** when **both**:

- **(a) the external owner has signed off** — NEOPAC's SAP integration team, Montebello's, Incoplast's, and the PowerBI/BI owner have confirmed cutover to the refdata/edge-api URL (or accepted a same-URL reverse-proxy so their config never changes); **and**
- **(b) the golden contract test is green** — the shim is proven byte-identical, and the shadow diff (for trafficked endpoints) shows zero drift over a representative window.

Log silence is **necessary but not sufficient**, and for external contracts it is not even necessary — a monthly SAP pull is *supposed* to be silent for 29 days. This is the anti-corruption discipline's teeth: you retire on **contract**, not on **observed traffic**.

Owner: **backend-dev** (shims + adapters) + **qa** (golden harness) + **devops-platform** (the same-URL reverse-proxy / DNS so external configs don't change) + **product/tech-lead** (owns the external sign-off conversations). Build now, cut over per-family as sign-offs land.

---

## 4. Workstream C — the 22 NET-NEW internal endpoints' target homes (build-order, not full specs)

Three families. This is a routing decision, not a spec — each family's detailed usecase design is its own task.

**C1 — downtime-reasons CRUD → edge-api write usecase (`usecases/downtime-reasons/`). BUILDABLE NOW.**
~8 route variants (`/upload/downtime_csv`, `/api/admin/upload/downtime_csv`, `/download/downtime_reasons/{id}`, `/api/admin/downtime-reasons/{upload,download}`, and the **guard-bypass typo** `/api/admindowntime-reasons/upload`) collapse to **two canonical edge-api routes**: a guarded CSV bulk-upsert (POST) and a guarded config read (GET). Rebuilding here **structurally closes #60** — edge-api's `auth.middleware` fronts every route, so the unauthenticated variants and the missing-slash bypass simply cease to exist (there is no unguarded path to build). Self-contained; no external or clock dependency. **This is step 2 of the execution order.**

**C2 — PO CSV bulk-import → edge-api production-orders CSV-import usecase = the #52/#60 security controller (Wave-3).**
~4 variants (`/upload/po_csv_validation`, `/api/admin/upload/po_csv`, `/api/production-orders/insert` [unauth + **live-trafficked**], `/api/admin/production-orders/upload`) collapse to **one guarded bulk-import usecase**, behind the #32 PO-staleness gate + `user_logs` audit (ADR-0026: every PO write goes through edge-api so the gate/audit can't be bypassed). The edge-api usecase is buildable now, but **cutover is coordinated with the security remediation** (§6) because `/api/production-orders/insert` is a live NEOPAC upload path — you cannot just delete it. Build the edge-api usecase now; sequence the back4-api route's removal with owner coordination (NEOPAC uploads here).

**C3 — device/PLC infra-events → the observability plane, NOT refdata. Decision-gated.**
~10 endpoints (`/devices*`, `/devices/ping`, `/devices/infra-events/*`, `/infra-events/plc/*`). These are **telemetry**, a different domain than product reads — do not force them into refdata just because the reads are GETs (the audit flags this explicitly). Split: **writes** (`/devices/ping` heartbeat [10,445 hits], `POST /devices/infra-events*` [768 hits]) → an ingestion/obs write sink (edge-node-red/oeecloud telemetry home); **reads** (`/devices/monitoring`, `/infra-events/plc/report`, …) → the observability read surface (Grafana/obs API). **Gate:** confirm the new stack's infra-events home before assigning targets — this is an open decision (§8), owned by devops-platform. Build last of the three.

Owner: **backend-dev** (C1, C2 edge-api usecases) + **devops-platform** (C3 home decision) + **qa** (parity per endpoint). Build order: **C1 → C2 → C3**.

---

## 5. Workstream D — the Hasura (Wave-4) retirement sequence

**Gated on the front4→refdata read re-point completing (ADR-0029 / #84).** Nothing to build here now; the sequence is decided so it executes without re-litigation the moment front4 is off Hasura.

**Two structural wins that make this cheaper than it looks:**

1. **front4 has ZERO subscriptions** → retiring Hasura's realtime/websocket layer is **free**. There are no live-query consumers to migrate to polling; refdata's request/response reads are a complete replacement. Hasura's realtime engine — the hardest part to replicate — has no consumer.
2. **The admin-secret (#58) dies structurally, not by cleanup.** front4 today ships a Hasura admin secret (and a hardcoded `in_id_enterprise: 31`, ADR-0027 §3b) to the browser. Once front4 reads via refdata (`X-Api-Key` / Firebase JWT → server-derived tenant), there **is no admin secret in the browser** — it's not "removed," it's unreachable. #58 closes as a consequence of the re-point, not as a separate task.

**Sequence — each consumer re-points behind a same-shape façade before Hasura stops serving:**

| Step | Consumer | Re-point target | Façade / gate |
|---|---|---|---|
| D1 | **front4** (the big one — gates all of D) | refdata Surface-1 datasets (ADR-0027 §3, §2b) + the Workstream-A datasets | same-shape response per endpoint, parity-checked (ADR-0027 §6 step 6); ADR-0029 owns the composition-layer swap |
| D2 | **PowerBI** dataset source | if PowerBI datasets pull from Hasura/DB → re-point to a stable `v_*`/refdata external-dataset (Family A) | same-shape; coordinate with the BI owner (rides §3d) |
| D3 | **reports / cq-logs / BigQuery** | ADR-0026 step 6 retargets export to **S3** (staging greenfield); the read path moves off Hasura to refdata or a direct stable view | verify export; confirm no prod BigQuery consumer (ADR-0026 OQ3) |
| D4 | **stop serving Hasura** | — | **no consumer still calling Hasura**, verified via Hasura's **own query logs** (Hasura is NOT behind the ALBs — the audit's NO-LOG-COVERAGE gap; needs Hasura logs / VPC flow, not the ALB re-mine) |
| D5 | **park, don't destroy** | keep `hdb_catalog` + metadata + compose def behind a profile (like alertmanager) | documented re-stand-up runbook (ADR-0026 reversibility) |

**Critical evidence caveat:** the #87 40-day ALB re-mine does **not** cover Hasura — Hasura sits behind no ALB in the log buckets. D4's "no consumer" gate needs a **different evidence source** (Hasura query logs). Do not conflate the back4-api clock with the Hasura clock.

Owner: **frontend-dev** (D1, ADR-0029) + **backend-dev** (D2/D3 read re-points) + **devops-platform** (D4 log evidence, D5 park + runbook). Gate: front4 fully off Hasura, verified.

---

## 6. Security debt (#52/#60/#61) riding Wave-3 back4-api retirement

The retirement **structurally closes** these — but back4-api is **still live and these routes are live-trafficked**, so there are two clocks: a *stopgap* clock (now, on back4-api) and a *structural-close* clock (Wave-3 cutover).

| Debt | What it is | Structural close (Wave-3) | Stopgap needed NOW (back4-api still live) |
|---|---|---|---|
| **#60** | unauth-write on downtime-reasons + the **guard-bypass typo** `/api/admindowntime-reasons/upload` (missing slash → `/api/admin/*` glob misses → unauthenticated) | C1 rebuild on edge-api: every route behind `auth.middleware`, no unguarded path exists to build | fix the missing-slash route on back4-api; it's an auth bypass on a live service |
| **#52** | PO CSV importer (`ProductionOrdersController`, own `pg.Pool`, 3/4 routes outside `/api/admin` guard); `/api/production-orders/insert` **hit in-window** | C2 rebuild on edge-api behind the PO gate + `user_logs` audit | put `/insert` behind auth on back4-api; coordinate with NEOPAC (live upload path) |
| **#61** | back4-api's own superuser `pg.Pool` + secret hygiene (branch `security/task-61-superuser-pool-and-secret-hygiene`) | the superuser pool **dies with back4-api** — Wave-3 cutover is the real fix | continue #61 secret-hygiene on back4-api until the service is gone |

**The lesson to name:** retirement is the *durable* fix (delete the vulnerable service, the vuln goes with it), but you **cannot wait 40 days on a live-trafficked auth bypass**. Stopgap on the live service now; let the rebuild close it structurally at cutover. The unauth-write holes are elevated precisely *because* the endpoints have live traffic — dormant vulnerable code is lower urgency than trafficked vulnerable code.

Owner: **backend-dev** (stopgaps + edge-api rebuilds) + **devops-platform** (#61 secret hygiene). Stopgaps are **buildable now** and **urgent**.

---

## 7. Recommended EXECUTION ORDER (the sequencing you launch from)

**Build now, in this order (no clock, no front4, no external coordination blocks these):**

1. **Workstream A — 3 net-new refdata datasets** (`oee-by-month`, `suzano-analogs`, `report-downtimes`) + the `pDate` param kind + isolation-test cases. *Highest value, lowest risk, pure additive.* (backend-dev + dba + qa)
2. **Security stopgaps** — fix the #60 guard-bypass slash + auth the #52 `/insert` route **on back4-api** (live auth bypass; do not wait). (backend-dev)
3. **Workstream C1 — edge-api downtime-reasons CRUD usecase** (structurally closes #60). (backend-dev)
4. **Workstream B — the golden-fixture harness + the shims themselves** (refdata `external.go` for Family A, edge-api `integrations/powerbi/` for Family B). Build + prove byte-identity in shadow. *Cutover waits on §3d sign-offs, but the code and proof are buildable now.* (backend-dev + qa + devops-platform)
5. **Workstream C2 — edge-api PO-CSV-import usecase** (the security controller; buildable now, cutover coordinated with NEOPAC). (backend-dev)

**Gated — sequence decided, execute when the gate opens:**

6. **Workstream B cutovers** — per external family, as owner sign-off + green golden test land (rolling; sap-report-sync is live so shadow-diff it hardest).
7. **Workstream C3 — device/PLC** — after the observability-plane infra-events home decision (§8, devops-platform).
8. **Wave-2 DUP retirement** (11 admin-CRUD) — after the **#87 40-day cross-month ALB re-mine** (~2026-08-27); re-parse at T+7d/T+30d/T+40d.
9. **Workstream D — Hasura stop-serving** — after **front4→refdata re-point** (ADR-0029/#84) completes; D1→D5 in order; D4 gated on **Hasura's own logs**, not the ALB clock.
10. **back4-api service deletion** — only when *every* endpoint has a home (A+B+C done) AND the 40-day window has cleared the internal routes AND every external family has signed off. This is the last domino.

**One-line mental model:** *build the additive reads and the structural security fixes today; build the shims + prove their shape today but cut them over on external contract, not on log silence; and let Hasura fall only after front4 stops leaning on it.*

---

## 8. Open questions (need a decision)

1. **PowerBI dataset source path (D2):** do PowerBI datasets pull from Hasura, a direct view, or the DB? Determines whether D2 is a real re-point or a no-op. (BI owner + backend-dev.)
2. **Observability infra-events home (C3):** is the device/PLC telemetry sink edge-node-red, oeecloud, or a new obs-ingest service? Blocks C3 target assignment. (devops-platform.)
3. **External same-URL vs new-URL cutover (§3d):** do we reverse-proxy the old back4-api external paths to refdata/edge-api (external configs never change — fastest sign-off) or ask each owner to re-point their URL? Recommendation: **same-URL reverse-proxy** — it makes the external sign-off a shape-verification, not a config-change ask, and keeps the frozen contract literally frozen (URL included).
4. **`report-downtimes` backing object (§2b-3):** confirm the `v_*`/`h_piot_*` behind `get-report-downtimes.service.js` before coding — the only Workstream-A dataset whose backing object is unconfirmed.
5. **Prod BigQuery consumer (D3 / ADR-0026 OQ3):** staging is greenfield for cq-logs→S3; is there a prod BigQuery reader that gates the reports re-point? (devops-platform + product.)

---

## 9. Reversibility & blast radius

- **Workstream A / C1** — additive datasets + a new guarded usecase; the old back4-api routes stay live in parallel until parity is proven, then removed. Reversible.
- **Workstream B** — the shim runs in shadow beside back4-api; cutover is a route/DNS flip that reverses instantly; the frozen golden test is the guardrail. Reversible until the external owner's config is repointed (mitigated by the same-URL reverse-proxy in OQ3).
- **Workstream D** — Hasura is **stopped, not destroyed** (`hdb_catalog` + metadata + parked compose profile preserved; re-stand-up is a config flip). Fully reversible per ADR-0026.
- **Blast radius:** Workstreams A, B-FamilyA, D are **reads only** — no OEE math, no writes, no gate/audit path; they can fail to serve, never corrupt a factory's numbers. B-FamilyB (PowerBI) and C (writes) touch edge-api's write plane and inherit its gate/audit/auth — the reason those homes were chosen.
</content>
</invoke>
