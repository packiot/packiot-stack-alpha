# ADR-0034 — Adopt AWS Cognito (via Amplify Auth) as the identity provider, replacing Firebase

**Status:** Proposed · **Date:** 2026-07-21 · **Scope:** front4 (reads) · operator PWA (writes) · edge-api (write API) · refdata-api (read plane) · back4-api / CS-Admin (client-user creation) · DB (`users`) — **DESIGN ONLY** (this ADR is the plan; no code changes, no cloud mutations ship with it). **Decision owner:** auth architect / tech-lead — pending USER sign-off on the four open questions in §11. **This is the USER's chosen direction: consolidate auth onto AWS.**

**Supersedes (the Firebase-*specific* parts of):**
- [ADR-0033](0033-unified-firebase-jwt-auth.md) — the unified client-user auth model. **ADR-0033's MODEL is kept in full; only the ISSUER changes (Firebase → Cognito).** The model is issuer-agnostic by construction: *a per-user RS256 JWT verified by public keys with no secret in the relying party → `uid → id_enterprise` → tenant-bound SQL, client never names a tenant, for reads AND writes.* Every decision in ADR-0033 (DB-lookup tenancy §3, operator offline drain-time mint §4, write-side SQL fence §5, M2M service-key boundary §7, per-env isolation §7A, CS-Admin owns provisioning §7B) survives verbatim with "Firebase" replaced by "Cognito". This ADR supersedes ADR-0033 Decisions **6** (Firebase project topology → Cognito user-pool topology) and **7B's SDK specifics** (Firebase Admin SDK → Cognito Admin API), and the setup guide [`docs/auth/staging-firebase-setup.md`](../auth/staging-firebase-setup.md) (now historical).

**Builds on / honors:**
- [ADR-0027](0027-refdata-api-surface-1-read-contract.md) — the **single tenant-injection authority** invariant (`credential → customer_id → $1`). The verifier is one seam behind that authority; swapping Firebase→Cognito changes only issuer + key source.
- [ADR-0031](0031-back4-api-retirement-shims-datasets-and-hasura-sequence.md) — back4-api retirement. The Firebase-admin **client-user-creation** path (`UsersController.createUsers`) that this ADR re-homes on Cognito is one of the back4 responsibilities moving to CS-Admin.
- [ADR-0026](0026-api-layer-consolidation.md) — API consolidation; refdata-api is the hardened read plane whose verifier is the proven base.
- [ADR-0021](0021-multitenancy-model.md) — `id_enterprise` as the tenant axis the write-fence protects.

> **Numbering:** `0034` is the next free slot (`0033` is the Firebase unified-auth ADR this supersedes).

---

## 1. Context — why change issuer at all, and why Cognito

ADR-0033 unified *client-user* auth onto **one** model: a per-user RS256 JWT, verified against the issuer's public keys (no secret in the relying party), resolved `uid → id_enterprise` via a DB lookup, and fenced in SQL on both reads and writes. That model is proven live on staging (refdata-api, tasks #57/#68/#70). **It is correct, and it stays.** The only question this ADR answers is: **which identity provider mints and signs those JWTs.**

Today the answer is **Firebase** — and it is the *one remaining cross-cloud dependency* in an otherwise all-AWS stack:

| Signal | Detail |
|---|---|
| **The whole stack is AWS** | EKS/ArgoCD, EB, RDS/Timescale, Secrets Manager, Route53, ACM, S3 state (`api-terraform`). Firebase (GCP) is the lone exception — a second cloud console, a second IAM model, a second billing/quota surface, a second provisioning path nobody else in the stack uses. |
| **front4 is already on Amplify** | front4 deploys via **AWS Amplify Hosting** (migrated off FTP). Amplify has first-class **Cognito** integration (`aws-amplify` Auth). Authenticating the SPA against Cognito is same-cloud, same-console, same-CLI as where it already lives. |
| **A committed prod service-account key** | `back4-api/private-key.json` — a **Firebase Admin service-account private key checked into the repo**. ADR-0033 already flagged this as the anti-pattern being retired; the credential is dead in GCP. Cognito's admin path uses **IAM roles** (task/instance role), so there is **no long-lived key to commit** at all — the class of mistake disappears. |
| **Firebase project-creation friction** | Standing up a *staging* Firebase project (ADR-0033 Decision 6 + the whole `staging-firebase-setup.md` guide) is a **manual GCP-console dance the USER must do by hand** — create project, enable Email/Password, register web app, generate + hand-place a SA key. None of it is Terraformable with the AWS creds that run the rest of the stack. A Cognito user pool is `terraform apply` in `api-terraform`, provisioned by the **same AWS credentials** as everything else. |
| **Native tenant claims** | Cognito has first-class **custom attributes** (`custom:id_enterprise`) and **groups** that are baked into the JWT natively — the exact "self-contained token" end-state ADR-0033 §3 discussed but couldn't get from Firebase without the Admin-SDK `setCustomUserClaims` machinery. (We still recommend DB-lookup as authority — see §2 — but the option is now native, not bolted on.) |

