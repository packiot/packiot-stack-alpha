# Client-Edge Deployment Bundle (ADR-0042 Mode-B)

The reusable, per-client edge a Customer Success engineer deploys **at a client
factory** to bring a new tenant onto the new stack. It is the productized
`Pull-to-edge` deliverable of the ADR-0042 §5 client CI/CD pipeline, and the
container that the ADR-0045 onboarding flow's **generate** step produces and
**cutover** step activates.

> Worked example throughout: **bispharma**. Everything under `bispharma/` is the
> `onboard-gen` output for a bispharma descriptor — a *scaffold topology*, not
> real ids. A new tenant is a new `.env` + a new `<tenant>/` dir. **Never a fork.**

---

## 1. What's in the bundle

| Path | What it is | Who produces it |
|---|---|---|
| `compose.edge.yml` | the 3-tier edge stack (Node-RED + internal mosquitto + sparkplug-agent) | this repo (reusable) |
| `.env.template` | every per-client parameter (copy → `.env`) | CS fills at deploy |
| `mosquitto/mosquitto.conf` | the internal Tier-1→Tier-2 loopback bus | this repo (reusable) |
| `bispharma/bispharma.descriptor.yaml` | the CS-Admin SSoT (describe output) | CS authors |
| `bispharma/bispharma-agent.yaml` | agentcfg descriptor — SparkPlug identity, brokers, mTLS refs, tag map | **generated** (`onboard-gen`) |
| `bispharma/bispharma-profile.yaml` | tenant conversion profile (prefix/alias/param/count-index) | **generated** |
| `bispharma/bispharma-register.sql` | `packml_register` INSERT (topic ↔ id_equipment) | **generated** |
| `bispharma/bispharma-tee-node.json` | the Node-RED Tier-1 raw-forwarder (tee) flow | **generated** |
| `certs/` | resolved mTLS material (gitignored) | provisioned at deploy |

The agent image is built multi-arch (amd64 **and** arm64 — client hardware may be
either) from `services/edge-transformer/Dockerfile.agent`.

## 2. The three tiers (ADR-0042 §2.1)

```
 PLC(s) ──fieldbus──▶ nodered (Tier-1 connectivity)  emits RAW suffix tags
                        │  tee: a 2nd wire off the SparkPlug-assembly node
                        ▼  edge/raw/<tenant>/#  (internal MQTT)  OR  POST :9104/v1/tags
                    sparkplug-agent (Tier-2 transmission)
                        │  alias-ASSIGN · NBIRTH/NDATA/NDEATH-LWT · RBE · outbox · encode
                        ▼  spBv1.0/<tenant>/…  over mTLS  (CN=<tenant>)
              ════════ OT/IT WAN ════════▶  new-prod ingest broker
```

Tier-1 is **SparkPlug-ignorant** — it forwards raw PLC facts and must never
publish `spBv1.0/*` (that namespace belongs to the agent). All canonicalization
(prefix fixups, count indices, parameter decomposition) happens **stack-side in
the agent's tenant profile** (ADR-0045 §2.3 Option B), never in the low-code flow.

---

## 3. Prerequisites

**At the CS workstation**
- `docker` ≥ 24 with `buildx` (multi-arch), or access to a pinned `AGENT_IMAGE`.
- The `onboard` / `onboard-gen` CLIs (`go build ./cmd/onboard-gen` in
  `services/edge-transformer`) — the ADR-0045 generator.
- SELECT-only access to staging `packml_register` to read real equipment ids.

**At the client factory (the edge box)**
- Linux host (amd64 **or** arm64) with Docker + Compose v2.
- Outbound TCP to the new-prod ingest broker (the `ssl://…:8883` in the
  generated `agent.yaml`) — the client's egress IP must be allow-listed there.
- Network reachability from Node-RED to the factory PLCs.

**Cloud-side (see §7 — this is a DEPENDENCY on new-prod readiness)**
- A SparkPlug ingest broker on new-prod terminating mTLS + a CN-scoped ACL.
- A per-tenant client cert issued with `CN=<TENANT>`.

