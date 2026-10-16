---
title: Service catalog
layer: 4
owner_area: platform
last_verified: 2026-10-13
---
# Service catalog

> **Reference.** The index that ties the docs together: for every deployable unit, its
> README (how to run and change it), its wiki page (how it works), its API reference and
> dashboard. When you add a service, add a row here. Up: [Reference](index.md)

Links: **README** = the repository README (GitHub, `staging` branch) · **Wiki** = the
component page in [Understand](../understand/index.md) · **API** = generated
[API reference](api/index.md) · **Dashboard** = Grafana on staging (SSO).

## Edge and ingestion

| Service | What it does | README | Wiki | API | Dashboard |
|---|---|---|---|---|---|
| sparkplug-agent | Factory-box agent: reads PLC tags, publishes Sparkplug B; HTTP tag ingest | [README][r-decoder] | [sparkplug-agent](../understand/components/sparkplug-agent.md) | [sparkplug-agent](api/sparkplug-agent.md) | [Ingest debug][g-ingest-debug] |
| sparkplug-decoder | Decodes Sparkplug, turns counters into increments, publishes to the `oee` exchange; onboarding API | [README][r-decoder] | [sparkplug-decoder](../understand/components/sparkplug-decoder.md) | [onboard API](api/onboard-api.md) | [Ingest][g-ingest] |
| ingest-shim | Sparkplug over HTTP for clients without MQTT | [README][r-ingest-shim] | [ingest-shim & fanout](../understand/components/ingest-shim-and-fanout.md) | [ingest-shim](api/ingest-shim.md) | [Ingest][g-ingest] |
| oeecloud-fanout | Copies a tenant's messages to its sandbox twin | [README][r-fanout] | [ingest-shim & fanout](../understand/components/ingest-shim-and-fanout.md) | — | [Bus — RabbitMQ][g-rabbitmq] |
| edge-node-red *(legacy)* | Old factory Node-RED; retired on staging | [README][r-enr] | [Edge Node-RED](../understand/components/edge-node-red.md) | — | — |

## Compute and data

| Service | What it does | README | Wiki | API | Dashboard |
|---|---|---|---|---|---|
| stream-engine | Consumes increments and events, rolls up OEE (hour, shift, day), production orders | [README][r-engine] | [stream-engine](../understand/components/stream-engine.md) | — | [Engine][g-engine] |
| analytics-sync | Replicates legacy writes into the analytics DB during the migration | [README][r-sync] | [analytics-sync](../understand/components/analytics-sync.md) | — | — |
| historian-gateway | SQL access to cold history (DuckDB over S3 Parquet) | [README][r-hist] | [historian gateway](../understand/components/historian-gateway.md) | — | — |
| Analytics DB (TimescaleDB) | `packiot_analytics`: bronze → silver → gold → serving | [db/README][r-db] | [schemas](../understand/components/analytics-db-schemas.md) · [jobs & retention](../understand/components/timescale-jobs-and-retention.md) | — | [Database][g-db] |
| RabbitMQ / Mosquitto | Message buses | — | [Brokers](../understand/components/brokers.md) | — | [Bus — RabbitMQ][g-rabbitmq] |
| mirror-worker-go *(retired)* | Old legacy comparator | [README][r-mirror] | [mirror-worker](../understand/components/mirror-worker.md) | — | — |

## APIs and apps

| Service | What it does | README | Wiki | API | Dashboard |
|---|---|---|---|---|---|
| edge-api | Control-plane API (NestJS) | [README][r-edge-api] | [edge-api](../understand/components/edge-api.md) | [edge-api](api/edge-api.md) | [API — RED][g-api] |
| read-api | Read-plane API | [README][r-read-api] | [read-api](../understand/components/read-api.md) | [read-api](api/read-api.md) | [API — RED][g-api] |
| operator-gateway | Operator actions from a client's own system | [README][r-opgw] | [operator-gateway](../understand/components/operator-gateway.md) | [operator-gateway](api/operator-gateway.md) | [Operator][g-operator] |
| barcode-service | Box-scan ingest, gapless labels | [README][r-barcode] | [barcode-service](../understand/components/barcode-service.md) | [barcode-service](api/barcode-service.md) | — |
| edge-session-broker | Browser shells to factory boxes (ADR-0057) | [README][r-broker] | [edge session broker](../understand/components/edge-session-broker.md) | — | — |
| front4 | Product dashboards (React) | [README][r-front4] | [front4](../understand/components/front4.md) | — | — |
| operator app | Shop-floor tablet app | [README][r-operator] | [Operator app](../understand/components/operator-app.md) | — | [Operator][g-operator] |
| CS Admin | Client onboarding SPA | [README][r-csadmin] | [CS Admin](../understand/components/csadmin.md) | — | [CS · Client health][g-cs] |
| Customization Hub | Per-client calculations, flows, OEE settings | — | [Customize](../understand/components/customize.md) | — | — |
| Superset | Self-service BI embedded in front4 | — | [Superset](../understand/components/superset.md) | — | — |

