# Reader-Path Edge Deploy (config-as-data Tier-1, no Node-RED)

The productized replacement for the Node-RED tee: a single **Go PLC reader**
(`s7` | `modbus` | `opcua`) is the SparkPlug-ignorant Tier-1 producer. It polls
ONE PLC endpoint and publishes RAW suffix tags to the internal mosquitto; the
shared `sparkplug-agent` consumes them, builds SparkPlug B, and uplinks over mTLS
to new-production — byte-identical to the tee path from the internal bus down.

```
 PLC ──s7/modbus/opcua──▶ reader (Tier-1)  emits RAW suffix tags
                            │  --raw-emit=true  → edge/raw/<tenant>/#  (internal MQTT)
                            ▼
                        sparkplug-agent (Tier-2)  alias-ASSIGN · NBIRTH/NDATA · outbox
                            ▼  spBv1.0/<tenant>/…  over mTLS (CN=<tenant>)
                  ════════ OT/IT WAN ════════▶  new-prod ingest broker
```

**Why the reader over the tee:** no Node-RED runtime, no low-code flow to import,
no HTTP ingest key on the wire — the whole connectivity plane is one config file
(`<tenant>-client.yaml`, `onboard-gen` artifact 5) + one `.env`. It IS the
ADR-0045 config-as-data Tier-1.

---

## Prerequisites

- The generated **`<tenant>-client.yaml`** (`onboard-gen` artifact 5 — emitted when
  the descriptor carries a `plc:` block). It declares `plc.endpoints[]` (each with a
  `name` + `host_ref`) and the per-protocol tag maps.
- The generated **`<tenant>-agent.yaml`** + **`<tenant>-profile.yaml`** (same as the tee path).
- The mTLS material (`uplink-cert.pem` / `uplink-key.pem` / `uplink-ca.pem`) from
  `gen-mtls-certs.sh` (same as the tee path).
- Network reachability from the edge host to the PLC endpoint.

---

## Deploy

```bash
cd docs/clients/edge-deployment
cp cpack.reader.env.example .env && $EDITOR .env
#   set TENANT_SLUG/TENANT_UPPER, READER_PROTOCOL (s7|modbus|opcua),
#   READER_ENDPOINT (= a plc.endpoints[].name in the client.yaml), the matching
#   PLC host secret (S7_HOST | MODBUS_HOST | OPCUA_ENDPOINT_URL), and the
#   CLIENT_CONFIG_FILE / AGENT_CONFIG_FILE / AGENT_PROFILE_FILE paths.

# 1. Provision mTLS material into ./certs/ (gitignored), then FIX KEY PERMISSIONS.
#    The agent runs as NON-ROOT uid 65532; a 0600 root/1000-owned key is
#    unreadable to it → the agent crash-loops on the TLS load (CPACK bring-up bug):
sudo chown 65532:65532 ./certs/uplink-key.pem        # (or: sudo chmod 0644 …)

# 2. Validate the composition (must exit 0), then bring up the reader stack:
docker compose -f compose.edge.yml --env-file .env --profile reader config -q
docker compose -f compose.edge.yml --env-file .env --profile reader up -d
```

`--profile reader` selects `mosquitto + reader + sparkplug-agent` and leaves
Node-RED down. (`COMPOSE_PROFILES=reader` in the env file makes it stick, so a bare
`docker compose … up -d` also picks the reader.)

> **AGENT_TAGMAP_FROM_REGISTER must stay `false`** on a real edge — the
> register-driven tag map queries the cloud `packml_register`, which the factory
> edge cannot reach; turning it on crash-loops the agent (CPACK bring-up bug). The
> reader env sets it `false` explicitly.

### Multi-PLC clients

One reader process = one PLC endpoint. For a client with N PLCs, duplicate the
`reader` service as `reader-<endpoint>` blocks (one per `plc.endpoints[]`, each with
its own `READER_ENDPOINT` + host env), or run
`docker compose --profile reader up -d --scale reader=N` with per-instance env. The
template ships the single-endpoint shape.

---

## Verify

| Check | Command | Expected |
|---|---|---|
| Reader polling | `docker logs edge-<tenant>-reader` | connects to the PLC + publishes to `edge/raw/<tenant>` each tick |
| Agent healthy | `curl -fsS <host>:${AGENT_HEALTH_PORT}/healthz` | `{"healthy":true}` — the raw-tag subscriber is fed off the internal bus, so it reports healthy once tags flow |
| Uplink connected | same JSON | `uplink_publisher.connected: true` |
| Tags flowing | `curl -s <host>:${AGENT_HEALTH_PORT}/metrics \| grep sparkplug_agent` | `raw_dropped_total{unmapped}` ≈ 0 |
| Cloud sees births | new-prod SparkPlug rules | NBIRTH observed; no seq-gap / IngestSilent alerts |
| Data in F3 | new-prod DB / Grafana | equipment counts land → OEE computes |

An ungraceful agent kill must produce a cloud-visible NDEATH (the Last-Will) —
verify the cloud registers the death→birth transition.

---

See **README.md** for the shared onboarding flow (describe → generate → capture →
validate → cutover), the mTLS design, and the new-production dependency notes. The
reader path swaps only the Tier-1 producer; everything from the internal bus down
is identical.
