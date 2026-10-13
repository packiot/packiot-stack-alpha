---
title: edge-session-broker
layer: 3
owner_area: edge
last_verified: 2026-10-13
---
# edge-session-broker

> **Layer 3 · Components** — the internal sidecar that lets csadmin (Box Ops) and customize open
> a shell or a web UI (Node-RED editor, edge dashboard) on a client edge box through AWS SSM,
> without the browser or the engineer's laptop ever holding AWS credentials. For engineers
> maintaining box access (ADR-0057).
> Up: [Edge subsystem](../subsystems/edge.md) ·
> [README](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/edge-session-broker/README.md) ·
> [edge-api API reference](../../reference/api/edge-api.md) (the `/api/edge-ssm/*` control plane; the broker itself has no public API) ·
> [Service catalog](../../reference/service-catalog.md)

## Responsibility

The broker owns the **SSM data plane** for platform-mediated box access: it runs the AWS
`session-manager-plugin` against a session that edge-api already opened, and bridges the
plugin to (a) a WebSocket for an interactive shell and (b) a local HTTP reverse proxy for a
port-forwarded web UI. edge-api owns the control plane (who may open what, `StartSession`,
tickets, termination). The broker exists only because the plugin is a glibc binary and
edge-api's image is Alpine (musl).

## At a glance

| | |
|---|---|
| Language / runtime | Node.js 18 (`node:18-bookworm-slim`), ESM, one dependency (`ws@^8.18`, pinned by `package-lock.json`, installed with `npm ci`) |
| Repo path | `services/edge-session-broker/` (`server.mjs`, `server.test.mjs`, `Dockerfile`, `package.json`, `package-lock.json`) |
| Image | Built in compose (`build: ./services/edge-session-broker`); installs `session-manager-plugin` `.deb` for amd64 or arm64 at build time |
| Container | compose service `edge-session-broker` (no `container_name`, so the container is `stack-edge-session-broker-1`; DNS name `edge-session-broker` on `packiot-net`) |
| Ports | `8090` WebSocket `/shell` (`BROKER_PORT`), `8091` HTTP (`BROKER_HTTP_PORT`); **not published** — reachable only on `packiot-net` |
| AWS credentials | None. The plugin authenticates with the short-lived `TokenValue` from edge-api's `StartSession` |
| Depends on | edge-api (its only caller), outbound HTTPS to `ssm.<region>.amazonaws.com` and the session stream URL |
| Depended on by | edge-api `EdgeSsmService` (`relayToBroker`, `startWebUi`); `edge-api` `depends_on` it in `compose.staging.yml` |
| Limits | none set in compose |
| Environments | Staging only; not present in `compose.production.yml` |

## Inputs & outputs

| Interface | Caller | Auth | Behaviour |
|---|---|---|---|
| `ws://edge-session-broker:8090/shell?token=<BROKER_TOKEN>` | edge-api | query `token` must equal `BROKER_TOKEN` (constant-time compare), else close `1008` | First text frame = JSON handle `{SessionId, StreamUrl, TokenValue, Target, region}`; later frames = terminal bytes to plugin stdin; plugin stdout → ws |
| `POST http://edge-session-broker:8091/forward` | edge-api | header `x-broker-token` must equal `BROKER_TOKEN` (constant-time), else `401` | Body `{sessionId, response:{SessionId,StreamUrl,TokenValue}, target, boxPort, localPort}`; starts an `AWS-StartPortForwardingSession` plugin binding `127.0.0.1:<localPort>` in the broker; 200 once the port accepts TCP, 502 otherwise |
| `ANY http://edge-session-broker:8091/p/<sessionId>/<path>` | edge-api reverse proxy | header `x-broker-token` must equal `BROKER_TOKEN`, else `401` (edge-api also authorises the user first; it sends the header since packiot/edge-api#304) | Proxies to `127.0.0.1:<localPort>/<path>`. Before the box: drops `x-broker-token`, the `_oauth2_proxy*` and `pk_webui_*` cookies (other cookies kept) and oauth2-proxy / ALB identity headers (`x-auth-request-*`, `x-amzn-oidc-*`, `x-forwarded-access-token`, `x-forwarded-id-token`). From the box: removes `X-Frame-Options`, `Content-Security-Policy` and `…-Report-Only`, and sets `Content-Security-Policy: frame-ancestors <BROKER_FRAME_ANCESTORS>`, so only the listed origins (customize, csadmin) can iframe the UI. 404 `no active forward` for an unknown id |

## Internal design

```text
 browser (csadmin / customize xterm.js)
   │ 1. POST /api/edge-ssm/session {idEnterprise}   (CS-Admin guard)
   │    edge-api: caps check → ssm:StartSession(Target=mi-…) → store handle in memory
   │    ◄── {sessionId, streamTicket}  (ticket single-use, 30 s)
   │ 2. wss://…/api/edge-ssm/session/stream?ticket=…   (edge-api main.ts upgrade handler)
   ▼
 edge-api relayToBroker ──ws /shell?token──► broker ──spawn──► session-manager-plugin
        first frame = SSM handle                         AWS_SSM_START_SESSION_RESPONSE (env)
        bytes both ways; close either side ⇒ kill plugin + ssm:TerminateSession

 web UI:
 POST /api/edge-ssm/webui ─► StartSession(AWS-StartPortForwardingSession, portNumber=box port,
        localPortNumber=15001..15900 round-robin) ─► broker POST /forward
 browser iframe /api/edge-ssm/webui/<sid>/…?ticket=… ─► edge-api proxy (cookie
        pk_webui_<sid>, injects <base> + fetch/XHR/WebSocket path shim)
        ─► broker /p/<sid>/… ─► 127.0.0.1:<localPort> ─► box :1880 (Node-RED) or
           :SSM_ONPREM_DASHBOARD_PORT (1881, on-prem tenants)
```

Key details:

- **Secret handling.** The broker exits at startup (`[broker] FATAL`) unless `BROKER_TOKEN` is at
  least 32 characters, and removes it from its own environment after reading it, so plugin
  children never inherit it. The `StartSession` response is passed to the plugin in the env var
  `AWS_SSM_START_SESSION_RESPONSE`; `argv[1]` carries only the variable's *name*, so the token
  never appears in `ps`. Argument order mirrors the AWS CLI's own invocation:
  `session-manager-plugin AWS_SSM_START_SESSION_RESPONSE <region> StartSession "" <request-json> <endpoint>`.
- **Lifecycle.** WS close → `SIGKILL` the plugin. Plugin exit → close the WS (`1000`,
  `plugin exit <code>`). Port-forwards idle for `BROKER_FORWARD_IDLE_MS` (10 min) are killed by
  a 60 s reaper. `SIGTERM` closes the WS server and exits.
- **Port-forward readiness.** After spawning, the broker polls `127.0.0.1:<localPort>` every
  250 ms, up to 40 tries (~10 s), before answering `/forward`.
- **edge-api side controls** (`edge-ssm.service.ts`): max 25 concurrent sessions platform-wide
  (`SSM_SESSION_MAX_GLOBAL`), 3 per enterprise (`SSM_SESSION_MAX_PER_TENANT`, else HTTP 429);
  idle reap after 10 min (`SSM_SESSION_IDLE_MS`), hard cap 60 min (`SSM_SESSION_MAX_MS`),
  reaper every 60 s. `StartSession` uses the account's default session document (naming
  `SSM-SessionManagerRunShell` explicitly returned "does not exist").
