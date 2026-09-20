# CPACK parallel co-tee deploy — via csadmin onboarding (Phase B design, PLAN ONLY)

> **Status: design / staged plan. Nothing in here is fired at the CPACK client VM
> without an explicit per-step "go".** This is the productization of the flow the
> SBXCPACK sandbox twin rehearsed (see Phase A below) — run for real, unmocked,
> against the actual CPACK factory box that also runs the client's **legacy
> Node-RED**.

## 0. The one non-negotiable invariant

The box lands **on the client VM where the legacy Node-RED runs**. Therefore:

- **The legacy Node-RED / legacy stack is NEVER touched.** We stand up a *parallel*
  Node-RED + sparkplug-agent (ADR-0042 Mode-B) that co-tees the PLC reads
  **read-only** and forwards to our ingest over mTLS. Our containers are a separate
  compose project; they do not import, edit, restart, or share state with the
  legacy flow.
- **Read-only tap.** The co-tee is a *second wire* off the PLC read — it reads, it
  does not write to PLCs or to the legacy flow.
- **Fail-safe by construction.** Same 5-layer severance discipline the sandbox
  proved: loopback-internal Tier-1→Tier-2 bus, mTLS `CN=cpack` (rejected by any
  other broker), disk-outbox buffering so a WAN blip loses nothing.

## 1. Why the SSM rail, not a GitHub runner

`FIRE-CPACK.md` documents an older GitHub-runner path (`register-runner.sh` +
`client-edge-deploy.yml`). **That is superseded (ADR-0049).** New-stack edges
enroll via **AWS SSM Hybrid Activation** and are deployed via **CS-Admin →
edge-api RunCommand**. This is the path the sandbox rehearsal exercised end-to-end,
and it is what csadmin drives. The runner path stays only as break-glass.

The user's ask — *"the cpack runner + bundle don't exist and should be configured
with csadmin onboarding"* — maps onto the SSM rail like this:

| Old (runner) prerequisite | New (SSM rail, csadmin-driven) equivalent |
|---|---|
| GitHub runner labelled `cpack` on the client VM | **SSM hybrid activation** minted by csadmin (`POST /api/edge-ssm/activation`), redeemed on the box by `ssm-register.sh` → the box becomes `mi-…` tagged `enterprise=<id>`,`managed-by=packiot-edge-api` |
| `docs/clients/edge-deployment/cpack/` bundle hand-committed | **`onboard-gen`** emits the bundle from the descriptor at csadmin's **generate** step; `edge-api deploy-bundle` pushes it to the box over one RunCommand |
| CS engineer runs the Action | csadmin **Box Ops → Deploy** button (RunCommand) |

## 2. End-to-end flow (what csadmin onboarding drives)

```
csadmin onboarding wizard
  1. describe   → CPACK client_descriptor (SSoT; the cpack descriptor already exists)
  2. generate   → onboard-gen emits cpack bundle: compose.edge.yml + cpack-agent.yaml
                   + cpack-profile.yaml + cpack-register.sql + cpack-tee-node.json
                   (+ cpack-client.yaml if a plc: block is present)
  3. activation → POST /api/edge-ssm/activation?idEnterprise=<cpack>  → code+id (shown ONCE)
        │  hand the code to the box over the same secure channel as the mTLS key
        ▼
[CPACK client VM]  (Docker + Compose v2, reaches PLCs + internet:443 outbound)
  ssm-register.sh (activation code/id) → box registers as mi-… (idempotent, reboot-safe)
        ▼
csadmin Box Ops → Deploy  → edge-api deploy-bundle (RunCommand):
  writes bundle under /opt/packiot, then `docker compose -f compose.edge.yml
  --profile nodered up -d`  (parallel stack: internal mosquitto + sparkplug-agent
  + the co-tee Node-RED — legacy Node-RED untouched)
        ▼
sparkplug-agent → mTLS CN=cpack → new-prod ingest broker :8883 → sparkplug-decoder → F3
```

## 3. GATED provisioning (cloud + secret steps — hold for explicit go)

From `FIRE-CPACK.md` PROVISIONING (unchanged, still required, each gated):

