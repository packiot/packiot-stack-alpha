# PROPOSAL — Node-RED MQTT tee (ADR-0032 Path B). Eventual replacement for the
# HTTPS `tee-node-setup.md`. Design reference; the real per-tenant version (with
# host + certs) is generated at provision time and kept LOCAL (never committed —
# it carries the client key).
#
# See docs/ingestion/mqtt-ingress-design.md §6.

## What changes vs the HTTPS shim tee

| | HTTPS shim (today) | MQTT direct (Path B) |
|---|---|---|
| Tee node | `http request` POST (JSON) | `mqtt out` (protobuf Buffer) |
| Auth | `X-Ingest-Key` header | mTLS client cert (CN = tenant) |
| Runs Go Calc downstream? | **No** | **Yes** — this is the whole point |
| Payload at the seam | SparkPlug-JSON | protobuf-encoded SparkPlug B **Buffer** |

## Where to tap
Tap where the payload is the **protobuf SparkPlug B buffer** — i.e. BEFORE any
JSON conversion (before the old `pubsub-out`/`PackML2SparkPlug`→JSON step). If
the flow only exposes the JSON object at the seam, either:
  (a) move the tee upstream to the SparkPlug DDATA/DBIRTH assembly (protobuf), or
  (b) insert a SparkPlug-encode function (Tahu / node-red-contrib-mqtt-sparkplug-plus,
      `proto.Marshal`), or
  (c) ask us to enable **variant B2** (JSON→Calc ingress on edge-transformer) and
      keep your existing JSON tee — no protobuf work on your side.

## mqtt out node
```
Broker:   mqtt-ingress.staging.packiot.com : 8883
TLS:      tls-config node →
            CA cert:     ca.crt
            Client cert: <tenant>.crt   (CN = CPACK | INCOPLAST)
            Client key:  <tenant>.key
            Verify server certificate: ON
Client ID: <tenant>-nodered-<edge>   (unique; clean session true)
Keepalive: 30    QoS: 0
Topic:     spBv1.0/<GROUP>/NDATA/<edgeNode>        (DDATA/<device> for sub-devices)
Payload:   the protobuf Buffer (msg.payload = Buffer, NOT a JSON string)
```

## Two must-dos
1. **NBIRTH first, retained.** Publish `spBv1.0/<GROUP>/NBIRTH/<edge>` with
   `retain=true` on connect and whenever the alias→name map changes. NDATA is
   alias-only; without the retained NBIRTH, edge-transformer's StateStore can't
   resolve aliases and the per-publisher sequence-gap counter climbs.
2. **Topic strings must match the seeded `packml_register`** for your tenant
   (the same rows that route the sim/shim today). A first-segment or shape
   mismatch drops the tenant routing (Incoplast hit exactly this before —
   register the collapsed key shape).

## Response / health
MQTT QoS 0 has no per-message ack; confirm success by watching, on our side,
the F3 tables populate + Calc metrics appear (`calc_*_total` in Prometheus). If
you need at-least-once, bump to QoS 1 (broker + edge-transformer tolerate it).
