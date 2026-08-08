# W2 — Embedded Superset (self-service BI) — Implementation Spec

Status: DRAFT (2026-08-07). Owner: platform. Scope: **W2 of the front4 program**
(`docs/plans/front4-cognito-cutover-and-bi-migration.md`). This is a **design +
scaffolding** deliverable — **nothing here is deployed**. It specifies how to
embed a self-hosted, multi-tenant **Apache Superset** into front4 so factory
customers can **build their own reports** (and view curated ones), with tenancy
driven by the new stack's **Cognito** identity.

> **Why Superset (re-cut from Metabase).** The predecessor design
> (`docs/plans/w2-embedded-metabase.md`) required Metabase **Enterprise**
> (interactive embedding + data sandboxing are paid features). That licensing was
> judged **infeasible**, so W2 is re-cut onto **Apache Superset** — Apache-2.0,
> **free**, self-hosted. Superset delivers the same multi-tenant self-service
> capability with **no license**, at the cost of **heavier ops** (Redis + Celery +
> its own metadata DB) and **more auth integration** (per-user Cognito-OIDC
> accounts for authoring instead of a paid sandbox). This spec is honest about
> that trade throughout (see §2, §6).

> **Decided constraints (honored throughout):**
> - **Superset** (Apache-2.0, self-hosted). No paid tier.
> - **Curated flagship OEE stays NATIVE in front4** (refdata + charts). Superset
>   is ONLY the "build your own" self-service surface.
> - Tenancy comes from the **Cognito identity**, enforced in two layers:
>   (a) **Superset RLS** — a per-tenant `id_enterprise` filter, applied via the
>   **guest token** (viewing) AND a **role-bound filter** (authoring);
>   (b) Postgres **RLS** is a DB-level **co-enforcer** keyed on the
>   `app.tenant_id` session GUC — it genuinely FILTERS when the GUC is stamped
>   and DENIES when unset (fail-closed), because the curated `bi.*` views are
>   SECURITY DEFINER owned by a NOBYPASSRLS role. Superset RLS is the PRIMARY
>   enforcer for the pooled embed path; Postgres RLS co-enforces on any
>   per-tenant-stamped connection (§3).
> - **Self-hosted** on the existing stack (Docker Compose now, K8s later). Data
>   source = the **TimescaleDB/Postgres** the stack already runs. New stack is
>   **Cognito** (refdata = read plane, edge-api = write/Cognito-aware plane). **No
>   Firebase, no Hasura** in this design.

Scaffolding shipped alongside this spec (all INERT / profile-gated — nothing
deploys until the W2 go decision):
- `compose.superset.yml` — profile-gated (`profiles: ["superset"]`) overlay: the
  web app + Celery worker + dedicated `superset-redis` + a one-shot that creates
  the dedicated `superset` **metadata** DB + the init one-shot. Applied on top of
  the env base file; default `docker compose up` is unchanged (§1.3).
- `db/superset/01-superset-ro-role.sql` — the curated `bi.*` views + the read
  roles, wired so Postgres RLS is a REAL co-enforcer: the views are **SECURITY
  DEFINER, owned by a NOBYPASSRLS `bi_owner`**, and `superset_ro` is created
  **NOLOGIN with no password literal** (LOGIN + password injected at apply from
  Secrets Manager — the Metabase `CHANGE_ME_AT_APPLY` anti-pattern is gone).
- `db/superset/02-tenant-rls.sql` — Postgres RLS **co-enforcer** on all five base
  tables behind the views, keyed on the `app.tenant_id` session GUC (§3.2).
- `db/superset/03-authoring-rls-mapping.optional.sql` — optional `bi.user_tenant`
  mapping table for authoring-RLS **Strategy B** (§2.3).
- `db/superset/README.md` — the two-isolation-layers explainer.
- `configs/superset/superset_config.py` — the Superset config (§1.5): Talisman
  frame-ancestors, cross-site cookie, Cognito OIDC, and the SQL-Lab denial for the
  authoring role (§2.3).
- `configs/superset/custom_sso_security_manager.py` — the Cognito→per-tenant-RLS
  security-manager sketch (§2.3).
- `terraform/production/user_data/nginx_setup.sh` — the bespoke iframe-embeddable
  `bi.<domain>` vhost (modeled on the refdata block; §1.4).
- **`tests/superset/`** — the NON-NEGOTIABLE 2-tenant isolation GATE (§7): an
  ephemeral-Postgres pytest that applies the real SQL, seeds two tenants, and
  proves disjoint per-tenant row-sets + fail-closed-on-unset + the
  no-view-without-a-rule guard. Wired blocking in
  `.github/workflows/superset-rls-isolation.yml`.
