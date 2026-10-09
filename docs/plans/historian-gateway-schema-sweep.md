# Historian-gateway schema sweep — redesign & improvement proposals

**Scope:** the `hist-gateway` container (`pgduckdb/pgduckdb:16-main`) on the staging
app box — its own Postgres (`db postgres`, user `postgres`) exposing the hot∪cold
union `ev_all` / `ev_all_events`. This is a **necessity/redesign audit**: findings +
prioritized recommendations, grounded in the live gateway, the init script
(`services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh`), and
the consumers (read-api `services/read-api/cmd/refdata-api/historian.go`, Superset
`configs/superset/assets/datasets/historian_union/ev_all.yaml`). **Nothing here is
executed** — staging only, and the redesign itself is left for a gated follow-up.

Date: 2026-09-14. Author: audit pass. Status: **DONE**.

> **Execution status (2026-09-14):** all recommendations landed.
> - **R1, R3** — #1254 (`t271` promoted allow-list + `ev_promoted`-gated cutover refresh).
> - **R2, R5, R6, R8, R9** — `db/migrations/t282-historian-gateway-glue/` (gateway + a
>   least-privilege `histgw_ro` remote FDW role on packiot_analytics). Cold id-space
>   provenance is now in `hist_promoted_enterprise` + `docs/audits/historian-cold-id-provenance.md`.
> - **R4, R7** — scheduled checks: `scripts/historian-staleness-monitor.sh` (R4/R5),
>   `scripts/historian-ee-coverage-check.sh` (R7), aggregated by
>   `scripts/historian-integrity-monitor.sh` on the `historian-integrity-monitor.timer`
>   (daily 04:00 UTC, app box). R5's stamp is written by the append post-run hook
>   (`scripts/stamp-hist-meta.sql`, wired in `historian-staging-run-append.sh`).
> - **R10** — skipped (cosmetic `cold` schema, low value).

---

## 0. What's actually live (ground truth)

| Schema | Object | Kind | Notes |
|---|---|---|---|
| `live` | `equipment_values` | foreign table | pinned 8-col FDW → `silver.equipment_values` on 10.10.10.89 |
| `live` | `equipment_events` | foreign table | `IMPORT FOREIGN SCHEMA silver` (full col set) |
| `public` | `hist` | view | pg_duckdb `read_parquet('.../equipment_values/*/*/*/*-legacy.parquet')` |
| `public` | `hist_ee` | view | pg_duckdb `read_parquet('.../equipment_events/*/*/*/*-legacy.parquet')` |
| `public` | `hist_cutover` | table | 25 rows, PK(id_enterprise); EV boundary = max(cold ts) |
| `public` | `ev_events_cutover` | table | 4 rows, PK(id_enterprise); EE boundary = min(hot ts) |
| `public` | `ev_all` | view | HOT(live>cutover) ∪ COLD(all hist) — legacy-priority |
| `public` | `ev_all_events` | view | HOT(all live) ∪ COLD(hist_ee<cutover) — hot-anchored |
| `duckdb` | extensions/tables + iceberg types | pg_duckdb internal | leave alone |

Roles: `postgres` (superuser), `dev@packiot.com` (superuser), and now
`cloudbeaver_histro` (NOSUPERUSER, SELECT-only browser — see the CloudBeaver work).

**Live tenants (hot, last 24h):** `id_enterprise ∈ {3, 5, 2000003}`.
**EV cold tenants (hist_cutover):** `{0,2,3,4,6,10,13,30,31,35,36,37,38,99,100,101,102,111,112,113,116,117,118,10016,1000000}`.
**EE cold tenants (ev_events_cutover):** `{3,4,5,2000003}`.

Double-count guard verified live: `ev_all` for ent 3, 2024-01 returns **6,297,560**
rows == cold `hist` for that partition exactly (hot contributes 0, since ent-3 hot
starts at its 2026-09-04 cutover). The T2b legacy-priority union is behaving correctly
for that tenant.

---

## 1. Hot∪cold union model — correctness review

### 1.1 EV (`ev_all`) legacy-priority — CORRECT, but the invariant is fragile
`ev_all` = `live WHERE ts>cutover(e)` ∪ `hist (all)`, cutover(e)=max(cold ts). Disjoint
at the instant, live fills forward. Spot-check above confirms no double-count. The
design is sound. **The fragility is operational, not logical** (see §2 staleness).

