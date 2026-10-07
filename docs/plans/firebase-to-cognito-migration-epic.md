# Epic — Firebase → Cognito auth migration (the #159 dual-path unblock)

Status: **#159 rescoped + SPLIT (2026-09-08).** #159 is now two distinct deliverables:
- **(a) New-stack Firebase cleanup — DONE + PROVEN.** Both new-stack planes are Firebase-free:
  staging (§9, PR #1130) and **prod new-stack (§10, PR #1141, deployed + hardproofed)**.
- **(b) `packiot40` → new-stack clean cutover — DEFERRED + GATED (design below, NOT executed).**
  The legacy customer plane (back4-api / edge-api-prod / 828 Firebase users) is untouched. It
  migrates LATER as a separate, human-green-lit program (§3-§8, §10.3). **`packiot40` is not
  touched — no schema change, no user deactivation, no writes — until that cutover is authorized.**

Everything below §3 that targets `packiot40` / back4-api / primary-api is deferred-cutover design,
not current work. Owner: platform.

**Why this epic exists.** Jira #159 wants to delete the Firebase auth *dual-path* (the
`FIREBASE_ISSUER` branch in edge-api, the unconditional `firebaseVerifier` in read-api, the
`id_user_firebase OR` clause in the tenant resolver). That removal is **proven-blocked**: the
entire legacy customer base still authenticates through Firebase. The `operator_pw_hash`
slice of #159 is already retired (staging done — see `operator-pw-hash-retirement.md` /
memory `project_159_operator_pw_hash_retired`); this epic scopes the *remaining* half.

Related prior art (do not duplicate — this epic depends on/extends them):
- ADR-0033 `docs/adr/0033-unified-firebase-jwt-auth.md` — the dual Firebase/Cognito Bearer verifier (edge-api).
- ADR-0034 `docs/adr/0034-adopt-cognito-amplify-auth.md` — Cognito adoption + JIT migrate-on-login Lambda.
- `docs/plans/front4-cognito-cutover-and-bi-migration.md` — the **new-stack** front4 read-cutover (refdata/edge-api on the `packiot` DB). That plan retires Firebase from front4 *by moving it onto the new stack*; this epic covers the **legacy `api4.packiot.com` plane** that plan does not touch.

---

## 0. TL;DR / verdict

There are **two independent production auth planes with two separate databases**. #159 is
blocked by the **legacy** one, which the new-stack work has never touched:

| Plane | Relying parties | DB | Firebase? | Cognito? |
|---|---|---|---|---|
| **Legacy customer** (`api4.packiot.com`) | back4-api, primary-api (=`packiot/api`), edge-api-prod, front4-prod | `packiot40`@18.220.223.110 (us-east-2) | **100% — 828 active users, 25 enterprises** | **none — column doesn't even exist** |
| **New-stack** (CPACK-migrated, not customer-serving) | edge-api(stack), refdata-api, barcode-service, operator | `packiot`@10.20.10.89 (us-east-1) | code-present, **config-dormant** | yes (dual-accept default) |

**The blocker in one line:** `back4-api` + `primary-api` are Firebase-ONLY relying parties
keyed on `users.id_user_firebase`, the `packiot40` DB has **no `id_user_cognito` column at
all**, and **no production Cognito pool exists** (the only pool org-wide is `packiot-staging`,
5 users). Until those are addressed and 828 users are backfilled, flipping `FIREBASE_ISSUER`
off would 401 the entire customer base.

Two viable strategies (detailed in §3):
- **Path B — dual-accept in place (recommended primary):** teach back4-api/primary-api to
  ALSO accept Cognito, add `id_user_cognito` to `packiot40`, JIT-migrate the 828 users on
  login, flip front4-prod to Cognito. Smallest blast radius; directly matches #159 option 1.
- **Path A — retire the legacy plane:** finish moving front4-prod onto the new stack
  (refdata + edge-api on `packiot`) and decommission back4-api/primary-api/`packiot40`. This
  is the org's stated direction but is a full re-platforming (all 25 enterprises' *data* must
  land on the new stack first) — far larger, and gated on the analytics migration.

Recommendation: **Path B to unblock #159 now; converge to Path A later.** The two are
compatible — Path B leaves every user Cognito-native, which is exactly the precondition Path A
needs anyway.

---

## 1. Current-state hardproof (inventoried 2026-09-08, file:line evidence)

### 1.1 Relying parties — Firebase verification + `id_user_firebase` resolution

**back4-api** (`packiot/back4-api`, branch `fix/back4-yarn-dev` @ `13f6247`; deployed branch
`main` → EB `back4-api-main`, **us-east-2**, app `piot4backend`). **Pure Firebase, zero Cognito.**
- Init: `src/server.js:48-51` `initializeApp({credential: cert(serviceAccount), databaseURL:"https://fbpackiot.firebaseio.com"})`.
- Verify: `src/app/middlewares/auth.js:8-9` `getAuth().verifyIdToken(token)`; same in dead `authDevices.js:8-9`; and in `UsersController.js` (`:244-245`, `:326`) + `UserRolesController.js`.
- Middleware contract: reads headers **`token`** (Firebase ID token) + **`uid`**; verifies, asserts `decoded.uid == req.headers.uid`, `next()`. Attaches **no** user object — controllers resolve tenant themselves. Wired ONLY on `app.use('/api/admin/*', …)` (`server.js:104`).
- Tenant resolution: `SELECT id_enterprise FROM users WHERE id_user_firebase = $uid` across ~9 controllers (UsersController, ProductionOrders(Ordens), DowntimeReasons, Pages, UserRoles).
- Cognito grep (incl. node_modules): **0 hits.** No `aws-jwt-verify`, no `@aws-sdk/client-cognito*`.
- Dep: `firebase-admin ^11.0.0` (lock 11.7.0). Node 16.
- **SECURITY:** `private-key.json` (a live `firebase-adminsdk-31o62@fbpackiot` service-account private key) is **committed to git** (only `.env` is gitignored) and bundled into every deploy zip (`.github/workflows/main.yml:25`, loaded `server.js:9`). Must be **rotated** when Firebase is removed regardless of this epic.

