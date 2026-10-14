---
title: Configuration reference
layer: 4
owner_area: platform
last_verified: 2026-10-13
---
# Configuration reference

> **Layer 4 · Reference** — every environment variable set in `compose.staging.yml`, grouped
> by service, with its code default, its staging value (secrets shown only as "from `.env`")
> and a one-line meaning, plus the important flags that code reads but compose leaves at the
> default. For looking up a knob; follow the links for how it behaves.
> Up: [Platform & operations](../understand/subsystems/platform.md) · Detail: [Compose topology](../understand/components/compose-topology.md)

How values arrive: `${VAR}` is substituted from `/opt/packiot/.env` (the deploy symlinks it as
`.env` in the runner checkout); services with `env_file: [.env]` also receive **every** key in
that file, so a key in `.env` can set a flag that compose does not mention. "from `.env`" means
the value is a secret or host-specific and lives only there (sourced from Secrets Manager, see
[Platform § secrets](../understand/subsystems/platform.md#secrets-path)). "Default" is the code
default, verified in source; "—" means no default (empty). "not set" means compose does not set
it, so staging runs the default unless `.env` overrides it. Changing a value takes a recreate:
[runbooks](../build/operate/runbooks.md#recreate-a-single-service).

Everything on this page is **staging** (the new stack). Production clients still run the
legacy platform; the new-stack production compose is summarised at the end.

Some behaviour that looks like configuration is **not** an env var. A client's OEE settings
(availability mode, ideal-speed source, per-line overrides) and calculation rules live in the
analytics DB (`client_descriptors.descriptor`), are edited in the customize app, and are read
by stream-engine and the shared agent **at start-up**. "Apply now" in customize asks edge-api
to recreate that container over SSM (see [edge-api](#edge-api), `SSM_OEE_ENGINE_SERVICE`,
`SSM_SHARED_AGENT_SERVICE`). See [OEE settings](../use/customize/oee-settings.md).

## Host-level keys in `/opt/packiot/.env`

| Key | Meaning |
|---|---|
| `COMPOSE_PROFILES` | profile-gated services to start (`superset`, `cpack-tee`, …). The staging deploy always adds `shared-tee`, and adds `alerting` when the Slack webhook file exists (see [Alerting](#alerting-and-data-invariants)) |
| `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | analytics DB host/login; `POSTGRES_DB` is the legacy `packiot` name, most services override to `packiot_analytics` |
| `POSTGRES_HOST_UPSTREAM` | DB host for direct (non-pgbouncer) DDL, used by the Superset overlay; also the decoder's OEE-profile fallback host |
| `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | broker admin (also rendered into RabbitMQ definitions) |
| `ALLOY_GATEWAY_BIND` | private IP for Alloy relays 3101/3102 (self-healed by deploy) |
| `HIST_GW_SVC_PASSWORD` | `historian_svc` login to the historian gateway (self-healed by deploy from Secrets Manager `packiot/staging/historian-svc`) |
| `INTERNAL_API_KEY`, `ONBOARD_API_KEY`, `INGEST_API_KEY`, `AGENT_INGEST_API_KEY`, `EDGE_SESSION_BROKER_TOKEN`, `LEGACY_DB_PASSWORD`, `READAPI_RO_PASSWORD` | service-to-service keys and logins referenced below |
| `OPERATOR_*_EDGE_API_KEY`, `OPERATOR_*_REFDATA_API_KEY`, `BARCODE_EDGE_API_KEY`, `BARCODE_REFDATA_API_KEY` | keys the frontend nginx containers inject |
| `GRAFANA_ADMIN_PASSWORD`, `OAUTH2_PROXY_CLIENT_SECRET`, `OAUTH2_PROXY_COOKIE_SECRET`, `CLOUDBEAVER_*_PASSWORD`, `SUPERSET_*` | per-service secrets |

## Edge ingress and decoding

Detail: [Ingestion](../understand/subsystems/ingestion.md), [Edge](../understand/subsystems/edge.md),
[sparkplug-decoder](../understand/components/sparkplug-decoder.md).

### sparkplug-decoder

| Variable | Default | Staging | Meaning |
|---|---|---|---|
| `LOG_LEVEL` | `info` | `info` | log verbosity |
| `EDGE_TRANSFORMER_MODE` | `factory` | `factory` | decoder run mode |
| `PHASE9_LINE_AGG_ENABLED` | off | `true` | publish line-aggregated metrics and seed line parameter 30700 from `POSTGRES_URL` (only where no other writer produces line counts) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_TRACES_SAMPLER_ARG` | — | `http://tempo:4317` / `0.1` | traces to Tempo, 10% sampled |
| `AWS_REGION`, `RABBITMQ_SECRET_ID` | `us-east-1`, `packiot/staging/rabbitmq-edge-transformer-creds` | `us-east-1`, `packiot/staging/rabbitmq-sparkplug-decoder-creds` | where AMQP creds come from |
| `RABBITMQ_HOST` / `RABBITMQ_PORT` | `rabbitmq` / `5672` | same | broker |
| `SOURCE_EXCHANGE`, `WORKER_QUEUE`, `RETRY_EXCHANGE`, `RETRY_QUEUE`, `FAILED_EXCHANGE`, `FAILED_QUEUE` | `plc.normalized`, `edge-transformer-q`, `plc.normalized-retry`, `edge-transformer-q-retry-30s`, `plc.normalized-failed`, `edge-transformer-q-failed` | `edge.plc-normalized`, `edge-transformer-q`, `edge.plc-normalized-retry`, `edge-transformer-q-retry-30s`, `dlx.edge.plc-normalized`, `edge-transformer-q-failed` | AMQP source path (disabled, see `AMQP_SOURCE_ENABLED`) |
| `RETRY_TTL_MS`, `MAX_RETRIES`, `PREFETCH` | `30000`, `5`, `50` | same | retry delay, attempts, consumer prefetch |
| `HEALTH_PORT` | `9102` | `9102` | health + `/metrics` |
| `CLIENT_YAML_PATH` | `/etc/packiot/client.yaml` | same | tenant config (mounted `docs/clients/cpack.yaml`) |
| `BIRTH_BOUND_RESOLVER`, `REFDATA_URL`, `REFDATA_INTERNAL_KEY` | `map`, —, — | `refdata`, `http://read-api:9104`, `INTERNAL_API_KEY` from `.env` | how birth-bound device keys are resolved (through read-api); only consulted when `BIRTH_BOUND_ROUTING` is on |
| `BIRTH_BOUND_ROUTING` | `false` | not set | ADR-0061 device keys: bind births by declared device key and stamp `id_equipment` on envelopes. Off on staging per compose |
| `MQTT_ENABLED`, `MQTT_BROKER_URL`, `MQTT_CLIENT_ID`, `MQTT_USERNAME`, `MQTT_PASSWORD` | `false`, `tcp://mosquitto:1883`, `edge-transformer`, empty, empty | `true`, same, `edge-transformer-staging`, empty, empty | MQTT ingest (the primary path) |
| `MQTT_STALE_THRESHOLD_SECONDS` | `60` | `-1` | stale-connection watchdog off |
| `AMQP_SOURCE_ENABLED` | `true` | `false` | legacy AMQP input off |
| `USE_GO_PORT` | `false` | `true` | run the Go Calc (production-counter) port |
| `ONBOARD_API_ENABLED`, `ONBOARD_API_PORT`, `ONBOARD_API_KEY` | off, `9105`, — | `true`, `9105`, from `.env` | onboarding generator API called by edge-api |
| `OUTBOX_ENABLED`, `OUTBOX_PATH`, `OUTBOX_CAP` | `false`, `/var/lib/edge-transformer/outbox.db`, `100000` | `true`, same, same | store-and-forward SQLite outbox |
| `CALC_STATE_DURABLE` | `true` | not set | checkpoint Calc baselines in the outbox so a restart does not lose one reading's delta per counter (needs the outbox) |
| `CALC_RESET_HEAL_ENABLED` | `true` | not set | on a counter reset or rebirth, re-seed the baseline instead of emitting the whole totalizer |
| `SHADOW_EMIT_REFACTORED`, `SHADOW_EMIT_GO`, `SHADOW_EMIT_PRODUCTION` | off, **on** (unless `false`), off | `true`, `false`, `false` | which envelope legs are published (only `refactored`) |
| `CALC_CUTOVER_REFACTORED`, `CALC_NO_SPEED_GUARD_FALLBACK` | off, `false` | `true`, `true` | `refactored` envelopes carry Calc deltas; machines without a speed signal are not rejected by the 3×speed guard |
| `CALC_COUNTER_SPIKE_MARGIN` | `0` | `0` | **retired 2026-09-30.** The decoder spike clamp is off (`0` = inert) and the OEE settings page no longer sets a per-client margin. Phantom increments are rejected by stream-engine instead (`INCREMENT_SANITY_CLAMP_*`) |
| `F3_PER_TENANT_ROUTING` | off | `true` | route to `sparkplug.data.<tenant>` keys |
| `POSTGRES_DB`, `POSTGRES_URL` | `packiot`, — | `packiot_analytics`, DSN built from `.env` values | direct DB access (bypasses pgbouncer) |
| `COUNTERS_ONLY_OEE_ENABLED`, `COUNTERS_ONLY_IDEAL_RATES` | `false`, — | `true`, JSON map topic→rate | OEE for counter-only lines and their ideal rates |
| `COUNTERS_ONLY_FROM_DB` | `false` | not set | read rated speeds from the DB instead of the JSON map |
| `OEE_PROFILE_FROM_DB` | `false` | `true` | read each client's OEE profile from `client_descriptors` (refreshed every `OEE_PROFILE_REFRESH_SECONDS`, default 300) |
| `EDGE_COMMANDS_ENABLED`, `EDGE_COMMANDS_ALLOWED` | `false`, `po_setup,param_write` | `false`, same | cloud→edge commands (off) |

### sparkplug-agent-cpack / sparkplug-agent-shared

Detail: [sparkplug-agent](../understand/components/sparkplug-agent.md).

| Variable | Default | Staging | Meaning |
|---|---|---|---|
| `AGENT_CONFIG` (cpack) | — | `/etc/packiot/agent.yaml` | single-tenant agent config |
| `AGENT_TENANTS_DIR`, `AGENT_TENANTS_PROFILE_DIR` (shared) | — | `/etc/packiot/tenants`, `/etc/packiot/tenant-profiles` | per-tenant configs and conversion profiles |
| `HEALTH_PORT` | `9103` | `9103` | health (the shared agent is scraped by Prometheus on it) |
| `AGENT_HTTP_INGEST_ENABLED`, `AGENT_INGEST_PORT`, `AGENT_INGEST_API_KEY` | `false`, `9104`, — | `true`, `9104`, from `.env` | HTTPS `/v1/tags` ingest behind nginx |
| `OUTBOX_PATH` (cpack) / `AGENT_OUTBOX_DIR` (shared) | `/var/lib/edge-transformer/agent-outbox.db` / `/var/lib/edge-transformer/outbox` | same | durability |
| `AGENT_BIRTH_ALL_MAPPED` | `true` | `true` | NBIRTH declares every mapped metric |
| `AGENT_MULTI_DERIVE_ENABLED` (shared) | `true` | not set | apply each tenant's saved calculation rules (kill switch) |
| `AGENT_CAPTURE_ENABLED` (shared) | `false` | `true` | record observed tags for tenants in capture posture (onboarding) |
| `AGENT_REGISTER_DSN` (shared) | — | from `.env` | DB DSN for register-driven tag maps, tenant status and capture |
| `AGENT_TAGMAP_FROM_REGISTER` | `false` | not set | force every tenant to the register-built tag map (otherwise per tenant, from `client_descriptors.status`) |
| `EMIT_DEFINITIVE_BIRTH` | `false` | not set | NBIRTH counter metrics carry role-typed properties (needed before ADR-0061 binding can bind anything) |
| `MQTT_STALE_THRESHOLD_SECONDS` | `60` | `-1` | watchdog off |

### ingest-shim

| Variable | Default | Staging | Meaning |
|---|---|---|---|
| `RABBITMQ_SECRET_ID`, `EXCHANGE`, `ROUTING_KEY` | `…/rabbitmq-oeecloud-creds`, `oee`, `sparkplug.data` | decoder creds, `oee`, `sparkplug.data.incoplast` | publish target |
| `FANOUT_SOURCE_TYPES`, `SCOPE_GROUP` | `legacy,go,refactored`, — | `refactored`, `INCOPLAST` | envelope types and allowed group |
| `HTTP_ADDR`, `METRICS_ADDR` | `:8444`, `:9105` | same | HTTPS ingest and metrics |
| `INGEST_API_KEY`, `TLS_CERT_FILE`, `TLS_KEY_FILE` | — | from `.env`, `/certs/*` | auth and TLS |
| `CONFIRM_TIMEOUT_MS`, `MAX_BODY_BYTES` | `5000`, 1 MiB | not set | publisher confirm wait, request size cap |

### oeecloud-fanout

Copies CPACK traffic to the sandbox twin SBXCPACK (enterprise 2000003).

| Variable | Default | Staging | Meaning |
|---|---|---|---|
| `FANOUT_ENABLED` / `FANOUT_CPACK_TO_SBXCPACK_ENABLED` | `false` | from `.env`, compose default `false` | master switch (`FANOUT_ENABLED` wins if set) |
| `FANOUT_QUEUE`, `FANOUT_SOURCE_GROUP`, `FANOUT_TARGET_GROUP` | `oeecloud-fanout-cpack-to-sbxcpack`, `CPACK`, `SBXCPACK` | same | copy CPACK → sandbox |
| `FANOUT_SOURCE_ROUTING_KEYS`, `FANOUT_TARGET_ROUTING_KEY` | —, `sparkplug.data.<target group>` | `sparkplug.data,sparkplug.data.cpack`, `sparkplug.data.sbxcpack` | keys read / written |
| `PREFETCH`, `PUBLISH_CONFIRM_TIMEOUT_MS`, `HEALTH_PORT` | `50`, `5000`, `9102` | same | consumer tuning, health |

### Simulators and twins

Detail: [Simulators and twins](../understand/components/simulators-and-twins.md). Values in
parentheses are the compose values; most come from `BISPHARMA_*` keys in `.env`.

| Service | Variables (staging) | Meaning |
|---|---|---|
| `bispharma-twin` | `BISPHARMA_TWIN_ENABLED` (`false` unless `.env` sets it), `TWIN_BROKER` (`tcp://mosquitto:1883`), `TWIN_GROUP=BISPHARMASTAGING`, `TWIN_EDGE_NODE=bispharmastaging-twin`, `TWIN_TENANT_CONFIG=/etc/packiot/tenants/bispharma.yaml`, `TWIN_LINE` (`ALL`; code default `L01`), `TWIN_INTERVAL_SEC` (15), `TWIN_RATE_PER_MIN` (50; code default 600), `TWIN_SCRAP_RATE` (0.03), `TWIN_STOP_PROB` (0.03), `TWIN_STOP_MIN_SEC`/`MAX_SEC` (120/600), `TWIN_STATE_FILE` (`/var/lib/bispharma-twin/totalizers.json`) | synthetic Bispharma producer and its per-line stop simulation |
| `bispharma-box-scan-mock` | `BISPHARMA_BOX_SCAN_MOCK_ENABLED` (`false`), `MOCK_INTERVAL_SEC` (30), `PGHOST=pgbouncer`, `PGDATABASE=packiot_analytics` | appends mock box scans |
| `plc-sim` | `MQTT_BROKER_URL`, `PLC_SIM_TICK_SEC=5` | synthetic PLC (profile `plc-sim`) |
| `s7-softplc` / `s7-reader` | `LISTEN_ADDR=:102`, `S7_DB=100`, `SOFTPLC_TICK_SEC=5` / `S7_HOST`, `S7_RACK=0`, `S7_SLOT=2`, `S7_GROUP=INCOPLAST`, `S7_EDGE_NODE`, `S7_TICK_SEC=5` | S7 test pair (profile `s7`) |
| `simulator` | `EDGE_NODERED_URL`, `EDGE_API_URL`, `DB_URL`, `SIM_INTERVAL=5`, `OP_INTERVAL=15`, `SIM_SKIP_ENTERPRISE_IDS=3,4` | legacy simulator (profile `legacy-sim`) |
| `edge-nodered` | `RABBITMQ_*`, `ID_PUBSUB_NODE`, `HASURA_URL`, `HASURA_ADMIN_SECRET`, `API_KEY`, `EDGE_API_BASE_URL`, `ID_ENTERPRISE=3` | retired Node-RED edge (profile `legacy-sim`) |

The sandbox twin (2000003) is also shaped by `legacy-replicator-sbx` (`SANDBOX_HOLD_ENABLED`,
[Legacy bridge](#legacy-bridge)) and by edge-api (`SSM_SANDBOX_ENTERPRISE_IDS`,
`OPERATOR_WRITE_BLOCK_SANDBOX_ENTERPRISE`).

### rabbitmq / mosquitto

| Service | Variable | Meaning |
|---|---|---|
| `rabbitmq` | `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` (from `.env`) | ignored once `load_definitions` imports users |
| `mosquitto` | none | config in `configs/mosquitto/mosquitto.conf` |

## Compute

### stream-engine

Detail: [stream-engine](../understand/components/stream-engine.md), [Compute](../understand/subsystems/compute.md).
The OEE rollup worker (binary `oeecloud-worker`). Per-client OEE settings come from the DB at
start-up and are **added** to the env lists below (env is the floor).

| Variable | Staging | Default | Meaning |
|---|---|---|---|
| `LOG_LEVEL` | `info` | `info` | log verbosity |
| `AWS_REGION`, `PG_SECRET_ID`, `CREDS_SOURCE` | `us-east-1`, `${STREAM_ENGINE_PG_SECRET_ID:-packiot/staging/stream-engine-db-creds}`, — | `us-east-1`, none (boot error), — | DB login as the least-privilege `stream_engine` role from Secrets Manager; no `env_file` (engine keys from `.env` passed through explicitly). [Provisioning](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/stream-engine/README.md#provisioning-the-db-role) |
| `AMQP_CREDS_SOURCE` | `aws` | follows `CREDS_SOURCE` | AMQP creds from `RABBITMQ_SECRET_ID` (least-privilege `stream-engine`), not the admin in `.env` |
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` | not set (in the secret: `10.10.10.89`, `5432`, `stream_engine`, —, `packiot_analytics`) | `postgres`, `5432`, —, —, `packiot` | direct DB connection (not pgbouncer); never the admin `POSTGRES_*` (CI `check-db-least-priv.py`) |
| `POSTGRES_ANALYTICS_DB_NAME` | `packiot_analytics` | empty | analytics DB name |
| `POSTGRES_MAX_CONNS`, `POSTGRES_ANALYTICS_MAX_CONNS` | `5`, `15` | same | pool sizes |
| `RABBITMQ_SECRET_ID`, `RABBITMQ_HOST`, `RABBITMQ_PORT` | `…/rabbitmq-stream-engine-creds`, `rabbitmq`, `5672` | same | broker |
| `SOURCE_EXCHANGE`, `WORKER_QUEUE`, `RETRY_*`, `FAILED_*`, `RETRY_TTL_MS`, `MAX_RETRIES` | `oee`, `stream-engine-q`, 30 s retry, `-failed` DLQ, `30000`, `5` | same | queue topology |
| `WORKER_TENANT_ALLOWLIST` | `cpack,sbxcpack,bispharmastaging,incoplast` (compose default; `.env` may override) | empty = all | tenants that get a consumer queue set (lowercased Sparkplug group) |
| `PREFETCH`, `CONSUME_LANES` | `50`, `4` | `50`, `1` | consumer prefetch and parallel lanes |
| `TENANT_DISCOVERY_INTERVAL_SECONDS` | `60` | `60` | how often tenants are re-discovered |
| `WORKER_POOL_SAC_ENABLED` | `false` | `false` | single-active-consumer worker pool |
| `HEALTH_PORT` | `9101` | `9101` | health + metrics |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://tempo:4317` | — | traces |
| `RUNTIME_ROLLUP_ENABLED`, `RUNTIME_PROVISION_ENABLED` | `true`, `true` | `false` | gold rollups; runtime row provisioning (every `RUNTIME_PROVISION_INTERVAL_HOURS`, default 6) |
| `ROLLUP_SHIFT_LIMIT` | `75` | `300` | rows per shift-rollup tick (lowered 2026-09-22 to fit the 300 s deadline) |
| `ROLLUP_BACKFILL_ENABLED`, `ROLLUP_BACKFILL_INTERVAL_SECONDS`, `ROLLUP_BACKFILL_LIMIT` | `true`, `7`, `50` | `true`, `30`, `200` | backfill sweep cadence and batch |
| `OEE_AVAIL_FLOOR_ENABLED`, `OEE_CANONICAL_APQ_ENABLED` | `true`, `true` | `false` | ADR-0049 correctness: availability floor; `oee = A × P × Q` with Performance computed directly |
| `SILVER_CLAMP_ENABLED` | not set | `true` | Silver invariant pass on served rows: negatives floored to 0, Availability kept in [0, 1]. Performance, Quality and OEE above 1 and net > gross are **kept as measured** (since 2026-09-29) and only detected |
| `DQ_ALARMS_ENABLED` | not set | `true` | record data-quality events (oee > 1, net > gross, negatives…) without changing values |
| `INCREMENT_SANITY_CLAMP_ENABLED`, `INCREMENT_SANITY_CLAMP_SPIKE_FRACTION` | `true`, `0.5` | `false`, `0.5` | reject impossible counter increments (written as 0 and recorded as a data-quality event); also `_K` (4), `_MIN_DT_SECONDS` (60), `_SPIKE_FLOOR` (1000) |
| `AVAILABILITY_EXCLUSIONS_ENABLED` | not set | `true` | subtract out-of-service windows and PLC no-data time from available time (inert without windows or no-data events) |
| `STRANDED_FLAG_SWEEP_ENABLED` | not set | `true` | hourly job clearing `recalc_needed` flags nothing can drain, with a WARN per table |
| `CHANGEOVER_AVAILABILITY_ENABLED` | not set | `false` | count changeover as an availability loss instead of planned time |
| `COUNTERS_ONLY_AVAILABILITY_ENABLED`, `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS`, `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS` | `true`, `68,69,70,71,72`, `300` | `false`, empty, `300` | availability from counter silence for listed equipment |
| `COUNTERS_ONLY_LINE_LEAD_ENABLED`, `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` | `true`, `3,5,2000003` | `false`, empty | line-lead availability for counter-only tenants; a client's OEE settings can add its enterprise and opt single lines in or out (cost scales with lines) |
| `PROVISIONAL_SPEED_INFERENCE_ENABLED`, `PROVISIONAL_SPEED_EQUIPMENTS` | not set | `false`, empty | infer an ideal speed from history for lines without a nameplate |
| `EVENTS_DERIVER_ENABLED`, `EVENTS_WIDEROW_STATE_ENTERPRISES` | `true`, `4` | `false`, empty | derive equipment events from state |
| `CPAC_EVENT_LIVE_ENTERPRISES` | `5` | empty | count-silence event deriver writes live events for these tenants |
| `CPAC_EVENT_DERIVATION_ENABLED`, `CPAC_EVENT_ENTERPRISES` | not set | `false`, empty | same deriver into a shadow comparison table |
| `EVENTS_CLOSE_STALE_ENABLED`, `EVENTS_CLOSE_STALE_ENTERPRISES` | `true`, `3,4,5,2000003` | `false`, empty | close stale open events (tuning: `_INTERVAL_SEC` 60, `_HORIZON_HOURS` 72, `_LONG_HORIZON_DAYS` 60, `_THRESHOLD_DEFAULT_SEC` 300) |
| `SHIFT_RESOLVER_ENABLED`, `SHIFT_FILL_FOLDED` | `true`, `true` | `false` | shift resolution |
| `SHIFT06_REPORT_ENABLED`/`_INTERVAL_MINUTES`, `SAP13_REPORT_ENABLED`/`_INTERVAL_MINUTES`, `SAP13_REASONS_FROM_DIM`, `BOXES13_REPORT_ENABLED`, `SYNC06_REPORT_ENABLED` | `true`/`15`, `true`/`15`, `false`, `true`, `true` | `false` (intervals `15`; boxes `5`) | per-client report/sync jobs (customer ids 6, 13) |
| `PO_CONTROL_ENABLED`, `PO_RECALC_ENABLED`, `PO_AVAILABILITY_ENABLED` | `true` | `false` | production-order control, recalculation, availability |
| `PO_RECOMPUTE_SWEEP_HOURS`, `PO_RECALC_WINDOW`, `PO_RECALC_EXCLUDED_ENTERPRISES` | not set | `24`, `1 month`, `6` | re-flag every closed PO run once per period inside the window |
| `ROLLUP_MACHINE_LEVEL_ENTERPRISES` | not set | `6` | enterprises whose machines join the shift grain |
| `BIRTHBIND_VERIFY`, `BIRTHBOUND_SWITCHED_ENTERPRISES` | not set | `true`, empty | ADR-0061: count-only verification of birth-bound ids; tenants listed resolve counters by the decoder's stamped id |
| `BOXES_BRIDGE_ENABLED` | `true` | `false` | box-scan bridge |
| `UNS_REFRESH_ENABLED`, `UNS_CURRENT_METRICS_ENABLED` | `true` | `false` | UNS snapshot refresh jobs |
| `LEGACY_INGEST_ENABLED` | `true` | `true` | accept legacy envelopes |
| `BRONZE_RAW_APPEND` | `true` | `false` | append raw values to bronze |
| `COUNTER_TOTALS_PUBLIC` | not set | `false` | also write exact float8 `*_total` counter columns on the public route |

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

Detail: [Legacy bridge](../understand/subsystems/legacy-bridge.md), [analytics-sync](../understand/components/analytics-sync.md).

| Service | Variable | Staging | Meaning |
|---|---|---|---|
| `legacy-replicator` / `-sbx` | `REPLICATE_ENABLED` | `true` / from `REPLICATE_SBX_ENABLED` (compose default `false`); code default `false` | master switch |
| | `LEGACY_DB_HOST`/`PORT`/`USER`/`NAME`, `LEGACY_DB_PASSWORD` | legacy `packiot40`, SELECT-only login; password from `.env` (`databaseCredentials`) | source |
| | `PG_SECRET_ID`, `AWS_REGION` | `${LEGACY_REPLICATOR_PG_SECRET_ID:-packiot/staging/legacy-replicator-db-creds}`, `us-east-1` (no `env_file`; `DEST_DB_*` and `CREDS_SOURCE` not set) | destination login as the least-privilege `legacy_replicator` role (`10.10.10.89`, `packiot_analytics`); each connection stamps `app.tenant_id = DST_ENTERPRISE` |
| | `SRC_ENTERPRISE`, `DST_ENTERPRISE` | `1` → `3` / `1` → `2000003` | tenant mapping |
| | `CURSOR_SOURCE` | `legacy-cpack` / `legacy-sbxcpack` | cursor + DLQ key in `ops.mirror_replay_dlq` |
| | `BACKFILL_SINCE_DAYS`, `REPLICATE_BASE_EVENTS` | `60`, `true` | initial window, replicate base events |
| | `POLL_INTERVAL_MS`, `BATCH_SIZE` | `3000`, `200` | poll cadence |
| | `HEALTH_PORT`, `HEALTHCHECK_MAX_AGE_SEC` | `9104`/`9114`, `600` (code default `0` = off) | health fails if no progress in 10 min |
| | `RECONCILE_PO_ENABLED`, `RECONCILE_PO_INTERVAL_SEC`, `RECONCILE_PO_WINDOW_DAYS` | `true`, `300`, `14` (code default off) | converge PO headers and runtime windows on legacy |
| | `RECONCILE_PO_ENRICH_ENABLED`, `RECONCILE_PO_ENRICH_WINDOW_DAYS` | `true`, `120` (code default off, `14`) | fill PO product/client by natural key |
| | `RECONCILE_PO_ENRICH_KEEP_LEGACY_IDS` | not set on main (code default `true`) / `false` on sbx | keep legacy ids, or remap them for the sandbox |
| | `RECONCILE_BASE_EVENTS_ENABLED`, `_INTERVAL_SEC`, `_LOOKBACK_HOURS` | `true`, `120`, `96` (code default off, `120`, `72`) | reconcile base PLC events from legacy `equipment_events` |
| | `RECONCILE_MANUAL_EVENTS_ENABLED`, `_INTERVAL_SEC`, `_LOOKBACK_DAYS`, `_MAX_DELETES`, `_REFRESH_SERVING` | `true`, `300`, `35`, `50`, `true` (code default off) | reconcile manual downtime events from legacy |
| | `SANDBOX_HOLD_ENABLED` (sbx only) | `true` (code default `false`) | sandbox grace hold: a hands-on session pauses replication, then the twin self-heals to CPACK |
| | `DLQ_CAPTURE_ENABLED`, `DLQ_RETRY_ENABLED` | not set (code default `true`) | capture failed rows and retry them |
| `analytics-sync` | `SHADOW_MIRROR_ENABLED` | `false` | shadow mirror off |
| | `DB_*`, `PG_DB_NAME`, `PG_ANALYTICS_DB_NAME` | not set: idle, no DB connection, no `env_file` (CI `check-db-least-priv.py` NO_DB) | enabled mode only: needs `DB_USER` + `DB_PASSWORD` of its own role |
| | `POLL_INTERVAL_MS`, `BATCH_SIZE`, `MAX_RETRIES`, `HEALTH_PORT` | `2000`, `100`, `5`, `9103` | loop tuning |
| `mirror-worker-go` (retired) | `PROD_DB_SECRET_ID`, `STAGING_DB_SECRET_ID`, `SOURCE_NAME`, `PROD_ENTERPRISE_ID`, `STAGING_ENTERPRISE_ID`, `POLL_INTERVAL_SEC`, `BATCH_SIZE`, `PER_POST_DELAY_MS`, `STAGING_API_URL`, `HEALTH_PORT`, `SHADOW_*`, `RECONCILE_*` | `databaseCredentials`, `packiot/staging/db`, `cpack-prod-go`, `1`, `3`, … | legacy→staging replay (profile `legacy-comparator`) |

## Serving (APIs)

### edge-api

Detail: [edge-api](../understand/components/edge-api.md). Also receives all of `.env`.

| Variable | Default | Staging | Meaning |
|---|---|---|---|
| `NODE_ENV` | — | `production` | runtime mode (read by Node libraries, not by edge-api code) |
| `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_ANALYTICS_URL` | — | `pgbouncer`, `5432`, from `.env`, `packiot_analytics`, DSN via pgbouncer | DB |
| `AUTH_BEARER_ENABLED`, `EDGE_API_COGNITO_AUTH_ENABLED`, `COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `COGNITO_USER_POOL_ID`, `COGNITO_CS_ADMIN_GROUP` | off, off, —, —, —, `cs-admin` | `true`, `true`, staging pool, …, `cs-admin` | JWT auth; `cs-admin` group = staff |
| `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | off | `true` | super-admin enterprise switch (`OPERATOR_SUPERADMIN_ALLOWLIST` limits who) |
| `EDGE_API_ONBOARDING_ENABLED`, `EDGE_API_TEARDOWN_ENABLED` | off | `true`, `true` | onboarding and teardown endpoints (`TEARDOWN_PROTECTED_ENTERPRISES` adds to the built-in deny list) |
| `ONBOARD_GENERATE_URL`, `ONBOARD_API_KEY` | —, — | `http://sparkplug-decoder:9105/v1/onboard/generate`, from `.env` | onboarding generator |
| `PO_STALENESS_GATE_ENABLED`, `PO_STALENESS_GATE_ENTERPRISES` | `false`, empty | `true`, `3,4` | reject stale PO writes (409) for these tenants |
| `OPERATOR_WRITE_BLOCKED_ENTERPRISES`, `OPERATOR_WRITE_BLOCK_SANDBOX_ENTERPRISE` | empty (off) | `3`, `2000003` | reject PO, downtime and shift writes (403) on the CPACK mirror tenant; the message points to the sandbox twin. Staging only |
| `AWS_REGION`, `SSM_HYBRID_INSTANCE_ROLE` | — | `us-east-1`, `packiot-edge-ssm-hybrid-role` | Box Ops via SSM (activation role) |
| `SSM_SHARED_AGENT_INSTANCE_ID`, `SSM_SHARED_AGENT_DIR` | empty (ops return 503), `/opt/packiot-stack` | the app host, runner checkout path | which host and checkout "Apply now" runs `docker compose` on |
| `SSM_SHARED_AGENT_SERVICE`, `SSM_SHARED_AGENT_PROFILE`, `SSM_SHARED_AGENT_COMPOSE_PROJECT`, `SSM_SHARED_AGENT_COMPOSE_FILE`, `SSM_SHARED_AGENT_TENANTS_DIR` | `sparkplug-agent-shared`, `shared-tee`, `stack`, `compose.staging.yml`, `<dir>/docs/clients/tenants` | not set | apply calculation rules = recreate the shared agent |
| `SSM_OEE_ENGINE_SERVICE` | `stream-engine` | not set | apply OEE settings = recreate this service |
| `SSM_SANDBOX_ENTERPRISE_IDS` | `2000003` | not set | tenants whose mutating box ops are mocked (any id ≥ 2,000,000 is treated as a twin anyway) |
| `SSM_EDGE_INGEST_URL`, `SSM_EDGE_INGEST_KEY` | `https://ingest.prod.packiot.app:8449/v1/tags`, empty | `https://ingest.staging.packiot.app:8449/v1/tags`, `INGEST_API_KEY` from `.env` | ingest endpoint written to boxes |
| `EDGE_SESSION_BROKER_WS_URL`, `EDGE_SESSION_BROKER_HTTP_URL`, `EDGE_SESSION_BROKER_TOKEN` | — | `ws://edge-session-broker:8090/shell`, `http://edge-session-broker:8091`, from `.env` (compose has a fallback) | browser SSM sessions |
| `EDGE_API_PROMOTE_ENABLED`, `EDGE_API_PROMOTE_APPLY_ENABLED` | off | not set | staging→production promote endpoints (404 while off) |
| `COMMANDS_ENABLED` | `false` | not set | cloud→edge command producer |
| `CORS_ALLOWED_ORIGINS` | built-in list | not set | browser origins allowed |
| `SUPERSET_BASE_URL`, `SUPERSET_GUESTTOKEN_ADMIN_USER`, `SUPERSET_GUESTTOKEN_ADMIN_PASSWORD`, `SUPERSET_OEE_DASHBOARD_UUID` | — | from `.env` if set | Superset embed broker; any missing → `/api/superset/*` returns 503 |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME` | — | `http://tempo:4317`, `edge-api` | traces |

Compose also sets `NEW_RELIC_ENABLED=false`, `NEW_RELIC_NO_CONFIG_FILE=true` and `REDIS_URL` on
edge-api; edge-api code does not read them (no New Relic agent, no Redis client).

### edge-session-broker

| Variable | Default | Staging | Meaning |
|---|---|---|---|
| `AWS_REGION`, `BROKER_PORT`, `BROKER_HTTP_PORT`, `BROKER_TOKEN` | `us-east-1`, `8090`, `8091`, empty | `us-east-1`, `8090`, not set, from `.env` | SSM session bridge and its shared token with edge-api |

### read-api

Detail: [read-api](../understand/components/read-api.md).

| Variable | Default | Staging | Meaning |
|---|---|---|---|
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD` | `pgbouncer`, `5432`, `postgres`, — | `pgbouncer`, `5432`, `READAPI_RO_USER` (compose default `readapi_ro`), `READAPI_RO_PASSWORD` from `.env` | read-only DB login |
| `DB_NAME`, `DB_NAME_F3`, `REFDATA_FLOW` | `packiot`, `packiot_analytics`, — | `packiot`, `packiot_analytics`, `f3` | serve from the analytics DB |
| `HIST_GW_HOST`, `HIST_GW_PORT`, `HIST_GW_USER`, `HIST_GW_PASSWORD`, `HIST_GW_DB` | `hist-gateway`, `5432`, `historian_svc`, —, `packiot_historian` | same; password `HIST_GW_SVC_PASSWORD` from `.env` | cold reads as the least-privilege `historian_svc` login (pool is nil-safe → 503 if unset). Not the same secret as the gateway's own superuser `HIST_GW_PASSWORD` on `hist-gateway` |
| `INTERNAL_API_KEY` | — | from `.env` | service-to-service key (decoder device resolver) |
| `QUERY_API_KEYS` | — | `key:enterprise` list (values not reproduced) | static API key → tenant map |
| `COGNITO_AUTH_ENABLED`, `COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED` | on (unless `false`), staging pool, staging client, `false` | `true`, staging pool, …, `true` | Cognito JWT auth (Firebase tokens still accepted) |
| `OPERATOR_SUPERADMIN_ALLOWLIST` | built-in list | not set | who may use the cross-tenant switch |
| `REDIS_CACHE_ENABLED`, `REDIS_URL` | `true`, `redis://app-redis:6379/0` | same | cache-aside (ADR-0035) |
| `HEALTH_PORT`, `OTEL_EXPORTER_OTLP_ENDPOINT` | `9104`, — | `9104`, `http://alloy:4317` | HTTP port + health; traces via Alloy |

### operator-gateway, barcode-service

| Service | Variable | Staging | Meaning |
|---|---|---|---|
| `operator-gateway` | `PORT`, `TLS_CERT_FILE`, `TLS_KEY_FILE` | `8443`, host certs | TLS listener |
| | `EDGE_API_URL`, `EDGE_API_KEY`, `OPERATOR_API_KEY` | `http://edge-api:8080`, `OPERATOR_EDGE_API_KEY` and `OPERATOR_API_KEY` from `.env` | forwards Incoplast operator writes |
| | `INCOPLAST_ENTERPRISE_ID`, `INCOPLAST_TOPIC_PREFIX` | `4`, `INCOPLAST` | tenant scope |
| | `PG_SECRET_ID` | `${OPERATOR_GATEWAY_PG_SECRET_ID:-packiot/staging/operator-gateway-db-creds}` (Secrets Manager; `CREDS_SOURCE` unset, no `env_file`) | DB login as the least-privilege `operator_gateway` role (`10.10.10.89`/`packiot_analytics`); never the admin `POSTGRES_*` (CI `check-db-least-priv.py`). Provisioning: [operator-gateway README](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/operator-gateway/README.md#provisioning-the-db-role) |
| | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://tempo:4317` | traces |
| `barcode-service` | `PG_SECRET_ID` | `${BARCODE_SERVICE_PG_SECRET_ID:-packiot/staging/barcode-service-db-creds}` (Secrets Manager; `CREDS_SOURCE` unset, no `env_file`) | DB login as the least-privilege `barcode_service` role (`pgbouncer`/`packiot_analytics`); never the admin `POSTGRES_*` (CI `check-db-least-priv.py`). Provisioning: [barcode-service README](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/barcode-service/README.md#provisioning-the-db-role) |
| | `HTTP_PORT`, `LOG_LEVEL` | `8446`, `info` | `/v1/scans` |
| | `COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `FIREBASE_PROJECT_ID` | staging pool, empty | JWT auth; an explicitly empty `FIREBASE_PROJECT_ID` turns Firebase off (unset would fall back to the code default) |

## Frontends

| Service | Variable | Staging | Meaning |
|---|---|---|---|
| `operator` | `EDGE_API_KEY`, `REFDATA_API_KEY` | from `.env` (`OPERATOR_EDGE_API_KEY`, `OPERATOR_REFDATA_API_KEY`) | keys nginx injects on proxied calls (CPACK) |
| `operator-sbx` | same | `OPERATOR_SBX_*` | sandbox 2000003 |
| `operator-bispharma` | same | `OPERATOR_BISPHARMA_*` | Bispharma 5 |
| `operator*` | build args `VITE_PO_WRITE_QUEUE_ENABLED`, `VITE_COGNITO_USER_POOL_ID`, `VITE_COGNITO_USER_POOL_CLIENT_ID` | `true`, staging pool, staging client | baked at build; rebuild to change |
| `barcode-app` | `EDGE_API_UPSTREAM`, `EDGE_API_KEY`, `REFDATA_UPSTREAM`, `REFDATA_API_KEY` | `http://edge-api:8080`, `BARCODE_EDGE_API_KEY`, `http://read-api:9104`, `BARCODE_REFDATA_API_KEY` | nginx upstreams + injected keys |
| `csadmin`, `customize` | build args `VITE_API_BASE_URL`, `VITE_AUTH_COGNITO_ENABLED`, `VITE_COGNITO_USER_POOL_ID`, `VITE_COGNITO_CLIENT_ID` | empty (same origin), `true`, staging pool, staging client | no runtime env; rebuild to change |

## Identity

Detail: [oauth2-proxy and Cognito](../understand/components/oauth2-proxy-and-cognito.md).

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

Detail: [Observability](../understand/components/observability.md).

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

### Alerting and data invariants

| Setting | Where | Meaning |
|---|---|---|
| `slack_api_url` key | Secrets Manager `packiot/staging/app` | Slack webhook. When the key is set, the deploy writes it to `monitoring/alertmanager/slack_api_url` (gitignored; read through `slack_api_url_file`) and adds the `alerting` profile, which starts Alertmanager. No key → no file, no Alertmanager, no Slack alerts |
| `LEGACY_SECRET_ID` | `scripts/ops/data-oracle-check.sh`, default `databaseCredentials` | legacy login for the legacy-oracle invariants (host systemd timer `data-oracle-check.timer`) |
| `EXCLUDE_FEEDS`, `EXCLUDE_LINES` | same script; defaults `FLEXO,L10-TEXA,L3` and `FLEXO` | feeds and lines left out of the legacy comparison |
| `STACK_ENV` | `scripts/ops/invariant-record.sh`, default the runner checkout's `.env` | where the result writer finds the analytics DB login; results go to `ops.data_invariant_result` and alert through postgres-exporter |

## Other compose files

| File / service | Key variables | Meaning |
|---|---|---|
| `compose.historian-gateway.yml` / `historian-gateway` | `POSTGRES_PASSWORD` (`HIST_GW_PASSWORD`), `POSTGRES_DB=packiot_historian`, `FDW_HOST/PORT/DB/USER/PASS` (from `DB_*`), `HISTORIAN_BUCKET`, `AWS_REGION`, `HIST_AWS_KEY`, `HIST_AWS_SECRET`, `CLOUDBEAVER_HISTRO_PASSWORD`, `HISTGW_RO_PASS`, `HIST_GW_SVC_PASSWORD` | gateway superuser, hot FDW source, cold S3 bucket + scoped key, least-privilege roles; compose refuses to start if a required one is missing — see [historian gateway](../understand/components/historian-gateway.md) |
| `compose.superset.yml` | `SUPERSET_SECRET_KEY`, `SUPERSET_GUEST_TOKEN_JWT_SECRET`, `SUPERSET_DB_PASSWORD`, `POSTGRES_HOST_UPSTREAM`, `SUPERSET_COGNITO_*`, `SUPERSET_ADMIN_*`, `SUPERSET_FRAME_ANCESTOR`, `SUPERSET_OEE_DASHBOARD_UUID`, `SUPERSET_EMBED_TARGET_DASHBOARD`, `SUPERSET_ASSET_SYNC_USER`, `SUPERSET_REDIS_HOST` | Superset secrets, metadata DB, OIDC, embed origin and dashboard, asset-sync user (profile `superset`) |
| `compose.onprem-edge.yml` (`.env.onprem`) | `TENANT`, `AGENT_INGEST_API_KEY`; edge-transformer `LOCAL_DECODE_ONLY=true`, `LOCAL_STATE_DB`; edge-dashboard `DASHBOARD_PORT=8080` | on-prem box identity, local ingest key, local-only decode, dashboard (edge-api's default host port for it is `SSM_ONPREM_DASHBOARD_PORT`, 1881) |
| `compose.production.yml` | see below | new-stack production |

### New-stack production compose

`compose.production.yml` is the single-flow production stack prepared for the promotion
(production clients still run legacy). It reads `packiot/production/*` secrets and differs
from staging in the flags it sets:

| Service | Differences from staging |
|---|---|
| `stream-engine` | `CONSUME_LANES=2`; `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES=3`; `COUNTERS_ONLY_AVAILABILITY_ENABLED=false`; no `WORKER_TENANT_ALLOWLIST` (all tenants); `OEE_AVAIL_FLOOR_ENABLED`, `OEE_CANONICAL_APQ_ENABLED`, `EVENTS_CLOSE_STALE_*`, report jobs and `BRONZE_RAW_APPEND` not set (code defaults) |
| `sparkplug-decoder` | `MQTT_CLIENT_ID=edge-transformer-production`, `COUNTERS_ONLY_FROM_DB=true`; no `F3_PER_TENANT_ROUTING`, `OEE_PROFILE_FROM_DB`, `BIRTH_BOUND_RESOLVER` or `PHASE9_LINE_AGG_ENABLED` |
| `ingest-shim` | `ROUTING_KEY` and `SCOPE_GROUP` from `.env` (`INGEST_ROUTING_KEY`, `INGEST_SCOPE_GROUP`) |
| `operator-gateway` | tenant scope from `.env` (`OPERATOR_ADAPTER_ENTERPRISE_ID`, `OPERATOR_ADAPTER_TOPIC_PREFIX`) |
| `edge-api`, `read-api` | edge-api sets only DB and New Relic keys in compose; Cognito, onboarding and `REDIS_*` keys sit under `read-api` (see warning) |

!!! warning "Unverified"
    In `compose.production.yml` the edge-api Cognito and onboarding keys
    (`COGNITO_USER_POOL_ID`, `COGNITO_CS_ADMIN_GROUP`, `EDGE_API_COGNITO_AUTH_ENABLED`,
    `EDGE_API_ONBOARDING_ENABLED`, `ONBOARD_GENERATE_URL`, `ONBOARD_API_KEY`) are in the
    `read-api` block, which does not read them. Unless the production `.env` supplies them,
    edge-api would start without bearer auth or onboarding. Not checked against a running host.
