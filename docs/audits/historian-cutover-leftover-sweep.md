# Historian staging cutover — closed out (allow-list + leak closure)

**Date:** 2026-09-14. **Scope:** the historian (cold-history) plane on **staging** only —
the `hist-gateway` pg_duckdb container (`i-06c9547a2c7091ab7`), its FDW app DB
`packiot_analytics` (`10.10.10.89`), and the S3 cold store
`packiot-staging-historian-639178078294`. **Legacy `packiot`/packiot40 was NOT touched.**

This supersedes the first-pass sweep (which concluded "nothing droppable, R1 gated"). That
pass was correct that no gateway *object* is dead, but it deferred the real defect. This
pass **finishes the cutover**: derives the promotion set from live, closes the cross-tenant
leak with an enforced allow-list, resolves the EE holdout, and keeps the raw-legacy
reference archive queryable-but-isolated. Every number below is hardproofed live.

## TL;DR

The staging historian gateway served the **cold** side of `ev_all`/`ev_all_events` with **no
tenant gate** — the S3 archive is keyed by RAW-LEGACY enterprise ids that collide numerically
with F3 tenant ids. HARDPROOF of the leak: `ev_all WHERE id_enterprise=6` for 2024-01
returned **16,731,194** rows of a *different* company's legacy production (F3 id 6 =
MONTEBELLO, a draft tenant with **zero** equipment). Fixed with an explicit **allow-list**
(`hist_promoted_enterprise`) that `ev_all`/`ev_all_events` INNER JOIN on the cold side.
Post-fix that same probe returns **0**; CPACK (the one genuinely-remapped tenant) is
unchanged. The raw-legacy archive stays fully queryable for reference via `hist`/`hist_ee`
(not tenant-facing). The EE `_unpromoted` path-exclusion hack is retired — isolation is now
100% the allow-list.

## 1. The promotion allow-list — DERIVED from live

Source of truth = `core.enterprises` (9 tenants) + `core.client_descriptors` +
`core.equipments`. **Ownership test:** a cold partition `enterprise=<id>` is genuinely owned
by the F3 tenant of that id **iff** its cold `DISTINCT id_equipment ⊆ core.equipments(id)`
**and** `core.equipments(id)` is non-empty (a real remap, not a raw-legacy id-collision).

| id | tenant (core) | active | cold EV equip | core.equipments(id) | verdict |
|----|---------------|--------|---------------|---------------------|---------|
| 3 | CPACK-Staging | t | {47..108} (62) | {47..108} (62) | **EV+EE promoted** (legacy 1→3) |
| 4 | Incoplast-Staging | t | {990015..990018} (4) | {990015..990018} (4) | **EV promoted** (legacy 33→4); EE not (see §3) |
| 2 | Simulator Corp | f | {160..184} (14) | {3,4,5} | reject — ⊄ (raw legacy) |
| 6 | (MONTEBELLO draft) | — | {134..852} (327) | ∅ | reject — no equipment (raw legacy) |
| 13 | (NEOPAC draft) | — | {0..865} (118) | ∅ | reject — no equipment (raw legacy) |
| 1000000 | PACKIOT-ADMIN | t | {111..113} (3) | ∅ | reject — no equipment (raw legacy) |
| 0,10,30,31,35–38,99–118,10016 | not in core.enterprises | — | (various) | n/a | reject — not F3 tenants |

The other core tenants (5 Bispharma, 119 Bisnago, 120, 2000003 SANDBOX) have **no
`*-legacy` EV cold at all** (5 has only Athena daily appends; the rest are absent from the
archive), so nothing to promote.

**Result — `hist_promoted_enterprise` (the gate):**
```
 id_enterprise | ev_promoted | ee_promoted | provenance
       3        |     t       |     t       | f3_remapped   (CPACK)
       4        |     t       |     f       | f3_remapped   (Incoplast; EE unmapped)
```

## 2. R1 — cross-tenant leak CLOSED (enforced, hardproofed)

`ev_all` / `ev_all_events` now `INNER JOIN hist_promoted_enterprise` on the cold side, so a
non-promoted id (a raw-legacy partition, or a future F3 tenant handed a colliding low id)
gets **zero** cold rows. `hist_cutover` / `ev_events_cutover` were pruned to the promoted set
(a boundary row for a non-served enterprise would wrongly clip its HOT history).

**Hardproof (same window before/after):**

| probe | before | after |
|---|---:|---:|
| `ev_all` id_enterprise=6, 2024-01 (LEAK) | 16,731,194 | **0** |
| `ev_all` id_enterprise=13, 2024-01 (LEAK) | 412,533 | **0** |
| `ev_all` id_enterprise=3, 2024-01 (KEEP=CPACK) | 6,297,560 | **6,297,560** |
| `ev_all_events` id_enterprise=6 / 33 (LEAK) | >0 | **0** / **0** |
| `hist` id_enterprise=6 (reference still queryable) | 16,731,194 | **16,731,194** |

