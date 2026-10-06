# Service contracts — P0 inventory for the local dev environment

**ADR:** [ADR-0060](../adr/0060-local-development-environment-and-cpack-dev-seed.md) phase **P0** ·
**Date:** 2026-10-06 · **Code baseline:** `origin/staging @ 28356ccc` · **Scope:** app services only
(observability stack listed as a group; legacy paths out of dev scope).

Every input and output a service has, so each one can run alone in dev with seeded or faked inputs.

| File | What it holds |
|---|---|
| this file | provenance, service matrix, live evidence, findings, ADR implications |
| [`contracts/go-services.md`](contracts/go-services.md) | per-service code evidence: decoder family, stream-engine, workers, APIs (~900 citations) |
| [`contracts/ui-services.md`](contracts/ui-services.md) | per-service code evidence: edge-api, SPAs, Node-RED, Grafana, Superset |
| [`contracts/probes/live-contract-probe.sh`](contracts/probes/live-contract-probe.sh) | the read-only runtime probe, with how it was run |

## 0. Evidence standard

Two independent kinds of evidence, each labelled:

- **code**: a repo-rooted `path:line`. All ~940 citations in the two inventories were machine-checked to exist and be in
  range at `28356ccc`. 925 resolve to exactly one file, 17 are marked `⚠ambiguous[…]`, 3 `⚠not-in-repo`. A random
  12-citation sample was also content-checked by hand: claim matched source in every case.
- **live**: read-only observation of staging on 2026-10-06 (containers, RabbitMQ topology, per-container TCP
  connections from inside each network namespace, `pg_stat_activity`). Env **keys** only, never values.

Limit: every service except read-api connects to Postgres as the same superuser, so **which tables a service touches
can only be proven from code**. Live evidence proves *edges that exist* (a connection), never their absence: pools close
idle connections (edge-api had zero DB connections at probe time).

## 1. Provenance: is the code we cite the code that runs?

`/opt/packiot` on the host is **not** a git checkout, so provenance comes from deploy history. The last successful
`Deploy to Staging` run is `28356ccc` (2026-10-02 20:41 UTC), the baseline above. Deploys rebuild only what changed, so
for each running service we checked that **no merge on `staging`'s first-parent history touched its source after the
container was built**:

| Service (container) | Built (UTC) | Source | Merges landing after build |
|---|---|---|---|
| sparkplug-decoder, sparkplug-agent-shared, bispharma-twin | 10-01 16:48 | `services/sparkplug-decoder` | none |
| stream-engine | 10-02 18:08 | `services/stream-engine` | none |
| read-api | 09-30 13:16 | `services/read-api` | none |
| barcode-service, ingest-shim, oeecloud-fanout, edge-session-broker | 09-27 08:13 | `services/<name>` | none |
| operator-gateway | 10-01 18:43 | `services/operator-gateway` | none |
| legacy-replicator(-sbx) | 10-02 20:43 | `services/analytics-sync` | none |
| analytics-sync | 09-29 22:38 | `services/analytics-sync` | 3 (`15ce801c`, `d209c122`, `28356ccc`). **All only in `internal/replicate`, which its binary (`cmd/shadow-mirror`) does not import** (`go list -deps`) |
| edge-api, csadmin, customize, operator(-sbx/-bispharma) | 10-01 18:43 | submodules / `customize` | none |
| grafana | 09-25 22:05 | `grafana/` | none |

No Go service uses a `replace => ../` directive, so a service's directory is its whole build input (besides `go.sum`
modules). **Conclusion: the running code of all 20 built services equals `28356ccc`.**

## 2. Service matrix

Tier per ADR-0060 D2. **Live** = observed connection on 2026-10-06. PG = `packiot_analytics` unless noted.

