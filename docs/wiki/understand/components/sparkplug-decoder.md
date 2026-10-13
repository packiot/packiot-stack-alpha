---
title: sparkplug-decoder (cloud decoder)
layer: 3
owner_area: ingestion
last_verified: 2026-09-28
---
# sparkplug-decoder (cloud decoder)

> **Layer 3 · Component** — the cloud service that reads Sparkplug B from Mosquitto, turns PLC
> totalizers into per-sample increments, and publishes JSON envelopes to RabbitMQ. For engineers
> changing counter math, routing, or the decoder's configuration.
> Up: [Ingestion subsystem](../subsystems/ingestion.md)

## Responsibility

The decoder owns **the counter math at the ingest boundary**: for each production counter it keeps
the last absolute value per topic in memory and emits the difference (the *increment*) plus the
absolute value, after guarding against first-boot spikes, resets, rollovers and impossible jumps.
It then publishes one envelope per Sparkplug message to the `oee` exchange. It does **not** write to
the database and does **not** resolve topics to `id_equipment`; the
[stream-engine](stream-engine.md) does that when it writes Bronze and Silver.

The container is called `sparkplug-decoder` (network alias `edge-transformer`, its old name). The
binary is built from `services/sparkplug-decoder/cmd/edge-transformer`, and many log lines,
metrics and env names still say "edge-transformer". The same image also ships the edge binaries
(`sparkplug-agent`, `plc-sim`, `s7-reader`, `modbus-reader`, `opcua-reader`, `bispharma-twin`, …);
those are covered in the [edge subsystem](../subsystems/edge.md): see
[sparkplug-agent](sparkplug-agent.md), [PLC readers](plc-readers.md) and
[simulators and twins](simulators-and-twins.md).

## At a glance

| | |
|---|---|
| Language / runtime | Go 1.25, distroless `static-debian12:nonroot` |
| Repo path | `services/sparkplug-decoder` (main: `cmd/edge-transformer/main.go`) |
| Compose service | `sparkplug-decoder` (`compose.staging.yml`), static IP `172.18.0.23` |
| Image | built from `services/sparkplug-decoder/Dockerfile`, entrypoint `/usr/local/bin/sparkplug-decoder` |
| Host (staging) | the staging app host (EC2), with the rest of the stack |
| Ports | 9102 `/healthz`, `/health`, `/metrics`; 9105 onboard-generate API (`ONBOARD_API_ENABLED=true` on staging) |
| Limits | `mem_limit: 128m`, `cpus: 0.5` |
| Volumes | `edge_transformer_outbox` → `/var/lib/edge-transformer` (SQLite outbox); `docs/clients/cpack.yaml` → `/etc/packiot/client.yaml` (read-only) |
| Depends on | Mosquitto, RabbitMQ; analytics DB (read-only lookups); read-api (only if birth-bound routing is on) |
| Depended on by | stream-engine (through RabbitMQ), oeecloud-fanout |

## Inputs & outputs

| Direction | What | Detail |
|---|---|---|
| In | MQTT `spBv1.0/#` on `tcp://mosquitto:1883`, QoS 0 | NBIRTH/DBIRTH seed the alias table; NDATA/DDATA carry values |
| In (read-only DB) | `packml_register` + `equipments` | Parameter30700 seed for Phase 9 line aggregation (every 5 min) |
| In (read-only DB) | `client_descriptors.descriptor->'oee_profile'` | per-client spike margin and rated speed (every 300 s) |
| In (read-only DB, off on staging) | `client_descriptors.descriptor->>'counters_only_oee'` + `equipments.production_speed` | counters-only rated speeds (`COUNTERS_ONLY_FROM_DB`) |
| Out | AMQP exchange `oee`, routing key `sparkplug.data.<tenant>` | JSON envelope, persistent, publisher confirms |
| Out (off) | `spBv1.0/<g>/NCMD/<node>` rebirth request | `ET_REQUEST_REBIRTH_ENABLED` |
| Out (off) | `spBv1.0/<g>/DCMD/<node>` | command channel, `EDGE_COMMANDS_ENABLED` |
| Out (off unless configured) | `POST /api/admin/production-orders/csv/import` on edge-api | ERP connector PO upsert, needs `EDGE_API_URL` |