**primary-api** = `packiot/api` (redirect; local `/home/podesta/github/packiot/primary-api` is a
throwaway container-volume stub, not source). NestJS/TS on **EKS via ArgoCD**. **Pure Firebase, zero Cognito.**
- Verify: `src/auth/strategies/firebase.strategy.ts:86` `admin.auth().verifyIdToken(token)` → `{uid: decoded.user_id, idEnterprise: decoded.id_enterprise}`. Guards: `firebase-auth.guard.ts`, `multi-auth.guard.ts` (Firebase + api-key strategies only).
- `id_user_firebase`: `prisma/schema.prisma:402` (`@unique VarChar(255)`), `migrations/20230817143018_create_users.ts:12`, repo `users.prisma.repository.ts:36/66/88`.
- Cognito / `id_user_cognito` / `aws-jwt-verify`: **0** by direct file inspection. Dep: `firebase-admin ^13.3.1`.

**edge-api** (shared codebase; prod EB env `edge-api-prod-docker-env` = `edge.api4.packiot.com`).
The dual-accept Bearer verifier is **already built** (ADR-0033) — the Firebase leg is purely env-gated:
- `src/shared/auth/bearer-jwt.config.ts:107-120` builds a Firebase issuer ONLY when `FIREBASE_ISSUER` + `FIREBASE_AUDIENCE` are set (dropped otherwise). Cognito issuer at `:93-105`. `BearerIssuerSource = 'firebase'|'cognito'` at `:16`.
- Column map: `src/data/DAO/auth-middleware/auth-user-dao.ts:15-16` `{firebase:'id_user_firebase', cognito:'id_user_cognito'}`; link-on-login self-heal `:77-81` (single-row).
- Prod edge-api env: **no `FIREBASE_ISSUER`/`COGNITO_*`** → Bearer path has zero issuers → api-key only; front4-prod's Firebase token is never presented here. Staging edge-api: `FIREBASE_ISSUER=https://securetoken.google.com/fbpackiot` + `FIREBASE_AUDIENCE=fbpackiot` + Cognito → dual-path ACTIVE.

**read-api / refdata-api** (`services/read-api/cmd/refdata-api`, shared, new-stack only). Firebase is
**unconditional by design**:
- `main.go:306` `var bv verifier = newFirebaseVerifier(projectID, nil)` — always constructed. Cognito wrapped in `multiVerifier` when `COGNITO_AUTH_ENABLED` (default ON) + pool ids resolve (`main.go:309-321`).
- Unified resolver: `auth_firebase.go:93-95` `WHERE (id_user_firebase = $1 OR id_user_cognito = $1) AND active AND id_enterprise IS NOT NULL`.
- Cognito verifier `auth_cognito.go`; link-on-login `linkCognitoSQL` `auth_firebase.go:405-411` (single-row `ORDER BY id_user ASC` dup-email guard, ADR-0034).

**barcode-service** (`services/barcode-service`, new-stack) — a **fifth relying party**, already
dual Firebase/Cognito (`cmd/barcode-service/auth_{firebase,cognito}.go`; `main.go:74` Firebase default-on unless `firebaseProject==""`).

**operator** — already **Cognito-only** (memory `session_operator_cognito_auth_cutover`; retired DB bcrypt/HS256). No Firebase leg. Not a blocker; a template for the end-state.

**front4** (`packiot/front4`; prod = `origin/production` @ `36c3c3f`, built `--mode production`).
Cognito login code is **shipped to prod but dark**:
- Gate `src/cognito.js:45-48`: `COGNITO_ENABLED = VITE_AUTH_COGNITO_ENABLED==="true" && VITE_COGNITO_USER_POOL_ID && VITE_COGNITO_USER_POOL_CLIENT_ID`.
- `.env.production`: all three **UNSET** → Firebase path (`firebase.js:24` inits real `fbpackiot`; `authToken.js` returns Firebase token as header `token`+`uid` to `api4.packiot.com`, Bearer to `edge.api4.packiot.com`). Targets: `VITE_API_URL=https://api4.packiot.com/`, `VITE_EDGE_API=https://edge.api4.packiot.com`; **no refdata in prod**.
- `.env.staging`: `VITE_AUTH_COGNITO_ENABLED=true`, pool `us-east-1_0T9t1sTwt`, client `2ckuoa0ov598rdpdn3uv039h6e` — Cognito live on staging.
- Full Cognito path built: `Amplify.configure` (`cognito.js:50-61`), `loginCognito` (`AuthContext.jsx:167-211`, `USER_PASSWORD_AUTH` so the migration Lambda fires). Deps: `aws-amplify ^6.6.0`, `firebase ^9.1.3`.
- **Unfinished:** migrate-on-login *account linking* client (`services/cognitoLink.js:41-44`) — comment states the `POST /users/cognito-link` endpoint + `id_user_cognito` write path do NOT exist on the legacy plane; rows are seeded out-of-band. Also password-reset + MS-OAuth are Firebase-only and go inert under Cognito (`AuthContext.jsx:104/128/237`).

### 1.2 User counts (live queries, 2026-09-08)

| DB | total | active | active Firebase | active Cognito | **active FB-only (need migrate)** | active enterprises |
|---|---|---|---|---|---|---|
| **`packiot40`** (legacy prod, us-east-2) | 967 | 828 | **828** | n/a (no column) | **828** | **25** |
| `packiot` (new-stack prod, us-east-1) | 3 | 3 | 0 | 1 | 0 | — |
| `packiot_analytics` (staging) | 8 | 8 | 5 | 2 | **4** | — |

- `packiot40.users` columns: `id_user, id_enterprise, id_user_firebase (varchar), user_email, active` — **no `id_user_cognito`, no `cognito` column of any kind.** The new-stack `migration 32-cognito-user-id.sql` was never applied here.
- **Dup-email audit on `packiot40` (active):** 2 emails collide, 4 rows involved → the single-row `ORDER BY id_user ASC` link guard (proven on read-api) is **mandatory** here.

### 1.3 Cognito + migration-Lambda state

