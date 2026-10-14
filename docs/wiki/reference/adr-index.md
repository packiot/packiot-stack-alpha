---
title: ADR index
layer: 4
owner_area: platform
last_verified: 2026-10-13
---
# ADR index

> **Layer 4 · Reference** — every Architecture Decision Record in `docs/adr/`: number, title,
> status as written in the file, and the decision in one line. For finding why something is
> the way it is. Up: [Architecture overview](../understand/architecture/overview.md)

How to read this table:

- **Title and status are copied from the ADR file** on 2026-10-13 (status trimmed at the
  date/scope that follows it). Many ADRs still say "Proposed" although parts shipped; the
  file's own progress notes (and the code) are the truth. For example ADR-0061 says
  "Proposed" while several of its phases are already merged on staging.
- Numbers 0029, 0039, 0042, 0046, 0049, 0050 and 0057 are each used by **two** files. 0030,
  0047 and 0048 have no top-level file (ADR-0047 lives under `docs/adr/reference/`).
- Title links open the ADR inside this site. Files under `docs/adr/reference/` are not
  published; they are given as repository paths.

| # | Title | Status | Decision in one line |
|---|---|---|---|
| 0001 | [Edge persistence for soft-real-time PLC data under intermittent connectivity](../adr/0001-edge-persistence-intermittent-connectivity.md) | Proposed | Local TimescaleDB on each factory PC as the canonical store; cloud sync is a separate retryable process |
| 0002 | [Firebase Auth Emulator for staging↔prod auth parity](../adr/0002-firebase-auth-emulator-staging.md) | Proposed | Use the Firebase emulator as staging auth backend (later superseded by Cognito, ADR-0034) |
| 0003 | [Production deployment of the parent stack](../adr/0003-production-deployment-parent-stack.md) | Proposed | New prod environment structurally identical to staging, separate Terraform/secrets/domain |
| 0004 | [Edge-nodered config centralization per client](../adr/0004-edge-nodered-config-centralization.md) | Proposed | One declarative per-client config file is the source of truth for client-varying settings |
| 0005 | [Edge-nodered self-hosted runner deployment per factory](../adr/0005-edge-nodered-self-hosted-runner-deploys.md) | Proposed | Standardise a per-factory self-hosted runner for edge deploys |
| 0006 | [Workflow infrastructure refactor for enterprise-grade CI/CD](../adr/0006-workflow-infrastructure-refactor.md) | Proposed | Adopt eight CI/CD patterns (OIDC, pinning, gates, …) in phases |
| 0007 | [Frontend write topology: synchronous-local-or-queued-remote](../adr/0007-frontend-write-topology.md) | Deferred (was Proposed; deferred 2026-06-30) | Criticality decides cloud- vs factory-authoritative writes; edge-api is the single API surface |
| 0008 | [Phase 2 split: comparator service + deferred data layer](../adr/0008-phase-2-comparator-split.md) | Proposed (amends ADR-0003 phase 2) | Split ADR-0003 phase 2 into a comparator phase and a deferred data-layer phase |
| 0009 | [Edge transformer (Go) service + Node-RED responsibility split](../adr/0009-edge-transformer-go-service-and-nodered-split.md) | Accepted — implemented (edge-transformer live on staging; blessed 2026-07-06) | Split Node-RED along a logic-type seam; protocol logic moves to a Go edge-transformer |
| 0010 | [Sparkplug B decode in Go (end-state for protocol processing)](../adr/0010-sparkplug-decode-in-go-end-state.md) | Accepted — implemented 2026-07-06 (10.9 cutover: MQTT is THE ingest; blessed 2026-07-06) | Decode Sparkplug B in Go; MQTT is the ingest path |
| 0011 | [Durability boundary and store-and-forward pattern](../adr/0011-durability-boundary-and-store-and-forward.md) | Accepted — implemented (outbox + retained-NBIRTH durability live on staging; blessed 2026-07-06) | Durability starts where data enters Packiot software: outbox + retained NBIRTH |
| 0012 | [Schema refactor: multi-tenancy pool pattern + naming unification](../adr/0012-schema-refactor-and-multitenancy-pool.md) | Accepted — in execution (Waves 0–2 done, Wave 3 partial, Wave 4 prepared; blessed 2026-07-06) | Pool multi-tenancy with façade views preserving BI-facing names; unify cagg naming |
| 0013 | [Shadow-mirror service for operator-action parity across the 3-flow POC](../adr/0013-shadow-mirror-service.md) | Accepted — implemented (retires at the flip, R1; blessed 2026-07-06) | Small Go service replays operator actions into the shadow flows |
| 0014 | [Extract OEE math from PostgreSQL into application layer](../adr/0014-extract-oee-math-from-database-to-app.md) | Accepted — implemented (engine live at measured parity 0/13,162 + 0/13,432; blessed 2026-07-06) | OEE math moves from DB procedures into the Go engine, proven at parity |
| 0015 | [Customer-facing composable query API + screen customization](../adr/0015-customer-facing-query-api.md) | PROPOSED (2026-07-02) | Build the curated read API first; composable customer queries later if demanded |
| 0016 | [Staging consolidation to ONE flow: the master plan](../adr/0016-staging-consolidation-master-plan.md) | Accepted — flip runbook prepared, gates pending (blessed 2026-07-06) | Freeze, compare side by side, then flip staging to one flow |
| 0017 | [Endgame target architecture: process separation + enterprise hardening](../adr/0017-endgame-process-separation-and-enterprise-hardening.md) | Accepted (blessed by decider Emmanuel Podestá, 2026-07-07, relayed via session) | Extract engine packages verbatim into separate processes; harden for enterprise |
| 0018 | [Operator + frontend integration makeover: retire the Node-RED BFF, one read/write split everywhere](../adr/0018-operator-frontend-integration-makeover.md) | Proposed (2026-07-07) | Every frontend: reads → refdata/read-api, writes → edge-api; retire the Node-RED BFF |
| 0019 | [Edge customization capabilities: every Incoplast-class intricacy gets a home](../adr/0019-edge-customization-capabilities.md) | Proposed (2026-07-08) | Give every Incoplast-class quirk a governed home in the edge config |
| 0020 | [Incoplast as a staging test tenant](../adr/0020-incoplast-staging-test-tenant.md) | Proposed (2026-07-08) | Run Incoplast (ent 4) as a staging test tenant |
| 0021 | [The multi-tenancy model: two tiers, and the tenant as a first-class descriptor](../adr/0021-multitenancy-model.md) | Proposed (2026-07-08) | Two-tier tenancy with a per-tenant descriptor; factories cannot assume reliable connectivity |
| 0022 | [Pre-flip behavior-correctness validation (both tenants)](../adr/0022-pre-flip-behavior-correctness-validation.md) | Proposed | Validate CPACK and Incoplast as mirrored tenants before the flip |
| 0023 | [Concurrent PO-across-lines: segment-derived running state](../adr/0023-concurrent-po-across-lines.md) | Proposed | Operator-driven second runtime segment; PLC-driven fan-out deferred |
| 0024 | [Phased mirror retirement: decouple the data-cutover from the action-cutover](../adr/0024-phased-mirror-retirement.md) | Proposed | Retire the two mirrors independently, in risk order (three cutovers, not one) |
| 0025 | [Three-flow prod-authoritative PO-state reconciliation](../adr/0025-three-flow-po-state-reconciliation.md) | Proposed | Mirror gains a prod-driven close/pause direction fanned to all flows |
| 0026 | [API-layer consolidation: edge-api (writes) + refdata-api (reads), retire Hasura + primary-api + back4-api](../adr/0026-api-layer-consolidation.md) | Proposed | Two APIs: edge-api (writes) + refdata-api (reads); retire Hasura, primary-api, back4-api |
| 0027 | [refdata-api Surface-1: the curated, tenant-safe read contract](../adr/0027-refdata-api-surface-1-read-contract.md) | Proposed | Curated read contract; replace positional static key→tenant map |
| 0028 | [front4 Refactor & Modernization Roadmap](../adr/0028-front4-refactor-modernization-roadmap.md) | Proposed | Phased front4 modernization on top of the consolidated APIs |
| 0029 | [Decisions resolved (2026-07-20)](../adr/0029-decisions-resolved-2026-07-20.md) | *(no status line; amends ADR-0029)* | Answers to the open questions of the front4 ADRs (e.g. migrate PlcStatusTile stub as-is) |
| 0029 | [front4 dashboard composition engine + calc/metric/graph layer](../adr/0029-front4-dashboard-composition-and-metric-layer.md) | Proposed | Collapse dashboard forks into three families on one composition/metric layer |
| 0031 | [back4-api retirement: external-contract shims, net-new refdata datasets, internal endpoint homes, and the Hasura (Wave-4) retirement sequence](../adr/0031-back4-api-retirement-shims-datasets-and-hasura-sequence.md) | Proposed | Contract shims + new read datasets + Hasura (Wave 4) retirement order |
| 0032 | [Collapse the staging three-flow parallel-run to the refactored flow (F3) as the sole telemetry-compute flow](../adr/0032-collapse-to-single-flow-f3.md) | Proposed | F3 (now "analytics") becomes the sole telemetry-compute flow on staging |
| 0033 | [Unify client-user authentication on Firebase JWT (reads + writes + operator), with per-tenant isolation](../adr/0033-unified-firebase-jwt-auth.md) | Proposed (issuer superseded by ADR-0034) | One JWT model across reads, writes and operator with per-tenant isolation |
| 0034 | [Adopt AWS Cognito (via Amplify Auth) as the identity provider, replacing Firebase](../adr/0034-adopt-cognito-amplify-auth.md) | Proposed | Cognito replaces Firebase; oauth2-proxy replaces Authentik for staff gates |
| 0035 | [Redis application cache + refdata-api cache-aside layer](../adr/0035-redis-cache-layer.md) | Proposed | Dedicated `app-redis` with cache-aside in the read API |
| 0036 | [Data Architecture: a streaming Bronze/Silver/Gold medallion on Timescale, with an immutable historian tier](../adr/0036-data-architecture-medallion.md) | Proposed (partially SHIPPED — see §10) | Four-tier medallion on TimescaleDB plus an immutable historian; no bought historian |
| 0037 | [OEE Correctness Remediation: prioritized findings, each slotted into a medallion layer](../adr/0037-oee-correctness-remediation.md) | Proposed (Step 0 + output-clamp SHIPPED — see §8) | Prioritized OEE fixes, each placed in a medallion layer, with data-quality alarms |
| 0038 | [North-Star target architecture: the full-fledged factory platform](../adr/0038-north-star-factory-platform.md) | Proposed | Frames the long-term platform; supporting ADRs stay valid |
| 0039 | [Entity lifecycle & deletion strategy: one delete contract, temporal columns, and SCD-2 history for dimensions](../adr/0039-entity-lifecycle-deletion-strategy.md) | Proposed | One delete contract, temporal columns, SCD-2 history for dimensions |
| 0039 R5 | [Reasons-dimension CONTRACT plan (drop the `equipments.*_reasons` jsonb)](../adr/0039-reasons-dimension-contract-plan.md) | Proposed | Drop the `equipments.*_reasons` jsonb via a dual-read sequence |
| 0040 | [Barcode / Quality-capture / Track-and-Trace: one consolidated `barcode-service`, an immutable `box_scans` Bronze fact, and server-side gapless sequence authority](../adr/0040-barcode-traceability-service.md) | Proposed | One Go `barcode-service`, immutable `box_scans` fact, server-side gapless sequences |
| 0041 | [GCP Exit → single cloud: an AWS-native lakehouse (S3 + Glue + Athena) replacing BigQuery, plus the single-cloud teardown checklist](../adr/0041-gcp-exit-lakehouse.md) | Proposed | Replace BigQuery with an S3 lakehouse; single-cloud teardown checklist |
| 0042 P1 | [CPACK Mode-A tee: front-door + cutover spec](../adr/0042-cpack-tee-frontdoor.md) | *(no status line; companion spec)* | CPACK Node-RED tees tags to a cloud sparkplug-agent over HTTPS |
| 0042 | [Separated Edge Gateway: split the client edge into a connectivity plane, a Go SparkPlug agent, and a governed client CI/CD](../adr/0042-separated-edge-gateway.md) | Proposed | Split the client edge into connectivity plane, Go Sparkplug agent and governed client CI/CD |
| 0043 | [CS-Admin-owned tenant conversion profile + register-driven agent tag map](../adr/0043-cs-admin-register-driven-tagmap.md) | Proposed (2026-07-23) | Tag map generated from the register; flag `AGENT_TAGMAP_FROM_REGISTER` (default off) |
| 0044 | [id-driven Parameter decomposition (bare `Status/Parameter` → canonical `Parameter<NNNNN>`)](../adr/0044-parameter-decomposition.md) | Proposed (2026-07-23) | Decompose bare `Status/Parameter` into canonical `Parameter<NNNNN>`; flag-gated |
| 0045 | [CS-Admin-driven Client Onboarding Architecture](../adr/0045-client-onboarding-architecture.md) | Proposed | One CS-Admin-authored client descriptor per tenant; everything else generated |
| 0046 | [The Edge-Source Plugin Contract (native agent ⇄ HighByte ⇄ any)](../adr/0046-edge-source-plugin-contract.md) | Draft (core decisions settled 2026-07-30) | The plugin contract is the BIRTH declaration, not a runtime string grammar |
| 0046 | [Product analytics for front4: self-hosted PostHog (heatmaps · session replay · funnels)](../adr/0046-product-analytics-posthog.md) | Proposed (DESIGN ONLY — build/provision gated) | Gated self-hosted PostHog pilot with a kill criterion; Matomo fallback |
| 0049 | [Reaching the Client Factory Box: AWS SSM as the Connectivity, Access & Deploy Substrate](../adr/0049-edge-deploy-last-mile-automation.md) | Proposed | SSM hybrid activations + Session Manager + RunCommand as access and deploy substrate |
| 0049 | [OEE Correctness: count-spike guard, availability floor, A×P×Q reconciliation](../adr/0049-oee-correctness.md) | Proposed (code SHIPPED behind flags — safe defaults) | Structural spike guard: no valid baseline ⇒ re-seed and emit 0 |
| 0050 | [PLC Type Profiles: derive the tag map from a reusable layout, don't hand-author it per endpoint](../adr/0050-plc-type-profiles.md) | Proposed | Generate tags from a reusable PLC-type layout × members |
| 0050 | [Rename the "F3" plane label to "analytics" (+ deploy-facing env cutover plan)](../adr/0050-rename-f3-plane-to-analytics.md) | Accepted (safe parts landed) · Env cutover: PLANNED (staged, not yet executed) | Rename in three buckets by blast radius |
| 0051 | [`packml_register` is a Generated Routing Table (Cloud-Side, Late-Binding), and Unroutable Topics Must Alert](../adr/0051-packml-register-generated-only-and-unroutable-alerting.md) | Proposed | Cloud-side late binding; register is generated, never hand-authored; alert on unroutable. Superseded in cloud scope by ADR-0061 |
| 0052 | [Edge autonomy during internet outages](../adr/0052-edge-autonomy-during-internet-outages.md) | Informational — the device-side capability is already built and live; one residual gap is a blocked, decision-gated follow-up | Device-side outage capability already exists; documents limits |
| 0053 | [On-prem ingest edge (relocate the pre-RabbitMQ stack to the box)](../adr/0053-on-prem-ingest-edge-for-outage-autonomy.md) | Proposed (durability half) + PARTIALLY IMPLEMENTED (visibility half, "B-minimal", 2026-09-01) | Local decode + current state + dashboard on the box |
| 0054 | [On-prem edge-operator: offline-tolerant operator writes (ADR-0019-C3 realization)](../adr/0054-on-prem-edge-operator-outage-writes.md) | Accepted (2026-09-02) | Durable forward-only write queue on the box |
| 0055 | [On-prem operator offline auth (cached token + local JWKS)](../adr/0055-onprem-operator-offline-auth.md) | Accepted (design) — 2026-09-03 | Cached token + local JWKS on the box |
| 0056 | [One application DB with schemas, not a control-plane split](../adr/0056-single-app-db-with-schemas-not-control-plane-split.md) | Accepted (2026-09-09) | Keep a single app DB, separated by schemas |
| 0057 | [Historian storage architecture: medallion-aligned naming now, Apache Iceberg on S3 as the end-state](../adr/0057-historian-storage-architecture-and-medallion-naming.md) | Proposed (2026-09-14) | Medallion-aligned names now; Apache Iceberg on S3 as the end state |
| 0057 | [Platform-mediated box access: a browser-native SSM session broker](../adr/0057-platform-mediated-box-access-ssm-broker.md) | Proposed | edge-api brokers SSM sessions for CS engineers (edge-session-broker) |
| 0058 | [A mature client-customization capability (declarative transforms + governed Node-RED)](../adr/0058-client-customization-capability.md) | Proposed | Sandboxed expression-derived metrics + governed Node-RED |
| 0059 | [Customization observability, rollback, and the Tier-2 editor round-trip](../adr/0059-customization-observability-rollback-editor.md) | Proposed | Observability, rollback and editor round-trip for ADR-0058 phases |
| 0060 | [Local development environment: service slices + an anonymized CPACK dev seed](../adr/0060-local-development-environment-and-cpack-dev-seed.md) | Proposed | Developers run one or a few services ("slices") on a laptop against an anonymized ~7-day CPACK seed; replaces the stale `compose.development.yml` |
| 0061 | [Remove PackML from the cloud: identity declared at birth, roles declared in the descriptor](../adr/0061-remove-packml-from-the-cloud.md) | Proposed | Each machine gets a permanent `device_key` declared in the client descriptor and sent in its birth message; the cloud binds by key and metric role, not by PackML topic names. Supersedes ADR-0047 and ADR-0051 (cloud scope) |
| 0062 | [Production-order identity: a text client number, one internal key, a UUIDv7 handle](../adr/0062-production-order-identity-and-alphanumeric-numbers.md) | Accepted — steps 1–3 live on staging (2026-10-08); step 4 (contract) pending client moves | The client PO number is text (`id_order_text`, NOT NULL, unique per enterprise; APIs add it as `order_number`); `id_production_order` stays the only internal key; a UUIDv7 `po_uuid` is the handle for ids minted outside the DB; the integer `id_order` is dropped in the last step |
| 0063 | [Is TimescaleDB still needed in the analytics database?](../adr/0063-timescaledb-necessity.md) | Proposed (2026-10-14, rewritten) | Not necessary, but coupled: 1.9 M rows/day fits plain partitioned PostgreSQL and the historian (cold tier) already runs PG 16 + pg_duckdb without TimescaleDB, but the engine reads two continuous aggregates as inputs. Target: hot = partitioned PostgreSQL with engine-maintained rollups, cold = Parquet + DuckDB. Phase A cleanup done (#1774–#1778); B and C ≈ 4–6 engineer-weeks; timing vs the promotion is the user's call |

## Reference material under `docs/adr/reference/`

Execution plans and runbooks that belong to ADRs (not ADRs themselves), e.g.
`0012-naming-map.md`, `0016-flip-runbook.md`, `0016-endstate-schema-map.md`,
`0032-f2-collapse-execution-plan.md`, `0034-jit-user-migration-lambda.md`,
`adr-0047-packml-is-internal-wire-contract.md` (superseded in cloud scope by ADR-0061),
`production-buildout-roadmap.md`, `production-recut-runbook.md`,
`production-w1-db-tier-rewire.md`, `production-w3-readplane-repoint.md`, `naming-ledger.md`.
Runbooks among them are indexed in [Runbooks](../build/operate/runbooks.md).
