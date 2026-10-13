---
title: oauth2-proxy and Cognito
layer: 3
owner_area: identity
last_verified: 2026-09-28
---
# oauth2-proxy and Cognito

> **Layer 3 · Components** — the Cognito user pool, its app clients and migration Lambda,
> and the oauth2-proxy forward-auth gate that host nginx puts in front of the staff and
> factory UIs. For whoever changes login, adds a vhost or debugs a 302/401/403 loop.
> Up: [Identity and access](../subsystems/identity.md)

## Responsibility

Cognito is the only identity provider of the new stack: it stores users and passwords,
the `cs-admin` group, and signs the ID tokens every backend verifies. oauth2-proxy is a small
OIDC relying party that host nginx asks, on every request to a gated vhost, "does this
browser have a valid Packiot session (and is it in `cs-admin`)?". It gates *page access*
only; it does not pass identity to the backends.

## At a glance

| | |
|---|---|
| Cognito pool | `packiot-staging`, id `us-east-1_0T9t1sTwt`, tier `LITE` (one pool serves staging **and** the new-stack production csadmin) |
| Hosted-UI domain | `packiot-auth` (`packiot-auth.auth.us-east-1.amazoncognito.com`) |
| App clients | `front4-amplify` (public, no secret), `oauth2-proxy-staging`, `oauth2-proxy-prod` (confidential) |
| Migration Lambda | `cognito-user-migration`, Node 20, arm64, source `services/cognito-user-migration/index.mjs` |
| oauth2-proxy image | `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0` |
| Container | `oauth2-proxy`, host port `127.0.0.1:4180`, static IP `172.18.0.39` on `packiot-net` |
| Session store (staging) | redis, `redis://app-redis:6379/1` |
| Public endpoint | `https://auth.staging.packiot.app/oauth2/{start,callback,sign_out}` |
| Depends on | Cognito, `app-redis`, host nginx |
| Depended on by | every vhost with `auth_request` (operator, operator-sbx, operator-bispharma, barcode, grafana, db, rabbitmq, api root) |

## Inputs & outputs

| Direction | What |
|---|---|
| In | nginx subrequest `GET /oauth2/auth` (any pool user) or `/oauth2/auth?allowed_groups=cs-admin` with the browser's cookies |
| Out | `202` (allowed) with `X-Auth-Request-User` / `X-Auth-Request-Email`; `401` (no session → nginx redirects to sign-in); `403` (session but wrong group) |
| In | browser at `/oauth2/start?rd=<url>` → redirect to the Cognito hosted UI (code flow, scopes `openid email profile`) |
| In | `/oauth2/callback` → back-channel code exchange with the client secret → session written to redis → cookie `_oauth2_proxy` for `.staging.packiot.app` |
| Out (Lambda) | Cognito `UserMigration_Authentication` / `_ForgotPassword` responses |

## Internal design

### Cognito pool (`terraform/staging/cognito.tf`)

- Email is the username (`username_attributes = ["email"]`, case-insensitive); email
  auto-verified; password min 8 with upper, lower and a digit; recovery by verified email.
- Custom attributes `custom:id_enterprise` and `custom:firebase_uid`. The backends resolve
  the tenant from the database, not from `custom:id_enterprise`; the Phase-0
  `barcode-service` scan API (superseded by edge-api `/api/scanned-boxes`) reads the claim.
- `front4-amplify` client: auth flows `USER_SRP_AUTH`, `USER_PASSWORD_AUTH` (needed so the
  migration Lambda can fire; SRP cannot), `REFRESH_TOKEN_AUTH`; ID and access tokens 1 h,
  refresh 30 days; `prevent_user_existence_errors = ENABLED`; no hosted-UI flows. Every
  backend checks `aud` against this client id, so a token minted by another client is 401.
