---
title: Compose topology
layer: 3
owner_area: platform
last_verified: 2026-09-28
---
# Compose topology

> **Layer 3 · Components** — every container defined in the Compose files: image, ports,
> dependencies, healthchecks, volumes and host. For anyone deploying, debugging a container
> or adding a service. Up: [Platform & operations](../subsystems/platform.md)

## Responsibility

The Compose files are the single definition of what runs where. `compose.staging.yml` is the
staging app host's entire application stack; overlays and sibling files add Superset, the
historian gateway, on-prem edge boxes and new-stack production. If a container is not in one
of these files (or started by a host script named below), it is drift.

## At a glance

| Item | Value |
|---|---|
| Files | `compose.staging.yml` (3,544 lines), `compose.superset.yml`, `compose.historian-gateway.yml`, `compose.production.yml`, `compose.onprem-edge.yml`, `the dev/ environment (ADR-0060; formerly compose.development.yml)` |
| Staging project name | `stack` (passed as `-p stack` by `deploy-staging.yml`) |
| Staging network | `packiot-net` → Docker name `stack_packiot-net`, bridge `172.18.0.0/24`; dynamic IPs confined to `172.18.0.128/26` |
| Host (staging) | all services in `compose.staging.yml` + overlay run on `packiot-staging-app`; the DB (`timescaledb`) runs on `packiot-staging-db`, outside Compose |
| Port policy | every published port binds `127.0.0.1` except the Alloy relays (`${ALLOY_GATEWAY_BIND}`); nginx on the host terminates TLS |
| Secrets | `${VAR}` substitution and `env_file: .env` → symlink to `/opt/packiot/.env` |
| Validated by | `pr-validation.yml` (`docker compose config --no-interpolate -q`) and the deploy service-state gate |

!!! warning "The file header is stale"
    The comment block at the top of `compose.staging.yml` still lists `hasura` and `oeecloud`.
    Neither exists as a service any more (Hasura retired 2026-08-21 on staging; oeecloud
    Node-RED decommissioned 2026-06-23). Trust the `services:` block, not the header.

## Inputs & outputs

Compose reads: `/opt/packiot/.env` (via `.env`), bind-mounted config under `configs/`,
`monitoring/`, `grafana/`, `docs/clients/` (tenant YAML), host paths under `/opt/packiot/`
(TLS certs, RabbitMQ definitions). It produces containers, named volumes and the
`stack_packiot-net` network that `compose.historian-gateway.yml` joins as `external`.

## Internal design

### Why static IPs and the `ip_range`

Most services pin `ipv4_address` in `.2`–`.51` (plus `.200` for `plc-sim`). Without
`ip_range: 172.18.0.128/26`, a hand-run container could grab a static slot whose owner was
briefly down, and that owner would then fail to start with "Address already in use" (the
hasura-init / gate-red incident). Keep hand-run containers on the network; they get
`.128`–`.191`. The IP allocation table in the file header is the registry; two slots are
reserved and must not be reused without checking consumers (`.6` old oeecloud, `.18` old TS
mirror-worker — `.18` is now cAdvisor).

### Profiles

A service with `profiles:` starts only when its profile is listed in `COMPOSE_PROFILES`
(in `/opt/packiot/.env`). `docker compose config --services` omits inactive profiles, so the
deploy gate ignores them.

| Profile | Services | Purpose |
|---|---|---|
| `superset` | all of `compose.superset.yml` | embedded BI (bi.staging) |
| `cpack-tee` | `sparkplug-agent-cpack` | CPACK Mode-A agent (ADR-0042 P1) |
| `shared-tee` | `sparkplug-agent-shared` | multi-tenant agent behind `ingest.staging` |
| `alerting` | `alertmanager` | Slack routing, parked until a webhook exists |
| `plc-sim` | `plc-sim` | synthetic Sparkplug PLC |
| `s7` | `s7-softplc`, `s7-reader` | S7 soft-PLC test pair |
| `legacy-sim` | `edge-nodered`, `simulator` | retired Node-RED path |
| `legacy-comparator` | `mirror-worker-go` | retired prod→staging mirror |

