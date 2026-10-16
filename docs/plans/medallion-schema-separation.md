# Medallion Schema Separation — bronze / silver / gold for `packiot_analytics` (STAGING)

**Task:** #228 · **Status:** DESIGN ONLY — no DDL executed, no objects moved.
**DB:** `packiot_analytics` @ `10.10.10.89` (staging box `i-06c9547a2c7091ab7`).
**Engine:** PostgreSQL 15.17 + TimescaleDB **2.27.0**.
**Author note:** every feasibility claim below is hardproofed with a read-only probe or a
throwaway temp-schema experiment that was created and dropped. No real object was altered.

---

## 0. TL;DR — the verdict

| Question | Answer |
|---|---|
| Can a TimescaleDB hypertable be moved between schemas with `ALTER TABLE … SET SCHEMA`? | **YES — proven.** Metadata-only, sub-second, data + chunks + policies + caggs all survive. |
| Do we need recreate + backfill of `equipment_values`/`equipment_events`? | **NO.** In-place `SET SCHEMA` is the mechanism. Recreate+backfill is explicitly *not* required. |
| Do the continuous aggregates break when the base hypertable moves? | **NO.** Caggs reference the base by internal id, not by qualified name — they follow the move automatically (hardproofed: inserted new rows into the moved base, cagg refresh picked them up). |
| Do compression / retention policies break? | **NO.** The TSDB jobs re-point to the new schema automatically. |
| Do in-DB views / matviews break? | **NO.** PostgreSQL views depend on the base **by OID** (`pg_depend`) — they follow the move. Zero views hard-code `public.equipment_values/events`. |
| What actually breaks? | (a) the **postgres_fdw** foreign tables in the historian-gateway (name-bound, separate DB); (b) **plpgsql/SQL functions with unqualified refs** if the moved schema isn't on `search_path`; (c) code/SQL that hard-codes `public.` (stream-engine `bake.go`/`port-parity`, analytics-sync, mirror-worker, terraform, one proc); (d) Superset `bi`-schema datasets are unaffected (they read `bi.*` views, which follow). |
| Cheapest lever | **`search_path`** absorbs the vast majority of moves transparently. The physical write-path cutover for silver is largely a **config flip** (`flows.Dest.EvSchema`), not a rewrite — with one code change (per-layer schema split). |

**Recommendation:** proceed with **in-place `SET SCHEMA`** per object, sequenced bronze → gold → silver,
using **expand/contract with public shim views + a widened `search_path`** to keep every consumer live
across the cutover. Silver (the live ingest fact) is the only hard phase; bronze is trivial (dormant, 0 chunks);
gold is a mechanical view-shim expand/contract.

---

## 1. Current landscape (read-only census)

### Schemas present
`public` (everything legacy), `silver` (already holds the new metric/categorical caggs),
`serving` (~40 SQL/plpgsql API functions), `bi` (10 security-definer-style views for Superset),
`customer_reports` (Wave-2 pool tables), `customer_dashboards` (3 snapshot tables).
**`bronze` and `gold` do NOT exist yet** — they must be created.

### The four hypertables (all currently in `public`)
| Hypertable | Chunks | Compression | Role |
|---|---|---|---|
| `public.equipment_values` | 67 | on | **SILVER fact** (live UPSERT ingest target) |
| `public.equipment_events` | 101 | on | **SILVER fact** (live UPSERT ingest target) |
| `public.equipment_values_raw` | **0** | on | **BRONZE** (ADR-0036 immutable append; `BRONZE_RAW_APPEND=false`, dormant) |
| `public.equipment_events_raw` | **0** | on | **BRONZE** (dormant) |

### Continuous aggregates
- **Already in `silver`:** `equipment_metrics_{1min,10min,1hour,1day}`, `equipment_categorical_{1min,10min,1hour}` (7 caggs, refresh policies 1057–1068). The `_1min` tier reads `public.equipment_values`; higher tiers roll up from the tier below.
- **Still in `public` (legacy-named, silver-tier by role):** `agg_{equipment,area,site}_values_{1min,10min,1hour}` (9), `ca_agg_equipment_values_{1min,1hour}`, `ca_discrete_changes_1s`, `ca_equipment_boxes_{1s,1hour}`. All reference `public.equipment_values` by OID.