- `oauth2-proxy-<env>` clients: `generate_secret = true`, `allowed_oauth_flows = ["code"]`,
  callback `https://auth.<env>.packiot.app/oauth2/callback`, logout `/oauth2/sign_out`.
  Terraform has `ignore_changes = [generate_secret]` because the secret cannot be read back
  on import. The secret is copied by hand into the host `.env` as
  `OAUTH2_PROXY_CLIENT_SECRET`.
- The `cs-admin` group is referenced by name (oauth2-proxy `allowed_groups`, edge-api
  `COGNITO_CS_ADMIN_GROUP`) and is managed by hand or by csadmin's Users page.

### Migrate-on-login Lambda (`terraform/staging/cognito_migration_lambda.tf`)

Firebase password hashes cannot be imported into Cognito, so the pool has a
`user_migration` trigger. When a user who is not yet in the pool signs in with
`USER_PASSWORD_AUTH`, Cognito calls the Lambda with the plaintext password; the Lambda
calls Firebase Identity Toolkit `accounts:signInWithPassword` with the Firebase **web** API
key (Secrets Manager `packiot/staging/firebase-web-api-key`, read at runtime), and on success
returns the user with `email_verified=true`, `finalUserStatus=CONFIRMED` and
`custom:firebase_uid`. `FIREBASE_PROJECT_ID = fbpackiot`, `MIGRATION_ENABLED = "true"`
since 2026-09-03. With the flag off every invocation denies. Passwords and keys are never
logged.

### oauth2-proxy (`compose.staging.yml`)

Configured only through `OAUTH2_PROXY_*` env vars (flag names differ, for example the flag
`--email-domain` vs env `EMAIL_DOMAINS`). `UPSTREAMS: static://202` means it never proxies
content; it only answers auth subrequests. `REVERSE_PROXY=true` makes it trust
`X-Forwarded-*` from nginx.

### Host nginx wiring (`terraform/staging/user_data/nginx_setup.sh`)

The script writes three shared files and one vhost per service:

| File | Content |
|---|---|
| `/etc/nginx/snippets/oauth2-proxy.conf` | `location = /oauth2/auth` and `= /oauth2/auth-csadmin` (both `internal`, 32k buffers), and `@oauth2_signin` → `302 https://auth.<domain>/oauth2/start?rd=<original url>` |
| `/etc/nginx/snippets/origin-verify.conf` | 403 unless `X-Origin-Verify` equals the secret from `packiot/staging/app` key `x_origin_verify` |
| `/etc/nginx/conf.d/00-oauth2-buffers.conf` | `large_client_header_buffers 8 32k` |
| `auth.conf` | `/oauth2/` → `127.0.0.1:4180`; everything else 404; no origin-verify (callbacks must work) |

A gated location looks like:

```nginx
location / {
    auth_request /oauth2/auth-csadmin;          # or /oauth2/auth for any pool user
    auth_request_set $auth_email $upstream_http_x_auth_request_email;
    error_page 401 = @oauth2_signin;            # 403 (wrong group) falls through
    proxy_pass http://127.0.0.1:<port>;
}
```

nginx `auth_request` silently ignores a query string, which is why the group filter is baked
into a second internal location instead of `auth_request /oauth2/auth?allowed_groups=…`.

Per-vhost tier comes from `service_auth` in `terraform/staging/variables.tf`:

| Tier | Gate | Vhosts (staging) |
|---|---|---|
| `csadmin` | origin-verify + `/oauth2/auth-csadmin` | grafana, rabbitmq, db (CloudBeaver), barcode |
| `any` | origin-verify + `/oauth2/auth`, with an API-route bypass list | operator, operator-sbx, operator-bispharma |
| `api` | origin-verify; `/api/*` and `/session*` bypass; `/` needs `cs-admin` | api |
| `none-originverify` | origin-verify only; the SPA owns its own Cognito login | csadmin, customize |
| no gate | deliberately open, own auth | refdata (read-api), scan, cpack-ingest, ingest, mq, auth |