!!! warning "Unverified: which profiles are on"
    The active list lives only in `/opt/packiot/.env` on the host. Incidents in September 2026
    show Superset, `sparkplug-agent-shared` (Bispharma) and `sparkplug-agent-cpack` running on
    staging. Check with `grep COMPOSE_PROFILES /opt/packiot/.env` before relying on it.

### Services in `compose.staging.yml`

Legend: **Ports** = host binding (all `127.0.0.1` unless noted) → container port; internal
ports are metrics/health ports reachable only on `stack_packiot-net`. **HC** = healthcheck.
**Name** = container name (`stack-<svc>-1` when not pinned). All run on the staging app host.

#### Messaging and edge ingress

| Service | Image / build | Ports | Depends on | HC | Volumes | Notes |
|---|---|---|---|---|---|---|
| `rabbitmq` (`stack-rabbitmq-1`) | `rabbitmq:3.13-management` | 5672, 15672 | — | `rabbitmq-diagnostics ping` | `rabbitmq-data`, `monitoring/rabbitmq/{enabled_plugins,rabbitmq.conf}`, `/opt/packiot/rabbitmq/definitions.json` | `load_definitions` re-imports users on every boot; plugins: management, prometheus (:15692) |
| `mosquitto` (`stack-mosquitto-1`) | `eclipse-mosquitto:2` | 1883 | — | `mosquitto_pub` ping | `configs/mosquitto/mosquitto.conf`, `mosquitto-data` | retained NBIRTHs survive restart (ADR-0011) |
| `sparkplug-decoder` | build `services/sparkplug-decoder` | internal 9102 (metrics), 9105 (onboard API) | rabbitmq ✓healthy, mosquitto ✓healthy | `--healthcheck` | `docs/clients/cpack.yaml`, `edge_transformer_outbox` | alias `edge-transformer`; writes Postgres directly at `10.10.10.89` (not pgbouncer); SQLite outbox cap 100,000 |
| `sparkplug-agent-cpack` | build `services/sparkplug-decoder` | internal 9103 health, 9104 ingest | mosquitto ✓healthy | `sparkplug-agent --healthcheck` | `docs/clients/cpack-agent.yaml`, `edge_transformer_agent_outbox` | profile `cpack-tee`; nginx `cpack-ingest.staging:8447` → 9104; 128 MB, 0.25 CPU |
| `sparkplug-agent-shared` | build `services/sparkplug-decoder` | internal 9103, 9104 | mosquitto ✓healthy | `sparkplug-agent --healthcheck` | `docs/clients/tenants`, `docs/clients/tenant-profiles`, `edge_transformer_agent_outbox` | profile `shared-tee`; nginx `ingest.staging:8449` → 9104; routes by envelope group_id; 192 MB |
| `ingest-shim` | build `services/ingest-shim` | 8444 → 8444; internal 9105 | rabbitmq ✓healthy | `--healthcheck` | `/opt/packiot/ingest-shim/certs` | HTTPS → RabbitMQ for Incoplast (`sparkplug.data.incoplast`) |
| `oeecloud-fanout` | build `services/oeecloud-fanout` | internal 9102 | rabbitmq ✓healthy | `--healthcheck` | — | copies CPACK traffic to the sandbox group SBXCPACK; flag `FANOUT_CPACK_TO_SBXCPACK_ENABLED` |
| `bispharma-twin` | build `services/sparkplug-decoder` | — | mosquitto ✓healthy | none | `docs/clients/tenants`, `bispharma-twin-state` | synthetic BISPHARMASTAGING producer; off unless `BISPHARMA_TWIN_ENABLED=true` |
| `plc-sim` | build `services/sparkplug-decoder` | — | mosquitto ✓healthy | none | — | profile `plc-sim`; IP `.200` |
| `s7-softplc`, `s7-reader` | build `services/sparkplug-decoder` | — | reader → mosquitto ✓, softplc started | none | — | profile `s7` |

#### Compute and data access

