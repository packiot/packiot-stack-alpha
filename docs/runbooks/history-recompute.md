# History recompute: rebuild gold OEE days older than the engine's windows

Use this when gold history (hour / shift / day / week / month OEE) must be rebuilt after a
data repair, and the rows are **older than the stream engine re-processes on its own**.
Examples: silver increments were repaired (2026-10-01 unbacked increments), shift math changed
and must be re-applied to past shifts (2026-10-02 boundary hours), a simulator's data was purged.

Writes to the shared staging DB. Dry-run first, keep a backup table, get the user's go.

## Why flagging old rows is not enough

Every engine pass only looks back so far:

| Pass | Live window |
|---|---|
| hour rollup | 65 min (the hour backfill drains older flags up to **10 days**) |
| shift eligible | 30 days |
| shift line-lead, shift oee-reconcile | **25 days** |
| day eligible | 1 month |
| count-floor / counters-avail (shift) | 2 days, on purpose: needs the 1-min cagg |

Flag a 40-day-old shift and only the passes whose window still covers it run. On 2026-10-01 that
rewrote old line shifts as "running the whole time": the state-only pass ran, the line-lead pass
that overrides it did not. **Rows past a window cliff need every pass, widened, in one
transaction.** That is what this tooling does.

Inside the windows, plain re-flagging (`recalc_needed = true`) is fine: the engine drains it.

## The tools

| File | What |
|---|---|
| `services/stream-engine/cmd/recompute-render` | renders the per-day SQL template from the **current** engine code: the exact `hourBackfillSteps` / `shiftSteps` / `daySteps` lists the worker runs, with every recency window widened to the horizon (default 75 days) |
| `scripts/recompute/run-day-recompute.sh` | runs the template one UTC day at a time over SSM; **ROLLBACK unless `--commit`**; stops at the first error |
| `scripts/recompute/flag-example.sql` | the scope SQL you copy and edit: which hour/shift rows to rebuild |

The renderer refuses to render if the engine grew a recency window nobody classified (a new
`now() - interval '…'`): either widen it in `widenForHistory` or list it as a deliberate
exception in `historyLeftoverOK` (`internal/rollup/history.go`). Unit tests pin that every engine
step appears in order.

Not covered: **PO runtime** (`production_orders_runtime`, `RunCompute`, 1-month window). Repair
POs separately and check their values afterwards (see "Flag race" below).

## Procedure

### 1. Render from current code

Always fetch first; the template must match the deployed engine.

```bash
git fetch origin && git switch --detach origin/staging
# on the app host: the running worker's rollup config (the renderer reads only these keys)
docker exec stream-engine env | grep -E '^(EVENTS_EXCLUDED|COUNTERS_ONLY|OEE_|AVAILABILITY_EXCLUSIONS|CHANGEOVER_AVAIL|ROLLUP_MACHINE_LEVEL)' > worker.env
```

The worker also adds line-lead enterprises and per-line overrides that clients set in their OEE
profile. Read them (read-only) and pass them on:

```sql
-- packiot_analytics
SELECT cd.id_enterprise, cd.descriptor->'oee_profile'->>'availability_mode',
       cd.descriptor->'oee_profile'->>'ideal_source', cd.descriptor->'oee_profile'->'lines'
  FROM core.client_descriptors cd WHERE cd.descriptor->'oee_profile' IS NOT NULL;
```

(`availability_mode = count_silence` or `ideal_source = lead_machine` → line-lead enterprise.)

```bash
cd services/stream-engine
go run ./cmd/recompute-render -env-file worker.env \
   -line-lead-enterprises 5 -line-lead-opt-in "" -line-lead-opt-out "" \
   -rev "$(git rev-parse --short HEAD)" -out /tmp/recompute_tpl.sql
head -6 /tmp/recompute_tpl.sql   # check the config line: line_lead, ents, floor, canonical …
```

### 2. Write the scope SQL

Copy `scripts/recompute/flag-example.sql` and edit the equipment predicate. It runs **inside**
each day's transaction, after the engine locks, so no live tick can drain a half-flagged day.
Flag hour and shift rows; day, week and month follow through the cascades. Leave open shifts
(`ts_end >= now()`) to the live rollup.

### 3. Back up what you will overwrite

```sql
CREATE TABLE ops._bkp_gold_<what>_<yyyymmdd>_hourly AS
  SELECT * FROM gold.equipment_oee_hourly WHERE <same scope and days>;
-- same for _shift and _daily
```

Note the drop date (about one month) in the open-items memory.