---

## 4. The onboarding flow (describe → generate → capture → validate → cutover)

This container **is** what `generate` produces and `cutover` activates. The flow
is driven by the `onboard` orchestrator (ADR-0045 §2.5); the steps below map each
stage to what you do with this bundle.

### ① DESCRIBE — author the client descriptor
```bash
cd services/edge-transformer
go run ./cmd/onboard describe \
  --descriptor docs/clients/edge-deployment/<tenant>/<tenant>.descriptor.yaml \
  --init --tenant <TENANT> --enterprise <ENTERPRISE_ID> --prefix "<TENANT>/<SITE>"
# then fill the equipment: block (lines tp=3 + members tp=1) from packml_register,
# and the agent.uplink_broker + mtls.*_ref (secret:// references, never values).
```

### ② GENERATE — emit the four artifacts
```bash
go run ./cmd/onboard-gen \
  --descriptor docs/clients/edge-deployment/<tenant>/<tenant>.descriptor.yaml \
  --out docs/clients/edge-deployment/<tenant>/
# writes <tenant>-agent.yaml, <tenant>-profile.yaml, <tenant>-register.sql,
# <tenant>-tee-node.json. Count indices are emitted as INFERRED placeholders.
```
Apply `<tenant>-register.sql` via CS-Admin (onboarding step 6), and import
`<tenant>-tee-node.json` onto the SparkPlug-assembly node in the client's
Node-RED (a **tee**, a second wire — not a redirect).

