# Production W1 — DB-tier rewire (compose → dedicated r7g) (DESIGN)

**Status:** DESIGN / PLAN ONLY — **do NOT deploy, do NOT terraform apply, do NOT
merge.** Pure config on `feat/prod-w1-6-db-tier-rewire`. Nothing here mutates
production; the change only takes effect on the next re-cut/deploy.
**Date:** 2026-07-28 · **Scope:** `packiot-stack-alpha`, `production` branch / prod
app EC2, single-flow **F3-native** DB.

**Anchors:**
[production-buildout-roadmap §W6/W1](./production-buildout-roadmap.md) (this doc builds
the compose-side of W6's DB split + W1 compose-parity) ·
[production-recut-runbook](./production-recut-runbook.md) (W1 — the compose the app box
brings up) ·
[production-f3-schema-assembly](./production-f3-schema-assembly.md) (W1.4 — schema loaded
INTO the r7g) ·
[production-knex-f3-reconciliation](./production-knex-f3-reconciliation.md) (W1.5) ·
`terraform/production/database.tf` (`aws_instance.db` = the r7g).

---

## 0. TL;DR

The production compose stack no longer runs a **local `postgres` container**. It now
talks to the **dedicated r7g TimescaleDB EC2** (`aws_instance.db`, private subnet,
`10.20.10.89:5432`). `pgbouncer` stays the pooler and is repointed at that IP;
DDL / migration / authentik / adminer connect to the r7g **directly** (transaction
pooling breaks advisory locks + prepared statements + `SET search_path`). The r7g IP
flows from terraform (`aws_instance.db.private_ip`) into the rendered `.env` as
`POSTGRES_HOST_UPSTREAM` — nothing is hardcoded in the committed compose.

## 1. What changed

### `compose.production.yml`
- **Removed** the local `postgres:` service and its `pg-data:` volume. The DB is
  external now.
- **`pgbouncer`**: upstream `DB_HOST: postgres` → `DB_HOST: ${POSTGRES_HOST_UPSTREAM}`.
  Added a **healthcheck** (`pg_isready -h ${POSTGRES_HOST_UPSTREAM}`) so dependents can
  gate on *"external DB reachable"* via `condition: service_healthy` — that gate used
  to be the local postgres's own healthcheck.
- **Added `db-init-bootstrap`** (one-shot). The removed local postgres auto-ran
  `db/docker-entrypoint-initdb.d/` on first boot to create the timescaledb/pg_cron
  extensions and the **`authentik` role + database**. The r7g's user_data does NOT run
  those scripts, so this one-shot re-establishes them against the r7g. It is
  **idempotent** (IF NOT EXISTS + `pg_roles`/`pg_database` shell guards), unlike the raw
  initdb `.sh` scripts (which assume a fresh empty PGDATA and would fail on re-deploy).
  Without it, `authentik-server` crashes: `FATAL: role "authentik" does not exist`.
- **Schema-loaders** (`db-schema-f3`, `db-knex-baseline`, `db-migrate`): host
  `postgres` → `${POSTGRES_HOST_UPSTREAM}` (**direct** to the r7g — DDL + knex advisory
  lock must bypass the pooler). `depends_on: postgres(healthy)` → `pgbouncer(healthy)`
  (+ `db-init-bootstrap` completed for `db-schema-f3`).
- **`hasura` / `adminer`**: `depends_on: postgres(healthy)` → `pgbouncer(healthy)`.
  Adminer's default server → the r7g IP. Hasura keeps its `.env` URL (routes via
  `pgbouncer:5432`).
- **`authentik-server` / `authentik-worker`**: `AUTHENTIK_POSTGRESQL__HOST: postgres`
  → `${POSTGRES_HOST_UPSTREAM}` (direct). authentik-server now depends on
  `db-init-bootstrap` completed (its DB must exist first).
- **App services unchanged**: `edge-api`, `oeecloud-worker`, `refdata-api`,
  `operator-adapter` still use `POSTGRES_HOST=pgbouncer` / `DB_HOST: pgbouncer` — they
  pool. Only pgbouncer's *upstream* moved.

### terraform
- `ec2.tf`: `app_init.sh` templatefile gains `db_private_ip = aws_instance.db.private_ip`
  (single source of truth; makes the app box's init script depend on the DB EC2 — no
  cycle, and the app boots after the DB exists).
