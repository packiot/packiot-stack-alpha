# ADR-0045 — CS-Admin-driven Client Onboarding Architecture

**Status:** Proposed · **Date:** 2026-07-23 · **Scope:** client onboarding (the whole path from "a new factory signs" to "its real PLC data computes OEE in F3") · **Decision owner:** chief architect (pending USER sign-off) · **Altitude:** this ADR is the *onboarding* companion to [ADR-0042 (separated edge gateway)](0042-separated-edge-gateway.md). 0042 defined the runtime three-tier split; **this ADR defines how a client is provisioned into that runtime** — the config artifacts, who fills them, where per-client quirks are absorbed, and the self-service sequence that replaces today's reactive quirk-discovery.

**Synthesis note.** The design is grounded in the live CPACK onboarding arc — PRs #590 (hand-built agent tag map), #593/[ADR-0043](0043-cs-admin-register-driven-tagmap.md) (register-driven conversion profile), #601 (full CPACK topology + Incoplast draft + the count-index finding), #602/[ADR-0044](0044-parameter-decomposition.md) (id-driven Parameter decomposition). That arc **is** the onboarding flow, performed by hand, one discovery at a time. This ADR turns the arc into a repeatable, self-service architecture. It is design of record, not a re-investigation; file citations were grounded against the live tree.

---

## 1. Context

### 1.1 The problem — onboarding is reactive quirk-discovery

Onboarding a factory today is a sequence of *surprises found in production data*, each patched by an engineering edit + deploy:

