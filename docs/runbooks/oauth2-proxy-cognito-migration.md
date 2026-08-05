# oauth2-proxy (Cognito) — Authentik retirement runbook (ADR-0034 §C)

Replaces Authentik's embedded outpost with **oauth2-proxy** as the nginx
`auth_request` gate for the internal admin UIs, backed by the shared Cognito
pool. One SSO login covers every `*.<env>.packiot.app` admin subdomain.

## Components
- **Cognito** (`terraform/staging/cognito.tf`): hosted-UI domain `packiot-auth`
  + two confidential clients `oauth2-proxy-{staging,prod}` (code flow, secrets in
  each host `.env`). The domain provides the `/oauth2/authorize` + `/oauth2/token`
  endpoints oauth2-proxy discovers from the issuer URL.
- **oauth2-proxy container** (`compose.<env>.yml`): image
  `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0`, bound `127.0.0.1:4180`. OIDC
  provider = the pool; `--oidc-groups-claim=cognito:groups`; cookie scoped to
  `.<env>.packiot.app`. Secrets from `.env`: `OAUTH2_PROXY_CLIENT_SECRET`,
  `OAUTH2_PROXY_COOKIE_SECRET` (must be literally 16/24/32 bytes — use
  `openssl rand -hex 16`, NOT `-base64 32` which is 44 chars).

## nginx layer (HOST-managed at /etc/nginx — not in this repo)
- `snippets/oauth2-proxy.conf` — two internal gates + the sign-in redirect:
  - `location = /oauth2/auth`          → any authenticated pool user (operator)
  - `location = /oauth2/auth-csadmin`  → `?allowed_groups=cs-admin` (admin UIs)
  - `location @oauth2_signin`          → 302 to `auth.<env>/oauth2/start?rd=...`
  NB: nginx `auth_request` silently no-ops if its argument has a query string,
  so the group filter is baked into `proxy_pass`, not the `auth_request` line.
- `auth.<env>.packiot.app` vhost (`auth.conf`) serves `/oauth2/` → :4180 (the
  callback+start). During migration it also keeps the Authentik `location /`.
- `00-oauth2-buffers.conf` — `large_client_header_buffers 8 32k` + the oauth2
  locations set `proxy_buffer_size 32k` (Cognito tokens make the session cookie
  exceed 4kb → split into `_oauth2_proxy_N` cookies; default buffers → 502).
- Per protected vhost: `include snippets/oauth2-proxy.conf;` +
  `auth_request /oauth2/auth[-csadmin];` + `error_page 401 = @oauth2_signin;`.

## Gated vhosts (staging)
cs-admin: grafana, hasura, adminer, rabbitmq, edge-nodered, oeecloud-nodered.
any-auth: operator (API-route regex still bypasses — own edge-nodered JWT).
untouched: refdata, api (own token auth).

## Verify
    # unauthenticated → 302
    curl -so/dev/null -w '%{http_code}' https://grafana.<env>.packiot.app/
    # full login (cs-admin user) → UI loads. See scratchpad oauth2_login_test.py

## Rollback (per vhost)
Restore `/etc/nginx/conf.d/oauth2-bak/<vhost>.conf.<ts>` and reload nginx.
Authentik stays running until the separate retirement PR.

## Production (same playbook, prod values)
- Client `oauth2-proxy-prod` (25i5je849qsd1hetcinrbm2t2c); cookie `.prod.packiot.app`;
  redirect `https://auth.prod.packiot.app/oauth2/callback`; cert `prod.packiot.app`.
- Gated vhosts: grafana/adminer/hasura/rabbitmq (cs-admin), operator (any-auth),
  api (root cs-admin, `/api/*` bypass — edge-api x-api-key). No nodereds/refdata.
- oauth2-proxy in `compose.production.yml`; reaches the prod host via
  `promote production←staging` → deploy-production. Proven end-to-end (adminer +
  grafana login as a cs-admin Cognito user).
