# ADR-0021 — The multi-tenancy model: two tiers, and the tenant as a first-class descriptor

- **Status**: Proposed (2026-07-08) — decider: Emmanuel Podestá.
- **Supersedes the "duplicate containers per tenant" framing** of
  [ADR-0020](0020-incoplast-staging-test-tenant.md) with a principled model;
  ADR-0020's Incoplast tenant becomes the *validation* of this model.

## Context: we built one axis of multi-tenancy, not both

The schema refactor ([ADR-0012](0012-schema-refactor-and-multitenancy-pool.md))
delivered **data multi-tenancy**: tenants share a schema, separated by a
`customer_id` column (the pools). This is real and necessary — but it is the easy
axis. It answers "can two tenants' *rows* coexist without bleeding into each other?"

Onboarding Incoplast ([the assessment](../clients/incoplast-migration-assessment.md))
forced the hard axis into view: **capability and configuration multi-tenancy.**
Tenants do not merely differ in data — they differ in *shape*:

- a different operator surface (Incoplast runs a **local, offline** operator UI; CPACK
  uses the standard cloud SPA),
- different **customization flows** (custom counter calc, ERP-dimension mapping, reel
  tracking),
- different **integrations** (Incoplast has a two-way on-prem Oracle ERP sync),
- different **capabilities** (Incoplast's operator writes parameters *down to the
  PLC* — a command path CPACK never needs).

A `customer_id` column does nothing for any of that. Today the stack handles this
axis *ad hoc*: the edge-facing services are pinned one-enterprise-per-container
(`ID_ENTERPRISE`, one `client.yaml` per transformer), and there is no first-class
notion of "what a tenant *is*" beyond its rows. That is tenant-per-deployment, not a
multi-tenancy model. This ADR defines the model.

## Decision: multi-tenancy is two-tier, because factories run offline

The single fact that shapes everything: **a factory floor cannot assume reliable
internet.** Incoplast's local operator UI exists for exactly this reason. You cannot
serve an offline floor from a shared cloud service. Therefore multi-tenancy here is
not "one deployment for everyone" — it is deliberately **two tiers**, each with a
different sharing model:

```
  CLOUD TIER — shared, genuinely multi-tenant (one deployment, all tenants)
  ┌──────────────────────────────────────────────────────────────────────┐
  │  oeecloud-worker · edge-api · refdata-api · PostgreSQL pools           │
  │  cloud operator SPA  ← resolves tenant PER SESSION (not per container) │
  │  Isolation is a PROPERTY here: every read/write scoped to the caller's │
  │  tenant server-side; no client can name another tenant.                │
  └──────────────────────────────────────────────────────────────────────┘
                        ▲  serves online tenants / dashboards
                        │
  EDGE TIER — per-factory deployment (one stack per physical factory)
  ┌──────────────────────────────────────────────────────────────────────┐
  │  edge Node-RED · edge-transformer · (optional) local operator SPA     │
  │  · governed customization flows                                        │
  │  Per-factory is CORRECT, not a limitation: each factory is its own     │
  │  edge box, offline-capable, running its own tenant descriptor.         │
  └──────────────────────────────────────────────────────────────────────┘
```

"Proper multi-tenancy" is therefore **not** collapsing the edge into shared infra —
that would fight the domain. It is (1) making the *cloud* tier truly multi-tenant, and
(2) making a *tenant* a first-class, portable descriptor that both tiers consume.

## The tenant descriptor (the thing we are missing)

A tenant becomes a single, declarative descriptor — not a scatter of `ID_ENTERPRISE`
envs and forked flows. It has four parts:

1. **Identity & data** — enterprise/site/area/equipment, `packml_register`, the
   `customer_id` that scopes the pools. (Exists.)
2. **Config** — `client.yaml` v1.1: PLC endpoints (incl. S7 rack/slot), equipment
   mapping (incl. ERP dimensions), shifts. (Schema growth — ADR-0019 / task C0.)
