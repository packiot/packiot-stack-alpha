# Spec — front4 Cognito Read-Cutover + Embedded BI + PowerBI Dashboard Migration

Status: DRAFT (2026-08-07). Owner: platform. Supersedes the PowerBI dependency in front4.

Three linked workstreams, deliberately **decoupled** so the login fix does not wait on the BI decision:

- **W1 — Read-plane cutover** (finish ADR-0026): move front4's last Hasura reads to refdata-api → **fixes the Cognito white page**, retires Hasura + Firebase from front4.
- **W2 — Embedded self-service BI**: a self-hosted BI tool embedded in front4 for customers to **build their own reports** and view curated OEE.
- **W3 — PowerBI dashboard migration**: bring the **existing PowerBI reports** onto W2's tool (no auto-importer exists — structured re-creation; the SQL/model is portable, the visuals are rebuilt).

---

## W1 — front4 read-plane cutover (the white-page fix)

### Current state (audited 2026-08-07, front4 @ `654f1bd2`)
- The analytics migration is **~95% done**. Nearly all ~119 `gql` constants are **dead payload** — `useDualRefdataQuery` is refdata-only and ignores its `gqlQuery` prop. front4 has **zero GraphQL mutations** (all writes are HTTP).
- **Only two queries still execute against Hasura** (`gqlpiot.packiot.com`, Firebase-issuer-only → Cognito token 401s):
  1. **`GET_VARIABLES_CONTEXT`** (`src/Context/Query.js:3`) — **always**. This is the white page: under Cognito the query 401s, the bootstrap `onCompleted` (`VariablesContext.jsx:48`) populates nothing (all optional-chained, so no throw — just an **empty authenticated shell**).
  2. **`DOWNTIME_QUERIES`** (`pages/Downtimes/index.jsx:73`) — flag-gated fallback; dead when `REFDATA_ANALYTICS_ENABLED` is on (staging), live on prod default.

### refdata already serves everything (nothing to build for the bootstrap)
`GET_VARIABLES_CONTEXT`'s 6 Hasura root fields all have Cognito-aware refdata twins:

| front4 root field | refdata dataset/route | Note |
|---|---|---|
| `v_entities_per_user_role` | dataset `entities-per-user-role` | MINUS the `enterprise` blob (get `nm_enterprise` from `enterprise-config`) |
| `enterprises` | dataset `enterprise-config` | **omits `api_key` by design** → see write-plane coupling |
| `user_roles` | dataset `user-roles` | permissions |
| `users` | dataset `users` | + nested `language_pack_desktop` via route `/v1/language-packs` |
| `v_menu_per_user_role` | dataset `menu-per-user-role` | |
| `shifts` | dataset `shifts` | purpose-built for this bootstrap shape |

refdata is a Cognito relying party (`auth_cognito.go`, `COGNITO_AUTH_ENABLED` default ON) — derives `customer_id` + `id_user_role` server-side. This is exactly why it serves a Cognito user where Hasura cannot.

### The load-bearing coupling: `api_key` → edge-api writes
`GET_VARIABLES_CONTEXT` is the **only** source of `enterprises[0].api_key` (`VariablesContext.jsx:69` → in-memory `apiKey.js` → sent as `x-api-key` to edge-api on **every** PO/downtime/target write). refdata never returns `api_key`. So migrating the read **breaks all writes** unless edge-api takes the Cognito bearer instead.

**Good news — the write plane is already built.** edge-api has the dual Firebase/Cognito Bearer verifier (ADR-0033: `src/shared/auth/jwks-bearer-jwt-verifier.ts`; auth.middleware verifies a Cognito bearer, resolves the tenant via the cognito column, stamps `callerEnterpriseId`, TenantFence honors it). It is flag-gated (`EDGE_API_COGNITO_AUTH_ENABLED`). So the switch is: front4 sends `Authorization: Bearer <token>` to edge-api writes (drop `x-api-key`), and we enable the flag on prod.

