# Deploy a CPACK edge Node-RED via GitHub Actions (Mode-B: agent + mTLS)

Goal: a **Node-RED at the CPACK factory, deployed by a GitHub Action**, that reads
the PLCs and sends the data to the new stack. It runs *alongside* CPACK's existing
Node-RED — nothing legacy is touched.

## How it works (Mode-B, ADR-0042 §6)

```
[ CPACK factory box ]                                   [ new-prod ]
  Node-RED ──reads──▶ PLCs                                mosquitto :8883 (mTLS)
     │  tee: POST http://localhost:9104/v1/tags               │  (CN=cpack verified)
     ▼                                                        ▼
  sparkplug-agent ── builds SparkPlug B, buffers (outbox) ──▶ │──▶ edge-transformer ──▶ F3
     └──────────── real SparkPlug B over mTLS ───────────────▶│    (already subscribed)
```

Node-RED stays SparkPlug-ignorant: it POSTs raw tags to the **local** agent; the
**Go agent** owns the SparkPlug B wire protocol and the mTLS uplink, and buffers to
a disk outbox so a WAN blip doesn't lose data.

## One-time setup

### 1. [factory] Edge box
Linux (amd64/arm64), Docker + Compose v2, reaches the CPACK PLCs + the internet.

### 2. [factory] Register it as the `cpack` runner  ← makes the Action land here
```bash
git clone https://github.com/packiot/packiot-stack-alpha.git
cd packiot-stack-alpha/docs/clients/edge-deployment
CLIENT=cpack GH_RUNNER_TOKEN=<token> ./register-runner.sh
```
`<token>` from repo → Settings → Actions → Runners → New self-hosted runner.

### 3. [me, GATED on your go] Provision mTLS certs — see PROVISIONING below
Generates the CA + server + `cpack` client cert, puts the server side on new-prod's
mosquitto, and hands you the three client files to drop on the edge box at
`./certs/` (`uplink-cert.pem`, `uplink-key.pem`, `uplink-ca.pem`).

### 4. [me, GATED] Open the firewall to this factory
Give me the box's **public egress IP** → I set `client_ingest_egress_cidrs =
["<ip>/32"]` in `terraform/production` and you approve `apply`. The `:8883` rule
already exists; it just needs your /32.

## Fire it
GitHub → Actions → **Client Edge Deploy** → `client=cpack, target=production,
confirm=cpack`. It checks the mTLS certs are present, brings up the stack, and
polls the agent `/healthz`.

## After firing
### 5. [factory] Wire the PLC-read flows
Open the new Node-RED (`http://<edge-box>:1880`, LAN/VPN-bound). Import your PLC
connectivity flows + `cpack/cpack-tee-node.json` (a *second wire* off the read).
The tee sends `{group,scan_ts,tags:[{metric,value}]}` to the local agent; `metric`
must match a `raw_tag_map` suffix in `cpack-agent.yaml`. Any mismatch shows up as
`sparkplug_agent_raw_dropped_total{reason="unmapped"}` — reject-don't-drop, so a
wrong name is visible, not silent.

### 6. [me] Verify
CPACK `equipment_values` freshening on new-prod F3 + OEE computing; agent
`/healthz` green; `sparkplug_agent_raw_dropped_total{reason="unmapped"}` ≈ 0.

---

# PROVISIONING (GATED — the cloud + secret steps, run with your go)

These are the steps I hold until you approve (prod writes + secrets + redeploy).

### P1. Generate the mTLS material (safe; local)
```bash
cd docs/clients/edge-deployment
TENANT=cpack SERVER_DNS=ec2-3-232-9-118.compute-1.amazonaws.com ./gen-mtls-certs.sh
# → ./mtls-out/{client-ca,server-cert,server-key,cpack-cert,cpack-key,ca-key}.pem
```
Server-cert SAN = the new-prod Elastic IP DNS (stable). The `ca-key.pem` never
leaves the vault — it only signs.

### P2. [SECRET] Store in AWS Secrets Manager
```
packiot/production/cpack-mtls/{cert,key,ca}   # cpack client cert/key + CA (agent refs)
packiot/production/mosquitto-server           # server-cert + server-key + client-ca
```

### P3. [PROD WRITE] Place the server side on new-prod's mosquitto
Put `server-cert.pem`, `server-key.pem`, `client-ca.pem` at
`/opt/packiot/mosquitto/certs/` on i-02d255a1c21fb1da3 (compose mounts it).
**Perms matter:** the eclipse-mosquitto container runs as uid 1883 — the key files
must be readable by it (e.g. `chmod 0644`, or chown to 1883). A `0600` root-owned
key makes mosquitto fail to start ("Unable to load server key file").

### P4. [PROD REDEPLOY] Roll new-prod so mosquitto binds :8883
Deploy the compose change (mosquitto.prod.conf + :8883 expose + certs mount).
Verify: `sudo ss -ltnp | grep 8883` shows the listener; `docker logs mosquitto`
shows "Opening ... listen socket on port 8883".

### P5. [factory] Place the client certs on the edge box
Copy `cpack-cert.pem`→`./certs/uplink-cert.pem`, `cpack-key.pem`→`uplink-key.pem`,
`client-ca.pem`→`uplink-ca.pem`. (The workflow guard fails closed without them.)

### P6. [PROD APPLY] terraform client /32 (needs your factory egress IP) — then fire.

## Durability (now included, unlike the shim path)
The agent's ADR-0011 store-and-forward outbox (SQLite/WAL named volume) buffers on
a WAN outage and replays FIFO on reconnect; idempotent at the cloud via
`equipment_values UNIQUE(ts_value,id_equipment)`. Right-size `OUTBOX_CAP` to CPACK's
real message rate and run the WAN-pull replay test on a staging dry-run before the
prod fire (README §durability).
