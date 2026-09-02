# ADR-0049 — Reaching the Client Factory Box: AWS SSM as the Connectivity, Access & Deploy Substrate

**Status:** Proposed · **Date:** 2026-08-27 · **Scope:** how the central control plane (edge-api / CS Admin) and CS engineers **reach a box on a locked-down client factory network** — for *both* (a) automated deploy of a per-client edge bundle and (b) interactive human access (SSH-equivalent shell, Node-RED `:1880`, Postgres, PLC tooling), across VPN/NAT/inbound-locked plant networks · **Decision owner:** chief architect (pending USER sign-off) · **Altitude:** the *delivery + reachability* companion to [ADR-0045 (CS-Admin-driven client onboarding)](0045-client-onboarding-architecture.md); supersedes the per-factory GitHub-runner direction of [ADR-0005](0005-edge-nodered-self-hosted-runner-deploys.md) for the new-stack edge. ADR-0045 makes the bundle *config-as-data*; this ADR decides how the **"Deploy" button** and a **"Connect" affordance** in CS Admin turn "we have a bundle / we need to reach the box" into a running edge and a live, audited shell.

**Synthesis note.** Grounded in the live CPACK bring-up (`docs/clients/cpack-edge-deploy-findings.md`, 2026-08-06 — the only real client edge deployed end-to-end), the CI-rot incident of this date (`memory/feedback_bug_edge_api_ci_rot_chain.md`, 2026-08-27), and a **hard USER constraint (2026-08-27): no paying another company/service — AWS-native first; self-hosted OSS on our own AWS is acceptable, paid third-party SaaS is not.** Decision doc, not a re-investigation.

---

## 1. Context

### 1.1 Two needs that are actually one problem

1. **Deploy the edge bundle automatically.** ADR-0045 productized *generation*: `.github/workflows/generate-client-bundle.yml` builds a per-client bundle (`compose.edge.yml` + generated `<tenant>/` artifacts + a signed `CN=<tenant>` mTLS cert + a `docker save`d image) and uploads it as a GitHub artifact — its own header states *"There is NO self-hosted runner AT the client … a CS engineer downloads the artifact, drops it on the client box … and runs `docker compose … up -d`."* The last mile is **manual**. CS Admin is meant to grow a **"Deploy" button** (`docs/clients/csadmin-bundle-setup-gaps.md` row 6).

2. **Reach the box interactively.** CS engineers must SSH in, open **Node-RED `:1880`** to wire PLC flows (`FIRE-CPACK.md` step 5: *"Open the new Node-RED (`http://<edge-box>:1880`, LAN/VPN-bound)"*), inspect Postgres, tail logs, hot-fix — every CPACK F0–F6 finding was a live poke on the box. Today that means an ad-hoc VPN with no per-engineer identity, no audit, no revocation.

**Both reduce to one problem:** *reach a box on a locked-down factory network from the central control plane, **outbound-initiated, zero inbound firewall holes**.* Deploy = "reach the box, run `compose up`." Interactive = "reach the box, open a shell / a port." Once you can reach the box, **deploy, SSH, `:1880`, and Postgres are all capabilities on one substrate.** So the *primary* decision is the **connectivity substrate**; the deploy mechanism is a *consumer* of it.

### 1.2 Constraints that bind (field evidence)

