# sparkplug-decoder

Cloud SparkPlug B decoder: turns PLC totalizers from MQTT into per-sample increments and publishes JSON
envelopes to RabbitMQ. The same Go module also builds the edge binaries (sparkplug-agent, PLC readers,
simulators).

## What it does

The decoder subscribes to `spBv1.0/#` on Mosquitto, decodes each SparkPlug B message (aliases from
NBIRTH/DBIRTH), and runs every production counter (`ProdProcessedCount`, `ProdConsumedCount`,
`ProdDefectiveCount`) through `calc_production_counters`, a Go port of the Node-RED *Calc Production
Counters* function: first-observation seed, reset heal, 16-bit wrap, spike and speed guards, and line
aggregation (Phase 9). It writes each envelope to a SQLite outbox first, then publishes it to the `oee`
exchange with publisher confirms. It does not write the database and does not resolve topics to
equipment; stream-engine does both. Its old name, `edge-transformer`, survives in the main package
(`cmd/edge-transformer`), the network alias, env names, metric prefixes and paths.

## Where it fits

```text
PLC / sparkplug-agent / plc-sim / seed-replay
   │ MQTT spBv1.0/<group>/{N,D}{BIRTH,DATA}/…   (mosquitto:1883)
   ▼
sparkplug-decoder ── SQLite outbox (/var/lib/edge-transformer/outbox.db)
   │ AMQP exchange `oee`, key sparkplug.data.<group lowercased>  (or sparkplug.data)
   ▼
stream-engine (and oeecloud-fanout for the CPACK → SBXCPACK twin)

reads (analytics DB, read-only): packml_register + equipments (Parameter30700 seed),
client_descriptors (OEE profile), optionally read-api /internal/resolve-device
```

## Status and environments

| Environment | Where | Image | Ports | Health |
|---|---|---|---|---|
| dev (ADR-0060) | `dev/services/sparkplug-decoder.yml` · `sparkplug-decoder` (firehose key `sparkplug.data`, `dev/decoder/client.yaml`) | built from `services/sparkplug-decoder/Dockerfile` (Go 1.25 → distroless) | 9102 in-network | `GET /healthz` |
| staging | `compose.staging.yml` · `sparkplug-decoder` (no profile), IP 172.18.0.23, alias `edge-transformer`; mounts `docs/clients/cpack.yaml` as `client.yaml` | same, built on deploy, entrypoint `/usr/local/bin/sparkplug-decoder` | 9102 health/metrics; 9105 onboard API (in-network) | `GET /healthz`; healthcheck `sparkplug-decoder --healthcheck` |
| production | defined in `compose.production.yml` · profile `client-ingest`; new-stack production is not promoted | same | same | same |
| on-prem edge box | `compose.onprem-edge.yml` · `edge-transformer` (`LOCAL_DECODE_ONLY=true`, writes local state only) | `packiot-sparkplug-decoder:local` | 9102 | `--healthcheck` |

The image ships these binaries (`Dockerfile`); other `cmd/` tools are CLIs run with `go run`:

| Binary | Runs as | What |
|---|---|---|
| `sparkplug-decoder` (`cmd/edge-transformer`) | the decoder | this README |
| `sparkplug-agent` | staging `sparkplug-agent-shared` (profile `shared-tee`, the multi-tenant cloud ingest), `sparkplug-agent-cpack` (profile `cpack-tee`); on-prem `sparkplug-agent` (`127.0.0.1:9104`) | HTTP raw tags → tag map / derive → SparkPlug B upstream |
| `edge-dashboard` | on-prem `edge-dashboard` (`:8080`) | floor board over the local current-state DB |
| `plc-sim` | staging `plc-sim` (profile `plc-sim`) | synthetic SparkPlug PLC; receives DCMD |
| `s7-reader`, `s7-softplc` | staging, profile `s7` | Siemens S7 reader and a pure-Go soft PLC |
| `modbus-reader`, `opcua-reader` | shipped in the image; no compose file runs them | Modbus / OPC UA readers → SparkPlug |
| `bispharma-twin` | staging `bispharma-twin` (no profile; inert unless `BISPHARMA_TWIN_ENABLED=true`) | synthetic Bispharma staging line |
| `seed-replay` | dev `seed-replay` | replays the dev seed's rows from one week earlier as SparkPlug |
| CLIs: `onboard`, `onboard-gen`, `onboard-import`, `onboard-capture`, `capture-fixtures`, `derive-replay`, `inject-counter-fixture`, `numeric-sim` | `go run ./cmd/<name>` | onboarding artifacts, fixtures, replays |