**No double-count regression** — EE ent3 union decomposes exactly: `union 338,628 == hot_kept
284,669 + cold_kept 53,959` (cold_kept identical to the init-header's documented 53,959; the
delta vs the old 316,688 total is 6 days of hot growth, not my change). **Consumers green:**
read-api `histProductionSeriesSQL` returns ent3 (promoted, hot+cold) and ent5 (onboarded,
hot-only — correctly no legacy cold) without error; view shapes are unchanged so Superset
`ev_all` and read-api `/v1/historian` are unaffected.

## 3. EE holdout — RESOLVED (no breadcrumb exclusions)

`hist_ee` now globs the **full** EE archive (both `equipment_events/` and the former
`equipment_events_legacy_unpromoted/` prefix, via a `read_parquet(ARRAY[...])` list). The
prefix is retired as a security boundary — isolation is the allow-list. Promotion status of
every legitimately-onboarded tenant:

| tenant | cold EE? | action |
|---|---|---|
| 3 CPACK | yes (enterprise=3, equip {47..108} == core) | **promoted** |
| 4 Incoplast | yes, but at **legacy-33** with **legacy** equipment (8 ids, not the F3 {990015..990018}); the legacy→F3 equipment map is not in tracked code and is **not derivable** from live (8≠4, a merge/drop) | **NOT promoted** — kept as `hist_ee` reference; promoting would attach downtimes to non-existent equipment. This is the one genuine limitation (see §5). |
| 5 Bispharma, 119 Bisnago, 120, 2000003 SANDBOX | **none** — the EE holdout's global equipment range is {1..10021}, **zero** F3-range ids (990xxx/2000xxx/41xxx), so none of these tenants' equipment appears in any cold EE partition | **proven no cold EE** to promote |

## 4. Reconciliation with the #169–175 "keep raw-legacy as reference" decision

The 24 raw-legacy EV partitions + 19 EE partitions are **kept on disk and fully queryable**
via `hist` / `hist_ee` (the reference surfaces, e.g. through the CloudBeaver `histro`
connection). They are **not** destroyed. The leak is closed not by deleting them but by
gating the **tenant-facing** unions (`ev_all`/`ev_all_events`, the only surfaces read-api and
Superset touch) with the allow-list. So legacy reference stays queryable *and* no F3 tenant
can reach another company's data through its own id. The allow-list also doubles as the
**id-reservation registry**: onboarding must never assign a new F3 tenant an id already
serving cold, and a colliding assignment is now inert (0 cold rows) rather than a leak.

## 5. The one genuine fork (needs a human call)

**The raw-legacy reference archive is a legacy tie.** Several partitions are **still being
appended by the live legacy `packiot40`** (EV/EE `max(ts)` = 2026-09-04), and the ids are
opaque (no F3 mapping doc; e.g. "legacy enterprise 6" ≠ any current tenant). On "the one and
only stack, no legacy ties" this is the tension the #169–175 decision left open.

- **Default (implemented):** keep it as frozen, isolated, queryable reference. Zero leak,
  nothing destroyed, Incoplast EE recoverable later if the equipment map surfaces.
- **Recommendation:** retire the raw-legacy reference archive (EV `enterprise∉{3,4}` +
  the entire EE holdout) at the **#225 legacy-packiot40 decommission**, when the legacy
  source stops appending and the "reference" loses its live counterpart. Until then, keep.
  For **Incoplast EE** specifically: leave as `hist_ee` reference; only promote if/when the
  legacy-33→F3-4 equipment map is provided (do not guess an 8→4 mapping).

## 6. What changed (all reversible, codified)

- `db/migrations/t271-historian-promoted-allowlist/{01-up.sql,rollback.sql}` — the allow-list
  + view gating + cutover pruning, and a full rollback.
- `services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh` — born with
  the allow-list; `ev_all`/`ev_all_events` gated; `hist_ee` full-archive glob; cutover seeds
  join the allow-list.
- `services/historian-gateway/refresh-{hist,ee}-cutover.sql` — join the allow-list + prune.
- `scripts/historian-events-reunload.sh` — EE promotion now flips `ee_promoted` **and**
  refreshes the boundary (fails on error).
- `scripts/historian-cutover-coverage-check.sh` — asserts `hist_cutover` set == the
  `ev_promoted` allow-list (both directions), replacing the obsolete S3-archive comparison.

**End state:** the staging historian is fully cut over — cold is served only for
verified-owned tenants (CPACK EV+EE, Incoplast EV), the cross-tenant leak is closed and
hardproofed to 0, the EE path-exclusion hack is gone, and the raw-legacy archive remains
queryable-but-isolated pending the §5 fork.
