# ADR-0026 — API-layer consolidation: edge-api (writes) + refdata-api (reads), retire Hasura + primary-api + back4-api

**Status:** Proposed · **Date:** 2026-07-16 · **Builds on:** ADR-0015 (customer-facing query API / refdata-api), ADR-0017 (endgame process separation), ADR-0021 (multitenancy model — server-side `customer_id` injection) · **Relates to:** ADR-0023 (Hasura parity views), ADR-0002 (Firebase/Hasura auth), the endgame roadmap · **Decision owner:** product owner (2026-07-16).

## Context — API sprawl

The platform currently exposes several overlapping API tiers:

| Service | Role today | Fate |
|---|---|---|
| `edge-api` | CS-Admin CRUD + factory control plane (PO control, downtimes, shifts, config) | **keep — becomes the write/control plane** |
| `refdata-api` | read surface: "legacy contract + composable query API," stateless, per-tenant (ADR-0017) | **keep — becomes the read/query surface** |
| `primary-api` | main cloud product API | **retire — fold into edge-api / refdata-api** |
| `back4-api` | additional cloud API tier | **retire — fold into edge-api / refdata-api** |
| `hasura` | GraphQL over Postgres — customer reads + front4 auth glue | **retire (reversibly) — reads move to refdata-api** |

Four+ API tiers means multiple auth models, duplicated business logic, cross-service hops for a single user action, and — most dangerously — **more than one place that must enforce per-tenant isolation.** The endgame (ADR-0017) already anticipates a two-service end state; this ADR makes the consolidation and the Hasura retirement explicit.

## Decision

Consolidate to a **CQRS-lite two-API end state**, and retire the rest:

