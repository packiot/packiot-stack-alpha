# packiot_shadow — Object Review & Human-Readable Rename Map — 2026-07-11

**Scope:** review of the **staging** refactor DB `packiot_shadow` (the F3 database on `10.10.10.89`, ours/mutable) and a rename map to bring its object names to a consistent, human-readable standard. `tsp12`/`packiot40` (client prod) was used **read-only, as a reference only** — no renames or writes to prod, ever. Renames here are a **design + phased-migration plan**; they are *not* applied live (a big-bang rename would break the Go worker, Hasura, and the running bake).

## Headline: the refactor already did ~90% of the work

`packiot_shadow` vs prod `tsp12`:

| | prod tsp12 | packiot_shadow |
|---|---|---|
| tables | 217 | 70 (+7 in `customer_*` schemas) |
| functions / procedures | 712 / 47 | **27 / 0** |
| triggers | incl. the 122 GB `feed_invalidation_log` | **0** (shed) |
| Portuguese/tenant-coded names | many | mostly parameterized into schemas |

So this is a **finishing pass on naming inconsistencies**, not a demolition. Wins already banked by the refactor: the invalidation monster dropped; `monitoramento_execucao_functions` → `function_execution_log`; per-tenant `c35_dashboard_*` / `report_*_enterprsie_06` clones collapsed into parameterized `customer_dashboards.*` / `customer_reports.*` tables with a `customer_id` column (the `enterprsie` **typo is fixed in the new tables** — it survives only in thin backward-compat views).

## Naming convention (the standard to converge on)

1. **snake_case, lowercase, English only** — no Portuguese (`producao`→`production`, `paradas`→`stops`, `execucao`→`execution`), no typos (`enterprsie`→`enterprise`) ever in an identifier.
2. **No tenant ids in names** — no `_cust_13`, `_enterprise_06`, `c33_`, `c35_`. Tenancy is a **column**, never a name.
3. **No consumer names in object names** — drop the `h_` (Hasura) and `piot_` (vendor) prefixes.
4. **One prefix per object kind** — `cagg_` for continuous aggregates, `v_` for plain views, unprefixed base tables, `hist_` for replay tapes. Retire the ambiguous `agg_` / `ca_` / `ca_agg_` cagg prefixes.
5. **Consistent grain suffixes**, smallest→largest: `_1s, _1min, _10min, _1hour, _1day, _1week, _1month, _shift`. **Keep the numeric form** (`_1hour`, not `_hourly`) — unambiguous, already pervasive across 40+ objects and the Go worker; switching is churn without benefit.
6. **No version-number suffixes** — `_2/_3/_4` on views means "we iterated and forgot to clean up." Version in git, not the catalog.
7. **Functions = `verb_object` with correct tense** — idempotent rollups are `refresh_*` (not `create_*`, which is misleading — they rebuild every run); pure lookups are `get_*`.
8. **Every table gets a primary key** (fixes the no-PK hazard on `hist_*`, `production_orders_runtime`, `function_execution_log`, `equipment_events`, `customer_*`).
9. **Schema-as-namespace** for cross-cutting families (`customer_reports.*`, `customer_dashboards.*` already; consider `ops.*` for `function_execution_log`/`user_logs`).

## The biggest single defect: two prefixes for continuous aggregates

`agg_*`, `ca_*`, and `ca_agg_*` all denote continuous aggregates (and `agg_*` is *also* used for plain views). Unify **all caggs to `cagg_`**. Representative renames (full family in the map below):

| legacy | proposed | referenced-by |
|---|---|---|
| `ca_agg_equipment_values_1hour` | `cagg_equipment_values_1hour` | **Go ×21**, refresh jobs |
| `ca_agg_equipment_values_1min` | `cagg_equipment_values_1min` | **Go ×7**, jobs |
| `ca_discrete_changes_1s` | `cagg_discrete_changes_1s` | Go, jobs |
| `ca_equipment_boxes_1s` | `cagg_equipment_boxes_1s` | jobs |
| `agg_{area,site}_values_{1min,10min,1hour}` (caggs) | `cagg_{area,site}_values_{grain}` | jobs, Hasura |

## Rename map (by domain, most-impactful first)

*referenced-by legend:* **GO** oeecloud/mirror-worker SQL · **NR** edge-node-red/db · **HAS** Hasura · **CMP** bake comparator · **FN** other DB functions · **JOB** TimescaleDB policy.

**Provision/rollup functions — wrong verb + vendor prefix** (17 functions, pattern `piot_create_<entity>_runtime_<grain>` → `refresh_<entity>_runtime_<grain>`):

| legacy | proposed | referenced-by |
|---|---|---|
| `piot_create_equipment_runtime_1hour` | `refresh_equipment_runtime_1hour` | **GO**, NR |
| `piot_create_equipment_runtime_shift` | `refresh_equipment_runtime_shift` | **GO**, NR |
| `piot_create_{area,site}_runtime_{grain}` | `refresh_{area,site}_runtime_{grain}` | GO, NR |

**Helper lookup functions** (8, `piot_get_*` → `get_*`):