### 1.1 Options considered

| Option | What it is | Verdict |
|---|---|---|
| **(A) Firebase, separate projects per env** | Status quo model (ADR-0033 Decision 6): keep Firebase, stand up a separate `packiot-staging` project. | **Rejected.** Keeps the lone cross-cloud dependency, the manual GCP project-creation friction, the second IAM/console/billing surface, and the committed-SA-key class of problem. Solves env-isolation but not consolidation. |
| **(B) AWS Cognito + Amplify Auth** ✅ | Cognito user pools (one per env, Terraform), front4 via `aws-amplify` Auth, admin path via Cognito Admin API + IAM, refdata/edge-api verify Cognito RS256 JWTs. | **CHOSEN.** All-AWS: same console, same IAM, same Terraform, same Secrets Manager. Native tenant claims available. No committed key (IAM roles). front4 already on Amplify. Env isolation is a Terraform `for_each`, not a console dance. |
| **(C) Self-hosted authentik (or Keycloak)** | Run our own OIDC IdP (authentik already runs for Grafana SSO — reference `memory/reference_grafana_access.md`). | **Rejected for client-users.** We'd *own* the availability, patching, backup, and scaling of the identity plane for **paying factory clients** — an operational liability a managed IdP removes. authentik stays for *internal* Grafana SSO (a staff tool, blast-radius = us); it is the wrong tool for the customer-facing login where an outage locks factories out of their own OEE. Cognito is managed, same-cloud, and priced per-MAU with a generous free tier. |

**Decision: (B) Cognito + Amplify Auth.** It is the only option that (a) removes the cross-cloud dependency, (b) kills the committed-key anti-pattern structurally (IAM, not a key file), (c) makes per-env isolation a Terraform artifact provisioned by existing AWS creds, and (d) sits natively where front4 already deploys.

---

## 2. Tenant isolation — the load-bearing requirement (unchanged model, swapped mechanics)

**The invariant is non-negotiable and identical to ADR-0033:** *one client's user can never read or write another client's data.* A cross-tenant read leaks; a cross-tenant **write corrupts another tenant's operational state** (starts/stops the wrong factory's PO). The write path is the highest-severity surface.

The model: `verified JWT → uid (sub) → id_enterprise → tenant-bound SQL ($1)`, client never names a tenant, fence enforced in SQL so it cannot be forgotten (refdata's `$1`-bind trick; edge-api's `AND id_enterprise = $caller` on every mutation → cross-tenant target matches zero rows → 404). **None of that changes.** What changes is only *how `uid → id_enterprise` is resolved*, and Cognito gives us a genuinely native second option:

