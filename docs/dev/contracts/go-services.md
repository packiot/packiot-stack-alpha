# P0 static contract inventory — Go services (+ edge-session-broker)

> **Citation format.** Every `path:line` is repo-rooted and was machine-checked on 2026-10-06 to exist and be in range at `28356ccc`. Citations the checker could not pin to one file are marked `⚠ambiguous[candidates]`; files not in this repo are marked `⚠not-in-repo`. Nothing was silently guessed. Live (runtime) evidence lives in [`../contracts.md`](../contracts.md) §3.


Checkout: `origin/staging @ 28356ccc` (branch `docs/p0-dev-contracts`). All paths relative to repo root. Deployed wiring = `compose.staging.yml`. READ-ONLY static analysis (grep + code reading); no DB/broker/remote host contacted.

## Index — compose service → build → binary

| Compose service | compose line | Build | Binary (cmd/) | Staging state |
|---|---|---|---|---|
| sparkplug-decoder | `compose.staging.yml:2541` | `services/sparkplug-decoder/Dockerfile` | `cmd/edge-transformer` → `sparkplug-decoder` | on |
| plc-sim | `:192` | same image | `cmd/plc-sim` | profile `plc-sim` |
| sparkplug-agent-cpack | `:254` | same image | `cmd/sparkplug-agent` | profile `cpack-tee` |
| sparkplug-agent-shared | `:322` | same image | `cmd/sparkplug-agent` (multi-tenant) | profile `shared-tee` |
| s7-softplc | `:404` | same image | `cmd/s7-softplc` | profile `s7` |
| s7-reader | `:425` | same image | `cmd/s7-reader` | profile `s7` |
| bispharma-twin | `:2321` | same image | `cmd/bispharma-twin` | always up, idles unless `BISPHARMA_TWIN_ENABLED` |
| stream-engine | `:1788` | `services/stream-engine/Dockerfile` | `cmd/oeecloud-worker` → `stream-engine` | on |
| mirror-worker-go | `:1655` | `services/mirror-worker-go/Dockerfile` | `cmd/mirror-worker-go` | profile `legacy-comparator` (retired) |
| oeecloud-fanout | `:2234` | `services/oeecloud-fanout/Dockerfile` | `cmd/oeecloud-fanout` | up, flag-gated |
| ingest-shim | `:2443` | `services/ingest-shim/Dockerfile` | `cmd/ingest-shim` | on |
| read-api | `:2876` | `services/read-api/Dockerfile` | `cmd/refdata-api` → `read-api` | on |
| operator-gateway | `:3071` | `services/operator-gateway/Dockerfile` | `cmd/operator-adapter` → `operator-gateway` | on |
| barcode-service | `:3016` | `services/barcode-service/Dockerfile` | `cmd/barcode-service` | on |
| analytics-sync | `:3141` | `services/analytics-sync/Dockerfile` | `cmd/shadow-mirror` → `analytics-sync` | up, `SHADOW_MIRROR_ENABLED=false` (idle) |
| legacy-replicator | `:3214` | `services/analytics-sync/Dockerfile.replicator` | `cmd/legacy-replicator` | on |
| legacy-replicator-sbx | `:3345` | same | `cmd/legacy-replicator` | flag `REPLICATE_SBX_ENABLED` (default off) |
| edge-session-broker | `:711` | `services/edge-session-broker/Dockerfile` (Node 18) | `server.mjs` | on |

## Cross-service data-flow summary (from the sections below)

- **MQTT** `spBv1.0/#` on mosquitto: producers plc-sim, sparkplug-agent-cpack/-shared, bispharma-twin (s7-reader emits raw `edge/raw/incoplast` by default) → consumer **sparkplug-decoder**.
- **AMQP `oee` (topic)**: sparkplug-decoder → `sparkplug.data.<tenant>` (F3_PER_TENANT_ROUTING=true); ingest-shim → `sparkplug.data.incoplast`; oeecloud-fanout consumes `sparkplug.data`,`sparkplug.data.cpack` and republishes `sparkplug.data.sbxcpack` → consumer **stream-engine** (`stream-engine-q[-<tenant>]`, tenants from `packml_register` ∩ `WORKER_TENANT_ALLOWLIST`).
- **Postgres writers into packiot_analytics**: stream-engine (silver/bronze/gold/core/customer_reports), legacy-replicator (core.production_orders, gold.production_orders_runtime, silver.equipment_events[_man], ops.*), barcode-service (box_scans, po_box_counter), read-api (identity.user_screen_config, users.id_user_cognito), sparkplug-agent-shared (silver.plc_link_minutes, capture_observations via AGENT_REGISTER_DSN).
- **Postgres readers**: read-api (serving.*/gold/silver views → front4/operator/barcode-app), sparkplug-decoder (packml_register, equipments, client_descriptors), operator-gateway (packml_register⋈equipments⋈areas⋈sites).
- **HTTP**: operator-gateway → edge-api `/api/…`; edge-api → sparkplug-decoder `:9105 /v1/onboard/*`; edge-api → edge-session-broker `:8090/shell`, `:8091`; sparkplug-decoder → read-api `/internal/resolve-device` (wired but inert); barcode-app → read-api.

## External (non-local) dependencies — consolidated

| Dependency | Services | Configurable by env? |
|---|---|---|
| AWS Secrets Manager (`GetSecretValue`) | sparkplug-decoder, ingest-shim, oeecloud-fanout, mirror-worker-go (used); stream-engine, operator-gateway (bypassed by `CREDS_SOURCE=env` on staging) | yes — `CREDS_SOURCE=env` + `RABBITMQ_USER/PASSWORD` / `DB_*` |
| AWS Cognito JWKS (`us-east-1_0T9t1sTwt`) | read-api, barcode-service | read-api: `COGNITO_ISSUER` + `COGNITO_JWKS_URL`; barcode-service: `COGNITO_ISSUER` only (JWKS = issuer + `/.well-known/jwks.json`) |
| Google securetoken x509 (Firebase) | barcode-service (active: `FIREBASE_PROJECT_ID=""` falls back to `fbpackiot`) | URL hard-coded; project id only overridable to non-empty |
| Legacy CPACK prod Postgres `18.220.223.110:5432/packiot40` | legacy-replicator(-sbx); mirror-worker-go (host via secret `databaseCredentials`) | yes — `LEGACY_DB_*` |
| Staging DB EC2 `10.10.10.89:5432` (outside compose) | stream-engine, sparkplug-decoder (`POSTGRES_URL`), analytics-sync, legacy-replicator, operator-gateway (direct); read-api, barcode-service via pgbouncer | yes — `DB_HOST` / `POSTGRES_URL` / `DEST_DB_HOST` |
| AWS SSM data plane + `session-manager-plugin` (downloaded from S3 at image build) | edge-session-broker | `SSM_ENDPOINT`, `AWS_REGION` |
| historian gateway (separate compose; S3 cold tier) | read-api `/v1/historian/*` | `HIST_GW_*`; nil-safe (503) when absent |
| Host-mounted TLS certs | ingest-shim, operator-gateway | file paths by env; required at boot |
| Values only in `/opt/packiot/.env` (not in repo) | most services (`env_file: [.env]`) | — see each UNPROVEN list |

---

## Shared notes for the sparkplug-decoder build context

Checkout: origin/staging @ 28356ccc. All paths are relative to the repo root. `SD/` = `services/sparkplug-decoder/`.
Every compose service below builds `SD/Dockerfile`, which compiles all binaries into one distroless image (`services/sparkplug-decoder/Dockerfile:22-58`, copied in at `:73-81`). The default ENTRYPOINT is `sparkplug-decoder` (= `cmd/edge-transformer`, `services/sparkplug-decoder/Dockerfile:24,90`). Other services override `entrypoint:`. `SD/Dockerfile.agent` (agent-only image) is NOT used by compose.staging.yml. Nothing in compose references it (`grep -n Dockerfile.agent compose.staging.yml` = none).

Edge-api note: edge-api's compose block has an "apply-agent-config target", which runs SSM SendCommand against the app box running `sparkplug-agent-shared` (`compose.staging.yml:566-582`, `SSM_SHARED_AGENT_INSTANCE_ID` at :581). Edge-api also proxies `POST /v1/onboard/generate` to `http://sparkplug-decoder:9105` (`compose.staging.yml:677-678`).

### Shared internal packages (documented once, referenced below)
- **Secrets loader** `SD/internal/secrets/secrets.go`. `FetchAMQPCreds` calls AWS Secrets Manager `GetSecretValue` (`:59` LoadDefaultConfig with region, `:63-64`) unless `CREDS_SOURCE=env` (`:85`), in which case it reads `RABBITMQ_USER/RABBITMQ_PASSWORD/RABBITMQ_HOST/RABBITMQ_PORT` (`:120-128`).
- **Tracing** `SD/internal/tracing/tracing.go`. `OTEL_EXPORTER_OTLP_ENDPOINT` (`:39`, no-op if unset) and `OTEL_TRACES_SAMPLER_ARG` (`:91`).
- **Health server** `SD/internal/health/health.go`. Routes: `/metrics` (`:174`), `/healthz` (`:189`), `/health` alias (`:192`). Returns 503 when a component is degraded.
- **Outbox (SQLite, local file)** `services/sparkplug-decoder/internal/outbox/outbox.go:140` (`sql.Open("sqlite")`). Table `outbox`: INSERT `:220`, SELECT/DELETE `:242-251,274,310`, UPDATE `:330`. This is not PostgreSQL.

---


## sparkplug-decoder

### 1. Build
- `compose.staging.yml:2541-2807`. `build: ./services/sparkplug-decoder`, no entrypoint override, so the binary is `/usr/local/bin/sparkplug-decoder` = `SD/cmd/edge-transformer` (`services/sparkplug-decoder/Dockerfile:22-24,90`).
- Mounts `docs/clients/cpack.yaml` to `/etc/packiot/client.yaml` (`:2783`) and the volume `edge_transformer_outbox` to `/var/lib/edge-transformer` (`:2787`). Uses `env_file: .env` (`:2545`); the contents of `.env` are not in the repo.
- Network alias `edge-transformer`, IP `172.18.0.23` (`:2790-2791`).

### 2. Env vars
Config struct: `services/sparkplug-decoder/internal/config/config.go:341-427`. Helpers: `:435-518`.

| Var | Code default (file:line) | Staging value (compose line) |
|---|---|---|
| EDGE_TRANSFORMER_MODE | factory (services/sparkplug-decoder/internal/config/config.go:341) | factory (:2548) |
| AWS_REGION | us-east-1 (:350) | us-east-1 (:2582) — **AWS** |
| RABBITMQ_SECRET_ID | packiot/staging/rabbitmq-edge-transformer-creds (:351) | packiot/staging/rabbitmq-sparkplug-decoder-creds (:2583) — **AWS Secrets Manager** |
| RABBITMQ_HOST / RABBITMQ_PORT | rabbitmq / 5672 (:352-353) | rabbitmq / 5672 (:2584-2585) |
| SOURCE_EXCHANGE | plc.normalized (:354) | edge.plc-normalized (:2586) |
| AMQP_SOURCE_ENABLED | true (:355) | **false** (:2615) |
| WORKER_QUEUE / RETRY_EXCHANGE / RETRY_QUEUE / FAILED_EXCHANGE / FAILED_QUEUE | edge-transformer-q / plc.normalized-retry / edge-transformer-q-retry-30s / plc.normalized-failed / edge-transformer-q-failed (:356-360) | edge-transformer-q / edge.plc-normalized-retry / edge-transformer-q-retry-30s / dlx.edge.plc-normalized / edge-transformer-q-failed (:2587-2591) |
| RETRY_TTL_MS / MAX_RETRIES / PREFETCH | 30000 / 5 / 50 (:361-363) | same (:2592-2594) |
| HEALTH_PORT | 9102 (:364; also read at services/sparkplug-decoder/cmd/edge-transformer/main.go:2191) | 9102 (:2595) |
| LOG_LEVEL | info (:365) | info (:2547) |
| CLIENT_YAML_PATH | /etc/packiot/client.yaml (:366) | same (:2596) |
| MQTT_ENABLED | false (:369) | true (:2612) |
| MQTT_BROKER_URL | tcp://mosquitto:1883 (:370) | same (:2622) |
| MQTT_CLIENT_ID | edge-transformer (:371) | edge-transformer-staging (:2623) |
| MQTT_USERNAME / MQTT_PASSWORD | "" (:372-373) | "" (:2624-2625) |
| MQTT_STALE_THRESHOLD_SECONDS | 60 (:374) | -1 (:2631) |
| CALC_MONOTONICITY_GUARD / CALC_COUNTER_ROLLOVER | false (:377-378) | unset |
| CALC_COUNTER_SPIKE_MARGIN | 0 (:379) | "0" (:2760) |
| ET_REQUEST_REBIRTH_ENABLED / _MIN_INTERVAL_SECONDS | false / 30 (:382-383) | unset |
| USE_GO_PORT | false (:386) | true (:2637) |
| CALC_RESET_HEAL_ENABLED | true (:389) | unset |
| CALC_NO_SPEED_GUARD_FALLBACK | false (:390) | true (:2689) |
| COUNTERS_ONLY_OEE_ENABLED | false (:393) | true (:2722) |
| COUNTERS_ONLY_IDEAL_RATES | empty map (:394) | JSON map of 7 CPACK topics (:2739) |
| COUNTERS_ONLY_FROM_DB / _REFRESH_SECONDS | false / 300 (:395-396) | unset, so the countersrate DB watcher is OFF |
| OEE_PROFILE_FROM_DB / _REFRESH_SECONDS | false / 300 (:397-398) | true (:2766) / unset |
| BIRTH_BOUND_ROUTING, BIRTH_BOUND_DEVICE_MAP | false / empty (:401-402) | unset |
| BIRTH_BOUND_RESOLVER | map (:405) | refdata (:2601) — inert, see UNPROVEN |
| REFDATA_URL / REFDATA_INTERNAL_KEY | "" (:406-407) | http://read-api:9104 (:2602) / ${INTERNAL_API_KEY} (:2603) |
| BIRTH_BOUND_ENTERPRISE_ID, *_RESOLVER_TTL_SECONDS, *_NEG_TTL_SECONDS | 0 / 600 / 30 (:408-410) | unset |
| OUTBOX_ENABLED / OUTBOX_PATH / OUTBOX_CAP | false / /var/lib/edge-transformer/outbox.db / 100000 (:413-415) | true / same / 100000 (:2648-2650) |
| EMIT_LIVENESS_TIMEOUT_SECONDS | 120 (:417) | unset |
| EDGE_COMMANDS_ENABLED | false (:420) | false (:2775) |
| EDGE_COMMANDS_ALLOWED | po_setup,param_write (:421) | same (:2779) |
| EDGE_COMMANDS_EXCHANGE / _QUEUE_PREFIX / _RETRY_EXCHANGE / _FAILED_EXCHANGE / _EDGE_NODE / _DEDUP_CAP | edge.commands / edge-commands / edge.commands-retry / edge.commands-failed / plc-sim / 4096 (:422-427) | unset |
| PHASE9_LINE_AGG_ENABLED | off unless truthy (services/sparkplug-decoder/cmd/edge-transformer/line_param30700_seed.go:40) | true (:2553) |
| POSTGRES_URL | "" means the seeder is skipped (services/sparkplug-decoder/cmd/edge-transformer/line_param30700_seed.go:96-98) | `postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@10.10.10.89:5432/packiot_analytics` (:2707) — **direct DB** |
| EDGE_API_URL / EDGE_API_KEY / EDGE_API_ENTERPRISE_ID | unset means no client (services/sparkplug-decoder/cmd/edge-transformer/main.go:93-106) | not set in the compose block. May arrive via .env (EDGE_API_KEY is interpolated from .env at compose:759) |
| ERP_SQL_TEMPLATE_DIR | /etc/packiot/tenant/sql (services/sparkplug-decoder/cmd/edge-transformer/main.go:241-244) | unset |
| ONBOARD_API_ENABLED / ONBOARD_API_KEY / ONBOARD_API_PORT | off / "" / 9105 (services/sparkplug-decoder/cmd/edge-transformer/main.go:366-379) | true / ${ONBOARD_API_KEY} / 9105 (:2640-2642) |
| LOCAL_DECODE_ONLY | false (services/sparkplug-decoder/cmd/edge-transformer/main.go:534) | unset |
| LINE_TRACE_TENANTS | "" (services/sparkplug-decoder/cmd/edge-transformer/main.go:641) | commented out (:2712) |
| LOCAL_STATE_DB | "" means off (services/sparkplug-decoder/cmd/edge-transformer/main.go:728) | unset |
| SHADOW_EMIT_REFACTORED | false (services/sparkplug-decoder/cmd/edge-transformer/main.go:748) | true (:2656) |
| SHADOW_EMIT_PRODUCTION | false (services/sparkplug-decoder/cmd/edge-transformer/main.go:752) | false (:2621) |
| CALC_CUTOVER_REFACTORED | false (services/sparkplug-decoder/cmd/edge-transformer/main.go:759) | true (:2677) |
| SHADOW_EMIT_GO | true unless "false" (services/sparkplug-decoder/cmd/edge-transformer/main.go:766) | false (:2664) |
| F3_PER_TENANT_ROUTING | false (services/sparkplug-decoder/cmd/edge-transformer/main.go:796) | true (:2705) |
| OEE_PROFILE_DSN, then COUNTERS_ONLY_DSN, then POSTGRES_USER/PASSWORD/HOST (fallback POSTGRES_HOST_UPSTREAM)/PORT/DB/SSLMODE | built DSN, db default packiot, port 5432, sslmode disable (services/sparkplug-decoder/internal/oeeprofile/oeeprofile.go:255-279) | POSTGRES_DB=packiot_analytics (:2706). POSTGRES_HOST/USER/PASSWORD come from .env (unproven values) |
| COUNTERS_ONLY_DSN + same POSTGRES_* | services/sparkplug-decoder/internal/countersrate/countersrate.go:189-210 | not used (COUNTERS_ONLY_FROM_DB off) |
| PLC_HOST_<NAME> | services/sparkplug-decoder/internal/rawemit/rawemit.go:63 | not used by this binary |
| CREDS_SOURCE, RABBITMQ_USER/PASSWORD | secrets.go:85⚠ambiguous[services/ingest-shim/internal/secrets/secrets.go|services/mirror-worker-go/internal/secrets/secrets.go|services/oeecloud-fanout/internal/secrets/secrets.go|services/operator-gateway/internal/secrets/secrets.go|services/sparkplug-decoder/internal/erpconnector/secrets.go|services/sparkplug-decoder/internal/secrets/secrets.go|services/stream-engine/internal/secrets/secrets.go],120-121 | unset in compose (.env unknown) |
| OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_TRACES_SAMPLER_ARG | off / 1.0 (services/sparkplug-decoder/internal/tracing/tracing.go:39,91) | http://tempo:4317 (:2574) / 0.1 (:2581) |
| COMPOSE-ONLY (set, never read by Go) | — | MQTT_* is read. `DB_*` is not set. None found beyond the above |