- `user_data/app_init.sh`: emits `POSTGRES_HOST_UPSTREAM=<r7g ip>` into `.env`; keeps
  `POSTGRES_HOST=pgbouncer` for app services; DB URL still built via pgbouncer.

### Boot / dependency graph (with local postgres GONE)
```
pgbouncer (healthcheck: pg_isready → r7g)
  └─ db-init-bootstrap (extensions + authentik role/DB)      [one-shot, idempotent]
       └─ db-schema-f3 (F3 public schema)                    [one-shot]
            └─ db-knex-baseline (fake-baseline knex vs F3)   [one-shot]
                 └─ db-migrate (edge-api-only migrations)    [one-shot]
                      └─ edge-api → operator, operator-adapter
hasura → hasura-init (also waits on db-migrate)
authentik-server (waits db-init-bootstrap) → authentik-worker
adminer                                     (waits pgbouncer healthy)
oeecloud-worker (waits rabbitmq + pgbouncer + db-migrate)
```
Every `depends_on` target exists; no service references the removed `postgres`.

## 2. Cutover a RUNNING app box (operational steps)

`app_init.sh` skips `.env` regeneration when `/opt/packiot/.env` exists. A box booted
under an **earlier** `.env` will lack `POSTGRES_HOST_UPSTREAM`, so pgbouncer would still
try to resolve the now-removed `postgres` service. To cut it over:

```bash
# On the app EC2 (SSM session):
#  Option A — full regenerate (also refreshes any other new .env keys):
sudo rm /opt/packiot/.env
sudo bash /opt/packiot/stack/... # re-run app_init (or the deploy re-runs it)

#  Option B — targeted (keeps existing secrets stable):
echo "POSTGRES_HOST_UPSTREAM=10.20.10.89" | sudo tee -a /opt/packiot/.env

# Bring the stack up (postgres service gone; pgbouncer repointed):
cd /opt/packiot/stack
sudo docker compose -f compose.production.yml up -d --wait --remove-orphans
```

### Verify
```bash
# pgbouncer reaches the r7g:
sudo docker compose -f compose.production.yml exec pgbouncer \
  pg_isready -h 10.20.10.89 -p 5432        # → "accepting connections"

# app path pools to the r7g through pgbouncer:
sudo docker compose -f compose.production.yml exec pgbouncer \
  psql "postgresql://postgres:$PW@127.0.0.1:5432/packiot" -tAc 'select 1'

# F3 schema landed on the r7g (not a phantom local container):
bash scripts/prod-f3-schema-parity-check.sh     # F3_MISSING=0
bash scripts/prod-knex-f3-reconcile-check.sh     # CLOBBER=0

# authentik DB/role exist on the r7g:
psql -h 10.20.10.89 -U postgres -tAc \
  "SELECT rolname FROM pg_roles WHERE rolname='authentik'"   # → authentik
```

## 3. Reversibility

Behind the un-happened re-cut. To revert the branch: restore the local `postgres:`
service + `pg-data:` volume, set `pgbouncer.DB_HOST: postgres`, drop
`db-init-bootstrap`, and revert the host/`depends_on` edits (git revert of this branch).
Secrets are untouched — the r7g and pgbouncer both use the existing
`packiot/production/db` password; no new secret.

## 4. Risks / open items

- **`db-init-bootstrap` vs raw initdb scripts (intentional divergence).** The SQL is
  re-authored inline (idempotent) rather than mounting the non-idempotent
  `db/docker-entrypoint-initdb.d/*.sh`. Minor duplication; the alternative breaks on the
  second deploy. If those scripts change, mirror the change here.
- **`pg_cron`.** `db-init-bootstrap` creates it best-effort (`|| skip`). The r7g runs the
  same `timescale/timescaledb:2.25.2-pg16` image the local postgres did, started the same
  way, so behavior is identical — but if `pg_cron` was never actually preloaded, it is
  simply skipped (F3 single-flow does rollups in Go, `RUNTIME_ROLLUP_ENABLED`).
- **pgbouncer health couples to the r7g.** A transient r7g blip marks pgbouncer
  unhealthy (does not restart it — healthcheck status only). This is the *intended*
  gate: don't proceed until the DB is reachable.
