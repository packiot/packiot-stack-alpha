# ADR-0022 — Pre-flip behavior-correctness validation (both tenants)

**Status:** Proposed · **Date:** 2026-07-08 · **Builds on:** [ADR-0016](0016-staging-consolidation-master-plan.md) (the flip), [ADR-0020](0020-incoplast-staging-test-tenant.md) (Incoplast test tenant), [ADR-0021](0021-multitenancy-model.md) (multi-tenancy model)

## Context — what the bake proves, and what it does not

The flip ([ADR-0016](0016-staging-consolidation-master-plan.md)) promotes F3
(`packiot_shadow`) to the one database. The confidence for it comes from the **bake**:
the [three-flow comparator](0008-phase-2-comparator-split.md) diffs F1 vs F3 and asserts
**data parity** — the refactored flow produces the same rows as the legacy flow. That is
necessary but it has two blind spots:

1. **It checks parity, not correctness of *behavior*.** "F3 equals F1" says the refactor
   didn't change the numbers. It does not, on its own, exercise whether the stack *does
   the right thing* across a factory's full surface — PO lifecycle, downtime
   classification, command execution, ERP round-trips, operator flows — only that two
   pipelines agree on the tables the comparator reads.
2. **It covers CPACK only, and CPACK is a *clean* tenant.** `cpack.yaml` has no
   customizations; CPACK runs the standard pipeline on real mirrored prod data. The
   hard tenant — Incoplast, with custom counters, ERP sync, operator→PLC commands, and a
   bespoke operator surface — has **zero** behavior coverage today. It is not mirrored
   into any running environment, its customizations are not ported, its capabilities have
   never been exercised.

So a green bake is not the same as *"the refactored stack behaves correctly for the real
range of tenants we intend to run on it."* This ADR closes that gap **before the flip**.

## Decision

Validate **each client — CPACK and Incoplast — as a mirrored tenant in the existing
staging stack**, using the same three-flow machinery CPACK already runs on. There is
**no isolated harness and no separate database**. A client's *legacy baseline* is its
**current production behavior**, captured by mirroring its real data and operator actions
into staging and letting them flow through F1/F2/F3.

This works because of a fact the original design missed: **both CPACK and Incoplast run
through the legacy oeecloud engine in production today, and F1 (`source_type=""`,
`packiot.public`) reproduces exactly that engine.** So for either tenant, F1 fed with the
client's real mirrored data *is* a faithful replay of what that client's production does
now. Diffing F1↔F3 through the [existing comparator](0008-phase-2-comparator-split.md)
therefore asserts, per tenant, "the refactored stack produces the same results the client
sees in production today" — which is precisely the pre-flip evidence we need.

Concretely, a client becomes a validated tenant in staging by wiring the **two mirrors**
the stack already provides:

| Mirror | What it carries | Mechanism |
|--------|-----------------|-----------|
| **Data mirror** | the client's real SparkPlug B production data | a tee node in the client's **live Node-RED** republishes its metric stream into staging's mirror ingestion (for CPACK this is `mirror-worker-go` reading prod SELECT-only; for Incoplast, a Node-RED tee into the same ingestion path) |
| **Operator-action mirror** | the client's real operator actions (PO lifecycle, justifications, commands) | `shadow-mirror` replays operator writes into staging |

Once both mirrors feed a tenant's real production stream into staging, the transformer
stamps each message with all three `source_type` values, the worker fans it to F1/F2/F3,
the OEE cascade runs per-tenant off database rows (tenancy is data, not table names — see
[ADR-0012](0012-schema-refactor-and-multitenancy-pool.md)/[ADR-0021](0021-multitenancy-model.md)),
and the comparator diffs the flows. The staging stack *is* the multi-tenant validation
environment; validating a second tenant is a matter of mirroring it in, not standing up a
parallel stack.

## Superseded design — why the isolated harness was dropped