- **edge-api endpoint** — `POST /api/superset/guest-token` is a REAL, tested slice
  landed in the edge-api submodule (PR
  [packiot/edge-api#175](https://github.com/packiot/edge-api/pull/175)), NOT a
  sketch (§2.2). The front4 component remains a code sketch here (§4).

---

## 0. Architecture at a glance

Two surfaces, ONE tenant key (`id_enterprise`), both enforced by Superset RLS:

```
                          ┌──────────────────────────────────────────────┐
Factory supervisor        │  front4 SPA  (holds a Cognito ID token)       │
(browser)                 └───────────────┬───────────────┬──────────────┘
                                          │               │
              (A) VIEW curated dashboards │               │ (B) BUILD your own reports
                  embedded in front4      │               │     (full Explore / SQL Lab)
                                          ▼               ▼
   POST /api/superset/guest-token   ┌──────────┐   redirect → Superset /login/cognito
   Authorization: Bearer <cognito>  │ edge-api │   (OIDC; user logs in with Cognito)
                                    │(Cognito- │
   a. verify Cognito JWT (JWKS)     │  aware   │   Superset is an OIDC relying party:
   b. derive id_enterprise SERVER-  │  write   │   custom security manager reads the
      side (resolveEnterpriseByUid) │  plane)  │   Cognito id_enterprise claim → binds
   c. call Superset admin API:      └────┬─────┘   a per-tenant RLS filter to the user
      POST /security/guest_token          │        (role tenant_<id>), grants Gamma_BI
      { user, resources:[dashboard],      │
        rls:[{clause:"id_enterprise=42"}]}│
   d. return guest token to browser       │
                                          ▼
front4  @superset-ui/embedded-sdk    ┌─────────────────────────────────────────────┐
  embedDashboard({ fetchGuestToken })│  Superset web  (+ Celery worker + beat)      │
        (curated view, RLS-scoped)   │  metadata DB: `superset` on the r7g          │
                                     │  cache/broker/results: superset-redis        │
                                     └──────────────────────┬──────────────────────┘
                                                            │ superset_ro (SELECT-only)
                                                            ▼
                                     ┌─────────────────────────────────────────────┐
                                     │  TimescaleDB / Postgres (analytics)          │
                                     │  reads curated bi.* views (each carries      │
                                     │  id_enterprise)                              │
                                     │  Layer-1: Superset RLS  →  WHERE id_enterprise│
                                     │           = <tenant>  (guest OR role filter)  │
                                     │  Layer-2: Postgres RLS backstop (app.tenant_id│
                                     │           GUC) — fail-closed defense-in-depth │
                                     └─────────────────────────────────────────────┘
```

Key property (same as the Metabase design): the **browser holds only its own
Cognito token**. The Superset admin credential (used to mint guest tokens), the
DB credentials, and the tenant derivation all live server-side in edge-api / the
stack. No BI secret ever reaches the browser — same posture as back4's PowerBI
`/getEmbedToken` and edge-api's api-key injection at nginx.

The one structural difference vs Metabase: **authoring can't ride the embed
token.** Superset's guest token is **view-only** (see §2.1). So authoring users
get a **real Superset account via Cognito OIDC** — that is the load-bearing change
this spec designs (§2.2–§2.3).

---

## 1. Deployment (heavier than Metabase)

Superset is not one container. It needs: the **web app**, a **Celery worker**
(async SQL Lab queries, alerts, thumbnails), optionally **Celery beat** (scheduled
alerts/reports), **Redis** (cache + Celery broker + results backend), and its own
**metadata DB**. That is the free-vs-paid trade: Metabase was one container + a
license; Superset is four services + no license.

### 1.1 Redis — dedicated `superset-redis`, do NOT reuse app-redis

The stack already runs two Redis instances: `authentik-redis` (.14) and
`app-redis` (.35, refdata cache-aside). **Neither is reusable for Superset's
Celery broker.** `app-redis` runs `--maxmemory-policy allkeys-lru` — an eviction
cache. A Celery broker on an LRU cache will **silently drop task messages** under
memory pressure (a queued async query / alert just vanishes). So Superset gets a
**dedicated** `superset-redis` with `noeviction` (broker safety) and light
persistence, sharing three logical DBs: `0`=cache, `1`=Celery results, `2`=Celery
broker.

```yaml
  # ── superset-redis (W2 — Superset cache + Celery broker/results) ──────────────
  # DEDICATED (not app-redis: that's allkeys-lru and would drop broker messages).
  # noeviction so the Celery broker never loses a task; small AOF for durability.
  superset-redis:
    image: redis:7-alpine
    container_name: superset-redis
    restart: unless-stopped
    command: >
      redis-server
      --maxmemory 256mb
      --maxmemory-policy noeviction
      --appendonly yes
      --save ""
    networks:
      packiot-net:
        ipv4_address: 172.18.0.45
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 15s
      timeout: 3s
      retries: 3
      start_period: 5s
    mem_limit: 320m
    cpus: 0.5
    logging:
      driver: json-file
      options: {max-size: "5m", max-file: "2"}
```

### 1.2 Metadata DB — dedicated `superset` role+DB (mirror authentik)

Superset stores ALL its state (users, roles, dashboards, charts, datasets, RLS
filters, embedded configs) in a metadata DB. This **must be separate** from the
analytics DB — mixing Superset's mutable metadata into the OEE schema is both a
blast-radius and a backup-lineage mistake. Mirror exactly how **authentik** gets
its own DB: extend the `db-init-bootstrap` inline command (same shell-guard
pattern — `CREATE ROLE`/`CREATE DATABASE` are not `IF NOT EXISTS`):

```sh
echo "== superset role + database (idempotent) =="
if [ -z "$${SUPERSET_DB_PASSWORD:-}" ]; then
  echo "SUPERSET_DB_PASSWORD unset — superset WILL fail; set it in .env"; exit 1;
fi
if [ "$$(psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='superset'")" != "1" ]; then
  psql -v ON_ERROR_STOP=1 -c "CREATE ROLE superset WITH LOGIN PASSWORD '$$SUPERSET_DB_PASSWORD';";
fi
if [ "$$(psql -tAc "SELECT 1 FROM pg_database WHERE datname='superset'")" != "1" ]; then
  psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE superset WITH OWNER = superset;";
fi
```

> Two DB connections, never conflate them:
> - **`superset`** — owns its metadata DB, read-write (Flask/SQLAlchemy). Via pgbouncer.
> - **`superset_ro`** — SELECT-only on the analytics `bi` schema (the OEE data),
>   provisioned by `db/superset/01-superset-ro-role.sql`. Registered as a Superset
>   "database" in the UI AFTER boot, never in config.

### 1.3 Superset compose services (web + worker + beat)

All three Superset processes share the SAME image and the SAME
`configs/superset/superset_config.py` (bind-mounted); they differ only in
entrypoint. `172.18.0.42/.43/.44` are free (used range: .2–.35).

```yaml
  # ── Superset web (W2 self-service BI) ─────────────────────────────────────────
  superset:
    image: apache/superset:4.1.1              # pin; FREE (Apache-2.0), no license
    restart: unless-stopped
    env_file: [.env]
    environment:
      SUPERSET_SECRET_KEY:               ${SUPERSET_SECRET_KEY}
      SUPERSET_GUEST_TOKEN_JWT_SECRET:   ${SUPERSET_GUEST_TOKEN_JWT_SECRET}
      SUPERSET_DB_PASSWORD:              ${SUPERSET_DB_PASSWORD}
      SUPERSET_COGNITO_ISSUER:           ${SUPERSET_COGNITO_ISSUER}
      SUPERSET_COGNITO_CLIENT_ID:        ${SUPERSET_COGNITO_CLIENT_ID}
      SUPERSET_COGNITO_CLIENT_SECRET:    ${SUPERSET_COGNITO_CLIENT_SECRET}
      SUPERSET_FRAME_ANCESTOR:           https://front.prod.packiot.app
      SUPERSET_REDIS_HOST:               superset-redis
      PYTHONPATH:                        /app/pythonpath
    volumes:
      - ./configs/superset/superset_config.py:/app/pythonpath/superset_config.py:ro
      - ./configs/superset/custom_sso_security_manager.py:/app/pythonpath/custom_sso_security_manager.py:ro
    # First boot MUST run DB migrations + create the admin used to mint guest
    # tokens. Do it in an INIT one-shot (below), not inline, so restarts are fast.
    command: ["gunicorn", "--bind", "0.0.0.0:8088", "--workers", "4",
              "--worker-class", "gthread", "--threads", "20", "--timeout", "120",
              "superset.app:create_app()"]
    ports:
      - "127.0.0.1:8088:8088"     # 8088 = Superset native (grafana owns :3000; avoid metabase's :3001)
    networks:
      packiot-net:
        ipv4_address: 172.18.0.42
    depends_on:
      superset-init:
        condition: service_completed_successfully
      superset-redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8088/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s
    logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}

  # ── Superset init (one-shot: DB migrate + roles + guest-token admin) ──────────
  superset-init:
    image: apache/superset:4.1.1
    env_file: [.env]
    environment:                     # same secrets as `superset` (elided for brevity)
      SUPERSET_SECRET_KEY: ${SUPERSET_SECRET_KEY}
      SUPERSET_DB_PASSWORD: ${SUPERSET_DB_PASSWORD}
      PYTHONPATH: /app/pythonpath
    volumes:
      - ./configs/superset/superset_config.py:/app/pythonpath/superset_config.py:ro
      - ./configs/superset/custom_sso_security_manager.py:/app/pythonpath/custom_sso_security_manager.py:ro
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        superset db upgrade
        superset init                # syncs built-in roles (Admin/Alpha/Gamma/Public) + perms
        # The guest-token minting service account edge-api authenticates as.
        # Give it ONLY the can_grant_guest_token perm in the real PR (custom role),
        # not full Admin. Password from Secrets Manager.
        superset fab create-admin \
          --username "$${SUPERSET_GUESTTOKEN_ADMIN_USER}" \
          --firstname guest --lastname minter --email guesttoken@packiot.app \
          --password "$${SUPERSET_GUESTTOKEN_ADMIN_PASSWORD}" || true
    depends_on:
      db-init-bootstrap:
        condition: service_completed_successfully
      superset-redis:
        condition: service_healthy
    networks:
      packiot-net: {ipv4_address: 172.18.0.44}   # transient; reuse a free .4x
    restart: "no"
    logging: {driver: json-file, options: {max-size: "5m", max-file: "2"}}

  # ── Superset Celery worker (async SQL Lab, alerts, thumbnails) ────────────────
  superset-worker:
    image: apache/superset:4.1.1
    restart: unless-stopped
    env_file: [.env]
    environment:                     # SAME env as `superset`
      SUPERSET_SECRET_KEY: ${SUPERSET_SECRET_KEY}
      SUPERSET_GUEST_TOKEN_JWT_SECRET: ${SUPERSET_GUEST_TOKEN_JWT_SECRET}
      SUPERSET_DB_PASSWORD: ${SUPERSET_DB_PASSWORD}
      SUPERSET_REDIS_HOST: superset-redis
      PYTHONPATH: /app/pythonpath
    volumes:
      - ./configs/superset/superset_config.py:/app/pythonpath/superset_config.py:ro
      - ./configs/superset/custom_sso_security_manager.py:/app/pythonpath/custom_sso_security_manager.py:ro
    command: ["celery", "--app=superset.tasks.celery_app:app", "worker",
              "--pool=prefork", "--concurrency=2", "-Ofair"]
    depends_on:
      superset:
        condition: service_healthy
    networks:
      packiot-net: {ipv4_address: 172.18.0.43}
    healthcheck:
      test: ["CMD-SHELL", "celery --app=superset.tasks.celery_app:app inspect ping -d celery@$$HOSTNAME || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}

  # ── Superset Celery beat (scheduler) — ONLY if alerts/reports are used ────────
  # Optional for W2 MVP (viewing + authoring need no scheduler). Add when we ship
  # scheduled email/Slack alerts. Runs a SINGLE replica (beat must be singleton).
  # superset-beat:
  #   image: apache/superset:4.1.1
  #   command: ["celery", "--app=superset.tasks.celery_app:app", "beat",
  #             "--pidfile", "/tmp/celerybeat.pid", "-s", "/tmp/celerybeat-schedule"]
  #   ... (same env/volumes; ipv4 .44 after superset-init exits)
```

> **Ops weight callout:** this is **4 always-on containers** (web, worker,
> superset-redis, + beat when alerts land) vs Metabase's **1**. Budget the r7g
> node headroom accordingly (`mem_limit`s above are conservative starting points —
> Superset web is the memory hog; watch it under real query load). This heavier
> footprint is the single biggest *operational* cost of going free (§6).

### 1.4 Host nginx vhost — `superset.prod.packiot.app` (iframe-embeddable)

Mirror the **refdata** vhost in `terraform/production/user_data/nginx_setup.sh`
(codified in #765): a **bespoke** vhost with `origin-verify` (CloudFront-only) +
scoped CORS. **Critical difference vs refdata AND vs Metabase's proposed vhost:**
the response must be **iframe-embeddable by front4**. We do NOT send
`X-Frame-Options`; instead **Superset itself emits `Content-Security-Policy:
frame-ancestors …`** via Talisman (`TALISMAN_CONFIG` in `superset_config.py`,
§1.5). nginx must not add `X-Frame-Options` (it would override the CSP and blank
the iframe). Note WebSocket upgrade headers — Superset uses websockets for async
query progress.

Add `services`/`service_auth` entries so the terraform csadmin loop skips it
(bespoke, like `api`/`operator`/`csadmin`/`refdata`):

```hcl
# terraform/*/variables.tf — services map
superset = 8088       # 127.0.0.1 host port (see compose)
# service_auth map
superset = "bespoke"  # emitted as an explicit block below, skipped by the loop
```

Bespoke vhost block (paste after the refdata block in `nginx_setup.sh`):

```nginx
# ── superset vhost (W2 self-service BI — embedded in front4) ───────────────────
# superset.$PRODUCTION_DOMAIN. origin-verify (CloudFront-only) + Superset's OWN
# auth (guest tokens for embeds; Cognito-OIDC session for authoring — NOT
# oauth2-proxy: a cookie forward-auth would break both the iframe handshake and
# the OIDC redirect). CORS scoped to the front4 SPA origin. Superset emits its own
# frame-ancestors CSP (Talisman) so we do NOT add X-Frame-Options here. Proxies
# the superset container's static IP 172.18.0.42:8088.
cat > /etc/nginx/conf.d/superset.conf <<NGINX
map \$http_origin \$superset_cors {
    default "";
    "~^https://front\.$PRODUCTION_DOMAIN\$" \$http_origin;
}
server {
    listen 80;
    server_name superset.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name superset.$PRODUCTION_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;
    client_max_body_size 20m;            # SQL Lab / CSV upload headroom
    location / {
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin  \$superset_cors always;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-CSRFToken" always;
            add_header Access-Control-Allow-Credentials "true" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Vary Origin always;
            return 204;
        }
        add_header Access-Control-Allow-Origin  \$superset_cors always;
        add_header Access-Control-Allow-Credentials "true" always;
        add_header Vary Origin always;
        # NOTE: NO X-Frame-Options here — Superset's Talisman CSP owns embeddability.
        proxy_pass         http://172.18.0.42:8088;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;    # async-query websocket
        proxy_set_header   Connection        \$ws_connection;
    }
}
NGINX
```

Plus (in `terraform/production/edge.tf`, the CloudFront layer): a
`superset.prod.packiot.app` alias/behavior injecting the `X-Origin-Verify` shared
secret, + a Route53 record — mirror the existing `refdata`/`operator` edge
entries.

### 1.5 `superset_config.py` sketch

Full sketch shipped at `configs/superset/superset_config.py`; the load-bearing
pieces:

| Area | Setting | Why |
|---|---|---|
| Secret | `SECRET_KEY` | signs the session cookie; must be stable + identical across web/worker/beat |
| Guest token | `GUEST_TOKEN_JWT_SECRET`, `GUEST_TOKEN_JWT_EXP_SECONDS=300`, `GUEST_ROLE_NAME` | signs embed guest tokens; independent of `SECRET_KEY` so it rotates alone |
| Metadata DB | `SQLALCHEMY_DATABASE_URI` → `superset@pgbouncer/superset` | Superset's own state; NOT the analytics DB |
| Cache | `CACHE_CONFIG` + `DATA_CACHE_CONFIG` + `FILTER_STATE_CACHE_CONFIG` on redis db0 | filter-state cache is **required** for embedded dashboards |
| Async | `RESULTS_BACKEND` (redis db1) + `CELERY_CONFIG` (broker db2) | async SQL Lab + alerts run on Celery |
| Feature flags | `EMBEDDED_SUPERSET=True`, `DASHBOARD_RBAC=True`, `ALERT_REPORTS=True` | unlock embed + per-role dashboards + scheduled reports. (Native RLS is GA — configured in UI, not a flag.) |
| Embed | `TALISMAN_CONFIG` CSP `frame-ancestors: [front4 origin]`, `frame_options: None` | the iframe hinge; NEVER `X-Frame-Options` |
| Cross-site cookie | `SESSION_COOKIE_SAMESITE="None"`, `SESSION_COOKIE_SECURE=True` | front4 frames Superset cross-site |
| CORS | `ENABLE_CORS=True`, `CORS_OPTIONS.origins=[front4]` | scoped to the SPA origin |
| Authoring auth | `AUTH_TYPE=AUTH_OAUTH`, `OAUTH_PROVIDERS=[cognito]`, `AUTH_USER_REGISTRATION_ROLE="Gamma_BI"`, `CUSTOM_SECURITY_MANAGER` | Cognito-OIDC login → auto-provisioned scoped accounts (§2.2) |

---

## 2. THE HARD PART — authoring vs viewing

### 2.1 Why one token can't do both

Superset's **guest token** (`@superset-ui/embedded-sdk`) is **dashboard-VIEW
centric**. A guest token authenticates as an **Anonymous user with the `Public`
role**, scoped to the specific `resources` (dashboards) named in the token. It
**cannot** create charts, cannot open Explore against arbitrary datasets, cannot
use SQL Lab. That is by design — it is a signed, short-lived, read-only capability
for embedding a *known* dashboard.

So the requirement "**customers build their own reports**" cannot be met by the
embed token alone. We design **both** surfaces, each with its own RLS binding:

| Surface | Who | Mechanism | RLS binding |
|---|---|---|---|
| **(A) View curated dashboards** | any supervisor | guest token, embedded SDK, in front4 | RLS clause **inline in the token** (edge-api mints it) |
| **(B) Build your own reports** | supervisors | **real Superset account via Cognito OIDC** | RLS filter **bound to the user's tenant role** (security manager) |

### 2.2 (A) Viewing — edge-api mints a Superset guest token

Exactly the "no secret in the browser" posture from the Metabase design, adapted
to Superset's guest-token API.

**Flow:**
1. front4 calls `POST /api/superset/guest-token` with the caller's existing
   `Authorization: Bearer <cognito-id-token>`.
2. edge-api verifies the Cognito JWT via the **existing** `JwksBearerJwtVerifier`
   (RS256/JWKS, `iss`+`aud`+`exp`, fail-closed).
3. edge-api derives `id_enterprise` **server-side** via the **existing**
   `resolveEnterpriseByUid` — the client-asserted tenant is never trusted.
4. edge-api authenticates to Superset as a **service admin** (one-time
   `POST /api/v1/security/login` → a short-lived Superset access token; cache it)
   and calls **`POST /api/v1/security/guest_token/`** with the RLS clause bound to
   the derived tenant.
5. edge-api returns ONLY the guest token to the browser. The Superset admin
   credential + guest-token signing secret never leave the server.

**Guest-token request body** (edge-api → Superset):
```jsonc
{
  "user": {                                  // cosmetic; identifies the embed session
    "username": "supervisor@acme-factory.com",
    "first_name": "Ana",
    "last_name":  "Silva"
  },
  "resources": [
    { "type": "dashboard", "id": "3f2a…-uuid" }   // the curated OEE dashboard's embed UUID
  ],
  "rls": [
    { "clause": "id_enterprise = 42" }        // THE tenant lock — server-derived, NEVER client-supplied
  ]
}
```
Superset ANDs `id_enterprise = 42` into every query the embedded dashboard emits
against the `bi.*` datasets (verified in `superset/connectors/sqla/models.py:
get_sqla_row_level_filters` — guest RLS clauses are appended to `all_filters`).
Because `clause` is raw SQL, edge-api MUST build it from the **integer**
`id_enterprise` it derived (never string-concat anything client-supplied) — an int
has no injection surface. Optionally scope the rule to a dataset:
`{ "dataset": "<dataset-id>", "clause": "id_enterprise = 42" }`.

**edge-api endpoint sketch** (vertical slice — land in the edge-api submodule):
```ts
// src/usecases/superset-embed/superset-embed.controller.ts
@Controller('api/superset')
export class SupersetEmbedController {
  constructor(private readonly svc: SupersetEmbedService) {}

  // AuthMiddleware has ALREADY verified the Cognito Bearer and published
  // res.locals.callerEnterpriseId (the server-derived tenant) — the SAME
  // injection the write controllers fence on. No tenant from the body, ever.
  @Post('guest-token')
  async guestToken(@Res() res: Response) {
    const idEnterprise = res.locals.callerEnterpriseId as number;
    const token = await this.svc.mintGuestToken(idEnterprise);
    res.locals.logData = {
      eventType: 'superset.guest-token.mint',
      payload: { idEnterprise }, lineId: null, enterpriseId: idEnterprise,
    };
    return res.json({ token });
  }
}
```
```ts
// src/usecases/superset-embed/superset-embed.service.ts
@Injectable()
export class SupersetEmbedService {
  private adminToken?: { jwt: string; exp: number };

  async mintGuestToken(idEnterprise: number): Promise<string> {
    if (!Number.isInteger(idEnterprise) || idEnterprise <= 0) {
      throw new UnauthorizedException('No tenant on caller'); // fail closed
    }
    const base = process.env.SUPERSET_BASE_URL;            // http://172.18.0.42:8088 (in-net) or the vhost
    const admin = await this.supersetAdminToken(base!);    // cached /security/login token
    const body = {
      user: { username: `tenant-${idEnterprise}`, first_name: 'embed', last_name: 'viewer' },
      resources: [{ type: 'dashboard', id: process.env.SUPERSET_OEE_DASHBOARD_UUID }],
      rls: [{ clause: `id_enterprise = ${idEnterprise}` }], // int → no injection surface
    };
    const r = await fetch(`${base}/api/v1/security/guest_token/`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${admin}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new UnauthorizedException('Superset guest-token mint failed');
    return (await r.json()).token as string;
  }
  // supersetAdminToken(): POST /api/v1/security/login {username,password,provider:'db'},
  // cache the returned access_token until ~exp; creds from Secrets Manager.
}
```
Env keys (Secrets-Manager-fed into `.env`, NEVER committed):
`SUPERSET_BASE_URL`, `SUPERSET_GUESTTOKEN_ADMIN_USER`,
`SUPERSET_GUESTTOKEN_ADMIN_PASSWORD`, `SUPERSET_OEE_DASHBOARD_UUID`.

> The guest-token admin should be a **custom role with only
> `can_grant_guest_token`**, not full Admin — least privilege. `superset init`
> creates the built-ins; add the scoped role in the real PR.

### 2.3 (B) Authoring — Cognito OIDC as Superset's auth provider

This is the real requirement and the real integration cost. Give each supervisor
a **genuine Superset account** (Explore + SQL Lab on the `bi.*` datasets) so they
can build and save their own charts/dashboards — scoped to their tenant by
Superset RLS bound to their account.

**OIDC config** (in `superset_config.py`, §1.5): `AUTH_TYPE = AUTH_OAUTH`, one
`OAUTH_PROVIDERS` entry for **Cognito** (`server_metadata_url` =
`<issuer>/.well-known/openid-configuration`, `scope: openid email profile`),
`AUTH_USER_REGISTRATION = True`, `AUTH_USER_REGISTRATION_ROLE = "Gamma_BI"`. First
login auto-provisions the account — **no manual account creation**, but note the
**deprovisioning** obligation (§6).

**Role model:**

| Role | Basis | Capability |
|---|---|---|
| `Gamma_BI` | a **cloned Gamma** restricted to the `bi.*` datasets | create/edit charts + dashboards, use Explore + SQL Lab, on `bi.*` ONLY; no admin, no other datasets |
| `tenant_<id>` | per-tenant, carries the RLS filter | binds `id_enterprise = <id>` to the user (the isolation) |
| `Admin` (packiot-bi-admin) | internal ops | full Superset admin; NOT granted to customers |

A supervisor is granted **`[Gamma_BI, tenant_<id>]`**. Gamma gives the *authoring*
capability; `tenant_<id>` gives the *isolation*. Vanilla Gamma is the right base —
it can build content but cannot administer, and (unlike Alpha) cannot add new
database connections or see datasets it wasn't granted.

**Binding `id_enterprise` → RLS (the custom security manager).** Superset has **no
Metabase-style login attribute** that a filter reads directly. So the tenant must
be bound to a Superset **RLS filter** at login. Sketch shipped at
`configs/superset/custom_sso_security_manager.py`
(`CognitoTenantSecurityManager` extends `SupersetSecurityManager`):
- `oauth_user_info()` extracts identity + the tenant claim (`custom:id_enterprise`,
  minted into the Cognito token by a pre-token-generation Lambda; or a
  `tenant-<id>` group convention as fallback).
- After FAB self-registers the user, the manager **ensures a `tenant_<id>` role
  exists carrying an RLS filter `id_enterprise = <id>` on the `bi.*` datasets**,
  and grants the user `[Gamma_BI, tenant_<id>]`.
- **Fail closed:** a login with no tenant claim gets `Public` only (no data).

Because the RLS filter is bound to the user's role, **every** query the author
runs — a new chart, an Explore drag, a SQL Lab query on a `bi.*` dataset — is
rewritten with `id_enterprise = <id>`. That is what makes *authoring* tenant-safe,
the same guarantee the guest token gives *viewing*.

**Two authoring-RLS strategies (pick one):**
- **A — role-per-tenant (default).** One `tenant_<id>` role + filter per tenant,
  auto-managed by the security manager. Zero analytics-DB state. Cost: a role +
  filter per onboarded tenant (role explosion at large tenant counts, but a
  factory-client roster is small — dozens, not thousands — so this is fine).
- **B — one global Jinja filter** (`db/superset/03-authoring-rls-mapping.optional.sql`).
  A single RLS filter `id_enterprise IN (SELECT id_enterprise FROM bi.user_tenant
  WHERE username = '{{ current_username() }}')` serves all tenants; the security
  manager (or edge-api onboarding) upserts `bi.user_tenant`. No role explosion;
  cost is maintaining that mapping table. Superset renders `{{ current_username()
  }}` per query.

Recommend **A** for the client roster size; B is the escape hatch if the role
count ever becomes unwieldy.

> **Honest trade vs Metabase.** Metabase's paid **data sandbox** did all of this
> (per-tenant filter bound to a login attribute) with a single admin setting and
> **no per-user accounts** — the SSO JWT provisioned an ephemeral sandboxed
> session. Superset's free equivalent is **more integration**: real per-user
> Cognito-OIDC accounts, a custom security manager, per-tenant roles/filters, and
> a deprovisioning story. **Per-user Superset accounts are the price of authoring
> for free.** That is the deliberate trade the Metabase-license decision bought.

---

## 3. Multi-tenancy — the two layers

### 3.1 Layer 1 (PRIMARY) — Superset Row Level Security

Native, free, GA. The `id_enterprise` filter is applied on **both** surfaces:
- **Viewing** → the guest-token `rls: [{clause}]` (§2.2). Ephemeral, per-request,
  minted by edge-api from the Cognito identity.
- **Authoring** → a role-bound RLS filter (§2.3). Persistent, per-account, bound
  by the security manager from the Cognito identity.

Same machinery under the hood (`get_sqla_row_level_filters` ANDs both regular and
guest RLS clauses into the query WHERE). Same tenant key (`id_enterprise`, carried
by every `bi.*` view). This is the **primary** enforcement.

### 3.2 Layer 2 (CO-ENFORCER) — Postgres RLS on the `app.tenant_id` GUC

`db/superset/02-tenant-rls.sql` — RLS on **all five base tables** behind the
`bi.*` views, policy `USING (id_enterprise = current_tenant())` (native-id
tables) or an `EXISTS`-join to `equipments` (reached-via-dimension tables), where
`current_tenant()` reads the `app.tenant_id` session GUC. This is a **real
co-enforcer**, not the fail-closed no-op the Metabase donor settled for. Two
design choices make it bite (and the isolation gate in §7 PROVES it does):

1. **The curated views are SECURITY DEFINER, owned by a NOBYPASSRLS `bi_owner`**
   (`db/superset/01`). When `superset_ro` reads `bi.oee_shift`, base-table access
   runs as `bi_owner` — a NOSUPERUSER **NOBYPASSRLS** role — so the base-table
   RLS policies apply. `current_setting('app.tenant_id')` is *session*-scoped, so
   even inside the definer view it reads the value stamped on the connection.
   (Why definer-owned rather than `security_invoker`: it keeps `superset_ro`
   grant-less on the raw base tables — the raw schema stays fully dark — and it
   has no PG-15 dependency.)
2. **The GUC is stamped per tenant on the connection.** Superset opens ONE pooled
   connection per registered "database" and never runs a per-query `SET`, so the
   tenant must ride the connection/role.

| Topology | How the GUC is stamped | Postgres RLS role | Ops cost |
|---|---|---|---|
| **(a) per-tenant Superset DB entry** (recommended for authoring / direct) | `connect_args {"options": "-c app.tenant_id=<id>"}` | **CO-ENFORCER** — Postgres RLS + Superset RLS both bite | one Superset "database"/connection per tenant |
| **(c) per-tenant login role** | `superset_ro_t<id>` with `ALTER ROLE … SET app.tenant_id='<id>'` | **CO-ENFORCER** — GUC rides the role | one role + Superset DB entry per tenant |
| **(b) pooled proxy** | a thin proxy runs `SET app.tenant_id` per checkout | co-enforcer | build/run a proxy |
| **single pooled `superset_ro`, GUC unset** (the embed path) | never stamped → `current_tenant()` NULL → **deny-all** | fail-closed net only; **Superset guest-token RLS is PRIMARY here** | zero |

The single curated embed dashboard is served over the pooled connection, so its
**viewer** isolation is carried by the Superset guest-token clause (§2.2), with
Postgres RLS as the fail-closed net. **Authoring** (and any direct `superset_ro`
client) should use a per-tenant connection/role (a)/(c) so Postgres RLS
co-enforces. The gate (§7) exercises the session-stamp primitive directly and
proves: GUC set → filter to that tenant, GUC unset → zero rows, wrong-tenant
clause → zero rows, tenant-A rows ∩ tenant-B rows = ∅.

> Performance note (TimescaleDB): key RLS on a **native** `id_enterprise` column
> (cheap `= current_tenant()`) over an `EXISTS`-join to `equipments` (can defeat
> chunk exclusion on hypertables). Consider denormalizing `id_enterprise` onto the
> hot rollup tables. Benchmark on staging.

---

## 4. front4 integration

### 4.1 Routes

- **`/reports/view`** — curated dashboards, guest-token embed (viewing). Gated to
  supervisors. THE default `/reports` landing.
- **`/reports/build`** — the authoring entry: a link/redirect into Superset's own
  Explore/SQL-Lab UI via Cognito OIDC (opens Superset in a second embedded route
  or a new tab; the full authoring UI is Superset's, not re-skinned).
- Both **gated to the supervisor population** — render only when the user's
  `id_user_role` (already in `VariablesContext` post-W1) is in the supervisor set.
  Defense-in-depth: edge-api's guest-token endpoint AND the Superset OIDC role
  mapping both refuse non-supervisors.
- **Curated flagship OEE stays native** front4 pages — untouched.

### 4.2 Viewing component — `@superset-ui/embedded-sdk`

```jsx
// src/pages/ReportsView/index.jsx
import React, { useEffect, useRef } from 'react';
import { embedDashboard } from '@superset-ui/embedded-sdk';
import { getAuthToken } from '../../services/authToken';

const EDGE_API   = import.meta.env.VITE_EDGE_API_URL || '';
const SUPERSET   = import.meta.env.VITE_SUPERSET_URL || 'https://superset.prod.packiot.app';
const DASH_UUID  = import.meta.env.VITE_SUPERSET_OEE_DASHBOARD_UUID;

export default function ReportsView() {
  const mount = useRef(null);
  useEffect(() => {
    if (!mount.current) return;
    embedDashboard({
      id: DASH_UUID,                         // the curated dashboard's embed UUID
      supersetDomain: SUPERSET,
      mountPoint: mount.current,
      // edge-api derives the tenant server-side and Superset mints the RLS-scoped
      // guest token. NO Superset secret in the browser.
      fetchGuestToken: async () => {
        const { token: cognito } = await getAuthToken();          // existing Cognito provider
        const res = await fetch(`${EDGE_API}/api/superset/guest-token`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${cognito}` },
        });
        return (await res.json()).token;                          // Superset guest token
      },
      dashboardUiConfig: { hideTitle: true, filters: { expanded: true } },
    });
  }, []);
  return <div ref={mount} style={{ width: '100%', height: '100%' }} />;
}
```
The SDK renders Superset in an iframe it manages and calls `fetchGuestToken` on
load + on token expiry (why the guest token is short-lived + cheap to re-mint).
`@superset-ui/embedded-sdk` is added to front4's `package.json`.

### 4.3 Authoring entry

`/reports/build` is a gated CTA that navigates to
`https://superset.prod.packiot.app/login/cognito` (Superset's OIDC entry). First
visit runs the Cognito OIDC dance → the security manager provisions the scoped,
tenant-bound account (§2.3) → the user lands in Superset's Explore/SQL-Lab. Can be
a new tab, or a second embedded iframe route (same Talisman frame-ancestors CSP
covers it). Because it's the *full authoring UI*, embedding it is optional polish;
a link is the honest MVP.