| Service | Image / build | Ports | Depends on | HC | Volumes | Notes |
|---|---|---|---|---|---|---|
| `stream-engine` | build `services/stream-engine` | internal 9101 | rabbitmq ✓healthy, pgbouncer, db-migrate ✓completed | `--healthcheck` | — | alias `oeecloud-worker` (Prometheus job still uses it); DB `10.10.10.89` direct; 256 MB, 0.5 CPU |
| `pgbouncer` (`stack-pgbouncer-1`) | `edoburu/pgbouncer:1.22.1-p0` | — (5432 on the network) | — | none | — | transaction pooling, pool 20, max clients 200, query timeout 60 s; adds a `packiot_analytics` entry at start |
| `db-migrate` (`stack-db-migrate-1`) | build `./edge-api` | — | — | none | — | one-shot (`restart: "no"`); edge-api DB migrations against `packiot_analytics` |
| `app-redis` | `redis:7-alpine` | — | — | `redis-cli ping` | — | 256 MB LRU cache, no persistence; db 0 = app cache, db 1 = oauth2-proxy sessions |

#### Legacy bridge

| Service | Image / build | Ports | Depends on | HC | Notes |
|---|---|---|---|---|---|
| `legacy-replicator` | build `services/analytics-sync` (`Dockerfile.replicator`) | internal 9104 | — | `legacy-replicator --healthcheck` | legacy ent 1 → analytics ent 3; PO reconcile every 300 s |
| `legacy-replicator-sbx` | same | internal 9114 | — | same | legacy ent 1 → sandbox 2000003; off unless `REPLICATE_SBX_ENABLED=true` |
| `analytics-sync` | build `services/analytics-sync` | internal 9103 | — | `analytics-sync --healthcheck` | alias `shadow-mirror`; `SHADOW_MIRROR_ENABLED=false` |
| `mirror-worker-go` | build `services/mirror-worker-go` | internal 9102 | pgbouncer, edge-api | `--healthcheck` | profile `legacy-comparator` (retired) |

#### Serving (APIs)

| Service | Image / build | Ports | Depends on | HC | Notes |
|---|---|---|---|---|---|
| `edge-api` (`stack-edge-api-1`) | build `./edge-api` (submodule) | 8080 → 8080 | db-migrate ✓completed, pgbouncer, edge-session-broker | `wget /health` | vhost `api.staging`; writes + CS Admin + Box Ops (SSM) |
| `edge-session-broker` | build `services/edge-session-broker` | internal 8090 (ws), 8091 (http) | — | TCP connect 8090 | browser-native SSM sessions (ADR-0057) |
| `read-api` | build `services/read-api` | internal 9104 | app-redis | `--healthcheck` | alias `refdata-api`; vhost `refdata.staging`; also reads the historian gateway |
| `operator-gateway` | build `services/operator-gateway` | 8445 → 8443 | edge-api, pgbouncer | `--healthcheck` | alias `operator-adapter`; Incoplast operator adapter (TLS) |
| `barcode-service` | build `services/barcode-service` | internal 8446 | pgbouncer | `--healthcheck` | vhost `scan.staging` (`/v1/scans`), own Cognito-JWT auth |
| `bispharma-box-scan-mock` | `postgres:15-alpine` | — | pgbouncer | none | loops `scripts/mock-bispharma-box-scans.sql`; off unless `BISPHARMA_BOX_SCAN_MOCK_ENABLED=true` |

#### Frontends (nginx-served SPAs)

| Service | Build | Ports | Depends on | HC | Notes |
|---|---|---|---|---|---|
| `operator` | `./operator` (submodule, `Dockerfile.staging`) | 8083 → 80 | edge-api, read-api ✓healthy | none | CPACK tenant key injected by nginx |
| `operator-sbx` | same | 8085 → 80 | same | none | sandbox 2000003 |
| `operator-bispharma` | same | 8087 → 80 | same | none | Bispharma 5 |
| `csadmin` | `./csadmin` (submodule, `Dockerfile.staging`) | 8084 → 80 | edge-api | `wget /` | own Cognito login |
| `customize` | `./customize` (in-repo, `Dockerfile.staging`) | 8086 → 80 | edge-api | `wget /` | Customization Hub |
| `barcode-app` | image `barcode-app:staging` (**no build stanza**) | 8092 → 80 | edge-api | `wget /` | image is built by hand on the host; a deploy does not rebuild it |