| Service | Staging | Tier | Postgres | RabbitMQ | MQTT | Other in | External deps (dev must fake) |
|---|---|---|---|---|---|---|---|
| sparkplug-decoder | running | 2 | direct `10.10.10.89` (code; idle at probe) | publishes `oee` / `sparkplug.data.<tenant>` (**live**) | subscribes `spBv1.0/#` (**live**) | read-api `/internal/resolve-device` (inactive) | Secrets Manager |
| sparkplug-agent-shared | running | 1 | direct, `AGENT_REGISTER_DSN` (**live** ×2) | — | publishes (**live**) | HTTP ingest `:9104` from factory tees | inbound internet |
| sparkplug-agent-cpack, plc-sim, s7-softplc, s7-reader | **not running** (profiles) | 1 | — | — | publish | — | — |
| bispharma-twin | running, idle (flag) | 1 | — | — | (code) | — | — |
| ingest-shim | running | 1 | — | publishes `sparkplug.data.incoplast` (**live** conn) | — | HTTPS `:8444` | Secrets Manager, host TLS certs |
| oeecloud-fanout | running | 2 | — | consumes `sparkplug.data[.cpack]` → `sparkplug.data.sbxcpack` (**live**) | — | — | Secrets Manager |
| stream-engine | running | 2 | direct (**live** ×14, app name `oeecloud-worker*`) | **declares** `oee`/`-retry`/`-failed`; consumes `stream-engine-q[-tenant]` (**live**) | — | — | (Secrets Manager bypassed by `CREDS_SOURCE=env`) |
| mirror-worker-go | **not running** (retired profile) | — | — | — | — | — | Secrets Manager, legacy prod DB |
| analytics-sync | running, idle (`SHADOW_MIRROR_ENABLED=false`) | 2 | (code) | — | — | — | — |
| edge-api | running | 3 | pgbouncer, 2 pools (code; idle at probe) | `edge.commands` + `oee` topology, flag-off (no live conn) | — | → decoder `:9105`, session-broker `:8090/8091`, agent `:9103`, Superset | Cognito: verify **env-configurable** (`edge-api/src/shared/auth/bearer-jwt.config.ts:93,100`), admin API **not**; SSM; GitHub API |
| read-api | running | 3 | pgbouncer as `readapi_ro`, RLS (**live** ×5) | — | — | app-redis (**live**), hist-gateway | Cognito JWKS (**env-configurable**) |
| operator-gateway | running | 3 | direct (**live**, app name `operator-gateway`) | — | — | → edge-api `/api/*` (`x-api-key`) | host TLS certs |
| barcode-service | running | 3 | pgbouncer (**live**) | — | — | — | Cognito (issuer only), **Firebase (finding F1)** |
| edge-session-broker | running | 3 | — | — | — | — | AWS SSM data plane |
| front4 | (static build) | 4 | — | — | — | read-api, edge-api | Firebase `fbpackiot` hard-coded; legacy endpoints (F4) |
| csadmin, customize | running | 4 | — | — | — | edge-api (Bearer), read-api as `refdata-api:9104` | **Cognito via Amplify, not fakeable by env (F6)** |
| operator | running | 4 | — | — | — | edge-api (`x-api-key` injected by nginx), read-api (`QUERY_API_KEYS`) | Cognito via Amplify |
| barcode-app | running (image only, repo `barcode-scanner-v2`) | 4 | — | — | — | edge-api, read-api | — |
| grafana | running | 4 | `packiot_analytics` (uid `packiot-postgres-shadow`) | — | — | Prometheus, Loki, Tempo | — |
| superset (+worker) | running | 4 | **direct**: metadata DB `superset` as role `superset` (**live** ×4); analytics as `superset_ro` on schema `bi` (code) | — | — | superset-redis (**live**), hist-gateway | (OAuth off; DB auth on staging) |
| edge-nodered | **not running** (`legacy-sim`) | — | — | — | — | points at removed Hasura | Firebase, Secrets Manager |

Observability (alloy, prometheus, loki, promtail, tempo, exporters, cadvisor) is one group. Six services export traces
to `tempo:4317` (**live**: read-api via alloy, decoder, ingest-shim, operator-gateway, edge-api, stream-engine), so
dev must either run Tempo or tolerate an unset/unreachable `OTEL_EXPORTER_OTLP_ENDPOINT`.

## 3. Live evidence (2026-10-06)

**RabbitMQ**: exchanges `oee`, `oee-retry`, `oee-failed` (topic), `oee-unroutable` (fanout). Bindings on `oee`:

| Routing key | Queue | Consumers |
|---|---|---|
| `sparkplug.data` | `stream-engine-q`, `oeecloud-fanout-cpack-to-sbxcpack` | 1, 1 |
| `sparkplug.data.cpack` | `stream-engine-q-cpack`, `oeecloud-fanout-cpack-to-sbxcpack` | 1, 1 |
| `sparkplug.data.sbxcpack` | `stream-engine-q-sbxcpack` | 1 |
| `sparkplug.data.bispharmastaging` | `stream-engine-q-bispharmastaging` | 1 |
| (unroutable) | `oee-unroutable-q` | 0, **482 messages (F5)** |

Retry (`*-retry-30s`) and failed (`*-failed`) queues exist per tenant, all empty. All consumers `ack_required=true`.
AMQP clients by IP → container: decoder `.23`, ingest-shim `.29`, oeecloud-fanout `.41`, stream-engine `.20`. Nothing else
connects; edge-api's publisher is flag-off. The `edge.commands` exchange does not exist.

**MQTT**: only sparkplug-decoder (×2) and sparkplug-agent-shared (×2) hold connections to mosquitto. The broker log's
~2,870 connects per 24 h are its own healthcheck (`mosquitto_pub` every 30 s, `compose.staging.yml:488-489`).

