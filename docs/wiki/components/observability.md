---
title: Observability
layer: 3
owner_area: platform
last_verified: 2026-09-28
---
# Observability

> **Layer 3 · Components** — the staging monitoring stack: Prometheus and its alert rules,
> Alertmanager, Grafana dashboards, Loki/Promtail logs, Tempo traces, the Alloy gateway and
> DB-box agent, exporters and blackbox probes; what to look at per subsystem and the known
> traps. For on-call engineers and anyone adding a metric or board.
> Up: [Platform & operations](../subsystems/platform.md)

## Responsibility

Tell a human, quickly and truthfully, whether data is arriving, being computed and being
served for every tenant, and give them the metric, log line or trace that explains why not.
All of it runs as containers in the staging `stack` project; new-stack production runs only
Grafana, Prometheus, Loki and Promtail.

## At a glance

| Piece | Image | Where it listens (on `stack_packiot-net`) | Config |
|---|---|---|---|
| Prometheus | `prom/prometheus:v3.1.0` | 9090 (host `127.0.0.1:9090`) | `monitoring/prometheus/prometheus.yml`, `rules.yml` |
| Alertmanager | `prom/alertmanager:v0.27.0` | 9093 — profile `alerting` (parked) | `monitoring/alertmanager/alertmanager.yml` |
| Grafana | `grafana/grafana:11.5.0` | 3000 → `grafana.staging.packiot.app` (cs-admin oauth2 gate) | `grafana/provisioning/`, `grafana/dashboards/` |
| Loki | `grafana/loki:3.4.2` | 3100 | `monitoring/loki/loki-local-config.yaml`, `rules/` |
| Promtail | `grafana/promtail:3.4.2` | 9080 | `monitoring/promtail/promtail-config.yaml` |
| Tempo | `grafana/tempo:2.6.1` | 4317/4318 (OTLP), 3200 (API) | `monitoring/tempo/tempo.yaml` |
| Alloy (gateway) | `grafana/alloy:v1.5.1` | 4317/4318 OTLP, 3101 Loki relay, 3102 remote-write relay, 12345 admin | `monitoring/alloy/gateway.alloy` |
| Alloy (DB box) | container `alloy-db` on the DB host | pushes only | `monitoring/alloy/db-agent.alloy`, `scripts/deploy-db-agent.sh` |
| postgres-exporter | `v0.15.0` | 9187 | `monitoring/postgres-exporter/queries.yaml` |
| node-exporter | `v1.8.2` | 9100 | compose flags |
| redis-exporter | `v1.62.0` | 9121 (scrapes `app-redis`) | env `REDIS_ADDR` |
| blackbox-exporter | `v0.25.0` | 9115 | `monitoring/blackbox/blackbox.yml` (`http_2xx`, `tcp_connect`) |
| cAdvisor | `v0.49.1` | 8080 | compose mounts |

## Inputs & outputs

```text
 Go services /metrics ─┐                       ┌─► Grafana (Prometheus, Loki, Tempo,
 exporters, RabbitMQ ──┼─► Prometheus ─rules──►│    Postgres datasources)
 blackbox probes ──────┘      ▲   └─► Alertmanager (parked) ─► Slack #alerts / #alerts-critical
 DB-box Alloy ─3102 remote-write┘
 container stdout ─► Promtail (docker SD, project stack) ─► Loki ◄─3101── DB-box Alloy
                                                      └─ruler─► Alertmanager
 services OTLP ─► Tempo (direct)   read-api OTLP ─► Alloy :4317 ─► Tempo
```

## Internal design

### Prometheus

- Global: `scrape_interval: 15s`, external label `env=staging`; retention 15 d or 2 GB;
  `--web.enable-lifecycle` (hot reload), `--web.enable-remote-write-receiver` (for Alloy),
  exemplar storage on.
- Scrape jobs (`prometheus.yml`):

| Job | Target | Notes |
|---|---|---|
| `oeecloud-worker` | `oeecloud-worker:9101` | = stream-engine (network alias); job name kept for dashboard continuity; relabels routing key → `tenant` |
| `edge-transformer` | `edge-transformer:9102` | = sparkplug-decoder (alias); metric prefix `edge_transformer_` kept |
| `analytics-sync` | `analytics-sync:9103` | |
| `legacy-replicator` | `legacy-replicator:9104` | |
| `read-api` | `read-api:9104` | |
| `ingest-shim` | `ingest-shim:9105` | |
| `operator-gateway` | `operator-gateway:8443` | |
| `edge-api` | `edge-api:8080` | HTTP RED metrics |
| `rabbitmq`, `rabbitmq-detailed` | `rabbitmq:15692` | aggregated + per-queue |
| `postgres-exporter`, `node-exporter`, `redis-exporter`, `cadvisor` | as above | |
| `blackbox` | probes `https://operator.staging.packiot.app`, `https://grafana.staging.packiot.app`, `http://edge-api:8080/health`, `http://read-api:9104/healthz` | `http_2xx` |
| `blackbox-historian` | `hist-gateway:5432` | `tcp_connect` |
| (commented) `mirror-worker-go` | — | retired; the `Mirror*` alerts therefore never fire |

