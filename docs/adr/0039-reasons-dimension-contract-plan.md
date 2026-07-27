# ADR-0039 R5 — Reasons-dimension CONTRACT plan (drop the `equipments.*_reasons` jsonb)

**Status:** Proposed · **Date:** 2026-07-23 · **Scope:** SEQUENCED PLAN ONLY — the only code that ships with this doc is the *additive, dual-read* refdata-api dataset (`equipment-downtime-reasons-dim`). Every consumer cutover and the final `DROP COLUMN` are **GATED follow-ups**, each in its own PR. · **Task:** #12 (medallion R5/R6 CONTRACT) · **Builds on:** [ADR-0039](0039-entity-lifecycle-deletion-strategy.md), R5 EXPAND migration (`0039-reasons-dimension.sql`, PR #586).

---

## 1. Where we are (EXPAND done) and what CONTRACT means

R5 EXPAND (PR #586) fixed the one genuine normal-form violation on `equipments`:
`downtime_reasons` / `scrap_reasons` were inline JSONB arrays — a repeating group (1NF)
whose elements are their own entity in a non-key column (3NF), with no dimension and no
FK on the reason codes. EXPAND created the normalized target and backfilled it, **keeping
the jsonb in place** (dual-source):

| Object | Role | Staging state (packiot_shadow, 2026-07-23) |
|--------|------|--------------------------------------------|
| `downtime_reason` | reason dimension (enterprise-scoped, self-ref `parent_id` hierarchy, `label_i18n`, classification flags) | 54 rows (18 codes × 3 enterprises) |
| `equipment_downtime_reason` | equipment ↔ reason junction (FK'd both sides) | 1188 rows (66 equip × 18 codes) |
| `scrap_reason` / `equipment_scrap_reason` | mirror shape | 0 rows (scrap vocabulary 100% empty on staging) |
| `equipments.downtime_reasons` / `scrap_reasons` | **legacy jsonb, KEPT** | intact (dual-source) |

**EXPAND/CONTRACT is the standard zero-downtime schema-change pattern** (Stripe/GitHub call
it "expand-contract" or "parallel change"). EXPAND adds the new shape and dual-writes/dual-sources
so old and new coexist; CONTRACT migrates every *reader* to the new shape, verifies parity, then
removes the old shape. **You may only drop the old column once no consumer reads it — never before.**
The hazard the ordering defends against: drop the jsonb while one reader still binds it → that reader
500s (or worse, silently returns empty) in production. For the operator downtime picker, "silently
returns empty" means **operators on the factory floor cannot justify a downtime** — a P1.

This doc sequences the readers in **dependency order** so each step is independently verifiable
and reversible, and the irreversible `DROP COLUMN` lands last, behind every green check.

---

## 2. What ships in THIS PR (step 0 — additive, safe, dual-read)

A new refdata-api read dataset, **`equipment-downtime-reasons-dim`**, serving the same
per-equipment downtime-reason vocabulary from the R5 dimension + junction instead of the
jsonb. The jsonb-sourced dataset (`equipment-downtime-reasons`) is **untouched** — both are
served in parallel (dual-read) so no consumer is forced to move in this pass.

```sql
SELECT j.id_equipment, e.nm_equipment, r.id AS id_reason, r.code, r.label,
       r.label_i18n, r.category, r.parent_id, r.reason_level,
       r.planned_downtime, r.change_over, r.idle
FROM equipment_downtime_reason j
JOIN downtime_reason r ON r.id = j.id_reason
JOIN equipments e ON e.id_equipment = j.id_equipment
WHERE e.id_enterprise = $1 AND e.id_equipment = $2 AND e.active
  AND j.active AND r.active
ORDER BY r.reason_level, r.category, r.code
```

Properties:
- **FK-clean end-to-end** — junction → dimension → enterprise. A tenant can only read reason
  rows FK'd to its own equipment; enterprise self-scopes to `$1`, equipment id is the required
  client filter `$2` (identical ownership shape to the legacy dataset and the `overview-detail` group).
- **i18n preserved** — `label_i18n` (full jsonb map) is projected, not just the flattened en-US `label`.
- **Hierarchy preserved** — `category` / `parent_id` / `reason_level` let a consumer rebuild the
  two-level category→subcategory tree the operator picker renders today.
- **Contract-gated** — the drift contract (`contract.go` / `contract.golden.json`) now records the
  three backing relations and their columns. Regenerated golden is committed; the full refdata test
  suite is green.

**Prod gating (important):** `downtime_reason` / `equipment_downtime_reason` exist on staging
`packiot_shadow` only — the R5 migration is prod-GATED. The manual `live-drift` gate
(`refdata-contract-drift.yml`, `workflow_dispatch`) will **correctly** report these two relations as
absent from prod until R5 is prod-applied. That prod-apply is a prerequisite step below, not a
regression. Per-PR CI (`contract-selfcheck`, no prod access) passes on the regenerated golden.

---

## 3. The sequenced CONTRACT plan (GATED follow-ups — NOT in this PR)

Ordering principle: migrate **leaf readers before the shared source**, and the **lowest-blast-radius,
easiest-to-roll-back reader first**, so that by the time we touch the operator picker (highest risk)
the pattern is proven on safer surfaces. The `DROP COLUMN` is strictly last.

### Step P — prerequisite: apply R5 to prod (gated)
- Apply `0039-reasons-dimension.sql` to prod under the standing prod-apply gate (SELECT-only verify
  of the four expected row counts first; the migration is idempotent + reversible).
- **Verify:** `live-drift` gate green — prod now has `downtime_reason` + `equipment_downtime_reason`
  with the projected columns. FK integrity clean (0 orphans). jsonb columns still intact.
- **Rollback:** DROP the 4 new tables + `set_updated_at()` (additive DDL, fully reversible).

### Step 1 — reports / BigQuery (lowest risk: offline, no live write path) — BUILT (flag-gated dual-read, default OFF)
Consumers: `oeecloud-worker/reports` `sap13_body.sql`, BigQuery exports that read the reason vocabulary.

**What shipped (this PR):** the `sap13` report (NEOPAC ent 13 — the only reports consumer that reads
the jsonb; it builds a category-code→description vocabulary lookup) now has a **dual-read swap**, gated
by `SAP13_REASONS_FROM_DIM` (default **false** = byte-identical jsonb path):
- The verbatim `sap13_body.sql` (ADR-0012 Wave-2 prod port) is **unchanged**. Its jsonb reason CTE
  chain (`top_level → category_level → downtime_codes`) is extracted byte-for-byte into
  `sap13_reasons_jsonb.sql`; the normalized replacement (`downtime_reason` + `equipment_downtime_reason`,
  `reason_level=1` categories) lives in `sap13_reasons_dim.sql`. Both emit the same
  `downtime_codes(position, description)` contract, so every downstream CTE is untouched.
- At run time, `SAP13_REASONS_FROM_DIM=true` swaps the jsonb block for the dim block via an exact
  substring replace that **fails loud** if the body drifted (never a silent no-op). A unit test locks
  the block-to-body match (exactly-once substring), the swap correctness, and the loud-failure path.
- `SAP13_REPORT_ENABLED` is already `true` on staging, so the flag is a live, reversible A/B lever.
  jsonb NOT dropped.

**Verify before flipping the flag on:** run `docs/adr/reference/designs/0039-sap13-reasons-parity.sql`
(SELECT-only, staging `packiot_shadow`) — the two EXCEPT sets show exactly how the jsonb- and
dimension-derived `(position, description)` vocabularies differ.

**IMPORTANT — this is a latent bug-fix, NOT byte-parity (definitive live finding, packiot_shadow
2026-07-26):** the report reads the category label from the jsonb `->'name'->>'en-US'` key, but on the
live data the `name` key is **never present** (categories: `name`=0 / `description`=1400; subcategories:
0 / 3640). So the jsonb path's `downtime_codes.description` is **NULL for every row**, the downstream
`ee.cd_category::text = dc.description` join never matches, and every stop today falls into the
no-reason/microstop buckets — a pre-existing reports bug. The R5 backfill correctly reads
`->'description'`, so the **dimension path is the correct one**: flipping `SAP13_REASONS_FROM_DIM=true`
starts matching categories that never matched before. Therefore the flag default stays **OFF** (preserves
today's behavior) and flipping it is a **behavioral change requiring the report owner's sign-off**, not a
silent parity swap. Reports are offline/batch, so the change is caught in the diff, not by an operator.
- **Rollback:** set `SAP13_REASONS_FROM_DIM=false` (or revert); jsonb still present.

(BigQuery exports: no export reads the reason vocabulary today — `sap13` is the only jsonb reader in the
reports/export surface. A future export that reads reasons repoints to the dimension the same way.)

### Step 2 — front4 (medium risk: read-only UI, no PackML write) — BUILT (flag-gated dual-read, default OFF; front4 PR #218)
Consumers: `pages/Settings/DowntimeReasons2/*` (config viewer/uploader), `pages/Downtimes/*`
(`DialogEdit.jsx`, split/trim dialogs). (`DowntimeReason.jsx` reads downtime *aggregates*, and
`_MissionControl/StatusHistory.jsx` reads status *percentages* — neither reads the reason vocabulary;
both verified and left untouched.)

**What shipped (front4 branch `feat/task12-r5-front4-reasons-dim`, PR #218 → front4 `staging`, NOT
merged):** the five vocabulary consumers were already on refdata (reading the legacy
`equipment-downtime-reasons` jsonb dataset from the ADR-0032 cutover). Added a `VITE_REASONS_FROM_DIM`
flag (default **OFF** = legacy jsonb path), a pure `reshapeReasonsDimRows()` helper (folds the flat
`equipment-downtime-reasons-dim` rows back into the `machine → category → subcategory` tree via
`reason_level` + `category`/`parent_id`), and a `useLazyDowntimeReasons()` seam swapped into each
consumer. 8/8 touched-file tests green. Upload/write path (`DowntimeReasonsUpload.jsx` CSV POST) left
intact for Step 3's write-side design.

**Verify before flipping:** DowntimeReasons2 tree + Downtimes picker render the same categories/
subcategories (labels, codes, flags) per enterprise. **Two known fidelity gaps (same root as Step 3):**
the flat dimension drops the top-level **machine** grouping (front4 synthesizes one node keyed on
`nm_equipment`, so the machine `code`/`cd_machine` preselect differs from the legacy value) and exposes a
single `label` (so reshaped `name` === `description`). Both are why it ships dark.
- **Rollback:** `VITE_REASONS_FROM_DIM=false` or revert the component reads; jsonb still present.

### Step 3 — edge-node-red operator justify-event flow (HIGHEST RISK — LIVE picker + PackML write)
Consumer: `subflows/Create/justify events` + the GraphQL loader in `flows/GraphQL.json` that
populates the `_downtime_reasons` global (keyed by `packmlTopic`), consumed as
`global.get("_downtime_reasons")[packmlTopic]` and emitted as PackML parameter **30810**.

**Why this is the highest-risk step — do it LAST and most carefully:**
- It is a **live operator-facing picker on the factory floor**. If it returns empty or the wrong
  shape, operators **cannot justify downtimes** → downtime data is lost/miscoded at the source →
  OEE corruption downstream. This is a P1, not a cosmetic bug.
- It **feeds a write** (PackML 30810 back to the PLC), so a shape mismatch is not read-only — it can
  push a malformed/empty justification.
- The global is keyed by `packmlTopic` and carries the **nested category→subcategory tree** the UI
  expects; the dimension exposes the same tree flat (`parent_id`/`reason_level`). The loader query
  must **re-nest** the dimension rows into the exact shape the subflow consumes — byte-for-byte for
  the fields the subflow reads.

**DESIGN PRODUCED (this pass, NOT cut over)** — full design + shape-diff + bake plan in
`docs/adr/reference/designs/0039-operator-justify-reasons-migration.md` and
`docs/adr/reference/designs/0039-operator-justify-shapediff.sql`. Definitive live findings:
- **Loader nodes:** `flows/GraphQL.json` node `89e16e3913a15d57` ("Save Downtime Reasons") sets
  `_downtime_reasons[packml_topic] = <raw jsonb array>` (no transform); the query builder is node
  `a6785d6d4f173dd0`. Consumer: `flows/API.json` node `63b722c0c1851e52` ("Build Justify Event Request",
  emits `.../Status/Parameter[30810]`), entered via node `0878e826d0603bef`.
- **The top-level per-machine grouping is LOAD-BEARING, not presentation.** The emitter enters the tree
  via `downtimeReasons.find(m => m.code == idMachine)`; if no machine node matches `idMachine` it sets
  `error=true` → HTTP 400 → **no 30810 write**. And that per-equipment set of machine codes lives **only
  in the jsonb** (the junction records only `(id_equipment, id_reason)`, flattening it away) and follows
  no clean hierarchy rule (e.g. the tp=3 lines each list the same 28 cross-line machine codes). So it
  **cannot** be safely reconstructed from the dimension alone for a PLC write path.
- **Label key = `description`, definitively** (name=0 rows live); re-nest emits `description` from
  `label_i18n` + `code`, never synthesizes `name`.

Cutover procedure (staging first, long bake — GATED, do NOT execute now):
1. Change **only** the global-builder node `89e16e3913a15d57` to re-nest: source the **vocabulary** from
   the dimension (`equipment-downtime-reasons-dim` or GraphQL on the junction→dimension), fold flat rows
   into `categories[{code, description, planned_downtime, change_over, idle, subcategories[...]}]` by
   `parent_id`/`reason_level`, and source the **top-level machine codes** from a thin
   `downtime_reasons[*].code` jsonb read; emit the outer product per `packml_topic`. Do **not** touch the
   justify subflow consumption logic.
2. **Shape-diff** (`0039-operator-justify-shapediff.sql`) the rebuilt global vs the jsonb-derived one for
   every `packmlTopic` — deep-equality of the fields the subflow reads. (A1 category + A2 subcategory
   already ran clean against enterprise 3 on staging.)
3. Bake over a full shift cycle on staging with real operator justifications; confirm 30810 payloads are
   identical to the jsonb path.
4. Also update `hasura/metadata.json` if the loader's GraphQL relationship changes.
- **Rollback:** the loader is one node — revert it; the subflow and jsonb are untouched.

### Step 4 — CONTRACT: DROP the jsonb (irreversible — final, all-green gate)
Only after Steps 1–3 are live and verified in prod for a bake period with **zero** reads of the jsonb.

**⚠️ BLOCKER (definitive): the `downtime_reasons` jsonb CANNOT be fully dropped after Step 3 as-is.** The
top-level per-machine attribution set per equipment — which gates the operator's PackML 30810 write
(Step 3) — exists **only** in the jsonb; R5 stores nothing of it, and both the reports (Step 1, if
enabled) and the front4/operator re-nests still read it thinly. Dropping the column is gated on one of:
(a) a new **R5b `equipment_attribution_machine(id_equipment, id_machine)` junction** backfilled from
`jsonb_path_query(downtime_reasons,'$[*].code')`, then repoint the machine-code read to it; or
(b) retain a **minimal jsonb skeleton** holding only the top-level `code` array (drop only the nested
`categories`/`subcategories` vocabulary, which R5 fully covers). Choose (a) for a clean CONTRACT.
- Confirm no reader remains: grep the four consumer surfaces (refdata `equipment-downtime-reasons`
  legacy dataset, `/v1/downtime-reasons` route in `main.go`, front4, edge-node-red, reports/BigQuery)
  for `downtime_reasons` / `scrap_reasons`; confirm the legacy refdata dataset + route are removed or
  repointed. Optionally instrument the legacy dataset to log any residual hits over the bake.
- Migration: `ALTER TABLE equipments DROP COLUMN downtime_reasons, DROP COLUMN scrap_reasons;`
  (staging `packiot_shadow` first, then prod under the gate).
- Remove the legacy refdata dataset `equipment-downtime-reasons` and (if fully migrated) the
  `/v1/downtime-reasons` route; regenerate the contract golden.
- **Verify:** full refdata suite green; `live-drift` green (contract no longer references the dropped
  columns); operator picker + front4 + reports still correct.
- **Rollback:** this step is **irreversible** without a restore — that is why it is last and gated on a
  clean bake. The data is not lost (it lives in the dimension); only the denormalized copy is dropped.

---

## 4. Dependency-order summary

| Step | Consumer | Risk | Live write? | Status | Rollback |
|------|----------|------|-------------|--------|----------|
| 0 (this PR) | refdata additive dataset | none (additive/dual-read) | no | **DONE** | revert dataset |
| P | prod-apply R5 migration | low (additive DDL) | no | pending (gated) | drop 4 tables |
| 1 (this PR) | reports / BigQuery (`sap13`) | low (offline batch) | no | **BUILT — flag OFF** (`SAP13_REASONS_FROM_DIM`) | flag off / revert |
| 2 (front4 PR #218) | front4 Settings/Downtimes | medium (read UI) | jsonb upload path intact | **BUILT — flag OFF** (`VITE_REASONS_FROM_DIM`) | flag off / revert reads |
| **3** | **edge-node-red operator justify flow** | **HIGHEST (live picker + PackML 30810 write)** | **yes** | **DESIGNED — NOT cut over** | revert one loader node |
| 4 | `DROP COLUMN` jsonb | irreversible | n/a | **BLOCKED** on R5b attribution junction (or minimal jsonb skeleton) | restore only |

**One-line risk callout:** the load-bearing, do-it-last, bake-the-longest step is the **operator
justify-event flow** — a live factory-floor picker that feeds a PackML write; a shape mismatch there
silently stops operators from justifying downtimes and corrupts OEE at the source. Everything else is
sequenced before it precisely so the pattern is proven on read-only/offline surfaces first.
