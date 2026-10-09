# Unified hot+cold serving — grain-tiered retention (design)

Status: **APPROVED 2026-09-23. T0–T4 DONE + LIVE on staging; T5 repo-side done (no prod promotion yet — user decision 2026-09-24).** Proposed ADR: ADR-0060.
Requirement (user): "Our service stack needs to query data from right now and from several years ago
seamlessly. Mainly Superset and frontends." Big-company maturity: codified, observable, least-privilege,
prod-parity.

---

## 1. Where we are (live-verified 2026-09-23, not just repo)

| Consumer | Reads | Sees history? |
|---|---|---|
| Superset (12 `bi.*` datasets) | analytics `packiot_analytics`, `superset_ro`, RLS via `app.tenant_id` | **~90 days** |
| Superset `historian_union` | gateway as **superuser `postgres`**, 1 dataset, **0 charts** | unused |
| front4 / operator via read-api `/v1/query` (~60 datasets → `serving.*` fns) | analytics, `readapi_ro`, RLS | **~90 days**; allows 400d windows → **silent truncation** |
| read-api `/v1/historian/*` | gateway as superuser; staging-only; **no frontend caller** | unused |
| edge-api | analytics | hot only |

Live retention on analytics (`timescaledb_information.jobs` + `purge_analytics_plain`):

| Relation | Size (live) | Coverage | Cut |
|---|---|---|---|
| `silver.equipment_values` (raw) | 1.3 GB | Jul-08 → now | 90 d (Timescale policy; **repo says 2 y = drift**) |
| `bronze.*_raw` | 1.3 GB | | 2 y |
| `silver.agg_…_1min`, `ca_discrete_changes_1s` | | | 90 d |
| `silver.equipment_events` | 143 MB | May-28 → now | 2 y |
| `gold.equipment_oee_hourly` | 201 MB | Jul-04 → | **90 d DELETE daily** (`purge_analytics_plain`) |
| `gold.equipment_oee_shift` | 32 MB | Jun-25 → | **90 d DELETE daily** |
| `gold.equipment_oee_daily/weekly/monthly` | 5–24 MB | Jul → | none |
| `core.production_orders` / `gold.production_orders_runtime` | 32 MB / 5 MB | 2026 only | none |

Whole analytics DB = **9.0 GB**. DB host disk 64 GB, **79 % used (14 GB free)**.

Historian (`packiot_historian` on `hist-gateway`, pg_duckdb over S3 Parquet ∪ FDW): raw EV, EE, POs,
shift-OEE — all 2021→now for CPACK, daily-maintained. But **no `serving.*`/`bi.*` equivalents**, no RLS,
superuser consumers, and pg_duckdb **cannot scan Parquet inside PL/pgSQL** (the `serving.*` functions are
PL/pgSQL) — so "point everything at the gateway" is not possible.

## 2. The key insight: history cost is dominated by RAW, not by what clients look at

Clients (dashboards, frontends) read **aggregates**: OEE by shift/day/week/month, PO headers, downtime
events. Those are tiny: all gold grains for all tenants for ~4 months ≈ 280 MB. Five years of the
coarse grains is **hundreds of MB**, trivially Postgres-sized. The expensive thing is raw
`equipment_values` (1.3 GB per 90 days, ~26 GB / 5 y compressed) — and nobody looks at 3-year-old
per-minute raw except for rare deep dives.

This is the **downsampling / resolution-decays-with-age** pattern every serious time-series shop uses:
RRDtool's round-robin archives, Prometheus+Thanos downsampling (raw 2w → 5m 1y → 1h forever),
Timescale's own guidance (drop raw chunks, keep continuous aggregates longer), Datadog rollups. Industry
standard, not preference.

## 3. Design — three tiers by grain, one query surface per consumer

```
                      ┌──────────────── analytics (Postgres/Timescale, RLS) ────────────────┐
  Superset bi.*  ───▶ │ GOLD / CORE / event grain: RETAINED LONG (5 y+)                      │
  read-api /v1/query ▶│   shift, daily, weekly, monthly OEE   → forever                      │
  (serving.* fns)     │   hourly OEE                          → 13 mo (YoY), compressed      │
  edge-api            │   POs + PO runtime, downtime events   → forever / 5 y                │
                      │ SILVER raw: 90 d HOT (unchanged)                                     │
                      └──────────────────────────────────────────────────────────────────────┘
                                   │ daily cold copy (existing, codified)
                                   ▼
  read-api raw-grain  ─── time router ──▶ historian gateway (pg_duckdb: S3 Parquet ∪ FDW hot)
  Superset "deep dive"  (window start < hot floor)   raw EV/EE/PO 2021→now; read-only role
```