---

## 5. Data-model exposure — the curated self-service surface

Identical to the Metabase design (the read surface is BI-tool-agnostic). Expose a
small, semantically clean set via the `bi.*` views
(`db/superset/01-superset-ro-role.sql`), NOT the raw ~300-table F3 schema. Every
view carries `id_enterprise` so both isolation layers have a key. Register **only
the `bi` schema** as a Superset database; the raw schema stays dark.

| Superset dataset (`bi.*` view) | Source | Why |
|---|---|---|
| `bi.oee_shift` | `equipment_runtime_shift` | shift-grain OEE — headline self-service aggregate |
| `bi.oee_hourly` | `equipment_runtime_1hour` | hourly trend — workhorse for time-series charts |
| `bi.production_order_runtime` | `production_orders_runtime` | per-PO OEE (native `id_enterprise`) |
| `bi.downtimes` | `downtimes` + `equipments` | downtime analysis by reason/machine |
| `bi.equipments` | `equipments` (active) | dimension for joins/filters |

**Deliberately hidden:** `equipment_values` raw time series (offer a pre-bucketed
`bi.*` rollup on request instead), `packml_register`, `users`, any
`api_key`/secret columns, `shadow_*`/internal signal-quality columns, everything
outside `bi`. `superset_ro` has `SELECT` on `bi` only. Extend the curated set as
customers ask — each addition is one `CREATE OR REPLACE VIEW` carrying
`id_enterprise` + (for authoring) inclusion in the security manager's `BI_DATASETS`
RLS coverage. W3's migrated PowerBI reports map onto this same surface.

