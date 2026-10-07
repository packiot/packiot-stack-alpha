# dev/ — local development environment (ADR-0060)

Service slices on top of a shared data plane. Design: [ADR-0060](../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md);
service inputs/outputs: [docs/dev/contracts.md](../docs/dev/contracts.md).

```sh
make dev                    # Tier 0: postgres, rabbitmq, mosquitto, redis, minio
make dev SVC="grafana"      # a slice: grafana + its depends_on closure (postgres)
make dev-ps                 # status (every port must read 127.0.0.1:…)
make dev-down               # stop + remove containers; named volumes are kept
docker compose -f dev/compose.yml --env-file dev/.env.dev down -v   # also wipe data
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

Adding a service: write `services/<svc>.yml` (contract header first, `depends_on` with
`condition: service_healthy` on what it reads), add it to `compose.yml`'s `include:`, give it a
healthcheck. Paths in a fragment resolve relative to the fragment's own directory (`../../`).

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
- Six services export OTLP to `tempo:4317`. Dev has no Tempo, so leave `OTEL_EXPORTER_OTLP_ENDPOINT`
  unset per service (verify each one tolerates that) or add an obs fragment.
- RabbitMQ users are created from definitions on **every** boot, so a new least-privilege user goes
  into both `monitoring/rabbitmq/definitions.template.json` (staging) and the dev template.