- **Only ONE Cognito user pool exists org-wide:** `us-east-1_0T9t1sTwt` name **`packiot-staging`**, 5 users. **No production pool** (checked us-east-1 + us-east-2).
- Migration Lambda `packiot-staging-cognito-user-migration` (nodejs20.x) IS deployed and wired as the pool's `UserMigration` trigger. Env: `MIGRATION_ENABLED=true`, `FIREBASE_PROJECT_ID=fbpackiot` (the real prod Firebase project — there's only one), `FIREBASE_WEB_API_KEY_SECRET_ID=packiot/staging/firebase-web-api-key`. So JIT migration is *live on staging* and validates against real `fbpackiot` passwords.
- Handler `services/cognito-user-migration/index.mjs`: gate at `:296` (`MIGRATION_ENABLED!=="true"` → deny), `handleAuthentication` `:217` (signInWithPassword → mint Cognito user CONFIRMED + SUPPRESS), `handleForgotPassword` `:255`. Zero forced resets.
- Terraform: `terraform/staging/cognito.tf` (pool + `front4` client + hosted-ui domain + `oauth2_proxy` client) and `terraform/staging/cognito_migration_lambda.tf` (secret + IAM + lambda + `aws_lambda_permission.cognito_invoke`). **`terraform/production/` has NEITHER** — no `cognito.tf`, no lambda (`production/edge.tf` only mentions Cognito in an nginx comment).

**Conclusion:** every prerequisite for a legacy cutover is missing on the prod side — pool,
lambda, DB column, and any Cognito verifier in back4-api/primary-api.

---

## 2. The invariant to preserve at every step

`credential → server-derived tenant → query`. No client ever names a tenant; the server maps
`verified uid → id_enterprise` (Firebase: `id_user_firebase`, Cognito: `id_user_cognito`). The
whole cutover must keep **at least one credential path valid for every user at every moment** —
dual-accept, never a flag-day swap. This is exactly the read-api/edge-api posture; we extend it
to the legacy plane.

---

## 3. Migration design

### 3.0 Path decision

Adopt **Path B (dual-accept in place)** as the #159 unblock. Path A (retire) is tracked
separately (it is the `front4-cognito-cutover-and-bi-migration.md` + analytics-migration
program); this epic makes every legacy user Cognito-native, which Path A also requires, so no
work is wasted.

### 3.1 Phase 0 — infra prerequisites (no user impact, fully reversible)

1. **Provision a dedicated production Cognito pool** `packiot-prod` (do NOT reuse the
   `packiot-staging` pool — mixing planes in one pool is a hygiene/blast-radius hazard, and
   staging test users would become prod-authenticatable). Port `terraform/staging/cognito.tf`
   → `terraform/production/cognito.tf`: pool + `front4` app client (public SPA, `USER_PASSWORD_AUTH`
   + SRP) + hosted-ui domain + (if used) `oauth2_proxy` client. Emit issuer + client id as tf outputs.
   - Decision to confirm with architect: **one prod pool spanning both prod planes** (legacy
     `packiot40` + new-stack `packiot`) vs. two. One pool is simpler for front4 and lets a user
     who later moves to the new stack keep the same identity; the resolver already keys on the
     opaque `sub`, so a single pool works for both DBs. **Recommend one prod pool.**
2. **Provision the prod migration Lambda** `packiot-prod-cognito-user-migration` from
   `terraform/staging/cognito_migration_lambda.tf`: create secret `packiot/prod/firebase-web-api-key`
   (the `fbpackiot` **web** API key — semi-public Identity-Toolkit key, NOT the admin
   private key), IAM (logs + `secretsmanager:GetSecretValue` on that ARN only), lambda
   (`FIREBASE_PROJECT_ID=fbpackiot`, `MIGRATION_ENABLED=false` initially), and the
   `aws_lambda_permission` + pool `UserMigration` trigger wiring. **Inert while `MIGRATION_ENABLED=false`.**
3. **Add the `id_user_cognito` column to `packiot40`** (the legacy DB migration mirroring
   new-stack `32-cognito-user-id.sql`):
   ```sql
   ALTER TABLE users ADD COLUMN id_user_cognito varchar(255);
   CREATE UNIQUE INDEX CONCURRENTLY users_id_user_cognito_key
     ON users (id_user_cognito) WHERE id_user_cognito IS NOT NULL;
   ```
   Additive + nullable → zero impact on the running Firebase path. This is the schema
   precondition for both the backend resolver OR-clause and the link-on-login write.
4. **Audit + resolve the 2 dup-email collisions** on `packiot40` before enabling linking
   (decide which row is canonical per collision; the guard picks `ORDER BY id_user ASC` = the
   real/earliest row, but confirm the 4 rows are real-vs-sandbox, not two live people).

### 3.2 Phase 1 — backends become dual-accept relying parties (additive; behavior-neutral while front4 still sends Firebase)

Two Node relying parties (back4-api, primary-api) must ALSO accept a Cognito token and resolve
by `id_user_cognito OR id_user_firebase`. **Recommendation: a small shared npm verifier lib**
`@packiot/cognito-verifier` (thin wrapper over `aws-jwt-verify`, the AWS-maintained JWKS
verifier) consumed by both — mirrors the read-api/edge-api contract (verify RS256/JWKS,
enforce iss+aud+exp, return `{sub, email, email_verified, idp}`) and avoids two divergent
hand-rolled verifiers. (Alternative: per-repo copies; rejected — two code paths to keep in
sync for a security primitive.)

- **primary-api (`packiot/api`, NestJS):** add a `cognito.strategy.ts` alongside
  `firebase.strategy.ts`, register it in `multi-auth.guard.ts` so a request authenticates if
  EITHER strategy passes. Resolver: `SELECT id_enterprise FROM users WHERE id_user_cognito=$1 OR id_user_firebase=$1`.
  Add the link-on-login upsert (verified email, single-row) so an existing user's first Cognito
  login binds `id_user_cognito`. Gate behind `COGNITO_AUTH_ENABLED` (default OFF in prod until cutover).
- **back4-api (Express):** the awkward one — it authenticates via **headers `token`+`uid`**,
  not `Authorization: Bearer`. Extend `src/app/middlewares/auth.js` to: if a Cognito token is
  present (accept it on `Authorization: Bearer` AND/OR the existing `token` header, distinguished
  by `iss`), verify via `@packiot/cognito-verifier`, set `req.headers.uid` to the resolved uid
  space the controllers expect. Because ~9 controllers resolve `WHERE id_user_firebase = uid`
  directly, the cleanest minimal change is a **shared resolver helper** `resolveEnterpriseByUid(uid, idp)`
  that runs `WHERE id_user_cognito=$1 OR id_user_firebase=$1` and have the controllers call it
  (or, lower-touch: have the middleware translate a verified Cognito `sub` → the row's
  `id_user_firebase` value and keep controllers unchanged during cutover, then clean up in
  Phase 4). Gate behind `COGNITO_AUTH_ENABLED` (default OFF).
