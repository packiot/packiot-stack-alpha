# dev/ — local development environment (ADR-0060)

Service slices on top of a shared data plane. Design: [ADR-0060](../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md);
service inputs/outputs: [docs/dev/contracts.md](../docs/dev/contracts.md).

```sh
make dev                    # Tier 0: postgres, rabbitmq, mosquitto, redis, minio
make dev SVC="grafana"      # a slice: grafana + its depends_on closure (postgres)
make dev SVC="front4"       # read-api + CORS proxy + front4 (needs FRONT4_DIR, see "front4" below)
make dev-ps                 # status (every port must read 127.0.0.1:…)
make dev-down               # stop + remove containers; named volumes are kept
docker compose -f dev/compose.yml --env-file dev/.env.dev down -v   # also wipe data
make dev-reset [SVC=...]   # wipe the dev volumes and reload the seed (fixes an empty/stale DB: postgres stays unhealthy)
make dev-smoke SVC="edge-api"   # health + one real request per service (the same check CI runs)
```

`make dev` uses `up -d --wait`, so it returns only when every started service is healthy.
Nothing here talks to AWS or staging. Every host port binds `127.0.0.1`.

## Layout

| File | What |
|---|---|
| `compose.yml` | entry point: `include:` of `base.yml` + every `services/*.yml`; project `packiot-dev` |
| `base.yml` | Tier 0 (data plane) |
| `services/<svc>.yml` | one fragment per service, starting with a contract header (ADR-0060 D1) |
| `.env.dev` | checked in, **fake values only**. Shell env overrides it (`POSTGRES_PASSWORD=x make dev`) |
| `rabbitmq/` | dev definitions template + the script that renders it at boot |
| `minio/entrypoint.sh` | starts MinIO and creates the historian bucket |
| `read-api/cors.conf.template` | CORS proxy config for read-api (dev twin of staging's refdata vhost) |
| `e2e/login-mission-control.py` | browser exit check: dev login → Mission Control with data |
| `e2e/replay-parity.sql` | P3 exit check: replayed gross = the seed's gross one week earlier |
| `e2e/smoke.sh` | per-service smoke (`make dev-smoke SVC=…`), also run by CI (`.github/workflows/dev-slices.yml`) |
| `seed/sync-sequences.sql` | init hook after the seed load: id sequences past the seed's rows (F11) |

Adding a service: write `services/<svc>.yml` (contract header first, `depends_on` with
`condition: service_healthy` on what it reads), add it to `compose.yml`'s `include:`, give it a
healthcheck, add a `smoke` case to `e2e/smoke.sh` and put it in a slice of `.github/workflows/dev-slices.yml`. Paths in a fragment resolve relative to the fragment's own directory (`../../`).

## Tier 0

| Service | Host port | Image | Staging equivalent |
|---|---|---|---|
| postgres | 5432 | `${DEVDB_IMAGE:-timescale/timescaledb:2.27.0-pg15}` | separate EC2, PG 15.17 + TimescaleDB 2.27.0 |
| rabbitmq | 5672, mgmt 15672 | `rabbitmq:3.13-management` (3.13.7) | same image, conf, plugins |
| mosquitto | 1883 | `eclipse-mosquitto:2` | same image + `configs/mosquitto/mosquitto.conf` |
| redis | 6379 | `redis:7-alpine` (alias `app-redis`) | `app-redis`, same flags |
| minio | 9000, console 9001 | `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` | S3 bucket `packiot-staging-historian-<account>` |

**postgres.** The image ships exactly PostgreSQL 15.17 and TimescaleDB 2.27.0 (verified with
`SELECT version()` and `pg_extension`), the same versions as staging. Its init script creates the
`timescaledb` extension in `packiot_analytics`. The DB is empty until P1-B's seed image replaces it
via `DEVDB_IMAGE`. The image is Alpine (musl): its `en_US.utf8` collation sorts like `C`, so text
`ORDER BY` can differ from staging's glibc host. The seed image should take this into account.

**rabbitmq.** `monitoring/rabbitmq/rabbitmq.conf` (shared with staging) sets `load_definitions`.
Staging renders `monitoring/rabbitmq/definitions.template.json` with jq and Secrets Manager
(`deploy-staging.yml`, "Generate RabbitMQ definitions"). Dev renders
`rabbitmq/definitions.dev.template.json` with sed and `.env.dev` (`rabbitmq/render-definitions.sh`,
the container entrypoint). The dev template is staging's template (users `__ADMIN__`, `stream-engine`,
`sparkplug-decoder`; their permissions; policy `oee-ae`; `oee-unroutable` fanout and queue) **plus**
the topology stream-engine declares in code (`services/stream-engine/internal/amqp/topology.go`):

