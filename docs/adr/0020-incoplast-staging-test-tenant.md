# ADR-0020 — Incoplast as a staging test tenant

- **Status**: Proposed (2026-07-08) — decider: Emmanuel Podestá.
- **Context**: [ADR-0019](0019-edge-customization-capabilities.md) turned the
  Incoplast assessment's seven gaps (local operator UI, ERP coupling, operator→PLC
  commands, …) into *requirements*. Those requirements need a place to be built and
  tested. CPACK — a clean, standard-pipeline tenant — cannot exercise any of them.
  This ADR stands up **Incoplast as a second staging tenant**, deliberately shaped
  differently from CPACK, so the ADR-0019 capabilities have a realistic target.

## Why a second tenant is worth the effort

Two reasons, one immediate and one strategic:

1. **It is the acid test of multi-tenancy.** The entire ADR-0012 refactor was about
   moving tenancy from table names to data. A second, differently-shaped tenant
   coexisting through shared infrastructure is the first real proof that claim holds
   — and if something is still single-tenant-hardcoded, we want to find it on
   staging with a synthetic tenant, not in production onboarding a real second
   factory.
2. **It is the workbench for ADR-0019.** The ERP connector, the operator→PLC command
   channel, and the edge-deployed operator SPA cannot be built against a tenant that
   doesn't need them. Incoplast does. Standing it up now gives every ADR-0019 project
   a place to land.

## Timing decision (2026-07-08)

The stack is ~6 days from the flip, mid-bake. **All artifacts are built now; the
tenant is stood up on staging only AFTER the flip.** Rationale: the parity bake
compares F1/F2/F3 on CPACK's per-equipment surfaces; a second tenant's data is
scoped to its own enterprise and would not appear on those surfaces, so it *should*
be isolated — but "should be" during a sensitive bake is not worth the risk when the
alternative costs only a few days. The build-now/stand-up-later split gives us
reviewed, ready artifacts and a clean bake.

## The three layers

| Layer | What | Status |
|-------|------|--------|
| **A — standard-pipeline tenant** | Incoplast flows through the same transformer → RabbitMQ → worker → DB → refdata → operator path as CPACK. Seed data, `client.yaml`, simulator, container instances. | **Buildable now (this ADR's artifacts)** |
| **B — customization flows** | Incoplast's custom counter calc, recurso/etapa/empresa mapping, reel tracking — as *governed* Node-RED customization flows per ADR-0009. | Next (needs the governance lint + refactored flows) |
| **C — the hard capabilities** | ERP connector (G1), operator→PLC command channel (G4), edge-deployed operator SPA (G3) — the ADR-0019 projects. | Gated on ADR-0019 execution |

Layer A is what makes the other two possible: you cannot test a customization flow or
a command channel without a tenant for them to act on.

## What Layer A requires (and what it revealed)

The stack is already substantially multi-tenant. A survey (2026-07-08) of how CPACK is
wired found most of it tenant-agnostic and keyed off database rows:

**Already multi-tenant-ready — no change:** RabbitMQ ingest (shared `oee` exchange +
`sparkplug.data` queue; tenant resolved from the payload's `packml_topic` against
`packml_register`); `oeecloud-worker`, `shadow-mirror`, `edge-api`, and all shared
infra; the Python `simulator/` (DB-driven, auto-discovers any seeded enterprise);
`refdata-api` (`QUERY_API_KEYS` is a list — append one entry); the `clientconfig`
loader and AMQP topology (already loop over tenants, just run one-per-container).

**Genuinely per-tenant work:**
- **Seed data** — enterprise, site, areas, equipment, `packml_register`, shifts.
  (`edge-node-red/db/26-incoplast-staging-fixtures.sql`, + the anchor row in `24-`.)
- **`client.yaml`** — `docs/clients/incoplast.yaml`.
- **Data generation** — use the **Python simulator**, not `plc-sim`. The Python sim
  is DB-driven and picks up Incoplast automatically once seeded. (`plc-sim` is the one
  compile-time-hardcoded artifact — `groupID`/`lines[]` are constants — and we
  deliberately avoid it.)
- **Container instances** — `edge-nodered`, `operator`, and `edge-transformer` are
  *one-enterprise-per-container* by design, so Incoplast needs its own instances of
  each (see the stand-up checklist below).

**One fragility this surfaced (a real finding):** `id_enterprise` is assigned
*positionally* by seed order, yet hardcoded as the literal `3` in three service envs
(`edge-nodered ID_ENTERPRISE`, `mirror-worker-go STAGING_ENTERPRISE_ID`,
`refdata-api QUERY_API_KEYS`). A reseed in a different order would silently break all
three. Incoplast's seed therefore emits its assigned id (`RAISE NOTICE`), and the
stand-up checklist wires that captured id explicitly. **Follow-up candidate:** have
these services resolve their enterprise id from the DB by name at startup rather than
hardcode it — a robustness improvement worth doing before prod onboards tenant N.

## The stand-up checklist (execute AFTER the flip)

The artifacts in this ADR's PR are inert files. To bring Incoplast up on staging:

1. **Apply the seed** `edge-node-red/db/26-incoplast-staging-fixtures.sql`; capture
   the `RAISE NOTICE` `id_enterprise` (call it `$IID`). Verify the anchor row from
   `24-` is present.
2. **Un-skip the simulator** — ensure `$IID` is not in `SIM_SKIP_ENTERPRISE_IDS`
   (default only skips CPACK=3); optionally add an `ENTERPRISE_PROFILES['Incoplast-Staging']`
   entry for realistic speed/scrap/downtime variability (already in this PR).
3. **Add container instances** to `compose.staging.yml`: a second `edge-nodered`
   (`ID_ENTERPRISE: "$IID"`, own port/volume/IP), a second `edge-transformer`
   (mounts `docs/clients/incoplast.yaml`, own health port), and a second `operator`
   (nginx → the Incoplast edge-nodered, `OPERATOR_EDGE_API_KEY` = Incoplast's
   `enterprises.api_key`).
4. **Append the refdata key** — `QUERY_API_KEYS += "stg-incoplast-key:$IID"`.
5. **No `mirror-worker-go`** for Incoplast — it has no real prod enterprise to
   mirror; its data comes entirely from the simulator.
6. Verify: Incoplast equipment appears in refdata reads and the operator SPA; OEE
   computes; no CPACK surface is affected.

## Consequences

- Positive: the first genuine multi-tenant proof on staging; a realistic workbench for
  every ADR-0019 capability; early discovery of any remaining single-tenant coupling.
- Negative: three more container instances on staging; the positional-`id_enterprise`
  fragility needs the captured-id discipline until the follow-up robustness fix lands.
- Scope discipline: this ADR delivers **Layer A only**. Layers B and C are named here
  for context but are their own projects, sequenced under ADR-0019.

## References

ADR-0019 (the requirements this tenant tests) · ADR-0009 (the customization surface,
Layer B) · ADR-0012 (the multi-tenancy this proves) ·
`docs/clients/incoplast-migration-assessment.md` (the source factory) ·
`docs/guide/07-customizations-and-real-factories.md` (the story).
