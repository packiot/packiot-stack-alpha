# core + gold column redesign — proposals (CUTOVER-only)

Staging `packiot_analytics`, schemas `core` and `gold` only. Companion to the SAFE
migration `db/migrations/tRD-core-gold-column-hardening/` (8 defense-in-depth CHECK
constraints, already applied + hardproofed on staging). This doc holds the changes that
touch producers/consumers or change column semantics/type in place — **propose only, do
not execute**. Every consumer claim below was grepped against
`services/{stream-engine,read-api}`, `edge-api/src`, `front4/src` on 2026-09-13.

Legend for the migrate-list: **SE** = stream-engine, **RA** = read-api, **EA** = edge-api,
**F4** = front4, **V** = DB view (schema noted), **SS** = Superset.

---

## A. Dead-but-written equipment columns (edge-api DAO passthrough) — drop batch

All the following on `core.equipments` are **0 non-NULL across all 283 rows** and have no
functional reader in the new stack (per the live column COMMENTs + independent grep). They
are **not** SAFE to drop today only because `edge-api/src/data/DAO/equipments/equipments-dao.ts`
lists each one in its INSERT column list, UPDATE SET list, and the create/edit DTOs
(`create-equipment.dto.ts` / `edit-equipment.dto.ts`) — a bare `DROP COLUMN` would 42703 the
write path on the next equipment create/edit.

| Column | Type | Evidence it's dead | Extra reader to clear |
|---|---|---|---|
| `id_counter_status` | int4 | 0 non-NULL; already removed from csadmin form | — |
| `id_equipment_type` | int4 | 0 non-NULL; no code→meaning table; distinct from `tp_equipment` | — |
| `id_equipment_state_status` | int4 | 0 non-NULL; legacy PLC state-code map, no reader | — |
| `id_equipment_state_idle` | int4 | 0 non-NULL; legacy PLC state-code map | — |
| `id_equipment_state_starved` | int4 | 0 non-NULL; legacy PLC state-code map | — |
| `id_equipment_state_blocked` | int4 | 0 non-NULL; legacy PLC state-code map | — |
| `id_equipment_state_fault` | int4 | 0 non-NULL; legacy PLC state-code map | — |
| `id_packed_counter` | int4 | 0 non-NULL; legacy PLC count-index, passthrough only | — |
| `id_plc` | int4 | 0 non-NULL; vestigial — no PLC registry in new stack | — |
| `sector_equipment_infeed` | int4 | 0 non-NULL; soft ref, no live reader | — |
| `sector_equipment_outfeed` | int4 | 0 non-NULL; soft ref, no live reader | — |
| `minimum_ideal_performance_threshold` | float4 | 0 non-NULL | **SE**: read (COALESCE) in `internal/uns/current_metrics.go:126-127,219` — must be removed there first |

### Expand/contract sequence (per column, batchable)
1. **EA**: remove the column from the `equipments-dao.ts` INSERT list, UPDATE SET list, and
   the `columnMappings` array; remove the field from both DTOs. Deploy.
   (For `minimum_ideal_performance_threshold` also drop the two `current_metrics.go` COALESCE
   legs in **SE** and deploy — it currently only ever COALESCEs NULL, so output is unchanged.)
