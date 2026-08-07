# W2 — Embedded Metabase (self-service BI) — Implementation Spec

Status: DRAFT (2026-08-07). Owner: platform. Scope: **W2 of the front4 program**
(`docs/plans/front4-cognito-cutover-and-bi-migration.md`). This is a **design +
scaffolding** deliverable — nothing here is deployed. It specifies how to embed a
self-hosted, multi-tenant **Metabase** into front4 so factory customers can
**build their own reports** (and view curated ones), with tenancy driven by the
new stack's **Cognito** identity.

> **Decided constraints (honored throughout):**
> - **Metabase**, not Superset. Target tier = **Pro/Enterprise** for
>   **interactive embedding + data sandboxing** (the two paid features that make
>   per-tenant self-service authoring possible).
> - **Curated flagship OEE stays NATIVE in front4** (refdata + charts). Metabase
>   is ONLY the "build your own" self-service surface.
> - Tenancy comes from the **Cognito identity**, enforced in two layers:
>   (a) the SSO embed token edge-api mints carries `id_enterprise`; (b) Postgres
>   **RLS** is a DB-level backstop keyed on `SET app.tenant_id`.
> - **Self-hosted** on the existing stack (Docker Compose now, K8s later). Data
>   source = the **TimescaleDB/Postgres** the stack already runs. New stack is
>   **Cognito** (refdata = read plane, edge-api = write/Cognito-aware plane). **No
>   Firebase, no Hasura** in this design.

Scaffolding shipped alongside this spec:
- `db/metabase/01-metabase-ro-role.sql` — read-only role + curated `bi.*` views.
- `db/metabase/02-tenant-rls.sql` — RLS backstop keyed on `app.tenant_id`.
- `db/metabase/README.md` — the two-isolation-layers explainer.
- (edge-api endpoint + front4 component are **code sketches in this spec** — both
  are separate submodule repos; land them there in their own PRs.)

---

## 0. Architecture at a glance

```
Factory supervisor (browser, front4 SPA)
  │  1. holds a Cognito ID token (VITE_AUTH_COGNITO_ENABLED path, authToken.js)
  │  2. POST /api/metabase/embed-token   Authorization: Bearer <cognito-id-token>
  ▼
edge-api  (NestJS — the Cognito-AWARE write plane; refdata is read-only, cannot mint)
  │  a. verifies the Cognito JWT (existing JwksBearerJwtVerifier / JWKS, RS256)
  │  b. derives id_enterprise SERVER-SIDE (resolveEnterpriseByUid — same as writes)
  │  c. mints a Metabase SSO JWT (HS256, MB_JWT_SHARED_SECRET) with id_enterprise
  │     locked in as a sandbox login-attribute; exp ~2 min
  │  d. returns the metabase /auth/sso URL  (secret NEVER leaves the server)
  ▼
front4 <iframe src="https://metabase.prod.packiot.app/auth/sso?jwt=…&return_to=…">
  ▼
Metabase  (self-hosted container; own app DB for its metadata)
  │  validates the SSO JWT → provisions/loads the user → applies group + sandbox
  │  → sets a Metabase session cookie → renders the interactive-embedding UI
  ▼
TimescaleDB / Postgres  (the analytics DB)
  │  Metabase connects as metabase_ro → reads the curated bi.* views
  │  Layer 1: data SANDBOX rewrites every query: WHERE id_enterprise = {attr}
  │  Layer 2: Postgres RLS backstop (app.tenant_id GUC) — defense in depth
```

Key property: the browser holds **only** its own Cognito token (which it already
has for refdata/edge-api). The Metabase shared secret, the DB credentials, and
the tenant derivation all live server-side in edge-api / the stack. This is the
same "no secret in the browser" posture as back4's PowerBI `/getEmbedToken` and
edge-api's api-key injection at nginx.

---

## 1. Deployment

### 1.1 Metabase's own app DB (metadata) — NOT the analytics DB

Metabase stores its own metadata (users, questions, dashboards, permissions,
sandbox rules) in an application database. This **must be separate** from the
analytics DB — mixing Metabase's mutable metadata into the OEE schema is both a
blast-radius and a backup-lineage mistake. Mirror exactly how **authentik** gets
its own DB in this stack: a dedicated role + database on the same r7g Postgres,
created idempotently by `db-init-bootstrap` (see `compose.production.yml`).