- **C1 — EOL OS floor (decisive).** CPACK's box is **Ubuntu 18.04** (EOL, kernel 4.15). `memory/session_98_cpack_edge_artifact_proven.md`: CPACK was deployed *manually* because *"the CPACK box is EOL Ubuntu 18.04 where GH runner can't run / .NET8."* Any on-box agent must clear this floor where the .NET-8 GitHub runner cannot.
- **C2 — Inbound-locked, outbound-permitted.** The box already holds a working **outbound** mTLS uplink `sparkplug-agent → ingest.prod.packiot.app:8883` (`README.md` §3). That **proves outbound from the factory floor is allowed** — any dial-out substrate rides the same property, **zero new inbound holes**.
- **C3 — Interactive = human access into a client's plant network.** Highest-trust operation on the platform. Requires per-engineer **identity**, **RBAC**, **session audit**, and **instant revocation** — first-class, not a footnote.
- **C4 — Unattended-box rot.** `memory/feedback_bug_edge_api_ci_rot_chain.md`: a self-hosted runner OOM-died (0 swap, `Restart=no`) and **stayed dead silently — two weeks of broken CI nobody noticed** on a *monitored datacenter* box. Multiply across N *unattended* factory boxes: the on-box component must be small, self-healing, and centrally observable.
- **C5 — Blast radius.** A GitHub runner executes *arbitrary workflow code* in the plant net (ADR-0005: *"if the runner registration token leaks, attacker can run arbitrary jobs on the factory PC"*). Prefer a substrate that carries only IAM-authenticated, audited, scoped operations.
- **C6 — No paid third parties; AWS-native; own-your-infra.** The org is deliberately moving off third-party cloud (`memory/reference_cost_ledger.md`: *"Move OFF GCP"*) and the new USER constraint forbids paying any external SaaS. **This rules out Tailscale SaaS, Teleport Cloud, Netbird Cloud, Cloudflare Tunnel.** Self-hosted OSS on our own AWS is fine; **AWS-native is preferred** — and the whole platform (and this very session, driving the boxes via `aws ssm start-session` / `SendCommand`) already runs on AWS SSM. The USER's own note `~/notes/zettel/aws/aws-ssm-remote-ops.md` frames it exactly: *"the instance calls out to AWS, not the other way around … No inbound port. No SSH keys. The control plane is AWS IAM."*

---

## Part I — The connectivity substrate (foundational)

### 2. Options

All dial **outbound** (C2-safe). They differ on OS floor, identity/audit/revocation, **$ to third parties**, and **reuse of what we already run**.

**Option S — AWS Systems Manager (Hybrid Activations + Session Manager + Port Forwarding + RunCommand). ✅ RECOMMENDED.** The AWS-native realization of everything below, already in use across the fleet.
- **Enroll the box — Hybrid Activations.** `ssm:CreateActivation` registers a **non-AWS on-prem factory box** as a *managed instance* (`mi-xxxx`) — AWS's supported path for on-prem/edge machines. The box runs the **SSM Agent** (`amazon-ssm-agent`, an open-source **Go** binary — runs on Ubuntu 18.04 where the .NET-8 runner cannot, C1), which long-polls **outbound HTTPS/443** to the SSM endpoints. Zero inbound holes (C2), same property as the `:8883` uplink.
- **Interactive shell — Session Manager.** `aws ssm start-session` = the SSH-equivalent: **IAM-authenticated per CS engineer**, every session logged to **CloudWatch Logs / S3** (keystroke/session audit), every API call in **CloudTrail** (C3). No SSH keys, no port 22. Revoke = deregister the instance or revoke the IAM permission.
- **Reach `:1880` / Postgres / native SSH — Port Forwarding.** For a service **on the box itself** (Node-RED `:1880`, Postgres `:5432`, and `box:22` for real `ssh`/`scp`/`rsync` via `localhost:2222 → box:22`) use **`AWS-StartPortForwardingSession`** (params `portNumber` / `localPortNumber`) — **proven live** carrying real HTTP from a non-EC2 node's `:1880`. Use `...ToRemoteHost` only to reach a host *beyond* the box; note AWS **forbids `host=localhost`** on the RemoteHost variant, so it is **not** the document for the box's own services. All over the same outbound 443 channel.
- **Deploy — RunCommand.** `ssm:SendCommand` with `AWS-RunShellScript` pushes `docker compose up -d` / bundle-apply from CS Admin → edge-api, IAM-scoped and CloudTrail-audited. **This largely dissolves the A/B/C deploy question below** — RunCommand *is* the AWS-native push-deploy: no GitHub runner, no custom pull-agent.
- **Cost (proven 2026-08-27 — it is $0).** The whole substrate was validated end-to-end on the **free standard tier**: a non-EC2 node registered as `mi-`, ran a RunCommand returning real stdout, **and** carried Session-Manager port-forward traffic — all *without* the advanced tier. An earlier draft claimed Session Manager / Port Forwarding on hybrid nodes needed the advanced-instances tier (~$5/mo/box); **the live proof disproved that** — AWS covers Session Manager + Run Command on the **first 1,000 hybrid instances per account/region on standard tier**. So deploy **and** interactive access are **$0 to any vendor** (C6). Advanced tier only matters past the 1,000-node cap or for at-scale patch/inventory extras.