### TimescaleDB policies (jobs) — all survive a `SET SCHEMA`
`equipment_values`: compression 1031 + retention 1032. `equipment_events`: compression 1019 + retention 1025.
The `_raw` tables: compression 1027/1028 + retention 1029/1030. Every cagg carries a refresh policy
(+ compression, + some retention). None are name-pinned to `public`.

### search_path (the key lever)
```
db:packiot_analytics  →  {track_functions=pl}      -- NO search_path override
session default       →  "$user", public
```
There is **no custom search_path** today. Unqualified references resolve to `public`. This is both the
risk (moving an object out of `public` hides it from unqualified refs) **and** the cheapest fix
(add `gold, silver, bronze` to the DB search_path and unqualified refs keep resolving to the new home).

---

## 2. THE CRUX — hypertable `SET SCHEMA` feasibility (hardproof)

Ran on staging in a throwaway schema (`t228_src`/`t228_dst`), created and **dropped**:

```sql
CREATE TABLE t228_src.tt (ts timestamptz NOT NULL, id int, v double precision);
SELECT create_hypertable('t228_src.tt','ts', chunk_time_interval => interval '1 day');
-- 37 rows across 4 daily chunks; + compression policy + retention + a continuous aggregate tt_1h
ALTER TABLE t228_src.tt SET SCHEMA t228_dst;   -- ← the move
```

**Observed (all EXIT=0):**

| Property | Before move | After move | Verdict |
|---|---|---|---|
| Hypertable schema | `t228_src` | `t228_dst` | moved ✅ |
| Chunk location | `_timescaledb_internal` (4) | `_timescaledb_internal` (4) | chunks live in the internal schema regardless of the logical schema — **they don't move, and don't need to** ✅ |
| Row count | 37 | 37 | data intact ✅ |
| Compression + retention policy | target `t228_src.tt` | target `t228_dst.tt` | **re-pointed automatically** ✅ |
| Cagg `tt_1h` base reference | resolves | resolves | followed by internal id ✅ |
| Cagg refresh after move | — | inserted 5 NEW rows into `t228_dst.tt`, refreshed → cagg **37 → 42** | **cagg tracks the moved base** ✅ |
| `ALTER MATERIALIZED VIEW tt_1h SET SCHEMA t228_dst` | — | succeeds | the cagg view itself is independently movable ✅ |

**Conclusion:** `ALTER TABLE … SET SCHEMA` is a **catalog-only relocation**. The physical chunks stay
in `_timescaledb_internal`; only the logical hypertable's namespace pointer changes. Policies and
continuous aggregates are wired by internal object id, so they follow with zero rebuild. This is the
single most important finding — it turns the silver fact move from a "recreate + backfill + rebuild the
whole cagg hierarchy" project into a **fast metadata operation guarded by a brief lock**.

**The one caveat — lock class.** `SET SCHEMA` takes an `ACCESS EXCLUSIVE` lock on the table for the
(sub-second) duration. Against the live ingest target that means: run it with `lock_timeout` + retry so it
never queues behind, or blocks, a long ingest transaction. (Same discipline the analytics rename cutover
used — see `session_analytics_rename_cutover`.)

---

## 3. What follows automatically vs. what breaks

The migration's whole risk profile reduces to **OID-bound (safe) vs. name-bound (breaks)**:

### Follows the move automatically (OID-bound — NO action)
- **All continuous aggregates** (silver `equipment_metrics_*`/`categorical_*`, legacy public `agg_*`/`ca_*`) — internal-id wired.
- **All compression / retention / refresh policies** — TSDB jobs re-point.
- **All in-DB views & matviews** — `pg_depend` confirms `bi.downtimes`, `bi.equipment_speed`, `bi.live_status`, `bi.production_by_team`, and the `public.v_*` SAP/operator/report views depend on `equipment_values`/`equipment_events` **by OID**. **Zero** views hard-code `public.` in their definition (proven: `pg_get_viewdef ILIKE '%public.equipment_%'` → 0 rows). They keep working after the move.
- **Superset `bi.*` datasets** — they select from the `bi` views (physical `schema: bi`), which follow. No Superset change needed for the `bi` layer.