## Interfaces

### HTTP

| Binary | Method | Path | Auth | What |
|---|---|---|---|---|
| decoder | GET | `/healthz`, `/health` | none | JSON snapshot; 503 when degraded (outbox > 5 000 rows or oldest > 60 s, MQTT stale, no confirms for `EMIT_LIVENESS_TIMEOUT_SECONDS`) |
| decoder | GET | `/metrics` | none | Prometheus |
| decoder, agent | POST | `/v1/onboard/generate`, `/v1/onboard/simulate` (port 9105, `ONBOARD_API_ENABLED`) | `Bearer <ONBOARD_API_KEY>` | descriptor → onboarding artifacts; pure, no side effects. Called by edge-api via `ONBOARD_GENERATE_URL` |
| agent | POST | `/v1/tags`, `/v1/counters` (port 9104, `AGENT_HTTP_INGEST_ENABLED`) | `X-Ingest-Key` | raw-tag ingest from a client tee or reader |
| edge-dashboard | GET | `/`, `/api/state`, `/healthz` | none | local board |

Specs: [`sparkplug-agent.openapi.json`](../../docs/api/openapi/sparkplug-agent.openapi.json) and
[`onboard-api.openapi.json`](../../docs/api/openapi/onboard-api.openapi.json) (each binary also
serves `GET /openapi.json`); portal https://api.staging.packiot.app/docs/ (cs-admin SSO). Staging's
public agent hosts (`ingest.<domain>:8449/v1/tags`, `cpack-ingest.<domain>:8447/v2/tags`) are described
in the agent spec.

### Messaging

| Direction | Where | Detail |
|---|---|---|
| in | MQTT `spBv1.0/#` (`MQTT_ENABLED=true`) | QoS 0; data before a birth is dropped (`sparkplug: data before birth`) |
| in (off on staging) | AMQP `SOURCE_EXCHANGE` / `WORKER_QUEUE` | legacy input, `AMQP_SOURCE_ENABLED=false` |
| out | AMQP `oee`, key `sparkplug.data.<tenant>` (`F3_PER_TENANT_ROUTING=true`, staging) else `sparkplug.data` | `{timestamp, gateway, source_type:"refactored", metrics:[{name, timestamp, value=increment, counter=absolute, curspeed?, id?}]}`; persistent, confirmed |
| out (off) | MQTT `NCMD` rebirth, `DCMD` commands from AMQP `edge.commands.<tenant>` | `ET_REQUEST_REBIRTH_ENABLED`, `EDGE_COMMANDS_ENABLED` |

The tenant is the SparkPlug group, lowercased. `source_type` `""` (F1) and `go` (F2) are retired legs
(`SHADOW_EMIT_PRODUCTION=false`, `SHADOW_EMIT_GO=false` on staging).

### Database

Read-only, analytics DB: `packml_register` + `equipments` (Parameter30700 seed, every 5 min, via
`POSTGRES_URL`), `client_descriptors` (OEE profile, counters-only rates, via `POSTGRES_*` or a DSN
override). Outbox and durable Calc baselines live in SQLite on the `edge_transformer_outbox` volume.
The ERP connector (off unless a descriptor declares a `database` integration) reads a customer DB and
upserts POs through edge-api's CSV import.

## Configuration

Staging values are in `compose.staging.yml`; secrets come from Secrets Manager
(`RABBITMQ_SECRET_ID`, staging `packiot/staging/rabbitmq-sparkplug-decoder-creds`) or `.env`.

**Decoder — inputs and broker**