- **P1** (safe, local): `gen-mtls-certs.sh TENANT=cpack SERVER_DNS=ingest.prod…` → CA + server + `cpack` client cert.
- **P2** (secret): store in Secrets Manager `packiot/production/cpack-mtls/{cert,key,ca}` + `packiot/production/mosquitto-server`.
- **P3** (prod write): place server cert/key/client-ca on new-prod mosquitto (`i-02d255a1c21fb1da3:/opt/packiot/mosquitto/certs/`).
- **P4** (prod write): open `:8883` to the factory egress `/32` — `client_ingest_egress_cidrs` in `terraform/production`, you approve `apply`.

## 4. Staged execution plan — each step needs your "go"

| # | Step | Who / where | Risk | Gate |
|---|---|---|---|---|
| S0 | Confirm target env + CPACK enterprise id (staging ent 3 twin vs **prod** ent 1) | you | — | **decide first** |
| S1 | P1 mTLS cert gen (local, safe) | me | none | on go |
| S2 | P2/P3 secrets + new-prod mosquitto server side | me | prod write | **explicit go** |
| S3 | P4 firewall `/32` for the factory egress IP | you + me | prod net | **you approve apply** |
| S4 | csadmin: generate the cpack bundle (dry, no push) — review `gaps[]` | me | none | review output |
| S5 | csadmin: mint activation; **you** run `ssm-register.sh` on the client VM | you (on VM) | box enroll (no data yet) | on go |
| S6 | Box Ops dry-check: `/status` + `/health` green on the real box | me | read-only | — |
| S7 | **Deploy** the co-tee `--profile nodered` (RunCommand) | me | starts parallel stack (legacy untouched) | **explicit go** |
| S8 | On the VM: wire the PLC read → tee node (`cpack-tee-node.json`, a 2nd wire) | you (on VM) | reads only | — |
| S9 | Verify: `equipment_values` freshening on F3, agent `/healthz` green, `raw_dropped{unmapped}≈0` | me | read-only | — |

**Rollback at any point:** `docker compose -f compose.edge.yml down` on the box
removes only *our* parallel stack; the legacy Node-RED is never in scope.
`deregister` (mocked on twins, real here) revokes the box's SSM identity.

## 5. What Phase A (the sandbox twin) already proved

The SBXCPACK twin (`mi-02633b3ebab443fc6`, enterprise 2000003) rehearsed **S5–S7
with mutations mocked**, so we validated the *mechanism* without risk:

- activation → `ssm-register` → `mi-` Online, resolved by edge-api tag filter ✅
- `deploy` / `deploy-bundle` / … return `{mock, mockMessage, wouldRun}` — proving
  exactly the RunCommand that WILL run for real, without executing ✅
- the embedded Node-RED editor renders and is enforced **read-only** (deploy → 403) ✅

For **real CPACK** (enterprise id < 2,000,000, not in `SSM_SANDBOX_ENTERPRISE_IDS`)
the identical calls run **unmocked** — same code path, no twin short-circuit. That
is the whole point of the rehearsal: the button you click in csadmin behaves
identically; only the tenant classification differs.

## 6. csadmin work items to "drive onboarding" (implementation, later phase)

1. Onboarding wizard **Deploy** panel for a client-edge tenant: activation mint →
   copy-code affordance → status poll → deploy-bundle → live `gaps[]` surfacing.
2. Surface `deploy-bundle` `gaps[]` (unmapped tags, missing INGEST_KEY, unsupported
   protocol) as blocking-vs-warning in the wizard before S7.
3. (already done, backend) mocked mutations + read-only webui for twin tenants —
   so CS can *train/rehearse* the whole flow on the sandbox before touching a
   client VM. Add the front-end `mockMessage` toast so the rehearsal is obvious.

## 7. Open decision (S0)

**Which CPACK is the target?** Staging `CPACK-Staging` (ent 3) is itself a twin;
the real client VM + legacy Node-RED implies **production CPACK (ent 1)**. That
changes the ingest host (prod), the Secrets Manager paths (`packiot/production/…`),
and the firewall file (`terraform/production`). Confirm before S1.