!!! note "Operator bypass list is legacy"
    The operator vhosts bypass the gate only for old edge-nodered route names
    (`session|machines|…|set-api-key`). The SPA's `/api/*` and `/v1/*` calls are not in that
    list, so they go through `location /` and need a valid oauth2 cookie. This is inferred
    from the config, not observed as a failure.

## Configuration

| Variable | Default | Staging value | Effect |
|---|---|---|---|
| `OAUTH2_PROXY_PROVIDER` | — | `oidc` | generic OIDC |
| `OAUTH2_PROXY_OIDC_ISSUER_URL` | — | pool issuer URL | discovery + JWKS |
| `OAUTH2_PROXY_CLIENT_ID` | — | the `oauth2-proxy-staging` client | |
| `OAUTH2_PROXY_CLIENT_SECRET` | — | from `/opt/packiot/.env` | code exchange |
| `OAUTH2_PROXY_COOKIE_SECRET` | — | from `/opt/packiot/.env` | must be exactly 16, 24 or 32 bytes (`openssl rand -hex 16`) |
| `OAUTH2_PROXY_REDIRECT_URL` | — | `https://auth.staging.packiot.app/oauth2/callback` | |
| `OAUTH2_PROXY_OIDC_GROUPS_CLAIM` | `groups` | `cognito:groups` | makes `allowed_groups=cs-admin` work |
| `OAUTH2_PROXY_SCOPE` | — | `openid email profile` | |
| `OAUTH2_PROXY_EMAIL_DOMAINS` | — | `*` | any email |
| `OAUTH2_PROXY_COOKIE_DOMAINS`, `_WHITELIST_DOMAINS` | host only | `.staging.packiot.app` | one sign-in for all subdomains; `rd` may point at any of them |
| `OAUTH2_PROXY_COOKIE_SECURE`, `_SAMESITE` | | `true`, `lax` | |
| `OAUTH2_PROXY_SET_XAUTHREQUEST` | `false` | `true` | returns user/email headers to nginx |
| `OAUTH2_PROXY_PASS_ACCESS_TOKEN` | `false` | `false` | backends get no token from the gate |
| `OAUTH2_PROXY_SKIP_PROVIDER_BUTTON` | `false` | `true` | straight to the hosted UI |
| `OAUTH2_PROXY_UPSTREAMS` | | `static://202` | auth-only |
| `OAUTH2_PROXY_SESSION_STORE_TYPE` | `cookie` | `redis` | session server-side; small cookie |
| `OAUTH2_PROXY_REDIS_CONNECTION_URL` | | `redis://app-redis:6379/1` | DB 1 (edge-api reserves DB 0) |

Production (`compose.production.yml`) uses the `oauth2-proxy-prod` client,
`auth.prod.packiot.app` and `.prod.packiot.app`, and still the default **cookie** store.

## Data & invariants

- One sign-in covers every `*.staging.packiot.app` vhost (parent-domain cookie).
- A staging session can never be used on prod: separate clients and callback URLs.
- `app-redis` runs with `--save ""` and `--appendonly no`: sessions are lost on restart,
  which logs everyone out but is otherwise harmless.
- The gate never replaces backend auth: `/api/*` and `/session*` bypass it on the api vhost,
  and edge-api authenticates every call itself.

## Observability

- `docker logs oauth2-proxy`: one line per auth decision; a bad redis URL is fatal at boot,
  so a clean boot proves the store works.
