# ADR-0058 — A mature client-customization capability (declarative transforms + governed Node-RED)

**Status:** Proposed · **Date:** 2026-09-15 · **Scope:** how the automation team applies **per-client edge customizations** — merge two PLC sources into one tag, derived/calc tags, unit conversion, deadband, cross-register math (`DW0−DW4`), bit-decode, virtual meters — with **governance** (versioned, testable, promotable, auditable, revertible), across all three edge models. · **Decision owner:** chief architect (pending USER sign-off) · **Altitude:** the maturation of [ADR-0019](0019-edge-customization-capabilities.md) (the G1–G7 gap catalog) and the successor to [ADR-0009](0009-*.md) (the Node-RED-sprawl reckoning); builds on [ADR-0045](0045-client-onboarding-architecture.md) (descriptor SSoT), [ADR-0046](0046-edge-source-plugin-contract.md) (plugin contract), [ADR-0050](0050-plc-type-profiles.md) (`plc.types[].derive`, reserved), and [ADR-0057](0057-platform-mediated-box-access-ssm-broker.md) (browser Node-RED access).

**Synthesis note.** Grounded in a live map of the current stack (descriptor customization surface, the Node-RED runtimes, and the reader→agent→stream-engine transform stages) and the OSS scan below. Not a re-investigation — a decision doc.

---

## 1. Context

### 1.1 The need
An automation team must, per client, do things that are **not** onboarding config — genuine transforms of factory data: **merge two PLCs' counts into one line**, compute `scrap = DW0 − DW4`, integrate an analog speed into a virtual counter, decode a status word, deadband noisy analog, parse a batch id. Today some of this is possible and some has **no executable home**.

### 1.2 What already exists (prior art — do NOT rebuild)
- **Descriptor SSoT + governance spine (ADR-0045).** `client_descriptors` is versioned JSONB with a `draft→generated→deployed→captured→validated→cutover` lifecycle and a **cutover gate** that refuses on inferred count-indices. *This is already promote-with-approval + versioning + audit.*
- **A rich declarative surface**: `mapping` (prefix fixups, aliases, parameter decomposition), `metric_templates`, `equipment[].count_index`, `equipment[].line_roles` (consumed/processed/defective at distinct indices), `equipment[].derived[]` (**integral** = analog→virtual counter; **sum** = latch+add addends), `counter_derive` modes (`scrap_derived` ⇒ `scrap = gross − net`, `outfeed_only`, …), and `plc.types[]` (ADR-0050 — a PLC layout expanded × members).
- **The agent derive stage is the correlation point** (`sparkplug-decoder/internal/agent/deriver` + `counterderive`, ingest chain `cmd/sparkplug-agent/main.go`) — it already sees every tenant's tags as canonical suffixes regardless of reader/protocol, and already hosts integral/sum/gross-net-scrap. Reader stays "read address → post"; cloud decoder stays generic (ADR-0032).
- **Cross-machine merge already works** as refdata: a line reads gross/net/scrap from *different* machines via `equipments.lead_machine/gross_machine/scrap_machine` (`stream-engine/internal/rollup/line_lead.go`).
- **Node-RED (Tier-2) already round-trips**: `descriptor.customizations[]` = raw Node-RED node objects; the onboard-gen renders them onto a `<Tenant> customizations` tab of the generated reader flow. ADR-0009 already bounds Node-RED (CI lint: ≤200 LOC/function, no inline HTTP, config-not-code).

### 1.3 The real gaps (from the live map)
- **G-A — No general expression.** Every transform is a **closed algebra** (integral, sum, fixed gross/net/scrap identities) or hard-coded Go/SQL. There is **no eval engine anywhere** (verified: no cel/expr/goja/starlark). So `DW0 − DW4`, arbitrary unit conversions, deadband, and novel virtual meters have no home. ADR-0050 `plc.types[].derive` (`scrap: "S1 - S2"`) is **parsed but explicitly NOT executed** — the reserved decision this ADR closes.
- **G-B — Authored customizations aren't shipped.** `customizations[]` can be authored + validated in CS-Admin, but the HTTP `/v1/onboard/generate` **drops** the reader-flow artifact; only the local `onboard-gen` CLI emits it, and the SSM go-live deploys the *thin Python reader* (no Node-RED). So Tier-2 customizations are authored-but-never-deployed on the modern path.
- **G-C — No authoring/test tooling.** Customizations are hand-exported Node-RED JSON pasted into a **textarea**, validated by a two-field structural check. No simulate-against-sample-data, no contract check, no diff review.
- **G-D — onprem/reader boxes have no Node-RED** (by design — the reader model exists to *eliminate* the low-code sprawl). So "give the automation team Node-RED" is wrong for that whole class of client (e.g. Bispharma).

### 1.4 OSS scan (is there a tool for the governance?)
- **FlowFuse** (Node-RED DevOps): Apache-2.0 core, self-hostable; **Device Agent is free/OSS** (fleet deploy) but the governance crown-jewel — **dev→prod pipelines — is Enterprise-*licensed* (paid)**. A paid self-hosted license trips the standing "no paying a third party" constraint, and your **descriptor pipeline already provides versioning/promote/audit** — arguably stronger for your model than FlowFuse-free.
- **Transform engines**: LF Edge **eKuiper**, **Redpanda Connect/Benthos**, **Apache StreamPipes** (all OSS) and **UMH** (OSS reference arch = Node-RED + Benthos + UNS + Timescale) — heavier than needed given your agent already owns the transform stage.
- **Embeddable evaluators**: **`google/cel-go`** and **`antonmedv/expr`** — Apache-2.0 Go libraries, sandboxed, no network/loops, perfect for a calc-tag primitive dropped into the existing Go agent.

