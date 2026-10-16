# 9 — The Endgame

The last chapter is about where all of this is going. The stack you've read about is
not a finished product sitting in production — it is a migration in flight, on
staging, days from its decisive moment. This chapter is the map from "here" to
"done."

## The finish line

The migration is complete when all of the following are true:

1. **One database.** The refactored schema (`packiot_analytics`) is promoted to be *the*
   database; the legacy schema and the shadow-port schema retire.
2. **Four clean services.** The ingest consumer, the engine, the report writers, and
   the read API each run independently, each least-privileged, each with its own
   SLOs and alerts.
3. **One bus, one ingest protocol.** RabbitMQ as the only data-plane bus; MQTT /
   SparkPlug as the only factory ingest. The old GCP PubSub and Node-RED pairs are
   gone.
4. **Production runs the new stack.** Real factories cut over, legacy decommissioned.
5. **It is operable.** Backups are restore-drilled, runbooks exist, and the hard-won
   rules from the migration are encoded as CI gates rather than tribal memory.

## The path, in phases

The route there is a sequence of phases, each with a clear entry and exit. In brief:

- **The flip** — collapse the three flows into one. Once the differential bake has
  been green for its full window, `packiot_analytics` is promoted and the parallel
  machinery (shadow schema, mirror replay, dual-emit) retires. This is a ~30-minute,
  env-reversible operation, and it is the pivot the whole staging effort has been
  building toward.
- **Stabilize** — a soak period on the single flow, during which backups get
  restore-drilled and alerting gets wired to humans.
- **Retire the read layer** — the Hasura GraphQL layer is replaced by refdata-api
  and removed.
- **Finish the schema** — consolidate the aggregate naming, complete the tenant
  pools, apply the retention and compression policies, and rename the last legacy
  objects (each behind a compatibility view so nothing breaks).
- **Split the engine** ([ADR-0017](../adr/0017-endgame-process-separation-and-enterprise-hardening.md))
  — the worker monolith, which was the correct *migration* shape, becomes separate
  ingest / engine / reports services along its natural fault and scaling boundaries.
- **Migrate production** — the real cutover: pool DDL with backfill, factory-by-factory
  MQTT cutover, and legacy decommission, each step behind a soak and a rollback
  window.

Alongside all of it runs **hardening** — backups, security, on-call runbooks, load
tests, and the CI gates that turn the migration's lessons into enforced rules.

## Two principles worth carrying forward

The endgame is disciplined in a way worth internalizing, because it is *why* a
migration this large is not terrifying.

**Gates come in three kinds, and you treat them differently.** A *clock* gate (a
bake window) cannot be compressed — a week-boundary bug only appears at a week
boundary, so you wait. A *human* gate (a sign-off) transfers accountability and can
be deferred-with-evidence but never silently skipped. A *code* gate is the only kind
you can burn down early — so you do, aggressively, until the critical path contains
no unwritten code. When every remaining blocker is a clock or a signature and never
"someone still has to build X," the migration is in a good place.

**Every irreversible step gets a reversible approach.** The flip is env-reversible
with the old database frozen-read for a month. Every rename ships with a
compatibility view. Every destructive cleanup runs behind one precise predicate with
a captured baseline. The pattern is always: make the scary thing rehearsable and
undoable, so the actual cutover is boring.

## Where to go next

This guide told the story. When you need to go deeper:

- The **[decision log](10-decision-log.md)** indexes every architecture decision —
  the arguments behind everything you just read.
- The **[reference material](../README.md#reference-material-the-why-and-the-how-to)**
  holds the operational artifacts: the flip runbook, the gate boards, the as-executed
  migration SQL, the schema and naming maps.

And if you are here to *work* on the stack rather than understand it: read this guide
end to end, then find the current phase in the endgame roadmap, and pick the topmost
thing that is neither a clock nor waiting on a human. That is always the next move.

---

That's the whole stack, end to end. You now know what every piece does, why it
exists, and where it is going. Welcome aboard.