`front4` is not in any compose file; it deploys from its own repository.

#### Identity and tooling

| Service | Image | Ports | Depends on | Notes |
|---|---|---|---|---|
| `oauth2-proxy` | `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0` | 4180 | app-redis ✓healthy | nginx `auth_request` target; Cognito OIDC; sessions in Redis db 1 |
| `cloudbeaver` | `dbeaver/cloudbeaver:26.2.0` | 8093 → 8978 | — | vhost `db.staging`; read-only connections to analytics + historian gateway; 1 GB |
| `pgweb-analytics` | `sosedoff/pgweb:latest` | 8082 → 8081 | — | kept unrouted as a fallback DB browser |
| `ollama` | `ollama/ollama:0.12.3` | — | — | CloudBeaver AI assistant model store; 2 GB, 1.5 CPU |

#### Observability

| Service | Image | Ports | HC | Volumes |
|---|---|---|---|---|
| `prometheus` | `prom/prometheus:v3.1.0` | 9090 | `/-/healthy` | `monitoring/prometheus/` (dir), `prom-data` |
| `alertmanager` | `prom/alertmanager:v0.27.0` | internal 9093 | none | `monitoring/alertmanager/` (dir), `alertmanager-data`; profile `alerting` |
| `grafana` (`stack-grafana-1`) | `grafana/grafana:11.5.0` | 3000 | `/api/health` | `grafana-data`, `grafana/provisioning`, `grafana/dashboards` |
| `loki` (`stack-loki-1`) | `grafana/loki:3.4.2` | internal 3100 | `/ready` | `monitoring/loki/…`, `loki-data` |
| `promtail` (`stack-promtail-1`) | `grafana/promtail:3.4.2` | — | none | `monitoring/promtail/…`, `/var/run/docker.sock` |
| `tempo` | `grafana/tempo:2.6.1` | internal 4317/4318/3200 | none | `monitoring/tempo/tempo.yaml`, `tempo-data` |
| `alloy` | `grafana/alloy:v1.5.1` | `${ALLOY_GATEWAY_BIND:-127.0.0.1}`:3101, :3102 | none | `monitoring/alloy/` (dir), `alloy-data` |
| `postgres-exporter` | `postgres-exporter:v0.15.0` | internal 9187 | none | `monitoring/postgres-exporter/` (dir) |
| `node-exporter` | `node-exporter:v1.8.2` | internal 9100 | none | `/proc`, `/sys`, `/` read-only |
| `redis-exporter` | `redis_exporter:v1.62.0` | internal 9121 | none | — |
| `blackbox-exporter` | `blackbox-exporter:v0.25.0` | internal 9115 | none | `monitoring/blackbox/blackbox.yml` |
| `cadvisor` | `cadvisor:v0.49.1` | internal 8080 | none | host `/`, `/var/run`, `/sys`, `/var/lib/docker` read-only |

Detail on each is in [observability.md](observability.md).

### Named volumes (staging)

`nr-edge-data`, `grafana-data`, `loki-data`, `prom-data`, `tempo-data`, `alloy-data`,
`alertmanager-data`, `rabbitmq-data`, `mosquitto-data`, `edge_transformer_outbox`,
`edge_transformer_agent_outbox`, `cloudbeaver-workspace`, `ollama-models`,
`bispharma-twin-state`. On disk they are prefixed `stack_`. The two outbox volumes and
`mosquitto-data` carry durability state (ADR-0011); never delete them to "clean up".

### `compose.superset.yml` (overlay)

Applied with `-f compose.staging.yml -f compose.superset.yml`; every service has
`profiles: ["superset"]` so nothing starts without the profile. It joins `packiot-net` and
uses `.42`–`.45`.