- **Twin tenants** (id ≥ 2,000,000 or in `SSM_SANDBOX_ENTERPRISE_IDS`): the edge-api proxy
  returns 403 `read-only-twin` for `POST|PUT|DELETE|PATCH` on Node-RED
  `/flows|/flow|/nodes|/context|/inject`, and injects a "READ-ONLY TWIN" banner.

## Configuration

Broker (`server.mjs`):

| Env | Default | Staging value | Effect |
|---|---|---|---|
| `BROKER_PORT` | `8090` | `8090` | WebSocket `/shell` |
| `BROKER_HTTP_PORT` | `8091` | (default) | `/forward` + `/p/*` |
| `BROKER_TOKEN` | *(none: the broker exits at startup unless it is ≥ 32 characters)* | `${EDGE_SESSION_BROKER_TOKEN:?}` (compose refuses to start without it), from Secrets Manager `packiot/staging/app` key `edge_session_broker_token` | Shared secret with edge-api, checked on every route |
| `BROKER_FRAME_ANCESTORS` | `'self'` | `'self' https://customize.staging.packiot.app https://csadmin.staging.packiot.app` | CSP `frame-ancestors` source list for proxied box UIs (space-separated; `;`, `,` or newlines rejected at startup) |
| `AWS_REGION` | `us-east-1` | `us-east-1` | Plugin region |
| `SSM_ENDPOINT` | `https://ssm.<region>.amazonaws.com` | — | Plugin endpoint argument |
| `BROKER_FORWARD_IDLE_MS` | `600000` | — | Idle port-forward reap |

edge-api side: `EDGE_SESSION_BROKER_WS_URL` (`ws://edge-session-broker:8090/shell`),
`EDGE_SESSION_BROKER_HTTP_URL` (`http://edge-session-broker:8091`),
`EDGE_SESSION_BROKER_TOKEN`, and the `SSM_SESSION_*` limits above. Empty WS URL ⇒ shell
streaming disabled (socket closed `1011`); empty HTTP URL ⇒ `POST webui` 503.

!!! note "Secret hygiene"
    The token lives only in Secrets Manager (`packiot/staging/app` key
    `edge_session_broker_token`). `deploy-staging.yml` writes it into `/opt/packiot/.env` on every
    deploy and fails if it is missing or shorter than 32 characters; `app_init.sh` writes it on a
    fresh box (without the length check; the broker itself refuses a short token). Before #1700 compose fell back to a committed literal, which is burned.
    Port isolation on `packiot-net` remains a second boundary, not the only one.

## Data & invariants

- Stateless across restarts: in-flight shells and forwards die with the container; edge-api's
  reaper then terminates the SSM sessions.
- edge-api keeps session state **in memory** (`sessions`, `tickets`, `webuiSessions` maps), so
  an edge-api restart also orphans open sessions until SSM times them out.
