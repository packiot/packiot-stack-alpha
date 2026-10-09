# Production promotion — branch reconciliation (2026-10)

**Status:** PREPARED, NOT PERFORMED. Branch `release/prod-promotion-2026-10` = `origin/staging` (`e6e22fc5`)
+ a normal merge of `origin/production` (`0d3872ac`) + two small adaptation commits. Nothing was deployed, no
protected branch was pushed, no terraform plan/apply was run, no secret value was read.
Companion docs: [readiness](production-promotion-readiness-2026-10-08.md) ·
[transplant runbook](production-promotion-transplant-runbook.md).

> **Merging the PR into `production` deploys prod** (`deploy-production.yml` runs on every push to
> `production`: `docker compose -f compose.production.yml build && up -d --remove-orphans` on the prod app box).
> It must wait for the user's explicit go **and** the database transplant window (runbook §5, step 5 is
> "deploy the promoted `production` branch"). Merging before the transplant would start staging-era services
> against prod's pre-medallion schema.

## 1. Shape of the branch
| | |
|---|---|
| Base | `origin/staging` @ `e6e22fc5` (1,445 commits ahead of `production`) |
| Merged in | `origin/production` @ `0d3872ac` (55 non-merge prod-only commits), merge commit `cf05dec6` |
| After merge | `production..release` = 1,448 commits, `release..production` = **0** (fast-forward superset) |
| Conflicts | **149 paths** (63 add/add, 49 content, 24 deleted-by-them, 12 deleted-by-us, 1 added-by-us) |
| Adaptations | `85e25fc6` F3 one-shots vs the transplanted schema (§4) · edge-api pin `8c6adfa` (§3) |

Conflict areas: `services/stream-engine` 55, `services/sparkplug-decoder` 25, `services/analytics-sync` 24,
`configs/superset` 20, `services/read-api` 8, `db/init-f3` 3, `tests/superset` 2, `terraform/production` 2,
`services/historian-gateway` 2, `db/superset` 2, submodules 3 (`edge-api`, `operator`, `edge-node-red`),
`compose.production.yml`, `.env.example`, `db/README.md`.