- **edge-api-prod:** set `COGNITO_ISSUER` + `COGNITO_CLIENT_ID` (prod pool) on
  `edge-api-prod-docker-env`. Code is already dual-accept; this just lights up the Cognito leg.
  Leave `FIREBASE_ISSUER` UNSET for now (front4-prod doesn't present Firebase to edge-api today;
  once front4 sends Cognito Bearer it resolves via the new column). Optionally set `FIREBASE_*`
  too for belt-and-suspenders during overlap.

All Phase-1 changes are **additive and default-off/dormant** → deploying them changes nothing
while front4-prod still issues Firebase tokens.

### 3.3 Phase 2 — backfill strategy (JIT migrate-on-login + link-on-login)

No bulk password import is possible (Firebase scrypt ≠ Cognito). Use the ADR-0034
**migrate-on-login** path, which needs no forced resets:

1. Turn the prod migration Lambda **ON** (`MIGRATION_ENABLED=true`) — still inert until a
   Cognito login is *attempted*, which only happens once front4-prod flips (Phase 3). Ordering:
   enable it just-before the front4 flip.
2. On a user's first Cognito login: pool has no such user → `UserMigration_Authentication`
   fires → Lambda validates the typed password against `fbpackiot` via Identity Toolkit →
   Cognito creates the user CONFIRMED carrying that password (`index.mjs:245-247`). User is now
   Cognito-native, **same password**, no email.
3. Backend receives the Cognito token; `sub` not yet in `id_user_cognito` → **link-on-login
   self-heal**: bind `id_user_cognito` to the row whose `lower(user_email)` matches the
   **verified** email claim, `id_user_cognito IS NULL`, `active`, **single-row `ORDER BY id_user ASC`**
   (the exact SQL proven in read-api `auth_firebase.go:405`; replicate in back4-api + primary-api
   against `packiot40`). Idempotent; a second login is a no-op.
4. Coverage: JIT covers *actives as they log in*. For the tail (infrequent logins) run an
   optional **admin-driven pre-provision** for the 828 rows near the end (AdminCreateUser
   SUPPRESS + set `id_user_cognito`) so a `FIREBASE_ISSUER`-off date isn't hostage to the last
   sleepy user — but never before front4 flips, or you'd create Cognito users no one uses.

**Dup-email guard:** the single-row subselect is what makes the 2 `packiot40` collisions safe —
without it the partial-unique index rejects the multi-row write and the sub is never linked
(this is the exact bug that left `0001_os2` dark on staging; see memory
`session_front4_cognito_linking_and_console`).

### 3.4 Phase 3 — front4-prod cutover (the user-visible flip)

Prereqs met: prod pool live, prod lambda ON, back4-api + primary-api + edge-api-prod
dual-accepting, `packiot40.id_user_cognito` column + link-on-login live.

Set in `front4/.env.production` and ship a prod build:
```
VITE_AUTH_COGNITO_ENABLED=true
VITE_COGNITO_USER_POOL_ID=<prod pool id>
VITE_COGNITO_USER_POOL_CLIENT_ID=<prod front4 client id>
VITE_COGNITO_LINK_ENABLED=false   # link happens server-side; keep client link off unless the endpoint is built
```
Effect: `firebase.js:24` no longer inits Firebase; `authToken.js` issues the Cognito ID token;
`loginCognito` runs. First login per user drives JIT-migrate + server link. **Reversible**:
revert the three vars + rebuild → back to Firebase instantly (users already migrated keep
working because the backend is still dual-accept).

Sequencing so **no user is locked out**:
1. Phase 0 + Phase 1 deployed (dormant). Firebase still 100% live. ✅ no change.
2. Enable prod migration Lambda (`MIGRATION_ENABLED=true`). ✅ still inert (no Cognito logins yet).
3. Flip front4-prod env → build → deploy. New logins migrate+link; already-linked users
   resolve via Cognito; the backend still accepts Firebase for anything mid-flight. ✅
4. Soak until `active AND id_user_cognito IS NULL` → 0 (dashboard the count). Pre-provision the tail. ✅
5. Only then Phase 4.

### 3.5 What "retire" (Path A) would mean instead

If the org prefers to retire rather than dual-accept: complete
`front4-cognito-cutover-and-bi-migration.md` W1 (front4-prod → refdata-api + edge-api on the
`packiot` DB), migrate all 25 enterprises' operational data onto the new stack, repoint
`api4.packiot.com`/`edge.api4.packiot.com` DNS at the new stack, and decommission
back4-api + primary-api + `packiot40`. Firebase then survives only in code → delete per §5.
This is a program, not a phase; it is the strategic end-state, not the #159 unblock.

---

## 4. Staging-first validation plan

Staging already runs Cognito dual-accept (pool `packiot-staging`, front4 `.env.staging`
enabled, migration Lambda ON). Use it to rehearse the *whole* Path-B sequence before prod:

1. **Prove JIT + link end-to-end on staging** for the **4 remaining FB-only actives**
   (`packiot_analytics`): confirm each can log in via Cognito, gets migrated, and
   `id_user_cognito` populates (single-row link, no partial-unique errors). This is the live
   proof the 828-user prod path will work.
2. **Stand up back4-api-dev + primary-api-dev (or a staging clone) as Cognito relying parties**
   against a staging copy of the `packiot40` schema with the `id_user_cognito` column, and prove
   a Cognito token resolves the tenant AND a Firebase token still resolves (dual-accept holds).
   This is the piece that has never been exercised — back4/api have zero Cognito code today.
3. **Prove Cognito-only on staging** by flipping `FIREBASE_ISSUER`/`COGNITO_AUTH_ENABLED=firebase-off`
   on staging edge-api + read-api AFTER step 1 zeroes the FB-only actives; confirm no 401s for a
   sustained window (this is the dress rehearsal for the prod `FIREBASE_ISSUER`-off).
4. **Verify rollback**: re-enable Firebase on staging, confirm instant recovery.

Gate to prod: staging shows `active AND id_user_cognito IS NULL = 0` AND back4/api dual-accept
proven AND a clean Firebase-off soak.