Add to the `db-init-bootstrap` inline command (same shell-guard pattern authentik
uses — `CREATE ROLE`/`CREATE DATABASE` are not `IF NOT EXISTS`):

```sh
echo "== metabase role + database (idempotent) =="
if [ -z "$${METABASE_DB_PASSWORD:-}" ]; then
  echo "METABASE_DB_PASSWORD unset — metabase WILL fail; set it in .env"; exit 1;
fi
if [ "$$(psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='metabase'")" != "1" ]; then
  psql -v ON_ERROR_STOP=1 -c "CREATE ROLE metabase WITH LOGIN PASSWORD '$$METABASE_DB_PASSWORD';";
fi
if [ "$$(psql -tAc "SELECT 1 FROM pg_database WHERE datname='metabase'")" != "1" ]; then
  psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE metabase WITH OWNER = metabase;";
fi
```

> The **analytics** connection Metabase makes (to read `bi.*`) is a *different*,
> read-only role — `metabase_ro` — provisioned by `db/metabase/01-metabase-ro-role.sql`.
> Two connections: `metabase` (owns its app DB, read-write, its own metadata) and
> `metabase_ro` (SELECT-only on the analytics `bi` schema). Do not conflate them.

### 1.2 Compose service

Add to `compose.production.yml` (and `compose.staging.yml`) — mirrors the grafana
service style (env_file, static IP on `packiot-net`, healthcheck, 127.0.0.1 host
publish, json-file logging). `172.18.0.41` is free in the static range (`.2–.40`
used).

```yaml
  # ── Metabase (W2 self-service BI) ────────────────────────────────────────────
  metabase:
    image: metabase/metabase-enterprise:v1.53.x   # Enterprise image = interactive embedding + sandboxing (LICENSE REQUIRED, see §1.4)
    restart: unless-stopped
    env_file: [.env]
    environment:
      # ── App DB (metadata) — the dedicated `metabase` DB on the r7g, via pgbouncer ──
      MB_DB_TYPE: postgres
      MB_DB_HOST: pgbouncer
      MB_DB_PORT: "5432"
      MB_DB_DBNAME: metabase
      MB_DB_USER: metabase
      MB_DB_PASS: ${METABASE_DB_PASSWORD}
      # ── Licensing (interactive embedding + data sandboxing) ──
      MB_PREMIUM_EMBEDDING_TOKEN: ${METABASE_PREMIUM_TOKEN}
      # ── Interactive-embedding SSO (JWT) — the handshake edge-api mints for ──
      MB_JWT_ENABLED: "true"
      MB_JWT_SHARED_SECRET: ${METABASE_JWT_SHARED_SECRET}   # 64 hex chars; edge-api signs with the SAME value
      MB_JWT_ATTRIBUTE_GROUPS: "groups"
      MB_ENABLE_EMBEDDING_INTERACTIVE: "true"
      MB_EMBEDDING_APP_ORIGINS_INTERACTIVE: "https://front.prod.packiot.app"  # CSP frame-ancestors + CORS allow-list
      MB_SESSION_COOKIE_SAMESITE: none    # required: front4 embeds Metabase cross-site in an iframe
      MB_SITE_URL: https://metabase.prod.packiot.app
    ports:
      - "127.0.0.1:3001:3000"     # 3001 on the host (grafana already owns 127.0.0.1:3000); nginx proxies the container IP:3000
    networks:
      packiot-net:
        ipv4_address: 172.18.0.41
    depends_on:
      db-init-bootstrap:
        condition: service_completed_successfully
      pgbouncer:
        condition: service_started
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:3000/api/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 90s          # Metabase migrates its app DB on first boot — generous start_period
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "5"}
```

### 1.3 Host nginx vhost — `metabase.prod.packiot.app`

