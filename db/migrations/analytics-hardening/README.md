# packiot_analytics — hardening & restructure migrations

Derived from the hardproofed audit (see the audit artifact). Split by risk: what
was **applied** (safe, reversible, verified) vs what is **authored for review**
(schema/consumer-touching — must NOT be blind-applied).

## Applied on staging this session (codified in `01_*` / `02_*`)

| Change | Proof |
|---|---|
| Cagg compression + policies (all large caggs) | DB **5,998 → ~2,810 MB (−53%)**; 17 compression policies |
| Retention 90d on fine caggs (aligned to 90d source) | 11 retention policies; bounds unbounded growth |
| `lab_equipment_values` chunk interval 1h → 1d | best-practice sizing (future chunks) |
| Self-select bug fix (`piot_create_equipment_runtime_shift_1week/_1month`) | week 0→3,830, month 0→1,532 rows; front4 week/month target overlay restored |
| Observability: `pg_stat_statements` + `auto_explain` + `track_io_timing` + slow-query log | via startup `-c` flags (see `03_observability_startup_flags.md`); `pg_stat_statements` tracking live |

## Authored for REVIEW — do NOT blind-apply (`04_*`, `05_*`)

These change cagg schemas / touch live consumers / need code deploys. Apply
deliberately, with eyes on consumer impact.

- **`04_REVIEW_cagg_hierarchical_redesign.sql`** — flat `agg_*_10min/1hour` re-scan
  raw; rebuild them hierarchically on `agg_*_1min`. **Correctness caveat (hardproof):**
  `avg(speed)` cannot be built from per-minute averages (`avg(avgs) ≠ true avg`),
  so the base cagg must expose `sum(speed)+count` partials and higher tiers compute
  `sum/count`. This **changes the base cagg output schema** → repoint consumers
  (read-api `external_integration.go`, `v_sap_*` views, procs) first. Requires
  drop+recreate (re-materialize window). Modest benefit (caggs refresh
  incrementally), so weigh cost/benefit before applying.
- **`05_REVIEW_drop_dead_objects.sql`** — drop confirmed-dead objects, each behind a
  re-verify guard (0 rows / 0 scans / 0 refs at apply time).

## Deferred (blocked, not authored yet)

- **agg_ vs ca_agg consolidation** — near-redundant but *different schemas* (31 vs 25
  cols, different grain); not a simple merge — needs a consumer-by-consumer repoint.
- **Physical-table renames** — the `bi.*` view layer already exposes good names to
  Superset; physical renames touch `ON CONFLICT` writers (can't bridge via view) →
  coordinated code+DB deploy across read-api/edge-api/stream-engine. Low value / high
  risk while `bi.*` suffices.
- **Dead `h_piot_*` proc prune** — `track_functions` was just enabled (and reset by the
  restart); needs days of call-count data to prove the ~56 non-refdata procs are truly
  dead before dropping. Re-check `pg_stat_user_functions` in ~a week.

## Apply order (for the review set)
1. Repoint consumers of `agg_*_1min` to the new partial columns (code/proc change).
2. `04_REVIEW_cagg_hierarchical_redesign.sql` (during a low-traffic window; expect a
   re-materialize).
3. `05_REVIEW_drop_dead_objects.sql`.
