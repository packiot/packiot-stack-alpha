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
- **Reach `:1880` / Postgres / native SSH — Port Forwarding.** `AWS-StartPortForwardingSessionToRemoteHost` (to a host the box can reach) and `AWS-StartPortForwardingSession` (to a port on the box itself) tunnel Node-RED `:1880`, Postgres `:5432`, PLC tools through the same 443 channel. Engineers who want **real** `ssh`/`scp`/`rsync` forward `localhost:2222 → box:22` and `ssh -p2222 localhost` (SSM ProxyCommand pattern).
- **Deploy — RunCommand.** `ssm:SendCommand` with `AWS-RunShellScript` pushes `docker compose up -d` / bundle-apply from CS Admin → edge-api, IAM-scoped and CloudTrail-audited. **This largely dissolves the A/B/C deploy question below** — RunCommand *is* the AWS-native push-deploy: no GitHub runner, no custom pull-agent.
- **Cost (state it honestly).** Standard-tier managed instances (**≤1,000 per account/region**) are **free** for inventory + RunCommand. **Caveat:** Session Manager *and* Port Forwarding **on hybrid (non-EC2) managed instances require the advanced-instances tier** — **≈ $0.00695/instance-hour ≈ $5/mo per box**. So: **deploy-only (RunCommand) = $0; interactive shell + port-forward = ~$5/mo/client box.** Either way it is **AWS, not a third party** — it satisfies C6. (At, say, 20 clients that is ~$100/mo for full audited interactive access to the whole fleet — cheap for what it buys.)

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
| 6 | **$ to third parties** (C6) | ✅ **$0 to any vendor** — AWS-native; RunCommand free, Session Mgr/port-fwd ~$5/mo/box (advanced tier) | ✅ **$0 to vendors** — OSS + EC2 cost only | ✅ **$0 to vendors** — OSS + EC2 | ❌ **pay a SaaS** — violates the constraint |
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

**Why SSM.** It is the *only* option that clears **every** binding constraint *and* costs **nothing to any vendor** *and* is **already the org's tool**: the SSM Agent is a Go binary that runs on CPACK's EOL 18.04 where the .NET-8 GitHub runner cannot (C1); it dials outbound 443 like the `:8883` uplink already proves is permitted, zero inbound holes (C2); **Session Manager gives IAM-per-engineer identity, CloudWatch/S3 session audit, CloudTrail, and instant tag-scoped revocation** — the first-class human-access-into-a-plant-network story C3 demands, which the reverse-SSH bastion would force us to hand-roll; there is **no new service to run** (AWS operates the control plane), so the unattended-box rot of C4 is bounded to one small self-healing agent whose ping status CS Admin can render; RunCommand carries only IAM-scoped audited operations, not arbitrary workflow code (C5); and it is **AWS-native with $0 to third parties** (C6) — RunCommand deploy is free, interactive shell + port-forward on hybrid nodes is ~$5/mo/box on the advanced tier, an honest cost we accept for audited fleet access. Decisively for reuse, **this session itself drove the boxes via `aws ssm start-session` / `SendCommand`** — we are formalizing a capability we already operate, not adopting a new dependency.

**One capability, four uses:** enroll (Hybrid Activation) → shell (Session Manager) → app ports incl. native SSH (Port Forwarding) → deploy (RunCommand). The "Deploy" button and the "Connect" affordance are two faces of the *same* SSM enrollment. That collapse is the whole point of putting connectivity first.

**Why not the mesh (M) as primary:** a self-hosted WireGuard overlay is excellent and fully honors the no-pay constraint, but it is a **new service to stand up and patch**, and SSM already delivers shell + port-forward + deploy with **less to run**. Reach for M only when SSM's model is outgrown — specifically if you need **stable private IPs or box-to-box peering** (SSM is hub-and-spoke via the AWS control plane, not a peer mesh). Keep it documented as the graduation path; the CS-Admin flow (mint credential → bake → register → connect/revoke) is substrate-agnostic and survives the swap.

**Why not reverse-SSH+bastion (T):** same $0-to-vendor price as SSM but you **build and own** the identity/ACL/audit/revocation layer — exactly the rot-prone DIY that C3/C4 warn against. SSM gives that policy layer as a managed capability. T is break-glass only.

**Honest tradeoff for the USER to weigh:** the one place SSM costs money is **Session Manager/Port-Forwarding on hybrid instances = advanced tier (~$5/mo/box)**. If the org wants *literally $0* and is willing to run infra, a self-hosted Headscale mesh (M) gives interactive access for EC2-cost-only. The recommendation weighs "~$5/mo/box, nothing to operate, already in use, best audit story" (SSM) as clearly worth it over "free-of-marginal-cost but a mesh to run" (M) at current client counts — but the USER decides, and M is a coherent all-$0 alternative if that constraint hardens.

---

## Consequences

**If SSM is adopted:**
- **edge-api gains** SSM control endpoints: `CreateActivation` (tagged, scoped IAM role, expiry), `DescribeInstanceInformation` (status), `SendCommand` (deploy), `StartSession`/port-forward brokering, `DeregisterManagedInstance` (revoke). CS Admin renders status + Connect/Deploy/Revoke.
- **Enable the advanced-instances tier** in the account/region if interactive Session Manager on hybrid nodes is wanted (needed for `:1880` port-forward + shell; ~$5/mo/box). Deploy-only stays on the free standard tier.
- **The bundle is extended, not rewritten** — add the SSM-register systemd oneshot + the activation code/id to the existing secure handoff. `compose.edge.yml`, generated `<tenant>/` artifacts, the `docker save`d image, and the mTLS cert are unchanged; ADR-0045's generation work is untouched.
- **IAM is the new control surface to steward:** tag-scoped `StartSession`/`SendCommand` policies per CS role, activation-role least privilege, Session Manager logging to a locked S3/CloudWatch destination. This is where the C3 security guarantees live — get it tight.
- **The GitHub-runner path (ADR-0005) is retired for the new-stack edge** — no per-factory runner, no `register-runner.sh` on client boxes. Per the clean-abandoned-path-trails rule (`memory/feedback_clean_abandoned_path_trails.md`), mark `register-runner.sh` superseded rather than leaving it as a live-looking alternative.

**If nothing is built (stay manual + ad-hoc VPN):** fine for 1–2 clients; at a fleet it means no identity, no audit, no revocation on human access into client plants (a real liability) and every deploy is a human trip.

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