### Breaks on the move (name-bound — MUST be updated)
1. **historian-gateway postgres_fdw** (separate DB, cross-repo). Foreign tables `live.equipment_values` / `live.equipment_events` carry option `schema_name='public'` (verified against the gateway catalog). Re-point is a **one-line metadata flip per table** — *no re-import, no drop/recreate*:
   ```sql
   ALTER FOREIGN TABLE live.equipment_values OPTIONS (SET schema_name 'silver');
   ALTER FOREIGN TABLE live.equipment_events OPTIONS (SET schema_name 'silver');
   ```
   Repo source that must also change so a fresh gateway init points correctly:
   `services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh:117,120`
   (`IMPORT FOREIGN SCHEMA public LIMIT TO (equipment_values) … INTO live;` → `silver`).
2. **plpgsql / SQL functions with UNqualified refs** (12 found: `serving.downtime_events`, `downtime_events_v2`, `events_timeline`, `events_timeline_by_po`, `overview_events`, `overview_events_v3`, `pending_downtime`, `downtime_duration_by_category`; `public.get_downtime_sync_enterprsie_06`, `get_report_shift_enterprsie_06c`, `h_piot_get_downtimes_per_category_equipment_level_new_4`, `h_piot_get_downtimes_sector_microstops`). plpgsql/SQL bodies are re-parsed at runtime and resolve unqualified names via `search_path` → they break **only if** the moved schema isn't on the path. **Widening `search_path` (§5) fixes all 12 without editing them.**
3. **One proc hard-codes `public.`:** `public.purge_analytics_plain` — must be edited.
4. **Application / infra code that hard-codes `public.`** (from the code inventory):
   - stream-engine: `internal/bake/bake.go` (equipment_events, equipment_oee_{shift,hourly,daily}, production_orders_runtime), `cmd/port-parity/main.go`, `scripts/parity-check.sql`.
   - analytics-sync: `internal/replicate/handlers.go`, `internal/replay/handlers/natural_key.go` (+ tests pin the literal `public.`).
   - mirror-worker-go: `internal/db/staging.go`.
   - terraform: `staging/user_data/db_init.sh` (`drop_chunks('public.equipment_values'/'…events')`, `VACUUM public.…`), `staging/scripts/install-backup-tooling.sh`.
   - edge-api migrations: `20250903183451_update_equipmentevents_trigger.ts`, the `shadow_go_port` migrations.
5. **Unqualified app refs that rely on `search_path=public`** (read-api `datasets.go`/`external*.go`, all edge-api DAOs). Covered by the widened `search_path` **if** the role default is updated; otherwise each must be schema-qualified.

---

## 4. Object → layer move map

> Legend: **MOVE** = `SET SCHEMA` in this migration · **STAY** = keep as-is (serving tier) · **ALREADY** = already in target · **DECIDE** = open classification (see §10).

### BRONZE (immutable append landing — ADR-0036 B1)
| Current | → | New |
|---|---|---|
| `public.equipment_values_raw` | MOVE | `bronze.equipment_values_raw` |
| `public.equipment_events_raw` | MOVE | `bronze.equipment_events_raw` |

### SILVER (merged fact + metric caggs)
| Current | → | New |
|---|---|---|
| `public.equipment_values` (hypertable) | MOVE | `silver.equipment_values` |
| `public.equipment_events` (hypertable) | MOVE | `silver.equipment_events` |
| `silver.equipment_metrics_*` / `equipment_categorical_*` | ALREADY | (stay in `silver`) |
| `public.agg_{equipment,area,site}_values_*` (9 caggs) | MOVE (opt.) | `silver.*` — pure but optional; they follow the base by OID either way |
| `public.ca_agg_equipment_values_*`, `ca_discrete_changes_1s`, `ca_equipment_boxes_*` | MOVE (opt.) | `silver.*` |
| `public.equipment_values_1min` (plain matz table) | DECIDE | silver-tier candidate |
| `public.equipment_events_man`, `equipment_events_low_speed`, `equipment_events_cpac_shadow` | DECIDE | event side-tables — likely silver |

### GOLD (OEE grains + PO runtime)
| Current | → | New |
|---|---|---|
| `public.equipment_oee_{shift,hourly,daily,weekly,monthly}` | MOVE | `gold.*` |
| `public.equipment_oee_shift_{weekly,monthly}` | MOVE | `gold.*` |
| `public.area_oee_{daily,shift}`, `public.site_oee_{daily,shift}` | MOVE | `gold.*` |
| `public.production_orders_runtime` | MOVE | `gold.production_orders_runtime` |
| `public.oee_targets` | MOVE | `gold.oee_targets` |
| `public.production_orders` | **DECIDE / recommend STAY** | it's a PO dimension/fact heavily written by edge-api; moving it is high-churn for low medallion value — keep in `public` (or a `dim`/`ops` schema) unless the user insists |