---

## 6. Rollout plan, risks, open questions

### 6.1 Ordered steps (staging-first, reversible)

1. **Secrets** — add `SUPERSET_*` keys to Secrets Manager (`packiot/staging/app`
   first): `SUPERSET_SECRET_KEY` (64 hex), `SUPERSET_GUEST_TOKEN_JWT_SECRET`,
   `SUPERSET_DB_PASSWORD`, `SUPERSET_DB_RO_PASSWORD`,
   `SUPERSET_GUESTTOKEN_ADMIN_USER/PASSWORD`, `SUPERSET_COGNITO_CLIENT_ID/SECRET`,
   `SUPERSET_COGNITO_ISSUER`, `SUPERSET_OEE_DASHBOARD_UUID`. Fed into `.env` by
   `app_init.sh` like the existing secrets. **No license key — that's the point.**
2. **Cognito app client** — register a Superset OIDC app client in the shared pool
   (callback `https://superset.<domain>/oauth-authorized/cognito`); decide the
   tenant claim (`custom:id_enterprise` via pre-token-generation Lambda, or a
   `tenant-<id>` group).
3. **Metadata DB** — extend `db-init-bootstrap` with the `superset` role+DB block (§1.2).
4. **Compose** — add `superset-redis`, `superset-init`, `superset`,
   `superset-worker` to `compose.staging.yml`; bring up; confirm `/health` +
   metadata-DB migration completes.
