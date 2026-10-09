---
title: Configuration reference
layer: 4
owner_area: platform
last_verified: 2026-09-28
---
# Configuration reference

> **Layer 4 · Reference** — every environment variable set in `compose.staging.yml`, grouped
> by service, with its staging value (secrets shown only as "from `.env`") and a one-line
> meaning. For looking up a knob; follow the links for how it behaves.
> Up: [Platform & operations](../subsystems/platform.md) · Detail: [Compose topology](../components/compose-topology.md)

How values arrive: `${VAR}` is substituted from `/opt/packiot/.env` (symlinked as `.env`);
services with `env_file: [.env]` also receive **every** key in that file. "from `.env`" means
the value is a secret or host-specific and lives only there (sourced from Secrets Manager, see
[Platform § secrets](../subsystems/platform.md#secrets-path)). "Default" is the code default
when it differs from staging and was verified in source. Changing a value takes a recreate:
[runbooks](../operations/runbooks.md#recreate-a-single-service).

## Host-level keys in `/opt/packiot/.env`

| Key | Meaning |
|---|---|
| `COMPOSE_PROFILES` | profile-gated services to start (`superset`, `cpack-tee`, `shared-tee`, `alerting`, …) |
| `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | analytics DB host/login; `POSTGRES_DB` is the legacy `packiot` name, most services override to `packiot_analytics` |
| `POSTGRES_HOST_UPSTREAM` | DB host for direct (non-pgbouncer) DDL, used by the Superset overlay |
| `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | broker admin (also rendered into RabbitMQ definitions) |
| `ALLOY_GATEWAY_BIND` | private IP for Alloy relays 3101/3102 (self-healed by deploy) |
| `HIST_GW_SVC_PASSWORD` | `historian_svc` login to the historian gateway (self-healed by deploy) |
| `GRAFANA_ADMIN_PASSWORD`, `OAUTH2_PROXY_CLIENT_SECRET`, `OAUTH2_PROXY_COOKIE_SECRET`, `CLOUDBEAVER_*_PASSWORD`, `SUPERSET_*` | per-service secrets |

## Edge ingress and decoding

Detail: [Ingestion](../subsystems/ingestion.md), [Edge](../subsystems/edge.md).

### sparkplug-decoder

| Variable | Staging | Meaning |
|---|---|---|
| `LOG_LEVEL` | `info` | log verbosity |
| `EDGE_TRANSFORMER_MODE` | `factory` | decoder run mode |
| `PHASE9_LINE_AGG_ENABLED` | `true` | aggregate member counters to line level |
| `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_TRACES_SAMPLER_ARG` | `http://tempo:4317` / `0.1` | traces to Tempo, 10% sampled |
| `AWS_REGION`, `RABBITMQ_SECRET_ID` | `us-east-1`, `packiot/staging/rabbitmq-sparkplug-decoder-creds` | where AMQP creds come from |
| `RABBITMQ_HOST` / `RABBITMQ_PORT` | `rabbitmq` / `5672` | broker |
| `SOURCE_EXCHANGE`, `WORKER_QUEUE`, `RETRY_EXCHANGE`, `RETRY_QUEUE`, `FAILED_EXCHANGE`, `FAILED_QUEUE` | `edge.plc-normalized`, `edge-transformer-q`, `…-retry`, `edge-transformer-q-retry-30s`, `dlx.edge.plc-normalized`, `edge-transformer-q-failed` | AMQP source path (disabled, see `AMQP_SOURCE_ENABLED`) |
| `RETRY_TTL_MS`, `MAX_RETRIES`, `PREFETCH` | `30000`, `5`, `50` | retry delay, attempts, consumer prefetch |
| `HEALTH_PORT` | `9102` | health + `/metrics` |
| `CLIENT_YAML_PATH` | `/etc/packiot/client.yaml` | tenant config (mounted `docs/clients/cpack.yaml`) |
| `BIRTH_BOUND_RESOLVER`, `REFDATA_URL`, `REFDATA_INTERNAL_KEY` | `refdata`, `http://read-api:9104`, from `.env` | resolve NBIRTH metrics through read-api |
| `MQTT_ENABLED`, `MQTT_BROKER_URL`, `MQTT_CLIENT_ID`, `MQTT_USERNAME`, `MQTT_PASSWORD` | `true`, `tcp://mosquitto:1883`, `edge-transformer-staging`, empty | MQTT ingest (the primary path) |
| `MQTT_STALE_THRESHOLD_SECONDS` | `-1` | stale-connection watchdog off |
| `AMQP_SOURCE_ENABLED` | `false` | legacy AMQP input off |
| `USE_GO_PORT` | `true` | use the Go calc port |
| `ONBOARD_API_ENABLED`, `ONBOARD_API_PORT`, `ONBOARD_API_KEY` | `true`, `9105`, from `.env` | onboarding generator API called by edge-api |
| `OUTBOX_ENABLED`, `OUTBOX_PATH`, `OUTBOX_CAP` | `true`, `/var/lib/edge-transformer/outbox.db`, `100000` | store-and-forward SQLite outbox |
| `SHADOW_EMIT_REFACTORED`, `SHADOW_EMIT_GO`, `SHADOW_EMIT_PRODUCTION` | `true`, `false`, `false` | which envelope legs are published (only `refactored`) |
| `CALC_CUTOVER_REFACTORED`, `CALC_NO_SPEED_GUARD_FALLBACK`, `CALC_COUNTER_SPIKE_MARGIN` | `true`, `true`, `10` | calc behaviour and counter-spike guard margin |
| `F3_PER_TENANT_ROUTING` | `true` | route to `sparkplug.data.<tenant>` keys |
| `POSTGRES_DB`, `POSTGRES_URL` | `packiot_analytics`, DSN from `.env` values | direct DB access (bypasses pgbouncer) |
| `COUNTERS_ONLY_OEE_ENABLED`, `COUNTERS_ONLY_IDEAL_RATES` | `true`, JSON map topic→rate | OEE for counter-only lines and their ideal rates |
| `OEE_PROFILE_FROM_DB` | `true` | read OEE profile from the DB |
| `EDGE_COMMANDS_ENABLED`, `EDGE_COMMANDS_ALLOWED` | `false`, `po_setup,param_write` | cloud→edge commands (off) |

### sparkplug-agent-cpack / sparkplug-agent-shared

| Variable | Staging | Meaning |
|---|---|---|
| `AGENT_CONFIG` (cpack) | `/etc/packiot/agent.yaml` | single-tenant agent config |
| `AGENT_TENANTS_DIR`, `AGENT_TENANTS_PROFILE_DIR` (shared) | `/etc/packiot/tenants`, `/etc/packiot/tenant-profiles` | per-tenant configs and conversion profiles |
| `HEALTH_PORT` | `9103` | health |
| `AGENT_HTTP_INGEST_ENABLED`, `AGENT_INGEST_PORT`, `AGENT_INGEST_API_KEY` | `true`, `9104`, from `.env` | HTTPS `/v1/tags` ingest behind nginx |
| `OUTBOX_PATH` (cpack) / `AGENT_OUTBOX_DIR` (shared) | agent outbox volume | durability |
| `AGENT_BIRTH_ALL_MAPPED` | `true` | NBIRTH declares every mapped metric |
| `AGENT_CAPTURE_ENABLED` (shared) | `true` | capture raw tags for onboarding |
| `AGENT_REGISTER_DSN` (shared) | from `.env` | DB DSN for register-driven tag maps (ADR-0043) |
| `MQTT_STALE_THRESHOLD_SECONDS` | `-1` | watchdog off |

### ingest-shim

| Variable | Staging | Meaning |
|---|---|---|
| `RABBITMQ_SECRET_ID`, `EXCHANGE`, `ROUTING_KEY` | decoder creds, `oee`, `sparkplug.data.incoplast` | publish target |
| `FANOUT_SOURCE_TYPES`, `SCOPE_GROUP` | `refactored`, `INCOPLAST` | envelope type and allowed group |
| `HTTP_ADDR`, `METRICS_ADDR` | `:8444`, `:9105` | HTTPS ingest and metrics |
| `INGEST_API_KEY`, `TLS_CERT_FILE`, `TLS_KEY_FILE` | from `.env`, `/certs/*` | auth and TLS |

### oeecloud-fanout

| Variable | Staging | Meaning |
|---|---|---|
| `FANOUT_CPACK_TO_SBXCPACK_ENABLED` | from `.env`, default `false` | master switch |
| `FANOUT_QUEUE`, `FANOUT_SOURCE_GROUP`, `FANOUT_TARGET_GROUP` | `oeecloud-fanout-cpack-to-sbxcpack`, `CPACK`, `SBXCPACK` | copy CPACK → sandbox |
| `FANOUT_SOURCE_ROUTING_KEYS`, `FANOUT_TARGET_ROUTING_KEY` | `sparkplug.data,sparkplug.data.cpack`, `sparkplug.data.sbxcpack` | keys read / written |
| `PREFETCH`, `PUBLISH_CONFIRM_TIMEOUT_MS`, `HEALTH_PORT` | `50`, `5000`, `9102` | consumer tuning, health |

### Simulators and twins

| Service | Variables (staging) | Meaning |
|---|---|---|
| `bispharma-twin` | `BISPHARMA_TWIN_ENABLED` (default `false`), `TWIN_GROUP=BISPHARMASTAGING`, `TWIN_LINE` (`ALL`), `TWIN_INTERVAL_SEC` (15), `TWIN_RATE_PER_MIN` (50), `TWIN_SCRAP_RATE` (0.03), `TWIN_STOP_PROB` (0.03), `TWIN_STOP_MIN_SEC`/`MAX_SEC` (120/600), `TWIN_STATE_FILE` | synthetic Bispharma producer and its per-line stop simulation |
| `bispharma-box-scan-mock` | `BISPHARMA_BOX_SCAN_MOCK_ENABLED` (default `false`), `MOCK_INTERVAL_SEC` (30), `PG*` | appends mock box scans via pgbouncer |
| `plc-sim` | `MQTT_BROKER_URL`, `PLC_SIM_TICK_SEC=5` | synthetic PLC (profile `plc-sim`) |
| `s7-softplc` / `s7-reader` | `LISTEN_ADDR=:102`, `S7_DB=100`, `SOFTPLC_TICK_SEC=5` / `S7_HOST`, `S7_RACK=0`, `S7_SLOT=2`, `S7_GROUP=INCOPLAST`, `S7_EDGE_NODE`, `S7_TICK_SEC=5` | S7 test pair (profile `s7`) |
| `simulator` | `EDGE_NODERED_URL`, `EDGE_API_URL`, `DB_URL`, `SIM_INTERVAL=5`, `OP_INTERVAL=15`, `SIM_SKIP_ENTERPRISE_IDS=3,4` | legacy simulator (profile `legacy-sim`) |
| `edge-nodered` | `RABBITMQ_*`, `ID_PUBSUB_NODE`, `HASURA_URL`, `HASURA_ADMIN_SECRET`, `API_KEY`, `EDGE_API_BASE_URL`, `ID_ENTERPRISE=3` | retired Node-RED edge (profile `legacy-sim`) |

### rabbitmq / mosquitto

| Service | Variable | Meaning |
|---|---|---|
| `rabbitmq` | `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` (from `.env`) | ignored once `load_definitions` imports users |
| `mosquitto` | none | config in `configs/mosquitto/mosquitto.conf` |

## Compute

### stream-engine

Detail: [stream-engine](../components/stream-engine.md), [Compute](../subsystems/compute.md).

| Variable | Staging | Default | Meaning |
|---|---|---|---|
| `LOG_LEVEL` | `info` | `info` | log verbosity |
| `AWS_REGION`, `PG_SECRET_ID`, `CREDS_SOURCE` | `us-east-1`, `packiot/staging/db`, `env` | | take DB creds from env (not Secrets Manager) |
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` | `10.10.10.89`, `5432`, from `.env`, `packiot_analytics` | | direct DB connection (not pgbouncer) |
| `POSTGRES_ANALYTICS_DB_NAME` | `packiot_analytics` | empty | analytics DB name |
| `POSTGRES_MAX_CONNS`, `POSTGRES_ANALYTICS_MAX_CONNS` | `5`, `15` | same | pool sizes |
| `RABBITMQ_SECRET_ID`, `RABBITMQ_HOST`, `RABBITMQ_PORT` | `…/rabbitmq-stream-engine-creds`, `rabbitmq`, `5672` | | broker |
| `SOURCE_EXCHANGE`, `WORKER_QUEUE`, `RETRY_*`, `FAILED_*`, `RETRY_TTL_MS`, `MAX_RETRIES` | `oee`, `stream-engine-q`, 30 s retry, `-failed` DLQ, `30000`, `5` | | queue topology |
| `WORKER_TENANT_ALLOWLIST` | `cpack,sbxcpack,bispharmastaging` | empty | tenants that get a consumer queue set (lowercased Sparkplug group) |
| `PREFETCH`, `CONSUME_LANES` | `50`, `4` | `50`, `1` | consumer prefetch and parallel lanes |
| `TENANT_DISCOVERY_INTERVAL_SECONDS` | `60` | `60` | how often tenants are re-discovered |
| `WORKER_POOL_SAC_ENABLED` | `false` | `false` | single-active-consumer worker pool |
| `HEALTH_PORT` | `9101` | `9101` | health + metrics |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://tempo:4317` | | traces |
| `RUNTIME_ROLLUP_ENABLED`, `RUNTIME_PROVISION_ENABLED` | `true`, `true` | `false` | gold rollups; runtime row provisioning (every 6 h) |
| `ROLLUP_SHIFT_LIMIT` | `75` | `300` | rows per shift-rollup tick (lowered 2026-09-22 to fit the 300 s deadline) |
| `ROLLUP_BACKFILL_ENABLED`, `ROLLUP_BACKFILL_INTERVAL_SECONDS`, `ROLLUP_BACKFILL_LIMIT` | `true`, `7`, `50` | `true`, `30`, `200` | backfill sweep cadence and batch |
| `OEE_AVAIL_FLOOR_ENABLED`, `OEE_CANONICAL_APQ_ENABLED` | `true`, `true` | `false` | ADR-0049 correctness: availability floor, A×P×Q reconciliation |
| `INCREMENT_SANITY_CLAMP_ENABLED`, `INCREMENT_SANITY_CLAMP_SPIKE_FRACTION` | `true`, `0.5` | `false`, `0.5` | clamp implausible counter increments |
| `COUNTERS_ONLY_AVAILABILITY_ENABLED`, `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS`, `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS` | `true`, `68,69,70,71,72`, `300` | `false`, empty, `300` | availability from counter silence for listed equipment |
| `COUNTERS_ONLY_LINE_LEAD_ENABLED`, `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` | `true`, `3,5,2000003` | `false`, empty | line-lead availability for counter-only tenants (cost scales with lines) |
| `EVENTS_DERIVER_ENABLED`, `EVENTS_WIDEROW_STATE_ENTERPRISES` | `true`, `4` | `false`, empty | derive equipment events from state |
| `CPAC_EVENT_LIVE_ENTERPRISES` | `5` | empty | count-silence event deriver writes live events for these tenants |
| `EVENTS_CLOSE_STALE_ENABLED`, `EVENTS_CLOSE_STALE_ENTERPRISES` | `true`, `3,4,5,2000003` | `false`, empty | close stale open events |
| `SHIFT_RESOLVER_ENABLED`, `SHIFT_FILL_FOLDED` | `true`, `true` | `false` | shift resolution |
| `SHIFT06_REPORT_ENABLED`/`_INTERVAL_MINUTES`, `SAP13_REPORT_ENABLED`/`_INTERVAL_MINUTES`, `SAP13_REASONS_FROM_DIM`, `BOXES13_REPORT_ENABLED`, `SYNC06_REPORT_ENABLED` | `true`/`15`, `true`/`15`, `false`, `true`, `true` | `false` | per-client report/sync jobs (customer ids 6, 13) |
| `PO_CONTROL_ENABLED`, `PO_RECALC_ENABLED`, `PO_AVAILABILITY_ENABLED` | `true` | `false` | production-order control, recalculation, availability |
| `BOXES_BRIDGE_ENABLED` | `true` | `false` | box-scan bridge |
| `UNS_REFRESH_ENABLED`, `UNS_CURRENT_METRICS_ENABLED` | `true` | `false` | UNS snapshot refresh jobs |
| `LEGACY_INGEST_ENABLED` | `true` | `true` | accept legacy envelopes |
| `BRONZE_RAW_APPEND` | `true` | `false` | append raw values to bronze |

## Data access

| Service | Variable | Staging | Meaning |
|---|---|---|---|
| `pgbouncer` | `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASSWORD`/`DB_NAME` | from `.env` | upstream DB |
| | `POOL_MODE`, `DEFAULT_POOL_SIZE`, `MAX_CLIENT_CONN` | `transaction`, `20`, `200` | pooling |
| | `AUTH_TYPE`, `SERVER_RESET_QUERY`, `SERVER_RESET_QUERY_ALWAYS` | `scram-sha-256`, `ROLLBACK`, `1` | auth and connection reset |
| | `QUERY_TIMEOUT`, `SERVER_IDLE_TIMEOUT` | `60`, `120` | seconds |
| `db-migrate` | `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_DB` | `5432`, from `.env`, `packiot_analytics` | migration target |
| `app-redis` | (command) `--maxmemory 256mb --maxmemory-policy allkeys-lru` | | cache only, no persistence |

## Legacy bridge

Detail: [Legacy bridge](../subsystems/legacy-bridge.md), [analytics-sync](../components/analytics-sync.md).

| Service | Variable | Staging | Meaning |
|---|---|---|---|
| `legacy-replicator` / `-sbx` | `REPLICATE_ENABLED` | `true` / from `REPLICATE_SBX_ENABLED` (default `false`) | master switch |
| | `LEGACY_DB_HOST`/`PORT`/`USER`/`NAME`, `LEGACY_DB_PASSWORD` | legacy `packiot40`, SELECT-only login; password from `.env` (`databaseCredentials`) | source |
| | `DEST_DB_*` | `10.10.10.89`, `packiot_analytics` | destination |
| | `SRC_ENTERPRISE`, `DST_ENTERPRISE` | `1` → `3` / `1` → `2000003` | tenant mapping |
| | `CURSOR_SOURCE` | `legacy-cpack` / `legacy-sbxcpack` | cursor + DLQ key in `ops.mirror_replay_dlq` |
| | `BACKFILL_SINCE_DAYS`, `REPLICATE_BASE_EVENTS` | `60`, `true` | initial window, replicate base events |
| | `POLL_INTERVAL_MS`, `BATCH_SIZE` | `3000`, `200` | poll cadence |
| | `HEALTH_PORT`, `HEALTHCHECK_MAX_AGE_SEC` | `9104`/`9114`, `600` | health fails if no progress in 10 min |
| | `RECONCILE_PO_ENABLED`, `RECONCILE_PO_INTERVAL_SEC`, `RECONCILE_PO_WINDOW_DAYS` | `true`, `300`, `14` | PO state reconciliation |
| | `RECONCILE_PO_ENRICH_ENABLED`, `RECONCILE_PO_ENRICH_WINDOW_DAYS` | `true`, `120` | fill PO product/client by natural key |
| | `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS` (sbx only) | `false` | remap ids for the sandbox |
| `analytics-sync` | `SHADOW_MIRROR_ENABLED` | `false` | shadow mirror off |
| | `PG_SECRET_ID`, `DB_*`, `PG_DB_NAME`, `PG_ANALYTICS_DB_NAME` | `packiot/staging/db`, `10.10.10.89`, `packiot`, `packiot_analytics` | DBs |
| | `POLL_INTERVAL_MS`, `BATCH_SIZE`, `MAX_RETRIES`, `HEALTH_PORT` | `2000`, `100`, `5`, `9103` | loop tuning |
| `mirror-worker-go` (retired) | `PROD_DB_SECRET_ID`, `STAGING_DB_SECRET_ID`, `SOURCE_NAME`, `PROD_ENTERPRISE_ID`, `STAGING_ENTERPRISE_ID`, `POLL_INTERVAL_SEC`, `BATCH_SIZE`, `PER_POST_DELAY_MS`, `STAGING_API_URL`, `HEALTH_PORT`, `SHADOW_*`, `RECONCILE_*` | `databaseCredentials`, `packiot/staging/db`, `cpack-prod-go`, `1`, `3`, … | legacy→staging replay (profile `legacy-comparator`) |

## Serving (APIs)

### edge-api

Detail: [edge-api](../components/edge-api.md). Also receives all of `.env`.

| Variable | Staging | Meaning |
|---|---|---|
| `NODE_ENV` | `production` | runtime mode |
| `NEW_RELIC_ENABLED`, `NEW_RELIC_NO_CONFIG_FILE` | `false`, `true` | APM off |
| `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_ANALYTICS_URL` | `pgbouncer`, `5432`, from `.env`, `packiot_analytics`, DSN via pgbouncer | DB |
| `REDIS_URL` | `redis://app-redis:6379/0` | cache |
| `AUTH_BEARER_ENABLED`, `EDGE_API_COGNITO_AUTH_ENABLED`, `COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `COGNITO_USER_POOL_ID`, `COGNITO_CS_ADMIN_GROUP` | `true`, `true`, staging pool, …, `cs-admin` | JWT auth; `cs-admin` group = staff |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | `true` | super-admin enterprise switch |
| `EDGE_API_ONBOARDING_ENABLED`, `EDGE_API_TEARDOWN_ENABLED` | `true`, `true` | onboarding and teardown endpoints |
| `ONBOARD_GENERATE_URL`, `ONBOARD_API_KEY` | `http://sparkplug-decoder:9105/v1/onboard/generate`, from `.env` | onboarding generator |
| `PO_STALENESS_GATE_ENABLED`, `PO_STALENESS_GATE_ENTERPRISES` | `true`, `3,4` | reject stale PO writes (409) for these tenants |
| `AWS_REGION`, `SSM_HYBRID_INSTANCE_ROLE`, `SSM_SHARED_AGENT_INSTANCE_ID`, `SSM_SHARED_AGENT_DIR` | `us-east-1`, `packiot-edge-ssm-hybrid-role`, the app host, runner checkout path | Box Ops via SSM (activation role; self-targeted shared agent) |
| `SSM_EDGE_INGEST_URL`, `SSM_EDGE_INGEST_KEY` | `https://ingest.staging.packiot.app:8449/v1/tags`, from `.env` | ingest endpoint written to boxes |
| `EDGE_SESSION_BROKER_WS_URL`, `EDGE_SESSION_BROKER_HTTP_URL`, `EDGE_SESSION_BROKER_TOKEN` | `ws://edge-session-broker:8090/shell`, `http://edge-session-broker:8091`, from `.env` | browser SSM sessions |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME` | `http://tempo:4317`, `edge-api` | traces |

### edge-session-broker

| Variable | Staging | Meaning |
|---|---|---|
| `AWS_REGION`, `BROKER_PORT`, `BROKER_TOKEN` | `us-east-1`, `8090`, from `.env` | SSM session bridge and its shared token with edge-api |

### read-api

Detail: [read-api](../components/read-api.md).

| Variable | Staging | Meaning |
|---|---|---|
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD` | `pgbouncer`, `5432`, `readapi_ro` (default), from `.env` | read-only DB login |
| `DB_NAME`, `DB_NAME_F3`, `REFDATA_FLOW` | `packiot`, `packiot_analytics`, `f3` | serve from the analytics DB |
| `HIST_GW_HOST`, `HIST_GW_PORT`, `HIST_GW_USER`, `HIST_GW_PASSWORD`, `HIST_GW_DB` | `hist-gateway`, `5432`, `historian_svc`, from `.env`, `packiot_historian` | cold reads (pool is nil-safe → 503 if unset) |
| `INTERNAL_API_KEY` | from `.env` | service-to-service key (decoder BIRTH resolver) |
| `QUERY_API_KEYS` | `key:enterprise` list (values not reproduced) | static API key → tenant map |
| `COGNITO_AUTH_ENABLED`, `COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | `true`, staging pool, …, `true` | JWT auth |
| `REDIS_CACHE_ENABLED`, `REDIS_URL` | `true`, `redis://app-redis:6379/0` | cache-aside (ADR-0035) |
| `HEALTH_PORT`, `OTEL_EXPORTER_OTLP_ENDPOINT` | `9104`, `http://alloy:4317` | HTTP port + health; traces via Alloy |

### operator-gateway, barcode-service

| Service | Variable | Staging | Meaning |
|---|---|---|---|
| `operator-gateway` | `PORT`, `TLS_CERT_FILE`, `TLS_KEY_FILE` | `8443`, host certs | TLS listener |
| | `EDGE_API_URL`, `EDGE_API_KEY`, `OPERATOR_API_KEY` | `http://edge-api:8080`, from `.env` | forwards Incoplast operator writes |
| | `INCOPLAST_ENTERPRISE_ID`, `INCOPLAST_TOPIC_PREFIX` | `4`, `INCOPLAST` | tenant scope |
| | `PG_SECRET_ID`, `CREDS_SOURCE`, `DB_*` | `packiot/staging/db`, `env`, `10.10.10.89`/`packiot_analytics` | DB |
| | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://tempo:4317` | traces |
| `barcode-service` | `DB_HOST`/`PORT`/`USER`/`PASSWORD`/`NAME` | `pgbouncer`, `packiot_analytics` | DB |
| | `HTTP_PORT` | `8446` | `/v1/scans` |
| | `COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `FIREBASE_PROJECT_ID` | staging pool, empty | JWT auth (Firebase off) |

## Frontends

| Service | Variable | Staging | Meaning |
|---|---|---|---|
| `operator` | `EDGE_API_KEY`, `REFDATA_API_KEY` | from `.env` (`OPERATOR_EDGE_API_KEY`, `OPERATOR_REFDATA_API_KEY`) | keys nginx injects on proxied calls (CPACK) |
| `operator-sbx` | same | `OPERATOR_SBX_*` | sandbox 2000003 |
| `operator-bispharma` | same | `OPERATOR_BISPHARMA_*` | Bispharma 5 |
| `barcode-app` | `EDGE_API_UPSTREAM`, `EDGE_API_KEY`, `REFDATA_UPSTREAM`, `REFDATA_API_KEY` | `http://edge-api:8080`, from `.env`, `http://read-api:9104`, from `.env` | nginx upstreams + injected sandbox keys |
| `csadmin`, `customize` | none at runtime | Cognito settings are **build args** | rebuild to change |

## Identity

Detail: [oauth2-proxy and Cognito](../components/oauth2-proxy-and-cognito.md).

| Variable (`oauth2-proxy`) | Staging | Meaning |
|---|---|---|
| `OAUTH2_PROXY_PROVIDER`, `OAUTH2_PROXY_OIDC_ISSUER_URL`, `OAUTH2_PROXY_CLIENT_ID`, `OAUTH2_PROXY_CLIENT_SECRET` | `oidc`, staging Cognito pool, oauth2-proxy app client, from `.env` | OIDC client |
| `OAUTH2_PROXY_REDIRECT_URL` | `https://auth.staging.packiot.app/oauth2/callback` | callback |
| `OAUTH2_PROXY_OIDC_GROUPS_CLAIM`, `OAUTH2_PROXY_SCOPE`, `OAUTH2_PROXY_EMAIL_DOMAINS` | `cognito:groups`, `openid email profile`, `*` | groups for tier checks |
| `OAUTH2_PROXY_COOKIE_DOMAINS`, `OAUTH2_PROXY_WHITELIST_DOMAINS`, `OAUTH2_PROXY_COOKIE_SECURE`, `OAUTH2_PROXY_COOKIE_SAMESITE`, `OAUTH2_PROXY_COOKIE_SECRET` | `.staging.packiot.app`, same, `true`, `lax`, from `.env` | SSO cookie across staging subdomains |
| `OAUTH2_PROXY_SET_XAUTHREQUEST`, `OAUTH2_PROXY_PASS_ACCESS_TOKEN`, `OAUTH2_PROXY_SKIP_PROVIDER_BUTTON`, `OAUTH2_PROXY_REVERSE_PROXY` | `true`, `false`, `true`, `true` | nginx `auth_request` mode |
| `OAUTH2_PROXY_HTTP_ADDRESS`, `OAUTH2_PROXY_UPSTREAMS` | `0.0.0.0:4180`, `static://202` | auth-only (no upstream) |
| `OAUTH2_PROXY_SESSION_STORE_TYPE`, `OAUTH2_PROXY_REDIS_CONNECTION_URL` | `redis`, `redis://app-redis:6379/1` | server-side sessions |

## Observability and tooling

Detail: [Observability](../components/observability.md).

| Service | Variable | Staging | Meaning |
|---|---|---|---|
| `grafana` | `GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD` | `admin`, from `.env` | admin login |
| | `GF_AUTH_ANONYMOUS_ENABLED`, `GF_USERS_DEFAULT_THEME`, `GF_FEATURE_TOGGLES_ENABLE` | `false`, `dark`, `publicDashboards` | UI |
| | `GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH` | `…/audience/00-overview.json` | home board |
| `postgres-exporter` | `DATA_SOURCE_NAME` | DSN to `postgres` DB on the DB host | connection |
| | `PG_EXPORTER_AUTO_DISCOVER_DATABASES`, `PG_EXPORTER_EXCLUDE_DATABASES`, `PG_EXPORTER_EXTEND_QUERY_PATH` | `true`, `template0,template1,authentik`, `/etc/pgexporter/queries.yaml` | per-DB metrics + custom queries |
| `redis-exporter` | `REDIS_ADDR` | `redis://app-redis:6379` | target |
| `cloudbeaver` | `CLOUDBEAVER_APP_*`, `CLOUDBEAVER_SYSTEM_VARIABLES_RESOLVING_ENABLED`, `CLOUDBEAVER_CORE_THEMING_THEME` | anonymous off, no custom connections, dark | locked-down web DB IDE |
| | `CLOUDBEAVER_RO_PASSWORD`, `CLOUDBEAVER_HISTRO_PASSWORD`, `CLOUDBEAVER_ADMIN_PASSWORD` | from `.env` | read-only analytics and historian logins, admin |
| `pgweb-analytics` | `DATABASE_URL` | DSN to `packiot_analytics` | fallback DB browser |
| `ollama` | `OLLAMA_KEEP_ALIVE`, `OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_NUM_PARALLEL` | `5m`, `1`, `1` | small local model for CloudBeaver |

Prometheus, Loki, Promtail, Tempo, Alloy, Alertmanager, node-exporter, blackbox-exporter and
cAdvisor take no environment variables; they are configured by command flags and mounted
files.

## Other compose files

| File / service | Key variables | Meaning |
|---|---|---|
| `compose.historian-gateway.yml` / `historian-gateway` | `POSTGRES_PASSWORD` (`HIST_GW_PASSWORD`), `POSTGRES_DB=packiot_historian`, `FDW_HOST/PORT/DB/USER/PASS`, `HISTORIAN_BUCKET`, `HIST_AWS_KEY`, `HIST_AWS_SECRET`, `CLOUDBEAVER_HISTRO_PASSWORD`, `HISTGW_RO_PASS`, `HIST_GW_SVC_PASSWORD` | gateway superuser, hot FDW source, cold S3 bucket + scoped key, least-privilege roles — see [historian gateway](../components/historian-gateway.md) |
| `compose.superset.yml` | `SUPERSET_SECRET_KEY`, `SUPERSET_GUEST_TOKEN_JWT_SECRET`, `SUPERSET_DB_PASSWORD`, `POSTGRES_HOST_UPSTREAM`, `SUPERSET_COGNITO_*`, `SUPERSET_ADMIN_*`, `SUPERSET_FRAME_ANCESTOR`, `SUPERSET_OEE_DASHBOARD_UUID`, `SUPERSET_EMBED_TARGET_DASHBOARD`, `SUPERSET_REDIS_HOST` | Superset secrets, metadata DB, OIDC, embed origin and dashboard |
| `compose.onprem-edge.yml` (`.env.onprem`) | `TENANT`, `AGENT_INGEST_API_KEY`, `DASHBOARD_PORT` | on-prem box identity, local ingest key, dashboard port |
