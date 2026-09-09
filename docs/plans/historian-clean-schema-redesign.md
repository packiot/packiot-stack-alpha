# historian — clean-schema redesign + cutover plan

**Status:** DESIGN (2026-09-08). Read-only review complete; **nothing applied**. The cutover
is a separate, approved step. This is the historian sibling of
`docs/plans/analytics-clean-schema-redesign.md`, and it **extends** the already-codified
RAW-layer PoC `db/design/historian-raw-schema.md` (the canonical hot≡cold column contract,
built + hardproofed 2026-09-04) to the **whole historian system**: the gateway objects, the
two divergent gateways (staging vs the prod "db3 union"), the cold Parquet layout, the
Athena/Glue catalog, the `hist_*` analytics archives, and every consumer.

Evidence: a fresh read-only pass on 2026-09-08 (account `639178078294`, `us-east-1`), every
verdict backed by live introspection —
- staging gateway `hist-gateway`@`i-06c9547a2c7091ab7` (docker exec psql);
- **prod** gateway `hist-gateway`@`i-0a5c5dadd9ea5e93e` (the prod Superset box);
- analytics DB `timescaledb`@`i-064bb36d1c454d861` (10.10.10.89, `packiot_analytics`);
- `aws glue get-table` on `packiot_historian_staging` + `packiot_historian`;
- `aws s3 ls` + `read_parquet()` probes through the gateway on both buckets;
- consumer greps across read-api, Superset assets, terraform, monitoring, and the scripts.

> **SSM note:** the Run-Command document on this account is **`AWS-RunShellScript`**
> (not `AWS-RunShellCommand`). Base64 the SQL through the SSM→docker→psql layers to
> dodge quote-mangling.

---

## 0. TL;DR

- The historian is **three conformed surfaces over one logical raw contract**
  (`equipment_values`, `equipment_events`): (1) the analytics **hot** tables (source of
  truth), (2) the **cold** S3 Parquet archive + its Glue/Athena catalog, (3) the
  **gateway union** (`ev_all` = hot FDW ∪ cold pg_duckdb). The raw column contract is
  already designed (`historian-raw-schema.md`); this plan promotes it and fixes the
  **operational/consistency** layer that doc did not cover.
- **The gateway is deliberately tiny and clean already**: exactly 4 relations
  (`live.equipment_values` FDW, `hist_cutover`, `ev_all`, `hist`) + 1 app function
  (`ev_between`). No sprawl to prune. The redesign is about **reconciling divergences**,
  not deleting objects.
- **The headline problem is that staging and prod are two different designs** that both
  call themselves "the historian gateway", plus **three inconsistent enterprise-id
  strategies** across EV/EE/staging/prod. A single canonical definition must replace both.