- exchanges `oee`, `oee-retry`, `oee-failed` (topic)
- `stream-engine-q` (`sparkplug.data`), `-retry-30s` (TTL 30000, DLX `oee`, `#` on `oee-retry`), `-failed` (`#` on `oee-failed`)
- per tenant `cpack`, `sbxcpack`, `bispharmastaging` (staging's `WORKER_TENANT_ALLOWLIST`):
  `stream-engine-q-<t>` (DLX `oee-retry`), `-retry-30s`, `-failed`, all bound to `sparkplug.data.<t>`

Queue arguments must equal what the code declares: they are immutable, and a mismatch makes the
service's redeclare fail with 406. This was checked by running stream-engine's real
`DeclareTopology` against the preloaded broker: no error. If you change `topology.go` (or turn on
`WORKER_POOL_SAC_ENABLED`, which adds `x-single-active-consumer`), edit this file to match.

**minio.** Staging's historian bucket is `packiot-staging-historian-<account_id>`
(`terraform/staging/historian.tf`, versioning on; prefixes `equipment_values/`, `equipment_events/`,
`production_orders/`). Services read the name from `HISTORIAN_BUCKET`, so dev creates
`$HISTORIAN_BUCKET` (`packiot-dev-historian`) with versioning on. The container is healthy only
after the bucket exists. Upstream `minio/minio` is gone from Docker Hub (404) and `quay.io/minio` needs
auth, so dev uses the `pgsty` community build of the same server. Override it with `MINIO_IMAGE`.

## Slices

### grafana (`services/grafana.yml`)

Same image (11.5.0), provisioning and dashboards mounts, and env names as staging. Open
<http://127.0.0.1:3000> and log in as `admin` / `admin`. Grafana asks you to change the password,
and you can skip that. 21 dashboards load (folders Audience, Library). They show no data until the
P1-B seed lands.

| Datasource uid | Dev target | State |
|---|---|---|
| `packiot-postgres-shadow` (Packiot Analytics) | `postgres:5432/packiot_analytics` | **works** |
| `packiot-postgres` (default) | `postgres:5432/$POSTGRES_DB` = `packiot_analytics` | works. Staging points it at the retired `packiot` DB (F9) |
| `packiot-prometheus` | `http://prometheus:9090` | provisioned, unreachable (no obs stack in dev) |
| `packiot-loki` | `http://loki:3100` | provisioned, unreachable |
| `packiot-tempo` | `http://tempo:3200` | provisioned, unreachable |

## Notes for later fragments

- **read-api** must carry the network alias `refdata-api` (port 9104). The csadmin/customize/operator
  nginx templates hard-code `refdata-api:9104` (contracts.md §5.5). The alias goes on the read-api
  service's `networks.default.aliases`, the same way redis carries `app-redis` here.
- Six services export OTLP to `tempo:4317`. Dev has no Tempo, so `OTEL_EXPORTER_OTLP_ENDPOINT` stays unset in
  every fragment (decoder, stream-engine, read-api, edge-api verified to run without it).
- RabbitMQ users are created from definitions on **every** boot, so a new least-privilege user goes
  into both `monitoring/rabbitmq/definitions.template.json` (staging) and the dev template.

## Login and the API slices (ADR-0060 P2)
**Dev Cognito pool** (`terraform/staging/cognito_dev.tf`): pool/client ids are in `.env.dev` (public, they ship in
every SPA bundle). Three users exist, matching the seed's synthetic `identity.users` (tenant 3):
`dev-admin@`, `dev-engineer@`, `dev-viewer@example.com`. Passwords:
`aws secretsmanager get-secret-value --secret-id packiot/dev/cognito --query SecretString --output text`.
read-api links `identity.users.id_user_cognito` by e-mail on a user's first request. A dev token is useless
against staging (different issuer).

**read-api** (`services/read-api.yml`): `REFDATA_FLOW=f3`, `readapi_ro` (password `dev`, set by the seed), the dev
pool's `COGNITO_ISSUER`/`COGNITO_CLIENT_ID` (without them every request 401s: the code defaults to the staging pool).
It needs the seed's database `search_path` (carried by the seed since 2026-10-07: read-api's SQL uses unqualified
names). **read-api-cors** answers CORS like staging's host nginx (read-api 401s the browser preflight on its own):
`http://127.0.0.1:9104` → read-api, `Access-Control-Allow-Origin` = `DEV_CORS_ORIGIN` (default the front4 dev server).