### STAY (serving layer above gold — user decision, unchanged)
`serving.*` functions · `bi.*` views · `customer_reports.*` · `customer_dashboards.*`.
`h_piot_*` tables, `equipment_live_*` tables → **DECIDE** (Hasura/live serving materializations; see §10).

---

## 5. `search_path` strategy — the cheapest lever

Set the **DB-level** default so every unqualified reference finds its object in its new home:
```sql
ALTER DATABASE packiot_analytics SET search_path = "$user", gold, silver, bronze, public;
```
Effect: unqualified `equipment_values` → resolves to `silver` (once moved, and once no `public` shim shadows it); `equipment_oee_shift` → `gold`; the 12 unqualified serving/report functions and all read-api/edge-api unqualified reads keep resolving with **no code edit**. This is the single change that collapses most of the "name-bound breakage" surface.

**Ordering hazard (shadowing):** during expand/contract a **public shim view** with the same name will coexist with the real object in `silver`/`gold`. Because `public` is *last* in the path above, the new-schema object wins for unqualified refs — good for the contract step, but during **expand** you may want the shim to win. Manage this by controlling either the path order or shim lifetime per phase (spelled out per phase in §6). New sessions pick up the DB setting; long-lived pooled connections (pgbouncer, read-api, stream-engine) must be **recycled** to observe a changed `search_path` — treat a pool bounce as part of each cutover gate.

**Rollup write-path note:** `rollup/provision.go` does `SET search_path TO <EvSchema>, public` per session. For gold outputs + silver inputs to both resolve, that session path must become `gold, silver, public` (or the Dest must carry explicit per-layer schemas — see §7).

---

## 6. Per-layer expand/contract plan

Sequence: **bronze first (trivial) → gold (mechanical) → silver (the hard one, live ingest)**. Each phase is independently revertible.

### Phase A — BRONZE (trivial; dormant, 0 chunks)
Because `BRONZE_RAW_APPEND=false` and both raw hypertables have **0 chunks**, there is effectively nothing live.
1. `CREATE SCHEMA bronze;`
2. `ALTER TABLE public.equipment_values_raw SET SCHEMA bronze;` (+ `equipment_events_raw`).
3. Update the stream-engine bronze writer target. **Already schema-parameterized** via `flows.Dest.EvSchema` (`writers/equipment_values.go:766,800` use `%s.equipment_values_raw`) — but note EvSchema is *shared* with silver/gold (see §7). Simplest: rely on the widened `search_path` so the append still resolves, or add `bronze` as the raw target once the per-layer split lands.
4. **Hardproof gate:** flip `BRONZE_RAW_APPEND=true` on a canary tick → confirm rows land in `bronze.equipment_values_raw` and the immutability trigger still fires (the `bronze_raw_golden_test` fixture already proves the trigger semantics against a `br.` schema).
**Rollback:** `ALTER TABLE bronze.* SET SCHEMA public` (instant). No data at risk.

### Phase B — GOLD (view-shim expand/contract; plain tables, no hypertable)
All gold objects are **plain tables** → `SET SCHEMA` is a trivial catalog op.
1. **Expand:** `CREATE SCHEMA gold;` then per table `ALTER TABLE public.equipment_oee_shift SET SCHEMA gold;` (× all grains + `production_orders_runtime` + `oee_targets`). Immediately create back-compat shims so name-bound readers/writers that still say `public.equipment_oee_shift` keep working:
   ```sql
   CREATE VIEW public.equipment_oee_shift AS SELECT * FROM gold.equipment_oee_shift;  -- read shim
   ```
   (Auto-updatable — the rename-cutover hardproof showed plain DML + `ON CONFLICT (col)` pass through such a view; only `ON CONSTRAINT` fails. Gold writers use plain INSERT/UPDATE, so writes pass through.)