---

## 5. Firebase-removal PR set (the #159 deletion — only after §3 Phase 4 gate)

Execute in this order (stop writing/verifying the credential before deleting its resolution),
staging-first then prod, each reversible until the last:

1. **Flip `FIREBASE_ISSUER` off** on staging edge-api → soak → prod edge-api. (Config only; no code.)
2. **read-api** — remove the Firebase leg:
   - `cmd/refdata-api/main.go:306` unconditional `newFirebaseVerifier` → make Cognito the sole verifier (drop the `multiVerifier`, or keep it Cognito-only).
   - `cmd/refdata-api/auth_firebase.go:93-95` `usersEnterpriseSQL` — drop `id_user_firebase = $1 OR`, leaving `WHERE id_user_cognito = $1 AND active AND id_enterprise IS NOT NULL`.
   - Delete `auth_firebase.go` verifier/certCache (keep the resolver/link plumbing, now Cognito-only); drop `COGNITO_AUTH_ENABLED` (becomes always-on) + `FIREBASE_PROJECT_ID`.
3. **edge-api** — `src/shared/auth/bearer-jwt.config.ts:107-120` remove the Firebase issuer block + `'firebase'` from `BearerIssuerSource` (`:16`); `src/data/DAO/auth-middleware/auth-user-dao.ts:15` drop the `firebase:'id_user_firebase'` column mapping. Drop env `FIREBASE_ISSUER`/`FIREBASE_AUDIENCE`.
4. **barcode-service** — `cmd/barcode-service/auth_firebase.go` + the `firebaseProject` default (`main.go:74`); make Cognito-only.
5. **back4-api** — remove `firebase-admin` dep, `src/app/middlewares/auth.js` Firebase branch (Cognito-only), `authDevices.js` (dead), Firebase usage in Users/UserRoles controllers; **delete `private-key.json` from git history + rotate the leaked service-account key**; drop it from the deploy zip (`.github/workflows/*.yml:25`).
6. **primary-api (`packiot/api`)** — delete `firebase.strategy.ts`, `firebase-auth.guard.ts`, Firebase from `multi-auth.guard.ts`, `firebase-admin` dep.
7. **front4** — remove `src/firebase.js`, the Firebase branches in `authToken.js`/`AuthContext.jsx`, `firebase` dep; make the reset + MS-OAuth flows Cognito-native or drop them.
8. **DB (last, after zero Firebase reads for a full soak):** optionally `ALTER TABLE users DROP COLUMN id_user_firebase` on `packiot40` (and new-stack `packiot`) — separate deploy, gated on a zero-reader log-watch (same rule as the `operator_pw_hash` drop).
9. Retire the Firebase migration Lambda + `fbpackiot` web-api-key secret once no user can ever hit the JIT path again.

Flags to drop by the end: `FIREBASE_ISSUER`, `FIREBASE_AUDIENCE`, `FIREBASE_PROJECT_ID`,
`COGNITO_AUTH_ENABLED` (→ always-on), `MIGRATION_ENABLED`, front4 has no Firebase vars left.

---

## 6. Risk / rollback

| Risk | Likelihood | Mitigation |
|---|---|---|
| A user can't log in after front4-prod flip (JIT/link fails) | Med | Dual-accept everywhere → revert front4 env (3 vars + rebuild) = instant Firebase restore; migrated users unaffected. Nothing deleted until §5. |
| Dup-email breaks linking (partial-unique reject → permanent 401) | **Confirmed present (2 cases on `packiot40`)** | Single-row `ORDER BY id_user ASC` guard (proven in read-api); pre-audit the 4 rows in Phase 0.4. |
| Wrong-tenant link (email shared across enterprises) | Low | `email_verified` required; single-row picks earliest/real row; audit collisions manually before enabling. |
| Leaked `fbpackiot` admin private key (committed in back4-api) | **Confirmed, live now** | Rotate the service-account key at Phase 4.5 regardless; scrub from git history. Independent of cutover. |
| Reusing the staging pool for prod → staging test users authenticatable in prod | Med if shortcut taken | Provision a **dedicated prod pool**; do not point front4-prod at `packiot-staging`. |
| No prod pool/lambda/DB-column today → premature `FIREBASE_ISSUER`-off = total outage | High if skipped | The whole Phase-0/1 gating; never flip Firebase off before `active AND id_user_cognito IS NULL = 0`. |
| back4-api header-auth (`token`/`uid`) can't cleanly carry a Cognito token | Med | Shared resolver helper + middleware `iss`-based routing; lowest-touch fallback maps verified `sub`→row then keeps controllers unchanged during cutover. |
| primary-api on EKS — secrets via External Secrets/OIDC, not EB | Low | Add the Cognito issuer/client as non-secret env; no new secret needed (public JWKS). |

Rollback posture overall: **every phase before §5 is a config/flag revert.** The point of no
easy return is deleting `id_user_firebase` reads (§5.2-3) — do those only after a clean soak.

---

## 7. Ordered checklist (with owners)

Owners are role placeholders — assign at kickoff.

**Phase 0 — infra prereqs (platform + DBA)**
- [ ] Architect decision: one prod pool vs. per-plane; dual-accept (Path B) vs. retire (Path A). — *architect*
- [ ] `terraform/production/cognito.tf` — prod pool + front4 client + hosted-ui (+ oauth2_proxy). — *platform*
- [ ] `terraform/production/cognito_migration_lambda.tf` + `packiot/prod/firebase-web-api-key` secret; `MIGRATION_ENABLED=false`. — *platform*
- [ ] `packiot40`: add `id_user_cognito` + partial-unique index (CONCURRENTLY). — *DBA*
- [ ] Audit + resolve the 2 dup-email collisions on `packiot40`. — *DBA*

**Phase 1 — dual-accept backends (backend)**
- [ ] `@packiot/cognito-verifier` shared lib (aws-jwt-verify wrapper). — *backend*
- [ ] primary-api: `cognito.strategy.ts` + multi-auth + OR-resolver + link-on-login (flag OFF). — *backend*
- [ ] back4-api: middleware Cognito acceptance + `resolveEnterpriseByUid` OR-resolver + link-on-login (flag OFF). — *backend*
- [ ] edge-api-prod: set `COGNITO_ISSUER`/`COGNITO_CLIENT_ID` (prod pool). — *platform*