### 3. PostgreSQL
- **Seeder pool (Phase-9 line Parameter30700).** `pgxpool.New(POSTGRES_URL)` at `services/sparkplug-decoder/cmd/edge-transformer/line_param30700_seed.go:96-102`. Staging connects **directly to 10.10.10.89:5432/packiot_analytics** as `${POSTGRES_USER}` (compose :2707). It runs at boot and then every 5 min (`:165-176`), only when USE_GO_PORT and PHASE9 are on (services/sparkplug-decoder/cmd/edge-transformer/main.go:446-449).
  - READ `packml_register`, `equipments` (`:54-67` member count-index CSV; `:77-85` line infeed/outfeed meters, columns `id_infeedcounter`, `id_outfeedcounter`). Table names are unqualified, so they resolve through the role's search_path.
- **OEE-profile watcher** (OEE_PROFILE_FROM_DB=true). `pgxpool.New` at `services/sparkplug-decoder/internal/oeeprofile/oeeprofile.go:141`, started from services/sparkplug-decoder/cmd/edge-transformer/main.go:618-623, reloads every 5 min (`:327-330`). DSN per the table above, with `POSTGRES_DB=packiot_analytics` (compose :2706). The host (`POSTGRES_HOST`) comes from .env, so pgbouncer vs direct is UNPROVEN.
  - READ `client_descriptors`, `sites`, `areas`, `equipments`, `packml_register` (`:64-82` marginsQuery). READ `client_descriptors` via `jsonb_path_query` (`:97-106` uint16CountersQuery). All unqualified.
- **Counters-rate watcher** (`services/sparkplug-decoder/internal/countersrate/countersrate.go:55-63,92`). It reads the same tables, but it is OFF on staging (COUNTERS_ONLY_FROM_DB unset, services/sparkplug-decoder/internal/config/config.go:395).
- **Writes:** none to PostgreSQL. The only writes go to the local SQLite outbox (shared section) and the optional `localstate` SQLite (`services/sparkplug-decoder/internal/localstate/localstate.go:90,161`), which is OFF because LOCAL_STATE_DB is unset.
- Dynamic SQL: none. All queries are const literals.
- LISTEN/NOTIFY: none found (searched `LISTEN|NOTIFY|WaitForNotification` in SD/).

### 4. RabbitMQ (AMQP creds from Secrets Manager `packiot/staging/rabbitmq-sparkplug-decoder-creds`, services/sparkplug-decoder/cmd/edge-transformer/main.go:273)
- **PUBLISH (live path):** exchange **`oee`** (services/sparkplug-decoder/cmd/edge-transformer/main.go:541 `analyticspub.NewWithRetry(..., "oee", ...)`).
  - Routing key `sparkplug.data.<lower(GroupID)>` when F3_PER_TENANT_ROUTING=true, else `sparkplug.data` (services/sparkplug-decoder/cmd/edge-transformer/main.go:1820-1825, called at :1992; tenant = `strings.ToLower(topic.GroupID)` at :1975).
  - The legacy direct-publish key `sparkplug.data.%s` is at `services/sparkplug-decoder/internal/analyticspub/publisher.go:523`.
  - The envelope carries `source_type`. Staging emits only `"refactored"` (services/sparkplug-decoder/cmd/edge-transformer/main.go:1624-1634, given SHADOW_EMIT_GO=false and SHADOW_EMIT_PRODUCTION=false).
  - Publisher confirms are on (`services/sparkplug-decoder/internal/analyticspub/publisher.go:201,338` `ch.Confirm`). Publish call: `services/sparkplug-decoder/internal/analyticspub/publisher.go:600`, mandatory=false.
  - Traceparent is carried through the outbox envelope (services/sparkplug-decoder/cmd/edge-transformer/main.go:2060-2066).
  - The `oee` exchange is **not declared** by this service (no ExchangeDeclare in `SD/internal/analyticspub/`). It must exist beforehand.
  - Outbox path: enqueue at services/sparkplug-decoder/cmd/edge-transformer/main.go:2071, drained by `runOutboxDrain` (services/sparkplug-decoder/cmd/edge-transformer/main.go:1715, publish at :1789).
- **CONSUME (disabled on staging):** `services/sparkplug-decoder/internal/amqp/topology.go:62-131` declares exchanges `SOURCE/RETRY/FAILED_EXCHANGE` (topic, durable, `:64-66`), plus queues `edge-transformer-q` (DLX to retry), `-retry-30s` (TTL, DLX to source, bound `#`), `-failed` (bound `#`), and per-tenant `edge-transformer-q-<t>` bound with key `edge.plc-normalized.<t>` (`:101-131`). The consumer uses manual ack (`services/sparkplug-decoder/internal/amqp/consumer.go:210` autoAck=false; Ack `:278,307`; Nack(requeue=false) `:293`; publish to the failed exchange `:265`). On staging this is **never run**: with AMQP_SOURCE_ENABLED=false, services/sparkplug-decoder/cmd/edge-transformer/main.go:949-955 blocks on ctx, and the topology is declared only inside connectAndConsume (consumer.go:166⚠ambiguous[services/sparkplug-decoder/internal/amqp/consumer.go|services/sparkplug-decoder/internal/command/consumer.go|services/stream-engine/internal/amqp/consumer.go]).
- **Command channel (disabled):** `services/sparkplug-decoder/internal/amqp/topology.go:184-236` declares `edge.commands`, `edge.commands-retry`, `edge.commands-failed`, plus quorum queues `edge-commands-<t>-q`, retry, failed and ack (key `edge.commands.<t>.ack`). The consumer is at `services/sparkplug-decoder/internal/command/consumer.go:178,219` with manual ack (`:268-299`). It self-gates when EDGE_COMMANDS_ENABLED=false (`services/sparkplug-decoder/internal/command/consumer.go:115`). The producer side is edge-api (`edge-api/src/providers/messaging/rabbitmq-command-publisher.ts:8`).

### 5. MQTT
- SUBSCRIBE `spBv1.0/#` (`services/sparkplug-decoder/internal/mqtt/subscriber.go:50`, subscribe at `:514`) on `tcp://mosquitto:1883` (compose :2622).
- PUBLISH NCMD Rebirth `spBv1.0/<group>/NCMD/<edgeNode>` (`services/sparkplug-decoder/internal/mqtt/rebirth.go:131`, publish `:87`). This is OFF (ET_REQUEST_REBIRTH_ENABLED unset).
- PUBLISH DCMD `spBv1.0/<group>/DCMD/<edgeNode>` (`services/sparkplug-decoder/internal/command/dcmd.go:106`, publish `services/sparkplug-decoder/internal/command/mqttpub.go:66`). This is OFF (EDGE_COMMANDS_ENABLED=false).

### 6. Redis
None found (searched `redis|Redis` across SD/internal and the 6 cmds; no matches outside comments).

### 7. HTTP
- EXPOSED on `:9102`: `/healthz`, `/health`, `/metrics` (services/sparkplug-decoder/internal/health/health.go:174-192; started at services/sparkplug-decoder/cmd/edge-transformer/main.go:353-354).
- EXPOSED on `:9105`: `POST /v1/onboard/generate` and `POST /v1/onboard/simulate` (`services/sparkplug-decoder/internal/agent/onboardapi/onboardapi.go:109-110`; server at services/sparkplug-decoder/cmd/edge-transformer/main.go:366-389). Key-gated by ONBOARD_API_KEY. Its consumer is edge-api (`compose.staging.yml:677`).
- OUTBOUND, edge-api: `POST {EDGE_API_URL}/api/admin/production-orders/csv/import?idEnterprise=N` (`services/sparkplug-decoder/internal/edgeapiclient/edgeapiclient.go:139-141`). It is called only from the ERP read sink (services/sparkplug-decoder/cmd/edge-transformer/main.go:127-160). Inert on staging, because `docs/clients/cpack.yaml` declares no `capabilities` (grep shows none), so `erpconnector.New` has zero integrations (services/sparkplug-decoder/cmd/edge-transformer/main.go:248-252).
- OUTBOUND, refdata: `GET {REFDATA_URL}/internal/resolve-device` with header `X-Internal-Key` (`services/sparkplug-decoder/internal/refdataresolver/refdataresolver.go:158-172`). **No non-test code imports this package** (`grep -rl 'internal/refdataresolver"'` matches only `_test.go`), so the call is never made.

### 8. External dependencies
- **AWS Secrets Manager** via SDK v2 (`services/sparkplug-decoder/internal/erpconnector/secrets.go:59-64`, `secretsmanager.NewFromConfig`), secret `packiot/staging/rabbitmq-sparkplug-decoder-creds`. The service exits at boot if the fetch fails (services/sparkplug-decoder/cmd/edge-transformer/main.go:273-281). Fake it with `CREDS_SOURCE=env` + `RABBITMQ_USER/PASSWORD` (secrets.go:85⚠ambiguous[services/ingest-shim/internal/secrets/secrets.go|services/mirror-worker-go/internal/secrets/secrets.go|services/oeecloud-fanout/internal/secrets/secrets.go|services/operator-gateway/internal/secrets/secrets.go|services/sparkplug-decoder/internal/erpconnector/secrets.go|services/sparkplug-decoder/internal/secrets/secrets.go|services/stream-engine/internal/secrets/secrets.go],120).
- ERP connector drivers: sqlite only, registered at `services/sparkplug-decoder/internal/erpconnector/driver.go:8`. Inert.
- Tempo OTLP (`tempo:4317`, local).
- JWT/Cognito: none found (searched `jwt|cognito|jwks`).
- S3/DuckDB: none found.

### 9. Health / ports
- `/healthz` on 9102. The compose healthcheck runs `sparkplug-decoder --healthcheck` (compose :2798), which GETs `http://127.0.0.1:<HEALTH_PORT>/healthz` (services/sparkplug-decoder/cmd/edge-transformer/main.go:2189-2195).
- Onboard API on 9105. No host ports are published.

### 10. UNPROVEN
- Values in `.env` (POSTGRES_HOST/USER/PASSWORD, CREDS_SOURCE, EDGE_API_*). They are not in the repo. So the oeeprofile pool's target host (pgbouncer vs 10.10.10.89) and role cannot be proven.
- Search path for the unqualified `packml_register`/`equipments`/`client_descriptors`/`sites`/`areas` on packiot_analytics. The agent's linkhealth uses `core.client_descriptors` (services/sparkplug-decoder/internal/agent/linkhealth/linkhealth.go:165), which suggests these live in `core`. Resolution depends on the role's search_path, which is not visible in Go code.
- Who declares the `oee` exchange. Not this service (searched ExchangeDeclare in `SD/internal/analyticspub`).
- `BIRTH_BOUND_RESOLVER=refdata` / `REFDATA_URL` have no effect: the config fields are loaded (services/sparkplug-decoder/internal/config/config.go:401-410), but no code imports `refdataresolver`/`birthbind` outside tests.

---

## plc-sim

### 1. Build
`compose.staging.yml:192-227`. Profile `plc-sim` (opt-in, `:207`). Context `./services/sparkplug-decoder` (`:209`), entrypoint `/usr/local/bin/plc-sim` (`:210`), which is `SD/cmd/plc-sim` (`services/sparkplug-decoder/Dockerfile:25`).

### 2. Env vars
| Var | Default | Staging |
|---|---|---|
| MQTT_BROKER_URL | tcp://mosquitto:1883 (`services/sparkplug-decoder/cmd/plc-sim/main.go:182`) | same (:212) |
| PLC_SIM_EDGE_NODE | plc-sim (:183) | unset |
| PLC_SIM_TICK_SEC | 5 (:184) | "5" (:213) |
| EMIT_DEFINITIVE_BIRTH | false (:192) | unset |

Group is hardcoded `CPACK` (`services/sparkplug-decoder/cmd/plc-sim/main.go:38`).

### 3. PostgreSQL
None found (searched `pgx|sql.Open|POSTGRES` in cmd/plc-sim).

### 4. RabbitMQ
None.

### 5. MQTT
- PUBLISH NBIRTH `spBv1.0/CPACK/NBIRTH/<edgeNode>`, retained (`services/sparkplug-decoder/cmd/plc-sim/main.go:223`).
- PUBLISH NDATA `spBv1.0/CPACK/NDATA/<edgeNode>` (`:331`).
- SUBSCRIBE DCMD `spBv1.0/CPACK/DCMD/<edgeNode>`, QoS 1 (`:251-257`).

### 6. Redis
None.

### 7. HTTP
None (searched `ListenAndServe|HandleFunc`).

### 8. External dependencies
None.

### 9. Health / ports
No health endpoint, no healthcheck in compose, no ports.

### 10. UNPROVEN
Whether the profile is active on the staging box (`COMPOSE_PROFILES` is set outside the repo, per the comment at :202).

---

## sparkplug-agent-cpack

### 1. Build
`compose.staging.yml:254-308`. Profile `cpack-tee` (`:255`). Context SD (`:257`), entrypoint `sparkplug-agent --config /etc/packiot/agent.yaml` (`:259`), which is `SD/cmd/sparkplug-agent` (`services/sparkplug-decoder/Dockerfile:45`). Mounts `docs/clients/cpack-agent.yaml` (`:288`) and the outbox volume (`:289`). `env_file .env` (`:261`).

### 2. Env vars (helpers at `services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1920-1945`)
| Var | Default | Staging |
|---|---|---|
| LOG_LEVEL | info (:97) | info (:263) |
| AGENT_CONFIG | "" (:294) | /etc/packiot/agent.yaml (:264). The CLI `--config` wins (:295-296) |
| AGENT_TENANTS_DIR | "" means single mode (:199) | unset |
| HEALTH_PORT | 9103 (:1878) | 9103 (:265) |
| MQTT_STALE_THRESHOLD_SECONDS | (:1883) | -1 (:269) |
| OUTBOX_PATH | /var/lib/edge-transformer/agent-outbox.db (:480) | same (:270) |
| AGENT_HTTP_INGEST_ENABLED | false (:579) | true (:272) |
| AGENT_INGEST_PORT | 9104 (:632) | 9104 (:273) |
| AGENT_INGEST_API_KEY | required when ingest is on (:580) | ${AGENT_INGEST_API_KEY} (:277) |
| AGENT_INGEST_MAX_BODY_BYTES | 0 (:627) | unset |
| AGENT_NUMERIC_INGEST_ENABLED | false (:603) | unset |
| AGENT_BIRTH_ALL_MAPPED | true (:474,823) | true (:285) |
| EMIT_DEFINITIVE_BIRTH | false (:473,817) | unset |
| AGENT_CAPTURE_ENABLED / _FLUSH_SEC / _STATUS_POLL_SEC | false / 30 / 300 (:345,525-526) | unset |
| AGENT_PARAM_DECOMPOSITION / AGENT_PROFILE_PATH | false / "" (:386-387,1632) | unset |
| AGENT_TAGMAP_FROM_REGISTER | false (:1631) | unset |
| AGENT_UPLINK_TLS_CERT / _KEY / AGENT_UPLINK_CA | "" (:448-450) | unset |
| AGENT_TICK_SEC | 5 (:703) | unset |
| AGENT_UNMAPPED_VERBOSE | false (:863) | unset |
| ONBOARD_API_ENABLED / ONBOARD_API_KEY / ONBOARD_API_PORT / ONBOARD_API_MAX_BODY_BYTES | false / "" / 9105 / 0 (:668-683) | unset in compose (may come via .env) |
| AGENT_LINK_HEALTH_ENABLED | true (:1955) | unset, so it is ON if a DSN resolves |
| AGENT_REGISTER_DSN, or DB_USER/DB_PASSWORD/DB_HOST(default postgres)/DB_PORT/DB_NAME(default packiot)/DB_SSLMODE | (:1759-1779) | not set in the block. `.env` is loaded, and compose :362 interpolates `${AGENT_REGISTER_DSN}` from .env, so it likely exists there (UNPROVEN) |

### 3. PostgreSQL (all optional; connects only if a DSN resolves)
- **Tag-map source.** Without AGENT_PROFILE_PATH the function returns `no_profile` with no DB access (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1634-1638). This is the staging case per compose.
- **PLC link health.** `startLinkHealth` (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1954-1988; wired in single mode at :630). Pool at :1964. WRITE `silver.plc_link_minutes` (INSERT … ON CONFLICT DO UPDATE), with a READ join on `core.client_descriptors` (`services/sparkplug-decoder/internal/agent/linkhealth/linkhealth.go:161-172`).
- Capture: needs a profile, so OFF.
- Dynamic SQL: none. LISTEN/NOTIFY: none.

### 4. RabbitMQ
None (the agent does not import `internal/amqp` or `internal/secrets`; searched).

### 5. MQTT (from `docs/clients/cpack-agent.yaml`)
- SUBSCRIBE raw tags `edge/raw/cpack/#` on `tcp://mosquitto:1883` (yaml `:105-106`; subscribe at `services/sparkplug-decoder/internal/agent/rawmqtt/rawmqtt.go:181`, broker from `cfg.Sparkplug.InternalBroker` at services/sparkplug-decoder/cmd/sparkplug-agent/main.go:547). On staging this is idle because tags arrive over HTTP.
- PUBLISH to uplink `tcp://mosquitto:1883` (yaml `:107`):
  - `spBv1.0/CPACK/NBIRTH|NDATA/cpack-tee`
  - NDEATH registered as Last-Will (`services/sparkplug-decoder/internal/agent/uplink/uplink.go:111-121,161-169`; publish `:383`)
- SUBSCRIBE `spBv1.0/CPACK/NCMD/cpack-tee` for rebirth (`services/sparkplug-decoder/internal/agent/uplink/uplink.go:121,260`).

### 6. Redis
None.

### 7. HTTP
- EXPOSED on `:9104`: `POST /v1/tags`, plus `POST /v1/counters` when numeric ingest is on (`services/sparkplug-decoder/internal/agent/httpingest/httpingest.go:198-200`). Auth is the header `X-Ingest-Key` (constant-time compare, `:216`); optional `X-Ingest-Group` (`:246`).
- EXPOSED on `:9103`: `/healthz`, `/health`, `/metrics` (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:654-657 → shared health server).
- Optional `:9105` onboard API (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:668-690).
- OUTBOUND: none found (searched `http.NewRequest|http.Get|http.Post` in cmd/sparkplug-agent + internal/agent; the only hit is `services/sparkplug-decoder/internal/agent/onboard/helpers.go:41`, which belongs to the onboard CLI tooling).

### 8. External dependencies
- None required.
- Optional mTLS file refs for uplink (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:448-450).
- Internet ingress: the real CPACK Node-RED tee POSTs here through nginx (comment at compose :250-253; that nginx config is outside this scope).

### 9. Health / ports
`/healthz` on 9103. The compose healthcheck runs `sparkplug-agent --healthcheck` (:299), which GETs `127.0.0.1:9103/healthz` (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1893-1894). Ingest is on 9104, with no host port published.

### 10. UNPROVEN
- Whether `.env` carries AGENT_REGISTER_DSN / DB_USER / DB_PASSWORD. This decides whether link-health writes `silver.plc_link_minutes` from this container.
- Whether `.env` sets ONBOARD_API_ENABLED.
- Whether the `cpack-tee` profile is active.

---

## sparkplug-agent-shared

### 1. Build
`compose.staging.yml:322-388`. Profile `shared-tee` (`:323`). Context SD (`:325`), entrypoint `/usr/local/bin/sparkplug-agent` with no `--config`, which selects multi mode (`:327`). Mounts `docs/clients/tenants` (`:365`), `docs/clients/tenant-profiles` (`:367`) and the outbox volume (`:368`).

