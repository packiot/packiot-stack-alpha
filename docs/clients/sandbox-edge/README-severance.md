# SBXCPACK edge replica — severance design & post-deploy proof

A full-topology, real-image replica of the CPACK edge box that runs on the
staging sandbox VM (SSM `mi-0114b66366e2d6613`, tenant `sbxcpack`, ent `2000003`)
and is **provably unable to write to real CPACK**. Deploy with
`scripts/provision-cpack-replica-sandbox.sh`; topology in `compose.replica.yml`.

## Why five cuts

The data path is severed at five independent layers. The design rule: **remove
any one cut and the other four still stop the data.** A single cut (e.g. "just
point the uplink at localhost") is one config typo away from leaking.

The data path is cut by **L2–L5 + the namespace cut** — none of which depend on
the network layer. L1 (`internal: true`) was intentionally NOT used: it would
have blocked Docker from publishing :9103/:1880 to the host, breaking Box Ops
health + Connect, which is the whole reason the replica exists (a real box
publishes those ports too). Leaking to real CPACK would require deliberately
re-pointing the uplink AND swapping in the real client cert — not a single typo.

| # | Layer | Cut | Where |
|---|-------|-----|-------|
| L1 | Network | **Not used** — a normal bridge (host ports must publish for Box Ops parity). Severance does not rely on the network layer; see L2–L5. | `compose.replica.yml` networks |
| L2 | Uplink | agent `uplink_broker` = internal loopback mosquitto (Mode-A); the SparkPlug session terminates inside the box. Any `ssl://` fallback → `.invalid` blackhole. | `sbxcpack.descriptor.yaml` → generated `sbxcpack-agent.yaml` |
| L3 | Identity | mTLS cert `CN=sbxcpack`, signed by a **throwaway sandbox CA** — never the real Packiot Edge Uplink CA. The real broker ACL rejects it. | provision script phase 2 |
| L4 | PLC in | readers' PLC hosts = RFC-5737 TEST-NET-1 `192.0.2.x` (non-routable; L1 blackholes too) → no factory data is ever read. | `.env` / `compose.replica.yml` reader-base |
| L5 | No DB | `AGENT_TAGMAP_FROM_REGISTER=false`, no `AGENT_REGISTER_DSN` → the agent never dials the cloud `packml_register` DB. | `.env` / compose agent env |

Plus a **namespace cut**: the descriptor uses tenant `SBXCPACK` + prefix
`SBXCPACK/SC`, which matches **no row** in the real CPACK `packml_register`, so
even a leaked payload resolves to nothing cloud-side.

## Post-deploy verification checklist

Run each after `DEPLOY=1`. All must pass. Prefix `SSM` = run via
`aws ssm send-command … AWS-RunShellScript` (or SSM Session Manager) on `$MI`.

### 1. Topology parity (looks like a real box)
```bash
SSM: docker ps --format '{{.Names}} | {{.Status}} | {{.Ports}}'
```
Expect `edge-sbxcpack-{mosquitto,agent,nodered,s7-reader,modbus-reader,opcua-reader}`.
Agent `Up (healthy)`, ports `9103` (healthz) + `9104` (ingest), nodered `1880`.
```bash
SSM: curl -fsS localhost:9103/healthz    # → {"healthy":true}
```

### 2. L1 — network has no route off-box
```bash
# The bridge must be internal (no gateway).
SSM: docker network inspect packiot-edge-sbxcpack_edge-net -f '{{.Internal}}'   # → true
# From INSIDE the agent container, egress must fail (no route / DNS).
SSM: docker exec edge-sbxcpack-agent sh -c 'wget -T3 -q -O- https://1.1.1.1 || echo BLOCKED'   # → BLOCKED
```
If the agent image is distroless (no shell), assert via the network flag alone
plus L2 below; the `internal:true` flag is the load-bearing guarantee.

### 3. L2 — uplink stays on the box
```bash
SSM: grep uplink_broker /opt/packiot/sbxcpack-replica/sbxcpack/sbxcpack-agent.yaml
#    → uplink_broker: tcp://mosquitto:1883   (NOT ssl://ingest.* )
SSM: docker logs edge-sbxcpack-agent 2>&1 | grep -iE 'uplink|connect' | tail
#    → connects to the loopback broker; NO ingest.prod / ingest.staging host.
# Belt-and-suspenders: no established connection to :8883 anywhere.
SSM: ss -tanp | grep ':8883' || echo "no 8883 connections"   # → no 8883 connections
```

### 4. L3 — identity is the sandbox CN, not the real client
```bash
SSM: openssl x509 -in /opt/packiot/sbxcpack-replica/certs/uplink-cert.pem -noout -subject -issuer
#    subject CN=sbxcpack ; issuer O=Packiot-SANDBOX "... DO NOT TRUST"
#    MUST NOT be CN=cpack, MUST NOT be issued by the real "Packiot Edge Uplink CA".
```

### 5. L4 — no PLC is dialed
```bash
SSM: docker logs edge-sbxcpack-s7-reader 2>&1 | tail
#    → dials 192.0.2.x (TEST-NET) and times out / self-retires (exit 0). No real PLC IP.
SSM: ss -tanp | grep -E ':102|:502|:4840' || echo "no PLC ports"   # → no PLC ports (or only to 192.0.2.x, which L1 blackholes)
```

### 6. L5 — no cloud DB dial
```bash
SSM: docker exec edge-sbxcpack-agent env | grep -E 'AGENT_TAGMAP_FROM_REGISTER|AGENT_REGISTER_DSN' || true
#    → AGENT_TAGMAP_FROM_REGISTER=false ; AGENT_REGISTER_DSN unset
SSM: docker logs edge-sbxcpack-agent 2>&1 | grep -i 'register' | grep -iv 'raw_tag' | tail
#    → no "dialing packml_register" / DB connection attempts.
```

### 7. Real-CPACK queue is untouched (cloud-side proof)
From a box with RabbitMQ admin (see memory `project_csadmin_onboarding_rabbitmq_provisioning`):
```bash
# Bind a temp queue to the cpack routing key and confirm ZERO messages arrive
# from the sandbox over an observation window; q-cpack depth/rate unchanged.
rabbitmqadmin list queues name messages | grep -i cpack
```
No new `cpack` traffic should appear that correlates with the sandbox being up.
Conversely, there is **no** `sbxcpack` producer on the cloud broker at all — the
uplink never leaves the box.

## If an image can't reach the box

The Node-RED and agent/reader images are built on the operator's host and shipped
as S3-presigned tars (`docker load` on the box) — see the acquisition plan in the
provision script header. If, and only if, the agent/reader image genuinely cannot
be built or transferred (e.g. an arm64 box with no cross-build), keep **that one**
container as the public-image mock from `scripts/provision-sandbox-edge-box.sh`
and make the rest real — never silently fake the agent, since it is the component
whose severance we are proving. Say so explicitly in the deploy notes.
