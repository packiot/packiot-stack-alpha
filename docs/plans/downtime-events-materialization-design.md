# Design: precomputed downtime-events serving table (durable fix for cold `downtimes-events`)

Deepens the FU1 entry in [downtimes-oee-followups.md](./downtimes-oee-followups.md). Scope: make the
front4 Downtimes page's `downtimes-events` leg sub-second **cold**, without changing results.

## Problem (measured)
`serving.downtime_events_v2` is ~300–540ms **warm** but ~18–31s **cold** — read-api's 20s ceiling made it
500 (mitigated to 40s + a 120s cache in #1371). EXPLAIN (ANALYZE, BUFFERS) over a 2-day window:
**75,633 shared buffers for ~215 rows**.

Cost breakdown (measured on staging):
- `silver.equipment_events` base scan (±1-month pad): ~12.8k buffers ≈ **17%**.
- The rest ≈ **83%** = **per-candidate cold random reads**: a correlated subquery into
  `production_orders_runtime` (`ts_event <@ runtime_timerange`, ~33 buffers/call) + a range join into
  `gold.equipment_oee_shift` (`ts_event <@ ts_range`, ~4 buffers/call), evaluated for every candidate row.

Both join targets are TINY (`equipment_oee_shift` = 52k rows / 24 MB) — so this is **cold random-access
latency on EBS**, not data volume. Warm, it's all buffer hits (300ms). That is why:
- Tightening the ±1-month pad does NOT help (it only touches the 17% scan; and closed events run up to 51
  days so it can't be tightened without dropping rows — proven, a 7-day pad dropped 5 rows).
- A TimescaleDB compression-policy change alone does NOT help (same reason — only the 17%).

## Why materialize
The result set is small (~215 rows / 2-day window; a 90-day window is still bounded), events arrive
**~1/min** (74 in the last hour), and the expensive part is *resolving each event* (PO + shift + line
rollup) via cold random reads. Precomputing that resolution once, incrementally, turns the serving query
into a cheap indexed range scan.

## Design — `serving.downtime_events_resolved` (materialized table + incremental refresh)

### Table
A plain table (NOT a continuous aggregate — the resolution isn't a time-bucket aggregate) with the exact
column set `downtime_events_v2_row` returns, plus bookkeeping:

```
serving.downtime_events_resolved (
  id_equipment_event bigint,
  id_enterprise int,
  ts_event timestamptz, ts_end timestamptz,      -- keep tz; the serving fn converts per-site tz at read
  id_equipment int, id_sector int, id_line int,
  nm_equipment text, sector text, cd_machine text,
  duration int, cd_category text, txt_category text,
  cd_subcategory text, txt_subcategory text, txt_downtime_notes text,
  id_order int, cd_shift text, id_shift int,
  planned_downtime bool, change_over bool,
  shift_ts_range tstzrange, stop_threshold_time int, manual_event bool,
  -- bookkeeping
  resolved_at timestamptz not null default now()
);
-- serving read pattern: (id_enterprise, ts_event) range + line/sector filters
create index on serving.downtime_events_resolved (id_enterprise, ts_event desc);
create index on serving.downtime_events_resolved (id_enterprise, id_line, ts_event desc);
-- open-event fast path (the ±1mo pad's real purpose):
create index on serving.downtime_events_resolved (id_enterprise, ts_end) where ts_end is null;
```

### Incremental refresh (pg_cron, every 1–2 min)
`downtime_events_v2` today re-resolves everything on every call. Instead, resolve only what changed:

```
-- 1. new/updated events since the last watermark (events + manual events)
--    use a watermark on GREATEST(ts_event, ts_end, <row mtime if available>).
-- 2. INSERT ... ON CONFLICT (id_equipment_event, manual_event) DO UPDATE  (upsert resolved rows)
-- 3. also re-resolve OPEN events (ts_end is null) each tick — cheap via the partial index — because
--    their overlap window + id_order can change until they close.
-- 4. optional retention: delete rows older than the serving window (e.g. 120 days) to bound size.
```
The resolution logic (PO lookup, shift range join, line/sector rollup, filters `status<>6`,
`event_should_be_displayed`, duration/microstop rule) is LIFTED VERBATIM from `downtime_events_v2` so the
rows are byte-identical — the ONLY change is *when* it runs (background, incrementally) vs at read time.

### Serving
`serving.downtime_events_v2` becomes a thin reader over `downtime_events_resolved` (same signature, same
per-site-tz conversion + the `tstzrange && window` overlap + the id/site/area/line/sector/microstop
filters applied at read). It scans a bounded, warm, indexed table → sub-second cold. `downtimes-events`
read-api dataset is unchanged (still calls `downtime_events_v2`).

## Rollout (safe, revertible)
1. Build `downtime_events_resolved` + the refresh proc as a NEW migration; backfill the serving window.
2. Add `serving.downtime_events_v3` (reader over the table) ALONGSIDE the untouched v2.
3. **Parity gate:** assert v3 row-set == v2 row-set for many (tenant × window) combos incl. open-event and
   long-straddling cases (2d / 14d / 30d / 90d), across ALL tenants — not just cpack.
4. Repoint the read-api `downtimes-events` dataset SQL v2→v3 (one-line, instantly revertible). v2 stays.
5. Watch: p95 latency + a freshness check (`max(resolved_at)` lag < 2 min).

## Acceptance
- Cold 7-day `downtimes-events` < ~3s (target sub-second); exact row parity vs v2 across the gate matrix;
  materialization lag < 2 min; read-api 40s timeout becomes pure headroom; the 120s cache becomes a bonus,
  not a crutch.

## Alternatives considered (and why not)
- **Tighten the ±1mo pad** — breaks parity (51-day events) and only touches 17% of cost.
- **Compression policy / smaller chunks on equipment_events** — only the 17% scan; per-candidate join I/O
  unchanged. Worth doing anyway for other queries, but not the fix here.
- **Just rely on #1371's cache** — 120s TTL + slow cold first-load per window/tenant; acceptable stopgap,
  not a fix (every distinct window/tenant re-pays the cold cost).

## Owner
DB / analytics-pipeline team (touches a shared serving function + adds a pg_cron job). read-api change is
a one-line dataset repoint behind the parity gate.
