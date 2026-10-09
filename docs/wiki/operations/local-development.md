---
title: Local development environment
layer: 4
owner_area: platform
last_verified: 2026-10-09
---
# Local development environment

> **Layer 4 · Operations** — how to run the Packiot stack on your own machine against a realistic,
> anonymized week of CPACK data: one-time setup, the everyday commands, every slice, the live pipeline,
> logging in, rebuilding after a change, the smoke checks CI also runs, and what to do when it breaks.
> For any engineer changing code. Up: [Environments](../architecture/environments.md)

!!! info "Dev is your laptop, not a server"
    "Dev" is a Docker Compose environment (`dev/`, [ADR-0060](../reference/adr-index.md)) that runs only on
    your machine. It never deploys anywhere and never syncs to or from staging at run time. Every host port
    binds `127.0.0.1`; nothing in it talks to AWS or staging, except the dev Cognito pool's public login
    endpoints when you log in to an SPA. Code reaches staging only through a pull request — see
    [Branches, merging and deploying to staging](branches-and-merging.md).

## What you get

```text
            ┌──────────────────────── your machine (Docker, project "packiot-dev") ──────────────────────┐
            │                                                                                           │
  Tier 1    │  seed-replay ── SparkPlug B over MQTT ──┐                                                 │
            │                                         ▼                                                 │
  Tier 2    │                              sparkplug-decoder ── AMQP `oee` ──► stream-engine            │
            │                                         │ resolve-device              │ writes silver/gold  │
  Tier 3    │  edge-api :8080   read-api (:9104 via read-api-cors)   barcode-service :8446               │
            │        │                │                                   │                              │
  Tier 4    │  csadmin :8084  customize :8086  operator :8083  front4 :5173 (your checkout)  grafana :3000 │
            │        │                │                                   │                              │
  Tier 0    │  postgres :5432 (the dev seed)  rabbitmq :5672/:15672  mosquitto :1883  redis :6379  minio │
            └───────────────────────────────────────────────────────────────────────────────────────────┘
```