The originally-proposed mechanism (PR #385) was a separate `packiot_validation` database
and a dedicated `-val` compose stack (`compose.validation.yml`,
`deploy-validation.yml`, `mosquitto-val`) that stood the refactored services against a
fresh DB built from migrations, isolated from the bake.

That was **over-engineered and strictly weaker**, and it has been removed:

- **It was single-flow.** With one `packiot_validation` DB there is no F1/F3 split, so the
  comparator could not run (`BAKE_COMPARATOR_ENABLED=false` in the harness) — the very
  mechanism that proves "refactored == legacy" was absent. It could only assert against
  hand-written golden fixtures, never against the client's actual production behavior.
- **It was redundant.** The staging three-flow stack already *is* a multi-tenant,
  parity-proving environment. Everything the harness would build (fan-out to F1/F2/F3, the
  comparator, the OEE cascade, the mirrors) already exists there and is already trusted for
  CPACK. A second, lesser copy added maintenance surface for no capability.
- **Its isolation premise was moot.** The harness existed to keep the bake untouched. But a
  second tenant's data is scoped to its own `id_enterprise` and does not appear on CPACK's
  per-equipment comparator surfaces (see [ADR-0020](0020-incoplast-staging-test-tenant.md)),
  so mirroring Incoplast into staging does not perturb the CPACK bake — the isolation the
  harness bought was isolation we did not need.

The lesson: when you already have a parity environment, validate *inside* it. A separate
single-flow harness cannot prove parity by construction.

## What "behavior correctness" means, concretely

Validated per tenant, by diffing F1↔F3 through the comparator plus a set of behavior
assertions layered on top:

### Both tenants (the shared spine)
- **OEE cascade** — `equipment_values → agg_equipment_values_1min → equipment_runtime_1hour
  → _shift/_1day/_1week/_1month`, area/line rollups: F3's computed A×P×Q at each grain
  matches F1's on the client's real mirrored data.
- **PO lifecycle** — start → running → pause → finish transitions (mirrored from the
  client's real operator actions) produce matching `production_orders_runtime` rows and OEE
  attribution across F1 and F3.
- **Downtime classification** — events land in `equipment_events` with the right
  `cd_category`/`planned_downtime`/`change_over`, and flow into availability identically.
- **Dirty-flag cascade** — a late correction re-arms `recalc_needed` up the grain ladder
  and F1/F3 recomputed totals still agree.
- **Tenant isolation** — the [ADR-0021 M1](reference/designs/0021-tenant-descriptor-and-isolation-gate.md)
  Level-2/3 checks: two tenants' data never cross — now exercised with two real mirrored
  tenants live in one staging stack.

### CPACK (the clean tenant)
- Standard pipeline on real mirrored prod data — behavior-level assertions layered over the
  data-parity the bake already provides.

### Incoplast (the customized tenant — the real work)
- **Custom counter calc** — its bespoke production count logic, ported to a governed flow
  ([B2](0019-edge-customization-capabilities.md)), produces counts that match its production.
- **ERP-dimension mapping** — `recurso`/`etapa` map onto equipment correctly.
- **Reel tracking** — its reel/roll lifecycle behaves.
- **Operator→PLC commands** ([C1](reference/designs/0019-C1-edge-command-channel.md)) — a
  `po_setup`/`param_write` from the operator surface reaches the PLC and takes effect,
  allow-listed and audited.
- **ERP round-trip** ([C2](reference/designs/0019-C2-erp-database-connector.md)) — against
  a mock ERP DB, POs/scrap read in and downtime/production write back, deduped.
- **Edge operator flows** ([C3](reference/designs/0019-C3-edge-operator-spa.md)) — the
  edge-deployed SPA's read/justify/command paths work against factory-local backends;
  offline reads serve from cache and writes fail closed.

## Phases

| Phase | Deliverable |
|-------|-------------|
| **V0** | This ADR — the concrete definition above + the mirrored-tenant mechanism. |
| **V1** | **Seed Incoplast into the staging stack and wire its two mirrors** — the Incoplast enterprise/site/area/equipment/`packml_register` seed applied; the data mirror (tee node in Incoplast's live Node-RED → staging mirror ingestion) and the operator-action mirror (`shadow-mirror`) both feeding its real production stream into staging, flowing through F1/F2/F3. CPACK is already there. |
| **V2** | **Incoplast's customizations/capabilities** made real in staging: [B2](0019-edge-customization-capabilities.md) customizations ported to governed flows; [C1](reference/designs/0019-C1-edge-command-channel.md)/[C2](reference/designs/0019-C2-erp-database-connector.md)/[C3](reference/designs/0019-C3-edge-operator-spa.md) capabilities enabled and wired. |
| **V3** | **Per-tenant F1↔F3 parity + behavior assertions** via the extended comparator: the comparator, scoped per tenant, plus golden behavior assertions → a per-tenant pass/fail verdict. |
| **V4** | Run it → the pre-flip behavior-correctness report for both tenants. |

## The flip-gating question (deliberately left open)

Whether a green V3 **gates the flip** (the flip waits) or **runs alongside** it (the flip
proceeds on its bake clocks, V3 grows as confidence and gates the *real Incoplast factory
connection* at Phase F instead) is a scheduling decision with real cost: V1–V3 is weeks,
because it includes building and porting Incoplast's real customizations, so gating the
flip on it delays the ~July-14 flip accordingly.

**This ADR does not decide that.** It builds the capability either way — V0+V1 are needed
regardless — and recommends deciding once V3 exists and its true cost is visible, rather
than pre-committing to a flip delay on an estimate.

## Consequences

- **Positive** — behavior correctness (not just data parity) becomes a checkable property
  for the real range of tenants, *inside the environment we already trust*. Reusing the
  three-flow comparator means F1↔F3 parity — "refactored equals what the client's
  production does today" — is provable per tenant, which a single-flow harness could never
  do. No parallel stack, no second database, no extra deploy surface to maintain.
- **Cost** — V2 pulls the Incoplast capability work ([B2](0019-edge-customization-capabilities.md)/C1/C2/C3
  wiring) forward from post-flip to pre-flip. That is the point, but it is real weeks. Also,
  Incoplast's real data now flows into staging, so its enterprise must be seeded and its two
  mirrors wired before validation can begin.
- **Reframes [ADR-0020](0020-incoplast-staging-test-tenant.md)** — Incoplast is stood up in
  the *existing* staging stack as a second mirrored tenant, and its Layer-A data source
  becomes its **real mirrored production** (data mirror + operator-action mirror), not the
  Python simulator. The simulator remains useful for synthetic load and for exercising
  variability, but the *baseline for parity* is the client's own production, because that is
  what "legacy behavior" means for a client already running on the legacy engine. The CPACK
  bake stays untouched: Incoplast's data is scoped to its own `id_enterprise` and never
  appears on CPACK's per-equipment comparator surfaces.

## Deploy note — refdata-api tenant key

`refdata-api`'s `QUERY_API_KEYS` is a comma-separated `key:customer_id` list. Staging ships
CPACK and the simulator keys in `compose.staging.yml`; this ADR's PR appends the Incoplast
entry `stg-incoplast-key:4` (matching Incoplast's `id_enterprise = 4`). If, in a given
environment, `QUERY_API_KEYS` is sourced from a secret / `.env` outside the repo rather than
from `compose.staging.yml`, the deployer must append `stg-incoplast-key:4` there by hand —
do **not** drop the existing CPACK/simulator entries.
