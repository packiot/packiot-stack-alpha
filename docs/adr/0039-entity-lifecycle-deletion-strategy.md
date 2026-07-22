# ADR-0039 — Entity lifecycle & deletion strategy: one delete contract, temporal columns, and SCD-2 history for dimensions

**Status:** Proposed · **Date:** 2026-07-22 · **Scope:** DESIGN ONLY (this ADR is the target strategy + sequenced migration; no code, no schema change ships with it). STAGING-first; every prod-touching step is explicitly gated. · **Decision owner:** data architect (pending USER review).

**Builds on / honors:**
- [ADR-0036](0036-data-architecture-medallion.md) — the medallion data architecture. 0036 makes **Bronze facts immutable/append-only** (`equipment_values`/`equipment_events` as a retained historian, §3). This ADR is the **dimension-side complement**: facts are append-only; the *entities* those facts point at (`equipments`, `packml_register`, `sites`, …) are **dimensions**, and a dimension needs *versioned history*, not immutability and not a boolean. 0036 answers "how do we keep every raw sample forever"; 0039 answers "how do we delete/rename/reconfigure a machine without losing the record of what it *was* when yesterday's samples were taken."
- [ADR-0038](0038-north-star-factory-platform.md) — the north-star. Two of its load-bearing decisions frame this ADR:
  - **Pillar P7 (Traceability / Genealogy) is MISSING** (0038 §4). Genealogy — "which lot ran on which machine, configured *how*, in which shift" — is impossible to reconstruct if a machine's `ideal_speed`/`area`/`name` are *overwritten* on every edit. SCD-2 dimension history (Tier 2 below) is the substrate that pillar stands on.
  - **Principle #6 — CQRS read/write split** (0038 §5): writes through edge-api, reads through **one** authority (refdata-api). Live bug 1 below is a *direct violation* of this principle — the write plane filters `active`, the read plane does not — and Tier 0 fixes it by moving the visibility rule to the single read authority.

> **Numbering:** 0036/0037 (data-arch + OEE correctness) and 0038 (north-star) are the immediate neighbours. 0039 is the entity-lifecycle counterpart to 0036's fact-lifecycle.

---

## 1. Problem & context

Ask the current schema a simple question — *"how do we delete a thing?"* — and it answers **four different ways depending on which thing.** There is no single delete contract, no record of *when / who / what-changed* for any entity, and (because of that) two live production-correctness bugs and one reactivation trap. This ADR turns a DBA review of the deletion surface into a sequenced decision.

The review's one-sentence framing: **the codebase conflates a *fact* (an immutable event that happened) with a *dimension* (an entity whose description changes over time), and reaches for the same crude tool — a boolean — for both.** Facts are being made properly immutable in ADR-0036. Dimensions are being deleted with a visibility flag that records nothing. That mismatch is the root cause of everything below.

### 1.1 Deletion today — four inconsistent patterns

| # | Pattern | Applies to | Evidence (real files) | What it records |
|---|---------|-----------|----------------------|-----------------|
| 1 | **`active` boolean soft-delete** (visibility flag; overwrite-in-place) | `enterprises`, `users`, `packml_register`, `devices` (base schema); `sites`, `areas`, `equipments`, `user_roles` (CS-Admin migrations) | `edge-api/schema.sql:965` (devices), `:979` (enterprises), `:2313` (packml_register), `:3400` (users); migrations `20260414000001_add_active_to_sites_and_areas.ts`, `20260414000003_add_active_to_equipments.ts` (`ADD COLUMN … active boolean NOT NULL DEFAULT true`) | **Nothing but current visibility.** No *when*, no *who*, no *prior value*. |
| 2 | **Hard `DELETE` + FK CASCADE** (row physically gone) | `shifts` (and `shift_hours` via cascade) | `edge-api/src/data/DAO/shifts/shifts-dao.ts:80` — `DELETE FROM shifts WHERE id_shift=$1 AND id_enterprise=$2`, comment: *"`shifts` has no `active` column in prod. Cascade FK … cleans up dependent rows."* | **Nothing at all** — the row and its children are erased. |
| 3 | **Status enum** (lifecycle state, not deletion) | `production_orders` | `edge-api/schema.sql:2375` — `status integer NOT NULL`; enum `available=1/running=2/finished=3/paused=4` (`edge-api/src/enums/production-orders/status.ts`) | Current lifecycle state — but has **no terminal `cancelled`/`void`** state, so "this PO should never have existed" has nowhere to go. |
| 4 | **Append-only facts** (never deleted) + **physical `*_archive` tables** | `equipment_values`, `equipment_events`, `downtimes`; `agg_equipment_values_1day_archive` (`edge-api/schema.sql:125`) | facts are insert-only time series (ADR-0036 Bronze); archive tables are a manual cold-storage move | Correct for facts. **Not** a deletion strategy for entities. |