Envelope shape (`internal/analyticspub/publisher.go`):

```text
{ "timestamp": <ms>, "gateway": "...", "source_type": "refactored",
  "metrics": [ { "name": "CPACK/SC/LINHAS/L5/TEXA/Admin/ProdProcessedCount/65/Unit",
                 "timestamp": <ms>, "value": <increment>, "counter": <absolute>,
                 "curspeed": <parts/min, optional>, "id": <param id, optional> } ] }
```

`source_type` decides where the stream-engine writes: `refactored` → the analytics DB medallion
schemas. `""` (F1) and `go` (F2) are retired legs, disabled on staging by `SHADOW_EMIT_PRODUCTION`
and `SHADOW_EMIT_GO`.

## Internal design

```text
 MQTT ─▶ subscriber (bounded queue 10 000) ─▶ sparkplugHandler
          │ decode protobuf, resolve aliases (StateStore per group/node/device)
          │ NBIRTH: seed Calc state from MachSpeed / Parameter* metrics
          ▼
       Calc (calc_production_counters) per counter metric ── state in memory (memState)
          ▼
       buildCutoverMetrics: Calc increments + non-counter metrics passed through
          ▼
       SQLite outbox (enqueue) ──▶ drain goroutine ──▶ RabbitMQ `oee` (confirm, then delete row)
```

### Alias resolution and births

`internal/sparkplug` keeps one alias table per publisher key (group, edge node, device). Data that
arrives before a birth returns `ErrNoBirth`: it is logged ("data before birth") and dropped, and a
rebirth NCMD is requested if that feature is on. Sequence gaps increment
`edge_transformer_sparkplug_seq_gaps_total{group_id,edge_node_id,device_id}`.

### Counter classification

A metric is a counter when its name contains `ProdProcessedCount` (processed = net / output),
`ProdConsumedCount` (consumed = gross / input) or `ProdDefectiveCount` (scrap). Anything else is
passed through (for example `/Status/MachSpeed`, `UnitModeCurrent`, `Parameter*`), and a few are
also stored as Calc state: `MachSpeed`, `Parameter*30750*` (speed threshold %), `Parameter30758`
(threshold mode), `Parameter*30761*` (external speed), `Parameter*30710*` (counter multiplier),
`Parameter30700` (line machine CSV).

The unit key is the first five topic segments (`Enterprise/Site/Area/Line/Unit`). When segment 4
is `Admin`, `Status` or `Command` the topic belongs to the line itself and the key is the first
four segments. The same rule is used by the stream-engine resolver.

