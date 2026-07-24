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

### Step 1 — reports / BigQuery (lowest risk: offline, no live write path)
Consumers: `oeecloud-worker/reports` `sap13_body.sql`, BigQuery exports that read the reason vocabulary.
- Repoint these SELECTs to `downtime_reason` + `equipment_downtime_reason` (or the new dataset).
- **Verify:** row-for-row parity between the jsonb-derived report and the dimension-derived report
  over a fixed window (counts + code sets + i18n labels identical). Reports are offline/batch, so a
  regression is caught in the diff, not by an operator.
- **Rollback:** revert the query; jsonb still present.

### Step 2 — front4 (medium risk: read-only UI, no PackML write)
Consumers: `pages/Settings/DowntimeReasons2/*` (config viewer/uploader), `pages/Downtimes/*`
(`DowntimeReason.jsx`, `DialogEdit.jsx`, split/trim dialogs), StatusHistory.
- Switch these reads from the Hasura/jsonb path to the refdata `equipment-downtime-reasons-dim`
  dataset. Reshape the two-level tree from `category`/`parent_id`/`reason_level` (was: nested jsonb).
- **Verify:** the DowntimeReasons2 tree and the Downtimes reason picker render an identical set of
  categories/subcategories (labels, codes, classification flags) before vs after, per enterprise.
  Note the **upload/write** path in `DowntimeReasonsUpload.jsx` — if front4 still *writes* the jsonb,
  that write path must be handled in Step 3's write-side design or kept dual-writing until then.
- **Rollback:** feature-flag or revert the component reads; jsonb still present.

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

Cutover procedure (staging first, long bake):
1. Change **only the GraphQL loader** that builds `_downtime_reasons` to source from
   `downtime_reason` + `equipment_downtime_reason` (or the refdata dataset), re-nesting to the exact
   legacy shape. Do **not** touch the justify subflow's consumption logic yet.
2. **Shape-diff** the rebuilt `_downtime_reasons` global against the jsonb-derived one for every
   `packmlTopic` on staging — assert deep-equality of the keys/fields the subflow reads.
3. Bake over a full shift cycle on staging with real operator justifications; confirm PackML 30810
   payloads are identical to the jsonb path.
4. Also update `hasura/metadata.json` if the loader's GraphQL relationship changes.
- **Rollback:** the loader is one node — revert it; the subflow and jsonb are untouched.

### Step 4 — CONTRACT: DROP the jsonb (irreversible — final, all-green gate)
Only after Steps 1–3 are live and verified in prod for a bake period with **zero** reads of the jsonb.
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

| Step | Consumer | Risk | Live write? | Rollback |
|------|----------|------|-------------|----------|
| 0 (this PR) | refdata additive dataset | none (additive/dual-read) | no | revert dataset |
| P | prod-apply R5 migration | low (additive DDL) | no | drop 4 tables |
| 1 | reports / BigQuery | low (offline batch) | no | revert query |
| 2 | front4 Settings/Downtimes | medium (read UI) | jsonb upload path TBD | revert reads |
| **3** | **edge-node-red operator justify flow** | **HIGHEST (live picker + PackML 30810 write)** | **yes** | revert one loader node |
| 4 | `DROP COLUMN` jsonb | irreversible | n/a | restore only |

**One-line risk callout:** the load-bearing, do-it-last, bake-the-longest step is the **operator
justify-event flow** — a live factory-floor picker that feeds a PackML write; a shape mismatch there
silently stops operators from justifying downtimes and corrupts OEE at the source. Everything else is
sequenced before it precisely so the pattern is proven on read-only/offline surfaces first.
