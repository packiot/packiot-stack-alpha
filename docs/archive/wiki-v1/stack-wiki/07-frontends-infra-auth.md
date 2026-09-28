# Frontends, Infrastructure & Auth

The cloud runs as a **single Docker Compose stack per environment** on a small fleet of
ARM64 (Graviton) EC2 boxes, deployed by pushing to a git branch that a **self-hosted
GitHub runner** on the box services. No Kubernetes yet — it's compose-on-EC2 fronted by a
host-level nginx doing TLS, same-origin API proxying, and forward-auth.

## The frontends

| SPA | Purpose | Backend | Auth | Deploy |
|-----|---------|---------|------|--------|
| **front4** | Customer OEE product | refdata-api (reads) + edge-api (writes) | Cognito (Amplify) + legacy Firebase | AWS Amplify → `go.packiot.com` |
| **operator** | Factory-floor kiosk | edge-nodered legacy + edge-api/refdata-api | Cognito via oauth2-proxy (any pool user) | in-stack compose service |
| **csadmin** | Internal CS provisioning | edge-api `/api/*` + refdata-api `/v1/*` | Cognito Bearer (group `cs-admin`) | in-stack image + nginx SPA |

- **front4** — React/MUI, `VITE_*`-driven backend selection (`VITE_REFDATA_API_URL`,
  `VITE_EDGE_API`, Cognito vars). Not a compose service; deployed to Amplify
  (`scripts/amplify-deploy.sh` → `aws amplify start-job`, builds AWS-side, zero Actions
  minutes).
- **operator** — the only frontend built inside the stack; its container nginx
  reverse-proxies APIs same-origin and **injects a server-side `x-api-key`** (the browser
  holds no credential). Submodule `packiot/operator4`.
- **csadmin** — React 19 + Tailwind v4; same-origin nginx proxies `/api/`→edge-api,
  `/v1/`→refdata-api and **forwards the client's Bearer JWT unchanged** (no key injection);
  cross-tenant via `?idEnterprise=` appended by the axios interceptor.

## The deploy pipeline

Deploys = **push to a branch** the box's self-hosted ARM64 runner services, serialized
(`concurrency: cancel-in-progress:false`) so two submodule-bump merges can't race.

- **Staging** (`.github/workflows/deploy-staging.yml`): push to `staging` → checkout →
  `git submodule update --init edge-api edge-node-red operator` → render `.env` from
  Secrets Manager → `docker compose -f compose.staging.yml -p stack build && up -d` →
  a **post-deploy service-state gate** asserts every long-running service is running/healthy.
- **Production** (`deploy-production.yml`): push to `production` (NOT main/master —
  `edge-api/master` is the *legacy Elastic Beanstalk* deploy). Submodules `edge-api` +
  `operator` only. Lighter post-deploy diagnostic.
- **Submodule-pin bump**: `.gitmodules` pins `edge-api`, `edge-node-red`, `operator` on
  `branch=staging`. **csadmin and front4 are neither submodules nor compose services** —
  csadmin ships as its own image built from `Dockerfile.staging`; front4 via Amplify.
  Wait — correction from live practice: on the current stack, **csadmin IS pinned as a
  submodule** and bumped per-deploy (each "chore(deploy): bump csadmin → …" PR). A PR to
  `staging` must pass the required **"Validate compose files"** check (`docker compose
  config -q`).

> Deploying a csadmin change: merge its PR → csadmin `staging` moves → bump the `csadmin`
> gitlink in stack-alpha (`git update-index --cacheinfo 160000,<sha>,csadmin`) → PR to
> stack-alpha `staging` → the check passes → merge → push triggers the deploy.

## AWS infrastructure (us-east-1)

Terraform per-env root modules `terraform/{staging,production}/`, per-concern files
(`ec2.tf`, `database.tf`, `edge.tf`, `cognito.tf`, …). Boxes are all Graviton/ARM64 AL2023:

| Box | Role |
|-----|------|
| **app** (`t4g.medium`) | the whole compose stack + host nginx + self-hosted runner |
| **db** (`t4g.medium`) | PostgreSQL/TimescaleDB (+ Authentik/Superset metadata DBs) |
| **nat** (`t4g.nano`) | fck-nat-style NAT instance (cheaper than a NAT gateway) |
| **superset** (`t4g.large`, prod) | dedicated Apache Superset (memory-heavy, isolated) |
| **runner** (`t4g.medium`, prod) | GitHub Actions self-hosted runner |
| SSM hybrid boxes | the resettable sandbox tenant + the CPACK-replica sandbox (managed via SSM, no SSH) |

- **DNS**: `packiot.app` (AWS zone) with delegated `staging.packiot.app` / `prod.packiot.app`.
  The new stack uses `.packiot.app`; the legacy stack uses `api4.packiot.com`.
