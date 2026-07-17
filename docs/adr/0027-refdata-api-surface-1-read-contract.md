# ADR-0027 — refdata-api Surface-1: the curated, tenant-safe read contract

**Status:** Proposed · **Date:** 2026-07-16 · **Companion to:** [ADR-0026](0026-api-layer-consolidation.md) (API-layer consolidation — answers its Open Question 1, "the saved-view mechanism's shape") · **Builds on:** [ADR-0015](0015-customer-facing-query-api.md) (composable query API — this realizes its P3 "saved views"), [ADR-0021](0021-multitenancy-model.md) (server-side `customer_id` injection as the single tenant-isolation authority) · **Relates to:** [ADR-0018](0018-operator-frontend-integration-makeover.md) (operator is the live consumer of the legacy `/v1/*` routes; front4 re-point is its Phase F), [ADR-0023](0023-concurrent-po-across-lines.md) (parity views become read endpoints), [ADR-0002](0002-firebase-auth-emulator-staging.md) (the Hasura auth glue this replaces) · **Decision owner:** tech-lead + product (pending).

---

## 1. Context — what already exists, and the hole in it

`refdata-api` is **not** a greenfield skeleton. It is a ~1,000-line Go service, a green CI target (`.github/workflows/go-services.yml`, matrix `refdata-api — vet/test/build`), and it is deployed in `compose.staging.yml` (port 9104, reads the main `packiot` DB through `pgbouncer`). It was born as ADR-0015's "Option C" (custom Go read API) to retire Hasura's read role. Today it serves **two generations of routes that do not share a security model** — and that split is the whole subject of this ADR.

### Generation A — the legacy fixed `endpoints` table (`cmd/refdata-api/main.go`)

Eleven routes, registered directly on the mux via `makeHandler`, each a hardcoded SQL string:

| Route | Backing object | Tenant scoping |
|---|---|---|
| `/v1/events-timeline?topics=` | `h_piot_get_events_timeline3_with_event_id($topics)` | **client-supplied topic vector** |
| `/v1/pending-downtime?topics=` | `h_piot_get_equipment_pending_downtime_with_event_id($topics)` | **client-supplied topic vector** |
| `/v1/shift-hours?topic=` | `piot_get_shift_hours_by_packml_topic_2($topic)` | **client-supplied topic** |
| `/v1/shift-hours-by-enterprise?topic=&enterprise=` | `piot_get_shift_hours_by_enterprise_packml_topic_2($topic,$enterprise)` | **client-supplied enterprise id** |
| `/v1/day-week-begin?topic=` | `piot_get_day_week_begin_by_packml_topic($topic)` | **client-supplied topic** |
| `/v1/operator-po-list` | `SELECT * FROM v_operator_po_list_setup_4` | **none — all tenants** |
| `/v1/operator-po-details` | `SELECT * FROM v_operator_po_details_3` | **none — all tenants** |
| `/v1/operator-entities` | `SELECT * FROM v_operator_entities_2` | **none — all tenants** |
| `/v1/entities-per-user-role` | `SELECT * FROM v_entities_per_user_role_operator` | **none — all tenants** |
| `/v1/language-packs` | `SELECT * FROM language_packs` | none (global reference — acceptable) |
| `/v1/downtime-reasons?topics=` | `equipments JOIN packml_register … WHERE packml_topic = ANY($topics)` | **client-supplied topic vector** |

**`makeHandler` calls no auth function at all.** These routes are unauthenticated and their scope is whatever the client puts in the query string. `main_test.go` even asserts the shape of that hole: `topicEnterpriseArg("…?topic=T&enterprise=3")` is a *tested contract*. A fourth variant hides in `GET /v1/screen-config` (`query.go`): it checks that the key exists but keys `user_screen_config` by `id_user`/`screen` only — it never scopes the read to the resolved `customer_id`, so a colliding `id_user` across tenants reads across the boundary.

