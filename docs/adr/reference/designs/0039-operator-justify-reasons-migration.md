# ADR-0039 R5 CONTRACT — Step 3 design: operator justify-flow downtime-reasons re-nest migration

**Status:** DESIGN ONLY — NOT cut over. No edge-node-red flow file is modified by this
document. This is the gated-execution-ready plan for migrating the highest-risk consumer
of `equipments.downtime_reasons` off the inline jsonb and onto the R5 normalized
`downtime_reason` + `equipment_downtime_reason` dimension.

**Consumer under design:** the edge-node-red operator **downtime-justify flow** — a
live factory-floor picker that writes **PackML parameter 30810** back to the PLC. This is
a write-back path to physical equipment; a shape regression here mis-attributes a
downtime (wrong category/planned/idle flags) or fails the justify outright. Treat every
byte as load-bearing.

**Task:** #12 · **ADR:** 0039 (entity-lifecycle) · medallion R5 CONTRACT · sequenced
after the additive dual-read dataset (`equipment-downtime-reasons-dim`, already shipped in
refdata-api) and after the R5 EXPAND migration (`0039-reasons-dimension.sql`, staging
`packiot_shadow` only, prod-gated).

---

## 0. TL;DR / the crux

| Question | Answer (evidence-backed) |
|---|---|
| Is the **top-level per-machine attribution grouping** used downstream? | **YES — load-bearing.** The justify builder's FIRST lookup is `downtimeReasons.find(m => m.code == idMachine)`; if a category was requested and this machine grouping is not found, the flow sets `error=true` and returns HTTP 400 (no 30810 write). See §2. |
| Is that top-level grouping **reconstructable from the R5 dimension + junction alone**? | **NO.** The dimension flattens category/subcategory vocabulary; the junction records only `(id_equipment, id_reason)`. **Neither stores the set of machine-name codes that appears at the top level of a given equipment's array.** The vocabulary re-nests cleanly; the per-machine attribution skeleton does not. See §3. |
| What is the live jsonb **label key** — `name` or `description`? | **`description`, definitively.** Live probe (packiot_shadow, 2026-07-26): categories `name=0 / description=1400`; subcategories `name=0 / description=3640`. `name` is **never present**. The R5 backfill (reads `->'description'`) is correct; the reports SQL that reads `->'name'->>'en-US'` returns NULL on this data (latent reports bug, out of scope here). See §4. |
| Can jsonb be **dropped** after this step? | **NO — blocker.** The top-level machine-attribution set is not stored anywhere in R5. Dropping `equipments.downtime_reasons` erases it. Dropping is gated on either (a) retaining a thin jsonb skeleton, or (b) a new R5b `equipment_attribution_machine` junction. See §7. |

---

## 1. Current loader — how `_downtime_reasons` is built

Two function nodes in **`edge-node-red/flows/GraphQL.json`** populate the global.

### 1a. Query builder — node `a6785d6d4f173dd0` "Hasura GET_DOWNTIME_REASONS"

Builds a Hasura GraphQL POST. The query (topic-scoped variant) is verbatim:

```graphql
query GET_DOWNTIME_REASONS($topic: [String!]) {
  equipments(where: {packml: {packml_topic: {_in: $topic}}}) {
    downtime_reasons
    packml { packml_topic }
    scrap_reasons
  }
}
```

(The un-scoped fallback pulls every `equipments` where `packml.active = true`.) The key
fact: it selects the **whole `downtime_reasons` jsonb column raw** — no server-side
shaping — plus the routing key `packml.packml_topic`.

### 1b. Global builder — node `89e16e3913a15d57` "Save Downtime Reasons"

```js
let data = msg.payload.data.equipments.map((item) => ({
    downtime_reasons: item.downtime_reasons,   // <-- raw jsonb array, verbatim
    topic: item.packml.packml_topic
}))
...
const new_arr = {}
data.forEach(function(load, index) {
    const foo = load.topic;
    const v  = { [foo]: load.downtime_reasons};   // key = packml_topic, value = raw array
    Object.assign(new_arr,v);
})
global.set("_downtime_reasons", new_arr )
```