### 1.2 EE (`ev_all_events`) hot-anchored — CORRECT and consistent with EV
EE is the mirror: hot holds the deep history (a backfill loaded ~197k CPACK pre-cutover
events into the hot F3 store with irreplaceable operator notes), so it is HOT-anchored —
`cutover(e)=min(hot ts)`, cold owns `ts<cutover`, hot owns `ts>=cutover`. The asymmetry
vs EV is deliberate and documented in the init header, and the boundaries are stored in
two separate tables so the two anchoring directions never get confused. **Good.** The
one soft spot is the documented completeness caveat: handing the overlap window entirely
to hot assumes hot fully covers it for *all* equipment of that tenant; a partially
backfilled promoted tenant would be *under*-covered (conservative failure — no
double-count, but a gap). Worth a periodic reconciliation check (see §5, R7).

### 1.3 🔴 HIGH — EV cold has NO unpromoted-holdout; EE does. Latent cross-tenant leak.
This is the headline finding. The **EE** cold glob is F3-only by construction —
un-remapped legacy partitions are quarantined under `equipment_events_legacy_unpromoted/`
precisely because *"their legacy ids collide numerically with real F3 tenant ids, so
serving them would be a CROSS-TENANT LEAK"* (init header). **EV has no such quarantine**:
`hist` reads `equipment_values/*/*/*/*-legacy.parquet` unconditionally, and `hist_cutover`
shows cold enterprise ids that are plainly *not* F3 tenants: `0, 2, 10016, 1000000`
(with old cutover_ts: 2022–2024), mixed in with the F3-remapped ids (recent 2026-09-04
cutover_ts). The tenant fence is a caller-supplied `id_enterprise = <literal>`, so:

- **Today:** benign. Live F3 tenants are `{3,5,2000003}`; a query for tenant 5 or
  2000003 finds no matching cold partition, tenant 3 is genuinely remapped. No real
  tenant currently collides with a legacy-only cold id.
- **The trap:** the moment a *new* F3 tenant is assigned a low id that numerically
  equals a legacy-only cold partition (e.g. `2`), `ev_all` for that tenant would serve
  **another company's legacy production data** as if it were theirs. There is no RLS
  co-enforcer to catch it, and the literal fence matches by construction.

**Recommendation (R1, HIGH, reversible):** bring EV to parity with EE — either
(a) quarantine un-remapped EV partitions under `equipment_values_legacy_unpromoted/`
so the `hist` glob is F3-only, or (b) add an allow-list guard: `hist` (or `ev_all`)
joins an explicit `hist_promoted_enterprise(id_enterprise)` table and only serves cold
rows for verified-remapped tenants. (b) is the smaller change and is fully reversible
(drop the join). Until then, **document a hard rule: never assign a new F3 tenant an
id that appears in `hist_cutover` but not in the F3 tenant registry.**

### 1.4 🟡 MED — id-space provenance is undocumented
The odd cold ids (`0`, `10016`, `1000000`) aren't explained anywhere. `0` is suspicious
(NULL-ish / unassigned). Nobody can currently answer "is cold id 2 the F3 tenant 2 or a
legacy passthrough?" without archaeology. **R2 (MED):** add a `hist_cutover.provenance`
column (`'f3-remapped' | 'legacy-passthrough'`) or a COMMENT + a one-page mapping doc,
so §1.3's collision rule is enforceable by inspection. Reversible, low risk.

---

## 2. 🔴 HIGH — cutover maintenance is manual and currently stale