**Option M — Self-hosted WireGuard overlay mesh (Headscale / Netbird OSS on our own EC2). Secondary / graduation path.** Box runs the OSS Tailscale/Netbird client (dials out to a **self-hosted** Headscale/Netbird control server on EC2 — **$0 to any vendor**, just EC2 cost). Gives every node a **stable private IP** → reach any port, and **box-to-box** peering SSM does not natively give. Clears C1 via **userspace mode** (`tailscaled --tun=userspace-networking` / wireguard-go, no kernel WireGuard needed on the 4.15 kernel). Identity/ACL/revocation via the control server (`tag:client-cpack`) + SSH mode. **Reserve for "if we outgrow SSM's shell+port-forward and need a true peer mesh with stable IPs."** More infra to run than SSM; not the primary.

**Option T — Reverse-SSH tunnel + self-hosted bastion.** Box holds an `autossh`/`ssh -R` (or OSS `frp`/`rathole`) reverse tunnel to a bastion we run. Lowest OS floor (just an SSH client). But you **hand-roll identity, ACL, audit, and revocation** on the bastion — the DIY policy layer C3/C4 warn rots. Fully self-hosted, $0 to vendors, but strictly worse than SSM on audit/RBAC for the same "no third party" price. **Break-glass only.**

**Rejected — paid third parties (violate C6, one-line each):**
- **Tailscale SaaS** — paid hosted control plane; we'd pay a vendor. (The OSS *Headscale* self-host is Option M.)
- **Teleport Cloud** — paid hosted broker. (Self-hosted OSS Teleport is a heavy Option-M/Z variant, not worth it over SSM here.)
- **Netbird Cloud** — paid hosted mesh. (Self-hosted Netbird is folded into Option M.)
- **Cloudflare Tunnel** — third-party edge dependence + paid tiers; not AWS-native.

### 3. Connectivity scoring

✅ good / 🟡 caveats / ❌ fails.