5. **Analytics grants + curated views** — apply `db/superset/01-superset-ro-role.sql`
   (set the real `superset_ro` password). Register the analytics DB in Superset as
   `superset_ro` → `bi` schema only; create the `bi.*` datasets.
6. **Curated dashboard + guest role** — build the curated OEE dashboard, enable
   embedding on it (note its embed UUID), create the scoped
   `can_grant_guest_token` role for the edge-api service admin.
7. **Authoring roles + RLS** — clone Gamma → `Gamma_BI` (restrict to `bi.*`); wire
   `custom_sso_security_manager.py`; verify a Cognito login provisions
   `[Gamma_BI, tenant_<id>]` + the RLS filter.
8. **edge-api endpoint** — land `src/usecases/superset-embed/` (§2.2) + the
   `SUPERSET_*` env. Deploy to staging.
9. **nginx + CloudFront** — add the `superset` vhost (§1.4) + `services`/`service_auth`
   entries + CloudFront alias/origin-verify + Route53 on staging.
10. **front4** — land `ReportsView` (guest-token embed) + `/reports/build` entry +
    the gated nav + `@superset-ui/embedded-sdk` + `VITE_SUPERSET_*`. Deploy (Amplify).
11. **Verify on staging (the acceptance gate)** — two tenants. Confirm supervisor A
    (i) never sees tenant B's rows in the **embedded curated dashboard** (guest RLS)
    AND (ii) never sees tenant B's rows in a **freshly authored** chart / SQL-Lab
    query (role RLS). Both, on both surfaces — that is the real proof.
