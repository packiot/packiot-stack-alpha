# Bispharma + Bisnago — clean canonical topic model + translation layer

**Status:** Proposed (design of record) · **Date:** 2026-07-27 · **Task:** #54 ·
**Governs:** [ADR-0045 (onboarding architecture)](../adr/0045-client-onboarding-architecture.md),
[ADR-0043 (conversion profile)](../adr/0043-cs-admin-register-driven-tagmap.md),
[ADR-0042 (separated edge gateway)](../adr/0042-separated-edge-gateway.md) ·
**Input:** [`bispharma-bisnago-legacy-inventory.md`](bispharma-bisnago-legacy-inventory.md)
(Part A — tsp12 mining), bisnago flow PR #632, the bispharma onboarding scaffold.

> **The directive (USER):** *"topics and plc configurations may be architected to
> provide a better stack — a proper translation layer between plc → mqtt → go
> sparkplug → go transformer."* This doc designs that clean target and the
> messy→clean translation, **not** a lift-and-shift of legacy topics. Part A
> proves there is no legacy topic set to lift for either tenant — so the "better
> stack" here is *architected from a blank slate*, which is the ideal case.

---

## 1. The clean canonical topic model (target — what everything downstream speaks)

Per ADR-0045 §2.1, every component downstream of the Go `sparkplug-agent` — decode,
alias-resolve, Calc, Phase-9 aggregation, F3, DB — speaks **one** canonical
SparkPlug topic shape. Both tenants map *to* this; nothing downstream ever sees a
tenant's raw form.

```
<ENTERPRISE>/<SITE>/<AREA>/<LINE>[/<MEMBER>]/<METRIC_LEAF>
└──── ASCII · UPPERCASE · no accents · no hyphens · no zero-padding ────┘
```

The `packml_topic` stored in `packml_register` = the topic **minus** the metric
leaf (and minus any count `/<idx>/Unit`); the cloud resolver maps it → `id_equipment`
by deterministic shortest-topic tie-break (`translate.go`).

### 1.1 Bispharma canonical tree (greenfield — authored from intake)

```
BISPHARMA/<SITE>/<AREA>/<LINE>[/<MEMBER>]/<leaf>
```

- `SITE`, `AREA`, `LINE`, `MEMBER`: from client intake (Part A found **zero**
  topology in tsp12 — nothing to reverse-engineer). Site short-code chosen in
  tenant-prep, e.g. `BISPHARMA/SP`.
- Metric leaves per ADR-0045 templates: `/Admin/ProdProcessedCount[/<idx>/Unit]`,
  `/Admin/ProdConsumedCount`, `/Admin/ProdDefectiveCount`, `/Status/MachSpeed`,
  `/Status/StateCurrent`, `/Status/Parameter30700`. Drop `MachSpeed`/`StateCurrent`
  for any machine lacking that sensor (counters-only path).
- Telemetry shape (SparkPlug-string vs numeric) is fixed by the bispharma flow
  extraction (sibling); the canonical tree above is protocol-agnostic — the agent
  normalizes to it regardless of the raw edge shape.

### 1.2 Bisnago canonical tree (from the 7 flow line-labels + client)

```
BISNAGO/<SITE>/<AREA>/<Lxx>[/<MEMBER>]/Admin/ProdProcessedCount[/<idx>/Unit]
```

- **7 active lines** (CONFIRMED from flow, Part A §3): `L71 L72 L73 L56 L57 L58 L60`
  — already ASCII/upper/no-pad, so the canonical **line** segment = the flow label
  verbatim. The 12 dormant `192.168.5.x` lines are treated **decommissioned** unless
  the client says otherwise (NEEDS-CLIENT).
- **COUNTERS-ONLY:** leaves are `/Admin/ProdProcessedCount` (line) and
  `/Admin/ProdProcessedCount/<idx>/Unit` (member). **No** `/Status/MachSpeed`, **no**
  `/Status/StateCurrent` (neither signal exists — Part A §4). `Parameter30700` on the
  line only if the line publishes a member-CSV; otherwise omit.
- `SITE`/`AREA`/`MEMBER` names: **NEEDS-CLIENT** (Part A §3 — the flow carries no
  tree; tsp12 carries nothing under ent 119). Placeholder `BISNAGO/<SITE>/<AREA>/…`.

---

## 2. The translation layer (messy raw → clean canonical, normalize-in-agent)

Per ADR-0045 §2.3 **Option B**: normalization happens **stack-side, in the Go
agent's tenant conversion profile**. The tee / client-edge forwards **raw PLC facts
faithfully** (topic-or-counter, value, quality, and — for SparkPlug — the metric
`id`); it constructs **no** canonical string. Each tenant gets one
`<tenant>-profile.yaml` (ADR-0043 schema), one `sparkplug-agent` instance, one mTLS
`CN`.