- The browser never sees `StreamUrl` / `TokenValue`; only edge-api → broker carries them.
- Interactive access through `GET /api/edge-ssm/connect` (copy-paste `aws ssm start-session`)
  stays available for engineers who need their own IAM audit trail.

## Observability

- Logs (stdout, prefix `[broker]`): `listening on :8090/shell`, `rejected unauthenticated
  connection`, `starting plugin for session <id> target <mi>`, `plugin exited <code>`,
  `pf[<sid>] plugin exit`, `reaping idle forward <sid>`, `forward failed: …`.
- Health: compose healthcheck opens a TCP connection to `127.0.0.1:8090` (30 s interval). It
  does not check `:8091`.
- No metrics endpoint.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Terminal closes immediately | WS close `1008 unauthorized` in broker log | Token mismatch between edge-api and broker | Both read `EDGE_SESSION_BROKER_TOKEN` from `.env`; redeploy so both are recreated |
| Web UI `401 unauthorized` | Iframe shows 401 | edge-api not sending `x-broker-token` on `/forward` or `/p/*` (an edge-api image older than packiot/edge-api#304), or token mismatch | Deploy edge-api ≥ #304; redeploy both services |
| Broker restarts in a loop | `[broker] FATAL BROKER_TOKEN must be set…` | Token missing or shorter than 32 characters | Seed `packiot/staging/app` `edge_session_broker_token` (`openssl rand -hex 32`) and redeploy |
| Box UI refuses to render in the iframe | Browser console: refused to frame, `frame-ancestors` | The embedding SPA's origin is not in `BROKER_FRAME_ANCESTORS` | Add the origin in `compose.staging.yml`, recreate the broker |
| Terminal closes with `plugin exit 255` | Session ends at once | Expired/used handle, or box offline | Check SSM ping status; retry |
| Web UI 502 `port-forward did not come up` | Iframe error | Box port not listening (e.g. on-prem box without Node-RED at 1880), or SSM denied | `connect` now picks the dashboard port for on-prem tenants; verify with `status/detailed` |
| Web UI 502 `StartSession` denied (2026-09-16 → 20) | 502 from edge-api | Target was an EC2 `i-` box; IAM scopes StartSession to `managed-instance/*` + `managed-by` tag | Register the box as a hybrid `mi-` |
| 429 on open | "Too many active box sessions" | Per-tenant (3) or global (25) cap | Close sessions or wait for the reaper |
| Broker build fails | Docker build error | Unsupported architecture (only amd64/arm64 plugin `.deb`s) | Build on amd64/arm64 |

## Operating it

- Restart: `docker compose -f compose.staging.yml up -d --force-recreate edge-session-broker`
  (drops open shells; safe otherwise).
- Rotate the token: put a new `openssl rand -hex 32` into `packiot/staging/app` key
  `edge_session_broker_token` and redeploy. The deploy rewrites `.env` and recreates **both**
  `edge-session-broker` and `edge-api` (a `docker restart` keeps the old env).
- Never publish ports 8090/8091 on the host or nginx; the token is a second boundary, not a
  reason to expose them.

## Tests

`services/edge-session-broker/server.test.mjs` (`npm test`, `node:test`, no plugin or AWS
needed) covers token enforcement on the WebSocket and every HTTP route (`/p/*` included), the
startup refusal without a 32-character token, the `frame-ancestors` header and the request-header
and cookie stripping on `/p/`. CI: `.github/workflows/node-services.yml` runs it on pull requests
that touch the service (not yet a required check). edge-api covers the control plane in
`edge-api/src/usecases/edge-ssm/shared/edge-ssm.service.spec.ts` (session caps, tickets, mock
tenants). End-to-end proof is manual: open a shell / web UI from csadmin Box Ops on a sandbox
tenant.

## Source map

| Path | What's there |
|---|---|
| `services/edge-session-broker/server.mjs` | WS shell bridge, `/forward`, `/p/*` proxy, token check, header filters, reaper |
| `services/edge-session-broker/server.test.mjs` | `node:test` suite |
| `.github/workflows/node-services.yml` | CI for Node services (matrix: `edge-session-broker`) |
| `services/edge-session-broker/Dockerfile` | Debian + session-manager-plugin install |
| `edge-api/src/main.ts` | WS upgrade handler `/api/edge-ssm/session/stream`, web-UI reverse proxy + HTML shim |
| `edge-api/src/usecases/edge-ssm/shared/edge-ssm.service.ts` | `startSession`, `relayToBroker`, `startWebUi`, reaper, `webUiTarget` |
| `edge-api/src/usecases/edge-ssm/shared/edge-ssm.config.ts` | `SSM_SESSION_*`, `EDGE_SESSION_BROKER_*` |
| `customize/src/components/edge/box-webui.tsx`, csadmin `src/components/edge/box-webui.tsx` / `box-shell.tsx` | the iframe and xterm.js clients |
| `compose.staging.yml` (`edge-session-broker`, `edge-api`) | Wiring |
| `docs/adr/0057-platform-mediated-box-access-ssm-broker.md` | Decision record |