**Decision: EXTEND, don't adopt.** Keep the descriptor pipeline as the governance spine; add a sandboxed **`cel-go`/`expr`** primitive to the agent derive stage for the declarative 80%; keep bounded Node-RED (Tier-2) for the arbitrary 20% and *fix its deploy path*. FlowFuse-free stays an optional, later add-on for nodered-model **fleet** management only.

---

## 2. Decision — a two-tier, governed customization model

### 2.1 Tier 1 — Declarative transforms (the default, config-as-data)
A new `DerivedRule` variant **`Expr`** in the agent derive stage: `metric = <expression over sibling tags/registers>`, evaluated by a **sandboxed `cel-go`/`expr`** engine (no I/O, no loops, bounded time). It sits beside `integral`/`sum`/`counter_derive` in the one ingest closure, so a customization emits a canonical tag exactly like today (allowlisted via `SynthesizeEquipment`) — **no cloud/serving/reader change**. Ships a small **op vocabulary** so most needs never touch a raw expression: `merge(first_non_null|sum|max)`, `scale(factor,offset)`, `derive(expr)`, `decode_bits(word,{bit:name})`, `deadband(abs|pct)`, `counter_delta`/`rollover`. **Wire ADR-0050's reserved `plc.types[].derive` to this** — its first customer. This covers `DW0−DW4`, "merge two PLCs into one tag," unit conversion, deadband, virtual meters — **declaratively, versioned in the descriptor, for ALL edge models** (the agent runs cloud-side/fat-edge, so even thin reader boxes like Bispharma get customization with **no Node-RED on the box**).

### 2.2 Tier 2 — Node-RED escape hatch (arbitrary logic, bounded)
For genuinely imperative per-client logic (stateful sequences, bespoke protocols) on **nodered-model** clients:
- **Fix G-B**: make `/v1/onboard/generate` (edge-api path) emit + ship the reader-flow with the `customizations` tab (today only the CLI does), so authored customizations actually deploy.
- **Access**: the ADR-0057 embedded Node-RED editor (already built) — CS/automation login only.
- **Bounds (ADR-0009)**: keep the CI-lint contract (≤200 LOC/function, no inline HTTP, config-not-code) + descriptor round-trip so flows stay reviewable and survive redeploy.
- **Not for reader/onprem boxes** (G-D): those use Tier 1. We do **not** add Node-RED to the reader model — that would reintroduce the sprawl the reader model eliminated.

### 2.3 Governance wrapper (what makes it "mature")
Reuse the descriptor spine; add the missing pieces:
- **Registry + versioning + promote + audit** — already the `client_descriptors` version/status/cutover lifecycle. Customizations are descriptor fields ⇒ they inherit it.
- **Test/simulate harness (G-C)** — run a customization (Tier-1 expr or Tier-2 flow) against **captured tee sample data** (the onboarding capture already grabs live samples) and show the produced tags *before* deploy. This is the single biggest maturity gain.
- **Authoring UI** — replace the JSON textarea with a real **customizations editor** (Tier-1: a typed op-builder + expr field with live preview; Tier-2: the embedded Node-RED + import/version).
- **Observability + rollback** — surface active customizations per client + their health (did the expr error? did the tag emit?), and revert = descriptor version rollback.

### 2.4 Runtime placement matrix
| Edge model | Customization mechanism | Node-RED? |
|---|---|---|
| **reader / onprem** (Bispharma) | **Tier 1** (agent Expr, in the cloud/fat-edge agent) | No (by design) |
| **nodered-tee** (CPACK, Incoplast) | Tier 1 **+** Tier 2 (on-box Node-RED, ADR-0057 access) | Yes |
| **shared-agent** (cloud) | Tier 1 (shared agent) | No |

### 2.5 OSS decision (explicit)
- **Governance spine**: the descriptor pipeline (keep). **No FlowFuse dependency for the backbone.**
- **Transform primitive**: `google/cel-go` **or** `antonmedv/expr` (Apache-2.0), embedded in the Go agent. (`expr` is lighter + Go-idiomatic; `cel-go` is more standardized/portable — pick in Phase 1.)
- **FlowFuse-free**: optional, later, for nodered-model **fleet/device** management only — never the governance backbone (its pipelines are paid).

---

## 3. Consequences
- **+** One coherent story: 80% declarative + governed (Tier 1), 20% bounded escape hatch (Tier 2), the same descriptor spine governing both. `DW0−DW4` and "merge two PLCs" finally have an executable, versioned home.
- **+** Reader/onprem clients get customization **without** a Node-RED runtime on the box (Tier-1 in the agent) — preserves the thin-reader, outage-tolerant model.
- **+** No new paid dependency; reuses AWS-native + OSS Go libs.
- **−** A sandboxed evaluator is a new execution surface in the agent — must be I/O-free, loop-free, time-bounded, and per-tenant fault-isolated (a bad expr must never crash the shared agent — cf. the ADR-0057 ws-crash lesson).
- **−** Fixing G-B + the test harness + the authoring UI is real work (see the epic).
- **−** Tier-2 Node-RED remains a governance cost (ADR-0009 bounds); we accept it only for clients that genuinely need imperative logic.

## 4. Rollout — see `docs/plans/adr-0058-customization-epic.md`
Phased: **P1** declarative Expr primitive in the agent (closes `DW0−DW4`, wires ADR-0050 `derive`); **P2** ship-authored-customizations fix (G-B) + test/simulate harness; **P3** the customizations authoring UI; **P4** Node-RED runtime/fleet polish + optional FlowFuse-free evaluation. Each phase is independently shippable + hardproven against a real box.