2. **Cut the writers off `public.`:**
   - stream-engine rollup: point the provision/rollup session `search_path` to `gold, silver, public` (the procs write grains unqualified) **or** carry a `GoldSchema` in `flows.Dest` (§7). Edit `bake/bake.go` + `cmd/port-parity` (hard-coded `public.equipment_oee_*` / `production_orders_runtime`).
   - analytics-sync `replicate/handlers.go` (`public.production_orders_runtime`) → `gold.` (or unqualified + path).
   - edge-api: unqualified DAO refs resolve via the widened DB `search_path` — no edit needed once the role picks up `gold` (bounce the pool). `production-targets-dao.ts` interpolates bare table names → still resolves.
   - Superset `bi.*` OEE datasets (`oee_hourly.yaml`, `oee_shift.yaml`, `production_order_runtime.yaml`) read `bi` views, which followed by OID → **no change**.
3. **Contract:** once all writers/readers are confirmed off the `public.` names, `DROP VIEW public.equipment_oee_shift …` shims.
4. **Hardproof gates:** (a) rollup tick writes land in `gold.*` (row-count delta on `gold.equipment_oee_shift` per tick); (b) `serving.oee_*` functions return non-empty for a known enterprise (they read the grains, OID-bound so unaffected); (c) Superset `oee_hourly`/`oee_shift` datasets render; (d) no `42P01`/500 in read-api logs.
**Rollback per step:** shims make it reversible — recreate the shim / move the table back with `SET SCHEMA public`.

### Phase C — SILVER (the hard one: live fact ingest + FDW + caggs)
This is the only phase touching the live UPSERT target and the historian FDW.

**Pre-flight:** confirm ingest lag is low and coordinate a quiet window (the historian agent FDW-reads these tables — the `ACCESS EXCLUSIVE` moment will briefly block its reads too).

1. **Expand — move the fact hypertables:**
   ```sql
   CREATE SCHEMA silver;  -- exists already
   SET lock_timeout = '3s';
   ALTER TABLE public.equipment_values SET SCHEMA silver;   -- retry-on-timeout loop
   ALTER TABLE public.equipment_events SET SCHEMA silver;
   ```
   Caggs (`silver.equipment_metrics_*`, legacy `public.agg_*`/`ca_*`) and all policies **follow automatically** (§2). Optionally also `ALTER MATERIALIZED VIEW public.agg_* SET SCHEMA silver` for purity — cosmetic, they work either way.
2. **Read shim (keep name-bound readers alive):**
   ```sql
   CREATE VIEW public.equipment_values AS SELECT * FROM silver.equipment_values;
   CREATE VIEW public.equipment_events AS SELECT * FROM silver.equipment_events;
   ```
   Careful: a *view* named `public.equipment_values` cannot itself be a hypertable and an
   ON-CONFLICT UPSERT through it into a hypertable is the risky path — so **do not** rely on the shim
   for the ingest writer. Instead cut the writer over explicitly (next step). The shim is for *readers*
   (bake.go, mirror-worker, terraform VACUUM, ad-hoc) during the window.
3. **Cut the ingest write-path over to `silver` (config flip + one code change):**
   `flows.StandardFiltered` currently returns `EvSchema:"public"` for the analytics dest. Change the
   silver-fact target to `silver`. **Constraint:** today `EvSchema` is one value shared by bronze-raw,
   silver-fact, AND gold-rollup — so a naïve flip sends OEE grains to `silver` too. Resolve via §7
   (per-layer schema fields) **or** the transitional shim approach: keep `EvSchema=public` with `public`
   pointing at silver via the shim only for reads, and qualify the fact INSERTs to `silver` directly.
   The clean answer is §7's `flows.Dest{ BronzeSchema, SilverSchema, GoldSchema }`.
4. **Re-point the historian-gateway FDW (cross-repo, separate DB):**
   ```sql
   -- on the hist-gateway postgres (docker exec hist-gateway psql -U postgres -d postgres)
   ALTER FOREIGN TABLE live.equipment_values OPTIONS (SET schema_name 'silver');
   ALTER FOREIGN TABLE live.equipment_events OPTIONS (SET schema_name 'silver');
   ```
   Then edit `services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh:117,120`
   so a rebuilt gateway imports from `silver`. `ev_all` / `ev_all_events` views and the cutover-refresh
   scripts read `live.equipment_values` (local FDW name, unchanged) → no further edit. The
   `refresh_hist_cutover()` invariant is untouched.
