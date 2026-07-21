# ADR-0033 — Unify client-user authentication on Firebase JWT (reads + writes + operator), with per-tenant isolation

**Status:** Proposed · **Date:** 2026-07-21 · **Scope:** front4 (reads) · operator PWA (writes) · edge-api (write API) — **DESIGN ONLY** (this ADR is the plan; no edge-api/operator code changes ship with it). **Decision owner:** auth architect / tech-lead — pending USER sign-off on the three open questions in §11. **This is the USER's chosen direction.**

**Builds on / honors:**
- [ADR-0027](0027-refdata-api-surface-1-read-contract.md) — the **single tenant-injection authority** invariant (`credential → customer_id → $1`; the client never names a tenant). This ADR extends that invariant from the read plane to the write plane.
- [ADR-0026](0026-api-layer-consolidation.md) — API consolidation; refdata-api is the hardened read plane. Firebase-JWT-for-reads (task #68) is the proven base this ADR generalizes.
- [ADR-0018](0018-operator-frontend-integration-makeover.md) — the operator SPA integration + the ported Node-RED login (`login.service.ts`), the bcrypt-on-`operator_pw_hash` path this ADR retires.
- [ADR-0021](0021-multitenancy-model.md) — the multitenancy model (`id_enterprise` as the tenant axis) this ADR fences writes against.

**Relates to:**
- [ADR-0032](0032-collapse-to-single-flow-f3.md) — the single-flow collapse. This ADR **removes** the `operator_pw_hash`-into-`packiot_shadow` seeding requirement (see §9): the F3 collapse needs only `uid → id_enterprise`, never password hashes.
- Tasks **#57** (tenant isolation) · **#68** (Firebase-JWT reads) · **#70** (per-user role) — the proven read-side building blocks. **#32** (operator durable-write-queue + staleness gate) — the load-bearing constraint on decision 2.

> **Numbering:** `0033` is the next free slot (`0032` is the F3 collapse). No renumbering of the existing 0029 duplicate is attempted here.

---

## 1. Context — what is fragmented, and the one model that already works

Packiot has **four** client-user auth mechanisms today. One of them is correct and proven; the other three are legacy fragments the org has committed to retiring. The whole point of this ADR is to make the proven one universal.

### 1.1 The proven base — front4 reads (ADOPT AS THE MODEL)

`services/refdata-api/cmd/refdata-api/auth.go` + `auth_firebase.go` (tasks #57/#68/#70, **live on staging**) already implement exactly the target model, for reads:

```
front4 (static SPA, holds NO secret, names NO tenant)
   │  Authorization: Bearer <Firebase ID token>   (same token it sends Hasura/back4)
   ▼
refdata-api  authMiddleware (single tenant-injection authority, in front of the WHOLE mux)
   │  1. verify RS256 signature against Google's public x509 certs  ← no secret in the service
   │     (iss/aud/exp/iat/sub checked; alg pinned RS256; 60s leeway; forged token → 401 before any DB touch)
   │  2. uid = sub  →  usersEnterpriseSQL:
   │        SELECT id_enterprise, user_roles FROM users
   │        WHERE id_user_firebase = $1 AND active = true AND id_enterprise IS NOT NULL
   │     (zero rows → errUnknownUID → 401; NEVER a default tenant)   ← DB LOOKUP, 5-min TTL cache
   │  3. inject customer_id into request context
   ▼
every handler binds the server-resolved customer_id as $1
   →  a cross-tenant read is UNREPRESENTABLE (no request field carries a tenant)
```

Load-bearing properties (all already true, all to be preserved and extended):

| Property | How refdata gets it | Why it matters for writes too |
|---|---|---|
| **Public-key verification, no secret** | `firebaseVerifier.Verify` uses Google's rotating x509 certs | edge-api becomes a relying party with **no private key to leak** |
| **Server-derived tenant** | uid → `users.id_enterprise`, client never names it | a write can't spoof its tenant via a query param |
| **Fail-closed** | unknown uid / deactivated / NULL enterprise → 401 | a deactivated operator's stale token stops resolving |
| **Single injection authority** | middleware in front of the whole mux | one place to audit; no route can skip it |
| **Tenant bound in SQL** | `customer_id` as `$1`, cross-tenant unrepresentable | this is the exact fence writes need (§decision 3) |

### 1.2 The three fragments to replace

**(F-a) Operator login → bcrypt on `users.operator_pw_hash`.**
`edge-api/src/usecases/session/login/login.service.ts`: the operator SPA POSTs username+password → `bcrypt.compare` against `users.operator_pw_hash` → mints a **custom `jsonwebtoken` JWT** (`JWT_SECRET`, 7-day expiry) carrying `{ user, user_permissions }`. This token is a **session-identity** token (drives entity scoping + the SPA `AuthContext`); it is a *different* JWT from Firebase, signed by a *shared symmetric secret* we own. This is the ported Node-RED "Check Credential and Generate JWT" (ADR-0018 wave 2).

**(F-b) Operator writes → shared per-factory enterprise api-key (nginx sidecar).**
The surprising part, and the real security posture: **operator write requests do NOT carry the login JWT.** `operator/nginx.edge.conf.template:34` injects a **server-side, per-tablet `EDGE_API_KEY`** (the factory's `enterprises.api_key`) as `x-api-key`; the browser never holds it. `operator/src/Services/endpoints.js`: `idEnterprise` rides the query string, and the operator's identity travels as an **advisory `x-user` header** — a string, **not cryptographically bound to anything**. So on the write path:
- The tenant fence = "which factory's nginx sidecar signed this" + the `idEnterprise` query param.
- The operator identity = a trust-me header used only for the audit trail (`user_logs`).
- There is **no per-user cryptographic identity on writes at all.**

**(F-c) edge-api write API → `?token=` / `x-api-key` → `authorize(token, idEnterprise)`.**
`edge-api/src/middleware/auth.middleware.ts` guards `/api/*`. It accepts `x-api-key` (preferred) or the **deprecated** `?token=` query param (already logged on every hit, pending removal). `auth-apikey-dao.ts#authorize` validates that the api-key matches an `active=true` enterprise — **and stops there.** It does **not** assert that the PO / equipment / downtime named in the request body belongs to that enterprise. **A valid api-key + a foreign PO id = a cross-tenant WRITE.** This is the hole decision 3 closes.

> **Why a cross-tenant write is worse than a read leak:** a read leak exposes data; a cross-tenant write *corrupts another tenant's operational state* — starts/stops the wrong factory's PO, injects a downtime into a stranger's OEE. It is unrecoverable without an audit-driven reversal. The write fence is therefore the highest-severity item in this ADR.

---

## 2. Target model — one identity, three relying parties

```
                         Firebase (per-ENV project — fbpackiot=prod, packiot-staging=staging; Decision 6)
                         mints per-USER ID tokens (RS256, ~1h TTL) + long-lived refresh tokens
                                   │
        ┌──────────────────────────┼───────────────────────────────┐
        │ Bearer <ID token>        │ Bearer <ID token>              │ Bearer <ID token>
        ▼                          ▼                                ▼
    front4 (reads)           operator PWA (writes)             (future front4 writes)
        │                          │  durable-write-queue #32         │
        ▼                          ▼  + staleness gate #32            ▼
    refdata-api  ◄────── SAME verifier + SAME uid→enterprise lookup ──►  edge-api /api/*
    (PROVEN today)             (this ADR: extend to writes)     (this ADR: replace api-key
        │                          │                             human path w/ Firebase Bearer)
        └──────────► verify RS256 (public certs, no secret)
                     uid = sub → users.id_user_firebase → id_enterprise  (DB LOOKUP, decision 1)
                     inject enterprise into request context
                     FENCE every query/mutation on that enterprise (decision 3)

    OUT OF SCOPE (stay as-is):
      Grafana  → authentik SSO (internal CS tool, not a client-user surface)   [§decision 5]
      mirror-worker-go / oeecloud replays / ingest-shim → retained SERVICE api-keys (M2M)  [§decision 5]
```

The invariant, generalized from ADR-0027: **`Firebase uid → id_enterprise → tenant-bound SQL`, for reads AND writes, with the client never naming a tenant.**

---

## 3. Decision 1 — Tenant claim: Firebase **custom claim** vs **DB lookup**

**Question:** does the token carry `id_enterprise` as a Firebase custom claim (baked at user creation via the Admin SDK, self-contained, no DB hit), or do we resolve `uid → id_enterprise` from `users` on every verify (what refdata does today)?

| | **Custom claim** (`id_enterprise` in the token) | **DB lookup** (`users.id_user_firebase → id_enterprise`) |
|---|---|---|
| Verify cost | Zero DB hit — tenant is in the verified token | One indexed lookup, already cached 5-min TTL |
| Source of truth | Firebase (must `setCustomUserClaims` at creation + on every move) | `users` table — the DB is already authoritative for everything else |
| Change enterprise | **Re-mint required** — must force a token refresh; stale tokens carry the old tenant up to 1h | Change one row; propagates within the cache TTL, no re-mint |
| Deactivation | Custom claim alone can't revoke — token still valid until exp | `active = true` in the `WHERE` — deactivated user stops resolving at next cache miss |
| Write fence | **Still needs a DB hit anyway** — the fence must read the *target row's* enterprise to compare (§decision 3), so the "no DB hit" win evaporates on writes | The uid→enterprise lookup rides alongside the fence's DB round-trip |
| Proven? | New machinery (Admin-SDK write at onboarding, claim-sync job) | **Already live on staging** (refdata) |

**RECOMMENDATION — DB lookup as the end-state.** Reasons, in priority order:

1. **The write fence hits the DB regardless.** Decision 3 must load the target PO/equipment's `id_enterprise` to compare — so on the write plane the custom claim's headline advantage (no DB touch) does not exist. Reads already cache the lookup to a 5-min TTL, so it is not a read-plane cost either.
2. **Single source of truth.** `users` is already authoritative for role, entities, `active`. Splitting tenant identity into Firebase custom claims creates a *second* place enterprise-membership lives, which must be kept in sync — the classic dual-write consistency bug. Enterprise moves and deactivations become "re-mint the token" operations instead of "UPDATE one row."
3. **Zero migration.** DB lookup reuses `usersEnterpriseSQL` verbatim. edge-api gets the *identical* resolver refdata already runs. Custom claims require an onboarding-time Admin-SDK write path and a backfill for every existing user.

**Optional defense-in-depth (NOT the authority):** later, we *may* also stamp `id_enterprise` as a custom claim and have the middleware assert `claim == db_lookup` — a cheap cross-check that catches a `users`-row tamper. But the DB stays authoritative; the claim is never trusted alone. This is a follow-up, not part of the cutover.

> **Migration note:** none. The end-state is what refdata already does. If OQ-1 comes back "custom claim," the migration is: add `setCustomUserClaims` to CS-Admin onboarding + a one-shot backfill script over existing `users.id_user_firebase`.

---

## 4. Decision 2 — Operator offline UX (the load-bearing design problem)

**The constraint stack.** The operator PWA is a **shared factory tablet**, **offline-first**, with the task-#32 durable-write-queue (`operator/src/Services/writeQueue.js`, IndexedDB) + staleness gate (`edge-api/.../po-staleness-gate.ts`). A queued write is replayed on reconnect carrying its **original `actionTime`** (not send time) + an optimistic-concurrency token, so a stale replay is *refused, never blindly applied*. Firebase **ID tokens expire in ~1h**; refreshing one **needs connectivity**. So: a write enqueued offline at 08:00 and flushed at 11:00 must arrive with a token that is valid *at 11:00* — but the operator may have been offline the whole time.

### 4.1 The key insight — separate the *ephemeral* credential from the *durable* one, and the *identity time* from the *action time*

Firebase issues **two** artifacts at login:
- an **ID token** — the ~1h RS256 JWT edge-api verifies (ephemeral, must be fresh *at send*);
- a **refresh token** — **long-lived** (does not expire unless revoked), which the Firebase Web SDK **persists in IndexedDB** and uses to mint fresh ID tokens.

The durable-write-queue already made the same split for the *business* payload: it froze `actionTime` at enqueue and does NOT trust send time. Decision 2 makes the *same* split for the *credential*:

> **Do NOT store an ID token with the queued write. Store the write; mint a FRESH ID token at DRAIN time from the persisted refresh token, and attach it just-in-time.**

### 4.2 The design, concretely

```
LOGIN (online, required once):
  operator authenticates to Firebase → Web SDK persists the REFRESH token in IndexedDB
  (survives reload / tab-crash / OS kill on the floor tablet — same durability class as the write queue)

ENQUEUE (offline OK):
  writeQueue stores { request, actionTime (frozen), assumedRunningPoId, enqueueUid }   ← NO token stored
  operator gets optimistic feedback immediately

DRAIN (on reconnect, writeQueue.js drain loop):
  for each pending write, in seq order:
    idToken = await firebase.auth().currentUser.getIdToken(/* forceRefresh if near-exp */)
              └─ uses the PERSISTED refresh token → one securetoken.googleapis.com round-trip → fresh ~1h ID token
    replay: PUT/POST edge-api  Authorization: Bearer <idToken>,  body carries the frozen actionTime
    edge-api: verify token (identity NOW) + staleness gate (actionTime = WHEN) + tenant fence (decision 3)
```

Why this is correct: **the token proves *who* at send time; the `actionTime` proves *when* the action happened.** The staleness gate already decouples send-time from action-time, so a token minted at 11:00 for an 08:00 action is exactly right — identity must be current (the operator's account might have been deactivated at 09:00, and it *should* now fail closed), while the action's business timestamp stays frozen. This reuses the queue's own outbox discipline and adds nothing new to the wire contract beyond swapping the nginx api-key for a per-request Bearer.

### 4.3 The shared-tablet wrinkle (must be surfaced to USER — OQ-2)

A shared tablet holds **one** Firebase session at a time. If operator A queues writes, then operator B logs in (new refresh token) and A never reconnected, a naive drain would sign A's writes with **B's** identity → wrong `uid` → wrong attribution (and, if A and B are different tenants, a cross-tenant write the fence would then *correctly reject*, stranding A's work). Mitigation options, in order of preference:

1. **Bind each queued write to its `enqueueUid`; drain only writes whose `enqueueUid == currentUser.uid`.** Writes from a different operator wait until *that* operator logs back in (the tablet prompts "3 pending actions from operator A — A must sign in to sync"). Simple, correct, no cross-user leakage. Cost: A's writes are stranded until A returns — acceptable on a per-shift tablet, and strictly better than today's silent `x-user` mis-attribution.
2. **Capture a short-lived token *at enqueue* and store it encrypted with the write.** Rejected: a token captured at 08:00 is expired by 11:00 (the whole problem), and storing bearer tokens at rest on a shared device is a worse posture than storing a scoped refresh token the SDK already manages.
3. **Per-tablet device identity (custom token) + attested operator claim.** A Firebase *custom token* minted for the tablet (durable device identity), with the operator name as an attested claim. Loses per-user cryptographic attribution (back to a shared credential + trust-me operator field) — this is the status quo's weakness, so **not recommended** unless OQ-2 decides shared-device ergonomics outweigh per-user non-repudiation.

**RECOMMENDATION:** option 1 (per-write `enqueueUid` binding + drain-under-matching-session). It preserves per-user non-repudiation, needs no new token storage, and degrades safely (stranded-until-owner-returns beats mis-attributed-or-cross-tenant). The service worker's role is limited to waking the drain on `online` + `sync` events; it does **not** hold or refresh tokens (the Firebase SDK owns that in the page context).

> **Token-refresh strategy is OQ-2 for the USER.** The recommendation above (persisted refresh token + JIT mint at drain + per-write uid binding) is the design; the USER should confirm the shared-tablet ergonomics (strand-until-owner-returns) are acceptable for their factories, or opt into option 3's device-identity model.

---

## 5. Decision 3 — Write-side tenant isolation in edge-api

**Goal:** every mutation (PO start/stop/replace, downtime justify/create) is fenced to the caller's `id_enterprise`, derived from the verified token — **never** from a request field. A cross-tenant write must be *unrepresentable*, mirroring refdata's read invariant.

### 5.1 Two layers, because a middleware check alone is not enough

**Layer 1 — authentication middleware (replace `authorize()` for humans).**
`auth.middleware.ts` gains a Firebase Bearer path alongside the retained service-key path:
```
if Authorization: Bearer <jwt>   → verify (same RS256 public-cert verifier as refdata; share the logic)
                                    → uid → users.id_enterprise (usersEnterpriseSQL) → req context { enterpriseId, uid, role }
                                    → fail-closed 401 on any failure (no DB touch on a forged token)
else if x-api-key (SERVICE only)  → retained M2M path (decision 5), scoped to its enterprise
else                              → 401
```
The resolved `enterpriseId` lives in a request-scoped value (NestJS: a custom `@Enterprise()` param decorator reading `req` set by the middleware, or `res.locals` consistent with the existing `logData` pattern). **It is never read from `req.query.idEnterprise` again** — that param is deleted from the trust path (it may linger as a deprecated no-op during migration, ignored by the fence).

**Layer 2 — the target-row fence (the actual anti-corruption).** Authenticating the *caller's* tenant is necessary but insufficient: the request body still names a **target** (a PO id, an equipment id). The fence asserts the target belongs to the caller's enterprise. Two equivalent implementations; prefer the first:

- **(preferred) Fold the enterprise into the mutation's own `WHERE`.** Every PO/downtime DAO mutation gains `AND id_enterprise = $callerEnterprise` in its lookup/update. A cross-tenant target then simply **matches zero rows** → the service maps "0 rows affected" to a rejection. This is refdata's exact trick (`$1`-bind, cross-tenant unrepresentable) applied to writes — the fence can't be forgotten because the query physically cannot touch another tenant's row.
- **(fallback, where a mutation can't cleanly carry the predicate)** a guard in the service layer: `SELECT id_enterprise FROM <target> WHERE id = $1`; if `!= callerEnterprise` → reject **before** the mutation runs.

### 5.2 Reject shape — 404, not 403

On a cross-tenant target, return **404 Not Found**, not 403 Forbidden. A 403 confirms the row *exists* (an existence oracle across tenants); 404 reveals nothing — from the caller's fenced view, another tenant's PO simply does not exist. This mirrors refdata's uniform-401 no-oracle stance. (`ConflictException`/`404` via the existing NestJS `HttpException` subclasses — never a plain `Error`, per the repo's global-filter rule.)

### 5.3 Where, precisely

| Layer | File(s) | Change (design intent) |
|---|---|---|
| Verify + resolve tenant | `edge-api/src/middleware/auth.middleware.ts` + a new `firebase-verifier` provider (port refdata's `auth_firebase.go` verify+lookup to TS, or a thin shared lib) | add Bearer path; inject `{ enterpriseId, uid, role }` into request context |
| Target fence | `edge-api/src/data/DAO/production-orders/*` + `downtimes` DAO | add `AND id_enterprise = $caller` to mutation lookups/updates; map 0-rows → 404 |
| Audit trail | existing `logger.middleware.ts` / `UserLogsDTO` | `uid`/`user` now comes from the **verified** token, not the advisory `x-user` header — the audit trail becomes cryptographically attributable for the first time |

> **This closes the highest-severity gap in §1.2 (F-c):** today `authorize()` says "valid api-key" and downstream trusts the body's PO id. After this, the tenant is *proven from the token* and the target is *fenced in SQL* — a cross-tenant PO write matches zero rows and 404s.

---

## 6. Decision 4 — Migration path: bcrypt + api-key → Firebase (staged, reversible)

**Phase 0 — provision Firebase identities for operators.**
Many operators may already be `users` rows with an `id_user_firebase` (front4 users). For operators that exist *only* as `operator_pw_hash` rows:
- Bulk-create Firebase accounts via the **Admin SDK** (`importUsers` / `createUser`), write each new `uid` back to `users.id_user_firebase`.
- Produce a `uid → id_enterprise` reconciliation report; any operator row with `operator_pw_hash` but no `id_user_firebase` is a migration TODO, surfaced before cutover.
- No password migration: operators set a Firebase credential (or use existing SSO/email link). `operator_pw_hash` is **not** carried into Firebase.

**Phase 1 — edge-api accepts Firebase Bearer alongside the api-key (flag-gated, additive).**
Deploy the §5 Bearer path behind a flag (e.g. `EDGE_API_FIREBASE_AUTH_ENABLED`, per-tenant allowlist, mirroring the `PO_STALENESS_GATE_ENTERPRISES` pattern already in the codebase). Both paths resolve to the **same** `enterpriseId`; the target fence applies to both. Bake per-tenant. **Reversible:** flag off → back to api-key-only.

**Phase 2 — flip the operator SPA to send the Firebase ID token.**
Operator PWA obtains the Firebase ID token (Phase-0 identity) and sends it as `Authorization: Bearer` on writes, using the §4 drain-time mint. **Remove the nginx `EDGE_API_KEY` injection for `/api/*`** (the sidecar's shared enterprise secret is no longer the write credential). Keep `x-user` only as redundant telemetry during bake, then drop it (the verified `uid` supersedes it). Per-tenant, reversible (revert nginx template + SPA header).

**Phase 3 — retire the bcrypt login + `operator_pw_hash`.**
Once every operator authenticates via Firebase and the SPA no longer calls `/api/session/login` for credentials:
- Delete `login.service.ts`'s bcrypt path (or reduce `/session/login` to a Firebase-token *exchange* for the SPA's non-credential session bootstrap — entities/language/permissions — if that bootstrap is still wanted; that bootstrap can also move to a refdata dataset).
- Migration to **drop `users.operator_pw_hash`** (soft first: stop writing it, verify nothing reads it via a deprecation-log bake, then drop the column). `JWT_SECRET` for operator tokens retires with it.

**Phase 4 — deprecate edge-api's `?token=` and the human api-key path.**
The `?token=` query fallback is *already* logged on every hit. Once Phase-2 bake shows the deprecation log quiet for human traffic, remove the query-param branch. The `x-api-key` path is **retained only for M2M** (decision 5) — conceptually renamed "service token," scoped, and documented as non-human.

Every phase is independently deployable, flag-gated where it touches live traffic, and reverts by flag or config. No phase requires a big-bang cutover.

---

## 7. Decision 5 — Scope boundaries

**Grafana — OUT OF SCOPE.** Grafana authenticates via **authentik SSO** (reference: `memory/reference_grafana_access.md` — SSO, *not* admin/pass, *not* a client-user surface). It is an internal CS/observability tool for Packiot staff, not a factory-client login. It stays on authentik; this ADR does not touch it.

**Machine-to-machine (service) callers — RETAIN scoped api-keys.** Not every caller is a human with a Firebase account. These authenticate with **retained service api-keys** (the `x-api-key` path, kept explicitly for M2M and conceptually renamed "service token"):
- **mirror-worker-go** — the shadow-mirror operator-action replay (ADR-0013/0032). A service, not a user; it replays already-authenticated operator actions into `packiot_shadow`.
- **oeecloud replays / edge-transformer / ingest-shim** — pipeline services, no human identity.
- **refdata-api's `X-Api-Key` operator map** (`QUERY_API_KEYS`) — already a service-style credential for non-front4 read callers; unchanged.

Service tokens should be per-service, scoped to the enterprise(s) they serve, rotatable, and *never* issued to a browser. The distinction is crisp: **human client-users → Firebase per-user JWT; services → scoped service api-keys.**

---

## 7A. Decision 6 — Firebase project topology: **SEPARATE project per environment** (RESOLVES OQ-3)

**Question (was OQ-3):** is the **staging** Firebase project the same `fbpackiot` as prod, or a separate project?

**DECISION — a SEPARATE Firebase project per environment.** Prod stays on `fbpackiot`; staging gets a dedicated **`packiot-staging`** project; (dev may share staging or get its own later). `FIREBASE_PROJECT_ID` becomes a **per-environment** value for every relying party (front4 via `VITE_FIREBASE_PROJECT_ID`; refdata + edge-api via env), and each environment's front4 authenticates against its own project.

**Why separate, in priority order:**

1. **Blast-radius isolation — the load-bearing reason.** A single shared project means a *staging* mistake mutates the *prod* user pool: a test-user spam run, a fat-fingered "delete all users", a loosened Auth setting, an accidental provider toggle — all land on real customers. Separate projects make staging a true sandbox: **nothing done in `packiot-staging` can touch a prod client's login.** This is the same isolation discipline as separate DB instances per env; auth deserves it more, not less.
2. **Token-audience isolation (a real security boundary, not just hygiene).** A Firebase ID token's `aud` claim **is the project id**, and the verifier pins `aud` (ADR-0027/§1.1). With one shared project, a token minted for staging is `aud`-valid against the **prod** refdata/edge-api verifier and vice-versa — the environments are cryptographically fungible. Separate projects make a staging token **fail `aud` verification** at the prod plane (and vice-versa): a leaked/replayed staging token cannot act on prod. Cross-env replay becomes unrepresentable, mirroring the cross-tenant-unrepresentable stance of the whole ADR.
3. **Clean per-env provisioning (feeds Decision 7).** Phase-0 operator provisioning + all test-user minting run against the **correct** project with a **staging-only** service-account key. The dead prod key (`back4-api/private-key.json`, credential deleted in GCP) is never needed; a staging SA key can only ever reach staging. A mis-pointed key is a *config error*, not a *cross-env breach*.
4. **Cost is not a reason to share.** Firebase **projects are free**; each project carries its **own free-tier** Auth quota; **standard Email/Password Auth is free** (Spark plan). Because tenancy is a **DB lookup** (Decision 1), staging does **not** need Identity Platform / custom claims, so there is no per-MAU billing to duplicate. Separation costs $0.

**Consequences / mechanics:**
- front4 `src/firebase.js` reads `VITE_FIREBASE_*` with fbpackiot fallbacks — prod byte-identical; staging flips by pointing `.env.staging` at `packiot-staging` (repo prep already landed; the flip is gated on the project existing).
- refdata + edge-api verifiers take `FIREBASE_PROJECT_ID` per env (refdata already supports this). The verifier's `aud` pin then enforces boundary #2 for free.
- **USER action** (console, cannot be automated by the repo): create `packiot-staging`, enable Email/Password, register the web app, create a staging service-account key → staging secrets manager (never the repo). Step-by-step: **[`docs/auth/staging-firebase-setup.md`](../auth/staging-firebase-setup.md)**.

---

## 7B. Decision 7 — **CS-Admin owns client-user creation** (per-ENV project + DB mapping, one transaction)

**Question:** who creates a client user's Firebase identity, and how does the `uid → id_enterprise` row that Decision 1 depends on get seeded — and where does that leave the ad-hoc "mint a user by hand with the prod service-account key" practice?

**DECISION — CS-Admin is the single provisioning authority for client users.** When CS-Admin onboards a client user it performs, **atomically**, both halves of the identity:

```
CS-Admin "create client user" (per-environment; uses THIS env's service-account key + THIS env's DB):
  BEGIN
    1. Firebase Admin SDK  createUser({ email, password|link })  in the CORRECT per-ENV project
       (Decision 6: packiot-staging for staging, fbpackiot for prod)  → uid
    2. INSERT/UPDATE users SET id_user_firebase = uid, id_enterprise = <tenant>, user_roles = ..., active = true
  COMMIT   (+ compensating Firebase delete if the DB write fails — no orphaned Firebase account)
```

**Why this is the right shape:**

1. **It closes the exact gap Decision 1 opens.** DB-lookup tenancy means a Firebase uid with **no** `users` row fails closed (401, correct) — but that also means a user is unusable until the `uid → id_enterprise` row exists. Doing both in **one transaction** guarantees there is never a half-provisioned user (a Firebase account nobody can attribute, or a `users` row pointing at a uid that was never minted). This is the standard "two systems, one logical create" outbox/saga problem; the compensating delete on rollback keeps Firebase and the DB consistent.
2. **It is per-ENV by construction (honors Decision 6).** CS-Admin is configured with the **target environment's** service-account key and points at the **target environment's** DB. Staging CS-Admin can only mint into `packiot-staging` + seed the staging DB; it **cannot** reach prod. The credential boundary from Decision 6 is enforced at the tool level.
3. **It retires manual minting.** The prior practice — a one-off admin script + the prod service-account key (`back4-api/private-key.json`) minting users by hand — is **retired**. That key is dead (deleted in GCP) and must not be resurrected. All new client-user creation goes through CS-Admin against the correct per-ENV project. (The one-off `packiot` **staging test user** is minted manually only because CS-Admin's staging wiring isn't stood up yet; it is the last hand-mint, and it uses the **staging** SA key, never the dead prod one.)

**Consequences:**
- CS-Admin gains a "create client user" flow (Firebase Admin SDK + the existing `users` write) — a concrete onboarding feature, sequenced after Decision 6's projects exist. This is the USER's stated future direction.
- Deactivation stays a **DB** operation (`active = false`) per Decision 1 — CS-Admin need not also disable the Firebase account for the tenant fence to stop resolving (though it may, defense-in-depth).
- No password material crosses environments or lands in a repo; the per-ENV SA key is the only secret, held in that env's secrets manager (Decision 6 / setup guide §4).

---

## 8. Operator session bootstrap after the flip (loose end from §decision 4)

Today `/session/login` returns more than a token: `{ entities, user, language, user_permissions }` — the SPA's `AuthContext` needs the operator's entity scope (which equipment/sectors they may act on) and localization. After bcrypt retires, that bootstrap still needs a home. Two options (design, not blocking): (a) a thin authenticated `/session/bootstrap` on edge-api that takes the Firebase Bearer and returns entities/language/permissions derived from `users.user_roles` (same query, no password step); or (b) move it to a refdata dataset (it is a *read*). Prefer (b) for consistency with the read-plane consolidation, but (a) is a smaller diff. Flag for the endgame, not the cutover.

---

## 9. Interaction with ADR-0032 — the `operator_pw_hash`-into-F3 seeding gap is RETIRED

ADR-0032's single-flow collapse must seed operator identity into `packiot_shadow` (F3) so shadow-mirror can replay operator actions there. Under **today's** bcrypt model, that implied carrying `operator_pw_hash` into the shadow DB — a password-hash-replication gap (extra secret material in a second database, extra sync surface).

**This ADR removes that gap entirely.** Once operator identity is Firebase-JWT, the *only* operator fact F3 needs is `uid → id_enterprise` (and optionally `user_roles`) — i.e. the `users.id_user_firebase` + `id_enterprise` columns. **No password hashes are replicated to `packiot_shadow`.** Firebase is the credential authority; the shadow DB holds only the tenant/role mapping needed to *attribute and fence* a replayed action. ADR-0032's seed step simplifies to: seed `id_user_firebase, id_enterprise, user_roles`; **do not** seed `operator_pw_hash`. (And Phase 3 here drops the column at source anyway.)

---

## 10. Risks & rollback

| Risk | Severity | Mitigation / rollback |
|---|---|---|
| **Offline operator can't mint a fresh token at drain** (refresh token revoked/expired, or never logged in online once) | High | The write stays `pending` in the durable queue (never lost) and the SPA prompts a re-auth; option-1 uid-binding strands it safely rather than mis-attributing. Rollback: Phase-1/2 flags off → api-key path resurfaces. |
| **Shared-tablet mis-attribution** (operator B drains A's writes) | High | §4.3 option 1: `enqueueUid` binding, drain only under matching session. This is *stricter* than today's advisory `x-user`. |
| **Firebase / Google cert endpoint outage** blocks writes | Medium | refdata already tolerates a transient cert-fetch blip (serves a stale-but-valid cached key). edge-api reuses that cache. Total Firebase outage = writes queue durably offline-style; no data loss. |
| **A `users` row lacks `id_user_firebase`** (unmigrated operator) | Medium | Phase-0 reconciliation report gates the cutover; such an operator keeps the bcrypt path until migrated (flag per-tenant). |
| **Cross-tenant write fence regression** | Critical | The fence is in SQL (`AND id_enterprise = $caller`), not a forgettable guard; add a CI isolation gate mirroring refdata's route-manifest gate — a PO/downtime mutation without the enterprise predicate fails the build. |
| **Clock skew rejecting valid tokens** | Low | 60s leeway (same as refdata's verifier). |

**Overall rollback:** every phase is flag-gated or config-reverted. The api-key + bcrypt paths are *removed*, not *broken*, and only after their per-tenant Firebase replacement bakes clean. Reverting a flag restores the prior credential path with zero data migration.

---

## 11. Open questions for the USER

- **OQ-1 — Tenant claim (decision 1):** confirm **DB lookup** as the end-state (recommended — reuses the proven refdata path, single source of truth, zero migration, the write fence hits the DB regardless), or opt for **Firebase custom claim** (self-contained token, but re-mint on enterprise move + a second source of truth to keep in sync).
- **OQ-2 — Operator token-refresh + shared-tablet strategy (decision 2):** confirm **persisted refresh token + just-in-time ID-token mint at drain + per-write `enqueueUid` binding** (recommended — preserves per-user non-repudiation, strands-until-owner-returns on a shared tablet), or opt into a **per-tablet device identity** (custom token) that trades per-user cryptographic attribution for shared-device ergonomics.
- **OQ-3 — Firebase project topology:** ~~is the **staging** Firebase project the **same** `fbpackiot` as prod, or a **separate** project?~~ **RESOLVED — SEPARATE project per environment (see [Decision 6](#7a-decision-6--firebase-project-topology-separate-project-per-environment-resolves-oq-3)).** Prod = `fbpackiot`, staging = `packiot-staging`; `FIREBASE_PROJECT_ID` is per-env for front4/refdata/edge-api; Phase-0 provisioning runs per-env; a staging token fails `aud` verification at the prod plane (and vice-versa). USER console steps: [`docs/auth/staging-firebase-setup.md`](../auth/staging-firebase-setup.md). The remaining open questions are OQ-1 and OQ-2 above.

---

## 12. What this ADR does NOT do

- No edge-api or operator **code** changes — this is the design + phased plan only.
- No prod change — staging-first, per-tenant, flag-gated, consistent with the standing staging-only directive.
- No change to Grafana/authentik or the M2M service-key paths.
- No change to the read plane's *behavior* — refdata is the model, adopted, not modified (edge-api may *share* its verifier logic, but refdata's contract is unchanged).
