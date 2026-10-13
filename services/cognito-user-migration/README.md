# cognito-user-migration

AWS Lambda for the staging Cognito user pool's User Migration trigger: migrates a Firebase user
into Cognito the first time they sign in, keeping their password (ADR-0034).

## What it does

Firebase stores passwords as project-specific scrypt hashes that Cognito cannot import, so a bulk
import would force every user to reset their password. Instead, when a user who is not yet in the
pool signs in, Cognito invokes this Lambda with the email and password. The Lambda checks them
against Firebase's Identity Toolkit REST API (`accounts:signInWithPassword`) with the Firebase
**web** API key; on success it returns the user's attributes with `finalUserStatus = CONFIRMED`, and
Cognito creates the user with that same password. On a forgotten password it only confirms the
account exists in Firebase (`accounts:createAuthUri`) and lets Cognito send its own reset code.
Every failure is the same opaque "Bad credentials"; passwords and key material are never logged.
Firebase is never written to.

## Where it fits

```text
 front4 / csadmin login (Amplify)
        │ sign-in for an email not yet in the pool
        ▼
 Cognito user pool (staging) ── UserMigration trigger ──▶ this Lambda
                                                          │ GetSecretValue
                                                          ├─▶ Secrets Manager packiot/staging/firebase-web-api-key
                                                          │ HTTPS
                                                          └─▶ identitytoolkit.googleapis.com (Firebase)
        ◀── userAttributes {email, email_verified, name, custom:firebase_uid} ──┘
```

## Status and environments

| Environment | Where | Image | Ports | Health |
|---|---|---|---|---|
| dev | none (not a container; the dev Cognito pool has no migration trigger) | — | — | — |
| staging | Lambda `packiot-staging-cognito-user-migration` (`terraform/staging/cognito_migration_lambda.tf`), attached as `lambda_config.user_migration` of the staging pool (`terraform/staging/cognito.tf`). Terraform sets `MIGRATION_ENABLED = "true"` (on since 2026-09-03) | zip of `index.mjs` only, Node.js 20, arm64, 128 MB, 10 s timeout | — | CloudWatch Logs of the function |
| production | not in `terraform/production/` | — | — | — |

## Interfaces

### HTTP

N/A: no HTTP server. Invoked by Cognito (`lambda:InvokeFunction` granted to `cognito-idp.amazonaws.com`
for the staging pool only). Trigger sources handled: `UserMigration_Authentication`,
`UserMigration_ForgotPassword`; any other source throws. No OpenAPI spec.

Outbound: `POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword` and
`.../accounts:createAuthUri`, key passed as the `key` query parameter.

### Messaging

N/A.

### Database

N/A: reads no database. Cognito stores the migrated user; the Firebase uid travels in the pool's
custom attribute `custom:firebase_uid`.

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `MIGRATION_ENABLED` | unset (= off) | yes, to do anything | Must be `true` (case-insensitive); otherwise every invocation denies without calling Firebase. Staging: `true` |
| `FIREBASE_WEB_API_KEY_SECRET_ID` | — | one of the two key sources | Secrets Manager id of the web API key. Staging: `packiot/staging/firebase-web-api-key` (value populated manually; never in Terraform). Bare string or JSON `{"web_api_key": …}` |
| `FIREBASE_WEB_API_KEY` | — | one of the two key sources | Key given directly; wins over the secret. For local tests only |
| `FIREBASE_UID_ATTRIBUTE` | `custom:firebase_uid` | no | Cognito attribute that receives the Firebase `localId`; set to `""` to drop it |

Terraform also sets `FIREBASE_PROJECT_ID = "fbpackiot"`; the code does not read it (the web API key
already determines the Firebase project). The resolved key is cached per warm container.

## Run locally

There is no dev slice (it only runs inside Cognito). Unit tests mock `fetch` and Secrets Manager:

```sh
cd services/cognito-user-migration
npm ci
npm test            # vitest run (index.test.mjs)
```

No CI workflow runs these tests; run them before changing `index.mjs`.

## Operating it

- **Deploy:** not part of "Deploy to Staging". Terraform packages `index.mjs` (`archive_file`) and
  updates the function on `make tf-plan` / `make tf-apply` in `terraform/staging/`. Only
  `index.mjs` ships: no `node_modules` (the Node 20 runtime provides `fetch` and the AWS SDK v3).
- **Turn it off:** set `MIGRATION_ENABLED` to anything but `true`, or remove the pool's
  `lambda_config` block, then apply.
- **Logs:** CloudWatch Logs (`AWSLambdaBasicExecutionRole`), one JSON line per event with `service`,
  `message`, `trigger`, `email`, outcome `code`. Useful messages: `user migrated on authentication`,
  `firebase password verification denied`, `migration disabled — denying`.
- **Metrics/dashboards:** none in `grafana/` or `monitoring/`; use the Lambda's CloudWatch metrics.
- **Failure modes:**
  - All migrations deny with `migration disabled — denying` → `MIGRATION_ENABLED` is not `true`.
  - `no Firebase web API key configured` or `secret is empty or malformed` → the secret is missing or
    unpopulated; the login fails like any wrong password.
  - A user exists in Firebase but login fails → Firebase returned `INVALID_PASSWORD`,
    `EMAIL_NOT_FOUND`, `USER_DISABLED` or `INVALID_LOGIN_CREDENTIALS` (logged as `code`).

## Code layout

| Path | What |
|---|---|
| `index.mjs` | Lambda handler, key resolution, Firebase REST calls, attribute mapping |
| `index.test.mjs` | vitest unit tests |
| `package.json`, `package-lock.json` | test toolchain (`vitest`) and the SDK dependency for local runs |

## Related docs

- [ADR-0034 — adopt Cognito/Amplify auth](../../docs/adr/0034-adopt-cognito-amplify-auth.md)
- [ADR-0034 reference — JIT user migration Lambda](../../docs/adr/reference/0034-jit-user-migration-lambda.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [oauth2-proxy-and-cognito](https://wiki.packiot.app/understand/components/oauth2-proxy-and-cognito/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
