# Public → core / app / barcode Schema Reorganization — STAGING `packiot_analytics`

**Task:** #237 · **Status:** DESIGN ONLY — no DDL executed, no objects moved.
**DB:** `packiot_analytics` @ `10.10.10.89` (staging box `i-06c9547a2c7091ab7`).
**Engine:** PostgreSQL 15.17 + TimescaleDB 2.27.0.
**Scope:** the *remaining* `public` objects, after the medallion split (#228/#231:
`bronze`/`silver`/`gold` facts) and the analytics rename (#224/#226) already landed.
**Author note:** every feasibility claim is hardproofed with a read-only probe or a
throwaway schema (`t237_core`/`t237_pub`) created and **dropped** (0 residual). No real
object in `packiot_analytics` was created, altered, moved, or dropped.

---

## 0. TL;DR — the verdict

| Question | Answer |
|---|---|
| Can the dims/app/barcode tables move with `ALTER TABLE … SET SCHEMA`? | **YES** — same catalog-only mechanism the medallion split proved for facts (#228 §2). Plain tables, sub-second, `ACCESS EXCLUSIVE` for the instant of the move. |
| Does the live write path (edge-api DAOs) need code edits? | **NO.** edge-api runtime `src/` has **0** hard-coded `public.<dim>` — every DAO uses *unqualified* names resolved by `search_path`. Adding `core, app, barcode` to the DB `search_path` absorbs the entire edge-api + read-api + sparkplug-decoder read/write surface with zero code change. |
| What is the residual hard-coded `public.` surface that must be lifted? | A **finite, enumerated** set: stream-engine (8 files), analytics-sync (4 files), mirror-worker-go (1 file). edge-node-red's 100 refs are all fresh-init `db/*.sql` (forward-port, not live). |
| **THE CRUX — does a fresh `knex migrate:latest` diverge from the moved env?** | **Handled by the existing fake-baseline mechanism**, extended. Greenfield is built from `db/init-f3/snapshot/*.sql` (curated pg_dump) + `knex-baseline.sql` (fake-seeds `knex_migrations`), *not* `migrate:latest` from empty. The fix is: (a) make the snapshot **multi-schema**, (b) **re-classify** the 5 knex-RUN net-new tables (labels/sample_boxes/scanned_boxes/idempotency_keys/mirror_replay_dlq) from RUN→FAKE once the snapshot provides them in their new schema, (c) widen `search_path`. Detailed in §4. |
| Is the crux hypothetical? | **NO — it is already broken on staging.** `gold.mirror_replay_dlq` holds the **1374 live rows**; `public.mirror_replay_dlq` is an **empty duplicate shadow** — the exact "moved a knex-touched table out of `public` without reclassifying" landmine, observed live (§4.3). |
| Auto-updatable public shim views for the moved dims — do writes pass through? | **YES — proven** on a throwaway schema: plain `INSERT`, `ON CONFLICT (col) DO NOTHING`, and `ON CONFLICT (col) DO UPDATE` all pass through an auto-updatable shim view into the base table (§8). Every hard-coded dim writer uses `ON CONFLICT (col-list)`, never `ON CONSTRAINT` (which would fail). |

**Recommendation:** proceed with **in-place `SET SCHEMA` + public shim views + a widened
`search_path`**, sequenced **core → app → barcode → silver-current-state → views**. Core dims
are the live write path = highest risk; the shim + search_path lever keeps every consumer live
across each cutover. The single indispensable non-DDL deliverable is the **db-migrate
reconciliation** (§4): without it, greenfield prod is born with dims in the wrong schema (or an
empty `public` shadow), computing silently wrong data.

---

## 1. Current landscape (read-only census)

### Schemas present (verified live)
`public`, `bronze` (2 tbl), `silver` (3 tbl + 7 caggs/views), `gold` (15 tbl), `serving`
(~40 fns), `bi` (10 views for Superset), `customer_reports` (4 tbl), `customer_dashboards`
(3 tbl), plus `drop_backup_20260908` (a #233/#226 backup schema). **`core`, `app`, `barcode`
do NOT exist yet** — they must be created.

### `public` object counts
- **70 tables** (`relkind r`) · **49 views** (`relkind v`, of which **14 are legacy caggs**
  `agg_*`/`ca_*`, and **~12 are medallion/rename shim views** already pointing at
  `silver`/`gold` — see §3).

### DB-level `search_path` (the key lever) — verified live
```
packiot_analytics default:  "$user", gold, silver, bronze, public
```
Set by migration `02` of the medallion split (t231). **This already carries the risk we must
manage:** an unqualified `CREATE TABLE` lands in the **first existing schema** in the path
(hardproofed §8) — today that is `gold`. This is why moving a knex-RUN table out of `public`
without reclassifying it produces a wrong-schema/empty-shadow table.

### The medallion + rename work already landed
- Facts live in `silver` (`equipment_values`, `equipment_events`, `equipment_live_metrics`,
  the `equipment_metrics_*`/`equipment_categorical_*` caggs).
- OEE grains + PO runtime live in `gold` (`equipment_oee_*`, `area_oee_*`, `site_oee_*`,
  `production_orders_runtime`).
- `public` carries **shim views** with the old names (`equipment_values`, `equipment_events`,
  `equipment_oee_*`, `production_orders_runtime`, `topic_routing`, `equipment_live_metrics`,
  `area_oee_*`, `site_oee_*`) — the medallion expand/contract compatibility surface. **These are
  #228/#231/#224 territory, not this task** — leave them alone.
- **Anomaly to reconcile (§4.3):** `gold` also holds `mirror_replay_cursor`, `mirror_replay_dlq`,
  `user_screen_config` — these are **app/ops tables miscategorized into `gold`** by the medallion
  move, and each has an **empty duplicate** still in `public`. This task re-homes them to `app`
  and fixes the duplicate. Coordinate with #233 (gold-shim contraction).

---

## 2. Object → schema map (every remaining `public` object)

Legend: **MOVE** = `SET SCHEMA` in this reorg · **STAY** = keep in `public` (justified) ·
**GOLD→APP** = re-home a mislocated table (currently in `gold`) · **SHIM** = medallion/rename
compatibility view, not this task.

### → `core` (dimensions / entities / reference)
| Table | Class* | Note |
|---|---|---|
| `equipments` | A/faked | live dim; edge-api + stream-engine (9 hc) + mirror-worker (hc) write/read |
| `sites` | A/faked | live dim; stream-engine (3 hc) |
| `areas` | A/faked | live dim |
| `enterprises` | A/faked | live dim; has `active` soft-delete |
| `clients` | A/faked | dim |
| `production_orders` | A/faked | **highest-churn**; edge-api PO control + analytics-sync (14 hc) + mirror-worker (hc) |
| `products` | A/faked | dim |
| `product_families` | A/faked | dim |
| `shifts` | A/faked (guarded RUN) | dim; stream-engine shiftresolver (hc) |
| `shift_hours` | A (snap) | dim; stream-engine shiftresolver (hc) |
| `teams` | A (snap) | dim |
| `packml_register` | A/faked | **hot ingest router**; `topic_routing` view already exists over it — see §7 note |
| `client_descriptors` | B (absent from snap) | ADR-0045 onboarding config; created by sparkplug-decoder onboarding, not knex |
| `box_production_bridges` | A (snap) | barcode↔PO bridge dim; stream-engine reports (hc) |
| `oee_targets` | A (snap) | target |
| `production_targets` | A (snap) | target; stream-engine (2 hc) |
| `scrap_targets` | A (snap) | target; edge-api migration `fix_scrap_target_on_conflict` hard-codes `public.scrap_targets` |
| `equipment_downtime_reason` | A (snap) | reason dim (1188 rows) |
| `equipment_scrap_reason` | A (snap) | reason dim |
| `downtime_reason` | A (snap) | reason dim (54 rows, ADR-0039) |
| `scrap_reason` | A (snap) | reason dim |
| `equipment_validation_shift` | B (absent) | 0 rows; provenance = OEE engine, not knex |
| `shifts_exception_period` | A (snap) | shift exception dim |

### → `app` (auth / i18n / config / ops)
| Table | Class* | Note |
|---|---|---|
| `users` | A/faked | edge-node-red (4 hc); has `active` soft-delete |
| `user_roles` | A/faked | edge-node-red (3 hc) |
| `user_logs` | A/faked | audit trail; analytics-sync (1 hc), edge-node-red (1 hc) |
| `user_screen_config` | **GOLD→APP** | currently mislocated in `gold`; empty dup in `public` |
| `translations` | B (absent) | langpack explode; edge-api migration `explode_language_packs_to_translations` hard-codes `public.` |
| `tenant_translations` | B (absent) | per-tenant i18n overrides |
| `language_packs` | A (snap) | i18n; edge-api migration `to_regclass('public.language_packs')` (hc) |
| `pages` | A/faked-guarded | menu pages |
| `dashboard_config` | A (snap) | edge-node-red (8 hc) |
| `labels` | **B/RUN** | knex-RUN net-new (`20260409000001`) |
| `label_formats` | A (snap) | stream-engine (2 hc) |
| `idempotency_keys` | **B/RUN** | knex-RUN net-new (`20260707180000`) |
| `function_execution_log` | A (snap) | ops log |
| `capture_observations` | B (absent) | ADR-0043 capture; created by sparkplug-decoder |
| `mirror_replay_cursor` | **GOLD→APP** | currently mislocated in `gold` (2 rows live); dup in `public` |
| `mirror_replay_dlq` | **GOLD→APP + B/RUN** | **live in `gold` (1374 rows), empty dup in `public`** — the crux landmine (§4.3); knex-RUN (`20260626000001`) |

### → `barcode`
| Table | Class* | Note |
|---|---|---|
| `box_scans` | A (snap) | append-only (has `box_scans_no_mutate` trigger + `box_scans_no_mutate()`); 0 rows |
| `po_box_counter` | A (snap) | counter |
| `scanned_boxes` | **B/RUN** | knex-RUN net-new (`20260409000003` + `fix_scanned_boxes`) |
| `sample_boxes` | **B/RUN** | knex-RUN net-new (`20260409000002`) |

### → `silver` (current-state grains — join the live tier)
| Table | Note |
|---|---|
| `equipment_live_day` / `_hour` / `_job` / `_month` / `_shift` / `_week` | live snapshot grains (283–505 rows); stream-engine hard-codes `public.equipment_live_{hour,job,month,week}` (12 hc) |
| `area_live_day` / `area_live_shift` | 23 rows each |
| `site_live_day` | 0 rows |
| `equipment_live_metrics` | **already in `silver`** (public is a shim view) — no action |

### Views → `serving` (unqualified read-api reads absorb via search_path)
`v_operator_entities_2`, `v_operator_po_details_3`, `v_operator_po_list_setup_4`,
`v_entities_per_user_role`, `v_entities_per_user_role_operator`, `v_menu_per_user_role`,
`v_report_downtimes`, `v_po_box_totals`, `v_events_2`, `production_information`.
*(read-api reads all of these `FROM <view>` unqualified — proven live.)*

### Views → `customer_reports` (SAP / per-tenant report views)
`v_13_site_deb_sap_report`, `v_sap_report_data_sync_customer_13`,
`v_sap_report_data_sync_customer_13_deb`, `v_piot_production_data_sync_cust6`,
`equipment_boxes_cust_13`. *(read-api reads 3 of these — the safe 1:1 re-home is already
designed in `t224-analytics-clean-schema-tail.md` Item 1; this reorg subsumes it.)*

### STAY in `public` (justified)
| Object(s) | Why |
|---|---|
| `knex_migrations`, `knex_migrations_lock` | the pinned migration ledger (knexfile `schemaName:'public'`); moving it breaks the migrator |
| `data_quality_event` (24010 rows) | ADR observability event log; cross-cutting, per task directive |
| `h_downtimes_table_with_sector_2`, `h_machine_speed`, `h_piot_day_week_begin`, `h_piot_get_downtimes_per_category_equipment_level_new`, `h_piot_oee_score_teams_table`, `h_shift_hours_per_equipment_packml_topic` | the 6 `h_*` SETOF **carrier tables** (all 0 rows) paired with `h_piot_*` return-type functions; move only *with* their functions in a later serving-consolidation pass |
| `agg_*` / `ca_*` (14 caggs) | legacy caggs retired by #226; STAY (they follow the fact by OID either way) |
| `equipment_values_1min` (0 bytes) | dead plain matz; drop candidate, not a move |
| `equipment_events_man` (90956), `equipment_events_cpac_shadow` (305241), `equipment_events_low_speed` (0) | event side-tables — **silver-tier by role** but entangled with the `equipment_events + _man` merge plan (t224 Item 4); defer to that pass, keep in `public` for now |
| **Shim views** (`equipment_values`, `equipment_events`, `equipment_oee_*`, `production_orders_runtime`, `topic_routing`, `equipment_live_metrics`, `area_oee_*`, `site_oee_*`) | medallion/rename compatibility surface — #228/#224 own their contraction |
| **Debris** (`data_sync_enterprise_06b`, `downtime_sync_enterprise_06`, `production_data_sync_enterprise_06`, `v_13_overview_partial_scrap_rate`, `v_13_overview_takt`) | 0-row per-enterprise fossils in `DEBRIS.exclude`; drop candidates, not moves |
| `monitoramento_execucao_functions`, `pg_stat_statements`, `pg_stat_statements_info` | extension/ops views |

\* **Class A** = present in the F3 snapshot (`db/init-f3/snapshot/00`) and **fake-baselined** in
knex (greenfield gets it from the snapshot, knex skips it). **Class B** = *absent* from the
snapshot; **B/RUN** = additionally created by a genuinely-run knex migration. Class B/RUN is the
crux landmine class (§4).

---

## 3. THE CRUX #1 — db-migrate / knex baseline reconciliation (most important)

### 3.1 How a fresh env is actually built (verified)
Greenfield prod does **not** run `knex migrate:latest` from an empty DB. `compose.production.yml`
runs an ordered one-shot chain:

```
db-init-bootstrap → db-schema-f3 → db-knex-baseline → db-migrate
```

1. **`db-schema-f3`** applies `db/init-f3/snapshot/*.sql` — a curated schema-only **pg_dump of
   staging `packiot_analytics`** (proven to `F3_MISSING=0`). This is where `public`'s tables are
   *born* in greenfield.
2. **`db-knex-baseline`** applies `db/init-f3/knex-baseline.sql` — the industry-standard
   *fake-baseline* (cf. Rails `db:migrate --fake`, Django `--fake-initial`): it pre-seeds
   `knex_migrations` with every migration whose object the snapshot already provides. knex then
   treats them as applied.
3. **`db-migrate`** runs `knex migrate:latest` — which now applies **only** the genuinely
   edge-api-specific migrations the snapshot lacks (the RUN allowlist).

Two gates already enforce this: `scripts/prod-f3-schema-parity-check.sh` (after step 1:
`F3_MISSING=0`) and `scripts/prod-knex-f3-reconcile-check.sh` (after step 3: `CLOBBER=0` +
*every migration is classified FAKE xor RUN*).

### 3.2 Why moving a table to `core`/`app`/`barcode` diverges — and the fix

There are two classes, and each needs a specific reconciliation:

**Class A — snapshot-provided + fake-baselined (all the dims + most config/targets/reasons).**
- *Running env:* `ALTER TABLE public.equipments SET SCHEMA core` — ledger already marks the
  create migration as applied (batch 0), so `migrate:latest` never touches it. ✅
- *Fresh env:* the snapshot must now dump `equipments` **from `core`**, or greenfield loses it.
  Today `capture-f3-snapshot.sh` dumps `--schema=public` **only** → after the move, a re-captured
  snapshot would silently *drop* every moved dim.
- **FIX:** make the snapshot **multi-schema**:
  `pg_dump … --schema=public --schema=core --schema=app --schema=barcode --schema=silver
  --schema=gold …` and have `db-schema-f3` apply them (it already globs `snapshot/*.sql`). The
  knex-baseline is **unchanged** — those migrations stay faked; because the migration's
  `createTable` never runs, its unqualified-CREATE-lands-in-`gold` hazard never fires. This is
  the whole point of fake-baselining: *a faked migration cannot create in the wrong schema
  because it does not execute.*

**Class B/RUN — absent from snapshot + genuinely run by knex (the 5:
`labels`, `sample_boxes`, `scanned_boxes`, `idempotency_keys`, `mirror_replay_dlq`).**
This is the landmine. Their migrations do **unqualified** `createTable`/`CREATE TABLE IF NOT
EXISTS`. If we `SET SCHEMA barcode.scanned_boxes` but leave the migration RUN + unqualified:
- *Fresh env:* `migrate:latest` runs the unqualified create → lands in the **first existing
  schema** on the path (`gold`, hardproofed §8) — **not** `barcode`. Divergence.
- *Running env:* the create is `IF NOT EXISTS`; if the moved table isn't found on the path it
  creates a **new empty duplicate** — exactly the observed `mirror_replay_dlq` bug (§4.3).

**FIX (uniform, recommended):** once the moved table is captured into the multi-schema snapshot,
**reclassify it RUN → FAKE** in `knex-baseline.sql` (remove from `RUN_ALLOWLIST` +
`RUN_NEW_TABLES` in the reconcile-check). Greenfield then gets it from the snapshot in the
correct schema; knex skips it entirely. This preserves the invariant *"fake everything the
snapshot provides."*

**FIX for FUTURE migrations (the durable guardrail):** any new edge-api migration that creates a
`core`/`app`/`barcode` table must **qualify the schema** —
`knex.schema.withSchema('barcode').createTable('scanned_boxes', …)` (the target schema exists by
then, born in the snapshot) — *and* be immediately classified. The reconcile-check already
**FAILS on any unclassified migration**, forcing the human decision. Extend it with a lint that
flags an *unqualified* `createTable` for a non-`public` target.

### 3.3 The knex_migrations ledger stays in `public`
`knexfile.ts` pins `schemaName:'public'` for the ledger (its comment already documents the
`gold`-shadow trap: an unqualified ledger would resolve through the widened path to `gold`, an
empty shadow ledger → every migration replays → `relation already exists`). **Keep it pinned to
`public`.** This is orthogonal to where the *data* tables live — the ledger is bookkeeping.

### 3.4 Public-shim-view is NOT sufficient for the knex baseline
A public shim view (`CREATE VIEW public.scanned_boxes AS SELECT * FROM barcode.scanned_boxes`)
does **not** satisfy a `CREATE TABLE IF NOT EXISTS scanned_boxes` — `to_regclass` sees the view
and the create no-ops, but for a *fresh* env the view doesn't exist yet, so the create still runs
and lands in `gold`. The shim helps the *running-env read path*, not the *fresh-env create path*.
**The fresh-env fix is snapshot + fake-baseline, not a shim.** (The shim's job is §6's
expand/contract on the *running* env only.)

---

## 4. Live evidence — the crux is already broken on staging (§4.3)

```
gold.mirror_replay_dlq    = 1374 rows   (LIVE — writers land here via widened search_path)
public.mirror_replay_dlq  =    0 rows   (empty duplicate shadow — knex/IF-NOT-EXISTS artifact)
gold.mirror_replay_cursor =    2 rows   (live)
public.mirror_replay_cursor =  2 rows   (dup)
gold.user_screen_config   =    0        public.user_screen_config = 0
```

`mirror_replay_dlq` is created by `edge-node-red/db/25-mirror-replay-schema.sql` **and**
bootstrapped by edge-api migration `20260626000001` (`CREATE TABLE IF NOT EXISTS
mirror_replay_dlq`, unqualified, knex-RUN). The medallion move relocated it to `gold`; the
unqualified-create + widened-path interaction left an empty `public` twin. **This is the precise
failure this design prevents** — and a cleanup deliverable: after re-homing to `app` +
reclassifying, drop the empty `public`/`gold` twins (writer-audited, per #186), leaving one
`app.mirror_replay_dlq`.

---

## 5. THE CRUX #3 — `search_path` strategy

**Target DB-level search_path:**
```sql
ALTER DATABASE packiot_analytics
  SET search_path = "$user", core, app, barcode, gold, silver, bronze, public;
```

**Why this order:**
- **Reads resolve to the new home:** unqualified `equipments` → `core`; `users` → `app`;
  `scanned_boxes` → `barcode` (hardproofed §8: with the target schema before `public`, the
  unqualified name resolves to it and any `public` shim is shadowed). This absorbs the entire
  edge-api DAO surface (0 code edits), read-api's unqualified `v_*`/dim reads, and
  sparkplug-decoder's unqualified `packml_register`.
- **`public` last:** during expand/contract a `public` shim coexists with the real object; with
  `public` last, the real object wins for unqualified refs — correct for the *contract* step.
- **Serving views:** add `serving` to the path too if the `v_*` views move there and any
  consumer reads them unqualified (read-api does). Recommended full path:
  `"$user", core, app, barcode, serving, gold, silver, bronze, public`.

**The unqualified-CREATE hazard (hardproofed §8):** an unqualified `CREATE TABLE` lands in the
first *existing* schema after `$user` — with this path, `core`. That is a **footgun for any
future unqualified migration**. Mitigation is layered: (1) fake-baseline every snapshot-provided
table (they don't run); (2) mandate `withSchema()` for future create migrations; (3) the
reconcile-check gate. Do **not** try to "fix" it by putting `public` first — that would break
read resolution of moved objects (they'd resolve to a stale shim).

**Pool recycling:** the DB setting is observed by *new* sessions. Long-lived pooled connections
(edge-api pool, read-api, stream-engine, pgbouncer) cache the old path — **bounce every pool as a
gate step** of each phase (same discipline as the medallion cutover).

---

## 6. THE CRUX #2 — consumer inventory (hard-coded `public.<moved>` refs)

Counted across all services for the full moved-object set (excludes `node_modules`/`dist`/
worktrees):

| Consumer | hard-coded refs | Verdict |
|---|---|---|
| **edge-api `src/` (runtime DAOs/services)** | **0** | ✅ fully search_path-absorbed — **no code change** |
| edge-api `migrations/` (canonical) | 10 | fresh-init only; handled by snapshot + fake-baseline (§3). Notable: `fix_scrap_target_on_conflict` (`public.scrap_targets`), `explode_language_packs_to_translations` (`public.language_packs`/`translations`), `shadow_go_port_schema` (`LIKE public.production_orders`) |
| read-api | **0** | ✅ unqualified `v_*` + `serving.*` qualified — absorbed |
| sparkplug-decoder | **0** | ✅ unqualified `packml_register` etc. — absorbed |
| barcode-service, operator-gateway, oeecloud-fanout, ingest-shim, historian-gateway, edge-transformer, cognito-user-migration | **0** | ✅ none |
| **stream-engine** | **32** | ⚠ LIFT — `internal/bake/bake.go`+`sentinel.go` (dims), `internal/shiftresolver/resolver.go` (`shifts`/`shift_hours`), `internal/reports/boxes_adapter.go`+`boxes_bridge.go` (`box_production_bridges`/`scanned_boxes`), `cmd/port-parity/main.go` (tool), tests. Tables: `equipments`(9), `sites`(3), `equipment_live_{week,month,job,hour}`(12), `production_targets`(2), `label_formats`(2), `shifts`/`shift_hours`/`production_orders`/`box_production_bridges`(1 each) |
| **analytics-sync** | **15** | ⚠ LIFT — `internal/replicate/handlers.go`+`reconcile.go`, `internal/replay/dispatcher.go`+`handlers/natural_key.go`. Tables: `production_orders`(14), `user_logs`(1). All writes `ON CONFLICT (id_enterprise,id_order)` — col-target, shim-safe |
| **mirror-worker-go** | **3** | ⚠ LIFT — `internal/db/staging.go`: `production_orders`(read), `equipments`(read ×2). Reads pass through a shim trivially |
| **edge-node-red** | **100** | forward-port only — **all in `db/*.sql`** (`00-schema` dump, `19-hasura-full-parity`, `20-oee-engine-parity`, `27-refdata-views`, `28-refdata-tables`); fresh-init fragments, most EXCLUDED from greenfield. Reconcile at snapshot-regen, not a live lift |
| front4, reports | **0** | ✅ none |

**Takeaway:** `search_path` erases the *entire* live read/write surface except a **finite 13
Go source files** (stream-engine 8, analytics-sync 4, mirror-worker 1). Those get lifted to
`core.`/`silver.` (or unqualified + path) during the relevant phase, behind a shim, writer-audited
before the shim drops.

---

## 7. Phased expand/contract plan

Sequence by risk: **P1 core → P2 app → P3 barcode → P4 silver-current-state → P5 views.**
Each phase is independently revertible. Every phase follows the same skeleton:
**expand (`SET SCHEMA` + public shim view) → repoint consumers → gate → contract (drop shim)**.

**P0 — prerequisites (one-time):**
1. `CREATE SCHEMA core; CREATE SCHEMA app; CREATE SCHEMA barcode;`
2. Widen the DB `search_path` (§5); bounce pools.
3. Extend `capture-f3-snapshot.sh` → multi-schema; extend `prod-f3-schema-parity-check.sh` +
   `MANIFEST.f3-target` to cover the new schemas; extend `prod-knex-f3-reconcile-check.sh` (§4
   reclassifications). *Do NOT regenerate the snapshot until after the staging cutover settles.*

### P1 — `core` (dims — HIGHEST RISK, the live write path)
1. **Expand:** per dim `ALTER TABLE public.equipments SET SCHEMA core;` (× all §2 core tables),
   with `SET lock_timeout='3s'` + retry (dims are small; the AccessExclusive instant is
   sub-second, but `production_orders` is on edge-api's hot PO-control path — never queue behind a
   long txn). Immediately `CREATE VIEW public.equipments AS SELECT * FROM core.equipments;`
   (auto-updatable read/write shim; **proven** to pass `ON CONFLICT (col)` — §8).
2. **Repoint the 13 hard-coded Go refs** touching core dims (stream-engine bake/shiftresolver/
   reports, analytics-sync replicate/replay, mirror-worker staging) → `core.` or unqualified.
   Deploy service-by-service, watching ingest + PO-write rates flat after each.
3. **Class-B `client_descriptors` / `equipment_validation_shift`** (not knex-owned): move + shim;
   verify sparkplug-decoder onboarding still resolves them (unqualified → absorbed).
4. **Gates:** (a) edge-api PO create/finish + downtime justify endpoints 200 and rows land in
   `core.production_orders`; (b) analytics-sync replicate lands PO rows (col-target ON CONFLICT
   through `core`); (c) read-api `/v1/query` refdata 200; (d) no `42P01` in any service log;
   (e) sparkplug-decoder ingest lag flat (packml_register resolves).
5. **Contract:** after zero-writer log-watch, `DROP VIEW public.<dim>` shims.
6. **Rollback:** `DROP VIEW` shim; `ALTER TABLE core.<dim> SET SCHEMA public`; revert Go pins.
   Symmetric — no data at risk (catalog-only).

**`packml_register` caveat:** a `topic_routing` view already exists over it (t224 Item 4). Moving
the base to `core.packml_register` must keep `public.topic_routing` + a `public.packml_register`
shim resolving correctly. `packml_register` is the hot SparkPlug router — move it **last within
P1**, watching `equipment_values` landing throughout.

### P2 — `app` (auth / i18n / config / ops)
1. **Expand + shim** per §2 app table.
2. **Re-home the `gold`-mislocated trio** (`mirror_replay_cursor`, `mirror_replay_dlq`,
   `user_screen_config`): `ALTER TABLE gold.* SET SCHEMA app;` then **drop the empty `public`
   twins** (writer-audited — confirm the live writer resolves to `app` via the path). Coordinate
   with #233.
3. **Reclassify the knex-RUN app tables** (`labels`, `idempotency_keys`, `mirror_replay_dlq`)
   RUN→FAKE in `knex-baseline.sql` (they'll be in the regenerated multi-schema snapshot).
4. **Gates:** edge-api auth/label/i18n endpoints 200; translations resolve; `function_execution_log`
   writes land; reconcile-check `classify` PASS.
5. **Contract + rollback:** as P1.

### P3 — `barcode`
1. **Expand + shim:** `box_scans` (preserve the `box_scans_no_mutate` append-only trigger — it
   follows the table by OID), `po_box_counter`, `scanned_boxes`, `sample_boxes`.
2. **Reclassify** `scanned_boxes`, `sample_boxes` RUN→FAKE (+ `fix_scanned_boxes`); repoint the
   stream-engine `reports/boxes_*` refs to `barcode.`.
3. **Gates:** barcode-service + operator box-scan flow 200; `v_po_box_totals` still returns
   (OID-bound); append-only trigger still rejects mutation.

### P4 — `silver` (current-state grains — join the existing live tier)
1. `ALTER TABLE public.equipment_live_day SET SCHEMA silver;` (× the 9 `*_live_*` grains).
2. Repoint stream-engine's 12 hard-coded `public.equipment_live_{hour,job,month,week}` refs →
   `silver.` (these are the rollup writers — highest care in this phase).
3. Shim + gate: rollup tick writes land in `silver.*`; mission-control live dashboard 200.

### P5 — views → `serving` / `customer_reports`
1. `ALTER VIEW public.v_operator_* SET SCHEMA serving;` etc. Views are OID-bound to their bases
   (which already moved) — the move is cosmetic namespacing.
2. read-api reads them unqualified → `serving` on the path absorbs; add a `public` shim view only
   if any consumer is found to hard-code `public.v_*` (none found).
3. SAP/`cust_13` views → `customer_reports` (subsumes t224 Item 1's 1:1 re-home; keep the
   hardcoded-tenant CTE bodies — do **not** generalize).

### Post-all-phases
- Regenerate the multi-schema snapshot; run both gates (`F3_MISSING=0`, `CLOBBER=0`,
  classify PASS) against a throwaway fresh container.
- Drop the empty duplicate twins from §4.3.

---

## 8. Hardproof appendix (throwaway `t237_core`/`t237_pub`, created + dropped)

```sql
CREATE SCHEMA t237_core; CREATE SCHEMA t237_pub;
CREATE TABLE t237_core.po (id serial pk, id_enterprise int, id_order int, nm text,
  CONSTRAINT po_uq UNIQUE (id_enterprise, id_order));
INSERT INTO t237_core.po VALUES (…, 3,100,'orig');
CREATE VIEW t237_pub.po AS SELECT * FROM t237_core.po;   -- auto-updatable shim
```

| Probe | Result |
|---|---|
| `INSERT … ON CONFLICT (id_enterprise,id_order) DO NOTHING` **through the shim view** | ✅ passed through; dup swallowed |
| `INSERT … ON CONFLICT (…) DO UPDATE SET nm=EXCLUDED.nm` **through the shim** | ✅ passed through; `orig`→`upd` in base |
| plain `INSERT` through the shim | ✅ landed in `t237_core.po` |
| unqualified `po` resolution with `search_path=t237_core,t237_pub` | ✅ resolves to **`t237_core`** (shim shadowed) |
| unqualified `CREATE TABLE landing_test` with `search_path="$user",t237_core,t237_pub` | ⚠ landed in **`t237_core`** — the *first existing* schema (the CREATE-landing hazard, §3.2/§5) |
| cleanup | `DROP SCHEMA … CASCADE` ×2 → `0` residual `t237%` schemas |

Plus read-only live probes: DB search_path = `"$user", gold, silver, bronze, public`;
70 public tables / 49 views censused; `gold.mirror_replay_dlq`=1374 vs `public`=0 (the crux
landmine); edge-api `src/`=0 hard-coded `public.<moved>`; consumer inventory (§6); knex-baseline
FAKE/RUN sets + reconcile-check classification logic read from source. All hard-coded dim writers
use `ON CONFLICT (col-list)` (shim-safe), never `ON CONSTRAINT`.

---

## 9. Prod forward-port

- **Prod is greenfield-from-snapshot** (`db/init-f3`), not migrate-from-scratch. The reorg
  forward-ports as: (1) the multi-schema `capture-f3-snapshot.sh` + regenerated snapshot,
  (2) the `knex-baseline.sql` reclassifications, (3) the widened `search_path` in
  `compose.production.yml`/migration `02`, (4) the lifted Go pins in the prod-tagged
  stream-engine/analytics-sync/mirror-worker images. Prod's object *names* already match staging
  (post-rename); only their *schema* changes.
- **The Go pin lift ships in the same prod deploy as the DDL** — prod runs the same service
  images; a stale `public.` pin against a moved table = `42P01` at runtime.
- **`knex_migrations` stays `public`** in prod too.
- Sequence prod *after* staging's cutover settles and both gates pass on a throwaway fresh
  container built from the regenerated snapshot.

---

## 10. Risk matrix

| Phase | Top risk | Mitigation | Rollback |
|---|---|---|---|
| P0 | widened path + unqualified-CREATE lands in `core` | fake-baseline (faked migs don't run) + `withSchema()` mandate + reconcile-check gate | narrow path back |
| **P1 core** | `production_orders`/`packml_register` are hot live write/ingest paths; AccessExclusive queues behind a long txn; shim UPSERT semantics | `lock_timeout`+retry; move `packml_register` last watching `equipment_values`; shim proven for `ON CONFLICT (col)`; lift the 13 Go pins before dropping shims | symmetric `SET SCHEMA public` + revert pins |
| P2 app | the `gold`→`app` twin cleanup drops the wrong copy | writer-audit which copy the path resolves to; drop only the confirmed-empty twin | recreate from sibling (`CREATE TABLE … LIKE`) |
| P3 barcode | append-only trigger / RUN→FAKE reclassification | trigger follows by OID; verify reconcile classify PASS | `SET SCHEMA public` |
| P4 silver | rollup writers hard-code `public.equipment_live_*` | lift stream-engine pins first, then move | `SET SCHEMA public` + revert pins |
| P5 views | a hidden hard-coded `public.v_*` consumer | grep found none; add shim if any surfaces | `SET SCHEMA public` |
| All | pooled connections cache old path | bounce every pool as a gate step | n/a |
| Fresh-env | snapshot not regenerated / not multi-schema → greenfield loses moved tables | P0 multi-schema capture + gate on throwaway container before prod | keep old snapshot |

---

## 11. EXECUTION LOG

### Phase 0 — DONE (2026-09-09, PR #1161, deploy run 34338014333 = success)

**The live crux fix — `mirror_replay_dlq` gold/public split-brain, zero-loss:**
- Live writers were `legacy-replicator` (source `legacy-cpack`, 683) + `legacy-replicator-sbx`
  (`legacy-sbxcpack`, 691) = **1374 rows in `gold`**; `public.mirror_replay_dlq` was the empty
  (0-row) shadow. Both replicators build from `services/analytics-sync`; `mirror-worker-go` is
  retired (`profiles:[legacy-comparator]`, off). Source (prod `packiot40`) is SELECT-only and
  never sees the DLQ — it is a DEST(staging)-only table, so `app.`-qualifying it does NOT hit the
  dual-DB "same SQL vs both prod+staging" constraint (that applies only to the P1 dims).
- **Move (expand → bridge → deploy → contract), applied + proven on staging:**
  `CREATE SCHEMA app` → `ALTER TABLE gold.mirror_replay_dlq SET SCHEMA app` (1374 rows + both
  indexes followed) → `DROP TABLE public.mirror_replay_dlq` (empty) → **auto-updatable
  `public.mirror_replay_dlq` shim view** to bridge the in-flight (unqualified) replicators →
  deploy `app.`-qualified code → `DROP VIEW` shim. Final: `app.mirror_replay_dlq (r)` is the SOLE
  copy, 1374 rows, **no gold/core/public shadow**. Shim write-through (INSERT/UPDATE/DELETE→app)
  canary-verified before the deploy.
- **Code lifted** (schema-qualified every DLQ statement to `app.mirror_replay_dlq`):
  `analytics-sync/internal/replicate/dlq.go` (live) + `mirror-worker-go/internal/db/staging.go`
  (dormant) + the `comparator_test.go` SQL-invariant needle. `EnsureDLQ` now
  `CREATE SCHEMA IF NOT EXISTS app` first so a fresh dest self-provisions.

**⚠ NEW HARDPROOF — extends §8 (the load-bearing correction):**
`CREATE TABLE IF NOT EXISTS <unqualified>` checks **ONLY the creation namespace** (first schema on
the path), **not the whole search_path**. Throwaway proof (rolled back, 0 residual): with
`search_path=t237a,t237b` and the real table in `t237b`, `CREATE TABLE IF NOT EXISTS foo` created
an **empty `t237a.foo` shadow**, and the next unqualified `INSERT` then landed in that empty shadow.
**Consequence for the reorg:** the §5 path-widening (`core, app` before `public`) does NOT by
itself make an unqualified `CREATE TABLE IF NOT EXISTS` a no-op — with empty `core` first, any
service that bootstraps its table that way (e.g. analytics-sync `EnsureDLQ`) will re-spawn an empty
shadow in `core`. **Rule going into P1–P5: schema-QUALIFY every bootstrap DDL (`withSchema`/
explicit `schema.table`); do not rely on the widened path to no-op an unqualified IF-NOT-EXISTS
create.** This is why the DLQ fix qualifies rather than leaning on the path.

**Deploy-safety machinery hardened (code, greenfield-forward):**
- `scripts/capture-f3-snapshot.sh`: multi-schema — dynamically adds `--schema=core/app/barcode`
  **only for schemas that exist** (plain-relation schemas, no overlap with the `05-*/10-*`
  timescale supplement layer; `silver/gold/bronze` deliberately EXCLUDED to avoid double-creating
  the medallion hypertables/caggs). Not run this phase (snapshot regen stays deferred).
- `scripts/prod-knex-f3-reconcile-check.sh`: column-integrity census now
  `nspname IN (public,core,app,barcode)` so a SET-SCHEMA'd table stays visible to the gate.

**Green-deploy proof:** staging `packiot_analytics` ledger = 56/56 applied → `db-migrate` no-op
(exit 0); deploy `success`; nothing stuck `created`; fresh `legacy-replicator(+-sbx)` healthy,
DLQ retrier started against `app.mirror_replay_dlq`, 0 error-lines; stream-engine / edge-api /
sparkplug-decoder / ingest-shim all healthy.

**DEFERRED (do NOT skip at their phase — all gated on the snapshot regen, a user-signoff step):**
1. **Snapshot regen + RUN→FAKE reclassification** of the 5 knex-RUN tables (`labels`,
   `sample_boxes`, `scanned_boxes`, `idempotency_keys`, `mirror_replay_dlq`) — each flips only
   *once the multi-schema snapshot provides it in its new schema*. Until then greenfield gets
   `mirror_replay_dlq` from the still-RUN migration (public, empty) + the worker `EnsureDLQ`
   self-heals `app` — functional, one cosmetic empty `public` shadow. Clean up at regen.
2. **`prod-f3-schema-parity-check.sh` + `MANIFEST.f3-target` multi-schema** (P0.3 remainder) —
   left as-is this phase (public-only); extend + regenerate MANIFEST at the snapshot regen.
3. **edge-api migration `20260626000001`** could be `withSchema('app')`-qualified at the greenfield
   reconciliation to drop even the cosmetic shadow. Not done (edge-api is a pinned submodule;
   greenfield is already gated by item 4 below).
4. **PRE-EXISTING classify drift** (NOT this reorg): 15 edge-api migrations added since
   `knex-baseline.sql` was last maintained (`20260728…`→`20260827…`: client_descriptors,
   translations, capture_observations, …) are UNCLASSIFIED → `reconcile-check classify` currently
   FAILS. All 15 ARE applied on staging (ledger 56/56) so staging deploys are unaffected, but a
   greenfield prod build is blocked until they're classified FAKE-xor-RUN. Resolve before any
   greenfield build (own analysis pass; couples with the snapshot regen).

**Move phases remaining (task risk-order, lowest first): P-barcode → P-app → P-silver →
P-views → P-core.** The `SET SCHEMA` + auto-updatable-public-shim + qualified-bootstrap mechanism
is now proven end-to-end on the low-stakes DLQ; reuse it, and remember the IF-NOT-EXISTS
creation-namespace rule above when widening the path for the dim moves.

### Phase P-barcode — DONE (2026-09-09)

Moved `box_scans`, `po_box_counter`, `scanned_boxes`, `sample_boxes` `public → barcode`.
Reversible migrations: `db/migrations/t237-barcode-schema/{01-expand,02-search-path,03-contract,rollback}.sql`.

**Writer census (why this phase needed ZERO service code change):**
- `barcode-service` writes `box_scans` + `po_box_counter` — all **unqualified** (search_path-absorbed);
  **no CREATE TABLE/SCHEMA anywhere** in the service → no bootstrap-shadow risk (the CRITICAL RULE
  has no live trigger here).
- edge-api `samples-dao.ts` writes `scanned_boxes` + `sample_boxes` — all **unqualified**.
- **stream-engine has 0 refs** to the 4 tables (plan §6 over-counted — the `reports/boxes_*` refs are
  to `box_production_bridges` [core] + a `public.label_formats` *comment*, none of the 4 barcode tables).
- read-api touches them only via `public.v_po_box_totals` (OID-bound, unaffected). No Go lift this phase.

**Hardproofs (throwaway `t237_bc`/`t237_pub`, 0 residual):** the `po_box_counter`
`ON CONFLICT (id_production_order) DO UPDATE SET last_label_seq = GREATEST(po_box_counter.last_label_seq,
EXCLUDED.last_label_seq), total_qty = po_box_counter.total_qty + $` — a **table-qualified SET ref** —
passes through an auto-updatable shim view (base went 10→17, `GREATEST(5,3)=5`). Confirms the shim is
write-safe for the transition window.

**Sequence gotcha caught live (first expand attempt failed + atomically rolled back):**
`ALTER TABLE … SET SCHEMA` **auto-moves owned sequences** (serial `scanned_boxes_id_seq`/
`sample_boxes_id_box_seq` + the `box_scans` IDENTITY seq `box_scans_box_scan_id_seq`). An explicit
`ALTER SEQUENCE public.scanned_boxes_id_seq SET SCHEMA barcode` then errors `does not exist` (already
followed). **Rule: never move owned sequences explicitly after a table `SET SCHEMA` — they follow by
OID.** Removed the explicit moves; re-expand clean. (Contrast the plan's §7 "SET SCHEMA does NOT move
owned sequences" claim — that is WRONG for *owned* serial/identity sequences; it's only true for a
standalone sequence with no ownership dependency.)

**Sequence:** expand (`SET SCHEMA` ×4 + 4 auto-updatable public shim views, atomic, `lock_timeout=3s`)
→ widen db `search_path` to `"$user", gold, silver, bronze, barcode, public` (barcode **after** the
medallion schemas → unqualified-CREATE landing stays `gold`, no NEW footgun this phase) → **restart
`stack-pgbouncer-1`** (transaction pooling → server conns cache the connect-time default; a client-app
restart would NOT recycle them — pgbouncer is the only bounce lever) → gate → contract (drop 4 shims;
barcode is DEST-only, no dual-DB reader).

**Gates — all green (canary run THROUGH pgbouncer, the real service path):**
effective `search_path` carries `barcode`; unqualified `scanned_boxes`/`box_scans`/`po_box_counter`
all resolve to schema `barcode`; an **unqualified** canary INSERT (rolled back) lands in `barcode`;
post-contract `to_regclass('public.scanned_boxes')` = NULL (shim gone, **no shadow re-spawned**);
`v_po_box_totals` still returns 3; rows preserved (`box_scans`=32, `po_box_counter`=3); 0 `42P01`
across barcode-service/edge-api/stream-engine/analytics-sync/sparkplug-decoder; all healthy.
(One pre-existing stream-engine WARN — `report_shift_enterprsie_06` `sync06` fossil — is unrelated
DEBRIS, predates this phase.)

**Final state:** the 4 tables live SOLELY in `barcode` (+ their indexes/triggers/3 sequences); `public`
holds NONE of the 4 names. Fully reversible via `rollback.sql` (+ pgbouncer restart).

**DEFERRED (unchanged, gated on the snapshot-regen user-signoff):** RUN→FAKE reclassification of
`scanned_boxes`/`sample_boxes` (+ `fix_scanned_boxes`) in `knex-baseline.sql` — on STAGING the tables
are already applied (ledger-gated → migrate never re-runs → no fresh public shadow observed), so the
move is functional now; the reclassification only matters for a greenfield build from the regenerated
multi-schema snapshot.

### Phase P-app.1 — DONE (2026-09-09) — the 13 deploy-free pure-public tables

Moved `users`, `user_roles`, `user_logs`, `translations`, `tenant_translations`, `language_packs`,
`pages`, `dashboard_config`, `labels`, `label_formats`, `idempotency_keys`, `function_execution_log`,
`capture_observations` `public → app`. Reversible migrations:
`db/migrations/t237-app-schema/{01-expand-public13,02-search-path,03-contract-public13,rollback-public13}.sql`.

**Why deploy-free (the phase-splitting insight):** of the 15 P-app tables, only the 2 GOLD→APP
self-heal tables (`mirror_replay_cursor`, `user_screen_config`) have a running-service unqualified
`CREATE TABLE IF NOT EXISTS` (analytics-sync `internal/replicate/cursor.go`; read-api
`cmd/refdata-api/query.go`). The other 13 are created only by ledger-gated edge-api knex one-shots
(never re-run on staging; edge-api app runs `node dist/main`, not migrate) → a mere pgbouncer bounce
re-runs no bootstrap DDL → **no shadow, no code deploy needed.** So P-app was split: P-app.1 = the 13
(this entry, DDL-only), P-app.2 = the 2 self-heal tables (needs the qualify-+-deploy pattern).

**Census proofs:** all writers unqualified (edge-api DAOs, read-api `v_user_menu`-family reads,
sparkplug-decoder `capture_pg.go` INSERT); no shim-unsafe `ON CONSTRAINT` on any app-table writer
(the grep hits are core-table comments); **no function references any of the 13 by table name** — the
`public.get_report_shift_enterprsie_06c` regex hit was the CTE named `labels`, not the table (the
fossil references only core/silver/gold tables + is itself dead: `sync06` already errors on a missing
`report_shift_enterprsie_06`).

**Sequence:** expand (`SET SCHEMA` ×13 + 13 auto-updatable public shim views, atomic) → widen path to
`"$user", gold, silver, bronze, barcode, app, public` (**`app` after `gold`** → the 2 not-yet-moved
GOLD→APP tables keep resolving to their live `gold` copy; unqualified-CREATE landing stays `gold`) →
restart `stack-pgbouncer-1` → gate → contract (drop 13 shims).

**Gates — all green (canary THROUGH pgbouncer):** all 13 resolve to `app`; `mirror_replay_cursor` +
`user_screen_config` STILL resolve to `gold` (P-app.2 pending — correct); unqualified canary INSERT
(`function_execution_log`) lands in `app`, rolled back clean; post-contract public residue = NONE;
data preserved (`users`=9, `user_logs`=31247, `translations`=2124, `capture_observations`=91, `pages`=67);
0 `42P01` across edge-api/read-api/sparkplug-decoder/analytics-sync/stream-engine; all healthy.
Final: `app` holds 14 tables (the 13 + P0's `mirror_replay_dlq`); NONE of the 13 remain in `public`.

### Phase P-app.2 — DONE (2026-09-09, PR #1162, deploy run 34342284154 = success)

Re-homed the 2 GOLD→APP self-heal tables `mirror_replay_cursor` + `user_screen_config`
`gold → app` (each was the §4.3 split-brain: LIVE copy in `gold`, stale/redundant twin in
`public`). Reversible migrations:
`db/migrations/t237-app-schema/{04-expand-goldapp2,05-contract-goldapp2,rollback-goldapp2,06-restore-stream-engine-public-shims}.sql`.

**Pre-move census (live):** `gold.mirror_replay_cursor`=2 rows LIVE (advancing, last_run_at
seconds-fresh) vs `public.mirror_replay_cursor`=2 rows STALE (frozen ~7h — a pooled conn's old
path artifact); `user_screen_config` both 0 rows (gold = read-api's `ensureSchema` home). No
view/function depends on either (pg_depend/pg_rewrite clean). `EnsureCursor`(replicate) +
`EnsureDLQ` run ONCE at loop start (loop.go:65), not per-tick → the running OLD container never
re-fires the bootstrap create during the expand→deploy window.

**Code lift (schema-qualify every ref + bootstrap to `app.`):** analytics-sync
`internal/replicate/cursor.go` (cursorDDL → `app.mirror_replay_cursor` + prepend
`CREATE SCHEMA IF NOT EXISTS app`) + `internal/replay/cursor.go`; mirror-worker-go
`internal/db/staging.go` (4 dormant refs, parity); read-api `cmd/refdata-api/query.go`
(ensureSchema bootstrap + screen-config read/write + the dashboard-config override CTE →
`app.user_screen_config`). All 3 services build + test green; `dashboard_config_test`
`strings.Contains(sql,"user_screen_config")` still matches `app.user_screen_config`.

**⚠ HARDPROOF-refinement over the P0 runbook — the shim goes in `gold`, not `public`:** with the
path `"$user",gold,silver,bronze,barcode,app,public`, the CREATION NAMESPACE of an unqualified
create is `gold` (first schema). A `public` shim does NOT guard it (a create still lands in
`gold`). The correct guard is a **`gold` shim VIEW** of the moved name: throwaway-proven that
`CREATE TABLE IF NOT EXISTS <name>` with a same-named VIEW in the creation namespace NO-OPs
(relkind stays `v`) AND gold-first unqualified runtime access flows through the view → app. Used
`gold` guard views on both tables; dropped at contract.

**Sequence:** canary shim write-through (throwaway, 0 residual — both `ON CONFLICT` upserts +
read-api's exact `DO UPDATE SET config=EXCLUDED.config` pass through the view to base) → EXPAND
(`04`: drop stale public twins → `ALTER gold.<t> SET SCHEMA app` (live rows+indexes follow by
OID) → `gold` guard views; cursor advanced 2748704→2748721 mid-move, no data loss) → deploy
(PR #1162, CI green, all healthy, nothing stuck `created`) → GATE → CONTRACT (`05`: drop gold
guard views).

**Gates — all green:** deployed analytics-sync read the EXISTING cursor `2748755` (NOT a
cold-start reseed — proves the qualified `SELECT FROM app.mirror_replay_cursor` found the live
row) and advances it (→2748764, seconds-fresh); read-api screen-config **PUT→200, GET→200**
returning the written JSON (X-Api-Key cid 3, from `QUERY_API_KEYS`), the row landing in
`app.user_screen_config` (probe cleaned up); no gold/public shadow re-spawned (post-contract:
both tables `app:r` ONLY); 0 `42P01` in analytics-sync/read-api/sparkplug-decoder; ingest fresh
(silver.equipment_values 3s); row counts preserved (user_logs 31247, cursor 2).

**⚠ REGRESSION CAUGHT + FIXED — P-app.1 stranded 2 stream-engine public-qualified refs:**
stream-engine's `flows.Dest` HARDCODES `EvSchema="public"` AND `RefSchema="public"`
(`internal/flows/flows.go:52,57`) — it does NOT resolve via search_path; it explicitly qualifies
`public.<t>` through `%[1]s`/`%[2]s`. The medallion deliberately KEPT `public` shims
(public.equipment_values→silver, …) for exactly this engine. P-app.1 moved `label_formats` +
`user_logs` public→app **and dropped their public shims** — but stream-engine still references
them public-qualified: `reports/boxes_adapter.go` `FROM %[2]s.label_formats` (LIVE — "boxes pass
failed: relation public.label_formats does not exist" every 5-min tick since P-app.1's contract)
and `pocontrol/{events_justify,setup_userlog}.go` `INSERT INTO %[1]s.user_logs` (LATENT — fires
on a PO justify/setup event through the Go port). **Fix (`06`, no deploy):** restored
auto-updatable `public.label_formats` + `public.user_logs` shim views over their `app` bases
(INSERT-through proven for user_logs). Boxes job recovered (0 failures on the next tick).
**This invalidates the reorg §6 premise "search_path absorbs stream-engine except a finite Go-pin
set" for the public-qualified Dest** — see the two carry-forwards below.

**CARRY-FORWARD for P-silver + P-core (load-bearing):**
1. **stream-engine is public-qualified, NOT search_path-absorbed.** ANY table it touches
   (equipment_values/events [silver, shimmed by medallion], the `*_live_*` grains [P-silver],
   equipments/sites/packml_register/production_targets/shifts/box_production_bridges [P-core],
   label_formats+user_logs [app, now shimmed]) needs a **persistent `public` shim** UNTIL
   stream-engine's Dest is re-pointed. **Do NOT contract a public shim for any stream-engine-read
   table without first lifting stream-engine + deploying.** P-silver MUST keep public shims for
   the `equipment_live_{hour,job,month,week}` grains (stream-engine hardcodes them) until the
   rollup writer is re-pointed.
2. **The `label_formats` shim cannot be dropped at P-core by flipping RefSchema.** stream-engine
   uses ONE `RefSchema` for both `label_formats`(app) and `equipments`(→core) — they will live in
   different schemas, so a single RefSchema can no longer serve both. The eventual stream-engine
   lift must give `label_formats` its own schema arg (or keep the public shim permanently).

**Final state:** `mirror_replay_cursor` + `user_screen_config` live SOLELY in `app`; `label_formats`
+ `user_logs` = `app` base + intentional `public` shim view (stream-engine bridge). Fully
reversible (`rollback-goldapp2.sql` + revert Go pins; `06` rollback gated on the stream-engine lift).

### Phase P-app.2 — original runbook (superseded by the DONE entry above)

`mirror_replay_cursor` (gold=2 rows LIVE, public=2 stale dup) + `user_screen_config` (gold + public
dup). Both are the §4.3 split-brain: the live copy is in `gold` (path resolves gold-first), `public`
holds a stale duplicate. This is the ONLY P-app work that needs a service redeploy, because each has a
running-service unqualified `CREATE TABLE IF NOT EXISTS` that (per the P0 creation-namespace rule)
would re-spawn a shadow on the service's next restart if left unqualified.

**Runbook (mirror the P0 `mirror_replay_dlq` move exactly):**
1. **Lift code — schema-qualify to `app.` (the CREATE + every ref):**
   - `services/analytics-sync/internal/replicate/cursor.go` — `cursorDDL` `CREATE TABLE IF NOT EXISTS`
     → `app.mirror_replay_cursor` (+ prepend `CREATE SCHEMA IF NOT EXISTS app`); SELECT/INSERT/UPDATE.
   - `services/analytics-sync/internal/replay/cursor.go` — SELECT/INSERT/UPDATE refs.
   - `services/mirror-worker-go/internal/db/staging.go` — the 4 dormant refs (retired
     `legacy-comparator` profile, but qualify for greenfield parity, as P0 did for dlq).
   - `services/read-api/cmd/refdata-api/query.go:487` — `CREATE TABLE IF NOT EXISTS user_screen_config`
     → `app.user_screen_config` (+ its read/write refs).
2. **Expand (per table): drop the stale `public` dup → `ALTER TABLE gold.<t> SET SCHEMA app` (the LIVE
   copy) → auto-updatable `public.<t>` shim view** (bridges in-flight unqualified writers, since with
   the current path `app` is behind `public`… actually `app` is now BEFORE `public` post-P-app.1, but
   `gold` is before `app` — so once the gold copy moves and the public dup is dropped, unqualified
   resolves to `app`; the shim is the bridge for the pgbouncer-recycle instant). Canary the shim
   write-through first (INSERT/UPDATE) as P0 did.
3. **Deploy** analytics-sync + read-api (Go build → commit → push staging → CI). The redeploy restarts
   with `app.`-qualified bootstrap → no gold/public re-shadow.
4. **Gate:** analytics-sync replay/replicate cursor advances against `app.mirror_replay_cursor`;
   read-api operator screen-config reads/writes 200; `mirror_replay_cursor`/`user_screen_config`
   resolve to `app`; no gold/public shadow re-spawned; 0 `42P01`; ingest healthy.
5. **Contract:** drop the `public` shim views. Final: each lives solely in `app`, gold+public twins gone.

**Current safe state (no regression):** the 2 tables remain in `gold` (live) with stale `public` dups
— exactly as before this task; analytics-sync/read-api unqualified refs still resolve gold-first, so
they are fully functional. The split-brain is pre-existing, not introduced here.

**Move phases still remaining after P-app.2: P-silver → P-views → P-core.**
```

### Phase P-views — DONE (2026-09-09)

Moved the 15 remaining public *views* to their real homes: **10 → `serving`**
(`production_information`, `v_entities_per_user_role`, `v_entities_per_user_role_operator`,
`v_events_2`, `v_menu_per_user_role`, `v_operator_entities_2`, `v_operator_po_details_3`,
`v_operator_po_list_setup_4`, `v_po_box_totals`, `v_report_downtimes`) and **5 →
`customer_reports`** (`equipment_boxes_cust_13`, `v_13_site_deb_sap_report`,
`v_piot_production_data_sync_cust6`, `v_sap_report_data_sync_customer_13`,
`v_sap_report_data_sync_customer_13_deb`). Reversible migrations:
`db/migrations/t237-views-schema/{01-expand,02-search-path,03-contract,rollback}.sql`.

**DEPLOY-FREE (like P-app.1) — the consumer census proves zero code change:**
- **read-api reads all 15 UNQUALIFIED** (`main.go` v_operator_*; `datasets.go` v_entities_/
  v_menu_/v_report_downtimes; `external*.go` v_13_/v_sap_/v_piot_) — **no `public.v_*`
  hard-code anywhere** → fully search_path-absorbed once `serving`+`customer_reports` join the
  path and pgbouncer recycles. read-api also has **no per-session `SET search_path`** (relies on
  the DB default via `DB_HOST=pgbouncer`), so the bounce alone repoints it.
- **stream-engine: 0 real SQL refs** — the only hits (`reports/boxes_*.go`, `config.go`) are
  *comments* naming `equipment_boxes_cust_13` / the retired `upsert_equipment_boxes_cust_13`
  function; no `FROM`/`JOIN` on any of the 15. (The stream-engine public-qualified-Dest
  carry-forward from P-app.2 does NOT bite here — Dest only qualifies fact/dim tables, never a
  `v_*` view.)
- **`serving.events_timeline_full`** reads `v_events_2` **unqualified** → absorbed via the path
  (bridged by the public shim during the recycle window; verified valid post-move).
- **Superset**: repo datasets are all on the `bi` schema (10) + one `public.ev_all` historian
  gateway; **no `bi` view/dataset depends on any of the 15** (pg_depend clean) → Superset
  unaffected. No dataset schema repoint was needed.

**DB-internal dependency census (all OID-bound, move together, stay valid):** the only
inter-object deps among the 15 are intra-set — `equipment_boxes_cust_13` ← `v_sap_report_data_sync_customer_13`(+`_deb`);
`v_operator_entities_2` ← `v_entities_per_user_role_operator`; `v_sap_..._deb` ← `v_sap_...` — all
land in the same schema. `ALTER VIEW … SET SCHEMA` is a catalog-only OID flip; dependents' stored
rewrite rules reference the base by OID (not the `public.` text), so they never break.

**Security:** all 15 are owner=postgres, `security_invoker=off` (definer/superuser; tenant
isolation is the read-api `WHERE id_enterprise=$1`, NOT view RLS) → plain `public.<v> AS SELECT *
FROM <newhome>.<v>` shims match the semantics exactly.

**Sequence:** expand (`SET SCHEMA` ×15 + 15 same-named auto-updatable public shim views, atomic,
`lock_timeout=3s`) → widen db `search_path` to `"$user", gold, silver, bronze, barcode, app,
**serving, customer_reports**, public` (both new schemas AFTER the medallion/dim schemas + BEFORE
public → unqualified-CREATE landing stays `gold`, **no new footgun**; both are views-only schemas
anyway) → **restart `stack-pgbouncer-1`** (transaction pooling → server conns cache the
connect-time default) → gate → contract (drop 15 shims).

**Gates — all green (canary + HTTP THROUGH the real read-api→pgbouncer path):**
- effective `search_path` through pgbouncer carries `serving`+`customer_reports`;
- all 15 unqualified names resolve to their new home (`relnamespace::regnamespace` = serving ×10 /
  customer_reports ×5), shadowing the shims;
- **real SELECT execution** (unqualified, through pgbouncer): serving views return data,
  customer_reports SAP views return 0 rows (empty, tenant-scoped) — **zero errors**;
- **HTTP 200 end-to-end** on `/v1/operator-entities`, `/v1/operator-po-list`,
  `/v1/entities-per-user-role` (X-Api-Key cid 3, CPACK data returned);
- 0 `42P01`/does-not-exist across read-api/stream-engine/analytics-sync/sparkplug-decoder/edge-api/
  barcode-service/operator-gateway; all healthy; ingest lag 5s; stream-engine boxes tick clean.
- **post-contract:** unqualified still resolves to serving/customer_reports (shim-free, path-only),
  `public` residue = **0**, no shadow re-spawned, HTTP still 200.

**Final state:** the 15 views live SOLELY in `serving` (10) / `customer_reports` (5); `public`
holds none of the 15 names. Fully reversible via `rollback.sql` (+ pgbouncer restart).

**DEFERRED:** none specific to P-views (no snapshot/knex reclassification — views are not knex-owned
and are absent from the F3 fake-baseline). Note: the multi-schema snapshot capture (P0 deferred
item) must add `--schema=serving --schema=customer_reports` at the eventual regen so greenfield is
born with these views in place; `serving`/`customer_reports` already existed pre-P-views (serving
~40 fns, customer_reports 4 tbl) so they are captured schemas either way.

**Move phases still remaining: P-silver → P-core** (per task risk-order; the stream-engine Dest
per-schema refactor precedes P-silver/P-core as the enabler).

### Phase 1 — stream-engine Dest per-schema REFACTOR (2026-09-09)

**The enabler.** `flows.Dest` previously carried only `EvSchema`/`RefSchema`, both hard-coded
`"public"` for the analytics dest — every flow table hid behind a `public` shim view, and (per the
P-app.2 carry-forward) the engine is **public-qualified, NOT search_path-absorbed**. This phase
peels `Dest` into per-LAYER knobs so each table resolves to its real home and its public shim can
drop — the prerequisite for P-silver (grains→silver), P-core (dims→core), #233 (grains→gold),
#228 (facts→silver), #239 (caggs).

**New `Dest` shape** (`internal/flows/flows.go`) — the analytics (staging) dest values in brackets:
- `EvSchema` [public] — the un-re-homed flow residue: legacy caggs (`ca_agg_equipment_values_1min/_1hour`),
  event side-tables (`equipment_events_cpac_shadow/_man/_low_speed`), `data_quality_event`; also the
  `RunProvision` search_path anchor.
- `RefSchema` [public] — the dimension plane (equipments, sites, areas, production_orders,
  packml_register, shifts, shift_hours, production_targets, box_production_bridges, targets). **P-core
  flips this to `core`.**
- `SilverSchema` [silver] — facts + silver caggs (equipment_values, equipment_events,
  equipment_live_metrics, equipment_metrics_/categorical_).
- `GoldSchema` [gold] — OEE grains (equipment_oee_*, area_oee_*, site_oee_*, production_orders_runtime).
- `GrainSchema` [public] — current-state grains (equipment_live_*, area_live_*, site_live_day).
  **P-silver flips this to `silver`.**
- `AppSchema` [app] — label_formats, user_logs.

**What was repointed this phase (the app-shim drop + the P-silver enabler):**
- **App peel (the Phase-1 hard contract):** `reports/boxes_adapter.go` `label_formats`→`AppSchema`;
  `pocontrol/{events_justify,setup_userlog}.go` `user_logs`→a new `appSchema` param threaded from the
  ingest `route` (which gained `app`/`grain` fields). This lets the two P-app.2 `06` public shims drop.
- **Grain peel (the P-silver enabler):** every current-state-grain SINK write in `uns/uns.go`,
  `uns/current_rest.go`, `pocontrol/setup_userlog.go` (equipment_live_job) now qualifies with
  `GrainSchema` (a dedicated placeholder), leaving the OEE/cagg SOURCE reads on `EvSchema`. With
  `GrainSchema="public"` this is byte-identical NOW; P-silver flips it to `silver` in one place
  (Dest + `routeForSource`).
- **Silver peel (reports):** `boxes_adapter`/`boxes_bridge` read `equipment_values` from `SilverSchema`.
- `pocontrol` threads `appSchema`/`grainSchema` (Execute→execute→executeEvents/executeSetupOrUserlog).

**DELIBERATELY DEFERRED — the rollup hot-path oee→gold / facts→silver requalification.** The
`rollup/*.go` OEE constants were **left untouched** (still `EvSchema="public"` → public shims →
gold/silver). Rationale: (1) it is **byte-identical** to the current public-shim resolution (a shim
is a pass-through `SELECT * FROM gold.<t>`), so the gate shows no change either way; (2) each such
constant conflates up to FOUR layers under one `%[1]s` (e.g. `hourSpeedSQL` touches ca_agg[public],
equipment_values[silver], equipment_oee_hourly[gold], equipments[ref]), so the peel is intricate
placeholder surgery on the LIVE OEE engine; (3) its only benefit accrues to the SEPARATE #228/#233
tickets, and #233 also needs `RunProvision`'s search_path lifted (it writes the OEE grains through
the same public shim via `SET search_path TO public`). **Safety property that makes this deferral
clean: EvSchema stays `"public"`, so every un-peeled ref still resolves through its public shim to
the SAME physical table — the partial peel is byte-identical and fully deployable.** #228/#233 flip
`SilverSchema`/`GoldSchema` (already defaulted correctly on the dest) per-constant later.

**GATE (byte-identical gold OEE, absolute frozen window `[2026-08-10, 2026-09-09 00:00Z)`):**
`gold.equipment_oee_shift` 12944 rows md5 `2b6d88c665e378f17f2806154b5f53d1`;
`gold.equipment_oee_hourly` 121662 rows md5 `2df7b7d886224414809dbbf0d0b66b26` (pre-deploy baseline;
re-hashed post-deploy — see below). `go build`/`go vet`/`go test ./...` all green (rewrote the
`uns` SQL-builds golden for the new grain arg + the pocontrol `Execute` signature ripples clean).

**Contract:** `db/migrations/t237-stream-engine-schema/01-contract-app-shims.sql` drops
`public.label_formats` + `public.user_logs` (reverts P-app.2 `06`) AFTER the deploy is healthy.

**Remaining after Phase 1: P-silver (grains→silver, flip GrainSchema) → P-core (dims→core, flip
RefSchema).** The deferred rollup oee/facts requalification is owned by #228/#233 (knobs in place).
