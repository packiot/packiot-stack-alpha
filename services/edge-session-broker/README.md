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
| staging | `compose.staging.yml` · `edge-session-broker` · no profile | built from `Dockerfile` (`node:18-bookworm-slim` + `session-manager-plugin` .deb, runs as `node`) | in-network 8090 (WS), 8091 (HTTP); no host publish | TCP connect to 8090 |
| production | not in `compose.production.yml` | — | — | — |

## Interfaces

### HTTP

| Method | Path / port | Auth | What |
|---|---|---|---|
| WS | `:8090/shell?token=<broker token>` | shared token (query) | First text frame = JSON handle `{SessionId, StreamUrl, TokenValue, Target, region}`; later frames = terminal input to the plugin's stdin; plugin stdout goes back as frames. Close codes: 1008 unauthorized, 1003 bad/incomplete handle |
| POST | `:8091/forward` | header `x-broker-token` | Body `{sessionId, response, target, boxPort, localPort}`: start an `AWS-StartPortForwardingSession` to `boxPort`, bound to `127.0.0.1:<localPort>`; 200 when the port accepts connections, 502 if not up within ~10 s |
| any | `:8091/p/<sessionId>/<path>` | none (in-network only) | Reverse-proxy to that session's forward; strips `X-Frame-Options` and `Content-Security-Policy` so csadmin can embed the UI; 404 `no active forward` |

No OpenAPI spec (internal, edge-api is the only caller). edge-api's environment points at it with
`EDGE_SESSION_BROKER_WS_URL`, `EDGE_SESSION_BROKER_HTTP_URL` and `EDGE_SESSION_BROKER_TOKEN`.

### Messaging

N/A.

### Database

N/A: no database. Session registry, authorization and audit live in edge-api.

## Configuration

| Name | Default | Required | Effect |
|---|---|---|---|
| `BROKER_TOKEN` | `""` | yes | Shared secret with edge-api. Empty rejects every WebSocket. Staging: `EDGE_SESSION_BROKER_TOKEN` from `.env` (compose has a fixed fallback if unset) |
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
BROKER_TOKEN=x node server.mjs      # needs session-manager-plugin on PATH to do anything useful
```

There are no tests and no CI workflow for this service.

## Operating it

- **Deploy:** merge to `staging` → "Deploy to Staging" (`.github/workflows/deploy-staging.yml`)
  rebuilds the image.
- **Logs:** plain lines prefixed `[broker]`: `starting plugin for session …`, `plugin exited <code>`,
  `rejected unauthenticated connection`, `forward failed: …`, `reaping idle forward …`.
- **Metrics/dashboards/alerts:** none.
- **Failure modes:**
  - Terminal closes at once with 1008 → edge-api and the broker disagree on the token.
  - `plugin exited 255` (or similar) → the SSM handle expired or the box's SSM agent is offline.
  - Web UI 404 `no active forward` → the forward was reaped (idle) or its plugin exited; open it again.
  - `port-forward did not come up` (502) → the box port is closed or SSM could not open the forward.
- Restarting the container drops every live shell and forward.

## Code layout

| Path | What |
|---|---|
| `server.mjs` | WebSocket shell bridge, port-forward control, HTTP reverse proxy, idle reaper |
| `Dockerfile` | debian-slim Node 18 image with the arch-matched `session-manager-plugin` |
| `package.json` | single dependency `ws` |

## Related docs

- [ADR-0057 — platform-mediated box access (SSM broker)](../../docs/adr/0057-platform-mediated-box-access-ssm-broker.md)
- [ADR-0060 — local development environment](../../docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)

## Docs

| What | Where |
|---|---|
| How it works (wiki) | [edge-session-broker](https://wiki.packiot.app/understand/components/edge-session-broker/) |
| Every service, linked | [Service catalog](https://wiki.packiot.app/reference/service-catalog/) |
