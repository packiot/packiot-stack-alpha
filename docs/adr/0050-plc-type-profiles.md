# ADR-0050 — PLC Type Profiles: derive the tag map from a reusable layout, don't hand-author it per endpoint

**Status:** Proposed · **Date:** 2026-09-01 · **Scope:** the PLC-conversion layer of onboarding — how an endpoint's raw registers become canonical count metrics · **Decision owner:** chief architect (pending USER sign-off) · **Altitude:** a refinement of [ADR-0045 (client onboarding)](0045-client-onboarding-architecture.md) and [ADR-0043 (register-driven tagmap)](0043-cs-admin-register-driven-tagmap.md). ADR-0045 made the descriptor → tagmap → agent chain config-as-data; this ADR removes the **hand-authored per-endpoint tag map** from that chain for the common case, replacing it with a reusable **PLC type** that the generator expands against the equipment members the descriptor already holds.

**Synthesis note.** Grounded in the live bispharma onboarding (2026-09). bispharma's site has **16 lines, every PLC an identical Siemens S7 program** — same `DB1` layout (`DINT0, DINT8, DINT12, DINT16, DINT20`), same rack/slot. Onboarding stalled at Go-live because the descriptor's `plc.s7_tag_map` was empty, so the reader-gen had nothing to emit and produced a no-op reader. The sensor-config UI could not help: it is a **view+editor over tag-map entries that already exist** (`buildGroups()` iterates `plc.{s7,opcua,modbus}_tag_map`), with no create-path — its own empty state punts to "add machine tags in Onboarding → Descriptor (or via capture)". So the tag map is a hand-authored artifact that, for a uniform client, is **96 copies of one 6-line layout**. The USER's observation is the decision this ADR records:

> **USER (2026-09-01):** *"how about we remove the plc tag map all together? its just for mapping different types of plc right? if we use the types directly its fine."*

---

## 1. Context

### 1.1 What the tag map actually binds

Each `*_tag_map` entry does **two** jobs, and only the first is protocol-specific:

1. **Where to read** — S7 `db`/`offset`, Modbus `kind`/`address`, OPC-UA `node_id`. Protocol-specific.
2. **What to publish** — the canonical metric suffix (`…/Admin/ProdProcessedCount/<count_index>/Unit`) the agent routes on.

You cannot simply delete it — both facts must live somewhere. But (2) is **already in the descriptor**: every `equipment` member carries its `topic` and `count_index`. And (1), for a client that deploys one PLC program to every line, is **one layout repeated N times**. That redundancy — not the concept — is the waste.

### 1.2 Three concrete pains from the hand-authored map

- **Redundancy.** bispharma = 16 identical PLCs → an explicit map is ~96 entries that are one layout copied. Every copy is a place to drift or mistype.
- **No create-path.** The onboarding UI edits existing entries; it never seeds them. Capture (ADR-0045 §2.4) was meant to, but it observes *post-reader* tags — it cannot discover raw S7 register offsets (chicken-and-egg: the reader needs the map to read). So a uniform S7 client has no non-JSON way to author the map.
- **Derived counters have nowhere clean to live.** bispharma's scrap is `DINT0 − DINT4` (infeed minus a mid-line sensor). The config-driven reader reads *raw registers only* — no cross-register arithmetic — and `DW0 − DW4` matches no standard `counter_derive` mode. So scrap silently falls out for every line, per-line, with no obvious home.

### 1.3 What is already settled (do not re-litigate)

- **CS Admin is the control-plane editor; edge-api is the write plane** (ADR-0026/0045). This ADR does not change *who* edits.
- **The descriptor is the SSoT and the reader/agent are generated from it** (ADR-0045). This ADR keeps that; it only changes *how much* of the descriptor is hand-authored.

---

## 2. Decision

Introduce a **PLC type profile**: a named, reusable layout that describes *how a class of PLC exposes its counters*, and have the generator produce the tags by joining `type × members`.

