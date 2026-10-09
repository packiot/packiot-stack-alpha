# W3 — PowerBI → Metabase Migration Readiness Kit

Status: **PREP / READINESS ONLY** (2026-08-07). Owner: platform.
Parent spec: [`front4-cognito-cutover-and-bi-migration.md`](./front4-cognito-cutover-and-bi-migration.md) (W3 section).

> **Nothing here is migrated or deployed.** This kit exists so that the moment the
> team gets `.pbix` files + Azure/PowerBI workspace access, extraction → rebuild →
> parity sign-off is **mechanical**, not exploratory. Every step that needs live
> PowerBI is marked **[NEEDS PBI ACCESS]**; everything else is installable/decidable now.

---

## 0. The single most important thing to decide before access lands

**Decide the W2 target tool (Metabase vs Superset) and stand up ONE empty instance
pointed at a read-replica of the prod Postgres/TimescaleDB.** W3 is a *re-creation*
into a target that must already exist. Every other prep item (toolchain, templates,
parity harness, back4 interim) can proceed in parallel and is tool-agnostic — but you
cannot rebuild a single visual until the destination BI tool and its DB connection
exist. This kit assumes **Metabase** (the parent spec's recommendation) and notes
Superset deltas where they matter.

Second-most-important, and independent: **ship the back4 dual-verifier (Section 5)**
so PowerBI keeps working through the Firebase→Cognito cutover. That is the one change
that prevents a *regression* while W3 is in flight.

---

## 1. Reality anchor (read before touching anything)

There is **no `.pbix` → Metabase/Superset auto-importer**. DAX, Power Query (M), and
visual layout have no clean target equivalent. Migration is **structured re-creation**.
What makes it tractable here — and cheaper than a generic PowerBI migration:

- **The reports read the SAME Postgres/TimescaleDB the new stack owns.** The SQL/model
  is portable; only visuals are rebuilt.
- **Codebase evidence: the PowerBI reports mostly SELECT from pre-computed per-tenant
  `report_*` tables**, not from raw facts. Grep of `scripts/powerbi-evidence-prod-read.sh`
  and `docs/` shows the live report tables PowerBI consumes:

  | Live prod table (note the baked-in `enterprsie` typo) | What it feeds |
  |---|---|
  | `report_shift_enterprsie_06` (+ `_06b`, `_06c`) | Enterprise 06 shift OEE report |
  | `report_speed_enterprsie_33` | Enterprise 33 speed report |
  | `report_data_sync_customer_13` | Customer 13 data-sync report |
  | `report_downtimes` | Downtimes report |

  These are populated by the stack's **report writers** (edge-transformer / cron), the
  same ones the existing prod-read fidelity harness already validates. **Implication:**
  for many reports the Power Query "M" is a thin `SELECT * FROM report_*` — the DAX on
  top is where the real logic lives, and DAX→SQL is the actual work. Confirm this
  per-report during extraction (Section 3); it may not hold for every page.

- **What is portable vs rebuilt:**

  | PowerBI asset | Fate in Metabase |
  |---|---|
  | Power Query (M) source | **Portable** → a SQL query / Metabase model against Postgres (often `report_*`) |
  | DAX measures | **Re-express** as SQL / Metabase custom columns + metrics (semantic 1:1) |
  | Data model (tables + relationships) | **Portable** → re-declare as Metabase models + joins |
  | Report pages / visuals / layout | **Rebuilt** manually, visual by visual |
  | Row-level security (RLS roles) | **Re-implement** as Metabase sandboxing + Postgres RLS (Section 6) |

**Honesty note:** Section 1's *inputs* (which reports exist, who owns them, the `.pbix`
files, the Azure workspace) are **user-provided**. This kit cannot enumerate the real
report set until access lands — it gives you the exact intake to run and the machinery
to process whatever comes back.

---

## 2. Intake checklist [NEEDS PBI ACCESS] — run this the day access lands

A literal, executable checklist. Fill [`w3-powerbi/intake-checklist.md`](./w3-powerbi/intake-checklist.md)
(a copy-per-run worksheet). Collect, in order:

### 2.1 Report inventory (two sources, cross-check them)
- [ ] **From our code:** enumerate every `reportId` front4 asks back4 to embed. front4
  routes `/:dataset/:reportId` → `pages/ReportsPowerBi/index.jsx` → `api.post('/getEmbedToken', { reportId })`.
  Grep front4 for the route table / menu entries that supply those `reportId`/`dataset`
  params, and pull distinct pairs from back4/access logs (`server.js` logs every request
  body — `method:[POST] path:/getEmbedToken body:{...}`). This yields the reports that
  are **actually reachable from the product**.