| Name | Default | Effect |
|---|---|---|
| `EDGE_TRANSFORMER_MODE` | `factory` | `factory` or `dev_replay` (same behaviour today) |
| `MQTT_ENABLED`, `MQTT_BROKER_URL`, `MQTT_CLIENT_ID` | `false`, `tcp://mosquitto:1883`, `edge-transformer` | MQTT input; client id must be unique per broker |
| `MQTT_USERNAME`, `MQTT_PASSWORD` | empty | broker login |
| `MQTT_STALE_THRESHOLD_SECONDS` | `60` | ≤ 0 disables the "no data" degradation (staging `-1`) |
| `AWS_REGION`, `RABBITMQ_SECRET_ID` | `us-east-1`, `packiot/staging/rabbitmq-edge-transformer-creds` | broker credentials secret |
| `CREDS_SOURCE`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD` | unset | `env` = credentials from env (dev) |
| `RABBITMQ_HOST`, `RABBITMQ_PORT` | `rabbitmq`, `5672` | broker |
| `AMQP_SOURCE_ENABLED` | `true` | legacy AMQP input (staging `false`) |
| `SOURCE_EXCHANGE`, `WORKER_QUEUE`, `RETRY_EXCHANGE`, `RETRY_QUEUE`, `FAILED_EXCHANGE`, `FAILED_QUEUE` | `plc.normalized`, `edge-transformer-q`, `plc.normalized-retry`, `edge-transformer-q-retry-30s`, `plc.normalized-failed`, `edge-transformer-q-failed` | legacy input topology |
| `RETRY_TTL_MS`, `MAX_RETRIES`, `PREFETCH` | `30000`, `5`, `50` | legacy input retry |
| `CLIENT_YAML_PATH` | `/etc/packiot/client.yaml` | tenant list and capabilities |
| `HEALTH_PORT`, `LOG_LEVEL` | `9102`, `info` | |

**Decoder — counter math (Calc)**

| Name | Default | Effect |
|---|---|---|
| `USE_GO_PORT` | `false` | run Calc (staging `true`); needed by everything below |
| `CALC_CUTOVER_REFACTORED` | off | envelope carries Calc increments instead of raw totalizers |
| `CALC_RESET_HEAL_ENABLED` | `true` | reseed on a reset instead of emitting the whole totalizer |
| `CALC_STATE_DURABLE` | `true` | checkpoint baselines in the outbox DB so a restart keeps deltas (needs the outbox) |
| `CALC_NO_SPEED_GUARD_FALLBACK` | `false` | no glitch guard for machines with no speed reference (staging `true`) |
| `CALC_MONOTONICITY_GUARD`, `CALC_COUNTER_ROLLOVER` | `false` | drop out-of-order samples; per-equipment `CounterMax` wrap |
| `CALC_COUNTER_SPIKE_MARGIN` | `0` (off) | default spike-guard margin (staging `0`) |
| `OEE_PROFILE_FROM_DB`, `OEE_PROFILE_REFRESH_SECONDS`, `OEE_PROFILE_DSN` | `false`, `300`, unset | per-client margin and rated speed from `client_descriptors` |
| `COUNTERS_ONLY_OEE_ENABLED`, `COUNTERS_ONLY_IDEAL_RATES` | `false`, `{}` | counters-only glitch bound; JSON unit topic → parts/min |
| `COUNTERS_ONLY_FROM_DB`, `COUNTERS_ONLY_REFRESH_SECONDS`, `COUNTERS_ONLY_DSN` | `false`, `300`, unset | rates from the DB |
| `POSTGRES_HOST` (else `POSTGRES_HOST_UPSTREAM`), `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_SSLMODE` | –, `5432`, `packiot`, –, –, `disable` | DSN for the two watchers |
| `PHASE9_LINE_AGG_ENABLED`, `POSTGRES_URL` | off, unset | seed `Parameter30700` from the DB and emit line aggregates; must stay off where another writer produces line counts |
| `LINE_TRACE_TENANTS` | empty | INFO trace of per-counter decisions for these groups |

**Decoder — output, identity, optional features**

| Name | Default | Effect |
|---|---|---|
| `SHADOW_EMIT_REFACTORED`, `SHADOW_EMIT_PRODUCTION`, `SHADOW_EMIT_GO` | off, off, on | which `source_type` legs to emit (staging: refactored only) |
| `F3_PER_TENANT_ROUTING` | off | key `sparkplug.data.<tenant>` |
| `OUTBOX_ENABLED`, `OUTBOX_PATH`, `OUTBOX_CAP` | `false`, `/var/lib/edge-transformer/outbox.db`, `100000` | store-and-forward |
| `EMIT_LIVENESS_TIMEOUT_SECONDS` | `120` | health fails when publishing without confirms this long |
| `LOCAL_DECODE_ONLY`, `LOCAL_STATE_DB` | unset | on-prem: decode to a local current-state SQLite, no AMQP (ADR-0053) |
| `ET_REQUEST_REBIRTH_ENABLED`, `ET_REQUEST_REBIRTH_MIN_INTERVAL_SECONDS` | `false`, `30` | rebirth NCMD on gaps / data before birth |
| `BIRTH_BOUND_ROUTING`, `BIRTH_BOUND_RESOLVER`, `BIRTH_BOUND_DEVICE_MAP`, `BIRTH_BOUND_ENTERPRISE_ID`, `BIRTH_BOUND_RESOLVER_TTL_SECONDS`, `BIRTH_BOUND_RESOLVER_NEG_TTL_SECONDS` | `false`, `map`, `{}`, `0`, `600`, `30` | ADR-0046 birth-declared identity (off) |
| `REFDATA_URL`, `REFDATA_INTERNAL_KEY` | empty | read-api resolver for the `refdata` resolver |
| `EDGE_COMMANDS_ENABLED`, `EDGE_COMMANDS_ALLOWED`, `EDGE_COMMANDS_EXCHANGE`, `EDGE_COMMANDS_QUEUE_PREFIX`, `EDGE_COMMANDS_RETRY_EXCHANGE`, `EDGE_COMMANDS_FAILED_EXCHANGE`, `EDGE_COMMANDS_EDGE_NODE`, `EDGE_COMMANDS_DEDUP_CAP` | `false`, `po_setup,param_write`, `edge.commands`, `edge-commands`, `edge.commands-retry`, `edge.commands-failed`, `plc-sim`, `4096` | AMQP → DCMD write-back |
| `ONBOARD_API_ENABLED`, `ONBOARD_API_PORT`, `ONBOARD_API_KEY` | off, `9105`, – | onboard API; refuses to start enabled without a key |
| `ERP_SQL_TEMPLATE_DIR`, `EDGE_API_URL`, `EDGE_API_KEY`, `EDGE_API_ENTERPRISE_ID` | unset | ERP connector templates and PO upsert target; DSNs come from env vars named by the descriptor's `dsn_ref` |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER_ARG` | unset, `1.0` | tracing (staging Tempo, `0.1`) |