12. **Postgres RLS backstop** — apply `db/superset/02-tenant-rls.sql`; pick the
    connection topology (§3.2); re-verify (default (c): confirm a GUC-less direct
    `superset_ro` query returns zero rows = fail-closed).
13. **Production** — repeat 1–12 against `packiot/production/*`. Keep every piece
    flag/route-gated so it's dark until the nav item is exposed.

### 6.2 Risks (Superset-specific)

- **★ Biggest — RLS correctness across BOTH paths.** The whole tenancy guarantee
  rests on Superset RLS biting on *two independent surfaces* (guest-token clause
  for viewers; role-bound filter for authors), because the Postgres backstop is
  fail-closed-only under the default pooled connection (§3.2). A gap in **either**
  path = cross-tenant data. The authoring path is the sharper edge: a
  mis-provisioned `tenant_<id>` role, an author who somehow lands with `Alpha`
  (can add datasets / bypass), or a `bi.*` dataset added later but omitted from
  the security manager's RLS coverage, all leak. **Mitigation:** the two-tenant
  acceptance test on BOTH surfaces (step 11) is mandatory and must be re-run
  whenever a `bi.*` dataset or a role is added; keep authoring on **Gamma_BI**
  (never Alpha); consider making the Postgres backstop a **co-enforcer** (topology
  (a)) for authoring connections specifically.
