---
title: ADR index
layer: 4
owner_area: platform
last_verified: 2026-09-28
---
# ADR index

> **Layer 4 · Reference** — every Architecture Decision Record in `docs/adr/`: number, title,
> status as written in the file, and the decision in one line. For finding why something is
> the way it is. Up: [Architecture overview](../architecture/overview.md)

How to read this table:

- **Status is copied from the ADR file** on 2026-09-28. Many ADRs still say "Proposed" although
  parts shipped; the file's own "shipped" notes (and the code) are the truth. Numbers 0029,
  0039, 0042, 0046, 0049, 0050 and 0057 are each used by **two** ADRs; 0030, 0047 and 0048
  have no top-level file (0047 notes live under `docs/adr/reference/`).
- Paths are given as repository paths (not links) because `docs/adr/reference/` is not part of
  the published site. Open them on GitHub or in your checkout.

| # | Title | Status | Decision in one line | File |
|---|---|---|---|---|
| 0001 | Edge persistence for soft-real-time PLC data under intermittent connectivity | Proposed | Local TimescaleDB on each factory PC as the canonical store; cloud sync is a separate retryable process | `docs/adr/0001-edge-persistence-intermittent-connectivity.md` |
| 0002 | Firebase Auth Emulator for staging↔prod auth parity | Proposed | Use the Firebase emulator as staging auth backend (later superseded by Cognito, ADR-0034) | `docs/adr/0002-firebase-auth-emulator-staging.md` |
| 0003 | Production deployment of the parent stack | Proposed | New prod environment structurally identical to staging, separate Terraform/secrets/domain | `docs/adr/0003-production-deployment-parent-stack.md` |
| 0004 | Edge-nodered config centralization per client | Proposed | One declarative per-client config file is the source of truth for client-varying settings | `docs/adr/0004-edge-nodered-config-centralization.md` |
| 0005 | Edge-nodered self-hosted runner deployment per factory | Proposed | Standardise a per-factory self-hosted runner for edge deploys | `docs/adr/0005-edge-nodered-self-hosted-runner-deploys.md` |
| 0006 | Workflow infrastructure refactor for enterprise-grade CI/CD | Proposed | Adopt eight CI/CD patterns (OIDC, pinning, gates, …) in phases | `docs/adr/0006-workflow-infrastructure-refactor.md` |
| 0007 | Frontend write topology: synchronous-local-or-queued-remote | Deferred (2026-06-30) | Criticality decides cloud- vs factory-authoritative writes; edge-api is the single API surface | `docs/adr/0007-frontend-write-topology.md` |
| 0008 | Phase 2 split: comparator service + deferred data layer | Proposed | Split ADR-0003 phase 2 into a comparator phase and a deferred data-layer phase | `docs/adr/0008-phase-2-comparator-split.md` |
| 0009 | Edge transformer (Go) service + Node-RED responsibility split | Accepted — implemented | Split Node-RED along a logic-type seam; protocol logic moves to a Go edge-transformer | `docs/adr/0009-edge-transformer-go-service-and-nodered-split.md` |
| 0010 | Sparkplug B decode in Go (end-state for protocol processing) | Accepted — implemented 2026-07-06 | Decode Sparkplug B in Go; MQTT is the ingest path | `docs/adr/0010-sparkplug-decode-in-go-end-state.md` |
| 0011 | Durability boundary and store-and-forward pattern | Accepted — implemented | Durability starts where data enters Packiot software: outbox + retained NBIRTH | `docs/adr/0011-durability-boundary-and-store-and-forward.md` |
| 0012 | Schema refactor: multi-tenancy pool pattern + naming unification | Accepted — in execution | Pool multi-tenancy with façade views preserving BI-facing names; unify cagg naming | `docs/adr/0012-schema-refactor-and-multitenancy-pool.md` |
| 0013 | Shadow-mirror service for operator-action parity | Accepted — implemented (retires at flip) | Small Go service replays operator actions into the shadow flows | `docs/adr/0013-shadow-mirror-service.md` |
| 0014 | Extract OEE math from PostgreSQL into application layer | Accepted — implemented | OEE math moves from DB procedures into the Go engine, proven at parity | `docs/adr/0014-extract-oee-math-from-database-to-app.md` |
| 0015 | Customer-facing composable query API + screen customization | Proposed | Build the curated read API first; composable customer queries later if demanded | `docs/adr/0015-customer-facing-query-api.md` |
| 0016 | Staging consolidation to ONE flow: the master plan | Accepted — gates pending | Freeze, compare side by side, then flip staging to one flow | `docs/adr/0016-staging-consolidation-master-plan.md` |
| 0017 | Endgame target architecture: process separation + enterprise hardening | Accepted | Extract engine packages verbatim into separate processes; harden for enterprise | `docs/adr/0017-endgame-process-separation-and-enterprise-hardening.md` |
| 0018 | Operator + frontend integration makeover | Proposed | Every frontend: reads → refdata/read-api, writes → edge-api; retire the Node-RED BFF | `docs/adr/0018-operator-frontend-integration-makeover.md` |
| 0019 | Edge customization capabilities | Proposed | Give every Incoplast-class quirk a governed home in the edge config | `docs/adr/0019-edge-customization-capabilities.md` |
| 0020 | Incoplast as a staging test tenant | Proposed | Run Incoplast (ent 4) as a staging test tenant | `docs/adr/0020-incoplast-staging-test-tenant.md` |
| 0021 | The multi-tenancy model: two tiers, tenant as first-class descriptor | Proposed | Two-tier tenancy with a per-tenant descriptor; factories cannot assume reliable connectivity | `docs/adr/0021-multitenancy-model.md` |
| 0022 | Pre-flip behavior-correctness validation (both tenants) | Proposed | Validate CPACK and Incoplast as mirrored tenants before the flip | `docs/adr/0022-pre-flip-behavior-correctness-validation.md` |
| 0023 | Concurrent PO-across-lines: segment-derived running state | Proposed | Operator-driven second runtime segment; PLC-driven fan-out deferred | `docs/adr/0023-concurrent-po-across-lines.md` |
| 0024 | Phased mirror retirement | Proposed | Retire the two mirrors independently, in risk order (three cutovers, not one) | `docs/adr/0024-phased-mirror-retirement.md` |
| 0025 | Three-flow prod-authoritative PO-state reconciliation | Proposed | Mirror gains a prod-driven close/pause direction fanned to all flows | `docs/adr/0025-three-flow-po-state-reconciliation.md` |
| 0026 | API-layer consolidation | Proposed | Two APIs: edge-api (writes) + refdata-api (reads); retire Hasura, primary-api, back4-api | `docs/adr/0026-api-layer-consolidation.md` |
| 0027 | refdata-api Surface-1: the curated, tenant-safe read contract | Proposed | Curated read contract; replace positional static key→tenant map | `docs/adr/0027-refdata-api-surface-1-read-contract.md` |
| 0028 | front4 Refactor & Modernization Roadmap | Proposed | Phased front4 modernization on top of the consolidated APIs | `docs/adr/0028-front4-refactor-modernization-roadmap.md` |
| 0029 | Decisions resolved (2026-07-20) | (resolution record) | Answers to the open questions of the front4 ADRs (e.g. migrate PlcStatusTile stub as-is) | `docs/adr/0029-decisions-resolved-2026-07-20.md` |
| 0029 | front4 dashboard composition engine + calc/metric/graph layer | Proposed | Collapse dashboard forks into three families on one composition/metric layer | `docs/adr/0029-front4-dashboard-composition-and-metric-layer.md` |
| 0031 | back4-api retirement: shims, datasets, Hasura sequence | Proposed | Contract shims + new read datasets + Hasura (Wave 4) retirement order | `docs/adr/0031-back4-api-retirement-shims-datasets-and-hasura-sequence.md` |
| 0032 | Collapse the staging three-flow parallel-run to F3 | Proposed (staging only) | F3 (now "analytics") becomes the sole telemetry-compute flow on staging | `docs/adr/0032-collapse-to-single-flow-f3.md` |
| 0033 | Unify client-user authentication on Firebase JWT | Proposed (issuer superseded by 0034) | One JWT model across reads, writes and operator with per-tenant isolation | `docs/adr/0033-unified-firebase-jwt-auth.md` |
| 0034 | Adopt AWS Cognito (via Amplify Auth) as the identity provider | Proposed (in use on staging) | Cognito replaces Firebase; oauth2-proxy replaces Authentik for staff gates | `docs/adr/0034-adopt-cognito-amplify-auth.md` |
| 0035 | Redis application cache + refdata-api cache-aside layer | Proposed (in use on staging) | Dedicated `app-redis` with cache-aside in the read API | `docs/adr/0035-redis-cache-layer.md` |
| 0036 | Data Architecture: streaming Bronze/Silver/Gold medallion on Timescale | Proposed (partially shipped) | Four-tier medallion on TimescaleDB plus an immutable historian; no bought historian | `docs/adr/0036-data-architecture-medallion.md` |
| 0037 | OEE Correctness Remediation | Proposed (partially shipped) | Prioritized OEE fixes, each placed in a medallion layer, with data-quality alarms | `docs/adr/0037-oee-correctness-remediation.md` |
| 0038 | North-Star target architecture: the full-fledged factory platform | Proposed | Frames the long-term platform; supporting ADRs stay valid | `docs/adr/0038-north-star-factory-platform.md` |
| 0039 | Entity lifecycle & deletion strategy | Proposed | One delete contract, temporal columns, SCD-2 history for dimensions | `docs/adr/0039-entity-lifecycle-deletion-strategy.md` |
| 0039 R5 | Reasons-dimension contract plan | Proposed | Drop the `equipments.*_reasons` jsonb via a dual-read sequence | `docs/adr/0039-reasons-dimension-contract-plan.md` |
| 0040 | Barcode / quality capture / track-and-trace | Proposed | One Go `barcode-service`, immutable `box_scans` fact, server-side gapless sequences | `docs/adr/0040-barcode-traceability-service.md` |
| 0041 | GCP exit → AWS-native lakehouse (S3 + Glue + Athena) | Proposed | Replace BigQuery with an S3 lakehouse; single-cloud teardown checklist | `docs/adr/0041-gcp-exit-lakehouse.md` |
| 0042 | Separated Edge Gateway | Proposed | Split the client edge into connectivity plane, Go Sparkplug agent and governed client CI/CD | `docs/adr/0042-separated-edge-gateway.md` |
| 0042 P1 | CPACK Mode-A tee: front-door + cutover spec | (spec) | CPACK Node-RED tees tags to a cloud sparkplug-agent over HTTPS | `docs/adr/0042-cpack-tee-frontdoor.md` |
| 0043 | CS-Admin-owned tenant conversion profile + register-driven agent tag map | Proposed | Tag map generated from the register; flag `AGENT_TAGMAP_FROM_REGISTER` (default off) | `docs/adr/0043-cs-admin-register-driven-tagmap.md` |
| 0044 | id-driven Parameter decomposition | Proposed | Decompose bare `Status/Parameter` into canonical `Parameter<NNNNN>`; flag-gated | `docs/adr/0044-parameter-decomposition.md` |
| 0045 | CS-Admin-driven Client Onboarding Architecture | Proposed | One CS-Admin-authored client descriptor per tenant; everything else generated | `docs/adr/0045-client-onboarding-architecture.md` |
| 0046 | The Edge-Source Plugin Contract | Draft | The plugin contract is the BIRTH declaration, not a runtime string grammar | `docs/adr/0046-edge-source-plugin-contract.md` |
| 0046 | Product analytics for front4: self-hosted PostHog | Proposed (design only) | Gated self-hosted PostHog pilot with a kill criterion; Matomo fallback | `docs/adr/0046-product-analytics-posthog.md` |
| 0049 | Reaching the client factory box: AWS SSM | Proposed | SSM hybrid activations + Session Manager + RunCommand as access and deploy substrate | `docs/adr/0049-edge-deploy-last-mile-automation.md` |
| 0049 | OEE Correctness: count-spike guard, availability floor, A×P×Q | Proposed (shipped behind flags) | Structural spike guard: no valid baseline ⇒ re-seed and emit 0 | `docs/adr/0049-oee-correctness.md` |
| 0050 | PLC Type Profiles | Proposed | Generate tags from a reusable PLC-type layout × members | `docs/adr/0050-plc-type-profiles.md` |
| 0050 | Rename the "F3" plane label to "analytics" | Accepted (safe parts landed); env cutover planned | Rename in three buckets by blast radius | `docs/adr/0050-rename-f3-plane-to-analytics.md` |
| 0051 | `packml_register` is a generated routing table; unroutable topics must alert | Proposed | Cloud-side late binding; register is generated, never hand-authored; alert on unroutable | `docs/adr/0051-packml-register-generated-only-and-unroutable-alerting.md` |
| 0052 | Edge autonomy during internet outages | Informational | Device-side outage capability already exists; documents limits | `docs/adr/0052-edge-autonomy-during-internet-outages.md` |
| 0053 | On-prem ingest edge (relocate the pre-RabbitMQ stack to the box) | Proposed + partially implemented (B-minimal) | Local decode + current state + dashboard on the box | `docs/adr/0053-on-prem-ingest-edge-for-outage-autonomy.md` |
| 0054 | On-prem edge-operator: offline-tolerant operator writes | Accepted (2026-09-02) | Durable forward-only write queue on the box | `docs/adr/0054-on-prem-edge-operator-outage-writes.md` |
| 0055 | On-prem operator offline auth | Accepted (design, 2026-09-03) | Cached token + local JWKS on the box | `docs/adr/0055-onprem-operator-offline-auth.md` |
| 0056 | One application DB with schemas, not a control-plane split | Accepted (2026-09-09) | Keep a single app DB, separated by schemas | `docs/adr/0056-single-app-db-with-schemas-not-control-plane-split.md` |
| 0057 | Historian storage architecture | Proposed (2026-09-14) | Medallion-aligned names now; Apache Iceberg on S3 as the end state | `docs/adr/0057-historian-storage-architecture-and-medallion-naming.md` |
| 0057 | Platform-mediated box access: browser-native SSM session broker | Proposed | edge-api brokers SSM sessions for CS engineers (edge-session-broker) | `docs/adr/0057-platform-mediated-box-access-ssm-broker.md` |
| 0058 | Client-customization capability | Proposed | Sandboxed expression-derived metrics + governed Node-RED | `docs/adr/0058-client-customization-capability.md` |
| 0059 | Customization observability, rollback, Tier-2 editor round-trip | Proposed | Observability, rollback and editor round-trip for ADR-0058 phases | `docs/adr/0059-customization-observability-rollback-editor.md` |

## Reference material under `docs/adr/reference/`

Execution plans and runbooks that belong to ADRs (not ADRs themselves), e.g.
`0012-naming-map.md`, `0016-flip-runbook.md`, `0016-endstate-schema-map.md`,
`0032-f2-collapse-execution-plan.md`, `0034-jit-user-migration-lambda.md`,
`adr-0047-packml-is-internal-wire-contract.md`, `production-buildout-roadmap.md`,
`production-recut-runbook.md`, `production-w1-db-tier-rewire.md`,
`production-w3-readplane-repoint.md`, `naming-ledger.md`. Runbooks among them are indexed in
[Runbooks](../operations/runbooks.md).