**Therefore the invariant the re-nest must satisfy:**
> `global.get("_downtime_reasons")[packmlTopic]` **=== the raw `equipments.downtime_reasons`
> jsonb array for the equipment that owns `packmlTopic`.** No transform sits between the DB
> and the global today. The re-nest must rebuild that identical array shape from the
> dimension.

(Also present: node `f18c13af373dfed1` "Parse Topic" enumerates `Object.keys(_downtime_reasons)`
to seed `_events_meta` — it only reads the KEYS, i.e. the topic set, so it is shape-agnostic
and unaffected by the re-nest as long as the same topics are present.)

---

## 2. Consumer — the justify subflow that emits PackML 30810

Two function nodes in **`edge-node-red/flows/API.json`** consume the global.

### 2a. node `0878e826d0603bef` "Get Downtime Reasons"

```js
let downtimeReasons = global.get("_downtime_reasons");
const { packmlTopic } = msg.payload;
msg.payload = {};
msg.payload.downtimeReasons = downtimeReasons?.[packmlTopic];   // the raw array for this topic
```

### 2b. node `63b722c0c1851e52` "Build Justify Event Request" — the 30810 emitter

This node sets the PackML topic and reads the reasons tree. Verbatim excerpts:

```js
let packmlParameterId = 30810;
...
msg.topic = packmlTopic + "/Status/Parameter[30810]";

let downtimeReasons = global.get("_downtime_reasons");
downtimeReasons = downtimeReasons?.[packmlTopic];

if (!downtimeReasons) { error = true; }
else {
    machineDowntimes = downtimeReasons?.find((machineDowntime) => machineDowntime.code == idMachine);
    if (idDwtCategory && !machineDowntimes) { error = true; }
    else {
        categoryDowntime = machineDowntimes?.categories?.find((c) =>
            c.code == idDwtCategory
            || c?.name?.["en-US"].toUpperCase()        == idDwtCategory.toUpperCase()
            || c?.description?.["en-US"].toUpperCase()  == idDwtCategory.toUpperCase());
        if (idDwtCategory && !categoryDowntime) { error = true; }
        else {
            subcategoryDowntime = categoryDowntime?.subcategories?.find((s) =>
                s.code == idDwtSubcategory
                || s?.name?.["en-US"]
                || (s?.code?.toUpperCase()               == idDwtSubcategory.toUpperCase())
                || (s?.description?.["en-US"]?.toUpperCase() == idDwtSubcategory.toUpperCase()));
            if (idDwtSubcategory && !subcategoryDowntime) { error = true; }
        }
    }
    if (subcategoryDowntime) {
        isPlannedEvent    = subcategoryDowntime?.planned_downtime;
        isChangeOverEvent = subcategoryDowntime?.change_over;
        isIdleEvent       = subcategoryDowntime?.idle;
    } else if (categoryDowntime) {
        isPlannedEvent    = categoryDowntime?.planned_downtime;
        isChangeOverEvent = categoryDowntime?.change_over;
        isIdleEvent       = categoryDowntime?.idle;
    }
}
...
msg.payload = {
    "cdMachine":       machineDowntimes ? machineDowntimes?.code : "",
    "cdCategory":      categoryDowntime ? (categoryDowntime?.name?.["en-US"] || categoryDowntime?.code || "") : "",
    "descCategory":    categoryDowntime ? categoryDowntime?.description?.["en-US"] : "",
    "cdSubcategory":   subcategoryDowntime ? (subcategoryDowntime?.name?.["en-US"] || subcategoryDowntime?.code || "") : "",
    "descSubcategory": subcategoryDowntime ? subcategoryDowntime?.description?.["en-US"] : "",
    "plannedDowntime": isPlannedEvent,
    "idle":            isIdleEvent,
    "changeOver":      isChangeOverEvent,
    "txtDowntimeNotes": eventNotes,
    "idEquipmentEvent": idEquipmentEvent,
    "idEquipment":      idEquipment,
};
```

### Exact set of fields the subflow reads (the byte-identity contract)