- **Real defects found (independent of the redesign):**
  1. **`refresh_hist_cutover()` is a live, broken trap on staging** — it scans the `hist`
     parquet view *inside a plpgsql body*, which pg_duckdb forbids, so it throws if called,
     silently leaving `hist_cutover` stale → hot/cold double-count. Not in the repo init
     script; staging-only cruft. **DROP.**
  2. **Legacy cold Parquet carries NULL production.** `enterprise=100` legacy: 519,924
     rows, **100 % gross/net/scrap NULL**; even `enterprise=3` (CPACK) legacy is **~50 %
     NULL**. The historian serves NULLs for old windows — the cold archive is currently
     a *coverage* store, not a *value* store, for legacy tenants.
  3. **Three id-spaces.** Staging EV = pre-remapped **F3** ids on disk (`enterprise=3`);
     staging/prod EE = raw **legacy** ids (`enterprise=1`, `33`, confirmed inside the
     Parquet column too); prod EV = raw legacy ids on disk (`enterprise=1`) **remapped
     1→3 by a hardcoded `CASE` inside the prod `hist` view**. These do not compose.
  4. **`equipment_events` cold store exists but is un-codified and un-unioned.** 462
     Parquet objects on staging (the doc's "zero data" is now stale), the Glue table was
     CLI-created (absent from `terraform/staging/historian.tf`), it is **not in the prod
     Glue DB at all**, and **nothing reads it** — no `ev_all_events`, no read-api endpoint.
  5. **Catalog drift persists.** Deployed EV projection = `enterprise 0,120` / `year
     1970,2027`; terraform still says `1,100` / `2019,2027`. EV Glue still the pre-redesign
     56-col shape (double/smallint, `id_production_order bigint`, no `ingested_at`/`source_seq`).
  6. **Orphan empties.** `enterprise=5` holds only 1,671-byte `data-2026-07-DD.parquet`
     files (0-row append artifacts, no `*-legacy.parquet`) → invisible to `ev_all`, dead weight.
- **`hist_production_orders` / `hist_production_orders_runtime`** (20,627 / 20,590 rows in
  `packiot_analytics`) are **PO archives, NOT historian time-series** — misleadingly named.
  Zero live consumers (only the F3 snapshot + `MANIFEST.f3-target` carry them). **DROP**
  (same verdict as the analytics review) and remove from the MANIFEST; they are unrelated
  to this S3 historian.

---

## 1. Current-state inventory

### 1.1 Gateway objects (identical structure on both boxes; definitions diverge)

Live enumeration of the `hist-gateway` (pg_duckdb `pgduckdb/pgduckdb:16-main`) default DB:

| Object | Kind | Purpose | Staging | Prod |
|---|---|---|---|---|
| `live.equipment_values` | foreign table (postgres_fdw) | HOT side — the live hypertable, 58 cols imported | `packiot_analytics`@10.10.10.89 | `packiot`@10.20.10.89 |
| `hist` | view (pg_duckdb `read_parquet`) | COLD side — the legacy Parquet archive | globs `*-legacy.parquet`; **no** id remap; cols {ts,ent,year,month,equip,gross,net} | globs **`data-*.parquet`**; **`CASE enterprise WHEN 1 THEN 3`** remap; **+`speed`** |
| `hist_cutover` | table | per-enterprise disjointness boundary `cutover_ts = max(hist.ts_value)` | **25 enterprises** | **1** (ent 3 only, `2026-08-11`) |
| `ev_all` | view | `hist ∪ live` (legacy-priority: cold owns `ts ≤ cutover`, hot owns `ts > cutover`) | 7 cols (gross/net) | **8 cols (+speed)** |
| `ev_between(p_start,p_end)` | SQL function | `ev_all` + injected year/month prune predicate for the cold side | present | present |
| `refresh_hist_cutover()` | plpgsql function | recompute `hist_cutover` | **present + BROKEN** (DuckDB-scan-in-function) | **absent** (correct) |

Everything else in the gateway (181 `public` functions) is **pg_duckdb extension-owned**
(`read_parquet`, `time_bucket`, `json_*`, `epoch_*`, aggregates…) — not app objects, leave alone.

**hot/cold disjointness is `hist_cutover`-driven** and the invariant is load-bearing: every
in-historian enterprise MUST have a `cutover_ts = max(hist.ts_value)` row, refreshed after
every backfill/append, else the newly-archived window is served by BOTH sides (proven
double-count in the init-script header: ent3 352,136 → 196,671 after the fix).

### 1.2 Cold Parquet layout (S3)

| | Staging `packiot-staging-historian-639178078294` | Prod `packiot-production-historian-639178078294` |
|---|---|---|
| Prefixes | `equipment_values/`, `equipment_events/`, `athena-results/`, `_watermark/` | `equipment_values/`, `athena-results/` |
| EV partitions | 26 enterprises (incl. **orphan `enterprise=5`**) | **1** (`enterprise=1` = legacy CPACK) |
| EV legacy id-space | **F3** (CPACK = `enterprise=3`, deep-remapped at unload) | **legacy** (CPACK = `enterprise=1`, remapped in-view) |
| EV file naming | `*-legacy.parquet` (one-shot backfill) + `data-YYYY-MM-DD.parquet` (daily append, Athena-only) | `data-YYYY-MM-DD.parquet` only |
| EE partitions | **19 enterprises, legacy id-space** (`enterprise=1`,`33`,…); id stored legacy **inside** the file too | **none** |
| Partitioning | hive `enterprise=/year=/month=`, projection resolved (no crawler) | same |

**Data-quality probes (`read_parquet` through the gateway):**
- `enterprise=100` legacy (2021-12): 519,924 rows, gross/net/scrap **100 % NULL**.
- `enterprise=3` legacy (2026-09): 610,771 rows, gross **51 % NULL**, net **49 % NULL**.
- File health (per the raw-schema doc, unchanged): ~961 EV objects, 82 % < 16 MB, 0 in the
  128 MB–1 GB band → many-tiny-files scan tax.

### 1.3 Athena / Glue catalog

| Glue DB | Tables | Notes |
|---|---|---|
| `packiot_historian_staging` | `equipment_values` (56 col), `equipment_events` (24 col) | EV in terraform; **EE CLI-created, NOT in terraform**; projection `enterprise 0,120`/`year 1970,2027` (terraform drift: `1,100`/`2019,2027`) |
| `packiot_historian` (prod) | `equipment_values` only | pilot table, `enterprise 1,100`, raw legacy id-space; **no EE**; not reconciled with the in-view remap |

Both EV Glue tables are still the **pre-redesign 56-col shape** (`double`/`smallint`,
`id_production_order bigint`, no `ingested_at`/`source_seq`, `ts_value`-first order) — the
raw-schema doc §3 corrected DDL is **not yet applied**.

### 1.4 `hist_*` in `packiot_analytics` (NOT the S3 historian)

| Table | Rows | Size | Consumers |
|---|---|---|---|
| `hist_production_orders` | 20,627 | 5960 kB | none live — only `db/init-f3/snapshot` + `MANIFEST.f3-target` |
| `hist_production_orders_runtime` | 20,590 | 2648 kB | none live — same |

These are **PO snapshots**, unrelated to the equipment_values/events time-series. The name
collision with the S3 "historian" is coincidental. **DROP** (fold into the analytics contract's
drop list, and delete their two `MANIFEST.f3-target` lines so the greenfield parity gate
doesn't re-materialise them).

### 1.5 Consumers (what actually needs what)

| Consumer | Reads | Columns needed |
|---|---|---|
| read-api `POST /v1/historian/production-series` | `ev_all` (view; **not** `ev_between` — pg_duckdb can't wrap `read_parquet` in a fn) | `id_enterprise, ts_value, year, month, id_equipment, gross, net` |
| Superset `historian_union` DB → `ev_all` virtual dataset | `ev_all` via Jinja year/month prune + native RLS `id_enterprise=<n>` | `+ count`, gross, net |
| Superset `packiot_historian` DB (Athena) | Glue `equipment_values` | historical BI dashboards |
| Prometheus | blackbox `probe_success{instance="hist-gateway:5432"}` | liveness only |

**No consumer reads `equipment_events` cold, and none reads scrap/quality/state from the
cold store.** The gateway's serving surface is intentionally narrow: production increments
(+ `speed` on prod) per equipment per time.

---

## 2. Used / dead classification (with evidence)

**KEEP (canonical, load-bearing):** `ev_all`, `ev_between`, `hist`, `hist_cutover`,
`live.equipment_values` FDW, the EV cold archive, the EV Glue table + Athena workgroup,
the `historian_union` + `packiot_historian` Superset DBs, the append/backfill scripts.

**DROP:**
- `refresh_hist_cutover()` (staging) — broken plpgsql trap; the working refresh is the
  top-level `services/historian-gateway/refresh-hist-cutover.sql`. Evidence: `pg_get_functiondef`
  shows a `SELECT … FROM hist` inside a `plpgsql` body; the init-script header documents
  "pg_duckdb CANNOT execute a DuckDB scan inside a PL/pgSQL function". Prod correctly lacks it.
- `hist_production_orders`, `hist_production_orders_runtime` (analytics) — PO archives, zero
  live consumers; also remove from `MANIFEST.f3-target` (lines 101–102).
- Orphan `enterprise=5` EV Parquet (staging) — 1,671-byte 0-row `data-*.parquet` artifacts,
  no `*-legacy.parquet`, no `hist_cutover` row → invisible to `ev_all`. Delete the prefix.

**RECONCILE (kept but currently inconsistent — the heart of this redesign):**
- The **two `hist`/`ev_all` definitions** (staging vs prod) → one canonical definition.
- The **three id-spaces** → one (F3).
- EE cold store: **codify or retire** (see §3.5 / §8).
- Glue drift (types, projection ranges, EE codification, prod↔staging).

**UNCLEAR — human call (§8):** whether the cold store must carry *values* for legacy
tenants (the 100 %-NULL problem) or only F3-era; whether EE is ever unioned; whether the
gateway serving surface widens beyond gross/net/speed.

---

## 3. Target schema — the clean historian

### 3.1 One canonical RAW contract (adopt `historian-raw-schema.md`)

The hot≡cold column contract is already designed: `equipment_values` 58 cols /
`equipment_events` 26 cols, **canonical order = analytics ordinal**, with
`real→float` (revert 8 widenings), `int4→int` (revert 20 narrowings),
`int4` for `id_production_order` (revert the bigint widening), `jsonb→string(JSON)`,
`timestamptz→timestamp` **stored as a UTC instant (`isAdjustedToUTC=1`)**, and the two
added lineage cols `ingested_at`,`source_seq`. See that doc §1–§4 for the full table +
the DuckDB unload SELECT. This plan does not restate it; it **depends on it**.

### 3.2 One canonical gateway definition (kill the staging/prod fork)

Replace both boxes' `hist`/`ev_all`/`ev_between` with a single parameterised init script
(`services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh`). Decisions:

1. **id-space = F3 everywhere, remapped at UNLOAD (on disk), not in the view.** The prod
   in-view `CASE enterprise WHEN 1 THEN 3` is a hardcoded, CPACK-only footgun that also
   makes Athena (raw `enterprise=1`) and the gateway (`3`) disagree. Canonical: the cold
   Parquet partition key IS the F3 `id_enterprise` (staging's approach), so `hist` reads
   the partition column directly with **no CASE**. Re-unload prod's `enterprise=1` archive
   into `enterprise=3` to match (§5).
2. **Glob = `*-legacy.parquet`** (staging's convention) on both boxes. It cleanly excludes
   the live `data-*.parquet` daily appends from the cold side so the FDW is the sole hot
   source — belt-and-suspenders with `hist_cutover`. Prod must **rename its
   `data-*.parquet` backfill files to `*-legacy.parquet`** to fit this glob (§5). (The
   daily appends stay `data-*.parquet` = Athena-only, invisible to `ev_all`.)
3. **Serving surface = `{gross_production_incr, net_production_incr, speed}`.** Adopt prod's
   `+speed` on staging too (Superset production charts want it; read-api ignores the extra
   column). Keep it narrow — the gateway is a production-series server, not a raw mirror.
   If a future consumer needs scrap/state, widen deliberately, not speculatively.
4. **`hist_cutover` stays** as the disjointness mechanism. Keep the refresh as the
   **top-level** `refresh-hist-cutover.sql` wired into the append job's post-run hook;
   **drop the broken `refresh_hist_cutover()` function**. Add a boot/CI assertion: "every
   `enterprise=` prefix present under the legacy glob has a `hist_cutover` row" (the missing
   row = silent double-count; today `enterprise=5` would violate it — another reason to
   delete that orphan).
5. **`ts_value`** stays cast to `timestamp` in the view; the raw-schema TZ fix
   (`isAdjustedToUTC=1`) makes that cast lossless. `ev_all`/`ev_between` keep surfacing
   `year`/`month` for partition pruning (load-bearing: cold prunes only on partition cols,
   proven 1 file/0.7s vs 59 files/171s).
6. **FDW target is env-driven** (`FDW_DB`, `FDW_HOST`) — staging `packiot_analytics`/10.10.10.89,
   prod `packiot`/10.20.10.89. No code divergence; only `.env` differs. Document the prod
   DB name is `packiot` (post analytics-rename), not `packiot_analytics`.

### 3.3 Cold Parquet — canonical, consistent, compacted

- Re-unload EV to the §3.1 canonical shape (types/order/lineage/TZ) — raw-schema §4.
- **Unify the id-space** (prod `enterprise=1` → `3`; EE `enterprise=1/33` → F3) so EV and
  EE share one key and every partition is an F3 `id_enterprise`.
- **Legacy NULL production (§1.2):** decide per §8 — either re-derive `*_incr` from the
  legacy source during re-unload (if the legacy columns exist under other names) or
  **contractually document legacy cold rows as coverage-only (NULL values)** and gate BI
  so legacy-window production tiles read the hot/aggregate path, not raw cold.
- **Compaction:** roll `data-YYYY-MM-DD.parquet` → `data-YYYY-MM.parquet` (NOT
  `*-legacy.parquet` — that glob is the cold side); one file per `enterprise/year/month`;
  row-count parity gate before deleting sources; monthly "seal last month" job (raw-schema §5).
- Delete the `enterprise=5` orphan empties.

### 3.4 Athena / Glue — codified, drift-free, symmetric

- Apply the raw-schema §3 corrected EV DDL (56→58 cols, `double→float`, `smallint→int`,
  `bigint→int` on `id_production_order`, `+ingested_at,+source_seq`).
- **Codify `equipment_events` in terraform** for BOTH `packiot_historian_staging` and
  `packiot_historian` (today: CLI-only on staging, absent on prod).
- Fix projection ranges to the deployed `enterprise 0,120` / `year 1970,2027` in terraform.
- Bring the **prod** Glue EV table to the same 58-col shape + F3 id-space after the prod
  re-unload, so Athena and the gateway agree.

### 3.5 `equipment_events` cold — resolve its status

It exists (462 objects, staging) but is un-codified, legacy-id, and unconsumed. Two coherent
end states (pick in §8):
- **(A) Promote:** re-unload to canonical F3 id-space + §2 types, codify Glue in terraform
  (both envs), and add an `ev_all_events` union + a read-api downtime/OEE-reconstruction
  endpoint. Justified by "OEE reconstruction needs downtime→Availability" (the backfill
  script's stated goal).
- **(B) Retire:** if OEE reconstruction from cold events isn't a product requirement, delete
  the `equipment_events/` prefix and the Glue table; stop the events-backfill script.

Do **not** leave it in today's limbo (data on disk, no contract, no consumer, no codification).

---

## 4. Rename / reconciliation map (old → new)

The historian is already well-named (`ev_all`, `hist`, `hist_cutover`, `ev_between`) — the
"renames" are consistency reconciliations, applied during the expand/contract cutover:

| Old (where) | New (canonical) | Why |
|---|---|---|
| prod `hist` view `CASE enterprise WHEN 1 THEN 3` | partition key already = F3 id; **no CASE** | remove hardcoded CPACK-only remap; Athena↔gateway agree |
| prod EV cold `enterprise=1/**/data-*.parquet` | `enterprise=3/**/*-legacy.parquet` | unify id-space (→F3) + glob (→legacy) with staging |
| EE cold `enterprise=1`,`33` (+id inside file) | `enterprise=<F3 id>` | one id-space across EV and EE |
| staging `refresh_hist_cutover()` fn | (dropped) → `refresh-hist-cutover.sql` top-level | the fn is broken by construction |
| Glue `packiot_historian_staging.equipment_values` 56-col | 58-col canonical (raw-schema §3.1) | revert type deviations + add lineage |
| Glue EE (CLI-only / prod-absent) | `aws_glue_catalog_table.equipment_events` in terraform ×2 | close codification gap |
| terraform `projection.enterprise.range 1,100` / `year 2019,2027` | `0,120` / `1970,2027` | match deployed |
| `data-YYYY-MM-DD.parquet` (append dailies) | `data-YYYY-MM.parquet` (sealed monthly) | compaction; stays off the `*-legacy` glob |
| analytics `hist_production_orders(_runtime)` | (dropped) | PO archive, not historian; no consumer |

No column renames inside the gateway views (the 7–8 surfaced columns already match the
canonical names). Column-level renames on the raw tables are the analytics contract's job,
inherited here by the "match analytics" rule.

---

## 5. Cutover plan (expand → contract, staging-first)

**Prereqs (fix first, independent of the redesign):**
- P0a. **DROP the broken `refresh_hist_cutover()`** on staging (a caller silently staleness-bombs `ev_all`). **DONE (2026-09-08)** — dropped live; the refresh stays the top-level `refresh-hist-cutover.sql`.
- P0b. ~~Delete the `enterprise=5` orphan~~ + add the "every legacy `enterprise=` prefix has a
  `hist_cutover` row" boot/CI assertion. **DONE (2026-09-08), with a correction:**
  - **`enterprise=5` is NO LONGER a deletable orphan.** Live S3 (2026-09-08) shows it now holds
    real, growing **daily `data-*.parquet` appends** (2026-08-31 → 2026-09-04, 27 KB → 2.5 MB, one
    per day) — the append job is writing it. These are on the `data-*` glob, **not** `*-legacy.parquet`,
    so they are **invisible to `ev_all`** (no double-count) and visible only to Athena. It has **no
    `*-legacy.parquet`**, so it correctly has no `hist_cutover` row and the coverage assertion does
    not flag it. **DO NOT delete** — that would drop live Athena data. (The plan's original "0-row
    1,671-byte orphan" premise is stale; the daily append re-populated it.)
  - **Coverage assertion SHIPPED** as `scripts/historian-cutover-coverage-check.sh` — a
    **metadata-only** check that compares the S3 `*-legacy.parquet` enterprise set (`aws s3 ls`)
    against the `hist_cutover` rows (`docker exec … psql`), exit 1 on any missing enterprise.
    Run on the gateway box (append-job post-run hook / CI via SSM). Hardproofed live on staging
    (exit 0, "all 25 cold-archive enterprise(s) have a cutover row"; correctly ignores
    `enterprise=5` which has only `data-*` appends) + negative-tested (correctly flags a missing
    enterprise, exit 1).
    - **Design note (why NOT in-SQL):** an in-SQL assertion appended to `refresh-hist-cutover.sql`
      is near-useless — it runs *after* the unfiltered `INSERT … ON CONFLICT`, by which point every
      hist enterprise trivially has a row. The real failure modes (a new `*-legacy` prefix appended
      without a refresh; a hand-filtered refresh) leave `hist_cutover` STALE vs the archive — caught
      only by an INDEPENDENT check against S3, which is what this script does. Also: `SELECT DISTINCT
      id_enterprise FROM hist` is a full ~96 s cold scan (DuckDB does NOT partition-prune a DISTINCT),
      and wrapping it in `CREATE TEMP TABLE AS …` **crashed the pg_duckdb backend** (CTAS-from-parquet
      is unsupported; `INSERT INTO <heap> SELECT … FROM hist` is the only safe scan-into-PG path).
      Both discovered by hardproof 2026-09-08.
- P0c. **Decide EE (§3.5) and legacy-NULL (§3.3)** — both gate the re-unload shape. **RESOLVED — see §7.**

**Phase 1 — unify the gateway definition (additive, no consumer break).**
- Land one parameterised init script producing the canonical `hist`/`ev_all`/`ev_between`
  (F3 partition ids, `*-legacy` glob, `+speed`, no CASE). Because pg_duckdb views are
  metadata-only, this is a cheap `CREATE OR REPLACE` on each box after the data is conformed
  — but sequence it AFTER Phase 2 so the view matches the data it reads.

**Phase 2 — conform the cold data (the heavy step), staging first.**
1. **Apply the Glue DDL first** (widen catalog types before re-unload — Athena reads Parquet
   by name; a widened `int` over old physical `smallint` up-casts cleanly, the reverse does not).
2. Re-unload the legacy EV backfill to the canonical shape (raw-schema §4) into the F3
   id-space + `*-legacy.parquet` keys; `duckdb DESCRIBE` a sample to assert byte-match; swap in place.
3. Re-derive or NULL-document legacy `*_incr` per the §8 decision.
4. EE per §3.5: re-unload canonical (A) or delete (B).
5. Compact dailies → sealed monthlies; delete `enterprise=5`; **re-run `refresh-hist-cutover.sql`**.
6. Assert `ev_all` row-count parity on a frozen window (hot+cold) vs the pre-cutover gateway
   for 2–3 tenants (one legacy, one F3, one live-only), as the RLS-fenced caller, with an
   `EXPLAIN` prune gate (no full-archive scan on a bounded query).

**Phase 3 — repoint / verify consumers.** read-api `/v1/historian/production-series`,
Superset `ev_all` dataset + `packiot_historian` Athena datasets — no schema change for them
(the 7–8 surfaced columns are unchanged), so this is a **parity re-verify**, not a repoint.
Confirm the Prometheus probe stays green across the gateway re-init.

**Phase 4 — codify + contract.**
- Terraform: EV 58-col DDL, EE table ×2, projection ranges, prod↔staging symmetry
  (`terraform import` to avoid click-ops drift, per the historian.tf apply note).
- DROP `hist_production_orders(_runtime)` + their `MANIFEST.f3-target` lines.
- Prod: repeat Phase 2/3 on the prod box (`i-0a5c5dadd9ea5e93e`, bucket
  `packiot-production-historian-*`, FDW `packiot`@10.20.10.89) — its cold store is CPACK-only,
  so the prod re-unload is small, but it is the one that removes the in-view CASE + renames
  `data-*`→`*-legacy` + shifts `enterprise=1`→`3`.

**Gate to production:** the staging parity + prune gates green, then the same conform→verify
on prod. Keep `HISTORIAN_APPEND_ENABLED` false until the ADR-0045 P1 decode-spike fix is
confirmed live (else the canonical re-unload re-archives spikes).

---

## 6. Risks & reconciliation

- **Prod ≠ staging by design, not accident.** Prod is the "db3 union" built on a different
  strategy (in-view remap, `data-*` glob, `+speed`, CPACK-only). The unification in §3.2 is
  the whole point — do **not** copy staging's init script onto prod without the prod
  re-unload (§5 Phase 4), or the `*-legacy` glob will read zero prod files.
- **`hist_cutover` staleness = double-count.** Any backfill/re-unload that extends cold MUST
  be followed by `refresh-hist-cutover.sql`. The broken function invites the opposite.
- **Legacy NULL production is a product decision, not just a bug** — re-deriving it may be
  impossible if the legacy source never stored `*_incr`; the honest fallback is "cold = coverage,
  values NULL for legacy" + a BI guard. Surface it before promising historical production charts.
- **pg_duckdb constraints are load-bearing:** simple query protocol only (read-api), no
  `read_parquet` inside a function (the `refresh_hist_cutover()` bug + why read-api inlines
  `ev_all` not `ev_between`), tenant must arrive as a literal (no GUC RLS on the cold path —
  Superset RLS + read-api server-cid are the SOLE tenant fences; keep `ev_all` out of SQL Lab).
- **EE id-space** — if EE is promoted (§3.5 A) without the id remap, ent=1 CPACK events won't
  join ent=3 CPACK values. Remap is mandatory before any EE union.

## 7. Decisions — RESOLVED (2026-09-08, hardproofed)

1. **Legacy cold production values → NULL + BI-guard (IRRECOVERABLE; do NOT re-unload for value
   recovery).** HARDPROOF (`read_parquet`/local `duckdb DESCRIBE`+null-fraction on the actual
   `*-legacy.parquet`):
   - The legacy parquet carries BOTH the delta cols (`gross/net/scrap_production_incr`) AND the
     cumulative totalizer cols (`gross/net/scrap_production_val`) — so re-derivation of `*_incr`
     from `*_val` is *a priori* possible **only where `*_val` is populated but `*_incr` is NULL**.
   - `enterprise=100` (2021-12, 519,924 rows): `*_incr` **and** `*_val` are **100 % NULL** — no
     source to derive from.
   - `enterprise=3`/CPACK (2022-08, 1,926,657 rows): `*_incr` **and** `*_val` **100 % NULL**.
   - `enterprise=3`/CPACK (2026-08, 5,474,361 rows): `gross_production_incr` 56.7 % NULL /
     `gross_production_val` **56.7 % NULL** (identical); `net` 53.1 % / 53.1 % (identical). Crucially,
     `count(*) WHERE gross_production_incr IS NULL AND gross_production_val IS NOT NULL = 0` — **not a
     single row** has the totalizer without the increment. **The `*_val` column is NULL in lockstep
     with `*_incr`.**
   - **Conclusion:** the legacy source simply did not record production for those rows (coverage /
     heartbeat rows, not readings). There is **nothing to re-derive** — a re-unload recovers zero
     values. Verdict = **NULL, contractually "cold = coverage store for legacy windows" + BI-guard**.
   - **BI-guard status: already satisfied on the read path.** read-api `historian.go` serves
     `sum(gross_production_incr)` / `sum(net_production_incr)` — SQL `sum()` **skips NULLs** (no
     `COALESCE(...,0)`), so an all-NULL legacy window returns a NULL sum (honest "no data"), never a
     fake 0. **Superset path also confirmed clean (2026-09-08):** `configs/superset/assets/datasets/
     historian_union/ev_all.yaml` metrics are `SUM(gross_production_incr)` / `SUM(net_production_incr)`
     — no `COALESCE(...,0)`, so legacy all-NULL windows render as gaps, not zeros. **BI-guard satisfied
     on BOTH consumers; decision 1 fully closed.**
   - **Consequence for Phase 2:** the heavy "re-unload legacy EV to the canonical 58-col shape" step
     delivers **no value recovery**. Its only residual benefit is type-canonicalisation
     (double→float, smallint→int) + lineage cols — but the gateway view already casts types at read
     time and the serving surface is narrow `{gross,net,speed}`, so this is **cosmetic**. **De-scoped:
     do not re-unload legacy EV for values.** (Type/lineage canonicalisation, if ever wanted, is a
     low-priority cleanup, not a cutover blocker.)

2. **`equipment_events` cold → PROMOTE (locked), but promotion is NON-TRIVIAL due to a hot-side
   overlap found 2026-09-08.** Facts:
   - Cold EE on staging: 19 enterprise partitions, **legacy id-space** (biggest: `enterprise=1`=57
     files=CPACK-legacy, `enterprise=33`=63 files=another tenant); id stored legacy **inside** the
     file too. Spans to 2026-09 (`data-YYYY-MM-legacy.parquet`, already monthly-compacted).
   - **CRITICAL OVERLAP:** `db/cutover/f3-phasec-history-backfill.sql` **already loaded 197,011 CPACK
     pre-cutover `equipment_events` (with irreplaceable operator reasons/notes) into the HOT F3
     analytics DB under ent-3**, surfaced in `v_report_downtimes`. So CPACK deep-history downtimes
     **already live in the hot store** — the cold EE archive for CPACK (`enterprise=1`) **overlaps**
     what Phase-C put in hot ent-3.
   - **Therefore a naïve `ev_all_events = hot ∪ cold` union DOUBLE-COUNTS CPACK events** in the
     Phase-C-backfilled window — exactly the `hist_cutover` problem, for events. Safe promotion
     **requires an events-cutover boundary** (`ev_events_cutover`, analog to `hist_cutover`:
     `cutover = max(cold EE ts_event)` per enterprise, hot owns `>`, cold owns `<=`), **AND** must be
     reconciled with the Phase-C hot backfill window per enterprise. This needs **analytics-owner
     coordination** (they own the hot EE table + the Phase-C backfill).
   - EE id-remap (`enterprise=1`→`3`, `33`→its F3 id) is **mandatory before any union** (EV is F3;
     EE joins EV on `id_enterprise`).
   - **Status: EXECUTED on STAGING for CPACK (2026-09-08, task #227), hardproofed + reversible.**
     Gateway/S3/Glue side + authored (undeployed) read-api endpoint done; prod is a later round.
     What landed:
     - **CPACK EE re-unload 1→3** (enterprise-only remap — equipment ids are STABLE across the
       remap, verified: cold ent-1 and hot ent-3 share the active machine ids 60–108, UNLIKE
       Incoplast's deep equipment re-key). 57 files, schema-identical (DESCRIBE), aggregate parity
       1,519,494 rows exact. `scripts/historian-events-reunload.sh` (parameterised, resumable).
     - **`ev_events_cutover` is HOT-ANCHORED** (the MIRROR of `hist_cutover`): `cutover_ts =
       min(hot ts_event)` per enterprise; COLD owns `ts_event < cutover`, HOT owns `>=`. CPACK
       boundary = **2026-05-28** (the Phase-C hot floor). This is because Phase-C loaded the deep
       history INTO hot, so hot owns its whole range and cold fills only the pre-hot window.
     - **NO-DOUBLE-COUNT HARDPROOF** (ent-3, window 2026-04-01..2026-09-08): `ev_all_events` union
       = **316,688** = cold_kept **53,959** ⊎ hot_kept **262,729** (disjoint, no gap). Naïve
       hot∪cold = 432,801 would double-count **exactly 116,113** overlap rows; the boundary removes
       precisely them. Prune gate: 1-month bounded query reads **1/57** cold files, 107 ms.
     - **TENANT-SAFETY FIX (found during this round):** the 18 un-promoted legacy-id EE partitions
       (enterprise=2,6,10,13,30,31,33,36,37,99,100,101,102,112,113,116,117,118) numerically COLLIDE
       with real F3 tenant ids → serving them under `ev_all_events` = cross-tenant leak. **Quarantined**
       them + the now-redundant original enterprise=1 to `equipment_events_legacy_unpromoted/` (reversible
       `aws s3 mv`); the served `equipment_events/` prefix is now F3-only (`enterprise=3`), matching EV.
     - Gateway init codified (`10-historian-gateway.sh`: FDW `live.equipment_events`, `hist_ee`,
       `ev_events_cutover` seed, `ev_all_events`) + `refresh-ee-cutover.sql` (hot-FDW aggregate, so
       it MAY be a function — unlike the cold-parquet `refresh-hist-cutover.sql`).
     - Glue EE table authored in `terraform/staging/historian.tf` (import-then-apply, not plain-apply;
       CLI-created table already exists) + prod counterpart documented for Phase 4.
     - read-api `POST /v1/historian/downtime-series` authored (`historian.go`, shared
       `serveHistWindowSeries` helper) + tests — **NOT deployed** (analytics owner owns read-api deploys).
   - **DEFERRED (next unit):** Incoplast **33→4** needs the equipment-id DEEP remap (legacy equip →
     F3 990015–990018, lines dropped) which is NOT in tracked code — a naïve enterprise relabel would
     leave cold events with equipment ids that don't join F3 ent-4. 33 is NOT a double-count blocker
     (excluded from the union). The other 17 quarantined partitions likewise need per-tenant remap
     verification. Promote each by: re-unload to F3 (extend `historian-events-reunload.sh`) → move into
     `equipment_events/` → `refresh-ee-cutover.sql`. No gateway view change needed (glob is F3-only).

3. **Serving surface → CONFIRMED `{gross, net, speed}` (narrow).** `speed` was added to the canonical
   `hist`/`ev_all`/`ev_between` on staging (already present in every `*-legacy.parquet`, surfaced with
   no re-unload). Widen only on demand. (EE promotion adds a *separate* events surface, not columns here.)

4. **Retention:** staging prunes cold at 180 d (`terraform/staging/historian.tf` lifecycle). **Prod
   `terraform/production/historian.tf` now EXISTS** in this repo (untracked working tree; part of the
   prod-hardening branch) — verify its tiering (365 d→IA, 730 d→GIR) at Phase 4 before relying on it.

### §8-EE — EE promotion runbook (the handed-back next unit)

Ordered, staging-first, each step reversible; coordinate step 0 with the analytics owner (#226):
0. **[coord]** Confirm the Phase-C hot backfill window per enterprise (`min/max ts_event` of the
   197,011 ent-3 rows in `packiot_analytics.equipment_events`) so the events-cutover is set to hand
   the overlap to exactly one side. Decide: is cold EE for CPACK even needed (hot already has it),
   or is cold EE only for tenants/windows NOT in hot? (Likely: cold owns pre-hot-earliest, hot owns
   the rest.)
1. **Re-unload EE to F3 id-space** (`enterprise=1`→`3`, `33`→F3, …) + canonical types, into
   `*-legacy.parquet` keys — mirror `scripts/historian-events-backfill.sh` but add the id remap
   (it currently writes legacy ids). DESCRIBE-assert byte-match; swap in place; row-count parity gate.
2. **Add `ev_events_cutover` + `ev_all_events`** to the gateway init script (analog to
   `hist_cutover`/`ev_all`); refresh cutover after the re-unload. Requires the hot EE table imported
   as a second FDW foreign table (`live.equipment_events`, pinned cols).
3. **Codify EE Glue** in terraform for BOTH `packiot_historian_staging` and `packiot_historian`
   (today: staging CLI-only, prod absent).
4. **read-api downtime/OEE endpoint** (`POST /v1/historian/downtime-series` or similar) reading
   `ev_all_events`, tenant-fenced by server-cid (mirror `historian.go`); simple protocol; inline union.
5. **Hardproof:** tenant-fenced row-count parity on a frozen window vs hot-only for one legacy / one
   F3 / one live-only tenant; EXPLAIN prune gate; **double-count check against the Phase-C hot window**.

---

## 8. Appendix — hardproof commands (2026-09-08, read-only)

- Gateway relations/functions/cutover/FDW cols: `docker exec hist-gateway psql -d postgres`
  on `i-06c9547a2c7091ab7` (staging) and `i-0a5c5dadd9ea5e93e` (prod) — `pg_class`,
  `pg_get_viewdef('hist'|'ev_all')`, `pg_get_functiondef('refresh_hist_cutover')`,
  `pg_foreign_server`, `SELECT * FROM hist_cutover`.
- Cold layout + data quality: `aws s3 ls` on both buckets; `read_parquet('s3://…')` null-fraction
  probes through the gateway (ent=100 = 100 % NULL, ent=3 = ~50 % NULL; EE ent=1 id_enterprise=1).
- Catalog: `aws glue get-table --database-name packiot_historian_staging|packiot_historian`.
- `hist_*` analytics: `pg_class`/`information_schema` on `timescaledb`@`i-064bb36d1c454d861`;
  consumer grep across read-api/edge-api/front4/reports + `db/init-f3/MANIFEST.f3-target`.
- Scripts: `scripts/historian-append.sh` (legacy=ent1 / new-prod=ent3 intent, 56-col projection,
  `data-*.parquet`, `HISTORIAN_APPEND_ENABLED` gate), `scripts/historian-events-backfill.sh`
  (`SELECT *` legacy shape, legacy id partitions, `*-legacy.parquet`).

**Related:** `db/design/historian-raw-schema.md` (the RAW column contract this extends),
`docs/plans/analytics-clean-schema-redesign.md` (the sibling), the gateway init script +
`refresh-hist-cutover.sql`, `configs/superset/assets/{databases,datasets}/historian_union*`,
`services/read-api/cmd/refdata-api/historian.go`, `terraform/staging/historian.tf`.