| Tier | What | Services |
|---|---|---|
| 0 | Data plane, always seeded | `postgres` (the **dev seed**), `rabbitmq` (+ the `oee` topology), `mosquitto`, `redis`, `minio` |
| 1 | Producers | `seed-replay` (replays the seed's own week as "now"), `ingest-shim` (HTTPS ingest → `oee`) |
| 2 | Processors | `sparkplug-decoder`, `stream-engine`, `oeecloud-fanout`, `analytics-sync` (idle, as on staging) |
| 3 | APIs | `edge-api` (+ one-shot `edge-api-migrate`), `read-api` (+ `read-api-cors`), `barcode-service`, `operator-gateway` |
| 4 | UIs / observability | `front4`, `csadmin`, `customize`, `operator`, `grafana` |

`make dev SVC="<service>"` starts that service **and everything it depends on** (its `depends_on`
closure), so you never list the data plane yourself.

## The dev seed (where the data comes from)

The `postgres` service runs the image `ghcr.io/packiot/devseed:latest`: PostgreSQL 15.17 + TimescaleDB 2.27.0
with staging's full schema (`pg_dump --schema-only`) and **7 days of CPACK (tenant 3) data, anonymized**.

| Property | Detail |
|---|---|
| Anonymization | Fail-closed allow-list (`dev/seed/classification.yml`): every text/json/array column of every copied table must be classified `keep`, `pseudonym` (keyed HMAC, deterministic, so joins still work), `scrub` (known sensitive tokens removed inside the string) or `null`, or the build fails (`validate.py`). Numeric, boolean, uuid and time columns are `keep` by type. Names become `Client 0058ac384a`, `Equipment 9341897b70`, …, and a leak gate (`leakgate.py`) re-scans the result. |
| Identities | Generated, not copied (`dev/seed/generators/`): `core.device_bindings` gets **fresh random** `dk_…` keys, and `identity.users` the three synthetic dev users. |
| Time | On first start the loader shifts all timestamps by **whole weeks** so the newest data is 0–7 days old (shift calendars stay aligned). Run `seed-replay` to get data at "now". |
| Credentials in it | Fakes only: `core.enterprises.api_key = dev-api-key-<id>`, `readapi_ro` password `dev`. |
| How it is built | `.github/workflows/dev-seed-build.yml` (extract → anonymize → validate → publish to GHCR). **Weekly, Sunday 05:00 UTC** (plus manual `gh workflow run dev-seed-build.yml`); last verified build **2026-10-09**; each build pushes `:<YYYY-MM-DD>` and `:latest`, and only after its boot test passes (seed loads, sequences past max(id), referential/validity data invariants green). A schema or data change on staging reaches dev at the next build; `docker pull ghcr.io/packiot/devseed:latest` + `make dev-reset` picks it up (compose does not re-pull a tag it already has). |

!!! warning "The seed image is private"
    You must `docker login ghcr.io` with a GitHub token that has `read:packages`, or `make dev` fails pulling
    `ghcr.io/packiot/devseed:latest`. For an empty database instead, set `DEVDB_IMAGE=timescale/timescaledb:2.27.0-pg15
    DEVDB_EXPECT_SEED=0`.

## One-time setup

You need Docker with the Compose plugin (v2) and `make`. Go, Node and Python are **not** needed on the host:
every service builds inside its own Dockerfile.

```bash
git clone --recurse-submodules git@github.com:packiot/packiot-stack-alpha.git
cd packiot-stack-alpha
git checkout staging                      # the integration branch — see branches-and-merging
git submodule update --init --recursive   # edge-api, csadmin, operator, front4, edge-node-red at the pinned SHAs
docker login ghcr.io                       # username = your GitHub user, password = token with read:packages
```

Nothing else: `dev/.env.dev` is **checked in** and holds only fake, dev-only values (database password,
RabbitMQ users, MinIO keys, the internal API key, the dev Cognito pool and client ids — the latter are public, they
ship in every SPA bundle). Override any value for your machine with a shell variable:
`POSTGRES_PASSWORD=x make dev`. Never put a real secret in `.env.dev`.

## Everyday commands

| Command | What it does |
|---|---|
| `make dev` | Tier 0 only (postgres, rabbitmq, mosquitto, redis, minio). Returns when all are **healthy**. |
| `make dev SVC="grafana"` | One slice: the service plus its dependencies. Several: `SVC="edge-api csadmin"`. |
| `make dev-ps` | Status of every dev container. Every published port must read `127.0.0.1:…`. |
| `make dev-smoke SVC="edge-api"` | Health + one real request per named service (the same check CI runs). Exit code = number of failures. |
| `make dev-down` | Stop and remove the containers. **Data volumes are kept.** |
| `make dev-reset [SVC=…]` | Delete the dev volumes and start again from a fresh seed. |
| `docker compose -f dev/compose.yml --env-file dev/.env.dev logs -f <svc>` | Follow one service's logs. |

`make dev` runs `docker compose -f dev/compose.yml --env-file dev/.env.dev up -d --wait …`, so it blocks until every
started service is healthy (one-shots: exited 0) and fails if one does not get there.

!!! warning "`make dev` never rebuilds an image it already has"
    After you change code in a service, rebuild that service explicitly:
    ```bash
    docker compose -f dev/compose.yml --env-file dev/.env.dev up -d --build <svc>
    ```
    The same applies to the SPAs (`csadmin`, `customize`, `operator`), whose Cognito ids are baked in at build time.

## Slices

| You are working on | Start | Open / call |
|---|---|---|
| Grafana dashboards | `make dev SVC="grafana"` | <http://127.0.0.1:3000> (`admin` / `admin`; skip the password change) |
| read-api / datasets | `make dev SVC="read-api-cors"` | `http://127.0.0.1:9104` (CORS proxy in front of read-api) |
| edge-api | `make dev SVC="edge-api"` | `http://127.0.0.1:8080`; runs edge-api's knex migrations first (`edge-api-migrate`) |
| csadmin / customize / operator | `make dev SVC="csadmin customize operator"` | :8084 / :8086 / :8083 (staging images; edge-api + read-api come with them) |
| barcode-service | `make dev SVC="barcode-service"` | `http://127.0.0.1:8446` |
| front4 | `FRONT4_DIR=../front4-staging make dev SVC=front4` | Vite dev server on <http://localhost:5173>, hot reload from **your checkout** |
| The data pipeline | `make dev SVC="seed-replay stream-engine"` | live rows appear in `silver.equipment_values` at "now" |
| ingest-shim | `make dev SVC="ingest-shim"` | `https://127.0.0.1:8444/ingest/sparkplug` (self-signed: `curl -k`; `X-Ingest-Key: dev-ingest-key`) |
| oeecloud-fanout | `make dev SVC="oeecloud-fanout"` (add `seed-replay stream-engine` to fan out real replay traffic) | clones appear in `stream-engine-q-sbxcpack` (RabbitMQ UI <http://127.0.0.1:15672>) |
| operator-gateway | `make dev SVC="operator-gateway"` | `https://127.0.0.1:8445/operator/*` (`X-Ingest-Key: dev-operator-gateway-key`); edge-api comes with it |
| analytics-sync | `make dev SVC="analytics-sync"` | idle: `/healthz` + `/metrics` in-network on :9103 |

**front4** runs from a separate clone because the stack's `front4` submodule pin is not maintained (front4
deploys through AWS Amplify on its own, see [branches-and-merging](branches-and-merging.md#what-each-branch-deploys)):

```bash
git clone -b staging git@github.com:packiot/front4.git ../front4-staging
FRONT4_DIR=../front4-staging make dev SVC=front4                      # front4 + read-api
DEV_FRONT4_EDGE_API=http://localhost:8080 make dev SVC="front4 edge-api"   # also against the local edge-api
```

The first start runs `yarn install` inside the container (about a minute).

### The factory-facing bridges

`ingest-shim` and `operator-gateway` refuse plaintext, as on staging. Dev mints a throwaway self-signed pair on first
use (one-shot `dev-tls`, volume `dev-tls`); nothing is checked in. What dev changes from staging:

| Service | Dev value | Why |
|---|---|---|
| `ingest-shim` | same scope (`INCOPLAST`), routing key `sparkplug.data.incoplast` | nothing binds that key in dev, exactly as on staging, so an accepted message lands in `oee-unroutable-q` (the mechanism behind contracts.md F5) |
| `oeecloud-fanout` | source group = `DEV_SEED_GROUP` (`Client 0058ac384a`) | "CPACK" never appears in the anonymized seed; the pseudonym is a keyed HMAC, so it is stable across seed builds |
| `operator-gateway` | tenant 3, topic prefix `DEV_SEED_GROUP`, edge-api key `dev-api-key-3` | staging's tenant (Incoplast, 4) is not in the seed |
| `analytics-sync` | idle (`SHADOW_MIRROR_ENABLED=false`) | same as staging: its source DB (F1 `packiot`) is retired |

### Calling the APIs without logging in

The seed's fake credentials work against the local APIs only:

```bash
KEY=dev-api-key-3                      # core.enterprises.api_key for tenant 3 in the dev seed
curl -s -H "x-api-key: $KEY" http://127.0.0.1:8080/api/lines | jq length
```

read-api maps the fake read key `dev-read-key-3` to tenant 3 (`QUERY_API_KEYS` in `dev/services/read-api.yml`).

### Logging in to the SPAs

The SPAs use a dedicated **dev Cognito user pool** (`terraform/staging/cognito_dev.tf`). It is a separate issuer: a
dev token is useless against staging or production, and staging tokens are useless here.

| User | Role |
|---|---|
| `dev-admin@example.com` | tenant 3 user **and** member of the `cs-admin` group (edge-api's CS-Admin paths: cross-tenant, onboarding) |
| `dev-engineer@example.com` | tenant 3 user |
| `dev-viewer@example.com` | tenant 3 user |

Passwords are in AWS Secrets Manager (you need AWS access to read them):

```bash
aws secretsmanager get-secret-value --secret-id packiot/dev/cognito --query SecretString --output text
```

## The live pipeline

`make dev SVC="seed-replay stream-engine"` brings up `seed-replay` → `sparkplug-decoder` → `stream-engine`, with
`read-api` as the decoder's device resolver.

- **seed-replay** (`services/sparkplug-decoder/cmd/seed-replay`) publishes, at wall-clock time *T*, the seed's
  silver rows from *T − 7 days* as SparkPlug B. Names are the seed's own registered topics; every metric also
  declares the seed's `device_key`. Counters are cumulative; a field that is NULL in the seed is **never** sent as 0.
- The real decoder and stream-engine compute fresh silver/gold at *T*. Next week's lap replays the rows they wrote,
  so it never runs dry.
- Dev differs from staging on purpose: the decoder publishes to the firehose routing key `sparkplug.data`, and
  stream-engine runs with `LEGACY_INGEST_ENABLED=false` (no per-tenant queues). Customer report jobs are off.

Check that the pipeline reproduces the seed. The check compares the 5 minutes that ended 1 minute ago, so
`seed-replay` must have been running for **at least 7 minutes** — a cached `make dev-reset` plus all slices takes
only about 4, so check first:

```bash
docker inspect -f '{{.State.StartedAt}}' packiot-dev-seed-replay-1   # ≥ 7 minutes ago?
docker exec -i packiot-dev-postgres-1 psql -U postgres -d packiot_analytics -f - < dev/e2e/replay-parity.sql
```

The last line must read `PASS`. It compares, per equipment, gross/net written at "now" with the seed's values one
week earlier, and lists scrap-only divergences for information.

## Smoke checks (what CI runs)

`make dev-smoke SVC="…"` (`dev/e2e/smoke.sh`) checks each named service: health plus one real request that reaches
its data — edge-api `GET /api/lines` with the seed key, read-api with the read key, Grafana a SQL query through its
datasource, the SPAs' nginx proxies, barcode-service's fail-closed 401, fresh silver rows for the pipeline, a message seen on the target routing key for
ingest-shim and oeecloud-fanout (through a temporary tap queue the smoke binds and deletes), and a manual downtime
written through edge-api for operator-gateway.

The same slices run in CI on every pull request into `staging` that touches `dev/`, `db/migrations/`, `services/`,
`customize/`, `grafana/`, the broker configs, a submodule pin or the `Makefile`
(`.github/workflows/dev-slices.yml`):

| CI slice | Starts | Smokes |
|---|---|---|
| `tier0-grafana` | Tier 0 + grafana | postgres rabbitmq mosquitto redis minio grafana |
| `pipeline` | seed-replay stream-engine read-api-cors | + read-api, decoder, stream-engine, live rows |
| `barcode` | barcode-service | postgres barcode-service |
| `ingest` | ingest-shim oeecloud-fanout analytics-sync | rabbitmq ingest-shim oeecloud-fanout analytics-sync |
| `edge` | edge-api csadmin customize operator front4 operator-gateway | + read-api, read-api-cors |

!!! warning "The `edge` slice is skipped until a secret exists"
    It needs the private repos edge-api, csadmin, operator4 and front4, which `GITHUB_TOKEN` cannot read. Until the
    repository secret `DEV_SUBMODULES_TOKEN` (read-only Contents on those four repos) is set, the slice is
    **skipped with a warning and still reports success**. Read the run summary, not just the green tick.
    operator-gateway rides in this slice (it needs edge-api), so it is not CI-proven until the secret exists.

Run the slice for what you changed before you open the PR:

```bash
make dev SVC="edge-api" && make dev-smoke SVC="edge-api"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `postgres` never becomes healthy, or services fail with "relation does not exist" | A dev volume from an earlier run: the entrypoint printed "Skipping initialization" and the seed never loaded (the healthcheck requires seed data) | `make dev-reset` |
| `make dev` fails pulling `ghcr.io/packiot/devseed` | Not logged in to GHCR, or the token lacks `read:packages` | `docker login ghcr.io` |
| `port is already allocated` | Another local Postgres/RabbitMQ/etc. on the same port | Override that port: `DEV_PG_PORT=5433 make dev` (all `DEV_*_PORT` in `dev/.env.dev`) |
| Your code change has no effect | `make dev` reused the old image | `docker compose -f dev/compose.yml --env-file dev/.env.dev up -d --build <svc>` |
| An SPA login works but CS-Admin pages are refused | The user is not in `cs-admin` | Use `dev-admin@example.com` |
| `seed-replay` logs "no active device_bindings with seed values" | `DEVDB_IMAGE` is not the dev seed | Unset `DEVDB_IMAGE` or use the seed |
| A new id collides on insert (`duplicate key … pkey`) | Seed sequences started at 1 (contracts.md F11) | Fixed in the image since 2026-10-09 (and by the `dev/base.yml` backstop hook on a fresh volume): `make dev-reset` |
| Data looks a few days old | Whole-week rebase: the newest seed data is 0–7 days old | Start `seed-replay` for data at "now" |
| `replay-parity.sql` says `FAIL` with almost no equipment matching | `seed-replay` started less than 7 minutes ago: the compared window predates it | Wait until it has run ≥ 7 minutes, then re-run (proven 2026-10-09: 2/34 at 2 min → `PASS` 31/31 at 8 min) |
| Parity lists line 50 as `info (scrap only)` | The seed's own L6 scrap predates the Phase-9 fix (contracts.md F10); gross/net match | Nothing — information only |

## Limits (honest list)

- Not in dev: **edge-session-broker** (it only runs AWS `session-manager-plugin` with an SSM handle edge-api gets
  from AWS; offline there is nothing to bridge, ADR-0060 D3), **legacy-replicator** (reads the legacy production DB),
  **historian-gateway** (feasible with MinIO, not built: the init script needs an S3 endpoint option and dev needs an
  exporter that writes the seed in the cold-archive Parquet layout, which on staging comes from the legacy production
  DB; so read-api `/v1/historian/*` is not testable locally) and **Superset** (optional, heavy, not built).
- analytics-sync runs idle (as on staging): its replay needs the retired F1 `packiot` DB, which the seed does not carry.
- edge-api in dev has no AWS: box operations, SSM, Cognito user administration, Superset and RabbitMQ commands answer
  errors.
- The seed covers CPACK (tenant 3) only, and is only as fresh as its last weekly build (up to 7 days + whole-week rebase).
- Tracing (Tempo/OTEL) and alerting are not part of dev.

## Source map

| Path | What's there |
|---|---|
| `dev/compose.yml`, `dev/base.yml`, `dev/services/*.yml` | the environment: Tier 0 + one fragment per service, each with a contract header |
| `dev/.env.dev` | checked-in fake values and host ports |
| `dev/README.md` | the same material, kept next to the code |
| `dev/e2e/smoke.sh`, `dev/e2e/replay-parity.sql`, `dev/e2e/login-mission-control.py` | smoke checks, pipeline parity, browser login check |
| `dev/seed/` | seed build pipeline: extract, classification, anonymize, validate, generators, `sync-sequences.sql` |
| `services/sparkplug-decoder/cmd/seed-replay/` | the replay producer |
| `Makefile` (`dev`, `dev-ps`, `dev-down`, `dev-reset`, `dev-smoke`) | the commands |
| `.github/workflows/dev-slices.yml`, `.github/workflows/dev-seed-build.yml` | CI slices; seed build |
| `terraform/staging/cognito_dev.tf` | dev Cognito pool, users, `cs-admin` group |
| `docs/adr/0060-local-development-environment-and-cpack-dev-seed.md`, `docs/dev/contracts.md` | design; service contracts and findings |

## Proof

This page was executed end to end on 2026-10-09 from a clean volume (`make dev-reset`), in a fresh checkout of
`staging`: the edge-api slice (`make dev-smoke` 4/4: health, knex 57/57, `/api/lines` with the seed key, 401 without
one; the curl above returned 20 lines), the pipeline, Grafana and the three SPAs (19/19 checks), barcode-service
(3/3), every published port on `127.0.0.1`, and `replay-parity.sql` `PASS` 31/31 after 8 minutes of replay.

The four fragments added later the same day were verified the same way (`make dev-reset`, then `make dev SVC=<svc>` and
`make dev-smoke SVC=<svc>` one at a time): analytics-sync 3/3, ingest-shim 5/5, oeecloud-fanout 3/3, operator-gateway
5/5 (a manual downtime written through edge-api). With `seed-replay` running, oeecloud-fanout cloned the real replay
traffic into `stream-engine-q-sbxcpack`.
