---
title: API reference
layer: 4
owner_area: serving
last_verified: 2026-10-13
---
# API reference

> **Reference · generated.** One page per API, generated at wiki build time from the OpenAPI
> 3.x documents the services publish. Up: [Reference](../index.md)

| API | What it is for | Who calls it | Reference | Service docs |
|---|---|---|---|---|
| **edge-api** | Control plane: tenants, sites, areas, equipment, shifts, production orders, downtimes, onboarding, box ops | front4, CS Admin, Customize, operator app, factory boxes | [edge-api](edge-api.md) | [component](../../understand/components/edge-api.md) |
| **read-api** | Read plane: operator reads, dashboards' query API, reference data, historian series, client integrations | front4, operator app, client systems | [read-api](read-api.md) | [component](../../understand/components/read-api.md) |
| **barcode-service** | Box-scan ingest with gapless label sequences, live scan stream | Barcode app | [barcode-service](barcode-service.md) | [component](../../understand/components/barcode-service.md) |
| **sparkplug-agent** | HTTP tag and counter ingest from a factory's own systems | Factory tees, client systems | [sparkplug-agent](sparkplug-agent.md) | [component](../../understand/components/sparkplug-agent.md) |
| **onboard API** | Generate and simulate a client's tag descriptor during onboarding | CS Admin | [onboard-api](onboard-api.md) | [component](../../understand/components/sparkplug-decoder.md) |
| **ingest-shim** | Sparkplug payloads over HTTP for clients that can't speak MQTT | Client Node-RED tees | [ingest-shim](ingest-shim.md) | [component](../../understand/components/ingest-shim-and-fanout.md) |
| **operator-gateway** | Operator actions (downtimes, production orders) from a client's own system | Client Node-RED tees | [operator-gateway](operator-gateway.md) | [component](../../understand/components/operator-gateway.md) |

## Three ways to read the same contract

| Where | Best for |
|---|---|
| These pages | Searching, reading, linking from other docs |
| [API portal](https://api.staging.packiot.app/docs/) (staging, SSO, read-only Swagger UI) | Browsing interactively; all APIs in one dropdown |
| `docs/api/openapi/<api>.openapi.json` in the stack repo | Code generation, diffing, tooling |

## How the contract stays true

Every API's spec is checked in CI against the code that serves it, so these pages can't
silently drift:

- **Route ↔ spec parity:** a route without a spec entry, or a spec path that no route
  serves, fails the service's tests.
- **Completeness:** every operation needs an id, summary, description, tag, a success
  response with an example, and a description for every error, parameter and field.
- **Export check:** `make openapi` (Go services) and `npm run openapi:export` (edge-api)
  write the committed JSON; CI fails if it is stale.

To add or change an endpoint, follow [Add an API endpoint](../../build/develop/add-an-api-endpoint.md).

## Authentication at a glance

| API | Credential |
|---|---|
| edge-api | `x-api-key` header (tenant key), or a Cognito `Bearer` token; CS-Admin-only routes need a Cognito user in the `cs-admin` group |
| read-api | `X-Api-Key` or Cognito `Bearer`; client-integration routes use their own per-client key |
| barcode-service | Cognito `Bearer` (tenant from the token) |
| sparkplug-agent, ingest-shim, operator-gateway | `X-Ingest-Key` header |
| onboard API | Static bearer key (internal) |

The tenant always comes from the **credential**, never from a client-supplied id. See
[Tenancy & security](../../understand/architecture/tenancy-and-security.md).
