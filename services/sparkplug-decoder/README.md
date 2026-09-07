# edge-transformer

Per-factory Go service that consumes from a local RabbitMQ exchange
(`plc.normalized.<tenant>`), runs deterministic Go transforms previously
implemented as Node-RED subflows, and publishes transformed payloads onward.

**Status: ADR-0009 Phase 2 SKELETON — shadow mode.** The binary boots,
connects, declares per-tenant topology, runs N per-tenant consume
goroutines (one Channel per tenant, shared Connection), and dispatches
every delivery to a no-op handler that logs and acks. No transforms, no
DB, no outbound publishes.

See [`docs/README.md`](./docs/README.md) for the operator-facing intro and
[`ADR-0009`](../../docs/adr/0009-edge-transformer-go-service-and-nodered-split.md)
for the architectural context.

## Reuse rule (ADR-0009 Errata Correction 2)

Every architectural element in this service is lifted verbatim from
`services/oeecloud-worker/` or `services/mirror-worker-go/`. Pattern
drift between these services is the single biggest risk this rule
exists to prevent — see PR #56's silent-metric-coverage-gap for the
worst-case example.

If a future PR introduces a new pattern that "feels almost like" an
existing one, the burden of proof is on that PR's author to justify
why — not on the reviewer to spot the drift.

## Quick start (local)

```bash
# From the parent stack repo:
docker compose -f compose.staging.yml up -d edge-transformer  # Phase 2 — not yet wired

# Direct (laptop, no Docker — requires Go 1.24+):
cd services/edge-transformer
CREDS_SOURCE=env \
RABBITMQ_USER=guest RABBITMQ_PASSWORD=guest \
RABBITMQ_HOST=localhost RABBITMQ_PORT=5672 \
CLIENT_YAML_PATH=./docs/client.example.yaml \
go run ./cmd/edge-transformer
```

## Endpoints

| Path        | Port  | Purpose                                                    |
|-------------|-------|------------------------------------------------------------|
| `/healthz`  | 9102  | JSON snapshot, 200/503; called by Docker `HEALTHCHECK`     |
| `/health`   | 9102  | Alias for `/healthz` (parity with oeecloud-worker)         |
| `/metrics`  | 9102  | Prometheus scrape target                                   |

Port 9102 is deliberate — oeecloud-worker uses 9101, so the two services
can colocate on a single host without port collision.

## S7 read path (real Siemens PLCs) — `cmd/s7-reader`

`s7-reader` is the real-client counterpart to `plc-sim`: it reads a Siemens S7
PLC's data blocks (via `github.com/robinson/gos7`, a pure-Go, CGo-free S7comm
client) and republishes each configured tag as SparkPlug B over MQTT — so a real
S7 line looks to the rest of the stack exactly like `plc-sim` / a native
SparkPlug PLC. The `internal/s7` package (`decode.go` / `poller.go` / `client.go`
/ `mapping.go`) does the byte decoding + tag→PackML mapping (config-driven via
`client.yaml`'s `s7_tag_map`, ADR-0019 G4).

### Running the S7 end-to-end with the soft-PLC (no hardware)

Staging has no physical PLC, so `cmd/s7-softplc` provides a **pure-Go S7 server**
(`internal/s7/softplc`) that serves an in-memory data block over real S7comm.
`s7-reader` reads it exactly as it would a factory PLC. Both are gated behind the
`s7` compose profile (they never start in the default bring-up):

```bash
# Bring up the S7 E2E: soft-PLC (:102) + s7-reader → mosquitto → edge-transformer
docker compose -f compose.staging.yml --profile s7 up -d --build s7-softplc s7-reader

# The soft-PLC increments DB100 counters every tick, so downstream OEE sees
# live production. Watch s7-reader publish NBIRTH then NDATA:
docker compose -f compose.staging.yml logs -f s7-reader
```

The wire path itself is proven in CI (no hardware, no C, no build tags):
`internal/s7/softplc/softplc_test.go` drives the REAL gos7 client against the
soft-PLC over a live TCP socket and asserts the seeded bytes round-trip through
the poller. Run it directly:

```bash
cd services/edge-transformer && go test ./internal/s7/...
```

> The soft-PLC speaks just enough S7comm (TPKT / COTP CR→CC / S7 setup-comm +
> Read Var) to satisfy gos7's parser — see the protocol notes at the top of
> `internal/s7/softplc/softplc.go`. For a landed F1/F3 row the tag's topic must
> exist `active` in `packml_register` for the tenant; the E2E proves the
> PLC→SparkPlug mechanism, the routing is the same as any other producer.

## C1 command channel (operator → PLC write-back)

The inverse of ingest: a typed `Command` on AMQP `edge.commands.<tenant>` →
`internal/command` consumer → executor translates the verb to a SparkPlug
**DCMD** (`spBv1.0/<group>/DCMD/<edgeNode>`) → the PLC applies it. `plc-sim` is
the receiving end in staging: it subscribes to the DCMD topic and mutates its
state so the write is observable in its next NBIRTH/NDATA.

**The two ends are proven to agree in CI** (`cmd/plc-sim/main_test.go`,
`TestDCMD_ExecutorToSim_Contract`): the executor's *real* `BuildDCMD` output is
fed straight into the sim's *real* decode+apply path — no broker, no mocks — and
must land the intended write. This closes the seam where the executor emitted a
DCMD and the sim consumed one but the two were never tested TOGETHER.

Live end-to-end check against a running stack (pre-flip manual validation):

```bash
# 1. Watch the sim's output.
docker compose -f compose.staging.yml logs -f plc-sim   # look for "DCMD applied"

# 2. Publish a param_write command onto the tenant command exchange (RabbitMQ).
#    Verb param_write on MachSpeed; the sim overrides its reported speed.
docker exec rabbitmq sh -c 'rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASSWORD" \
  publish exchange=edge.commands routing_key=edge.commands.cpack \
  payload='"'"'{"tenant":"cpack","packmlTopic":"CPACK/SC/LINHAS/L5/BREYER","verb":"param_write","params":{"parameter":"Status/MachSpeed","value":87.5},"idempotencyKey":"manual-test-1"}'"'"''

# 3. Confirm: plc-sim logs "DCMD applied: MachSpeed override … value=87.5",
#    re-births, and its next NDATA reports MachSpeed=87.5 for L5/BREYER.
#    An ack lands on edge.commands.cpack.ack.
```

A rejected command (bad verb / missing param) is nacked to the DLX and acked
`rejected` — never a partial PLC write (the fail-safe rule in `internal/command`).