```yaml
plc:
  types:
    bispharma_s7:                 # one definition, referenced by many endpoints
      protocol: s7
      rack: 0
      slot: 2
      port: 102
      word: dint
      db: 1
      # sensor position → register offset. The member's SENSOR name (S1, S3, …)
      # selects the offset; the member's count_index supplies the canonical metric.
      sensor_offsets: { S1: 0, S2: 4, S3: 8, S4: 12, S5: 16, S6: 20 }
      derive:
        scrap: "S1 - S2"          # cross-register derivation lives HERE, once
  endpoints:
    - { name: L01, host_ref: 192.168.5.3, type: bispharma_s7 }
    - { name: L03, host_ref: 192.168.5.11, type: bispharma_s7 }
    # … 14 more, each one line
```

**The generator expands `type × members → tags`.** For each equipment member on an endpoint, it looks up the member's sensor → register offset (from the type) and pairs it with the member's `count_index` (canonical metric). No `s7_tag_map` is authored by hand.

**The explicit `*_tag_map` remains — as an override.** An endpoint may still carry (or the generator may still emit) explicit per-tag entries for an irregular PLC that no type fits. Precedence: **explicit tag entry > endpoint type > nothing**.

### 2.1 Where each protocol's derivation lands

- Simple reads (S1/S3/…): the type's `sensor_offsets` → a raw read tag. No change to the reader.
- Derived counters (`scrap: S1 - S2`): the type's `derive` block. The generator either (a) emits a `counter_derive` the agent understands, or (b) emits a small computed-tag spec the reader evaluates. **Deciding (a) vs (b) is the one open design question** (see §4) — but either way the derivation is written **once per type**, not once per line.

---

## 3. Consequences

**Positive**
- **DRY.** 16 endpoints + 1 type replace ~96 hand-authored entries. Onboarding a uniform client becomes "assign the type", not "enter 96 rows".
- **The create-path problem dissolves.** The sensor-config / onboarding UI offers "pick a PLC type" (a short, reusable list) instead of a per-tag editor that can only edit what already exists.
- **Derivations have a home.** `scrap = S1 − S2` is a type property, authored once, not a per-line landmine that silently zeroes.
- **The descriptor stays the SSoT.** Members remain the truth; the type is a small template; the tag map stops being a hand-maintained artifact.

**Negative / cost**
- **Schema + generator work.** Add `plc.types` and `endpoint.type` to the descriptor schema; teach the reader-gen (and the register-leaf generation, ADR-0045) to expand `type × members`. Medium effort.
- **Heterogeneous clients still need the override.** CPACK is *not* uniform — different machines per line (BREYER/PTH/POLYTYPE/TEXA…), different count-index sets. A single global type does not fit it. Two honest sub-options, not mutually exclusive: **per-machine-model types** (a BREYER is a BREYER wherever it sits — often uniform at that grain) and/or **keep the explicit map** as the escape hatch. The framing is: *types are the default; the explicit map is the override* — never "types replace the map".

---

## 4. Open question (needs a call before build)

Where does a cross-register derivation like bispharma's `scrap = DW0 − DW4` execute?
- **(a) Agent-side** — the reader posts the raw sensors; the agent's counter-derive stage computes scrap. Keeps the reader dumb; needs a derive mode more general than the current gross/net/scrap algebra.
- **(b) Reader-side** — the type emits a computed-tag spec (`metric = f(reg_a, reg_b)`) the reader evaluates before posting. Keeps derivation next to the raw reads; adds a tiny expression evaluator to the reader.

Recommendation: **(a)**, because it keeps the on-box reader a pure "read address → post" component (the thin-reader → shared-cloud-agent model of ADR-0042/0045) and centralizes semantics in the agent where the other derivations already live.

---

## 5. Migration & staging note

Non-breaking. `plc.types` is additive; existing descriptors with an explicit `*_tag_map` keep working unchanged (the override path). The bispharma staging onboarding (2026-09) was unblocked with an explicit generated `s7_tag_map` (72 sensor tags across 15 lines, derived from the members) as the interim; that map is exactly what a `bispharma_s7` type would emit, so it becomes the first migration target once the type model lands.
