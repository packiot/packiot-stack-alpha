# Superset W2 — STAGING go-live runbook

Status: **staging-first, in progress.** Design spec: `docs/plans/w2-embedded-superset.md`.
Isolation gate: `tests/superset/`. This runbook is the ordered, copy-pasteable
sequence to bring embedded Superset up on **staging** and pass the
**non-negotiable live 2-tenant acceptance test** before any tenant sees a chart.

> **SAFETY — read first.** STAGING only. Do **not** run any of this against
> `packiot/production/*`. **No tenant may be pointed at Superset until the live
> 2-tenant isolation test (§9) passes** — that test is the hard gate, not a nicety.
> Superset RLS is the PRIMARY tenant enforcer on the pooled embed path; the
> Postgres RLS in `db/superset/02-tenant-rls.sql` is a fail-closed co-enforcer.

---

## 0.0 Overlay go-live blocker fixes (this PR)

Four scaffold defects surfaced during the staging live 2-tenant test (which
**passed** — guest-token RLS isolation is proven). They are now fixed durably so
this runbook is executable as-written:

1. **Derived image** — the bare `apache/superset:4.1.1` ships no Postgres driver
   and lacks `flask-cors`/`Authlib`/`flask-talisman`, so it could not boot our
   config. `docker/superset/Dockerfile` adds exactly those four; the overlay's web/
   worker/init services now `build:` it and tag it `packiot/superset:4.1.1-w2`
   (arm64-buildable on the t4g runner). No more manual `pip install` in the container.
2. **Metadata DB is UPSTREAM-DIRECT, not pgbouncer.** pgbouncer routes only
   `packiot`/`packiot_shadow` (no `superset` route, no wildcard). Rather than edit
   the shared base `pgbouncer` service `command:` (out of overlay scope; affects the
   whole stack), the low-traffic Superset metadata DB connects direct to the r7g via
   `POSTGRES_HOST_UPSTREAM` — the same host `superset-db-init` already uses, and the
   safer home for Alembic migrations under transaction-pooling (same rationale as
   hasura-direct). Wired in `superset_config.py` + `compose.superset.yml` env.