- **Ops weight (Redis + Celery).** 4 always-on containers vs Metabase's 1. Redis
  is now on the critical path for embeds (filter-state cache) and async queries
  (broker/results); a Redis outage degrades Superset. Monitor `superset-redis` +
  the worker's `inspect ping`; size the r7g headroom.
- **OIDC per-user account lifecycle.** Auto-provisioning on first login is easy;
  **deprovisioning is the gap** — a supervisor removed from Cognito still has a
  Superset account (+ any saved private charts) until reaped. Need a
  deactivate-on-Cognito-disable job (or periodic reconcile). Also: a user moving
  tenants must have their `tenant_<id>` role reassigned (the security manager
  re-binds at each login — but stale saved charts referencing old data need
  thought).
- **TimescaleDB hypertable query perf under RLS + ad-hoc.** Self-service authors
  will write unbounded/whole-history queries against hypertable-backed rollups;
  RLS join-predicates can defeat chunk exclusion. Mitigation: native
  `id_enterprise` on hot rollups; row/time limits in `superset_config.py`
  (`ROW_LIMIT`, `SQL_MAX_ROW`); async (Celery) for heavy SQL Lab.
- **Embed session / CSRF / cross-site cookie.** `SESSION_COOKIE_SAMESITE=None`,
  the Talisman `frame-ancestors` CSP, and nginx NOT adding `X-Frame-Options` must
  all line up or the iframe blanks. Safari ITP on cross-site cookies is the usual
  gotcha; test in target browsers. Keep CSRF ON (guest tokens are exempt by
  design; the authoring session is not).