| Level | Field read | Used for |
|---|---|---|
| **top-level** | `.code` | `find(code == idMachine)` — machine attribution match; `cdMachine` output |
| category | `.code` | match + `cdCategory` fallback |
| category | `.name?.["en-US"]` | match + `cdCategory` (always undefined on live data — see §4) |
| category | `.description?.["en-US"]` | match + `descCategory` output |
| category | `.planned_downtime` | `plannedDowntime` output |
| category | `.change_over` | `changeOver` output |
| category | `.idle` | `idle` output |
| category | `.subcategories` | descend to subcategory |
| subcategory | `.code` | match + `cdSubcategory` fallback |
| subcategory | `.name?.["en-US"]` | match + `cdSubcategory` (always undefined — §4) |
| subcategory | `.description?.["en-US"]` | match + `descSubcategory` output |
| subcategory | `.planned_downtime` / `.change_over` / `.idle` | planned/changeOver/idle output |

**Note on array ORDER:** every access is `.find(...)` (content-addressed) — the 30810
payload does **not** depend on array ordering. The re-nest need not preserve element
order; it must preserve the field *set* and *values* per node. (The shape-diff test in
§6 still sorts deterministically so the assertion is order-stable.)

### DEFINITIVE: the top-level per-machine grouping IS used

The first `.find((m) => m.code == idMachine)` is the entry point. `idMachine` is the
machine the operator attributed the stop to (a machine **name**, e.g. `L5-BREYER`).
When `idDwtCategory` is present and no top-level entry matches `idMachine`, the flow
short-circuits to `error=true` → HTTP 400 → **no 30810 write**. The grouping is not
cosmetic; it gates the whole write-back. Any re-nest that drops or mis-keys the top level
breaks justify.

---

## 3. The R5 dimension and WHY the top-level grouping does not survive it

### Live legacy shape (probed SELECT-only on packiot_shadow, 2026-07-26)

```
downtime_reasons  (jsonb array, 3 levels):
  [ { "code": <machine name>,                      <-- per-machine ATTRIBUTION grouping
      "categories": [
        { "code", "description": {"en-US": ...},   <-- label key is "description"
          "planned_downtime", "change_over", "idle",
          "subcategories": [
            { "code", "description": {...},
              "planned_downtime", "change_over", "idle" } ] } ] }, ... ]
```

### R5 normalized shape (`0039-reasons-dimension.sql`, staging only)

```
downtime_reason(id, id_enterprise, code, label, label_i18n jsonb, category,
                parent_id, reason_level [1=cat,2=sub], planned_downtime,
                change_over, idle, active, ...)
equipment_downtime_reason(id_equipment, id_reason, active, ...)   -- junction
```

- `label`      = flattened `description->>'en-US'`
- `label_i18n` = the whole `description` i18n map (no loss)
- category↔subcategory hierarchy = `parent_id` / `reason_level`
- the junction records the many-to-many **(equipment ↔ reason vocabulary)** — it
  **flattens the per-member repetition**.

### The lossy point, demonstrated

Live distribution of top-level array length (packiot_shadow, 2026-07-26):

| top-level length | # equipment | what they are |
|---|---|---|
| 1  | 47 | tp=1 **machines** — the single top code == the machine's own `nm_equipment` (self-referential) |
| 2  | 2  | small groupings |
| 5  | 5  | groupings |
| 6  | 6  | groupings |
| 28 | 6  | tp=3 **lines** (L3,L4,L5,L6,L8,L10 in ent 3) — each lists the SAME 28 machine codes |

Two decisive facts:
1. **All 58 distinct top-level codes (across all equipment) match an existing
   `nm_equipment` in the same enterprise** (`matched=58 / total=58`). The top-level codes
   ARE machine names.
2. **Within one equipment, the category-code set is identical across every top-level
   grouping** (`distinct_catsets = 1` for every multi-entry equipment). The vocabulary is
   *uniform* — each machine grouping carries the same shared category/subcategory tree.

So the array is, structurally: `{ machine-code } × { shared vocabulary }` — an outer
product. The R5 dimension captures the **shared vocabulary factor perfectly** (proved:
line eq 48 → dimension yields exactly 5 categories + 13 subcategories = the same 5/13 the
jsonb carries). It captures **nothing of the machine-code factor** — the set `{L5-BREYER,
L5-POLYTYPE, …}` for a given equipment lives only in the jsonb.

### Is the machine-code set reconstructable from `equipments` instead?

