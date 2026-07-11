# Production DB (tsp12 / packiot40) — Senior-DBA Audit — 2026-07-11

**Scope:** read-only health audit of the production client database `tsp12` / `packiot40` (all tables, functions, procedures), triggered by client-reported "table processing" issues. Cross-referenced against the staging refactor (`packiot` = F1/F2, `packiot_shadow` = F3) to determine which legacy defects were **inherited** vs **shed**.
**Question answered:** *what legacy problems live in prod, which did the refactor inherit, and what do we tune on staging?*
**Constraints:** tsp12 was accessed **strictly read-only** (`BEGIN READ ONLY`, `awslambda` role — SELECT-only). **No changes were made to prod.** Every fix lands on staging; prod-side items are recommendations for the client.

**Instance snapshot:** PostgreSQL 12.11 · 333 GB · TimescaleDB 2.11 · 217 tables · 147 views · 10 matviews · 712 functions · 47 procedures · 19 hypertables · 17 continuous aggregates.

---

## TL;DR — findings ranked

| # | Severity | Finding | Evidence | Inherited by staging? | Action |
|---|----------|---------|----------|-----------------------|--------|
| 1 | 🔴🔴 | **122 GB custom invalidation log, never pruned** | `agg_equipment_values_1min_t_invalidation` 75 GB + 30 GB PK + 17 GB unused index = ~37% of DB; **485M rows**; fed by trigger `piot_feed_invalidation_log` on every `equipment_values` insert; **no function/proc deletes from it** | **No** — trigger absent in staging (only a 16 KB empty shell in `packiot.public`) | Client: prune + fix consumer. Staging: drop the empty shell |
| 2 | 🔴 | **Statements averaging 25–82 s/call** | `pg_stat_statements`: #1 = 82 s avg × 104,354 calls = **2,394 cumulative hrs**; several at 25–55 s | Partially — same slow `piot_*` compute; **replaced** by the Go rollup | Go rollup + provision-perf work (#55, #58) |
| 3 | 🔴 | **`user_logs` missing index** | 144k seq scans reading **69 billion** cumulative rows (466 MB table, only PK) | Latent — staging low-traffic, PK-only | Add secondary index on staging + recommend to client |
| 4 | 🔴 | **Compression policy failing 47%** | `policy_compression` on `equipment_values`: 319 failures / 682 runs | TBD | Client: investigate failing chunks |
| 5 | 🟠 | **Autovacuum starvation** | `cron.job_run_details` last vacuumed 7 wks ago; `area_runtime_1hour` 3 wks; `scale_factor=0.2` too lax for 16M-row tables | **Yes** — staging also `0.2` | ✅ **Tuned** — 24 hot tables → `0.02` |
| 6 | 🟠 | **`max_wal_size=1GB`** (too small for 333 GB write-heavy) | `pg_settings` | **Yes** — staging also 1 GB | ✅ **Tuned** — staging → 4 GB |
| 7 | 🟠 | **~25 GB+ unused indexes** | `idx_scan=0`: 17 GB invalidation idx, ~5 GB pg_cron, dashboard PKs, over-indexed cagg `_hyper_158` | Partially — ~300 MB unused `equipment_values` idx on `packiot` | Confirm-then-drop (needs days of counters) |
| 8 | 🟠 | **pg_cron history unbounded** | `cron.job_run_details` 8.3 GB, no retention | Latent — `packiot` 11 MB (same design) | Add retention job on staging |
| 9 | 🟡 | **No-PK tables** | `monitoramento_execucao_functions` 2.1 GB; several report tables | **Yes** — staging `uns_metrics` (1.2 GB), `production_orders_runtime` | Add keys after dedup check |
| 10 | 🟡 | **Enterprise-hardcoded mega-functions** | `piot4_13_get_production_po` (46k chars), `h_piot_oee_score_full_*`, `get_report_shift_enterprsie_06*` (20–46k chars) | Refactor parameterizes | Ongoing (no-hardcoded-ids direction) |
| 11 | 🟡 | **`max_background_workers`** | prod = 8; **staging = 16** (worse — drove cagg refresh thrash) | Staging worse | Staged → 8 (needs DB-host restart) |

---

## 1 — The 122 GB invalidation monster (🔴🔴 the headline)

**Mechanism.** A custom trigger on `equipment_values`:

```sql
CREATE OR REPLACE FUNCTION public.piot_feed_invalidation_log() RETURNS trigger AS $$
BEGIN
    if NEW.ts_value < date_trunc('minute', now()) - interval '9 minute' then
        insert into agg_equipment_values_1min_t_invalidation (ts_value, id_equipment, id_enterprise)
          values (NEW.ts_value, NEW.id_equipment, NEW.id_enterprise) ON CONFLICT do nothing;
    end if;
    RETURN NEW;
end; $$ LANGUAGE plpgsql;
```

Every insert of data more than 9 minutes late appends a `(ts_value, id_equipment, id_enterprise)` row. This is a hand-rolled "late-data invalidation queue" for re-materializing the 1-minute aggregate — **separate from** TimescaleDB's own invalidation log (a healthy 165 MB).

**The defect.** *Nothing prunes it.* A repo-wide search of prod functions/procedures for a `DELETE` against this table returned **none**. The consumer that was supposed to drain it either never deletes or was removed. Result:

```
agg_equipment_values_1min_t_invalidation        75 GB   (485,623,584 rows)
  ..._invalidation_pk                            30 GB
  ..._invalidation_id_equipment_idx             17 GB   (idx_scan = 0 → never even read)
                                               ─────
                                              122 GB   ≈ 37 % of the 333 GB database
```

Every `equipment_values` write pays a per-row insert tax into this table; every refresh/read that touches it scans a mountain. This is a prime suspect for the client's slowness.

**Cross-reference / verdict.** The staging refactor **dropped this entirely** — no `feed_invalidation_log` trigger and no trigger at all on `equipment_values` in `packiot` or `packiot_shadow`; only an empty 16 KB leftover shell table in `packiot.public`. **This is the single strongest validation of the refactor.**

**Recommendations.** *Client (prod):* prune the table (bounded batched `DELETE`, oldest-first) and either fix or remove the consumer; the trigger should ultimately go. *Staging:* drop the empty shell (cosmetic).

## 2 — Compute cost centers (🔴)

`pg_stat_statements` (query text hidden — `awslambda` is not superuser — but timing is visible):

| total time | avg/call | calls |
|---|---|---|
| 8,616,378 s (2,394 hrs) | **82 s** | 104,354 |
| 2,609,989 s | 8.9 s | 294,566 |
| 525,650 s | **55 s** | 9,630 |
| 511,256 s | 53 s | 9,643 |

Statements averaging **25–82 seconds per call** are the "tables aren't processing" symptom. This matches the staging finding that `piot_create_equipment_runtime_shift()` burns ~14 min of CPU per run (**#58**) and the legacy OEE rollup functions are the largest, most complex bodies in the DB (finding 10). The refactor replaces these with the Go rollup engine.

## 3 — `user_logs` missing index (🔴)

`user_logs` (466 MB) carries only its PK, yet shows **144,552 sequential scans reading 69,130,150,318 rows** cumulatively — the mirror-worker and reports full-scan it. Add a secondary index matching the hot predicate (likely `(id_enterprise, ts_event)`). Low-traffic on staging today, but the same PK-only shape is present — add it proactively.

## 4–8 — Bloat, WAL, indexes, autovacuum, pg_cron

- **Compression** on `equipment_values` fails 47% of runs (319/682) though the bulk is compressed (1332/1404 chunks) — noisy and worth pinning down which chunks error.
- **Autovacuum** is too lax (`scale_factor=0.2` = wait for 20% dead): `cron.job_run_details` unvacuumed 7 weeks, `area_runtime_1hour` 3 weeks; big runtime tables carry 10–16% dead tuples.
- **`max_wal_size=1GB`** on a 333 GB write-heavy DB → checkpoints far too frequent → periodic I/O storms.
- **~25 GB+ unused indexes** (the 17 GB invalidation index, ~5 GB on pg_cron, dashboard-table PKs, and a heavily over-indexed cagg `_hyper_158`).
- **pg_cron** `job_run_details` is 8.3 GB with no retention.

## 9–11 — Design debt

- **No-PK tables:** `monitoramento_execucao_functions` (2.1 GB) and several report tables — replication/dedup hazards.
- **Enterprise-hardcoded mega-functions:** the largest function bodies are per-enterprise-hardcoded (`piot4_13_...` 46k chars, `..._enterprise_06*`) — the "no hardcoded enterprise ids" debt the refactor is unwinding.
- **`timescaledb.max_background_workers`:** prod 8, **staging 16** — staging is over-parallelized, which drove the cagg-refresh I/O thrash we hit while draining the F3 rollup.

---

## Inheritance summary

**Shed by the refactor (wins):**
- The 122 GB `feed_invalidation_log` trigger + table (finding 1).
- pg_cron owning OEE work — gone on `packiot_shadow` (the Go worker owns it).
- The 25–82 s stored-procedure compute — replaced by the Go rollup engine.

**Inherited (config/hygiene) — tuned on staging:**

| Inherited | Fix applied (staging, 2026-07-11) |
|---|---|
| `autovacuum_vacuum_scale_factor = 0.2` | → `0.02` + 5k threshold on 24 hot tables across F1/F2/F3 (live `ALTER TABLE`) |
| `max_wal_size = 1 GB` | → `4 GB` (live `ALTER SYSTEM` + reload) |
| 1-second caggs re-materializing huge windows | `ca_discrete_changes_1s` `start_offset` 2h→30min + sched 1min→15min (per-run 19min→~5min); `ca_equipment_boxes_1s` 2day→6h |
| `max_background_workers = 16` | Staged → `8` (`pending_restart=true`; applies on next `10.10.10.89` DB-host restart) |
| pg_cron unbounded history | Retention job (planned, #60) |
| No-PK tables (`uns_metrics`, `production_orders_runtime`) | Add keys after dedup (planned, #60) |

> **Note:** the staging `alter_job` / `ALTER SYSTEM` changes above are **live-only** and must be baked into the cagg + Postgres config migration SQL so they survive a rebuild (tracked in #60).

---

## Bottom line

The client's prod pain is **largely legacy and largely independent of the refactor** — the 122 GB unpruned invalidation log and the missing `user_logs` index alone would explain "tables not processing." The refactor into `packiot_shadow` + the Go engine **sheds the three worst defects**; what it inherited is config/hygiene, now tuned. This audit is itself a strong argument for completing the migration.

*Access path (for reproduction): SSM → staging EC2 → fetch `databaseCredentials` (Secrets Manager, us-east-1) → `psql` read-only. Prod credentials are never persisted. Related tasks: #55, #57, #58, #59, #60.*