**Grep-confirmed gap:** searching `edge-api/src`, `edge-api/schema.sql`, `packiot-stack-alpha/services`, and `edge-node-red/db` for `deleted_at`, `deleted_by`, `*_history`, `system_versioning`/`SYSTEM_TIME`, `valid_from`/`valid_to` returns **nothing**. There is no temporal column and no history table anywhere in the stack.

### 1.2 `active` is a visibility flag, not history

The whole problem in one line: **`active` captures neither *when*, nor *who*, nor *what-changed* — and it overwrites all prior state.** When a CS engineer soft-deletes an equipment, the row's `active` flips `true → false` in place. The `nm_equipment`, `ideal_speed`, `id_area`, `status_type` it had a moment ago are gone the instant they're next edited; the timestamp of the delete is not recorded; the actor is not recorded. A boolean answers exactly one question — *"is it visible right now?"* — and the review's finding is that we have been using that one-bit answer to stand in for *four* different needs: visibility, audit (who/when), reconstruction (what-was-it-then), and reactivation.

That is why, when someone asked *"can we see the history of this machine?"*, the schema answered with a flag. **A flag is not history.** The rest of this ADR is about giving each of those four needs the right tool.

---

## 2. The two live bugs + the reactivation trap

The pattern-soup isn't cosmetic — it produces incorrect production behaviour *today*.

### 2.1 LIVE BUG 1 — the read-plane leak (CQRS violation)

**Symptom:** a soft-deleted entity is invisible in the CS-Admin tool but **still visible in front4's analytics.** The two planes disagree about whether a thing exists.

**Root cause:** the visibility rule (`WHERE active`) is enforced on the **write** plane (edge-api DAOs) but **not** on the **read** plane (refdata-api). Nine refdata datasets read `equipments`/`sites`/`enterprises`/`users` and **none of them filter `active`**:

- `services/refdata-api/cmd/refdata-api/datasets.go:313` — `FROM equipments WHERE id_enterprise=$1 AND id_equipment=$2` (no `AND active`)
- `:585`, `:592` — the `active` token here is a **selected column** (`… logo_url, active, …` / `… internal_user, active`), i.e. the flag is *returned as data*, never used as a *filter* — the tell-tale of the leak
- `:644` — `FROM sites s WHERE s.id_enterprise=$1` (no `active`)
- `:696`, `:809`, `:824` — `FROM equipments …` counts/lists with no `active`
- grep confirms **zero** `WHERE … active` filters in the whole file.

**Why this is exactly the ADR-0038 CQRS violation:** 0038 principle #6 says reads must flow through **one** authority so tenant/visibility rules live in **one** auditable place. Here the rule was duplicated into the write DAOs and *forgotten* on the read side — the precise failure CQRS-with-a-single-read-authority exists to prevent. The fix is not "add `active` to nine more queries and hope the tenth is remembered"; it is to make the single read authority enforce it structurally (§5, Tier 0).

### 2.2 LIVE BUG 2 — the deleted machine that keeps computing

**Symptom:** you "delete" an equipment in CS-Admin and it **keeps ingesting SparkPlug samples and computing OEE.**