**front4** (`services/front4.yml`): Vite dev server on `http://localhost:5173`, hot reload from **your checkout**:
`FRONT4_DIR=../front4-staging make dev SVC=front4` (the submodule pin is stale; clone the branch you work on,
e.g. `git clone -b staging https://github.com/packiot/front4 ../front4-staging`). First start runs `yarn install`
(~1 min). Legacy remote APIs (`dev.api4` / `edge-dev.api4`) are pinned to a closed local port: those calls fail soft
(no enterprise switcher, bundled i18n) until an edge-api slice exists.

**Exit check** (log in, Mission Control shows data): `dev/e2e/login-mission-control.py` (instructions inside).

## The live pipeline (ADR-0060 P3)

```sh
make dev SVC="seed-replay stream-engine"   # replay → decoder → stream-engine (read-api comes via depends_on)
docker compose -f dev/compose.yml --env-file dev/.env.dev up -d --build seed-replay sparkplug-decoder   # after Go edits
```

`make dev` never rebuilds an image it already has: after changing Go code, pass `--build` as above.

| Service | Tier | What it does in dev |
|---|---|---|
| `seed-replay` (`services/seed-replay.yml`) | 1 | At wall-clock T, publishes the seed's silver rows for T − 7 days as SparkPlug B on `spBv1.0/DEV/…/seed-replay` |
| `sparkplug-decoder` (`services/sparkplug-decoder.yml`) | 2 | Decodes, computes increments, publishes envelopes to `oee` with routing key `sparkplug.data` |
| `stream-engine` (`services/stream-engine.yml`) | 2 | Consumes `stream-engine-q`, writes silver/gold at T (events, rollups, PO runtimes, UNS) |

How replay stays faithful (`services/sparkplug-decoder/cmd/seed-replay/main.go`):
- **Names** are the seed's own anonymized `packml_register` topics (registered counter paths verbatim), because
  stream-engine still resolves equipment by topic until ADR-0061 removes it. Every metric also declares the seed's
  `device_key` (random, minted at seed build), so it keeps working when routing moves to declared identity.
- **Counters** are cumulative running sums of the seed's `*_incr`. A field that is NULL in a seed row is not sent,
  and a counter the seed never carries for an equipment is never born. A constant-0 net next to a rising gross reads
  downstream as scrap (found 2026-10-08: 53/54 showed scrap = gross).
- **Laps**: next week, replay reads the rows the pipeline wrote this week, so it never runs dry.

Dev differs from staging on purpose: the decoder publishes to the firehose (`F3_PER_TENANT_ROUTING=false`) and
stream-engine has `LEGACY_INGEST_ENABLED=false`. The per-tenant queues are named after the SparkPlug group and
declared from `packml_register`, and the anonymized tenant name (`Client …`) is not a usable routing key.
Customer report jobs (SHIFT06/SAP13/BOXES13/SYNC06) are off.

**Exit check** (`dev/e2e/replay-parity.sql`): after ≥ 10 min of replay, per equipment, the gross produced at "now"
equals the seed's gross for the same window one week earlier.

```sh
docker exec -i packiot-dev-postgres-1 psql -U postgres -d packiot_analytics -f - < dev/e2e/replay-parity.sql
```