**Phase 2/3 — validate then cut over (backend + frontend + platform)**
- [ ] Staging rehearsal §4 steps 1-4 (incl. the 4 FB-only actives migrated). — *backend/QA*
- [ ] Enable prod migration Lambda (`MIGRATION_ENABLED=true`). — *platform*
- [ ] front4 `.env.production` Cognito vars + prod build/deploy. — *frontend*
- [ ] Dashboard `active AND id_user_cognito IS NULL` on `packiot40`; drive to 0; pre-provision tail. — *backend*

**Phase 4 — remove Firebase (§5) — only after gate (all)**
- [ ] `FIREBASE_ISSUER` off (staging→prod), soak.
- [ ] read-api / edge-api / barcode-service Firebase-leg deletions.
- [ ] back4-api / primary-api / front4 Firebase deletions; **rotate + scrub `private-key.json`**.
- [ ] DROP `id_user_firebase` (separate, zero-reader-gated deploy).
- [ ] Retire migration Lambda + `fbpackiot` web-api-key secret.

---

## 8. EXECUTION STATUS + hardproofed blockers (2026-09-08)

Mandate was upgraded to *execute* this (staging-first, hardproof-gated). Two facts
discovered during execution **invalidate the naive staging-first sequence** and trip the
mandate's own STOP condition ("if backfill can't reach 100%, STOP and report which users/why").

### 8.1 Done (safe, reversible, proven)
- **back4-api dual-accept Cognito verifier** — branch `feat/cognito-dual-accept` (off `origin/main`),
  commit `e7bbaa9`. Additive, **dark by default** (`COGNITO_AUTH_ENABLED` unset + null verifier
  when `COGNITO_*` unset → byte-for-byte Firebase behavior). Files:
  `src/app/services/cognitoVerifier.js` (aws-jwt-verify wrapper + iss-peek router),
  `src/app/middlewares/cognitoDualAuth.js` (verify → resolve by `id_user_cognito`, link-on-login
  by VERIFIED email with the single-row `ORDER BY id_user ASC` dup guard, **normalizes identity to
  the row's `id_user_firebase` so all ~9 controllers stay unchanged during overlap**),
  rewired `src/app/middlewares/auth.js`, `+aws-jwt-verify ^4.0.1`. **11 unit tests pass**
  (`npx jest .../cognitoDualAuth.test.js`), `node --check` clean, module loads with Cognito dark.
  NOT deployed (see 8.3).

### 8.2 BLOCKER A — the legacy plane has NO safe staging (staging-first is impossible for it)
- `back4-api-dev` (EB, us-east-2) points at **the same `packiot40`@18.220.223.110 prod DB** as
  `back4-api-main` (verified via EB config). back4-api has **no `staging` branch** (only `main`, `dev`).
- `front4` **staging** targets the **new stack** (`api.staging.packiot.app` = edge-api/refdata on
  `packiot_analytics`), **never** back4-api/primary-api. The legacy plane is exercised ONLY by front4-**prod**.
- ⇒ There is no non-prod environment in which to deploy+prove back4-api/primary-api dual-accept, and
  any `id_user_cognito` DDL/backfill on `packiot40` **is a prod-customer-DB write**. Per the standing
  user rule (sandbox-first; prod touch = explicitly-authorized exception) this requires **either a
  `packiot40` sandbox clone** (the CPACK-replica pattern) **or an explicit green-light** for an
  additive, default-off prod deploy. Not done in this session.

### 8.3 BLOCKER B — 100% backfill is IMPOSSIBLE without data remediation (would lock users out)
An email-keyed Cognito pool + email link-on-login **cannot** migrate users who have no email or who
share an email. Hardproofed on `packiot40` (active users):
- **2 duplicate-email collisions, both enterprise 37 (Suzano):** `jorgempv@suzano.com.br`
  (id_user 609 + 641), `ottospigariol.3sv@suzano.com.br` (id_user 507 + 612). Cognito holds each
  address once → only the earliest row can ever link; the other row is **permanently unreachable
  from Cognito** → 401/lock-out on a Firebase-off flip.
- **5 active users with NULL/empty email** → **cannot be email-linked at all**.
- Staging (`packiot_analytics`) shows the same class: `0001_os2@packiot.com` is active + fb-only on
  BOTH `id_user=3` (ent 3) and `id_user=2000003` (ent 2000003) → even staging can't reach 100% by link.
- ⇒ **STOP per mandate.** Before ANY Firebase-off flip, these **7 prod rows** need an owner decision:
  deactivate the stale/duplicate rows (confirm which of 507/612 and 609/641 is live), and give the
  5 no-email actives a real verified email or pre-provision them by `sub` out-of-band. Flipping
  Firebase off before this = locking out those users.

### 8.4 Prod removal — staged, NOT executed (needs green-light)
No prod change was made. The prod removal is the §5 PR set, gated on ALL of:
1. **Provision prod Cognito pool + prod migration Lambda + `packiot40.id_user_cognito` column** (§3.1) — none exist today.
2. **Deploy back4-api + primary-api dual-accept** (COGNITO_* + flag OFF) → prove a Cognito token → 200 on both while Firebase still 200s. (back4-api code ready on `feat/cognito-dual-accept`; **primary-api mirror still to write** — a `cognito.strategy.ts` + multi-auth registration + OR-resolver + link-on-login in `packiot/api`, same contract; it is a NestJS/EKS repo not checked out locally.)
3. **Backfill to provable 100%:** `SELECT count(*) FROM users WHERE active AND id_user_firebase IS NOT NULL AND id_user_cognito IS NULL` on `packiot40` must reach **0** — after remediating the 7 rows in 8.3. Backfill = front4-prod Cognito flip drives JIT-migrate + link, tail pre-provisioned.
4. **Then** the §5 Firebase-removal PR set + column drop, staging-proven first on the new-stack plane.
- **Deploy order:** pool/lambda/column → back4+api dual-accept (flag off) → enable flag + prod migration Lambda → remediate 7 rows → front4-prod Cognito flip → soak to 0 fb-only → `FIREBASE_ISSUER` off → code removal → drop `id_user_firebase`.
- **Rollback (each step, until column drop):** revert front4 env (3 vars + rebuild) / set flag off / re-enable `FIREBASE_ISSUER`. Nothing irreversible before the column drop; do that only after a zero-Firebase-reader soak.
- **The final front4-prod Cognito flip is the one action reserved for explicit human green-light** (it locks the customer base if wrong and is slow to reverse).

## 9. STAGING EXECUTION (new-stack plane) — DONE + PROVEN (2026-09-08)

Scope narrowed by the user to STAGING ONLY (legacy/prod promotion deferred). Executed the
Firebase removal on the new-stack staging plane (`packiot_analytics`, edge-api + read-api +
barcode-service; front4-staging already Cognito). All hardproof-gated.

**Step 1 — backfill (DONE, proven 0 fb-only).** Of the 4 active Firebase-only staging users,
exactly one was a real Firebase identity: `id_user=3` (0001_os2@, ent 3, real uid `nUcZHLJj…`)
→ linked to Cognito sub `d458f418…` via the single-row `ORDER BY id_user ASC` guard. The other
3 (`2000002/2000003/2000004`, ent 2000003 sandbox tenant) carried SYNTHETIC `sbx-200000X`
placeholder uids — not real Firebase identities, so no real user is locked out; their synthetic
uids were cleared (reversible). Verified: `active AND id_user_firebase IS NOT NULL AND
id_user_cognito IS NULL` = **0**.

**Step 2 — code removal (DONE, vetted).** Branches:
- edge-api `feat/159-remove-firebase-leg` @ `b8c6a73`: removed FIREBASE issuer block +
  narrowed `BearerIssuerSource` to `'cognito'`; dropped the firebase→id_user_firebase column
  map; removed id_user_firebase from `users-dao.ts` INSERT/SELECT + create-user/list-users DTOs
  + seed; specs updated. **nest build OK, tsc clean, 90 tests green.**
- read-api (in stack-alpha PR): Cognito is the sole verifier (single-entry `multiVerifier`
  preserves idp-tag + link-on-login), `usersEnterpriseSQL` resolves by `id_user_cognito` only.
  **go build + vet + tests green** (CI `read-api — vet/test/build` PASS).
- compose.staging.yml: dropped edge-api `FIREBASE_ISSUER/AUDIENCE`; set barcode-service
  `FIREBASE_PROJECT_ID=""` (disables its firebase lookup, so its id_user_firebase SQL never runs).

**Step 3 — deploy + hardproof (DONE).** Merged as stack-alpha **PR #1130** (all required checks
incl. "Validate compose files" green) → deploy-staging run `34187284306` **success**. Live:
- read-api: Cognito `/v1/catalog` → **200**, `/v1/query enterprise-config` → **200** (tenant
  2000003 resolved via id_user_cognito); Firebase-iss token → **401**.