- **CPACK** publishes its enterprise head as `C-PACK/SC/LINHAS/...` (hyphen), not the canonical `CPACK/...`. Discovered by inspecting live tee bytes; patched with a `prefix_fixup` (#593).
- **CPACK** count metrics embed an **arbitrary PLC channel index** (`.../ProdProcessedCount/<IDX>/Unit`) that is *only coincidentally* the equipment id — L4 uses a separate `6/7/8/9` series, `CELULA2/BREYER1` uses `26` while its id is `340` (#601). **Not derivable from any table — must be observed from a real payload**, member by member.
- **Incoplast** publishes accented, mixed-case, zero-padded names — `SÃO_LUDGERO/IMPRESSÃO/NovoFlex_015` — where canonical is `SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15` (#601, already in the bug ledger as `incoplast-topic-shape-mismatch`).
- The bare `Status/Parameter` topic carries **different PackML parameters over time**, disambiguated only by the SparkPlug metric `id` (30700/30701/30750/30758) — a single rename cannot route it (#602).

Each of these was a **code edit to a hand-maintained YAML** (`docs/clients/cpack-agent.yaml` `raw_tag_map`) followed by a redeploy. That does not scale to N factories, and it silently fails: an unmapped or wrong-indexed tag is **dropped with no signal** — the failure mode that bit L6's inferred indices (#601).

### 1.2 The directive — customization is data CS Admin sets, not code engineering writes

> **USER (2026-07-23):** *"CS Admin will be responsible to set this all up. topics, conversion etc."* … *"architect this better."*

This is north-star principle #2 (config-driven, never a fork) applied to onboarding, and [ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md)'s long-flagged direction (*"Phase 3 replaces EQUIPMENT_MAP with a `packml_register`-driven loader"*). CS Admin already owns `packml_register` (onboarding step 6). The gap is everything *around* it: the conversion profile, the agent/MQTT config, the tee, and the discovery-then-validate loop — none of which is yet a governed, generated, self-service artifact.

### 1.3 What ADR-0042 already fixed — and what it left open

[ADR-0042](0042-separated-edge-gateway.md) split the client edge into **Tier 1 (Node-RED connectivity, SparkPlug-ignorant, emits raw suffix tags)** → **Tier 2 (Go `sparkplug-agent`, owns the whole SparkPlug session)** → **cloud edge-transformer (decode + Calc, unchanged)**. It defined the *runtime*. It explicitly deferred the *provisioning* questions this ADR answers: where the per-client tag map comes from (0042 §Open-Q references `client.yaml`), and open-question #3 (per-tenant vs multi-tenant agent). This ADR is the provisioning layer that sits on top of that runtime.

---

## 2. Decision

**One CS-Admin-authored `client descriptor` per tenant is the single source of truth. Everything else is generated from it. Per-client PLC quirks are normalized stack-side in the Go agent's tenant profile (never in per-client low-code). Quirks that are PLC facts — count indices, real naming — are captured from a live tee in an explicit observe step, never inferred. Onboarding is a gated, self-service sequence: describe → generate → capture → validate → cut over.**

### 2.1 The canonical topic model (what everything downstream speaks)

Downstream of the agent — decode, alias-resolve, Calc, Phase-9 aggregation, F3 — every component speaks **one canonical SparkPlug topic shape**. Every client's raw topics map *to* this; nothing downstream ever sees a client's raw form.

```
<ENTERPRISE>/<SITE>/<AREA>/<LINE>[/<MEMBER>]/<METRIC_LEAF>
└── ASCII, UPPERCASE, no accents, no hyphens, no zero-padding ──┘
```

| Segment | tp | Meaning | Canonical example | Real (raw) example |
|---|---|---|---|---|
| ENTERPRISE | — | tenant head | `CPACK` | `C-PACK` |
| SITE | — | factory | `SC`, `SAO_LUDGERO` | `SÃO_LUDGERO` |
| AREA / cell | — | area or cell | `LINHAS`, `CELULA1`, `IMPRESSAO` | `IMPRESSÃO` |
| LINE | 3 | production line (`packml_register` line topic) | `L5`, `MIRAFLEX_28` | `NovoFlex_015` |
| MEMBER | 1 | machine under a line (optional; single-machine cells repeat the line name) | `BREYER`, `CER400` | — |
| METRIC_LEAF | — | the PackML metric | `Status/MachSpeed`, `Status/Parameter30700`, `Admin/ProdProcessedCount/92/Unit` | `Status/CurMachSpeed`, `Status/Parameter`(+id), `.../<PLC-idx>/Unit` |

**Load-bearing invariants of the canonical model:**

1. **The `packml_topic` = topic minus the metric leaf** (and minus any count `/idx/Unit`). This is what `packml_register` stores and how the cloud resolver maps topic → `id_equipment` (deterministic shortest-topic tie-break, per `translate.go`).
2. **The count index is a leaf detail, not identity.** The resolver strips `/idx/Unit`; the index only has to *match the tee's emitted value* so the agent's strict allowlist accepts the tag. A wrong index drops that member's counts and **nothing else** — which is exactly why it must be a first-class, validated artifact, not a guess.
3. **PackML parameter number lives in a numbered leaf** (`Parameter30700`), synthesized from the bare `Status/Parameter` topic + the SparkPlug metric `id` at agent ingest (ADR-0044). The Calc keys its seeds on this numbered suffix.

This canonical model is the client-side face of the [ADR-0032](0032-collapse-to-single-flow-f3.md) one-ingest-contract: `edge-transformer` has one source-agnostic processor precisely because every agent emits this one shape.

### 2.2 The client descriptor → generated artifact set

CS Admin authors **one** artifact — a `client descriptor` — describing the tenant. A generator turns it into the four downstream artifacts, which are **generated, never hand-edited**:

```
                    ┌──────────────────────────────┐
   CS Admin  ───▶   │  CLIENT DESCRIPTOR (SSoT)     │
   (form/YAML)      │  tenant, enterprise_id,       │
                    │  canonical hierarchy,         │
                    │  known quirks (prefix/alias), │
                    │  endpoints, mTLS CN, secrets  │
                    └───────────────┬──────────────┘
                          generate  │  (deterministic, reproducible)
        ┌──────────────────┬────────┼────────────────┬──────────────────┐
        ▼                  ▼        ▼                 ▼                  ▼
  packml_register    tenant         client.yaml   Node-RED tee     (observe
  rows               conversion     (agent + MQTT  snippet          placeholders:
  (topic↔equip)      profile        config: prefix, (Tier-1 raw     count-index
  ADR-0043 §CS-Admin (ADR-0043 +    endpoints,     forwarder +      overrides,
  onboarding step 6  ADR-0044:      mTLS CN,       param-id copy)   naming folds
                     prefix_fixups, secrets_ref)                    → filled by
                     metric_aliases,                                the CAPTURE
                     parameter_*,                                   step, §2.4)
                     count_index,
                     metric_templates)
```

| Generated artifact | Owner today | What the descriptor supplies | Status |
|---|---|---|---|
| **`packml_register` rows** | CS Admin (already) | canonical hierarchy → one topic↔equipment row per line/member | **built** (existing onboarding step 6) |
| **tenant conversion profile** (`<tenant>-profile.yaml`) | *hand-authored today* | `prefix_fixups`, `metric_aliases`, `parameter_aliases`, `parameter_decomposition`, `count_index`, `metric_templates` | schema **built** (ADR-0043/0044); generation from descriptor = **gap** |
| **`client.yaml`** (agent + MQTT) | *hand-authored today* | `tenant_prefix`, broker endpoints, `mTLS CN=<tenant>`, `*_ref` secrets | schema **built** (ADR-0004/0042); generation = **gap** |
| **Node-RED tee snippet** | *hand-built today* | raw-tag forward + the `param`-id copy (ADR-0044 §1) | **gap** (generator + snippet template) |

**The rule:** the descriptor is the only thing a human writes. The four artifacts are `make onboard <tenant>` output — reproducible, diffable, PR-reviewed. This is the same discipline [ADR-0042 §5](0042-separated-edge-gateway.md) applies to the release triple: a client change is a gated PR against generated artifacts, never a live edit.

### 2.3 The normalization seam — the key architectural choice

**Where does a client's raw topic become canonical?** Two candidates, and the choice governs the whole onboarding cost model.

| | **Option A — normalize in Node-RED (Tier 1, client-side)** | **Option B — normalize in the Go agent (Tier 2, stack-side)** ✅ |
|---|---|---|
| Tee emits | already-canonical tags | **raw** PLC tags (+ metric `id`) |
| Quirk knowledge lives in | per-client low-code flow | the versioned **tenant profile** (stack repo) |
| Change a naming rule | edit + redeploy that factory's Node-RED | edit a YAML in the stack repo, PR-gated, CI-tested |
| Who can get it wrong | each client's flow drifts independently | one reviewed, tested artifact per tenant |
| Testability | none (low-code, per-factory) | `tenantprofile_test.go` + equivalence proof vs ground truth |
| Blast radius of a bad rule | one factory, silent | caught by CI + parity-gate before cutover |

**Decision: Option B — normalize stack-side, in the Go agent's tenant profile. The tee forwards raw PLC facts faithfully; it does not canonicalize.**

**Reasoning, grounded in the ADR-0042 plane boundary:**

1. **It respects the connectivity-plane / transmission-plane seam.** ADR-0042 defines Tier 1 as **SparkPlug-ignorant**: it emits raw suffix tags and *never* constructs a canonical path. Making Tier 1 normalize names would smuggle the canonicalization job — a stack concern — back into per-client low-code, re-coupling exactly what 0042 decoupled. Normalization is a *transmission-plane* responsibility: it belongs with the alias/encode/session logic in the agent, because the canonical name is what the agent births into the SparkPlug alias table.
2. **The quirks are stack knowledge, so they belong in a stack artifact.** `C-PACK→CPACK`, `CurMachSpeed→MachSpeed`, the accent fold, the Parameter decomposition — these are facts about *how the platform's canonical model differs from this PLC*. That mapping is versioned, tested (ADR-0043's `TestBuildRawTagMap_MatchesPR590Yaml` pins CPACK's 44 entries against ground truth; ADR-0044's e2e proves Parameter30700 reaches the cloud), and reviewed. In a low-code flow it is none of those.
3. **The tee stays a dumb, near-zero-maintenance forwarder** — the same across every client but for the connectivity I/O. Onboarding a client is then *fill a profile*, not *write a flow*, which is precisely the CS-Admin-not-engineering shift the directive demands.

**The one deliberate exception — and why it is not a violation.** The tee *does* copy the SparkPlug metric `id` into the raw-tag envelope's `param` field (ADR-0044 §1). That is **not normalization** — it is *faithful transmission of a PLC fact* (the id the PLC already put on the metric). The tee still spells no canonical name; the agent's `DecomposeParameterSuffix(suffix, paramID)` does the canonicalization. This sharpens the seam rather than blurring it: **Tier 1 transmits raw PLC facts (topic, value, quality, metric id); Tier 2 owns every canonicalization** (prefix, alias, count index, parameter number, alias-table, encode).

**The corollary that makes Option B safe: count-index and real-naming quirks are PLC facts that must be *observed*, not coded, wherever normalization runs.** Option B does not let us *invent* the mapping — an index like `BREYER1→26` is unknowable from any table (#601). What Option B buys is that once observed, the fact lands in *one reviewed stack artifact*, captured centrally, instead of being re-typed into each factory's flow. Observation is a first-class onboarding step (§2.4), not an afterthought.

### 2.4 Robustness — reject-don't-drop, and live-capture the unknowable

Two mechanisms harden onboarding against the exact failures the CPACK arc surfaced.

**(a) Structured topic validation at ingest — flag, don't silently drop.**
Today the agent's `raw_tag_map` is a strict allowlist: a tag not in it is dropped. The strictness is correct (a stray PO-control write must never masquerade as a Calc seed — ADR-0044 §2); the **silence** is the bug (a wrong inferred index just vanishes). The fix is to make every rejection *observable*:

- Emit `sparkplug_agent_tag_unmapped_total{tenant, reason}` for every dropped raw tag — `reason ∈ {unknown_topic, malformed, no_param_id, index_mismatch}`.
- Surface an **onboarding DQ report**: the set of distinct raw topics seen on the tee that did **not** resolve to a canonical allowlist entry. This is the difference between "L6 counts are silently missing" and "these 3 topics arrived and matched nothing — here they are."
- A validation gate (below) fails onboarding if the unmapped set is non-empty for expected equipment.

This is ADR-0042 §7's "observable, not zero" doctrine applied to the *provisioning* boundary: an unknown topic is a birth/validation event, not a dropped packet.

**(b) The live-tee index-capture step.** Count indices (and, for accented tenants, the exact emitted naming) are **not derivable** — #601 proves `mode: equipment_id` is wrong for all 42 CPACK members against staging ids, and L8/L10/SLEEVE/most-CELULA indices are marked *inferred* precisely because no active count topic existed to observe. So onboarding includes an explicit **CAPTURE** phase: run the agent in an observe posture fed by the client's live tee, record the distinct `.../<IDX>/Unit` indices and real name forms actually emitted, and **write them into the profile's `count_index.overrides` / `prefix_fixups`** as confirmed values. `confirmed` vs `inferred` is tracked in the profile (as #601 already annotates). **No tenant cuts over on inferred indices.**

### 2.5 The self-service onboarding flow (CPACK is the worked example)

```
① DESCRIBE      CS Admin fills the client descriptor (form → YAML):
                 tenant, enterprise_id, canonical hierarchy, known quirks,
                 endpoints, mTLS CN, secrets-by-ref.
        │
        ▼ generate (deterministic)
② GENERATE      → packml_register rows  → <tenant>-profile.yaml
                 → client.yaml           → Node-RED tee snippet
                 (indices/naming left as observe-placeholders)
        │
        ▼ deploy agent in OBSERVE posture, wire the tee
③ CAPTURE       Live tee → agent. Record distinct count indices + real name
                 forms actually emitted. DQ report lists every unmapped topic.
                 Fill count_index.overrides / prefix_fixups = CONFIRMED values.
        │
        ▼
④ VALIDATE       - allowlist coverage: 0 unmapped topics for expected equipment
                 - profile re-validated by agentcfg invariants
                 - Mode-A parity-gate: F3-from-agent == F3-from-prod via
                   internal/bake (ADR-0042 §5.2 / ADR-0022)
        │
        ▼ flip AGENT_TAGMAP_FROM_REGISTER (+ AGENT_PARAM_DECOMPOSITION) on
⑤ CUT OVER       Tenant runs the register-driven profile. Gated PR, reversible
                 (flag back OFF → static behaviour byte-for-byte).
```

**CPACK, mapped to the flow (what the arc already did, by hand):** ① implicit (prod topology read SELECT-only) → ② #590 hand-built the map, #593 turned it into a profile, #601 widened to the full 5-cell topology → ③ #590's L6 live-tee observation captured `TEXA=92` etc., #601 recorded confirmed-vs-inferred → ④ ADR-0044's e2e proves Phase-9 fires; parity-gate pending live tee → ⑤ flags default OFF, awaiting the deliberate flip. **This ADR's contribution is making steps ①–② a generator and step ③ a first-class tool, so the next tenant is hours of config, not a multi-PR forensic arc.**

### 2.6 Multi-tenant vs per-client agent

**Decision: one multi-tenant agent *image*, deployed as one *instance per tenant*.** (Resolves ADR-0042 open-question #3.)

- **The code is multi-tenant-capable** — a single generic `sparkplug-agent` binary that loads a profile + `client.yaml`; zero per-client code (ADR-0043's whole thesis; the register loader is even scoped by `enterprise_id` as a cross-tenant guard).
- **The runtime is per-tenant** — one `sparkplug-agent-<tenant>` process per client, because:
  1. **It matches the security model.** ADR-0042 §6 keys tenant isolation on `mTLS CN=<tenant>` + a CN-scoped broker ACL — one cert, one identity, one process. A multiplexing agent would hold N tenants' certs and could, on misconfig, publish as the wrong tenant — the exact failure north-star #5 exists to make unrepresentable.
  2. **Clean blast radius.** A bad profile, a rebirth storm, an OOM affects one tenant. Matches ADR-0010's "subscriber-per-tenant is embarrassingly parallel" finding.
  3. **Independent lifecycle.** Each tenant flips `AGENT_TAGMAP_FROM_REGISTER` / cuts over / rolls back on its own clock — impossible if they share a process.

Revisit only if raw process count becomes a real operational cost on a shared edge box; the mitigation then is a supervisor multiplexing *config* while preserving per-tenant certs, not a shared session.

---

## 3. Artifact-ownership table

| Artifact | Authored by | Generated from descriptor? | Normalization role | Prior art |
|---|---|---|---|---|
| Client descriptor | **CS Admin** (form/YAML) | — (it *is* the source) | declares the canonical hierarchy + known quirks | **new (this ADR)** |
| `packml_register` rows | generated → CS Admin owns | ✅ | topic↔equipment (canonical) | ADR-0043, onboarding step 6 |
| `<tenant>-profile.yaml` | generated (quirks captured live) | ✅ + CAPTURE step | **the normalization SSoT** (prefix/alias/param/count-index) | ADR-0043 / ADR-0044 |
| `client.yaml` | generated | ✅ | `tenant_prefix`, endpoints, mTLS CN, secrets-ref | ADR-0004 / ADR-0042 |
| Node-RED tee snippet | generated | ✅ | **none** — raw forward + `param`-id copy only | ADR-0042 §2.3, ADR-0044 §1 |
| DQ / unmapped-topic report | agent-emitted (observe) | — | validation feedback | **new (this ADR §2.4)** |

---

## 4. Phased build plan — shipped vs gap

**Already shipped — the normalization mechanism (§2.3 Option B), proven, flags default OFF:**

| Shipped | Deliverable |
|---|---|
| ✅ **#593 / ADR-0043** | tenant conversion profile schema (`tenantprofile`) with `prefix_fixups`/`metric_aliases`/`parameter_aliases`/`count_index`/`metric_templates`; register-driven loader (flag `AGENT_TAGMAP_FROM_REGISTER`, default OFF); equivalence proof vs the hand YAML (`TestBuildRawTagMap_MatchesPR590Yaml`, 44 entries). |
| ✅ **#601** | full CPACK topology profile (62 equipment, 5 cells, 330 entries) + the **count-index finding** (indices are arbitrary PLC channels, per-member overrides required, confirmed-vs-inferred tracked); Incoplast draft profile (accent/case/pad folds, `id_unit` indices). |
| ✅ **#602 / ADR-0044** | id-driven **Parameter decomposition** (`parameter_decomposition` rule + `RawTag.ParamID` on the wire + agent-ingest rewrite; flag `AGENT_PARAM_DECOMPOSITION`, default OFF); e2e proof Phase-9 line CSV reaches the cloud decoder. |

The chosen architecture — normalize in the Go agent, Node-RED stays connectivity-only, downstream sees only canonical — is therefore **already the running mechanism**. Everything below is **provisioning ergonomics + observability** on top of it.

**The gap — the build plan:**

| Phase | Deliverable | Status / owner |
|---|---|---|
| **P0 — Validate-and-flag (kill silent-drop)** | `sparkplug_agent_tag_unmapped_total{tenant, reason}` + LOG + the onboarding unmapped-topic DQ surface; validation gate on empty-unmapped. Turns the strict-allowlist silent-drop (what hid L6's inferred-index mismatch) into a debuggable, surfaced event. | **being built separately now** (§2.4a) |
| **P1 — Client descriptor → generated artifacts** | The `client descriptor` schema (SSoT) + generator producing, from one source: the **tenant conversion profile** + **agent `client.yaml`** + **`packml_register` seed** + **Node-RED tee snippet**. Retires hand-authoring of all four. | **gap** (§2.2) |
| **P2 — Live-tee index-capture tool/procedure** | Agent observe-posture that records the distinct count indices + real name forms a live tee actually emits, and writes them back as *confirmed* `count_index.overrides` / `prefix_fixups`. Indices are unknowable PLC facts (§2.4b) — this is how they enter the descriptor. | **gap** — done by hand for CPACK L6 |
| **P3 — Self-service onboarding UI/flow** | CS-Admin form driving the descriptor; the ①→⑤ sequence (§2.5) wired with the Mode-A parity-gate; per-tenant flag flip. | **gap** — CPACK flags await the deliberate flip |
| **+ Agent-topology recommendation** | one multi-tenant *image*, one *instance per tenant* (§2.6; resolves ADR-0042 open-Q3). | **decided** (this ADR) |

Ordering rationale: **P0 first** — validate-and-flag removes the silent-failure class and makes every later step debuggable, so it lands even before the generator (it is being built separately now). **P1** turns the multi-PR forensic arc into a descriptor + `make onboard`. **P2** feeds P1 the one thing that cannot be generated (observed PLC facts). **P3** puts a CS-Admin surface on the whole loop. Each phase is independently valuable and reversible.

---

## 5. Consequences

### Positive
- **Onboarding becomes config, not code.** A new tenant is a descriptor + a live-capture pass, not a fork or a hand-YAML edit — the CS-Admin-owns-conversion directive realized.
- **One canonical model downstream** — decode/Calc/F3 never see a client's raw form; the ADR-0032 one-ingest-contract holds at provisioning time, not just runtime.
- **Silent-drop failure class removed** — reject-don't-drop + the unmapped-topic DQ report turn "L6 counts silently vanished" into a validation failure with a named cause.
- **The unknowable is captured, not guessed** — count indices / real naming become observed, confirmed artifacts; no tenant cuts over on inferred data.
- **Normalization is versioned, tested, reviewed** — the quirk mapping lives in one stack artifact with an equivalence proof, not in N drifting low-code flows.
- **Reversible per tenant** — every step is flag-gated (`AGENT_TAGMAP_FROM_REGISTER`, `AGENT_PARAM_DECOMPOSITION`), default OFF, so cutover is a deliberate, rollback-able flip.

### Negative / trade-offs
- **The descriptor + generator are net-new tooling** — the four artifacts must stay perfectly consistent, which is the generator's whole job; a generator bug fans out to all four. Mitigated by the equivalence proofs already pinning profile output.
- **A live tee is required before cutover** — the CAPTURE step means a tenant cannot be fully onboarded from documentation alone; it needs real payload observation. This is inherent (indices are unknowable) but adds a synchronous dependency on the client's connectivity being live.
- **Profile becomes even more load-bearing** — it is now the normalization SSoT *and* the count-index registry *and* the parameter-decomposition rule. Mitigated by schema-lint + CI + the confirmed/inferred annotation discipline.

### Neutral
- **Matches the enterprise-IoT reference stack** — the profile plays HighByte's contextualization role (ADR-0042 §2.7); onboarding-as-config is the Ignition/HighByte norm, not an invention.

---

## 6. Open questions

1. **Descriptor granularity vs `packml_register` as source.** ADR-0043 offers two loader paths — SYNTHESIZE (build the map from equipment rows + templates) and NORMALIZE (canonicalize per-metric register rows). Should the descriptor drive `packml_register` (register is derived) or read from it (register is primary)? Recommend: descriptor is primary, `packml_register` seed is generated from it, so there is one SSoT — but confirm against the existing CS-Admin onboarding UI that already writes `packml_register` directly.
2. **CAPTURE posture safety.** Running the agent in observe mode against a live tee on staging (Mode A) is safe; against a client's real edge (Mode B) before cutover needs a read-only/dry posture that publishes nothing to the cloud alias table. Define the observe-only agent mode (record indices/names, emit DQ, publish nothing).
3. **Confirmed-vs-inferred as a hard gate.** Should VALIDATE *refuse* to cut over any tenant with an `inferred` count index for an expected-active member, or only warn? Recommend: hard-fail for members with active count topics; warn for members whose counts are legitimately dormant.
4. **Generator home.** Does the generator live in the stack repo (`make onboard`), in edge-api (the CS-Admin control plane), or in a CS-Admin UI action? Recommend: a stack-repo generator invoked by the CS-Admin UI, so output is reproducible and PR-diffable regardless of who triggers it.

---

## 7. Cross-reference table

| ADR | Relationship |
|---|---|
| [ADR-0042 (separated edge gateway)](0042-separated-edge-gateway.md) | **Companion / governs.** 0042 = the runtime three-tier split; this ADR = the provisioning layer on top. The normalization seam (§2.3) rests on 0042's connectivity/transmission plane boundary; §2.6 resolves 0042 open-question #3. |
| [ADR-0043](0043-cs-admin-register-driven-tagmap.md) | **The conversion-profile mechanism.** This ADR wraps the profile + register loader in a descriptor-driven, live-captured onboarding flow. |
| [ADR-0044](0044-parameter-decomposition.md) | **The Parameter seam.** The tee's `param`-id copy is the one deliberate Tier-1 exception (§2.3); decomposition is agent-side normalization. |
| [ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md) | **The register-driven-loader direction** this ADR completes, and the logic-type seam the normalization choice honours. |
| [ADR-0032](0032-collapse-to-single-flow-f3.md) | **One ingest contract.** §2.1's canonical model is the client-side face of the source-agnostic F3 processor. |
| [ADR-0022](0022-pre-flip-behavior-correctness-validation.md) | **The VALIDATE bar.** Step ④ holds a tenant to F3-vs-prod parity via `internal/bake`. |
| [ADR-0004](0004-edge-nodered-config-centralization.md) | **`client.yaml` as SSoT** — endpoints, secrets-by-reference, generated here. |
| [ADR-0038 (north star)](0038-north-star-factory-platform.md) | **Governs.** Principle #2 (config not fork), #5 (tenant isolation → per-tenant agent + mTLS CN). |

---

## Decision log

| Date | Decision | Decider |
|---|---|---|
| 2026-07-23 | Onboarding architecture drafted: client descriptor SSoT → generated artifacts; normalization stack-side in the agent profile; live-capture for unknowable PLC facts; reject-don't-drop; per-tenant agent instance of a multi-tenant image; describe→generate→capture→validate→cutover flow. Status: Proposed. | chief architect + Claude |
| TBD | USER review + sign-off | |
| TBD | P0 validate-and-flag (being built separately) | |
| TBD | P1 client descriptor → generated artifacts | |
