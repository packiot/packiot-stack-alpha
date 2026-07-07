# 5 — The Database

Everything so far has been moving data *toward* the database. This chapter is about
what it lands in, why the schema is shaped the way it is, and what the refactor
changed. The database is PostgreSQL with **TimescaleDB** (a time-series extension)
layered on top.

The mental model to hold: the schema has **layers**, and data flows up through them
— from raw truth, through time buckets, into business windows, with live caches off
to the side. We'll build that picture from the bottom.

## The core spine

Five tables carry the whole story. If you understand these, you understand the
data model; everything else is a projection, a rollup, or a cache of these.

### `equipment_values` — the raw truth

The root of everything. A TimescaleDB **hypertable** where one row is one machine
sample at one instant, keyed uniquely by `(ts_value, id_equipment)`. This is the
only table the factory floor truly writes into. Its columns fall into three groups:

- **Counters** — `net_production_incr` / `gross_production_incr` / `scrap_incr` (and
  `_val` absolute variants). Gross minus scrap is where OEE's *Quality* comes from.
- **State** — `state`, `mode`, `speed`, `ideal_production_speed`. Running-vs-stopped
  and actual-vs-ideal speed feed *Availability* and *Performance*.
- **Denormalized context** — `id_enterprise/site/area`, `id_shift`, `id_team`,
  `id_production_order`, stamped onto every row at ingest so the aggregates never
  have to join back to the hierarchy.

Because it is a hypertable, a year of per-second data stays queryable and
compressible. Nothing downstream reads it directly — that is the whole point of the
next layer.

### `ca_equipment_values_1min` — the first aggregate

A TimescaleDB **continuous aggregate** (CAgg): the firehose rolled into one-minute
buckets per machine, refreshed automatically. It is stage one of a cascade —
`1min → 1hour → shift` — and the reason a query for "this machine's OEE last month"
does not have to scan a billion raw rows. The refactor's fight over *naming* this
layer (the `ca_` prefix) is a whole subplot below.

### `equipment_events` / `equipment_events_man` — the downtime ledger

One row per machine event: when it started (`ts_event`), when it ended (`ts_end`),
and — crucially — its *classification*: `cd_category` / `cd_subcategory`,
`planned_downtime`, `change_over`, operator notes. This is the raw material of
*Availability*: a stopped machine only becomes "planned" vs "unplanned" vs
"changeover" through this table. The `_man` suffix marks manually-classified events.

### `production_orders` — the business work unit

"Make N units of product X on machine Y." Carries the lifecycle (`status`:
1 = available, 2 = running, 3 = finished, 4 = paused), the plan
(`production_programmed`) versus the outcome (`production_final`), and the
denormalized OEE result (`oee`, plus its `_quality/_availability/_performance`
breakdown). The `recalc_needed` boolean is the dirty-flag from
[Chapter 4](04-the-engine.md): it tells the engine "recompute this PO" after
late-arriving data.

### `production_orders_runtime` — one PO, many runs

The table that makes the model honest. A PO can pause and resume, so each
*contiguous run* gets its own row with a `runtime_timerange` and its own full OEE
breakdown. `production_orders.oee` is essentially the rollup of its runtime rows. A
GiST exclusion constraint forbids overlapping runs on the same equipment — the
database enforcing a real-world truth (a machine can't be in two runs at once), and
the source of the honest `409 Conflict` an operator sees if they try.

## The two axes

Those five tables sit on two axes that meet at OEE:

```
  TIME AXIS  (what did machines do, per minute / hour / shift?)
  equipment_values ──▶ ca_..._1min ──▶ ..._1hour ──▶ runtime_shift
        │                                                  │
        │        equipment_events (planned/unplanned) ─────┤
        │                                                  ▼
  production_orders ──▶ production_orders_runtime ◀──── OEE = Q × A × P
  WORK AXIS  (what did each order achieve?)
```

OEE lives at the intersection: the *time* axis says how the machine behaved during
a window, the *work* axis says what order was running, and the classified events say
whether the stopped time counted against availability. This is a classic industrial
**historian** shape — the same pattern you'd find in OSIsoft PI or Ignition:
append-only telemetry, cascaded rollups, an event ledger for classification, and
dirty-flags instead of recomputing the world.

Off to the side sits one more family worth naming: the **UNS current-state** tables
(`uns_equipment_current_metrics` and friends) — not history, but a live "what is
every machine doing *right now*" snapshot that mission-control screens poll instead
of re-aggregating history on every page load.

## The refactor: what changed and why

The legacy production schema is five years of sediment: ~200 tables, ~130 views, OEE
math in triggers, and three problems the refactor
([ADR-0012](../adr/0012-schema-refactor-and-multitenancy-pool.md)) sets out to fix.
The end-state schema map has six deliberate layers plus a pointedly "absent seventh":

**1 — Tenancy moves from names to rows.** The single worst pattern in the legacy
schema is tenant identity encoded in *table names*: `report_speed_enterprise_33`,
`equipment_boxes_cust_13`. Onboarding a customer meant creating tables; there was no
cross-customer analytics. The refactor introduces **pool schemas** —
`customer_reports.speed`, `customer_dashboards.*` — where the customer is a
`customer_id` *column*. Onboarding a new factory becomes an `INSERT`, not a schema
migration. Legacy names survive as compatibility views (an *expand-contract*
migration) so nothing downstream breaks during the transition.

**2 — One aggregate naming scheme.** The legacy database had the *same* hourly
aggregate under three naming dialects (`agg_*`, `ca_agg_*`, `mv_*_full_hot`),
uncompressed alongside compressed, nobody able to tell which was canonical. The
refactor consolidates to a single `ca_*` prefix, hierarchical (each grain built on
the one below), compressed, with one retention policy per grain.

**3 — History is separated.** `hist_*` tables hold frozen history, so live tables
stay lean and retention policies can differ by table class (raw telemetry kept
90 days compressed, grain aggregates two years, history frozen).

**The absent seventh layer** is the point of the whole exercise: what the refactor
*removes*. The OEE math (gone to Go), the Hasura metadata, dead per-customer
dashboards, version-sprawl generations of superseded tables, a 496-million-row
invalidation log. Every removal is done *with evidence* — a "bloat ledger" records
why each object is safe to drop — never silent omission.

The one-sentence version, from the schema map itself: *raw truth flows through
buckets into business windows and current caches, guided by reference data,
configured by descriptors, exported through tenant-keyed pools — every
customer-specific NAME reduced to a customer_id VALUE.*

## How you look at it

Direct `pg_dump` is blocked on the production database, so schema inspection happens
through `information_schema` queries and the snapshot at `edge-api/schema.sql`.
Grafana reads the database directly via SQL datasources for the operational boards.
And the migration's own tooling — as-executed SQL, naming maps, gate boards — lives
under [`adr/reference/`](../adr/reference/), because a migration this careful treats
its *migration scripts* as artifacts to be reviewed, not just the schema they
produce.

---

Next: [APIs and the Operator](06-apis-and-operator.md) — how people read and change
all this.