| # | Dimension (constraint) | **S — AWS SSM** ✅ | M — self-hosted WG mesh (Headscale/Netbird on EC2) | T — reverse-SSH + self-host bastion | *rejected: paid SaaS* |
|---|---|---|---|---|---|
| 1 | **EOL Ubuntu 18.04 floor** (C1) | ✅ SSM Agent = portable Go binary, supports 18.04 | ✅ userspace WireGuard (`--tun=userspace-networking`) | ✅ just an SSH client — any OS | (n/a) |
| 2 | **Inbound holes = 0** (C2) | ✅ agent dials OUT 443 (same as `:8883` uplink) | ✅ dials out to control server | ✅ dials out to bastion | ✅ |
| 3 | **Identity / RBAC / audit / revocation** (C3) | ✅ **IAM per engineer**, Session Manager logs → CloudWatch/S3, CloudTrail; revoke = deregister/IAM | ✅ IdP + ACL tags + SSH-mode certs/recording | ❌ **hand-rolled** on the bastion | (varies) |
| 4 | **Ops burden at N unattended boxes** (C4) | ✅ **no new service to run** — SSM is managed by AWS; `mi-` ping status is centrally visible | 🟡 you run + patch Headscale/Netbird EC2 | 🟡 you run + babysit the bastion; dropped `autossh` = silent-rot class | (varies) |
| 5 | **Blast radius on the box** (C5) | ✅ only IAM-scoped, audited SSM ops (no arbitrary workflow code) | ✅ ACL-scoped network flows | ✅ scoped tunnel | (varies) |
| 6 | **$ to third parties** (C6) | ✅ **$0 to any vendor** — AWS-native; RunCommand + Session Mgr + port-fwd **all free on standard tier** (proven live) | ✅ **$0 to vendors** — OSS + EC2 cost only | ✅ **$0 to vendors** — OSS + EC2 | ❌ **pay a SaaS** — violates the constraint |
| 7 | **Reuse — already in use?** | ✅✅ **already the org's tool** — this session drove the boxes via `aws ssm start-session`/`SendCommand`; USER has a note on it | ⬜ new to stand up | ⬜ new to stand up | ⬜ |
| 8 | **One substrate → many capabilities** | ✅ Session Mgr (shell) + Port-fwd (`:1880`/PG/ssh) + RunCommand (deploy), one agent | ✅ stable IP → any port | 🟡 each port = a hand-managed `-R` | (varies) |

---

## Part II — The deploy shape (largely dissolved by RunCommand)

With **S** as substrate, **RunCommand IS the deploy mechanism** — the earlier A/B/C debate mostly evaporates:

- **Option A — ephemeral GitHub runner on the box:** ❌ still fails C1 (.NET 8 won't run on CPACK's 18.04) and C5 (arbitrary workflow code in the plant net); and it duplicates a reachability channel SSM already gives. **Superseded by RunCommand.**
- **Option B — custom pull-agent:** was the recommendation *without* an AWS-native substrate; **now redundant** — `ssm:SendCommand` is the audited push-deploy, no bespoke agent + signing service to build. (If a *pull/converge* model is ever wanted for offline-tolerant self-healing, State Manager Associations give an AWS-native periodic-apply on top of the same agent — a config choice, not a new service.)
- **Option C — manual bundle-artifact:** stays as the **first-boot bootstrap + break-glass fallback**, and is *materially better* now: the engineer reaches the box via **Session Manager** (audited, keyless) instead of ad-hoc VPN, and applies the bundle over the same channel.

Net: **deploy = RunCommand (`AWS-RunShellScript`) invoked by edge-api from the CS-Admin "Deploy" button**, with manual-over-Session-Manager as fallback. No GitHub runner, no custom pull-agent.

---

## Part III — The CS-Admin provisioning + access flow (AWS-native)

1. **Onboard → mint activation.** CS Admin "Onboard" → edge-api calls **`ssm:CreateActivation`** for the client: scoped **IamRole** (least-privilege — only what the edge needs), a **RegistrationLimit** (usually 1), and an **ExpirationDate** on the activation window. Returns an **activation code + activation ID**.
2. **Bake into the bundle.** The activation code+id + region + a **systemd oneshot** that runs `amazon-ssm-agent -register -code … -id … -region …` go into the onboarding bundle — the same repo-access-controlled secure-handoff channel that already carries the mTLS client key (`README.md` §8, `secret://` discipline). Tag the instance `client:<slug>` at registration.
3. **First-boot registration.** On first boot the oneshot installs/registers the SSM Agent (outbound 443 only, C2) → the box appears as `mi-xxxx` tagged `client:<slug>`. The pull-of-record is then **RunCommand** for deploy.
4. **CS Admin surfaces status + actions.** Per client: **managed-instance ping status** (online / last-ping, from `ssm:DescribeInstanceInformation`), and buttons: **[Start Session]** (Session Manager shell), **[Port-forward :1880]** (Node-RED) / **[Port-forward :5432]** (Postgres), **[Run deploy]** (RunCommand `docker compose up -d`), and **[Deregister]** = revoke (`ssm:DeregisterManagedInstance` + expire the activation).
5. **RBAC + audit are enforced by IAM/SSM, not by CS-Admin convention.** IAM policies scope **which CS engineers can `StartSession`/`SendCommand` against which `client:<slug>` tag** (tag-based `Condition` on `ssm:resourceTag/client`); Session Manager logging + CloudTrail give the per-engineer audit trail (C3). Revocation is instant and centralized.

