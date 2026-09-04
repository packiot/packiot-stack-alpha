# analytics-rename — meaningful-names cutover (expand phase)

**Status:** APPLIED + HARDPROOFED on staging `packiot_analytics`
(`i-064bb36d1c454d861`, PG 15.17 / TimescaleDB 2.27) on 2026-09-04.
Production untouched. Fully reversible (`*.down.sql`).

## What changed

The 17 OEE rollup tables carried the vague prefix `*_runtime_*`. They store
OEE aggregates (oee, oee_a/p/q, gross, net, scrap, running_time, …) per
shift/hour/day/week/month — so `*_oee_*` is the accurate name. Renamed:

| old | new |
|---|---|
| `equipment_runtime_shift` | `equipment_oee_shift` |
| `equipment_runtime_1hour` | `equipment_oee_hourly` |
| `equipment_runtime_1day`  | `equipment_oee_daily` |
| `equipment_runtime_1week` | `equipment_oee_weekly` |
| `equipment_runtime_1month`| `equipment_oee_monthly` |
| `equipment_runtime_shift_1week`  | `equipment_oee_shift_weekly` |
| `equipment_runtime_shift_1month` | `equipment_oee_shift_monthly` |
| `area_runtime_{shift,1hour,1day,1week,1month}` | `area_oee_{shift,hourly,daily,weekly,monthly}` |
| `site_runtime_{shift,1hour,1day,1week,1month}` | `site_oee_{shift,hourly,daily,weekly,monthly}` |

The new name is now the **physical table**. The old name survives as a
`security_invoker` **compatibility view** (`SELECT * FROM <new>`), so every
existing consumer — 46 `h_piot_*` functions, `bi.*` serving views, the
`piot_create_*` provisioning procs, and the stream-engine Go worker — keeps
working unchanged. This is the **expand** half of an expand/contract rename.

## Why this is safe (all hardproofed 2026-09-04, not asserted)

1. **Auto-updatable views bridge the writers.** A view defined as
   `SELECT * FROM base` is auto-updatable: plain `INSERT`/`UPDATE`/`DELETE`
   pass through to the base. Proven that `INSERT … ON CONFLICT (col) DO
   UPDATE/NOTHING` and bare `ON CONFLICT DO NOTHING` **also traverse** the view
   (the rewriter re-resolves the arbiter index against the *base* table). The
   **only** form that breaks is `ON CONFLICT ON CONSTRAINT <name>` (a view has
   no constraints of its own) — and **none** of the 17 `piot_create_*` procs
   use it (all use column/bare inference; verified `by_constraint_name=f`).
2. **Code writers are UPDATE-only.** The stream-engine writes these tables with
   plain `UPDATE`; row creation is done by the DB `piot_create_*` procs. Plain
   `UPDATE` traverses the view. (The `uns_*` tables, by contrast, have *code*
   `ON CONFLICT` writers, so they were **not** renamed here.)
3. **RLS preserved.** `equipment_oee_shift` and `equipment_oee_hourly` have
   `FORCE ROW LEVEL SECURITY`. The compat views are `security_invoker=true`, so
   RLS binds to the **calling** role exactly as if it queried the base — proven:
   SELECT isolates to the caller's tenant, a foreign-tenant write is blocked by
   `WITH CHECK`, and superuser bypass is unchanged. A plain (definer) view owned
   by `postgres` would have **bypassed** RLS — the footgun this avoids.
4. **Lossless + live.** All 17 `count(new) == count(old_view) == pre-count`.
   `bi.oee_shift` returns 2293 (tenant −1) / 1948 (tenant 3), identical to
   pre-migration. The real `piot_create_equipment_runtime_shift()` runs clean
   through the shim, and stream-engine's live per-minute `UPDATE` landed 83 s
   after the migration committed.

## Operational note

`ALTER TABLE … RENAME` needs `ACCESS EXCLUSIVE`, which contends with the live
stream-engine writer. The first apply aborted on lock contention and the whole
transaction rolled back (atomic — no partial state); the retry won the lock and
committed. On a busier DB, wrap with `SET lock_timeout` + retry.

## Not renamed (deliberate, with reasons)

- **`uns_*` (16 tables)** — the `uns` prefix is *Unified Namespace*, a real
  IIoT/ISA-95 domain term, so `uns_*→*_live_*` is lateral, not a clear win; and
  these have code-side `ON CONFLICT` writers (stream-engine `internal/uns/uns.go`,
  node-red) that a compat view would still bridge for column-inference but which
  raise the risk surface. Held pending an explicit decision.
- **`production_orders_runtime`** — "production order runtime" is a reasonable
  name, 33 downstream consumers, and `bi.production_order_runtime` already
  exposes it. Low value / high blast radius.
- **Columns** — the columns in these tables are already well-named
  (`oee`, `oee_a/p/q`, `gross`, `net`, `scrap`, `running_time`,
  `planned_downtime`, …). The naming debt in this DB is at the *table* level,
  not the column level. No column churn.

## Contract phase (later, incremental — NOT done here)

Repoint consumers (`bi.*`, `h_piot_*`, procs, stream-engine) to the new names,
then drop the compat shims. Each shim drop is independently reversible. Keep
`bi_owner` ownership when repointing `bi.*` (do **not** `CREATE OR REPLACE` them
as `postgres` — that would flip them to superuser-owned definer views and bypass
RLS).

## Separate, still-gated: the `agg_*` → `equipment_metrics_*` redesign

The hierarchical metrics cagg family (`analytics-v2.sql`) is a *structural*
replacement of the flat `agg_*`/`ca_agg_*` caggs, **not** a rename — the tiers
have different grouping, so no compat view can bridge them. Its cutover stays
gated on the §7 equivalence proof (all contract `h_piot_*` + `bi.*` symmetric-
diff 0 across {−1, busy, quiet} × 2 windows + perf gate). See
`db/design/analytics-v2-target-schema.md` §7.