**Tier 1 — Hot analytics keeps every CLIENT-FACING grain long.** Stop deleting gold. Backfill gold/core
history 2021→ from the authentic sources we already hardproofed (historian cold shift grain = legacy
`equipment_runtime_shift`, legacy `_1day/_1week/_1month/_1hour`, historian PO archive). Result: **every
existing `serving.*` function, every `bi.*` view, every Superset chart and every front4 screen sees
years of history with ZERO code changes, full RLS, same latency.** "Seamless" by construction rather
than by a router.

**Tier 2 — Raw stays 90 d hot, years cold.** Unchanged economics. Raw deep history is served by the
historian through ONE explicit, time-routed path.

**Tier 3 — Historian = the archive of record + raw deep-dive engine,** hardened to production standard
(least privilege, codified schema, monitored boundaries). Iceberg (ADR-0057 end state) stays a later
evolution; nothing here blocks it.

### Rejected alternatives
- **Route every consumer through the gateway** — serving fns are PL/pgSQL (can't scan Parquet), no RLS,
  DuckDB latency for interactive frontends, and it rewrites ~60 datasets + 12 bi views. High risk, low gain.
- **Keep everything (incl. raw) 5 y in analytics** — ~26 GB+ raw on a 64 GB host, backup/vacuum/restore
  times grow linearly; that's what the lake is for.
- **Timescale tiered storage** — Timescale Cloud only, not in self-hosted OSS.
- **Trino/Athena federation layer** — a new query engine + ops surface for a problem Tier 1 solves in SQL.

## 4. Workstreams

### T0 — Stop the bleeding + repo = live (small, first)
- Remove gold shift/hourly from `purge_analytics_plain` (shift → keep; hourly → 13 mo, see T1).
- Codify the ACTUAL retention as a migration + a **retention catalog** (`ops.retention_policy`: relation,
  tier, keep, source-of-truth, cold-copy job) — one table answers "how long do we keep X and where is
  the rest?". Fix repo drift (EV 90 d vs repo 2 y; dead `public.*` drop_chunks cron in db_init.sh).
- Capacity: grow DB EBS 64→128 GB gp3 (~$5/mo) + disk alert at 80 %.

### T1 — Long-retained gold + backfill (the "seamless" payload)
- Convert `gold.equipment_oee_hourly` to a compressed hypertable (segmentby id_equipment) → 13-mo policy.
- Backfill 2021→ into analytics (idempotent `ON CONFLICT`, tenant-mapped legacy ent1 → ent3, same
  clamps as the historian archive): shift, daily, weekly, monthly, hourly(13 mo), POs + PO runtime,
  downtime events (verify EE 2 y policy → raise to 5 y).
- **Open DQ question to hardproof first:** `core.production_orders` has 25,683 POs all dated 2026 vs
  legacy ~20k over 5 years — replayed legacy POs likely carry replay-time dates. Backfilling real-dated
  history without reconciling would double-count. Gate: id_order-level reconciliation before insert.
- Parity gates (reuse cutover-readiness queries): per-year counts == legacy, net ≤ gross, OEE ∈ [0,1],
  no duplicate (equipment, ts) keys.

### T2 — read-api time router + honest windows
- Replace hardcoded window caps with the catalog: each dataset declares its grain; the hot floor comes
  from `ops.retention_policy`, not a literal `90d`.
- Raw-grain datasets (`machine-speed`, events timeline, `/v1/query` metric composer): if
  `ts_start < hot_floor` → route to the historian pool (`silver.*` union views, year/month pruning),
  else analytics. Aggregate datasets never route (Tier 1 has them).
- **No silent truncation:** response carries `coverage: {from, to, tier}`; a window beyond ALL tiers
  returns 422, not a short answer.
- Frontends: zero change for aggregates; optional "data from archive" badge using `coverage.tier`.

### T3 — Historian hardening (big-company baseline)
- `historian_ro` login role (NOSUPERUSER, `duckdb.postgres_role`, SELECT on `silver.*`/`gold.*` only);
  move read-api + Superset off `postgres`. Tenant literal enforced server-side (read-api builds it from
  the authed tenant; Superset from the server-minted guest RLS clause) — documented trust boundary.
- Codify live-only gateway objects into `10-historian-gateway.sh` (gold.equipment_oee_shift, id_product
  cols) + a drift check (compare `pg_views` live vs init script) in CI.
- Boundary-coverage + staleness gates → Prometheus metrics + Grafana alerts (double-count and gap become
  pages, not archaeology).

### T4 — Superset
- `bi.*` gains history automatically after T1. Add a date-range default + one "5-year trend" dashboard as
  the acceptance proof. `historian_union` rewired to `historian_ro`, fix stale `schema: cold`.

### T5 — Prod parity + ops
- Template Superset analytics URI (staging host hardcoded today), prod read-api `HIST_GW_*`, prod gateway
  unification (db3-union variant). Backups: verify PITR covers the now-longer-lived gold; restore drill.
- Runbook + wiki update (`06-database.md`, `13-dba-guide.md`).

## 5. Sequencing & risk

T0 → T1 (after the PO-date DQ hardproof) → T3 → T2 → T4 → T5.
T0/T1 deliver ~90 % of the user-visible value (Superset + front4 see years) with the least new code.
Risk controls: every backfill idempotent + gated by parity queries; purge change is additive-safe (keeping
more data); router ships behind `READAPI_HISTORIAN_ROUTING` default-off with shadow comparison.

## 6. Acceptance ("hardproof")
1. front4 OEE / Downtimes / Orders for CPACK with a 2023 window render real numbers == legacy.
2. Superset embed (guest token, ent3) shows a 2021→now OEE trend; a different tenant sees 0 rows (RLS).
3. read-api `machine-speed` for a 2022 day returns historian data with `coverage.tier=cold`; 2-tenant
   isolation test passes on the historian path.
4. `ops.retention_policy` == live Timescale jobs (CI check); gateway drift check green.

## 7. Environment lifecycle — staging now, production next, then cap staging

Staging is the current working environment and runs the **production** retention
profile while we build and prove this. When done:

1. Promote to the production branch (prod gets `ops.retention_policy` via the same
   migration → production profile; historian prod = keep forever + tiering).
2. After prod is verified serving, cap staging to 3 months (cost/storage):
   - analytics: `psql -d packiot_analytics -f db/retention/profiles/staging-capped.sql`
     (next purge run deletes >3 mo, FK-ordered by `purge_order`).
   - historian: `scripts/historian-prune-by-data-age.sh` (WRITTEN, dry-run tested
     2026-09-24: would delete 1,417 objects / ~9.7 GB) — deletes `year=/month=` partitions
     older than 3 months, then re-runs the `refresh-*-cutover.sql`s. Guards: dry-run default,
     refuses non-staging buckets / ENVIRONMENT=production, APPLY needs
     CONFIRM=delete-staging-history. **Not** an S3 lifecycle rule (object age ≠ data age).

## 8. T0 execution log (2026-09-23)

- DB EBS 64→128 GB online (snapshot `snap-0f535e3c42d4e2ae0` first; growpart +
  xfs_growfs; 79%→40%). `db_volume_size_gb` = 128.
- `t-retention-catalog` applied live after a rolled-back dry run proved 0 rows/chunks
  deleted; drift 0; job 1033 run manually → 0 errors, gold shift 53,764 before = after.
  Policy changes: gold shift 90 d→forever, hourly 90 d→13 mo, events 2 y→5 y, bronze
  raw 2 y→90 d (~34 GB/yr leak), 5 previously-unbounded caggs bounded (1.65 GB/80 d leak).
- Landmines defused (repo ≠ live, an apply would have been destructive):
  historian S3 lifecycle (repo re-armed 180 d expiration) and app SG 3101 rule (repo
  would have revoked the DB log relay). app↔db SG cycle broken via imported standalone
  5432 rule. Targeted plans: 0 changes on touched resources.
- DB box host metrics (never monitored): Alloy exporter.unix → :3102 relay →
  Prometheus remote-write; alerts HostDiskHigh(80%)/DbBoxMetricsMissing/
  RetentionPolicyDrift/RetentionPurgeErrors. `scripts/deploy-db-agent.sh` codifies the
  previously hand-run agent.

## 9. Execution log T1–T5 (2026-09-24, overnight, user-authorized "go through all phases")

| Phase | PR | Live result |
|---|---|---|
| T1 legacy history → analytics | #1410 | shift 322,722 / hourly 495,504 (13 mo) / daily / weekly / monthly / area / site; POs 17,534 + runtimes 17,787; events 1.40 M + manual 5,639; resolved downtimes 2021-12→2026-07 — per-year == legacy. front4 Orders 2023 = 2,685 POs; Downtimes 2023-03 = 11,624 events in 3.3 s (was 120 s timeout) |
| T1 fix | #1410 | `serving.production_orders` failed on EVERY call (row type missed t281 int8) |
| T2 honest windows | #1407 | `X-Data-Hot-Floor` / `X-Data-Truncated` / `Warning: 299` derived from the retention catalog (18 bounded datasets); composer 422 before floor |
| T3 least privilege | #1408 | read-api + Superset on NOSUPERUSER `historian_svc` (duckdb.postgres_role, per-role S3 mapping, histgw_ro RLS/-1) |
| T4 Superset | #1411 | historian_union was NEVER imported (dashboard-dependency-only import) → `sync_databases.py`; `bi.*` serve 2021→ under RLS (tenant 5 sees 0) |
| T5 prod parity | this PR | Superset analytics URI env-templated (was hardcoded STAGING); prune script; promotion checklist |
| ops | #1409 | timescaledb log 28.8 GB unbounded → rotation codified; DB agent CPU cap |
| **regression (mine)** | #1414 | T1's legacy monthly rows (NULL counters) entered the 365-day DQ window → every runtime-rollup tick failed its DQ side-read (`cannot scan NULL into *float64`; rollups themselves unaffected). Fix: scan skips NULL-counter rows (NULL = no reading, never 0) |
| post-sweep | #1415 #1416 #1417 | app disk 94% (build cache 15.4 GB; deploy now prunes, keep 5 GB) · `AnalyticsTimescaleJobFailing` false positive on never-run telemetry job · cagg lag alert relative to schedule. End state 06:03 UTC: **0 alerts firing** |

**Honest limit:** history fidelity = legacy's computation. Legacy never populated
`running_time` for 2021 and only ~15 % of 2024–25 shift rows; `bi.oee_shift` (filters
`running_time>0` by design) is therefore sparse there — identical to legacy column for column.

## 10. Production promotion checklist (NOT executed — for promotion day)

1. Prod DB: apply migrations `t-retention-catalog` (production profile), `t-analytics-history-backfill`,
   `t-historian-svc-hardening` — each with a rolled-back dry run first; `SELECT * FROM ops.retention_drift` = 0.
2. Prod `.env`: `SUPERSET_ANALYTICS_DB=packiot` (T5 templating; host comes from `POSTGRES_HOST_UPSTREAM`);
   `HIST_GW_SVC_PASSWORD` from a prod secret; verify superset-init logs `superset_ro@10.20.10.89:5432/packiot`.
3. Prod historian gateway: apply-hardening.sh; prod keeps history FOREVER (lifecycle = tiering only).
4. Prod history: CPACK prod IS legacy ent1 — decide whether prod analytics backfills like staging (T1 tooling
   is tenant-parameterized: LEG_ENT / F3_ENT).
5. After prod verified serving: cap STAGING — `staging-capped.sql` + `historian-prune-by-data-age.sh`
   (APPLY=1 CONFIRM=delete-staging-history).

## 11. PINNED open items (found during T0–T5; deliberately NOT fixed unattended)

| # | Item | Why pinned |
|---|---|---|
| P1 | **SECURITY: historian S3 key printed in a session transcript** (my masking sed missed the `simple_s3_secret` mapping) | Rotate; then re-seed gateway DuckDB secret + re-run `apply-hardening.sh` (historian_svc mapping is a clone). Needs attended window |
| P2 | **SECURITY: one SHARED dev credential (`dev@packiot.com`) is a cluster-global SUPERUSER on the analytics DB (10.10.10.89) AND on the historian gateway**, and the same password is reused for Grafana, CloudBeaver and operator logins (also recorded in plaintext in the operator's private assistant notes) | Rotate + split into per-system credentials; drop SUPERUSER where a read role suffices (T3's `historian_svc` / `readapi_ro` pattern). Human decision — the role is in active use |
| P3 | SECURITY: app SG allows SSH 22 from 0.0.0.0/0 | SSM exists; closing it is a policy decision |
| P4 | Alertmanager parked → every alert (incl. the new disk/retention ones) notifies nobody | Needs a Slack webhook / on-call target |
| P5 | timescaledb container log 28.8 GB; rotation codified (#1409) but needs container RECREATE | DB restart = maintenance window; then recreate alloy-db with positions volume |
| P6 | Pre-existing TF drift: historian bucket tags, db_init S3 object | Unrelated to this work; review before any apply |
| P7 | Superset web/worker single-FILE config mounts (inode trap #39/#41 class) | Dir mount would shadow image /app/pythonpath — needs care |
| P8 | History fidelity bounded by legacy (running_time) | Recompute OEE from archived raw = separate project |
| P9 | front4: read `X-Data-Truncated` → "archive" badge; consider raising `analyticsWindow` (400 d) for multi-year aggregate charts | UI/product decision |
| P10 | Raw archive has a `year=1970` EV partition (bad timestamps) | DQ cleanup |
| P11 | Only CPACK had legacy history; other tenants start at their onboarding | Expected; note for sales/CS |
| P12 | stream-engine `hour reflag: deadlock detected (40P01)` ~1–2×/hour (pre-existing; seen before T1) | Transient (next tick retries); root-cause the lock order between hour reflag and concurrent writers |