---

## Decision

**Recommend AWS Systems Manager as the unified substrate — Hybrid Activations to enroll the factory box, Session Manager + Port Forwarding for CS interactive access, RunCommand for deploy — all provisioned and revoked from CS Admin via edge-api. Self-hosted Headscale/Netbird on EC2 is the secondary graduation path if a true peer mesh (stable IPs / box-to-box) is later needed; reverse-SSH+bastion is break-glass only. Paid third-party SaaS (Tailscale/Teleport/Netbird Cloud, Cloudflare) is rejected outright per the no-pay constraint. Proposed — pending USER sign-off.**

> **Validation (2026-08-27) — the substrate was PROVEN end-to-end, not asserted.** A genuinely non-EC2 node (a Docker container running `amazon-ssm-agent` in hybrid mode) was registered via `CreateActivation` → appeared as `mi-08220fdd…` (`ResourceType=ManagedInstance`), `PingStatus=Online`; `SendCommand`/`AWS-RunShellScript` returned real stdout (the "Deploy" button); `AWS-StartPortForwardingSession` local`:12880`→node`:1880` carried a real HTTP payload (`curl` OK) — **all on the free standard tier.** Two draft claims were corrected by the proof: (1) the advanced-tier/~$5-per-box cost is **wrong** — hybrid Session Manager + RunCommand are free on standard tier; (2) reach a service on the box with **`AWS-StartPortForwardingSession`**, not `...ToRemoteHost` (which forbids `host=localhost`). Least-priv IAM (tag-scoped `SendCommand`/`StartSession` via `managed-by=packiot-edge-api`, `iam:PassRole` conditioned to `ssm.amazonaws.com`) and the hybrid instance role (`packiot-edge-ssm-hybrid-role`, trust `ssm.amazonaws.com` + `AmazonSSMManagedInstanceCore`) are captured. All test resources were cleaned up.

**Why SSM.** It is the *only* option that clears **every** binding constraint *and* costs **nothing to any vendor** *and* is **already the org's tool**: the SSM Agent is a Go binary that runs on CPACK's EOL 18.04 where the .NET-8 GitHub runner cannot (C1); it dials outbound 443 like the `:8883` uplink already proves is permitted, zero inbound holes (C2); **Session Manager gives IAM-per-engineer identity, CloudWatch/S3 session audit, CloudTrail, and instant tag-scoped revocation** — the first-class human-access-into-a-plant-network story C3 demands, which the reverse-SSH bastion would force us to hand-roll; there is **no new service to run** (AWS operates the control plane), so the unattended-box rot of C4 is bounded to one small self-healing agent whose ping status CS Admin can render; RunCommand carries only IAM-scoped audited operations, not arbitrary workflow code (C5); and it is **AWS-native with $0 to third parties** (C6) — RunCommand deploy **and** interactive shell + port-forward on hybrid nodes are **all free on the standard tier** (proven live 2026-08-27 against a real non-EC2 node; the advanced-tier cost was a draft error, disproved). Decisively for reuse, **this session itself drove the boxes via `aws ssm start-session` / `SendCommand`** — we are formalizing a capability we already operate, not adopting a new dependency.

**One capability, four uses:** enroll (Hybrid Activation) → shell (Session Manager) → app ports incl. native SSH (Port Forwarding) → deploy (RunCommand). The "Deploy" button and the "Connect" affordance are two faces of the *same* SSM enrollment. That collapse is the whole point of putting connectivity first.