### Alert rules (`monitoring/prometheus/rules.yml`)

| Group | Alerts (severity) | Meaning in one line |
|---|---|---|
| `packiot-staging` | `ScrapeTargetDown` (page), `EngineJobErrorStreak` (page), `EngineStalled` (page), `IngestSilent` (page), `WritePathDry` (page), `ClientIngestStopped` (warn) | a target is down; stream-engine jobs erroring/not ticking; no AMQP deliveries in 10 m; deliveries but no writes; one tenant stopped writing after being active in the prior 6 h |
| `packiot-flow-and-parity` | `FlowWriteImbalance` (critical), `BatchWriteErrors`, `BakeSurfacePersisting`, `IdentityBrokenPersisting` (critical), `MirrorDLQNotEmpty`, `MQTTDisconnected` (critical) | write legs diverging; batch statement errors; parity bake mismatches; decoder lost Mosquitto |
| `packiot-durability-and-mirror` | `TransformerOutboxBacklog`, `TransformerOutboxStale` (critical), `TransformerPublishNacked`, `TransformerMqttDrops`, `OeeUnroutableMessages`, `PackmlUnroutableTopic`, `SparkplugSeqGapStream`, `MirrorCursorLag`, `MirrorOeeDivergence`, `ShadowMirrorFailures`, `ReplicatorReplayGaps` | outbox not draining; broker nacks; messages hitting no binding (`oee-unroutable-q`); topics with no active `packml_register`; Sparkplug seq gaps; replicator zero-row updates |
| `packiot-host-and-db` | `HostDiskFilling` (critical, <15% free), `HostDiskHigh` (<20%), `DbBoxMetricsMissing`, `RetentionPolicyDrift`, `RetentionPurgeErrors`, `PostgresDown` (critical), `PostgresConnectionsHigh` (>160 of 200), `AnalyticsCaggRefreshLag`, `AnalyticsTimescaleJobFailing`, `HistorianGatewayDown` | host/DB health, retention catalog drift, stale continuous aggregates, failing Timescale jobs, cold-store gateway down |
| `packiot-flip-readiness` | `TenantNotFlipReady` (info) | a tenant's bake surfaces not converged |
| `packiot-po-staleness-gate` | `POStalenessGateRejectingWrites` (critical) | edge-api returning 409 on PO routes for 10 m |

Loki ruler (`monitoring/loki/rules/fake/log-alerts.yaml`): `LogErrorSpike`, `LogPanicDetected`,
`LogOOMDetected`, sent to `alertmanager:9093`.

### Alertmanager

Routes group by `alertname, severity`; `severity="critical"` → receiver `slack-critical`
(`#alerts-critical`, faster repeat), everything else → `slack-default` (`#alerts`). Inhibits
warnings under a firing critical, and `ClientIngestStopped` under a global `IngestSilent` /
`WritePathDry`. The webhook URL is read from a gitignored file the deploy materializes from
`packiot/staging/app` key `slack_api_url`. **Status: parked.** To enable: put the URL in the
secret, add `alerting` to `COMPOSE_PROFILES`, deploy. Until then alerts are visible only in
Prometheus `/alerts` and Grafana.

### Grafana

- Datasources (provisioned): `Prometheus` (`packiot-prometheus`), `Loki` (`packiot-loki`),
  `Tempo` (`packiot-tempo`), `Packiot Analytics (F3)` (uid `packiot-postgres-shadow`,
  database `packiot_analytics` — the uid is legacy on purpose; many panels reference it),
  `Packiot PostgreSQL` (`packiot-postgres`, `$POSTGRES_DB`).
- `foldersFromFilesStructure: true` → folder per subdirectory. Home dashboard:
  `audience/00-overview.json`. Admin login from `GRAFANA_ADMIN_PASSWORD`; anonymous off.

