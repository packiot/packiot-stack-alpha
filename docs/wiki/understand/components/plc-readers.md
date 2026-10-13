---
title: PLC readers (s7, modbus, opcua)
layer: 3
owner_area: edge
last_verified: 2026-09-28
---
# PLC readers (s7, modbus, opcua)

> **Layer 3 · Components** — the three Go binaries that poll factory PLCs and emit named
> readings for the sparkplug-agent. For engineers writing a `client.yaml` tag map or debugging
> "the reader is up but no values arrive".
> Up: [Edge subsystem](../subsystems/edge.md)

## Responsibility

Each reader is accountable for one thing: **read the configured addresses from every PLC
endpoint of its protocol, convert each raw value into a number, and publish it under its
canonical metric suffix**. The readers know nothing about SparkPlug in their default mode
(ADR-0042 "Option A"): no aliases, no sequence numbers, no births. The
[sparkplug-agent](sparkplug-agent.md) owns all of that.

!!! note "Which reader actually runs on client boxes today"
    The Go readers ship in the edge bundle (`docs/clients/edge-deployment/compose.edge.yml`,
    profile `reader`). The **edge-api "Go-live" deploy** instead pushes a *generated Python
    reader* (`packiot-edge-reader`) that POSTs over HTTPS, because the Go readers cannot POST
    to the HTTP front-door (comment in `edge-api/src/usecases/edge-ssm/shared/reader-bundle.ts`).
    That reader is described in [edge-box](edge-box.md#the-thin-reader-packiot-edge-reader).
    On staging, `s7-reader` only runs under compose profile `s7` against the soft-PLC.

## At a glance

| | s7-reader | modbus-reader | opcua-reader |
|---|---|---|---|
| Language | Go 1.25, `CGO_ENABLED=0` | same | same |
| Source | `services/sparkplug-decoder/cmd/s7-reader` | `.../cmd/modbus-reader` | `.../cmd/opcua-reader` |
| Protocol library | `gos7` (pure Go) | `goburrow/modbus` (pure Go) | `gopcua/opcua` (pure Go) |
| Image | `packiot-sparkplug-decoder` (main `Dockerfile`, binary `/usr/local/bin/<name>`) | same | same |
| PLC port | ISO-on-TCP :102 | :502 | `opc.tcp://host:port/path` |
| Config file | `client.yaml` → `s7_tag_map` | `modbus_tag_map` | `opcua_tag_map` |
| Output (default) | MQTT `edge/raw/<tenant>` | same | same |
| Depends on | an MQTT broker (the box mosquitto) | same | same |
| Depended on by | sparkplug-agent (single-file mode, MQTT raw subscriber) | same | same |

Staging (`compose.staging.yml`, profile `s7`): `s7-reader` at 172.18.0.34, reading
`s7-softplc:102` (172.18.0.33), `mem_limit: 64m`. No Modbus/OPC-UA reader runs on staging.
Production (`compose.production.yml`) excludes all readers.

## Inputs & outputs

**Input:** PLC memory, addressed per tag:

| Protocol | Address fields | Read granularity per tick |
|---|---|---|
| S7 | `db`, `offset` (byte), `bit` (0–7, bool only), `type` ∈ `int\|dint\|real\|bool` | One `AGReadDB(db, 0, maxEnd)` per data block — from byte 0 to the furthest tag end |
| Modbus | `kind` ∈ `holding\|input\|coil\|discrete`, `address` (0-based), `quantity`, `type` ∈ `uint16\|int16\|uint32\|int32\|float32\|bool`, `word_swap` | One request per kind, spanning min→max address |
| OPC-UA | `node_id` (e.g. `ns=2;s=Machine.Speed`), `type` ∈ `int\|float\|bool\|string` | One batched `Read` of all node Values |

**Output (raw-emit, default):** one MQTT publish per endpoint per tick, QoS 0, not retained,
to `edge/raw/<tenant>` where `<tenant>` = `--tenant` or lower-cased `--group`. Body:

```json
{"endpoint":"CELULA1","scan_ts":1727500000000,
 "tags":[{"metric":"/CELULA1/CER400/Admin/ProdProcessedCount/1/Unit","value":1234},
         {"metric":"/CELULA1/CER400/Status/StateCurrent","value":6,"long":true}]}
```

`metric` is the **suffix**: `packml_topic + tag.metric` with the file's `canonical_prefix`
stripped (`internal/rawemit/rawemit.go` `toOutTags`). The agent resolves by exact suffix, so
this strip is load-bearing (ADR-0045 §C).

**Output (legacy, `--raw-emit=false`):** direct SparkPlug B on the same broker —
retained NBIRTH `spBv1.0/<group>/NBIRTH/<edge-node>` (QoS 0) with the full name↔alias table
at connect, then alias-only NDATA `spBv1.0/<group>/NDATA/<edge-node>` every tick. Single
endpoint only; the endpoint must be pinned with `--endpoint` for Modbus/OPC-UA.

## Internal design

```text
 client.yaml ─► <proto>.Endpoints(cfg)      distinct endpoint names in <proto>_tag_map
            ─► <proto>.TagsForEndpoint()    Tag{Metric=packml_topic+metric, Alias 1..N, addr}
            ─► <proto>.NewPoller(tags)      validates: non-empty name, unique non-zero alias
            ─► <proto>.NewClient(host,...)  lazy dial, mutex-serialised, redial on error
 rawemit.Run(endpoints) ── one goroutine per endpoint, ONE shared paho MQTT client
     every tick: Sample(birth=true) → toOutTags(strip canonical_prefix) → rawtag.Encode
                 → Publish(edge/raw/<tenant>, qos 0)
```

- **Multi-PLC.** One process drives every endpoint of its protocol found in `client.yaml`
  (ADR-0045). CPACK-shaped configs mix nine S7 cells and one Modbus device; the S7 reader
  takes the S7 ones, the Modbus reader the Modbus one (`internal/rawemit/rawemit_test.go`
  `TestMixedProtocolMetricSuffix`).
- **Host resolution** (`rawemit.HostForEndpoint`): env `PLC_HOST_<NAME>` wins, where `<NAME>`
  is the endpoint name upper-cased with every non-`[A-Z0-9]` character turned into `_`
  (`CELL-1` → `PLC_HOST_CELL_1`). Otherwise the protocol-wide fallback is used. An endpoint
  with no host is skipped with a warning; if *all* are skipped the reader exits 1.
- **Nothing to drive.** A reader whose protocol has no endpoints in `client.yaml` (or whose
  pinned `--endpoint` is another protocol's) logs "nothing to drive" and **exits 0**. The
  edge bundle therefore uses `restart: on-failure`, so the umbrella `reader` profile is safe
  for any protocol mix.
- **Failure isolation.** A read error on one endpoint logs `PLC read failed — skipping tick`
  and only that endpoint misses the tick. The client drops its connection and redials on the
  next tick. There is no reader-side buffering: a skipped tick is simply not sent.
- **Logging.** JSON (`slog`), `service=<reader>`. "raw envelope published" is logged on the
  first publish and whenever the tag count changes, not every tick.

### Value decoding

| Protocol | Rule | Source |
|---|---|---|
| S7 | Big-endian. `int` = int16 (2 B), `dint` = int32 (4 B), `real` = IEEE-754 float32 (4 B), `bool` = bit `bit` of byte `offset`, LSB-first (bit 0 = `0x01`) | `internal/s7/decode.go` |
| Modbus | Registers are big-endian 16-bit (fixed by the protocol). For 32-bit types, `word_swap: false` = ABCD (first register is the high word), `true` = CDAB (first register is the low word). Coils/discrete inputs are packed bits, LSB-first | `internal/modbus/decode.go` |
| OPC-UA | Server Variant coerced to float64; `bool` → 0/1; `string` parsed as a number (for servers exposing numbers as strings); a nil / bad-status value fails the whole sample | `internal/opcua/poller.go` |

Then for every protocol: `value = raw × scale` (`scale: 0` means 1); `long: true` emits an
integer (SparkPlug Long; use it for `StateCurrent`), otherwise a Double.

!!! tip "`word_swap` is a per-device fact"
    The Modbus spec does not define the word order of 32-bit values. Take it from the vendor's
    register map, or read a known counter both ways and pick the one that increments sanely.
    A wrong `word_swap` on a counter looks like huge jumps every time the low word rolls over.

### Where TRIG lives

The `***TRIG_CS`, `***TRIG_CI`, `***TRIG_C=I`, `***TRIG_C=O`, `***TRIG_CO` and
`***STATESPEED_THIS` topic suffixes are **not** handled by the readers. They are parsed by
the cloud counter state machine (`internal/transforms/calc_production_counters/decision_tree.go`
`parseTriggerFlags`) — see [sparkplug-decoder](sparkplug-decoder.md). A reader only needs to
emit the suffix the tenant's `raw_tag_map` expects.

## Configuration

All flags have an env fallback; the flag wins when both are given.

**s7-reader** (`cmd/s7-reader/main.go`)

| Env | Flag | Default | Effect |
|---|---|---|---|
| `MQTT_BROKER_URL` | `--broker` | `tcp://mosquitto:1883` | Broker for raw envelopes or legacy SparkPlug |
| `S7_GROUP` | `--group` | `INCOPLAST` | SparkPlug group (legacy) and default tenant |
| `TENANT` | `--tenant` | lower-cased group | Topic `edge/raw/<tenant>` |
| `S7_EDGE_NODE` | `--edge-node` | `s7-reader` | Edge node id (legacy mode only) |
| `S7_HOST` | `--s7-host` | *(empty)* | Fallback PLC host; required for the demo path and legacy mode |
| `S7_RACK` / `S7_SLOT` | `--s7-rack` / `--s7-slot` | `0` / `2` | Defaults; per-endpoint `rack`/`slot` in `client.yaml` override |
| `S7_TICK_SEC` | `--tick` | `5` | Seconds between reads; also the per-request timeout |
| `S7_DB` | `--db` | `100` | Data block for the built-in demo tags |
| `CLIENT_CONFIG` | `--client-config` | *(empty)* | Empty ⇒ four hard-coded demo tags (Incoplast NOVOFLEX_15, DB100 offsets 0/4/8/12) |
| `S7_ENDPOINT` | `--endpoint` | *(empty = all)* | Pin one endpoint |
| `RAW_EMIT` | `--raw-emit` | `true` | `false` ⇒ legacy SparkPlug |
| `PLC_HOST_<NAME>` | — | — | Per-endpoint host |

**modbus-reader** — same shape; `--client-config` is **required** (no demo tags).

| Env | Default | Effect |
|---|---|---|
| `MODBUS_HOST` | *(empty)* | Fallback `host:port` |
| `MODBUS_UNIT_ID` | `1` | Unit/slave id fallback; endpoint `unit_id` overrides |
| `MODBUS_TICK_SEC` | `5` | Poll interval and timeout |
| `MODBUS_GROUP` / `MODBUS_EDGE_NODE` / `MODBUS_ENDPOINT` | `INCOPLAST` / `modbus-reader` / all | As for S7 |

**opcua-reader** — same shape; `--client-config` is **required**.

| Env | Default | Effect |
|---|---|---|
| `OPCUA_ENDPOINT_URL` | *(empty)* | Fallback server URL |
| `OPCUA_TICK_SEC` | `5` | Poll interval and timeout |
| `OPCUA_GROUP` / `OPCUA_EDGE_NODE` / `OPCUA_ENDPOINT` | `INCOPLAST` / `opcua-reader` / all | As for S7 |
| endpoint `security_policy` / `security_mode` | `None` / `None` | Anonymous auth; Sign/SignAndEncrypt certificates are not provisioned yet |

A best-effort connect is attempted at boot for OPC-UA so a bad URL shows up in the first log
lines; it is not fatal.

### `client.yaml` shape (tag-map part)

```yaml
canonical_prefix: CPACK/SC
plc:
  endpoints:
    - {name: CELULA1, host_ref: "secret://cpack/plc/celula1", rack: 0, slot: 2}
    - {name: CELULA2, host_ref: "secret://cpack/plc/celula2", unit_id: 1}
s7_tag_map:
  - endpoint: CELULA1
    packml_topic: CPACK/SC/CELULA1/CER400
    id_equipment: 83
    tags:
      - {metric: /Admin/ProdProcessedCount/1/Unit, db: 100, offset: 0, type: dint}
      - {metric: /Status/MachSpeed,               db: 100, offset: 8, type: real}
modbus_tag_map:
  - endpoint: CELULA2
    packml_topic: CPACK/SC/CELULA2/PACKER
    id_equipment: 84
    tags:
      - {metric: /Admin/ProdProcessedCount/1/Unit, kind: holding, address: 0, type: uint32}
```

(Shape taken from the unit-test fixture `internal/rawemit/rawemit_test.go`; `host_ref` values
are secret references, the real IPs go in `PLC_HOST_*`.) The file is generated by
`onboard-gen` as `<tenant>-client.yaml` from the client descriptor's `plc:` block — do not
hand-edit it.

## Data & invariants

- **Alias stability** (legacy mode): aliases are 1..N in config order, stable within one
  boot. Reordering `client.yaml` changes them, which is safe only because a new NBIRTH is
  published on connect.
- **Legacy mode re-births after a failed read.** A read error sets `birthed=false`; the next
  successful tick publishes NBIRTH instead of NDATA, because the decoder drops DATA seen
  before a BIRTH.
- **Raw mode is stateless.** Every envelope is name-addressed; the agent can restart at any
  time without coordination.
- **No invented values.** A decode that runs past the buffer (DB too short for the offset,
  Modbus span too short) fails the whole endpoint sample rather than emitting zeros.

## Observability

- No metrics endpoint and no health port: the readers are observed through the agent
  (`raw_tag_subscriber` component on `/healthz`: "no raw tags received in …", and
  `sparkplug_agent_unmapped_tags_total`).
- Log lines worth grepping: `endpoint compiled` (boot, one per endpoint, `tags=` count),
  `PLC read failed — skipping tick`, `nothing to drive`, `no host for S7 endpoint`,
  `initial OPC-UA connect failed`.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Reader exits 0 immediately | Container `Exited (0)` | Its protocol has no endpoints in `client.yaml`, or `READER_ENDPOINT` names another protocol's endpoint | Expected; use the per-protocol profile |
| Reader exits 1 at boot | "none had a host" | No `PLC_HOST_<NAME>` and no protocol fallback | Fill `.env` with the per-endpoint hosts |
| Values arrive but agent maps 0 | `accepted:0`, unmapped counter climbs | Suffix mismatch between `client.yaml` (`canonical_prefix`/`packml_topic`) and the agent `raw_tag_map` | Regenerate reader + agent config as a pair from the same descriptor (CPACK, 2026-08-18: reader emitted `/L5/...`, generated agent expected `/LINHAS/L5/...`) |
| Counter jumps by ~65,536 multiples | Huge increments at low-word rollover | Wrong `word_swap` | Flip `word_swap` for that tag |
| Modbus read error every tick | `modbus read holding[...]` exception | Span from min to max address too wide for one request (Modbus limits a register read to 125 registers) or includes unmapped addresses the device rejects | Keep one kind's addresses clustered or split across endpoints |
| S7 PLC becomes unresponsive | Reads time out for several PLCs | Too many concurrent S7 clients on a fragile CPU (CPACK box ran both the legacy reader and the new reader against the same S7s, noted 2026-09-07) | Run one reader per PLC; stagger ticks |
| Staging `s7` profile shows no data downstream | No SparkPlug from `s7-reader` | Staging compose does not set `RAW_EMIT`, so it defaults to raw-emit and publishes to `edge/raw/incoplast`, which no staging agent subscribes to | Set `RAW_EMIT=false` on the staging service, or run an agent subscribed to that topic |

!!! warning "Unverified"
    The staging `s7` profile finding above is derived from the code and compose file
    (`compose.staging.yml` comments still describe the reader as publishing NBIRTH/NDATA). It
    has not been re-run live.

## Operating it

- **Start on a box (bundle):**
  `docker compose -f compose.edge.yml --env-file .env --profile reader up -d`
  (or `reader-s7` / `reader-modbus` / `reader-opcua`).
- **Probe a PLC without deploying:** edge-api's plc-probe slice
  (`edge-api/src/usecases/plc-status/plc-probe/`) calls `EdgeSsmService.probePlc`, which runs a
  one-shot TCP reachability check of `host:port` on the box through SSM RunCommand.
- **Staging S7 end-to-end:** `docker compose -f compose.staging.yml --profile s7 up -d
  s7-softplc s7-reader`.
- **Safe:** restarting a reader (stateless). **Unsafe:** pointing a second reader at the same
  S7 PLC as the client's existing reader without checking the PLC's connection budget.

## Tests

```bash
cd services/sparkplug-decoder
go test ./internal/s7/... ./internal/modbus/... ./internal/opcua/... ./internal/rawemit/...
```

- `internal/s7/s7_test.go`, `internal/modbus/modbus_test.go`, `internal/opcua/opcua_test.go`:
  decoders against known byte buffers / fake read functions.
- `internal/s7/softplc`: wire-level S7comm test against the pure-Go soft-PLC.
- `internal/*/mapping_test.go`: `client.yaml` → tag compilation.
- `internal/rawemit/rawemit_test.go`: mixed-protocol, canonical-prefix strip contract.

## Source map

| Path | What's there |
|---|---|
| `services/sparkplug-decoder/cmd/s7-reader/main.go` | S7 flags, demo tags, raw-emit and legacy loops |
| `services/sparkplug-decoder/cmd/modbus-reader/main.go` | Modbus reader main |
| `services/sparkplug-decoder/cmd/opcua-reader/main.go` | OPC-UA reader main |
| `services/sparkplug-decoder/internal/rawemit/rawemit.go` | Multi-endpoint loop, `PLC_HOST_<NAME>`, suffix strip |
| `services/sparkplug-decoder/internal/agent/rawtag/` | Raw-tag envelope encode/decode (the wire contract) |
| `services/sparkplug-decoder/internal/s7/` | gos7 client, big-endian decoders, poller, mapping |
| `services/sparkplug-decoder/internal/modbus/` | goburrow client, word-order decoders, read plan |
| `services/sparkplug-decoder/internal/opcua/` | gopcua client, Variant coercion |
| `services/sparkplug-decoder/internal/clientconfig/loader.go` | `client.yaml` schema |
| `services/sparkplug-decoder/Dockerfile` | Builds all reader binaries into one image |
| `docs/clients/edge-deployment/compose.edge.yml` | `x-reader-base`, reader services and profiles |
| `compose.staging.yml` (`s7-softplc`, `s7-reader`) | Staging S7 end-to-end profile |
