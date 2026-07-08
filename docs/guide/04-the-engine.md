# 4 — The Engine

> For a concrete inventory of the worker's writers and scheduled jobs, see the
> [Service Catalog (Ch.11)](11-service-catalog.md).

This is the most important chapter, because it is where the rebuild's central claim
is either true or false: that we moved the OEE computation out of the database and
into Go **without changing a single number a customer sees.**

## Where the math used to live

In the legacy system, OEE was computed *inside PostgreSQL*. Raw telemetry landed in
a table; database **triggers** fired on those writes, and **pg_cron** — a scheduler
running inside the database — periodically executed a family of stored procedures
(`piot_*`) that rolled the raw data up into hourly, shift, and daily OEE figures.

This is a legitimate way to build a first version. It is a painful way to run a
growing one:

- The business logic is **invisible** to every normal tool. You cannot read the OEE
  algorithm in a code review; it lives in `pg_proc`.
- It is **untestable**. There is no unit test for a stored procedure that reads
  half the schema.
- Every performance problem is a **database** problem, because the CPU-heavy
  computation shares a process with the storage.
- The scheduler (`pg_cron`) has no panic isolation, no per-job timeout you can
  reason about, and an opaque execution log.

The rebuild's [ADR-0014](../adr/0014-extract-oee-math-from-database-to-app.md)
decides to extract all of this into the **oeecloud-worker**, a Go service. But the
extraction has a hard constraint: the new code must produce **byte-identical**
results to the old procedures on the same input. This chapter is about how you do
that responsibly.

## The engine's two halves