| legacy | proposed | referenced-by |
|---|---|---|
| `piot_get_shift_hour_begin_by_equipment` | `get_shift_hour_begin_by_equipment` | **GO ×9**, NR |
| `piot_get_day_begin_by_equipment` | `get_day_begin_by_equipment` | **GO ×9**, NR |
| `h_piot_get_events_timeline3_with_event_id` | `get_events_timeline_with_event_id` (drop `h_`,`piot_`,`3`) | HAS |

**Tables — cryptic / double-grain / no-PK:**

| legacy | proposed | note |
|---|---|---|
| `equipment_runtime_shift_1week` | `equipment_runtime_shift_by_week` | disambiguate double-grain |
| `equipment_runtime_shift_1month` | `equipment_runtime_shift_by_month` | same |
| `equipment_events_man` | `equipment_events_manual` | expand abbrev |
| `box_production_bridges` | `production_order_box_links` | opaque "bridges" → junction intent |
| `production_orders_runtime` | *(keep name; **add PK**)* | no-PK hazard |
| `customer_dashboards.dashboard_producao_24h` | `customer_dashboards.production_last_24h` | de-Portuguese |
| `customer_dashboards.dashboard_paradas_24h` | `customer_dashboards.stops_last_24h` | de-Portuguese |

**Operator views — drop iteration-version suffixes:**
`v_operator_po_list_setup_4` → `v_operator_po_list_setup`; `v_operator_po_details_3` → `v_operator_po_details`; `v_operator_entities_2` → `v_operator_entities`.

## Drop candidates (dead / superseded — remove, don't rename)

- **Legacy compat shim views** (superseded by the `customer_*` schemas — drop *after* consumers repoint): `report_shift_enterprsie_06`, `report_speed_enterprsie_33` (still carry the typo + tenant id), `equipment_boxes_cust_13` (tenant id + hardcoded `label_key='Label_Neopac'`), `c33_dashboard_producao_24h`, `c35_dashboard_{producao,paradas,timeline}_24h`, `monitoramento_execucao_functions`, `dt5min_po_func_ret`.
- **Dead 0-byte stubs:** `report_shift_enterprise_06`, `report_speed_enterprise_33`, `equipment_values_1min` (+ its dead view `agg_equipment_values_1min_t`), `dt5min_po_function_returns`, `h_pending_events_with_event_id`, `h_events_timeline3_with_event_id`, `equipment_events_low_speed`.
- **Consolidation decision (not an automatic drop):** two parallel cagg families compute overlapping equipment rollups — the `agg_*` cascade (jobs 1003–1011) vs the `ca_agg_*` flow caggs (jobs 1016–1017). Go reads `ca_agg_*` heavily (`_1hour` ×21, `_1min` ×7) and the `agg_*` cascade barely — so the `agg_*` cascade is the likely retire target, but confirm against Hasura/reports consumers before renaming either.

## Phased migration (must not break F3 mid-flip)

The refactor already proves the safe pattern (`docs/adr/reference/migrations/0012-sandbox-gate-alignment.sql`: new schema-qualified table → old-name compat view). Generalize to 5 phases per object:

0. **Map referencers** across the four surfaces (GO / NR / HAS / CMP) — the `referenced-by` column is that map.
1. **Introduce the new name as a synonym** — compat view (tables) or one-line delegating wrapper (functions/caggs) so old + new coexist.
2. **Repoint consumers in dependency order:** DB-internal functions first (a renamed cagg must land atomically with the `refresh_*` function + refresh policy that read it) → **Go worker** (its SQL is *strings*, so a rename is a silent runtime no-op until redeploy — keep the old name resolvable until the new build is live) → **Hasura** (relationships are name-bound; retrack, don't assume) → comparator/reports/edge-node-red seed.
3. **Verify parity** — run the bake comparator after each surface repoint; it catches a missed referencer before the flip.
4. **Rename base & drop compat** — once every surface reads the new name and the comparator is green across a full shift cycle, rename the base object and drop the transitional shims (this is when the tenant-coded/typo'd views finally disappear).

**Ordering risks (highest→lowest):** (1) the Go worker's string SQL — no compile-time safety; (2) cagg ↔ refresh-policy ↔ function coupling — must land atomically; (3) Hasura relationship rebinding — name-bound, silent GraphQL field loss; (4) resolve the `agg_*` vs `ca_agg_*` consolidation *before* renaming either.

## Flags

- **`uns_metrics` is not in `packiot_shadow`** — shadow has `uns_equipment_current_metrics` + the `uns_*_current_*` snapshot family; the bare `uns_metrics` table lives in `packiot` (F1/F2), not shadow.
- Several `piot_*` names the Go worker references (`piot_proc_refresh_runtime`, `piot_get_equipment_production_order_runtime_final`, …) are Go-internal SQL builders or target `packiot`, not shadow — they don't need renaming here but reinforce the drop-`piot_` convention if ported back.
- Confirm the distinct grains of `ca_lab_equipment_values_1min` vs `ca_agg_lab_equipment_values_1min` before finalizing collision-safe names.

**Recommendation:** apply this as a **post-flip** finishing pass (the flip itself needs the current names stable for the comparator). Start with the zero-risk drops (dead stubs), then the `cagg_` unification and the `refresh_*`/`get_*` function renames behind compat wrappers, verifying against the comparator at each step.