3. **Capabilities** — declarative flags: `operator.mode: edge|cloud`,
   `integrations[]` (ERP connector), `commands.enabled` (operator→PLC). The cloud
   tier and the edge deployment both read these to decide what to stand up.
4. **Customizations** — governed Node-RED flows, versioned per tenant, passing the
   governance lint ([ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md)).

Secrets are always **by reference**, never inline (the Incoplast export's cleartext
Oracle credentials are the standing cautionary tale).

## What must change

| Area | Today | Under this model |
|------|-------|------------------|
| Cloud operator SPA | pinned per container via `ID_ENTERPRISE` | resolves tenant **per session** from login/entities; one deployment serves all cloud tenants |
| `id_enterprise` | positional, hardcoded as literal in 3 service envs | resolved from the DB by name at startup (ADR-0020 R1) — the descriptor names the tenant, not a magic number |
| Tenant definition | scattered (envs + seed order + forked flows) | one descriptor (identity + config + capabilities + customizations) |
| Edge operator | Incoplast forks a 556-node bespoke UI | the standard SPA deployed at the edge (`operator.mode: edge`), offline-capable — ADR-0019 G3 |
| Customizations | ungoverned per-customer forks | governed flows behind a CI lint — ADR-0009 |
| Isolation | pools scope by `customer_id`; unproven with 2 tenants | an explicit isolation guarantee + a segregation test as a merge gate |

The cloud tier is *already* most of the way there (worker, edge-api, refdata scope by
tenant server-side). The concrete cloud work is the operator's per-session tenant
resolution and the `id_enterprise` de-fragilization. The edge tier's work is the
ADR-0019 capabilities (edge operator, command channel, ERP connector) plus the
customization governance.

## Isolation as a guarantee, not a hope

Because the cloud tier is shared, isolation must be *proven*, not assumed. Two
mechanisms:

- **Server-side scoping everywhere** — every cloud read/write derives the tenant from
  the authenticated caller (the refdata `X-Api-Key → customer_id` pattern), never from
  a client-supplied id. This already holds in refdata; it becomes a rule for every new
  cloud endpoint.
- **A segregation test as a merge gate** — a test that runs *two* tenants through the
  shared cloud tier and asserts zero cross-tenant bleed (pool reads, refdata datasets,
  a rollup). This is the check that turns "we think it's multi-tenant" into "we measure
  it," and it runs on the isolated `packiot_refactor` sandbox so it never touches the
  parity bake.

## Consequences

- Positive: a real answer to "what is a tenant," portable across staging and prod; the
  cloud tier scales to N tenants without N deployments; the edge stays honest to the
  offline-factory reality; onboarding a factory becomes "write a descriptor," and
  Incoplast validates the whole thing before prod ever onboards a second real factory.
- Negative: the cloud operator's per-session tenant resolution is real work (it is
  pinned today); the isolation gate must be built and kept green; the descriptor format
  must be designed to span both tiers cleanly.
- This ADR is the **foundation** the Incoplast layers and prod onboarding sit on. It
  does not itself onboard Incoplast — it defines the model Incoplast proves.

## Sequencing

1. **Design the descriptor + the isolation gate** (this ADR → a concrete schema + test).
2. **Validate data isolation** in the sandbox with two tenants (the segregation gate).
3. **Make the cloud operator per-session multi-tenant** + `id_enterprise` from-DB.
4. **Then** the ADR-0019 edge capabilities (edge operator, command channel, ERP), each
   a `capabilities` flag the descriptor turns on.
5. Incoplast is the running validation throughout — the tenant whose shape exercises
   every part of the model.

## References

ADR-0012 (data multi-tenancy — the pools) · ADR-0019 (edge capabilities — the
`capabilities` this model makes declarative) · ADR-0020 (Incoplast tenant — the
validation) · ADR-0009 (customization governance) ·
`docs/guide/07-customizations-and-real-factories.md` ·
`docs/clients/incoplast-migration-assessment.md`.