5. **Edit the hard-coded `public.` name-bound writers/readers** (bake.go, port-parity, analytics-sync,
   mirror-worker, terraform `drop_chunks`/VACUUM, `purge_analytics_plain`, edge-api trigger migration)
   → `silver.` or unqualified (path-resolved). Recycle pools so the widened `search_path` takes effect.
6. **Contract:** once ingest writes to `silver`, the FDW points at `silver`, and no consumer references
   `public.equipment_values/events` by name, `DROP VIEW public.equipment_values / equipment_events`.

**Hardproof gates (Phase C):**
- **Ingest continuity:** `SELECT max(ts_value) FROM silver.equipment_values` advances within seconds of the move; ingest lag metric stays flat.
- **Cagg watermark continuity:** `cagg_watermark` on `silver.equipment_metrics_1min` continues to advance post-move; a manual `refresh_continuous_aggregate` picks up new rows (mirrors the throwaway proof).
- **FDW parity:** on the gateway, `SELECT count(*) FROM live.equipment_values WHERE ts_value > now()-interval '5 min'` returns fresh rows *after* the re-point; `ev_all` returns hot+cold with no double-count (the `hist_cutover` invariant still holds).
- **No consumer 500s:** read-api `/v1/query` + `/v1/historian/*`, Superset `bi.*` + `ev_all` datasets, edge-api downtime/PO endpoints all 200.
- **serving functions:** the 12 unqualified functions return rows (proves `search_path` absorbed them).