| Folder | Board (uid) | Use it for |
|---|---|---|
| audience | Overview (`v2-overview`) | firing alerts, stack alive, does data land — start here |
| audience | ① CS · Client health (`aud-cs`) | per-client queue, writes, OEE sanity |
| audience | ② Platform · SRE (`aud-sre`) | host, containers, DB, broker |
| audience | ③ Pipeline · Data eng (`aud-data`) | flow through bronze/silver/gold |
| audience | Ingest debug (`aud-debug-ingest`) | decision tree "why isn't client X's data arriving?"; `$tenant` = lowercased group |
| library | `v2-oee`, `v2-engine`, `v2-ingest`, `v2-operator`, `v2-logs`, `v2-equipment`, `v2-infra`, `v2-database`, `v2-api`, `v2-rabbitmq`, `v2-uptime-containers`, `v2-po-staleness-gate`, `v2-database-dbm`, `v2-data-quality`, `v2-query-traces`, `v2-factory-analysis` | component deep dives (stable uids for links) |

The persona layout is documented in `docs/ops/observability-persona-dashboards.md`, which
supersedes `grafana/README.md` and `grafana/dashboards/_SPEC.md`.

### Logs: Promtail and Loki

Promtail discovers containers via the Docker socket and **keeps only compose project
`stack` or `packiot-stack-alpha`**, labelling `container` and `service`. Loki is single-binary
with filesystem storage and 72 h retention. The DB box's `timescaledb` logs arrive through
the Alloy relay on 3101.

### Traces: Tempo and Alloy

Tempo keeps 48 h of traces. edge-api, stream-engine, sparkplug-decoder (10% sampling),
operator-gateway and ingest-shim export OTLP straight to `tempo:4317`; read-api goes through
the Alloy gateway (`alloy:4317`) as the first step of moving all services behind it. Board
`v2-query-traces` covers per-request DB query forensics.

### DB-box agent

`scripts/deploy-db-agent.sh` (run from a workstation via SSM) recreates the `alloy-db`
container on the DB host with `--cpus 0.3` and a positions volume. It pushes container logs to
`<app private IP>:3101` and host metrics to `:3102`; the app SG admits those ports from the DB
SG only. Verify with the absence alert: `absent(node_filesystem_avail_bytes{instance="db-box"})`
must be empty.

### Where to look, by subsystem

| Subsystem | First look | Then |
|---|---|---|
| [Edge](../subsystems/edge.md) / [Ingestion](../subsystems/ingestion.md) | `aud-debug-ingest` for the tenant; `MQTTDisconnected`, `SparkplugSeqGapStream`, `PackmlUnroutableTopic` | `v2-ingest`, `v2-rabbitmq`; `docker logs sparkplug-decoder`, `sparkplug-agent-shared` |
| [Compute](../subsystems/compute.md) | `EngineStalled`, `EngineJobErrorStreak`, `WritePathDry` | `v2-engine`; logs `stream-engine` (`job tick TIMED OUT`) |
| [Analytics DB](../subsystems/analytics-db.md) | `PostgresDown`, `PostgresConnectionsHigh`, `AnalyticsCaggRefreshLag` | `v2-database`, `v2-database-dbm`, `v2-data-quality`; DB logs in Loki via relay |
| [Historian](../subsystems/historian.md) | `HistorianGatewayDown` | `docker logs hist-gateway` (not in Loki); systemd journal for `historian-staging-append` |
| [Legacy bridge](../subsystems/legacy-bridge.md) | `ReplicatorReplayGaps` | `docker logs legacy-replicator`; `ops.mirror_replay_dlq` |
| [Serving & APIs](../subsystems/serving-apis.md) | blackbox `probe_success`, `POStalenessGateRejectingWrites` | `v2-api`, `v2-query-traces` |
| [Frontends](../subsystems/frontends.md) | blackbox on operator URL | nginx logs on the host; container logs |
| Platform | `HostDiskFilling`, `ScrapeTargetDown`, `DbBoxMetricsMissing` | `v2-infra`, `v2-uptime-containers`, `aud-sre` |

## Configuration

