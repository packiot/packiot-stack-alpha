# DBA Guide — packiot_analytics

The operational reference for the **one live application database**. Pairs with
[Database & Data Model](06-database.md) (the *schema* reference) — this page is the
*operate-it* reference: topology, access, the medallion schema map, continuous-aggregate
policies, retention, backup, and the runbooks you reach for at 2 a.m.

> **Golden rule:** there is exactly **one** application database — `packiot_analytics`.
> It is NOT split by concern into multiple databases; separation is by **schema**
> (ADR-0056). "More databases" ≠ "more mature" — coupling lives in views/joins, so a
> split would only add cross-DB pain. The legacy monolith `packiot` is frozen, out of the
> pipeline, and slated for retirement; when it frees the name, `packiot_analytics` →
> `packiot` (gated on #225).

---

## 1. Cluster topology

Staging runs on **two EC2 boxes** (one app, one DB):

| Box | Instance | Private IP | Runs |
|-----|----------|-----------|------|
| **App** | `i-06c9547a2c7091ab7` | 10.10.0.228 | all service containers (stream-engine, edge-api, read-api, operator, superset, grafana, the CI runner) |
| **DB** | `i-064bb36d1c454d861` | **10.10.10.89** | `timescaledb` container + `alloy` (metrics) |

The DB box `10.10.10.89` hosts a Postgres 16 + TimescaleDB cluster with **4 databases**:

| Database | Role |
|----------|------|
| **`packiot_analytics`** | **the live app DB** — every schema below. All telemetry + control-plane writes land here. |
| `packiot` | legacy monolith (frozen Aug-2026, out of the pipeline, #225-gated retirement) |
| `superset` | Superset metadata |
| `postgres` | cluster bootstrap DB |

There is no public Postgres port. Reach it three ways:
- **psql (read/write):** SSM → `docker exec timescaledb psql -U postgres -d packiot_analytics` (see the `apsql.sh` pattern in ops tooling).
- **pgweb (browse):** `db.staging.packiot.app` (analytics) / `histdb.staging.packiot.app` (historian gateway), behind the cs-admin oauth2 gate.
- **services:** via `stack-pgbouncer-1` on the app box (pooled) or direct for the few that need it.

A cluster-global **superuser** `dev@packiot.com` / `Packiot2026!` exists **staging-only**
(weak password by design; it did NOT change the `postgres` master). Do not create its
equivalent on prod.

---

## 2. The schema map (medallion + domain planes)

> **Why four schema *families* and not one scheme?** Because a schema answers **one
> question about one *kind* of object**, and the kinds are disjoint — so each gets the
> axis that fits its nature, not a single axis forced onto everything:
> - **telemetry** has a raw→cleaned→business *lifecycle* → **layer** axis (bronze/silver/gold).
> - **entities** (enterprises, users, labels) have no lifecycle — "a bronze `enterprises`"
>   is a category error → **domain** axis (core/identity/config/ops).
> - **views** are a *read contract* (who reads under whose rights) — orthogonal to storage
>   → **consumption** axis (serving=invoker/RLS, bi=definer).
> - **`public`** is **not a design family** — it's a **shrinking transitional bucket**:
>   genuine transactional tables + migration bookkeeping, *plus* not-yet-migrated legacy
>   caggs and retiring compat shims. It looks "scattered" because it's mid-migration; the
>   target is for it to hold only the genuinely-public handful (see §8 / the de-shim epic).
>
> The rule the design obeys: **every object has exactly one home.** Where the live DB
> still violates it (caggs in both `silver` and `public`; live-grain shims), that's
> *transitional debt*, not the taxonomy — tracked, not hand-waved.

The database-level `search_path` is:

```
"$user", gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public
```

So a **bare** table reference (`equipment_oee_shift`) resolves to its real home by this
order; only a **qualified** `public.X` pins a (retiring) compat shim. When you write ad-hoc
SQL, bare refs Just Work; qualify only when you mean to.

| Schema | Layer | Size | What lives here |
|--------|-------|-----:|-----------------|
| **bronze** | medallion — raw/immutable | 176 kB | `equipment_values_raw`, `equipment_events_raw` (append-only dual-write, **flag-gated OFF** `BRONZE_RAW_APPEND=false` → 0-row on staging, do NOT drop), `box_scans` (the barcode Bronze ledger — gapless server-assigned `label_seq`) |
| **silver** | medallion — cleaned facts | 1.1 GB* | `equipment_values` (raw metric **hypertable**, the big one), `equipment_events` (**hypertable**), `equipment_live_metrics`, current-state grains `equipment_live_{day,hour,job,shift,week,month}` + `area_live_*`/`site_live_day`, and the rollup caggs `equipment_metrics_*` / `equipment_categorical_*` |
| **gold** | medallion — OEE / business | 229 MB | `equipment_oee_{hourly,daily,weekly,monthly,shift,…}`, `area_oee_*`, `site_oee_*`, **`production_orders_runtime`** (GiST EXCLUDE: no overlapping runs per equipment), `po_box_counter` |
| **core** | domain — dimensions | 34 MB | `enterprises, sites, areas, equipments`, **`topic_routing`** (was `packml_register`), `shifts, shift_hours, production_orders, products, clients, product_families, teams`, targets (`oee_targets, scrap_targets, production_targets`), **`client_descriptors`** (onboarding SSoT) |
| **identity** | domain — authZ | 13 MB | `users` (`id_user_cognito`), `user_roles`, `user_logs` (audit), `user_screen_config`. Keyed to Cognito — this is domain authZ, NOT authN (Cognito) and NOT AWS-IAM. |
| **config** | domain — i18n/labels | 1.2 MB | `label_formats, labels, translations, tenant_translations, language_packs, pages, dashboard_config` |
| **ops** | domain — plumbing | 2.1 MB | `idempotency_keys, function_execution_log, capture_observations, mirror_replay_cursor, mirror_replay_dlq` |
| **serving** | read views (**invoker**) | views | what front4/operator/read-api read: `oee_score`(fn), `production_information`, `v_entities_per_user_role(_operator)`, `v_operator_*`, `v_po_box_totals`, `v_report_downtimes`, `v_events_2` |
| **bi** | read views (**definer**) | views | Superset/analyst surface: `oee_shift, oee_hourly, downtimes, equipment_speed, production_by_team, …` |
| **customer_reports** | per-customer exports | 80 kB | SAP/enterprise report tables (`sap_data_sync, production_data_sync, boxes, shift, speed`) |
| **public** | transactional + **retiring shims** | 131 MB | genuine public tables (`data_quality_event`, a few event side-tables, legacy caggs `agg_equipment_values_*`, CPAC `ca_*`) + compat views. New code should NOT target `public.*`. |

\* the silver "size" is dominated by the `equipment_values` hypertable (~1.1 GB) — its
chunks live under `_timescaledb_internal` (~5.5 GB incl. indexes), not the schema total.

`serving` = **invoker** (runs with the caller's rights → RLS applies); `bi` = **definer**
(bypasses RLS for trusted analytics). Keep that distinction — it's the tenant-isolation
boundary.

---

## 3. TimescaleDB — hypertables & continuous aggregates

**Hypertables** (chunked, time-partitioned):

| Hypertable | Size | Notes |
|------------|-----:|-------|
| `silver.equipment_values` | ~1.1 GB | raw metric time series, the ingest hot table |
| `silver.equipment_events` | ~120 MB | machine status / downtime events |
| `bronze.equipment_{values,events}_raw` | 24 kB | dormant (flag-gated Bronze append) |

> A TimescaleDB hypertable `SET SCHEMA` is **catalog-only** — chunks stay, caggs +
> policies follow by OID, zero rebuild. That's how the facts moved public→silver with no
> data copy. A hot table must be moved under `lock_timeout` in its own tx.

**Continuous aggregates** — the rollup engine reads these:

- `silver.equipment_metrics_{1min,10min,1hour,1day}` + `silver.equipment_categorical_{1min,10min,1hour}` — the **live rollup cascade** (feeds OEE).
- `public.agg_equipment_values_{1min,10min,1hour}` — legacy caggs (still read by a few paths).
- `public.ca_discrete_changes_1s` (CPAC algorithm), `public.ca_equipment_boxes_1s` (box counting).

> ### ⚠ The #1 recurring DBA time-bomb: a cagg with **no refresh policy**
> A real-time continuous aggregate with **no refresh policy** has a **frozen watermark** —
> the rollup then re-aggregates ALL raw on the fly every tick until a query crosses the
> statement timeout (this was the CPACK #196 outage: EXPLAIN cost 1.05M → 300 s timeout →
> OEE silently stale for days). **Every cagg MUST have an `add_continuous_aggregate_policy`**
> (provisioning enforces this since #206). Before profiling a slowly-degrading query,
> **check the cagg watermark first**:
> ```sql
> SELECT view_name, _timescaledb_functions.cagg_watermark(mat_hypertable_id)
> FROM _timescaledb_catalog.continuous_agg;   -- a frozen/old watermark = the smoking gun
> ```
> Recovery: full-gap `CALL refresh_continuous_aggregate(...)` then
> `add_continuous_aggregate_policy(...)`. To DROP a cagg: `remove_continuous_aggregate_policy`
> **first** (+ `lock_timeout`) or the DROP queues behind refresh jobs.

---

## 4. Retention & the cold historian

Two layers bound data lifetime:

- **Hot (in `packiot_analytics`, staging):** `silver.equipment_values` retained **90 days**
  (TimescaleDB `drop_after`); `equipment_events`/`*_raw` 2 years; derived plain tables
  (`gold.equipment_oee_hourly/_shift`) purged at 90 days by a daily UDA job (`drop_chunks`
  can't reach non-hypertables). `production_orders` + `equipment_events_man` are
  deliberately **unbounded** (business/manual data).
- **Cold (S3 + Athena/DuckDB historian):** a daily job unloads `equipment_values` →
  **ZSTD Parquet** partitioned `enterprise=/year=/month=` (UTC!), queried via Athena
  partition projection ($0 catalog) and exposed to read-api/Superset through the
  **hist-gateway** (`ev_all` union view). Staging prunes cold at 180 days → **~6 months
  total queryable**; **prod tiers/keeps-forever** — do not apply the staging prune to prod.

The hot 90-day window is a *subset* of the 180-day cold window (not additive); a row is
archived ~87–90 days before it leaves the hot DB → no gap.

---

## 5. Integer-as-timestamp traps (read before writing shift SQL)

The single most error-prone corner. These columns look like times but are **integer
seconds**, and getting them wrong silently corrupts OEE denominators:

- `core.shift_hours.begin_time / end_time` = **INTEGER SECONDS from the operational
  week start**, NOT clock times (`21600` = 06:00). Runtime fields `shift_size`/`duration`/
  `id_equipment` are engine-set, never CS-Admin.
- `core.{enterprises,sites,areas}.week_begin` = **signed** seconds offset of the week
  start relative to **Monday 00:00** — **can be negative** (CPACK `-3000` = week starts
  Sunday 23:10). The Go shift resolver does naive-week arithmetic with area-priority,
  site-fallback, fail-open.
- Understandability is codified as `COMMENT ON COLUMN` for the 16 int-timestamp traps —
  `\d+` and read them before touching shift math.

---

## 6. Common runbooks

**Is OEE fresh for a tenant?** (the "dashboards look stale" first check)
```sql
SELECT max(computed_at), now()-max(computed_at) AS lag
FROM gold.equipment_oee_shift s JOIN core.equipments e USING (id_equipment)
WHERE e.id_enterprise = :ENT;                 -- lag > 1 shift → investigate rollup
```

**Recalc backlog — real vs phantom.** Child sub-meters (`id_parentequipment IS NOT NULL`,
`tp_equipment=1`) never compute OEE, so a rollup asymmetry leaves them permanently flagged
`recalc_needed` — that is **phantom**, client-invisible noise, NOT staleness. Measure the
**real** backlog on OEE-computing equipment only:
```sql
SELECT count(*) FROM gold.equipment_oee_shift s JOIN core.equipments e USING (id_equipment)
WHERE e.id_enterprise=:ENT AND s.recalc_needed AND e.id_parentequipment IS NULL;
```
(One-time drain of the phantom flags: `db/migrations/t256-drain-phantom-child-recalc/`.)

**Force-refresh a cagg over a window** (after a raw backfill/cleanup):
```sql
CALL refresh_continuous_aggregate('silver.equipment_metrics_1hour', '2026-09-01', '2026-09-08');
```

**Drop a dead object — the writer-audit rule.** Never drop on "it looks empty". An empty
table can be load-bearing (a `RETURNS SETOF` row-type carrier; a flag-gated writer like
Bronze; a report view read by Superset). Before any DROP: grep **every** service for a
writer *and* a reader (bare + schema-qualified), check for an enable flag, then
`DROP … RESTRICT` (fails if any dependent exists) inside a reversible migration. Gate the
drop on a **zero-writer log-watch** ≥ the slowest job tick.

**Add a cluster user / rotate access:** superuser via `docker exec timescaledb psql`;
service creds live in the app-box compose env + Secrets Manager, not in the DB.

---

## 7. Backup & recovery

- **Snapshots:** the DB box EBS volume is snapshotted (last known-good before a big
  migration: `snap-0ea2644a0c11d270a`). Take a fresh snapshot before any destructive
  cutover.
- **pg_dump is blocked by Hasura on legacy** — for `packiot_analytics` use the superuser +
  `docker exec`. For point-in-time data extraction the cold historian (Parquet) is the
  durable archive.
- **Migrations are codified + reversible** under `db/migrations/<task>/` with a paired
  `rollback.sql`. Expand/contract for anything touching a live consumer (see
  `~/notes/systems/postgres-expand-contract-rename.md`): add-new → repoint readers →
  drop-old, each a separate deploy.

---

## 8. Flagged discrepancies (real, not smoothed over)

1. Counter-role naming: `core.areas.id_rejectscounter` (plural) vs
   `core.topic_routing.id_infeedcounter/id_outfeedcounter` (no reject column at line level).
   Reject role lives at the **area** level; many tenants (Bispharma) leave all NULL and rely
   on co-located `ProdDefectiveCount` / `***TRIG_CS` flow-derived scrap.
2. `public.*` still holds retiring compat shims — new code must target the real schema.
3. Some caggs live in `public` (legacy `agg_*`, CPAC `ca_*`), the rest in `silver`
   (`equipment_metrics_*`/`equipment_categorical_*`) — the `public` ones are being retired
   onto silver (task-tracked; a cagg-vs-cagg historical divergence is *stale materialization*
   over since-cleaned raw, not a logic bug — force-refresh one bucket to prove).
4. `active` soft-delete is enforced in edge-api reads but not universally downstream —
   verify per consumer.

## 9. Path to a clean `public` (the de-shim epic — *repoint, don't drop*)

> **Dead-object status (2026-09-10 maintenance window): the DB is garbage-free.** A full
> scan (pg_stat_statements 6-day window + pg_catalog static refs + orphan/backup-name sweep)
> found exactly **one** dead object in the entire database — `public.agg_equipment_values_10min`
> (0 queries, 0 dependents) — now **dropped** (migration `t258a`, via a stream-engine quiesce
> since cagg DDL contends with the ingest invalidation lock). Everything else that "looks
> scattered" in `public` is **live** (the `h_*` tables back called functions; the caggs feed
> read-api/reports/uns; the dim shims feed the shiftresolver) — un-migrated architecture, not
> leftovers. So what remains below is **forward-migration**, not cleanup.

`public`'s residue is **load-bearing**, not droppable cruft — an audit (2026-09-10) traced
every object to a live consumer. So the cleanup is a **repoint-then-drop** epic, in this
order (each phase its own deploy + soak; **plan it from the LIVE DB + deployed code, not a
local checkout** — the local tree drifts behind deploys):

1. **Caggs → silver.** `public.agg_equipment_values_{1min,10min,1hour}` + `ca_discrete_changes_1s` + `ca_equipment_boxes_1s` are read by the **rollup engine** (`availability/hour/shift/line_lead/inferspeed/deriver/uns`) and **read-api** (`query/datasets`). Repoint to `silver.equipment_metrics_*` / `equipment_categorical_*`, prove parity, then `remove_continuous_aggregate_policy` + drop.
2. **Dimension shims → core.** `public.{equipments,sites,shift_hours}` are still read (qualified) by the **shiftresolver** (hardcoded) and `bake/sentinel.go`. Repoint to `core.*`, then drop the shim views.
3. **Live-grain shims.** `public.equipment_live_{hour,job,month,week}` (views) — drop once consumers use `silver.*`.
4. **Return-type carriers.** The 5 `h_*` tables are empty but back a function's `RETURNS SETOF` — retire the **owning function** first, then the carrier.
5. **Deliberately-kept tools** (`equipment_values_1min`, `agg_*_1min_t`) — leave until the port-parity tooling is retired (a prior audit chose to keep them).

Done state: `public` holds only migration bookkeeping (`knex_*`) + the genuinely-public event tables (`data_quality_event`, `equipment_events_man/_low_speed/_cpac_shadow`). Everything else has one home.

---

## Related
- [Database & Data Model](06-database.md) — the schema/data-model reference.
- [Onboarding a Client](02-onboarding.md) + `docs/clients/onboarding-acceptance-checklist.md` — the per-tenant DB-level go/no-go gates.
- [Cloud Services & OEE Compute](05-cloud-services-and-oee.md) — who writes/reads each schema.
- ADR-0056 (one-DB decision), ADR-0045 (config-as-data / medallion).