- [ ] **From PowerBI:** list every report in the workspace (`workspaceId` default in
  `back4-api/.../PowerBIController/index.js` = `635f5c34-4183-4211-831b-241fbf1ec3dc`;
  reports may also live in other workspaces — confirm). Use the PowerBI REST API or
  portal (Section 3.4).
- [ ] **Reconcile** the two lists. Reports in PowerBI but not reachable from front4 =
  candidates to drop (don't migrate dead reports). Reports reachable but missing from
  the workspace = broken embeds to flag.
- [ ] **Rank by usage** (from back4 logs / PowerBI usage metrics). Migrate highest-usage first.

### 2.2 Per-report artifacts (one set per report kept)
- [ ] The **`.pbix` export** (PowerBI Desktop: *File → Download this report*, or Service
  *Download the .pbix*). Store under a **private, access-controlled** path — `.pbix` embeds
  cached data + connection strings. **Do NOT commit `.pbix` to git.**
- [ ] The **datasets / data sources** each report binds to (dataset id + the underlying
  connection: which Postgres/Timescale host+db, or a PowerBI dataflow, or an imported
  extract). Note **import vs DirectQuery** mode per dataset (changes refresh semantics).
- [ ] The **refresh schedule** per dataset (cadence + last-refresh) — needed for Section 7 risk.

### 2.3 Azure / PowerBI platform details
- [ ] **Workspace(s)** id(s) and names.
- [ ] **Service principal**: `clientId`, `tenantId`, and the fact that the client secret
      is **currently hardcoded in `back4-api/.../PowerBIController/index.js`** (see Section 5.4 —
      this secret must be rotated + moved to Secrets Manager regardless of migration).
- [ ] Whether the SP has **workspace admin** (needed to export `.pbix` + read dataset metadata via API).
- [ ] The Azure AD **tenant** + any **RLS roles** defined in the PowerBI datasets (these
      encode the per-customer isolation you must reproduce — Section 6).

### 2.4 Ownership + acceptance
- [ ] **Report owner** (business + technical) per report — the person who signs off parity.
- [ ] The **key measures** each owner cares about (the numbers that must match). These become
      the parity harness inputs (Section 4).
- [ ] A **known-good test window** per report (a tenant + period where the owner trusts the
      current PowerBI numbers) — the parity baseline.

**Output of Section 2:** a filled inventory table (rank, reportId, workspace, `.pbix` path,
datasets, owner, key measures, test window) → drives Sections 3–4.

---

## 3. Extraction toolchain — installable + runnable NOW (no PBI access needed to install)

Install these now; they only *need* a `.pbix` at run time. A `.pbix` is a **ZIP**: the
`DataModel` part holds the tabular model (VertiPaq); `Report/Layout` holds the visuals
(JSON); `Connections`/`DataMashup` hold the Power Query (M) + data-source bindings.

Wrapper: [`scripts/w3-powerbi/extract-pbix.sh`](../../scripts/w3-powerbi/extract-pbix.sh)
drives the ZIP + pbi-tools steps and drops everything into a per-report `extract/` folder
for diffing.

### 3.1 The `.pbix` is a ZIP — the zero-tool baseline
```bash
# Peek at the parts without any special tool:
unzip -l report.pbix
# Report/Layout is JSON-ish (UTF-16); DataMashup holds the M queries (also zipped inside):
mkdir report_unzipped && (cd report_unzipped && unzip -o ../report.pbix)
```
- **Extracts:** raw `Report/Layout` (visual tree), `DataMashup` (M), `Connections`.
- **Maps to Metabase:** `Report/Layout` → the list of visuals you must rebuild;
  `Connections`/`DataMashup` → the SQL/`report_*` source per table.

### 3.2 `pbi-tools` — decompile to source (the primary tool)
Open-source. Decompiles `.pbix` → a git-diffable source tree (model + layout as JSON).
```bash
# Install (Windows-native; on Linux run under the .NET 6 build or a Windows box/CI):
#   https://github.com/pbi-tools/pbi-tools  → download release, add to PATH
pbi-tools extract report.pbix -extractFolder ./extract/report
# Produces: ./extract/report/Model/  (tables, measures, relationships as JSON/TMDL)
#           ./extract/report/Report/ (pages + visuals as JSON)
```
- **Extracts:** the full model (tables, columns, **measures as DAX**, relationships) +
  the visual layout, all as text you can diff and review.
- **Maps to Metabase:** `Model/tables/*` → Metabase **models**; `Model/…/measures` (DAX) →
  Metabase **metrics / custom columns** (rewritten as SQL); `Report/sections/*/visuals` →
  the visuals to rebuild, one row in the per-report worksheet each.

### 3.3 DAX Studio + Tabular Editor — export the measures + model cleanly
- **DAX Studio** (`https://daxstudio.org`): connect to the `.pbix` (opened in PowerBI
  Desktop) or the dataset; run *Advanced → Export Metrics* to dump **all DAX measures**
  to a file. Also lets you **run the DAX** and capture the exact result set for a test
  window → this is a parity baseline source (Section 4).
- **Tabular Editor** (`https://tabulareditor.com`, free v2): opens the model; export
  measures + tables + relationships as scripts (C#/TMSL). Best for a structured dump of
  the semantic model.
- **Extracts:** the authoritative list of **DAX measures** (name + expression) and the
  tabular model shape.
- **Maps to Metabase:** each DAX measure → one row in the worksheet's "DAX→SQL" table;
  the model → the Metabase model/join graph.

### 3.4 PowerBI REST API — inventory + `.pbix` export at scale [NEEDS PBI ACCESS]
Using the same service principal back4 already uses (`clientId`/`tenantId` in
`PowerBIController/index.js`), acquire an AAD token (scope
`https://analysis.windows.net/powerbi/api/.default`) and call:
```
GET  https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/reports
GET  https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/datasets
GET  https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/reports/{reportId}/Export   # → .pbix
GET  https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/datasets/{datasetId}/datasources
```
- **Extracts:** the full report+dataset inventory + `.pbix` files + each dataset's data
  sources (proves whether it points at our Postgres / `report_*` tables).
- **Maps to Metabase:** the inventory table (Section 2.1) + confirms the SQL source per report.

> **Tooling reality:** `pbi-tools`, DAX Studio, Tabular Editor are **Windows-first**.
> If no one has a Windows box, run them in a Windows CI runner / VM. The ZIP-unzip path
> (3.1) + the REST API (3.4) are OS-agnostic and get you 70% of the way.

---

## 4. Parity-check harness — the per-report sign-off gate [NEEDS PBI ACCESS to baseline]

**Goal:** prove a migrated Metabase report matches the PowerBI original — *same tenant,
same period, same numbers within tolerance*. This is the gate that lets an owner sign off.

### 4.1 We already have half of it
`scripts/powerbi-evidence-prod-read.sh` already: opens a **read-only** prod connection
(`BEGIN READ ONLY`, SELECT-only, honors the "prod is SELECT-only forever" rule), computes
report values, and diffs them against the live `report_*` tables (it scored `1197/1197`
on shift06 and `63/68` on speed33 historically). **Reuse its DB-connection + read-only
pattern verbatim.** W3's twist: the "expected" side is the **PowerBI-exported values**, and
the "actual" side is the **Metabase/refdata query** — both hitting the same `report_*` /
OEE tables.

### 4.2 The three-way tie-out
For each report + key measure + test window:
```
  PowerBI (DAX result, exported via DAX Studio)          ── expected (owner-trusted)
        ≈  Postgres report_* / OEE aggregate table       ── ground truth (source of both)
        ≈  Metabase question result (the migrated report) ── actual (what we shipped)
```
If PowerBI ≈ Postgres but Metabase ≠ Postgres → **our rebuild is wrong** (fix the Metabase
question). If PowerBI ≠ Postgres → the PowerBI DAX did something extra (a filter, a
time-zone shift, a blank-exclusion) → capture it as a DAX→SQL semantic gap and re-express.

### 4.3 The harness stub
[`scripts/w3-powerbi/parity_check.py`](../../scripts/w3-powerbi/parity_check.py) — a fill-in
runner that:
1. Loads a **spec file** per report (`w3-powerbi/parity-specs/<report>.yaml`): the measures,
   the test window, the tenant, the tolerance, and the two queries (Postgres ground-truth
   SQL + the Metabase question id / refdata endpoint).
2. Loads the **PowerBI-exported CSV** (from DAX Studio for that same window).
3. Diffs all three, applies per-measure **tolerance** (abs + relative), and prints a
   PASS/FAIL table. Non-zero exit on any FAIL = the gate is red.

Tolerance guidance: OEE ratios to **±0.001 absolute**; counts (boxes, production) **exact
(0)** unless a documented rounding/time-boundary reason exists; speeds to **±0.1**. Record
the tolerance + the reason in the spec so sign-off is auditable.

**Sign-off rule:** a report is "migrated" only when its parity spec is green for the
owner's test window **and** a second independent window. Nothing ships on one window.

---

## 5. Interim — keep PowerBI alive under Cognito (DESIGN ONLY; back4 is a separate repo)

This is the change that **prevents a PowerBI regression** during the Firebase→Cognito
cutover. **Do not implement here** — it lands in `back4-api`. Spec follows.

### 5.1 Current back4 state (audited)
- Routes (`back4-api/src/routes.js`): `/getEmbedToken`, `/refreshDataset`,
  `/getRefreshDatasetToken` are registered **with NO auth middleware**. Global auth only
  covers `/api/admin/*` (`server.js:104`). So today the embed endpoints are effectively
  **unauthenticated**.
- The auth middleware that *does* exist (`src/app/middlewares/auth.js`) is **Firebase-only**:
  it reads `req.headers.token` + `req.headers.uid` and calls
  `firebase-admin getAuth().verifyIdToken(token)` — which **cannot** verify a Cognito token.
- front4 sends the credential as **`token` + `uid` headers** (not `Authorization: Bearer`) —
  see `front4/src/services/api.js` interceptor + `authToken.js` (dual Firebase/Cognito
  provider; a Cognito session yields `{ token: idToken, uid: sub }`).

### 5.2 The regression, stated precisely
- **Literal today:** because `/getEmbedToken` has *no* verifier, a Cognito user's embed
  **won't 401** — it just works (the route ignores the token). So there is **no hard
  functional regression** the instant Firebase→Cognito flips, **as long as the route stays
  unauthenticated.**
- **But:** (a) an unauthenticated embed-token minter is a **security hole** that should be
  closed as part of this work, and (b) the moment anyone hardens back4 (puts these routes
  behind `authMiddleware`, or makes auth global like `/api/admin/*`), the **Firebase-only
  verifier 401s every Cognito user**. So the correct interim is: **add the dual verifier AND
  put the embed routes behind it** — closing the hole and staying Cognito-safe in one move.

### 5.3 The change (mirror edge-api / refdata-api verifier)
Port the exact trust model of `edge-api/src/shared/auth/jwks-bearer-jwt-verifier.ts` (which
itself mirrors refdata-api `cmd/refdata-api/auth_cognito.go`). back4 **already has the deps**:
`jsonwebtoken ^8.5.1` + `jwks-rsa ^2.1.4` + `firebase-admin ^11` — nothing new to add.

New `back4-api/src/app/middlewares/authDual.js`:
1. Read the token from `req.headers.token` (keep back4's existing header shape — front4
   already sends `token`/`uid`, not `Authorization`). Optionally also accept
   `Authorization: Bearer`.
2. `jwt.decode(token, {complete:true})` **unverified**, only to read `iss` + `kid` (route,
   never trust — same as the edge-api verifier's step 1).
3. **Route by `iss`:**
   - `iss === COGNITO_ISSUER` → verify RS256 against the Cognito JWKS (`jwks-rsa`,
     cached, rate-limited), enforcing `algorithms:['RS256']`, `issuer=COGNITO_ISSUER`,
     `audience=COGNITO_CLIENT_ID`, `exp`. On success `next()`.
   - Firebase issuer (`https://securetoken.google.com/<project>`) → keep the existing
     `firebase-admin verifyIdToken` path (unchanged), OR verify via the Google securetoken
     JWKS the same way. **Preserve the current Firebase behavior byte-for-byte** so nothing
     regresses while both issuers are live.
   - Unknown `iss` → 401 (fail closed — never silently allow).
4. **Fail closed:** every failure → `401`. Never downgrade a present-but-invalid token.

Apply it to the PowerBI routes:
```js
// routes.js
routes.post('/getEmbedToken',        authDual, PowerBIController.getEmbedToken);
routes.post('/refreshDataset',       authDual, PowerBIController.refreshDataset);
routes.post('/getRefreshDatasetToken', authDual, PowerBIController.getDatasetResfreshToken);
```

### 5.4 Env (mirror edge-api `bearer-jwt.config.ts`)
```
COGNITO_ISSUER      https://cognito-idp.<region>.amazonaws.com/<userPoolId>   # exact iss
COGNITO_CLIENT_ID   <app-client-id>                                          # required aud
COGNITO_JWKS_URI    <issuer>/.well-known/jwks.json   # default derivable from COGNITO_ISSUER
FIREBASE_PROJECT_ID <existing>                        # unchanged Firebase path
AUTH_DUAL_ENABLED   default ON; "false" makes the Cognito leg inert (instant rollback)
```
Use the **same shared Cognito user pool** as refdata-api / edge-api / oauth2-proxy (memory:
pool domain `packiot-auth`) so one token works everywhere. A partly-configured issuer
(missing `aud` or `issuer`) must be **dropped, not trusted** (edge-api's rule).

### 5.5 Test
- **Firebase token** (legacy) → 200 + valid embed URL (proves no regression).
- **Cognito token** from the shared pool → 200 (proves the new leg).
- **No token / expired / wrong-`aud` / unknown-`iss`** → 401 (proves fail-closed).
- **Rotation:** kill a signing key mid-flight → `jwks-rsa` cache refetches on cache-miss.
- Do it against a back4 dev/staging env; **do not touch prod** from this kit.

### 5.6 Flag it
> **This is the pre-req that prevents a PowerBI regression during W3.** If back4 auth is
> ever tightened without this verifier, every Cognito user loses PowerBI. Track it as a
> back4 ticket, land it **before** the Firebase→Cognito prod flip (W1 step 1). Also:
> **the service-principal client secret is hardcoded in `PowerBIController/index.js` and
> committed** — rotate it and move it to Secrets Manager as part of this change (independent
> of migration; it's a live exposure).

---

## 6. Target structure in Metabase (where migrated reports land)

W2 stands up Metabase embedded in front4, connected to TimescaleDB, tenant-isolated by the
Cognito identity (signed/interactive-embedding JWT with a locked `tenant_id`; belt-and-
suspenders **Postgres native RLS** on a session GUC `SET app.tenant_id`).

### 6.1 Collections
- **One collection per tenant** for anything tenant-specific (the migrated `report_*`-backed
  reports are inherently per-enterprise — `report_shift_enterprsie_06`, `report_speed_enterprsie_33`
  are already per-tenant tables). A tenant only ever sees its own collection.
- **A shared "Packiot Curated" collection** for report *templates* that are identical across
  tenants (parameterized by `tenant_id`), so you build once and sandbox per viewer rather
  than copy-per-tenant.
- **Admin-only "Migration WIP" collection** for reports mid-parity (not yet signed off) so
  half-migrated reports are never visible to customers.

### 6.2 Curated (front4-native) vs self-service (Metabase)
Per the parent spec's **hybrid** model:
- **Flagship OEE** (the numbers customers live in) → **keep native in front4** (refdata +
  ECharts/Tremor). If a migrated PowerBI report *is* core OEE, its destination may be a
  **refdata dataset / front4 view**, not a Metabase question. Decide per report in the
  worksheet ("Destination: front4-native | Metabase-curated | Metabase-self-service").
- **Everything else** → **Metabase**, seeded as the **curated set** customers then extend
  with self-service authoring.

### 6.3 Sandbox / RLS — a migrated report MUST keep per-tenant isolation
PowerBI enforced isolation via dataset **RLS roles**. Metabase must reproduce it or you leak
cross-tenant data:
- **Metabase data sandboxing** (paid/interactive tier): map the embed JWT's `tenant_id` to a
  row filter on every tenant-scoped table/model. A migrated report inherits the sandbox — it
  cannot widen its own tenant scope.
- **Postgres RLS** as the hard floor: `ENABLE ROW LEVEL SECURITY` + a policy keyed on
  `current_setting('app.tenant_id')`, set per connection from the embed identity. Even a
  hand-written SQL question can't escape it. **This is the parity gate for security:** re-run
  a migrated report as tenant A and confirm zero tenant-B rows (Section 7 risk).
- Note the `report_*` tables are *already* per-enterprise (the enterprise id is in the table
  name), so isolation there is partly structural — but any report that reads shared facts
  (`equipment_values`, `downtimes`, `production_orders_runtime`) needs the RLS/sandbox filter.

---

## 7. Sequencing + risks

### 7.1 Ordered plan
1. **[now, no access] Decide W2 tool + stand up empty Metabase** on a Postgres read-replica
   (Section 0). Nothing rebuilds without it.
2. **[now, no access] Install the toolchain** (Section 3) + land the **back4 dual verifier**
   (Section 5) so PowerBI survives the Cognito flip. Rotate the leaked SP secret.
3. **[access lands] Run intake** (Section 2) → ranked inventory + `.pbix` + owners + test windows.
4. **[per report, highest usage first]** extract (Section 3) → fill the worksheet
   ([`w3-powerbi/per-report-migration-template.md`](./w3-powerbi/per-report-migration-template.md))
   → rebuild in Metabase → **parity-gate** (Section 4) → owner sign-off. Only then mark migrated.
5. **Decommission** each PowerBI report only after its Metabase replacement is signed off on
   two windows. When the *last* report is migrated, retire the back4 PowerBI routes + SP.

### 7.2 Real risks
| Risk | Why it bites | Mitigation |
|---|---|---|
| **DAX→SQL semantic gaps** | DAX filter context / `CALCULATE` / time-intelligence / blank-handling has no literal SQL twin; a naive rewrite silently changes numbers | The three-way tie-out (4.2) catches it: PowerBI≠Postgres exposes the hidden DAX behavior → re-express explicitly. Never eyeball-approve. |
| **Visuals with no Metabase equivalent** | PowerBI custom visuals / decomposition trees / R-Python visuals don't exist in Metabase | Flag per visual in the worksheet ("no equivalent → nearest / drop / front4-native"). Get owner agreement *before* rebuild, not after. |
| **Row-level-security parity** | PowerBI RLS roles ≠ Metabase sandbox by default → cross-tenant leak | Postgres RLS as the hard floor (6.3) + a mandatory "run as tenant A, assert zero tenant-B rows" check in the parity gate. |
| **Dataset refresh cadence** | PowerBI import datasets show *stale-by-schedule* data; Metabase on live Postgres shows *now*. Numbers "differ" only because of the time offset | Record each dataset's refresh mode+cadence (2.2). For import datasets, run parity against a **closed** window (fully past) so both sides are settled. |
| **`report_*` writer coupling** | If a report reads a `report_*` table, its correctness depends on the report-writer cron still running post-migration | Confirm the writer stays alive until the report is retired; or migrate the report to read the underlying OEE aggregates directly. |
| **Tool-tier / license** | Metabase data sandboxing + interactive embedding are **paid**; without it, per-tenant isolation falls back to Postgres RLS only | Resolve in W2 (Section 0). Superset does RLS free but shifts ops cost. |
| **`.pbix` handling** | `.pbix` embeds cached data + a connection string (and historically secrets) | Private storage only, never in git; treat like a credential. |

---

## Appendix — schema reference (the tables migrated reports read)

From the monorepo CLAUDE.md + `scripts/powerbi-evidence-prod-read.sh`. Confirm exact column
names against the live schema at migration time (this checkout has no `schema.sql`):

- **Pre-computed report tables (what PowerBI usually SELECTs):** `report_shift_enterprsie_<ent>`
  (+ `_b`/`_c` variants), `report_speed_enterprsie_<ent>`, `report_data_sync_customer_<id>`,
  `report_downtimes`.
- **OEE aggregates:** `equipment_runtime_shift`, `equipment_runtime_1hour`,
  `equipment_runtime_1day`, `equipment_runtime_1week`, `equipment_runtime_1month`
  (OEE = Quality × Availability × Performance; ratio columns bounded [0,1] per the OEE
  invariant work).
- **Facts:** `equipment_values` (raw SparkPlug time series; `speed`, `net_production_incr`,
  `net_production_val`, `ts_value`, UNIQUE(`ts_value`,`id_equipment`)), `downtimes`,
  `production_orders_runtime` (OEE row per PO run), `scanned_boxes` (`increment`,
  `box_order_number != 0` = valid), `production_orders` (`status` 1..4).
- **Hierarchy for filters/RLS:** `enterprises → sites → areas → equipments`
  (`tp_equipment` 1=machine, 2=sector, 3=line), `shifts` / `shift_hours`.

---

## What is NOT done (honesty ledger)

- **No report is migrated.** No Metabase instance is stood up by this kit. No back4 change is
  implemented (Section 5 is a spec for a separate repo). Nothing is deployed; prod is untouched.
- Section 1's real inputs (the actual report list, owners, `.pbix` files) are **user-provided**
  and unknown until PowerBI access lands.
- The tool commands (Section 3) are validated against public docs + the `.pbix`-is-a-ZIP fact,
  not run here (no `.pbix` available).
