# edge-session-broker

Internal sidecar that runs the AWS `session-manager-plugin` for edge-api, bridging SSM sessions
to a client box's shell (WebSocket) and on-box web UIs (HTTP reverse proxy) (ADR-0057 Phase 2).

## What it does

ADR-0057 lets a CS engineer reach a client box from CS Admin with only their csadmin login.
edge-api owns the control plane: it authenticates the user, scopes the tenant, holds the AWS role
and calls `ssm:StartSession`. It then hands the session handle (`SessionId`, `StreamUrl`,
`TokenValue`) to this sidecar, which runs `session-manager-plugin` (a glibc binary that edge-api's
Alpine image cannot run). For a shell, the plugin's stdio is bridged to a WebSocket; for a web UI,
the plugin opens a port-forward inside this container and the sidecar reverse-proxies HTTP to it.
The sidecar holds no AWS credentials and is never exposed beyond the compose network.

## Where it fits

```text
 csadmin (browser, xterm.js / iframe)
        │ HTTPS/WSS, csadmin session
        ▼
 edge-api  ── ssm:StartSession (AWS role) ──▶ AWS SSM
        │ handle + BROKER_TOKEN
        ├─ ws://edge-session-broker:8090/shell ─┐
        └─ http://edge-session-broker:8091 ─────┤
                                                ▼
                         edge-session-broker ── session-manager-plugin ──▶ SSM ──▶ client box
                                                                         (shell, :1880/:1881 UIs)
```

## Status and environments

| Environment | Where (compose file · service · profile) | Image | Ports | Health |
|---|---|---|---|---|
| dev | none: left out on purpose (no SSM handle offline; `dev/README.md`, "Not in dev") | — | — | — |
| staging | `compose.staging.yml` · `edge-session-broker` · no profile | built from `Dockerfile` (`node:22-bookworm-slim` + `session-manager-plugin` .deb, runs as `node`) | in-network 8090 (WS), 8091 (HTTP); no host publish | TCP connect to 8090 |
| production | not in `compose.production.yml` | — | — | — |

## Interfaces

### HTTP

| Method | Path / port | Auth | What |
|---|---|---|---|
| WS | `:8090/shell?token=<broker token>` | shared token (query) | First text frame = JSON handle `{SessionId, StreamUrl, TokenValue, Target, region}`; later frames = terminal input to the plugin's stdin; plugin stdout goes back as frames. Close codes: 1008 unauthorized, 1003 bad/incomplete handle |
| POST | `:8091/forward` | header `x-broker-token` | Body `{sessionId, response, target, boxPort, localPort}`: start an `AWS-StartPortForwardingSession` to `boxPort`, bound to `127.0.0.1:<localPort>`; 200 when the port accepts connections, 502 if not up within ~10 s |
| any | `:8091/p/<sessionId>/<path>` | header `x-broker-token` (every `:8091` route; 401 otherwise) | Reverse-proxy to that session's forward. Replaces the box's `X-Frame-Options`/CSP with `Content-Security-Policy: frame-ancestors <BROKER_FRAME_ANCESTORS>` (customize/csadmin embed the UI; nobody else may frame it). Never forwards `x-broker-token`, platform cookies (`_oauth2_proxy*`, `pk_webui_*`) or oauth2-proxy/ALB identity headers to the box. 404 `no active forward` |

No OpenAPI spec (internal, edge-api is the only caller). edge-api's environment points at it with
`EDGE_SESSION_BROKER_WS_URL`, `EDGE_SESSION_BROKER_HTTP_URL` and `EDGE_SESSION_BROKER_TOKEN`.

### Messaging

N/A.

### Database

N/A: no database. Session registry, authorization and audit live in edge-api.

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `BROKER_TOKEN` | none | yes | Shared secret with edge-api, checked (constant-time) on the WebSocket and on every HTTP route. Shorter than 32 chars or unset → the process exits at startup. Staging: Secrets Manager `packiot/staging/app` key `edge_session_broker_token` → `.env` `EDGE_SESSION_BROKER_TOKEN` (deploy step), no compose fallback |
| `BROKER_FRAME_ANCESTORS` | `'self'` | no | CSP `frame-ancestors` source list sent on proxied box UIs (staging: `'self'` + the customize and csadmin origins) |
| `BROKER_PORT` | `8090` | no | WebSocket listener (`/shell`) |
| `BROKER_HTTP_PORT` | `8091` | no | HTTP listener (`/forward`, `/p/…`) |
| `BROKER_FORWARD_IDLE_MS` | `600000` (10 min) | no | Idle port-forwards are killed (checked every minute) |
| `AWS_REGION` | `us-east-1` | no | Region passed to the plugin when the handle has none |
| `SSM_ENDPOINT` | `https://ssm.<AWS_REGION>.amazonaws.com` | no | SSM endpoint passed to the plugin |

The SSM session response is passed to the plugin through the `AWS_SSM_START_SESSION_RESPONSE`
environment variable, never argv, so the token does not show in `ps`.

## Run locally

No dev slice (ADR-0060 D3 keeps SSM out of dev). To try the process alone:

```sh
cd services/edge-session-broker
npm install
BROKER_TOKEN=$(openssl rand -hex 32) node server.mjs   # needs session-manager-plugin on PATH to do anything useful
```

Tests: `npm test` (`node:test`, `server.test.mjs`: token enforcement on WS and HTTP, framing and request-header handling; no plugin or AWS needed). CI: `.github/workflows/node-services.yml`.

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`)
  rebuilds the image.
- **Logs:** plain lines prefixed `[broker]`: `starting plugin for session …`, `plugin exited <code>`,
  `rejected unauthenticated connection`, `forward failed: …`, `reaping idle forward …`.
- **Metrics/dashboards/alerts:** none.
- **Failure modes:**
  - Container exits at start with `FATAL BROKER_TOKEN must be set…` → the token is missing/short in `.env`.
  - Terminal closes at once with 1008, or web UI 401 → edge-api and the broker disagree on the token (or edge-api predates sending `x-broker-token` on `/p/`).
  - `plugin exited 255` (or similar) → the SSM handle expired or the box's SSM agent is offline.
  - Web UI 404 `no active forward` → the forward was reaped (idle) or its plugin exited; open it again.
  - `port-forward did not come up` (502) → the box port is closed or SSM could not open the forward.
- Restarting the container drops every live shell and forward.

## Code layout

| Path | What |
|---|---|
| `server.mjs` | WebSocket shell bridge, port-forward control, HTTP reverse proxy, idle reaper (`createBroker` exported for tests) |
| `server.test.mjs` | `node:test` suite |
| `Dockerfile` | debian-slim Node 22 (LTS) image with the arch-matched `session-manager-plugin` |
| `package.json`, `package-lock.json` | single dependency `ws` (locked; image uses `npm ci`) |

## Related docs

- [ADR-0057 — platform-mediated box access (SSM broker)](../../docs/adr/0057-platform-mediated-box-access-ssm-broker.md)
- [ADR-0060 — local development environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [edge-session-broker](https://wiki.packiot.app/understand/components/edge-session-broker/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