### 2. Env vars
Same binary and same table as sparkplug-agent-cpack. Values that differ on staging:

| Var | Code ref | Staging |
|---|---|---|
| AGENT_TENANTS_DIR | services/sparkplug-decoder/cmd/sparkplug-agent/main.go:199 | /etc/packiot/tenants (:334) |
| AGENT_OUTBOX_DIR | default /var/lib/edge-transformer/outbox (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1104) | same (:335) |
| AGENT_HTTP_INGEST_ENABLED / AGENT_INGEST_PORT / AGENT_INGEST_API_KEY | required in multi mode (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1255-1274) | true / 9104 / ${AGENT_INGEST_API_KEY} (:339-343) |
| AGENT_BIRTH_ALL_MAPPED | | true (:346) |
| AGENT_CAPTURE_ENABLED | services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1434 | true (:354) |
| AGENT_TENANTS_PROFILE_DIR | services/sparkplug-decoder/cmd/sparkplug-agent/main.go:205,1437 | /etc/packiot/tenant-profiles (:358) |
| AGENT_MULTI_DERIVE_ENABLED | default true (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:205,212) | unset |
| AGENT_REGISTER_DSN | services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1760 | ${AGENT_REGISTER_DSN:-} (:362), from .env |
| HEALTH_PORT / MQTT_STALE_THRESHOLD_SECONDS / LOG_LEVEL | | 9103 / -1 / info (:331-337) |

### 3. PostgreSQL (DSN = AGENT_REGISTER_DSN, value in .env)
| Op | Object | Where |
|---|---|---|
| READ (boot only) | `client_descriptors` (descriptor::text, tenant_code, updated_at) | `services/sparkplug-decoder/cmd/sparkplug-agent/tenant_rules.go:33-35`. Pool at services/sparkplug-decoder/cmd/sparkplug-agent/main.go:213-214, closed after boot (:230-232) |
| READ (poll every 300 s) | `client_descriptors.status` | `services/sparkplug-decoder/internal/agent/agentcfg/descriptor_pg.go:46`. Wired by `wireMultiTenantCapture` services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1433-1475; controller services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1503 |
| WRITE (upsert) | `capture_observations` (id_enterprise, topic, count_index, metric_suffix, first/last_seen_ts, observed_count) | `services/sparkplug-decoder/internal/agent/capture/capture_pg.go:33-41` |
| WRITE (upsert) + READ join | `silver.plc_link_minutes` ← `core.client_descriptors` | `services/sparkplug-decoder/internal/agent/linkhealth/linkhealth.go:161-172`. Wired via `startLinkHealth` at services/sparkplug-decoder/cmd/sparkplug-agent/main.go:290 → :1954 |
| READ (only if a register tag map is selected) | `packml_register`, `equipments`, `areas`, `sites` | `services/sparkplug-decoder/internal/agent/agentcfg/register_pg.go:46-58`. In multi mode the tag map is set as `tenants_dir_static` (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:267), so this is single-mode only |

- `client_descriptors`/`capture_observations` are unqualified; `silver.`/`core.` are qualified.
- Dynamic SQL: none.
- LISTEN/NOTIFY: none.

### 4. RabbitMQ
None.

### 5. MQTT (from `docs/clients/tenants/*.yaml`)
- Per tenant: SUBSCRIBE raw `edge/raw/cpack/#` (`docs/clients/tenants/cpack.yaml:105-106`) and `edge/raw/bispharmastaging/#` (`docs/clients/tenants/bispharma.yaml:5-6`). The comments say these are idle in multi mode, where HTTP is the ingest (services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1256).
- PUBLISH:
  - `spBv1.0/CPACK/{NBIRTH,NDATA,NDEATH}/cpack-tee` (docs/clients/tenants/cpack.yaml:93,98,107)
  - `spBv1.0/BISPHARMASTAGING/{…}/bispharmastaging-tee` (docs/clients/tenants/bispharma.yaml:2-3,7)
  - Both go to `tcp://mosquitto:1883`, via services/sparkplug-decoder/internal/agent/uplink/uplink.go:111-121,383.
- SUBSCRIBE the NCMD of each tenant (services/sparkplug-decoder/internal/agent/uplink/uplink.go:260).

### 6. Redis
None.