Where the [transformer](03-the-edge.md#the-transformers-responsibilities-exactly)
owns *protocol and durability*, the worker owns *raw persistence and computation* —
and, symmetrically, it does **not** own protocol (it never sees MQTT or SparkPlug;
it consumes already-decoded messages off the bus) and does **not** own the read
surface (that is refdata-api, [Chapter 6](06-apis-and-operator.md)). It is the only
service that both writes raw telemetry to the database and computes OEE from it.

The worker (`services/oeecloud-worker/`) does two distinct things.

**1. It consumes the bus and writes raw data.** An AMQP consumer reads the messages
the transformer published, and a set of *writers* upsert them into the database —
`equipment_values`, the current-state tables, PO parameters. This is the fast,
latency-sensitive ingest path. It fans each message to the three flows by reading
the `source_type` stamp from [Chapter 3](03-the-edge.md).

**2. It runs the scheduled computation.** About thirteen jobs run on timers — the
rollups, the PO-runtime calculations, the shift resolver, the UNS current-state
refresh, the per-customer report writers. *These are the ported stored procedures.*
This is the slow, CPU-heavy engine path.

Keeping these two on one clock inside one binary was the *correct migration shape* —
one process to bake, one place to reason about — but it is the wrong end state, and
[ADR-0017](../adr/0017-endgame-process-separation-and-enterprise-hardening.md) splits
them apart once the migration stabilizes. We return to that in
[Chapter 9](09-the-endgame.md).

## How Go talks to the database

Before the scheduling and the math, the plumbing — because "the engine processes the
database" is a claim that has to cash out in real connections and real SQL. Three
mechanics carry it, and the third is the one that makes the whole three-flow
migration cheap.

**A connection pool per physical database.** The worker holds pooled connections via
`pgx` (`pgxpool.Pool`) — one pool to the main database, and a second to the separate
refactored database (F3). Nothing opens a connection per query; work borrows a
connection from the pool and returns it.

**The ingest path writes in batches, not row by row.** When a message arrives, its
writers don't fire one `INSERT` per value. Each writer builds a query object that the
handler *enqueues into a `pgx.Batch`*, and the whole batch executes in one round trip
per delivery. This is the difference between a fast ingest path and a database melting
under per-row chatter. The package comment states the split plainly:

> *Writers no longer execute … they return `*Query` for the handler to enqueue into
> a `pgx.Batch`. Handler executes all of a delivery's queries as one batched
> round-trip.*

Each `*Query` is an idempotent UPSERT keyed on `(ts_value, id_equipment)` — the same
grain the legacy Node-RED node wrote, now visible Go instead of a buried flow node:

```go
// internal/writers/equipment_values.go — one metric → one batched UPSERT (trimmed)
INSERT INTO %s.equipment_values
    (ts_value, id_enterprise, id_site, id_area, id_equipment,
     tp_equipment, net_production_incr, net_production_val, speed, ...)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, ...)
ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
    net_production_incr = EXCLUDED.net_production_incr,
    net_production_val  = COALESCE(EXCLUDED.net_production_val, equipment_values.net_production_val),
    ...
```

The `ON CONFLICT … DO UPDATE` is what makes the whole pipeline safe to retry: a
message replayed from the transformer's outbox re-lands on the same key and updates
in place rather than duplicating, so "never lose a message" upstream never becomes
"double-count a message" downstream.

**The compute path fans one function across flows by swapping `search_path`.** This is
the elegant part. Recall the [three flows](02-architecture-at-a-glance.md#idea-2--the-three-flows)
write to three different schemas. The worker does *not* have three copies of each
rollup. It has one, and it runs it against each destination by changing the schema on
the connection's search path. A small helper loops the destinations:

```go
// internal/jobs/jobs.go — run one pass against every flow destination
func RunPerDest(ctx context.Context, dests []flows.Dest, name string, logger *slog.Logger,
    fn func(ctx context.Context, d flows.Dest) (int64, error)) error {
    for _, d := range dests {
        n, err := fn(ctx, d)   // same fn, different schema — see below
        // ... per-dest error isolation + row-count logging ...
    }
}
```

…and each pass acquires a connection, points it at that flow's schema, and runs
identical SQL:

```go
// internal/rollup/provision.go — the per-flow execution pattern
conn, err := d.Pool.Acquire(ctx)
defer conn.Release()

// The SAME code becomes F1 / F2 / F3 by changing ONE thing:
conn.Exec(ctx, fmt.Sprintf(`SET search_path TO %s, public`, d.EvSchema))

// Session-scoped advisory lock: provision and the rollup passes write
// the same grain tables; unserialized they deadlock hourly.
conn.Exec(ctx, `SELECT pg_advisory_lock(hashtextextended($1, 0))`, d.Name+":runtime")
defer conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(...)`, d.Name+":runtime")
defer conn.Exec(context.WithoutCancel(ctx), `RESET search_path`)

// ... issue the flow-agnostic SQL ...
```

Two things in that snippet are worth pausing on, because they are exactly the kind of
production concern a stored procedure inside pg_cron never had to state out loud:

- **`search_path` is how one code path serves three flows.** Write the rollup once,
  against unqualified table names, and the schema you set decides whether it lands in
  the legacy schema, the shadow-port schema, or the refactored database. That is why
  proving three flows identical costs almost no extra code — it *is* the same code.
- **The advisory lock is a scar with a story.** Provision and the rollup passes both
  write the same grain tables; run them unserialized and they deadlock every hour. A
  Postgres session-level advisory lock, keyed by flow name, serializes them. Details
  like this — and the `SET statement_timeout = 0` for the deliberately-slow hourly
  provision pass — are the operational reality of moving computation out of the
  database: you now *own* the concurrency and timeout behavior the database used to
  manage implicitly, and you state it explicitly in code.

So "the engine processes the database" means, concretely: pooled `pgx` connections,
batched writes on the hot ingest path, and one set of rollup functions replayed
across flows by schema-swapping — all of it visible, testable Go, none of it hidden
in `pg_proc`.

## The scheduler: replacing pg_cron in Go

Before the math, the rhythm. The legacy `pg_cron` rows — "run this procedure every
minute" — become Go jobs, each a goroutine on a ticker, described by one small
struct:

```go
// internal/jobs/jobs.go
type Job struct {
    Name  string
    Every time.Duration
    Run   func(ctx context.Context) error
    // Timeout: 0 → max(2×Every, 5m). A hung tick must DIE, not
    // silently stop the ticker forever (prod runs a watchdog for
    // exactly this — terminate_long_proc_runtime; we build it in).
    Timeout time.Duration
}
```

That comment is the whole philosophy in four lines. The runner gives every job
three things pg_cron never did:

- **Panic isolation** — a poison message in one job's tick is recovered and logged,
  never crashing the whole worker into a restart loop.
- **A built-in watchdog** — prod needed a *separate* stored procedure
  (`terminate_long_proc_runtime`) to kill hung engine runs; here the per-tick
  timeout is part of the runner.
- **Observability** — every tick reports an outcome (`ok` / `error` / `timeout` /
  `panic`) to a Prometheus counter, which is what the alerts and dashboards read.

The lineage is exact: a `cron.job` schedule becomes a `Job.Every`; a stored
procedure body becomes a `Job.Run`; prod's external watchdog becomes a per-tick
`Timeout`; and pg_cron's opaque log becomes structured metrics. Same rhythm, now
supervised and legible.

## The math: how Go reproduces a stored procedure exactly

Now the hard part. Here is the header of `internal/rollup/hour.go` — the ported
version of the procedure that computes each machine's hourly OEE. Read it slowly;
this comment style is the single most important convention in the codebase.

```go
// hour.go — runtime-rollup-hour (ledger name), ported from prod's
// piot_get_equipment_runtime_1hour_production (DISPATCHER-VERIFIED
// live generation, 2026-07-04). The cascade's foundation grain.
//
// EQUIVALENCE ARGUMENT:
//   - Window: flagged hour buckets in [now()−65min, now()].
//   - Phase V (ca_agg sums → gross/net/scrap): always-FOUND class →
//     eligible LEFT JOIN zero-fill. CRUCIALLY sets recalc_needed=TRUE
//     (verbatim!) — only the events phase clears the flag.
//   - Phase E (event overlaps, [ts,+1h)): GROUP BY → CONDITIONAL
//     inner join; sets recalc_needed=FALSE (the only clear);
//     oee = net/ideal, ideal=((total−planned)/60)·ideal_speed;
//     guard ts_value >= now()−6h verbatim.
//   - Exclusion lists (prod hardcodes incl. 35=CPACK) → config; our
//     flows keep CPACK live (divergence-by-config, documented).
```

Every ported file carries an **Equivalence Argument**: a phase-by-phase account of
how the Go SQL reproduces the original procedure, written so a reviewer can check
faithfulness *without* reading the 300-line PL/pgSQL source beside it. Notice what
it captures:

- **What is verbatim** ("sets recalc_needed=TRUE *(verbatim!)*") — the parts that
  must match the original bit for bit.
- **The dirty-flag choreography** — `recalc_needed` is a flag that says "this row
  needs recomputing." One phase sets it, exactly one phase clears it, and getting
  that dance wrong silently corrupts OEE. The argument documents which phase does
  what and why.
- **Deliberate divergences, ledgered** — prod hardcodes a list of enterprises to
  exclude; the port turns that into config (no literals in code — a standing rule)
  and documents that our flows keep an enterprise live that prod excludes. A
  divergence that is *chosen and recorded* is a decision; an unrecorded one is a bug.

### Two porting styles

Not everything gets a deep rewrite. The engine uses two approaches deliberately:

1. **Deep port with an equivalence argument** — for the OEE math itself. The
   procedure is rewritten as set-based Go-issued SQL, its faithfulness argued in the
   header, and guarded by golden-fixture tests (below).

2. **Verbatim execution of surviving PL/pgSQL** — for low-risk, high-volume
   *provisioning* functions (the ones that just pre-create empty bucket rows). These
   are not rewritten; the Go job simply calls the legacy function with the flow's
   schema on the search path. Zero transcription risk for periphery that carries no
   math. The deep port is spent where it matters.

### The dirty-flag cascade, concretely

The equivalence argument above kept mentioning `recalc_needed`. It is the single
mechanism that makes the whole engine tractable, so it earns a from-scratch
explanation.

Start with the problem. The database is a historian with *billions* of raw rows
([Chapter 5](05-the-database.md)). Recomputing every machine's every OEE window on
every tick is impossible. But data also arrives *late* — an operator justifies a
downtime an hour after it happened, a delayed sample lands in a bucket already
summarized. So you cannot compute a window once and forget it, either. The answer is
a **dirty flag**: a `recalc_needed` boolean on each aggregate row. A write that could
have changed a window sets the flag; a scheduled pass recomputes *only* flagged rows
and clears it. You recompute the minimum, but never miss a change.

The discipline that makes this correct is strict: **many things may set the flag, but
exactly one phase may clear it.** Get that wrong in either direction and OEE corrupts
*silently* — clear too eagerly and a late edit is lost; never clear and the row
recomputes forever, masking the fact that its inputs stopped changing. That is why
the hourly rollup's equivalence argument insists its value phase "sets
`recalc_needed=TRUE` *(verbatim!)*" while "only the events phase clears the flag."

Two faithful fragments show the flag both propagating and re-arming. First, the
hourly pass doesn't just recompute *its* grain — it marks the grains **above** it
dirty, so a corrected hour cascades up into the day and the area totals that contain
it:

```go
// internal/rollup/hour.go — the hourly pass flags the grains above it
UPDATE %[1]s.equipment_runtime_1day  d SET recalc_needed = true ...   // the day that contains this hour
UPDATE %[1]s.area_runtime_1hour      a SET recalc_needed = true ...   // the area that contains this equipment
```

Second, the PO-runtime pass **re-arms the flag on anything that can still change** —
running orders every pass, and finished ones for a 48-hour tail to absorb late
operator edits:

```go
// internal/rollup/recalc.go — keep recomputing what isn't final yet
UPDATE %[1]s.production_orders SET recalc_needed = true
 WHERE status = 2 AND recalc_needed = false;                 -- running: re-flag every pass
UPDATE %[1]s.production_orders SET recalc_needed = true
 WHERE status = 3 AND ts_start >= now() - interval '48 hours' -- finished: 48h late-edit window
   AND recalc_needed = false;
```

Read together, these are the whole cascade: writes and self-re-enqueues *set* the
flag, the rollup passes *consume* it, and the flag propagates up the grain hierarchy
so a fix at the bottom reaches every total built on it. This is the `equipment_values
→ agg_equipment_values_1min → equipment_runtime_1hour → _shift/_1day` chain from
[Chapter 5](05-the-database.md#agg_equipment_values_1min--the-first-aggregate), driven
one dirty row at a time rather than by recomputing the world.

## Proving it: golden fixtures and the differential bake

An equivalence argument is a claim. Two mechanisms turn the claim into evidence.

**Golden fixtures.** Each ported rollup has a test that stands up an ephemeral
PostgreSQL, seeds a known scenario, runs the Go SQL, and asserts the exact output.
These caught real bugs — most recently a line-level OEE that computed `0` instead of
`0.95` because a machine's ideal-speed was NULL and the port missed prod's
last-known-value fallback. The fixture for "a line with a NULL ideal speed" now
exists precisely because that case was wrong once.

**The differential bake.** In production-shaped conditions, the three flows run in
parallel on identical input and a comparator diffs them continuously. The receipts
this produced are the reason we can make the "same behavior" claim without
flinching:

- PO-runtime recalculation: **0 mismatches out of 13,162** rows compared.
- PO-runtime compute: **0 mismatches out of 13,432**.

When a mismatch *does* appear, it gets a named cause before anything proceeds. The
line-OEE bug above showed up as a handful of non-zero rows on the comparator board;
it was diagnosed, fixed against prod's actual derivation, and the fix was *verified
live* — the shadow flow's number moved from `0.000` to `0.9666`, tracking the legacy
flow's `0.9882`. That is what "provably identical" looks like in practice: not a
promise, a measurement, watched until it reaches zero.

---

Next: [The Database](05-the-database.md) — what the numbers land in.