### Ordered plan (W1)
1. **edge-api writes accept the bearer** — flip front4's write dialogs from `x-api-key` to `Authorization: Bearer <getAuthToken()>` (10 call sites: ProductionOrders/Table, Downtimes/DialogEdit + split/split-manual/unjustified, Settings/Targets ×3, Settings/PO/DialogDelete). Enable `EDGE_API_COGNITO_AUTH_ENABLED` on prod. Retire `apiKey.js`/`setApiKey`. **Do this first (or atomically) — else step 2 kills writes.**
2. **Migrate `GET_VARIABLES_CONTEXT`** in `VariablesContext.jsx` to a refdata fan-out (6 datasets + language-packs route), reassembling the same `data1` shape the `onCompleted` selectors read. Drop the now-dead `api_key` selector. **This stops the white page.**
3. **Repoint the 3 breadcrumbs** (`Breadcrumb/components/{site,area,line}.jsx`) off `useQuery(GET_VARIABLES_CONTEXT)` → read from `VariablesContext` (they already `useContext` it).
4. **Flip `REFDATA_ANALYTICS_ENABLED` on prod**, then delete the `DOWNTIME_QUERIES` Hasura fallback.
5. **Retire `services/api.js` reads** → refdata (mostly exist; net-new datasets only for `/api/admin/pages`, `/api/production/health`, `/infra-events/plc/current-status`). Move its writes → edge-api.
6. **Delete `services/graphqlConnection.js`** + the ~119 dead `gql` constants. Hasura + Firebase are now unreferenced by front4.

Each step is independently shippable and reversible (flags). Step 1+2 = the login fix.

---

## W2 — Embedded self-service BI

> **DECISION (2026-08-07): the tool is Apache Superset, not Metabase.** Metabase's
> self-service authoring + per-tenant isolation require **Enterprise licensing**,
> judged **infeasible**. Superset delivers the same capability **free**
> (Apache-2.0, self-hosted) — at the cost of heavier ops (Redis + Celery + its own
> metadata DB) and per-user Cognito-OIDC accounts for authoring. **Full design:
> `docs/plans/w2-embedded-superset.md`** + scaffolding in `db/superset/*` and
> `configs/superset/*`. The superseded Metabase design is retained for reference
> at `docs/plans/w2-embedded-metabase.md`.

**Requirement:** factory customers **build their own reports** AND view curated OEE. That rules out native-charts-only and Grafana; it's **Metabase vs Superset** (self-service authoring, embedded, multi-tenant, self-hosted, TimescaleDB, Cognito-aligned).

**Recommendation: hybrid (tool = Superset).**
- **Curated flagship OEE** → keep native in front4 (refdata + ECharts/Tremor) — best UX, Cognito-scoped, your design.
- **Self-service "build your own"** → **embedded Superset** (chosen).
  - **Metabase** (NOT chosen): best non-technical authoring UX, but **interactive embedding + data sandboxing** are a **paid** Enterprise tier → licensing infeasible.
  - **Superset** (chosen): same capability **free** (Apache-2.0); external-user authoring = provision them via **Cognito OIDC SSO + a custom security manager + per-tenant RLS**; heavier ops (Redis/Celery/metadata DB). This is the deliberate trade the license decision bought.

**Multi-tenant embed:** Superset connects to TimescaleDB; tenant isolation comes from the **Cognito identity**, enforced by **Superset Row Level Security** on TWO surfaces — a **guest token** (edge-api mints it with an `id_enterprise` RLS clause) for **viewing**, and a **role-bound RLS filter** (the custom security manager binds it from the Cognito claim) for **authoring**. Belt-and-suspenders: **Postgres native RLS** keyed on a session GUC (`SET app.tenant_id`) as a fail-closed DB backstop (under Superset's single pooled connection it's a backstop, not a co-enforcer — Superset RLS is primary).