**Postgres** (`pg_stat_activity`, grouped): from the app host (all SNAT'd to `10.10.0.228`): `oeecloud-worker` and
`oeecloud-worker-analytics` (= stream-engine, 14), `legacy-replicator-dst` (2), `operator-gateway` (1), `readapi_ro` (2),
`superset` role on DB `superset` (4), plus unnamed `postgres` sessions on `packiot_analytics` (5), `packiot`, `postgres`.
Most clients set no `application_name`, so attribution comes from the per-container socket view, not from Postgres.

## 4. Findings (defects and drift, not fixed in this PR)

| # | Finding | Evidence |
|---|---|---|
| F1 | **barcode-service still accepts Firebase tokens.** Compose sets `FIREBASE_PROJECT_ID: ""` "to disable" it, but `getenv` treats empty as unset, so it falls back to `fbpackiot` and registers the Firebase verifier | code: `compose.staging.yml:3039`, `services/barcode-service/cmd/barcode-service/main.go:74,216-221`, `services/barcode-service/cmd/barcode-service/auth_firebase.go:41`, `services/barcode-service/cmd/barcode-service/auth.go:69-70` |
| F2 | Grafana `19-factory-analysis` queries `FROM equipment_oee_ r`: `${grain}` suffix missing, table does not exist | code: `grafana/dashboards/library/19-factory-analysis.json:1124,1202` |
| F3 | csadmin/customize compose pass build arg `VITE_API_BASE_URL`, which no Dockerfile declares (no-op); SPAs read `VITE_EDGE_API_URL` | code: `compose.staging.yml:1549,1596` |
| F4 | front4 submodule pinned to `49408c1` (2026-07-23) builds against legacy endpoints (`api4.packiot.com`, `edge-dev.api4…`, `gqlpiot…`) | code: [`ui-services.md`](contracts/ui-services.md) §front4 |
| F5 | `oee-unroutable-q` holds 482 messages: something publishes to `oee` with a key no queue binds (candidate: ingest-shim's `sparkplug.data.incoplast`, **unproven**: confirming needs a requeue-peek) | live: §3 |
| F6 | No SPA can log in without a real IdP: Amplify gets pool id + client id only, no endpoint override; with Cognito off, csadmin falls back to Firebase | code: `csadmin/src/lib/cognito.ts:45-60`, `csadmin/src/lib/auth-token.ts:28-38` |
| F7 | stream-engine identifies itself to Postgres as `oeecloud-worker*` (legacy name) | live: §3 |
| F8 | `db/migrations/` (creates `core`, `config`, `gold`, `silver`, `bronze`, `serving`, `bi`) has **no runner**; `db-migrate` runs only `edge-api/migrations/` (knex, 56 files) | code: [`ui-services.md`](contracts/ui-services.md) §db-migrate; no CI/Makefile reference applies them |
| F9 | Grafana's default datasource points at `$POSTGRES_DB` = `packiot` (retired F1 DB); no panel uses it | code: [`ui-services.md`](contracts/ui-services.md) §grafana |

## 5. What this changes in ADR-0060

1. **Schema (D4):** F8 confirms the seed must ship the **full schema from `pg_dump --schema-only`**. Replaying
   migrations is not an option today. Verified live (read-only, 2026-10-06), the seed must also reproduce:
   - **PostgreSQL 15.17 + TimescaleDB 2.27.0** (pin the seed image to these).
   - **Database-level** settings on `packiot_analytics` (not role-level, so `pg_dump --create` carries them):
     `search_path = "$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public`
     and `track_functions = pl`. Most service SQL uses unqualified names and depends on this.
   - Login roles `readapi_ro`, `superset`, `superset_ro` (all non-superuser, `rolbypassrls = false`, so RLS
     applies) and `histgw_ro` (role setting `app.tenant_id = -1`). `pg_dump` does not dump roles: they need a
     separate `pg_dumpall --roles-only` step with passwords stripped.
2. **Auth (D3):** the mock OIDC issuer covers the **APIs** (read-api, edge-api verify; barcode-service issuer-only) but
   **not the SPAs** (F6). Needs a decision, see the PR.
3. **Secrets Manager (D3):** decoder, ingest-shim and oeecloud-fanout fetch secrets at boot and fail if they can't.
   Dev needs `CREDS_SOURCE=env` support in all of them, or a local Secrets Manager stand-in.
4. **RabbitMQ (D2):** only stream-engine declares the `oee` topology. Tier 0 must load it (definitions file) so a
   decoder-only slice still routes.
5. **Aliases:** nginx templates hard-code `refdata-api:9104`; dev must keep the network alias for read-api.
6. **Tracing:** six services export OTLP to `tempo:4317`; dev runs a no-op collector or leaves the endpoint unset
   (to verify per service in P1).

## 6. Unproven (searched, not confirmed)

- Values of `.env`-only settings (credentials, `CREDS_SOURCE`, feature flags, `EXTERNAL_*_CUSTOMER_ID`): keys observed
  live per container, values deliberately not read.
- Per-table access at runtime (shared superuser role, see §0).
- F5's routing key (needs a non-destructive `basic.get` with requeue; not done).
- barcode-app internals (source in another repo).
- The 17 `⚠ambiguous` and 3 `⚠not-in-repo` citations in the inventories.
