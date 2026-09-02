# Production W3 — read plane + front4/operator re-point (DESIGN)

**Status:** DESIGN / PLAN ONLY — **do NOT deploy, do NOT re-point front4 live, do
NOT merge.** This is the plan that executes *right after* the prod DB exists
(W1.4/W1.6). Nothing here mutates production. All live-DB access is **SELECT-only**.
**Date:** 2026-07-27 · **Scope:** `packiot-stack-alpha`, `production` branch / prod EC2
`i-02d255a1c21fb1da3`, single-flow **F3-native** DB. First client: **Bispharma**
(greenfield ent 4 — legacy shell, ~65 Firebase users, ZERO topology, ZERO PLC data).

**Anchors:**
[production-buildout-roadmap §W3/R1](./production-buildout-roadmap.md) (this doc is the
detailed build of W3, the roadmap's #1 RISK) ·
[production-f3-schema-assembly](./production-f3-schema-assembly.md) (W1.4 — the read
surface these datasets bind to) ·
[production-recut-runbook](./production-recut-runbook.md) (W1 — compose #627 that already
carries the refdata block) ·
[ADR-0032 §5](../0032-collapse-to-single-flow-f3.md) (F3 read-surface completeness) ·
[ADR-0027](../0027-refdata-read-plane.md) (refdata as the single injection authority) ·
[ADR-0034](../0034-cognito-migration.md) / ADR-0035 (auth + cache) ·
[ADR-0026](../0026-api-consolidation.md) (front4→refdata read migration).

---

## 0. TL;DR

The prod read plane is **refdata-api** in front of the single F3 DB, serving the
**same object-name-identical dataset SQL** it serves on staging — because in
greenfield prod the DB's `public` schema *is* F3, so every `h_piot_*` / `piot_*` /
`v_operator_*` function the datasets call resolves with **zero SQL change**. front4
and the operator PWA re-point off legacy (Hasura Cloud `gqlpiot.packiot.com` /
back4) onto new-prod refdata by flipping their `VITE_REFDATA_*` build flags.

**Bispharma is the easy case and this SIMPLIFIES the roadmap's #1 risk.** The
blank-dashboard risk (R1) exists because a client with *existing* dashboards can be
blanked mid-flip if the F3 read surface is incomplete. Bispharma has **no legacy
dashboard to preserve** (its legacy ent-4 is an empty shell — nothing renders there
today), so there is **nothing to parallel-run against and nothing to blank**. Its
cutover is a one-way *dark-launch → health-gate → flip*, not a shadow/parity dance.
The R1 mitigation for Bispharma collapses to a **boot-order checklist**, not a
comparator program.

**This week (safe, no prod mutation):** the compose refdata env is already scaffolded
(#627); the only net-new safe artifacts are this doc + a front4 **prod env template**
(flags present-but-OFF). The live flip is gated on: refdata healthy · F3 schema present
· 65 users seeded · data flowing.

---

## 1. What serves reads in new-prod

```
                        browser (front4 SPA)  ·  operator PWA
                                 │  Authorization: Bearer <Firebase ID token>
                                 ▼
                    nginx  refdata.prod.packiot.app  (NO Authentik forward-auth — §1.3)
                                 │
                                 ▼
                    refdata-api  :9104   (container 172.18.0.26)
                       │  verify JWT → uid → id_enterprise (server-side)
                       │  cache-aside over app-redis (fail-open, ADR-0035)
                       ▼
                    pgbouncer → PostgreSQL  (single prod DB, public = F3)
                       │  bare-name SQL resolves via search_path=public:
                       │    h_piot_* · piot_* · v_operator_*
                       ▼
                    F3 objects (the W1.4 snapshot — 309 curated objects)
```

Three pieces make up the plane, all already present on the W1 compose (#627):

| Piece | Role | Prod config (from compose #627) |
|-------|------|--------------------------------|
| **refdata-api** | tenant-scoped read authority; the ONLY read path front4/operator use | `DB_NAME = DB_NAME_F3 = ${POSTGRES_DB}`, `REFDATA_FLOW=f3`, `HEALTH_PORT=9104` |
| **app-redis** | ADR-0035 cache-aside (fail-open — a slow/dead cache never blocks reads) | `redis:7-alpine`, 256 MB LRU, `REDIS_CACHE_ENABLED=true` |
| **the F3 read surface** | `h_piot_*` analytics fns + `piot_*` + `v_operator_*` views, part of the W1.4 snapshot | assembled as `public` by the `db-schema-f3` one-shot |
| **hasura** | prod GraphQL **metadata only** — NOT a browser read path anymore | present but not consumed by front4/operator reads (they use refdata) |

### 1.1 Why the datasets resolve against F3-as-`public` with ZERO change (confirmed)

refdata's dataset/endpoint SQL uses **bare, unqualified object names** — verified in
`services/refdata-api/cmd/refdata-api/main.go`:

```go
{"/v1/events-timeline",
 `SELECT * FROM h_piot_get_events_timeline3_with_event_id($2) WHERE id_enterprise = $1`, …},
{"/v1/operator-po-list",
 `SELECT * FROM v_operator_po_list_setup_4 WHERE id_enterprise = $1`, …},
```

There is **no schema qualifier and no `REFDATA_FLOW`-driven SQL rewrite** in the code —
the flow is selected entirely by *which DB / search_path the pool connects to*. On
staging the F3 objects live in `packiot_shadow`; in greenfield prod they live in
`public` (the W1.4 snapshot was captured *from* staging's `packiot_shadow` and restored
*as* `public`). Same names, different schema home → the identical SQL binds to F3 in
prod with `search_path=public` (the default). This is the "object-name-identical across
flows" W1 finding, confirmed at the source.

> **Arity caveat (task #90, already handled in code):** the W1.4 F3 snapshot is taken
> from **staging** `packiot_shadow`, so every function signature matches *staging's*
> copy — including `piot_get_shift_hours_by_enterprise_packml_topic_2` (the 2-arg
> staging wrapper), NOT legacy prod's 1-arg variant. refdata already binds `topic` only
> and lets the outer `WHERE id_enterprise=$1` do the tenant fence, so it is byte-stable
> against the staging-derived F3 surface. No new-prod-specific drift is expected because
> new-prod F3 ≡ staging F3 by construction.

### 1.2 Read-surface completeness is a W1.4 property, not a W3 build

R1's root cause — "F3 read surface incomplete → dashboards blank" — is **discharged by
W1.4**, not re-litigated here. The W1.4 assembly gate
(`scripts/prod-f3-schema-parity-check.sh`) proved `F3_MISSING=0, EXTRA=0` against live
staging F3 (309 curated objects incl. the `h_piot_*` analytics functions ADR-0032 §5
enumerates). **W3's job is not to complete the surface — it is to verify the plane in
front of it is healthy before flipping consumers.** The health-gate (§5) is the
enforcement point: it re-asserts every `h_piot_*` the front4 analytics hooks call
actually exists and returns rows for Bispharma's tenant *before* the flag flips.

### 1.3 KEY FINDING — refdata's prod vhost must BYPASS Authentik

Prod's nginx (`terraform/production/user_data/nginx_setup.sh`) generates one vhost per
entry in the `services` map, and **every such vhost is wrapped in Authentik
forward-auth** (`auth_request` → `/outpost.goauthentik.io`). refdata is a **browser API
authenticated in-app by a Firebase/Cognito Bearer JWT** — putting it behind Authentik
SSO would 302-redirect the SPA's `fetch()` to the Authentik login page and break every
read (this is exactly why refdata is **absent from the `services` map on staging too** —
it is wired via a dedicated, no-`auth_request` vhost out-of-band).

**Therefore:** do **NOT** add `refdata` to `terraform/production/variables.tf`
`services`. Prod needs a dedicated `refdata.prod.packiot.app` vhost that:
- proxies to `172.18.0.26:9104`,
- has **no** `auth_request` (auth is refdata's JWT verify),
- reuses the already-issued wildcard `*.prod.packiot.app` cert,
- gets its own `A refdata.prod.packiot.app → EIP` record (a dedicated
  `aws_route53_record`, mirroring the `auth.` record, NOT the `services` for_each).

This is a W3 build step (§6, gated) — it is **not** committed as terraform in this PR,
because a new nginx block must be validated against how staging's refdata vhost is
actually shaped before it lands. Flagged here so the mistake ("just add it to the
services map") is not made.

---

## 2. front4 re-point — the flag flip

front4 is a **static SPA** (sibling repo `front4`, not a submodule of this stack). Its
read source is chosen at **build time** by three Vite flags (`src/services/refdata.js`):

| Flag | Meaning | Legacy value (today) | New-prod value |
|------|---------|----------------------|----------------|
| `VITE_REFDATA_API_URL` | refdata base URL | *(unset in `.env.production`)* | `https://refdata.prod.packiot.app` |
| `VITE_REFDATA_ENABLED` | master gate — turns on the refdata transport (non-analytics reads) | *(unset ⇒ OFF)* | `true` |
| `VITE_REFDATA_ANALYTICS` | **second, independent** gate for the Overview + analytics-page reads | *(unset ⇒ OFF)* | `true` |

Today `front4/.env.production` contains only `VITE_API_URL=https://api4.packiot.com/`
and `VITE_EDGE_API=https://edge.api4.packiot.com` → **legacy read plane** (Hasura Cloud
`gqlpiot.packiot.com` + back4). Adding the three flags above (and building) re-points
reads onto new-prod refdata → F3.

**Two flags, not one — and it matters for the flip.** `REFDATA_ANALYTICS_ENABLED` is
ANDed with `REFDATA_ENABLED` (`refdata.js:48`): the analytics surfaces (Overview
composition hooks, OEE / Downtimes / SinglePeriod / MachineSpeed pages) only cut over
when *both* are true. This is what lets you turn on the base transport first and the
heavy analytics reads as a second, deliberate step.

### 2.1 ⚠ NO Hasura fallback on the analytics path (the sharp edge)

Historically `useDualRefdataQuery` ran a Hasura leg *and* a refdata leg and picked one.
As of the ADR-0026 endgame the Hasura leg was **deleted** — the hook is now
**refdata-ONLY** (`refdata.js:306`+: *"the Hasura leg was pure dead weight… this hook is
now refdata-ONLY… Apollo-free"*). Consequence: once `VITE_REFDATA_ANALYTICS=true`, a
refdata failure (unhealthy service, missing F3 object, unseeded user → 401, empty
tenant) surfaces as a dashboard **error/blank with no automatic fallback**. This is the
mechanical reason R1 is "High" severity — and the reason the health-gate (§5) must pass
*before* the flag flips. (The non-analytics `useRefdataQuery` path *does* still no-op to
its caller's legacy path when `REFDATA_ENABLED` is false, but once enabled it too has no
silent fallback.)

### 2.2 Bispharma greenfield = NO parallel-run needed (the simplification)

| | **Existing-data client** (e.g. a future CPACK/Incoplast prod cutover) | **Bispharma (greenfield)** |
|---|---|---|
| Legacy dashboards today | render real OEE off Hasura Cloud/back4 | **none** — legacy ent-4 is an empty shell, nothing renders |
| Risk on flip | flip mid-render → users watching a live dashboard see it blank | **no user is watching a legacy dashboard** — there is nothing to blank |
| Required rigor | **parallel-run / shadow-read**: point at refdata in a canary build, diff every dashboard vs the legacy baseline, byte-compare shapes, THEN flip | **direct**: dark-launch data into F3, pass the health-gate, flip once |
| Comparator | cross-source shape+value parity vs legacy baseline | **none possible and none needed** — there is no legacy baseline to diff |
| Rollback | flip flag back to legacy (data still in both planes) | flip flag back = back to the *empty* legacy shell (no data loss either way) |

**Call it out plainly:** Bispharma removes the single most dangerous part of W3. The
roadmap's R1 mitigation ("shape-parity vs the legacy baseline before the customer-facing
flip") is an **existing-data-client** requirement. For Bispharma there is no baseline, so
W3.4 degrades from "gated mini-program with a comparator" to "a boot-order checklist"
(§5). The rigor we *do* keep is **internal-consistency + client spot-check** (W5 bake),
not cross-source parity.

---

## 3. Auth / users seed for prod

refdata resolves tenant **server-side** from the browser's JWT — verified in
`services/refdata-api/cmd/refdata-api/auth_firebase.go`:

```sql
SELECT id_enterprise, user_roles FROM users
WHERE id_user_firebase = $1 AND active = true AND id_enterprise IS NOT NULL
```

(the Cognito path ORs `id_user_cognito = $1`). So **a Bispharma login only resolves to a
tenant once a `users` row with that person's `id_user_firebase` exists in the prod DB,
`active=true`, pointing at Bispharma's `id_enterprise`.** No seed → uid resolves to no
enterprise → `401` → blank dashboard. Seeding the 65 users is therefore a **hard
precondition of the flip**, item 3 of the health-gate.

### 3.1 The seed plan (identical shape to the staging seed we already ran)

This mirrors `docs/clients/bispharma-staging-tenant-prep.md §2` exactly, retargeted from
staging `packiot_shadow` to the prod `public` F3 DB.

1. **Pull the 65 from legacy PROD — SELECT-only, `BEGIN READ ONLY`, never echo secrets.**
   Legacy prod Bispharma = `id_enterprise = 4`.
   ```sql
   BEGIN READ ONLY;
   SELECT id_user_firebase, email, nm_user, user_roles, active
   FROM users
   WHERE id_enterprise = 4
     AND id_user_firebase IS NOT NULL
   ORDER BY id_user;
   COMMIT;
   ```
   Redirect to `~/bispharma-users.prod.tsv` — **outside the repo, git-ignored. Real
   UIDs/emails are PII; never commit, never paste into a PR or chat.** Expect ≈65 rows.

2. **Generate the prod seed SQL (kept out of git — contains PII).** Idempotent UPSERT on
   `id_user_firebase`, remapping `id_enterprise` to the chosen **prod** Bispharma id:
   ```sql
   -- bispharma-users.seed.prod.sql  (GENERATED, NOT COMMITTED — PII)
   INSERT INTO users (id_enterprise, nm_user, email, id_user_firebase, user_roles, active)
   VALUES (:ENT, '<nm_user>', '<email>', '<id_user_firebase>', <user_roles-or-NULL>, true), …
   ON CONFLICT (id_user_firebase) DO UPDATE
     SET id_enterprise = EXCLUDED.id_enterprise, active = true;
   ```
   - `:ENT` = Bispharma's **prod** enterprise id. Decide the same way as staging
     (`bispharma-staging-tenant-prep §0`): reuse `4` iff prod ent-4 is free/shell, else
     next free id and remap. Since prod is a **fresh empty F3 DB**, ent-4 is trivially
     free → reuse `4` (keeps the users' legacy `id_enterprise` copying straight over).
   - `ON CONFLICT (id_user_firebase)` needs that UNIQUE constraint — it's the core safety
     property the auth code relies on ("id_user_firebase is UNIQUE"). Verify it exists on
     the prod F3 `users` (it's part of the W1.4 snapshot); dedupe in the generator if not.
   - `user_roles` is nullable — a NULL role still authenticates (tenant resolves; the two
     per-role datasets fail closed). Carry the legacy value through as-is.
   - **Pilot subset:** filter step 1 to the chosen UIDs to cut over a handful first.

3. **Apply on the prod F3 DB** at the cutover window (this is the one deliberate prod DML
   in W3 — a bounded, reviewed, idempotent INSERT). Verify:
   ```sql
   SELECT count(*) FROM users WHERE id_enterprise = :ENT AND active;  -- expect ≈65 (or pilot N)
   ```

### 3.2 Firebase now, Cognito later (ADR-0034 path)

Bispharma **stays on Firebase initially.** refdata's verifier is **dual** and
issuer-agnostic (`auth_firebase.go` ORs `id_user_firebase` / `id_user_cognito`); the
compose (#627) ships `FIREBASE_PROJECT_ID=fbpackiot`, `COGNITO_AUTH_ENABLED=false`. So
front4 sends the *same* Firebase ID token it sends to Hasura/back4 today, refdata
verifies it against the public `fbpackiot` project, no Cognito pool needed for go-live.
The ADR-0034 Cognito migration is a **later, additive** step: provision a prod pool, seed
`id_user_cognito` out-of-band, flip `COGNITO_AUTH_ENABLED=true` + set the prod
issuer/client-id — refdata then accepts *either* issuer with no front4 change (the dual
path is already built and proven on staging). Bispharma go-live does not wait on it.

---

## 4. operator re-point (only if Bispharma uses the operator PWA)

Whether this applies is **open decision #7 in the roadmap** (does Bispharma use the
operator PWA or a bespoke UI?). If it uses the PWA:

- **Reads:** the operator PWA reads through the **same refdata** as front4 — the fixed
  `/v1/operator-*` routes (`v_operator_po_list_setup_4`, `v_operator_po_details_3`,
  `v_operator_entities_2`), tenant-scoped by the server-resolved id. It authenticates
  with a **per-tenant read key** (`REFDATA_API_KEY` build-arg in compose #627 —
  `OPERATOR_REFDATA_API_KEY` = the Bispharma entry from refdata's `QUERY_API_KEYS`), not
  a browser JWT. **Shape stability is load-bearing** — the operator caches `/v1/*` by URL
  and parses fixed shapes, so the F3-derived responses must stay byte-stable (they are,
  by the same object-identity argument as §1.1).
- **Writes:** operator PO actions (start/stop, downtimes) go to **edge-api**, which in
  greenfield prod writes the **single F3 DB directly** (roadmap §W4 — no `shadow-mirror`
  bridge, because there is no `public`→`packiot_shadow` boundary to carry writes across).
  The `operator-adapter` service (compose #627) is only needed if Bispharma uses a
  *bespoke* operator UI; if it uses the PWA, the PWA's own durable offline write-queue
  (`VITE_PO_WRITE_QUEUE_ENABLED=true`, #31) is the path and `operator-adapter` can be
  dropped.

operator re-point is **lower risk than front4**: it is an internal tool, not a
customer-facing dashboard, and Bispharma has no operator history to preserve. It inherits
the same health-gate (refdata healthy + F3 present + users/keys seeded).

---

## 5. Blank-dashboard risk mitigation — the health-gate (exact order)

R1 is realized when a consumer flag is flipped **before** the plane behind it can serve.
The mitigation is strict ordering: **prove each layer healthy bottom-up, flip the flag
last.** No step proceeds until the one below is green. For Bispharma (greenfield) this
*replaces* the parallel-run/comparator an existing-data client would need.

```
G0  DB up + F3 schema present   ── W1.4 gate: scripts/prod-f3-schema-parity-check.sh
    │                              → F3_MISSING=0, EXTRA=0 against staging F3
    ▼
G1  refdata-api healthy          ── GET refdata:9104/healthz = 200 (container + DB reachable)
    │                              app-redis up (fail-open, so non-blocking)
    ▼
G2  users seeded                 ── §3: SELECT count(*) FROM users WHERE id_enterprise=:ENT
    │                              AND active  → ≈65 (or pilot N).  Pick ONE real uid and
    │                              confirm it resolves: the auth path returns its id_enterprise.
    ▼
G3  data flowing into F3         ── W2 ingest live + W5 dark-launch: equipment_values fresh
    │                              (<2s lag), rollups populating, OEE in-range (Q×A×P, no
    │                              oee>1.0, no two-writer double-count)
    ▼
G4  read surface answers FOR THIS TENANT
    │   for each h_piot_* / v_operator_* the front4+operator hooks call, with a seeded
    │   Bispharma token / read-key:  the endpoint returns 200 and (once G3) non-empty rows.
    │   This is the concrete "is the surface complete AND populated" check — done against
    │   the real tenant, not just object existence.
    ▼
G5  FLIP  ── build front4 with VITE_REFDATA_ENABLED=true + VITE_REFDATA_ANALYTICS=true +
             VITE_REFDATA_API_URL=https://refdata.prod.packiot.app ; deploy operator with
             its refdata read-key.  Dashboards now render off new-prod F3.
             Rollback = rebuild without the flags (back to legacy shell; no data loss).
```

**Why this order specifically:** G2 before G4 because an unseeded user 401s at G4
regardless of surface health; G3 before G5 because the analytics hooks have **no Hasura
fallback** (§2.1) — flipping onto an empty tenant paints empty/error dashboards. G4 is the
real teeth: it checks the surface *answers for Bispharma*, catching both "object missing"
(should be impossible post-W1.4) and "object present but tenant has no rows yet" (a G3
timing bug). Only G5 is customer-visible; everything above is dark.

**Dark-launch is the safety net.** Because G3–G4 run with data already flowing but front4
*still on the legacy (empty) shell*, we validate the entire prod read plane against real
Bispharma data with **no user pointed at it**. The flip (G5) then only changes *which URL
the SPA reads* — the plane it's flipping to is already proven live.

---

## 6. Pre-stageable (this-week-safe) vs gated (post-DB)

### 6.1 Safe to pre-stage now (config/doc only — no prod mutation)

| Item | Where | Why safe |
|------|-------|----------|
| **This design doc** | `docs/adr/reference/production-w3-readplane-repoint.md` | doc only |
| **refdata env scaffold** | `compose.production.yml` — **already done in W1 #627** | config, not deployed; values `FILL AT DEPLOY` |
| **front4 prod env template** | `docs/clients/bispharma-front4-prod.env.template` (this PR) | a *reference template*, flags present-but-**OFF/commented** — NOT the live `front4/.env.production`, not built, not shipped. Shows exactly what W3.4 will flip. |
| **QUERY_API_KEYS / secret placeholders** | roadmap §2 `secrets.tf` scaffold (W1 track) | placeholder values; real keys at deploy |

### 6.2 Gated — executes only after the prod DB exists (W1.4/W1.6)

| Item | Gate | Notes |
|------|------|-------|
| refdata `refdata.prod.packiot.app` **vhost (no Authentik)** + DNS A-record | needs a validated nginx block (§1.3) + `terraform apply` | **do NOT add refdata to the `services` map** — it would wrap it in Authentik SSO and break the JWT API |
| Fill `REFDATA_QUERY_API_KEYS` (per-tenant → enterprise id) in the deploy env | secrets provisioned | server-side only; never shipped to the browser |
| **Seed the 65 Bispharma users** into prod F3 `users` | DB exists (G0) | §3 — one reviewed idempotent prod DML; PII stays out of git |
| The G0–G4 health-gate checks | DB + refdata + ingest live | §5 |
| **G5: flip front4 `VITE_REFDATA_*` + rebuild/deploy** | **all of §5 green + USER sign-off** | the customer-visible cutover — a deliberate, announced step |
| operator deploy with its refdata read-key | if Bispharma uses the PWA (open decision #7) | §4 |
| Cognito enablement (`COGNITO_AUTH_ENABLED=true`) | later, additive | §3.2 — Bispharma go-live does not wait on it |

---

## 7. What this doc explicitly does NOT do

- Does **not** re-point front4 or the operator live, and does **not** build/ship any
  front4 bundle.
- Does **not** deploy, `terraform apply`, or `docker compose up` anything.
- Does **not** seed users or run any DML on prod (that is a gated §3 step).
- Does **not** write the prod nginx refdata vhost as terraform (a validated block is a
  gated W3 build step, §1.3/§6.2).
- Reads legacy prod **SELECT-only** (the users pull, §3.1), never writes it.

---

## 8. Open items feeding USER decisions

- **Open decision #7 (roadmap):** does Bispharma use the operator PWA or a bespoke UI? —
  drives whether `operator-adapter` stays (§4).
- **Prod enterprise id for Bispharma:** recommend **reuse `4`** (prod F3 is empty → no
  collision; users' legacy `id_enterprise` copies straight over) — §3.1.
- **Pilot-subset vs all-65 first flip:** a pilot cut (a few UIDs) de-risks G5 further —
  §3.1 step 1 filter.
- **refdata prod nginx vhost shape:** confirm against how staging's out-of-band refdata
  vhost is actually configured before writing the prod block (§1.3).

## References

- `services/refdata-api/cmd/refdata-api/main.go` — the dataset/endpoint SQL (bare object
  names → resolve against `public`=F3); §1.1
- `services/refdata-api/cmd/refdata-api/auth_firebase.go` — uid→id_enterprise resolver; §3
- `front4/src/services/refdata.js` — `VITE_REFDATA_*` gates + the refdata-only analytics
  hook (no Hasura fallback); §2
- `front4/.env.production` — current legacy-only prod config; §2
- `compose.production.yml` (W1 #627) — refdata-api / app-redis / operator blocks
- `docs/clients/bispharma-staging-tenant-prep.md §2` — the staging users-seed this mirrors
- `terraform/production/user_data/nginx_setup.sh` / `variables.tf` — the Authentik-wrapped
  `services` vhosts refdata must avoid; §1.3
- [production-f3-schema-assembly.md](./production-f3-schema-assembly.md) — the F3 read
  surface (W1.4) the datasets bind to; §1.2
</content>
</invoke>