Not by a clean rule. For a tp=1 machine it is trivially `{ self.nm_equipment }`. But the
six tp=3 lines each list the **same 28 machines** — a set that spans machines named for
L4/L5/L6/L8/L10, i.e. **not** "the line's own member machines." It is an attribution
scope (which machines an operator may blame for a stop on this line), and there is no
`equipments` relationship (lead_machine / id_unit / sector membership) that has been shown
to yield exactly these 28. **Reconstructing it heuristically is unsafe for a PLC
write-back path.** The honest conclusion: the machine-attribution set is data that R5
dropped and must be re-sourced explicitly.

---

## 4. Label-key finding: `description`, not `name`

Live probe (packiot_shadow, 2026-07-26):

```
categories:    has 'name' = 0    has 'description' = 1400
subcategories: has 'name' = 0    has 'description' = 3640
```

- The live jsonb **only ever uses `description`** (an i18n map `{"en-US": ...}`). `name`
  is **never present**.
- Consequence in the consumer: `categoryDowntime?.name?.["en-US"]` is always `undefined`,
  so `cdCategory` = `... || categoryDowntime?.code` → **the code**. `descCategory` =
  `description?.["en-US"]`. Same for subcategory.
- The R5 backfill reads `cat->'description'->>'en-US'` into `label` and `cat->'description'`
  into `label_i18n` — **correct** for this data.
- The reports SQL that reads `->'name'->>'en-US'` would return NULL against this data.
  That is a pre-existing reports latent bug, **out of scope** for this step, but flagged
  so a future reports migration reads `description` / `label_i18n`.

**Re-nest rule from this finding:** emit `description` (the full i18n map, sourced from
`label_i18n`) and `code`. Do **not** synthesize a `name` key — the source has none, and the
consumer's `|| code` fallback makes an emitted `name` a byte-diff for no behavioral gain.

---

## 5. Replacement loader — re-nest the flat dimension back to byte-identical global

### 5.1 Source of the vocabulary factor

Two equivalent options; both return the same flat rows. Prefer **(A)** to keep the loader
on the same Hasura/GraphQL transport it already uses; **(B)** is the ADR-0026 forward
transport.

**(A) GraphQL against the dimension + junction** (drop-in replacement for the query in
node `a6785d6d4f173dd0`):

```graphql
query GET_DOWNTIME_REASONS_DIM($topic: [String!]) {
  equipments(where: {packml: {packml_topic: {_in: $topic}}}) {
    id_equipment
    packml { packml_topic }
    # vocabulary factor — from the normalized dimension via the junction relationship
    equipment_downtime_reasons(where: {active: {_eq: true}, reason: {active: {_eq: true}}}) {
      reason {
        code
        label_i18n
        category
        reason_level
        planned_downtime
        change_over
        idle
      }
    }
    # machine-attribution factor — see 5.2 (thin jsonb skeleton this pass)
    downtime_reasons
  }
}
```

(Hasura relationship names assume `equipment_downtime_reason → reason` FKs are tracked;
if not yet tracked, use option (B).)

**(B) refdata-api dataset** `equipment-downtime-reasons-dim` (already shipped), params
`$1=enterprise, $2=equipment`, returns flat rows:
`id_equipment, nm_equipment, id_reason, code, label, label_i18n, category, parent_id,
reason_level, planned_downtime, change_over, idle`. Loop the equipment set and call once
per equipment (or add an enterprise-wide variant), keyed by the packml_topic resolved from
`packml_register`.

### 5.2 Source of the machine-attribution factor (this pass = thin jsonb skeleton)

Because §3 proved the machine-code set is not in the dimension, this pass keeps a **thin**
read of the jsonb — **only the top-level `code` list**, nothing else:

```graphql
# still selected in 5.1's query as `downtime_reasons`; the re-nest reads ONLY
# jsonb_path_query_array(downtime_reasons, '$[*].code') from it — the vocabulary is
# taken entirely from the dimension.
```

This is the deliberate, documented compromise that **feeds the "do NOT drop jsonb this
pass" rule** (§7). The endgame that removes even this thin read is the R5b attribution
junction in §7.

### 5.3 The re-nest transform (replaces node `89e16e3913a15d57` "Save Downtime Reasons")