### 4. Dry run, then commit

```bash
scripts/recompute/run-day-recompute.sh --template /tmp/recompute_tpl.sql \
   --flag-sql my-scope.sql 2026-09-01 2026-09-02          # ROLLBACK, prints n_* counts
scripts/recompute/run-day-recompute.sh --template /tmp/recompute_tpl.sql \
   --flag-sql my-scope.sql --commit 2026-09-01 2026-09-02
```

- One transaction per day. It holds the engine's `<dest>:runtime-backfill` **and**
  `<dest>:runtime` advisory locks, so the **live rollup waits** while a day runs. Watch the
  `secs=` column: a day that takes minutes stalls live OEE for every tenant for those minutes
  (the 2026-10-01 incident stalled the shift rollup for 22 min). Run outside client peak hours.
- SSM kills a command after 1 hour. Each day is its own SSM command; for a long list of days,
  start the runner with `nohup … &` from a shell that survives your session.
- Check that the counts look right before committing. A count of 0 means your scope matched
  nothing.

### 5. Verify

The flags draining is **not** proof. Check the values.

```sql
-- gold hourly vs raw silver for machines in scope (lines read their lead machine's counters)
SELECT g.id_equipment, sum(g.net) AS gold_net, sum(s.net_production_incr) AS silver_net
  FROM gold.equipment_oee_hourly g
  JOIN core.equipments q ON q.id_equipment = g.id_equipment
  LEFT JOIN silver.equipment_categorical_1hour s
         ON s.id_equipment = COALESCE(NULLIF(q.lead_machine, 0), q.id_equipment) AND s.ts_value = g.ts_value
 WHERE g.ts_value >= '2026-09-01' AND g.ts_value < '2026-09-03' AND q.id_enterprise = 5
 GROUP BY 1 HAVING abs(sum(g.net) - coalesce(sum(s.net_production_incr), 0)) > 0.5;

SELECT * FROM ops.data_invariant_latest WHERE NOT ok;   -- after the next 30-min run
```

Lines with separate gross/net counters (`gross_ctr` / `net_ctr`) need the line-lead mapping;
the invariant battery (C6 shift = Σ hour, V3 increments backed by counters) covers those.

## Rules

- **Never `decompress_chunk`** on the shared DB. Its ACCESS EXCLUSIVE lock blocks every reader of
  the chunk (2026-09-30: CPACK operator 500s). The template only does row-level DML;
  `timescaledb.max_tuples_decompressed_per_dml_transaction = 0` lets those UPDATEs decompress
  just the rows they touch, which takes row locks only.
- **Flag race (PO runtime).** `RunCompute` runs its phases as separate statements, each
  re-reading `recalc_needed`; a manual re-flag that lands mid-tick is cleared without line-lead
  values. After any PO repair, check the values changed, not just the flags.
- **Never reuse an old template.** The engine changes weekly (the boundary-hour fix #1545 changed
  the shift line-lead pass the day after the 10-01 repair). Re-render every time.
- **A day that holds the locks for more than ~2 minutes: check the ideal-speed LOCF first.** The
  hour `speed` step and the shift `values` step look up the last non-null
  `ideal_production_speed` per minute (hour) / per hour bucket (shift), bounded by
  `now() - (horizon + 7) days`. Compressed chunks have no partial index, so each lookup probes every
  compressed chunk in that range. On 2026-10-09 (CPACK gap backfill, 20 lines, one day) the
  speed step alone ran > 10 min at horizon 75 and at horizon 30, stalling the live hour rollup for
  every tenant until cancelled. Two levers:
  - render with the smallest valid `-horizon-days` (30; the renderer refuses less);
  - if `SELECT count(*) FROM silver.equipment_values WHERE ideal_production_speed IS NOT NULL AND
    ts_value >= <oldest day - 8 d> AND ts_value < <newest day + 1 d>` is **0** (no tenant reports it;
    true on staging through 2026-10), the lookup always returns NULL, so appending `AND false` to
    both `AND ev.ideal_production_speed IS NOT NULL` lines is exactly equivalent. That brought the
    day to ~2 min. Re-prove the count every time; never carry the patch to a window where a tenant
    reports ideal speed.
- Run one enterprise per transaction (copy the scope SQL per enterprise) and pause between days, so
  the live rollup catches up between lock holds.
- The day pass is not bounded to the window: it also drains any other flagged day inside the
  horizon. Same math as the engine, so this is harmless, but it can make `n_day_elig` larger
  than the days you asked for.
