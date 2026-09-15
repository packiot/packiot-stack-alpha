# ADR-0057 implementation plan — platform-mediated box access (SSM session broker)

Companion to [ADR-0057](../adr/0057-platform-mediated-box-access-ssm-broker.md). Phased so each step is independently testable and the risky data-plane work is isolated from the auth/audit foundation.

## Phase 1 — Broker control plane (edge-api, NO plugin) ← executing now
Goal: the auth + tenant-scope + audit + lifecycle model, using only `@aws-sdk/client-ssm` control-plane calls. No user-visible data path; **not deployed** until Phase 2 makes it usable.

Files (edge-api):
- `src/usecases/edge-ssm/shared/edge-ssm.service.ts`
  - `startSession(idEnterprise)`: `assertProvisioned` → `requireInstanceId` (tag-scoped resolve) → enforce caps (global + per-tenant concurrency) → `StartSessionCommand({ Target, DocumentName: 'SSM-SessionManagerRunShell' })` → register the session → return `{ sessionId, streamUrl, tokenValue, instanceId }`. (StreamUrl/TokenValue are consumed by the Phase-2 broker, never sent to the browser.)
  - `terminateSession(idEnterprise, sessionId)`: registry-guard (only a session this tenant owns) → `TerminateSessionCommand` → deregister.
  - `SessionRegistry` (in-process `Map`): `{ sessionId → { idEnterprise, actingUser, instanceId, startedAt, lastSeenAt } }`; `reapIdle(now)` terminates + drops sessions past idle-timeout / max-duration.
  - Config: `sessionIdleMs`, `sessionMaxMs`, `sessionMaxPerTenant`, `sessionMaxGlobal` (env, sane defaults).
- `src/usecases/edge-ssm/edge-ssm.controller.ts`
  - `POST /api/edge-ssm/session` (`@OnboardingEndpoint`/CS-guard) → `startSession(callerEnterpriseId)`; `audit(res, 'edge_ssm_session_start', { sessionId, instanceId })`.
  - `DELETE /api/edge-ssm/session/:id` → `terminateSession`; `audit('edge_ssm_session_stop', …)`.
- Reaper: a `setInterval` (or Nest `@Interval`) calling `registry.reapIdle`; guarded so tests don't leak timers.
- DTOs mirror the new shapes; `Date.now`-based timing injected for testability.

Tests (`edge-ssm.service.spec.ts`): start registers + returns handle; terminate calls `TerminateSessionCommand` + deregisters; caps reject with 429/`ConflictException`; reaper terminates only past-deadline sessions; cross-tenant terminate is refused. Mock the SSM `send`.

Exit criteria: `tsc` clean, `eslint` clean, jest green. Commit as its own PR; **hold deploy**.

## Phase 2a — Shell data plane (sidecar + xterm.js)
- New `edge-session-broker` service: debian-slim image + `session-manager-plugin` + a tiny `ws` server. Receives `{sessionId, streamUrl, tokenValue}` from edge-api (server-to-server, on the internal network), spawns `session-manager-plugin '<json>' <region> StartSession`, bridges plugin stdio ↔ the browser WS.
- edge-api: `GET /api/edge-ssm/session/:id/stream` upgrades to WS (add `ws`); authorizes via the CS session, then proxies to the broker. Update registry `lastSeenAt` on traffic; `TerminateSession` on WS close.
- csadmin: `<BoxShell>` xterm.js component in the Box-ops page; "Open shell" button.
- Ingress: confirm oauth2-proxy/nginx pass `Upgrade: websocket`; keep the auth cookie < 8 KB on the WS path (K4).

## Phase 2b — Dashboard reverse proxy
- Broker: on demand, `session-manager-plugin` `AWS-StartPortForwardingSession` to `box:<port>` bound to an ephemeral localhost port; hand edge-api the port.
- edge-api: reverse-proxy `/api/edge/{idEnterprise}/ui/*` → `http://broker:<port>/*` (add `http-proxy-middleware`), CS-guarded + tenant-scoped; rewrite dashboard base-href as needed.
- csadmin: "Open dashboard" opens the proxied URL embedded; drop the copy-paste port-forward affordance from the Connect card (keep as fallback under "advanced").

## Phase 3 — Hardening
Session recording (S3/CloudWatch), per-role scoping (view-only dashboard vs shell), rate limits, and a metrics counter (active sessions) on the existing Prometheus scrape.

## Deploy note
Everything ships through the (now-healthy) auto-bump→Deploy-to-Staging chain. Phase 2 adds the `edge-session-broker` service to `compose.staging.yml`; the post-deploy service-state gate will require it healthy.