## 2. Resolution rules applied
1. **`services/**` → staging, wholesale.** Production's service code is the 09-07 forward-port *snapshot of
   staging* (`db290876` copied staging's renamed service dirs). Staging kept evolving it for a month, and later
   *deliberately* deleted some of it. The three prod-authored service fixes were checked one by one and are on
   staging (table below). The merged `services/` tree is byte-identical to staging's.
2. **Superset (`configs/superset`, `db/superset`, `tests/superset`, `scripts/superset`) → staging**, after checking each
   prod behaviour exists there: `DB_CONNECTION_MUTATOR` tenant stamp, AUTH_DB fail-safe + Cognito-OAuth gate,
   super-admin all-tenant (`is_all_tenant()`, qualified), guest role `all_datasource_access` (now on the dedicated
   `GuestViewer` role), speed model (`COALESCE(plc_speed, inferred_rate)`), `live_status.state_label`, the W3
   dashboard set (ported in #832, kept evolving through #1578). Prod-only helper scripts
   (`scripts/superset/materialize_query_context.py`, `import_new_dashboards.py`) are kept as-is (no conflict).
3. **Prod config is preserved:** `terraform/production/**` (superset.tf, bi_edge.tf, historian.tf, superset_init.sh,
   github runner, edge/dash/wiki, operator keys, DB-SG ingress, app_init `.env` keys), prod domains, the oauth2
   `.packiot.app` cookie scope, the operator SPA service, the inline opt-in historian-gateway, and the 09-07 F3
   snapshot. Relative to `origin/production`, `terraform/production` only **gains** staging's additions
   (`ci_runner.tf`, `outputs.tf`, `variables.tf`, `runner_repos += back4-api`, runner toolchain, nginx `/session`
   bypass + refdata CORS headers). `terraform validate` (offline, `-backend=false`) = **valid**.
4. **Renamed services take staging's names** (`compose.production.yml`), with the old names kept as network aliases
   (staging's S2 "flip" pattern), so any remaining caller of `refdata-api:9104`, `oeecloud-worker`, … still resolves.

## 3. Decision per prod-only commit (55)
K = keep (carried as-is) · S = superseded by staging (staging already has it or a newer equivalent) ·
A = adapted (carried, but changed to fit staging).

| Commit | Subject | Decision | Why |
|---|---|---|---|
| `3898f269` | bump edge-api → api_key non-disclosure (#174) + guest-token (#175) | S | prod pin `9c64118` is an ancestor of the final edge-api pin |
| `bfbccb12` | promote edge-api → P1 tenant-authz (#176) | S | pin `7151cb3` is an ancestor |
| `9855a6e2` | promote edge-api → P2 schema-integrity (#177) | S | pin `37d1536` is an ancestor |
| `14625803` | deploy operator → kiosk resilience + E1 dedup | S | operator pin `b26d3c2` is an ancestor of staging's `a53efb6` |
| `131cacfa` | superset W2 embedded-BI overlay + bundle | S | staging has the overlay, `compose.superset.yml`, RLS workflow and assets (newer) |
| `3b848bae` | superset DB_CONNECTION_MUTATOR tenant stamp | S | present on staging, extended to `packiot_analytics` names |
| `4e28e989` | prod-tf: escape `${GO_VERSION}` in app_init templatefile | K | prod TF; no conflict, present in merge |
| `f640557f` | oeecloud-worker: equipment shift/day refreshers + line lead live-state | S | `RefreshCurrentEquipmentShiftDay` is on staging's stream-engine (`internal/uns/uns.go`) |
| `66a94f3e` | superset guest role `all_datasource_access` | S | staging grants it on `GuestViewer` (Public stripped — safer) |
| `ccf4f3e6` | prod-tf: Superset infra + DB-SG ingress | K | prod infra (`superset.tf`, `superset_init.sh`, SG) |
| `08ea80ec` | superset AUTH_DB fail-safe, Cognito OAuth behind env | S | same gate on staging (`_USE_COGNITO_OAUTH`) |
| `f743abb7` | prod-tf: dash.packiot.app edge cutover | K | prod infra (`edge.tf`) |
| `73e81cf2` | prod-tf: bi.prod CloudFront + WAF + origin-lock | K | prod infra (`bi_edge.tf`) |
| `5d88759c` | prod OEE embed — edge-api mint + view fix | K/S | app_init + `01-superset-ro-role.sql` kept via staging's newer file; edge-api part → see `39840a8` row |
| `c1908576` | edge-api pin → CORS allow front.prod | S | `front.prod.packiot.app` is in the final pin's default CORS list |
| `06a1b2ef` | superset materialized query_context + admin tenant stamp | S | staging re-materializes + syncs every asset (#1255, #1370, #1578) |
| `25f98723` | prod: operator SPA + operator/refdata keys | K/A | kept (compose `operator`, `secrets.tf`, app_init); **adapted** `depends_on`/upstream `refdata-api` → `read-api` (renamed) |
| `145a2660` | ADR-0045 P1 reconnect-baseline decode hardening | S | same change merged to staging as `51df6970` (#787) |
| `82873c24` | superset super-admin all-tenant visibility | S | on staging (`is_all_tenant()`) |
| `ab864424` | qualify `current_tenant()` in `is_all_tenant()` | S | on staging (search-path safety block) |
| `8b6deee0` | full CPACK dashboard set + 5 bi.* views (W3) | S | ported to staging in #832 and evolved |
| `e705e6df` | defensive parsing in materialize_query_context.py | K | prod-only script, carried |
| `038c8fe1` | import helper for new dashboards | K | prod-only script, carried |
| `1cced062` | rebase 02-tenant-rls onto public-qualified base | S | staging's `02-tenant-rls.sql` |
| `2ad0d24f` | database extra as YAML mapping | S | staging asset format |
| `58de1173` | chart params as YAML mapping | S | staging asset format |
| `af9fb7fc` | finalizer numeric datasource + FK rebind | K | prod-only script, carried |
| `cab96ecf` | finalizer rebuilds queries from form_data | K | prod-only script, carried |
| `a08b7cf8` | speed trend grain PT5M → PT1H | S | staging chart (#1255 rework) |
| `8d5023e9` | docs: superset data-readiness | K | docs (`docs/plans/cpack-superset-dashboard-buildout.md`) + staging dashboards |
| `864c4f0f` | CPACK speed model actual-vs-ideal + inferred | S | staging `01-superset-ro-role.sql` has the inferred-rate model |
| `d7f60777` | Track A presentation hardening | S | staging assets (newer) |
| `c5bcf5b2` | tf: self-hosted CI runner + historian.tf | K | prod infra; `github_runner.tf` resolved to staging's superset of it |
| `ba9622bc` | tf: ASCII-only SG description | K | in staging's `github_runner.tf` too |
| `1ece2b92` | tf: durable multi-repo runner_init | K/S | staging's `runner_init.sh` = prod's + yarn/compose/buildx toolchain |
| `14d519f7` | live_status state_label | S | on staging |
| `33a36f4e` | app_init: edge-api JWT_SECRET into .env | K | prod TF |
| `91c2e805` | nginx: drop Cognito gate from operator vhost (B4) | K | prod TF |
| `1a6b22e9` | docs(naming): R2 promote v_operator_entities | K | docs; DB effect superseded by the transplant (staging's view set) |
| `66ed9259` | operator re-pin sidebar-fix + view enrich | S/K | pin `54c394a` is an ancestor; SQL doc kept |
| `08b812c5` | oauth2-gate dash + internal wiki.packiot.app (#983) | K | compose oauth2 `.packiot.app` scope + edge.tf + nginx |
| `53fc9c7d` | dash.packiot.app service directory | K | prod nginx |
| `27c74e33` | forward-port incr1: pins + config | S/K | pins are ancestors; `prod-ready-forward-port.md` kept |
| `db290876` | forward-port incr2+3: edge-api pin + renamed dirs + compose | S/A | renamed dirs → staging's; compose → staging's service names; edge-api pin → `8c6adfa` |
| `16d305ce` | forward-port incr4a: historian-gateway inline | K | prod compose (profile `historian`, opt-in, not started by default) |
| `7f07ef3a` | forward-port incr4b: F3 snapshot supplements + tooling | K | `db/init-f3/snapshot/15-…`, parity scripts |
| `7ebb4398` | docs: forward-port complete + runbook | K | docs |
| `28b50550` | historian-gateway opt-in + app_init HIST_* | K | prod compose + TF |
| `486608f7` | docs: verified prod cutover runbook | K | docs |
| `17e99016` | docs: snapshot regen delta | K | docs |
| `cc2dacb8` | cutover step 1: regenerate F3 snapshot + MANIFEST | K | `db/init-f3/*` taken from **production** (the record of what prod runs; only prod consumes it) |
| `07b9cf3b` | cutover step 2: parity gate + neopac exclusion | K | `DEBRIS.exclude` |
| `30e7a31b` | revert csadmin pin to 7af3aa6 (runner PAT) | S + **open** | staging pins csadmin `a0ab759`; see blocker B3 |
| `1e7adc69` | repoint healthchecks to renamed binaries | S | staging's prod compose already uses the new binaries |
| `bcc72b44` | read-api: retire Firebase IdP on prod (#159) | K/S | code: staging (`cognito_only`); compose: prod's removal of `FIREBASE_PROJECT_ID` kept |

**Prod-only edge-api change carried by adaptation:** prod pins edge-api `39840a8` (branch `prod-forward-port`) =
an ancestor of staging's pin **plus one commit**, *feat(superset-embed): origin-lock header + CSRF handshake*
(`SUPERSET_ORIGIN_VERIFY`). Staging's pin `ac671d0` lacks it, so taking staging's pin would have silently dropped it.
It was cherry-picked onto `ac671d0` (conflict with #269's language-variant broker resolved by keeping both; the
three language-variant specs now mock the csrf leg; `jest src/usecases/superset-embed` 15/15, `tsc --noEmit` clean)
as **`8c6adfa`** on edge-api branch `release/prod-promotion-2026-10`, draft PR **packiot/edge-api#297** into
`staging`. The release branch pins `edge-api` at `8c6adfa`.

**Inspected, not merge decisions:** csadmin's prod pin `7af3aa6` carries #16/#17 (enterprise edit "block Save on a
failed prefetch", site/area weekly-schedule mappers, users name/email mapping, shift-form `FormProvider`). It was
already the merge-base pin, so it is not a prod-only change, but `7af3aa6` is not an ancestor of staging's
`a0ab759`. Staging has the `FormProvider` and `user_name` mapping; the **prefetch overwrite guard and the
`*ApiToForm` mappers were not found** (staging remodelled week fields in #37, which may cover the schedule part).
A trial cherry-pick conflicts in 5 files → needs a csadmin PR or proof of supersession (blocker B4).

## 4. Adaptations made for the promoted prod (commit `85e25fc6`)
- **`db-schema-f3` guard.** It skips only if `public.agg_equipment_values_1min` exists. After the transplant that cagg
  is `silver.agg_equipment_values_1min`, so the one-shot would replay the 09-07 F3 snapshot over the new schema and
  (strict layer fails) block `db-migrate`, which every app service depends on. Now: either schema satisfies it.
- **`db/init-f3/knex-baseline.sql`** creates an unqualified `knex_migrations`. With staging's DB-level `search_path`
  (transplant `create` phase) that lands in `gold` as an empty shadow ledger (the t231 / #1153 class).
  Added `SET LOCAL search_path = public;` (no-op on today's prod).

## 5. What the prod deploy does on push to `production`
`deploy-production.yml` (runner labels `self-hosted, production, linux, arm64`, i.e. the prod app box):
checkout → `git submodule update --init --force edge-api operator csadmin` → `ln -sf /opt/packiot/.env .env` →
`docker compose -f compose.production.yml build` → `up -d --remove-orphans` → `ps` + error-log diagnostic.
Project name `stack`. Active profiles come from `/opt/packiot/.env` (`COMPOSE_PROFILES`); prod today runs the
`client-ingest` profile (edge-transformer, ingest-shim and operator-adapter are up). `build-wiki.yml` also runs on push
to `production`. On the PR itself only `gitleaks`, `build-wiki` (docs/adr paths) and `dashboard-lint` trigger;
`pr-validation`, `go-services`, `superset-rls-isolation` only run for PRs into `staging`/`development`.

### 5a. Service delta on the prod app box
| Today (container) | After promotion | Change |
|---|---|---|
| adminer, app-redis, csadmin, edge-api, grafana, hasura, loki, mosquitto, oauth2-proxy, operator, pgbouncer, prometheus, promtail, rabbitmq | same names | rebuilt from staging code/pins; `csadmin` and `operator` from new submodule pins |
| `oeecloud-worker` | `stream-engine` | **renamed** (same dir `services/stream-engine`, IP .20, alias `oeecloud-worker`) — queues `oeecloud-worker-q*` → `stream-engine-q*`, secret → `rabbitmq-stream-engine-creds` |
| `edge-transformer` (client-ingest) | `sparkplug-decoder` | **renamed** (IP .23, alias kept, same queue `edge-transformer-q`, same outbox volume) — secret → `rabbitmq-sparkplug-decoder-creds` |
| `refdata-api` | `read-api` | **renamed** (IP .26, alias `refdata-api`, ports unchanged) |
| `operator-adapter` (client-ingest) | `operator-gateway` | **renamed** (IP .31, alias kept, cert path unchanged) |
| ingest-shim (client-ingest) | ingest-shim | unchanged name |
| one-shots `db-init-bootstrap`, `db-schema-f3`, `db-knex-baseline`, `db-migrate`, `hasura-init` | same | `db-schema-f3`/`db-knex-baseline` adapted (§4); `db-migrate` runs edge-api `8c6adfa` knex (ledger pinned to `public`) |
| — | `historian-gateway` (profile `historian`) | defined, **not started** (opt-in, unchanged from prod) |

`--remove-orphans` stops and removes the four old-named containers in the same `up`. **New services: none.** The
staging-maintained `compose.production.yml` carries the same 25 services as today; staging runs 49. Services that
run on staging and are **absent** from the promoted prod compose: `edge-session-broker` (ADR-0057 box access),
`customize`, `barcode-service` + `barcode-app`, `analytics-sync`, `oeecloud-fanout`, observability
(`postgres-exporter`, `node-exporter`, `redis-exporter`, `cadvisor`, `blackbox-exporter`, `alloy`, `tempo`,
`alertmanager`), `cloudbeaver`, `pgweb-analytics`, `ollama`; plus staging-only rigs (plc-sim, s7, agents, twins,
sandbox operators, legacy-replicator(-sbx), mirror-worker-go, simulator, edge-nodered). Each needs a keep-off /
bring-to-prod decision (B6).

### 5b. Config the promoted services read with **different values than staging**
The staging-maintained prod compose lags staging's own service config. With no env set, code defaults apply:

| Service | Staging sets | Prod compose → code default |
|---|---|---|
| stream-engine | `OEE_CANONICAL_APQ_ENABLED=true`, `OEE_AVAIL_FLOOR_ENABLED=true` | **false / false** → different OEE math than staging |
| stream-engine | `PO_AVAILABILITY_ENABLED`, `EVENTS_CLOSE_STALE_ENABLED`(+`_ENTERPRISES`), `BRONZE_RAW_APPEND`, `BOXES_BRIDGE_ENABLED`, `SHIFT06/SAP13/BOXES13/SYNC06_REPORT_ENABLED` = true | all **false** |
| stream-engine | `ROLLUP_SHIFT_LIMIT=75`, `ROLLUP_BACKFILL_LIMIT=50`, `WORKER_TENANT_ALLOWLIST`, `CPAC_EVENT_LIVE_ENTERPRISES`, `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS` | 300 / 200 / empty (all tenants) / empty / empty |
| sparkplug-decoder | `BIRTH_BOUND_RESOLVER=refdata` (+`REFDATA_URL`, `REFDATA_INTERNAL_KEY`), `F3_PER_TENANT_ROUTING`, `OEE_PROFILE_FROM_DB`, `PHASE9_LINE_AGG_ENABLED`, `CALC_NO_SPEED_GUARD_FALLBACK`, `COUNTERS_ONLY_IDEAL_RATES` | `map` resolver, rest off/unset — ADR-0061 device-key resolution not engaged |
| read-api | `DB_USER=readapi_ro` (NOBYPASSRLS, t276), `INTERNAL_API_KEY`, `HIST_GW_*`, `OPERATOR_SUPERADMIN_CROSS_TENANT_ENABLED=true` | `${POSTGRES_USER}` (owner), unset, defaults (no gateway running), **false** |
| edge-api | `EDGE_API_COGNITO_AUTH_ENABLED`, `AUTH_BEARER_ENABLED`, `EDGE_API_ONBOARDING/TEARDOWN_ENABLED`, `PO_STALENESS_GATE_*`, `REDIS_URL`, `ONBOARD_GENERATE_URL`, `EDGE_SESSION_BROKER_*`, `SSM_*` | from `/opt/packiot/.env` if present (app_init writes `EDGE_API_COGNITO_AUTH_ENABLED`, `COGNITO_*`, `ONBOARD_API_KEY`), otherwise dark |
| oauth2-proxy | redis session store | cookie store |

Tenant lists on staging (`3,4,5,2000003`) name staging tenants; prod has enterprises 1 and 3.

### 5c. Env / secret **names** the prod side must provide (names only, no values were read)
Interpolated by the promoted `compose.production.yml` (34 vars; only `OEECLOUD_WORKER_REPLICAS` is new, defaulted):
- required, no default: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_HOST_UPSTREAM`, `RABBITMQ_USER`,
  `RABBITMQ_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `OAUTH2_PROXY_CLIENT_SECRET`, `OAUTH2_PROXY_COOKIE_SECRET`, `ONBOARD_API_KEY`
  (all written by `app_init.sh` today);
- defaulted (empty if unset): `REFDATA_QUERY_API_KEYS`, `OPERATOR_EDGE_API_KEY`, `OPERATOR_REFDATA_API_KEY`, `OPERATOR_API_KEY`,
  `OPERATOR_ADAPTER_ENTERPRISE_ID`, `OPERATOR_ADAPTER_TOPIC_PREFIX`, `INGEST_API_KEY`, `INGEST_ROUTING_KEY`, `INGEST_SCOPE_GROUP`,
  `REDIS_URL`, `COGNITO_AUTH_ENABLED`, `AWS_REGION`, `AUTHENTIK_DB_PASSWORD`, `CSADMIN_FIREBASE_*` (6), `HIST_GW_PASSWORD`,
  `HISTORIAN_BUCKET`, `HIST_AWS_KEY`, `HIST_AWS_SECRET`, `OEECLOUD_WORKER_REPLICAS`.

Read from `/opt/packiot/.env` via `env_file` by the new code (prod-side decision whether to set):
`EDGE_API_COGNITO_AUTH_ENABLED`, `COGNITO_USER_POOL_ID`, `COGNITO_CS_ADMIN_GROUP`, `JWT_SECRET`, `SUPERSET_BASE_URL`,
`SUPERSET_GUESTTOKEN_ADMIN_USER`, `SUPERSET_GUESTTOKEN_ADMIN_PASSWORD`, `SUPERSET_OEE_DASHBOARD_UUID`, `SUPERSET_ORIGIN_VERIFY`
(all already emitted by `app_init.sh`), plus for parity: `SUPERSET_OEE_DASHBOARD_UUID_PT`, `INTERNAL_API_KEY`,
`READAPI_RO_USER`/`READAPI_RO_PASSWORD`, `HIST_GW_SVC_PASSWORD`, `EDGE_SESSION_BROKER_TOKEN`, `CORS_ALLOWED_ORIGINS` (optional).

AWS Secrets Manager ids referenced by the promoted compose:
- `packiot/production/db`, `packiot/production/refdata-query-keys` — exist (secrets.tf);
- **`packiot/production/rabbitmq-stream-engine-creds`** and **`packiot/production/rabbitmq-sparkplug-decoder-creds`** —
  **not in `terraform/production/secrets.tf`** (it declares `rabbitmq-oeecloud-creds` and
  `rabbitmq-edge-transformer-creds`). The matching RabbitMQ users (`stream-engine`, `sparkplug-decoder`) and their
  permissions on `stream-engine-q*` must exist in prod's broker (prod RabbitMQ has no `definitions.json`; users live in
  the `rabbitmq-data` volume).

DB roles after the transplant (runbook §6.4/6.5): `readapi_ro`, `histgw_ro` (prod has `hist_gw_ro`), extensions
`btree_gist`, `dblink`, `pg_stat_statements`.

## 6. Blockers and open decisions before the go
| # | Item | Why it blocks |
|---|---|---|
| B1 | Create SM secrets `rabbitmq-stream-engine-creds` + `rabbitmq-sparkplug-decoder-creds` **and** the RabbitMQ users/permissions | stream-engine and the decoder cannot authenticate to AMQP → no ingest/OEE |
| B2 | Queue rename: `oeecloud-worker-q*` → `stream-engine-q*` | old queues stay bound to `oee` and fill up unconsumed; drain then delete after cutover |
| B3 | Prod runner PAT cannot fetch `csadmin` (`30e7a31b`); the release pins csadmin `a0ab759` (+ new operator/edge-api shas) | `Fetch submodules` fails → deploy aborts before build. Grant the PAT csadmin access first |
| B4 | csadmin #16/#17 (prefetch overwrite guard, `*ApiToForm` mappers) not in staging's csadmin | possible regression of a prod fix; port or prove superseded |
| B5 | Service config parity (§5b) | prod would compute OEE with flags staging turned on months ago; needs a reviewed `compose.production.yml` parity change (tenant lists for prod's ents 1, 3) |
| B6 | Services absent from prod compose (§5a) | decide per service: observability, edge-session-broker, customize, barcode, analytics-sync, fanout |
| B7 | edge-api#297 | the release pins edge-api `8c6adfa`, reachable only from that branch until merged into edge-api `staging` |
| B8 | Transplant + runbook §6 decisions (CPACK config sync, retention, events gap since 08-12, Hasura metadata, roles/extensions) | the deploy must follow the transplant, never precede it |
| B9 | `historian-gateway` inline definition is the 09-07 shape (DB `postgres`, no OOM guards) | harmless while the profile is off; switch to `compose.historian-gateway.yml` before enabling a prod cold tier |
| B10 | `monitoring/prometheus/prometheus.yml` is staging's (scrapes services prod doesn't run) | targets show down; no Alertmanager on prod |

## 7. Checks run locally (2026-10-08)
- `docker compose -f compose.production.yml config --no-interpolate -q` OK (also `compose.staging.yml`,
  `compose.superset.yml`, `compose.historian-gateway.yml`, `dev/compose.yml`); profiles `client-ingest` + `historian` resolve.
- `scripts/ci/packml-ratchet.sh` OK (213 files, 1,166 lines, nothing new).
- `terraform validate` on `terraform/production` (copy, `init -backend=false`, no AWS calls) → valid.
- edge-api `8c6adfa`: `jest src/usecases/superset-embed` 15/15, `tsc --noEmit` clean.