1. **`edge-api` = the write / control plane.** *All* mutations and business logic: PO lifecycle (behind the #32 staleness gate + audit log), downtimes, shifts, equipment/enterprise config, CS-Admin onboarding. Serves the **write** needs of CS Admin, front4, and operator. Every write goes through here so the gate, `user_logs` audit trail, and PO invariants cannot be bypassed.
2. **`refdata-api` = the read / query surface.** Curated, tenant-safe reads with **server-side `customer_id` injection** (ADR-0021) as the single tenant-isolation authority. Serves the **read** needs of front4, CS Admin, operator, and customers — including a controlled **"saved view" mechanism** so a user can query a view they built, *scoped to their tenant*, without exposing the raw schema.
3. **Retire `primary-api` + `back4-api`.** Inventory every endpoint, fold **writes → edge-api** and **reads → refdata-api**. They become façades-then-nothing (same-shape façade during transition, then removed).
4. **Retire Hasura — reversibly (product-owner decision, 2026-07-16).** Its customer-read role moves to refdata-api. **Do NOT delete Hasura's metadata (`hdb_catalog`) or config — stop *serving* it.** If a genuine ad-hoc / power-user GraphQL need arises later, it can be re-stood-up from the preserved metadata. This is a *stop*, not a *destroy*.
5. **GraphQL boundary (whenever GraphQL exists — refdata-api feature or a re-stood-up Hasura):** **reads only.** No mutations through GraphQL — every write stays on edge-api REST, so the gate/audit/invariants hold.
6. **`cq-logs-bigquery` → all-AWS (S3), for staging.** The stack is AWS-native; BigQuery is a lone GCP dependency for a stub that never shipped. Retarget the export to **S3** (date-partitioned), with **Athena** on top if SQL-queryability is needed. Staging is **greenfield** for BigQuery (confirmed — no consumer), so zero migration cost there. Any prod BigQuery consumer is handled as a separate decision.

## Why this shape

- **One place enforces tenant isolation.** The single most important reason to retire Hasura for the customer surface: Hasura's row/column permission model is a *second* isolation system that must be kept in sync with the app's `customer_id` injection — and a single misconfiguration leaks one factory's data to another. refdata-api's server-side injection (ADR-0021) makes tenant isolation a single, auditable authority.
- **The façade insulates consumers from the schema.** The whole migration discipline is keeping consumers off the raw DB schema via same-shape façades (so renames/refactors don't ripple outward — cf. ADR-0023 T9, where Hasura's direct schema coupling is "the largest blast radius"). refdata-api *is* that façade for reads; Hasura's direct table exposure fights it.
- **Fewer services = smaller operational + security surface**, aligning with ADR-0017's process-separation endgame.
- **CQRS-lite is the right seam.** Writes (few, business-logic-heavy, must be gated) and reads (many, flexible, scale horizontally) have genuinely different shapes; one service each keeps both healthy and prevents edge-api from becoming a read+write+analytics monolith.

## Consequences & the load-bearing sequencing

**Hasura cannot retire until its consumers are re-pointed.** front4 (and any report/consumer) reads through Hasura today (ADR-0002, ADR-0023). So the order is non-negotiable:

| Step | What | Gate |
|---|---|---|
| 1 | **refdata-api covers Hasura's read surface** — the queries front4/CS-Admin/operator need + the tenant-scoped saved-view mechanism | read-parity vs the current Hasura responses, per consumer |
| 2 | **Re-point consumers** front4 → refdata-api (same-shape responses) | each consumer verified on refdata-api |
| 3 | **Stop serving Hasura** (keep `hdb_catalog` + config for reversibility) | no consumer still calling Hasura; documented re-stand-up path |
| 4 | **Inventory + fold primary-api / back4-api** — writes → edge-api, reads → refdata-api, behind façades | per-endpoint parity |
| 5 | **Retire primary-api / back4-api** | 30-day frozen-read window per the endgame decommission discipline |
| 6 | **cq-logs → S3** (staging, greenfield now) | S3 export verified; Athena optional |

**Costs / risks**
- refdata-api must *build* the flexibility Hasura gave for free (the saved-view / composable-query mechanism) — real design work (safe parameterized queries, per-tenant scoping, injection prevention). This is the price of the single-auth surface; it's worth it for a customer-facing read API.
- Re-pointing front4 is the delicate step (its reads are Hasura-shaped today) — same-shape façade + parity check per query, or front4 changes.
- Retiring primary-api/back4-api needs a complete endpoint inventory first (unknown consumers are the risk) — the security fixes (#30/#52) are stopgaps on these retiring services until then.

## Reversibility (the product-owner's "if the need arises")
Hasura retirement is a **stop, not a destroy**: preserve `hdb_catalog`, the metadata migrations, and the compose service definition (parked behind a profile, like alertmanager). Re-standing it up is then a config flip + a metadata reload — hours, not a rebuild. Document the re-stand-up runbook when Hasura is parked.

## Relationship to existing decisions
- **Realizes** ADR-0017's two-service end state and **extends** ADR-0015 (refdata-api) to explicitly absorb the customer-read role from Hasura + the saved-view need.
- **Depends on** ADR-0021's server-side `customer_id` injection as the single tenant-isolation authority that makes retiring Hasura's permission layer safe.
- **Interacts with** ADR-0023: the "Hasura/OEE parity views" become refdata-api read endpoints; the segment-derived recast lands in refdata-api rather than Hasura metadata.
- **Sequences after** the OEE-compute cutover (ADR-0024/0025 mirror retirement) is a separate track — this is the *API/read-path* consolidation, runnable in parallel once refdata-api read-parity is proven.

## Open questions
1. **The saved-view mechanism's shape** — a registry of named parameterized views (safest), a constrained query DSL, or a re-stood-up read-only Hasura for the *internal* audience only? (Decide at refdata-api design time.)
2. **primary-api / back4-api endpoint inventory** — needed before retirement; unknown external consumers are the blocker.
3. **Prod cq-logs** — is there a prod BigQuery consumer? (Staging is greenfield; prod is a separate check.)
