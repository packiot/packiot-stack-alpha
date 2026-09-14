# CS Admin — "Promote Client to Production" — Design & Implementation Plan

**Status:** Draft for review · **Date:** 2026-09-13 · **Author:** investigation + design pass
**Scope:** Read-only investigation only. Nothing in this doc was executed against production.
**Primordial rule honored:** every load-bearing claim is grounded in a code cite (`file:line`)
or a live query. Anything not verifiable is marked **[unverified]**.

---

## 0. TL;DR

CS onboards + validates a client entirely in **staging**, then promotes that client's
**onboarding configuration** to **production**. The feature turns today's manual "prod recut"
(sketched in `docs/clients/bispharma-prod-recut-runbook.md`, `cpack-newprod-seed-runbook.md`)
into a gated, diff-able, reversible one-click action.

Three findings dominate the design:

1. **Staging and prod are separate clusters *and* separate schema generations.**
   Staging `packiot_analytics` is on the **medallion schema** (`core.*` / `config.*` / `identity.*`);
   prod `packiot` is still on the **flat legacy schema** (`public.*`, and `packml_register`
   is *not yet* renamed to `topic_routing`). A promote is therefore a **cross-cluster,
   cross-schema** operation — but see finding 2.

2. **edge-api's onboarding write-path is schema-agnostic.** Every onboarding DAO writes
   **bare, unqualified** table names; schema is resolved by the connected role's `search_path`.
   Staging resolves bare `enterprises`→`core.enterprises`, `users`→`identity.users`,
   `packml_register`→`core.packml_register` (a view over `topic_routing`); prod resolves the
   same bare names to `public.*`. **This means the cleanest promote mechanism is to replay the
   config *through the prod edge-api's own onboarding endpoints*, not to copy rows cluster-to-cluster.**
   The app code already does the schema translation for free.

3. **The `core.client_descriptors` row is the config-as-data SSoT** (ADR-0045). The whole
   topology + edge config is regenerable from it. Promoting *that one JSONB row* + re-running
   `generate` + `apply-register` on the prod side reconstructs the tenant deterministically and
   idempotently — avoiding copying staging surrogate ids at all.

The feature = **(A)** promote the descriptor + the CS-authored rows the descriptor does not
cover, **(B)** never copy secrets/`api_key`/surrogate-PKs/runtime, **(C)** gate on the 8-gate
acceptance checklist being green, **(D)** dry-run + diff + reversible, **(E)** re-deploy the edge
bundle to the prod-enrolled factory box.

---

## 1. Topology — staging vs prod (proven)

| | **Staging** | **Production** |
|---|---|---|
| App box (SSM-managed) | `i-06c9547a2c7091ab7` `packiot-staging-app` `10.10.0.228` | `i-02d255a1c21fb1da3` `packiot-production-app` `10.20.0.215` |
| DB box | `i-064bb36d1c454d861` `packiot-staging-db` `10.10.10.89` (SSM Online) | `i-0bc1181ffcd9de6c7` `packiot-production-db` `10.20.10.89` (**NOT SSM-managed**) |
| App DB name | `packiot_analytics` | `packiot` |
| Schema generation | **medallion** — `core, config, identity, silver, gold, bronze, serving, customer_reports, bi, ops` | **flat legacy** — `public, bi, hdb_catalog` only |
| DB search_path | `"$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public` | `public` (default) |
| Tenants present | 9 (`Staging`, `Simulator Corp`, `CPACK-Staging`=3, `Incoplast`=4, `Bispharma`=5, `Bisnago`=119, `OPS-TEST`=120, `PACKIOT-ADMIN`=1000000, `SANDBOX-CPACK`=2000003) | 2 (`OPS-TEST`=1, `CPACK`=3) |

*Evidence:* EC2 `describe-instances` + SSM `describe-instance-information` (prod-db absent from the
managed list); staging queries via `dbq.sh`; prod queries proxied read-only through the prod app
box (`docker run --rm --network stack_packiot-net postgres:15-alpine psql -h 10.20.10.89`).
Prod DB name/host from `docker exec stack-edge-api-1 printenv DB_NAME/DB_HOST` → `packiot` / `10.20.10.89`.

**Consequences:**
- Separate VPC ranges (`10.10.x` staging vs `10.20.x` prod), separate boxes ⇒ **a promote is a
  cross-cluster copy, never a same-DB `INSERT … SELECT`.**
- The prod DB box is **not** an SSM managed instance, so prod DB reads/writes must be brokered
  through the **prod app box** (which reaches `10.20.10.89` on the docker `stack_packiot-net`).
