# 8 — Observability

A stack you cannot see is a stack you cannot operate, and a migration you cannot
measure is a leap of faith. This chapter is about how the stack makes itself
visible — and how observability is not a bolt-on here but the mechanism that makes
the whole "provably identical" migration possible.

## The three signals

The stack emits three kinds of telemetry, each answering a different question:

- **Metrics (Prometheus)** — *how much and how fast?* Every Go service exposes
  counters and gauges: messages received, jobs ticked, rows written per flow, outbox
  depth, publish confirms and nacks. These are numbers over time.
- **Logs (Loki, via Promtail)** — *what exactly happened?* Structured logs from
  every service, searchable, correlated with the metrics.
- **Dashboards (Grafana)** — *show me.* About thirteen boards, each mapped to a hop
  in the data path, plus direct-SQL boards that read the database itself.

The design rule, learned the hard way, is that **silence must mean success.** An
alert that only fires on the happy-path signal stays quiet through a crash. So the
alert rules are written to catch every terminal state, and the job runner from
[Chapter 4](04-the-engine.md) reports `ok` / `error` / `timeout` / `panic` on every
single tick — you can tell the difference between "healthy and idle" and "wedged and
silent," which are otherwise identical from the outside.

## Coverage, hop by hop

Each hop in the [architecture](02-architecture-at-a-glance.md) has its own
instrumentation and its own board:

| Hop | Key signals | Alerts on |
|-----|-------------|-----------|
| Ingest (transformer) | MQTT received, decode errors, SparkPlug sequence gaps, **outbox depth & age** | broker disconnect, outbox backing up, publish nacks |
| Bus (RabbitMQ) | queue depth, DLQ counts | *(needs a broker exporter — a known gap)* |
| Engine (worker) | `job_ticks_total{job,outcome}`, batch writes per flow | job error streaks, scheduler stalled, ingest silent, write path dry |
| The bake | per-surface mismatch counts, F2↔F3 identity fingerprints | a surface mismatched past its expiry, identity broken |
| Mirrors | replay lag, DLQ depth, comparator divergence | cursor lag, OEE divergence |
| Database & host | connections, disk | disk filling, postgres unreachable |

The single most important board is the **bake-flow-parity** board. It is not a
health dashboard — it is the *flip gate*. It shows, surface by surface, whether the
three flows agree, and the migration does not proceed while any surface shows an
unexplained non-zero. Every mismatch on that board must carry a *named cause*; a red
number without an explanation stops the clock.

## Why observability is load-bearing here

In most systems, monitoring tells you when something broke. In *this* system it does
that too — but its deeper job is to be the **evidence** for the migration's central
claim. The whole "same behavior as prod" argument from [Chapter 4](04-the-engine.md)
is not a code-review conclusion; it is a *measurement*, read off the parity board,
watched until it reaches and holds zero. When a bug was found and fixed, the proof it
worked was watching a shadow flow's number move from `0.000` to match the legacy
flow live on the board — not re-reading the diff.

This is why the durability signals (outbox depth, sequence gaps), the per-flow write
counters, and the per-surface mismatch counts all exist: they are the instruments
that let a team replace a production system and *know*, rather than hope, that
nothing a customer sees has changed.

## Honest gaps

A trustworthy observability chapter names what it can't see. The current known gaps,
tracked rather than hidden:

- **No broker/database/host exporters yet for some metric-level alerts** — queue
  depth and CAgg-invalidation backlog are visible on dashboards but not all are
  alertable until the relevant exporters land.
- **Alert delivery is not yet routed to a human channel.** The rules exist and fire
  on the dashboards; wiring them to a pager (email/Slack/ntfy) waits on a deliberate
  choice of who reads them — an alert nobody reads is worse than no alert.

Both are on the hardening track, and both are the kind of gap that is fine *while
documented* and dangerous *while hidden* — which is the whole ethic of this chapter.

---

Next: [The Endgame](09-the-endgame.md) — where the migration is going and how it
finishes.