| | **DB lookup** (`users.id_user_cognito → id_enterprise`) | **Cognito custom attribute / group** (`custom:id_enterprise` baked into the JWT as a NATIVE claim) |
|---|---|---|
| Verify cost | One indexed lookup, 5-min TTL cache (what refdata does today) | **Zero DB hit** — the tenant is a verified claim in the token. This is the self-contained end-state ADR-0033 §3 *wanted* but couldn't get cleanly from Firebase. |
| Native support | n/a (it's our table) | **First-class in Cognito** — `custom:id_enterprise` is a schema attribute set at `AdminCreateUser`; a **Pre-Token-Generation Lambda** or a group can stamp it into every ID/access token. No bolt-on. |
| Source of truth | `users` — already authoritative for role, entities, `active` | Cognito user-pool attribute — a **second** place tenant membership lives, must stay in sync with `users` |
| Change enterprise | `UPDATE` one row; propagates within cache TTL | `AdminUpdateUserAttributes` **+ force token refresh** — stale tokens carry the old tenant up to token TTL (~1h) |
| Deactivation | `active = false` in the `WHERE` — deactivated user stops resolving at next cache miss | Attribute alone can't revoke — token valid until exp (need `AdminDisableUser` + accept the TTL lag) |
| Write fence | The fence loads the **target row's** `id_enterprise` from the DB regardless — so the write plane hits the DB either way; the claim's "no DB hit" win **evaporates on writes** | Same: the target-row fence still needs the DB round-trip |
| Proven? | **Already live on staging** (refdata `usersEnterpriseSQL`); zero migration of resolver logic | New: Pre-Token-Gen Lambda + attribute-sync at onboarding + backfill for existing users |

**RECOMMENDATION — keep DB lookup as the authority (same as ADR-0033 §3), with the Cognito custom claim available as optional defense-in-depth.** Reasons, in priority order, are identical to ADR-0033 and *strengthened* by consolidation:

1. **The write fence hits the DB regardless.** Decision-3-in-ADR-0033's target-row fence must load the PO/equipment's `id_enterprise` to compare, so on writes the claim's headline advantage (no DB touch) does not exist. Reads already cache the lookup.
2. **Single source of truth.** `users` is already authoritative for role/entities/`active`. Splitting tenant identity into a Cognito attribute recreates the classic dual-write consistency bug (the same one back4's `setCustomUserClaims` Hasura-claim write already is). Enterprise moves and deactivations become "re-mint the token" instead of "UPDATE one row."
3. **Near-zero resolver migration.** The refdata resolver stays *byte-identical except the SQL column name* (`id_user_firebase → id_user_cognito`) and the `sub` format. edge-api inherits the same resolver.

**Refdata verifier delta is small and surgical.** `services/refdata-api/cmd/refdata-api/auth_firebase.go` already isolates verification behind the `verifier` interface (`Verify(ctx, token) (uid, err)`) and injects it, so the tenant-resolution half (`firebaseBearerAuth`, the cache, `usersEnterpriseSQL`) is **reused unchanged**. Only `newFirebaseVerifier` is replaced by a Cognito verifier:

| Verifier field | Firebase (today) | Cognito (target) |
|---|---|---|
| `iss` | `https://securetoken.google.com/<projectID>` | `https://cognito-idp.<region>.amazonaws.com/<userPoolId>` |
| Key source | Google x509 PEM certs @ `googleapis.com/robot/v1/.../securetoken@system` | **JWKS** @ `<iss>/.well-known/jwks.json` (RSA `n`/`e`, not PEM — the only parsing change; `golang-jwt/jwt/v5` has `jwt.NewParser` + a JWKS keyfunc, or reuse the existing cert-cache shape parsing JWKS instead of x509) |
| `aud` | Firebase `projectID` | Cognito **app client id** (`WithAudience(appClientID)`) — note: Cognito **access** tokens use `client_id` not `aud`; **ID** tokens use `aud`. Verify the **ID token** → `aud` is present (keep the ID-token choice, matching front4's existing "send the ID token" contract). |
| `token_use` | n/a | verify **`token_use == "id"`** (Cognito-specific claim; pins ID vs access token) |
| alg / leeway / exp / iat | RS256, 60s leeway, exp required, iat checked | **identical** — same RS256 model, same checks, same leeway |

Everything else — the RWMutex key cache, stale-key-on-transient-blip tolerance, `Cache-Control` max-age refresh, fail-closed-to-401, the `resolvedIdentity` shape, `userRoleFromContext` — is unchanged. **This is the payoff of ADR-0033 having built the verifier as an issuer-agnostic seam.**

---

## 3. The migration surface (per component)

| Component | Today (Firebase) | Target (Cognito) | Delta size |
|---|---|---|---|
| **refdata-api** (read plane) | `newFirebaseVerifier(projectID)` — iss=securetoken, x509 certs, aud=projectID | Cognito verifier — iss=user-pool URL, JWKS URL, aud=app-client-id, assert `token_use=id`. Tenant resolution (`firebaseBearerAuth` + `usersEnterpriseSQL`) **unchanged** except the `id_user_firebase → id_user_cognito` column. | **Small** — one file (`auth_firebase.go` → `auth_cognito.go`), the `verifier` interface already isolates it. |
| **front4** (reads) | Firebase JS SDK (`firebase/auth`): `signInWithEmailAndPassword`, `getIdToken`, `sendPasswordResetEmail`/`confirmPasswordReset`, `OAuthProvider`/`signInWithPopup`; config env-driven via `VITE_FIREBASE_*` (**PR #207**) | **Amplify Auth** (`aws-amplify` v6): `signIn`, `fetchAuthSession().tokens.idToken`, `resetPassword`/`confirmResetPassword`, `signInWithRedirect` (hosted-UI federation). `Amplify.configure({ Auth: { Cognito: {...} } })` from `VITE_COGNITO_*`. **PR #207 made the Firebase config env-driven; this ADR replaces that config layer with Amplify Auth entirely** (the env-driven plumbing proves the app tolerates a swappable auth config — now the swap goes all the way to a different provider). | **Medium** — `src/firebase.js` → `src/amplifyAuth.js`; `src/Context/AuthContext.jsx` method-by-method port; `src/services/{api,refdata,graphqlConnection}.js` `getIdToken()` → `fetchAuthSession()`. Token-shape on the wire is still "RS256 JWT in `Authorization: Bearer`", so callers below front4 are contract-stable. |
| **back4-api / CS-Admin** (client-user creation) | `UsersController.createUsers`: `firebase-admin` `getAuth().createUser()` + `setCustomUserClaims` (Hasura claims) + compensating `deleteUser`; `back4-api/private-key.json` committed key. Auth middleware `verifyIdToken`. | **Cognito `AdminCreateUser`** via AWS SDK v3 (`@aws-sdk/client-cognito-identity-provider`), authenticated by the **task/instance IAM role** (no key). Compensating `AdminDeleteUser` on DB-write failure. **Retire `back4-api/private-key.json`.** *Per USER: CS-Admin owns client-user creation going forward* (ADR-0031 back4 retirement + ADR-0033 Decision 7B) — the Cognito admin path lands in CS-Admin's onboarding flow, not back4. | **Medium** — SDK swap + IAM policy (`cognito-idp:AdminCreateUser/AdminDeleteUser/AdminUpdateUserAttributes` scoped to the env's pool ARN). Delete the key file + its `require`. |
| **DB** (`users`) | `users.id_user_firebase` (the Firebase uid); UNIQUE; queried across back4 + refdata | Rename/migrate to **`users.id_user_cognito`** (the Cognito `sub`, a UUID). See §4 for the *value* migration; the *column* migration is a standard soft-rename (add column → dual-write/backfill → cut reads → drop old). | **Small schema, careful data** — column is referenced in refdata `usersEnterpriseSQL` + ~10 back4 queries; a coordinated rename. |
| **edge-api** (write path) | (ADR-0033 design) Bearer-JWT middleware + enterprise write-fence, verifying Firebase | **Same middleware, same fence — issuer swap only.** The write-fence work (`AND id_enterprise = $caller` folded into PO/downtime mutations) is being implemented separately (ADR-0033 §5); it is verifier-agnostic. edge-api's Bearer path shares refdata's Cognito verifier logic. | **None beyond the issuer swap** — the fence is the same SQL regardless of issuer. |
| **Hasura** | Firebase JWT with embedded `https://hasura.io/jwt/claims` (set by back4's `setCustomUserClaims` at user creation) | Hasura JWT config points at the **Cognito JWKS**; the Hasura claims are injected by a **Pre-Token-Generation Lambda** (or Hasura's claims-map reads Cognito's native `sub`/`cognito:groups`). **This is a real migration item** — front4 talks to Hasura directly today; Hasura must trust Cognito-signed tokens before front4 flips. | **Medium** — Hasura JWT secret config + the claims-injection Lambda; sequence *before* front4 cutover. |
| **Grafana** | authentik SSO (internal) | **UNCHANGED** — out of scope, staff tool (ADR-0033 §7). | None |
| **M2M service callers** (mirror-worker-go, oeecloud replays, ingest-shim, refdata `X-Api-Key`) | scoped service api-keys | **UNCHANGED** — human↔Cognito, service↔scoped api-key (ADR-0033 §7). | None |

---

## 4. Existing-user migration — the hard part (migrate-on-login Lambda)

**The core problem:** Firebase stores passwords as **scrypt** hashes with **Firebase-specific parameters** (a base64 signer key, salt separator, rounds, and mem-cost that Firebase publishes per-project under *Authentication → Users → ⋮ → Password hash parameters*). Cognito cannot import a scrypt hash — Cognito's bulk `CreateUserImportJob` accepts only user *attributes*, never a password hash, so a bulk import **forces every user to reset their password**. For an OEE product whose users are factory staff, a mass forced-reset is a support-load and adoption event we want to avoid.

### 4.1 Recommended: Cognito **User Migration Lambda trigger** (migrate-on-login, zero forced reset)

Cognito's `UserMigration_Authentication` Lambda trigger fires **the first time a not-yet-in-Cognito user signs in**. The flow:

```
User signs in on front4 (Amplify Auth signIn, USER_PASSWORD_AUTH flow) with email + their EXISTING Firebase password
   │
   ▼
Cognito: no such user in the pool → invoke the User Migration Lambda (trigger = UserMigration_Authentication)
   │  event carries { userName: email, request.password: <plaintext, over TLS, in-Lambda only> }
   ▼
Lambda validates the password against FIREBASE:
   POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=<FIREBASE_WEB_API_KEY>
        { email, password, returnSecureToken:false }
   (the Identity Toolkit REST "verify password" endpoint — the ONLY way to check a Firebase
    password; the Admin SDK cannot verify a password, only mint/inspect. Needs temporary
    Firebase-verify access during the cutover window — see OQ-4.)
   │
   ├─ 200 OK  → password correct → Lambda returns userAttributes (email, email_verified,
   │            custom:id_enterprise if we choose to stamp it) + finalUserStatus=CONFIRMED
   │            + messageAction=SUPPRESS  → Cognito CREATES the user with THAT password,
   │            transparently. User is now native in Cognito; Firebase never consulted again for them.
   │
   └─ non-200 → Lambda throws → Cognito returns auth failure (same as a wrong password).
```

**Result: zero forced resets.** Each user is migrated silently on their next successful login, carrying their existing password into Cognito. Users who never log in during the window are handled by the fallback (below). This is the AWS-documented, standard Firebase→Cognito path.

**The `sub` mapping:** the Lambda (or the migration reconciler) must write the **new Cognito `sub`** back to `users.id_user_cognito` for the row currently keyed by the Firebase uid. Two shapes: (a) match on **email** (Firebase email == `users.user_email`) and `UPDATE users SET id_user_cognito = <new sub> WHERE user_email = $email`; or (b) have the Lambda stamp `custom:legacy_firebase_uid` and reconcile by that. Prefer (a) — email is the stable natural key both systems share. This is the one genuinely fiddly data step; it must be **idempotent** (a ret/re-login must not create duplicates — the UNIQUE on the mapping column enforces that).

### 4.2 Fallback: bulk import with forced reset (for the long tail)

For users who don't log in during the cutover window (or if OQ-3 rejects migrate-on-login): a one-shot script enumerates Firebase users (Admin SDK `listUsers`), `AdminCreateUser` each into Cognito with `MessageAction=SUPPRESS` and no password → user is `FORCE_CHANGE_PASSWORD` → they reset on next login via the standard Cognito flow. Higher friction, but a clean backstop for stragglers after migrate-on-login has drained the active population.

**RECOMMENDATION — migrate-on-login as primary, bulk-import-with-reset as the tail-cleanup.** Run migrate-on-login for the whole cutover window; after the window, bulk-import-with-reset the remaining never-logged-in accounts and retire the Firebase-verify credential. This gets ~all active users across with zero reset and bounds the Firebase dependency to a fixed window.

> **The temporary Firebase-verify dependency (OQ-4):** migrate-on-login needs the Lambda to call Firebase's `signInWithPassword` during the window — i.e. a **Firebase web API key** (public identifier) held by the Lambda. This is a *read-only password check*, not the dead Admin SA key, and it retires the moment the window closes. Who owns/holds it during cutover is OQ-4.

---

## 5. Per-environment isolation — Cognito user pools per env (the big provisioning win)

ADR-0033 Decision 6 established **blast-radius + token-audience isolation per environment** (a staging mistake must not touch prod users; a staging token must fail `aud` verification at the prod plane). That requirement is **kept**; the Cognito analog is a **separate `aws_cognito_user_pool` per environment** — and this is where consolidation pays off most.

| | Firebase (ADR-0033 Decision 6) | Cognito (this ADR) |
|---|---|---|
| Provisioning | **Manual GCP console** — create project, enable Email/Password, register web app, generate SA key, hand-place it. A whole USER checklist (`staging-firebase-setup.md`). Not automatable with AWS creds. | **`terraform apply`** in `api-terraform` — `aws_cognito_user_pool` + `aws_cognito_user_pool_client`. Provisioned by the **same AWS credentials** as EKS/RDS/DNS. No console dance, no GCP dependency. |
| Isolation boundary | Separate Firebase project; token `aud` = project id | Separate user pool; token `iss` = pool URL, `aud` = app client id. A staging token **fails `iss`/`aud`/JWKS verification** at the prod verifier — cross-env replay unrepresentable, same guarantee. |
| Secret handling | A staging SA key file → staging secrets manager, by hand | **No key at all** — admin ops use the env's IAM role. Only the (public) Firebase-verify key exists, and only during the migration window. |
| Cost | Free tier | Cognito free tier (50k MAU) — effectively free at Packiot's user count; no per-project juggling. |

### 5.1 Terraform sketch — staging user pool (`api-terraform`)

Fits the existing `api-terraform` layout (`modules/` + per-env `stacks/env/00-env-{dev,prod}`, S3 backend, `provider "aws" { region = var.aws_region }`). A new `modules/cognito` consumed by each env stack:

```hcl
# api-terraform/modules/cognito/main.tf   (REVIEW-ONLY sketch — no apply ships with this ADR)

variable "env"       { type = string }         # "staging" | "prod"
variable "callback_urls" { type = list(string) } # front4 Amplify origins for hosted-UI/federation

resource "aws_cognito_user_pool" "clients" {
  name = "packiot-clients-${var.env}"

  # Email as the sign-in identifier (matches front4's email/password login today).
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_uppercase = true
    require_symbols   = false
  }

  # Native tenant claim (OPTIONAL, defense-in-depth per §2 — DB lookup stays authoritative).
  schema {
    name                = "id_enterprise"     # → custom:id_enterprise in the token
    attribute_data_type = "Number"
    mutable             = true
  }

  # migrate-on-login (§4). Points at the migration Lambda; REMOVED after the cutover window.
  lambda_config {
    user_migration = var.migration_lambda_arn   # null after window → trigger detached
    # pre_token_generation = var.hasura_claims_lambda_arn  # if we inject Hasura claims (§3)
  }

  account_recovery_setting {
    recovery_mechanism { name = "verified_email" priority = 1 }
  }

  # Staging pool is disposable: no deletion protection so it can be torn down/rebuilt freely.
  deletion_protection = var.env == "prod" ? "ACTIVE" : "INACTIVE"
}

# App client for front4 (public SPA — NO client secret; the browser holds no secret,
# same posture as the Firebase web apiKey).
resource "aws_cognito_user_pool_client" "front4" {
  name         = "front4-${var.env}"
  user_pool_id = aws_cognito_user_pool.clients.id

  generate_secret = false                       # public SPA client
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",                 # required for migrate-on-login (§4)
    "ALLOW_USER_SRP_AUTH",                      # SRP for steady-state (password never on the wire)
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
  access_token_validity  = 60                   # minutes (~parity with Firebase ~1h ID token)
  id_token_validity      = 60
  refresh_token_validity = 30                   # days (long-lived → operator offline drain, §4-of-0033)
  token_validity_units { access_token = "minutes" id_token = "minutes" refresh_token = "days" }

  callback_urls = var.callback_urls             # front4 Amplify origins
  supported_identity_providers = ["COGNITO"]
}

output "user_pool_id"   { value = aws_cognito_user_pool.clients.id }
output "app_client_id"  { value = aws_cognito_user_pool_client.front4.id }
output "issuer"         { value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.clients.id}" }
output "jwks_uri"       { value = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.clients.id}/.well-known/jwks.json" }
```

The `issuer`/`jwks_uri`/`app_client_id` outputs feed refdata + edge-api env (`COGNITO_ISSUER`, `COGNITO_JWKS_URI`, `COGNITO_APP_CLIENT_ID`) and front4's `VITE_COGNITO_*` — the exact plumbing PR #207 already established for `VITE_FIREBASE_*`, now pointed at Cognito. **Prod is the same module with `env = "prod"` and its own state key** — nothing shared, mirroring the separate-project isolation.

---

## 6. Phased, reversible migration plan (flag-gated, staging-first)

Every phase is independently deployable and reverts by flag or config. **No big-bang cutover.** Follows the standing staging-only directive.

| Phase | Action | Reversible by |
|---|---|---|
| **P0 — Stand up the staging user pool** | `terraform apply` the `modules/cognito` staging instance in `api-terraform`. Outputs → staging Secrets Manager / env. No consumer wired yet — pure infra. | Destroy the pool (staging `deletion_protection=INACTIVE`). Zero blast radius. |
| **P1 — refdata dual-verify** | refdata accepts **Firebase OR Cognito** during cutover: try Cognito verifier, fall back to Firebase verifier (or run both keyed off `iss`). Both resolve `uid → id_enterprise` via the same lookup (the `id_user_cognito` column dual-populated in P3). Behind `REFDATA_COGNITO_AUTH_ENABLED`. | Flag off → Firebase-only. |
| **P2 — Hasura trusts Cognito** | Add Cognito JWKS to Hasura's JWT config (alongside Firebase during the window); wire the Hasura-claims Pre-Token-Gen Lambda. Verify a Cognito-signed token authorizes a Hasura query on staging. | Remove the Cognito JWT secret from Hasura config. |
| **P3 — DB column migrate** | `users`: add `id_user_cognito`, dual-write/backfill (email-keyed from the migrate-on-login reconciler), keep `id_user_firebase` readable. refdata/back4 read `COALESCE(id_user_cognito, …)` during the window. | Column is additive; drop `id_user_cognito`, keep Firebase column. |
| **P4 — front4 Amplify Auth on staging** | Replace `firebase/auth` with `aws-amplify` Auth in front4; `.env.staging` → `VITE_COGNITO_*`. Staging front4 signs in against the staging pool. **This is the flip that exercises migrate-on-login** (§4) — existing staging users migrate on first Cognito login. | Revert front4 to the Firebase build (`.env.staging` → `VITE_FIREBASE_*`); the env-driven config (PR #207) makes this a config revert, not a code revert, until the SDK swap lands — after which it's a branch revert. |
| **P5 — CS-Admin Cognito provisioning** | CS-Admin's "create client user" flow uses Cognito `AdminCreateUser` + the atomic `users` insert (ADR-0033 Decision 7B, IAM-authenticated). Retire back4's `createUsers` Firebase path. | Feature-flag the CS-Admin flow; back4 path stays until P5 bakes. |
| **P6 — Cut prod** | Repeat P0–P5 against a **prod** Cognito pool (separate state, `deletion_protection=ACTIVE`). Prod migrate-on-login window opens. | Flags/config per phase; prod verifiers run dual (Cognito+Firebase) until the window closes clean. |
| **P7 — Retire Firebase** | After the prod window drains (migrate-on-login quiet, tail bulk-imported per §4.2): remove Firebase verifiers from refdata/edge-api/Hasura, delete `back4-api/private-key.json` (already dead), detach the migration Lambda, revoke the temporary Firebase-verify key, drop `users.id_user_firebase`. | Terminal — but only entered after the dual-verify bake proves Cognito carries 100% of traffic. |

**Rollback posture:** identical discipline to ADR-0033 — the Firebase paths are *removed, not broken*, and only after their per-env Cognito replacement bakes clean under dual-verify. Reverting a flag restores Firebase with zero data loss (the `id_user_firebase` column survives until P7).

---

## 7. Amplify specifics — Gen-2 Auth vs direct SDK

front4 is an **Amplify Hosting** app (a Vite React SPA built + served by Amplify; migrated off FTP). Two ways to give it Cognito:

| Approach | What it means | Fit for Packiot |
|---|---|---|
| **Amplify Gen-2 Auth** (`amplify/auth/resource.ts`) | Define the user pool *in the front4 repo* as Amplify backend code; `npx ampx` provisions + owns the Cognito resources; `amplify_outputs.json` generated at build. | **Not recommended.** It would make **front4's repo the owner of the Cognito pool** — a *second* IaC authority fighting `api-terraform`, which owns every other AWS resource (EKS, RDS, DNS, secrets). Two tools provisioning the same class of resource is the dual-source-of-truth trap. It also couples pool lifecycle to front-end deploys. |
| **Direct `aws-amplify` SDK against a Terraform-provisioned pool** ✅ | Pool is created by `api-terraform` (§5); front4 just **configures the client SDK** to point at it: `Amplify.configure({ Auth: { Cognito: { userPoolId, userPoolClientId } } })` from `VITE_COGNITO_*`. Use `aws-amplify/auth` (`signIn`, `fetchAuthSession`, `resetPassword`, …). | **Recommended.** Single IaC authority (`api-terraform`, same as the whole stack). front4 is a pure *relying party* — exactly its role today with Firebase (config points at a pool provisioned elsewhere). Mirrors the current shape 1:1, minimal conceptual change, and keeps the pool's lifecycle in the platform team's Terraform, not the front-end build. |

**RECOMMENDATION — direct `aws-amplify` SDK against a Terraform-provisioned pool.** Provision in `api-terraform` (single source of truth, existing AWS creds, per-env state), consume via the `aws-amplify` Auth SDK in front4. This keeps front4 a relying party (its role today) and avoids a second IaC authority. Amplify *Hosting* stays as-is; only the *client SDK* changes.

---

## 8. Open questions for the USER

- **OQ-1 — Tenant claim:** confirm **DB lookup** as the authority (recommended — reuses the proven refdata resolver, single source of truth, near-zero migration, write fence hits the DB regardless), OR adopt **Cognito `custom:id_enterprise`** as a native token claim (self-contained token, but re-mint on enterprise move + a second source of truth to sync). Note: Cognito makes the claim *native*, so this is a more real option than it was under Firebase — but the recommendation is unchanged.
- **OQ-2 — Amplify Gen-2 vs direct SDK:** confirm **direct `aws-amplify` SDK against a Terraform-provisioned pool** (recommended — single IaC authority, front4 stays a relying party), OR **Amplify Gen-2 Auth** (front4 repo owns the pool — rejected here as a second IaC authority).
- **OQ-3 — Existing-user migration:** confirm **migrate-on-login Lambda** primary + **bulk-import-with-reset** tail (recommended — zero forced reset for active users), OR go straight to **bulk-import-with-forced-reset** for everyone (simpler, no Firebase-verify dependency, but a mass reset event).
- **OQ-4 — Firebase-verify credential during cutover:** who owns/holds the temporary **Firebase web API key** the migrate-on-login Lambda uses to validate passwords against Firebase during the window (read-only, retires when the window closes)? Confirm it goes in the **staging/prod Secrets Manager** (not a repo, never near the dead `private-key.json`).

> ADR-0033's OQ-1 (tenant claim) and OQ-2 (operator token-refresh/shared-tablet) carry forward **unchanged in substance** — the operator drain-time-mint design (§4 of ADR-0033) is issuer-agnostic (Cognito refresh tokens are long-lived and persisted by the Amplify SDK exactly as Firebase's were), so that decision needs no re-litigation, only a re-confirm that Amplify's `fetchAuthSession({ forceRefresh })` is the drain-time mint (it is the direct analog of `getIdToken(forceRefresh)`).

---

## 9. Risks & rollback

| Risk | Severity | Mitigation / rollback |
|---|---|---|
| **Hasura stops trusting front4 tokens at cutover** (front4 talks to Hasura directly) | Critical | P2 wires Hasura to trust Cognito **before** P4 flips front4; dual-trust (Firebase+Cognito) during the window; verify a Cognito token authorizes a staging Hasura query before front4 flip. |
| **migrate-on-login mis-maps `sub → users` row** (duplicate/orphan) | High | Email as the natural key + UNIQUE on `id_user_cognito` (idempotent upsert); reconciliation report before prod window; the row's `id_enterprise` unchanged, only the uid column rewritten. |
| **Firebase password-verify endpoint unavailable during window** | Medium | A failed verify = a normal auth failure the user retries; the account stays in Firebase (not lost) and migrates on a later successful login. Total Firebase outage only stalls *migrations*, not already-migrated users. |
| **Cognito JWKS parsing differs from Firebase x509** | Low | Contained to the verifier's key-parse path (JWKS `n`/`e` vs PEM); `golang-jwt/jwt/v5` + a JWKS keyfunc is standard; unit-test with a static JWKS the same way `auth_firebase_test.go` injects a keyfunc. |
| **Committed key lingers** (`back4-api/private-key.json`) | Medium | Already dead in GCP; P7 deletes the file + the `require`; add a CI secret-scan gate so no SA key can be committed again (the class this whole ADR removes). |
| **Cross-env token replay** | Critical→removed | Separate pools → separate `iss`/`aud`/JWKS; a staging token fails verification at prod, same guarantee as separate Firebase projects. |
| **Dual-verify window drift** (a user in Firebase but not Cognito, or vice-versa) | Medium | The `id_user_cognito`/`id_user_firebase` columns coexist through P3–P6; refdata resolves either; the window closes (P7) only after dual-verify shows Cognito carrying 100%. |

**Overall rollback:** every phase is flag-gated or config-reverted; Firebase paths are removed only after Cognito bakes clean under dual-verify; the `id_user_firebase` column and Firebase verifiers survive until P7, so any pre-P7 revert restores Firebase with zero data migration.

---

## 10. What this ADR does NOT do

- **No code changes and no cloud mutations** — this is the design + phased plan only. No `terraform apply`, no pool creation, no Lambda deploy, no front4/refdata/back4 edits. The Terraform in §5 is a review-only sketch.
- **No prod change** — staging-first, per-env, flag-gated, per the standing staging-only directive.
- **No change to the ADR-0033 MODEL** — DB-lookup tenancy, operator offline drain-time mint, write-side SQL fence, M2M service-key boundary, per-env isolation, CS-Admin-owns-provisioning all carry forward verbatim; only the issuer (Firebase→Cognito) and its mechanics (project→pool, Admin-SDK→Admin-API+IAM, x509→JWKS) change.
- **No change to Grafana/authentik or the M2M service-key paths.**
- **No change to the read plane's *contract*** — refdata's behavior is unchanged; only its verifier's issuer/key-source swaps.