- **Schema/name drift is real and must be handled** (§2.4). The bare-name/`search_path` trick
  (finding 2) absorbs *most* of it, but not column-level drift (see the `device_key` gotcha, §2.4).

**ID-collision proof (why remap is mandatory):**

| grain | staging range | prod range |
|---|---|---|
| `id_enterprise` | 1..2000003 (CPACK-Staging = **3**) | 1..3 (CPACK = **3**) |
| `id_equipment` | 1..(≥108) | 1..108 (64 rows) |
| `id_site` | 1..(10 rows) | 1..6 (2 rows) |

Staging `CPACK-Staging` and prod `CPACK` *both* sit at `id_enterprise=3`, and equipment id ranges
overlap. A naive surrogate-id copy would collide/clobber. **Surrogate PKs are environment-local and
must be re-minted on the prod side.**

---

## 2. What "onboarding configuration" IS — table-by-table (who-writes-it proof)

All citations below are from the **stack submodule** `edge-api` (the new-stack API; the standalone
`~/github/packiot/edge-api` checkout lacks the `edge-ssm` usecase). Onboarding DAOs write **bare,
unqualified** table names (grep of `edge-api/src/data/DAO` shows zero schema-qualified INSERT/UPDATE
and zero `search_path` set) — so the same SQL lands in `core.*`/`config.*`/`identity.*` on staging
and `public.*` on prod.

### 2.1 INCLUDE — CS-authored config (promote these)

| Table (staging→prod) | CS-authored columns | Auto / defaulted (do NOT copy) | Who-writes-it proof |
|---|---|---|---|
| `core.enterprises` → `public.enterprises` | `nm_enterprise, timezone, week_begin, day_begin, week_size, scrap_calc_type, active, logo_url` | **`api_key = randomUUID()`**, `id_enterprise` (serial) | `create-enterprise.service.ts:17`; DAO `enterprises-dao.ts:69-72` |
| `core.sites` → `public.sites` | `nm_site, week_begin, day_begin, week_size, timezone, language_tag, active`, FK `id_enterprise` | `id_site` (serial) | `create-site.service.ts:14`; `sites-dao.ts:15-26` |
| `core.areas` → `public.areas` | `nm_area, week_begin, day_begin, week_size, active`, FKs `id_enterprise, id_site` | `id_area`; **never CS-set:** `id_infeedcounter, id_outfeedcounter, id_rejectscounter` | `create-area.service.ts:13`; `areas-dao.ts:22-32` |
| `core.equipments` → `public.equipments` | ~16 CS cols via `equipmentFormToApi` (`tp_equipment, nm_equipment, cd_equipment, stop_threshold_time, production_speed, ideal_speed, minimum_(ideal_)performance_threshold, require_downtime_reason, event_should_be_displayed, status_type, net_production_type, overview_events_type`, cond. `id_parentequipment, id_equipment_status_mirror`) | `id_equipment`; server-managed line roles `lead_machine, gross_machine, scrap_machine, position` (apply-line-meters path); ~25 cols NULL at create | `create-equipment.service.ts:13`; `equipments-dao.ts:40-74`; csadmin `equipment.ts:31-70` |
| `core.shifts` → `public.shifts` | `cd_shift, sequence_position`, FKs `id_enterprise, id_site?, id_area?` | `id_shift`; UI never sends `id_equipment, begin_time, end_time` | `create-shift.service.ts:12`; `shifts-dao.ts:35-52`; csadmin `shifts.ts:59-65` |
| `core.shift_hours` → `public.shift_hours` | `cd_shift, begin_time, end_time (integer sec from week), day_number, day_week`, FKs | `id_shift_hour`; **excluded (OEE engine):** `shift_size, duration, id_equipment` | `create-shift-hour.service.ts:12`; `shift-hours-dao.ts:19-35` |
| `core.client_descriptors` → `public.client_descriptors` | `tenant_code`, `descriptor` (JSONB — the config-as-data SSoT incl. `.plc`, `.equipment[]`, `.mapping`, `.canonical`, `counters_only_oee`, `onprem_offline`) | `id`, `version`, `status`, `created_by/updated_by`; derived `artifacts, validation` | `upsert-descriptor.service.ts:20`; `client-descriptor-dao.ts:16-42`; **`ON CONFLICT (id_enterprise) DO UPDATE`** |
| `core.topic_routing` (`core.packml_register` view) → `public.packml_register` | CONFIG cols only: `packml_topic, mqtt_topic, id_equipment, id_site, id_area, id_enterprise, id_unit, active(=true), attributed, device_nm, line_unit_seq, device_key` | PK (`id_topic_route`/`id_packml_register`); **runtime cols excluded:** `value, signal_quality, ts_quality, sparkplug_json, timestamp` | generated by `apply-register.service.ts:32-63`; SQL from `sparkplug-decoder …/clientdescriptor/generate.go:315-347` (`INSERT … ON CONFLICT (packml_topic) WHERE active DO NOTHING`) |
| `identity.users` → `public.users` | `user_email, user_name, id_enterprise, user_roles, active, internal_user` (+cognito path adds `id_user_cognito`) | `id_user`; **never copy `id_user_cognito` (per-pool) / `id_user_firebase`**; `operator_pw_hash` set separately | `create-user.service.ts:17`+`users-dao.ts:53-69`; cognito path `cognito-users.service.ts:105-145`+`cognito-users-dao.ts:31-39` |
| `identity.user_roles` → `public.user_roles` | `nm_user_role`, `permissions`, `super_user` | `id_user_role`; UNIQUE `(id_enterprise, nm_user_role)` | `user-roles-dao.ts:44-53` |
| `config.language_packs` → `public.language_packs` | `language_tag`, 5 JSONB packs | **`id_language_pack = MAX(id)+1`** (env-local); **GLOBAL table — not tenant-scoped, promote with care** | `language-packs-dao.ts:55-62` |