## Platform

| Unit | What it does | README | Wiki | Dashboard |
|---|---|---|---|---|
| Identity | Cognito, oauth2-proxy SSO, user migration Lambda | [cognito-user-migration][r-cognito] | [oauth2-proxy & Cognito](../understand/components/oauth2-proxy-and-cognito.md) | — |
| Observability | Prometheus, Loki, Tempo, Alloy, Grafana | [grafana/README][r-grafana] | [Observability](../understand/components/observability.md) | [Overview][g-overview] · [Platform · SRE][g-sre] |
| Infrastructure | Terraform, compose topology, CI/CD | [terraform/README][r-tf] | [Terraform](../understand/components/terraform.md) · [Compose topology](../understand/components/compose-topology.md) · [CI/CD](../understand/components/ci-cd.md) | [Infra][g-infra] |
| Dev environment | ADR-0060 local slices + anonymized seed | [dev/README][r-dev] | [Local development](../build/develop/local-development.md) | — |
| Docs | This wiki, READMEs, API specs | [docs/README][r-docs] | [Wiki pipeline](../understand/components/wiki-pipeline.md) | — |

[r-decoder]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/sparkplug-decoder/README.md
[r-ingest-shim]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/ingest-shim/README.md
[r-fanout]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/oeecloud-fanout/README.md
[r-enr]: https://github.com/packiot/edge-node-red/blob/staging/README.md
[r-engine]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/stream-engine/README.md
[r-sync]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/analytics-sync/README.md
[r-hist]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/historian-gateway/README.md
[r-db]: https://github.com/packiot/packiot-stack-alpha/blob/staging/db/README.md
[r-mirror]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/mirror-worker-go/README.md
[r-edge-api]: https://github.com/packiot/edge-api/blob/staging/README.md
[r-read-api]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/read-api/README.md
[r-opgw]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/operator-gateway/README.md
[r-barcode]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/barcode-service/README.md
[r-broker]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/edge-session-broker/README.md
[r-front4]: https://github.com/packiot/front4/blob/staging/README.md
[r-operator]: https://github.com/packiot/operator4/blob/staging/README.md
[r-csadmin]: https://github.com/packiot/csadmin/blob/staging/README.md
[r-cognito]: https://github.com/packiot/packiot-stack-alpha/blob/staging/services/cognito-user-migration/README.md
[r-grafana]: https://github.com/packiot/packiot-stack-alpha/blob/staging/grafana/README.md
[r-tf]: https://github.com/packiot/packiot-stack-alpha/blob/staging/terraform/README.md
[r-dev]: https://github.com/packiot/packiot-stack-alpha/blob/staging/dev/README.md
[r-docs]: https://github.com/packiot/packiot-stack-alpha/blob/staging/docs/README.md
[g-ingest-debug]: https://grafana.staging.packiot.app/d/aud-debug-ingest
[g-ingest]: https://grafana.staging.packiot.app/d/v2-ingest
[g-rabbitmq]: https://grafana.staging.packiot.app/d/v2-rabbitmq
[g-engine]: https://grafana.staging.packiot.app/d/v2-engine
[g-db]: https://grafana.staging.packiot.app/d/v2-database
[g-api]: https://grafana.staging.packiot.app/d/v2-api
[g-operator]: https://grafana.staging.packiot.app/d/v2-operator
[g-cs]: https://grafana.staging.packiot.app/d/aud-cs
[g-overview]: https://grafana.staging.packiot.app/d/v2-overview
[g-sre]: https://grafana.staging.packiot.app/d/aud-sre
[g-infra]: https://grafana.staging.packiot.app/d/v2-infra
