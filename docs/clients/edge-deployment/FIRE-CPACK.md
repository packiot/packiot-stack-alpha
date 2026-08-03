# Deploy a CPACK edge Node-RED via GitHub Actions — the short runbook

Goal: a **Node-RED instance at the CPACK factory, deployed by a GitHub Action,
that forwards PLC data to the new stack (new-prod)**. It runs *alongside* CPACK's
existing Node-RED — nothing legacy is touched.

## How it works (one paragraph)
The `Client Edge Deploy` workflow runs on a **self-hosted GitHub runner that lives
on a box at the factory** (`runs-on: [self-hosted, cpack]`). When fired, it brings
up `compose.edge.yml` on that box — a Node-RED (+ a mosquitto + a sparkplug-agent).
The Node-RED reads the PLCs and **POSTs SparkPlug-JSON over HTTPS to new-prod's
ingest-shim (`:8444`)**, which routes it through RabbitMQ → the OEE engine → F3.
So "deployed by GitHub Actions" works *because* the factory box is a runner.

## The steps (first time)

### 1. [factory] Provide the edge box
A Linux host at CPACK with **Docker + Compose v2**, that can (a) reach the CPACK
PLCs on the factory LAN and (b) reach the internet (GitHub + new-prod). amd64 or arm64.

### 2. [factory] Register it as the `cpack` runner  ← the real prerequisite
On that box, once:
```bash
git clone https://github.com/packiot/packiot-stack-alpha.git
cd packiot-stack-alpha/docs/clients/edge-deployment
CLIENT=cpack GH_RUNNER_TOKEN=<token> ./register-runner.sh
```
Get `<token>` from **repo → Settings → Actions → Runners → New self-hosted runner**
(copy the registration token), or pass `GH_PAT=<pat>` instead (PAT is in Secrets
Manager `packiot/production/github-runner`). Confirm the runner shows **Idle/green**
in that Runners page.

### 3. [cloud, me] Open the firewall to this factory
Give me the factory box's **public egress IP**. I set
`client_ingest_egress_cidrs = ["<ip>/32"]` in `terraform/production` and run
`terraform plan`; you approve `apply`. This opens new-prod `:8444` to CPACK only.
(PR #679 already added the `:8444` rule + fixed the tee to point at `:8444`.)

### 4. [you] Fire the action
GitHub → Actions → **Client Edge Deploy** → Run workflow:
`client=cpack`, `target=production`, `confirm=cpack`.
It brings up the stack on the factory box and checks the agent `/healthz`.

### 5. [factory] Wire the PLC-read flows
Open the new Node-RED (`http://<edge-box>:1880`, bind to LAN/VPN only). Import your
PLC connectivity flows + the generated `cpack/cpack-tee-node.json` tee (a *second
wire* off the SparkPlug-assembly node — a tee, not a redirect). Data starts flowing.

### 6. [cloud, me] Verify
CPACK `equipment_values` freshening on new-prod F3 + OEE computing.

## What's already done vs. still needed
- ✅ Workflow correct + tee points at the live `:8444` shim (PR #679).
- ✅ Cloud ingress live + ready (shim healthy, key set, cert present, topology seeded).
- ✅ `register-runner.sh` provided (step 2).
- ⏳ **You:** the factory box + run step 2 + the egress IP (step 3) + fire (step 4) + flows (step 5).

## Durability note (not blocking)
Today the tee POSTs straight to the cloud (no local buffer). CPACK counters are
absolute totalizers, so a WAN blip self-heals the cumulative count on reconnect;
only sub-blip resolution + downtime events during an outage are lost. The zero-loss
agent+outbox path (mTLS `:8883`) is a tracked follow-up, not a blocker for first data.
