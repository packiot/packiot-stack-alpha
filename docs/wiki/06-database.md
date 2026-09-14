# Database & Data Model

A single **PostgreSQL 16 + TimescaleDB** cluster. There is **no `edge-api/schema.sql`** in
this repo despite older references — the authoritative schema is `edge-api/migrations/*.ts`
(Knex; control-plane tables) + `db/migrations/*` (medallion schema moves, caggs, triggers).
Where they disagree, trust the live DB.

> **This page is the data-model reference. For operating the DB** — topology, access,
> continuous-aggregate policies, retention, backup, runbooks — see the
> **[DBA Guide](13-dba-guide.md)**.

## One database, schemas not planes (ADR-0056)

Live app data lives in **one** database, **`packiot_analytics`**, separated by **schema**
(a **medallion** model), NOT split across databases. The old F1/F3 two-database shadow
(`packiot` vs `packiot_analytics`/`packiot_shadow`) is **retired** — `packiot` is the
frozen legacy monolith, out of the pipeline (#225-gated retirement). The schema planes:

| Plane | Schemas | Holds |
|-------|---------|-------|
| **medallion** | `bronze` → `silver` → `gold` | raw (`*_raw`, `box_scans`) → cleaned facts (`equipment_values`, events, live grains, rollup caggs) → OEE/business (`equipment_oee_*`, `production_orders_runtime`) |
| **domain** | `core` (dims), `identity` (authZ), `config` (i18n), `ops` (plumbing) | the non-telemetry entities |
| **serving** | `serving` (invoker/RLS), `bi` (definer), `customer_reports` | read surfaces for front4/operator/Superset/exports |
| **public** | `public` | genuine transactional tables + **retiring compat shims** — new code must NOT target `public.*` |

The DB `search_path` puts the real schemas ahead of `public`, so **bare** refs resolve to
real tables; only a qualified `public.X` hits a shim. **Drift risk:** columns were added
out-of-band historically (e.g. `users.id_user_cognito`) — check the live DB, don't assume.

## Hierarchy tables

```
enterprises ─1:N▶ sites ─1:N▶ areas ─1:N▶ equipments ─self-FK▶ equipments
```
Every level carries denormalized `id_enterprise`/`id_site`/`id_area` back-refs.

- **enterprises** — `id_enterprise`, `nm_enterprise` (note `nm_`, **no `cd_` column**),
  `api_key` (minted `randomUUID()`, never returned by read DAOs), `week_begin/day_begin/
  week_size`, `timezone`, `active`, `scrap_calc_type`.
- **sites / areas** — `nm_site`/`nm_area`, hierarchy FKs, `week_*` (site is the shift
  fallback), `active`. `areas` also carries counter-role columns
  `id_infeedcounter`/`id_outfeedcounter`/`id_rejectscounter` (note plural `rejects` here
  vs singular on packml_register — a real naming inconsistency).
- **equipments** (~50 cols) — `tp_equipment` (**1=machine, 2=sector, 3=line**),
  `id_parentequipment` (self-ref), `lead_machine` (the machine that generates a line's
  downtime events), `gross_machine`/`scrap_machine` (line counter-role sources; identity
  `gross=net+scrap`), `status_type`, `ideal_speed`/`production_speed`,
  `stop_threshold_time` (often NULL platform-wide), `exclude_idle_from_availability`/
  `idle_timeout_seconds` (storage only — worker not yet wired to read them), `active`.
  A partial unique index blocks two active same-name-same-type rows while allowing a
  line + a single-machine member to share a name.

> **Equipment config enums (resolved).** The coded integer columns on `equipments` /
> `enterprises` / `production_orders` / `shift_hours` are decoded in the
> **[Concepts enum reference](08-concepts.md#coded-field-values-the-enum-reference)** —
> `scrap_calc_type` (2 = /net, 0&1 = /gross), `net_production_type` (0 = sensors,
> 1 = scanned boxes), `status_type` (0 = instant, 5 = 5-min/CPAC — never 4),
> `production_speed` vs `ideal_speed`, `conversion_factor` vs the unused `multiplier`,
> and `shift_hours.day_number` (**1 = Monday … 7 = Sunday**). The legacy PLC/state
> columns (`id_plc`, `id_equipment_type`, `id_packed_counter`, `sector_equipment_*`,
> `id_equipment_state_*`, `id_counter_status`) are **soft references / raw indices, never
> FKs**, and are NULL platform-wide. The live DB now carries every one of these as a
> resolved column `COMMENT` (migration `db/migrations/t279-core-enum-column-resolve`) —
> read them with `\d+ core.equipments`, pgweb, or CloudBeaver.

**Phantom code columns:** there is **no `cd_enterprise`/`cd_site`/`cd_area`** — only
`nm_*`. (`equipments` does have `cd_equipment`.) Code referencing those cd_ columns
references something that doesn't exist.

**`active` soft-delete** is enforced in edge-api reads (sites/areas/equipments/tree DAOs
filter `active=true`) but **not universally downstream** — don't assume it's enforced by
stream-engine/reports until verified.

## core.topic_routing — SparkPlug topic routing (was `packml_register`)

Maps `packml_topic` (UNIQUE) → `id_equipment` so the pipeline can attribute metrics. Now
`core.topic_routing` (renamed from `packml_register`; `core.packml_register` remains as a
compat view). CS-Admin creates all entries; **the decoder/rollup only processes a topic
when `active=true`.** `id_unit` (= `id_equipment` for machines) looks up PackML param 30700.
Counter-role columns `id_infeedcounter`/`id_outfeedcounter` — **collision-sensitive** (the
Phase-9 incident: several count-indices equal a real `id_equipment`, so `COUNTER_ROLES_FROM_DB`
must stay `false` while these hold count-indices). The **reject** counter role lives at the
**area** level (`core.areas.id_rejectscounter`), not here — many tenants leave it NULL and
rely on co-located `ProdDefectiveCount` / `***TRIG_CS` flow-derived scrap.

## The OEE aggregate cascade (data plane)

```
silver.equipment_values  (raw hypertable, PK(id_equipment, ts_value), 90-day hot — see the DBA Guide)
   │ time_bucket → TimescaleDB continuous aggregates
   ▼
silver.equipment_metrics_{1min,10min,1hour,1day} + silver.equipment_categorical_{1min,10min,1hour}
   │ stream-engine rollup jobs (Go)
   ▼
gold.equipment_oee_{shift,hourly,daily,weekly,monthly}  ·  gold.area_oee_* / site_oee_*
   │  oee, oee_a/p/q, running/stopped/idle_time, gross/net/scrap, recalc_needed
   ├─▶ gold.production_orders_runtime  (GiST EXCLUDE: no overlapping runs per equipment)
   │      └─▶ core.production_orders  (status 1/2/3/4, denormalized OEE, UNIQUE(id_enterprise,id_order))
   └─▶ silver.equipment_live_* (current-state grains) → serving.production_information (live "now")
```

- `equipment_values` pairs each metric with a `_quality` column.
- **All caggs need a refresh policy** — a policy-less cagg has a frozen watermark and the
  rollup re-aggregates all raw every tick → eventual statement-timeout + silently stale OEE
  (the CPACK #196 outage). Check the watermark first when OEE degrades. See the
  [DBA Guide §3](13-dba-guide.md).
- `recalc_needed` (partial index `WHERE recalc_needed`) is the dirty flag driving
  incremental rollups. **Child sub-meters never compute OEE**, so a rollup asymmetry leaves
  them permanently flagged — that backlog is *phantom* and client-invisible; measure real
  backlog on `id_parentequipment IS NULL` equipment only.
- **Live-snapshot gotcha:** greyed dashboard tiles usually mean the current-state grains /
  `serving.production_information` went stale because a refresher wasn't running — a
  live-snapshot, not a fresh aggregate.

### Medallion object inventory

Every object carries a DB `COMMENT` (read `\d+ <schema>.<obj>` / pgweb / CloudBeaver for
column detail). One-liners by layer:

**`bronze`** (raw, append-only):

- `equipment_values_raw` / `equipment_events_raw` — ADR-0036 flag-gated **raw dual-write** (immutability-triggered; the untouched landing copy).
- `scanned_boxes` / `box_scans` / `sample_boxes` — barcode box-scan capture (per PO + equipment).

**`silver`** (cleaned facts + rollup continuous-aggregates):

- `equipment_values` — the raw production-reading hypertable (PK `id_equipment,ts_value`; 90-day hot). **THE source fact.** Each metric paired with a `_quality`.
- `equipment_events` — downtime / machine-status events (2-year hot). `equipment_events_{man,low_speed,cpac_shadow}` — manual downtimes / low-speed / CPAC shadow.
- `machine_state` — decoded PLC state stream.
- `agg_equipment_values_{1min,1hour}` + `equipment_categorical_{1min,1hour}` — TimescaleDB **continuous aggregates** (numeric / categorical), the rollup feedstock.
- `equipment_metrics_1min` — per-minute derived metrics. `ca_discrete_changes_1s` — CPAC 1-s discrete-change feed. `ca_equipment_boxes_1s` — 1-s box counts.
- `equipment_live_{metrics,job,shift,day,month}` / `area_live_{shift,day}` — **current-state ("now") grains** for live dashboards (a live snapshot, not an aggregate).
- `data_quality_event` — DQ flags (overspeed, ideal-speed-too-low, …).

**`gold`** (OEE + business):

- `equipment_oee_{shift,hourly,daily,weekly,monthly}` (+ `_shift_weekly`/`_shift_monthly`) — **OEE per equipment per grain**: `oee`, `oee_a/p/q`, running/stopped/idle time, gross/net/scrap, `recalc_needed`.
- `area_oee_{shift,daily}` / `site_oee_shift` — OEE rolled up to area/site.
- `production_orders_runtime` — one OEE row per PO run (GiST EXCLUDE → no overlapping runs per equipment). `po_box_counter` — box counts per PO.

## Retention & the historian cold store

Two layers bound how long data lives: a **hot** retention policy inside the
analytics DB, and a **cold** Parquet historian on S3 for anything older.

### Hot retention — inside `packiot_analytics` (staging)

| Table | Bound | Mechanism |
|---|---|---|
| `equipment_values` (raw hypertable) | **90 days** | TimescaleDB `policy_retention` (`drop_after`) |
| `equipment_events`, `*_raw` | 2 years | retention policy |
| `lab_equipment_values` | 1 year | retention policy |
| `gold.equipment_oee_hourly` / `_shift`, `equipment_events_cpac_shadow` (plain derived tables) | **90 days** | UDA job `purge_analytics_plain` (a daily `add_job` procedure — these are **not** hypertables, so `drop_chunks` can't reach them) |

So staging analytics keeps **~3 months** of telemetry + derived rows. `production_orders`
and `equipment_events_man` are deliberately **unbounded** — they're business-entity /
manual-entry tables that grow with human activity, not sample rate. (This is why the
OEE-cascade box above says "time-bounded — see here" rather than a single number: the
bound is plane- and table-specific.)

### Cold store — S3 Parquet (`terraform/staging/historian.tf`)

Anything older than the hot window lives as **ZSTD Parquet on S3**, keyed
`s3://packiot-staging-historian-<acct>/equipment_values/enterprise=<F3-id>/year=<Y>/month=<M>/*.parquet`
(partitions **and** `ts_value` are **UTC** — query in UTC or you drift by the offset).
Two read paths: **Athena** (partition projection, no Glue crawler → $0 catalog) for ad-hoc
scans, and the **historian gateway** (below) for the live hot∪cold SQL surface.

**What fills cold — TEMPORARY, until the #225 legacy cutover:** a daily job copies the
**legacy** production DB (`packiot40`, read-only) into cold — remapped from the legacy
id-space to the new-stack (**F3**) id-space and translated into the 56-column hist schema —
writing one `data-<YYYY-MM>-legacy.parquet` per month (idempotent overwrite), up to a lag
boundary that leaves the live edge to the hot side. This is `scripts/historian-legacy-copy.sh`,
run by `historian-staging-append.timer` (02:30 UTC), which then stamps the watermark and
refreshes the union boundaries.

- **Why legacy, not analytics:** analytics only carries the machines wired to the new stack
  so far (hardproof 2026-09: **46 of 62** CPACK machines), so the legacy copy is the only
  **complete-history** source until the cutover. LIVE/recent data is served from analytics
  (the hot side) — not copied here.
- **Remap:** legacy→F3 equipment ids are recovered by joining `packml_register` on the
  group-normalized SparkPlug topic (`C-PACK`→`CPACK`), proven identical to the original
  onboarding remap. F3 `id_site`/`id_area` come from `core.equipments`.
- **Prune:** S3 lifecycle expires Parquet after **180 days** (staging is a *test* historian).

> **Prod differs:** `terraform/production/historian.tf` is a **keep-forever** design that
> *tiers* to colder storage (365d/730d) rather than pruning; the prod instance is a one-time
> legacy backfill pilot (ent-1 only), not an ongoing copy. Don't apply the staging prune to prod.

## Historian gateway (`packiot_historian`) — the hot∪cold query layer

A separate **pg_duckdb** container (`hist-gateway`, DB `packiot_historian`) presents ONE
seamless SQL surface per fact that stitches **HOT** (live analytics via `postgres_fdw`) with
**COLD** (S3 Parquet via `read_parquet`). Consumers (read-api `/v1/historian`, the Superset
historian dataset) query plain Postgres SQL; old timestamps transparently resolve to Parquet.

| `schema.object` | Kind | Purpose |
|---|---|---|
| `live.equipment_values` | FDW | **HOT** side of EV — window onto `packiot_analytics.silver.equipment_values` (pinned 8 cols) |
| `live.equipment_events` | FDW | **HOT** side of EE — window onto `silver.equipment_events` (pinned 12 cols) |
| `cold.equipment_values` | view | **COLD** side of EV — `read_parquet(…/equipment_values/*-legacy.parquet)` |
| `cold.equipment_events` | view | **COLD** side of EE — `read_parquet(…/equipment_events/*-legacy.parquet)` |
| `cold.equipment_oee_shift` | view | COLD deep-OEE-history over the gold OEE-shift Parquet (PoC; not yet in a union) |
| `cold.equipment_values_all` | view | **THE EV serving surface** — hot ∪ cold, no double-count |
| `cold.equipment_events_all` | view | **THE EE serving surface** — hot ∪ cold |
| `cold.ev_union_boundary` | table | Per-tenant EV seam. Cold-anchored: `cutover_ts = max(cold ts_value)`; union serves cold `≤`, hot `>`. (was `hist_cutover`) |
| `cold.ee_union_boundary` | table | Per-tenant EE seam. **Hot-anchored** (opposite): `cutover_ts = min(hot ts_event)`; cold `<`, hot `≥` — hot holds the deep event history + operator downtime notes. (was `ev_events_cutover`) |
| `cold.promoted_enterprise` | table | Tenant-isolation **allow-list** — the cold side of each union INNER-JOINs it, so an enterprise's cold rows are served only when promoted (legacy ids collide across tenants; this is the sole cold fence) |
| `cold.cold_append_watermark` | table | Per-tenant staleness/progress stamp for the cold copy (observability + the staleness monitor). (was `hist_meta`) |

**Query contract:** every bounded query MUST carry a `year` AND `month` predicate (DuckDB
prunes only on partition columns — `ts_value` alone = full-archive scan) **and** an
`id_enterprise = <literal>` tenant fence (no Postgres RLS here — the literal is the fence).
Keep the union views out of Superset SQL Lab.

**EV vs EE asymmetry (the non-obvious bit):** EV is cold-anchored (cold = the big
authoritative archive, hot = the recent tail); EE is hot-anchored (hot = the deep event
history, cold = only the pre-hot window). That's why the two boundary tables compute
`cutover_ts` from opposite ends.

## Naming correlation: analytics ↔ historian

The historian deliberately **mirrors the analytics medallion fact names** — the gateway is a
query layer over the same facts, so the names line up 1:1 (no drift):

| Analytics (source of truth) | Historian gateway |
|---|---|
| `silver.equipment_values` | `live.equipment_values` (hot) + `cold.equipment_values` (archive) → `equipment_values_all` |
| `silver.equipment_events` | `live.equipment_events` + `cold.equipment_events` → `equipment_events_all` |
| `gold.equipment_oee_shift` | `cold.equipment_oee_shift` |

- The union views add only the `_all` suffix.
- The control tables (`ev_union_boundary`, `ee_union_boundary`, `promoted_enterprise`,
  `cold_append_watermark`) are gateway-internal — no analytics equivalent, named for their role.
- **Verdict: correlated.** The 2026-09 rename removed the last cryptic gateway names
  (`hist_cutover`/`ev_events_cutover`/`hist_meta` → the boundary/watermark names above).

## Shifts — the seconds-from-week-start encoding

The most counter-intuitive part.

- **`shifts`** — `cd_shift` (alphanumeric: `MORNING`/`T1`/`1`), area/site scope
  (area-first, site fallback), `begin_time`/`end_time`.
- **`shift_hours`** — one row per shift × weekday. `begin_time`/`end_time` are **INTEGER
  SECONDS from the operational week start**, not clock times (`21600` = 06:00). Runtime
  fields `shift_size`/`duration`/`id_equipment` are engine-set, not CS-Admin.
- **`week_begin`** (on enterprises/sites/areas) is a **signed** seconds offset defining
  where the operational week starts relative to **Monday 00:00** — **can be negative**.
  CPACK's `-3000` = −50 min = the week starts **Sunday 23:10**. The Go shift resolver
  (`stream-engine/internal/shiftresolver/`, a 1:1 port of the old SQL trigger) does
  naive-week arithmetic with the negative offset, area-priority, fail-open.

## Other key tables

- **equipment_events / _man** — downtime/status events. `forced_creation_system=true` is
  a **replicator dedup-bypass** flag on genuine manual downtimes, NOT "system pollution".
- **scanned_boxes** — box scans per PO; `increment` accumulates; `box_order_number != 0`
  filters valid scans.
- **users** — `id_user_firebase` (legacy), `id_user_cognito` (shadow, out-of-band, partial
  unique index; Bearer auth resolves tenant via it), `operator_pw_hash` (bcrypt, operator
  login). `user_roles` — `permissions` jsonb, `super_user`.
- **client_descriptors** (ADR-0045) — the onboarding SSoT; one JSONB `descriptor` per
  tenant, `status` lifecycle `draft→generated→captured→validated→cutover`.

## Flagged discrepancies (not guessed)
1. No `edge-api/schema.sql` — schema is migrations + `edge-node-red/db/*.sql`.
2. Counter-role naming: `areas.id_rejectscounter` (plural) vs
   `packml_register.id_rejectcounter` (singular).
3. `samples` referenced by CLAUDE.md + a DAO but has no migration here — realized as
   `sample_boxes` + `scanned_boxes`; possible out-of-band table.
4. `exclude_idle_from_availability`/`idle_timeout_seconds` are storage-only (worker not
   wired to read them yet — still uses env CSVs).
5. CAgg (prod) vs plain view (staging) drift on the `agg_*` layer.