- Blackbox probes against gated vhosts see `302` (no cookie). That is expected, not an outage.
- For a CloudFront 403 "Request blocked", read WAF sampled requests, not CloudWatch totals:
  `aws wafv2 get-sampled-requests --scope CLOUDFRONT --web-acl-arn <arn> --rule-metric-name <rule> --time-window …`.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| WAF cookie size (2026-09-13) | every admin vhost, even `GET /`, returns CloudFront 403 "Request blocked" | cookie store chunked the Cognito session into `_oauth2_proxy_0/_1` (~5.4 KB); a stale host-scoped copy doubled it past the 8 KB `SizeRestrictions_Cookie_HEADER` rule | redis session store (PR #1219). Browsers still holding the big cookie must clear `*.staging.packiot.app` cookies once; the fix cannot reach them because WAF blocks first. Latent on prod (cookie store). |
| Cookie secret length (2026-08-05) | container crash-loops on recreate | base64 secret of 44 chars; `sed` edit of `.env` silently failed and the running container hid it | use `openssl rand -hex 16`; edit `.env` with a tool that handles `+/=` |
| `502 upstream sent too big header` | after login | Cognito tokens in the cookie exceed nginx buffers | `proxy_buffer_size 32k` in the snippet, `large_client_header_buffers 8 32k` |
| Group filter ignored | non-staff reach staff UIs | `auth_request` with a query string no-ops | use the `/oauth2/auth-csadmin` internal location |
| RabbitMQ UI `431` | after login | Cowboy's 4 KB header limit | the rabbitmq vhost strips `Cookie` and injects Basic auth |
| Hosted UI double form | Playwright `fill` hangs | the classic hosted UI renders the form twice (one hidden) | select `input[name="username"]:visible` (see `e2e/fixtures/auth.ts`) |
| Vhost missing on the box | operator-sbx 403 (2026-09-20) | host nginx is written by user_data; a new vhost in the repo is not on a running box until the script (or a hand copy) is applied | re-run `nginx_setup.sh` or copy the vhost, then `nginx -t && systemctl reload nginx` |

## Operating it

- **Rotate the cookie secret**: put a new 32-hex value in `/opt/packiot/.env`, then
  `docker compose -p stack -f compose.staging.yml up -d oauth2-proxy` (recreate, not
  `docker restart`, which keeps the old env). Everyone signs in again.
- **Add a staff UI**: add the service to `services` and `service_auth` in
  `terraform/staging/variables.tf`, apply, and run the nginx setup on the box. DNS and
  CloudFront live in `terraform/staging/edge.tf` and `dns.tf`.
- **Create a user by hand** (prefer csadmin's Users page):
  `aws cognito-idp admin-create-user --user-pool-id us-east-1_0T9t1sTwt --username <email> --user-attributes file://attrs.json --message-action SUPPRESS`,
  then `admin-set-user-password --permanent`, and `admin-add-user-to-group --group-name cs-admin`
  for staff. Use `file://` for attributes: a non-ASCII character breaks the CLI shorthand.
  Then link the `identity.users` row (see [Identity](../subsystems/identity.md#linking-a-cognito-user-to-a-row)).
- **Unsafe**: `terraform destroy` on the pool (deletes every user; `deletion_protection` is
  `INACTIVE`); rotating the oauth2 client secret without updating `.env` on both hosts.

## Tests

- `services/cognito-user-migration/index.test.mjs` (`npm test`, vitest): migration trigger cases.
- `e2e/` Playwright projects log in through the hosted UI for operator and through the
  Amplify form for front4/csadmin/customize (`npm run creds` fetches QA users from Secrets
  Manager `packiot/staging/e2e-test-creds`).

## Source map

| Path | What's there |
|---|---|
| `terraform/staging/cognito.tf` | pool, `front4-amplify` client, hosted-UI domain, oauth2-proxy clients |
| `terraform/staging/cognito_migration_lambda.tf` | Lambda, IAM role, Firebase web-key secret |
| `services/cognito-user-migration/index.mjs` | migration handler |
| `compose.staging.yml` (`oauth2-proxy`, `app-redis`) | proxy config, session store |
| `compose.production.yml` (`oauth2-proxy`) | prod proxy config |
| `terraform/staging/user_data/nginx_setup.sh` | snippets, tiers, per-vhost gates |
| `terraform/staging/variables.tf` (`services`, `service_auth`) | vhost → port and tier |
| `docs/runbooks/oauth2-proxy-cognito-migration.md` | the Authentik → oauth2-proxy migration runbook |