This is the exact structure the **`[SECURITY-verify] refdata-api legacy read routes bypass tenant isolation`** task flags — unscoped `SELECT *`, a client-supplied enterprise id, and a topic vector — three variants of the same anti-pattern: **the client names the tenant.** (Naming note: the task-launcher's shorthand "#57" refers to *this* security task from the #54 refdata-design lens, **not** GitHub issue #57, which is an unrelated — and merged — `mirror-worker-go` id-order fix. This ADR closes the security task; I use "the isolation task" for it below.) Concrete sites, for the implementers:

- `main.go:91-93` — `SELECT * FROM v_operator_*` with no `WHERE` (all tenants).
- `main.go:67-78` + `:89` — `topicEnterpriseArg`, the client-supplied `?enterprise=`.
- `main.go:51-65` + `:86-90,96-98` — topic/`?topics=` routes; `packml_topic` is globally unique, so a caller can name another tenant's topic.
- `query.go` `/v1/screen-config` GET — keyed by `id_user`/`screen`, not scoped by the resolved `customer_id`.

The isolation task's own STEP 1 notes this is a *live* leak only if refdata-api is internet-exposed to multiple tenants; today it is internal-only (`compose.staging.yml`), so this is "fix before external exposure," not "actively bleeding." Surface-1 is that fix.

### Generation B — the composable query API (`cmd/refdata-api/query.go`, `datasets.go`)

`registerQueryAPI` mounts `POST /v1/query`, `GET /v1/catalog`, `GET/PUT /v1/screen-config`. This generation is **already correct**:

- `parseAPIKeys(QUERY_API_KEYS)` builds a `map[apiKey]customerID`; `auth(r)` resolves `X-Api-Key` → `customerID` and every handler rejects an unknown key with `401`.
- `compile` / `compileDataset` take `customerID` as a Go parameter and **inject it as `$1`**; the request body cannot move it. `datasets.go` has ~35 named, allowlisted datasets, each with `pEnterprise` as its first parameter.
- `cmd/refdata-api/tenancy_isolation_test.go` enforces this **structurally at CI**: every dataset's `params[0]` must be `pEnterprise`, it must appear exactly once, the SQL must reference `$1`, and the compiled SQL must be byte-identical across two different tenants (only the bound arg differs). A dataset that leaks across tenants fails to merge.

**The core finding:** refdata-api already contains the correct injection authority (Generation B) and a working proof-of-isolation gate. The problem is that Generation A predates it and bypasses it. **Surface-1 is not "build tenancy" — it is "make Generation B's authority the *only* door, and re-home Generation A behind it."**

---

## 2. The core invariant — single injection authority

> `X-Api-Key` → `customer_id` → `$1`. The client never supplies a tenant, enterprise, or customer id in path, query, or body. The server derives it from the key and binds it as the first query parameter of every read.

### Why this is structural, not procedural

The #57 hole and the correct pattern differ by *where the tenant comes from*:

```
#57 (Generation A):   tenant := request.query["enterprise" | "topics"]   // attacker-controlled
Surface-1 (Gen B):    tenant := keymap[request.header["X-Api-Key"]]      // server-controlled, per-credential
```

Once the tenant is a **server-derived value bound as `$1`**, a cross-tenant read is not "prevented by a check" — it is **unrepresentable**. There is no request field that carries a tenant, so there is nothing for an attacker to tamper with. Every dataset's SQL is written `WHERE id_enterprise = $1` (or scoped through the `equipments` hierarchy to `$1`), and `$1` is *always* the authenticated caller's id. This is the property `tenancy_isolation_test.go` mechanizes: same request body + two keys ⇒ same SQL, different `$1`, disjoint rows.

### Where the resolution lives, and how it fails closed

- **Resolution site:** a single `auth(*http.Request) (customerID int, ok bool)` chokepoint, applied as **middleware in front of the whole mux** (today it is called per-handler in Generation B and *not at all* in Generation A — Surface-1 promotes it to a wrapper that no route can skip). Reads inject the resolved `customerID` via `request.Context()`.
- **Fail-closed rules (all already the behavior in Generation B; Surface-1 makes them universal):**
  1. No `X-Api-Key` header ⇒ `401`, no DB touch.
  2. Key not in the map ⇒ `401`, no DB touch. (An empty/malformed `QUERY_API_KEYS` yields an empty map ⇒ *everything* 401s. Failure of the credential source denies all access; it never falls through to "no filter.")
  3. A route handler that reaches the DB **without** a resolved `customerID` in context is a bug the middleware makes impossible — there is no code path from an unauthenticated request to a query.
- **Global reference data** (`language_packs`) is the one deliberate exception: it is tenant-independent i18n. It is served read-only and carries no tenant column; it is explicitly enumerated, not a general "unscoped is OK" carve-out.

### The key→customer_id source of truth (open decision, see §6)

Today the map is `QUERY_API_KEYS="stg-cpack-key:3,stg-sim-key:2,stg-incoplast-key:4"` — a static env parsed once at boot. ADR-0020 already flagged the fragility: **the enterprise id is hardcoded as a literal, positional to seed order**, and ADR-0021 mandates resolving `id_enterprise` from the DB by name rather than baking the number. Surface-1 keeps the env map as the v1 mechanism (it is fail-closed and simple) but **specifies the target**: a keyed lookup against a `customer_api_keys` table (hashed key → `id_enterprise`), cached in-process with a short TTL and a fail-closed miss. This removes the hardcoded id, makes onboarding a tenant a DB insert (not a redeploy), and keeps the hot path a memory read. This is the standing "no hardcoded enterprise ids" directive applied to the credential layer.

---

## 3. Surface-1 — the curated read contract

**Scope.** Surface-1 is the first curated read set that lets front4 stop querying Hasura directly with an admin secret. It is **~37 reads total**: **~24 already covered** by refdata-api Generation B (datasets.go) / edge-api, which Surface-1 *adopts and hardens* under the single authority, plus **~13 net-new** reads front4 needs that no service serves safely today. Design rules for every Surface-1 endpoint:

1. **Read-only.** `GET` for fixed reads; `POST /v1/query {dataset,…}` for the parameterized datasets (body is a *filter*, never SQL, never a tenant).
2. **Projection-shaped, never raw tables.** Explicit column lists; secrets and auth-provider internals stripped at the projection (`enterprises` minus `api_key`; `users` minus `operator_pw_hash`, `id_user_firebase`). No `SELECT *` on a base table reaches the wire.
3. **Tenant-injected.** `$1 = customer_id` from the key. Per-equipment functions that take only an equipment id are wrapped in an ownership guard: `… WHERE EXISTS (SELECT 1 FROM equipments e WHERE e.id_equipment = $2 AND e.id_enterprise = $1)` (the existing `perEquipment` helper).
4. **Bounded.** Windowed datasets carry per-dataset max-window budgets; every compiled SQL gets the shared row cap appended; `statement_timeout` on the pool.

### 3a. The ~24 already-covered reads (adopt + harden)

These exist in `datasets.go` today and already satisfy the invariant — Surface-1 *keeps* them and folds the eleven Generation-A routes into the same model (see §4). Grouped by front4 screen:

| Front4 screen | Datasets (already tenant-scoped in `datasets.go`) |
|---|---|
| OEE dashboards | `oee-score-teams`, `oee-score-full`, `oee-progress` |
| Mission control | `mission-control`, `mission-control-area`, `mission-control-timeline` |
| Equipment overview (per-equipment, ownership-guarded) | `overview-job-info`, `overview-events`, `overview-production-chart`, `overview-production-health`, `overview-downtimes-by-category` |
| Downtime analytics | `downtimes-summary`, `downtimes-per-category`, `downtimes-events` |
| Production analytics | `total-production`, `single-period`, `machine-speed`, `production-flow` |
| Targets | `targets`, `production-targets`, `scrap-targets`, `oee-targets` |
| Config | `enterprise-config`, `users`, `user-roles` |

(Legacy-generation duplicates — `overview-events-legacy`, `single-period-legacy`, etc. — are retained only until front4 confirms it consumes the live generation, then dropped.)

### 3b. The ~13 net-new reads front4 needs

Census (front4-lens, `front4/src` grep vs `datasets.go`). front4 today issues these as **Hasura GraphQL directly** (no service in between); none are served by refdata-api yet. Each becomes a `pEnterprise`-first dataset (body carries filters only, `$1` = customer_id):

| # | front4 caller / screen | Backing object | Notes |
|---|---|---|---|
| 1 | Home | `h_piot_home_uns` | landing rollup — new dataset |
| 2 | Downtimes / EventsTab | `h_piot_get_events_timeline_full_with_filter_3` | **distinct fn** from the legacy route's `…3_with_event_id` — different generation |
| 3 | Downtimes split dialogs | `h_piot_get_events_timeline_from_po` | PO-scoped event timeline |
| 4 | Production Orders list | `h_piot_production_orders_with_runtimes6` | PO + runtime join, live generation |
| 5 | Production Orders (older gen) | `h_piot_production_orders_runtimes` | retire once #4 confirmed the only consumer |
| 6 | Header user chip | `piot_username` | user display name |
| 7 | Menu / nav authz | `v_menu_per_user_role` | refdata only has `v_entities_per_user_role_operator` today |
| 8 | Older Overview screens | `h_piot_overview_production_chart` | non-`v6`, non-`_i_` variant — **verify** front4 still calls it before adding |
| 9 | Dropdowns / Breadcrumb | `equipments` (hierarchy) | **project, do not expose raw** — a scoped `entities` projection, not `SELECT *` |
| 10 | Breadcrumb | `sites` | same — scoped projection |
| 11 | Filters | `shifts` | same — scoped projection |
| 12 | Settings → Production Orders | `production_orders` | same — scoped projection |
| 13 | Scrap computation | `scrap_calc` / scrapCalc | enterprise scrap-calc config read |

**Uncertainty flagged:** rows 8–13 are best-effort from grep; 9–12 are raw-table reads front4 does directly today and **must not** be re-exposed as raw tables — they become explicit projections joined to `$1` (a `hierarchy`/`entities` dataset), which is also what finally lets front4 drop its browser-side `api_key` (see §3, below). Confirm the exact set against front4's live query files at implementation time; the *count* may shift by ±2, the *structural rule* does not.

**Why this is urgent, not cosmetic:** front4 today reads Hasura directly with the enterprise `api_key` shipped to the browser **and a hardcoded `in_id_enterprise: 31`** in `front4/src/pages/OverviewV6/index.jsx`. That is the #57 anti-pattern on the *client* side — a literal tenant id and a tenant secret in front-end code. Surface-1 is what removes both: front4 sends only its `X-Api-Key`, the server derives the tenant, and no enterprise id or admin secret ever reaches the browser. (This also discharges the standing "no hardcoded enterprise ids" directive at the front4 boundary.)

### 3c. Endpoint contract shape (worked example)

Every Surface-1 read compiles to the same wire shape. A representative net-new endpoint, expressed as it will land in the `datasets` registry:

```go
// POST /v1/query  {"dataset":"live-equipment-metrics","filters":{"equipments":[…]}}
"live-equipment-metrics": {
    group: "live-uns-equipment",
    doc:   "Live equipment state/speed/status snapshot",
    // $1 is ALWAYS the authenticated customer_id — the client's filter
    // can only narrow WITHIN the tenant, never widen past it.
    sql: `SELECT id_equipment, status, speed, ts_value
            FROM uns_equipment_current_metrics
           WHERE id_enterprise = $1
             AND (cardinality($2::int[]) = 0 OR id_equipment = ANY($2::int[]))`,
    params: []dsParam{pEnt, ids("equipments")},
},
```

Response: a JSON array of row-objects (pgx field descriptions → column names) — the same shape front4 gets from Hasura's data root, minus the GraphQL envelope. **No cursor into raw tables, no arbitrary column selection, no join the catalog did not pre-authorize.**

---

## 4. Closing #57 — the re-homing of Generation A

The eleven legacy routes are not deleted (front4/operator/edge-node-red consume several); they are **migrated behind the authority**:

| Legacy shape | Surface-1 replacement |
|---|---|
| `?enterprise=3` (client names tenant) | **removed** — tenant is `$1` from the key. `shift-hours-by-enterprise` collapses into `shift-hours` (the enterprise is implicit). |
| `?topics=a,b,c` (client names a topic vector) | topic becomes a **filter within the tenant**: the query joins `packml_register` and adds `AND id_enterprise = $1`, so a topic the caller doesn't own returns zero rows instead of another tenant's data. Cardinality-0 = "all my topics," never "all tenants' topics." |
| `SELECT * FROM v_operator_*` (no scope) | re-expressed as tenant-scoped datasets: either the view gains an `id_enterprise` predicate (`… WHERE id_enterprise = $1`) or it is read through the `equipments`/`entities` hierarchy joined to `$1`. `operator-po-list`, `operator-po-details`, `operator-entities`, `entities-per-user-role` each become a `pEnterprise`-first dataset. |
| `/v1/screen-config` GET keyed by `id_user` only | add `AND id_enterprise = $1` (from the key) to both the read and the upsert; a saved layout becomes tenant-private, same as `saved_views` in §5. |
| unauthenticated `makeHandler` | all routes behind the `auth` middleware; no route reaches the DB without a resolved `customer_id`. |

**The live consumer is the operator SPA, not front4.** front4 does not call refdata-api yet (that is ADR-0018 Phase F). The eleven legacy routes are consumed *today* by the **operator** PWA, which runtime-caches `GET /v1/*` (`operator/pwa.config.js`, `REFDATA_CACHE_NAME='refdata-v1-reads'`) and cuts over live at ADR-0018 wave 3 (nginx `/v1/* → refdata`). So the re-homing in this table has a real consumer with a real cache: the migration must keep each route's **response shape** stable (the operator caches by URL) even as the *scoping* changes underneath. This is the coordination seam with the operator team — a re-homed route that drops or renames a field breaks a cached kiosk screen. `/v1/query` and `/v1/catalog` (the safe surface) have **zero** consumers today, so the net-new datasets (§3b) carry no such constraint.

**CI gate extension (the enforcement):** `tenancy_isolation_test.go` today only guards the `datasets` map. Surface-1 extends the gate to the *entire* route table — a test that fails the build if any registered read (a) is reachable without `auth`, or (b) issues SQL that does not bind the server-derived tenant to `$1`. That converts "#57 is fixed" from a claim into a **checked, non-regressable property** — the same discipline that made the datasets isolation-safe, now applied to the legacy surface that lacked it.

---

## 5. The saved-view mechanism (answers ADR-0026 OQ1)

Retiring Hasura removes front4's "I just want to see this thing I built" capability. Surface-1 restores it **without** restoring arbitrary SQL. ADR-0026 enumerated three shapes; this ADR **decides**:

> **A registry of named, server-defined, parameterized views — NOT a client SQL DSL, NOT a re-stood-up Hasura for customers.** A saved view is a *reference to an allowlisted dataset plus a frozen set of filters/window*, owned by a `(customer_id, user)`, executed through the exact same injection authority as an ad-hoc dataset call.

### Storage model

```sql
CREATE TABLE saved_views (
  id_saved_view  bigserial PRIMARY KEY,
  id_enterprise  int  NOT NULL,          -- the owning tenant (server-set from the key, NEVER the body)
  id_user        text NOT NULL,          -- the author
  name           text NOT NULL,
  dataset        text NOT NULL,          -- MUST be a key in the datasets registry (FK-in-spirit, validated at write)
  filters        jsonb NOT NULL,         -- the same {filters} a POST /v1/query body carries — filters only
  window_spec    jsonb,                  -- {from,to} or a relative window ("last_30d"); NULL for non-windowed datasets
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id_enterprise, id_user, name)
);
```

This is the same table family as the existing `user_screen_config` (P2) — a small, refdata-owned config table, created by `ensureSchema` at boot.

### Execution — safe by the same construction

- **Save:** `POST /v1/saved-views {name, dataset, filters, window}`. The server validates `dataset ∈ registry`, validates `filters` against that dataset's allowlisted filter keys (the exact `compileDataset` validation), rejects unknown keys, and stores the row with `id_enterprise = $customer_id` from the key. **The client cannot store a tenant id or raw SQL — the columns for those do not exist; `dataset` is an enum, `filters` is a validated bag.**
- **List/read:** `GET /v1/saved-views` → only rows `WHERE id_enterprise = $1 AND id_user = $auth_user`. A saved view is invisible to other tenants and other users.
- **Execute:** `POST /v1/saved-views/{id}/run` → load the row *scoped to `$1`* (a view id belonging to another tenant simply isn't found → `404`), then feed its stored `dataset`+`filters`+`window` into the **same `compileDataset` path** an ad-hoc query uses. `customer_id` is re-injected as `$1` at execution time from the *current* caller's key — a saved view carries no ambient authority; it is re-scoped to whoever runs it.

### Why this shape and not the others

- **Not a client SQL/query DSL:** any string the client controls that reaches SQL re-opens an injection surface and re-couples consumers to the schema — the precise thing ADR-0023/ADR-0026 spend their blast-radius budget avoiding. A saved view stores a *dataset name + filters*, so its power is exactly the catalog's power — no more.
- **Not a per-customer Hasura:** that is a second isolation system to keep in sync — the original sin ADR-0026 retires Hasura to escape. A saved view runs through the *one* authority.
- **It fails closed:** unknown dataset, unknown filter key, out-of-enum value, or a foreign view id all reject before any query runs; a malformed stored row cannot widen past `$1`.

**Net:** front4 retires its Hasura admin-secret habit — ad-hoc exploration becomes "compose a dataset," and "save the thing I built" becomes a `saved_views` row — with tenant isolation intact on both paths.

---

## 6. Sequencing, risks, rollback

**Delivery order (this ADR is design; these are the implementation steps and owners):**

| Step | Work | Owner | Seam |
|---|---|---|---|
| 1 | Promote `auth` to whole-mux middleware; add the context-injected `customer_id` | backend-dev | — |
| 2 | Extend `tenancy_isolation_test.go` to gate the *entire* route table (fail build on unauth'd or unscoped read) | qa | must land **with** step 1 or the legacy routes fail immediately (intended) |
| 3 | Re-home the 11 Generation-A routes as `pEnterprise`-first datasets; drop `?enterprise=`/`?topics=` | backend-dev + dba (view `id_enterprise` predicates) | dba confirms each `v_operator_*` view scopes to `$1` without changing OEE semantics; **operator team** confirms response shapes stay stable (its PWA caches `/v1/*` by URL — ADR-0018 wave 3) |
| 4 | Land the ~13 net-new datasets (from §3b census) | backend-dev | frontend-dev verifies response shape parity per endpoint |
| 5 | `saved_views` table + 3 endpoints | backend-dev + dba | — |
| 6 | Re-point front4 reads → refdata-api, per-endpoint parity vs current Hasura response | frontend-dev + qa | this is ADR-0026 step 2; **gates** Hasura stop-serving |
| 7 | Move `QUERY_API_KEYS` → `customer_api_keys` DB lookup (removes hardcoded id) | backend-dev + dba | devops-platform provisions the secret/table |

**Risks & rollback:**
- **Re-homing a legacy route wrong** (a `v_operator_*` view that can't be cleanly scoped) → the route returns fewer/zero rows. *Rollback:* the routes are additive datasets; the old handler can be kept flag-gated for one release while parity is proven, then removed. Reversible.
- **front4 re-point breaks a screen** → same-shape response is the contract; parity check per endpoint (step 6) catches it before Hasura stops serving. Hasura retirement is a *stop, not a destroy* (ADR-0026), so re-pointing is reversible by flipping front4 back.
- **Key-map DB migration** (step 7) → fail-closed by design; if the lookup errors, all reads 401 rather than leak. Roll back to the env map.
- **Blast radius:** reads only. No OEE math, no writes, no gate/audit path touched — this surface cannot corrupt a factory's numbers, only fail to serve them.

---

## 7. Open questions (need a decision)

1. **Key→customer_id source (§2):** ship Surface-1 on the existing static `QUERY_API_KEYS` env and do the `customer_api_keys` DB-lookup as a fast-follow (step 7), or block Surface-1 on it? (Recommendation: ship on env, fast-follow the table — the env map is already fail-closed; the DB lookup is a robustness/onboarding win, not a security fix.)
2. **Per-user vs per-tenant key granularity:** today one key = one tenant, so `saved_views.id_user` and `screen-config`'s user come from a query param, not the credential. Do we need per-user API keys (key → `(customer_id, user)`), or does front4 pass an authenticated user id it already trusts from Firebase? This decides whether saved-view/screen-config user-scoping is credential-derived or app-asserted.
3. **Which generation front4 actually consumes** for the `*-legacy` datasets (overview/single-period/downtimes) — confirm before dropping the legacy-suffixed duplicates in step 3.
4. **Saved-view sharing:** is a saved view strictly private to its author, or shareable within a tenant (a team dashboard)? The table supports both (`UNIQUE(id_enterprise,id_user,name)`); the read scope in §5 assumes private. Product call.
5. **cq-logs / reports read path:** ADR-0026 retires Hasura for front4; do reporting consumers also read through Surface-1, or keep a separate internal path? (Out of Surface-1 scope; flagged so it isn't forgotten.)

---

## Appendix — files touched by this design (for the implementers)

- `services/refdata-api/cmd/refdata-api/main.go` — the Generation-A `endpoints` table + `makeHandler` (no auth) → re-home behind middleware.
- `services/refdata-api/cmd/refdata-api/query.go` — `parseAPIKeys`/`auth` (the authority) + `compile` + `screen-config` + `ensureSchema`.
- `services/refdata-api/cmd/refdata-api/datasets.go` — the ~35 tenant-scoped datasets (`pEnterprise`-first) + `compileDataset`.
- `services/refdata-api/cmd/refdata-api/tenancy_isolation_test.go` — the isolation gate → extend to the whole route table.
- `compose.staging.yml` (`refdata-api` service, `QUERY_API_KEYS`).
- `docs/adr/0015-…`, `0021-…`, `0026-…` (the decisions this sits inside).
