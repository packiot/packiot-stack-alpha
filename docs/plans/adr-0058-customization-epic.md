# ADR-0058 epic — client-customization capability

Companion to [ADR-0058](../adr/0058-client-customization-capability.md). Phased so each ships independently and is hardproven against a real box (per the session discipline: real evidence, never HTTP-200-only). "Tier 1" = declarative agent Expr; "Tier 2" = bounded Node-RED.

## Phase 1 — Declarative Expr transform primitive (Tier 1 core) ← start here
**Goal:** close gap G-A. A general, sandboxed `Expr` derive rule in the agent, so `DW0−DW4` / merge / scale / deadband have a home — no cloud/serving/reader change.

- **P1.1 — pick + embed the evaluator.** Add `antonmedv/expr` (or `google/cel-go`) to `services/sparkplug-decoder`. Sandbox: no I/O, no loops, compile-once, per-eval time budget, per-tenant panic isolation (a bad expr → drop that tag + emit a data-quality event, NEVER crash the shared agent).
- **P1.2 — `DerivedRule.Expr` variant.** Extend `tenantprofile.DerivedRule` + `clientconfig.TagSource` + descriptor `equipment[].derived[]` schema (`clientdescriptor.go`) with `kind: expr`, `expr: "consumed - processed"`, `emit: <leaf>`, over sibling canonical tags/registers. Resolve + allowlist via `SynthesizeEquipment` exactly like integral/sum. Evaluate in the ingest closure (`cmd/sparkplug-agent/main.go`) right after `deriver.Process`.
- **P1.3 — op vocabulary** (typed sugar over raw expr so most cases never write an expression): `merge(first_non_null|sum|max)`, `scale(factor,offset)`, `decode_bits`, `deadband(abs|pct)`, `counter_delta`/`rollover`. Each lowers to an Expr.
- **P1.4 — wire ADR-0050 `plc.types[].derive` (DONE, member-only).** Each `role: "<expr>"` on a type now generates a `DerivedRule` on the endpoint's LINE equipment (tp=3): the role picks the emit leaf (scrap→ProdDefectiveCount), each sensor key binds to that member's published NET count, the line owns the derived tag (`generateTypeDeriveRules`). Proven: bispharma `scrap = S1 - S6` → 16 line scrap rules, harness emits 30 from 500−470, §C still holds. **Constraint: MEMBER-ONLY** — every referenced sensor must be a published member.
- **P1.4b — reader-publishes-sensors (DONE).** A derive referencing a sensor with an offset but NO member now works: the generator synthesizes (a) a reader S7 tag that physically reads that offset, published under the LINE topic as `/Derive/<key>`; (b) an agent raw_tag_map allowlist entry, so the §C `checkClientAgentConsistency` invariant passes and the agent accepts it; and the DerivedRule marks that var **consumed** (`ExprSource.Consume`), so the deriver folds it into the expression and DROPS it from passthrough — it never reaches the cloud uplink. Proven: `defective = S1 - S2` (S1 member, S2 non-member) → reader reads offset 4, allowlist gains `/LINHAS/L01/Derive/S2`, `consume=[S2]`, §C holds, deriver consumes the input. `ExprSource.Consume` is also available to equipment-level `derived[].expr` (the "merge two PLCs and don't republish the raws" case). Original recon (kept for reference):
  - `plc.types[].derive` (`PLCType.Derive map[string]string`, `clientdescriptor.go:230-259`) is fully dead: zero consumers, not even shape-validated (`validatePLCTypes` skips it).
  - Its expression tokens (`S1`, `S2`) are **`sensor_offsets` keys**, and each resolves to a **distinct member equipment** (the member whose topic tail starts with that token, via `sensorKeyOf`). So `scrap: "S1 - S2"` is inherently **cross-member**.
  - The existing per-equipment Expr resolver (`generateDerivedRules`, `generate.go:234-307`) resolves vars relative to **one** equipment segment — it cannot express a cross-member reference. The sensor-key→member→full-suffix knowledge lives only in the reader-side `expandS7TypeEndpoint` (`generate.go:894-933`). These two paths are structurally disjoint.
  - Roles: derive key `scrap` → `ProdDefectiveCount` (needs a `scrap`→`defective` alias, since `lineRoleLeaf` keys on `"defective"`); `Sn` resolves to that member's NET suffix `localSegment(member.Topic)+"/Admin/ProdProcessedCount/<idx>/Unit"`.
  - **THE DECISION (ADR-0050 §4): which entity owns the emitted derived tag + its count-index?** SCRAP is deliberately NOT a member equipment, so there is no equipment slot to populate. **Recommendation:** attach a type-level `derive` as a `DerivedRule` on the **LINE** equipment (tp_equipment=3, which already has a resolved count-index), with a new bridging resolver that maps each `Sn` token → its member's resolved arriving suffix (reusing `sensorKeyOf` / `membersOnEndpointLine` / `ResolveCountIndex`). This keeps the runtime Expr primitive (P1.1–P1.3) unchanged — only a new **generate-time** expansion feeds it.
  - Scope: a new `generateTypeDerivedRules` path + `scrap`→`defective` alias + validation of `Derive` in `validatePLCTypes` + a test on the `bispharma.descriptor.yaml` fixture. Runtime deriver is untouched. **Blocked on ratifying the LINE-owns-it decision.**