- edge-api: Cognito bearer → **403** (authenticated, authz-forbidden = token VERIFIED);
  Firebase-iss token → **401**; no-cred → 401.
- Deployed config confirmed: edge-api env has **no FIREBASE_ISSUER**; barcode
  `FIREBASE_PROJECT_ID=""`. **0 `42703` errors** in edge-api/read-api since deploy.

**Step 4 — column DROP: GATED (not executed).** DB dependency audit found `users.id_user_firebase`
is used by the legacy Hasura-parity view **`public.v_user_menu`** (as a passthrough identity
column; **0 objects depend on that view**). A plain `DROP COLUMN` errors (RESTRICT); `CASCADE`
would drop the view. Correct remediation (a follow-up migration, NOT done live to avoid
uncodified shared-staging schema drift): `DROP VIEW v_user_menu; CREATE VIEW v_user_menu …`
minus the `id_user_firebase` passthrough (4 SELECT refs + GROUP BY), update the init SQL
(`edge-node-red/db/19-hasura-full-parity.sql`) to match, then `ALTER TABLE users DROP COLUMN
id_user_firebase` (auto-drops indexes `users_id_user_firebase_unique` + `uid_firebase_un`).
The column is now DEAD (0 code readers — proven) so it is harmless to leave until this migration.

**Note:** `sandbox@packiot.com` (throwaway staging Cognito account) password was set to a temp
value to obtain a proof token; it is an internal sandbox account.

## 10. PROD NEW-STACK execution + #159 split + deferred `packiot40` cutover (2026-09-08)

Scope (user rescope): *"do not touch `packiot40`. All changes set up staging and prod NEW STACK
for a clean cutover from `packiot40` later."* So #159 splits into **(a) new-stack cleanup — done**
and **(b) the deferred `packiot40` cutover — designed, gated, NOT executed.**

### 10.1 (a) Prod new-stack Firebase removal — DONE + HARDPROOFED (PR #1141)

The deployed prod `refdata-api` was still running the **pre-#1130 dual-accept binary** (image
built 2026-09-07T15:43 from `production`@`1e7adc69`, before #1130 merged). Boot log:
`"tenant auth configured" … "firebase_project":"fbpackiot" "cognito_dual_accept":true`. It
constructed a Firebase verifier from the **in-binary default** `fbpackiot` — the box `.env` does
NOT set `FIREBASE_PROJECT_ID`; the value came from `compose.production.yml`'s
`${FIREBASE_PROJECT_ID:-fbpackiot}` default. The new-stack prod tenant (CPACK, id 3) has **0
Firebase users** — front4 already authenticates /v1 via Cognito — so this was a dormant,
unused relying party. Removing the compose line alone was insufficient (the old binary defaults
to `fbpackiot`); the **binary itself had to be rebuilt** with the #1130 removal.

Change — forward-port #1130 to the `production` branch (deploy trigger for the new prod stack):
- `services/read-api/cmd/refdata-api/main.go`: drop the Firebase verifier + `FIREBASE_PROJECT_ID`
  read; wrap the Cognito verifier in the same single-entry `multiVerifier` (idp tagging +
  link-on-login self-heal preserved). Boot log now `cognito_only=true`.
- `compose.production.yml`: remove the dead `FIREBASE_PROJECT_ID` env; document
  `COGNITO_AUTH_ENABLED` as inert for refdata (Cognito is now unconditional).

Codified + deployed via the normal pipeline (PR #1141 → `production` → `deploy-production.yml`
run `34271857994` success). **Hardproof on box `i-02d255a1c21fb1da3` (image rebuilt
2026-09-08T19:57):**
- Boot log: `"cognito_only":true` — no `firebase_project`, no `cognito_dual_accept`; **0**
  `firebase` strings in logs; **0** ERROR/panic since deploy.