**Why not the mesh (M) as primary:** a self-hosted WireGuard overlay is excellent and fully honors the no-pay constraint, but it is a **new service to stand up and patch**, and SSM already delivers shell + port-forward + deploy with **less to run**. Reach for M only when SSM's model is outgrown — specifically if you need **stable private IPs or box-to-box peering** (SSM is hub-and-spoke via the AWS control plane, not a peer mesh). Keep it documented as the graduation path; the CS-Admin flow (mint credential → bake → register → connect/revoke) is substrate-agnostic and survives the swap.

**Why not reverse-SSH+bastion (T):** same $0-to-vendor price as SSM but you **build and own** the identity/ACL/audit/revocation layer — exactly the rot-prone DIY that C3/C4 warn against. SSM gives that policy layer as a managed capability. T is break-glass only.

**Honest tradeoff for the USER to weigh:** with the advanced-tier cost **disproved by live proof** (interactive port-forward + shell ran on the free standard tier), SSM is genuinely **$0 to any vendor** — so the SSM-vs-mesh choice is no longer about money at all. The only thing SSM does *not* provide is a true **peer mesh**: it is hub-and-spoke via the AWS control plane, so no stable private IPs and no box-to-box connectivity. For CS's actual needs (shell, `:1880`, Postgres, deploy) that is irrelevant. Net: SSM wins on **$0 + nothing-to-operate + already-in-use + best-audit**; reserve the self-hosted mesh (M) purely for a future need that demands peer topology, not for cost.

---

## Consequences

**If SSM is adopted:**
- **edge-api gains** SSM control endpoints: `CreateActivation` (tagged, scoped IAM role, expiry), `DescribeInstanceInformation` (status), `SendCommand` (deploy), `StartSession`/port-forward brokering, `DeregisterManagedInstance` (revoke). CS Admin renders status + Connect/Deploy/Revoke.
- **No advanced-instances tier needed** — proven (2026-08-27) that Session Manager, Port Forwarding, and RunCommand on hybrid `mi-` nodes all work on the **free standard tier** (≤1,000 hybrid instances per account/region). Only revisit past that cap. edge-api must **track + `ssm:TerminateSession`** any Session Manager sessions it brokers (killing the local plugin leaves them Connected server-side).
- **The bundle is extended, not rewritten** — add the SSM-register systemd oneshot + the activation code/id to the existing secure handoff. `compose.edge.yml`, generated `<tenant>/` artifacts, the `docker save`d image, and the mTLS cert are unchanged; ADR-0045's generation work is untouched.
- **IAM is the new control surface to steward:** tag-scoped `StartSession`/`SendCommand` policies per CS role, activation-role least privilege, Session Manager logging to a locked S3/CloudWatch destination. This is where the C3 security guarantees live — get it tight.
- **The GitHub-runner path (ADR-0005) is retired for the new-stack edge** — no per-factory runner, no `register-runner.sh` on client boxes. Per the clean-abandoned-path-trails rule (`memory/feedback_clean_abandoned_path_trails.md`), mark `register-runner.sh` superseded rather than leaving it as a live-looking alternative.

**If nothing is built (stay manual + ad-hoc VPN):** fine for 1–2 clients; at a fleet it means no identity, no audit, no revocation on human access into client plants (a real liability) and every deploy is a human trip.

---

## IAM policy — canonical document + the SendCommand document-leg gotcha (2026-08-27)

The edge-api control-plane policy is codified in **`scripts/provision-edge-ssm-iam.sh`** (idempotent; publishes the embedded document as the default version of `packiot-edge-ssm-control`, attached to the `packiot-edge-ssm` user). Treat that script as the source of truth — the substrate was first stood up imperatively, and this closes the codification gap.