- **P1.5 — tests + hardproof.** Unit: each op + sandbox limits (bad expr isolated, no crash). Hardproof: feed Bispharma's real captured tags through the agent with `scrap = gross − net` (or the true `DW0−DW4` once the factory PLC map lands) and show the derived scrap tag emitted + landing in silver — against the real box data, not a mock.

**Exit:** `DW0−DW4`-class customizations expressible in the descriptor, evaluated in the agent, tenant-fault-isolated; ADR-0050 `derive` executes.

## Phase 2 — Ship authored customizations + test/simulate harness
**Goal:** close G-B (authored ≠ shipped) and G-C (no test tooling).

- **P2.1 — ship the reader-flow (G-B).** Make edge-api's `/v1/onboard/generate` path emit + include the `reader_flow` artifact (with the `customizations` tab) that today only the `onboard-gen` CLI produces; ensure the nodered-model deploy actually ships it (the thin Python reader path stays Tier-1-only).
- **P2.2 — simulate harness.** Endpoint + UI: run a customization (Tier-1 expr or Tier-2 flow) against the tenant's **captured tee sample** (onboarding capture already stores live samples) and return the produced tags/values — a dry-run BEFORE deploy. This is the biggest maturity win.
- **P2.3 — contract/lint on the CS-Admin path.** Enforce the ADR-0009 bounds (function-size, no-inline-HTTP, config-not-code) + Expr validation server-side, not just a two-field structural check.

**Exit:** a customization authored in CS-Admin is validated, simulated against real sample data, then actually deployed.

## Phase 3 — Customizations authoring UI
**Goal:** replace the JSON textarea (`review-step.tsx`) with a real editor.

- **P3.1 — Tier-1 op-builder**: a typed form (pick op → source tags → params) with **live preview** via the P2.2 harness; writes to `descriptor.equipment[].derived[]`.
- **P3.2 — Tier-2**: the embedded Node-RED editor (ADR-0057) with import/version of the `customizations` tab back to the descriptor; diff vs the deployed version.
- **P3.3 — observability**: per-client "active customizations + health" panel (did each expr/flow emit? last error?), and rollback = descriptor version revert.

**Exit:** the automation team customizes a client end-to-end in csadmin without hand-editing JSON, with preview + audit + rollback.

## Phase 4 — Node-RED runtime/fleet polish (optional)
- **P4.1** — decide Node-RED editor auth hardening (`edge-node-red` `adminAuth` is open when env unset) + the ADR-0057 access model as the only path.
- **P4.2** — evaluate **FlowFuse-free Device Agent** for nodered-model **fleet** deploy/monitor (NOT the governance backbone; pipelines are paid). Time-boxed spike; adopt only if it beats the current submodule-bump deploy for the Node-RED fleet.
- **P4.3** — (stretch) push #257 `scrap_measurable` into the OEE math so single-meter lines don't fabricate Q=100% (currently serving-only, undeployed on staging).

## Cross-cutting
- **Governance spine is the existing descriptor pipeline** — versioning/promote/cutover/audit already there; customizations inherit it. No FlowFuse for the backbone.
- **Every phase hardproofs against a real box** (Bispharma reader-model for Tier-1; a nodered-model client — CPACK/Incoplast — for Tier-2).
- **Fault isolation is a first-class requirement** (a bad customization must degrade to a data-quality event, never take down the shared agent) — the ADR-0057 uncaught-throw-crash lesson.