`hist_cutover.refreshed_at` = **2026-09-04** everywhere; `ev_events_cutover` =
2026-09-08. The load-bearing invariant ("re-run `refresh-hist-cutover.sql` after EVERY
backfill/append that extends the cold store, or the newly-archived window
double-counts") is enforced only by a comment and a hoped-for "append job post-run
hook". `scripts/historian-append.sh` / `historian-append-verify.sh` exist in the tree —
if any append ran after 2026-09-04 without the hook firing, `ev_all` is silently
double-counting the newly-archived window for that tenant right now.

Note the genuine constraint: the EV refresh **cannot** be wrapped in a PL/pgSQL function
(pg_duckdb can't scan parquet inside a function body — a broken `refresh_hist_cutover()`
of exactly this shape was found live and dropped 2026-09-08). So "just add a trigger" is
off the table for EV.

**Recommendations:**
- **R3 (HIGH, reversible):** make the append pipeline *own* the refresh — have
  `historian-append.sh` (and any backfill) unconditionally `psql -f
  /…/refresh-hist-cutover.sql` as its final step, and **fail the job** if the refresh
  errors. This is the only durable fix; the boundary must be refreshed by whatever
  extends the cold store, transactionally with it.
- **R4 (MED, reversible):** add a cheap **staleness monitor** — a scheduled check (host
  cron or the existing monitoring stack) that alerts if `max(hist.ts_value)` for any
  enterprise exceeds `hist_cutover.cutover_ts` by more than a margin, i.e. cold grew
  past the recorded boundary. This is the detector for a missed R3 hook. It reads cold
  (superuser / duckdb role), runs off-hours, bounded to a recent year/month.
- **R5 (LOW):** stamp the cold store's last-append time into a `hist_meta(last_append_at)`
  row so the monitor compares timestamps instead of doing a full cold `max()` scan.

---

## 3. pg_duckdb / S3 cold path

### 3.1 Partition pruning — correct and load-bearing, but only if the consumer cooperates
DuckDB prunes on `year`/`month` (partition cols) only, NOT `ts_value` (hardproof:
59 files/171s vs 1 file/0.57s). `ev_all`/`ev_all_events` surface `year`+`month`, and both
consumers inject the year/month range (Superset via Jinja `{{ from_dttm }}`, read-api in
Go). **This works but is a footgun**: any *new* consumer that filters only `ts_value`
triggers a full-archive scan. **R6 (MED, reversible):** encode the prune contract in the
view itself where possible, or at minimum add a `COMMENT ON VIEW ev_all` stating "a
bounded query MUST carry a year/month predicate or it scans the whole archive", and keep
`ev_all` out of Superset SQL Lab (already the RLS rule).

### 3.2 `-legacy.parquet` glob (F3-only holdout) — right for EE, wrong for EV (see §1.3)
The glob restricting to `*-legacy.parquet` is the promotion mechanism. For EE it's a
genuine tenant-safety boundary (unpromoted held out). For EV the same glob matches
everything (there is no `_unpromoted` prefix), so it provides no isolation — see R1.

### 3.3 `ev_between()` drop — CORRECT, already done (t269)
The broken year/month-pruning helper was dropped (a SQL function body can't run
`read_parquet`). Consumers inline the predicate. Verified absent from the live gateway
and the init script. Nothing to do. (The init's final echo still mentioned
`ev_between()` — fixed in this pass.)

### 3.4 FDW vs direct for the hot side — correct
Hot via `postgres_fdw` (not a second duckdb scan of live) is right: chunk-exclusion
pushdown happens on the remote timescaledb when a `ts_value` predicate is supplied, and
`use_remote_estimate/fetch_size/async_capable` are set so aggregates can push down and
the union's two branches run concurrently. After T2b the hot side is an inherently small
recent tail, so the old "2-day DISTINCT timed out" no longer applies. **Good.** The
pinned 8-col foreign table for `equipment_values` (prune-proof against the remote's
column drop) is a nice touch; `equipment_events` uses full `IMPORT` — acceptable since
it's not in the analytics column-prune, but note it *could* break if a remote EE column
is dropped/renamed. **R8 (LOW, reversible):** pin `live.equipment_events` to the exact
14 columns `ev_all_events` selects, matching the EV pattern, for the same prune-proofing.

---

## 4. Tenant scoping / isolation

The gateway has **no Postgres RLS** — the tenant arrives as a literal `id_enterprise = N`
(pg_duckdb can't evaluate a GUC/STABLE fn during pushdown; it ships into DuckDB which has
no PG context). This is a documented, deliberate constraint. The enforcers:
- **read-api**: injects `id_enterprise = $1` from the *server-resolved* customer id
  (auth middleware), never the request body — identical rule to `/v1/query`. Sound.
- **Superset**: native RLS is the **sole** enforcer; embed/guest tokens carry
  `id_enterprise = <n>` (no dataset scope → applies to every id_enterprise dataset),
  authoring users get a base RLS rule. `ev_all` must stay out of SQL Lab.

**Verdict: the literal-fence model is safe *given* both consumers always inject a
server-derived id — which they do.** The real isolation risk is NOT the literal model;
it's §1.3 (EV cold serving legacy-id partitions to a colliding future tenant), which no
amount of correct literal-injection catches. Fix R1 and the isolation story is clean.

**R9 (LOW, defense-in-depth):** the `cloudbeaver_histro` role added in this session
connects via a `live_pg` user mapping to the *remote* `postgres` superuser. Consider
minting a read-only remote role on packiot_analytics and mapping to that instead, so a
compromised gateway browser role can't ride a superuser FDW identity. Reversible.

---

## 5. Schema hygiene

- **Two-schema split (`public` vs `live`):** `live` = the FDW foreign tables (honest —
  "these live elsewhere"). `public` = the cold parquet *views* + cutover tables + unions.
  Coherent enough, but the cold `hist`/`hist_ee` views are conceptually the mirror of
  `live.*` and arguably belong in a `cold` schema for symmetry. **R10 (LOW, cosmetic,
  reversible):** optional `cold` schema for `hist`/`hist_ee`; low value, defer.
- **Indexes:** cutover tables are tiny (25/4 rows) — PK is sufficient, no extra indexes
  needed. Foreign tables can't carry local indexes (the remote hypertable has them). The
  join `ev_all … LEFT JOIN hist_cutover ON id_enterprise` is a 25-row hash — negligible.
  **No index work needed.**
- **Dead/vestigial:** none found beyond the already-dropped `ev_between`. The `duckdb`
  schema objects are pg_duckdb internals — leave alone.
- **R7 (MED, reversible) — EE completeness reconciliation:** a scheduled check that, per
  promoted tenant, verifies hot EE covers the full overlap window for all equipment
  (guards the §1.2 caveat). Alert-only.

---

## 6. Prioritized recommendations

| # | Pri | Change | Rationale | Risk | Reversible |
|---|-----|--------|-----------|------|-----------|
| R1 | 🔴 HIGH | EV unpromoted-holdout or promotion allow-list (parity with EE) | closes latent cross-tenant leak when a future tenant id collides with a legacy cold id | low (additive join / prefix move) | yes |
| R3 | 🔴 HIGH | append pipeline owns `refresh-hist-cutover.sql`, fails on error | the double-count invariant is currently comment-only; cutover is stale since 09-04 | low | yes |
| R2 | 🟡 MED | document cold id provenance (col/COMMENT + mapping) | makes R1's collision rule enforceable by inspection | none | yes |
| R4 | 🟡 MED | staleness monitor (cold max ts > cutover) | detects a missed R3 hook before it corrupts served numbers | low | yes |
| R6 | 🟡 MED | encode/COMMENT the year/month prune contract on `ev_all` | prevents a new consumer from full-scanning the archive | none | yes |
| R7 | 🟡 MED | EE hot-coverage reconciliation check | guards the hot-anchored completeness caveat | none | yes |
| R5 | 🟢 LOW | `hist_meta(last_append_at)` stamp | cheap monitor input vs full cold scan | none | yes |
| R8 | 🟢 LOW | pin `live.equipment_events` columns | prune-proof EE FDW like EV | low | yes |
| R9 | 🟢 LOW | read-only remote FDW identity for browser role | defense-in-depth | low | yes |
| R10 | 🟢 LOW | optional `cold` schema for hist views | cosmetic symmetry | low | yes |

**Quick wins (do first, no redesign):** R2, R3, R6 — all documentation/pipeline glue,
no data movement. **Larger, gated:** R1 (touches the promotion/unload path and the
cold glob). Everything is reversible; nothing requires a gateway rebuild except R1(a)
(a partition re-unload) — R1(b) (allow-list join) avoids even that.

---

## 7. What was verified live (evidence)

- Object inventory (`pg_class`/`pg_namespace`), role list (`\du`), cutover contents,
  index list — all queried on `hist-gateway` directly.
- Double-count guard: `ev_all` ent-3 2024-01 == cold `hist` exactly (6,297,560), hot 0.
- Prune behaviour and the `ev_between` removal confirmed against the init script header
  hardproofs (EXPLAIN numbers not re-run this pass — bounded cold scans are expensive).
- Tenant id-spaces: hot `{3,5,2000003}` vs EV cold `{0,2,3,4,6,10,13,30,31,35,36,37,38,
  99,100,101,102,111,112,113,116,117,118,10016,1000000}` — the basis for §1.3.
