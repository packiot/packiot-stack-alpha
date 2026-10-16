# customize.staging.packiot.app — infra runbook

Standing up the dedicated Customization Hub SPA at its own subdomain, mirroring
the csadmin / dbeaver pattern. The **app + compose service live in this repo**;
the **subdomain edge (DNS/CloudFront/oauth2/origin-nginx) lives in `api-terraform`**.

## In this repo (done / codified here)
- **App:** `customize/` — standalone Vite/React SPA (clone of csadmin's stack),
  own `Dockerfile.staging` + `nginx.staging.conf.template` (SPA fallback, `/api/`
  → `edge-api:8080`, hashed-asset immutable cache, **`= /index.html` no-store** —
  the deploy-staleness fix). Serves on container port 80.
- **compose.staging.yml:** `customize` service — build `./customize`, bound
  `127.0.0.1:8086:80`, container IP `172.18.0.51`, `depends_on: edge-api`.
- **CI:** no change needed — `deploy-staging.yml`'s `docker compose … build`
  builds every service, and `customize/` is a plain monorepo dir (not a submodule,
  so no submodule-init step). It builds + runs automatically on the next deploy.

## In `api-terraform` (ops — mirror the dbeaver PR #1222 precedent)
1. **`var.services`** += `customize = 8086` (host port the origin nginx proxies to).
2. **Origin nginx**: add a `customize.staging.packiot.app` server block →
   `proxy_pass http://127.0.0.1:8086;`, cloned from the `csadmin.staging` block
   (same `service_auth`/oauth2 wiring). The SPA is same-origin, so no extra
   `/api` rules are needed at the edge — the container's own nginx proxies `/api`.
3. **Route53**: `customize.staging.packiot.app` A-alias → the staging CloudFront
   distribution `EU535D92RK58M` (`*.staging.packiot.app`).
4. **oauth2 / WAF**: NO new config — the shared `*.staging` CloudFront + WAF +
   oauth2-proxy edge already gates every `*.staging` host (redis session store,
   per the WAF-8KB-cookie fix). The new subdomain inherits the gate once (2) + (3)
   land.
5. `terraform apply` to reconcile; then the next stack deploy serves the app.

## Verify after deploy (hardproof)
- `curl -sI https://customize.staging.packiot.app/` → 302 to Cognito (gate works).
- Authenticated: Hub renders; `/api/*` proxies to edge-api (descriptor loads);
  `index.html` returns `Cache-Control: no-store` (no stale SPA on redeploys).
- On the box: `docker ps --filter name=customize` up; `:8086` serves 200.

## Notes
- Prod promotion mirrors csadmin: same image/config, a `customize.prod` behavior
  on the prod CloudFront (`*.prod.packiot.app`) once staging is proven.
- Auth token + `/api` behavior are identical to csadmin, so edge-api's
  `EDGE_API_COGNITO_AUTH_ENABLED` already accepts this app's Cognito tokens.
