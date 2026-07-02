# Prod ↔ staging ↔ 3-flows database comparison

- **Date**: 2026-07-02 · **Method**: SELECT-only on prod tsp12/packiot40
  (awslambda + BEGIN READ ONLY), postgres on staging; diffs computed on
  the app EC2. Requested before ADR-0012 Phase 4 proceeds.
- **Surfaces compared**: prod `public` · staging `packiot.public`
  (Flow 1) · `packiot.shadow_go_port` (Flow 2) ·
  `packiot_shadow.public` (Flow 3) · `packiot.customer_reports` (pool)

## 1. Object counts

| Surface | tables (r) | views (v) | matviews (m) | notes |
|---|---|---|---|---|
| prod public | 203 | 134 | 10 | + 19 hypertables, 17 CAggs (CAggs count within views) |
| staging public | 233 | 111 | 10 | + 2 hypertables, **0 CAggs** |
| Flow 2 shadow_go_port | 4 | 0 | 0 | raw writer targets, by design |
| Flow 3 packiot_shadow | 110 | 12 | 0 | Hasura-parity stub + writer tables + Wave 0/1 objects |
| pool customer_reports | 3 | 0 | 0 | Wave 1 |

## 2. View-materialization drift is WIDER than the PowerBI set

Wave 0 fixed 15 PowerBI objects. The full diff shows **~22 more objects
that are views on prod but plain tables on staging** (same
`00-schema.sql` bootstrap bug): `agg_equipment_values_1min` (a CAGG on
prod!), `h_piot_production_orders_merged{,_new}`,
`v_agg_equipment_values_1day_full`, `v_entities_per_user_role`,
`v_insights_main`, `v_menu_per_user_role`, `v_mission_control` (+4
siblings), `v_operator_entities`, `v_operator_po_list{,_setup,_2,_3}`,
`v_pages`, `v_total_production_{today,yesterday,month_grain_1day,_1week}`.

→ **Wave 0b**: flip these too (same captured-def transactional method).
Note several are operator/mission-control views the staging operator UI
may actually read — dependency probe required per object (unlike the
empty PowerBI 15).

Staging-only tables that are legitimate: mirror infrastructure
(`mirror_id_map`, `mirror_replay_cursor`, `mirror_replay_dlq`),
`t_piot_*` scratch tables, `labels`, `sample_boxes`, `uns_metrics`.

## 3. Aggregate architecture — three layers on prod, ~absent on staging

| Layer | Prod | Staging |
|---|---|---|
| Hypertables | **19** — incl. `equipment_values`, `equipment_events`, `agg_equipment_values_1min_t` (1371 chunks), `agg_*_past` ×9, `agg_*_archive` ×5, ohlc/ticks | **2** — `equipment_runtime_1hour`, `equipment_runtime_shift`. `equipment_values` is a PLAIN table on staging |
| Continuous aggregates | **17** — `agg_{equipment,area,site}_values_{1min,10min,1hour}` + `ca_agg_equipment_values_{1s,10min,1hour,1day}` + `ca_discrete_changes_1s` + `ca_equipment_boxes_{1s,1hour}` + `mv_ohlc_1s` | **0** |
| Plain matviews | 10 (`mv_agg_equipment_values_*_full_{hot,warm}`) | 10 — identical names ✓ |

**Implication for ADR-0014 Phase 3**: the ADR frames Phase 3 as
"convert runtime functions into CAggs" — but prod ALREADY RUNS a CAgg
layer for the values aggregates. Phase 3 splits into (a) adopt prod's
existing CAgg layer on staging (prerequisite for any rehearsal — today
staging exercises a completely different aggregate path than prod!),
and (b) port the runtime rollup writers, which have no CAgg equivalent
on either side yet. Also note prod's TimescaleDB machinery includes a
CAgg invalidation trigger + `feed_invalidation_log` on
equipment_values, with `agg_equipment_values_1min_t_invalidation` at
**496M rows** — the invalidation stream is prod's largest table.

## 4. Triggers on hot tables — staging does NOT mirror prod

| Table | Prod | Staging |
|---|---|---|
| equipment_values | `feed_invalidation_log`, `ts_cagg_invalidation_trigger`, `ts_insert_blocker` | `piot_set_shift_before_insert` |
| equipment_events | `update_prev`, `update_last_update_…`, `ts_insert_blocker` | `update_prev` |
| equipment_events_man | `update_last_update_…` | — |
| production_orders | `update_last_update_…` | — |
| equipments | `Create packml topics`, `Update super users`, `upsert_to_uns` | — |