3. **`bi.*` views reconciled to the REAL F3 schema** — see §5. OEE cols are
   `oee_a/oee_p/oee_q`; timestamps `ts_value/ts_end`; counts `gross/net`;
   `production_orders_runtime` has no `id_enterprise` (derived via equipments); the
   `downtimes` table does not exist (source is `equipment_events`, a compressed
   hypertable that can't take RLS → isolated transitively via the equipments join).
   Validated ephemerally on staging (all views resolve, every view exposes
   `id_enterprise`, tenant-set → own rows + 0 foreign, tenant-unset → 0; all
   artifacts dropped afterward).
4. **Guest-role grants baked into init** — `superset init` left the guest role
   (`Public`) with zero perms, so `@protect()` 403'd chart-data before RLS ran.
   `superset-init` now runs `configs/superset/bootstrap_guest_role.py` (idempotent):
   grants `can_read` on Chart/Dashboard/Dataset + `can_explore`/`can_explore_json`
   (+ `can_read` on EmbeddedDashboard, best-effort).

---

## 0. What is already done (this PR / prior work)

| Item | State | Evidence |
|---|---|---|
| Scaffold merged (compose overlay, `db/superset/*.sql`, `configs/superset/*`, `tests/superset/`, CI gate) | ✅ on `staging` | PR #773 |
| **DB-layer 2-tenant isolation gate** (`tests/superset/`) | ✅ **GREEN** (7/7) — structural guards + fail-closed + disjoint row-sets | `./tests/superset/run.sh` |
| **`SUPERSET_*` secrets generated + provisioned** into `packiot/staging/app` | ✅ (6 keys, version `950408ec…`) | §1 |
| `app_init.sh` (staging) materializes `SUPERSET_*` + `POSTGRES_HOST_UPSTREAM` into `.env` | ✅ this PR | `terraform/staging/user_data/app_init.sh` |
| `compose.superset.yml` wired into `deploy-staging.yml` (profile-gated, **inert** until `COMPOSE_PROFILES=superset`) | ✅ this PR | `.github/workflows/deploy-staging.yml` |
| `bi.staging.packiot.app` nginx vhost (staging) | ✅ this PR (inert until :8088 up) | `terraform/staging/user_data/nginx_setup.sh` |
| edge-api `superset-embed` guest-token slice | ✅ present + wired in `app.module.ts` | `edge-api/src/usecases/superset-embed/` |

**Remaining is human/product-gated** (see §10 open questions before proceeding):
Cognito OIDC app client, curated dashboard authoring, `bi.*` dataset registration,
the 2 Cognito test users, and the live acceptance test.

---

## 1. Secrets (DONE — reference only)

Six generatable `SUPERSET_*` keys are already in `packiot/staging/app`:
`superset_secret_key`, `superset_guest_token_jwt_secret`, `superset_db_password`,
`superset_db_ro_password`, `superset_guesttoken_admin_user` (`guesttoken-svc`),
`superset_guesttoken_admin_password`.

Four **non-generatable** keys are filled at their step below (they come from
Cognito / the dashboard, not from `openssl`): `superset_cognito_issuer`,
`superset_cognito_client_id`, `superset_cognito_client_secret`,
`superset_oee_dashboard_uuid`. Add each with a read-merge-write (never print values):

```bash
# Template for adding a non-generatable key (run per key, staging only)
SID=packiot/staging/app
CUR=$(aws secretsmanager get-secret-value --secret-id $SID --region us-east-1 \
        --query SecretString --output text)
echo "$CUR" | jq --arg v "$VALUE" '. + {superset_oee_dashboard_uuid: $v}' > /tmp/app.json
aws secretsmanager put-secret-value --secret-id $SID --region us-east-1 \
    --secret-string file:///tmp/app.json && rm -f /tmp/app.json
```

> The guest-token JWT secret and `SECRET_KEY` MUST be identical across
> web/worker/init and stable across restarts (rotating either invalidates sessions
> + in-flight guest tokens). They ride `.env`, shared by all three via `env_file`.

---

## 2. Patch the running staging box's `.env`

The staging `.env` is guarded (not regenerated while it exists), so append the
`SUPERSET_*` keys once on the running box (this is what a fresh `app_init.sh`
re-init would do automatically after this PR). Via SSM on `i-06c9547a2c7091ab7`
(`packiot-staging-app`):

```bash
SEC=$(aws secretsmanager get-secret-value --secret-id packiot/staging/app \
        --region us-east-1 --query SecretString --output text)
{
  echo "POSTGRES_HOST_UPSTREAM=$(grep -E '^POSTGRES_HOST=' /opt/packiot/.env | cut -d= -f2)"
  for k in superset_secret_key superset_guest_token_jwt_secret superset_db_password \
           superset_db_ro_password superset_guesttoken_admin_user \
           superset_guesttoken_admin_password superset_cognito_issuer \
           superset_cognito_client_id superset_cognito_client_secret \
           superset_oee_dashboard_uuid; do
    echo "$(echo "$k" | tr a-z A-Z)=$(echo "$SEC" | jq -r ".$k // \"\"")"
  done
  echo "SUPERSET_FRAME_ANCESTOR=https://front.staging.packiot.app"
  echo "SUPERSET_BASE_URL=http://172.18.0.42:8088"
} >> /opt/packiot/.env
```

Do **not** set `COMPOSE_PROFILES=superset` yet — that is the deliberate activation
switch in §4.

---

## 3. Cognito OIDC app client (authoring surface B — §10 Q1/Q2 first)

Only needed for the **authoring** surface ("build your own report"). The viewing/
guest-token surface does NOT need it. Decide the tenant-claim shape first (§10 Q2).

```bash
# Register a Superset OIDC app client in the shared staging pool.
aws cognito-idp create-user-pool-client --region us-east-1 \
  --user-pool-id us-east-1_0T9t1sTwt \
  --client-name superset-staging \
  --generate-secret \
  --allowed-o-auth-flows code --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --supported-identity-providers COGNITO \
  --callback-urls https://bi.staging.packiot.app/oauth-authorized/cognito \
  --logout-urls https://bi.staging.packiot.app/logout
# → store ClientId → superset_cognito_client_id, ClientSecret → superset_cognito_client_secret,
#   and the issuer https://cognito-idp.us-east-1.amazonaws.com/us-east-1_0T9t1sTwt
#   → superset_cognito_issuer  (all via the §1 read-merge-write; then re-append to .env)
```

Also mint the `custom:id_enterprise` claim (pre-token-generation Lambda) OR adopt
the `tenant-<id>` group convention — this is §10 Q2.

---

## 4. Bring up the `superset` profile

The overlay is now part of the `stack` project (Build/Deploy include
`-f compose.superset.yml`), so it survives `--remove-orphans`. Activate it:

```bash
cd /opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha
# a) enable the profile durably (so pipeline deploys keep it up)
grep -q '^COMPOSE_PROFILES=' /opt/packiot/.env \
  && sed -i 's/^COMPOSE_PROFILES=.*/&,superset/' /opt/packiot/.env \
  || echo 'COMPOSE_PROFILES=superset' >> /opt/packiot/.env
# a2) build the derived image (adds psycopg2 + flask-cors + Authlib + flask-talisman;
#     arm64, ~1-2 min on the t4g runner). `up -d` also builds if missing, but build
#     explicitly so a build error surfaces before the one-shots run.
docker compose -f compose.staging.yml -f compose.superset.yml -p stack build superset
# b) bring the profile up (init one-shots run first, then web+worker)
docker compose -f compose.staging.yml -f compose.superset.yml -p stack up -d
# c) confirm ordering completed
docker logs superset-db-init --tail 20     # "superset-db-init complete."
docker logs superset-init    --tail 40     # db upgrade + init + create-admin +
                                           # "[bootstrap_guest_role] ... granted=..."
docker compose -p stack ps superset superset-worker superset-redis
curl -fsS http://127.0.0.1:8088/health     # → "OK"
```

> **Memory watch:** staging-app is `t4g.large` (7.6 GiB, ~4.5 GiB free at rest)
> and already runs ~30 containers. The overlay adds ~3.3 GiB of `mem_limit`
> (web 2g + worker 1g + redis 320m). Watch `free -h` and `docker stats` on
> first boot; it has 6 GiB swap as a cushion but do not co-run a heavy deploy.

`superset db upgrade` (metadata migrations) + `superset init` (built-in roles) +
the `guesttoken-svc` admin all run inside `superset-init` (a one-shot, `restart:no`).

---

## 5. Analytics grants + curated `bi.*` views (`db/superset/01` + `02`)

Apply the two shipped SQL files against the **analytics** DB (the r7g, direct as
superuser — NOT pgbouncer, NOT the metadata `superset` DB). Both are idempotent.
Inject the real `superset_ro` LOGIN + password from `.env` at apply (the SQL ships
`superset_ro` as NOLOGIN with no literal — the apply is where it gets a password).

```bash
PGH=$(grep -E '^POSTGRES_HOST=' /opt/packiot/.env | cut -d= -f2)
PGU=$(grep -E '^POSTGRES_USER=' /opt/packiot/.env | cut -d= -f2)
PGDB=$(grep -E '^POSTGRES_DB=' /opt/packiot/.env | cut -d= -f2)
export PGPASSWORD=$(grep -E '^POSTGRES_PASSWORD=' /opt/packiot/.env | cut -d= -f2)
RO_PW=$(grep -E '^SUPERSET_DB_RO_PASSWORD=' /opt/packiot/.env | cut -d= -f2)
REPO=/opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha

psql "host=$PGH user=$PGU dbname=$PGDB" -v ON_ERROR_STOP=1 -f "$REPO/db/superset/01-superset-ro-role.sql"
psql "host=$PGH user=$PGU dbname=$PGDB" -v ON_ERROR_STOP=1 -f "$REPO/db/superset/02-tenant-rls.sql"
# grant LOGIN + password (the apply-time Secrets-Manager step the SQL documents)
psql "host=$PGH user=$PGU dbname=$PGDB" -v ON_ERROR_STOP=1 \
  -c "ALTER ROLE superset_ro LOGIN PASSWORD '$RO_PW';"
```

> **Schema reconciliation (this PR).** `01`/`02` were rewritten to the REAL F3
> schema (validated ephemerally on staging, id_enterprise=3). Corrections:
> OEE cols `oee_a/oee_p/oee_q` (not `oee_availability/…`); time bounds
> `ts_value/ts_end` (not `begin_time/end_time`); counts `gross/net` (no `count`);
> `equipment_runtime_1hour` buckets on `ts_value` (no `bucket`);
> `production_orders_runtime` has **no** `id_enterprise` → derived via the
> `equipments` join (id_equipment 100% populated), run window from
> `runtime_timerange` (tstzrange, `lower()/upper()`); the `downtimes` table does
> **not** exist → the downtime source is `equipment_events` (via `bi.downtimes`).
>
> **RLS-locked base tables** are now `equipments`, `equipment_runtime_shift`,
> `equipment_runtime_1hour`, `production_orders_runtime`. **`equipment_events` is
> NOT RLS-locked** — it is a COMPRESSED TimescaleDB hypertable and `ENABLE ROW
> LEVEL SECURITY` errors on columnstore hypertables; its isolation is TRANSITIVE
> (the `bi.downtimes` view joins the RLS-protected `equipments` and exposes
> `eq.id_enterprise`). Note the TimescaleDB perf caveat (the `EXISTS`-join can
> defeat chunk exclusion on the hypertable rollups — see the SQL's PERFORMANCE
> NOTE; denormalize `id_enterprise` onto hot rollups if latency bites). Enabling
> RLS is live-affecting on those shared tables — validate on staging under real
> query load. The ephemeral gate wraps all DDL in a transaction and ROLLBACKs, so
> it does NOT leave RLS on the live tables.

Then register the analytics DB **in Superset** as `superset_ro`, exposing **only
the `bi` schema**, and create datasets for each `bi.*` view (§5 of the spec):
`bi.oee_shift`, `bi.oee_hourly`, `bi.production_order_runtime`, `bi.downtimes`,
`bi.equipments`. For the Postgres co-enforcer to bite on authoring/direct
connections, stamp the tenant on the connection (topology §3.2 (a)/(c)):
`connect_args {"options": "-c app.tenant_id=<id_enterprise>"}`.

---

## 6. Curated dashboard + guest role

1. Build the curated OEE dashboard on the `bi.*` datasets (or import a saved
   export). Enable **embedding** on it → copy the **embed UUID**.
2. Store it: `superset_oee_dashboard_uuid` → Secrets Manager (§1) and re-append to
   `.env` as `SUPERSET_OEE_DASHBOARD_UUID`.
3. Create a scoped role with **only** `can_grant_guest_token` and assign it to the
   `guesttoken-svc` admin (least privilege — replace full Admin from the init
   one-shot). edge-api authenticates as this user to mint guest tokens.

---

## 7. Authoring roles + RLS (surface B — only if §10 Q1 = yes)

Clone `Gamma` → `Gamma_BI`, restricted to the `bi.*` datasets. Wire
`configs/superset/custom_sso_security_manager.py` so a Cognito login provisions
`[Gamma_BI, tenant_<id>]` + an RLS filter `id_enterprise = <id>` on the `bi.*`
datasets. Fail-closed: a login with no tenant claim gets `Public` only.

---

## 8. edge-api + nginx/CloudFront/DNS

```bash
# edge-api: recreate so it picks up SUPERSET_* from .env (the slice reads
# SUPERSET_BASE_URL + SUPERSET_GUESTTOKEN_ADMIN_USER/PASSWORD + SUPERSET_OEE_DASHBOARD_UUID)
docker compose -f compose.staging.yml -f compose.superset.yml -p stack up -d edge-api
```

- **nginx:** re-run `nginx_setup.sh` (or just `nginx -t && nginx -s reload`) so the
  new `bi.staging.packiot.app` vhost loads. It is inert until :8088 answers.
- **cert:** the wildcard `*.staging.packiot.app` ACM/letsencrypt cert already covers
  `bi.staging.packiot.app` — no new cert.
- **CloudFront + DNS:** the staging distribution already aliases `*.staging.packiot.app`
  and injects `X-Origin-Verify`; add/confirm a Route53 record + a `bi.` behavior if
  the wildcard alias doesn't already route it. Verify origin-lock: a request without
  the shared `X-Origin-Verify` header 403s at the origin.
- **front4:** land `ReportsView` (guest-token embed) + `/reports/build` entry +
  `@superset-ui/embedded-sdk` + `VITE_SUPERSET_*` (Amplify). Gate the nav to the
  supervisor role — keep the route dark until §9 passes.

---

## 9. ★ THE live 2-tenant acceptance test — the hard gate

**No tenant sees a chart until this passes on staging.** This is the end-to-end
proof the DB-layer gate (`tests/superset/`, already green) cannot give: that
**Superset RLS** itself bites on both surfaces with real Cognito identities.

Prereqs: two Cognito test users in **different** enterprises (e.g. `id_enterprise`
A and B), Superset up, `bi.*` datasets + curated dashboard live, edge-api redeployed.

**(A) Viewing — guest token, per tenant:**
```bash
# For each test user: get a Cognito ID token, then mint a guest token via edge-api.
# The RLS clause is server-DERIVED from the token (never client-supplied).
curl -s -X POST https://api.staging.packiot.app/api/superset/guest-token \
     -H "Authorization: Bearer $COGNITO_ID_TOKEN_A"   # → { "token": "<guest A>" }
curl -s -X POST https://api.staging.packiot.app/api/superset/guest-token \
     -H "Authorization: Bearer $COGNITO_ID_TOKEN_B"   # → { "token": "<guest B>" }
```
Load the embedded curated dashboard with each guest token. **Assert:** user A never
sees any of B's rows and vice-versa (inspect the rendered data / network payloads).

**(B) Authoring — real accounts:** log each user into Superset via
`https://bi.staging.packiot.app/login/cognito`, then **author a net-new raw
question** (Explore or SQL Lab) against a `bi.*` dataset. **Assert:** the freshly
authored query returns ONLY the author's tenant rows — the role-bound RLS rewrote
`id_enterprise = <id>` into it.

**Acceptance criteria (all must hold):**
1. Guest-token dashboard for A ∩ B row-sets = ∅ (viewing path).
2. Net-new authored question for A ∩ B row-sets = ∅ (authoring path).
3. A direct GUC-less `superset_ro` query returns **zero** rows (Postgres fail-closed):
   `psql "host=$PGH user=superset_ro dbname=$PGDB" -c "SELECT count(*) FROM bi.oee_shift;"` → 0.
4. Re-run the DB gate green: `./tests/superset/run.sh`.

> **Re-run discipline:** re-run BOTH this live test and the DB gate whenever a
> `bi.*` view or a Superset role/RLS filter is added. The structural guards catch a
> new view missing a tenant key / base RLS; only the live test catches a mis-scoped
> Superset RLS filter on the authoring role.

---

## 10. Open questions — resolve BEFORE surfaces B / production (spec §6.3)

1. **★ Accept the authoring-integration cost of "free".** Superset authoring means
   per-user Cognito-OIDC accounts + a custom security manager + per-tenant RLS
   roles + a deprovisioning story (vs Metabase's single paid sandbox setting).
   Confirm before building surface B.
2. **Tenant claim shape** — `custom:id_enterprise` (pre-token Lambda; recommended)
   vs `tenant-<id>` group convention.
3. **Authoring-RLS strategy** — role-per-tenant (A, default) vs global Jinja filter +
   `bi.user_tenant` (B, `db/superset/03-*.optional.sql`).
4. **Postgres RLS topology** — single pooled `superset_ro` (fail-closed backstop) vs
   per-tenant connection/role (co-enforcer). Recommend per-tenant for authoring.
5. **Curated OEE stays native** in front4 (Superset dashboard is a convenience embed,
   not the source of truth) — confirm no duplication.

## 11. Production (do NOT start until staging §9 is green)

Repeat §1–§9 against `packiot/production/*`: provision `SUPERSET_*` into
`packiot/production/app`, mirror the `app_init.sh` + `deploy-production.yml` overlay
wiring (prod's `nginx_setup.sh` already has the `bi.<prod-domain>` vhost), keep
everything route/profile-gated so it is dark until the front4 nav item is exposed.