- Container `Config.Env`: **no `FIREBASE_*` key** (the compose default was the only source).
- `/v1` served from the stack network (`stack_packiot-net`): operator key → **200**
  (`/v1/operator-entities`, `/v1/language-packs`); **no** credential → 401; a Firebase-issuer
  Bearer (`iss=securetoken.google.com/fbpackiot`) → **401** (Firebase relying party gone); the
  Cognito verifier path is byte-identical to the pre-fix binary that already serves front4-prod
  Cognito logins. Container `healthy`.
- Reversible: revert the PR + redeploy. **`packiot40` untouched.**

### 10.2 (b) Staging new-stack — CONFIRMED 100% Firebase-clean (re-verified 2026-09-08)

Re-hardproofed on box `i-06c9547a2c7091ab7` (the #1130 outcome held): read-api boots
`"cognito_only":true`, **no `FIREBASE_*` env**, **0** firebase log strings; `/v1/operator-entities`
with the operator key → **200**, no-cred → 401, Firebase-issuer Bearer → 401. edge-api env has no
`FIREBASE_ISSUER`; barcode-service `FIREBASE_PROJECT_ID=""`. Staging is Cognito-only.

### 10.3 Prod Cognito pool decision — INTERIM (reuse staging pool); dedicated pool is a CUTOVER step

**State (read-only AWS CLI, 2026-09-08):** the only Cognito pool org-wide is
`us-east-1_0T9t1sTwt` name **`packiot-staging`** (~5 users). **No `packiot-prod` pool exists** →
PR #1139 (`terraform/production/cognito.tf` + inert migration lambda; branch
`feat/159-prod-cognito-infra`@`10b785d7`, purely additive: +1788/-0) is **authored, NOT applied.**
New-stack prod (edge-api / refdata-api / operator) currently points `COGNITO_ISSUER` at this
staging pool.

**Decision: keep the interim (reuse `packiot-staging`); do NOT apply #1139 now.** Rationale:
1. New-stack prod is Firebase-clean **regardless** of which pool it uses — the pool is orthogonal
   to the Firebase removal. Reusing the staging pool works today (front4-prod logs in via it).
2. The dedicated `packiot-prod` pool is only *needed* when `packiot40`'s 828 Firebase users
   migrate — i.e. at the deferred cutover. Applying #1139 now creates an **empty, unused** pool.
3. **The prod terraform state is drifted:** `superset.tf` / `historian.tf` / runner resources
   were added to the applied state out-of-band and are not cleanly represented in the canonical
   `terraform/production/` tree. A full `terraform apply` reconciles the **entire** config against
   state → it could propose destroying superset/historian. Because I **cannot prove** a
   `terraform apply` is zero-destroy/zero-replace against this drifted state, per the task's own
   gate I did **not** apply, and did **not** run `terraform plan` (a plan against the drifted tree
   would be dominated by misleading destroy noise and briefly locks the prod state). Grounded the
   pool reality via read-only `aws cognito-idp list-user-pools` instead.

**Cutover step (later):** reconcile the prod tf state first (import/codify superset + historian so
the tree matches applied state), *then* apply #1139 to provision `packiot-prod` + the (inert)
migration lambda, repoint new-stack prod `COGNITO_ISSUER`/client at it, and provision the 828
legacy users there. Recommend **one prod pool spanning both prod planes** (the resolver keys on the
opaque `sub`, so a user who later moves from `packiot40` to the new stack keeps one identity) — see
§3.1.

### 10.4 What the deferred `packiot40` → new-stack cutover still carries (gated, unchanged)

The legacy-plane program (§3-§8) is untouched by this session. Its gating prerequisites and the
**already-decided 7-user remediation** (from the §8.3 hardproof) are cutover steps:

- **KEEP `id_user` 609 + 612** (the real/earliest identities: 609 = `jorgempv@suzano.com.br`,
  612 = `ottospigariol.3sv@suzano.com.br`).
- **DEACTIVATE the duplicates + no-email rows: 641, 507, 964, 965, 966, 967, 968** — the 641/507
  dup-email collisions (unreachable second rows) + the 5 NULL/empty-email actives that cannot be
  email-linked. This unblocks a provable 100% backfill (`active AND id_user_firebase IS NOT NULL
  AND id_user_cognito IS NULL` → 0). **These are `packiot40` writes → deferred until the cutover
  is explicitly authorized (they are NOT done now).**
- Provision the dedicated `packiot-prod` pool + inert migration lambda (§10.3, PR #1139) after tf
  reconciliation; add `id_user_cognito` to `packiot40`; deploy back4-api/primary-api dual-accept
  (flag off); enable the lambda; flip front4-prod to Cognito (the one human-green-lit action);
  soak to zero FB-only; then the §5 Firebase-removal PR set + `id_user_firebase` column drop.

**Invariant:** `packiot40` and the entire legacy relying-party plane stay exactly as they are —
no schema change, no user deactivation, no writes — until the cutover program is green-lit.

## Appendix — evidence index (for re-verification)

- Legacy DB creds: EB `piot4backend`/`back4-api-main` (us-east-2) `DB_HOST=18.220.223.110 DB_NAME=packiot40 DB_USER=packiotapi`.
- New-stack prod DB: `packiot`@`pgbouncer` on box `i-02d255a1c21fb1da3`, creds `/opt/packiot/.env`, network `stack_packiot-net`.
- Staging DB: box `i-06c9547a2c7091ab7`, `packiot_analytics`.
- Cognito pool: `us-east-1_0T9t1sTwt` (`packiot-staging`); Lambda `packiot-staging-cognito-user-migration`.
- Key source files: `edge-api/src/shared/auth/bearer-jwt.config.ts`, `edge-api/src/data/DAO/auth-middleware/auth-user-dao.ts`, `services/read-api/cmd/refdata-api/{main.go,auth_firebase.go,auth_cognito.go}`, `services/cognito-user-migration/index.mjs`, `back4-api/src/app/middlewares/auth.js`, `packiot/api src/auth/strategies/firebase.strategy.ts`, `front4/src/{cognito.js,firebase.js,services/authToken.js,Context/AuthContext.jsx}`.
</content>
</invoke>
