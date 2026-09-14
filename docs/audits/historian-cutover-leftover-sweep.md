# Historian cutover-leftover sweep — staging

**Date:** 2026-09-14. **Scope:** the historian (cold-history) plane on **staging** only —
the `hist-gateway` pg_duckdb container (`i-06c9547a2c7091ab7`), its FDW-backed app DB
`packiot_analytics` (`10.10.10.89`), and the S3 cold store
`packiot-staging-historian-639178078294`. **Legacy `packiot`/packiot40 was NOT touched.**

**Trigger:** report that "there are still cutover tables" left over from the historian
remap (#167) + clean-schema cutover (#214/#227). **Every claim below is backed by a live
query / S3 listing / view definition — nothing is asserted from memory.**

## TL;DR

**There are NO leftover/droppable cutover tables.** The historian gateway is already
clean. The two objects whose names contain `cutover` — `hist_cutover` and
`ev_events_cutover` — are **load-bearing union-boundary tables**, proven consumed by the
`ev_all` / `ev_all_events` views that read-api and Superset serve. Dropping either (or any
row) would break hot/cold disjointness and **double-count** served production numbers. The
transitional objects a prior audit flagged (`ev_between()`, `refresh_hist_cutover()`, the
`hist_production_orders*` PO-archives) were **already removed** in earlier necessity
passes and are confirmed absent. The genuine open items are the **R1** (EV cold cross-tenant
holdout parity) and **R3** (cutover-refresh ownership) hardening items from
`docs/plans/historian-gateway-schema-sweep.md`; R3 is fixed in this PR, R1 is documented as
gated (no safe unilateral fix).

## 1. Full historian schema map (live, 2026-09-14)

### Gateway Postgres (`hist-gateway`, db `postgres`) — 8 relations, ALL canonical

| Schema | Object | Kind | Purpose | Consumer |
|---|---|---|---|---|
| `live` | `equipment_values` | foreign table | HOT side of `ev_all`; pinned 8-col FDW → `packiot_analytics.silver.equipment_values` | via `ev_all` |
| `live` | `equipment_events` | foreign table | HOT side of `ev_all_events`; IMPORT → `silver.equipment_events` | via `ev_all_events` |
| `public` | `hist` | view | COLD EV: `read_parquet('…/equipment_values/*/*/*/*-legacy.parquet')` | via `ev_all` |
| `public` | `hist_ee` | view | COLD EE: `read_parquet('…/equipment_events/*/*/*/*-legacy.parquet')` | via `ev_all_events` |
| `public` | `hist_cutover` | **table (25 rows)** | EV disjointness boundary `cutover_ts=max(cold ts)` per enterprise | **`ev_all` (LEFT JOIN)** |
| `public` | `ev_events_cutover` | **table (4 rows)** | EE disjointness boundary `cutover_ts=min(hot ts)` per enterprise | **`ev_all_events` (LEFT JOIN)** |
| `public` | `ev_all` | view | HOT(ts>cutover) ∪ COLD(all `hist`), legacy-priority | **read-api** `/v1/historian` production-series, **Superset** `ev_all` virtual dataset |
| `public` | `ev_all_events` | view | HOT(all live) ∪ COLD(`hist_ee` ts<cutover), hot-anchored | **read-api** `/v1/historian` EE downtimes (#227 §8-EE) |

Functions: only pg_duckdb extension aggregates (`histogram`, …). **No app functions** —
`ev_between()` and the broken `refresh_hist_cutover()` are absent (dropped t269 / 09-08).
Only one gateway DB exists (`\l` = postgres/template0/template1). Everything is
COMMENT-documented in `services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh`
and mirrored in `db/migrations/t-histdb-object-docs/01-comments.sql`.

### S3 cold store layout

| Prefix | Contents |
|---|---|
| `equipment_values/enterprise=<id>/year=/month=/*-legacy.parquet` | one-shot deep-remap backfill (globbed by `hist`), **frozen — all files dated 2026-09-04** |
| `equipment_values/…/data-YYYY-MM-DD.parquet` | daily append (ents 3,5) — **Athena/Glue only, NOT globbed by `hist`** |
| `equipment_events/enterprise=<id>/…/*-legacy.parquet` | promoted EE (F3 id-space) — only `enterprise=3` |
| `equipment_events_legacy_unpromoted/enterprise=<id>/` | EE holdout — un-promoted legacy ids `{1,2,6,10,13,30,31,33,36,37,99,100,101,102,112,113,116,117,118}` quarantined by path |
| `_watermark/`, `athena-results/` | append last-run markers / Athena spill |

### App DB `packiot_analytics`

No historian scratch. `hist_production_orders` / `hist_production_orders_runtime`
(PO-archives flagged in the redesign plan) are **already dropped** (0 rows in `pg_class`).
Name-pattern sweep (`cutover|remap|_old|_bak|_tmp|_stage|_v2|hist|mirror|migrat|_shadow…`)
returns only unrelated live objects (`ops.mirror_replay_*`, `silver.equipment_events_cpac_shadow`,
`knex_migrations`, TimescaleDB internals).

## 2. Proof the cutover tables are load-bearing (NOT leftovers)

`ev_all` (from `pg_get_viewdef`):
```sql
FROM live.equipment_values lv
LEFT JOIN hist_cutover c ON c.id_enterprise = lv.id_enterprise
WHERE c.cutover_ts IS NULL OR lv.ts_value > c.cutover_ts   -- HOT filtered by hist_cutover
UNION ALL SELECT … FROM hist h;                            -- COLD (all legacy parquet)
```
`ev_all_events`:
```sql
FROM live.equipment_events lv                              -- HOT (all)
UNION ALL SELECT … FROM hist_ee h
LEFT JOIN ev_events_cutover c ON c.id_enterprise = h.id_enterprise
WHERE c.cutover_ts IS NULL OR h.ts_event < c.cutover_ts;   -- COLD filtered by ev_events_cutover
```
Drop `hist_cutover` (or a row) ⇒ its hot rows lose the `ts>cutover` fence ⇒ hot ∪ cold
double-counts the archived window. Same for `ev_events_cutover` on the cold EE side. These
tables are the disjointness mechanism, not remap scratch.

### Double-count invariant — hardproof (currently HEALTHY)
- EV enterprises with a `*-legacy.parquet` in S3 (globbed by `hist`):
  `{0,2,3,4,6,10,13,30,31,35,36,37,38,99,100,101,102,111,112,113,116,117,118,10016,1000000}` = **25**.
- `hist_cutover` rows: **exactly those 25**. → every cold enterprise has a boundary row →
  **no missing row → no double-count**. (`scripts/historian-cutover-coverage-check.sh` is the
  CI/boot detector for this.)
- EV `data-*.parquet` daily appends (ents 3,5) are **not** globbed by `hist` (glob is
  `*-legacy.parquet`), so daily appends cannot double-count — they feed Athena/Glue only.
- EE: only `enterprise=3` is promoted under `equipment_events/`; the rest are held out under
  `equipment_events_legacy_unpromoted/` (path-excluded from `hist_ee`). Holdout works.

## 3. R1 — EV cold has no unpromoted-holdout (cross-tenant leak, latent) — GATED

`hist_ee` gets tenant isolation for free: un-promoted legacy EE lives under a **separate
prefix** (`equipment_events_legacy_unpromoted/`) that the glob never matches. **EV has no
equivalent** — `hist` globs `equipment_values/*/*/*/*-legacy.parquet` **unconditionally**,
serving legacy-passthrough ids (`0, 2, 10016, 1000000`, plus old-`cutover_ts` `35–38,100–117`)
alongside genuinely F3-remapped ids (e.g. `3`). The tenant fence is a caller-supplied
`id_enterprise = <literal>` (read-api server-derived; Superset RLS), so:

- **Today: benign.** Live F3 tenants are `{3,5,2000003}`; none collides with a legacy-only
  cold id, and enterprise=3 is genuinely remapped.
- **The trap:** assign a future F3 tenant a low id that equals a legacy-only cold partition
  (e.g. `2`) and `ev_all` serves **another company's legacy data** as theirs. No RLS
  co-enforcer catches it.

**Why not fixed here:** the safe fixes both need the **F3-promotion registry** (which of the
25 EV cold ids are genuine F3 tenants vs legacy-passthrough) — data this audit cannot derive
with certainty. Options (both reversible, gated on that registry):
- **R1(a)** quarantine un-promoted EV partitions under `equipment_values_legacy_unpromoted/`
  (EE parity) — requires a partition re-unload.
- **R1(b)** add a `hist_promoted_enterprise(id_enterprise)` allow-list table and join it in
  `hist` — additive, no data movement.

**Hard rule until fixed (enforceable by inspection):** never assign a new F3 tenant an
`id_enterprise` that appears in `hist_cutover` but is not a verified F3-remapped tenant. The
legacy-passthrough ids are `{0, 2, 10016, 1000000}` (and the 2024-`cutover_ts` cohort).

## 4. R3 — cutover-refresh ownership — FIXED (EE) + status (EV)

**Finding:** `hist_cutover.refreshed_at` was uniformly `2026-09-04`. This is **not** an
active corruption: the globbed cold set (`*-legacy.parquet`) has not changed since the
one-shot backfill (coverage 25=25, §2), and the daily append path writes non-globbed
`data-*.parquet`. The stale timestamp is a **process** gap — the boundary is refreshed only
by a hoped-for manual step, not by the writer that extends the cold store.

**Fix (this PR):** `scripts/historian-events-reunload.sh` (the only tracked writer that
emits new `*-legacy.parquet`, i.e. EE tenant promotion) now **owns** its boundary refresh —
after writing partitions it runs `refresh-ee-cutover.sql` on the gateway and **fails (exit 1)
if it can't**, so a promotion can never silently leave a stale/absent `ev_events_cutover`
row (which would double-count the EE overlap). The refresh reads only the hot FDW (a cheap
PG aggregate), so it is safe to run every time.

**Hardproof:** ran `refresh-ee-cutover.sql` live on the gateway — completed clean;
`refreshed_at` advanced to 2026-09-14; all four `cutover_ts` values **unchanged**
(`3→2026-05-28, 4→2026-07-22, 5→2026-08-31, 2000003→2026-06-29`), i.e. the boundary was
already correct → **zero consumer impact**.

**EV status:** the EV refresh (`refresh-hist-cutover.sql`) *must* stay a top-level statement
(pg_duckdb cannot scan `hist` inside a function) and is a minutes-long full scan of the 336M-row
CPACK partition, so it is **not** wired into the (frequent, cheap) daily append — correctly,
since daily appends don't touch the globbed set. It only needs to run after an EV *legacy*
re-backfill; there is no tracked EV legacy re-backfill script (the backfill was one-shot).
The coverage-check script remains the CI/boot detector.

## 5. What was dropped

**Nothing.** No droppable leftover exists — the gateway is already at its minimal canonical
surface, both cutover tables are load-bearing, and the previously-flagged transitional
objects were removed in earlier passes. This audit's deliverable is the proof of that plus
the R3 fix and the R1 gating record.

## 6. What remains (gated / documented)

| Item | Status |
|---|---|
| R1 — EV unpromoted-holdout / allow-list | Gated on the F3-promotion registry; hard rule recorded (§3). |
| R3 — EV legacy re-backfill refresh ownership | No tracked writer exists; coverage-check is the detector. Wire the refresh in if an EV re-backfill script is ever added. |
| R2/R4–R10 | See `docs/plans/historian-gateway-schema-sweep.md` (provenance doc, staleness monitor, prune COMMENT, EE reconciliation) — all LOW/MED, unchanged. |
