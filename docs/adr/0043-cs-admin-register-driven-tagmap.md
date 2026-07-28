# ADR-0043 — CS-Admin-owned tenant conversion profile + register-driven agent tag map

Status: Proposed (2026-07-23) · Task #13 · Extends [ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md) and [ADR-0042](0042-separated-edge-gateway.md)

## Context

The CPACK L6 tee validation ([ADR-0042](0042-cpack-tee-frontdoor.md) P1) proved the
Tier-2 sparkplug-agent pipeline end-to-end, but only after **hand-editing**
`docs/clients/cpack-agent.yaml`'s `raw_tag_map` (PR #590) to match the real prod
PLC naming. That hand-YAML is a STOPGAP:

- It puts per-factory onboarding data (topic namespace + metric-name quirks) in an
  engineering artifact that needs a code edit + deploy per client.
- It does not scale to N factories, each with its own PLC tag conventions.

USER directive (2026-07-23): *"CS Admin will be responsible to set this all up.
topics, conversion etc."* ADR-0009 already flagged the direction: *"Phase 3 replaces
EQUIPMENT_MAP with a packml_register-driven loader."* CS Admin already populates
`packml_register` at onboarding — so the equipment set is already CS-Admin data.

## Decision

Two additive pieces, flag-gated (`AGENT_TAGMAP_FROM_REGISTER`, default **OFF** — the
static YAML behaviour is unchanged).

### 1. A declarative tenant CONVERSION PROFILE (`tenantprofile` package)

A per-tenant, CS-Admin-fillable YAML (`docs/clients/<tenant>-profile.yaml`) that
expresses — as data, not code — the four quirk classes the CPACK validation surfaced:

| Quirk | Profile field | CPACK example |
|---|---|---|
| prefix fixup | `prefix_fixups` | `C-PACK/` → `CPACK/` |
| metric alias | `metric_aliases` | `Status/CurMachSpeed` → `Status/MachSpeed` |
| ambiguous Parameter | `parameter_aliases` (with `applies_to`) | `Status/Parameter` → `Status/Parameter30700` (line-scoped; bare `Parameter` is ambiguous across 30700/30750/30758) |
| count-index rule | `count_index.mode` + `overrides` | default = `id_equipment`; override members whose PLC embeds a legacy/prod id (BREYER 53→61, TEXA 57→65, PTH 61→81) |
| line-vs-member | `metric_templates.line` / `.member` | lines additionally publish `Parameter30700`; members do not |

The profile drives two complementary transforms from one source of truth:
- **SYNTHESIZE** — build the canonical `raw_tag_map` (suffix→type) from the tenant's
  equipment rows (templates + count-index).
- **NORMALIZE** — canonicalise an inbound raw metric name (prefix fixups + aliases),
  for a register that already carries per-metric rows in real naming.

### 2. A register-driven loader (`agentcfg` + `register_pg.go`)

Behind `AGENT_TAGMAP_FROM_REGISTER=true`, the sparkplug-agent:
1. loads the tenant profile (`AGENT_PROFILE_PATH`);
2. queries `packml_register` (scoped to the profile's `enterprise_id` — the
   cross-tenant guard) for the tenant's equipment, taking the canonical **shortest**
   topic per equipment (same deterministic tie-break as `translate.go`);
3. synthesizes the canonical `raw_tag_map` via the profile;
4. installs it (re-validated by the same `agentcfg` invariants as a hand YAML).

The DB is a seam (`RegisterFetcher`); the pgx pool is dialled **only** when the flag
is on, keeping the default agent run DB-free. pgx was added to
`services/edge-transformer/go.mod` for exactly the ADR-0009 Phase-2 purpose its
prior "intentionally NOT included" note anticipated.

The agent + edge-transformer stay **generic** — they LOAD the profile + register and
build the map from data. Zero per-client Go (ADR-0032 one-ingest-contract).

## Equivalence proof (the acceptance bar)

`TestBuildRawTagMap_MatchesPR590Yaml` parses the hand-built `cpack-agent.yaml`
(ground truth) and asserts that `BuildRawTagMapFromRegister(cpack-profile,
enterprise-3 equipment rows)` produces the **same 44 suffix→type entries** (4
lines × 6 + 4 members × 5). Count-index overrides, line-vs-member Parameter
gating, and type inference are each pinned by dedicated tests, plus a
`NormalizeTopic` test for the inbound (prefix-fixup + alias) direction. The
generated map is also re-run through full `agentcfg` validation.

## CS-Admin onboarding wiring

`packml_register` is already a CS-Admin artifact (created at onboarding, step 6). The
**conversion profile is the one new artifact** CS Admin fills per tenant. Onboarding
becomes: populate `packml_register` (unchanged) → write `<tenant>-profile.yaml` →
set `AGENT_TAGMAP_FROM_REGISTER=true` + `AGENT_PROFILE_PATH`. No `raw_tag_map` edit,
no code change, no redeploy of the agent binary per client.

## Consequences / follow-ups

- **NOT cut over.** Flag defaults OFF; CPACK still runs the static YAML until a
  deliberate flip. The register loader assumes the tenant's `packml_register` on the
  target DB matches the profile's expectations — validate against the live register
  before flipping a tenant (staging probe was deferred: SELECT-only when available).
- The NORMALIZE path (per-metric register rows) is built + tested but the SYNTHESIZE
  path is what the equivalence proof + default wiring use; pick per-tenant based on
  whether that tenant's register is metric-granular or equipment-granular.
- Alias correctness (e.g. `CurMachSpeed`→`MachSpeed`) is CS-Admin domain data — the
  loader proves the MECHANISM reproduces the hand map, not the domain truth of any
  single alias.