| Knob | Where | Effect |
|---|---|---|
| `ALLOY_GATEWAY_BIND` | `/opt/packiot/.env` | host IP the 3101/3102 relays bind; default loopback silently refuses the DB box |
| `COMPOSE_PROFILES` contains `alerting` | `.env` | starts Alertmanager |
| `packiot/staging/app` `slack_api_url` | Secrets Manager | Slack webhook |
| `--storage.tsdb.retention.time/size` | compose `prometheus.command` | 15d / 2GB |
| `retention_period` | Loki config | 72h |
| `block_retention` | Tempo config | 48h |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER_ARG` | per service in compose | trace destination and sampling |
| `PG_EXPORTER_EXTEND_QUERY_PATH` | postgres-exporter env | custom queries (`pg_retention`, Timescale jobs/caggs/compression, …) |

## Data & invariants

- Config directories (`monitoring/prometheus/`, `monitoring/alertmanager/`,
  `monitoring/alloy/`, `monitoring/postgres-exporter/`) are mounted as **directories** so a
  git checkout's new inode is visible; the deploy then reloads Prometheus, Alloy and
  Alertmanager, and restarts postgres-exporter only if its queries changed.
- Dashboards must pin known datasource uids and query real metrics (`dashboard-lint.yml`); every
  Prometheus tile is hard-proofed against live staging Prometheus.

## Observability

This page is the observability of the platform; its own health is `ScrapeTargetDown` on
`job="prometheus"` and the blackbox probe of `grafana.staging.packiot.app`.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Alloy relay on loopback | DB slow-query logs missing from Loki; `alloy-db` logged "error sending batch" 24,716× (≥2026-09-14 → 2026-09-24) | `ALLOY_GATEWAY_BIND` absent from `.env` (never regenerated) → `127.0.0.1` bind | deploy step sets it to the private IP (#1405); check `docker port alloy` |
| Exporter single-file-mount inode trap | new metric (`pg_retention`) absent after a green deploy; container saw 12 queries, repo had 13 (stale since 2026-08-27) | a single-file bind mount pins the inode at container create; `git checkout` writes a new inode | directory mounts + reload/restart (#1406, tasks #39/#41) |
| Rule edits not loaded | new alert missing | Prometheus reads config only at start/reload | deploy POSTs `/-/reload`; manual: `docker run --rm --network container:prometheus curlimages/curl -X POST localhost:9090/-/reload` |
| Promtail dropped everything | no logs for any container (until 2026-06-18, 108k+ entries lost) | keep-regex matched the wrong project name | regex now matches `stack` or `packiot-stack-alpha` |
| Historian gateway logs absent | nothing in Loki for `hist-gateway` | runs under project `packiot`, which Promtail's keep-regex drops | read with `docker logs hist-gateway` |
| "Up" but dead services | green deploy, no data | e.g. decoder started before RabbitMQ and disabled its publisher (2026-09-25) | trust `IngestSilent`/`WritePathDry` and write counters, not container state |
| Memory pressure invisible in cAdvisor | containers shrinking, host thrashing | a host process (historian DuckDB timer) outside cAdvisor's view (2026-09-25) | look at `node_memory_MemAvailable_bytes` and the host journal |
| Alerts not reaching anyone | alerts fire in Prometheus only | Alertmanager parked | enable `alerting` profile with the webhook |

## Operating it

```bash
# open Prometheus / Grafana through an SSM port-forward (no public Prometheus)
aws ssm start-session --target <app-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9090"],"localPortNumber":["19090"]}'
# firing alerts
curl -s localhost:19090/api/v1/alerts | jq '.data.alerts[] | {a: .labels.alertname, s: .state}'
# is every target up?
curl -s 'localhost:19090/api/v1/query?query=up==0' | jq '.data.result[].metric.job'
```

Grafana is at `https://grafana.staging.packiot.app` (cs-admin group). After any
observability change, **verify the effect** (query the metric, see the log line), not the
deploy status.

## Tests

`dashboard-lint.yml` (structure + live hardproof), `scripts/lint-dashboards.py`,
`scripts/hardproof-dashboards.py`. Alert expressions are validated by Prometheus on reload.

## Source map

| Path | What's there |
|---|---|
| `monitoring/prometheus/prometheus.yml`, `rules.yml` | scrape jobs, alert rules |
| `monitoring/alertmanager/alertmanager.yml`, `slack_api_url.example` | routing, receivers, inhibits |
| `monitoring/loki/loki-local-config.yaml`, `monitoring/loki/rules/` | Loki + ruler |
| `monitoring/promtail/promtail-config.yaml` | log shipping |
| `monitoring/tempo/tempo.yaml` | traces |
| `monitoring/alloy/gateway.alloy`, `db-agent.alloy` | OTLP gateway, relays, DB-box agent |
| `monitoring/postgres-exporter/queries.yaml` | custom DB metrics |
| `monitoring/blackbox/blackbox.yml` | probe modules |
| `monitoring/rabbitmq/` | broker plugins (prometheus) and definitions template |
| `grafana/provisioning/`, `grafana/dashboards/{audience,library}/` | datasources, boards |
| `docs/ops/observability-persona-dashboards.md` | dashboard map (canonical) |
| `scripts/deploy-db-agent.sh` | DB-box Alloy deploy |
| `.github/workflows/deploy-staging.yml` | reload/restart steps |
| `monitoring/README.md`, `grafana/README.md` | older notes (partly stale) |
