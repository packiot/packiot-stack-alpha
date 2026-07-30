# CPACK controlled edge deploy — runbook (fire tomorrow)

**Goal:** deploy a NEW, PARALLEL Node-RED + sparkplug-agent at the CPACK site that
co-tees the PLCs (read-only) → **new-production** ingest, as a controlled test of the
client-onboarding deploy. **The legacy CPACK Node-RED / stack is NOT touched.**

**Model:** ADR-0042 Mode-B, `docs/clients/edge-deployment/compose.edge.yml` (Node-RED +
internal mosquitto + sparkplug-agent). This is the NEW-stack path — **not** the legacy
`edge-node-red/deploy-template.yml` (that one goes to Google PubSub).

## Already done (cloud side — new-prod is CPACK-ready)
- CPACK topology seeded on new-prod (ent 3, 62 equip / 137 register / shifts).
- `client-ingest` profile UP + healthy (edge-transformer + ingest-shim + operator-adapter).
- Ingest front-door live: `https://ec2-3-232-9-118.compute-1.amazonaws.com:8446/ingest/sparkplug`,
  auth via `INGEST_API_KEY` (in `/opt/packiot/.env` on `i-02d255a1c21fb1da3`).

## What this PR adds (edge side, ready to fire)
- `docs/clients/edge-deployment/cpack/` — generated bundle (agent.yaml, profile.yaml,
  register.sql, tee-node.json). **tee-node already repointed to new-prod's `:8446`.**
- `docs/clients/edge-deployment/cpack.env.example` — the `compose.edge` `.env` for CPACK.
- `.github/workflows/client-edge-deploy.yml` — the **reusable** `workflow_dispatch` deploy,
  parameterized by `(client, target=staging|production)` — so you can fire ANY client's
  edge into EITHER environment (test a new/migrating client on staging, or cut over on prod).

## PREREQUISITES you must set before firing (⚠ not automatable from here)
1. **Self-hosted runner** on the CPACK edge host, **label `cpack`** (the workflow's
   `runs-on: [self-hosted, cpack]`). This is what makes it deploy *at the client*.
2. **GitHub secret `CPACK_INGEST_API_KEY`** = new-prod's `INGEST_API_KEY` value
   (retrieve from `/opt/packiot/.env` on `i-02d255a1c21fb1da3`).
3. **mTLS uplink certs** (CN=cpack) placed at the edge host's `CERTS_DIR` (see
   `cpack.env.example`) — the agent's Mode-B uplink.
4. **new-prod security group** must allow inbound **:8446** from the CPACK site's
   egress IP (else the tee's POST can't reach the ingest front-door). Verify this —
   it's the single most likely "data doesn't arrive" cause.
5. **PLC connectivity** from the new edge host to the CPACK PLCs (read-only) — the
   Node-RED flows in `cpack/nodered/` read them.

## Fire it
Actions tab → **"Client Edge Deploy (controlled)"** → Run workflow →
`client: cpack`, `target: production`, `confirm: cpack`. It resolves the target's ingest
host + `PRODUCTION_INGEST_API_KEY`, materializes `.env`, repoints the tee-node to the
target host, `docker compose -f compose.edge.yml up -d --wait`, health-checks the agent.

**Per-env secrets (set once):** `STAGING_INGEST_API_KEY`, `PRODUCTION_INGEST_API_KEY`.
The workflow picks the right one by `target`. To test a client on STAGING first, fire with
`target: staging` — same client bundle, different environment.

## Verify data flow (after firing + PLCs connected)
- Edge host: `curl localhost:9103/healthz` (agent) + Node-RED UI on `:1880`.
- New-prod: CPACK `equipment_values` freshening on F3 for id_equipment 47–120; OEE
  computing on the seeded lines. (SSM to `i-02d255a1c21fb1da3` → prod DB.)

## ⚠ Honest caveats (verify — this is a first-of-its-kind deploy)
- **The `compose.edge` deploy workflow is authored fresh** (no prior instance of the
  NEW-model deploy as an Action). **Test-fire it on the runner before relying on it** —
  the mechanics (checkout on the runner, `compose.edge` env wiring, the agent image
  `packiot/sparkplug-agent:local` being present on the edge host) need a real run.
- **Flow choice:** `compose.edge` supports (a) Node-RED→mosquitto→agent→mTLS-uplink and
  (b) tee-HTTP-POST to `:8446`. This bundle wires both; confirm which one CPACK's flows
  actually use so you're not double-sending.
- **Durability:** new-prod's ingress secrets/certs were hand-provisioned (task #23) —
  fine for this test, bake into Secrets Manager before it's load-bearing.
- **Cosmetic:** new-prod enterprise `nm='CPACK-Staging'` (copied from staging ent-3) —
  rename to `CPACK`.
