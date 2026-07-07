# 4 — The Engine

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