- **Key management.** `SECRET_KEY` (session) and `GUEST_TOKEN_JWT_SECRET` must be
  **stable and identical across web/worker/beat**; a mismatch/rotation invalidates
  sessions + in-flight guest tokens. Manage via Secrets Manager; rotate
  deliberately (guest-token key can rotate independently of `SECRET_KEY`).
- **Two DB connections conflated** — `superset` (metadata, read-write) vs
  `superset_ro` (analytics, SELECT-only). Wiring the analytics source as the
  read-write metadata role would blow past both isolation layers. Keep distinct.

### 6.3 Open questions for the user

1. **★ Biggest — accept the authoring-integration cost of "free."** Superset
   removes the license, but "customers build their own reports" now means
   **per-user Cognito-OIDC Superset accounts + a custom security manager +
   per-tenant RLS roles + a deprovisioning story** — materially more integration
   and ongoing ops than Metabase's single paid sandbox setting. Confirm we accept
   that trade (the alternative is reopening the license decision). Everything below
   assumes yes.
2. **Tenant claim shape** — `custom:id_enterprise` via a Cognito
   pre-token-generation Lambda (clean, explicit) vs a `tenant-<id>` **group**
   convention (no Lambda, but group-name parsing). Recommend the custom claim.
3. **Authoring-RLS strategy** — role-per-tenant (A, default, fine for a small
   client roster) vs one global Jinja filter + `bi.user_tenant` (B, no role
   explosion, mapping-table upkeep). Recommend A.
4. **Postgres RLS topology** — single pooled `superset_ro` (backstop fail-closed;
   zero ops) vs per-tenant connection (co-enforcer). Recommend single + Superset
   RLS primary; revisit for authoring if a stricter DB-level guarantee is wanted.
5. **Curated OEE in Superset too?** Spec keeps flagship OEE native in front4.
   Confirm we do NOT duplicate it as the source of truth (the curated Superset
   dashboard is a *convenience view* for embed, not the canonical OEE surface).

---

## 7. THE isolation gate (automated) — no chart ships until this is green

`tests/superset/` is the **non-negotiable gate**. It is DB-layer ground truth for
tenant isolation, so it needs **no running Superset** — it runs in CI on a bare
Postgres container (`.github/workflows/superset-rls-isolation.yml`, blocking on
PRs to staging). The full end-to-end guest-token mint against a live Superset is
the **staging acceptance step** (§6.1 step 11); this gate is what blocks a merge.

**What it does.** Stands up an ephemeral Postgres, seeds **two** enterprises'
data, applies the **shipped** `db/superset/01` + `02` verbatim (the SQL files ARE
under test), grants `superset_ro` LOGIN (the apply-time Secrets-Manager step),
then — as the NOBYPASSRLS `superset_ro`, reading the curated `bi.*` views —
asserts, with a **net-new raw query against every `bi.*` model**:

| Check | Asserts |
|---|---|
| stamped tenant A | sees ONLY A's rows (`SET app.tenant_id=A` → `{A}`) |
| stamped tenant B | sees ONLY B's rows |
| **unset GUC** | **ZERO rows (fail-closed)** — the property the Metabase no-op lacked |
| stamped A + `WHERE id_enterprise=B` | ZERO rows (the guest-token-clause shape is also blocked) |
| disjoint + partition | `A ∩ B = ∅` and `A ∪ B =` the seeded universe |

**Two structural guards** (auto-discover from the catalog, so a NET-NEW `bi.*`
view can't slip through):
- **every `bi.*` view exposes `id_enterprise`** — no view can omit the tenant key;
- **every base table under a `bi.*` view has RLS enabled + a policy** — the
  "no view without a rule" guard (walks `pg_rewrite`/`pg_depend`).
- plus: `superset_ro`/`bi_owner` are asserted NOSUPERUSER + NOBYPASSRLS.

**Not a false-green:** `SUPERSET_GATE_REQUIRE=1` (set in CI) makes the harness
**fail** rather than skip if docker is unavailable, and the gate runs on every PR
to staging (no path filter) so it can be a required status check without
deadlocking. Run locally: `./tests/superset/run.sh`.

> **Re-run discipline (the ★ risk from §6.2):** the whole tenancy guarantee rests
> on RLS biting on both surfaces. **Re-run this gate whenever a `bi.*` view or a
> Superset role/RLS filter is added** — the structural guards will catch a new
> view that lacks a tenant key or base RLS, but a mis-scoped *Superset* RLS filter
> (authoring role) is only caught by the live 2-tenant acceptance test (§6.1
> step 11). Both must pass before a tenant sees a chart.
```