2. Confirm no residual `to_regclass`/grep hit in any deployed service.
3. `ALTER TABLE core.equipments DROP COLUMN <col>` (NOT VALID-style not needed; use a
   generous `lock_timeout` + retry — see the SAFE migration's note, `equipments` is hot).
4. Reversible only by re-add + re-deploy; since all rows are NULL, no data is lost.

**Risk**: Low per column, but the write path breaks the instant the DB column is gone while a
pre-drop edge-api image is still live — order strictly EA-deploy → DB-drop. `equipments` write
traffic is CS-Admin-only (low), but the drop still needs the hot-table lock dance.

---

## B. `core.areas` dead counter columns (view-passthrough) — drop batch

`id_infeedcounter`, `id_outfeedcounter`, `id_rejectscounter` (int4): **0 non-NULL / 19 rows**,
DEPRECATED per COMMENT. Not SAFE because `pg_depend` shows column-level dependencies from
views **`v_entities_per_user_role`, `v_events_2`, `v_operator_entities_2`** onto `core.areas`
(these live outside core — likely `serving`; confirm owner before touching). A plain DROP
would need CASCADE (drops the views) or fails.

**Sequence**: (1) confirm which of those views actually project these 3 columns (they may
depend on other `areas` columns); (2) if projected, coordinate with the owning schema's agent
to drop the columns from the view SELECTs; (3) then `DROP COLUMN`. **Cross-schema — propose to
the serving owner, do not reach across.**

---

## C. `gold.production_orders_runtime` — duplicate id + type mismatch + legacy zero-cols

This table is the richest redesign target.

1. **Duplicate surrogate id.** Columns `id_production_order_runtime` (BIGINT, **PK**) and
   `id_production_orders_runtime` (BIGINT, plural, NOT NULL). Both are populated on all 18,877
   rows and — verified — **never equal (0 equal, 18,877 distinct pairs)**, so the plural is a
   *separate* legacy surrogate, not a copy. No app reference anywhere in
   services/edge-api/front4. It is NOT NULL with no default, so some non-app writer (legacy
   proc / seed) still supplies it, and views depend on the table at column level
   (`v_events_2`, `v_operator_po_details_3`, `v_report_downtimes`, `production_order_runtime` —
   confirm they don't project the plural col).
   **Proposal**: after confirming zero view/proc references to the *plural* column specifically,
   `DROP COLUMN id_production_orders_runtime`. Expand/contract; reversible via re-add (values
   are not reconstructable, so snapshot first if any doubt).

2. **Type mismatch on the FK.** `production_orders_runtime.id_production_order` is **int4**,
   while its parent `core.production_orders.id_production_order` is **int8** (and
   `gold.po_box_counter.id_production_order` is int8). There is also *no* FK constraint from
   runtime → production_orders. This is an int-overflow time-bomb (PO ids are int8-spaced) and
   a join-type-coercion cost. **Proposal**: `ALTER COLUMN id_production_order TYPE bigint`
   (widening is data-safe; rewrite under lock) and add the missing FK
   `id_production_order → core.production_orders(id_production_order)`. Consumer check: **SE**
   `internal/rollup/recalc.go` / `compute.go` write this column — verify Go int64 binding
   (it already is) before widening.

3. **Legacy always-zero metric columns.** Per COMMENT + 0-on-staging: `oee`, `oee_p`, `oee_a`,
   `available_time`, `planned_downtime`, `ideal_production`, `idle_time`, `idle_starved`,
   `idle_blocked`, `downtime`, `changeover_time`, `multiplier` are NOT written by the new-stack
   compute pass (only `oee_q`, `running_time`, `stopped_time`, `net_production`,
   `gross_production`, `speed` are). `recalc.go` *reads* `available_time`/`planned_downtime`.
   **Proposal**: keep the read columns; drop the genuinely unreferenced ones (`multiplier`,
   `idle_*`, `downtime`, `changeover_time`, `oee_p`/`oee_a`) after clearing the golden-test
   fixtures in `internal/rollup/*_test.go`. Lower priority than 1 & 2.

---

## D. `gold` dormant metric columns present on every grain

`idle_time`, `idle_starved`, `idle_blocked` exist on all equipment/area/site OEE grains and are
**summed up the cascade but never populated by any base-grain writer** (0 on staging, per
COMMENT). Removing them touches the whole rollup SUM list (SE `grains.go`, `entity_grains.go`,
`day.go`, provisioning procs `piot_create_*`) plus **RA** datasets that may project them and
Superset datasets. **Proposal**: treat as one coordinated cascade edit; low value, medium blast
radius — defer unless the idle feature is formally cancelled. Same story, smaller, for
`equipment_oee_shift.manually_customized` / `invalidated` (legacy flags, default false, never
written by the new-stack rollup).

Whole-table dormancy: `gold.equipment_oee_shift_weekly` and `gold.equipment_oee_shift_monthly`
are legacy shift×week / shift×month aggregates the new-stack rollup does **not** populate (only
`unmetered.go` touches them to NULL `oee` for line-metered machines; `provision.go` still
provisions `piot_create_equipment_oee_shift_weekly`). **Proposal**: candidate *table* drops
after retiring the provision-proc references and confirming no RA/SS reader — bigger than a
column change, route through a dedicated task.

---

## E. `topic_routing` — reserved-word / vague column names + mixed concerns

`core.topic_routing` (renamed from `packml_register`) mixes routing *config* (`packml_topic`,
`mqtt_topic`, `id_equipment`, `id_unit`, `device_key`, `active`, `attributed`, …) with
per-signal *live values* (`timestamp`, `value`, `signal_quality`, `ts_quality`,
`sparkplug_json`). Two smells:

- **`timestamp` and `value` are SQL non-reserved keywords** used as bare column names — every
  reference must quote-or-qualify, and they read as generic. Rename → `last_signal_ts`,
  `last_signal_value`. **Heavy consumer surface** (SE decoder/uns, RA, edge-api topic writers,
  Hasura) — full expand/contract with dual-read.
- `id_topic_route` still defaults from the pre-rename sequence
  `packml_register_id_packml_register_seq` (cosmetic; rename the sequence for hygiene).
- Column ordinal 15 is a dropped column (gap) — cosmetic, ignore.

**Proposal**: rename the two value columns via add-new → backfill/dual-write → repoint readers
→ drop-old. Only worth it bundled with a topic_routing touch; otherwise document-and-defer.

---

## F. `core.equipments.status_type` — enum with source drift (NOT constrained in the SAFE batch)

Authoring enum is `{0,1,5}` (csadmin), live distribution `0×130, 5×21, 1×1, NULL×131`. A domain
CHECK was **deliberately excluded** from the SAFE migration because: (a) the stream-engine
native-events deriver + `BuildEventMint` gate on `status_type = 4`
(`internal/events/deriver.go:75`, `writers/equipment_values.go:493`) — a value that matches
**zero** live rows, while `cpac_deriver.go`/`closer.go` treat `status_type = 0` as the
CPAC/pipeline class; and (b) the lone `status_type = 1` row is unexplained. Pinning a CHECK now
could entrench the drift or block a legacy `4`. **Proposal**: first reconcile the `=4` predicate
in SE against the live `{0,1,5}` authoring values (bug or intentional?), settle the `1` row,
then add `CHECK (status_type IN (0,1,5))`.

---

## G. Lower-value semantic / type cleanups (document, batch opportunistically)

| Item | Current | Issue | Proposed |
|---|---|---|---|
| `core.production_orders.oee` vs `oee_q/a/p` | `oee`=float4, `oee_q/a/p`=float8 | precision inconsistent within one row; gold OEE cols are all float4 | standardize the 4 PO OEE cols on one type (float4 to match gold, or float8 for headroom) |
| `core.{oee,production,scrap}_targets.id_site` / `id_equipment` | `0` sentinel = "not scoped" | sentinel-instead-of-NULL; and these are in the composite PK, so NULL can't be used as-is | document the `0`-sentinel contract explicitly (already COMMENTed); a true fix needs a scope-type discriminator — large |
| `id_enterprise` nullability across the 3 target tables | `oee_targets` NOT NULL default 0; `production_targets`/`scrap_targets` nullable | inconsistent tenant-scoping | make all three NOT NULL after backfilling any NULLs (verify first) |
| `core.enterprises.scrap_calc_type` | `0` and `1` both = "% of gross" | two distinct codes with identical behavior (COMMENT confirms) | collapse to a single "gross" code (2 = net) — needs csadmin + front4 `scrapPercent.ts` + edge-node-red SQL touch |
| `gold.*_oee_*.recalc_needed` default | `true` on area/site grains, `false` on equipment grains | inconsistent dirty-flag default across sibling grain tables | pick one convention (align to the rollup's re-flag semantics) |
| `core.production_orders.multiplier` | float8, 0 non-NULL / 25,700 rows | dead (distinct from the equipment_setup LINE UNIT MULTIPLIER map) | drop after confirming no proc/view reader |

---

## Ordering recommendation

1. **C.2** (widen `id_production_order` to bigint + add FK) — correctness/overflow, small surface.
2. **A** (dead equipment columns) — one edge-api deploy clears 11 of 12; highest cleanup yield.
3. **C.1 / C.3 / G.multiplier** (drop dead runtime + PO columns) — after fixture cleanup.
4. **B / E / D / F / G-rest** — cross-schema or heavy-consumer; schedule individually.

Everything here is expand/contract and reversible. Nothing in this doc has been executed.