The DB-backed counter-role override (`COUNTER_ROLES_FROM_DB`) was **removed on 2026-08-26**: it
read the same `packml_register.id_{infeed,outfeed,reject}counter` columns that Phase 9 uses as
count indices and poisoned CPACK L5 net. Line counter roles now live in the stream-engine
([line-lead](stream-engine.md#line-lead)).

### `calc_production_counters`: the decision tree

`internal/transforms/calc_production_counters/calc.go` is a port of the Node-RED function
*Calc Production Counters*. The decoder builds the topic as `<name>***TRIG` (the plain trigger) and
calls `CalcWithConfig`. Phases, in order:

| Phase | What happens | Drops the sample when |
|---|---|---|
| 1 | Parse topic, read unit mode | unit is in SETUP (mode 6) |
| 2 | Read the three prior absolutes for the unit | no trigger flag (never on this path) |
| First-observation seed (ADR-0045 P1) | no stored baseline for this counter → store `cur`, emit nothing | always, on the first sample after a restart |
| Monotonicity guard (`CALC_MONOTONICITY_GUARD`, off) | drop samples not newer than the last one for that counter | timestamp ≤ last |
| 3 | `cur > prev` → increment. `cur < prev` → a 16-bit wrap (`prev ≥ 61440`, `cur < 4096`) keeps counting across 65 536; otherwise a **reset**. `CALC_COUNTER_ROLLOVER` (off) adds a per-equipment `CounterMax` wrap | – |
| Reset-heal (`CALC_RESET_HEAL_ENABLED`, **on by default**) | on a genuine reset, reseed the baseline to `cur` and emit nothing | reset |
| 4 | TRIG corrections. With plain `***TRIG`: if the defective absolute is ≤ 0, set defective = consumed − processed. The suffix variants `TRIG_CS`, `TRIG_CI`, `TRIG_C=I`, `TRIG_C=O`, `TRIG_CO`, `STATESPEED_THIS` exist for Node-RED parity but are not produced by this decoder | – |
| Spike guard (WS1, per client) | clamp an increment above `margin × rated_speed × Δt/60 000` to that ceiling | never drops; clamps |
| 5 | Persist new absolutes (negatives stored as 0) | – |
| 6 | Speed = consumed increment / time since the unit's last speed timestamp × 60 000, × `Parameter*30710*` if set | – |
| 7–8 | Glitch guard: emit a counter only if `speed < 3 × MachSpeed`. Counters-only machines use `3 × IdealRate`. With `CALC_NO_SPEED_GUARD_FALLBACK=true` a machine with no MachSpeed and no ideal rate has no guard | speed ≥ bound |
| 9 | Line aggregation: if the unit's count index is first or last in the line's `Parameter30700` CSV, also emit line-level consumed / processed / defective (tagged `LineAggregated`) | – |
| 10 | Status metric (`StateCurrent = 6`) when speed ≥ `MachSpeed × Parameter*30750* / 100` (or the mode-4 rolling average), unless `Parameter*30763*` disables it | – |

**Per-counter spike-guard timestamp (#1462, 2026-09-27).** The spike guard measures Δt from the
previous reading of **the same counter** (`<counter topic>___GUARD_TS`). It used to use the unit's
last speed timestamp. CPACK L6-TEXA publishes consumed and processed ~0.6 s apart, so processed
saw a 0.6 s window and every net increment was clamped to ~14 (L6 net −40% from 2026-09-23 to
09-27). The guard's rate is `IdealRate` for counters-only topics, else `GuardRatedSpeed`
(`equipments.production_speed` from the client OEE profile).

**Phase 9 and `PHASE9_LINE_AGG_ENABLED`.** CPACK's PLCs never publish `Parameter30700`. With the
flag on, `line_param30700_seed.go` seeds it from the analytics DB at boot and every 5 minutes:
first the explicit `[id_infeedcounter, id_outfeedcounter]` of the line's `packml_register` row,
else the ascending list of member count indices. The same flag lets the `LineAggregated` metrics
through to the envelope. It must stay off anywhere another writer produces line counts (the
two-writer double count of 2026-07-14, #456).

### F3 envelope build (`CALC_CUTOVER_REFACTORED`)

With `CALC_CUTOVER_REFACTORED=true` the `refactored` envelope carries Calc's output
(`value` = increment, `counter` = absolute, `curspeed`) and drops the raw cumulative counters.
Before this, the continuous aggregate summed cumulative totalizers into billions. Non-counter
metrics are passed through unchanged.

### Outbox

With `OUTBOX_ENABLED=true` each envelope is written to SQLite (`OUTBOX_PATH`, cap `OUTBOX_CAP`
rows, oldest dropped beyond it) **before** it is published. `runOutboxDrain` reads 10 rows at a
time, publishes with a 10 s confirm timeout, deletes on confirm, and backs off exponentially
(1 s → 60 s) on failure. The W3C `traceparent` is stored in the row so the trace continues after
the drain. `/healthz` reports the outbox degraded above 5 000 rows or when the oldest row is older
than 60 s.

### Other loops

| Loop | Interval | Gate |
|---|---|---|
| Parameter30700 seed | boot + 5 min | `PHASE9_LINE_AGG_ENABLED` and `USE_GO_PORT` |
| OEE-profile watcher (spike margins, rated speeds) | `OEE_PROFILE_REFRESH_SECONDS` (300) | `OEE_PROFILE_FROM_DB` |
| Counters-only rate watcher | `COUNTERS_ONLY_REFRESH_SECONDS` (300) | `COUNTERS_ONLY_FROM_DB` |
| Outbox drain | continuous, 200 ms idle poll | `OUTBOX_ENABLED` |
| RabbitMQ connection monitor | on close | always when publishing |
| ERP connector | per integration cadence | tenant descriptor declares a `database` integration |

### ERP connector (ADR-0019 G1)

`internal/erpconnector` reads production orders (and other datasets) from a customer database
declared under `capabilities.integrations` in the tenant's client descriptor, using versioned SQL
templates from `ERP_SQL_TEMPLATE_DIR` and secret-referenced DSNs. The read sink logs every cycle.
For `production_orders`, and only when `EDGE_API_URL`, `EDGE_API_KEY` and `EDGE_API_ENTERPRISE_ID`
are set, it upserts the rows through edge-api's CSV import (idempotent on
`(id_enterprise, id_order)`). CPACK's descriptor declares no integrations, so it is inert on
staging. `Capabilities` is optional (`nil` for CPACK); a missing nil-check crash-looped the shared
decoder on 2026-09-16 (#1327).

### Where "derive" (ADR-0058) lives

The per-client **derive** stage (integral, sum, sandboxed expression) runs in the
**sparkplug-agent** at the edge (`internal/agent/deriver`), before Sparkplug encoding, so this
decoder only sees canonical counts. The cloud decoder's ADR-0058 piece is the per-client OEE profile
(spike margin + rated speed) read from `client_descriptors`.

## Configuration

Staging values come from `compose.staging.yml`. "—" means not set there: the code default applies
unless the host `/opt/packiot/.env` (not in git) sets it.

| Variable | Default | Staging | Effect |
|---|---|---|---|
| `EDGE_TRANSFORMER_MODE` | `factory` | `factory` | `factory` or `dev_replay` (same behaviour today) |
| `LOG_LEVEL` | `info` | `info` | |
| `AWS_REGION` | `us-east-1` | `us-east-1` | |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-edge-transformer-creds` | `packiot/staging/rabbitmq-sparkplug-decoder-creds` | AMQP user/password |
| `CREDS_SOURCE` | unset | — | `env` = read `RABBITMQ_USER/PASSWORD` from env instead of Secrets Manager |
| `RABBITMQ_HOST` / `RABBITMQ_PORT` | `rabbitmq` / 5672 | same | |
| `SOURCE_EXCHANGE` | `plc.normalized` | `edge.plc-normalized` | legacy AMQP input |
| `AMQP_SOURCE_ENABLED` | `true` | `false` | consume the legacy AMQP input; MQTT is the input on staging |
| `WORKER_QUEUE`, `RETRY_EXCHANGE`, `RETRY_QUEUE`, `FAILED_EXCHANGE`, `FAILED_QUEUE` | `edge-transformer-q`, `plc.normalized-retry`, … | `edge-transformer-q`, `edge.plc-normalized-retry`, `edge-transformer-q-retry-30s`, `dlx.edge.plc-normalized`, `edge-transformer-q-failed` | legacy AMQP input topology (unused while disabled) |
| `RETRY_TTL_MS` / `MAX_RETRIES` / `PREFETCH` | 30000 / 5 / 50 | same | |
| `HEALTH_PORT` | 9102 | 9102 | |
| `CLIENT_YAML_PATH` | `/etc/packiot/client.yaml` | same (`docs/clients/cpack.yaml`) | tenant list, capabilities |
| `MQTT_ENABLED` | `false` | `true` | start the MQTT subscriber (the real input) |
| `MQTT_BROKER_URL` | `tcp://mosquitto:1883` | same | |
| `MQTT_CLIENT_ID` | `edge-transformer` | `edge-transformer-staging` | must be unique per broker |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | empty | empty | anonymous |
| `MQTT_STALE_THRESHOLD_SECONDS` | 60 | `-1` | ≤ 0 disables the "no data" degradation |
| `USE_GO_PORT` | `false` | `true` | run Calc; required for everything below |
| `CALC_CUTOVER_REFACTORED` | off | `true` | F3 envelope = Calc increments |
| `CALC_RESET_HEAL_ENABLED` | `true` | — | reseed on reset instead of emitting the whole totalizer |
| `CALC_NO_SPEED_GUARD_FALLBACK` | `false` | `true` | no glitch guard when there is no speed reference |
| `CALC_MONOTONICITY_GUARD` | `false` | — | drop out-of-order samples |
| `CALC_COUNTER_ROLLOVER` | `false` | — | per-equipment `CounterMax` wrap |
| `CALC_COUNTER_SPIKE_MARGIN` | 0 (off) | `10` | default spike-guard margin |
| `OEE_PROFILE_FROM_DB` / `OEE_PROFILE_REFRESH_SECONDS` | `false` / 300 | `true` / — | per-client margin + rated speed |
| `OEE_PROFILE_DSN` | unset | — | overrides the DSN built from `POSTGRES_*` |
| `COUNTERS_ONLY_OEE_ENABLED` | `false` | `true` | counters-only glitch bound |
| `COUNTERS_ONLY_IDEAL_RATES` | `{}` | 7 CPACK L6/L5 unit topics at 147 | JSON map unit topic → parts/min |
| `COUNTERS_ONLY_FROM_DB` / `COUNTERS_ONLY_REFRESH_SECONDS` / `COUNTERS_ONLY_DSN` | `false` / 300 / unset | — | load rated speeds from the DB |
| `PHASE9_LINE_AGG_ENABLED` | off | `true` | seed Parameter30700 + let line aggregates through |
| `POSTGRES_URL` | unset | analytics DB DSN (built from `.env` secrets) | used by the Parameter30700 seeder |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_HOST_UPSTREAM`, `POSTGRES_PORT`, `POSTGRES_DB` | – / – / – / – / 5432 / `packiot` | `POSTGRES_DB=packiot_analytics`, others from `.env` | DSN for the profile / rate watchers |
| `SHADOW_EMIT_REFACTORED` | off | `true` | emit `source_type=refactored` (F3) |
| `SHADOW_EMIT_PRODUCTION` | off | `false` | emit `source_type=""` (F1, retired) |
| `SHADOW_EMIT_GO` | on | `false` | emit `source_type=go` (F2, retired) |
| `F3_PER_TENANT_ROUTING` | off | `true` | routing key `sparkplug.data.<tenant>` |
| `OUTBOX_ENABLED` / `OUTBOX_PATH` / `OUTBOX_CAP` | `false` / `/var/lib/edge-transformer/outbox.db` / 100000 | `true` / same / 100000 | store-and-forward |
| `EMIT_LIVENESS_TIMEOUT_SECONDS` | 120 | — | `/healthz` fails when publishing but no confirms for this long |
| `LOCAL_DECODE_ONLY` | unset | — | on-prem box: decode to local state only, no AMQP |
| `LOCAL_STATE_DB` | unset | — | on-prem current-state SQLite sink (ADR-0053) |
| `LINE_TRACE_TENANTS` | empty | — (commented) | INFO-level per-counter drop trace for listed tenants |
| `ET_REQUEST_REBIRTH_ENABLED` / `…_MIN_INTERVAL_SECONDS` | `false` / 30 | — | send rebirth NCMD on seq gap / data before birth |
| `BIRTH_BOUND_ROUTING` | `false` | — | ADR-0046 birth-declared identity (off) |
| `BIRTH_BOUND_RESOLVER` | `map` | `refdata` | resolver used only when routing is on |
| `BIRTH_BOUND_DEVICE_MAP` | `{}` | — | device key → id_equipment for the `map` resolver |
| `REFDATA_URL` / `REFDATA_INTERNAL_KEY` | empty | `http://read-api:9104` / from `.env` | refdata resolver |
| `BIRTH_BOUND_ENTERPRISE_ID`, `…_RESOLVER_TTL_SECONDS`, `…_NEG_TTL_SECONDS` | 0, 600, 30 | — | |
| `EDGE_COMMANDS_ENABLED` | `false` | `false` | PLC write path |
| `EDGE_COMMANDS_ALLOWED` | `po_setup,param_write` | same | allowed verbs |
| `EDGE_COMMANDS_EXCHANGE`, `…_QUEUE_PREFIX`, `…_RETRY_EXCHANGE`, `…_FAILED_EXCHANGE`, `…_EDGE_NODE`, `…_DEDUP_CAP` | `edge.commands`, `edge-commands`, `edge.commands-retry`, `edge.commands-failed`, `plc-sim`, 4096 | — | |
| `ONBOARD_API_ENABLED` / `ONBOARD_API_PORT` / `ONBOARD_API_KEY` | off / 9105 / – | `true` / 9105 / from `.env` | onboarding bundle generator; refuses to start without the key |
| `ERP_SQL_TEMPLATE_DIR` | `/etc/packiot/tenant/sql` | — | ERP SQL templates |
| `EDGE_API_URL`, `EDGE_API_KEY`, `EDGE_API_ENTERPRISE_ID` | unset | — | enable the ERP PO upsert |
| `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_TRACES_SAMPLER_ARG` | unset / 1.0 | `http://tempo:4317` / `0.1` | tracing (10% head sampling) |

## Data & invariants

- **No delta from zero.** The first sample of each counter after a restart only seeds the
  baseline. A genuine reset only reseeds. This is why a decoder restart loses one sample per
  counter instead of minting a whole-totalizer spike (the 2026-08-11 bug: ~66% of CPACK new-prod
  production was fake, fingerprint `incr == val`).
- **State is per process.** Baselines live in memory (`NewMemState`). Only one decoder may consume a
  given Mosquitto namespace; a second instance would compute its own deltas and double-count.
- **Increments are never negative** and a spike is clamped, not dropped: the next reading
  differences normally from the stored absolute.
- **Tenant = Sparkplug group, lowercased.** Routing key and downstream tenant come from it.
- **Timestamps** are the metric's source (PLC) time when present, else the payload time.

## Observability

| Metric | Meaning |
|---|---|
| `edge_transformer_emitted_total{flow}` | envelopes enqueued per destination flow |
| `calc_evaluations_total{tenant,kind,outcome}` | Calc decisions (`send` / `drop`) |
| `calc_state_mutations_total`, `calc_state_seeds_total`, `calc_errors_total`, `calc_metrics_emitted_total` | Calc internals |
| `edge_transformer_sparkplug_seq_gaps_total{group_id,edge_node_id,device_id}` | missed Sparkplug sequence numbers |
| `edge_transformer_mqtt_connected`, `…_mqtt_received_total`, `…_mqtt_handled_total`, `…_mqtt_handle_errors_total`, `…_mqtt_reconnects_total` | MQTT subscriber state |
| `edge_transformer_mqtt_dropped_events_total{reason}` | ingest queue full |
| `outbox_depth`, `outbox_oldest_age_seconds` | outbox backlog |
| `edge_transformer_shadowpub_*` (published, confirmed, nacked, confirm timeouts) | RabbitMQ publisher |
| `edge_transformer_rebirth_requests_total`, `edge_transformer_onboard_generate_total`, `edge_transformer_commands_*` | optional features |

Log lines worth grepping: `sparkplug: data before birth`, `sparkplug: sequence gap`,
`phase9 line-agg: seeded Parameter30700`, `analyticspub: broker unreachable after startup retries`,
`outbox: publish failed`, `line-trace:` (with `LINE_TRACE_TENANTS`).

Alerts (`monitoring/prometheus/rules.yml`): `MQTTDisconnected`, `TransformerOutboxBacklog` (> 1000),
`TransformerOutboxStale` (> 900 s), `TransformerPublishNacked`, `TransformerMqttDrops`,
`SparkplugSeqGapStream`.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Spike-guard window bug (2026-09-23 → 09-27) | CPACK L6 net −40%, RMH −15% | Δt measured from the unit's speed timestamp | #1462 per-counter `___GUARD_TS`; repaired from silver values |
| Synthetic writers on real topics (to 2026-09-25) | L5 production ~6× legacy | twin injector and deploy inject fixture published on CPACK L5 topics; fixture also sent `Parameter30700="61"` | #1460 fixture uses group `E2EFIXTURE`; data repaired 2026-09-27 |
| Decoder up before RabbitMQ (2026-09-25) | healthy, publishing nothing | publisher init failed once | #1447 `NewWithRetry` then exit |
| ERP connector nil capabilities (2026-09-16) | shared decoder crash-loop | `clientCfg.Capabilities` nil for CPACK | #1327 nil guard |
| No-MachSpeed machines dropped (2026-08-13) | L8/L10/FLEXO/SLEEVE/CELULA counts vanish | `3 × MachSpeed = 0` bound after mirror-worker-go retired | `CALC_NO_SPEED_GUARD_FALLBACK=true` |
| Counter-role column collision (2026-08-26) | CPACK L5 phantom net | two features read `id_*counter` with different meanings | counter-role resolver removed |
| First-boot spike (2026-08-11) | `incr == val` rows, inflated OEE | baseline absent after reconnect | first-observation seed |
| Two writers for line counts (2026-07-14) | line OEE > 1 | Phase 9 line emission + downstream derivation | suppress `LineAggregated` unless `PHASE9_LINE_AGG_ENABLED` and no other writer |
| Recreate with debug logging | decode stalls, lines missing | restart drops alias tables and baselines | use `LINE_TRACE_TENANTS` instead of `LOG_LEVEL=debug` |

## Operating it

- **Deploy**: part of the staging deploy (`docker compose up -d`). A restart costs one sample per
  counter (seed) and needs births: agents that stay connected do not rebirth unless asked, so
  consider `ET_REQUEST_REBIRTH_ENABLED` before relying on restarts.
- **Health**: `docker exec sparkplug-decoder /usr/local/bin/sparkplug-decoder --healthcheck`, or
  `curl` port 9102 `/healthz` from inside the network.
- **Trace one tenant's lines**: set `LINE_TRACE_TENANTS: cpack` and redeploy normally.
- **Never** run two decoders against the same Mosquitto namespace, and never publish test
  fixtures under a real tenant group.
- **Onboarding a counters-only line**: add its unit topic to `COUNTERS_ONLY_IDEAL_RATES` (or turn on
  `COUNTERS_ONLY_FROM_DB` and mark the descriptor `counters_only_oee`); otherwise, with no
  `MachSpeed`, only the no-speed fallback lets its counts through.

## Tests

- `cd services/sparkplug-decoder && go test ./...` (also runs in CI: `.github/workflows/go-services.yml`, `go test -race`).
- Calc golden and focused tests: `internal/transforms/calc_production_counters/*_test.go`
  (`spike_guard_interval_test.go`, `counters_only_test.go`, `no_speed_guard_test.go`,
  `line_aggregation_test.go`, `silver_rules_test.go`), with fixtures in `testdata/`.
- Deploy smoke: the inject fixture and the outbox chaos test in `.github/workflows/deploy-staging.yml`.

## Source map

| Path | What's there |
|---|---|
| `services/sparkplug-decoder/cmd/edge-transformer/main.go` | wiring, MQTT handler, outbox drain, envelope build |
| `services/sparkplug-decoder/cmd/edge-transformer/line_param30700_seed.go` | Phase 9 Parameter30700 seed from `packml_register` |
| `services/sparkplug-decoder/internal/config/config.go` | env configuration |
| `services/sparkplug-decoder/internal/transforms/calc_production_counters/` | Calc port: `calc.go`, `decision_tree.go`, `counter_math.go`, `line_aggregation.go`, `state.go`, `source.js` |
| `services/sparkplug-decoder/internal/mqtt/` | subscriber, rebirth requester |
| `services/sparkplug-decoder/internal/sparkplug/` | protobuf decode, alias table |
| `services/sparkplug-decoder/internal/analyticspub/` | envelope + RabbitMQ publisher |
| `services/sparkplug-decoder/internal/outbox/` | SQLite store-and-forward |
| `services/sparkplug-decoder/internal/oeeprofile/`, `internal/countersrate/` | DB watchers |
| `services/sparkplug-decoder/internal/erpconnector/`, `internal/edgeapiclient/` | ERP read + PO upsert |
| `services/sparkplug-decoder/internal/command/` | DCMD command channel (off) |
| `services/sparkplug-decoder/internal/health/`, `internal/metrics/` | `/healthz`, Prometheus |
| `services/sparkplug-decoder/Dockerfile` | builds the decoder and the edge binaries |
| `docs/clients/cpack.yaml` | staging client descriptor mounted as `client.yaml` |
| `docs/adr/0010-sparkplug-decode-in-go-end-state.md`, `0011-…`, `0037-oee-correctness-remediation.md`, `0045-client-onboarding-architecture.md`, `0049-oee-correctness.md`, `0058-client-customization-capability.md` | design decisions |

`services/edge-transformer/` holds only a stray test file for a module path that no longer exists;
it is not part of the running system.
