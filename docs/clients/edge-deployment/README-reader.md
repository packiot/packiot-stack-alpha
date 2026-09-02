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
#   set TENANT_SLUG/TENANT_UPPER; leave READER_ENDPOINT empty to drive ALL
#   endpoints of each protocol (set it to pin ONE); fill the PLC host secrets —
#   per-endpoint PLC_HOST_<NAME> (multi-PLC) or the protocol-wide fallback
#   (S7_HOST | MODBUS_HOST | OPCUA_ENDPOINT_URL); and the CLIENT_CONFIG_FILE /
#   AGENT_CONFIG_FILE / AGENT_PROFILE_FILE paths.

# 1. Provision mTLS material into ./certs/ (gitignored), then FIX KEY PERMISSIONS.
#    The agent runs as NON-ROOT uid 65532; a 0600 root/1000-owned key is
#    unreadable to it → the agent crash-loops on the TLS load (CPACK bring-up bug):
sudo chown 65532:65532 ./certs/uplink-key.pem        # (or: sudo chmod 0644 …)

# 2. Validate the composition (must exit 0), then bring up the reader stack:
docker compose -f compose.edge.yml --env-file .env --profile reader config -q
docker compose -f compose.edge.yml --env-file .env --profile reader up -d
```

`--profile reader` selects `mosquitto + {s7,modbus,opcua}-reader + sparkplug-agent`
and leaves Node-RED down. (`COMPOSE_PROFILES=reader` in the env file makes it stick,
so a bare `docker compose … up -d` also picks the readers.) Each protocol reader
whose protocol has no endpoints in the client.yaml logs "nothing to drive" and
exits 0 — so the umbrella `reader` profile is correct for any protocol mix. To
start only the protocols you use, set e.g. `COMPOSE_PROFILES=reader-s7,reader-modbus`.

> **AGENT_TAGMAP_FROM_REGISTER must stay `false`** on a real edge — the
> register-driven tag map queries the cloud `packml_register`, which the factory
> edge cannot reach; turning it on crash-loops the agent (CPACK bring-up bug). The
> reader env sets it `false` explicitly.

### Multi-PLC, mixed-protocol clients (ADR-0045)

Each protocol reader drives **every** endpoint of its protocol in the client.yaml
— one poller + PLC connection per endpoint, all publishing to `edge/raw/<tenant>`.
So N endpoints of any protocol mix collapse to **≤3 reader services**, config-driven,
no per-endpoint service explosion. CPACK (9 S7 + 1 Modbus) = the `s7-reader` drives
the nine S7 cells + the `modbus-reader` drives the packer; the `opcua-reader` finds
nothing and self-retires.

Give each PLC its own host in `.env` via a per-endpoint override
`PLC_HOST_<NAME>` (NAME = the `plc.endpoints[].name`, upper-cased with
non-alphanumerics → `_`) — a generated bundle appends one blank line per driven
endpoint. An endpoint with no `PLC_HOST_<NAME>` falls back to the protocol-wide
`S7_HOST` / `MODBUS_HOST` / `OPCUA_ENDPOINT_URL` (the single-PLC convenience). The
agent composes per-equipment off the internal bus, so one equipment fed by an S7
counter + a Modbus speed just works once both readers emit.

---

## Verify

| Check | Command | Expected |
|---|---|---|
| Reader polling | `docker logs edge-<tenant>-s7-reader` (or `-modbus-reader`/`-opcua-reader`) | connects to each PLC + publishes to `edge/raw/<tenant>` each tick |
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