- **CloudFront + WAFv2 + ACM** (`edge.tf`): CloudFront fronts the nginx origin; WAF web ACL
  (mode via `waf_managed_rules_mode`; prod canonical = `block`, with `SizeRestrictions_BODY`
  force-counted so the ~23KB onboarding POST isn't rejected). Cutover flipped live 2026-08-05.
- **Origin lock**: CloudFront stamps `X-Origin-Verify` (a random secret); nginx 403s any
  request lacking it, so the box EIP can't be hit directly.

## Auth end-to-end

```
Cognito pool → oauth2-proxy (:4180, OIDC) → nginx auth_request
  /oauth2/auth          → any pool user (operator)
  /oauth2/auth-csadmin  → group cs-admin (admin UIs)
CloudFront fronts all vhosts → X-Origin-Verify 403s non-CloudFront hits
  /api/*  bypasses oauth2 → edge-api AuthMiddleware (Bearer JWT / api-key, fail-closed)
```

- **Cognito** pool `us-east-1_0T9t1sTwt`; custom attr `custom:id_enterprise`; a public SPA
  client for front4/Amplify + a confidential oauth2-proxy client. The `cs-admin` group is
  manually managed, referenced by name in oauth2-proxy + edge-api.
- **Authentik is retired** (oauth2-proxy replaced the embedded outpost); `authentik-*`
  containers linger in compose mid-decommission.

## Operator super-admin: the cross-tenant enterprise switcher

A **super-admin** operates **any** enterprise from a single operator account. The header
shows an enterprise **picker**; selecting a tenant re-scopes the whole session — sidebar,
reads, and writes all follow — without logging out. A normal operator never sees the
picker and is always locked to their own enterprise.

**Who can be a super-admin is exclusive and double-gated.** An account is a super-admin
only when **all three** hold:

1. the live DB flag `user_roles.super_user = true` (re-checked on every request — a
   de-escalated role loses power immediately, never trusted from a token body);
2. membership in an **email allowlist** — env `OPERATOR_SUPERADMIN_ALLOWLIST`, default
   exactly `dev@packiot.com` (comma-separated, case-insensitive);
3. the deployment capability flag `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED = true`.

A stray `super_user=true` on any other account can therefore never escalate. On staging
today the sole super-admin is **`dev@packiot.com`**, whose home is a dedicated internal
enterprise **`PACKIOT-ADMIN` (id 1000000)** — not a client tenant.

!!! note "One flag governs the whole feature, coherently"
    `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` is set on **both** `edge-api` and
    `read-api`. It gates the picker (`super_user` login field), `POST /session/switch`,
    `GET /session/enterprises`, **and** the cross-tenant read + write escalations
    together. Flip it to `false` for instant, total rollback — picker, switch, reads,
    and writes all go dark at once. There is no half-enabled state.

How the three planes honor a switch (each **fail-closed to the home tenant** — a
missing/forged claim is silently denied, never a leak):

| Plane | Path | How it re-scopes |
|-------|------|------------------|
| **Session / picker** | edge-api `/session`, `/session/switch`, `/session/enterprises` | `LoginService.isCrossTenantSuperAdmin` = DB `super_user` **AND** allowlist **AND** flag; a fresh scoped JWT is minted per switch |
| **Reads** | refdata-api `/v1/*` | The SPA tags reads with `?idEnterprise=<target>` + header `x-operator-superadmin-token`; refdata verifies the operator JWT (HS256, `JWT_SECRET`) + live `super_user` + allowlist + target-active, then re-scopes the `$1` tenant. The ADR-0027 single-injection `$1` fence is untouched — this changes *which* tenant is `$1`, never *whether* |
| **Writes** | edge-api `/api/*` | Same header + `?idEnterprise=`; `auth.middleware` honors the target only for a verified super-admin, else locks to the api-key's home enterprise |

**Using it (CS / dev):** log in to the operator as `dev@packiot.com` — the password lives
in **AWS Secrets Manager**:

```bash
aws secretsmanager get-secret-value \
  --secret-id packiot/staging/operator/dev-superadmin-password \
  --query SecretString --output text
```

Then pick a tenant from the header and operate it exactly as its own operator would.
Selecting the current enterprise is a cheap no-op reload. (The box's app instance role
`packiot-staging-app` has `secretsmanager:Create/PutSecretValue` on `packiot/staging/*`, so
the stack stores its own secrets rather than leaving plaintext on disk.)

**Activating a NEW super-admin** is a deliberate two-step change (never accidental): add
the email to `OPERATOR_SUPERADMIN_ALLOWLIST` **and** set `user_roles.super_user=true` for
that operator user. Membership in one without the other confers nothing.

## Observability

- **Grafana** (dashboards/datasources provisioned under `grafana/`) behind the cs-admin
  oauth2 gate; **Loki**+**Promtail** logs, **Tempo** traces (48h), **Alertmanager**.
- **Prometheus** scrapes the app plane's OpenMetrics: `edge-api:8080`, `refdata-api:9104`,
  `oeecloud-worker:9101`, `edge-transformer:9102` (Prometheus keeps the old service names as job labels — see the naming note in 01), exporters (`postgres-exporter`,
  `node-exporter`, `cadvisor`, `blackbox`).
- **Superset** (dedicated prod box, `bi.prod.packiot.app`): apache/superset 4.1.1;
  per-tenant FORCE-RLS; embedded in front4 via guest tokens.
- **Historian** (`historian.tf`): `equipment_values` unloaded SELECT-only into ZSTD
  Parquet on S3, queried via Athena with partition projection (no Glue crawlers —
  cost-avoided). Off GCP for cost. **Staging** (`terraform/staging/historian.tf`) is a
  live ongoing cold store: a daily systemd timer appends yesterday's partitions from
  `packiot_analytics`, with a **180-day (6-month) prune** — see
  [Database → Retention & the historian cold store](06-database.md). **Prod**
  (`terraform/production/historian.tf`) is the legacy `equipment_values` backfill pilot
  (~2.19B rows) with a keep-forever/tiering design (no prune). _Drift note:_ the staging
  bucket/Glue/IAM/lifecycle were first created via CLI to prove the pilot, then imported
  into terraform state; the Athena workgroup + a couple of tags remain a pending
  non-destructive `apply`._

> Caveat: the CloudFront/WAF/oauth2-proxy/X-Origin-Verify edge is authoritative on
> `origin/staging` / `origin/production`; some feature branches still reference Authentik
> and lack `edge.tf`.