### 2.1 Bisnago — the numeric-counter → canonical SYNTHESIZE (the interesting case)

Bisnago is the **pre-SparkPlug numeric-counter model** (Part A §3–4): the edge
emits DINT counter values keyed by a numeric id, **no topic strings at all**. So the
translation is not a string-rewrite (there are no strings to fix) — it is a
**SYNTHESIZE** from the descriptor: a `counter-id → (canonical line/member, count
leaf, idx)` map that the new edge applies to build the canonical topic.

| Legacy raw fact (from the S7/counter edge) | Canonical target | Rule |
|---|---|---|
| DINT absolute totalizer on counter id *N* | `BISNAGO/<SITE>/<AREA>/<Lxx>/<MEMBER>/Admin/ProdProcessedCount/<idx>/Unit` value | forward the **absolute** value; new stack recomputes delta (do NOT forward the flow's `increment`) |
| counter-id *N* → which line | `<Lxx>` segment | from the descriptor's confirmed id→line map (flow gives 7 lines; the 670–683 pair-per-line meaning is NEEDS-CLIENT) |
| `<idx>` (count index) | leaf `/…/<idx>/Unit` | a **fresh** channel — **NOT** the legacy id 670–683 (those collide with NEOPAC, Part A §3). Author `confidence: inferred`; a live-tee CAPTURE (ADR-0045 §2.4b) turns it `confirmed`. **No cutover on inferred indices.** |
| UTC-3 timestamp (`ts.setHours(-3)`) | canonical UTC ts | ingest maps to UTC (`ts_utc` already carried by the flow) |
| no speed / no state | *(absent)* | drop `MachSpeed`/`StateCurrent`; `status_type≠4`; counters-only OEE (rated `production_speed` + inferred availability) |

`prefix_fixups: []`, `metric_aliases: []`, `parameter_aliases: []` — **empty**,
because there are no legacy strings to canonicalize. The whole Bisnago "translation"
lives in the **equipment inventory + count_index** blocks of the descriptor, which
SYNTHESIZE the canonical `raw_tag_map` (ADR-0043 §1 SYNTHESIZE path). This is why a
counters-only tenant is the *simplest* profile, not the hardest — the messiness
(numeric ids, no strings) collapses into a table, not a rule-set.

**Edge decision (NEEDS-DECISION):** the legacy flow ran on a Raspberry Pi reading 7
S7 PLCs → PubSub. On the new stack Bisnago becomes **either** a rebuilt Tier-1 tee
**or** our client-edge container reading the same 7 S7 endpoints (`192.168.7.5–29`,
rack 0 / slot 2, 30 s poll, DB1 DINTs). Recommend the **client-edge container**
(ADR-0042 Tier-1): it removes the bespoke Pi flow and makes the raw shape a governed
artifact. Either way the raw envelope carries `{counter_id, value, quality, ts}` and
the agent SYNTHESIZEs canonical topics.

### 2.2 Bispharma — SparkPlug-string → canonical NORMALIZE (CPACK/Incoplast-class, if applicable)

If the bispharma flow (sibling extraction) publishes SparkPlug **strings** with the
usual quirks (accents, hyphens, `CurMachSpeed`, bare `Parameter`), the translation
is the standard NORMALIZE profile — same mechanism as CPACK:

```yaml
# bispharma-profile.yaml (shape; fill from the flow extraction)
prefix_fixups:    []   # e.g. {from: "BIS-PHARMA/", to: "BISPHARMA/"} — ONLY if the flow shows a hyphen/accent head
metric_aliases:   []   # e.g. {from: "Status/CurMachSpeed", to: "Status/MachSpeed"} — ONLY if present
parameter_aliases: []  # or parameter_decomposition, if a bare Status/Parameter carries many ids (ADR-0044)
count_index: {mode: equipment_id, overrides: {}}   # overrides captured live (ADR-0045 §2.4b)
```

Because Part A found **zero** bispharma topology in tsp12, none of these can be
pre-filled from the DB — they are read from the flow and confirmed by a live tee.
If the flow already emits clean ASCII/upper strings, **all three lists stay empty**
and bispharma also reduces to a SYNTHESIZE from its equipment inventory.

---

## 3. Reconcile flow-vs-register — nothing to reconcile

For both tenants, `packml_register` in tsp12 is **empty** (Part A §0). There is **no
registered topic set that differs from the flow's published topics** — the classic
"flow publishes `NovoFlex_015`, register stores `NovoFlex-015`" discrepancy
(Incoplast) **cannot arise** here, because there is no register row to disagree
with. The canonical model *is* the register: the descriptor generates the
`packml_register` seed (ADR-0045 §2.2), so flow-published canonical topic ==
registered `packml_topic` **by construction**. This is the payoff of onboarding a
greenfield tenant on the new architecture instead of migrating a legacy one.

The one discrepancy Part A *did* surface — bisnago flow counter ids 670–683
colliding with NEOPAC `id_equipment` — is resolved by the canonical model assigning
**fresh** surrogate ids and treating the legacy counter id as an *inferred* count
index to be re-captured, never as identity.

---

## 4. One tenant vs two — recommendation: **TWO tenants, one commercial group**

Part A's shared-signals (identical enterprise config §1; the 13 `bisnago.ind.br`
users under ent 4 §2; the shared `bispharma_bisnago_publisher` PubSub topic) prove
Bispharma + Bisnago are **one commercial group**. But on the new stack they must be
**two tenants**, not one tenant / two sites:

| Factor | Verdict |
|---|---|
| `id_enterprise` | **distinct** (4 vs 119) — the `packml_register` cross-tenant guard (ADR-0043 §2) is keyed per `enterprise_id`; one agent profile cannot span two |
| `api_key` | **distinct** per enterprise |
| PLC integration model | **different** — Bispharma = SparkPlug-string; Bisnago = numeric-counter, counters-only. Different `raw_tag_map` synthesis, different edge shape. |
| mTLS identity (ADR-0042 §6) | **one `CN` per tenant** — a shared agent holding both certs is exactly the mis-publish footgun north-star #5 forbids |
| Physical sites | different factories |

**Decision (resolving ADR-0045 §2.6 for this group): two tenant profiles
(`bispharma-profile.yaml`, `bisnago-profile.yaml`), two `sparkplug-agent`
instances of the one multi-tenant image, two mTLS CNs, two enterprise_ids.** Model
the group linkage only where it is real:

- **Shared user pool.** Decide in tenant-prep whether the 13 `bisnago.ind.br` users
  stay under ent 4 (matches legacy) or split to ent 119. Recommend **split to 119**
  on the new stack so a Bisnago login resolves to the Bisnago tenant
  (`refdata-api` resolves Firebase JWT → `id_enterprise` server-side); otherwise
  Bisnago users would see Bispharma's tenant. This is a data decision, not an
  architecture one.
- **Shared publisher.** The single `bispharma_bisnago_publisher` PubSub topic is a
  **legacy-edge** artifact; on the new stack each tenant gets its own ingest
  front-door + `edge_node_id` (`bispharma-tee` / `bisnago-tee`). The shared
  publisher does **not** survive the migration.

Revisit "merge to one enterprise" only if the client explicitly wants a single
OEE rollup across both plants — a reporting choice, made above the tenant/agent
layer, not a reason to collapse the two agents.

---

## 5. Onboarding sequence (per tenant, ADR-0045 §2.5 describe→generate→capture→validate→cutover)

Both tenants follow the same gated flow; the greenfield status means step ① is
"author from intake," not "reverse-engineer":

1. **DESCRIBE** — fill `<tenant>.descriptor.yaml` (bisnago partially done, PR #632;
   bispharma scaffold exists). Reserve a **fresh** staging `id_equipment` block
   above `max(id_equipment)` — never 670–683 (NEOPAC).
2. **GENERATE** — `onboard-gen` → profile + `packml_register` SQL + agent
   `client.yaml` + tee snippet. Indices/tree left as observe-placeholders.
3. **CAPTURE** — live tee → agent in observe posture; record the real count indices
   (and, for bisnago, resolve the 2-ids-per-line meaning). Fill `count_index`
   overrides as **confirmed**.
4. **VALIDATE** — 0 unmapped topics; Mode-A parity gate (F3-from-agent vs ground
   truth). For bisnago, set `production_speed` (rated) + `status_type≠4` first, or
   Performance can't compute / `running_time` overflows.
5. **CUT OVER** — flip `AGENT_TAGMAP_FROM_REGISTER` per tenant, reversible.

---

## 6. Open questions (all NEEDS-CLIENT / tenant-prep)

1. **Bisnago 2-ids-per-line** — two machines, or processed + consumed on one? (Part
   A §3; unresolved by any table.) Drives whether members are 2 machines or 1
   machine with a Quality source.
2. **Bisnago dormant lines** — are the 12 `192.168.5.x` endpoints decommissioned or
   paused? (Part A §3.)
3. **Bisnago rated speeds** — `production_speed` per line (units/min), required for
   the counters-only Performance path.
4. **Bispharma tree + flow shape** — sites/areas/lines/machines + whether the flow
   emits clean or quirky SparkPlug strings (sibling extraction).
5. **Shared users** — keep 13 `bisnago.ind.br` users under ent 4 or split to 119 (§4).
6. **Site short-codes** — `BISPHARMA/<SITE>`, `BISNAGO/<SITE>` canonical heads.
</content>