Mirror the **refdata** vhost pattern in
`terraform/production/user_data/nginx_setup.sh` (codified in #765): a **bespoke**
vhost (NOT the oauth2-proxy csadmin loop — Metabase drives its own JWT-SSO
session, and an oauth2 cookie forward-auth would intercept the iframe). Keep
`origin-verify` (CloudFront-only) + scoped CORS. **One critical difference vs
refdata:** the response must be **iframe-embeddable by front4**, so we do NOT send
`X-Frame-Options`, and Metabase itself emits the `frame-ancestors` CSP from
`MB_EMBEDDING_APP_ORIGINS_INTERACTIVE`.

Add a `services`/`service_auth` pair so the terraform loop skips it (bespoke, like
`api`/`operator`/`csadmin`/`refdata`):

```hcl
# terraform/*/variables.tf — services map
metabase = 3001      # 127.0.0.1 host port (see compose)
# service_auth map
metabase = "bespoke" # emitted as an explicit block below, skipped by the csadmin loop
```

Bespoke vhost block (paste after the refdata block in `nginx_setup.sh`):

```nginx
# ── metabase vhost (W2 self-service BI — embedded in front4) ───────────────────
# metabase.$PRODUCTION_DOMAIN. origin-verify (CloudFront-only) + Metabase's OWN
# JWT-SSO session (NOT oauth2-proxy — cookie forward-auth would break the iframe
# handshake). CORS scoped to the front4 SPA origin. Metabase emits its own
# frame-ancestors CSP (MB_EMBEDDING_APP_ORIGINS_INTERACTIVE) so we do NOT add
# X-Frame-Options here. Proxies the metabase container's static IP 172.18.0.41:3000.
cat > /etc/nginx/conf.d/metabase.conf <<NGINX
map \$http_origin \$metabase_cors {
    default "";
    "~^https://front\.$PRODUCTION_DOMAIN\$" \$http_origin;
}
server {
    listen 80;
    server_name metabase.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name metabase.$PRODUCTION_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;
    location / {
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin  \$metabase_cors always;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
            add_header Access-Control-Allow-Credentials "true" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Vary Origin always;
            return 204;
        }
        add_header Access-Control-Allow-Origin  \$metabase_cors always;
        add_header Access-Control-Allow-Credentials "true" always;
        add_header Vary Origin always;
        proxy_pass         http://172.18.0.41:3000;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$ws_connection;
    }
}
NGINX
```

Plus (in `terraform/production/edge.tf`, the CloudFront layer): a
`metabase.prod.packiot.app` alias/behavior that injects the `X-Origin-Verify`
shared secret, exactly like the other CloudFront-fronted vhosts, and a Route53
record. (Not shown — mirror the existing `refdata`/`operator` edge entries.)

### 1.4 Licensing (call it out loudly)

- **Interactive embedding** (the "log in via your app, full authoring UI in an
  iframe") and **data sandboxing** (per-tenant row filtering by user attribute)
  are **paid** — Metabase **Pro** (cloud) or **Enterprise** (self-hosted, what we
  need). The **Enterprise self-hosted** plan gives a **premium-embedding token**
  (`MB_PREMIUM_EMBEDDING_TOKEN`) that unlocks both.
- The free/OSS image supports only **static embedding** (locked, signed-parameter
  dashboards — NO authoring, NO SSO login, NO sandboxing). Static embedding
  cannot satisfy "customers build their own reports," so **the Enterprise license
  is a hard dependency for W2.** Without it the design falls back to Superset
  (free, heavier ops) — that is the fork the user already resolved toward
  Metabase, so the license purchase is the load-bearing prerequisite (see §6).

---

## 2. Auth / embed model — the token-minting endpoint

### 2.1 Which service owns it — **edge-api**

- **refdata** is the read plane and deliberately **read-only** — it must not hold
  a signing secret nor mint credentials. It cannot own this.
- **edge-api** is already the **Cognito-aware write/control plane**: it has the
  JWKS Bearer verifier (`src/shared/auth/jwks-bearer-jwt-verifier.ts`), the
  tenant derivation (`resolveEnterpriseByUid`), Secrets-Manager-fed env, and the
  vertical-slice module convention. The embed-token endpoint is a natural new
  vertical slice there.

### 2.2 The flow (server-side, no secret in the browser)

1. front4 calls `POST /api/metabase/embed-token` with the caller's existing
   `Authorization: Bearer <cognito-id-token>` (the same token authToken.js
   already attaches to refdata/edge-api).
2. edge-api verifies the Cognito JWT via the **existing** `JwksBearerJwtVerifier`
   (RS256/JWKS, `iss`+`aud`+`exp` enforced, fail-closed).
3. edge-api derives `id_enterprise` **server-side** from the verified `sub` via
   the **existing** `resolveEnterpriseByUid(uid, 'cognito')` — identical to how a
   write is tenant-fenced. The client-asserted tenant is never trusted.
4. edge-api mints a **Metabase SSO JWT** (HS256, signed with
   `METABASE_JWT_SHARED_SECRET` — the SAME value in Metabase's
   `MB_JWT_SHARED_SECRET`), with `id_enterprise` as a custom claim that Metabase
   maps to a sandbox **login attribute**. `exp ~120s` (this JWT is a one-shot SSO
   handoff; the resulting Metabase session cookie has its own, longer lifetime).
5. edge-api returns the `/auth/sso` URL (or just the JWT). The shared secret never
   leaves the server.

### 2.3 JWT claims shape (the Metabase SSO handoff token)

```jsonc
{
  // ── standard Metabase JWT-SSO claims ──
  "email":      "supervisor@acme-factory.com",  // from the Cognito token / users row
  "first_name": "Ana",
  "last_name":  "Silva",
  "groups":     ["factory-supervisor"],          // → Metabase group sync (MB_JWT_ATTRIBUTE_GROUPS)

  // ── custom claim → sandbox login attribute (the tenant lock) ──
  "id_enterprise": 42,                            // server-derived, NEVER client-supplied

  // ── lifetime (short — one-shot handshake) ──
  "iat": 1733600000,
  "exp": 1733600120                               // now + 120s
}
```

Any non-standard claim (here `id_enterprise`) becomes a Metabase **user
attribute** available to the data-sandbox rule. That is the hinge: the sandbox
rule filters `WHERE id_enterprise = {{id_enterprise}}` where `{{id_enterprise}}`
resolves to this claim — so the tenant a supervisor sees is fixed by a
signature-verified value edge-api computed from their Cognito identity, not by
anything the browser can set.

### 2.4 edge-api endpoint sketch (vertical slice — land in the edge-api submodule)

`src/usecases/metabase-embed/` — mirrors the existing slice convention
(controller sets `res.locals.logData`; service holds logic; module wires DI):

```ts
// metabase-embed.controller.ts
import { Controller, Post, Res } from '@nestjs/common';
import { Response } from 'express';
import { MetabaseEmbedService } from './metabase-embed.service';

@Controller('api/metabase')
export class MetabaseEmbedController {
  constructor(private readonly svc: MetabaseEmbedService) {}

  // AuthMiddleware has ALREADY verified the Cognito Bearer for this route and
  // published res.locals.callerEnterpriseId (the server-derived tenant) — the
  // SAME injection the write controllers fence on. We reuse it directly; no
  // tenant ever comes from the request body.
  @Post('embed-token')
  async embedToken(@Res() res: Response) {
    const idEnterprise = res.locals.callerEnterpriseId as number;
    const { ssoUrl, jwt, expiresAt } = await this.svc.mint(res.locals);
    res.locals.logData = {
      eventType: 'metabase.embed-token.mint',
      payload: { idEnterprise, expiresAt },
      lineId: null,
      enterpriseId: idEnterprise,
    };
    return res.json({ ssoUrl, token: jwt, expiresAt });
  }
}
```

```ts
// metabase-embed.service.ts
import { Injectable, UnauthorizedException } from '@nestjs/common';
const jwt = require('jsonwebtoken'); // CJS require — matches login.service.ts convention

@Injectable()
export class MetabaseEmbedService {
  async mint(locals: any) {
    const idEnterprise = locals.callerEnterpriseId as number;
    if (!Number.isInteger(idEnterprise) || idEnterprise <= 0) {
      throw new UnauthorizedException('No tenant on caller'); // fail closed
    }
    const secret = process.env.METABASE_JWT_SHARED_SECRET; // from Secrets Manager via .env
    const site   = process.env.METABASE_SITE_URL;          // https://metabase.prod.packiot.app
    if (!secret || !site) throw new UnauthorizedException('Metabase embed not configured');

    const now = Math.floor(Date.now() / 1000);
    const claims = {
      email:      locals.callerEmail,      // resolved alongside the tenant (users row)
      first_name: locals.callerFirstName ?? '',
      last_name:  locals.callerLastName ?? '',
      groups:     ['factory-supervisor'],  // static for now; later map from id_user_role
      id_enterprise: idEnterprise,         // → Metabase sandbox login-attribute (the tenant lock)
      iat: now,
      exp: now + 120,                      // one-shot SSO handoff
    };
    const token  = jwt.sign(claims, secret, { algorithm: 'HS256' });
    const ssoUrl = `${site}/auth/sso?jwt=${token}&return_to=${encodeURIComponent('/')}`;
    return { jwt: token, ssoUrl, expiresAt: (now + 120) * 1000 };
  }
}
```

> **Small extension needed in the write plane:** the endpoint needs the caller's
> `email`/name for the SSO claims. `resolveEnterpriseByUid` today returns
> `{ idEnterprise, idUserRole }`; extend it (or add a sibling resolver) to also
> surface `email`/`first_name`/`last_name` from the `users` row, published on
> `res.locals`. This is the only new server-side data dependency.

Env keys (Secrets-Manager-fed, into `.env` like the other secrets — NEVER
committed): `METABASE_JWT_SHARED_SECRET` (64 hex), `METABASE_SITE_URL`,
`METABASE_DB_PASSWORD`, `METABASE_PREMIUM_TOKEN`, `METABASE_DB_RO_PASSWORD`.

---

## 3. Multi-tenancy — the two layers

### 3.1 Layer 1 (PRIMARY) — Metabase data sandbox

Configured **in Metabase** (admin, one-time), not in code:
- Create a group `factory-supervisor` (JWT `groups` sync provisions members).
- Add a **login attribute** `id_enterprise`, sourced from the SSO JWT claim.
- For each curated `bi.*` model, add a **sandbox** on that group:
  *"filter rows where `id_enterprise` = `{{id_enterprise}}` (login attribute)."*

Every question/dashboard a sandboxed user builds — including net-new ones — is
transparently rewritten with that predicate. This is what makes **self-service
authoring** tenant-safe.

### 3.2 Layer 2 (BACKSTOP) — Postgres RLS on `app.tenant_id`

`db/metabase/02-tenant-rls.sql` (shipped with this spec). RLS on the analytics
tables, policy `USING (id_enterprise = current_tenant())` where `current_tenant()`
reads the `app.tenant_id` session GUC. Representative policy:

```sql
CREATE OR REPLACE FUNCTION current_tenant() RETURNS int
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::int
$$;

ALTER TABLE production_orders_runtime ENABLE ROW LEVEL SECURITY;
ALTER TABLE production_orders_runtime FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON production_orders_runtime
  USING (id_enterprise = current_tenant());
```

**How the connection sets the GUC** (the load-bearing caveat): RLS only bites if
`app.tenant_id` is set on the connection. Options:

| Topology | How GUC is set | RLS enforcement | Ops cost |
|---|---|---|---|
| **(a) per-tenant Metabase DB entry** | JDBC `?options=-c app.tenant_id=<id>` on each tenant's connection | **full** — RLS + sandbox both enforce | N connections; add one per onboarded tenant |
| **(b) pooled proxy stamps it** | a thin proxy runs `SET app.tenant_id` per session from the sandbox attr | full | build/run a proxy |
| **(c) single shared `metabase_ro`, no GUC** | never set → `current_tenant()` NULL → policy denies all | **backstop only** (fail-closed); **sandbox is the real enforcement** | zero |

Default is **(c)**: one `metabase_ro` connection, sandbox does the per-tenant
work, RLS is a fail-closed safety net (a mis-scoped or sandbox-less query returns
zero rows rather than cross-tenant data). Moving to **(a)** upgrades RLS from
"safety net" to "co-enforcer" at the cost of a connection per tenant. **This
choice is the biggest multi-tenancy decision — see §6.**

> Performance note (TimescaleDB): prefer keying RLS on a **native** `id_enterprise`
> column (cheap `= current_tenant()`) over an `EXISTS`-join to `equipments` (can
> defeat chunk exclusion on hypertables). Consider denormalizing `id_enterprise`
> onto the hot rollup tables. Benchmark on staging before enabling broadly.

---

## 4. front4 integration

### 4.1 Where it lives

- **Route:** `/reports/build` (self-service) — registered in `src/routes.jsx`
  behind `AuthGuard`, alongside the existing `ReportsPowerBI` route it will
  eventually replace (W3).
- **Nav:** a "Reports → Build your own" item, **gated to the supervisor
  population** — render it only when the user's `id_user_role` (already in
  `VariablesContext` after the W1 bootstrap) is in the supervisor/admin set.
  Non-supervisors never see the entry and, defense-in-depth, edge-api's
  embed-token endpoint + the Metabase group both refuse them.
- **Curated OEE is untouched** — it stays the native front4 pages. This route is
  purely the "build your own" surface.

### 4.2 Component sketch (mirrors ReportsPowerBi's mint-token-then-embed shape)

```jsx
// src/pages/ReportsBuild/index.jsx
import React, { useEffect, useState } from 'react';
import Loading from '../../components/Loading';
import { getAuthToken } from '../../services/authToken';

const EDGE_API = import.meta.env.VITE_EDGE_API_URL || '';

export default function ReportsBuild() {
  const [ssoUrl, setSsoUrl] = useState(null);

  useEffect(() => {
    (async () => {
      const { token } = await getAuthToken();               // existing dual-path (Cognito) provider
      const res = await fetch(`${EDGE_API}/api/metabase/embed-token`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}` },       // NO secret in the browser
      });
      const { ssoUrl } = await res.json();                   // edge-api derived the tenant server-side
      setSsoUrl(ssoUrl);
    })();
  }, []);

  if (!ssoUrl) return <Loading />;
  return (
    <iframe
      title="Metabase self-service reports"
      src={ssoUrl}                                            // /auth/sso?jwt=…&return_to=/
      style={{ width: '100%', height: '100%', border: 0 }}
      // Metabase sets frame-ancestors CSP (MB_EMBEDDING_APP_ORIGINS_INTERACTIVE)
      // to allow THIS origin; it also sets the session cookie (SameSite=None).
    />
  );
}
```

Notes:
- The iframe loads Metabase's `/auth/sso?jwt=…` once; Metabase validates the JWT,
  sets its session cookie, and hands the user the full interactive authoring UI.
  On cookie expiry the child re-hits `/auth/sso`; front4 can also re-mint on a
  401 by re-calling `embed-token` (the JWT is cheap and short-lived).
- Because it's cross-site, the Metabase session cookie needs `SameSite=None;
  Secure` (`MB_SESSION_COOKIE_SAMESITE=none`) — set in the compose env above.
- `VITE_EDGE_API_URL` points at `api.prod.packiot.app` (front4 already talks to
  edge-api for writes post-W1).

---

## 5. Data-model exposure — the curated self-service surface

Expose a **small, semantically clean** set via the `bi.*` views
(`db/metabase/01-metabase-ro-role.sql`), NOT the raw ~300-table F3 schema. Every
exposed view carries `id_enterprise` so both isolation layers have a key.

| Exposed (`bi.*` view) | Source | Why |
|---|---|---|
| `bi.oee_shift` | `equipment_runtime_shift` | shift-grain OEE — the headline self-service aggregate |
| `bi.oee_hourly` | `equipment_runtime_1hour` | hourly trend — workhorse for time-series charts |
| `bi.production_order_runtime` | `production_orders_runtime` | per-PO OEE (native `id_enterprise`) |
| `bi.downtimes` | `downtimes` + `equipments` | downtime analysis by reason/machine |
| `bi.equipments` | `equipments` (active) | dimension for joins/filters |

**Deliberately hidden** (do NOT add to `bi`): `equipment_values` raw time series
(too large/high-cardinality for ad-hoc self-service — offer a pre-bucketed `bi.*`
rollup on request instead), `packml_register`, `users`, any `api_key`/secret
columns, `shadow_*`/internal signal-quality columns, and everything outside the
`bi` schema. `metabase_ro` has `SELECT` on `bi` only.

Extend the curated set as customers ask (add a `_1day`/`_1week` rollup, a scrap
view, etc.) — each addition is one `CREATE OR REPLACE VIEW` carrying
`id_enterprise` + a sandbox rule. Later, PowerBI reports migrated in **W3** map
onto this same curated surface (their DAX/Power-Query re-expressed as SQL against
`bi.*`).

---

## 6. Rollout plan, risks, open questions

### 6.1 Ordered steps (staging-first, reversible)

1. **License** — purchase Metabase **Enterprise self-hosted**; obtain the
   premium-embedding token. *(Hard gate — nothing embeddable/sandboxed without
   it.)*
2. **Secrets** — add `METABASE_*` keys to Secrets Manager (`packiot/staging/app`
   first): `METABASE_DB_PASSWORD`, `METABASE_DB_RO_PASSWORD`,
   `METABASE_JWT_SHARED_SECRET` (64 hex), `METABASE_PREMIUM_TOKEN`,
   `METABASE_SITE_URL`. Fed into `.env` by `app_init.sh` like the existing
   secrets.
3. **App DB** — extend `db-init-bootstrap` with the `metabase` role+DB block (§1.1).
4. **Compose** — add the `metabase` service to `compose.staging.yml`; bring it up;
   confirm `/api/health` healthy + app-DB migration completes.
5. **Analytics grants + curated views** — apply `db/metabase/01-metabase-ro-role.sql`
   (set the real `metabase_ro` password). Add the analytics DB in Metabase as
   `metabase_ro` → `bi` schema only.
6. **Sandbox + group** — create the `factory-supervisor` group, the
   `id_enterprise` login attribute, and the per-model sandbox rules (§3.1).
7. **edge-api endpoint** — land `src/usecases/metabase-embed/` (§2.4) +
   `METABASE_JWT_SHARED_SECRET`/`METABASE_SITE_URL` env; extend the tenant
   resolver to surface email/name. Deploy to staging.
8. **nginx + CloudFront** — add the `metabase` vhost (§1.3) + `services`/`service_auth`
   entries + the CloudFront alias/origin-verify + Route53 record on staging.
9. **front4** — land `ReportsBuild` + the gated nav item + `VITE_EDGE_API_URL`;
   deploy to staging (Amplify).
10. **Verify on staging** — two tenants; confirm supervisor A never sees tenant
    B's rows in a **freshly authored** question (proves the sandbox, not just
    curated dashboards). Then decide on the RLS topology (§6.3).
11. **RLS backstop** — apply `db/metabase/02-tenant-rls.sql` on staging; pick the
    connection topology; re-verify.
12. **Production** — repeat 2–11 against `packiot/production/*`, prod compose,
    prod nginx/edge, prod front4. Keep every piece flag/route-gated so it's dark
    until the nav item is exposed.

### 6.2 Risks

- **License cost/tier** — Enterprise self-hosted is priced per-seat/instance;
  confirm the quote and that the plan tier actually includes **interactive
  embedding AND data sandboxing** (both, not just one).
- **RLS on TimescaleDB hypertables** — join-predicate policies can defeat chunk
  exclusion and add per-row subplans on the big rollups. Mitigation: key RLS on a
  **native** `id_enterprise` column (denormalize onto hot rollups); benchmark on
  staging.
- **Embed session lifetime** — the SSO JWT is ~120s (fine), but the Metabase
  **session cookie** lifetime (`MAX_SESSION_AGE`) and the cross-site
  `SameSite=None` cookie must survive front4's iframe; test cookie behavior in
  the target browsers (Safari ITP is the usual gotcha).
- **CSP / iframe** — `MB_EMBEDDING_APP_ORIGINS_INTERACTIVE` must exactly match
  the front4 origin, and nginx must NOT re-add `X-Frame-Options` (would override
  the CSP and blank the iframe).
- **Two DB connections conflated** — `metabase` (app DB, read-write) vs
  `metabase_ro` (analytics, SELECT-only). Wiring the analytics source as the
  read-write role would blow past both isolation layers. Keep them distinct.

### 6.3 Open questions for the user

1. **★ Biggest — confirm the Metabase Enterprise (self-hosted) license
   purchase.** Interactive embedding + data sandboxing are BOTH paid; they are
   the load-bearing dependency of the entire "customers build their own reports,
   multi-tenant" design. Without the license the only self-hosted path that meets
   the requirement is **Superset** (free, heavier ops) — i.e. the license
   decision silently re-opens the Metabase-vs-Superset fork. Everything else in
   this spec assumes the Enterprise token exists.
2. **RLS connection topology** — single shared `metabase_ro` (sandbox is primary,
   RLS fail-closed backstop; zero ops) vs. per-tenant DB connection (RLS
   co-enforces; a connection per onboarded tenant). Recommend starting single +
   sandbox, revisit if a stricter DB-level guarantee is required.
3. **Curated OEE in Metabase too?** The spec keeps flagship OEE native in front4
   (per the decided constraint). Confirm we do NOT also duplicate it into the
   Metabase curated set (avoids two sources of truth for the headline numbers).
```
