# Production Re-cut Runbook — `production` ← `staging` + prod compose overlay

**Status:** RUNBOOK / DESIGN ONLY — **do NOT execute any step here without USER sign-off.**
Nothing in this file promotes, deploys, force-pushes, or `terraform apply`s. It is the
exact, reviewed procedure to *later* re-cut the `production` branch and stand up the
single-flow F3-native prod compose stack.
**Date:** 2026-07-27 · **Scope:** `packiot-stack-alpha`, `production` branch / prod EC2
`i-02d255a1c21fb1da3`. Legacy EB prod (`edge.api4.packiot.com`) is out of scope.
**Anchors:** [production-buildout-roadmap.md](production-buildout-roadmap.md) (§3.2 re-cut,
§2 secrets, W1), [ADR-0003](../0003-production-deployment-parent-stack.md),
[ADR-0032](../0032-collapse-to-single-flow-f3.md).

---

## 0. Why a re-cut (not a merge / cherry-pick)

`production` is **frozen, ~568 commits behind `staging`**. `staging` is a strict superset:
every prod-specific artifact (`compose.production.yml`, `terraform/production/`,
`.github/workflows/deploy-production.yml`, prod DB init scripts) already lives on `staging`.
So `production` holds nothing `staging` lacks → re-cutting the branch tip is pure gain, zero
loss. Cherry-picking 568 commits is untenable; a merge across a month-old base yields
spurious conflicts. The prod EC2 has an **empty DB and no customer**, so the branch carries
no operational risk to reset.

> This is a **force-update of a protected branch** → USER-gated. It is safe *because* prod
> is greenfield, but it is still deliberate and announced.

---

## 1. Pre-flight safety gate (run, read, STOP)

Everything here is read-only inspection. Do not proceed past this section without USER
go-ahead.

```bash
# 1.1 Fetch the latest of both branches.
git fetch origin staging production

# 1.2 Confirm production carries NO prod-only artifact staging lacks.
#     Expected: EMPTY (or only trivially-behind). If ANY prod-only hotfix shows here
#     that never reached staging, STOP and port it to staging first.
git diff origin/staging origin/production -- \
  terraform/production \
  compose.production.yml \
  .github/workflows/deploy-production.yml \
  db/docker-entrypoint-initdb.d

# 1.3 How far behind is production, and does anything unique live only on it?
git log --oneline origin/production ^origin/staging   # commits ONLY on production → expect none material
git rev-list --count origin/production ^origin/staging # count of prod-only commits

# 1.4 Confirm the prod DB is genuinely empty / no customer (belt-and-suspenders).
#     (SELECT-only, via the awslambda read-only role — see memory: prod DB is read-only.)
#     Expect 0 enterprises / 0 equipment_values on the NEW prod stack DB.
```

**Gate:** proceed only if 1.2 is empty (or reconciled) AND 1.4 confirms empty DB.

---

## 2. Tag the old `production` (rollback anchor) — DO THIS BEFORE THE RESET

```bash
# 2.1 Immutable tag of the current production tip. This IS the rollback target.
git tag -a production-pre-recut-2026-07-27 origin/production \
  -m "production tip before F3-native re-cut (roadmap W1)"
git push origin production-pre-recut-2026-07-27

# 2.2 (optional, extra safety) keep a throwaway branch pointer too.
git branch production-archive-2026-07-27 origin/production
git push origin production-archive-2026-07-27
```

Rollback later = `git push --force origin production-pre-recut-2026-07-27:production`
(see §6).

---

## 3. Re-cut `production` to `staging`

Two ways — **prefer 3A (PR)** for an auditable, reviewable trail; 3B is the raw force-update.

### 3A — PR-based re-cut (preferred)

