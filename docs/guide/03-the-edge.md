# 3 — The Edge

The edge is everything that runs *inside the factory*: the machine, its controller,
and the on-site software that gets the machine's data ready to leave the building.
This chapter follows a single machine signal from the metal to the message bus.

## What the machine emits

A machine's PLC (Programmable Logic Controller) doesn't speak business. It exposes
raw values: a production counter that ticks up, a current speed, a state code
(running / stopped / changeover), a fault flag. These are published using
**SparkPlug B** — an industrial standard that rides on **MQTT** and encodes payloads
as Protocol Buffers, with a stateful session model (birth certificates, sequence
numbers, aliases) designed for unreliable factory networks.

The job of the edge is to turn this raw, protocol-specific, per-machine stream into
a clean, normalized message the cloud can process — reliably, even when the factory
internet drops.

## The split: minimal Node-RED + the Go transformer

Historically, one big Node-RED flow did *everything* at the edge: talk to the PLC,
decode SparkPlug, do calculations, buffer, and ship to the cloud — and it was
forked per customer until no two factories ran the same code. The rebuild splits
this into two pieces with a clean responsibility boundary.

### edge Node-RED — deliberately minimal

Node-RED survives at the edge, but shrunk to two jobs:

1. **Connect to the PLC and set up its messages** — the protocol-touching,
   site-specific wiring that genuinely benefits from a visual, non-developer-editable
   tool.
2. **Provide a space for customization** — a governed place where a customer's
   (possibly non-developer) integration team can add client-specific logic:
   special calculations, a local screen, an ERP hook.

Everything *else* — decoding, normalization, durability, the standard pipeline —
was pulled out of Node-RED and into a purpose-built Go service. Why keep Node-RED
at all rather than go "all Go"? Because real factories genuinely need a
customization surface, and forcing every one-off through a compiled service would
be worse than the disease. [Chapter 7](07-customizations-and-real-factories.md) is
entirely about what belongs here and what doesn't — told through a real factory
that pushed this boundary to its limit.

> **Decision:** the Node-RED / transformer split, and why Node-RED is not killed
> outright, is [ADR-0009](../adr/0009-edge-transformer-go-service-and-nodered-split.md).
> The "all-Go, kill Node-RED" option was considered and explicitly rejected.

### edge-transformer — the Go pipeline

The `edge-transformer` (in `services/edge-transformer/`) is the workhorse. As of
the "10.9 cutover," it subscribes to the machine's MQTT/SparkPlug stream **directly**
— it is *the* ingest, not a downstream of Node-RED — and runs a four-stage pipeline.

**Stage 1 — Decode.** Raw bytes become a typed payload. The whole of SparkPlug's
protobuf complexity collapses to one honest function:

```go
// internal/sparkplug/decoder.go
func Decode(body []byte) (*Payload, error) {
    var p Payload
    if err := proto.Unmarshal(body, &p); err != nil {
        return nil, fmt.Errorf("sparkplug: decode payload (%d bytes): %w", len(body), err)
    }
    return &p, nil
}
```

**Stage 2 — Normalize.** SparkPlug metrics arrive keyed by topic and numeric
aliases; the normalizer resolves them to a stable equipment identity and a
canonical metric shape, so downstream code never has to know about aliases or topic
grammar.

**Stage 3 — Calculate.** Some values a machine reports as raw counters must become
deltas and rates (the "counter calc"). This is the same arithmetic the old system
did — ported to Go with the same fidelity discipline as the OEE math in
[Chapter 4](04-the-engine.md).

**Stage 4 — Publish, durably.** The result is published to RabbitMQ with **publisher
confirms** (the broker must acknowledge each message), and a **SQLite outbox** sits
in front of the publish so nothing is lost if the broker or network is down. This
is the durability boundary: once a message is in the outbox, it *will* reach the
bus, retried until confirmed.

> **Decision:** the store-and-forward outbox and where the durability boundary sits
> is [ADR-0011](../adr/0011-durability-boundary-and-store-and-forward.md). Decoding
> SparkPlug in Go rather than Node-RED is [ADR-0010](../adr/0010-sparkplug-decode-in-go-end-state.md).

The failure model is worth stating plainly, because it is the transformer's whole
reason to exist: **never lose a message.** Decode, buffer to disk, publish with
acknowledgment, retry forever. Contrast this with the engine in the next chapter,
whose obsession is not durability but *fidelity* — the same language, opposite
disciplines.

## The triple-emit

Recall [the three flows](02-architecture-at-a-glance.md#idea-2--the-three-flows).
This is where they are born. For each machine event, the transformer emits the same
normalized message multiple times, each stamped with a different `source_type` in
its envelope — `"go"` for the shadow schema, `"refactored"` for the refactored
database, `""` for the legacy path. One decode, several destinations, so the
migration can prove the new path matches the old on identical input.

## Configuring a factory: `client.yaml`

Every factory is different — different PLCs, different equipment, different
customer. The rebuild's answer to "how do we onboard a factory without forking
code" is a single, standardized, per-tenant configuration file: **`client.yaml`**,
mounted into the transformer and parsed at boot.

```yaml
# clients/cpack/client.yaml — mounted at /etc/packiot/client.yaml
tenant_id:    cpack                 # drives per-tenant queues + Prometheus labels
customer:     "C-Pack Solutions"
environment:  staging
equipments: []                      # populated from packml_register exports
```

Today the loader honors a **skeleton** (`tenant_id`, `customer`, `environment`,
`equipments`); the full v1.0 schema — PLC endpoints, equipment mapping, shifts,
integrations, customization declarations — is documented in
[`clients/_schema.yaml`](../clients/_schema.yaml) and is the target the loader
grows into. The principle is the important part: **onboarding a factory should be
writing a config file, not writing code.** [Chapter 7](07-customizations-and-real-factories.md)
tests that principle against a factory whose real config needs went well beyond
today's schema — and turns the gaps into requirements.

One subtlety that has already bitten us and is worth internalizing: the `tenant_id`
is not cosmetic. It names the RabbitMQ queues and the Prometheus metric labels, so
a mismatch between what the transformer publishes under and what the worker
consumes under is a *silent* coverage gap — messages vanish with no error. Naming
is a contract here, enforced on both sides.

---

Next: [The Engine](04-the-engine.md) — how raw messages become OEE, and how Go code
reproduces a database exactly.
