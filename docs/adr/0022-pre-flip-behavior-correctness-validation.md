# ADR-0022 — Pre-flip behavior-correctness validation (both tenants)

**Status:** Proposed · **Date:** 2026-07-08 · **Builds on:** [ADR-0016](0016-staging-consolidation-master-plan.md) (the flip), [ADR-0020](0020-incoplast-staging-test-tenant.md) (Incoplast test tenant), [ADR-0021](0021-multitenancy-model.md) (multi-tenancy model)

## Context — what the bake proves, and what it does not

The flip ([ADR-0016](0016-staging-consolidation-master-plan.md)) promotes F3
(`packiot_shadow`) to the one database. The confidence for it comes from the **bake**:
the comparator diffs F1 vs F3 and asserts **data parity** — the refactored flow produces
the same rows as the legacy flow. That is necessary but it has two blind spots:

1. **It checks parity, not correctness of *behavior*.** "F3 equals F1" says the refactor
   didn't change the numbers. It does not, on its own, exercise whether the stack *does
   the right thing* across a factory's full surface — PO lifecycle, downtime
   classification, command execution, ERP round-trips, operator flows — only that two
   pipelines agree on the tables the comparator reads.
2. **It covers CPACK only, and CPACK is a *clean* tenant.** `cpack.yaml` has no
   customizations; CPACK runs the standard pipeline on real mirrored prod data. The
   hard tenant — Incoplast, with custom counters, ERP sync, operator→PLC commands, and a
   bespoke operator surface — has **zero** behavior coverage today. It is not seeded in
   any running environment, its customizations are not ported, its capabilities have
   never been exercised.

So a green bake is not the same as *"the refactored stack behaves correctly for the real
range of tenants we intend to run on it."* This ADR closes that gap **before the flip**.

## Decision

Build a **reproducible both-tenant behavior-acceptance harness**: a compose-based
validation stack that stands the refactored services against a **fresh** refactored DB
(built from migrations — **never** `packiot_shadow`, so the bake is never perturbed),
seeds **both** a CPACK-shaped tenant and Incoplast, drives production with the simulator,
and **asserts behaviors** against golden expectations. A green run is the pre-flip
evidence that the stack is behaviorally correct for both a clean tenant and a
heavily-customized one.

It is a **harness, not a hand-maintained environment**: reproducible from migrations +
seeds + fixtures, runnable on demand and in CI, isolated from the bake.

## What "behavior correctness" means, concretely

The harness asserts, per tenant, against golden expectations:

### Both tenants (the shared spine)
- **OEE cascade** — `equipment_values → agg_equipment_values_1min → equipment_runtime_1hour
  → _shift/_1day/_1week/_1month`, area/line rollups: given a known production+downtime
  input, the computed A×P×Q at each grain matches the golden value (within tolerance).
- **PO lifecycle** — start → running → pause → finish transitions produce the correct
  `production_orders_runtime` rows and OEE attribution.
- **Downtime classification** — events land in `equipment_events` with the right
  `cd_category`/`planned_downtime`/`change_over`, and flow into availability correctly.
- **Dirty-flag cascade** — a late correction re-arms `recalc_needed` up the grain ladder
  and the recomputed totals match.
- **Tenant isolation** — the [ADR-0021 M1](reference/designs/0021-tenant-descriptor-and-isolation-gate.md)
  Level-2/3 checks: two tenants' data never cross (the pre-flip Level-1 gate already runs
  in CI; here it runs with live two-tenant data).

### CPACK (the clean tenant)
- Standard pipeline on realistic data — behavior-level assertions layered over the
  data-parity the bake already provides.

### Incoplast (the customized tenant — the real work)
- **Custom counter calc** — its bespoke production count logic, ported to a governed flow
  ([B2](0019-edge-customization-capabilities.md)), produces the golden counts.
- **ERP-dimension mapping** — `recurso`/`etapa` map onto equipment correctly.
- **Reel tracking** — its reel/roll lifecycle behaves.
- **Operator→PLC commands** ([C1](reference/designs/0019-C1-edge-command-channel.md)) — a
  `po_setup`/`param_write` from the operator surface reaches the (simulated) PLC and takes
  effect, allow-listed and audited.
- **ERP round-trip** ([C2](reference/designs/0019-C2-erp-database-connector.md)) — against
  a mock ERP DB, POs/scrap read in and downtime/production write back, deduped.
- **Edge operator flows** ([C3](reference/designs/0019-C3-edge-operator-spa.md)) — the
  edge-deployed SPA's read/justify/command paths work against factory-local backends;
  offline reads serve from cache and writes fail closed.

## Phases

| Phase | Deliverable |
|-------|-------------|
| **V0** | This ADR — the concrete definition above + the harness topology. |
| **V1** | The environment: compose stack, fresh refactored DB from migrations, both tenants seeded, simulator driving Incoplast. Isolated from the bake. |
| **V2** | Incoplast behaviors made real *in the harness*: [B2](0019-edge-customization-capabilities.md) customizations ported; [C1](reference/designs/0019-C1-edge-command-channel.md)/[C2](reference/designs/0019-C2-erp-database-connector.md)/[C3](reference/designs/0019-C3-edge-operator-spa.md) capabilities enabled and wired. |
| **V3** | The harness: golden fixtures + per-tenant behavior assertions → a pass/fail verdict. |
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
  for the real range of tenants; Incoplast's customizations get exercised in a segregated
  harness that never touches the bake; the harness outlives the flip as the acceptance
  suite for every future tenant onboarding.
- **Cost** — V2 pulls the Incoplast capability work ([B2](0019-edge-customization-capabilities.md)/C1/C2/C3
  wiring) forward from post-flip to pre-flip. That is the point, but it is real weeks.
- **Reframes [ADR-0020](0020-incoplast-staging-test-tenant.md)** — Incoplast's stand-up
  moves from "build now, stand up post-flip" into a *pre-flip segregated harness*, because
  the goal is now behavior confidence before the flip, not just avoiding bake variables.
  The bake stays untouched because the harness uses a separate DB.