**Finding A (affects the live ADR-0014 P2 bake)**:
`piot_set_shift_before_insert` — the trigger we just ported to Go — is
**staging-only**. Probed on prod: last-hour equipment_values = 41,146
rows with only **36 having id_shift (0.09%) and ZERO having
ts_value_production**; day-old rows show the same ratio, so nothing
backfills them later. **On prod these columns are effectively unused —
shift attribution must happen at aggregate/rollup time, not per-row.**
Consequences:
- The P2 bake remains valid as a fidelity test of the staging trigger
  semantics, and the trigger retirement is staging-only cleanup.
- For prod, the Go fill is a **behavioral addition**, not a port.
  Decide deliberately at Phase 5: per-row shift attribution would
  simplify ADR-0014's downstream rollup ports (the shift join moves
  from every rollup query to once-at-ingest), but it changes prod data
  shape — PowerBI/report owners should confirm nothing assumes NULL.
- Where prod DOES attribute shifts today: inside the rollup functions
  (`piot_get_*_production` family reads shift_hours at aggregation
  time) — verify when porting those in P3.

**Finding B**: staging is missing prod's `Create packml topics` +
`Update super users` + `upsert_to_uns` triggers on `equipments` — yet
CLAUDE.md documents packml auto-management as trigger-driven. CS-Admin
rehearsals on staging therefore don't exercise prod's trigger path.

**Finding C**: prod's `last_update` maintenance triggers are absent on
staging (3 tables) — timestamp-based comparisons between environments
can silently skew.

## 5. Functions — 607 (prod) vs 636 (staging)

- Env-API noise: prod-only = TimescaleDB multi-node API
  (`*_data_node`, `create_distributed_hypertable`) + pg_stat_statements;
  staging-only = columnstore/chunk API + btree_gist. **TimescaleDB
  versions differ substantially** (prod older multi-node era; staging
  2.18+ columnstore era) — a Phase 5 constraint for any CAgg DDL parity.
- **Real body drift in OEE functions** (same name, different source
  size — prod|staging bytes):
  `piot_trig_equipment_events_update_prev` 283|1461,
  `piot_get_shift_hours_by_enterprise_packml_topic_2` 1308|69,
  `piot_get_shift_hours_by_packml_topic_2` 1754|1989,
  `piot_feed_agg_equipmentvalues_1min_t_new` 6374|6191,
  `h_piot_get_events_timeline3_with_event_id` 3236|866,
  `proc_create_jobs_enterprsie_10` 9274|9060.
  → **Prod is ground truth for any port**; staging bodies must not be
  trusted without a prod diff (extend the Wave-2 capture pattern).

## 6. Scale (n_live_tup; hypertable parents read ~0 — see caveat)

| Prod top tables | rows | Staging top tables | rows |
|---|---|---|---|
| agg_equipment_values_1min_t_invalidation | 496M | equipment_values | 8.2M |
| monitoramento_execucao_functions | 28.3M | uns_metrics | 7.8M |
| equipment_runtime_1hour | 16.6M | agg_equipment_values_1min_t | 1.8M |
| mv_agg_…_1min_full_hot | 6.8M | mirror_id_map | 1.4M |
| c35_dashboard_timeline_24h | 5.4M (dead) | monitoramento_execucao_functions | 0.6M |
| user_logs | 2.5M | equipment_events | 0.3M |

Caveat: prod `equipment_values`/`equipment_events` are hypertables —
their rows live in chunks, so they don't appear here; true sizes are in
the schema-map audit (3.7GB+). Prod hygiene candidates surfaced: the
496M invalidation log and the still-growing 28M dead pt-BR logger.

## 7. The 3 flows (by design, confirmed)

- **Flow 2** (`shadow_go_port`): exactly 4 raw writer targets
  (equipment_values, equipment_events_man, production_orders,
  uns_equipment_current_metrics) — intentional minimal surface.
- **Flow 3** (`packiot_shadow.public`): 110 tables + 12 views = the
  Hasura-metadata-parity stub (~60 `h_*` objects that are
  views/functions on prod exist as stub TABLES here) + ADR-0013 writer
  tables + Wave 0 flipped views + POC façades. Reminder from Wave 1:
  stub tables share prod names but NOT shapes — never backfill/join
  against them without a shape check.

## 8. Actions fed into the plans

1. **(ADR-0014 P2, before bake close-out)** identify prod's real
   id_shift fill mechanism — the trigger being retired exists only on
   staging (Finding A)
2. **(Wave 0b)** flip the ~22 additional drifted views on staging —
   with per-object dependency probes (operator UI may read some)
3. **(ADR-0014 P3 reframe)** step one is adopting prod's existing CAgg
   layer on staging, not inventing CAggs; TimescaleDB version skew is a
   prerequisite check
4. **(porting rule)** prod is ground truth for every PL/pgSQL body —
   staging has confirmed drift in 6+ OEE functions
5. **(Phase 5 list)** prod hygiene: 496M invalidation log,
   28M dead-logger; staging parity: missing equipments/last_update
   triggers (Findings B/C)