**The gotcha (Box-Ops "SendCommand not authorized" outage, fixed 2026-08-27):** `ssm:SendCommand` authorizes against **both** resources in the request — the *document* (`AWS-RunShellScript`) **and** the *target managed instance*. A single statement that scopes SendCommand with a `ssm:resourceTag/managed-by` `Condition` applies that Condition to the **AWS-owned document too**, which can never carry our tag → the document leg is denied and every Box-Ops command fails with *"not authorized to perform: ssm:SendCommand on resource …/document/AWS-RunShellScript."* The tenant-scoping intent is real, but it belongs on the **instance** leg only. Fix = **split** into an unconditional `SendCommandDocument` statement + a tag-gated `SendCommandToTaggedInstances` statement; the identical split applies to `ssm:StartSession` (Connect / `:1880` port-forward), whose session documents likewise cannot carry the tag. The tag gate on the instance legs (`managed-by=packiot-edge-api`, set at `CreateActivation`) is what actually enforces least privilege — edge-api can only target boxes it enrolled. Verified live via `simulate-principal-policy` **and** a real SendCommand as the `packiot-edge-ssm` user against the bispharma box.

---

## Rollback

- **Substrate is not in the data path.** SSM governs only *reachability + updates*; the running edge (agent, readers, mTLS uplink to `:8883`) keeps producing OEE with the SSM Agent stopped. Pulling SSM does not stop the factory data.
- **Deploy:** the manual bundle-artifact path (`README.md` §5 / `FIRE-CPACK.md`) stays fully functional as the fallback — apply bundles by hand over a Session Manager shell (or ad-hoc access if SSM is down).
- **Bad deploy:** re-`SendCommand` the previous bundle (idempotent `compose up`), or (if State Manager associations are used) pin the prior desired-state.
- **Kill access instantly:** `ssm:DeregisterManagedInstance` + expire the activation, or revoke the IAM permission — the box drops off the control plane immediately (client offboard / engineer departure).
- **Substrate migration (S → M):** the CS-Admin provisioning model is substrate-agnostic (mint credential → bake → register → connect/revoke); graduating to a self-hosted mesh swaps the on-box agent + the credential type without changing CS Admin's shape.

---

## References (grounded in the live tree)

- `.github/workflows/generate-client-bundle.yml` — the bundle generator (*"NO self-hosted runner AT the client"*).
- `docs/clients/edge-deployment/register-runner.sh` — the existing GitHub-runner registration (ADR-0005). **Superseded** by SSM RunCommand for the new-stack edge.
- `docs/clients/edge-deployment/{compose.edge.yml, Dockerfile.nodered-reader, README.md, FIRE-CPACK.md}` — bundle contents + manual apply runbook (§5 key-`chown`; `:1880` Node-RED; §6 `/healthz`).
- `docs/clients/cpack-edge-deploy-findings.md` — the real bring-up log (F0–F6); manual last mile + live pokes.
- `docs/clients/csadmin-bundle-setup-gaps.md` — the "Deploy" button + fields CS Admin must own (row 6).
- `memory/session_98_cpack_edge_artifact_proven.md` — **C1**: *"the CPACK box is EOL Ubuntu 18.04 where GH runner can't run / .NET8."*
- `memory/feedback_bug_edge_api_ci_rot_chain.md` (2026-08-27) — **C4**: runner OOM-dead (0 swap, `Restart=no`) → ~2-week silent outage; and the ops team *already* uses `SSM in` to reach the box.
- `~/notes/zettel/aws/aws-ssm-remote-ops.md` — **C6/reuse**: the SSM "instance calls out, IAM is the control plane, no inbound port, no SSH keys" model, already documented and in use.
- `memory/reference_cost_ledger.md` — off-GCP / own-your-infra ethos backing the no-third-party constraint.
- `docs/adr/0005-edge-nodered-self-hosted-runner-deploys.md` — the prior per-factory-runner decision this supersedes for the new-stack edge; its "what's missing" table flags the C5 arbitrary-code / token-leak risk.
- `docs/adr/0045-client-onboarding-architecture.md` — the parent ADR (this is its delivery + reachability companion).
