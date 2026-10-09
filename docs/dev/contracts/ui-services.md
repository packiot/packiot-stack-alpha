# P0 static contract inventory — non-Go app services (TS / SPA / Node-RED / Grafana / Superset)

> **Citation format.** Every `path:line` is repo-rooted and was machine-checked on 2026-10-06 to exist and be in range at `28356ccc`. Citations the checker could not pin to one file are marked `⚠ambiguous[candidates]`; files not in this repo are marked `⚠not-in-repo`. Nothing was silently guessed. Live (runtime) evidence lives in [`../contracts.md`](../contracts.md) §3.


Checkout: `origin/staging @ 28356ccc` (branch `docs/p0-dev-contracts`), submodules at pinned commits:

| submodule | pinned commit (date) | cite |
|---|---|---|
| edge-api | `3ea501b` (2026-10-01) | `git submodule status` |
| csadmin | `bc71804` (2026-10-01) | idem |
| operator | `bdd2f7f` (2026-09-30) | idem |
| edge-node-red | `8816e80` (branch `chore/t244-bootstrap-parity`) | idem |
| front4 | `49408c1` (**2026-07-23**, PR #217) — see front4 §0 staleness flag | idem |

Method: grep/AST-free static scan of source (node_modules, dist, coverage, tests/spec excluded). SQL table lists produced by a
regex scanner (`FROM|JOIN|INSERT INTO|UPDATE … SET|DELETE FROM`) over `.ts` source, then hand-filtered for CTE aliases/comment noise.
All paths are relative to the repo root unless prefixed by a submodule name (e.g. `edge-api/src/...`).

Cross-cutting facts used by many sections:

- **Box `.env` is generated, not committed.** `terraform/staging/user_data/app_init.sh:228-345` writes it from AWS Secrets Manager
  (`app_init.sh:71⚠ambiguous[terraform/production/user_data/app_init.sh|terraform/staging/user_data/app_init.sh]-72` `aws secretsmanager get-secret-value`, secrets `databaseCredentials` `:171`, `packiot/staging/agent-ingest` `:158`, etc.).
  Keys it writes include `POSTGRES_HOST=${db_private_ip}` (`:233`), `POSTGRES_DB=${db_name}` (`:241`), `POSTGRES_USER=${db_user}` (`:240`),
  `RABBITMQ_USER/PASSWORD/URL` (`:271-273`), `EDGE_API_KEY` (`:252`), `GITHUB_DISPATCH_TOKEN` (`:254`), `ONBOARD_API_KEY` (`:256`),
  `OPERATOR_EDGE_API_KEY` (`:259`), `COGNITO_USER_POOL_ID/COGNITO_CS_ADMIN_GROUP/EDGE_API_COGNITO_AUTH_ENABLED` (`:306-308`),
  `SUPERSET_*` (`:316-345`).
- `db_name` default = `"packiot"` (`terraform/staging/variables.tf:122`), `db_user` default = `"postgres"` (`variables.tf:127`) ⇒
  **`.env` `POSTGRES_DB=packiot` (the retired F1 DB) and `POSTGRES_USER=postgres` (superuser)** unless a service overrides it in compose.
- Host nginx vhost → port map: `terraform/staging/variables.tf:70-79` (`grafana=3000`, `barcode=8092`, `operator=8083`, `csadmin=8084`,
  `customize=8086`); per-vhost oauth2-proxy tier `variables.tf:104-114` (`grafana/barcode = "csadmin"`, `operator = "any"`,
  `csadmin/customize = "none-originverify"`). Generic staff-tier vhost template `terraform/staging/user_data/nginx_setup.sh:157-186`
  (`auth_request /oauth2/auth-csadmin` → oauth2-proxy `127.0.0.1:4180`, `nginx_setup.sh:87⚠ambiguous[terraform/production/user_data/nginx_setup.sh|terraform/staging/user_data/nginx_setup.sh]-113`).
- read-api is reachable under the legacy DNS alias **`refdata-api`** (`compose.staging.yml:2983` `aliases: ["refdata-api"]`, ip
  `172.18.0.26` `:2982`); operator-gateway under alias `operator-adapter` (`compose.staging.yml:3123`). SPA nginx templates still use
  `refdata-api:9104` — a dev compose must provide that alias.
- `packiot_analytics` default `search_path` is `"$user", gold, silver, bronze, public` (stated in `edge-api/knexfile.ts:21-27`
  comment; the migration that sets it is in `db/migrations`, not verified here). **Every unqualified table name below resolves through
  that path** — which schema a given unqualified name lands in is UNPROVEN statically.

---

## db-migrate (edge-api `migrate` target)

1. **Build**: `compose.staging.yml:516-531` — `build.context: ./edge-api`, `target: migrate`, `env_file: [.env]`, `restart: "no"`,
   ip `172.18.0.16`. Dockerfile stage `edge-api/Dockerfile:25-26`:
   `FROM development AS migrate` / `ENTRYPOINT ["npx","knex","--knexfile","knexfile.ts","migrate:latest","--env","development"]`
   (`development` = `deps` + full source, `Dockerfile:5-16`, node:18-alpine).
2. **Env**: knex connection from `POSTGRES_HOST/PORT/DB/USER/PASSWORD` (`edge-api/knexfile.ts:8-14`; `dotenv-flow/config` `:2`).
   Staging: `POSTGRES_PORT=5432`, `POSTGRES_USER=${POSTGRES_USER}`, `POSTGRES_DB=packiot_analytics` (`compose.staging.yml:522-524`);
   **`POSTGRES_HOST` is NOT set in compose** → comes from `.env` = the DB EC2 private IP (direct, not pgbouncer) (`terraform/staging/user_data/app_init.sh:233`).
   `POSTGRES_PASSWORD` from `.env` (`terraform/staging/user_data/app_init.sh:242`). Pool min 2 / max 10 (`edge-api/knexfile.ts:15-18`).
3. **What it runs**: knex default migrations directory `./migrations` (no `directory` key in `edge-api/knexfile.ts:19-31`) ⇒
   `edge-api/migrations/*.ts`, **56 files**, `20230816170559_create_equipment_values.ts` … `20260827000001_client_descriptors_add_deployed_status.ts`.
   Ledger pinned to `public.knex_migrations` (`edge-api/knexfile.ts:20,30`). Seeds dir `./src/seeds` (`edge-api/knexfile.ts:32-34`) — not run by `migrate:latest`.
   Objects created/altered (grep of migrations): base tables `equipment_values, equipments, enterprises, clients, sites, areas,
   product_family, products, user_roles, users, production_orders, production_orders_runtime, equipment_events (public.), manual events,
   user_logs, labels, sample_boxes, scanned_boxes, shifts, pages, packml_register, uns_equipment_current_metrics, idempotency_keys,
   client_descriptors, translations, tenant_translations, language_packs, capture_observations, makes, mirror_replay_dlq`; schemas
   `shadow_go_port`, `shadow_diff`; function `public.piot_trig_equipment_events_update_prev` (ALTER).
   **It does NOT run the stack's own `db/migrations/` (159 entries per ADR §1.2)**, which own `core.*`, `config.*`, `gold.*`, `silver.*`,
   `bronze.*`, `serving.*`, `ops.*`. No CI/compose step that applies `db/migrations/` was found (searched `.github/workflows/*.yml`,
   `scripts/`, `Makefile` for `db/migrations`: only sandbox scripts reference specific dirs).
   Extra SQL outside knex: `edge-api/db/backfill/2026-08-26-lead-machine-defaults.sql` (not wired to any target).
4. **PostgreSQL**: role `postgres` (superuser, `variables.tf:127`) direct to the DB host; DDL across `public`, `shadow_go_port`, `shadow_diff`.
5. **MQ/Redis**: none.
6. **Auth**: n/a.
7. **External**: `npm install` at image build (`Dockerfile:10`) → npm registry.
8. **Health/ports**: one-shot; `edge-api` waits on `service_completed_successfully` (`compose.staging.yml:694-696`).
9. **UNPROVEN**: whether replaying the 56 knex migrations on an empty DB builds the tables edge-api queries (many queried tables —
   `core.equipments`, `config.equipment_out_of_service`, `gold.*`, `equipment_oee_*`, `equipment_live_metrics`, `box_scans`, `po_box_counter`
   — are not created here); which runner applies `db/migrations/` on staging.

---

## edge-api

1. **Build / serving**: `compose.staging.yml:534-703`. `build.context: ./edge-api`, `target: production` (`:535-537`);
   Dockerfile `edge-api/Dockerfile:30-47` (node:18-alpine, `npm ci --omit=dev`, `CMD node dist/main`, `EXPOSE 8080`).
   Listens on hard-coded `8080` (`edge-api/src/main.ts:302` `app.listen(8080)`). Host port `127.0.0.1:8080:8080` (`compose.staging.yml:689-690`),
   ip `172.18.0.3`. Public vhost `api.$STAGING_DOMAIN` → `127.0.0.1:8080` (`terraform/staging/user_data/nginx_setup.sh:234-280`). depends_on db-migrate, pgbouncer,
   edge-session-broker (`compose.staging.yml:694-700`). Swagger at `packiot/docs` (`edge-api/src/main.ts:151`).
   ~141 controller files; route prefixes all under `/api/*` plus `/session` and `/health` (grep `@Controller(`).
2. **Env vars** (all read via `process.env`; first citation shown). Staging values from `compose.staging.yml` unless noted `(.env)`.

| var | read at | default in code | staging value | flag |
|---|---|---|---|---|
| POSTGRES_HOST/PORT/DB/USER/PASSWORD | `edge-api/src/providers/database/postgres-adapter.ts:28` | none | `pgbouncer`/`5432`/`packiot_analytics`/`${POSTGRES_USER}` (`:610-613`), pw (.env) | |
| POSTGRES_ANALYTICS_URL | `edge-api/src/providers/database/analytics-postgres-adapter.ts:32` | falls back to primary URL | `postgresql://…@pgbouncer:5432/packiot_analytics` (`:622`) | |
| RABBITMQ_URL / HOST / PORT / USER / PASSWORD / VHOST | `edge-api/src/providers/messaging/broker-url.ts:13-18` | `localhost:5672 guest/guest` | not in compose env; `.env` `RABBITMQ_URL=amqp://…@rabbitmq:5672` (`terraform/staging/user_data/app_init.sh:273`) | |
| COMMANDS_ENABLED / COMMANDS_ALLOWED | `edge-api/src/usecases/commands/commands.service.ts:52,56` | `false` | not set (searched compose + app_init) | |
| EDGE_API_INGEST_TOPOLOGY_PROVISION_ENABLED | `edge-api/src/providers/messaging/rabbitmq-tenant-topology.ts:58` | off | not set | |
| INGEST_SOURCE/RETRY/FAILED_EXCHANGE, INGEST_WORKER_QUEUE, INGEST_RETRY_TTL_MS | `edge-api/src/providers/messaging/rabbitmq-tenant-topology.ts:66-71` | `oee`,`oee-retry`,`oee-failed`,`oeecloud-worker-q`,`30000` | not set | |
| AUTH_BEARER_ENABLED | `edge-api/src/shared/auth/bearer-jwt.config.ts:112` | | `"true"` (`:646`) | |
| COGNITO_ISSUER / COGNITO_CLIENT_ID / COGNITO_JWKS_URI | `edge-api/src/shared/auth/bearer-jwt.config.ts:93,94,100` | JWKS = `<issuer>/.well-known/jwks.json` | `https://cognito-idp.us-east-1.amazonaws.com/us-east-1_0T9t1sTwt` / `2ckuoa0ov598rdpdn3uv039h6e` (`:647-648`) | **AWS Cognito** |
| EDGE_API_COGNITO_AUTH_ENABLED / EDGE_API_CS_ADMIN_GROUP | `edge-api/src/shared/auth/bearer-jwt.config.ts:118-119` | off / `cs-admin` | `"true"` (`:655`) | |
| COGNITO_USER_POOL_ID / COGNITO_CS_ADMIN_GROUP | `edge-api/src/usecases/cognito-users/shared/cognito-users.config.ts:40,42` | `''` → 503 | `us-east-1_0T9t1sTwt` / `cs-admin` (`:653-654`) | **AWS Cognito admin API** |
| AWS_REGION | `edge-api/src/usecases/edge-ssm/shared/edge-ssm.config.ts:225`, `edge-api/src/usecases/cognito-users/shared/cognito-users.config.ts:39` | `us-east-1` | `"us-east-1"` (`:564`) | **AWS** |
| SSM_* (≈30 vars: HYBRID_INSTANCE_ROLE, SHARED_AGENT_INSTANCE_ID/DIR/…, EDGE_INGEST_URL/KEY, SESSION_*, ONPREM_*) | `edge-api/src/usecases/edge-ssm/shared/edge-ssm.config.ts:228-304` | `SSM_EDGE_INGEST_URL` defaults to **`https://ingest.prod.packiot.app`** (`edge-api/src/usecases/edge-ssm/shared/edge-ssm.config.ts:63`) | `SSM_HYBRID_INSTANCE_ROLE`, `SSM_SHARED_AGENT_INSTANCE_ID=i-06c9547a2c7091ab7`, `SSM_SHARED_AGENT_DIR`, `SSM_EDGE_INGEST_URL=https://ingest.staging.packiot.app:8449/v1/tags`, `SSM_EDGE_INGEST_KEY` (`:565,581-582,592-593`) | **AWS SSM**, prod-default URL |
| EDGE_SESSION_BROKER_WS_URL / HTTP_URL / TOKEN | `edge-api/src/usecases/edge-ssm/shared/edge-ssm.config.ts:307-309` | empty ⇒ 503 | `ws://edge-session-broker:8090/shell`, `http://edge-session-broker:8091`, `${EDGE_SESSION_BROKER_TOKEN:-esb-internal-staging}` (`:686-688`) | |
| ONBOARD_GENERATE_URL / ONBOARD_SIMULATE_URL / ONBOARD_API_KEY / ONBOARD_DEFAULT_PRODUCTION_SPEED / EDGE_API_ONBOARDING_ENABLED | `edge-api/src/usecases/onboarding/shared/onboarding.config.ts:51-62` | simulate = generate with `/generate`→`/simulate`; speed 60 | `http://sparkplug-decoder:9105/v1/onboard/generate`, `${ONBOARD_API_KEY}`, enabled `"true"` (`:656,677-678`) | |
| EDGE_API_TEARDOWN_ENABLED / TEARDOWN_PROTECTED_ENTERPRISES / TEARDOWN_INGEST_SECURITY_GROUP_ID | `edge-api/src/usecases/teardown/shared/teardown.config.ts:63-70` | | enabled `"true"` (`:673`) | SG id ⇒ AWS EC2 (UNPROVEN usage) |
| EDGE_API_PROMOTE_ENABLED / _APPLY_ENABLED / PROMOTE_SOURCE_ENV | `edge-api/src/usecases/promote/shared/promote.config.ts:30-31`, `edge-api/src/usecases/promote/extract/extract.service.ts:50` | off | not set | |
| OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED / OPERATOR_SUPERADMIN_ALLOWLIST | `edge-api/src/shared/auth/operator-superadmin.config.ts:37,53` | | `"true"` (`:667`) | |
| PO_STALENESS_GATE_ENABLED / PO_STALENESS_GATE_ENTERPRISES | `edge-api/src/usecases/production-orders/shared/po-staleness-gate.ts:162,173` (names `:12,27`) | `false` | `"true"`, `"3,4"` (`:602-603`) | |
| SUPERSET_BASE_URL / SUPERSET_GUESTTOKEN_ADMIN_USER / _PASSWORD / SUPERSET_OEE_DASHBOARD_UUID / _PT | `edge-api/src/usecases/superset-embed/superset-embed.config.ts:49-63` | missing ⇒ 503 per request | (.env) `SUPERSET_BASE_URL=http://172.18.0.42:8088` (`terraform/staging/user_data/app_init.sh:334`), UUIDs `:335,345` | |
| GITHUB_DISPATCH_TOKEN / _REPO / _REF / _WORKFLOW / GITHUB_DEPLOY_WORKFLOW | `edge-api/src/usecases/edge-bundle/shared/edge-bundle.config.ts:44-52` | repo `packiot/packiot-stack-alpha`, ref `production` | token from .env (`terraform/staging/user_data/app_init.sh:254`) | **GitHub API** |
| POWERBI_* (8 vars) | `edge-api/src/usecases/integrations/powerbi/shared/powerbi-config.ts:60-72` | `https://api.powerbi.com/`, `login.microsoftonline.com` (`:51-53`) | not set | **Microsoft PowerBI/Entra** |
| CORS_ALLOWED_ORIGINS | `edge-api/src/main.ts:81` | 9 hard-coded origins (`edge-api/src/main.ts:63-79`) | not set | |
| OTEL_EXPORTER_OTLP_ENDPOINT | `edge-api/src/tracing.ts:18` | | `http://tempo:4317`, `OTEL_SERVICE_NAME=edge-api` (`:608-609`) | |
| REDIS_URL | — none found (searched `ioredis`, `from 'redis'`, `createClient`, `REDIS` in `edge-api/src`) | | `redis://app-redis:6379/0` (`:632`, comment says not consumed) | |
| NODE_ENV, NEW_RELIC_* | Dockerfile `:35-37` | | `:550-552` | |

3. **Backend calls (outbound HTTP)**:
   - Superset: `POST ${SUPERSET_BASE_URL}/api/v1/security/login` and `/api/v1/security/guest_token/` (`edge-api/src/usecases/superset-embed/superset-embed.service.ts:114,63`).
   - sparkplug-decoder onboard server: `fetch(generateUrl)` / `fetch(simulateUrl)` (`edge-api/src/usecases/onboarding/shared/onboarding-generate.client.ts:71`, `edge-api/src/usecases/onboarding/shared/onboarding-simulate.client.ts:73`).
   - edge-session-broker: `http.request` to `${brokerHttpUrl}/forward` (`edge-api/src/usecases/edge-ssm/shared/edge-ssm.service.ts:2955-2959,3109`) + ws relay.
   - sparkplug-agent colocated services: `http://sparkplug-agent[-x]:9103/healthz|/metrics` (`edge-api/src/usecases/plc-status/agent-health/agent-health.service.ts:78,94-97`), `/probe` (`edge-api/src/usecases/plc-status/plc-probe/plc-probe.service.ts:229-235`).
   - GitHub REST: `https://api.github.com/repos/...` (`edge-api/src/usecases/edge-bundle/generate-bundle/generate-bundle.service.ts:74`, list-runs `:79`, download `edge-api/src/usecases/edge-bundle/download-bundle/download-bundle.service.ts:78,124`, deploy `edge-api/src/usecases/edge-bundle/deploy-bundle/deploy-bundle.service.ts:82`).
   - PowerBI: `edge-api/src/usecases/integrations/powerbi/shared/fetch-powerbi-http-client.ts:20-43`, `edge-api/src/usecases/integrations/powerbi/shared/powerbi-client.service.ts:190` (login.microsoftonline.com).
   - AWS SDK v3: `@aws-sdk/client-ssm` (`edge-api/src/usecases/edge-ssm/shared/edge-ssm.config.ts:1`), `@aws-sdk/client-cognito-identity-provider` (`edge-api/src/usecases/cognito-users/shared/cognito-users.config.ts:1`); region-only clients, default cred chain (`edge-api/src/usecases/cognito-users/shared/cognito-users.config.ts:44`).
4. **PostgreSQL**:
   - Connections: primary pg-promise pool `PostgresAdapter` (URL built from POSTGRES_* , `edge-api/src/providers/database/postgres-adapter.ts:28`) and `AnalyticsPostgresAdapter`
     (`POSTGRES_ANALYTICS_URL` else primary, `edge-api/src/providers/database/analytics-postgres-adapter.ts:32-36`); used by get-pending-downtimes, get-justified-downtimes,
     plc-status, entities-tree, justify modules (`edge-api/src/usecases/downtimes/get-pending-downtimes/get-pending-downtimes.module.ts:21-22`, etc.).
     **On staging both pools point at `packiot_analytics` via pgbouncer** (`compose.staging.yml:612-613,622`); the compose comment at `:615-619`
     describing a separate F1 `packiot` DB is stale relative to `POSTGRES_DB: packiot_analytics` (`:612`).
   - Role: `${POSTGRES_USER}` = `postgres` (`variables.tf:127`).
   - **WRITTEN** (INSERT/UPDATE/DELETE; scanner, first cite):
     `areas` (`edge-api/src/data/DAO/areas/areas-dao.ts:28`), `sites` (`edge-api/src/data/DAO/sites/sites-dao.ts:30`), `enterprises` (`edge-api/src/data/DAO/enterprises/enterprises-dao.ts:69`),
     `equipments` (`edge-api/src/data/DAO/equipments/equipments-dao.ts:183`), `packml_register` (`edge-api/src/data/DAO/packml-register/packml-register-dao.ts:89`),
     `shifts` (`edge-api/src/data/DAO/shifts/shifts-dao.ts:36`), `shift_hours` (`edge-api/src/data/DAO/shift-hours/shift-hours-dao.ts:20`), `teams` (`edge-api/src/data/DAO/teams/teams-dao.ts:19`),
     `users` (`edge-api/src/data/DAO/users/users-dao.ts:53`, `edge-api/src/data/DAO/cognito-users/cognito-users-dao.ts:31`), `user_roles` (`edge-api/src/data/DAO/user-roles/user-roles-dao.ts:44`),
     `language_packs` (`edge-api/src/data/DAO/language-packs/language-packs-dao.ts:55`), `translations` (`edge-api/src/data/DAO/i18n/i18n-dao.ts:52`), `tenant_translations` (`edge-api/src/data/DAO/i18n/i18n-dao.ts:77`),
     `production_orders` (`edge-api/src/data/DAO/production-orders/production-orders-dao.ts:104`), `production_orders_runtime` (`edge-api/src/data/DAO/production-orders/production-orders-dao.ts:68`),
     `equipment_events` (`edge-api/src/data/DAO/downtimes/downtimes-dao.ts:263`), `equipment_events_man` (`edge-api/src/data/DAO/manualDowntimes/manual-downtimes-dao.ts:131`),
     `box_scans` (`edge-api/src/data/DAO/scanned-boxes/scanned-boxes-dao.ts:191`), `po_box_counter` (`edge-api/src/data/DAO/scanned-boxes/scanned-boxes-dao.ts:217`),
     `sample_boxes` (`edge-api/src/data/DAO/samples/samples-dao.ts:38`), `scanned_boxes` (`edge-api/src/data/DAO/samples/samples-dao.ts:60`),
     `clients`, `products`, `product_families`, `_po_import_stage` (`edge-api/src/data/DAO/po-import/po-import-dao.ts:118-153`),
     `client_descriptors` (`edge-api/src/data/DAO/client-descriptor/client-descriptor-dao.ts:50`), `capture_observations` (`edge-api/src/data/DAO/teardown/teardown-dao.ts:165`),
     **`config.equipment_out_of_service`** (`edge-api/src/data/DAO/out-of-service/out-of-service-dao.ts:93`),
     **`gold.equipment_oee_hourly`, `gold.equipment_oee_shift`** (`recalc_needed=true`, `edge-api/src/data/DAO/out-of-service/out-of-service-dao.ts:182,190`),
     `idempotency_keys` (`edge-api/src/interceptors/idempotency.interceptor.ts:84`), `user_logs` (audit, `edge-api/src/repositories/user-logs.repository.ts:14`).
     Via stored functions: `h_piot_set_production_target(...)`, `h_piot_set_scrap_target(...)` (`edge-api/src/data/DAO/production-targets/production-targets-dao.ts:90,108`).
     Teardown hard/soft deletes across `equipment_values, equipment_live_metrics, equipment_live_shift, equipment_live_day, equipment_oee_shift,
     equipment_oee_hourly, equipment_oee_daily, equipment_oee_weekly, equipment_oee_monthly` (`edge-api/src/data/DAO/teardown/teardown-dao.ts:24-34,138`) and
     `equipments/areas/sites/enterprises` (`edge-api/src/data/DAO/teardown/teardown-dao.ts:281-294`).
   - **READ only** (beyond the above): `equipment_values` (`edge-api/src/data/DAO/plc-status/plc-status-dao.ts:71`), `equipment_live_metrics` (`edge-api/src/data/DAO/plc-status/plc-status-dao.ts:63`),
     **`core.equipments`** (`edge-api/src/data/DAO/out-of-service/out-of-service-dao.ts:74`), **`silver.equipment_values`** (`edge-api/src/data/DAO/onboarding-readiness/onboarding-readiness-dao.ts:181`),
     **`silver.data_quality_event`** (`edge-api/src/data/DAO/onboarding-readiness/onboarding-readiness-dao.ts:118`), **`serving.equipment_scrap_capability(...)`** (function, probed via
     `to_regprocedure`, `edge-api/src/data/DAO/onboarding-readiness/onboarding-readiness-dao.ts:223,231`), `v_entities_per_user_role_operator` (view, `edge-api/src/data/DAO/session/session-dao.ts:30`),
     `pages` (`edge-api/src/data/DAO/pages/pages-dao.ts:20`), `production_information` (`edge-api/src/data/DAO/production-information/production-information-dao.ts:13`),
     `production_targets` (`edge-api/src/data/DAO/production-targets/production-targets-dao.ts:57`), `labels`/`scanned_boxes` (`edge-api/src/data/DAO/labels/labels-dao.ts:16`),
     `information_schema.columns` (`edge-api/src/data/DAO/downtimes/downtimes-dao.ts:353`), `pg_tables` (`edge-api/src/data/DAO/teardown/teardown-dao.ts:53`).
     Tenant fence reads `production_orders, equipments, equipment_events, equipment_events_man, user_roles, enterprises`
     (`edge-api/src/shared/tenant-fence/tenant-fence.ts:108-232`).
   - **Dynamic SQL (flag)**: table name interpolation in `edge-api/src/shared/tenant-fence/tenant-fence.ts:256` (`FROM ${table}` — allowlist `sites, areas, shifts, shift_hours,
     packml_register` at `:263-309`); `edge-api/src/data/DAO/production-targets/production-targets-dao.ts:126,147` (`INSERT INTO ${table}` from `RUNTIME_TABLE` = `equipment_oee_daily|weekly|monthly`,
     `:17-21`); `edge-api/src/data/DAO/teardown/teardown-dao.ts:108,138,281-282` (`${table}` from the constant lists); column-name interpolation `SET ${col}=…` in
     `edge-api/src/data/DAO/sites/sites-dao.ts:85`, `edge-api/src/data/DAO/packml-register/packml-register-dao.ts:134`, `edge-api/src/data/DAO/equipments/equipments-dao.ts:383`, `edge-api/src/data/DAO/enterprises/enterprises-dao.ts:121`, `edge-api/src/data/DAO/users/users-dao.ts:108`, and
     `WHERE u.${column}` in `edge-api/src/data/DAO/auth-middleware/auth-user-dao.ts:41`; `make_interval(days => ${HOUR_RECOMPUTE_DAYS})` in `edge-api/src/data/DAO/out-of-service/out-of-service-dao.ts:186`.
5. **RabbitMQ**: amqplib confirm-channel publisher to topic exchange **`edge.commands`**, routing key `edge.commands.<tenant>`
   (`edge-api/src/providers/messaging/rabbitmq-command-publisher.ts:8,67,87-93`), gated by `COMMANDS_ENABLED` (default false). Tenant ingest topology
   provisioner: asserts exchanges `oee`, `oee-retry`, `oee-failed` and queues `oeecloud-worker-q*` bound on `sparkplug.data.<tenant>`
   (`edge-api/src/providers/messaging/rabbitmq-tenant-topology.ts:137-184`), gated by `EDGE_API_INGEST_TOPOLOGY_PROVISION_ENABLED`. **No consumers** (no `consume(` found).
   MQTT: none in edge-api runtime (only strings it renders into generated on-prem compose, `edge-api/src/usecases/edge-ssm/shared/onprem-compose.ts:253-254`).
   Redis: none (see table).
6. **Auth**: `AuthMiddleware` on `/api/*` (`edge-api/src/app.module.ts:407-409`, excludes `/api/edge-ssm/webui/(.*)`) — accepts `x-api-key` header or
   deprecated `?token=` (`edge-api/src/middleware/auth.middleware.ts:147-165`) resolved against `enterprises.api_key`, **or** Bearer JWT verified against
   JWKS. Issuer/audience/JWKS **fully env-configurable** (`edge-api/src/shared/auth/bearer-jwt.config.ts:93-104`) ⇒ a mock OIDC issuer works for verification.
   Firebase issuer removed (`edge-api/src/shared/auth/bearer-jwt.config.ts:106-108`). Cognito **admin** operations (`/api/cognito-users`) use the AWS SDK with no
   endpoint override (`edge-api/src/usecases/cognito-users/shared/cognito-users.config.ts:38-46`) ⇒ cannot be pointed at a fake without code change (or SDK-level env, UNPROVEN).
7. **External deps**: AWS Cognito (JWKS + IdP admin API), AWS SSM (SendCommand/StartSession/activations), GitHub REST API, Microsoft
   PowerBI/Entra (if configured), AWS EC2 security group (teardown, UNPROVEN usage), npm registry at build. Generated artifacts embed
   `https://get.docker.com` (`edge-api/src/usecases/edge-ssm/shared/edge-ssm.service.ts:2580`) and `https://ingest.prod.packiot.app` default (`edge-api/src/usecases/edge-ssm/shared/edge-ssm.config.ts:63`).
8. **Health / ports**: `GET /health` → `{status:'ok'}` outside the auth chain (`edge-api/src/app.controller.ts:18-20`); compose healthcheck `wget
   http://localhost:8080/health` (`compose.staging.yml:542-547`). Prometheus metrics via `PrometheusModule` (`edge-api/src/app.module.ts:29`,
   default path `/metrics` — path not proven statically). Port 8080.
9. **UNPROVEN** (searched, not provable statically):
   - Actual contents of box `.env` beyond what `app_init.sh` writes (hand edits on the box) — e.g. whether `COMMANDS_ENABLED` /
     `EDGE_API_INGEST_TOPOLOGY_PROVISION_ENABLED` are set (searched `compose.staging.yml`, `app_init.sh`: absent).
   - Which schema each unqualified table resolves to under the `gold, silver, bronze, public` search_path (e.g. `box_scans`, `po_box_counter`,
     `equipment_live_metrics`, `equipment_oee_*`, `production_orders`).
   - Whether `/metrics` is the PrometheusModule path (default, not overridden in code seen).
   - Use of `TEARDOWN_INGEST_SECURITY_GROUP_ID` (EC2 API) — env read at `edge-api/src/usecases/teardown/shared/teardown.config.ts:70`, call site not traced.
   - Whether the AWS SDK v3 version (`^3.1103.0`, `edge-api/package.json:27-28`) honors `AWS_ENDPOINT_URL*` for a local fake.

---

## front4

0. **Staleness flag**: the pinned submodule is `49408c1` dated 2026-07-23. It contains **no Superset embed code** (grep `superset` in
   `front4/src` → only comments in `lib/dashboard`), although Superset/edge-api embed config targets front4 (`compose.superset.yml:61`,
   `app_init.sh:327⚠ambiguous[terraform/production/user_data/app_init.sh|terraform/staging/user_data/app_init.sh]-345`). The deployed staging front4 is therefore likely newer than this pin — everything below describes the pin only.
1. **Build / serving**: **no compose service** (searched `compose*.yml` for `front4`: only comments). Deployed by the submodule's own GitHub
   workflow: `yarn run build:staging` (`front4/.github/workflows/staging.yml:25`, script `vite build --mode staging`, `front4/package.json:64`)
   then **FTP upload** to `/staging.packiot.com/` (`front4/.github/workflows/staging.yml:27-33`, `SamKirkland/FTP-Deploy-Action`, secrets `FTP_HOST/USERNAME/PASSWORD`).
   Output dir `build/` (`front4/vite.config.js:9`). `front.$STAGING_DOMAIN` appears only in CORS/frame-ancestor lists
   (`terraform/staging/user_data/nginx_setup.sh:663`, `app_init.sh:332⚠ambiguous[terraform/production/user_data/app_init.sh|terraform/staging/user_data/app_init.sh]`); no vhost serving it was found in `nginx_setup.sh`.
2. **Env (build-time, Vite `--mode staging` ⇒ `front4/.env.staging`)**:

| var | read at | default | staging value (`front4/.env.staging`) | flag |
|---|---|---|---|---|
| VITE_API_URL | `front4/src/services/api.js:8` | `https://api4.packiot.com/` | `https://api4.packiot.com/` (`:2`) | **legacy PROD back4 API (external)** |
| VITE_EDGE_API | `front4/src/services/cognitoLink.js:52` + 9 page files (e.g. `src/pages/ProductionOrders/components/Table.jsx:39`) | `""` | `https://edge-dev.api4.packiot.com` (`:31`) | **legacy EB dev edge-api (external)** |
| VITE_REFDATA_API_URL / VITE_REFDATA_ENABLED / VITE_REFDATA_ANALYTICS | `front4/src/services/refdata.js:24,26,50` | off | `https://refdata.staging.packiot.app`, `true`, `true` (`:6,7,14`) | staging read-api via public vhost |
| VITE_AUTH_COGNITO_ENABLED / VITE_COGNITO_USER_POOL_ID / VITE_COGNITO_USER_POOL_CLIENT_ID | `front4/src/cognito.js:37-46` | off | `false`, `us-east-1_0T9t1sTwt`, `2ckuoa0ov598rdpdn3uv039h6e` (`:24-26`) | AWS Cognito (disabled at this pin) |
| VITE_COGNITO_LINK_ENABLED | `front4/src/services/cognitoLink.js:56` | off | `false` (`:32`) | |
| REACT_APP_BACKEND_URL | only in a comment (`front4/src/services/api.js:5`) | | | |

3. **Backend calls**:
   - back4/primary-api (axios `api`, base `VITE_API_URL`): `/api/admin/users`, `/api/admin/user-roles`, `/api/admin/pages`,
     `/api/admin/downtimes/total/categories/`, `/api/admin/oeeavgmonth/`, `/api/production/health/`, `/api/users/external`, `/analogs/`,
     `/infra-events/plc/current-status/`, `/getEmbedToken`, `/refreshDataset` — e.g. `src/pages/Settings/Pages/UsersAndPermissions/index.jsx:79-131`,
     `src/Context/AuthContext.jsx:58`, `src/pages/ReportsPowerBi/index.jsx:37,80`, `src/pages/OverviewV6/index.jsx:162`.
   - edge-api (`VITE_EDGE_API`, `?token=<localStorage api_key>&idEnterprise=`): `/api/production-orders/{replace,change-status,change-time,delete}`
     (`src/pages/ProductionOrders/components/Table.jsx:46,82,99`, `src/pages/Settings/Pages/ProductionOrders/components/DialogDelete.jsx:29`),
     `/api/downtimes/{split,justify,edit-manual-event,split-manual-downtime}` (`src/pages/Downtimes/components/DialogEdit.jsx:222,239`,
     `split/DialogTrim.jsx:226`), `/api/production-targets{,/scrap,/custom,/custom/delete}` (`src/pages/Settings/Pages/Targets/components/DefaultTarget.jsx:174,191`,
     `CustomTargets.jsx:98`, `CustomTargetTable.jsx:67`). API key from `localStorage.getItem('api_key')` (`CustomTargetTable.jsx:58`).
   - read-api (`VITE_REFDATA_API_URL`): `POST /v1/query` (`front4/src/services/refdata.js:83`) with datasets `mission-control-timeline`
     (`src/pages/OverviewV6/index.jsx:84`), `overview-job-info`, `equipment-info`, `production-orders-by-equipment` (`OverviewV6/index.jsx:51-57`),
     `downtimes-summary/-per-category/-events` (`src/pages/Downtimes/index.jsx:128-130`), `equipment-downtime-reasons`, `oee-progress`,
     `oee-score-teams` (`src/pages/OEE/index.jsx:49-50`), `total-production`, `targets`, `oee-score-full`, `single-period`, `single-period-legacy`,
     `machine-speed`, `production-flow`, `home-uns`, `events-timeline-full`, `mission-control`, `mission-control-area`, `equipments-list`,
     `production-orders-rich`, `production-orders-with-runtimes`, `production-targets-by-equipment`, `scrap-targets-by-equipment`,
     `custom-target-day/week/month`, `current-shift`, `overview-takt`, `overview-scrap-rate`, `equipment-runtime-1day`, `live-equipment-job`,
     `enterprise-config`, `equipments-events-column-flag` (≈37 dataset names); fixed route `GET /v1/language-packs`
     (`src/pages/Settings/Pages/UsersAndPermissions/index.jsx:72`).
   - Hasura GraphQL **hard-coded** `https://gqlpiot.packiot.com/v1/graphql` + `ws://gqlpiot.packiot.com/v1/graphql`
     (`front4/src/services/graphqlConnection.js:10,17`); used by 10 files (e.g. `src/Context/VariablesContext.jsx`, `src/components/Breadcrumb/components/site.jsx`).
4. **PostgreSQL**: n/a (SPA).
5. **MQ/Redis**: none (GraphQL subscriptions over ws to Hasura, above).
6. **Auth**: Firebase **hard-coded** config project `fbpackiot`, apiKey literal (`front4/src/firebase.js:4-11`), `onAuthStateChanged` stores ID token in
   `localStorage['@packiot4:token']` (`src/Context/AuthContext.jsx:53-55`). Cognito (Amplify) env-driven but **disabled** in staging env (`.env.staging:24`);
   Amplify derives the Cognito endpoint from the pool id — no endpoint override (`front4/src/cognito.js:48-58`).
7. **External**: Firebase Auth (`fbpackiot.firebaseapp.com`), legacy `api4.packiot.com`, `edge-dev.api4.packiot.com`, `gqlpiot.packiot.com`
   (legacy Hasura), `refdata.staging.packiot.app`, Google Fonts (`front4/index.html:22-24`), PowerBI embed via back4 (`ReportsPowerBi/index.jsx:37`),
   MUI X Pro license (`@mui/x-license-pro`, `package.json`), FTP host (deploy), hard-coded `http://camargo.packiot.com`
   (`src/pages/CustomPages/C35/C35MissionControl/pageMoved.jsx:29`).
8. **Health/ports**: n/a (static files on FTP/CDN host).
9. **UNPROVEN**: what front4 commit is actually deployed to `staging.packiot.com`; whether the deployed build sets Cognito on; whether the
   FTP host is the CDN behind `staging.packiot.com`; whether back4/Hasura legacy endpoints are still live.

---

## csadmin

1. **Build / serving**: `compose.staging.yml:1544-1580`; `build.context: ./csadmin`, `dockerfile: Dockerfile.staging`, ports `127.0.0.1:8084:80`,
   ip `172.18.0.40`, depends_on edge-api. Image: node:22-alpine builder `npm run build` → `nginx:1.27-alpine` serving `/usr/share/nginx/html`
   with `nginx.staging.conf.template` envsubst'd (`csadmin/Dockerfile.staging:18,57,59-66`). Host vhost `csadmin.$STAGING_DOMAIN` →
   `127.0.0.1:8084` (`nginx_setup.sh:463⚠ambiguous[terraform/production/user_data/nginx_setup.sh|terraform/staging/user_data/nginx_setup.sh]-475`), tier `none-originverify` (`variables.tf:112`).
   nginx: `/api/edge-ssm/session/stream` (ws upgrade) → `http://edge-api:8080` (`csadmin/nginx.staging.conf.template:31-41`);
   `^~ /api/` → `http://edge-api:8080` (`:43-51`); `^~ /v1/` → **`http://refdata-api:9104`** (`:56-64`); SPA fallback `:68-72`.
2. **Env (build-time)**: Dockerfile ARGs `VITE_EDGE_API_URL=""` (`Dockerfile.staging:29`), `VITE_FIREBASE_*=""` (`:36-41`),
   `VITE_AUTH_COGNITO_ENABLED="true"`, `VITE_COGNITO_USER_POOL_ID="us-east-1_0T9t1sTwt"`, `VITE_COGNITO_CLIENT_ID="2ckuoa0ov598rdpdn3uv039h6e"` (`:49-51`).
   Compose build args (`compose.staging.yml:1548-1558`): `VITE_API_BASE_URL: ""` — **not declared as an ARG in `Dockerfile.staging`, i.e. unused**
   (the SPA reads `VITE_EDGE_API_URL`, `csadmin/src/lib/api-client.ts:35`); Cognito args duplicate the Dockerfile defaults.
   Code reads: `VITE_EDGE_API_URL` (`csadmin/src/lib/api-client.ts:35`, `csadmin/src/api/edge-ssm.ts:505,523`), `VITE_FIREBASE_*` (`csadmin/src/lib/firebase.ts:5-10`),
   `VITE_COGNITO_*`/`VITE_AUTH_COGNITO_ENABLED` (`csadmin/src/lib/cognito.ts:37-46`), `VITE_CUSTOMIZE_URL` (`csadmin/src/lib/sibling-apps.ts:20`, default = derived
   sibling host), `VITE_PROMOTE_APPLY_ENABLED` (`csadmin/src/api/promote.ts:22`, default off). Runtime container env: none (template has no `${VAR}`).
3. **Backend calls** (all same-origin via axios `apiClient` → nginx → edge-api; Bearer + `?idEnterprise=` interceptors `csadmin/src/lib/api-client.ts:39-63`):
   CRUD factory `/api/${resource}` (`csadmin/src/api/crud.ts:22`) for `areas, sites, enterprises, users, user-roles, language-packs`;
   `/api/onboarding/*` (23 refs, `csadmin/src/api/onboarding.ts:527`), `/api/equipments` (`csadmin/src/api/equipment.ts:192`), `/api/edge-bundle` (`csadmin/src/api/edge.ts:175`),
   `/api/packml-config` (`csadmin/src/api/edge.ts:145`), `/api/edge-ssm` (+ ws `/api/edge-ssm/session/stream`, webui iframe `/api/edge-ssm/webui/...`, `csadmin/src/api/edge-ssm.ts:338,505-527`),
   `/api/packml-register` (`csadmin/src/api/packml-register.ts:35`), `/api/shifts`, `/api/shift-hours` (`csadmin/src/api/shifts.ts:70,92`), `/api/teams` (`csadmin/src/api/teams.ts:43`),
   `/api/production-targets` (`csadmin/src/api/production-targets.ts:60`), `/api/out-of-service` (`csadmin/src/api/out-of-service.ts:44`), `/api/plc-status`
   (`csadmin/src/api/plc-status.ts:89`), `/api/i18n` (`csadmin/src/api/i18n.ts:48`), `/api/promote` (`csadmin/src/api/promote.ts:122`), `/api/teardown` (`csadmin/src/api/teardown.ts:5`),
   `/api/cognito-users` (`csadmin/src/api/users-admin.ts:125`), `/api/admin/*` (`csadmin/src/api/downtime-reasons.ts:145`), `/api/entities` (`csadmin/src/api/entities.ts:44`),
   `/api/enterprises` (`csadmin/src/api/enterprises.ts:58`). **No `/v1/` calls found** in `csadmin/src` (searched `"/v1`, `'/v1`, `` `/v1 ``) — the nginx `/v1` proxy is unused by this code.
4. **PostgreSQL**: n/a.
5. **MQ/Redis**: none.
6. **Auth**: Cognito via Amplify, pool/client baked at build (`csadmin/src/lib/cognito.ts:37-46`; no endpoint override); Firebase init only when
   `VITE_FIREBASE_*` non-blank (blank on staging, `Dockerfile.staging:36-41`). Not behind oauth2-proxy (`variables.tf:112`).
7. **External**: AWS Cognito (cognito-idp.us-east-1), npm registry (build). Hard-coded external hosts in non-test source: none found
   (searched `https?://` in `csadmin/src`, `index.html`; hits only in `src/test/*`).
8. **Health/ports**: container healthcheck `wget http://localhost:80/` (`compose.staging.yml:1562-1567`); port 80 → host 8084.
9. **UNPROVEN**: whether any runtime path still needs `/v1` (only static grep); whether nginx `envsubst` leaves `$host` etc. intact (stock
   nginx entrypoint substitutes only defined env vars — assumed, not verified here).

---

## customize (in-tree `customize/`)

1. **Build / serving**: `compose.staging.yml:1591-1622`; `build.context: ./customize`, `Dockerfile.staging`, ports `127.0.0.1:8086:80`, ip `172.18.0.51`.
   Same two-stage pattern as csadmin (`customize/Dockerfile.staging:16,57,63`). nginx: only `^~ /api/` → `http://edge-api:8080`
   (`customize/nginx.staging.conf.template:21-22`) + SPA fallback (`:33`) — **no `/v1` and no ws location**.
   Host vhost `customize.$STAGING_DOMAIN` → 8086 (`terraform/staging/user_data/nginx_setup.sh:495-507`), tier `none-originverify` (`variables.tf:113`).
2. **Env (build-time)**: ARGs `VITE_EDGE_API_URL=""` (`Dockerfile.staging:27`), `VITE_FIREBASE_*=""` (`:34-39`), Cognito trio (`:47-49`).
   Compose args `VITE_API_BASE_URL: ""` (unused, no ARG), Cognito trio (`compose.staging.yml:1595-1601`). Code reads `VITE_EDGE_API_URL`
   (`customize/src/lib/api-client.ts:35`, `customize/src/api/edge-ssm.ts:135`), `VITE_COGNITO_*` (`customize/src/lib/cognito.ts:37-46`), `VITE_FIREBASE_*` (`customize/src/lib/firebase.ts:5-10`),
   `VITE_CSADMIN_URL` (`customize/src/lib/sibling-apps.ts:20`).
3. **Backend calls** (edge-api only): `/api/${resource}` CRUD (`customize/src/api/crud.ts:22`, resource `enterprises`), `/api/onboarding/*` (22 refs,
   `customize/src/api/onboarding.ts:661`), `/api/equipments` (`customize/src/api/equipment.ts:178`), `/api/edge-ssm/*` incl. `apply-oee-settings`, `webui`
   (`customize/src/api/edge-ssm.ts:9,125-136`), `/api/plc-status` (`customize/src/api/plc-status.ts:89`), `/api/enterprises` (`customize/src/api/enterprises.ts:58`).
4–5. n/a / none.
6. **Auth**: Cognito/Amplify (as csadmin); Firebase gated on blank config (`customize/src/lib/firebase.ts:23`).
7. **External**: AWS Cognito; npm registry.
8. **Health/ports**: `wget http://localhost:80/` (`compose.staging.yml:1604-1609`); 80 → 8086.
9. **UNPROVEN**: the edge-ssm web-UI iframe path (`/api/edge-ssm/webui/...`) proxies through the generic `/api/` location (no `Upgrade`
   headers) — whether the web UI needs websockets was not traced.

---

## operator (also: operator-sbx, operator-bispharma)

1. **Build / serving**: `compose.staging.yml:3426-3482`; `build.context: ./operator`, `dockerfile: Dockerfile.staging`, ports `127.0.0.1:8083:80`,
   ip `172.18.0.19`, depends_on edge-api + read-api(healthy) (`:3469-3477`). Image: node:22-alpine `yarn build` → nginx:1.27-alpine
   (`operator/Dockerfile.staging:11-50`). PWA/workbox runtime caching of reads (`operator/pwa.config.js:60-75`).
   nginx template (`operator/nginx.staging.conf.template`): Docker DNS resolver (`:23`); `^~ /api/` → `http://edge-api:8080` **injecting
   `x-api-key: ${EDGE_API_KEY}` and stripping `Authorization`** (`:28-43`); `^~ /session` → `http://edge-api:8080` (`:49-57`);
   `/v1/` → **`http://refdata-api:9104`** injecting `x-api-key: ${REFDATA_API_KEY}` and forwarding `x-operator-superadmin-token` (`:67-84`); SPA (`:98-102`).
   Host vhost `operator.$STAGING_DOMAIN` → 8083 (`terraform/staging/user_data/nginx_setup.sh:297-335`), oauth2 tier `any` (`variables.tf:111`).
2. **Env**:
   - Build-time: `ENV VITE_API_URL=""` (`Dockerfile.staging:20`, read `operator/src/Services/api.js:12`), `ENV VITE_STAGING_AUTO_LOGIN="false"` (`:25`, read
     `src/Pages/Login/index.jsx:41-45`, fallbacks `packiot`/`packiot`), `ARG VITE_PO_WRITE_QUEUE_ENABLED=false` (`:31-32`, read
     `operator/src/Services/durableWrite.js:43`), `ARG VITE_COGNITO_USER_POOL_ID / VITE_COGNITO_USER_POOL_CLIENT_ID` (`:37-40`, read `operator/src/Services/cognito.js:29-30`),
     `VITE_EQUIPMENT_SETUP_GROUPS` (`src/Components/EquipmentSetup/index.jsx:18`, default `'PACK,C-PACK'`, not passed).
     Staging build args: `VITE_PO_WRITE_QUEUE_ENABLED: "true"`, pool `us-east-1_0T9t1sTwt`, client `2ckuoa0ov598rdpdn3uv039h6e` (`compose.staging.yml:3431-3442`).
   - Runtime (nginx envsubst): `EDGE_API_KEY: ${OPERATOR_EDGE_API_KEY:-}` (CPACK `enterprises.api_key`), `REFDATA_API_KEY:
     ${OPERATOR_REFDATA_API_KEY:-stg-cpack-key}` (`compose.staging.yml:3461-3463`). read-api maps `stg-cpack-key:3` (`compose.staging.yml:2944`).
3. **Backend calls** (same-origin): edge-api `POST /session`, `/session/switch`, `/session/enterprises` (`operator/src/Services/endpoints.js:595-605`,
   `src/Components/Header/components/EnterpriseSwitcher.jsx:18`); `/api/downtimes/{justify,edit-manual-event,create-manual-event,split}`
   (`operator/src/Services/endpoints.js:326,358,391,435`); `/api/production-orders/{start,create-and-start,replace,setup,create}` (`operator/src/Services/endpoints.js:473,497,526,543,582`);
   `/api/i18n/front4/...` (`operator/src/i18n/backend.js:67`). read-api: `/v1/operator-po-list`, `/v1/operator-po-details` (`operator/src/Services/endpoints.js:52-53`),
   `/v1/pending-downtime` (`:100`), `/v1/events-timeline` (`:113`), `/v1/downtime-reasons` (`:172`), `/v1/operator-entities` (`:180`),
   `/v1/language-packs` (`:193`, `operator/src/i18n/backend.js:17`). Super-admin read escalation interceptor (`operator/src/Services/api.js:30-80`).
   **No calls to edge-nodered or operator-gateway** found (searched `operator-gateway|operator-adapter|8443|barcode` in `operator/src`).
4–5. n/a / none.
6. **Auth**: Cognito/Amplify SRP, configured when both ids present (`operator/src/Services/cognito.js:37-50`), no endpoint override; Bearer attached per
   request (`operator/src/Services/api.js:9`); nginx strips `Authorization` on `/api/` and authenticates writes with the injected api-key
   (`operator/nginx.staging.conf.template:31-37`). Additionally behind oauth2-proxy (`variables.tf:111`). No Firebase (grep `firebase` in `operator/src`: none).
   Compose comment "Authentik SSO … packiot/packiot" (`compose.staging.yml:3423-3425`) is stale vs `Dockerfile.staging:21-25`.
7. **External**: AWS Cognito; Google Fonts (`operator/index.html:10`); npm/yarn registry at build.
8. **Health/ports**: no compose healthcheck for `operator` (none in `:3426-3482`); nginx :80 → host 8083.
9. **Variants** (same build stanza ⇒ same image):
   - `operator-sbx` (`compose.staging.yml:3509-3546`): `EDGE_API_KEY=${OPERATOR_SBX_EDGE_API_KEY:-}` (sandbox ent 2000003), `REFDATA_API_KEY=${…:-stg-sbxcpack-key}`, host port 8085, no static IP.
   - `operator-bispharma` (`compose.staging.yml:3552-3588`): `EDGE_API_KEY=${OPERATOR_BISPHARMA_EDGE_API_KEY:-}` (ent 5), `REFDATA_API_KEY=${…:-stg-bispharma-key}`, host port 8087.
10. **UNPROVEN**: service-worker cached endpoints list (`isCacheableRead` body not traced); whether `/session` still returns HS256 tokens anywhere.

---

## barcode-app

1. **Build / serving**: `compose.staging.yml:1504-1535` — **`image: barcode-app:staging` (no build)**, ports `127.0.0.1:8092:80`, ip `172.18.0.50`,
   healthcheck `wget http://localhost:80/` (`:1519-1524`). Source = separate repo `barcode-scanner-v2` (**not a submodule**, `.gitmodules` lists only
   edge-node-red, edge-api, operator, csadmin, front4) — comment `compose.staging.yml:1493-1503`. Deploy pulls `ghcr.io/packiot/barcode-edge:staging`
   and retags (`.github/workflows/deploy-staging.yml:161-184`), else the hand-built image is kept.
   **Source not present in this repo** (searched `find -iname '*barcode*'`: only `services/barcode-service` (Go), `db/migrations/t237-barcode-schema`,
   `t241-barcode-fold`, docs).
2. **Env (runtime, per compose)**: `EDGE_API_UPSTREAM=http://edge-api:8080`, `EDGE_API_KEY=${BARCODE_EDGE_API_KEY:-}`, `REFDATA_UPSTREAM=http://read-api:9104`,
   `REFDATA_API_KEY=${BARCODE_REFDATA_API_KEY:-}` (`compose.staging.yml:1508-1516`). Build arg `VITE_STATION_EQUIPMENT_ID=2000047` per comment only (`:1499-1503`).
3. **Backend calls**: per compose comments only — edge-api same-origin `/api` with nginx-injected `x-api-key`; `/v1` read plane "unused by this
   build" (`:1509-1514`). Not verifiable.
4–7. Unknown (source absent). Vhost `barcode.$STAGING_DOMAIN` tier `csadmin` (`variables.tf:76,110`).
8. **Health/ports**: above.
9. **UNPROVEN**: everything about code-level env reads, endpoints, auth and external deps (source not in repo); the `BARCODE_*` keys are not
   written by `app_init.sh` (searched) — origin unknown.

---

## edge-nodered (submodule `edge-node-red`)

1. **Build / serving**: `compose.staging.yml:733-798` — **`profiles: ["legacy-sim"]` (retired 2026-08-16, off by default, `:734-742`)**.
   `build.context: ./edge-node-red`; image `nodered/node-red:4.0.9-20` + `npm ci` into `/app` (`edge-node-red/Dockerfile:1-13`); flows copied to
   `/repo-data` and synced to `/data` by `entrypoint.sh` (`Dockerfile:24-33`, `edge-node-red/entrypoint.sh:51-57`). Port `127.0.0.1:1880:1880`, ip `172.18.0.4`,
   volume `nr-edge-data:/data`, `extra_hosts` for hasura/rabbitmq/edge-api/pgbouncer (`compose.staging.yml:773-777`).
2. **Env**: required at boot (exit if empty): `NODE_RED_CREDENTIAL_SECRET, RABBITMQ_HOST, RABBITMQ_USER, RABBITMQ_PASSWORD, ID_PUBSUB_NODE, API_KEY,
   FIREBASE_API_KEY, HASURA_URL` (`edge-node-red/entrypoint.sh:30-44`). Optional `AWS_SECRET_ID` + `AWS_REGION` → loads env from **AWS Secrets Manager** (`edge-node-red/entrypoint.sh:11-27`).
   settings.js: `NODE_RED_CREDENTIAL_SECRET` (`edge-node-red/settings.js:44`), `NODE_RED_ADMIN_USERNAME/_PASSWORD_HASH` (`:76-82`), `PORT` (`:148`),
   `RABBITMQ_USER/PASSWORD` (`:558-559`). Flows (`env.get`): `EDGE_API_BASE_URL`, `ID_ENTERPRISE`, `API_KEY` (`edge-node-red/flows/API.json:628`), `JWT_SECRET`
   (`edge-node-red/flows/API.json:1766`), `HASURA_URL`/`HASURA_ADMIN_SECRET` (`edge-node-red/flows/GraphQL.json:198-219`), `RABBITMQ_URL/HOST/USER/PASSWORD` (`edge-node-red/flows/Sparkplug.json:443`),
   `CLIENT_TENANT_ID`, `HOSTNAME` (`flows/Publish to edge.plc-normalized.json:55⚠not-in-repo`).
   Staging values (`compose.staging.yml:747-770`): `RABBITMQ_HOST=rabbitmq`, `ID_PUBSUB_NODE=staging-app-ec2`, `HASURA_URL=http://hasura:8080/v1/graphql`
   (**Hasura service no longer exists**, `compose.staging.yml:500-510`), `HASURA_ADMIN_SECRET`, `API_KEY=${EDGE_API_KEY}`, `FIREBASE_API_KEY=bypassed-by-hasura-admin-secret`,
   `EDGE_API_BASE_URL=http://edge-api:8080`, `ID_ENTERPRISE="3"`.
3. **Backend calls**: edge-api `POST /api/downtimes/{create-manual-event,edit-manual-event,justify,split}`, `/api/production-orders/{create-and-start,replace,setup,start}`
   with `?token=<API_KEY>&idEnterprise=` (`edge-node-red/flows/API.json:628` and sibling function nodes); Hasura GraphQL (`edge-node-red/flows/GraphQL.json:219`, 9 http-request nodes);
   **Firebase REST** `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword` and `https://securetoken.googleapis.com/v1/token`
   (`edge-node-red/flows/GraphQL.json:876,730`); Loki push `http://loki:3100/loki/api/v1/push` (`flows/Sparkplug.json`, "POST: Loki push" node);
   RabbitMQ **management HTTP API** `http://rabbitmq:15672/api/exchanges/%2F/edge.plc-normalized/publish` (`flows/Publish to edge.plc-normalized.json:74⚠not-in-repo`).
   Exposes 21 `http in` endpoints (e.g. `/session`, `/machines/:lineId`, `/plc-data`, `/health`) (`flows/API.json`, `flows/Sparkplug.json`).
4. **PostgreSQL**: none direct (no postgres nodes; searched node types in all flow files).
5. **RabbitMQ**: amqplib publish to exchange **`oee`**, routing key `sparkplug.data.<gateway>` (`edge-node-red/flows/Sparkplug.json:439-443`); HTTP-API publish to
   **`edge.plc-normalized`**, rk `edge.plc-normalized.<tenant>` (`flows/Publish to edge.plc-normalized.json:74⚠not-in-repo`). Local SQLite store-and-forward
   `/data/sparkplug_queue.sqlite` (`edge-node-red/flows/Sparkplug.json:268`). MQTT: none (no mqtt nodes). PLC: `s7 in` node with empty endpoint (`edge-node-red/flows/PLCs.json:56-60`).
6. **Auth**: local users + `jsonwebtoken` signed with `JWT_SECRET` (`edge-node-red/flows/API.json:1766-1775`); Firebase REST login (above); editor adminAuth only if
   `NODE_RED_ADMIN_USERNAME` set (`edge-node-red/settings.js:76-82`; `.env` deliberately omits it, `terraform/staging/user_data/app_init.sh:262-266`).
7. **External**: Google Identity Toolkit/securetoken (Firebase), AWS Secrets Manager (optional), npm registry at build, Docker Hub base image.
8. **Health/ports**: `GET /health` http-in (`edge-node-red/flows/API.json:1470-1471`); image HEALTHCHECK `wget http://localhost:1880/health` (`Dockerfile:44-45`);
   compose healthcheck `wget http://127.0.0.1:1880/` (`compose.staging.yml:780-785`). Port 1880.
9. **UNPROVEN**: whether FlowManager loads `flows.json` or `flows/*.json` as the authority (both copied, `edge-node-red/entrypoint.sh:51-57`; `flows.json` duplicates
   the same env reads at `:1390,4307,5343,6753,6812`); runtime behaviour without Hasura.

---

## grafana

1. **Build / serving**: `compose.staging.yml:811-854` — `image: grafana/grafana:11.5.0`, `env_file: [.env]`, port `127.0.0.1:3000:3000`, ip `172.18.0.7`,
   mounts `./grafana/provisioning:/etc/grafana/provisioning:ro` and `./grafana/dashboards:/var/lib/grafana/dashboards:ro` (`:838-845`),
   volume `grafana-data`. Host vhost `grafana.$STAGING_DOMAIN` → 3000, oauth2 tier `csadmin` (`variables.tf:73,107`).
2. **Env**: `GF_SECURITY_ADMIN_USER=admin`, `GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}`, `GF_AUTH_ANONYMOUS_ENABLED=false`,
   `GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=…/audience/00-overview.json`, `GF_USERS_DEFAULT_THEME=dark`, `GF_FEATURE_TOGGLES_ENABLE=publicDashboards`
   (`compose.staging.yml:821-832`). Datasource provisioning interpolates `$POSTGRES_HOST/$POSTGRES_PORT/$POSTGRES_USER/$POSTGRES_PASSWORD/$POSTGRES_DB`
   from `.env` (`grafana/provisioning/datasources/postgres.yml:12-17`, `grafana/provisioning/datasources/postgres-analytics.yml:9-12`) ⇒ **direct DB host IP, user `postgres`**
   (`app_init.sh:233⚠ambiguous[terraform/production/user_data/app_init.sh|terraform/staging/user_data/app_init.sh],240`). `GF_SERVER_ROOT_URL` from `.env` (`terraform/staging/user_data/app_init.sh:277`).
3. **Datasources** (`grafana/provisioning/datasources/`):

| name | uid | type | target | cite |
|---|---|---|---|---|
| Packiot PostgreSQL (default) | `packiot-postgres` | postgres | `$POSTGRES_HOST:$POSTGRES_PORT`, db **`$POSTGRES_DB` = `packiot`** (F1) | `grafana/provisioning/datasources/postgres.yml:9-25` |
| Packiot Analytics (F3) | `packiot-postgres-shadow` | postgres (timescaledb) | `$POSTGRES_HOST:$POSTGRES_PORT`, db `packiot_analytics` | `grafana/provisioning/datasources/postgres-analytics.yml:6-21` |
| Prometheus | `packiot-prometheus` | prometheus | `http://prometheus:9090` | `grafana/provisioning/datasources/prometheus.yml:4-7` |
| Loki | `packiot-loki` | loki | `http://loki:3100` | `grafana/provisioning/datasources/loki.yml:4-7` |
| Tempo | `packiot-tempo` | tempo | `http://tempo:3200` | `grafana/provisioning/datasources/tempo.yml:4-8` |

   `packiot-postgres` (F1 `packiot`) is referenced by **0** dashboard panels (grep `"uid": "packiot-postgres"` → 0).
   Dashboard providers: folder `Audience` ← `/var/lib/grafana/dashboards/audience`, folder `Library` ← `…/library` (`grafana/provisioning/dashboards/all.yml:14-30`).
4. **PostgreSQL reads per dashboard** (all via `packiot-postgres-shadow` = `packiot_analytics`; templated `${datasource}` defaults to it — e.g.
   `library/03-oee-business.json` templating `current.value = packiot-postgres-shadow`). All table names unqualified (resolve via search_path).
   No write statements found in any dashboard SQL.

   **Folder `audience/` (5 dashboards; 6 SQL targets total)**

| dashboard (uid) | SQL targets | tables | other ds |
|---|---|---|---|
| `00-overview.json` (v2-overview) | 0 | — | prometheus |
| `01-cs-client-health.json` (aud-cs) | 4 | enterprises, equipments, equipment_values, equipment_oee_shift | prometheus |
| `02-platform-sre.json` (aud-sre) | 0 | — | prometheus |
| `03-pipeline-data.json` (aud-data) | 1 | data_quality_event | prometheus |
| `04-ingest-debug.json` (aud-debug-ingest) | 1 | enterprises, equipment_values | prometheus |

   **Folder `library/` (16 dashboards; 89 SQL targets total)**

| dashboard (uid) | SQL targets | tables / objects | other ds |
|---|---|---|---|
| `03-oee-business.json` (v2-oee) | 17 | enterprises, sites, areas, equipments, equipment_values, packml_register | — |
| `04-engine.json`, `05-ingest.json`, `10-infra.json`, `11-database.json`, `12-api.json`, `13-rabbitmq.json`, `14-uptime-containers.json`, `15-po-staleness-gate.json` | 0 | — | prometheus |
| `07-operator.json` (v2-operator) | 13 | enterprises, equipment_events, production_orders, user_logs | prometheus |
| `08-logs.json` | 0 | — | loki |
| `09-equipment.json` (v2-equipment) | 12 | enterprises, sites, areas, equipments, packml_register, production_orders, production_orders_runtime, shifts, shift_hours | — |
| `16-database-dbm.json` (v2-database-dbm) | 6 | `timescaledb_information.{hypertables,jobs,job_stats,continuous_aggregates}`, `hypertable_compression_stats()`, `pg_stat_user_tables`, `pg_stat_user_indexes` | prometheus |
| `17-data-quality.json` (v2-data-quality) | 10 | data_quality_event | — |
| `18-query-traces.json` | 0 | — | tempo |
| `19-factory-analysis.json` (v2-factory-analysis) | 31 | enterprises, sites, areas, equipments, equipment_events, equipment_oee_shift, equipment_oee_daily, area_oee_shift, production_orders, production_orders_runtime, data_quality_event | — |

   **Defect found**: `grafana/dashboards/library/19-factory-analysis.json:1124` and `:1202` query `FROM equipment_oee_ r` — the `${grain}` suffix (custom
   variable `grain = shift,hourly,daily`) is missing from the table name, so those two panels reference a non-existent relation.
5. **MQ/Redis**: none.
6. **Auth**: Grafana built-in admin (`compose.staging.yml:822-824`), no OAuth config; access gated externally by oauth2-proxy cs-admin tier
   (`variables.tf:107`, `nginx_setup.sh:157⚠ambiguous[terraform/production/user_data/nginx_setup.sh|terraform/staging/user_data/nginx_setup.sh]-186`).
7. **External**: Docker Hub image; none at runtime found (no `GF_INSTALL_PLUGINS`; searched compose env).
8. **Health/ports**: `wget http://127.0.0.1:3000/api/health` (`compose.staging.yml:846-851`); port 3000. Depends implicitly on prometheus/loki/tempo
   containers (`compose.staging.yml:857,907,1078`) for non-SQL panels.
9. **UNPROVEN**: which schema each unqualified table (e.g. `data_quality_event` → `silver`? `area_oee_shift` → `gold`?) resolves to; library
   folder SQL counts are scanner-derived (`rawSql`/`query` strings containing `SELECT`).

---

## superset (compose.superset.yml; services superset-redis, superset-db-init, superset-init, superset, superset-worker)

1. **Build / serving**: overlay file, all services `profiles: ["superset"]` (e.g. `compose.superset.yml:104,132,173,255,293`; activation via
   `COMPOSE_PROFILES=superset`, `terraform/staging/user_data/app_init.sh:347-349`). Image `packiot/superset:4.1.1-w2` built from `docker/superset/Dockerfile`
   (`compose.superset.yml:35-38`): `FROM apache/superset:4.1.1` + pip `psycopg2-binary==2.9.10, flask-cors==4.0.2, Authlib==1.3.2,
   flask-talisman==1.1.0` (`docker/superset/Dockerfile:23-32`). Config dir mount `./configs/superset:/app/pythonpath:ro` (`compose.superset.yml:84`).
   - `superset`: gunicorn `0.0.0.0:8088`, 4 workers × 20 threads (`:260-267`), `127.0.0.1:8088:8088` (`:268-269`), ip `172.18.0.42`; host vhost
     `bi.$STAGING_DOMAIN` → 8088 with origin-verify + CORS for front4, **no auth_request** (`terraform/staging/user_data/nginx_setup.sh:735-782`).
   - `superset-worker`: celery prefork ×2 (`:298-304`), ip `.43`.
   - `superset-redis`: `redis:7-alpine`, noeviction 256 MB, AOF (`:101-122`), ip `.45`.
   - `superset-db-init` (one-shot, `postgres:16-alpine`): connects **directly** `PGHOST=${POSTGRES_HOST_UPSTREAM}` as `${POSTGRES_USER}` to `${POSTGRES_DB}`
     (`:134-139`), creates role `superset` + database `superset` + `pgcrypto` (`:148-154`).
   - `superset-init` (one-shot): `superset db upgrade` / `init` / `fab create-admin` ×2 / `bootstrap_guest_role.py` / `import_bundle.py` +
     `superset import-dashboards` / `sync_databases.py` / `normalize_query_context.py` / `harden_dashboard_roles.py` / `register_embed.py` (`:178-235`).
2. **Env** (anchor `x-superset-env`, `compose.superset.yml:40-67`, plus `.env`): `SUPERSET_SECRET_KEY` (read `configs/superset/superset_config.py:23`),
   `SUPERSET_GUEST_TOKEN_JWT_SECRET` (`:28`), `SUPERSET_DB_PASSWORD` (`:69`), `POSTGRES_HOST_UPSTREAM` (`:65`, also asset templating
   `configs/superset/import_bundle.py:48`, default `10.10.10.89`), `SUPERSET_METADATA_DB_HOST` (`configs/superset/superset_config.py:64`, unset on staging),
   `SUPERSET_REDIS_HOST=superset-redis` / `SUPERSET_REDIS_PORT` (`:76-77`), `SUPERSET_FRAME_ANCESTOR` (compose default `https://front.prod.packiot.app`,
   `compose.superset.yml:59`; staging `.env` `https://staging.packiot.com,https://front.$STAGING_DOMAIN`, `terraform/staging/user_data/app_init.sh:332`; read `configs/superset/superset_config.py:130`,
   `configs/superset/register_embed.py:49`), `SUPERSET_AUTH_MODE` (`configs/superset/superset_config.py:235`, default `db`; **not set** in compose or `app_init.sh` ⇒ AUTH_DB on staging),
   `SUPERSET_COGNITO_ISSUER/CLIENT_ID/CLIENT_SECRET` (`compose.superset.yml:50-52`; read `configs/superset/superset_config.py:236,251,259` only in oauth mode),
   `SUPERSET_ADMIN_USER/PASSWORD`, `SUPERSET_GUESTTOKEN_ADMIN_USER/PASSWORD` (`compose.superset.yml:57-58`; `.env` `terraform/staging/user_data/app_init.sh:320-323`),
   `SUPERSET_DB_RO_PASSWORD`, `HIST_GW_SVC_PASSWORD`, `SUPERSET_ANALYTICS_DB` (`configs/superset/import_bundle.py:40-49`), `SUPERSET_OEE_DASHBOARD_UUID[_PT]`,
   `SUPERSET_EMBED_TARGET_DASHBOARD[_PT]` (`configs/superset/register_embed.py:95-106`).
3. **Backend calls / embed**: guest tokens minted by edge-api (`edge-api/src/usecases/superset-embed/superset-embed.service.ts:63,114`) for
   front4 iframe; `FEATURE_FLAGS EMBEDDED_SUPERSET, DASHBOARD_RBAC, ALERT_REPORTS` (`configs/superset/superset_config.py:108-113`); Talisman CSP `frame-ancestors`
   from `SUPERSET_FRAME_ANCESTOR` (`configs/superset/superset_config.py:130-148`); guest role `GuestViewer`, token TTL 300 s (`configs/superset/superset_config.py:29,35`).
4. **PostgreSQL**:
   - Metadata DB: `postgresql+psycopg2://superset:<pw>@<POSTGRES_HOST_UPSTREAM>:5432/superset` (`configs/superset/superset_config.py:67-70`).
   - Analytics source `packiot_analytics` as **`superset_ro`** (`configs/superset/assets/databases/packiot_analytics.yaml:40-41`, `allow_dml: false`
     `:51`, `expose_in_sqllab: false` `:47`). 12 datasets, all physical (`sql: null`) in **schema `bi`**: `oee_shift, oee_hourly,
     production_order_runtime, downtimes, equipments, equipment_speed, live_status, production_by_team, production_orders, production_targets,
     po_box_counter, scanned_boxes` (`configs/superset/assets/datasets/packiot_analytics/*.yaml`).
   - `bi.*` views defined in `db/superset/01-superset-ro-role.sql` over unqualified `equipment_oee_shift` (`:143`), `equipment_oee_hourly` (`:166`),
     `production_orders_runtime` (`:189`), `equipment_events` (`:226,245`), `equipments` (`:263`), `equipment_values` (`:336,394,416`),
     `production_orders` (`:457`), `production_targets` (`:475`); grants to `bi_owner` (`:86-95`), `superset_ro` USAGE on `bi` only (`:98`,
     `:500-501`). `04-bi-oee-spike-guard.sql` redefines `bi.oee_shift/oee_hourly` over **`gold.equipment_oee_shift` / `gold.equipment_oee_hourly`**
     + `core.equipments` (`:49-96`). `05-bi-scanned-boxes.sql` defines `bi.scanned_boxes` over **`bronze.box_scans`** + `core.equipments/sites/areas/production_orders`
     (`:20-31`) and `bi.po_box_counter` over **`gold.po_box_counter`** (`:36-40`). Tenant RLS: `public.current_tenant()`, `public.is_all_tenant()`
     and `tenant_isolation` policies on `equipments, equipment_events, production_orders_runtime, equipment_oee_shift, equipment_oee_hourly,
     equipment_values, production_orders, production_targets` (`db/superset/02-tenant-rls.sql:64-241`). Optional `bi.user_tenant` mapping
     (`db/superset/03-authoring-rls-mapping.optional.sql:32`).
   - Historian source `historian_union`: `postgresql+psycopg2://historian_svc:<pw>@hist-gateway:5432/packiot_historian`
     (`configs/superset/assets/databases/historian_union.yaml:36-37`); dataset `ev_all` = virtual SQL over `silver.equipment_values` with Jinja time filters
     (`configs/superset/assets/datasets/historian_union/ev_all.yaml:49-61`). `hist-gateway` is defined in `compose.historian-gateway.yml:13` (not in staging main file).
   - superset-db-init: superuser DDL on `${POSTGRES_DB}` (= `packiot`, see cross-cutting) to create role/db `superset` (`compose.superset.yml:135-154`).
5. **Redis**: `superset-redis` db0 cache (`configs/superset/superset_config.py:79-87`), db1 results / celery result backend, db2 celery broker (`:93-99`).
   RabbitMQ/MQTT: none.
6. **Auth**: AUTH_DB by default; AUTH_OAUTH against Cognito only if `SUPERSET_AUTH_MODE=oauth` and client id set, issuer env-driven with
   `server_metadata_url = <issuer>/.well-known/openid-configuration` (`configs/superset/superset_config.py:235-261`) ⇒ a mock OIDC issuer is pluggable by env.
   Guest tokens HS-signed with `GUEST_TOKEN_JWT_SECRET` (`configs/superset/superset_config.py:28`).
7. **External**: Docker Hub (`apache/superset:4.1.1`, `redis:7-alpine`, `postgres:16-alpine`), PyPI at build, Cognito (only in oauth mode).
   No Mapbox / CDN config found (searched `MAPBOX|mapbox|deck_gl|googleapis` in `configs/superset`).
8. **Health/ports**: superset `curl -fsS http://127.0.0.1:8088/health` (`compose.superset.yml:278-283`); worker `celery inspect ping` (`:311-316`);
   redis `redis-cli ping` (`:114-119`). Ports 8088 (web), 6379 (redis, internal).
9. **UNPROVEN**: which `db/superset/*.sql` files are applied on staging and in what order (README only; no runner found); that `superset_ro`
   has LOGIN on staging (file creates it `NOLOGIN` at `db/superset/01-superset-ro-role.sql:64`, LOGIN granted "at apply" per comment `:51-53`);
   the remaining `configs/superset/assets/charts/*.yaml` / dashboards (82 asset files) were not individually traced.

---

## Appendix — searches that returned nothing (for the record)

| question | patterns searched | scope | result |
|---|---|---|---|
| front4 compose service | `front4` | `compose*.yml`, `Makefile` | comments only |
| barcode-app source | `-iname '*barcode*'`, `barcode-scanner-v2` | repo (excl. node_modules/.git) | none (separate repo) |
| edge-api Redis | `ioredis`, `from 'redis'`, `createClient`, `REDIS` | `edge-api/src` | none |
| edge-api MQTT client | `mqtt` | `edge-api/src` | only rendered strings |
| SPA Cognito endpoint override | `userPoolEndpoint`, `endpoint` | `*/cognito.(ts|js)` in csadmin, customize, operator, front4 | none |
| edge-api AWS endpoint override | `endpoint`, `AWS_ENDPOINT` | cognito-users / edge-ssm config | none |
| stack db/migrations runner | `db/migrations` | `.github/workflows`, `scripts`, `Makefile` | sandbox scripts only |
| Grafana use of F1 datasource | `"uid": "packiot-postgres"` | `grafana/dashboards` | 0 |
| csadmin `/v1` calls | `"/v1`, `'/v1`, `` `/v1 `` | `csadmin/src` | none |
