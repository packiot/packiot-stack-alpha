# Historian derived-history backfill to 2021 (POs + OEE-shift grain)

**Status:** DONE (both items executed on staging 2026-09-23) · **Date:** 2026-09-23 · Scope: CPACK (ent3, legacy ent1)

Driven by: "analytics is 3-month by design; the historian is the everything store —
backfill POs/runtimes/downtimes to 2021." Validated the historian's real
architecture first (below), which redirects the work from a DB backfill to a
historian-archival workstream.

## Validated state (what the historian actually holds)

`packiot_historian` (on the `hist-gateway` container) is a **pg_duckdb query gateway
over S3 Parquet + FDW to the hot analytics** — a raw-history server, NOT a PO store.

| Relation | Cold archive (S3 Parquet) | Producer | Extent |
|---|---|---|---|
| `equipment_values` (raw) | `equipment_values/enterprise=/year=/month=/*-legacy.parquet` | `scripts/historian-legacy-copy.sh` (legacy→F3 remap via packml_register) | **2021 → today ✓ COMPLETE** |
| `equipment_events` (raw downtime events) | `equipment_events/…/*-legacy.parquet` | `historian-events-backfill.sh` + `-reunload.sh` (re-key to F3) | 2021 → today ✓ (downtimes ARE the EE archive) |
| `equipment_oee_shift` (OEE grain) | `equipment_oee_shift/enterprise=3/year=2026/` | **NONE — no gateway producer; written ad-hoc** | **2026 ONLY — the gap** |
| `production_orders` / runtime | — | **NONE — no archive** | **absent — the gap** |

So: **raw is already complete to 2021** (the user was right). The gaps are the
**derived** layer — `equipment_oee_shift` (2026 only) and `production_orders` (absent).
Analytics stays 3-month (by design; do NOT backfill 5y there). Legacy `packiot40`
holds computed POs+OEE to 2021-12-23 (20,480 POs).

## Why this is a workstream, not a `psql` backfill

The write-side is codified bash + Terraform + gateway glue with load-bearing
invariants (README + `10-historian-gateway.sh`):
- **Double-count fence:** every backfill that extends a cold store MUST be followed by
  the per-enterprise `*_union_boundary` cutover refresh, or the archived window is
  served by BOTH hot and cold. Refresh SQL must be **top-level** (pg_duckdb can't scan
  parquet inside a PL/pgSQL function — a broken wrapper was found live + dropped).
- **Promote allow-list:** cold side is INNER-JOINed to `promoted_enterprise`; a new
  relation needs its own `<t>_promoted` gate + seed.
- **RLS = caller literal** (no GUC on the gateway).

## Work items

### A. `equipment_oee_shift` 2021–2025 (recompute-from-raw)
Hard dependency: the shift-OEE rollup runs in the **analytics DB** (stream-engine
`internal/rollup/*` + `edge-node-red/db/14-oee-uns-compute.sql`), not in DuckDB — so
the grain can't be computed from cold parquet directly. Path:
1. **Recompute `gold.equipment_oee_shift` for 2021-01…2025-12 (ent3) in analytics.**
   BLOCKER: that window's raw lives only in the cold S3 archive, not analytics silver
   (3-mo). Needs a decision: (i) stage the cold raw back into analytics silver for the
   window and run the rollup, or (ii) port the shift-rollup math to DuckDB over cold
   parquet. (i) is safer/authentic; (ii) is a large reimplementation.
2. New archiver `scripts/historian-oee-shift-backfill.sh` (clone
   `historian-events-backfill.sh`): `SELECT … FROM gold.equipment_oee_shift WHERE
   id_equipment ∈ equipments(3) AND ts_value ∈ [month)` → `COPY TO
   s3://…/equipment_oee_shift/enterprise=3/year=/month=/data-Y-MM-legacy.parquet`
   (ZSTD). Note: grain has no `id_enterprise` col — scope via equipments join, stamp
   partition cols. 
3. Glue table `aws_glue_catalog_table.equipment_oee_shift` in `terraform/staging/
   historian.tf` (clone EE block; `terraform import`, not plain apply).
4. Gateway `10-historian-gateway.sh`: `live.equipment_oee_shift` FDW + `cold.*`
   read_parquet view + `oee_shift_promoted` gate + `silver/gold.equipment_oee_shift`
   union + `oee_shift_union_boundary` (cold-anchored, EV-style).
5. `refresh-oee-shift-cutover.sql` (clone EV refresh) wired into
   `historian-staging-run-append.sh` post-run hook + `install-historian-pipeline.sh`.

### B. `production_orders` (+ runtime) archive (legacy-copy)
`downtimes` need NO new work — they are the `equipment_events` archive (already 2021+).
For POs:
1. `scripts/historian-po-backfill.sh` (clone `historian-legacy-copy.sh`): legacy
   `production_orders` → F3 remap (packml_register / equipments) → COPY TO
   `production_orders/enterprise=3/year=/month=/*-legacy.parquet`; range from legacy
   `min/max(ts_start)`.
2. Glue table `aws_glue_catalog_table.production_orders` (`historian.tf`).
3. Gateway objects: `live.production_orders` FDW (from `core`/`gold`), `cold.*` view,
   `po_promoted` gate, `silver/gold.production_orders` union + `po_union_boundary`.
4. `refresh-po-cutover.sql` + wire into post-run hook + installer.
5. Cutover-refresh + one-boundary-row-per-promoted-ent invariant after the backfill.

## Sequencing / risk

- **B (POs)** is the tractable, codified clone — lowest risk, highest immediate value
  (historical Orders view). Do first.
- **A (oee_shift)** is gated on the 5-year recompute decision (A.1) — larger, needs the
  analytics-recompute-over-cold-raw approach settled before archiving.
- Every production run (the backfill scripts + the live `10-historian-gateway.sh`
  changes) is a **reviewed ops step** — the double-count/cutover invariants make an
  improvised run dangerous. Scaffold as reviewable PRs (scripts + terraform + glue),
  then run the backfill + gateway reload in a controlled window with the coverage-check
  (`historian-cutover-coverage-check.sh`) + staleness-monitor as gates.