**Other binaries** (defaults in parentheses)

| Binary | Env |
|---|---|
| sparkplug-agent | `AGENT_CONFIG`, `AGENT_TENANTS_DIR`, `AGENT_TENANTS_PROFILE_DIR`, `AGENT_PROFILE_PATH`, `AGENT_TICK_SEC` (5), `AGENT_HTTP_INGEST_ENABLED` (false), `AGENT_INGEST_PORT` (9104), `AGENT_INGEST_API_KEY`, `AGENT_INGEST_MAX_BODY_BYTES`, `AGENT_NUMERIC_INGEST_ENABLED` (false), `AGENT_BIRTH_ALL_MAPPED` (true), `AGENT_MULTI_DERIVE_ENABLED` (true), `AGENT_LINK_HEALTH_ENABLED` (true), `AGENT_PARAM_DECOMPOSITION` (false), `AGENT_UNMAPPED_VERBOSE` (false), `AGENT_CAPTURE_ENABLED` (false), `AGENT_CAPTURE_FLUSH_SEC` (30), `AGENT_CAPTURE_STATUS_POLL_SEC` (300), `AGENT_TAGMAP_FROM_REGISTER` (false), `AGENT_REGISTER_DSN`, `AGENT_OUTBOX_DIR`, `OUTBOX_PATH`, `AGENT_UPLINK_CA`, `AGENT_UPLINK_TLS_CERT`, `AGENT_UPLINK_TLS_KEY`, `DB_HOST` (postgres), `DB_PORT` (5432), `DB_NAME` (packiot), `DB_USER`, `DB_PASSWORD`, `DB_SSLMODE` (disable), `EMIT_DEFINITIVE_BIRTH` (false), `MQTT_STALE_THRESHOLD_SECONDS`, `ONBOARD_API_ENABLED`, `ONBOARD_API_PORT` (9105), `ONBOARD_API_KEY`, `ONBOARD_API_MAX_BODY_BYTES`, `HEALTH_PORT` (9103), `LOG_LEVEL` |
| edge-dashboard | `LOCAL_STATE_DB` (required), `TENANT` (required), `DASHBOARD_PORT` (8080), `DASHBOARD_STALE_SECONDS` |
| plc-sim | `MQTT_BROKER_URL`, `PLC_SIM_EDGE_NODE` (plc-sim), `PLC_SIM_TICK_SEC` (5), `EMIT_DEFINITIVE_BIRTH` |
| s7-reader | `S7_HOST`, `S7_ENDPOINT`, `S7_RACK` (0), `S7_SLOT` (2), `S7_DB` (100), `S7_GROUP` (INCOPLAST), `S7_EDGE_NODE`, `S7_TICK_SEC` (5), `TENANT`, `CLIENT_CONFIG`, `RAW_EMIT` (true), `MQTT_BROKER_URL`, `PLC_HOST_<ENDPOINT>` |
| s7-softplc | `LISTEN_ADDR`, `S7_DB` (100), `SOFTPLC_TICK_SEC` (5), `SOFTPLC_SPEED` (42.5), `SOFTPLC_CONSUMED_STEP` (1), `SOFTPLC_PROCESSED_STEP` (20) |
| modbus-reader | `MODBUS_HOST`, `MODBUS_ENDPOINT`, `MODBUS_UNIT_ID` (1), `MODBUS_GROUP` (INCOPLAST), `MODBUS_EDGE_NODE`, `MODBUS_TICK_SEC` (5), `TENANT`, `CLIENT_CONFIG`, `RAW_EMIT` (true), `MQTT_BROKER_URL`, `PLC_HOST_<ENDPOINT>` |
| opcua-reader | `OPCUA_ENDPOINT`, `OPCUA_ENDPOINT_URL`, `OPCUA_GROUP` (INCOPLAST), `OPCUA_EDGE_NODE`, `OPCUA_TICK_SEC` (5), `TENANT`, `CLIENT_CONFIG`, `RAW_EMIT` (true), `MQTT_BROKER_URL`, `PLC_HOST_<ENDPOINT>` |
| bispharma-twin | `BISPHARMA_TWIN_ENABLED` (false), `TWIN_BROKER`, `TWIN_CLIENT_ID`, `TWIN_GROUP` (BISPHARMASTAGING), `TWIN_EDGE_NODE`, `TWIN_LINE` (L01), `TWIN_INTERVAL_SEC` (15), `TWIN_RATE_PER_MIN` (600), `TWIN_SCRAP_RATE` (0.03), `TWIN_STOP_PROB` (0.03), `TWIN_STOP_MIN_SEC` (120), `TWIN_STOP_MAX_SEC` (600), `TWIN_STATE_FILE`, `TWIN_TENANT_CONFIG` |
| seed-replay | `DATABASE_URL`, `MQTT_BROKER_URL`, `REPLAY_GROUP_ID` (DEV), `REPLAY_EDGE_NODE` (seed-replay), `REPLAY_TICK` (5s), `REPLAY_LAG` (168h), `REPLAY_ENTERPRISES` |
| numeric-sim | `AGENT_INGEST_API_KEY` |