Byte-identical rebuild of `_downtime_reasons[packmlTopic]`. Written for source option (A);
for (B) the only change is how `rows` and `topLevelCodes` are obtained.

```js
// Build _downtime_reasons from the R5 dimension (vocabulary) + jsonb top-level codes
// (machine-attribution skeleton). Byte-identical to the legacy raw-jsonb global for
// every field the justify subflow reads (top .code; category/subcategory
// code/description/planned_downtime/change_over/idle/subcategories).
try {
    const equipments = msg.payload.data.equipments;
    const out = {};

    equipments.forEach((eq) => {
        const topic = eq.packml && eq.packml.packml_topic;
        if (!topic) return;

        // ---- 1. vocabulary factor: flat dimension rows -> nested categories tree ----
        const rows = (eq.equipment_downtime_reasons || []).map(j => j.reason);
        const cats = {};   // code -> category node
        const subsByParent = {};  // parent category code -> [subcategory nodes]

        rows.forEach((r) => {
            const node = {
                code: r.code,
                // emit `description` (NOT `name`) = the full i18n map from label_i18n
                description: r.label_i18n,
                planned_downtime: r.planned_downtime,
                change_over: r.change_over,
                idle: r.idle,
            };
            if (r.reason_level === 1) {
                node.subcategories = node.subcategories || [];
                cats[r.code] = node;
            } else { // reason_level === 2
                (subsByParent[r.category] = subsByParent[r.category] || []).push(node);
            }
        });
        // attach subcategories under their parent category (parent = `category` code)
        Object.keys(subsByParent).forEach((parentCode) => {
            if (cats[parentCode]) cats[parentCode].subcategories = subsByParent[parentCode];
        });
        const sharedCategories = Object.keys(cats)
            .sort()                      // deterministic; order is not read by the subflow
            .map(c => cats[c]);

        // ---- 2. machine-attribution factor: top-level machine codes (thin jsonb read) ----
        // ONLY the top-level `.code` list is taken from jsonb this pass.
        const rawArray = Array.isArray(eq.downtime_reasons) ? eq.downtime_reasons : [];
        const machineCodes = rawArray.map(m => m && m.code).filter(Boolean);

        // ---- 3. outer product: { machineCode } x { shared vocabulary } ----
        out[topic] = machineCodes.map((mc) => ({
            code: mc,
            categories: sharedCategories,   // uniform per equipment (proved distinct_catsets=1)
        }));
    });

    global.set("_downtime_reasons", out);
} catch (e) {
    flow.set("ERR", e);
}
```

**What this reproduces, field-by-field, vs the legacy global:**
- top-level `.code` — from `machineCodes` (thin jsonb skeleton) ✔
- category `.code`, `.description` (=label_i18n), `.planned_downtime`, `.change_over`,
  `.idle`, `.subcategories` — from the dimension ✔
- subcategory `.code`, `.description`, `.planned_downtime`, `.change_over`, `.idle` — from
  the dimension ✔
- `.name` — intentionally omitted (absent in source; consumer `|| code` fallback identical) ✔

The `scrap_reasons` sibling global is untouched by this step (scrap dimension is empty on
staging; separate CONTRACT step).

---

## 6. Shape-diff test

See the companion file **`0039-operator-justify-shapediff.sql`** in this directory. It
rebuilds `_downtime_reasons` server-side from the dimension + jsonb-skeleton and asserts
deep-equality, per packml_topic, against the jsonb-derived global for **every field the
subflow reads**. Run it SELECT-only on packiot_shadow; it returns zero rows when clean and
one row per mismatch otherwise. Per-key assertions enumerated inside.

---

## 7. BLOCKER — jsonb cannot be dropped after this step

Even with the loader cut over, **`equipments.downtime_reasons` must be retained** because
the **top-level machine-attribution set per equipment lives only in that jsonb** (§3).
This step's re-nest still reads it (thinly). Two exits, both gated follow-ups:

- **R5b attribution junction (clean endgame):** add
  `equipment_attribution_machine(id_equipment, id_machine)` (or reuse a machine-membership
  relation if one can be *proven* to reproduce the exact sets, incl. the 28-machine line
  sets). Backfill from `jsonb_path_query(downtime_reasons,'$[*].code')` joined to
  `equipments.nm_equipment`. Then the loader sources machine codes from the junction and
  jsonb is fully droppable.
