# ADR-0044 — id-driven Parameter decomposition (bare `Status/Parameter` → canonical `Parameter<NNNNN>`)

Status: Proposed (2026-07-23) · Task #54 (ADR-0031 Workstream B follow-up) · Extends [ADR-0043](0043-cs-admin-register-driven-tagmap.md) and [ADR-0042](0042-cpack-tee-frontdoor.md)

## Context

PR #590 (rebuild CPACK agent tag_map from real prod topology) and PR #593 /
[ADR-0043](0043-cs-admin-register-driven-tagmap.md) (CS-Admin tenant conversion
profile) both landed a documented **open follow-up**:

> **Parameter decomposition** — a single bare `Status/Parameter` cannot stand in
> for `Parameter30700` (line CSV) / `30701` / `30750` / `30751` / `30758`. Until
> resolved, **Phase-9 line aggregation does not fire**; lines fall back to their
> own bare-topic count stream.

The refactored edge-transformer Calc keys its non-counter state seeds on the metric
NAME suffix (`cmd/edge-transformer/main.go` `seedFromMetric`,
`calc_production_counters`):

| Calc seed | keyed suffix | consumer |
|---|---|---|
| line-machines CSV | `/Status/Parameter30700` | Phase-9 line aggregation (`line_aggregation.go`) |
| ideal speed | `/Status/Parameter30701` | Phase-7 |
| min-speed threshold | `/Status/Parameter30750` / `30751` | Phase-7/8 |
| event trigger type | `/Status/Parameter30758` | Phase-8 |

ADR-0043's `parameter_aliases` (a single per-class rename `Status/Parameter →
Status/Parameter30700`) **cannot** route real CPACK: the SAME topic carries
DIFFERENT parameters over time, so one rename can only ever pick one number.

### What real CPACK actually sends (prod, SELECT-only, 2026-07-23)

Verified against the ent-1 production `packml_register` (SSM `i-06c9547a2c7091ab7`
→ `databaseCredentials` → docker `psql`, `BEGIN TRANSACTION READ ONLY`, prod
SELECT-only) and the current cloud flow `oeecloud-node-red/flows/01 · Ingestion &
Writes.json`:

- There is exactly **ONE bare `.../Status/Parameter` topic per equipment** — no
  numbered `Parameter30700`/`30701`/… topics exist on the wire. (`packml_register`
  shows a single `Status/Parameter` registration per line; members carry none.)
- The PackML parameter NUMBER travels in the **SparkPlug metric's `id`/alias
  field**, not the topic:

  ```json
  {"timestamp":1652433763000,"id":30700,
   "name":"C-PACK/SC/LINHAS/L5/Status/Parameter","value":"5","type":"int32"}
  ```

- The current cloud decomposes exactly this way: it reads
  `parameter_id = JSON.parse(metric).id` and branches on it (30700 line order,
  30701 ideal speed, 30750 min-speed, 30758 event trigger, 30800+ PO control).

So the decomposition mechanism is **id → canonical numbered leaf**, per tag — not a
structured sub-field split, not multiple topics.

## Decision

Three additive pieces, **flag-gated** (`AGENT_PARAM_DECOMPOSITION`, default **OFF**
— current behaviour byte-for-byte: a bare `Status/Parameter` stays unmapped →
dropped, Phase-9 does not fire).

### 1. Carry the id on the raw-tag wire (`rawtag`)

The Tier-1 envelope tag gains an optional `param` field (`RawTag.ParamID`): the
PackML parameter id the tee copies from the PLC SparkPlug metric's `id`. `0` ⇒
absent (valid PackML ids are ≥30000, so `0` is an unambiguous sentinel); the vast
majority of tags carry no id and are untouched.

### 2. A declared decomposition rule on the tenant profile (`tenantprofile`)

```yaml
parameter_decomposition:
  source_leaf: "/Status/Parameter"
  params:
    - {id: 30700, leaf: "/Status/Parameter30700", applies_to: line}  # Phase-9 line CSV
    - {id: 30701, leaf: "/Status/Parameter30701"}                    # ideal speed
    - {id: 30750, leaf: "/Status/Parameter30750"}                    # min-speed threshold (qty)
    - {id: 30751, leaf: "/Status/Parameter30751"}                    # min-speed threshold (time)
    - {id: 30758, leaf: "/Status/Parameter30758"}                    # event trigger type
```

`Profile.DecomposeParameterSuffix(suffix, paramID)` rewrites a suffix ending in
`source_leaf` to the numbered leaf of the matching `params` entry. This is an
**explicit allowlist**: an id NOT declared here is left bare (→ dropped) — a stray
PO-control write (30800+) can never be mistaken for a Calc seed. The rewritten
metric's SparkPlug wire type comes from the `raw_tag_map` allowlist entry it
resolves to (`metric_templates`), keeping one source of truth for types.

### 3. Wire it at agent ingest (`cmd/sparkplug-agent`)

The shared `ingest` closure (both the MQTT subscriber and the HTTP front-door feed
it) decomposes each id-carrying bare-Parameter tag **before** the `raw_tag_map`
lookup, so the numbered entry (`Parameter30700`) both resolves in the allowlist and
publishes under the SparkPlug name the cloud Calc keys on. A
`sparkplug_agent_param_decomposed_total{param_id}` counter observes the rewrite.

## Why this seam

`RawTag.Metric` (the suffix) is the key for the resolver, tagstore RBE, and the
published SparkPlug name alike. Rewriting it once, at ingest, propagates the
canonical numbered name through the entire pipeline with no change to the Calc.
The edge-transformer cloud side is **untouched** — it already HasSuffix-matches
`/Status/Parameter30700`.

## Proof

`internal/agent/httpingest/e2e_test.go` `TestE2E_ParameterDecomposition_FeedsPhase9`
drives the real pipeline: a bare `POST /v1/tags` `{"metric":"/L5/Status/Parameter",
"value":"47,53","param":30700}` → decompose → resolve → tagstore → session →
`sparkplug.Encode` → `sparkplug.Decode` + `StateStore.Ingest` (the exact cloud
code). It asserts the metric arrives at the cloud decoder as
`CPACK/SC/LINHAS/L5/Status/Parameter30700` with the CSV value — the exact name and
payload `seedFromMetric` seeds and `runPhase9LineAggregation` reads — and that the
bare name never leaks. A baseline POST without the `param` id confirms the tag is
dropped (unchanged current behaviour). Plus unit coverage in
`tenantprofile_test.go` (`TestDecomposeParameterSuffix`,
`TestDecompose_ProvesPhase9Input`, validation) and `rawtag_test.go`
(`TestDecode_ParamID`).

## Not in scope / follow-ups

- **NOT cut over** — flag OFF. Enabling on staging requires the CPACK tee to emit
  the `param` id (the connectivity Node-RED copies the PLC SparkPlug metric `id`),
  and the numbered `Parameter30700` entry present in the line's `raw_tag_map`
  (already in `metric_templates.line`).
- **Calc-side suffix bug (pre-existing, separate).** `seedFromMetric` matches
  30750/30761/30710 with LITERAL asterisks (`/Status/Parameter*30750*`) — a JS
  wildcard that leaked into the Go port. Decomposition emits the clean
  `Parameter30750`; wiring those seeds through end-to-end needs that HasSuffix bug
  fixed first. 30700 (Phase-9) and 30758 are clean and unaffected.
- **Member-level params.** 30750/30751/30758 are unit-scoped; their `raw_tag_map`
  allowlist entries (member templates) are a follow-up — only 30700 (lines) is
  proven end-to-end here, which is this task's gate.
