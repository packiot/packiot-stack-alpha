# #159 primary-api Cognito patch

`159-primary-api-cognito-dual-accept.patch` is the primary-api (`packiot/api`,
NestJS) half of the Firebase→Cognito dual-accept work. It lives here as a **patch
file** rather than a PR because **`packiot/api` is an ARCHIVED (read-only) GitHub
repo** — a branch cannot be pushed to it. (This archival is itself worth
confirming: if primary-api is being retired rather than kept, the dual-accept leg
may be unnecessary — see the epic's Phase 1 note.)

## What it does

Mirrors the back4-api `feat/cognito-dual-accept` branch for primary-api:
`CognitoStrategy` (aws-jwt-verify ID-token verify, **dark unless
`COGNITO_AUTH_ENABLED=true` + `COGNITO_USER_POOL_ID`/`COGNITO_CLIENT_ID`**) +
`AuthCognito` DAO (resolve-by-sub + single-row link-on-login), wired into
`AuthGuardModule` + `MultiAuthGuard`. Additive, behavior-neutral while off.

Proven on a local checkout of `packiot/api@main` (commit before archival):
`nest build` clean, **24 auth tests green** (10 new).

## To apply (once a writable home for primary-api exists)

```bash
git clone <writable primary-api remote> && cd api
git checkout -b feat/159-cognito-dual-accept
git am < 159-primary-api-cognito-dual-accept.patch   # or: git apply
npm install && npm run build && npx jest src/auth src/data/DAO/auth-middleware
```

Runtime: keep it dark. Only set the three `COGNITO_*` env vars at cutover
(epic Phase 1/3), never before the packiot40 `id_user_cognito` column exists.