- **Retain-skeleton (do-nothing endgame):** keep a minimal `downtime_reasons` jsonb holding
  only the top-level `code` array. Cheaper but leaves a 1NF wart; acceptable only as an
  interim.

Recommendation: ship this step's loader (vocabulary from the dimension, machine codes from
the thin jsonb read), then land R5b before any CONTRACT drop of `downtime_reasons`.

---

## 8. Bake plan (staging-first, full shift cycle)

**Principle:** the flip is a single loader-node swap; keep both the legacy and re-nest
globals side-by-side under different keys and compare the actual 30810 payload the builder
would produce, before flipping the key the builder reads.

1. **Shadow-load, don't flip (staging packiot_shadow).** Deploy the re-nest loader writing
   to a *parallel* global `_downtime_reasons_dim` (NOT `_downtime_reasons`). The live
   justify builder keeps reading `_downtime_reasons` (jsonb path). Zero behavior change.
2. **Static shape-diff.** Run `0039-operator-justify-shapediff.sql` — must return zero
   mismatch rows across all packml_topics. Gate.
3. **Payload-diff harness (a full shift cycle, ≥ one 24 h cycle incl. shift boundaries).**
   For each real justify request, compute the 30810 `msg.payload` under BOTH paths
   (jsonb-path vs dim-path) using the same `{idMachine, idDwtCategory, idDwtSubcategory,
   eventType, tsEvent, ...}` inputs, and diff:
   `cdMachine, cdCategory, descCategory, cdSubcategory, descSubcategory, plannedDowntime,
   idle, changeOver, statusCode`, and the resolved `msg.topic`
   (`.../Status/Parameter[30810]`). Log any diff; **do not send** the dim-path payload to
   the PLC during bake — compare only.
4. **Cover the matrix:** category-only justify, category+subcategory, unknown machine
   (expect matching 400 on both paths), planned/changeOver/idle-bearing reasons, a tp=1
   machine (len-1 top level) and a tp=3 line (len-28 top level), across ≥2 enterprises.
5. **Flip gate:** payload-diff clean for a full shift cycle AND static shape-diff clean →
   flip the loader to write `_downtime_reasons` (the key the builder reads). Vocabulary now
   comes from the dimension; machine codes from the thin jsonb read.
6. **Prod:** only after R5 migration is prod-applied (dimension + junction exist in prod)
   AND staging bake is clean. Same shadow→diff→flip sequence on prod.

**Rollback:** revert the single loader node (`89e16e3913a15d57`) to its raw-jsonb form (and
node `a6785d6d4f173dd0` to the original query). No schema change to undo — R5 is additive;
jsonb was never dropped. Rollback is a one-node flow redeploy, instantly reversible.

---

## 9. Provenance of the facts in this doc

All live figures probed SELECT-only (`BEGIN READ ONLY`) on staging `packiot_shadow` via
SSM on 2026-07-26:
- label keys: categories `name=0/description=1400`, subcategories `name=0/description=3640`
- top-level length distribution: 1×47, 2×2, 5×5, 6×6, 28×6 (66 equipment total)
- 58/58 distinct top-level codes match `nm_equipment` in-enterprise
- `distinct_catsets = 1` per multi-entry equipment (uniform vocabulary)
- dimension populated: 54 `downtime_reason` rows (15 cat + 39 sub), `label_i18n` never
  null; junction 1188 rows over 66 equipment; line eq 48 dimension → 5 cat + 13 sub ==
  jsonb's 5/13.
- **shape-diff validated:** assertions A1 (category set + description i18n + planned/
  change_over/idle) and A2 (subcategory set + fields) from
  `0039-operator-justify-shapediff.sql` were executed SELECT-only against enterprise 3
  (the richest tenant — the six tp=3 lines) on packiot_shadow and returned **zero mismatch
  rows** — the dimension re-nests the vocabulary factor byte-identically. (The full-surface
  run over all enterprises is a bake-step gate; the whole-DB query is heavier and belongs
  in the harness, not an ad-hoc probe.)

Node ids/quotes are from the submodule checkout at
`edge-node-red/flows/GraphQL.json` and `edge-node-red/flows/API.json` (read-only; not
modified).