**Root cause:** `equipments.active` and `packml_register.active` are **two independent booleans with no coupling.** oeecloud routes incoming SparkPlug topics on `packml_register.active` (per the monorepo CLAUDE.md: *"CS Admin must set `active=true` for oeecloud to process a topic"*). Soft-deleting the *equipment* flips `equipments.active=false` but leaves the **routing row** `packml_register.active=true` — so the topic still resolves, the worker still writes `equipment_values`, and the rollup still produces OEE for a machine the admin tool swears is gone.

**The deeper defect:** there is **no single "delete this machine" operation that fences all of a machine's representations.** A machine exists as (at least) an `equipments` row *and* a `packml_register` routing row (and tomorrow: a history record, a dashboard tile, a targets row). "Delete" today touches one boolean and calls it done. The review's demand: **one delete contract, one transaction, all representations fenced together** (§5, Tier 0c).

### 2.3 The reactivation trap — plain uniques block re-registering a deleted key

Soft-delete keeps the row; the row keeps the unique key. So **re-creating a soft-deleted entity throws `23505 unique_violation`** on a plain unique constraint:

- `edge-api/schema.sql:5160` — `CREATE UNIQUE INDEX packml_topic_un ON packml_register (packml_topic)` — **no `WHERE active`**
- name-uniques on `products` (`:5199` `products_un (nm_product, id_enterprise)`), `clients` (`:5061` `clients_un (nm_client, id_enterprise)`), `user_roles` (`:5238` `user_roles_un (id_enterprise, nm_user_role)`) — likewise unconditional.

**Proof it already bites:** the staging seed *works around this exact wall* — `edge-node-red/db/26-incoplast-staging-fixtures.sql:121` re-registers topics with `INSERT … ON CONFLICT (packml_topic) DO UPDATE SET active = true`. That `ON CONFLICT DO UPDATE active=true` is *reactivation implemented by hand*, in a seed file, because the schema offers no first-class way to do it. **Reactivation is a real, recurring operation that the model does not support** — it's been smuggled in via upsert. Partial unique indexes (§5, Tier 0b) make reactivation legal *and* keep the constraint meaningful for live rows.

---

## 3. Principle: append-only for FACTS, SCD-versioned history for DIMENSIONS

This is the organizing idea; every decision below descends from it.

| | **Fact** (event) | **Dimension** (entity) |
|---|---|---|
| Examples | `equipment_values`, `equipment_events`, `downtimes`, `scanned_boxes` | `equipments`, `packml_register`, `sites`, `products`, `shifts`, `users` |
| Nature | An immutable record that *something happened at time T* | A described thing whose *description changes over time* |
| Correct lifecycle | **Append-only, never mutated** — ADR-0036 Bronze | **SCD-versioned** — keep every version with its validity interval |
| Wrong tool | (n/a — 0036 handles it) | **a boolean** — exactly what we did |
| Kimball name | fact table | slowly-changing dimension (SCD) |

**Why the conflation is the root cause:** when "can we keep the history?" is asked of a schema that only has facts-and-booleans, the boolean is the only lever within reach, so "history" gets answered with `active`. But a fact and a dimension want *opposite* things: a fact must **never change** (immutability); a dimension **must change, while remembering what it was** (versioning). A single boolean gives you neither — it mutates (so it's not immutable) *and* it forgets (so it's not versioned). It is the worst tool for a dimension precisely because a dimension is the one thing a boolean can't model.

Kimball's SCD taxonomy names our options exactly:
- **SCD Type 1** — overwrite in place, no history. **This is what `active` (and every `UPDATE equipments SET …`) does today.**
- **SCD Type 2** — add a new row per change with `valid_from`/`valid_to`; the current row has `valid_to = NULL`. **This is Tier 2 below** — the genealogy substrate.
- **SCD Type 3** — keep only "previous value" columns. Insufficient for genealogy (only one step of history).

Tier 1 (`deleted_at`/`deleted_by`) is the *audit* half — *when/who*; Tier 2 (SCD-2 history) is the *reconstruction* half — *what-was-it-then*. Both are needed; they're sequenced because Tier 1 is cheap and unblocks the leak-fix era, while Tier 2 lands *with* the Traceability pillar it exists to serve.

---

