# ADR-0034 reference — JIT User Migration Lambda (Firebase → Cognito)

**Status:** Built + proven on staging (BUILD + PROVE, NOT cut over) · **Date:** 2026-07-27 · **Scope:** staging Cognito pool only · **Companion to:** [ADR-0034 §4](../0034-adopt-cognito-amplify-auth.md) (migrate-on-login design)

This sub-doc records the concrete implementation of ADR-0034 §4's **migrate-on-login** path: a Cognito **User Migration** trigger Lambda that lazily (just-in-time) migrates Firebase users into Cognito on their first login, carrying their existing password across with **zero forced reset**. It is deployed to the **staging** pool, wired but **inert** (gated OFF), and points at **no production Firebase** until the USER performs the cutover steps below.

---

## 1. Why a migrate-on-login Lambda at all

Firebase stores passwords as project-specific **scrypt** hashes Cognito cannot import — a bulk `CreateUserImportJob` accepts attributes only, never a password hash, so bulk import **forces every user to reset**. For factory-floor users that is an adoption/support event we avoid.

Cognito's `UserMigration_Authentication` trigger fires the first time a not-yet-in-Cognito user signs in. The Lambda validates the supplied password against Firebase, and on success Cognito **creates the user natively with that same password** (`finalUserStatus=CONFIRMED`, `messageAction=SUPPRESS`). Each user migrates silently on next login; Firebase is never consulted for them again.

---

## 2. The web-API-key-NOT-SA-key decision (security-load-bearing)

The **only** way to verify a Firebase password is the Identity Toolkit REST endpoint `accounts:signInWithPassword` — the Firebase **Admin SDK cannot verify a password**, only mint/inspect tokens. That endpoint authenticates with the **Firebase WEB API key** (the semi-public Identity Toolkit key client apps already embed for `signInWithPassword`) — a *read-only password check*.

- We use the **web API key**, sourced from Secrets Manager at runtime. We do **NOT** use, reference, or need the leaked Admin service-account private key (`back4-api/private-key.json`) — that key is dead in GCP and is exactly the anti-pattern ADR-0034 retires.
- The key value is **never** in code, env literals, or terraform state. Terraform creates the secret **without a value**; the Lambda's env carries only the secret's **name** (`FIREBASE_WEB_API_KEY_SECRET_ID`), and the handler fetches the value at cold start via its IAM role.
- The Firebase **project** the key belongs to is a config value (`FIREBASE_PROJECT_ID`), left empty on staging. Pointing at prod `fbpackiot` is a deliberate USER config flip at cutover — never baked in.
- Passwords and key material are never logged (structured JSON logs carry only trigger source, the non-secret email, and outcome codes).

---

## 3. The two triggers