### 7. HTTP
- EXPOSED on `:9104`: `POST /v1/tags` (and `/v1/counters`), routed by `X-Ingest-Group` or the body group to a tenant pipeline (services/sparkplug-decoder/internal/agent/httpingest/httpingest.go:198-200,246; multi server at services/sparkplug-decoder/cmd/sparkplug-agent/main.go:1254-1290).
- EXPOSED on `:9103`: health/metrics.
- Public front-door nginx `ingest.staging…:8449` (comment :320; edge-api's `SSM_EDGE_INGEST_URL` at compose :591).
- OUTBOUND: none.

### 8. External dependencies
None in code. Ingress from client factory boxes over the internet goes through nginx (outside this scope).

### 9. Health / ports
Same as cpack (9103 /healthz, `--healthcheck` at compose :379).

### 10. UNPROVEN
- The AGENT_REGISTER_DSN value (host, role, db). It is in `.env`.
- The schema / search_path for `capture_observations` and `client_descriptors`.
- Whether the `shared-tee` profile is running.

---

## s7-softplc

### 1. Build
`compose.staging.yml:404-423`. Profile `s7`. Context SD, entrypoint `/usr/local/bin/s7-softplc`, which is `SD/cmd/s7-softplc` (`services/sparkplug-decoder/Dockerfile:39`).

### 2. Env vars
| Var | Default (SD/cmd/s7-softplc/main.go) | Staging |
|---|---|---|
| LISTEN_ADDR | :102 (:36) | :102 (:410) |
| S7_DB | 100 (:37) | 100 (:411) |
| SOFTPLC_TICK_SEC | 5 (:38) | 5 (:412) |
| SOFTPLC_PROCESSED_STEP | 20 (:39) | unset |
| SOFTPLC_CONSUMED_STEP | 1 (:40) | unset |
| SOFTPLC_SPEED | 42.5 (:41) | unset |

### 3. PostgreSQL, 4. RabbitMQ, 5. MQTT, 6. Redis
None (searched in cmd/s7-softplc).

### 7. HTTP
None. EXPOSES S7comm ISO-on-TCP via `net.Listen("tcp", addr)` (`services/sparkplug-decoder/internal/s7/softplc/softplc.go:112`; server built at services/sparkplug-decoder/cmd/s7-softplc/main.go:52).

### 8. External dependencies
None.

### 9. Health / ports
TCP 102 only. No healthcheck.

### 10. UNPROVEN
None beyond profile activation.

---

## s7-reader

### 1. Build
`compose.staging.yml:425-452`. Profile `s7`. Entrypoint `/usr/local/bin/s7-reader`, which is `SD/cmd/s7-reader` (`services/sparkplug-decoder/Dockerfile:29`).

### 2. Env vars (SD/cmd/s7-reader/main.go)
| Var | Default | Staging |
|---|---|---|
| MQTT_BROKER_URL | tcp://mosquitto:1883 (:47) | same (:431) |
| S7_EDGE_NODE | s7-reader (:48) | s7-reader (:436) |
| S7_GROUP | INCOPLAST (:49) | INCOPLAST (:435) |
| S7_HOST | "" (:50) | s7-softplc:102 (:432) |
| S7_RACK / S7_SLOT | 0 / 2 (:51-52) | 0 / 2 (:433-434) |
| S7_TICK_SEC | 5 (:53) | 5 (:437) |
| S7_DB | 100 (:54) | unset |
| CLIENT_CONFIG | "" (:55) | unset |
| S7_ENDPOINT | "" (:56) | unset |
| **RAW_EMIT** | **true** (:57) | unset |
| TENANT | lower(group) (:58,62-63) | unset |
| PLC_HOST_<NAME> | `services/sparkplug-decoder/internal/rawemit/rawemit.go:63` | unset |

### 3. PostgreSQL, 4. RabbitMQ, 6. Redis
None.

### 5. MQTT
- With the code default RAW_EMIT=true, it PUBLISHES raw-tag envelopes to **`edge/raw/incoplast`** (`services/sparkplug-decoder/internal/rawemit/rawemit.go:90,151`; services/sparkplug-decoder/cmd/s7-reader/main.go:70-76). It does **not** publish SparkPlug.
- The legacy path (RAW_EMIT=false) publishes `spBv1.0/INCOPLAST/NBIRTH|NDATA/s7-reader` (services/sparkplug-decoder/cmd/s7-reader/main.go:244,290).
- **Contract mismatch:** the compose comment says the reader goes "→ SparkPlug B … mosquitto → edge-transformer" (:395-399). But with RAW_EMIT defaulting to true, it emits `edge/raw/incoplast`, and no staging agent subscribes to that topic (the agent raw topics are cpack and bispharmastaging only).

### 7. HTTP
None.

### 8. External dependencies
None. It talks S7 to `s7-softplc:102`.

### 9. Health / ports
None.

### 10. UNPROVEN
Whether anything on staging consumes `edge/raw/incoplast` (searched `edge/raw/incoplast` and `raw_topic` in `docs/clients`: no subscriber).

---

## bispharma-twin

### 1. Build
`compose.staging.yml:2321-2380`. No profile (always present). Gated by BISPHARMA_TWIN_ENABLED. Context SD, entrypoint `/usr/local/bin/bispharma-twin`, which is `SD/cmd/bispharma-twin` (`services/sparkplug-decoder/Dockerfile:58`). Mounts `docs/clients/tenants` read-only (`:2366`) and the volume `bispharma-twin-state` (`:2368`).

### 2. Env vars (SD/cmd/bispharma-twin/main.go)
| Var | Default | Staging |
|---|---|---|
| BISPHARMA_TWIN_ENABLED | false, idle (:110) | ${BISPHARMA_TWIN_ENABLED:-false} (:2332) |
| TWIN_BROKER | tcp://mosquitto:1883 (:184) | same (:2336) |
| TWIN_GROUP | BISPHARMASTAGING (:185) | same (:2337) |
| TWIN_EDGE_NODE | bispharmastaging-twin (:186) | same (:2338) |
| TWIN_LINE | L01 (:187) | ${BISPHARMA_TWIN_LINE:-ALL} (:2341) |
| TWIN_TENANT_CONFIG | /etc/packiot/tenants/bispharma.yaml (:188) | same (:2342) |
| TWIN_INTERVAL_SEC | 15 (:189) | ${…:-15} (:2343) |
| TWIN_RATE_PER_MIN | 600 (:190) | ${…:-50} (:2348) |
| TWIN_SCRAP_RATE | 0.03 (:191) | ${…:-0.03} (:2349) |
| TWIN_STOP_PROB / _MIN_SEC / _MAX_SEC | 0.03 / 120 / 600 (:192-194) | same defaults (:2356-2358) |
| TWIN_CLIENT_ID | bispharma-twin (:195) | unset |
| TWIN_STATE_FILE | "" (:196) | /var/lib/bispharma-twin/totalizers.json (:2362) |

### 3. PostgreSQL, 4. RabbitMQ, 6. Redis, 7. HTTP
None (searched `pgx|sql|amqp|redis|ListenAndServe|http\.` in cmd/bispharma-twin).

### 5. MQTT
- PUBLISH `spBv1.0/BISPHARMASTAGING/NBIRTH/bispharmastaging-twin` (`:564`) and `…/NDATA/…` (`:578,583`).
- SUBSCRIBE `…/NCMD/bispharmastaging-twin` for rebirth (`:597-598`).

### 8. External dependencies
None.
- Local file I/O: reads the tenant yaml and reads/writes the state file (`:362-365`).

### 9. Health / ports
None (no healthcheck in compose, no listener).

### 10. UNPROVEN
The value of BISPHARMA_TWIN_ENABLED in `.env`.

---

## stream-engine

Paths are relative to the repo root. `SE` = `services/stream-engine`. Staging values come from `compose.staging.yml` (`CS`).

### 1. Build
- Compose service: `CS:1788` (`build: ./services/stream-engine`, `CS:1789`). Container `stream-engine` (`CS:1790`), static IP 172.18.0.20 with alias `oeecloud-worker` (`CS:2187-2188`). Replicas: `${OEECLOUD_WORKER_REPLICAS:-1}` (`CS:2182`).
- Dockerfile: `services/stream-engine/Dockerfile:22-24` builds only `./cmd/oeecloud-worker` into `/out/stream-engine`. Entrypoint is `/usr/local/bin/stream-engine` (`services/stream-engine/Dockerfile:35`). Image is distroless (`services/stream-engine/Dockerfile:28`).
- Not deployed: `SE/cmd/port-parity/main.go` (a legacy-vs-Go differential harness, `services/stream-engine/cmd/port-parity/main.go:1-8`) and `SE/cmd/recompute-render/main.go` (renders history-recompute SQL with "No database access", `services/stream-engine/cmd/recompute-render/main.go:1-2`). Neither is built by `SE/Dockerfile`, which has a single `go build` (line 22-24).
- Extra entrypoint mode: `--identity-sentinel`, a one-shot F3 int-overflow gate run from CI with `docker exec` (`services/stream-engine/cmd/oeecloud-worker/main.go:55-62`). It is SELECT-only on `gold` (`services/stream-engine/internal/bake/sentinel.go:128,153`).
- `depends_on`: rabbitmq healthy, pgbouncer started, db-migrate completed (`CS:2193-2202`). `env_file: [.env]` (`CS:1792`).

### 2. Env vars (code default → staging value)
All of these are read in `services/stream-engine/internal/config/config.go:427-537` (helpers at `:553-570`) unless noted otherwise.

| Var | Default (file:line) | Staging (CS line) |
|---|---|---|
| AWS_REGION | us-east-1 (:429) | us-east-1 (1883) — **AWS** |
| PG_SECRET_ID | packiot/staging/db (:430) | same (1884) — **AWS SM**. Ignored when CREDS_SOURCE=env |
| RABBITMQ_SECRET_ID | packiot/staging/rabbitmq-stream-engine-creds (:431) | same (1920) — **AWS SM**. Ignored when CREDS_SOURCE=env |
| CREDS_SOURCE | unset (`services/stream-engine/internal/secrets/secrets.go:122,170`) | `env` (1885). Skips Secrets Manager for **both** DB and AMQP |
| DB_HOST / DB_PORT / DB_USER / DB_PASSWORD / DB_NAME | postgres / 5432 / required / required / packiot (`services/stream-engine/internal/secrets/secrets.go:242-249`) | 10.10.10.89 / 5432 / ${POSTGRES_USER} / ${POSTGRES_PASSWORD} / packiot_analytics (1904-1908) |
| RABBITMQ_USER / RABBITMQ_PASSWORD | required when CREDS_SOURCE=env (`services/stream-engine/internal/secrets/secrets.go:267-271`) | **not in the compose env block**, so they must come from `.env` (UNPROVEN) |
| RABBITMQ_HOST / RABBITMQ_PORT | rabbitmq / 5672 (:432-433; `services/stream-engine/internal/secrets/secrets.go:272-275`) | rabbitmq / 5672 (1921-1922) |
| SOURCE_EXCHANGE | oee (:434) | oee (1923) |
| WORKER_QUEUE | stream-engine-q (:435) | stream-engine-q (1924) |
| RETRY_EXCHANGE / RETRY_QUEUE | oee-retry / stream-engine-q-retry-30s (:436-437) | same (1933-1934) |
| FAILED_EXCHANGE / FAILED_QUEUE | oee-failed / stream-engine-q-failed (:438-439) | same (1935-1936) |
| RETRY_TTL_MS / MAX_RETRIES / PREFETCH | 30000 / 5 / 50 (:440-442) | 30000 / 5 / 50 (1937-1939) |
| CONSUME_LANES | 1 (:443) | 4 (1946) |
| TENANT_DISCOVERY_INTERVAL_SECONDS | 60 (:444) | 60 (2160) |
| WORKER_POOL_SAC_ENABLED | false (:445) | false (2170) |
| WORKER_TENANT_ALLOWLIST | "" = all (:502) | `${WORKER_TENANT_ALLOWLIST:-cpack,sbxcpack,bispharmastaging}` (1932) |
| HEALTH_PORT | 9101 (:446; `services/stream-engine/cmd/oeecloud-worker/main.go:673`) | 9101 (1956) |
| LOG_LEVEL | info (:447) | info (1794) |
| POSTGRES_ANALYTICS_DB_NAME | "" (:448) | packiot_analytics (1963) |
| POSTGRES_MAX_CONNS / POSTGRES_ANALYTICS_MAX_CONNS | 5 / 15 (:449-450) | 5 / 15 (1913-1914) |
| SHIFT_RESOLVER_ENABLED / SHIFT_FILL_FOLDED | false / false (:451-452) | true / true (1970, 1955) |
| SHIFT06_REPORT_ENABLED / _INTERVAL_MINUTES / _CUSTOMER_ID | false / 15 / 6 (:453-455) | true / 15 / unset (1978-1979) |
| SAP13_REPORT_ENABLED / _INTERVAL_MINUTES / _CUSTOMER_ID / SAP13_REASONS_FROM_DIM | false / 15 / 13 / false (:456-459) | true / 15 / unset / false (1987-1995) |
| EVENTS_DERIVER_ENABLED / _INTERVAL_MINUTES | false / 1 (:460-461) | true / unset (2000) |
| EVENTS_EXCLUDED_AREAS / EVENTS_EXCLUDED_ENTERPRISES | "" (:462-463) | unset |
| EVENTS_WIDEROW_STATE_ENTERPRISES | "" (:464) | 4 (2008) |
| CPAC_EVENT_DERIVATION_ENABLED / _INTERVAL_MINUTES | false / 1 (:465-466) | **not in compose**. The comment at CS:1864 says CPAC_EVENT_ENTERPRISES is in `.env` (UNPROVEN) |
| CPAC_EVENT_ENTERPRISES | "" (:467) | from `.env` per comment CS:1864 (UNPROVEN) |
| CPAC_EVENT_LIVE_ENTERPRISES | "" (:468) | 5 (1874). Only takes effect if CPAC_EVENT_DERIVATION_ENABLED=true (`services/stream-engine/cmd/oeecloud-worker/main.go:485`) |
| CPAC_STOP_THRESHOLD_DEFAULT_SEC / CPAC_EVENT_TARGET_TABLE | 300 / equipment_events_cpac_shadow (:469-470) | unset |
| EVENTS_CLOSE_STALE_ENABLED / _INTERVAL_SEC / _ENTERPRISES / _THRESHOLD_DEFAULT_SEC / _HORIZON_HOURS / _LONG_HORIZON_DAYS | false / 60 / "" / 300 / 72 / 60 (:471-476) | true / – / "3,4,5,2000003" (1849, 1860) |
| PO_CONTROL_ENABLED | false (:477) | true (2012) |
| BOXES13_REPORT_ENABLED / BOXES13_INTERVAL_MINUTES / BOXES_BRIDGE_ENABLED | false / 5 / false (:478,506,479) | true / – / true (2014, 2017) |
| UNS_REFRESH_ENABLED / UNS_INTERVAL_MINUTES | false / 5 (:480-481) | true (2024) |
| UNS_CURRENT_METRICS_ENABLED / _INTERVAL_MINUTES | false / 1 (:482-483) | true (2037) |
| PO_RECALC_ENABLED / _INTERVAL_MINUTES / PO_RECALC_WINDOW / PO_RECALC_EXCLUDED_ENTERPRISES / PO_RECOMPUTE_SWEEP_HOURS | false / 1 / "1 month" / "6" / 24 (:484-488) | true (2039) |
| PO_AVAILABILITY_ENABLED | false (:518) | true (2048) |
| RUNTIME_PROVISION_ENABLED / _INTERVAL_HOURS | false / 6 (:489-490) | true (2049) |
| RUNTIME_ROLLUP_ENABLED | false (:491) | true (2050) |
| DQ_ALARMS_ENABLED / SILVER_CLAMP_ENABLED | true / true (:492-493) | unset |
| CHANGEOVER_AVAILABILITY_ENABLED | false (:494) | unset |
| ROLLUP_BACKFILL_ENABLED / _LIMIT / _INTERVAL_SECONDS | true / 200 / 30 (:495-496,499) | true / 50 / 7 (1813, 1826, 1820) |
| ROLLUP_SHIFT_LIMIT | 300 (:497) | 75 (1842) |
| BAKE_ENTERPRISE_IDS | "3" (:498) | unset |
| LEGACY_INGEST_ENABLED | true (:500) | true (2058) |
| ROLLUP_MACHINE_LEVEL_ENTERPRISES | "6" (:501) | unset |
| SYNC06_REPORT_ENABLED / _INTERVAL_MINUTES / SYNC06_ENTERPRISE_ID | false / 15 / 6 (:503-505) | true (2016) |
| COUNTERS_ONLY_AVAILABILITY_ENABLED / _EQUIPMENTS / COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS | false / "" / 300 (:508-510) | true / "68,69,70,71,72" / 300 (2081, 2094, 2095) |
| COUNTERS_ONLY_LINE_LEAD_ENABLED / _ENTERPRISES | false / "" (:511-512) | true / "3,5,2000003" (2105, 2116) |
| OEE_AVAIL_FLOOR_ENABLED / OEE_CANONICAL_APQ_ENABLED | false / false (:514-515) | true / true (1806-1807) |
| AVAILABILITY_EXCLUSIONS_ENABLED / STRANDED_FLAG_SWEEP_ENABLED | true / true (:516-517) | unset |
| INCREMENT_SANITY_CLAMP_ENABLED / _K / _MIN_DT_SECONDS / _SPIKE_FLOOR / _SPIKE_FRACTION | false / 4.0 / 60 / 1000 / 0.5 (:520-527) | true / – / – / – / 0.5 (2128, 2136) |
| PROVISIONAL_SPEED_INFERENCE_ENABLED / _EQUIPMENTS / _WINDOW_HOURS / _MIN_MINUTES / _PERCENTILE / _FLOOR | false / "" / 72 / 240 / 0.95 / 1.0 (:529-534) | unset |
| BRONZE_RAW_APPEND | false (:536) | true (2154) |
| OTEL_EXPORTER_OTLP_ENDPOINT | unset = tracing off (`services/stream-engine/internal/tracing/tracing.go:39`) | http://tempo:4317 (1878) |
| OTEL_TRACES_SAMPLER_ARG | (`services/stream-engine/internal/tracing/tracing.go:91`) | unset |

Stale compose vars that the code does not read: COUNTERS_ONLY_* vars are all read, but none of the SPEED33_*, REFSYNC_*, or SHADOW_GO_PORT_ENABLED vars are (compose comments CS:1976, 2018-2022 say they were removed, and grep of config.go finds none).

### 3. PostgreSQL
- **Connection.** Two pgx pools, both direct to `10.10.10.89:5432`, which bypasses pgbouncer by design (CS:1886-1904). The role is `${POSTGRES_USER}` (CS:1906). The DSN is built with `sslmode=disable` (`services/stream-engine/internal/secrets/secrets.go:216-228`).
  - Main pool: `db.New`, DB = `DB_NAME` = **packiot_analytics** on staging (CS:1908; `services/stream-engine/cmd/oeecloud-worker/main.go:118`).
  - Analytics pool: `db.NewForDatabase(..., POSTGRES_ANALYTICS_DB_NAME="packiot_analytics", app "oeecloud-worker-analytics")` (`services/stream-engine/cmd/oeecloud-worker/main.go:131-132`). On staging, therefore, **both pools point at packiot_analytics**.
  - The analytics pool sets `statement_timeout = 0` per connection (`services/stream-engine/internal/db/pool.go:91`) and uses simple protocol (`services/stream-engine/internal/db/pool.go:67`).
- **Boot side effect.** `SELECT _timescaledb_functions.start_background_workers()` on the analytics pool (`services/stream-engine/cmd/oeecloud-worker/main.go:154`).
- **Destination schemas for background jobs.** Staging uses `flows.Standard` with a non-nil analytics pool → Ev=silver, Ref=core, Silver=silver, Gold=gold, Grain=silver, Config=config (`services/stream-engine/internal/flows/flows.go:80-85`). A prod-shaped deploy (analyticsPool nil) puts everything in `public` (`services/stream-engine/internal/flows/flows.go:91-96`).
- **Ingest routing.** source_type `refactored` → analytics pool with silver/bronze/ev=silver/auth=identity/grain=silver/ref=core/gold=gold (`services/stream-engine/internal/handlers/sparkplug.go:501-503`). source_type "" or unknown → main pool `public` (`:507-509`). source_type `go` → dropped and ACKed (`:206-209`).
- **Dynamic SQL.** Every schema below is `fmt.Sprintf`-injected, never a literal. Table names are also dynamic in these places:
  - grain lists: `services/stream-engine/internal/rollup/grains.go:50-51`, `services/stream-engine/internal/rollup/dq.go:242-249`, `services/stream-engine/internal/rollup/unmetered.go:74-80`, `services/stream-engine/internal/rollup/entity_grains.go:256-266`
  - `uns.go` unsTable/entityTable (`services/stream-engine/internal/uns/uns.go:48,98,105`)
  - `current_rest.go` (`:36,39`)
  - the CPAC target table, set by env CPAC_EVENT_TARGET_TABLE (`services/stream-engine/internal/events/cpac_deriver.go:330,336,363,377`)
- **LISTEN/NOTIFY.** None found (searched: `LISTEN|NOTIFY|pg_notify|WaitForNotification`).
- **Locks.** A session `pg_advisory_lock` is held for provision (`services/stream-engine/internal/rollup/provision.go:80`), and xact try-locks are used for backfill and rollup (`services/stream-engine/internal/rollup/backfill.go:123`, `services/stream-engine/internal/rollup/day.go:231`). Provision sets `search_path TO gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public` (`services/stream-engine/internal/rollup/provision.go:68`).

**Ingest path (per AMQP delivery, `services/stream-engine/internal/handlers/sparkplug.go:216-300`).** Staging schemas resolved:

| Object | R/W | file:line |
|---|---|---|
| silver.equipment_values (UPSERT ×5 metric kinds; shift-fill UPDATE) | W | `services/stream-engine/internal/writers/equipment_values.go:541,574,607,638,668,179` |
| bronze.equipment_values_raw (append) | W | `services/stream-engine/internal/writers/equipment_values.go:784` |
| silver.equipment_events (mint) | W | `services/stream-engine/internal/writers/equipment_values.go:528` |
| bronze.equipment_events_raw | W | `services/stream-engine/internal/writers/equipment_values.go:818` |
| silver.equipment_live_metrics | W | `services/stream-engine/internal/writers/uns_current_metrics.go:52` |
| silver.equipment_values (PO parameters 30700…) | W | `services/stream-engine/internal/writers/po_parameter.go:107,162` |
| silver.data_quality_event (clamp DQ) | W | `services/stream-engine/internal/handlers/sparkplug.go:388,404` |
| silver.equipment_values (totalizer seed) | R | `services/stream-engine/internal/writers/totalizer_seed.go:36` |
| packml_register ⋈ areas ⋈ equipments (**unqualified**, main pool) | R | `services/stream-engine/internal/sparkplug/resolver.go:123-125` |
| packml_register (**unqualified**, tenant discovery) | R | `services/stream-engine/internal/tenants/discovery.go:37-40` |
| core.sites, core.equipments, core.shift_hours (main pool) | R | `services/stream-engine/internal/shiftresolver/resolver.go:183,210,238` |
| client_descriptors (**unqualified**), equipments | R | `services/stream-engine/internal/oeeprofile/oeeprofile.go:46,71-73` |

**pocontrol** (PO lifecycle from params 30700/30800–30899, `services/stream-engine/internal/handlers/sparkplug.go:249-253`). Schemas: Core=core, Gold=gold, Silver=silver, Ev=silver, Identity=identity.

| Object | R/W | file:line |
|---|---|---|
| core.production_orders | R/W | `services/stream-engine/internal/pocontrol/pocontrol.go:143,166,207,271,295,325`; INSERT `services/stream-engine/internal/pocontrol/createpo.go:72` |
| gold.production_orders_runtime | R/W | `services/stream-engine/internal/pocontrol/pocontrol.go:219,254,267,305` |
| silver.equipment_values | W | `services/stream-engine/internal/pocontrol/pocontrol.go:335,347`; `topology.go:35⚠ambiguous[services/sparkplug-decoder/internal/amqp/topology.go|services/stream-engine/internal/amqp/topology.go|services/stream-engine/internal/pocontrol/topology.go],47,56,69`; `services/stream-engine/internal/pocontrol/events_justify.go:141` |
| core.product_families, core.products, core.clients | R/W | `services/stream-engine/internal/pocontrol/createpo.go:49,55,57,60,65-68` |
| core.packml_register (a compat view over core.topic_routing, per `services/stream-engine/internal/flows/flows.go:70-71`) | R/**UPDATE** | `services/stream-engine/internal/pocontrol/topology.go:30,39,40,61` |
| silver.equipment_events | R/W | `services/stream-engine/internal/pocontrol/events_justify.go:88,117,130,137` |
| silver.equipment_events_man | R/W | `services/stream-engine/internal/pocontrol/events_justify.go:98,104,108` |
| identity.user_logs | W | `services/stream-engine/internal/pocontrol/events_justify.go:82,272`; `services/stream-engine/internal/pocontrol/setup_userlog.go:37,80` |
| silver.equipment_live_job | W | `services/stream-engine/internal/pocontrol/setup_userlog.go:27,32` |

**Background jobs** (`services/stream-engine/cmd/oeecloud-worker/main.go:289-518`). Each row gives the flag, the loop, and the objects resolved for staging.

| Job (gate) | Reads | Writes | file:line |
|---|---|---|---|
| shift06 (SHIFT06_REPORT_ENABLED), main pool | serving.report_shift(fn) | customer_reports.shift (DELETE + INSERT) | `services/stream-engine/internal/reports/shift06.go:37,42,51` |
| sap13 (SAP13_REPORT_ENABLED), main pool, embedded SQL | **unqualified**: equipments, equipment_oee_shift, shifts, agg_equipment_values_1min, ca_equipment_boxes_1s, equipment_events, customer_reports.boxes; downtime_reason/equipment_downtime_reason when FROM_DIM | customer_reports.sap_data_sync | `services/stream-engine/internal/reports/sap13_body.sql:17,63,74,83,104,118,259,453`; `services/stream-engine/internal/reports/sap13_reasons_dim.sql:13-15`; exec `services/stream-engine/internal/reports/sap13.go:67` |
| sync06 (SYNC06_REPORT_ENABLED), main pool | serving.data_sync, customer_reports.production_data_sync | customer_reports.production_data_sync (INSERT/UPDATE) | `services/stream-engine/internal/reports/sync06_body.sql:12,15,55,195,277` |
| boxes adapter (BOXES13_REPORT_ENABLED) | config.label_formats, silver.equipment_values, core.equipments | customer_reports.boxes | `services/stream-engine/internal/reports/boxes_adapter.go:38,44,52,62,73,79,89` |
| boxes bridge (BOXES_BRIDGE_ENABLED) | core.box_production_bridges, core.equipments, customer_reports.boxes | silver.equipment_values | `services/stream-engine/internal/reports/boxes_bridge.go:27,32,40,47,62,81` |
| po-runtime-recalc (PO_RECALC_ENABLED) | gold.production_orders_runtime, core.equipments, silver.equipment_values, silver.equipment_events, silver.equipment_categorical_1min, config.equipment_out_of_service | gold.production_orders_runtime, core.production_orders | `services/stream-engine/internal/rollup/compute.go:74-399,349,470-535`; `services/stream-engine/internal/rollup/recalc.go:64-145`; `services/stream-engine/internal/rollup/availability_exclusions_po.go:43-57` |
| stranded sweep (STRANDED_FLAG_SWEEP_ENABLED) | core.equipments | gold.production_orders_runtime, core.production_orders, gold.equipment_oee_shift, gold.equipment_oee_hourly (flag clears) | `services/stream-engine/internal/rollup/stranded.go:43-75` |
| runtime rollup hour (RUNTIME_ROLLUP_ENABLED) | silver.equipment_values, silver.equipment_categorical_1min/_1hour, core.equipments, core.production_targets(%[6]=config? see UNPROVEN), fn piot_get_day_begin_by_equipment, piot_get_shift_hour_begin_by_equipment | gold.equipment_oee_hourly, gold.equipment_oee_daily | `services/stream-engine/internal/rollup/hour.go:49-50,63-356,384-430` |
| rollup shift | core.shifts, core.equipments, silver.equipment_values, silver.equipment_categorical_1hour | gold.equipment_oee_shift, gold.area_oee_shift | `services/stream-engine/internal/rollup/shift.go:71-334,425-436` |
| rollup line-lead / availability / exclusions | silver.equipment_categorical_1min/_1hour, core.equipments, silver.equipment_events, config.equipment_out_of_service | gold.equipment_oee_hourly, gold.equipment_oee_shift | `services/stream-engine/internal/rollup/line_lead.go:103-521`; `services/stream-engine/internal/rollup/availability.go:172-403`; `services/stream-engine/internal/rollup/availability_exclusions.go:46-90` |
| rollup day + grain cascade | gold.equipment_oee_hourly/_daily, core.equipments, core.enterprises, config.production_targets | gold.equipment_oee_daily/_weekly/_monthly | `services/stream-engine/internal/rollup/day.go:69-266`; `services/stream-engine/internal/rollup/grains.go:50-261` |
| entity grains | gold.equipment_oee_daily/_shift, core.areas, core.equipments, fn piot_get_day_begin_by_area/_site | gold.area_oee_daily/_shift, gold.site_oee_daily/_shift | `services/stream-engine/internal/rollup/entity_grains.go:54-282` |
| DQ + silver clamp (DQ_ALARMS/SILVER_CLAMP) | gold.equipment_oee_{shift,hourly,daily,weekly,monthly}, core.equipments | silver.data_quality_event (INSERT), gold.<grain> (clamp UPDATE) | `services/stream-engine/internal/rollup/dq.go:242-249,284-298,334,384`; `services/stream-engine/internal/rollup/silver.go:181-229,271-274` |
| unmetered null | core.equipments | gold.equipment_oee_{hourly,daily,weekly,monthly,shift,shift_weekly,shift_monthly} | `services/stream-engine/internal/rollup/unmetered.go:74-134` |
| hour backfill (ROLLUP_BACKFILL_ENABLED) | same as hour | gold.equipment_oee_hourly | `services/stream-engine/internal/rollup/backfill.go:68-207` |
| runtime provision (RUNTIME_PROVISION_ENABLED) | – | CALLs fns piot_create_{equipment_oee_hourly,daily,weekly,monthly,shift,shift_weekly,shift_monthly; area_oee_daily,shift; site_oee_daily,shift} via search_path | `services/stream-engine/internal/rollup/provision.go:38-50,68` |
| infer speed (PROVISIONAL_SPEED_INFERENCE_ENABLED) — OFF on staging | silver.equipment_categorical_1min | core.equipments.production_speed | `services/stream-engine/internal/rollup/inferspeed.go:115,121,178` |
| UNS refresh (UNS_REFRESH_ENABLED) | core.equipments/areas/sites/enterprises/shifts, silver.agg_equipment_values_1hour, gold.equipment_oee_daily/_shift | silver.<uns tables> (INSERT/UPDATE), silver.equipment_live_metrics, silver.equipment_live_day/_shift | `services/stream-engine/internal/uns/uns.go:48-324` |
| UNS current_rest (part of UNS jobs) | gold.<rt day tables>, gold.area_oee_shift, core.production_orders/products/product_families/clients/enterprises/areas/equipments, gold.production_orders_runtime | silver.<uns day tables>, silver.area_live_shift, silver.equipment_live_job | `services/stream-engine/internal/uns/current_rest.go:36-182` |
| UNS current metrics (UNS_CURRENT_METRICS_ENABLED) | silver.equipment_values, silver.equipment_events, core.equipments/areas/sites | silver.equipment_live_metrics | `services/stream-engine/internal/uns/current_metrics.go:128-270` |
| events deriver (EVENTS_DERIVER_ENABLED) | silver.ca_discrete_changes_1s, core.equipments | silver.equipment_events (DELETE + INSERT) | `services/stream-engine/internal/events/deriver.go:72-126` |
| CPAC deriver (CPAC_EVENT_DERIVATION_ENABLED; live instance target `equipment_events` when CPAC_EVENT_LIVE_ENTERPRISES set) | silver.equipments(?, %[1]=Ev), core.equipments, silver.equipment_categorical_1min, silver.plc_link_minutes, silver.plc_endpoint_equipment | silver.<CPAC_EVENT_TARGET_TABLE> and silver.equipment_events (DELETE + INSERT) | `services/stream-engine/internal/events/cpac_deriver.go:133-436`; `services/stream-engine/cmd/oeecloud-worker/main.go:465-502` |
| stale-open closer (EVENTS_CLOSE_STALE_ENABLED) | silver.equipment_events, silver.equipment_categorical_1min, core.equipments | silver.equipment_events (UPDATE) | `services/stream-engine/internal/events/closer.go:106-260` |
| identity sentinel (CLI only) | gold.equipment_oee_shift, gold.production_orders_runtime, core.equipments | – | `services/stream-engine/internal/bake/sentinel.go:53-70,153` |

### 4. RabbitMQ
- **Credentials.** On staging they come from env RABBITMQ_USER/PASSWORD because CREDS_SOURCE=env (`services/stream-engine/internal/secrets/secrets.go:170-171,266-286`). Otherwise they come from Secrets Manager (`services/stream-engine/internal/secrets/secrets.go:173-186`).
- **Exchanges.** Declared topic and durable: `oee`, `oee-retry`, `oee-failed` (`services/stream-engine/internal/amqp/topology.go:99-103`).
- **Legacy queue.** `stream-engine-q` (DLX → oee-retry) is bound to `oee` with key `sparkplug.data` only, after unbinding `#` (`topology.go:120⚠ambiguous[services/sparkplug-decoder/internal/amqp/topology.go|services/stream-engine/internal/amqp/topology.go|services/stream-engine/internal/pocontrol/topology.go]-131`).
- **Retry queue.** `stream-engine-q-retry-30s` (TTL 30000, DLX → `oee`) is bound `#` on oee-retry (`topology.go:133⚠ambiguous[services/sparkplug-decoder/internal/amqp/topology.go|services/stream-engine/internal/amqp/topology.go|services/stream-engine/internal/pocontrol/topology.go]-141`).
- **Failed queue.** `stream-engine-q-failed` is bound `#` on oee-failed (`topology.go:144⚠ambiguous[services/sparkplug-decoder/internal/amqp/topology.go|services/stream-engine/internal/amqp/topology.go]-149`).
- **Per-tenant queues.** One set per tenant `t` (discovered from packml_register ∩ allowlist): `stream-engine-q-<t>` (DLX oee-retry, optional x-single-active-consumer), `-<t>-retry-30s`, and `-<t>-failed`, all bound on `sparkplug.data.<t>` (`topology.go:196⚠ambiguous[services/sparkplug-decoder/internal/amqp/topology.go|services/stream-engine/internal/amqp/topology.go]-236`).
- **Consumption.** Consumes the legacy queue and every tenant queue, with periodic re-discovery (`services/stream-engine/internal/amqp/consumer.go:259-299`). The dispatcher handles keys `sparkplug.data` and `sparkplug.data.<tenant>` (`services/stream-engine/cmd/oeecloud-worker/main.go:556-559`).
- **Ack mode.** Manual (`autoAck=false`, `services/stream-engine/internal/amqp/consumer.go:399`) with QoS prefetch (`:394`). A handler error causes `Nack(requeue=false)` → retry DLX (`:585`). Once x-death ≥ MAX_RETRIES, the message is published to `oee-failed` with the original routing key and then ACKed (`:548-557`). Success is acked at `:600`.
- **Published.** Only the republish to FAILED_EXCHANGE (`services/stream-engine/internal/amqp/consumer.go:551`). No other publish was found.
- **Payload contract.** JSON `{timestamp, gateway, metrics[{name,timestamp,value,counter,curspeed,alias,faults,id}], source_type}` (`services/stream-engine/internal/sparkplug/parse.go:31-52`).

### 5. MQTT
None found (searched: `mqtt|paho` in SE `*.go` and `go.mod`).

### 6. Redis
None found (searched: `redis` in `*.go` and `go.mod`).

### 7. HTTP
- **Exposed.** `:HEALTH_PORT` (9101) serves `/health` and `/metrics` (`services/stream-engine/internal/health/health.go:42,44`). The server starts at `services/stream-engine/cmd/oeecloud-worker/main.go:630-631`. No host port is published (CS:2178-2179 comment).
- **Outbound.** Only the self-probe `GET http://127.0.0.1:<port>/health` (`services/stream-engine/cmd/oeecloud-worker/main.go:676-677`). Otherwise none found (searched: `http.Get|http.Post|http.NewRequest|http.Client`).

### 8. External dependencies
- **AWS Secrets Manager.** `secretsmanager.GetSecretValue` (`services/stream-engine/internal/secrets/secrets.go:96-101`). Imports at `:28-29`. Bypassed on staging by CREDS_SOURCE=env (CS:1885). With CREDS_SOURCE unset, it needs AWS creds/IMDS and region.
- **OTLP gRPC.** Traces go to `tempo:4317` (CS:1878; `services/stream-engine/internal/tracing/tracing.go:39`). The `otelpgx` DB spans are listed in `SE/go.mod`.
- **Other.** No JWT, S3, DuckDB, or Parquet usage was found (searched: `jwt|jwks|cognito|firebase|s3|duckdb|parquet`).

### 9. Health and ports
- `/health` on 9101. JSON `healthy` flag (`services/stream-engine/cmd/oeecloud-worker/main.go:664-699`). Compose healthcheck is `stream-engine --healthcheck` (CS:2206-2207). Dockerfile `EXPOSE 9101` (`services/stream-engine/Dockerfile:33`).

### 10. UNPROVEN
- RABBITMQ_USER/RABBITMQ_PASSWORD and CPAC_EVENT_DERIVATION_ENABLED / CPAC_EVENT_ENTERPRISES are not in the compose env block. They must come from `/opt/packiot/.env` (`env_file`, CS:1792), which is not in the repo. Whether the live CPAC instance actually runs on staging cannot be shown statically.
- The `search_path` of `${POSTGRES_USER}` on packiot_analytics is unknown. It decides where these unqualified names resolve: `packml_register` / `areas` / `equipments` (`services/stream-engine/internal/sparkplug/resolver.go:123-125`, `services/stream-engine/internal/tenants/discovery.go:38`), `client_descriptors` (`services/stream-engine/internal/oeeprofile/oeeprofile.go:46`), the sap13 body tables, and `piot_get_*` / `piot_create_*` functions outside provision. Searched: `search_path` (only `services/stream-engine/internal/rollup/provision.go:68` sets it).
- The exact %[n] mapping for `services/stream-engine/internal/rollup/hour.go:312` / `services/stream-engine/internal/rollup/shift.go:305` `%[6]s.production_targets` is unresolved. fmtRD passes the 5 dest schemas plus extras (`services/stream-engine/internal/rollup/hour.go:50`); the targets step passes d.ConfigSchema as extra (`services/stream-engine/internal/rollup/hour.go:428`), so that is **likely config.production_targets**, but this was not traced line by line. The same applies to `services/stream-engine/internal/events/cpac_deriver.go:133` `%[1]s.equipments` (Ev=silver by arg order, `services/stream-engine/internal/events/cpac_deriver.go:432`). This looks like a view, or a bug if no silver.equipments exists. Not verified.
- The CPAC target table default is `equipment_events_cpac_shadow` (`services/stream-engine/internal/config/config.go:470`). The comment at `services/stream-engine/internal/flows/flows.go:75-76` says it is in silver, but its existence was not checked against the migrations.
- Which DB objects are views and which are tables (for example core.packml_register is described as a compat view at `services/stream-engine/internal/flows/flows.go:70-71`, and it is UPDATEd at `services/stream-engine/internal/pocontrol/topology.go:30`) was not verified against migrations.

## mirror-worker-go

`MW` = `services/mirror-worker-go`.

### 1. Build
- Compose service: `CS:1655`, `build: ./services/mirror-worker-go` (`CS:1656`), container `mirror-worker-go`. It is **profile-gated `legacy-comparator`** (CS:1665), so it is not started by the default staging deploy (RETIRED 2026-08-13 per CS:1658-1664). IP 172.18.0.21 (CS:1758).
- Dockerfile builds `./cmd/mirror-worker-go` (`services/mirror-worker-go/Dockerfile:22-24`). Entrypoint is `/usr/local/bin/mirror-worker-go` (`services/mirror-worker-go/Dockerfile:37`). Distroless.
- **No `env_file`** in the compose block (CS:1655-1775). `depends_on`: pgbouncer and edge-api started (CS:1759-1763).

### 2. Env vars
All read in `services/mirror-worker-go/internal/config/config.go:272-326` unless noted.

| Var | Default | Staging (CS line) |
|---|---|---|
| AWS_REGION | us-east-1 (:272) | us-east-1 (1669) — **AWS** |
| PROD_DB_SECRET_ID | databaseCredentials (:273) | databaseCredentials (1670) — **AWS SM → legacy prod DB** |
| STAGING_DB_SECRET_ID | packiot/staging/db (:274) | same (1671) — **AWS SM** |
| CREDS_SOURCE | unset → Secrets Manager (`services/mirror-worker-go/internal/secrets/secrets.go:92`) | not set, so **SM is used** |
| `<prefix>HOST/PORT/USER/PASSWORD/NAME` (only when CREDS_SOURCE=env; prefix derived from secret id) | postgres / 5432 / required / required / packiot (`services/mirror-worker-go/internal/secrets/secrets.go:201-215`) | n/a |
| SOURCE_NAME | cpack-prod-go (:275) | cpack-prod-go (1672) |
| PROD_ENTERPRISE_ID / STAGING_ENTERPRISE_ID | 1 / 3 (:276-277) | 1 / 3 (1673-1674) |
| POLL_INTERVAL_SEC / BATCH_SIZE / PER_POST_DELAY_MS | 60 / 50 / 50 (:278-280) | 60 / 50 / 50 (1675-1677) |
| STAGING_API_URL | http://edge-api:8080 (:281) | same (1678) |
| SHADOW_VALUE_FANOUT / SHADOW_FANOUT_F2 | false / true (:282-283) | true / false (1687, 1696) |
| POSTGRES_ANALYTICS_DB_NAME / SHADOW_DB_HOST | "" / "" (:284-285) | packiot_analytics / 10.10.10.89 (1697, 1700) |
| EVENT_MIN_OVERLAP_SEC / EVENT_MAX_START_DRIFT_SEC | 30 / 600 (:286-287) | unset |
| HEALTH_PORT | 9102 (:288; `services/mirror-worker-go/cmd/mirror-worker-go/main.go:424`) | 9102 (1679) |
| RECONCILE_ENABLED / _INTERVAL_SEC / _MAX_PER_RUN | true / 300 / 20 (:289-291) | unset |
| RECONCILE_MODE / _CREATE_INTERVAL_SEC / _FINISHER_INTERVAL_SEC | poll / 3 / 300 (:294-296) | tail / 3 / 300 (1736-1738) |
| RECONCILE_FINISHER_ENABLED / _GRACE_MINUTES | false / 30 (:298-299) | true / 30 (1709-1710) |
| RECONCILE_CLOSE_PROD_TERMINAL_ORPHANS | false (:302) | true (1726) |
| RECONCILE_VALUES_ENABLED / _INTERVAL_SEC | true / 30 (:303-304) | unset |
| RECONCILE_EVENTS_ENABLED / _INTERVAL_SEC / _BATCH_SIZE | true / 60 / 200 (:305-307) | unset |
| RECONCILE_EVENTS_CLOSE_SWEEP_* (ENABLED / EVERY_N_TICKS / RECENT_HOURS / TIMEOUT_SEC / BATCH_SIZE) | false / 10 / 72 / 30 / 500 (:309-313) | ENABLED=true (1755) |
| DLQ_RETRY_* (ENABLED / INTERVAL_SEC / MAX_ATTEMPTS / BATCH_SIZE) | true / 300 / 5 / 50 (:315-318) | unset |
| DLQ_REANIMATE_* (ENABLED / INTERVAL_SEC / BATCH_SIZE) | true / 600 / 100 (:319-321) | unset |
| COMPARATOR_ENABLED / _INTERVAL_SEC / _OEE_INTERVAL_SEC / _EVENT_OPEN_STRAND_HOURS | true / 300 / 1800 / 48 (:322-325) | unset |
| LOG_LEVEL | info (:326) | info (1668) |

### 3. PostgreSQL
- **Prod (legacy, SELECT-only per CS:1722-1723).** The pool comes from secret `databaseCredentials` (`services/mirror-worker-go/cmd/mirror-worker-go/main.go:73,84`). Host and DB come from the secret, so they are not visible statically. Reads **unqualified** tables: user_logs (`services/mirror-worker-go/internal/db/prod.go:88,141,195,241,633`), equipment_events (`:278,581,794`), production_orders (`:314,351,430`), production_orders_runtime (`:431,499`), packml_register (`:696`). The translator reads prod/staging sites, areas, packml_register, production_orders, equipment_events, and mirror_id_map (`services/mirror-worker-go/internal/translate/translate.go:65-395`).
- **Staging main pool.** Comes from secret `packiot/staging/db` (`services/mirror-worker-go/cmd/mirror-worker-go/main.go:78,91`). Host and DB come from the secret (pgbouncer vs direct is UNPROVEN).
  - Reads: `enterprises.api_key` (token for edge-api, `services/mirror-worker-go/internal/db/staging.go:142-146`), production_orders, production_orders_runtime, equipment_events, core.equipments (`:956,1258`), core.production_orders ⋈ gold.production_orders_runtime (`:714-715`), silver.equipment_values (`:1564`), and fns piot_get_day_begin_by_equipment / piot_get_shift_hour_begin_by_equipment (`:953-955,1255-1257`).
  - Writes: mirror_id_map (`:195`), ops.mirror_replay_cursor (`:160,176,1285,1300`), ops.mirror_replay_dlq (INSERT/UPDATE/DELETE `:1424-1546`), unqualified production_orders / production_orders_runtime UPDATE (`:426,437,544,559`), unqualified equipment_events INSERT (`:1344`).
- **Shadow fan-out (dynamic schema `%s`).**
  - F2 = `shadow_go_port` on the main pool (`services/mirror-worker-go/internal/db/staging.go:615`), off on staging via SHADOW_FANOUT_F2=false (`services/mirror-worker-go/cmd/mirror-worker-go/main.go:103`; CS:1696).
  - F3 = `public` on the analytics pool, DB=packiot_analytics, host SHADOW_DB_HOST (`services/mirror-worker-go/internal/db/staging.go:618`; `services/mirror-worker-go/cmd/mirror-worker-go/main.go:104-105`).
  - Statements: INSERT %s.equipment_values (`:926,949,1252,1272`), INSERT %s.equipment_events (`:995-1024`), R/W %s.production_orders / %s.production_orders_runtime (`:656,660,770,775,783,805,814`), R %s.equipment_events (`:1164,1183,1223`).
  - Note: F3 is the `public` schema, not the medallion `silver`/`gold`.
- **Comparator.** SELECT-only on both prod and staging. Described at `services/mirror-worker-go/internal/comparator/comparator.go:1-4`; the queries are delegated to the db packages.
- **LISTEN/NOTIFY.** None found (searched: `LISTEN|NOTIFY|pg_notify`).

### 4. RabbitMQ
None found (searched: `amqp|rabbitmq` in `MW/go.mod` and `*.go`).

### 5. MQTT
None found (searched: `mqtt|paho`).

### 6. Redis
None found (searched: `redis`).

### 7. HTTP
- **Exposed.** `:9102` serves `/health` and `/metrics` (`services/mirror-worker-go/internal/health/health.go:155-156`; started `services/mirror-worker-go/cmd/mirror-worker-go/main.go:167-168`).
- **Outbound.** POST `${STAGING_API_URL}<path>?token=<enterprises.api_key>&idEnterprise=<STAGING_ENTERPRISE_ID>` (`services/mirror-worker-go/internal/replay/httputil.go:289-291`; `services/mirror-worker-go/internal/reconcile/http.go:30-31`). Paths:
  - `/api/production-orders/create` (`services/mirror-worker-go/internal/replay/order_created.go:116`; `services/mirror-worker-go/internal/reconcile/reconciler.go:840`)
  - `/api/production-orders/create-and-start` (`services/mirror-worker-go/internal/replay/order_created_started.go:111`)
  - `/api/production-orders/start` (`services/mirror-worker-go/internal/replay/order_started.go:88`; `services/mirror-worker-go/internal/reconcile/reconciler.go:876,961`)
  - `/api/production-orders/stop` (`services/mirror-worker-go/internal/replay/order_stopped.go:74`; `services/mirror-worker-go/internal/replay/order_changed.go:84`)
  - `/api/production-orders/change-status` (`services/mirror-worker-go/internal/replay/order_status_changed.go:67`)
  - `/api/production-orders/replace` (`services/mirror-worker-go/internal/replay/order_replaced.go:66`)
  - `/api/downtimes` (`services/mirror-worker-go/internal/replay/downtime_event_created.go:116`)
- **Client.** Timeout 20 s (`services/mirror-worker-go/cmd/mirror-worker-go/main.go:125`).

### 8. External dependencies
- **AWS Secrets Manager** for two secrets (`services/mirror-worker-go/internal/secrets/secrets.go:95-101`). This needs IAM access to `databaseCredentials` and `packiot/staging/db`.
- **Legacy production Postgres** (CPACK prod, ent 1), whose host is inside the secret. This is a **non-local, production** dependency. legacy-replicator points at 18.220.223.110/packiot40 (CS:3227-3231), but that the mirror's secret resolves to the same host is UNPROVEN.
- **Other.** No JWT, S3, or OTLP usage was found (searched: `otel|jwt|s3`).

### 9. Health and ports
- `/health` reports cursor and DLQ depth (`services/mirror-worker-go/cmd/mirror-worker-go/main.go:158-168`). The healthcheck is `mirror-worker-go --healthcheck` (CS:1764-1765). `EXPOSE 9102` (`services/mirror-worker-go/Dockerfile:35`).

### 10. UNPROVEN
- The contents of the `databaseCredentials` and `packiot/staging/db` secrets (host, DB name, user) are unknown, and so is whether the staging pool goes through pgbouncer. Searched compose and code; the values live only in Secrets Manager.
- The default search_path that resolves unqualified staging names (production_orders, equipment_events, mirror_id_map, enterprises) is unknown. These may resolve to F1 `packiot.public`, which compose says is retired.
- The service is profile-gated off (CS:1665), so a live staging role is not proven.

---

## oeecloud-fanout

**1. Build**
- compose: `compose.staging.yml:2234` (`build: ./services/oeecloud-fanout`, `compose.staging.yml:2235`), static IP 172.18.0.41 (`compose.staging.yml:2272`). No profile — always runs, idles unless flag on.
- Binary: `services/oeecloud-fanout/Dockerfile:16-18` builds `./cmd/oeecloud-fanout` → `/usr/local/bin/oeecloud-fanout` (`Dockerfile:22,28`).

**2. Env vars** (all read in `services/oeecloud-fanout/internal/config/config.go` unless noted)

| Var | Code default (file:line) | Staging value (compose line) |
|---|---|---|
| FANOUT_ENABLED → fallback FANOUT_CPACK_TO_SBXCPACK_ENABLED | `"false"` (`services/oeecloud-fanout/internal/config/config.go:82`) | `${FANOUT_CPACK_TO_SBXCPACK_ENABLED:-false}` (`compose.staging.yml:2242`) — real value lives in `/opt/packiot/.env` (not in repo) |
| AWS_REGION | `us-east-1` (`services/oeecloud-fanout/internal/config/config.go:83`) | `us-east-1` (`:2243`) **AWS** |
| RABBITMQ_SECRET_ID | `packiot/staging/rabbitmq-oeecloud-creds` (`services/oeecloud-fanout/internal/config/config.go:84`) | `packiot/staging/rabbitmq-stream-engine-creds` (`:2253`) **AWS Secrets Manager** |
| RABBITMQ_HOST / RABBITMQ_PORT | `rabbitmq` / 5672 (`services/oeecloud-fanout/internal/config/config.go:85-86`) | `rabbitmq` / `5672` (`:2254-2255`) |
| SOURCE_EXCHANGE | `oee` (`services/oeecloud-fanout/internal/config/config.go:87`) | `oee` (`:2256`) |
| FANOUT_QUEUE | `oeecloud-fanout-cpack-to-sbxcpack` (`services/oeecloud-fanout/internal/config/config.go:88`) | same (`:2257`) |
| FANOUT_SOURCE_GROUP / FANOUT_TARGET_GROUP | `CPACK` / `SBXCPACK` (`services/oeecloud-fanout/internal/config/config.go:74-75`) | same (`:2258-2259`) |
| FANOUT_SOURCE_ROUTING_KEYS | `sparkplug.data,sparkplug.data.<lower(src)>` (`services/oeecloud-fanout/internal/config/config.go:104,115`) | `sparkplug.data,sparkplug.data.cpack` (`:2265`) |
| FANOUT_TARGET_ROUTING_KEY | `sparkplug.data.<lower(tgt)>` (`services/oeecloud-fanout/internal/config/config.go:90`) | `sparkplug.data.sbxcpack` (`:2266`) |
| PREFETCH | 50 (`services/oeecloud-fanout/internal/config/config.go:93`) | `50` (`:2267`) |
| PUBLISH_CONFIRM_TIMEOUT_MS | 5000 (`services/oeecloud-fanout/internal/config/config.go:94`) | `5000` (`:2268`) |
| HEALTH_PORT | 9102 (`services/oeecloud-fanout/internal/config/config.go:95`; also `services/oeecloud-fanout/cmd/oeecloud-fanout/main.go:113-114` for `--healthcheck`) | `9102` (`:2269`) |
| LOG_LEVEL | `info` (`services/oeecloud-fanout/internal/config/config.go:96`) | `info` (`:2240`) |
| CREDS_SOURCE (=`env` skips Secrets Manager) | unset (`services/oeecloud-fanout/internal/secrets/secrets.go:41`) | not set in compose; `.env` is `env_file` (`:2238`) — unknown |
| RABBITMQ_USER / RABBITMQ_PASSWORD (only when CREDS_SOURCE=env) | none (`services/oeecloud-fanout/internal/secrets/secrets.go:107-108`) | not set in compose |

**3. PostgreSQL** — none. No pgx/sql import (searched: `pgx`, `database/sql`, `SELECT`, `INSERT` under `services/oeecloud-fanout`). Package doc says "the fan-out never touches Postgres" (`services/oeecloud-fanout/internal/secrets/secrets.go:2-3`).

**4. RabbitMQ** (`services/oeecloud-fanout/internal/amqp/fanout.go`)
- Declares exchange `oee` type `topic`, durable (`services/oeecloud-fanout/internal/amqp/fanout.go:209`).
- Declares queue `oeecloud-fanout-cpack-to-sbxcpack` durable, no args / no DLX (`services/oeecloud-fanout/internal/amqp/fanout.go:215`).
- Binds queue to `oee` on each of `sparkplug.data`, `sparkplug.data.cpack` (`services/oeecloud-fanout/internal/amqp/fanout.go:219`).
- Consumes with `autoAck=false` (`services/oeecloud-fanout/internal/amqp/fanout.go:162`), `Qos(prefetch=50)` (`services/oeecloud-fanout/internal/amqp/fanout.go:159`).
- Ack modes: undecodable → Ack+drop (`services/oeecloud-fanout/internal/amqp/fanout.go:245`); not source tenant → Ack skip (`services/oeecloud-fanout/internal/amqp/fanout.go:253`); publish failure → `Nack(requeue=true)` (`services/oeecloud-fanout/internal/amqp/fanout.go:261`); success → Ack (`services/oeecloud-fanout/internal/amqp/fanout.go:272`).
- Publishes to exchange `oee`, routing key `sparkplug.data.sbxcpack`, persistent, publisher confirms (`services/oeecloud-fanout/internal/amqp/fanout.go:149,152,285-288`).
- Payload transform: rewrites GroupID CPACK→SBXCPACK and clears `id_equipment`/`equipment_id`/`idequipment` fields (`services/oeecloud-fanout/internal/retenant/retenant.go:71,89,176`).

**5. MQTT** — none found (searched: `paho`, `mqtt`).
**6. Redis** — none found (searched: `redis`).
**7. HTTP**
- Exposed: `GET /health` on `:9102` (`services/oeecloud-fanout/internal/health/health.go:28`); served even when disabled (`services/oeecloud-fanout/cmd/oeecloud-fanout/main.go:52-56`).
- Outbound: only the self-probe `http://127.0.0.1:<HEALTH_PORT>/health` (`services/oeecloud-fanout/cmd/oeecloud-fanout/main.go:116`).

**8. External deps**
- AWS Secrets Manager `GetSecretValue` via `aws-sdk-go-v2` default credential chain (`services/oeecloud-fanout/internal/secrets/secrets.go:76,81`), called at boot (`services/oeecloud-fanout/cmd/oeecloud-fanout/main.go:74`) only when enabled. Dev bypass: `CREDS_SOURCE=env` (`services/oeecloud-fanout/internal/secrets/secrets.go:41`).
- No JWT / S3 / DuckDB.

**9. Health / ports**: `/health` :9102; compose healthcheck `--healthcheck` (`compose.staging.yml:2277`, `services/oeecloud-fanout/cmd/oeecloud-fanout/main.go:40`). No host port.

**10. UNPROVEN**
- Whether `FANOUT_CPACK_TO_SBXCPACK_ENABLED=true` on staging: lives in `/opt/packiot/.env` (not in repo; searched `.env.example`, compose).
- Whether `CREDS_SOURCE` is set via `.env` (same reason).

---

## ingest-shim

**1. Build**
- compose: `compose.staging.yml:2443` (`build: ./services/ingest-shim`), IP 172.18.0.29 (`:2503`), host port `127.0.0.1:8444:8444` (`:2500`).
- Binary: `services/ingest-shim/Dockerfile:18-20` → `/usr/local/bin/ingest-shim` (`Dockerfile:26,33`).

**2. Env vars** (`services/ingest-shim/internal/config/config.go` unless noted)

| Var | Default | Staging |
|---|---|---|
| AWS_REGION | `us-east-1` (`services/ingest-shim/internal/config/config.go:81`) | `us-east-1` (`compose.staging.yml:2455`) **AWS** |
| RABBITMQ_SECRET_ID | `packiot/staging/rabbitmq-oeecloud-creds` (`services/ingest-shim/internal/config/config.go:82`) | `packiot/staging/rabbitmq-sparkplug-decoder-creds` (`:2459`) **Secrets Manager** |
| RABBITMQ_HOST/PORT | `rabbitmq`/5672 (`services/ingest-shim/internal/config/config.go:83-84`) | same (`:2460-2461`) |
| EXCHANGE | `oee` (`services/ingest-shim/internal/config/config.go:85`) | `oee` (`:2470`) |
| ROUTING_KEY | `sparkplug.data` (`services/ingest-shim/internal/config/config.go:86`) | `sparkplug.data.incoplast` (`:2471`) |
| CONFIRM_TIMEOUT_MS | 5000 (`services/ingest-shim/internal/config/config.go:87`) | not set |
| HTTP_ADDR | `:8444` (`services/ingest-shim/internal/config/config.go:88`) | `:8444` (`:2480`) |
| METRICS_ADDR | `:9105` (`services/ingest-shim/internal/config/config.go:89`) | `:9105` (`:2481`) |
| INGEST_API_KEY | none — **required**, Load fails if empty (`services/ingest-shim/internal/config/config.go:90,66-67`) | `${INGEST_API_KEY:-}` (`:2485`) |
| SCOPE_GROUP | `INCOPLAST` (`services/ingest-shim/internal/config/config.go:91`) | `INCOPLAST` (`:2478`) |
| FANOUT_SOURCE_TYPES | `legacy,go,refactored` (`services/ingest-shim/internal/config/config.go:92`; `legacy`→`""` `services/ingest-shim/internal/config/config.go:123-133`) | `refactored` (`:2475`) |
| MAX_BODY_BYTES | 1 MiB (`services/ingest-shim/internal/config/config.go:93`) | not set |
| TLS_CERT_FILE / TLS_KEY_FILE | none — **required** (`services/ingest-shim/internal/config/config.go:94-95`; refuse-to-start `services/ingest-shim/cmd/ingest-shim/main.go:63-66`) | `/certs/server.crt`, `/certs/server.key` (`:2488-2489`), host mount `/opt/packiot/ingest-shim/certs` (`:2492`) |
| LOG_LEVEL | `info` (`services/ingest-shim/internal/config/config.go:96`) | `info` (`:2449`) |
| OTEL_EXPORTER_OTLP_ENDPOINT | unset = tracing off (`services/ingest-shim/internal/tracing/tracing.go:39`) | `http://tempo:4317` (`:2453`) |
| OTEL_TRACES_SAMPLER_ARG | (`services/ingest-shim/internal/tracing/tracing.go:91`) | not set |
| CREDS_SOURCE, RABBITMQ_USER/PASSWORD | env bypass (`services/ingest-shim/internal/secrets/secrets.go:76,96-97`) | not set in compose |

**3. PostgreSQL** — none (searched `pgx`, `database/sql`, `SELECT`, `INSERT` in `services/ingest-shim`).

**4. RabbitMQ** (`services/ingest-shim/internal/amqp/publisher.go`)
- No exchange/queue declared (searched `ExchangeDeclare|QueueDeclare|QueueBind` — no hits); publishes into the pre-existing `oee` exchange.
- Publish: exchange `oee`, routing key `sparkplug.data.incoplast`, persistent, `traceparent` injected into headers (`services/ingest-shim/internal/amqp/publisher.go:139-146`); confirm mode (`services/ingest-shim/internal/amqp/publisher.go:96,105`); confirm timeout → error (`services/ingest-shim/internal/amqp/publisher.go:167`).
- One publish per configured source_type, with top-level `"source_type"` stamped into the JSON (`services/ingest-shim/internal/httpserver/server.go:127-135,160-171`); staging = one copy `source_type:"refactored"`.
- Consumer: none.

**5. MQTT / 6. Redis** — none found (searched `mqtt`, `paho`, `redis`).

**7. HTTP**
- Exposed TLS `:8444`: `POST /ingest/sparkplug` (`services/ingest-shim/internal/httpserver/server.go:53`), `GET /healthz` (`services/ingest-shim/internal/httpserver/server.go:54`); `X-Ingest-Key` auth (`services/ingest-shim/internal/httpserver/server.go:81`), scope check on first topic group vs `SCOPE_GROUP` → 403 (`services/ingest-shim/internal/httpserver/server.go:115-116`). Server `ListenAndServeTLS` (`services/ingest-shim/cmd/ingest-shim/main.go:156`).
- Exposed plain `:9105` `/metrics` (`services/ingest-shim/internal/metrics/metrics.go:67`, `services/ingest-shim/cmd/ingest-shim/main.go:122-129`).
- Outbound: self-probe `https://127.0.0.1:<port>/healthz` (`services/ingest-shim/cmd/ingest-shim/main.go:194`). OTLP to `tempo:4317` when set.

**8. External deps**: AWS Secrets Manager `GetSecretValue` at boot, fatal on failure (`services/ingest-shim/internal/secrets/secrets.go:52,57`; `services/ingest-shim/cmd/ingest-shim/main.go:96-103`). TLS cert files from host. No JWT.

**9. Health / ports**: `/healthz` on TLS :8444, `/metrics` :9105; healthcheck `--healthcheck` (`compose.staging.yml:2510`, `services/ingest-shim/cmd/ingest-shim/main.go:48-50`).

**10. UNPROVEN**
- The actual producer (Incoplast Node-RED) is outside the repo; the inbound payload shape is only given by parse code in `server.go` (not by a schema file).
- Whether staging RabbitMQ has a binding for `sparkplug.data.incoplast` (it is declared by stream-engine tenant discovery, not by this service; see the stream-engine section). Compose comment `:2463-2469` claims it is.

---

## analytics-sync

**1. Build**
- compose: `compose.staging.yml:3141` (`build: ./services/analytics-sync`), IP 172.18.0.25, alias `shadow-mirror` (`:3177-3178`).
- Binary: `services/analytics-sync/Dockerfile:7-8` builds **`./cmd/shadow-mirror`** → `/usr/local/bin/analytics-sync` (`Dockerfile:11,13`).
- **Staging state: DISABLED** — `SHADOW_MIRROR_ENABLED: "false"` (`compose.staging.yml:3154`). In that mode it only serves `/healthz` + `/metrics` and opens no DB connection (`services/analytics-sync/cmd/shadow-mirror/main.go:41-46`).

**2. Env vars**

| Var | Default | Staging |
|---|---|---|
| SHADOW_MIRROR_ENABLED | `false` (`services/analytics-sync/internal/config/config.go:53`) | `false` (`:3154`) |
| AWS_REGION | `us-east-1` (`services/analytics-sync/internal/config/config.go:46`) | `us-east-1` (`:3155`) — **read but unused** |
| PG_SECRET_ID | `packiot/staging/db` (`services/analytics-sync/internal/config/config.go:47`) | `packiot/staging/db` (`:3156`) — **read but never used**: only refs are `config.go:23⚠ambiguous[services/analytics-sync/internal/config/config.go|services/analytics-sync/internal/replicate/config.go|services/ingest-shim/internal/config/config.go|services/mirror-worker-go/internal/config/config.go|services/oeecloud-fanout/internal/config/config.go|services/sparkplug-decoder/internal/config/config.go|services/stream-engine/internal/config/config.go],47` (grep `PGSecretID`); code has `TODO Phase 2: fetch creds from AWS Secrets Manager` (`services/analytics-sync/cmd/shadow-mirror/main.go:52`) |
| DB_HOST / DB_PORT | `postgres` / 5432 (`services/analytics-sync/cmd/shadow-mirror/main.go:56-57`) | `10.10.10.89` / `5432` (`:3163-3164`) — **direct, no pgbouncer** |
| DB_USER / DB_PASSWORD | `postgres` / `""` → exit if empty (`services/analytics-sync/cmd/shadow-mirror/main.go:58-63`) | `${POSTGRES_USER}` / `${POSTGRES_PASSWORD}` (`:3167-3168`) |
| PG_DB_NAME | `packiot` (`services/analytics-sync/internal/config/config.go:48`) | `packiot` (`:3169`) |
| PG_ANALYTICS_DB_NAME | `packiot_analytics` (`services/analytics-sync/internal/config/config.go:49`) | `packiot_analytics` (`:3170`) |
| POLL_INTERVAL_MS / BATCH_SIZE / MAX_RETRIES | 2000 / 100 / 5 (`services/analytics-sync/internal/config/config.go:50-52`) | `2000`/`100`/`5` (`:3171-3173`) |
| HEALTH_PORT | 9103 (`services/analytics-sync/internal/config/config.go:54`, `services/analytics-sync/cmd/shadow-mirror/main.go:157`) | `9103` (`:3174`) |
| LOG_LEVEL | `info` (`services/analytics-sync/internal/config/config.go:55`) | `info` (`:3147`) |

**3. PostgreSQL** (only when enabled)
- Two pools from the same creds: main → `packiot` (`services/analytics-sync/cmd/shadow-mirror/main.go:67`), analytics → `packiot_analytics` (`services/analytics-sync/cmd/shadow-mirror/main.go:78`); `MaxConns=5`, `application_name` set (`services/analytics-sync/internal/db/pool.go:36,48`).
- READ (main/packiot): `user_logs` (`services/analytics-sync/internal/replay/cursor.go:40,71`); `ops.mirror_replay_cursor` (`services/analytics-sync/internal/replay/cursor.go:32`).
- WRITE: `ops.mirror_replay_cursor` INSERT/UPDATE (`services/analytics-sync/internal/replay/cursor.go:44,57`).
- **Dynamic schema** `%s.` in every handler SQL — schema is the literal `"shadow_go_port"` (main pool) or `"public"` (analytics pool), e.g. `services/analytics-sync/internal/replay/handlers/manual_event_created.go:105,111`, `services/analytics-sync/internal/replay/handlers/event_classified.go:96,101`, `services/analytics-sync/internal/replay/handlers/order_changed.go:78,82`, `services/analytics-sync/internal/replay/handlers/event_splitted.go:53,57`, `services/analytics-sync/internal/replay/handlers/production_orders_lifecycle.go:40,44`. Tables written via that template: `%s.equipment_events_man` (`services/analytics-sync/internal/replay/handlers/manual_event_created.go:119`, `services/analytics-sync/internal/replay/handlers/event_splitted.go:65`, `services/analytics-sync/internal/replay/handlers/production_orders_lifecycle.go:323`), `%s.production_orders` (`services/analytics-sync/internal/replay/handlers/production_orders.go:78,159,199`, `services/analytics-sync/internal/replay/handlers/order_changed.go:90,94`, `services/analytics-sync/internal/replay/handlers/production_orders_lifecycle.go:52,122,176,264`), `%s.production_orders_runtime` (`services/analytics-sync/internal/replay/handlers/production_orders.go:204,210,219`), `%s.equipment_events` UPDATE (`services/analytics-sync/internal/replay/handlers/event_classified.go:116`).
- READ for natural keys: `core.production_orders` (`services/analytics-sync/internal/replay/handlers/natural_key.go:31`), `public.equipment_events_man` (`services/analytics-sync/internal/replay/handlers/natural_key.go:51`), `silver.equipment_events` (`services/analytics-sync/internal/replay/handlers/natural_key.go:84`).
- Note: compose says `shadow_go_port` schema was DROPPED (`compose.staging.yml:1795-1797`) — enabling this service would hit 42P01 on the main-pool leg (inference from compose comment; schema existence not provable statically).
- LISTEN/NOTIFY: none (searched `LISTEN|NOTIFY`).

**4–6. RabbitMQ / MQTT / Redis** — none (searched `amqp`, `mqtt`, `redis` in `services/analytics-sync`).

**7. HTTP**: `/healthz`, `/metrics` on :9103 (`services/analytics-sync/cmd/shadow-mirror/main.go:121-122` enabled; `:144-145` idle). No outbound HTTP.

**8. External deps**: none in effect (AWS vars read but unused, see above).

**9. Health / ports**: :9103; healthcheck `--healthcheck` (`compose.staging.yml:3182`).

**10. UNPROVEN**: whether `shadow_go_port`/`public.equipment_events_man` exist in today's DBs (needs DB, not code).

---

## legacy-replicator  (and legacy-replicator-sbx)

**1. Build**
- compose: `legacy-replicator` `compose.staging.yml:3214`; `legacy-replicator-sbx` `compose.staging.yml:3345`. Both `context: ./services/analytics-sync`, `dockerfile: Dockerfile.replicator` (`:3215-3217`, `:3346-3348`).
- Binary: `services/analytics-sync/Dockerfile.replicator:8-9` builds `./cmd/legacy-replicator` → `/usr/local/bin/legacy-replicator` (`:12,14`).
- `legacy-replicator` is ENABLED (`REPLICATE_ENABLED: "true"`, `:3223`); `-sbx` is `${REPLICATE_SBX_ENABLED:-false}` (`:3355`).

**2. Env vars** (`services/analytics-sync/internal/replicate/config.go`)

| Var | Default | legacy-replicator | -sbx |
|---|---|---|---|
| REPLICATE_ENABLED | false (`services/analytics-sync/internal/replicate/config.go:184`) | `true` (`:3223`) | `${REPLICATE_SBX_ENABLED:-false}` (`:3355`) |
| LEGACY_DB_HOST | **`18.220.223.110`** (`services/analytics-sync/internal/replicate/config.go:159`) | `18.220.223.110` (`:3227`) **EXTERNAL public IP (legacy prod)** | `:3357` same |
| LEGACY_DB_PORT/USER/NAME | 5432/`awslambda`/`packiot40` (`services/analytics-sync/internal/replicate/config.go:160-163`) | same (`:3228-3231`) | `:3358-3361` |
| LEGACY_DB_PASSWORD | `""` → exit (`services/analytics-sync/internal/replicate/config.go:162`, `services/analytics-sync/cmd/legacy-replicator/main.go:44`) | `${LEGACY_DB_PASSWORD}` (`:3230`) | `:3360` |
| DEST_DB_HOST/PORT | `10.10.10.89`/5432 (`services/analytics-sync/internal/replicate/config.go:165-166`) | same, **direct** (`:3234-3235`) | `:3363-3364` |
| DEST_DB_USER/PASSWORD/NAME | `postgres`/`""`/`packiot_analytics` (`services/analytics-sync/internal/replicate/config.go:167-169`) | `${POSTGRES_USER}`/`${POSTGRES_PASSWORD}`/`packiot_analytics` (`:3236-3238`) | `:3365-3367` |
| SRC_ENTERPRISE / DST_ENTERPRISE | 1 / 3 (`services/analytics-sync/internal/replicate/config.go:171-172`) | `1`/`3` (`:3240-3241`) | `1`/`2000003` (`:3370-3371`) |
| BACKFILL_SINCE_DAYS / BACKFILL_SINCE | 60 / "" (`services/analytics-sync/internal/replicate/config.go:174-175`) | `60` (`:3243`) | `60` (`:3373`) |
| REPLICATE_BASE_EVENTS | true (`services/analytics-sync/internal/replicate/config.go:177`) | `true` (`:3246`) | `:3374` |
| CURSOR_SOURCE | `legacy-cpack` (`services/analytics-sync/internal/replicate/config.go:179`) | `legacy-cpack` (`:3248`) | `legacy-sbxcpack` (`:3376`) |
| POLL_INTERVAL_MS / BATCH_SIZE | 3000/200 (`services/analytics-sync/internal/replicate/config.go:181-182`) | same (`:3249-3250`) | `:3377-3378` |
| HEALTH_PORT | 9104 (`services/analytics-sync/internal/replicate/config.go:185`; `services/analytics-sync/cmd/legacy-replicator/main.go:176`) | `9104` (`:3251`) | `9114` (`:3380`) |
| HEALTHCHECK_MAX_AGE_SEC | 0 (`services/analytics-sync/internal/replicate/config.go:187`) | `600` (`:3263`) | `600` (`:3381`) |
| RECONCILE_PO_ENABLED / _INTERVAL_SEC / _WINDOW_DAYS | false/300/14 (`services/analytics-sync/internal/replicate/config.go:189-191`) | `true`/`300`/`14` (`:3273-3275`) | `:3388-3390` |
| RECONCILE_PO_ENRICH_ENABLED / _WINDOW_DAYS / _KEEP_LEGACY_IDS | false/14/true (`services/analytics-sync/internal/replicate/config.go:193-195`) | `true`/`120`/(unset→true) (`:3283-3284`) | `true`/`120`/`false` (`:3396-3398`) |
| SANDBOX_HOLD_ENABLED | false (`services/analytics-sync/internal/replicate/config.go:197`) | unset | `true` (`:3385`) |
| RECONCILE_MANUAL_EVENTS_* (ENABLED, INTERVAL_SEC, LOOKBACK_DAYS, MAX_DELETES, REFRESH_SERVING) | false/300/35/50/true (`services/analytics-sync/internal/replicate/config.go:199-203`) | `true`/`300`/`35`/`50`/`true` (`:3295-3299`) | `:3401-3405` |
| EVENT_MIN_OVERLAP_SEC / EVENT_MAX_START_DRIFT_SEC | 30/600 (`services/analytics-sync/internal/replicate/config.go:205-206`) | unset | unset |
| DLQ_CAPTURE_ENABLED / DLQ_RETRY_ENABLED / _INTERVAL_SEC / _MAX_ATTEMPTS / _BATCH_SIZE | true/true/120/5/100 (`services/analytics-sync/internal/replicate/config.go:208-212`) | unset (defaults) | unset |
| LOG_LEVEL | info (`services/analytics-sync/internal/replicate/config.go:186`) | `info` (`:3222`) | `:3353` |

**3. PostgreSQL** — two pools: `legacyPool` (source, SELECT-only by code) `services/analytics-sync/cmd/legacy-replicator/main.go:54`; `destPool` `services/analytics-sync/cmd/legacy-replicator/main.go:63`. Both `MaxConns=5` (`services/analytics-sync/internal/db/pool.go:48`).

SOURCE reads (legacy `packiot40`, public schema, unqualified):
| Object | file:line |
|---|---|
| user_logs | `services/analytics-sync/internal/replicate/cursor.go:60,71,111`; `services/analytics-sync/internal/replicate/dlq.go:297` |
| production_orders (+ products, product_families, clients joins) | `services/analytics-sync/internal/replicate/reconcile.go:215`; `services/analytics-sync/internal/replicate/handlers.go:86`; `services/analytics-sync/internal/replicate/enrich.go:46-52` (exec `services/analytics-sync/internal/replicate/enrich.go:198`) |
| equipment_events | `services/analytics-sync/internal/replicate/handlers.go:122` |
| equipment_events_man | `services/analytics-sync/internal/replicate/handlers.go:202`; `services/analytics-sync/internal/replicate/manual_reconcile.go:343-347` (exec `:647`) |
| packml_register, equipments | `services/analytics-sync/internal/replicate/resolver.go:179,199` (called for legacy at `services/analytics-sync/internal/replicate/resolver.go:122`) |

DEST (staging `packiot_analytics`) — READ:
| Object | file:line |
|---|---|
| packml_register, equipments (unqualified → search_path) | `services/analytics-sync/internal/replicate/resolver.go:179,199` (dest call `services/analytics-sync/internal/replicate/resolver.go:126`) |
| core.production_orders | `services/analytics-sync/internal/replicate/reconcile.go:262`; `services/analytics-sync/internal/replicate/handlers.go:365`; `services/analytics-sync/internal/replicate/enrich.go:40` |
| production_orders (unqualified) | `services/analytics-sync/internal/replicate/reconcile.go:272` |
| core.products / core.product_families / core.clients (+ `_seq` last_value) | `services/analytics-sync/internal/replicate/enrich.go:57-59,83,85` |
| silver.equipment_events | `services/analytics-sync/internal/replicate/handlers.go:158,850` |
| gold.production_orders_runtime | `services/analytics-sync/internal/replicate/reconcile.go:130,132,143`; `services/analytics-sync/internal/replicate/handlers.go:1237` |
| ops.mirror_replay_cursor | `services/analytics-sync/internal/replicate/cursor.go:48` |
| ops.mirror_replay_dlq | `services/analytics-sync/internal/replicate/dlq.go:115,270` |
| ops.legacy_manual_event_link, silver.equipment_events_man | `services/analytics-sync/internal/replicate/manual_reconcile.go:353-354` |
| ops.sandbox_hold_mode(int) (function) | `services/analytics-sync/internal/replicate/hold.go:52` |

DEST — WRITE:
| Object | Op | file:line |
|---|---|---|
| core.production_orders | INSERT/UPDATE | `services/analytics-sync/internal/replicate/reconcile.go:92,105,114`; `services/analytics-sync/internal/replicate/handlers.go:228,303,315,339,346,356,382,388,392,400,1254,1268`; `services/analytics-sync/internal/replicate/enrich.go:88` |
| gold.production_orders_runtime | INSERT/UPDATE | `services/analytics-sync/internal/replicate/reconcile.go:123`; `services/analytics-sync/internal/replicate/handlers.go:218,253,262,1245` |
| silver.equipment_events | INSERT/UPDATE | `services/analytics-sync/internal/replicate/handlers.go:421,427,469,482` |
| silver.equipment_events_man | INSERT/UPDATE/DELETE | `services/analytics-sync/internal/replicate/handlers.go:439,447`; `services/analytics-sync/internal/replicate/manual_reconcile.go:370,378,391` |
| ops.legacy_manual_event_link | INSERT/DELETE | `services/analytics-sync/internal/replicate/manual_reconcile.go:364,375,395,398` |
| core.products / core.product_families / core.clients | INSERT | `services/analytics-sync/internal/replicate/enrich.go:61,67,71,73,77` |
| ops.mirror_replay_cursor | INSERT/UPDATE | `services/analytics-sync/internal/replicate/cursor.go:77,88` |
| ops.mirror_replay_dlq | INSERT/UPDATE/DELETE | `services/analytics-sync/internal/replicate/dlq.go:94,275,281,287` |
| serving.refresh_downtime_events_resolved(a,b) (function call) | SELECT fn | `services/analytics-sync/internal/replicate/manual_reconcile.go:404,614` |

- Dynamic table names: none in this package (all literals; searched `Sprintf(` with `%s.`).
- LISTEN/NOTIFY: none.

**4–6. RabbitMQ / MQTT / Redis** — none.

**7. HTTP**: `/healthz` (heartbeat checker → 503 when stale, `services/analytics-sync/internal/health/health.go:44,54-63`) + `/metrics` on HEALTH_PORT (`services/analytics-sync/cmd/legacy-replicator/main.go:107-108`; idle `:165-166`). No outbound HTTP.

**8. External deps**: **the legacy production PostgreSQL at 18.220.223.110:5432 (`packiot40`, user `awslambda`)** — `config.go:159⚠ambiguous[services/analytics-sync/internal/replicate/config.go|services/mirror-worker-go/internal/config/config.go|services/sparkplug-decoder/internal/config/config.go|services/stream-engine/internal/config/config.go]-163`, `compose.staging.yml:3227-3231`. Password is sourced into `.env` from Secrets Manager `databaseCredentials` per compose comment (`:3224-3226`) — the binary itself does NOT call AWS (searched `secretsmanager` in `services/analytics-sync`: none).

**9. Health / ports**: 9104 (main) / 9114 (sbx); healthcheck `--healthcheck` (`compose.staging.yml:3303,3409`).

**10. UNPROVEN**
- Legacy schema shape (`packiot40`) — external DB, only inferable from SQL text.
- Whether `ops.sandbox_hold_mode` / `serving.refresh_downtime_events_resolved` exist — defined in migrations (e.g. `db/migrations/t-replicate-manual-events/01-up.sql` named in compose `:3293`), not verified here.

---

## read-api

**1. Build**
- compose: `compose.staging.yml:2876` (`build: ./services/read-api`), IP 172.18.0.26, alias `refdata-api` (`:2982-2983`). No host port.
- Binary: `services/read-api/Dockerfile:7-8` builds `./cmd/refdata-api` → `/usr/local/bin/read-api` (`:11,13`).

**2. Env vars** (files under `services/read-api/cmd/refdata-api/` unless noted)

| Var | Default | Staging |
|---|---|---|
| DB_HOST / DB_PORT | `pgbouncer` / 5432 (`services/read-api/cmd/refdata-api/main.go:212`) | `pgbouncer` / `5432` (`:2882-2883`) |
| DB_USER / DB_PASSWORD | `postgres` / none (`services/read-api/cmd/refdata-api/main.go:213`) | `${READAPI_RO_USER:-readapi_ro}` / `${READAPI_RO_PASSWORD}` (`:2898-2899`) |
| REFDATA_FLOW | `f1` (`flow.go` activeFlow; `services/read-api/cmd/refdata-api/main.go:207`) | `f3` (`:2911`) |
| DB_NAME (f1) / DB_NAME_F3 (f3) | `packiot` / `packiot_analytics` (`services/read-api/cmd/refdata-api/flow.go:80-82`) | `packiot` / `packiot_analytics` (`:2900,2917`) → effective DB **packiot_analytics** |
| INTERNAL_API_KEY | none → `/internal/resolve-device` 401 (`services/read-api/cmd/refdata-api/internal.go:83`) | `${INTERNAL_API_KEY:-}` (`:2916`) |
| HIST_GW_HOST/PORT/USER/DB | `hist-gateway`/5432/`historian_svc`/`packiot_historian` (`services/read-api/cmd/refdata-api/historian.go:65-70`) | same (`:2929-2933`) |
| HIST_GW_PASSWORD | none → hist pool nil → 503 (`services/read-api/cmd/refdata-api/historian.go:60`) | `${HIST_GW_SVC_PASSWORD:-}` (`:2932`) |
| HEALTH_PORT (also the API port) | `9104` (`services/read-api/cmd/refdata-api/main.go:297,457`) | `9104` (`:2934`) |
| OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_TRACES_SAMPLER_ARG | off (`services/read-api/internal/tracing/tracing.go:39,91`) | `http://alloy:4317` (`:2940`) |
| QUERY_API_KEYS | none (`services/read-api/cmd/refdata-api/main.go:312`) | `stg-cpack-key:3,…,stg-bispharma-key:5` (`:2944`) |
| COGNITO_ISSUER | **`https://cognito-idp.us-east-1.amazonaws.com/us-east-1_0T9t1sTwt`** (`services/read-api/cmd/refdata-api/auth_cognito.go:64`; read `services/read-api/cmd/refdata-api/main.go:320`) | same (`:2955`) **AWS Cognito** |
| COGNITO_CLIENT_ID | `2ckuoa0ov598rdpdn3uv039h6e` (`services/read-api/cmd/refdata-api/auth_cognito.go:65`; `services/read-api/cmd/refdata-api/main.go:321`) | same (`:2956`) |
| COGNITO_JWKS_URL | "" → `<issuer>/.well-known/jwks.json` (`services/read-api/cmd/refdata-api/main.go:322`) | not set |
| COGNITO_AUTH_ENABLED | parsed in `services/read-api/cmd/refdata-api/auth_cognito.go:73-79` but **`cognitoAuthEnabled()` has no non-test caller** (grep) → dead | `"true"` (`:2954`) |
| FIREBASE_PROJECT_ID | mentioned in comment `services/read-api/cmd/refdata-api/auth_firebase.go:58`; **`newFirebaseVerifier` has no non-test caller** (grep) → Firebase path dead; main wires Cognito only (`services/read-api/cmd/refdata-api/main.go:323-330`) | not set |
| OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED | false (`services/read-api/cmd/refdata-api/auth_operator_superadmin.go:70`) | `"true"` (`:2970`) |
| OPERATOR_SUPERADMIN_ALLOWLIST | `dev@packiot.com` (`services/read-api/cmd/refdata-api/auth_operator_superadmin.go:53,82`) | not set |
| REDIS_URL | `redis://app-redis:6379/0` (`services/read-api/cmd/refdata-api/main.go:240`) | same (`:2979`) |
| REDIS_CACHE_ENABLED | true (`services/read-api/cmd/refdata-api/main.go:241`) | `"true"` (`:2978`) |
| EXTERNAL_NEOPAC_CUSTOMER_ID / EXTERNAL_MONTEBELLO_CUSTOMER_ID / EXTERNAL_INCOPLAST_CUSTOMER_ID | 0 (`services/read-api/cmd/refdata-api/external.go:594-681` ownerEnv; read via `getenvInt` `services/read-api/cmd/refdata-api/external.go:899`) | not set in compose (maybe `.env`) |
| JWT_SECRET | compose comment says super-admin uses it (`:2963-2964`) — **not read by code** (grep `JWT_SECRET` in read-api: only comment `services/read-api/cmd/refdata-api/main.go:337`) | via `.env` |

**3. PostgreSQL**
- Main pool: pgbouncer → `packiot_analytics` (pgbouncer extra DB line `compose.staging.yml:132`), role `readapi_ro` (NOBYPASSRLS; `db/migrations/t276-readapi-ro-nobypassrls/01-role.sql:48`). `MaxConns=5`, simple protocol (`services/read-api/cmd/refdata-api/main.go:220,223`), otelpgx tracer (`services/read-api/cmd/refdata-api/main.go:226`).
- Tenant: every scoped query runs in a tx with `set_config('app.tenant_id', <cid>, true)` (`services/read-api/cmd/refdata-api/query.go:508`) — **dynamic SQL via Sprintf with an int** (safe), and `$1 = id_enterprise`.
- WRITES (despite "read" API):
  - `identity.user_screen_config` CREATE SCHEMA/TABLE/ALTER/INDEX at startup (`services/read-api/cmd/refdata-api/query.go:566-575`, errors ignored) and `INSERT … ON CONFLICT` (`services/read-api/cmd/refdata-api/query.go:317`). Grant: `t276…db/migrations/t276-readapi-ro-nobypassrls/01-role.sql:84`.
  - `UPDATE users SET id_user_cognito` login self-heal (`services/read-api/cmd/refdata-api/auth_firebase.go:408-414`, exec `:426`). Grant `UPDATE ON identity.users` (`t276…db/migrations/t276-readapi-ro-nobypassrls/01-role.sql:86`).
- READS (fixed endpoints, `services/read-api/cmd/refdata-api/main.go:103-166`): `serving.events_timeline($2)` (`:104`), `serving.pending_downtime($2)` (`:107`), `piot_get_shift_hours_by_packml_topic_2` (`:110`), `piot_get_shift_hours_by_enterprise_packml_topic_2` (`:124`), `piot_get_day_week_begin_by_packml_topic` (`:127`), `v_operator_po_list_setup_4` (`:132`), `v_operator_po_details_3` (`:135`), `v_operator_entities_2` (`:138`), `v_entities_per_user_role_operator` (`:141`), `language_packs` (`:147`), `equipments` + `packml_register` (`:160-166`). Unqualified → resolved by role search_path (UNPROVEN which schema).
- READS (`/v1/query` compile, **dynamic FROM** chosen from an allowlist): `agg_equipment_values_1min` / `agg_equipment_values_1hour` (`services/read-api/cmd/refdata-api/query.go:60-61`, SQL built `services/read-api/cmd/refdata-api/query.go:118`). Window guard reads `ops.retention_policy` (`services/read-api/cmd/refdata-api/query.go:209`; `services/read-api/cmd/refdata-api/coverage.go:125-126`), `pg_proc`/`pg_namespace` (`services/read-api/cmd/refdata-api/coverage.go:152-153`).
- READS (`/v1/query` datasets, SQL per dataset in `datasets.go`, chosen by name — dynamic selection, literal SQL; `compileDataset` `services/read-api/cmd/refdata-api/datasets.go:1217,1330`): `serving.oee_score` (`:281,294`), `serving.oee_score_by_team` (`:275`), `serving.equipment_scrap_capability` (`:307`), `serving.oee_progress` (`:312`), `serving.mission_control` / `_area` / `_timeline` (`:403,408,413`), `serving.overview_job_info` / `overview_events` / `overview_events_v3` / `production_chart` / `overview_production_chart` / `production_chart_legacy` (`:420-439`), `serving.production_health` (`:456`), `serving.downtime_duration_by_category` / `downtime_summary` / `downtime_by_category` (`:458-470`), `serving.downtime_events_v3` / `downtime_events_resolved` (`:476-482`), `serving.downtime_events` (`:491`), `serving.total_production_by_team` (`:501`), `serving.single_period_by_team_v4` / `_by_team` (`:508,515`), `serving.machine_speed` (`:521,533`), `silver.equipment_categorical_1hour` (`:526`), `public.h_piot_machine_speed` (`:531`), `serving.production_flow` (`:540`), `serving.targets` (`:549`), `serving.home` (`:609`), `serving.events_timeline_by_po` / `events_timeline_full` (`:622,632`), `serving.production_orders` / `production_orders_with_runtimes` (`:646,653`), `serving.overview_takt` / `overview_scrap_rate` (`:1014-1031`); `serving.downtime_events_v2`, `silver.equipment_events` (`services/read-api/cmd/refdata-api/query.go:236-237`); `core.equipments`, `gold.equipment_oee_hourly`, `public.current_tenant` (`services/read-api/cmd/refdata-api/query.go:487-489`); coverage index `gold.equipment_oee_shift` (`services/read-api/cmd/refdata-api/coverage.go:14`), `silver.equipment_categorical_1hour` (`services/read-api/cmd/refdata-api/coverage.go:44`).
- READS (external shims `external.go`, `external_integration.go`, `external_montebello_incoplast.go`): `serving.sap_site_report` (`services/read-api/cmd/refdata-api/external.go:598,694`), `serving.sap_report_data_sync` (`services/read-api/cmd/refdata-api/external.go:609,725`), `serving.production_data_sync` (`services/read-api/cmd/refdata-api/external.go:621`; `services/read-api/cmd/refdata-api/external_montebello_incoplast.go:99`), `serving.downtime_sync` (`services/read-api/cmd/refdata-api/external.go:633`; `services/read-api/cmd/refdata-api/external_montebello_incoplast.go:136`), `serving.data_sync` (`services/read-api/cmd/refdata-api/external.go:666`; `services/read-api/cmd/refdata-api/external_integration.go:159`).
- READS (auth): `users` + `user_roles` (`services/read-api/cmd/refdata-api/auth_firebase.go:96`; `services/read-api/cmd/refdata-api/auth_operator_superadmin.go:165-167`), `enterprises` (`services/read-api/cmd/refdata-api/auth_operator_superadmin.go:186`), `packml_register` by `device_key` (`services/read-api/cmd/refdata-api/internal.go:56-57`).
- Historian pool (separate, `hist-gateway:5432/packiot_historian`, `services/read-api/cmd/refdata-api/historian.go:60-71`): `silver.equipment_values`, `silver.equipment_events` (`services/read-api/cmd/refdata-api/historian.go:10-176`), `cold.equipment_values_daily`, `cold.ev_daily_watermark`, `cold.promoted_enterprise`, `cold.equipment_events`, `cold.ee_union_boundary` (`services/read-api/cmd/refdata-api/historian_split.go:13-89`); **dynamic** equip filter via `Sprintf` (`services/read-api/cmd/refdata-api/historian.go:270`; `services/read-api/cmd/refdata-api/historian_split.go:322-362`).
- LISTEN/NOTIFY: none.

**4–5. RabbitMQ / MQTT** — none (searched `amqp`, `mqtt`).

**6. Redis** (`app-redis`): cache-aside keys `refdata:ds:v1:<flow>:e<enterprise>:<dataset>:<sha>` (`services/read-api/internal/cache/cache.go:215`), TTL per dataset group (`services/read-api/cmd/refdata-api/datasets.go:190,224`), GET/SET (`services/read-api/internal/cache/cache.go:222-233`), used by `/v1/query` (`services/read-api/cmd/refdata-api/query.go:261`). Fails open (`services/read-api/cmd/refdata-api/main.go:243-251`).

**7. HTTP** (single listener :9104, `services/read-api/cmd/refdata-api/main.go:297,356`)
- `/v1/catalog`, `/v1/query`, `/v1/screen-config`, `/v1/dashboard-config` (`services/read-api/cmd/refdata-api/query.go:148,161,283,333`)
- `/v1/events-timeline`, `/v1/pending-downtime`, `/v1/shift-hours`, `/v1/shift-hours-by-enterprise`, `/v1/day-week-begin`, `/v1/operator-po-list`, `/v1/operator-po-details`, `/v1/operator-entities`, `/v1/entities-per-user-role`, `/v1/language-packs`, `/v1/downtime-reasons` (`services/read-api/cmd/refdata-api/main.go:103-159`, mounted `services/read-api/cmd/refdata-api/main.go:261`)
- `/v1/historian/production-series`, `/v1/historian/downtime-series` (`services/read-api/cmd/refdata-api/historian.go:178,181`)
- `/internal/resolve-device` (`services/read-api/cmd/refdata-api/internal.go:84`)
- `/ext/neopac/sap-report`, `/ext/neopac/sap-report-sync`, `/ext/montebello/data-sync`, `/ext/montebello/events`, `/ext/incoplast/events`, `/ext/incoplast/jobs`, `/integration/job_data_integration/:id_enterprise`, `/integration/get-shift-validation/:id_enterprise`, `/integration/job_report/:id_enterprise` (`services/read-api/cmd/refdata-api/external.go:593-680`, mounted `services/read-api/cmd/refdata-api/external.go:910`)
- `/healthz`, `/metrics` (`services/read-api/cmd/refdata-api/main.go:286-287`)
- Auth: X-Api-Key (QUERY_API_KEYS) or Cognito bearer (`services/read-api/cmd/refdata-api/main.go:312-350`).
- Outbound HTTP: Cognito JWKS fetch (`services/read-api/cmd/refdata-api/auth_cognito.go:137`, 12 h TTL `:86`). Firebase x509 URL constant exists (`services/read-api/cmd/refdata-api/auth_firebase.go:54`) but verifier not wired.
- Known callers in compose: sparkplug-decoder `REFDATA_URL: http://read-api:9104` (`compose.staging.yml:2602`), barcode-app `REFDATA_UPSTREAM` (`:1515`).

**8. External deps**: AWS Cognito JWKS at `https://cognito-idp.us-east-1.amazonaws.com/us-east-1_0T9t1sTwt/.well-known/jwks.json` — issuer + JWKS **configurable** by `COGNITO_ISSUER` / `COGNITO_JWKS_URL` (`services/read-api/cmd/refdata-api/main.go:320-323`). Historian gateway (separate compose file `compose.historian-gateway.yml`) whose cold tier is S3 (per compose comment `:2918-2928`; not in this service's code). No AWS SDK (searched `aws-sdk`).

**9. Health / ports**: `/healthz` (pings DB) on :9104 (`services/read-api/cmd/refdata-api/main.go:287-295`); healthcheck `--healthcheck` (`compose.staging.yml:2991`).

**10. UNPROVEN**
- search_path of `readapi_ro` (which schema unqualified `equipments`, `packml_register`, `users`, `v_operator_*`, `piot_*` resolve to).
- Whether all `serving.*` objects listed exist in the target DB (only code references).
- Whether `EXTERNAL_*_CUSTOMER_ID` are set in staging `.env` (not in repo).

---

## operator-gateway

**1. Build**
- compose: `compose.staging.yml:3071` (`build: ./services/operator-gateway`), IP 172.18.0.30, alias `operator-adapter` (`:3122-3123`), host `127.0.0.1:8445:8443` (`:3119`).
- Binary: `services/operator-gateway/Dockerfile:7-8` builds `./cmd/operator-adapter` → `/usr/local/bin/operator-gateway` (`:11,13`).

**2. Env vars**

| Var | Default | Staging |
|---|---|---|
| PORT | `8443` (`services/operator-gateway/cmd/operator-adapter/main.go:125`) | `8443` (`:3077`) |
| EDGE_API_URL | `http://edge-api:8080` (`services/operator-gateway/cmd/operator-adapter/main.go:78`) | same (`:3078`) |
| OPERATOR_API_KEY (inbound X-Ingest-Key) | required (`services/operator-gateway/cmd/operator-adapter/main.go:56`) | `${OPERATOR_API_KEY}` (`:3106`) |
| EDGE_API_KEY (outbound x-api-key) | required (`services/operator-gateway/cmd/operator-adapter/main.go:61`) | `${OPERATOR_EDGE_API_KEY}` (`:3107`) |
| INCOPLAST_ENTERPRISE_ID | required int (`services/operator-gateway/cmd/operator-adapter/main.go:66`) | `4` (`:3085`) |
| INCOPLAST_TOPIC_PREFIX | (`services/operator-gateway/cmd/operator-adapter/main.go:75`) | `INCOPLAST` (`:3086`) |
| AWS_REGION / PG_SECRET_ID | `us-east-1` / `packiot/staging/db` (`services/operator-gateway/cmd/operator-adapter/main.go:86-87`) | same (`:3092-3093`) **AWS Secrets Manager** unless CREDS_SOURCE=env |
| CREDS_SOURCE | Secrets Manager unless `env` (`services/operator-gateway/internal/secrets/secrets.go:102`) | `env` (`:3094`) → **SM bypassed on staging** |
| DB_HOST / DB_PORT / DB_NAME (env path) | `postgres` / 5432 / `packiot` (`secrets.go` fetchDBCredsFromEnv, `envOr("DB_HOST","postgres")`, `envOr("DB_NAME","packiot")`) | `10.10.10.89` / `5432` / `packiot_analytics` (`:3095-3099`) — **direct, not pgbouncer** (compose comment `:3091` and `services/operator-gateway/cmd/operator-adapter/main.go:80-83` comment say packiot/pgbouncer — stale) |
| DB_USER / DB_PASSWORD | required (`services/operator-gateway/internal/secrets/secrets.go:176-177`) | `${POSTGRES_USER}` / `${POSTGRES_PASSWORD}` (`:3097-3098`) |
| TLS_CERT_FILE / TLS_KEY_FILE | required, refuse plaintext (`services/operator-gateway/cmd/operator-adapter/main.go:126-132`) | `/opt/packiot/operator-adapter/certs/tls.{crt,key}` (`:3109-3110`) |
| OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_TRACES_SAMPLER_ARG | (`services/operator-gateway/internal/tracing/tracing.go:39,91`) | `http://tempo:4317` (`:3083`) |

**3. PostgreSQL**: pool `MaxConns=3` (`services/operator-gateway/internal/db/pool.go:30`), boot ping fatal (`services/operator-gateway/internal/db/pool.go:47-49`). READ only: `packml_register` ⋈ `equipments` ⋈ `areas` ⋈ `sites` by `packml_topic` + `s.id_enterprise` (`services/operator-gateway/internal/adapter/resolver.go:149-154`). No writes (searched INSERT/UPDATE/DELETE in `services/operator-gateway`). Unqualified names → search_path of the `POSTGRES_USER` role in `packiot_analytics` (UNPROVEN).

**4–6. RabbitMQ / MQTT / Redis** — none.

**7. HTTP**
- Exposed TLS :8443 (`services/operator-gateway/cmd/operator-adapter/main.go:135-150`): `/operator/downtime`, `/operator/po`, `/operator/po/stop`, `/operator/po/setup`, `/operator/po/replace`, `/operator/po/change-status`, `/operator/po/change-time`, `/operator/split`, `/healthz` (`services/operator-gateway/internal/adapter/server.go:67-79`), `/metrics` (`services/operator-gateway/cmd/operator-adapter/main.go:122`). POST-only, `X-Ingest-Key` constant-time (`services/operator-gateway/internal/adapter/server.go:97-102,140-144`).
- Outbound → edge-api (`EDGE_API_URL`), POST with header `x-api-key` + `?idEnterprise=` (`services/operator-gateway/internal/adapter/edgeclient.go:66-77`), paths: `/api/downtimes/create-manual-event` (`services/operator-gateway/internal/adapter/mapping.go:70`), `/api/downtimes/edit-manual-event` (`services/operator-gateway/internal/adapter/mapping.go:95`), `/api/production-orders/create-and-start` (`services/operator-gateway/internal/adapter/mapping.go:138`), `/api/production-orders/stop|setup|replace|change-status|change-time` (`services/operator-gateway/internal/adapter/po_lifecycle.go:213,262,274,285,304`), `/api/downtimes/split` (`services/operator-gateway/internal/adapter/split.go:146`).

**8. External deps**: AWS Secrets Manager client present (`internal/secrets/secrets.go`) but bypassed on staging by `CREDS_SOURCE=env` (`compose.staging.yml:3094`). TLS certs from host. No JWT.

**9. Health / ports**: `/healthz` on :8443 TLS; healthcheck `--healthcheck` (`compose.staging.yml:3132`).

**10. UNPROVEN**: whether `packiot_analytics` has unqualified `packml_register/equipments/areas/sites` visible on the role's search_path (the code comment `services/operator-gateway/cmd/operator-adapter/main.go:80-83` still targets F1 `packiot`).

---

## barcode-service

**1. Build**
- compose: `compose.staging.yml:3016` (`build: ./services/barcode-service`), IP 172.18.0.36 (`:3045`). No host port; nginx vhost per comment (`:3009-3012`).
- Binary: `services/barcode-service/Dockerfile:8-9` → `/usr/local/bin/barcode-service` (`:12,14`).

**2. Env vars** (`services/barcode-service/cmd/barcode-service/main.go`)

| Var | Default | Staging |
|---|---|---|
| HTTP_PORT | `8446` (`services/barcode-service/cmd/barcode-service/main.go:68`) | `8446` (`:3029`) |
| DB_HOST/DB_PORT | `pgbouncer`/5432 (`services/barcode-service/cmd/barcode-service/main.go:69-70`) | `pgbouncer`/`5432` (`:3022-3023`) |
| DB_USER/DB_PASSWORD | `postgres`/none (`services/barcode-service/cmd/barcode-service/main.go:71-72`) | `${POSTGRES_USER}`/`${POSTGRES_PASSWORD}` (`:3024-3025`) |
| DB_NAME | `packiot_analytics` (`services/barcode-service/cmd/barcode-service/main.go:73`) | same (`:3028`) |
| FIREBASE_PROJECT_ID | **`fbpackiot`** (`services/barcode-service/cmd/barcode-service/main.go:74`, const `services/barcode-service/cmd/barcode-service/auth_firebase.go:41`) | `""` (`:3039`) — **BUT `getenv` treats empty as unset (`services/barcode-service/cmd/barcode-service/main.go:216-221`), so the Firebase verifier IS registered with `fbpackiot` (`services/barcode-service/cmd/barcode-service/auth.go:69-70`)**; compose comment `:3036-3038` ("empty disables Firebase") is wrong |
| COGNITO_ISSUER | `""` → Cognito off (`services/barcode-service/cmd/barcode-service/main.go:75`) | `https://cognito-idp.us-east-1.amazonaws.com/us-east-1_0T9t1sTwt` (`:3040`) **AWS Cognito** |
| COGNITO_CLIENT_ID | `""` → aud check skipped (`services/barcode-service/cmd/barcode-service/main.go:76`) | `2ckuoa0ov598rdpdn3uv039h6e` (`:3041`) |
| LOG_LEVEL | `info` (`services/barcode-service/cmd/barcode-service/main.go:77`) | `info` (`:3042`) |

**3. PostgreSQL**: pgbouncer → `packiot_analytics` pool (`compose.staging.yml:132`), `MaxConns=5`, simple protocol (`services/barcode-service/cmd/barcode-service/main.go:108,114`). Unqualified table names (search_path UNPROVEN).
- READ: `box_scans` ⋈ `po_box_counter` (`services/barcode-service/cmd/barcode-service/scans.go:226-228`), `production_orders`, `equipments` (`services/barcode-service/cmd/barcode-service/scans.go:244-245,272-275`), `po_box_counter` (`services/barcode-service/cmd/barcode-service/scans.go:255`), `users` (Firebase uid → enterprise, `services/barcode-service/cmd/barcode-service/auth_firebase.go:47`).
- WRITE: `INSERT INTO box_scans` (`services/barcode-service/cmd/barcode-service/scans.go:267`), `INSERT INTO po_box_counter … ON CONFLICT DO UPDATE` (`services/barcode-service/cmd/barcode-service/scans.go:289-291`).
- `pg_advisory_xact_lock(id_production_order)` (`services/barcode-service/cmd/barcode-service/scans.go:204`).
- LISTEN/NOTIFY: none; SSE fan-out is in-memory (`sse.go`).

**4–6. RabbitMQ / MQTT / Redis** — none.

**7. HTTP** (:8446, `services/barcode-service/cmd/barcode-service/main.go:136-140`): `POST /v1/scans`, `GET /v1/scans/stream` (SSE) — both behind JWT middleware; `GET /healthz` (DB ping), `GET /metrics` (hand-written text).
- Outbound: Cognito JWKS `<COGNITO_ISSUER>/.well-known/jwks.json` (`services/barcode-service/cmd/barcode-service/auth_cognito.go:50`, fetch `:180`); Firebase x509 certs `https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com` (`services/barcode-service/cmd/barcode-service/auth_firebase.go:37`, fetch `:205`) — active because of the empty-env bug above.
- CORS: none found in code (searched `Access-Control|cors|Origin`) — compose comment `:3014-3015` claim of a CORS allowlist is unverified in this service.

**8. External deps**: Cognito JWKS (issuer configurable, JWKS URL **derived, not separately configurable** — `services/barcode-service/cmd/barcode-service/auth_cognito.go:50`); Google securetoken x509 (URL hard-coded const `services/barcode-service/cmd/barcode-service/auth_firebase.go:37`; project id configurable only to a non-empty value).

**9. Health / ports**: `/healthz` :8446; healthcheck `--healthcheck` (`compose.staging.yml:3052`, `services/barcode-service/cmd/barcode-service/main.go:97-99`).

**10. UNPROVEN**: schema of `box_scans`/`po_box_counter` (compose comment says `edge-node-red/db/36-box-scans.sql`, `:3007`); actual inbound producers.

---

## edge-session-broker  (Node.js, not Go — included for completeness)

**1. Build**: compose `compose.staging.yml:711` (`context: ./services/edge-session-broker`). `services/edge-session-broker/Dockerfile:4` `node:18-bookworm-slim`, installs AWS `session-manager-plugin` .deb from `https://s3.amazonaws.com/session-manager-downloads/...` at **build time** (`Dockerfile:9-23`), `CMD node server.mjs` (`:32`).

**2. Env vars** (`services/edge-session-broker/server.mjs`)

| Var | Default | Staging |
|---|---|---|
| BROKER_PORT | 8090 (`services/edge-session-broker/server.mjs:20`) | `8090` (`compose.staging.yml:717`) |
| BROKER_HTTP_PORT | 8091 (`services/edge-session-broker/server.mjs:21`) | not set |
| BROKER_TOKEN | `""` (`services/edge-session-broker/server.mjs:22`) → all WS rejected (`:195`) | `${EDGE_SESSION_BROKER_TOKEN:-esb-internal-staging}` (`:718`) |
| AWS_REGION | `us-east-1` (`services/edge-session-broker/server.mjs:23`) | `us-east-1` (`:716`) |
| SSM_ENDPOINT | `https://ssm.<region>.amazonaws.com` (`services/edge-session-broker/server.mjs:24`) | not set **AWS SSM** |
| BROKER_FORWARD_IDLE_MS | 600000 (`services/edge-session-broker/server.mjs:56`) | not set |

**3–6. Postgres / RabbitMQ / MQTT / Redis** — none (single 272-line file; searched `pg`, `amqp`, `mqtt`, `redis`).

**7. HTTP / WS**
- WS `:8090/shell` (`services/edge-session-broker/server.mjs:189`), token via `?token=` (`:195`); first frame = SSM StartSession handle → spawns `session-manager-plugin` (`:206-242`).
- HTTP `:8091`: `POST /forward` (header `x-broker-token`, `services/edge-session-broker/server.mjs:107-108`) starts a port-forward; `/p/:sessionId/*` reverse-proxies to `127.0.0.1:<localPort>` (`:136-149`).
- Caller: edge-api (`EDGE_SESSION_BROKER_WS_URL`/`_HTTP_URL`/`_TOKEN`, `compose.staging.yml:686-688`).

**8. External deps**: AWS SSM data plane (StreamUrl from edge-api's `ssm:StartSession`; plugin dials `SSM_ENDPOINT`, `services/edge-session-broker/server.mjs:24,33-41`). Holds no AWS creds itself (compose comment `:709-710`; no SDK import in `server.mjs`).

**9. Health / ports**: TCP connect probe on :8090 (`compose.staging.yml:723`). No HTTP health route.

**10. UNPROVEN**: none beyond the AWS-side behaviour (not testable offline; this service is inherently AWS-bound — dev needs a stub or exclusion).