| Service | Image | Notes |
|---|---|---|
| `superset-redis` | `redis:7-alpine` | `noeviction`, AOF on, 256 MB |
| `superset-db-init` | `postgres:16-alpine` | one-shot; connects **directly** to the DB host (`POSTGRES_HOST_UPSTREAM`) for DDL |
| `superset-init` | `packiot/superset:4.1.1-w2` (built from `docker/superset/Dockerfile`) | one-shot migrations + roles |
| `superset` | same | 8088 on 127.0.0.1; `/health` HC; 2 GB; vhost `bi.staging` |
| `superset-worker` | same | Celery worker; 1 GB |

`pr-validation`-style guard: `superset-rls-isolation.yml` proves the overlay adds nothing
without `--profile superset`.

### `compose.historian-gateway.yml`

One service, `historian-gateway` (container `hist-gateway`), image `pgduckdb/pgduckdb:16-main`.
It joins the **external** network `stack_packiot-net`, so the `stack` project must exist first.
DuckDB is capped by `-c duckdb.memory_limit=1024 -c duckdb.threads=2` plus `mem_limit: 2560m`
(2026-09-28 audit after the 2026-09-25 OOM class). First boot on a fresh volume runs a
multi-minute seed inside initdb (`start_period: 20m`). It is **not** started by
`deploy-staging.yml`; the documented start is:

```bash
cd /opt/packiot && docker compose -p packiot --env-file .env.historian-gateway \
  -f compose.historian-gateway.yml up -d historian-gateway
```

See [historian gateway](historian-gateway.md).

### `compose.production.yml` (new-stack production)

Top-level `name: stack` pins the project (the deploy workflow and `app_init.sh` run from
different directories and used to create two container sets). Differences from staging:

| Aspect | Production |
|---|---|
| DB | external r7g DB EC2 `${POSTGRES_HOST_UPSTREAM}` (10.20.10.89); one DB whose `public` schema is the analytics schema |
| Only in production | `db-init-bootstrap`, `db-schema-f3`, `db-knex-baseline` (one-shot schema assembly), `hasura` + `hasura-init`, `adminer` |
| Profile `client-ingest` | `sparkplug-decoder`, `ingest-shim` (8444 on 0.0.0.0), `operator-gateway` (8445 on 0.0.0.0) |
| mosquitto | also publishes `8883` (mTLS) on 0.0.0.0 |
| Not in production | every simulator/twin/tee, mirrors, replicators, analytics-sync, legacy Node-RED, operator SPAs, customize, barcode, exporters, tempo, alloy, alertmanager, CloudBeaver, ollama, edge-session-broker, oeecloud-fanout |
| Deploy | `deploy-production.yml` on `[self-hosted, production, linux, arm64]`, no service-state gate (a diagnostic only) |

### `compose.onprem-edge.yml` (client factory box)

The "fat edge" (ADR-0053 B-minimal) that keeps the shop floor seeing live production during
an internet outage. Runs next to the client's `packiot-edge-reader`; no custom network.

| Service | Image | Ports | Notes |
|---|---|---|---|
| `mosquitto` | `eclipse-mosquitto:2` | — | local broker, `onprem_mosquitto_data` |
| `sparkplug-agent` | `packiot-sparkplug-decoder:local` | 127.0.0.1:9104 | the reader's local tee target |
| `edge-transformer` | same | — | `LOCAL_DECODE_ONLY`; writes current state to `edge_localstate` (SQLite) |
| `edge-dashboard` | same | `${DASHBOARD_PORT:-8080}` | the floor's browser page |

Start: `docker compose -f compose.onprem-edge.yml --env-file .env.onprem up -d --build`.

### `dev/` (local, ADR-0060 — replaced compose.development.yml)

