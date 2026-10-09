# ADR-0057 — Platform-mediated box access: a browser-native SSM session broker

**Status:** Proposed · **Date:** 2026-09-15 · **Scope:** let a CS engineer reach a client box's **shell** and its **on-box web UIs** (edge-dashboard `:1881` / Node-RED `:1880`) from **CS Admin with only their csadmin login** — no local AWS credentials, no AWS CLI, no `session-manager-plugin`. · **Decision owner:** chief architect (pending USER sign-off) · **Altitude:** the *interactive-access* successor to [ADR-0049](0049-edge-deploy-last-mile-automation.md) Part I. ADR-0049 chose AWS SSM as the connectivity substrate and deliberately shipped the "Connect" affordance as **copy-paste `aws ssm start-session` commands**; this ADR decides how to turn that into a **platform-mediated** connection so access is gated by csadmin auth alone.

---

## 1. Context

### 1.1 Where we are (ADR-0049 Part I, shipped)
`edge-ssm.service.ts#connect()` hands the CS engineer copy-paste commands they run in **their own shell**:

```
aws ssm start-session --target mi-… --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["1881"],"localPortNumber":["1881"]}' --region …
```

That session authenticates with the **engineer's own AWS IAM identity**, and the code comment states the two reasons this path was chosen over brokering:

1. **Per-identity IAM audit** — CloudTrail records *which human* opened a shell to *which box*, under their name.
2. **Session lifecycle** — a brokered session "would leak `Connected` server-side forever if the local plugin dies," so edge-api would have to persist the `SessionId` and `TerminateSession` on disconnect.

### 1.2 The cost of that choice
Every CS engineer needs (a) an **AWS IAM identity** with `ssm:StartSession` on the tagged boxes, (b) the **AWS CLI**, and (c) the **session-manager-plugin** installed locally. That is a real onboarding tax and leaks the "platform" abstraction: csadmin is supposed to be the single pane of glass, but interactive access drops the engineer to a personal AWS toolchain.

### 1.3 The goal
A CS engineer authenticated to **csadmin (Cognito CS group)** clicks **Open shell** / **Open dashboard** and gets a working, audited connection **in the browser** — no AWS identity of their own.

### 1.4 Constraints that bind
- **K1 — edge-api stack:** NestJS on Express, `@aws-sdk/client-ssm` present; **no** `ws`/proxy libs yet.
- **K2 — production image is `node:18-alpine` (musl).** The official `session-manager-plugin` is a glibc binary — it does not run cleanly on alpine.
- **K3 — the SSM data channel is a binary agent-message protocol.** The AWS **JS SDK ships only the control plane** (`StartSession` → `{SessionId, StreamUrl, TokenValue}`); it does **not** include a data-channel client. Speaking the channel means either the `session-manager-plugin` or a hand-rolled protocol implementation.
- **K4 — ingress:** csadmin/edge-api sit behind CloudFront → oauth2-proxy → nginx. WebSocket upgrades must be allowed through, and we have already been bitten by the **WAF 8 KB cookie cap** on this path (`feedback_bug_waf_cookie_size_oauth2proxy_cookie_store`).
- **K5 — box identity is an SSM hybrid activation** (`mi-…`, tags `enterprise=<id>` + `managed-by=packiot-edge-api`); the agent holds only **rotating short-lived role creds**, no static key (ADR-0049).

---

## 2. Decision

**edge-api becomes an authenticated SSM session *broker*.** It already holds the AWS role that does `CreateActivation`/`SendCommand`; it will additionally, **on behalf of a csadmin-authenticated CS engineer**, open and tear down SSM sessions and bridge them to the browser. Two capabilities:

- **Shell** → an in-browser **xterm.js** terminal over a WebSocket that edge-api relays to the SSM data channel.
- **On-box HTTP UI** (edge-dashboard `:1881` / Node-RED `:1880`) → an **authenticated reverse proxy** (`/api/edge/{idEnterprise}/ui/*`) tunnelled through an SSM port-forward, so the UI loads embedded in csadmin.

The box side is **unchanged** — same agent, same hybrid activation. Only *who drives `StartSession`* moves from the human's CLI to edge-api.

### 2.1 The audit-model shift (the crux)
Brokering **forfeits CloudTrail per-identity attribution** — every session now shows edge-api's role. ADR-0049 rejected brokering for exactly this. We now **accept it and re-establish accountability one layer up**: edge-api already derives the acting CS identity from the verified Cognito token (`res.locals.actingUser`, the same `isCsAdmin` path the readiness/connect endpoints use). Every session **start / target / stop / duration** is written to the **UserLogs audit trail** keyed on `actingUser` + `callerEnterpriseId`. Net: attribution moves **from CloudTrail to csadmin's own audit log** — arguably *better* for CS ops (queryable next to every other CS action) and the enabling reason ADR-0049's objection no longer blocks us.

