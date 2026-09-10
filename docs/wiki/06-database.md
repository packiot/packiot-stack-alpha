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

### Cold store — the S3 + Athena historian (`terraform/staging/historian.tf`)

A daily job unloads `equipment_values` from the analytics DB to **ZSTD Parquet on S3**,
queried via **Athena partition projection** (no Glue crawler → $0 catalog cost).

- **Layout:** `s3://packiot-staging-historian-<acct>/equipment_values/enterprise=<id>/year=<Y>/month=<M>/data-<YYYY-MM-DD>.parquet`. Partitions **and** `ts_value` are **UTC** — query in UTC, not local BRT, or you drift by the offset.
- **Append job:** `historian-staging-append.timer` (systemd, daily 02:30 UTC, `Persistent=true`) runs `scripts/historian-staging-run-append.sh` on the app box. DuckDB `postgres_query` (READ_ONLY) → a **56-column** projection matching the Glue table → `COPY TO` a **deterministic per-day S3 key**. Versioning is off, so a re-run **overwrites** (never duplicates); a 2-day trailing overlap window (`OVERLAP_DAYS`) re-heals late rows.
- **Prune:** S3 lifecycle expires `equipment_values/` Parquet after **180 days** (staging is a *test* historian — 6-month prune) and `athena-results/` after 30 days.
- **No-gap guarantee:** rows land in the cold store ~1 day after they occur; analytics doesn't drop a row until it's 90 days old — so every row is archived ~87–90 days *before* it would leave the hot DB. Watermark files (`_watermark/enterprise=<id>/last-append.json`) give observability; the DB→S3 row counts cross-check **exactly**.
- **Total queryable age ≈ 6 months** — the 90-day hot window is a *subset* of the 180-day cold window, **not additive**.

> **Prod differs:** `terraform/production/historian.tf` is a **keep-forever** design that
> *tiers* to colder storage (365d/730d transitions) rather than pruning, and the prod
> instance is currently a one-time legacy backfill pilot (ent-1 only), not an ongoing
> append. Don't apply the staging 6-month prune to prod.

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