## API + admin slices (ADR-0060 P4)

```sh
make dev SVC="edge-api"                              # API on :8080, runs edge-api's knex migrations first
make dev SVC="csadmin customize operator"            # the three SPAs (edge-api + read-api come via depends_on)
make dev SVC="barcode-service"                       # :8446
```

| Service | Host port | Source | What dev does differently from staging |
|---|---|---|---|
| `edge-api-migrate` (one-shot) | — | `edge-api` submodule, target `migrate` | = staging's `db-migrate`: knex `migrate:latest` on `packiot_analytics`. The seed carries the knex ledger, so only migrations newer than the snapshot run |
| `edge-api` | 8080 | `edge-api` submodule, target `production` | direct to postgres (staging: pgbouncer); dev Cognito pool; no AWS at all (`AWS_EC2_METADATA_DISABLED`, no keys) → box ops / SSM / Cognito user admin answer errors; no Superset, Power BI, RabbitMQ commands |
| `barcode-service` | 8446 | `services/barcode-service` | direct to postgres; dev Cognito pool; Firebase off |
| `csadmin` | 8084 | `csadmin` submodule, `Dockerfile.staging` | dev pool ids baked at build (rebuild with `--build` after changing them) |
| `customize` | 8086 | `customize/` (in-tree), `Dockerfile.staging` | same |
| `operator` | 8083 | `operator` submodule, `Dockerfile.staging` | nginx injects the fake keys `dev-api-key-3` (edge-api) and `dev-read-key-3` (read-api) |

Credentials without a login: the seed sets `core.enterprises.api_key = dev-api-key-<id>`, and read-api maps the read
key `dev-read-key-3` to tenant 3 (`QUERY_API_KEYS`). Both are fakes.

```sh
KEY=dev-api-key-3   # the seed's fake enterprises.api_key for tenant 3
curl -s -H "x-api-key: $KEY" http://127.0.0.1:8080/api/lines | jq length
```

The SPAs are the staging images (nginx, static build): use them to check a whole flow. For UI work, run the SPA's own
dev server against this slice's edge-api. Logging in to csadmin/customize works with the dev users; `dev-admin@example.com` is in the dev pool's `cs-admin`
group (contracts.md F12, fixed 2026-10-09), so it can use the CS-Admin routes (cross-tenant, onboarding). front4 can use the edge-api slice
too: `DEV_FRONT4_EDGE_API=http://localhost:8080 make dev SVC="front4 edge-api"`.

## Smoke checks and CI (ADR-0060 D8)

`make dev-smoke SVC="…"` (`e2e/smoke.sh`) checks each named service: health plus one real request that reaches its
data (edge-api `GET /api/lines` with the seed's key, read-api `/v1/operator-entities` with the read key, Grafana a SQL
query through its datasource, the SPAs' nginx proxies to edge-api/read-api with the dev pool id baked in the bundle,
barcode-service fail-closed 401 + its write-path tables, the pipeline fresh silver rows at "now"). Services with no
host port are probed from inside the compose network. Exit code = number of failed services.

`.github/workflows/dev-slices.yml` runs on every PR into `staging` that touches `dev/`, `db/migrations/`,
`services/`, `customize/`, `grafana/` or a submodule pin. Each slice is one ubuntu-latest runner with a clean
Docker, the published seed and `make dev SVC=… && make dev-smoke SVC=…`:

| Slice | `make dev SVC=` | Smoke |
|---|---|---|
| tier0-grafana | Tier 0 + grafana | postgres rabbitmq mosquitto redis minio grafana |
| pipeline | seed-replay stream-engine read-api-cors | + read-api, decoder, stream-engine, live rows |
| barcode | barcode-service | postgres barcode-service |
| edge | edge-api csadmin customize operator front4 | + read-api, read-api-cors |

The edge slice needs the private repos edge-api, csadmin, operator4 and front4. `GITHUB_TOKEN` reads only this
repository, so it uses the repository secret `DEV_SUBMODULES_TOKEN` (read-only Contents on those four). Without it the
slice is skipped with a warning in the run summary.