**Rollback (Phase C):** the move is symmetric — `ALTER TABLE silver.equipment_values SET SCHEMA public` (drop the shim first), re-point FDW `schema_name` back to `public`, revert `EvSchema`. Because chunks/policies/caggs follow the id, rollback is as clean as the forward move. Keep the write-path flip and the DROP-shim in **separate deploys** (writer-audit lesson from #186: never drop the compatibility surface until every writer is confirmed off it).

---

## 7. Code change: per-layer schema in `flows.Dest` (the one real write-path lift)

Today `flows.Dest` has a single `EvSchema` used for **bronze raw**, **silver fact**, AND (via
`rollup/provision.go`'s `SET search_path TO %s, public`) **gold grains**. Full-purity separation needs
the writer to distinguish them. Two options:

- **(A) `search_path`-only (least churn):** leave `EvSchema` as a *search-path seed* and set it (or the
  DB default) to `gold, silver, bronze, public`. Unqualified writes in the rollup procs resolve outputs
  to `gold` and inputs to `silver`. Fact UPSERTs in `writers/equipment_values.go` (`%s.equipment_values`)
  need `%s` = `silver`; raw appends need `bronze`. Since these are *different* `%s`, path-only doesn't
  fully disambiguate the qualified writers — works for the unqualified rollup, not the qualified writers.
- **(B) explicit fields (clean, recommended):** extend `Dest` with `BronzeSchema`, `SilverSchema`,
  `GoldSchema`; qualify each writer/rollup accordingly. Larger diff but unambiguous and self-documenting.

**Recommendation:** (B) for the fact/raw writers (they're already `%s.`-parameterized — just thread the
right field), plus a widened session `search_path` for the plpgsql rollup procs (they're unqualified).
This keeps the DB-side move mechanical and the code-side change small and localized to stream-engine.

---

## 8. Can `search_path` absorb moves transparently? (summary)

| Consumer class | Absorbed by widened `search_path`? |
|---|---|
| In-DB views/matviews (bi.*, v_*, caggs) | N/A — OID-bound, follow automatically |
| TSDB policies | N/A — follow automatically |
| plpgsql/SQL functions with **unqualified** refs (the 12 + rollup procs) | **YES** — no edit needed |
| read-api / edge-api **unqualified** reads | **YES** — once role default updated + pools bounced |
| Hard-coded `public.` (bake.go, analytics-sync, mirror-worker, terraform, `purge_analytics_plain`, edge-api trigger mig) | **NO** — must be edited |
| Qualified silver-fact / bronze-raw **writers** (`%s.` with `%s=public`) | **NO** — flip the schema value (§7) |
| historian-gateway FDW | **NO** — `ALTER FOREIGN TABLE … OPTIONS (SET schema_name …)` + init-script edit |

So `search_path` erases roughly the whole *read* surface and every *unqualified* function; the residual
work is a finite, enumerated list of hard-coded `public.` sites + the FDW + the writer schema value.

---

## 9. Risk & rollback matrix

| Layer | Top risk | Mitigation | Rollback |
|---|---|---|---|
| Bronze | none (dormant) | canary flip of `BRONZE_RAW_APPEND` | `SET SCHEMA public` (instant) |
| Gold | writer still on `public.` after shim drop → 42P01 | drop shim only after zero-writer log-watch (per #186) | recreate shim / `SET SCHEMA public` |
| Silver | (1) `ACCESS EXCLUSIVE` blocks/queues behind long ingest txn; (2) FDW stale until re-point → historian reads miss fresh rows; (3) UPSERT-through-view semantics | `lock_timeout`+retry; re-point FDW in the same window; cut writer to qualified `silver` (don't UPSERT through the shim view) | symmetric `SET SCHEMA public` + FDW `schema_name` back to `public` + revert `EvSchema` |
| All | pooled connections cache old `search_path` | bounce pgbouncer / read-api / stream-engine as a gate step | n/a |

---

## 10. Open decisions (need user/architect call)

1. **`production_orders`** — move to `gold` (purity) or keep in `public`/`ops`? It's edge-api's heavily-written PO dimension; recommend **keep** unless purity is mandated.
2. **`h_piot_*` tables** (`h_piot_oee_*`, `h_total_production_chart_from_runtime`, `h_piot_production_orders_*`) — Hasura-served serving materializations. Move to `serving` or keep in `public`? (They're the serving tier by role, not gold facts.)
3. **`equipment_live_*`** (day/hour/job/metrics/shift/week/month) — live snapshot tables: gold, silver, or a dedicated `live` tier?
4. **Event side-tables** (`equipment_events_man`, `_low_speed`, `_cpac_shadow`) — silver, or leave in `public`?
5. **Legacy public caggs** (`agg_*`, `ca_*`) — physically move to `silver` (pure) or leave (they work either way)?
6. **Move-`EvSchema` design** — §7 option (A) vs (B).

---

## 11. Prod forward-port callout

- **Prod runs OLD-named/placed objects.** The analytics meaningful-names rename (`runtime_*→oee_*`,
  `uns_*→live_*`) and the `silver.*` caggs are **staging-first**; prod's cutover was in-progress
  (`project_prod_cutover_inprogress`). This medallion split is **staging-only** here and must be
  **forward-ported** to prod as a separate, sequenced change after prod's rename cutover settles —
  the same object→layer map applies, but prod's starting object names/locations differ.
- **The historian-gateway FDW re-point is cross-repo** (`services/historian-gateway`) and lives on the
  **Superset/gateway box**, not the DB box — its deploy is a separate unit from the analytics DDL. Its
  `schema_name` flip + init-script edit must ship in lockstep with the silver move, or `ev_all` goes
  stale (hot side empty) until it does.

---

## 12. Hardproof appendix (read-only probes run)

- Landscape: PG 15.17, TSDB 2.27.0; 4 hypertables in `public`; `silver` present, `bronze`/`gold` absent.
- Throwaway `SET SCHEMA` experiment (`t228_src`/`t228_dst`, created + **dropped**): move succeeded; 37 rows / 4 chunks intact in `_timescaledb_internal`; compression+retention re-pointed; cagg tracked the move (37→42 after post-move insert + refresh); `ALTER MATERIALIZED VIEW … SET SCHEMA` succeeded. Cleanup verified (`SELECT nspname … LIKE 't228%'` → 0 rows).
- Policies census: 49 TSDB jobs enumerated; none name-pinned to `public`.
- Dependency census (`pg_depend`/`pg_rewrite`): 4 `bi.*` + 8 `public.v_*` views + all caggs depend on the facts **by OID**; `pg_get_viewdef ILIKE '%public.equipment_%'` → **0** hard-coded qualifiers.
- Functions: 1 (`purge_analytics_plain`) hard-codes `public.`; 12 reference the facts unqualified.
- `search_path`: DB has no override; session default `"$user", public`.
- FDW (gateway catalog, read-only): `live.equipment_values`/`live.equipment_events` → `schema_name=public`; re-point = `ALTER FOREIGN TABLE … OPTIONS (SET schema_name 'silver')`.

*(No real object was created, altered, moved, or dropped in `packiot_analytics` beyond the throwaway
`t228_*` schemas, which were dropped. The gateway FDW was read-only inspected — not altered.)*