### ③ CAPTURE — observe the unknowable PLC facts on a live tee
Count indices (`…/ProdProcessedCount/<IDX>/Unit`) are **arbitrary PLC channels,
not derivable from any table** (#601). Bring the edge up in observe posture
(steps §5), let the real tee flow, and reconcile the observed indices back into
the descriptor as **confirmed**:
```bash
go run ./cmd/onboard-capture --descriptor …/<tenant>.descriptor.yaml \
  --health http://<edge-host>:9103/healthz     # reads distinct observed indices
# re-run ② GENERATE so the profile carries CONFIRMED indices.
```
The agent surfaces every raw topic that matched nothing via
`sparkplug_agent_raw_dropped_total{reason="unmapped"}` — **reject-don't-drop**
(ADR-0045 §2.4a), so a wrong index is a visible metric, not a silent gap.

### ④ VALIDATE — the readiness gate
- **Health green:** `curl -fsS http://<edge-host>:9103/healthz` → `{"healthy":true}`.
- **Zero unmapped** for expected equipment (check the drop metric ≈ 0).
- **All indices confirmed** — `onboard-gen --cutover` must succeed (it *refuses*
  while any index is inferred: no tenant cuts over on inferred data, §2.4b).
- **Parity-gate** (ADR-0042 §5.2 / ADR-0022): replay the tenant's real data
  through the Mode-A staging harness and diff F3-from-agent vs prod via
  `internal/bake`. This is the load-bearing release gate.

### ⑤ CUTOVER — flip to the register-driven, real-data path
Only when ④ is green:
```bash
# in .env:
AGENT_TAGMAP_FROM_REGISTER=true
AGENT_PARAM_DECOMPOSITION=true
docker compose -f compose.edge.yml --env-file .env up -d sparkplug-agent
```
Reversible: flag back to `false` restores the static `raw_tag_map` byte-for-byte.

---

## 5. Deploying the edge (the mechanical steps)

```bash
cd docs/clients/edge-deployment
cp .env.template .env && $EDITOR .env          # fill TENANT_*, image, key, cert paths

# 1. Provision mTLS material into ./certs/ (gitignored). Resolve the secret://
#    refs from the generated agent.yaml → files:
#      certs/uplink-cert.pem   (client cert, CN=<TENANT>)
#      certs/uplink-key.pem    (client private key)
#      certs/uplink-ca.pem     (CA that signs the cloud broker's server cert)

# 2. Build (or pull) the agent image. Multi-arch build+push once, centrally:
docker buildx build --platform linux/amd64,linux/arm64 \
  -f ../../../services/edge-transformer/Dockerfile.agent \
  -t <registry>/sparkplug-agent:<semver> --push ../../../services/edge-transformer
#    …then set AGENT_IMAGE=<registry>/sparkplug-agent:<semver> in .env.
#    (Or leave AGENT_IMAGE=…:local to `docker compose build` on the edge box.)

# 3. Validate the composition, then bring it up:
docker compose -f compose.edge.yml --env-file .env config     # must exit 0
docker compose -f compose.edge.yml --env-file .env up -d

# 4. Wire the tee: open Node-RED (http://<edge-host>:${NODERED_UI_PORT}), import
#    <tenant>-tee-node.json onto the SparkPlug-assembly node, set the ingest key
#    env, deploy the flow.
```

## 6. Health & verification

| Check | Command | Expected |
|---|---|---|
| Agent healthy | `curl -fsS <host>:9103/healthz` | `{"healthy":true}` |
| Uplink connected | same JSON | `uplink_publisher.connected: true` |
| Tags flowing | `curl -s <host>:9103/metrics \| grep sparkplug_agent` | `raw_dropped_total{unmapped}` ≈ 0; `param_decomposed_total` rising after cutover |
| Cloud sees births | new-prod: SparkPlug seq-gap / IngestSilent Prometheus rules | no alerts; NBIRTH observed |
| Store-and-forward | pull the WAN, confirm outbox grows, restore, confirm drain | backlog replays cleanly |

An **ungraceful agent kill** must produce a cloud-visible NDEATH (the Last-Will,
ADR-0042 §2.2) — verify the cloud registers the death→birth transition.

---

## 7. DEPENDENCY on new-production readiness

Two cloud-side pieces this bundle targets **do not yet exist on new-prod** and are
tracked as blockers (a parallel agent is assessing new-prod readiness):

1. **The SparkPlug ingest broker.** `compose.production.yml` today has **no
   mosquitto and no edge-transformer** — there is no `ssl://…:8883` endpoint for
   the agent to uplink to. Until new-prod runs an mTLS-terminating SparkPlug
   ingest + the edge-transformer decode/Calc, Mode-B has no landing zone. (Mode-A
   validation on staging is unaffected — it uses the internal staging mosquitto.)
2. **Per-tenant cert provisioning.** The `CN=<tenant>` client cert + the CN-scoped
   broker ACL (ADR-0042 §6) must be issued and installed cloud-side. The bundle
   consumes the resolved cert files; **issuing** them is the cloud dependency.

3. **Agent feature parity for CUTOVER.** The base `sparkplug-agent` on `staging`
   already serves the static tag map + the HTTP-ingest tee path + the mTLS uplink
   (this PR), so **describe→generate→capture→validate all work today**. The final
   register-driven cutover flags (`AGENT_TAGMAP_FROM_REGISTER` / `AGENT_PARAM_DECOMPOSITION`
   / `AGENT_PROFILE_PATH`, ADR-0043/0044) activate only once those agent features
   merge to staging (separate PRs) — until then the agent ignores them and runs
   the static path, which is the correct pre-cutover posture.

Until (1) and (2) land, deploy the bundle in **Mode-A posture** (point `uplink_broker`
at the staging internal mosquitto over the tee, no client cert) to validate the edge
end-to-end without the WAN crossing.

## 8. Security notes (ADR-0042 §6)

- **The client never names its own tenant on the wire** — the mTLS `CN` asserts
  it and the broker ACL enforces `spBv1.0/<CN>/#`. One misconfig must not let one
  factory publish as another.
- **Secrets by reference, never value.** The generated `agent.yaml` carries
  `secret://…` refs; the deploy resolves them into `./certs/` (gitignored). The
  agentcfg loader *rejects* an inline value in a `_ref` field. `.env` and `certs/`
  are never committed.
- **The internal bus is deliberately open + plaintext** — it is loopback-only,
  carries no `spBv1.0/*`, and has no cross-tenant traffic. Standardize (mTLS,
  ACL, protobuf) only at the WAN crossing.