Tier 0 (`dev/base.yml`): `postgres` (the anonymized seed image `ghcr.io/packiot/devseed`), `rabbitmq`, `mosquitto`,
`redis` (alias `app-redis`), `minio`. Slices (`dev/services/*.yml`): `grafana`, `read-api` + `read-api-cors`,
`front4` (Vite dev server from your checkout, dev Cognito pool). Driven by `make dev SVC=<service>`
(= `docker compose -f dev/compose.yml --env-file dev/.env.dev up -d --wait <service>`); every port binds 127.0.0.1.
See `dev/README.md`. The former `compose.development.yml` (Hasura, edge-nodered, simulator, `tests`, …) was removed
2026-10-07; its README is archived at `docs/archive/legacy-local-harness-README.md`.

## Configuration

Every environment variable in `compose.staging.yml` is indexed per service in
[configuration.md](../reference/configuration.md). Compose-level knobs: `COMPOSE_PROFILES`,
`ALLOY_GATEWAY_BIND`, and the `-p stack` project name.

## Data & invariants

- One compose project per host (`stack`). `--remove-orphans` is safe only because nothing
  else shares that project; the historian gateway uses a different project (`packiot`) so it
  is never reaped.
- Named volumes survive `up -d --force-recreate`; only `down -v` or `volume rm` deletes them.
- A config file must be mounted as a **directory** if you expect edits to reach a running
  container; single-file mounts pin the old inode (see [observability](observability.md#failure-modes)).
- Nothing listens publicly except through nginx or the Alloy relays (private IP, DB SG only).

## Observability

`cadvisor` gives per-container CPU/memory; the deploy gate prints state per service; the
`Uptime & containers` board (`library/14-uptime-containers.json`) shows restarts. Quick look:

```bash
docker compose -p stack -f compose.staging.yml -f compose.superset.yml ps -a
```

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Service stuck in `created` | Gate fails | compose create→start race when a dependency is not itself recreated (#67, run 29609399636) | `up -d --no-deps <svc>` |
| "Address already in use" on start | Service will not start | a hand-run container took its static IP (pre-`ip_range`) or a host port clash | remove the stray container; keep hand-runs on dynamic range |
| Duplicate stack / "Pool overlaps" | two sets of containers | built/started with a different project name | always `-p stack` on staging |
| Build reused an old image | Fix "deployed" but not live | built under a different `-p` than the running stack (edge-api Stop-PO fix, 2026-09) | rebuild with `-p stack` |
| RabbitMQ bind source became a directory | rabbitmq exit 127 after reboot | generated file lived in the CI workspace (2026-09-25) | now under `/opt/packiot/rabbitmq/` |
| `barcode-app` not updated by deploy | old SPA served | image tag without a `build:` stanza | rebuild/tag on the host; rollback tag noted in ops notes |

## Operating it

- Full redeploy: merge to `staging` (or dispatch `deploy-staging.yml`).
- One service: see [runbooks](../operations/runbooks.md#recreate-a-single-service).
- Never run heavy Docker operations (large `commit`, storage-driver changes, restart churn) on
  the shared staging app host; sandbox sim boxes run as containers there (2026-09-16 incident).

## Tests

- `pr-validation.yml`: `docker compose config --no-interpolate -q` on staging and development files.
- `superset-rls-isolation.yml` `validate-overlay` job: overlay is profile-gated and parses.
- Deploy service-state gate: every expected service running/healthy, one-shots exited 0.

## Source map

| Path | What's there |
|---|---|
| `compose.staging.yml` | staging app host stack, IP registry in header comments |
| `compose.superset.yml` | Superset overlay (profile `superset`) |
| `compose.historian-gateway.yml` | historian gateway (`hist-gateway`) |
| `compose.production.yml` | new-stack production |
| `compose.onprem-edge.yml` | on-prem fat edge |
| `dev/`, `Makefile` | local stack (ADR-0060) |
| `configs/` | mosquitto, CloudBeaver, Superset, pgbackrest, fanout configs |
| `monitoring/`, `grafana/` | observability configs mounted into the stack |
| `terraform/staging/user_data/nginx_setup.sh` | host nginx vhosts → container ports |
| `terraform/staging/user_data/db_init.sh` | how the DB host's `timescaledb` container is run |