| Trigger source | Input | Behaviour | Denies when |
|---|---|---|---|
| `UserMigration_Authentication` | `event.userName` (email) + `event.request.password` | `POST accounts:signInWithPassword`. **200** → set `userAttributes` (email, `email_verified=true`, `name` from displayName if present, `custom:firebase_uid`←`localId`) + `finalUserStatus=CONFIRMED` + `messageAction=SUPPRESS`. | Firebase returns non-200 (`INVALID_PASSWORD`, `EMAIL_NOT_FOUND`, `USER_DISABLED`, `INVALID_LOGIN_CREDENTIALS`) → throw → Cognito shows a generic auth failure (never leaks which failed). |
| `UserMigration_ForgotPassword` | `event.userName` (email) | No password is available, so confirm the account exists via `POST accounts:createAuthUri` (web-key accessible, no admin creds). Registered → set attributes + `messageAction=SUPPRESS` so Cognito drives its own reset. | Not registered, or lookup error → throw (user can't be found). |

Both paths are additionally gated by `MIGRATION_ENABLED` (default `"false"`) — the whole trigger denies until the USER enables it.

The `custom:firebase_uid` attribute carries the legacy Firebase uid forward for the `uid ↔ sub` reconciler (ADR-0034 §4 recommends **email** as the natural reconciliation key; the uid attribute is defense-in-depth). It is declared on the pool schema in `terraform/staging/cognito.tf`.

---

## 4. Files

| File | Role |
|---|---|
| `services/cognito-user-migration/index.mjs` | The handler (Node 20 ESM, zero third-party runtime deps — global `fetch` + runtime-bundled `@aws-sdk/client-secrets-manager`). Exports `handler`, plus `resolveWebApiKey` / `firebaseSignInWithPassword` / `firebaseLookupByEmail` / `buildUserAttributes` for testing. |
| `services/cognito-user-migration/index.test.mjs` | Vitest unit tests — mocked Firebase responses, no live calls (16 tests). |
| `terraform/staging/cognito_migration_lambda.tf` | Lambda + IAM role (logs + read-only the one secret) + `aws_secretsmanager_secret.firebase_web_api_key` (**value not set**) + `aws_lambda_permission` for Cognito. |
| `terraform/staging/cognito.tf` | `lambda_config { user_migration = … }` on the pool + the `firebase_uid` custom attribute. |

### Config / secret seam

| Env var (Lambda) | Value on staging | Purpose |
|---|---|---|
| `FIREBASE_WEB_API_KEY_SECRET_ID` | `packiot/staging/firebase-web-api-key` | Secrets Manager **name**; the value is fetched at runtime, never in state. |
| `FIREBASE_PROJECT_ID` | `""` (empty) | Which Firebase project to verify against; set to `fbpackiot` only at prod cutover. |
| `MIGRATION_ENABLED` | `"false"` | Master gate. `"true"` only at cutover. |
| `FIREBASE_WEB_API_KEY` | *(unset)* | Optional direct-value override for local dev/tests; bypasses Secrets Manager. Never set in deployed infra. |

---

## 5. CUTOVER procedure (USER-gated — do NOT run as part of this PR)

Each step is a deliberate, reversible USER action. Nothing here happens on `terraform apply` of this PR.

**Staging cutover (validate the JIT path against a STAGING/test Firebase project):**
1. Populate the secret with the **staging/test** Firebase web API key (never the SA key):
   ```
   aws secretsmanager put-secret-value \
     --secret-id packiot/staging/firebase-web-api-key \
     --region us-east-1 \
     --secret-string '{"web_api_key":"<STAGING_FIREBASE_WEB_API_KEY>"}'
   ```
2. Set `FIREBASE_PROJECT_ID` to the staging project id and `MIGRATION_ENABLED=true` on the Lambda (terraform var flip or `aws lambda update-function-configuration`).
3. Sign a known staging user in against the staging Cognito pool via front4/Amplify → confirm the user appears in the pool `CONFIRMED` with `custom:firebase_uid` set, and CloudWatch logs show `user migrated on authentication`.

**Prod cutover (separate, later — only after the staging bake is clean):**
1. Provision the **prod** Cognito pool + this Lambda in `terraform/production` (separate state, `deletion_protection=ACTIVE`).
2. Populate the prod secret with the **prod** `fbpackiot` web API key.
3. Set `FIREBASE_PROJECT_ID=fbpackiot` + `MIGRATION_ENABLED=true` on the prod Lambda.
4. Flip front4 prod to Amplify Auth → prod migrate-on-login window opens; monitor migration rate.

### Rollback

| Revert | Effect |
|---|---|
| `MIGRATION_ENABLED=false` | Instantly disables all migration; the Lambda denies every invocation. First-line kill switch. |
| Blank the secret / delete the secret version | Lambda can't resolve the key → every migration fails cleanly (already-migrated Cognito users are unaffected). |
| Remove the `lambda_config` block (or set the ARN to null) in `cognito.tf` | Detaches the trigger from the pool entirely. |
| `terraform destroy` (staging) | Removes Lambda, role, and secret cleanly — staging pool has `deletion_protection=INACTIVE`. |

A Firebase outage during the window only stalls *new* migrations (a failed verify is a normal retry-able auth failure); already-migrated Cognito users are never affected, and un-migrated accounts stay in Firebase and migrate on a later successful login.

---

## 6. What this does NOT do

- Does **not** touch production Firebase `fbpackiot`, read the prod user list, or bulk-export users.
- Does **not** use or reference the Admin SA private key (`back4-api/private-key.json`).
- Does **not** set the secret value in code/terraform, and does **not** enable migration (gated OFF).
- Does **not** cut over front4, refdata, Hasura, or CS-Admin — those are the other ADR-0034 phases (P1–P7).