### 2.2 Data-plane options
| # | Option | Verdict |
|---|--------|---------|
| O1 | **`session-manager-plugin` subprocess** (reuse AWS's maintained protocol impl). Requires a glibc runtime → **base-image change** (alpine→debian-slim) *or* a dedicated debian **sidecar broker service**. | ✅ **Recommended** — don't hand-roll a binary AWS protocol. |
| O2 | Hand-roll the SSM agent-message protocol in Node (`ws` only, alpine-safe). | ❌ Rejected — hundreds of lines of framing/ACK/flow-control with no official JS client; high maintenance risk (K3). |
| O3 | Return `StreamUrl`+`TokenValue` to the browser and connect direct to SSM. | ❌ Rejected — still needs the protocol client-side, and hands a session token to the browser (harder to reap/scope). |

**Isolation call:** the plugin turns edge-api into a *privileged session gateway* that can shell into any managed box. To bound blast radius we prefer running the plugin-bearing broker as a **dedicated `edge-session-broker` sidecar** (its own debian-slim image, minimal surface), leaving edge-api on alpine. The **control plane** (auth, tenant-scope, registry, audit) stays in edge-api; only the **data plane** (plugin + WS/proxy bridge) lives in the sidecar. Phase 1 below builds the control plane with no plugin at all, so this split can be finalized when Phase 2 lands.

### 2.3 Authorization & scope (unchanged fences, reused)
- **CsAdminGuard** (Cognito CS group) authenticates the human; `callerEnterpriseId` = the request target (ADR-0026 write-plane pattern).
- `resolveInstance(idEnterprise)` already filters on `managed-by=packiot-edge-api` — the broker can only reach boxes this control plane minted, never the pre-existing EC2 fleet.
- **Session caps:** hard idle-timeout, absolute max duration, per-tenant + global concurrency cap; **terminate on WS close** + a periodic **reaper** that `TerminateSession`s anything orphaned (directly answers ADR-0049's "Connected forever" objection).

---

## 3. Consequences

- **+ Platform UX:** CS engineers need only their csadmin login; no AWS identity/CLI/plugin. Onboarding tax gone.
- **+ Unified audit:** session history sits in UserLogs beside every other CS action, keyed on the person.
- **+ Revocation:** cut a person via Cognito group; cut a box via `DeleteActivation`/deregister; cut a live session via `TerminateSession`.
- **− edge-api/broker is now privileged:** mitigated by the sidecar split, tag-scoping, CS-guard, caps, and full audit.
- **− New moving parts:** a plugin-bearing runtime (base-image or sidecar), a WS relay, a reverse proxy, and ingress WS-upgrade config (K4 — verify oauth2-proxy/WAF pass `Upgrade`/`Connection` and that the auth cookie stays under 8 KB on the WS path).
- **− Data-channel dependency:** we depend on the `session-manager-plugin`'s protocol; acceptable (it's AWS-maintained and the same one the CLI ships).

---

## 4. Rollout (phased — detail in `docs/plans/adr-0057-ssm-broker-implementation.md`)

- **Phase 1 — Broker control plane (edge-api, no plugin):** `POST /api/edge-ssm/session` (CS-guard → tenant-scoped `StartSession` → register `{sessionId, actingUser, idEnterprise, startedAt}` → audit) and `DELETE /api/edge-ssm/session/:id` (`TerminateSession` + reap), an in-process **session registry + idle reaper**, caps, and unit tests. Establishes the authz + audit + lifecycle model. **No user-visible data path yet — not deployed until Phase 2.**
- **Phase 2a — Shell data plane:** `edge-session-broker` sidecar (debian-slim + `session-manager-plugin` + `ws`) bridging a browser WS ↔ the plugin's stdio; csadmin xterm.js terminal; ingress WS config.
- **Phase 2b — Dashboard reverse proxy:** broker holds a port-forward to `box:1881`; edge-api reverse-proxies `/api/edge/{id}/ui/*`; csadmin "Open dashboard" loads it embedded.
- **Phase 3 — Hardening:** session-recording to S3/CloudWatch (optional keystroke audit), per-role scoping, rate limits.

Supersedes the copy-paste `connect()` affordance for interactive use **once Phase 2 ships**; `connect()` stays as the documented fallback for power users with their own AWS identity.
