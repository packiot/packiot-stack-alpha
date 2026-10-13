# services/ — in-tree services

Every deployable program that lives in this repo (not in a submodule). Each directory has a README with the
same sections: what it does, where it fits, environments, interfaces, configuration, running it locally,
operating it, code layout and related docs.

| Service | Language | What | Runs on | README | OpenAPI spec |
|---|---|---|---|---|---|
| `analytics-sync` | Go | Replays operator actions (`user_logs`) into the analytics DB; two binaries: `analytics-sync` (idle on staging) and `legacy-replicator` (CPACK twin feed from the legacy DB) | staging | [README](./analytics-sync/README.md) | — |
| `barcode-service` | Go | Durable box-scan ingest with a server-authoritative, gapless label sequence per production order (ADR-0040) | staging | [README](./barcode-service/README.md) | [barcode-service](../docs/api/openapi/barcode-service.openapi.json) |
| `cognito-user-migration` | Node.js (AWS Lambda) | Cognito User Migration trigger: moves a Firebase user into the staging Cognito pool on first sign-in (ADR-0034) | staging (Lambda, Terraform) | [README](./cognito-user-migration/README.md) | — |
| `edge-session-broker` | Node.js | Runs AWS `session-manager-plugin` for edge-api: SSM shell (WebSocket) and on-box web UIs (HTTP proxy) of client boxes (ADR-0057) | staging | [README](./edge-session-broker/README.md) | — |
| `historian-gateway` | PostgreSQL + pg_duckdb (SQL, shell) | One SQL surface over hot analytics-DB rows (postgres_fdw) and the cold S3 Parquet historian (DuckDB) | staging (started by hand) | [README](./historian-gateway/README.md) | — |
| `ingest-shim` | Go | HTTPS → RabbitMQ ingress for a client's Node-RED tee: one envelope per request onto `oee` with publisher confirms | staging; prod compose | [README](./ingest-shim/README.md) | [ingest-shim](../docs/api/openapi/ingest-shim.openapi.json) |
| `mirror-worker-go` | Go | Retired legacy-production → staging mirror for CPACK (profile `legacy-comparator`, off since 2026-08-13) | staging (off) | [README](./mirror-worker-go/README.md) | — |
| `oeecloud-fanout` | Go | Clones one tenant's decoded stream into a sandbox tenant (staging: CPACK → SBXCPACK, enterprise 2000003) | staging | [README](./oeecloud-fanout/README.md) | — |
| `operator-gateway` | Go | HTTPS bridge: a client's own operator-app actions (Node-RED tee) → edge-api calls | staging; prod compose | [README](./operator-gateway/README.md) | [operator-gateway](../docs/api/openapi/operator-gateway.openapi.json) |
| `read-api` | Go | The read plane: tenant-scoped HTTP reads over the analytics DB for front4, operator, csadmin and integrations | staging; prod compose | [README](./read-api/README.md) | [read-api](../docs/api/openapi/read-api.openapi.json) |
| `sparkplug-decoder` | Go | SparkPlug B decoder (MQTT totalizers → increments → `oee` exchange); the same module builds the edge binaries (`sparkplug-agent`, PLC readers, simulators) | staging; prod compose; edge boxes | [README](./sparkplug-decoder/README.md) | [sparkplug-agent](../docs/api/openapi/sparkplug-agent.openapi.json), [onboard-api](../docs/api/openapi/onboard-api.openapi.json) |
| `stream-engine` | Go | The OEE engine: consumes decoded envelopes, writes Bronze/Silver, runs the jobs that compute Gold OEE, events, PO runtime, UNS and reports | staging; prod compose | [README](./stream-engine/README.md) | — |

"prod compose" means the service is defined in `compose.production.yml`; new-stack production is not promoted
yet, and the legacy platform serves production clients. OpenAPI specs are exported by `make openapi` into
[`docs/api/openapi/`](../docs/api/openapi/) and browsable at https://api.staging.packiot.app/docs/ (behind the
CS-Admin SSO).

## Data path at a glance (staging)

```text
 PLC ─SparkPlug B─> mosquitto ─> sparkplug-decoder ─> RabbitMQ `oee` ─> stream-engine ─> analytics DB
 client Node-RED tee ─HTTPS─> ingest-shim ─────────────┘   │                                │
                                                 oeecloud-fanout (CPACK → SBXCPACK)          │
 client operator app ─tee─> operator-gateway ─> edge-api ─────────────────────────> analytics DB
 legacy DB (packiot40) ─> legacy-replicator (analytics-sync module) ──────────────> analytics DB
 front4 / operator / csadmin <── read-api <── analytics DB (+ historian-gateway for cold history)
 scanners ─> barcode-service ─> analytics DB
```

## Shared conventions (Go services)

- **Build**: multi-stage Dockerfile, `golang:1.25-alpine` builder (`1.24` for mirror-worker-go) and a
  `gcr.io/distroless/static-debian12:nonroot` runtime. Staging builds every image on the app host during
  **Deploy to Staging** (`docker compose ... build`); there is no registry step for these services.
- **Health**: distroless has no shell, so each binary has a `--healthcheck` flag that probes its own health
  endpoint; compose healthchecks call it.
- **Credentials**: services with `internal/secrets/` read DB/RabbitMQ credentials from AWS Secrets Manager by
  default and from plain env with `CREDS_SOURCE=env` (what dev uses). Each README names the secrets it reads.
- **CI**: `.github/workflows/go-services.yml` runs `go vet`, `go test -race` and `go build` for analytics-sync,
  barcode-service, ingest-shim, mirror-worker-go, oeecloud-fanout, operator-gateway, read-api, sparkplug-decoder
  and stream-engine (plus stream-engine's golden tests). The dev slices
  (`dev-slices.yml`, required check "dev slices gate") boot and smoke-test the services that have a slice.
- **Deploy**: merge to `staging` → **Deploy to Staging** (`.github/workflows/deploy-staging.yml`). These are
  first-party directories, so the submodule auto-bump chain does not apply.

## Docs

- **How each service works:** the component pages under [Understand](https://wiki.packiot.app/understand/) in the wiki (SSO).
- **APIs:** [API reference](https://wiki.packiot.app/reference/api/) (generated from the OpenAPI specs in this repo) and the
  interactive [API portal](https://api.staging.packiot.app/docs/) (staging, SSO).
- **Everything linked in one table:** [Service catalog](https://wiki.packiot.app/reference/service-catalog/).
- **Adding a service:** [Add a service](https://wiki.packiot.app/build/develop/add-a-service/).