## 4. Options considered (per-need tradeoffs)

The review evaluated five candidate models against the four needs a deletion strategy must serve — **Visibility** (hide from reads), **Audit** (when/who), **Reconstruct** (what-was-it-then, for genealogy), **Reactivate** (bring a deleted key back cleanly).

| Option | Visibility | Audit (when/who) | Reconstruct (genealogy) | Reactivate | Cost | Verdict |
|---|---|---|---|---|---|---|
| **A. `active` boolean** (status quo, SCD-1) | ✅ (if filtered everywhere — bug 1 shows it isn't) | ❌ | ❌ | ❌ (23505 trap) | trivial | **Insufficient** — the thing we're replacing |
| **B. Hard `DELETE` + CASCADE** (`shifts` today) | ✅ (row gone) | ❌ | ❌ (worse — unrecoverable) | ✅ (key freed) | trivial | **Dangerous** — irreversible, no audit; only tolerable for genuinely disposable rows |
| **C. `deleted_at timestamptz` + `deleted_by`** (SCD-1 + audit) | ✅ (`WHERE deleted_at IS NULL`) | ✅ | ❌ (still overwrites descriptive columns) | ✅ (with partial unique `WHERE deleted_at IS NULL`) | low (columns + backfill) | **Tier 1** — the audit-complete soft-delete |
| **D. SCD-2 history tables** (`*_history`, `valid_from`/`valid_to`) | ✅ | ✅ | ✅ (full reconstruction) | ✅ | med–high (triggers/versioning + storage) | **Tier 2** — for genealogy-bearing dimensions, lands with P7 |
| **E. Postgres system-versioned tables** (temporal, e.g. `periods`/`pg_bitemporal` ext) | ✅ | ✅ | ✅ | ✅ | med (extension + ops learning) | **Tier 2 mechanism candidate** — evaluate vs trigger-written history |

**Reading the table:** no single option serves all four needs at a cost worth paying *now*. Visibility+audit is cheap (C); full reconstruction is expensive and only *some* dimensions need it (D/E). Hence a **tiered** decision rather than one big-bang model: buy the cheap, high-leverage capabilities immediately, and defer the expensive reconstruction capability to the pillar that actually consumes it.

---

## 5. Decision — a tiered strategy

Adopt a **three-tier entity-lifecycle strategy**, sequenced so each tier is independently valuable, reversible, and lands next to the work that needs it.

### Tier 0 — stop the bleeding (now; no data-model change beyond indexes)

Three moves, all shippable against the current `active` boolean, each closing a *live* defect:

**0a — Enforce `active` at the single read authority (fixes bug 1, honors ADR-0038 CQRS).**
Make refdata-api — the *one* read authority (0038 §5.6) — filter visibility structurally rather than per-query. Two equivalent mechanisms:
- **`v_active_*` views** (`v_active_equipments`, `v_active_sites`, …) defined as `SELECT * FROM equipments WHERE active`, and point the nine `datasets.go` queries (`:313,585,592,644,696,809,824`) at the views; **or**
- a shared query-builder predicate injected once (mirroring the tenant-`$1` injection already done in `auth_firebase.go`), so `active` is appended in one place, not nine.
*Recommendation:* views — they make the rule declarative and auditable, and a future analytics consumer that legitimately wants *deleted* rows can opt out by reading the base table explicitly. Either way the invariant becomes: **visibility is decided once, at the read authority, not smeared across callers.**

**0b — Convert exposed uniques to partial unique indexes (fixes the reactivation trap, §2.3).**
Replace the unconditional uniques with `WHERE active` partial indexes:
```sql
-- sketch — DESIGN ONLY, sized/verified on staging first
DROP INDEX packml_topic_un;
CREATE UNIQUE INDEX packml_topic_un_active ON packml_register (packml_topic) WHERE active;   -- schema.sql:5160
-- same shape for products.nm_product, clients.nm_client, user_roles.nm_user_role
```
Effect: a **soft-deleted** key no longer blocks re-registering the same topic/name, so reactivation and re-create both stop throwing `23505` — and the `ON CONFLICT DO UPDATE active=true` hack in `26-incoplast-staging-fixtures.sql:121` becomes unnecessary rather than load-bearing. (When Tier 1 lands, the predicate migrates `WHERE deleted_at IS NULL`.)

**0c — Define ONE delete contract (fixes bug 2).**
A single edge-api operation — *delete-equipment* — that **fences every representation of a machine in one transaction**:
```
BEGIN;
  UPDATE equipments        SET active=false WHERE id_equipment=$1 AND id_enterprise=$2;
  UPDATE packml_register   SET active=false WHERE id_equipment=$1 AND id_enterprise=$2;  -- ← the currently-missing fence
  -- (future representations register here: targets rows, dashboard bindings, history close-out)
COMMIT;
```
The contract is the important artifact, not the SQL: **"deleted" must mean fenced across all representations, atomically, so a deleted machine cannot keep computing.** `packml_register` is the specific row bug 2 leaves live; the contract generalizes so the next representation added to a machine is fenced by construction. This is the CS-Admin-facing counterpart to the write-side tenant fence in ADR-0033/0034.

### Tier 1 — audit-complete soft-delete: `active` → `deleted_at` + `deleted_by`

Migrate the SCD-1 boolean to a **temporal + actor** pair, aligning with the temporal-columns direction and recording the two things `active` throws away:

- add `deleted_at timestamptz NULL` and `deleted_by <user-ref> NULL` to the soft-delete dimensions;
- **keep a back-compat `active`** as a generated column / view: `active := (deleted_at IS NULL)` — so existing consumers (and the Tier-0b partial indexes, re-predicated to `WHERE deleted_at IS NULL`) keep working through the transition;
- `deleted_at IS NULL` becomes the canonical "live" predicate everywhere.

**Do this *before* more deletions accrue — and accept the backfill is lossy.** Existing `active=false` rows can be backfilled to a sentinel `deleted_at` (e.g. the migration timestamp) with `deleted_by=NULL`, but **the true when/who is unrecoverable — it was never recorded.** That irreversibility is the *argument for urgency*: every day on the boolean is another delete whose audit trail is lost forever. Tier 1 stops the bleeding of *audit* history the way Tier 0a stops the bleeding of *visibility*.

### Tier 2 — SCD-2 history tables for genealogy-bearing dimensions

For the dimensions whose *past configuration* must be reconstructable, add **Type-2 history**: `*_history` tables (or Postgres system-versioning) carrying `valid_from`/`valid_to`, one row per version, current row `valid_to = NULL`, written by trigger or by the temporal extension.

**Scope — only the genealogy-bearing dimensions:**

| Dimension | Why it needs SCD-2 |
|---|---|
| `equipments` | reconstruct the `ideal_speed` / `id_area` / `nm_equipment` a lot ran *under* — the core genealogy join |
| `packml_register` | reconstruct topic→equipment routing *as it was* when a sample landed |
| `production_orders` | the as-run PO configuration (product, target) at execution time |
| `shifts` | which shift definition was in force for a given historical window (today `shifts` is *hard-deleted* — the worst case: no recovery at all) |

**Why a boolean (or even Tier 1) cannot do this:** genealogy asks *"which lot ran on which machine **as-configured-then**?"* — i.e. the `ideal_speed`/`area`/`name` **at the time the fact occurred**, not now. `active`/`deleted_at` only ever hold the *current* descriptive columns; the moment a machine's `ideal_speed` is edited, yesterday's value is gone and yesterday's OEE can no longer be explained. Only a versioned dimension — a row per (entity, validity-interval) — lets a fact at time T join the dimension version valid at T. **This is the literal substrate of ADR-0038's Traceability/Genealogy pillar (P7, MISSING).**

**Sequencing:** Tier 2 **lands with the Traceability pillar (0038 Phase B3), not before.** It is the highest-cost tier (versioning machinery + years of dimension history storage) and its *only* consumer is genealogy, which doesn't exist yet. Building it early is storage and complexity with no reader. Tier 0 and Tier 1, by contrast, have live consumers *today* (the two bugs, the audit gap) and ship now.

### Entities that stay as they are

- **`production_orders` keeps its status enum** — a PO is a lifecycle object, not a soft-deletable dimension; forcing an `active` boolean onto it would be the same conflation in reverse. The one gap: **add an explicit terminal `cancelled`/`void` status** so "this PO should never have existed / was created in error" has a first-class state instead of being hard-deleted or hidden. (Tier 2 history still applies to POs for the *as-run* record.)
- **`devices` can keep the bare boolean** — a device is not genealogy-bearing and not on the read-plane leak surface; the cost of temporal columns isn't justified. (It still benefits from Tier 0b if it ever gets an exposed unique.)
- **Facts (`equipment_values`/`equipment_events`/`downtimes`) stay append-only** — ADR-0036 owns their lifecycle; this ADR does not touch them. The `agg_*_archive` tables remain a cold-storage mechanism, not a deletion model.

---

## 6. Migration sketch

Sequenced; each row independently valuable and reversible. **This ADR ships none of it as code.** Staging-first; prod steps gated per the standing prod-apply gate (prod DB is SELECT-only for us).

| Phase | Step | Risk | Reversible? |
|---|---|---|---|
| **T0-a** | refdata `v_active_*` views (or shared predicate); repoint the 9 `datasets.go` queries. Closes bug 1. | Low | Yes (repoint back to base tables) |
| **T0-b** | Convert `packml_topic`, `products.nm_product`, `clients.nm_client`, `user_roles.nm_user_role` uniques → partial `… WHERE active`. Closes the 23505 trap. | Low–Med | Yes (recreate unconditional index — requires no dup live keys) |
| **T0-c** | edge-api single *delete-equipment* transaction fencing `equipments` + `packml_register`. Closes bug 2. | Med | Yes (additive usecase) |
| **T1** | Add `deleted_at`/`deleted_by`; generated `active := deleted_at IS NULL`; backfill existing `active=false` (lossy — no true when/who); migrate partial-index predicate to `WHERE deleted_at IS NULL`. | Med | Yes (keep `active` through transition) |
| **T2** | SCD-2 `*_history` (trigger-written or system-versioning) for `equipments`, `packml_register`, `production_orders`, `shifts`. **Lands with 0038 Phase-B3 Traceability.** | Med–High | Yes (history is additive; base tables unchanged) |
| **PO** | Add `cancelled`/`void` to the `production_orders` status enum + guard transitions. | Low | Yes |
| **P** | Promote each phase staging→prod under its own gate. | — | Per-phase |

**Sequencing rule:** Tier 0 first (it fixes live bugs at near-zero model cost). Tier 1 *before more deletions accrue* (audit loss is irreversible and grows daily). Tier 2 *with* the Traceability pillar (no earlier — no reader before then). The two live bugs (0a, 0c) and the trap (0b) are the only *urgent* items; everything else is scheduled, not rushed.

---

## 7. Consequences

**Positive:**
- **Two live production bugs closed** at Tier 0 — the read-plane leak (bug 1) and the deleted-machine-keeps-computing (bug 2) — plus the reactivation trap.
- **One delete contract** — "deleted" finally means the same thing across all of a machine's representations, atomically; no more per-boolean whack-a-mole.
- **CQRS honored** — visibility becomes a single-authority rule (0038 #6), not a duplicated-and-forgotten predicate.
- **Audit trail** (Tier 1) — every future delete records *when* and *who*.
- **Genealogy substrate** (Tier 2) — the Traceability pillar (0038 P7) gets the versioned dimensions it structurally requires; yesterday's OEE stays explainable after a machine is reconfigured.
- **Facts and dimensions stop being conflated** — 0036 owns fact immutability, 0039 owns dimension versioning; each need gets its right tool.

**Negative / risks:**
- **Lossy Tier-1 backfill.** Existing `active=false` rows can never recover their true delete timestamp/actor. *Mitigation:* do Tier 1 sooner rather than later; sentinel-backfill honestly (`deleted_by=NULL`) rather than fabricating an actor.
- **Partial-index conversion (0b) fails if duplicate live keys already exist.** Converting to `WHERE active` requires that no two *active* rows share the key today. *Mitigation:* pre-flight a duplicate-detection query on staging before the DDL; the `ON CONFLICT active=true` seed hack means at least one path has been keeping keys unique already.
- **SCD-2 storage + write cost.** Trigger-written history doubles dimension write volume and retains years of versions. *Mitigation:* Tier 2 is scoped to only the four genealogy-bearing dimensions and deferred to when a reader exists; the staging DB is already memory-constrained, so size Tier-2 retention against real capacity.
- **`shifts` hard-delete is a latent data-loss bug until Tier 2.** Every `DELETE FROM shifts` (`shifts-dao.ts:80`) is currently unrecoverable and cascades to `shift_hours`. *Mitigation:* Tier 1 should extend to `shifts` (give it a `deleted_at` and stop the hard delete) even though the review's Tier 0 list doesn't strictly require it — it's the single most destructive pattern in the map (#2 in §1.1).

---

## 8. Alternatives considered

- **Keep the `active` boolean everywhere, just add the filter to the nine refdata queries.** Rejected — it fixes bug 1's *symptom* while leaving the CQRS violation (the rule still lives in N places, forgotten on the tenth) and does nothing for audit, genealogy, or reactivation. Tier 0a fixes it *structurally* at the single authority.
- **Hard-DELETE everything (extend the `shifts` pattern).** Rejected — irreversible, zero audit, destroys genealogy; the opposite of what a traceability-bearing MES needs (0038 P7). Hard delete is only tolerable for genuinely disposable rows.
- **One big-bang jump straight to SCD-2 everywhere.** Rejected — highest-cost tier for dimensions that have no genealogy reader yet, on a memory-constrained staging DB; front-loads storage and complexity for capability nobody consumes until Phase-B3. The tiering buys the cheap live-bug fixes now and defers the expensive reconstruction to its consumer.
- **Postgres system-versioned tables (temporal extension) as the Tier-1 mechanism.** Deferred to Tier 2, not adopted for Tier 1 — `deleted_at`/`deleted_by` is a smaller, well-understood step that unblocks audit immediately without an extension dependency; system-versioning is a *Tier-2 mechanism candidate* (§4 option E) to evaluate against trigger-written `*_history` when genealogy lands.
- **Force `production_orders` onto an `active` boolean for uniformity.** Rejected — a PO is a lifecycle object, not a soft-deletable dimension; the fix is an explicit `cancelled`/`void` terminal state, not the same conflation in reverse.

---

## 9. Cross-references

| ADR | Relationship |
|---|---|
| [0036](0036-data-architecture-medallion.md) | **Complement.** 0036 = fact lifecycle (Bronze append-only immutability); 0039 = dimension lifecycle (SCD-versioned history). Together they end the fact/dimension conflation that is this ADR's root cause. |
| [0038](0038-north-star-factory-platform.md) | **Governed by.** Tier 0a fixes a direct violation of 0038 principle #6 (CQRS / single read authority); Tier 2 is the substrate for 0038 pillar P7 (Traceability/Genealogy, MISSING) and lands with its Phase-B3. |
| [0033](0033-unified-firebase-jwt-auth.md) / [0034](0034-adopt-cognito-amplify-auth.md) | The write-side tenant fence is the security counterpart to Tier 0c's *delete* fence — both make edge-api enforce an invariant in one atomic authority rather than trusting callers. |
| [0027](0027-refdata-api-surface-1-read-contract.md) | Tier 0a changes *what rows* the refdata read contract returns (active-only via `v_active_*`), without changing the contract's shape. |
| [0037](0037-oee-correctness-remediation.md) | Same disease, different organ: 0037 = metrics correct *by invariant not by parity*; 0039 = entities correct *by lifecycle not by boolean*. Bug 2 (deleted machine still computes OEE) sits on the seam between them. |

**The theme, stated once:** a boolean was asked to be four things — a visibility flag, an audit log, a time machine, and a reactivation switch. It is only good at the first. This ADR gives the other three their proper tools, in the order the platform actually needs them.
