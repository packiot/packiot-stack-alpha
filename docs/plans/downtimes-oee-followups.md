# Follow-ups: Downtimes-events cold performance + faulty-PLC speed data quality

Context: this captures the diagnosis from the 2026-09-21 Operations-menu investigation
(front4 Downtimes submenu 500 + "weird OEE/speed numbers"). The user-facing symptoms
are already MITIGATED and shipped:

- **#1370** — Superset Orders/Last-events table `query_context.columns` de-synced from
  `all_columns` (embed rendered a column the query didn't return). Merged + deployed.
- **#1371** — read-api `/v1/query` timeout 20s→40s + `downtimes-events` cache 30s→120s.
  Merged + deployed; proven live (cold 3-day `downtimes-events` now 200 in ~31s, was 500).
- **cpack `production_speed` recalibration** — raised 11 GENUINE over-runners (p50 ≥ config,
  plausible p95) to demonstrated p95, live-verified (L4 oee_p→0.87, L6→0.95). Live data change.

The two items below are the DURABLE fixes. Both are heavy shared-infra changes and were
deliberately NOT rushed live — they need DB/pipeline-team review + fast iteration.

---

## FU1 — `serving.downtime_events_v2` is ~18–31s cold (mitigated by the 40s timeout, not fixed)

### Measured
- Warm ~300–540ms; cold ~18–31s. read-api's per-query ceiling was 20s → cold loads 500'd
  ("query failed", and the composable-dataset 500 path does NOT log the DB error — query.go:237-240).
- EXPLAIN (ANALYZE, BUFFERS): **75,633 shared buffers** for ~215 result rows.
  - Base `silver.equipment_events` scan (ent3, ±1mo pad) ≈ **12.8k** buffers.
  - Remaining ≈ **62k** buffers = the per-row correlated `production_orders_runtime` subquery
    (SELECT-list, lines ~92-100 / ~188-196) + the `equipment_oee_shift` range join, executed
    across the **all-tenant** candidate set (`id_enterprise` is filtered only in the OUTER
    wrapper, so the inner scan + subqueries run for ALL tenants: 96,543 rows scanned for a
    2-day request vs 2,167 in the tight window).
- `silver.equipment_events` = TimescaleDB hypertable, ~114 daily chunks, 99 compressed →
  the ±1-month pad decompresses ~17 old compressed chunks per request (cold cost).

### Why the naive fixes don't work (tested with a probe function on staging)
- Pushing `id_enterprise` into the inner scan + cutting the pad 1mo→7d changed buffers only
  75,608 → 73,264 (≈3%) AND **dropped 5 rows** (215→210). The ±1-month pad is **load-bearing**:
  it catches OPEN events (`ts_end IS NULL`) that started weeks before the window but still
  overlap it (line 120's `tstzrange(ts_event, ts_end) && window`). A blind pad cut drops them.

### Recommended approach (DB team)
1. **Split the scan** so the ±1mo range is only paid for the rare long/open events:
   - `A` = events with `ts_event` INSIDE the tight `[_tsstart, _tsend]` window (recent,
     mostly-uncompressed chunks → cheap), UNION
   - `B` = OPEN events (`ts_end IS NULL`) with `ts_event < _tsstart` (few; back an index like
     `(id_enterprise, ts_event) WHERE ts_end IS NULL` or a partial), UNION
   - `C` = closed events straddling `_tsstart` (bounded by a realistic max event duration, not
     a fixed month — measure the actual max straddling-event span first).
2. **Filter `id_enterprise` + line/equipment + the overlap BEFORE** the correlated
   `production_orders_runtime` subquery runs (move it to a LATERAL join computed only on the
   surviving rows), so it executes ~215× not ~96k×.
3. Keep predicates chunk-exclusion-friendly (compare raw `ts_event`, avoid wrapping it in
   `at time zone` before the range test).
4. Consider a **continuous aggregate / materialized downtime-events** table if the list view
   stays hot; or a TimescaleDB policy keeping the recent N days uncompressed.

Acceptance: cold `downtimes-events` over a 7-day window < ~3s, row-parity identical to today
across 2d/14d/30d windows and for open events. Then the read-api 40s timeout is pure headroom.

---

## FU2 — Faulty-PLC speed readings poison OEE/Performance (and scrap) for L5 / L8 / L10 / HOTMADAG

### Evidence
- Per-minute speed p95 from `silver.equipment_metrics_1min` (a continuous aggregate;
  `sum_speed`/`cnt_speed`/`max_speed`) is physically impossible on the faulty lines:
  **L5-PTH p95 = 1,676,622** (max 3.5M); HOTMADAG median 55 but p95 191 (spike-driven);
  L8/L3 similar. These are the SAME faulty PLCs behind the scrap-spike guard already shipped
  (`serving.single_period_by_team_v4`, migration `t-scrap-spike-guard`).
- Effect: corrupt readings inflate/distort `sum_speed` → wrong `avg_speed` → the OEE page's
  live `serving.oee_score_by_team` (which computes performance = avg_speed / production_speed)
  shows numbers that "don't reflect the data" (e.g. L5 = 38%). NOTE: gold
  `gold.equipment_oee_shift` already CLAMPS performance ≤ 1.0 (0 rows >100% in 30d), so the
  symptom is distortion of the AVG, not >100%.

### Why it can't be fixed at read time
- `equipment_metrics_1min` is a continuous aggregate → `sum_speed` has the corrupt readings
  already baked in; you cannot exclude individual bad minutes in the serving RPC. Recreating
  the cagg with a filtered aggregate rebuilds ALL materialized data (expensive, all-tenant).

### Recommended approach (pipeline / decoder team)
- **Guard at ingestion**: where the speed metric is written toward silver (sparkplug-decoder
  or the bronze→silver transform), drop/flag per-reading speed beyond a physical ceiling
  (e.g. > `production_speed` × K, or an absolute per-equipment max). New data only — historical
  stays distorted until re-materialized. Mirrors the scrap-spike guard's intent, but at the
  correct (ingestion) layer so it fixes speed AND scrap at the source.
- Backfill option: a one-off sanitize pass over the affected chunks if historical accuracy is
  needed for those lines.
- Independently, obtain real design nameplates for L5/L8/L10/HOTMADAG — p95 is only a proxy and
  is itself contaminated for these lines (so they were EXCLUDED from the recalibration above).

Acceptance: `avg_speed` on the faulty lines becomes physically plausible; OEE performance on
the OEE page reflects real throughput; the scrap-spike guard becomes redundant (belt-and-suspenders).