**Optional / data-load (decide per policy — not strictly "config"):**
`core.clients`, `core.product_families`, `core.products` are written by the **PO-CSV import**
path (`po-import-dao.ts:126/135/153`, all `ON CONFLICT (id_enterprise, nm_*)`), not by an
onboarding form. They are tenant catalog data, not topology. Recommend **exclude** from the
config promote (they re-populate from the customer's first prod PO import).

### 2.2 EXCLUDE — runtime / secret / computed (never promote)

| Excluded | Why | Proof |
|---|---|---|
| `enterprises.api_key` | secret; regenerated in prod via `randomUUID()` at create; edge is re-provisioned with the new key | `create-enterprise.service.ts:17`; excluded from all read paths `enterprises-dao.ts:20-33` |
| all surrogate PKs (`id_enterprise, id_site, id_area, id_equipment, id_user, id_user_role, id_language_pack`) | DB serials, environment-local, collide across clusters (§1) | serial defaults in `information_schema.columns` (live query) |
| `id_user_cognito`, `id_user_firebase` | per-pool identity; re-linked on login by `user_email` | `auth-user-dao.ts:61-70`, `auth.middleware.ts:103` |
| `topic_routing.{value, signal_quality, ts_quality, sparkplug_json, timestamp}` | live SparkPlug runtime, written by ingest, not CS | live column dump; CLAUDE.md CS-Admin DTO rule |
| `shift_hours.{shift_size, duration, id_equipment}` | OEE-engine computed | `shift-hours-dao.ts:20` omits them; CLAUDE.md |
| `core.production_targets`, `core.scrap_targets`, `equipment_runtime_1{day,week,month}` | operational planning + runtime aggregates | `production-targets-dao.ts:64-105` |
| `silver.* / gold.* / bronze.*` facts, all OEE aggregates, caggs | runtime telemetry + engine output; prod recut targets an **empty** OEE history (`cpack-newprod-seed-runbook.md:9`) | ADR-0036 medallion |
| `ops.*` (`idempotency_keys, mirror_replay_*, capture_observations`) | operational plumbing | live schema |
| box-local edge secrets (`endpoints[].host_ref = secret://…`, reader `.env` `INGEST_KEY`, `PLC_HOST_*`) | terraform/Secrets-Manager owned, per-env | `reader-bundle.ts:190-213,328-352`; `bispharma-prod-secrets-manifest.md:10-28` |

### 2.3 Natural keys (for id-remap-safe matching)

| Entity | Natural match key | UNIQUE-enforced? | Cite |
|---|---|---|---|
| enterprises | `nm_enterprise` | **No** (⚠ dedupe risk) | live `pg_constraint`: only `enterprises_pkey` |
| client_descriptors | `id_enterprise` (1 row/tenant) & `tenant_code` | UNIQUE `(id_enterprise)` | `client_descriptors_enterprise_uniq` |
| sites/areas/equipments | `nm_site` / `nm_area` / `nm_equipment`,`cd_equipment` | No | live `pg_constraint` |
| packml_register | `device_key` (tenant-prefixed, global) + `packml_topic` (partial-unique `WHERE active`) | Yes | `generate.go:302,315` |
| shifts/shift_hours | `cd_shift` | No | `create-shift-hour.dto.ts:16-21` |
| user_roles | `(id_enterprise, nm_user_role)` | Yes | migration |
| clients/products/product_families | `(id_enterprise, nm_*)` | Yes | `po-import-dao.ts` ON CONFLICT |
| users | `user_email` (cross-env), `id_user_cognito` (env-local) | partial-unique on cognito | migration |
| language_packs | `language_tag` | PK | `language-packs-dao.ts:40-42` |

### 2.4 Schema/name drift the promote must survive (proven live)

- **Table rename:** staging real table is `core.topic_routing` (PK `id_topic_route`); prod is
  `public.packml_register` (PK `id_packml_register`). Staging keeps a **view** `core.packml_register`
  (relkind `v`) so the generated `INSERT INTO packml_register` still works on staging. On prod the
  bare name hits the real `public.packml_register`. ✅ portable via bare-name resolution.
- **Column parity — enterprises:** prod `public.enterprises` column list is **identical** to staging
  `core.enterprises` (`id_enterprise, nm_enterprise, api_key, week_begin, day_begin, week_size,
  timezone, logo_url, active, basic_menu, custom_menu, language_packs, scrap_calc_type, valid_from,
  valid_to, created_at, updated_at`). ✅ no drift.
- **Column drift — packml_register (GOTCHA):** staging `topic_routing` has `device_key` (pos 21);
  **prod `public.packml_register` has NO `device_key` column.** The generator emits
  `INSERT INTO packml_register (… device_key)` (`generate.go:315`), which would **fail on prod today**.
  → prod must gain `device_key` (an expand migration) before register SQL applies, OR the generator
  must conditionally omit it. **This is exactly the class of drift the config-parity gate (§4.4) must
  detect and block on.**
- **`config.*` / `identity.*` tables all exist in prod as `public.*`** (`users, translations,
  tenant_translations, dashboard_config, label_formats, shifts, shift_hours` all present in
  `public`). ✅ names portable; column parity per-table is [unverified] beyond enterprises and
  packml_register — the parity gate must check all of them.

---

## 3. Edge config promotion

**What is CS config vs infra:**
- **Per-client CS config** = `client_descriptors.descriptor.plc` (endpoints, tag maps, canonical
  prefix) — lives **in the DB**, so it rides along automatically when the descriptor row is promoted
  (`reader-bundle.ts:843-1071`, `cpack.descriptor.yaml:145-228`).
- **Infra (already in prod)** = the single multi-tenant cloud sparkplug-agent behind
  `ingest.<env>.packiot.app` and the ingest front-door; its per-tenant profile is *generated* from
  the descriptor (ADR-0043 register-driven loader).

**But promoting the DB row is not enough — the factory box keeps its old bundle.** To land the
promoted `descriptor.plc` on the prod reader you must, after the DB promote:
1. **`POST /api/edge-ssm/deploy-bundle`** (the Go-live verb) against the **prod-enrolled** `mi-` box —
   it loads the stored descriptor (`edge-ssm.service.ts:709`), `generateReaderBundle(...)` (`:720`),
   base64-writes the files over one SSM `SendCommand`, then `compose up`. Plain `POST /deploy` only
   re-applies existing compose and will **not** re-provision the reader (`edge-ssm.ts:137-161`).
2. **Regenerate the cloud agent's tenant profile** from the promoted descriptor and ensure the prod
   `packml_register` rows are `active=true` (ADR-0051 §2: unroutable topics should alert, not drop).

**Deploy substrate (today):** ADR-0049 chooses **AWS SSM RunCommand** as the unified edge-deploy
mechanism (Hybrid Activation `mi-` box, outbound-443 only), invoked by edge-api from a csadmin
"Deploy" button — **proposed, proven end-to-end live 2026-08-27, pending user sign-off**
(`0049-…:2,40,70-88,94,96`). The GitHub self-hosted-runner path (ADR-0005) is retired for the
new-stack edge. **Preconditions for prod edge promotion:** the prod factory box must already be
enrolled as a prod Hybrid Activation tagged `enterprise=<prod id>`, and box-local secrets
(`INGEST_KEY`, `PLC_HOST_*`) must be provisioned per-env (the reader `.env` is written **only if
absent** so hand-seeded secrets survive — `edge-ssm.service.ts:808-816`).

---

## 4. The mechanism

### 4.1 Design principle — replay, don't copy

Do **not** `pg_dump`/row-copy staging→prod (blocked by Hasura anyway,
`cpack-newprod-seed-runbook.md:16`). Instead **replay the config through the prod edge-api's own
onboarding endpoints**, because (a) the DAOs are schema-agnostic so schema translation is free,
(b) `api_key`/PKs/`id_user_cognito` are re-minted correctly by the create paths, (c) `apply-register`
rebuilds `packml_register` deterministically from the descriptor. The **`client_descriptors` JSONB
row is the primary promote unit**; the topology rows (enterprise/site/area/equipment/shift) are
either re-derived from the descriptor (`generate`) or replayed via their create endpoints for the
fields the descriptor does not carry.

### 4.2 UX (csadmin)

`csadmin/src/pages/onboarding` gains a **"Promote to Production"** action on a validated tenant,
guarded by `CsAdminGuard`. Flow:
1. **Pre-flight** — runs the 8-gate acceptance checklist against staging (§4.5). Red gate ⇒ button
   disabled with the failing gate shown.
2. **Dry-run / diff** — calls `POST /api/promote/plan` → renders a **promotion manifest**: every
   entity to be created/updated in prod, the id-remap table (staging id → prod id | "new"),
   secrets that will be regenerated (never shown), and a **schema-parity report** (§4.4) with any
   `MISSING`/`EXTRA` columns (e.g. the `device_key` gotcha) blocking apply.
3. **Approve & promote** — explicit confirm; irreversible steps are individually confirmed
   (matches the "USER-gated at each irreversible step" posture of the manual runbooks).
4. **Edge Go-live** — after DB promote, a **"Deploy to prod edge"** step (`/deploy-bundle`) with the
   prod `mi-` box, surfacing unresolved secret gaps as non-fatal warnings.

### 4.3 API (edge-api) — new `promote` usecase

`POST /api/promote/plan` (dry-run, **read-only both sides**)
- Snapshots the staging tenant config (descriptor + CS-authored rows, filtered to §2.1 include list).
- Connects **read-only** to prod (through the prod broker, §5), matches on natural keys (§2.3),
  builds the id-remap table and the diff.
- Runs the schema-parity check (§4.4) and the acceptance-checklist gate (§4.5).
- Returns the manifest + `apply_safe: bool`. **Writes nothing.**

`POST /api/promote/apply` (gated on a plan token from `/plan`)
- Idempotent, transactional, FK-ordered:
  `enterprises → sites → areas → equipments → shifts → shift_hours → (descriptor upsert) → apply-register → users/user_roles`.
- **Regenerate, never copy:** new `api_key` via the prod create path; new surrogate PKs; users
  matched/re-linked by `user_email`; `id_user_cognito` minted by the prod Cognito pool.
- Every write uses `ON CONFLICT (<natural key>) DO UPDATE|NOTHING` so re-apply is a no-op
  (the CPACK-seed idempotency pattern, `cpack-newprod-seed-runbook.md:37-39`).
- Tenant is created **inactive** (`enterprises.active=false`); a final explicit "activate" flips it
  on so a half-applied promote never goes live.

### 4.4 Safety, idempotency, reversibility

- **Snapshot-gated:** before any prod write, tag a rollback anchor (prod DB volume snapshot, the
  runbook's `:44` step; or a logical `pg_dump` of the affected tenant's rows). Reuse the
  `production-recut-runbook.md:61-74` rollback-point discipline.
- **Config-parity gate (generalize the F3 MANIFEST pattern,
  `production-f3-schema-assembly.md:84-90`):** capture a **normalized fingerprint of the config
  surface only** (the §2.1 tables + their columns), diff staging-shape vs prod-shape, emit
  `MISSING`/`EXTRA`, and **block apply unless the target has every column the promote writes**
  (this catches the `device_key` drift). Exclude runtime/derived columns from the fingerprint —
  the analog of the F3 gate excluding extension-owned objects (`:78-81`).
- **Idempotent:** natural-key `ON CONFLICT` everywhere; re-running `/apply` converges, never
  duplicates (⚠ `nm_enterprise` is not unique-enforced — the plan must resolve the target enterprise
  by explicit id or `tenant_code`, not by name alone, to avoid creating a second enterprise).
- **Reversible:** because the tenant lands **inactive** and the only prod mutations are the tenant's
  own new rows (never existing tenants' data), rollback = deactivate + delete the newly-minted
  ids (recorded in the apply's audit log, written via `res.locals.logData`).
- **Refuses runtime/secrets:** the include list (§2.1) is a hard allow-list in code; the plan step
  fails closed if the staging snapshot contains any excluded column with a non-default value.
- **Never clobbers prod runtime:** promote only touches config tables for the one tenant; it never
  writes `silver/gold/bronze`, `production_orders_runtime`, or another tenant's rows.

### 4.5 Approval gating — the 8-gate acceptance checklist

`docs/clients/onboarding-acceptance-checklist.md` defines **8 gates, all must be green**, the bar
being **"Bispharma-clean" = 0 clamps firing, not merely wired**. Promotion is disabled unless the
staging tenant passes all 8 (Gate 5 "counters clean / 0 clamps" is the real bar):

| Gate | Pass condition |
|---|---|
| 1 Identity & tenant | `has_key=true`, `unlinked_customer_users=0`, `authz_rows>0` |
| 2 Hierarchy | ent→site→area→equipment counts match intake; tp=3 lines have `lead_machine`; no dup area names |
| 3 Shifts | `shifts>0`, `shift_hours>0`, begin/end = integer seconds |
| 4 Topic routing | `unrouted=0`, `active_routes>0` |
| **5 Counters clean** | `neg_scrap_shifts=0`, no totalizer spike, OEE factors ∈[0,1], `bad_*=0` |
| 6 Barcode (if used) | 0 seq gaps + idempotent tenant-fenced ledger |
| 7 Historian | hot∪cold loaded, tenant-isolated |
| 8 Freshness & rollup | OEE lag within one shift; every cagg has a refresh policy |

---

## 5. Prod access model (for the plan/read side)

Prod DB (`i-0bc1181ffcd9de6c7`) is **not** SSM-managed, so the promote service cannot hit it
directly from outside. Two viable brokers:
- **Preferred (feature runtime):** run the promote endpoint on the **prod edge-api** itself
  (`stack-edge-api-1` on the prod app box), which already has a pooled connection to `10.20.10.89`
  via pgbouncer. `/plan` opens a read-only transaction; `/apply` writes through the same pool. This
  also gives the schema-agnostic bare-name resolution for free.
- **Investigation/verification (this doc):** proxy read-only SQL via SSM RunCommand on the prod app
  box → `docker run --rm --network stack_packiot-net -e PGPASSWORD=… postgres:15-alpine psql -h
  10.20.10.89 …` (creds pulled from the running container's env, never echoed). Used here for all
  prod reads; **no prod writes were performed.**

---

## 6. Phased build plan

**Phase 0 — De-risk the schema drift (blocker).** Run the config-parity fingerprint (§4.4) for
**every** §2.1 table, staging-shape vs prod-shape. Land expand migrations on prod for any `MISSING`
column (known: `packml_register.device_key`). Decide the strategic question: **promote-as-translation
(keep prod flat) vs. migrate prod to the medallion schema first** (the "forward-port gated" work in
project memory). *Everything else assumes the parity gate can pass.*

**Phase 1 — Read-only `/api/promote/plan`.** Snapshot + natural-key match + id-remap table +
diff + parity report + acceptance-gate result. No writes. Ship behind a flag. This alone is a
huge win: it productizes the manual "what would we copy?" audit.

**Phase 2 — Idempotent `/api/promote/apply` (DB only).** FK-ordered replay through create endpoints
+ descriptor upsert + `apply-register`; regenerate secrets/PKs; tenant lands inactive;
snapshot-gated + reversible; full audit log. Prove on a **shell prod tenant** (or a prod-shaped
disposable DB) with row-parity verification before any real client.

**Phase 3 — csadmin UX.** "Promote to Production" wizard: gate → dry-run/diff → approve → apply →
activate. Reuse existing `CsAdminGuard` + onboarding page shell.

**Phase 4 — Edge Go-live integration.** Wire the post-DB `/deploy-bundle` step against the prod
`mi-` box (ADR-0049), surface secret gaps, verify `packml_register.active=true` + a live-topic
smoke test. Gated on ADR-0049 user sign-off.

**Phase 5 — Hardening.** Rollback tooling (deactivate + delete minted ids), promote-history view,
re-promote (config drift re-sync) semantics, and the `nm_enterprise` non-uniqueness guard.

---

## 7. Open questions / decisions a human must make

1. **Strategic (blocker): promote-as-translation vs. migrate prod to medallion first?**
   Staging is medallion, prod is flat legacy. The bare-name/`search_path` trick makes translation
   *feasible today*, but every future schema move on staging risks a new drift. Do we (a) keep prod
   flat and translate at promote time, or (b) forward-port the medallion schema to prod first (then
   promote is pure id-remap)? This changes the whole shape of the feature.

2. **ID strategy per tenant: reuse vs. fresh id?** The runbooks support both
   (`bispharma-staging-tenant-prep.md:26-35`). CPACK collides at `id=3` in both envs. Recommend
   **always mint fresh prod ids + full remap**, resolving the target by `tenant_code`, never by
   `nm_enterprise` (not unique). Confirm.

3. **Descriptor-first vs. rows-first?** Should `/apply` (a) promote the descriptor then
   `generate`+`apply-register` to *derive* topology in prod, or (b) replay the CS-authored rows
   verbatim via create endpoints? The descriptor carries staging `id_equipment`/`id_unit` values
   (`descriptor.equipment[].id_equipment`) that won't match prod — so a descriptor-first approach
   needs an id-rewrite pass on the JSONB before apply. Decide the SSoT precedence.

4. **Scope of the config surface.** Include PO-catalog data (`clients/products/product_families`) and
   the global `language_packs`? Recommend exclude both (catalog re-imports; language_packs is shared
   and env-managed). Confirm.

5. **Edge enrollment prerequisite.** Promotion assumes the prod factory box is already SSM-enrolled
   (prod Hybrid Activation) and prod-side box secrets provisioned. Is that a manual pre-req or part
   of the promote flow? (ADR-0049 is still "proposed, pending sign-off".)

6. **Prod write authorization.** `/apply` writes prod. What approval artifact (ticket, second CS
   sign-off, checklist snapshot) is required, and is it recorded in the `identity.user_logs` audit
   trail? The manual runbooks are "USER-gated at each irreversible step" — mirror that.

7. **`translations` / `teams` / `dashboard_config` server-side gaps.** csadmin posts to
   `/api/i18n/*` and `/api/teams/*` but **no edge-api server endpoint or table write exists on the
   inspected branch** [unverified]. If these become part of onboarding config, the promote surface
   must grow — track them.

---

## Appendix A — Evidence ledger (queries + cites)

- **Topology:** `aws ec2 describe-instances`, `aws ssm describe-instance-information` (prod-db absent);
  prod `DB_NAME=packiot`/`DB_HOST=10.20.10.89` from `docker exec stack-edge-api-1 printenv`.
- **Staging schema/search_path:** `SELECT ... FROM pg_database WHERE datname='packiot_analytics'` →
  search_path `…identity, config, ops, serving, customer_reports, core, public`;
  `core.packml_register` relkind = `v` (view over `core.topic_routing`).
- **Prod schema:** `packiot` schemas = `public, bi, hdb_catalog` only; `enterprises/equipments/
  packml_register/client_descriptors/users/translations/...` all in `public`.
- **Column parity:** prod `public.enterprises` cols == staging `core.enterprises` cols; prod
  `public.packml_register` has **no `device_key`** (staging `topic_routing` does).
- **ID ranges / tenants:** staging 9 enterprises (CPACK-Staging=3), prod 2 (OPS-TEST=1, CPACK=3);
  equipment id ranges overlap.
- **Write-path cites:** see §2 table (all `edge-api` stack-submodule paths).
- **Edge:** `reader-bundle.ts`, `edge-ssm.service.ts`, `client-descriptor-dao.ts`, `csadmin/src/api/edge-ssm.ts`, ADR-0043/0045/0049/0051.
- **Prior art:** `bispharma-prod-recut-runbook.md`, `bispharma-prod-secrets-manifest.md`,
  `cpack-newprod-seed-runbook.md`, `onboarding-acceptance-checklist.md`,
  `production-f3-schema-assembly.md`, `production-recut-runbook.md`.

**[unverified]** items: ADR-0047 files were not present in any git ref at investigation time
(transient working-tree files); prod per-table column parity beyond `enterprises`/`packml_register`;
server-side `translations`/`teams` write paths; `PositionSQL` apply path.

---

## Appendix B — Increment 1 (BUILT) — extract + dry-run plan; prod-apply GATED

Increment 1 implements everything in Phases 1 + 3 (read-only extract, dry-run
plan/diff, csadmin UX) plus the Phase-2 apply MECHANISM behind a hard gate that
is OFF. **No prod write path is reachable.** Proven on staging against Bispharma
(enterprise 5).

### edge-api — `promote` usecase (PR: `feat/273-promote-to-production`)

Dark-by-default (`EDGE_API_PROMOTE_ENABLED`, mirrors the onboarding slice), CS-Admin-gated
(reuses `CsAdminGuard`).

| Route | What it does | Writes? |
|---|---|---|
| `GET /api/promote/bundle` | Extracts the tenant config surface (§2.1 include-list) into a portable `PromotionBundle`. `PromotionDAO` reads bare table names + include columns only — no `api_key`, no surrogate-PK identity (carried only as `source_id_*` for FK rebuild), no runtime/engine columns. | none |
| `POST /api/promote/plan` | Extract → **`translateBundleToLegacy`** (pure fn): FK-ordered write manifest, id-remap table (all `mint-fresh`), per-table schema-parity report vs the captured prod fixture, honest `apply_safe`. Handles the `device_key` drift — the register op **drops** it (`prod-schema.fixture.ts` marks it `known_missing`), status `drift_handled`. | none |
| `POST /api/promote/apply` | The prod-apply mechanism, **double-gated**: `PromoteApplyEnabledGuard` 403s the route unless `EDGE_API_PROMOTE_APPLY_ENABLED` is flipped, AND the terminal executor (`executeAgainstProd`) is a `NotImplemented` stub. Cannot mutate prod in increment 1. | **gated OFF** |

Key files: `src/usecases/promote/{extract,plan,apply,translate,shared,dto}`,
`src/data/DAO/promotion/`. Unit tests: `translate.spec.ts` (device_key drop,
`api_key`/`id_user_cognito` exclusion, FK ordering, mint-fresh remap, honest
`apply_safe`), `promote-apply-enabled.guard.spec.ts` (403 GATED when off).

### csadmin — "Promote to production" step (PR: `feat/273-promote-to-production`)

New final wizard step (unlocks once cut over on staging). Loads the dry-run plan,
renders summary + apply-safety verdict + schema-parity table + FK-ordered op
manifest (per-op preview SQL) + secrets-regenerated list. The "Apply to
production" confirm dialog is HARD-GATED: `VITE_PROMOTE_APPLY_ENABLED` off ⇒
disabled button + "GATED" banner; even if flipped, the edge-api double-gate
refuses. `api/promote.ts` + `classifyPromoteError` (dark-404 vs no-such-tenant).

### Hardproof (staging, Bispharma ent 5)

- Extract SQL (the DAO's exact `SELECT`s) returned the real surface: **2 sites,
  2 areas, 128 equipments, 6 shifts, 36 shift_hours, 128 topic_routing, 1
  descriptor (`BISPHARMASTAGING`, status `cutover`), 1 user, 1 role** — with
  `api_key` absent and `device_key` present on the routes.
- Piping that real bundle through the compiled `translateBundleToLegacy` produced
  a 10-op FK-ordered plan; `packml_register` op **dropped `device_key`**
  (`drift_handled`), `enterprises` op excluded `api_key`, `users` op omitted
  `id_user_cognito`, and `apply_safe=false` with the honest blocker "prod column
  parity UNVERIFIED for … — increment 2 must run a live prod parity capture".

### What increment 2 (the real prod-apply) needs — the gate checklist

To flip `EDGE_API_PROMOTE_APPLY_ENABLED` on and wire `executeAgainstProd`:

1. **Prod connectivity.** Run the apply endpoint on the **prod edge-api**
   (`stack-edge-api-1` on prod app box `i-02d255a1c21fb1da3`), the only host with
   a pooled route to prod DB `10.20.10.89` (not SSM-reachable elsewhere).
2. **Live prod parity capture (Phase 0).** Run the §4.4 config-parity fingerprint
   against live prod and promote every §2.1 table in `prod-schema.fixture.ts`
   from `verified:false` → `true`. Land an expand migration for any real
   `MISSING` column (known: `packml_register.device_key`, currently handled by
   dropping it). This is what turns `apply_safe` green.
3. **Auth + authorization artifact.** CS-Admin credential (already stacked) PLUS
   an explicit human authorization recorded in the audit log (`res.locals.logData`).
4. **Snapshot-gated, reversible executor.** Wire `executeAgainstProd`: tag a
   rollback anchor (prod DB snapshot / logical `pg_dump` of the tenant rows) →
   FK-ordered replay via the create services/idempotent upserts, resolving
   symbolic FK edges through a live symbol table (staging `source_id` → minted
   prod id), regenerate `api_key` + `id_user_cognito`, id-rewrite
   `descriptor.equipment[].id_equipment` (§7.3), apply the register SQL, land the
   tenant **inactive**, record the audit, then a separate explicit activate.
5. **Edge Go-live (Phase 4).** After the DB promote, `POST /deploy-bundle` to the
   prod `mi-` box + verify `packml_register.active=true` (gated on ADR-0049).