**New components:** Superset web **+ Celery worker + Redis + its own metadata DB** (Superset needs all four); a **Cognito-aware guest-token-minting endpoint** in edge-api (`POST /api/superset/guest-token` — refdata is read-only and cannot mint); **Cognito OIDC** as Superset's auth provider (Flask-AppBuilder `AUTH_OAUTH`) + a **custom security manager** mapping the Cognito `id_enterprise` claim → a per-tenant Superset RLS filter; per-tenant RLS rules.

---

## W3 — Import the existing PowerBI dashboards

**Reality check: there is NO `.pbix` → Metabase/Superset importer.** PowerBI's DAX measures, Power Query (M), and visual definitions have no clean target-tool equivalent. Migration = **structured re-creation**. But most of the value is portable because the reports read the **same Postgres/TimescaleDB**.

### What's portable vs rebuilt
| PowerBI asset | Fate |
|---|---|
| Power Query (M) source queries | **Portable** — they resolve to SQL against Postgres; lift into refdata datasets or BI-tool models |
| DAX measures | **Re-express** as SQL / Metabase metrics / Superset dataset columns (semantic, 1:1 logic) |
| Data model (tables, relationships) | **Portable** — maps to your schema; re-declare in the tool |
| Report pages / visuals / layout | **Rebuilt** manually, visual by visual |

### Extraction toolchain (read the existing reports)
- **`pbi-tools`** (open-source) — decompiles a `.pbix` into source (model + layout JSON) for diffing/inspection.
- **DAX Studio** / **Tabular Editor** — export the DAX measures and the model.
- A `.pbix` is a ZIP: the `DataModel` part holds the tabular model; `Report/Layout` holds the visuals.

### Process
1. **Inventory** every PowerBI report in use (via back4 `/getEmbedToken` `reportId`s + the PowerBI workspace). Rank by usage.
2. For each: extract source queries + DAX (toolchain above), map tables to the Postgres schema.
3. **Recreate the dataset/model** in the target BI tool (or as a refdata dataset if it becomes a curated front4 view).
4. **Rebuild the visuals**; validate output numbers against the live PowerBI report (parity check).
5. Migrate highest-usage first; the rebuilt reports become the **curated seed set** customers then extend with self-service.

### Interim (don't block on the full migration)
front4's PowerBI embed (`pages/ReportsPowerBi/index.jsx`) gets its token from **back4 `/getEmbedToken`** (Azure service principal, minted server-side — good, no browser token). Under Cognito it breaks **only if back4's verifier rejects the Cognito issuer**. So: **teach back4 to accept Cognito** (same dual verifier as edge-api/refdata) → PowerBI keeps working during W3, then is decommissioned when its reports are migrated. This is a back4 item, tracked separately; it does **not** block W1.

---

## Sequencing across workstreams
- **W1 is the critical path** (fixes the white page + Cognito login). Ship it independently, now.
- **W2** tool is **decided: Superset** (Metabase license infeasible) — design in `docs/plans/w2-embedded-superset.md`; scope/build in parallel, no dependency on W1.
- **W3** depends on W2 (need the target tool). Interim = back4-accepts-Cognito keeps PowerBI alive so nothing regresses.
- **Cannot move to refdata:** all writes → edge-api (built); PowerBI token minting → back4/new service; `POST /api/users/external` login provisioning → edge-api/auth.

## Open decisions for the user
1. **BI tool:** ~~Metabase vs Superset~~ **DECIDED → Superset** (Metabase Enterprise licensing infeasible). Remaining W2 sub-decisions live in `docs/plans/w2-embedded-superset.md` §6.3 (accept the authoring-integration cost; tenant-claim shape; authoring-RLS strategy; Postgres-RLS topology).
2. **Curated OEE:** keep native in front4, or also move into the BI tool?
3. **W1 go:** implement steps 1–2 (edge-api bearer flip + `GET_VARIABLES_CONTEXT`→refdata) as the first PR to kill the white page?