## Run locally

```sh
make dev SVC="seed-replay stream-engine"   # replay → decoder → stream-engine (+ read-api)
docker compose -f dev/compose.yml --env-file dev/.env.dev up -d --build seed-replay sparkplug-decoder   # after Go edits
make dev-smoke SVC="sparkplug-decoder"
cd services/sparkplug-decoder && go test ./...
```

The decoder is in the `pipeline` slice of `.github/workflows/dev-slices.yml` and in the
`go-services.yml` matrix (`go test -race`). Calc tests live in
`internal/transforms/calc_production_counters/`; `testdata/parity/` holds a Node.js decode parity check.

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`); the
  same workflow injects a synthetic counter fixture, inspects the decoder and runs an outbox chaos test.
  Agents behind profiles (`shared-tee`, `cpack-tee`) rebuild only when the profile is active.
  `inspect-edge-transformer.yml` prints the decoder's live state on demand.
- **Metrics** (scrape job `edge-transformer`): `edge_transformer_emitted_total{flow}`,
  `calc_evaluations_total{tenant,kind,outcome}`, `calc_state_*` (incl. `calc_state_restored_entries`,
  `calc_state_checkpoint_failures_total`), `edge_transformer_mqtt_*`,
  `edge_transformer_sparkplug_seq_gaps_total`, `edge_transformer_shadowpub_*`, `outbox_depth`,
  `outbox_oldest_age_seconds`, `edge_transformer_birthbind_*`, `edge_transformer_commands_*`,
  `edge_transformer_rebirth_requests_total`, `edge_transformer_onboard_generate_total`.
  Dashboards: `audience/00-overview.json`, `audience/03-pipeline-data.json`,
  `audience/04-ingest-debug.json`, `library/05-ingest.json`.
- **Alerts** (`monitoring/prometheus/rules.yml`): `MQTTDisconnected`, `TransformerOutboxBacklog`,
  `TransformerOutboxStale`, `TransformerPublishNacked`, `TransformerMqttDrops`, `SparkplugSeqGapStream`.
- **Rules:** never run two decoders on the same Mosquitto namespace (each computes its own deltas);
  never publish test fixtures under a real tenant group; prefer `LINE_TRACE_TENANTS` over
  `LOG_LEVEL=debug` (a recreate drops alias tables until the next birth).
- **Known failure modes:** spike guard measured Δt per unit instead of per counter (CPACK L6 net −40 %,
  fixed #1462); decoder started before RabbitMQ and published nothing (fixed with retry-then-exit,
  #1447); ERP connector nil-capabilities crash loop (#1327); machines without MachSpeed lost all counts
  (`CALC_NO_SPEED_GUARD_FALLBACK`); restart lost one delta per stream (`CALC_STATE_DURABLE`, #1671).

## Code layout

| Path | What |
|---|---|
| `cmd/edge-transformer/` | decoder main: MQTT handler, envelope build, outbox drain, Phase 9 seed, birth-bind wiring |
| `cmd/<binary>/` | the edge binaries and CLIs listed above |
| `internal/config/` | decoder env config |
| `internal/transforms/calc_production_counters/` | Calc port (decision tree, counter math, line aggregation, state) |
| `internal/sparkplug/`, `internal/mqtt/` | protobuf decode, alias tables, subscriber, rebirth requester |
| `internal/analyticspub/`, `internal/outbox/` | envelope + RabbitMQ publisher, SQLite store-and-forward |
| `internal/oeeprofile/`, `internal/countersrate/` | DB watchers |
| `internal/birthbind/`, `internal/refdataresolver/` | ADR-0046 identity routing |
| `internal/command/` | DCMD command channel |
| `internal/erpconnector/`, `internal/edgeapiclient/`, `internal/writeforward/` | ERP read and edge-api clients |
| `internal/agent/` | sparkplug-agent: tag store, deriver, HTTP ingest, onboard API, uplink, capture |
| `internal/s7/`, `internal/modbus/`, `internal/opcua/`, `internal/rawemit/` | PLC readers |
| `internal/localstate/` | on-prem current-state SQLite |
| `internal/health/`, `internal/metrics/`, `internal/tracing/` | `/healthz`, Prometheus, OpenTelemetry |

## Related docs

- [ADR-0009 edge-transformer service](../../docs/adr/0009-edge-transformer-go-service-and-nodered-split.md)
- [ADR-0010 SparkPlug decode in Go](../../docs/adr/0010-sparkplug-decode-in-go-end-state.md)
- [ADR-0011 durability boundary and store-and-forward](../../docs/adr/0011-durability-boundary-and-store-and-forward.md)
- [ADR-0046 edge source plugin contract](../../docs/adr/0046-edge-source-plugin-contract.md)
- [ADR-0049 OEE correctness](../../docs/adr/0049-oee-correctness.md)
- [ADR-0053 on-prem ingest edge](../../docs/adr/0053-on-prem-ingest-edge-for-outage-autonomy.md)
- [ADR-0058 client customization](../../docs/adr/0058-client-customization-capability.md)
- [ADR-0061 remove PackML from the cloud](../../docs/adr/0061-remove-packml-from-the-cloud.md)
- [`docs/client.example.yaml`](docs/client.example.yaml) — example client config

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [sparkplug-decoder](https://wiki.packiot.app/understand/components/sparkplug-decoder/) |
| API reference (generated from the spec) | [onboard-api](https://wiki.packiot.app/reference/api/onboard-api/) |
| Interactive API docs (staging, SSO) | [API portal](https://api.staging.packiot.app/docs/) |
| Sparkplug agent (HTTP ingest) | [component](https://wiki.packiot.app/understand/components/sparkplug-agent/) · [API](https://wiki.packiot.app/reference/api/sparkplug-agent/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