The compose overlay for single-flow F3-native (this task's `compose.production.yml`) is
**already on `staging`** via the compose-parity PR. So making `production == staging`
brings the overlay along automatically. Open a PR `staging → production`:

```bash
gh pr create --base production --head staging \
  --title "prod re-cut: production ← staging (single-flow F3-native, roadmap W1)" \
  --body "Force-aligns production to staging. Empty prod DB, no customer → no data loss.
Rollback tag: production-pre-recut-2026-07-27. See docs/adr/reference/production-recut-runbook.md."
```

Because `production` is behind and protected, this merge is a fast-forward-or-reset. If the
branch protection blocks a non-linear merge, temporarily relax "require linear history" on
`production` (repo admin), merge, then restore it. The merge event is the audit record.

### 3B — Direct force-update (only if PR path is impractical)

```bash
# Requires the branch-protection allowance for a force push to production (repo admin).
git push --force-with-lease origin origin/staging:production
```

`--force-with-lease` refuses the push if `production` moved since your fetch — a guard
against clobbering a concurrent change.

**After either path:** verify.

```bash
git fetch origin production
git diff origin/staging origin/production --stat   # expect EMPTY (identical trees)
```

---

## 4. Provision secrets (gated — values populated by USER/ops, NOT here)

The prod compose references `packiot/production/*` secrets and several `# FILL AT DEPLOY`
env values written into `/opt/packiot/.env` by `app_init.sh`. **Create the secrets (empty /
placeholder) via `terraform/production/secrets.tf` — this is a separate, reviewed terraform
PR — then populate values out-of-band.** See §7 for the full checklist. Services boot to
`/healthz` without the FILL values but reject real traffic until they are set.

---

## 5. First green dry-run deploy (empty F3 DB, no ingest)

Only after §3 + §4. This is the boot-validation gate — NOT a customer cutover.

```bash
# The self-hosted arm64 runner on the prod EC2 runs, on push to production:
#   docker compose -f compose.production.yml -p packiot-prod build
#   docker compose -f compose.production.yml -p packiot-prod up -d --wait --remove-orphans
# Watch:
docker compose -f compose.production.yml -p packiot-prod ps
docker compose -f compose.production.yml -p packiot-prod logs --since 5m oeecloud-worker edge-transformer refdata-api
```

**Expected steady state:** every service healthy; `oeecloud-worker` + `edge-transformer`
**idle-but-ready** (no client tee live → RabbitMQ queues empty, MQTT silent — this is
correct, not a failure; `MQTT_STALE_THRESHOLD_SECONDS=-1` keeps the healthcheck green).

> ⚠ **Not covered by this runbook (roadmap [LATER], gated separately):** W1.4 assembling the
> **F3 schema as `public`** (db-migrate currently builds the legacy F1 shape — the compute
> chain produces wrong OEE until this is done), W2 ingest front-door + SG rule, W3 front4
> re-point, W6 DB-EC2 split. Do not put a real client on this stack before those land.

---

## 6. Rollback

Because the prod DB is empty and there is no customer, rollback is a branch operation only:

```bash
# Restore production to the pre-recut tip.
git push --force-with-lease origin production-pre-recut-2026-07-27:production
# Redeploy the old tip (runner picks up the push) OR, to just stop the new stack:
docker compose -f compose.production.yml -p packiot-prod down    # keeps named volumes
# Full teardown incl. the empty DB volume (safe — greenfield):
docker compose -f compose.production.yml -p packiot-prod down -v
```

No data-loss consideration applies while the stack is pre-customer. Re-evaluate this rollback
once a client's data is live (then the DB volume is precious → never `down -v`).

---

## 7. Secrets checklist — `packiot/production/*`

**Values are NOT set here — populate out-of-band after `terraform apply` creates the secret
shells (gated).** Scaffold new secrets in `terraform/production/secrets.tf` (roadmap W1.3).

### Already provisioned (present in `terraform/production/secrets.tf`)

| Secret | Consumers | Status |
|--------|-----------|--------|
| `packiot/production/db` | oeecloud-worker, operator-adapter (PG_SECRET_ID) | ✅ exists |
| `packiot/production/hasura` | hasura | ✅ exists |
| `packiot/production/app` | edge-api / app env | ✅ exists |
| `packiot/production/nginx-auth` | nginx basic-auth | ✅ exists |
| `packiot/production/authentik` | authentik server/worker | ✅ exists |
| `packiot/production/github-runner` | self-hosted runner registration | ✅ exists |
| `packiot/production/ec2-rescue` | serial-console rescue | ✅ exists |

### NEW — must be created before the added services boot healthy

| Secret / env | Consumer(s) | Notes | Status |
|--------------|-------------|-------|--------|
| `packiot/production/rabbitmq-oeecloud-creds` | oeecloud-worker (`RABBITMQ_SECRET_ID`) | least-privilege **consumer** on `oee` | ⛔ referenced, NOT provisioned |
| `packiot/production/rabbitmq-edge-transformer-creds` | edge-transformer, ingest-shim (`RABBITMQ_SECRET_ID`) | **publish** perm on the `oee` exchange | ⛔ create |
| `REFDATA_QUERY_API_KEYS` (env; source `packiot/production/refdata-query-keys`) | refdata-api (`QUERY_API_KEYS`) | `"prod-<client>-key:<enterprise_id>"` CSV; maps read key → enterprise SERVER-SIDE | ⛔ create |
| `INGEST_API_KEY` (env; source `packiot/production/ingest-shim` or app) | ingest-shim | `X-Ingest-Key` the client tee presents | ⛔ create (per-client) |
| `INGEST_SCOPE_GROUP` / `INGEST_ROUTING_KEY` (env) | ingest-shim | client topic prefix (e.g. `BISPHARMA`) + per-tenant routing key | ⛔ set (per-client, non-secret config) |
| `OPERATOR_API_KEY` (env; source `packiot/production/operator-adapter`) | operator-adapter | shared secret the client operator tee presents | ⛔ create (only if bespoke operator UI) |
| `OPERATOR_EDGE_API_KEY` (env) | operator-adapter, operator SPA | the **client enterprise `api_key`** edge-api authenticates | ⛔ create (per-client) |
| `OPERATOR_ADAPTER_ENTERPRISE_ID` / `OPERATOR_ADAPTER_TOPIC_PREFIX` (env) | operator-adapter | client enterprise id + topic prefix (non-secret config) | ⛔ set (per-client) |
| `OPERATOR_REFDATA_API_KEY` (env) | operator SPA | the prod-client entry from refdata `QUERY_API_KEYS` (read key) | ⛔ set (per-client) |
| Cognito issuer/client-id (env, PUBLIC — not a secret) | refdata-api | only if a prod Cognito pool is chosen (roadmap W3.2); Firebase-only otherwise | ◻ decision |

### Host-mounted TLS material (NOT Secrets Manager — placed on the EC2 by ops)

| Path (host) | Consumer | Notes |
|-------------|----------|-------|
| `/opt/packiot/ingest-shim/certs/{server.crt,server.key}` | ingest-shim `:8444` | reuse the `*.prod.packiot.app` wildcard cert (already issued) |
| `/opt/packiot/operator-adapter/certs/{tls.crt,tls.key}` | operator-adapter `:8445` | only if the operator-adapter path is used |

---

## 8. What this runbook explicitly does NOT do

- Does **not** execute any step — every command here is copy-run-later under USER sign-off.
- Does **not** force-push `production` or deploy to prod.
- Does **not** create or populate any secret value.
- Does **not** assemble the F3 schema (roadmap W1.4), stand up ingest (W2), re-point front4
  (W3), or split the DB EC2 (W6) — those are separate, gated workstreams.
