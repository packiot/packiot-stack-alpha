# Welcome — what Packiot is and why it works the way it does

If you're new to this codebase, read this first. It's prose, not a reference card. After this you'll have the mental model; the reference docs (INDEX, BUSINESS-RULES, TOPICS, the ADRs) will read much faster.

---

## The one-sentence version

Packiot helps factories answer one question: *how efficiently are we actually running today?* — and it does so by reading directly from the machines on the factory floor, doing the math centrally in the cloud, and giving operators a UI to explain the gaps.

That question has a name in the industry: **OEE** — Overall Equipment Effectiveness. It's the product of three things: how much of what you made was good (Quality), how much of the time you were running at all (Availability), and how fast you ran when you were running (Performance). Multiply those three percentages and you get a single number every factory manager already cares about. Our job is to make that number trustworthy.

That makes everything else downstream. Every architectural choice in this codebase exists to keep that one number honest.

---

## Where the data comes from, and how it travels

The data lives in PLCs — the little industrial computers wired into each machine. They count units, track state ("running" vs "idle" vs "faulted"), and emit events. They speak SparkPlug B (an MQTT-based protocol on top of MQTT) or, depending on the customer, OPC-UA, S7, or Modbus. We don't get to choose; the customer's existing PLC vendor is what it is.

At each factory site we run a small stack of services that listen to those PLCs. The heart of it has been **Node-RED** — a visual flow programming tool that's the de-facto standard in industrial automation. Node-RED is good at three things: speaking factory protocols (the SparkPlug B node is mature), letting non-developers wire up per-customer customizations visually, and being extensible when you need a Python or JavaScript escape hatch. It's not good at heavy data processing, has a single-threaded runtime, and its source-of-truth file (`flows.json`) is brutal to code-review.

For years that didn't matter much. We had a small number of customers, each customer's Node-RED was managed by hand, and the cloud side did all the heavy lifting. As we've grown, two costs have crept up. First, every new customer means a substantial Node-RED-tweaking exercise that only one or two engineers know how to do safely. Second, when something goes wrong on the floor, finding the bug means reading a 1000-line `function` node that's grown organically over years.

This is the tension that drives the current architectural direction (ADR-0009): **split Node-RED into two roles**. Keep it as the visual customization layer that Customer Success engineers can edit without writing code, but move the heavy/standardized processing into a proper Go service called `edge-transformer`. Same data, same destinations, much more reviewable and testable code at the parts that matter.

The data flow today looks like this:

```
PLC → edge-node-red (per factory) → local RabbitMQ → edge-transformer (Go, per factory)
                                                        ↓
                                                    cloud edge-api
                                                        ↓
                                                    cloud TimescaleDB + Hasura
                                                        ↓
                                                    dashboards, operator UI, OEE
```

`edge-transformer` is new (as of mid-2026); for the customers who haven't been migrated yet, the path skips it and goes directly to a cloud message bus. We're in shadow-mode for most customers — the Go service receives the messages but doesn't produce authoritative output yet. The cutover from Node-RED-authoritative to Go-authoritative happens one transform at a time, with a comparator running both sides in parallel for at least 30 days before flipping. That's a deliberate slowness. The cost of getting OEE wrong is much higher than the cost of taking another month to ship a port.

---

## The cloud side: where everything converges

In the cloud (us-east-1) we run a roughly conventional stack: NestJS API, Go workers, PostgreSQL + TimescaleDB, Hasura as the GraphQL gateway, Grafana for everything operational, Authentik for SSO. Each piece is interesting for a reason worth knowing.

**The NestJS API (`edge-api`) is the control plane.** It's where Customer Success engineers onboard new factories — enterprise → site → area → equipment → shifts → packml_register, in that exact order, because the foreign keys require it. It's also where the operator UI sends critical writes (justify-an-event, start-a-PO, scan-a-box). The codebase follows a "vertical slices" pattern — each feature is a folder with its own controller, service, DAO, and module — which makes it easy to find things but means that adding a 21st HTTP endpoint feels just like adding the first one.

**TimescaleDB is where the truth lives.** Every PLC sample lands in `equipment_values`, indexed by timestamp and equipment_id. Continuous aggregates (`equipment_runtime_1min`, `equipment_runtime_1hour`, `equipment_runtime_shift`) roll the raw data up into the windows dashboards actually query. There's a non-obvious trap here: the aggregates don't update instantly — there's a 1-2 minute lag from raw insert to 1-minute cagg visibility. When you're debugging "why don't I see my data," check that first.

**All OEE math lives in PostgreSQL triggers and stored procedures, not in application code.** This is unusual in 2026. The reasoning is conservative: the math is genuinely subtle (shifts crossing midnight, lead-machine downtime propagation, CPAC 5-minute averaging), and getting it wrong is expensive. Keeping it in one place — the database, where the data also lives — has been less painful than splitting it across services. There's an ADR for the day we revisit this; we just haven't gotten there.

**Hasura sits in front of PostgreSQL as the GraphQL gateway.** Everything external — operator UI, dashboards, reports — reads through Hasura. There's a load-bearing detail here: Hasura connects DIRECTLY to PostgreSQL, NOT through pgbouncer. Hasura uses prepared statements; pgbouncer's transaction-pooling mode collides with that and produces `error 42P05: prepared statement "0" already exists` on every other `BEGIN`. We've debugged this twice. It's noted on every relevant doc.

**There's also a second database `tsp12`** — the real production data. We treat it as read-only from everywhere except the legacy production Beanstalk environment. Even pg_dump fails against it (the SELECT-only role doesn't have LOCK TABLE), which sounds inconvenient but is actually the discipline that's saved us from accidentally writing to customer data multiple times.

---

## The cloud side, continued: the workers

Three Go services do background work, and they all share a family resemblance.

**`oeecloud-worker`** consumes from the GCP PubSub message bus (the legacy edge→cloud path) and writes raw data to `equipment_values`, `equipment_events`, and `uns_metrics`. It does NOT compute OEE — that's the database's job. The service is built around a per-tenant pattern: one AMQP Channel per tenant, one Prometheus label set per tenant, all sharing one Connection. That sounds obvious but it took shipping a bug to learn — early on the service had a single global metrics counter and a tenant routing change broke silently for hours because the metric kept incrementing while the wrong tenant's data flowed through. The zettel `silent-metric-coverage-gap` is the cautionary tale. Every multi-tenant service in this codebase now follows the per-tenant pattern verbatim, which is also why the new `edge-transformer` is structured the same way.

**`mirror-worker-go`** copies operator actions from production to staging so the staging environment has realistic data to develop against. It only runs in staging. Its design is a small masterpiece of failure-handling — there's a DLQ for messages that fail more than five times, a reanimator loop that periodically wakes up dead-letter entries when their underlying cause resolves, and a comparator service that checks "is the staging mirror still faithful?" by running SELECTs against both prod and staging and emitting divergence metrics. The comparator caught a real bug within hours of its first deploy — that's the kind of feedback loop we try to build in everywhere.

**`edge-transformer`** is the newest, per-factory Go service that consumes from the local RabbitMQ exchange `edge.plc-normalized` and runs the standardized transforms (PackML param parsing, counter math, dedup, batching). It's in shadow mode today — receives messages, logs them, acks them, writes nothing — because we're staging the cutover from Node-RED. Phase 3 of ADR-0009 is when we start porting the actual transforms; that's months of work to do safely.

All three workers follow the same pattern: AMQP consumer → handler dispatcher → typed payload handlers → outputs. The pattern is so consistent that new services are nearly mechanical to spin up. That's the point.

---

## The factory side: where things get specific to each customer

This is where the story gets uglier and the codebase reflects it.

Every customer's factory has its own particular setup. Different PLC vendors, different machine layouts, different error code mappings, different counting conventions. The way the team has historically dealt with this is: each customer gets their own Node-RED `flows.json` with a per-customer customization tab where the per-customer logic lives. One real customer's file is over 3 MB — about 1,000 nodes, half of which are function nodes containing JavaScript that's grown over years.

The interesting finding from auditing a real customer's instance: about **58% of that "customization code" is actually configuration data masquerading as code**. The 8,113-line function called "set error list json" is literally a JavaScript object containing the customer's error code mappings — it has no logic, just `flow.set('error_codes', { ... 8000 lines ... })`. This pattern repeats — we found three monster functions in one customer that are pure data totaling about 9,000 lines.

That's why the new direction (ADR-0009) is explicit: the architecture distinguishes between **standardized transforms** (port to Go), **per-customer data** (move to YAML files under `clients/<customer-id>/data/`), and **per-customer logic** (stays in Node-RED, but with strict governance rules enforced by a lint script). The governance rules — max 200 lines per function, no big `flow.set` blobs, no inline HTTP endpoints — exist specifically to prevent the next 5 years from accumulating another 9,000 lines of config-in-disguise.

The lint script ships in advisory mode initially, because the existing baseline already violates several rules. Once the existing violations are cleared (which happens incrementally as transforms move to Go), the lint flips to enforcing. This is a deliberate ratcheting strategy — see the `lint-advisory-mode-ratcheting-pattern` zettel for the family of pattern this is part of.

---

## The patterns that keep recurring

A handful of architectural patterns recur across services. They're documented exhaustively in `TOPICS.md` as a reference; here's the narrative.

**Per-tenant isolation everywhere.** Every queue, every Prometheus metric label, every AWS secret prefix is namespaced by tenant. This isn't a style preference; it's how we keep one customer's bad day from becoming everyone's bad day. Failures stay scoped to a tenant's blast radius.

**Comparator validation before logic cutover.** Whenever we port a piece of logic from one implementation to another (Node-RED → Go, JavaScript → Go, old endpoint → new endpoint), we run both side-by-side and diff the outputs. The validation window is 7 days for low-risk things and 30 days for anything affecting OEE math. If we wanted to skip this and just trust ourselves, we could. We don't, because OEE math is what the customer pays us for.

**Pattern reuse over invention.** When `mirror-worker-go` solved DLQ + exponential backoff + reanimator, we agreed: any new service hitting the same problem class uses the same pattern, code lifted verbatim. The reason is honest — every novel implementation has its own novel bugs. The proven implementation has bugs we've already found.

**Recover-validate-then-merge for stranded work.** Found uncommitted code in a stash or a UU state? Test it in dev BEFORE you merge. This rule has its own zettel because we broke staging exactly this way (PR #9, June 2026). The lesson: stranded WIP isn't almost-done; it's the author hit a problem and didn't finish. Treating the stash as a deliverable is how you discover the missing-step the original author abandoned.

**Staging is canonical, production is sacred.** Push to `main` or `master` is forbidden. `edge-api/master` is the legacy Elastic Beanstalk deploy trigger that goes to real customer-facing production. We've never broken it because we've never touched it. Production gets explicit, manual promotions; staging is where iteration happens.

---

## How we make decisions

Every architectural decision lives as a numbered ADR (Architecture Decision Record) in `docs/adr/`. We use Michael Nygard's format because it forces three things every decision needs: context (why now), the decision itself, and consequences (what we're giving up). ADRs land as their own PRs, separate from implementation, so the architecture can be reviewed without the code distraction.

If an ADR's direction is parked rather than rejected, it gets `Status: Deferred` with explicit revival conditions — the signals that would justify revisiting. We don't delete deferred work; we don't pretend it's current. ADR-0007 (frontend write topology for offline tolerance) is the canonical example — the analysis is solid, the business signal just isn't there yet.

For non-architectural lessons — the kind of insight you learn from a specific debug session — we write zettels. They live in a separate notes vault, organized by pattern. Every zettel captures the **pattern**, not the **fix**, so it's recognizable next time. The current cluster contains about 60 zettels across systems / databases / linux / observability, accumulated over years.

The unifying principle is that institutional memory is the most expensive thing to lose and the cheapest thing to write down. A 20-line ADR or a 200-line zettel saves hours of re-derivation later.

---

## What you should NOT do (the hard rules)

These are the rules whose violation costs us real money or real customer data. They're absolute.

1. **Never touch `main` or `master` branches** — `edge-api/master` is the legacy production deploy trigger.
2. **Never write to the production `tsp12` database** from a new service. SELECT-only, always. The role doesn't even have LOCK TABLE, so accidental writes will fail loudly — which is the safety net we want.
3. **Never re-implement queueing, retry, DLQ, or replay logic.** Those patterns exist in `oeecloud-worker` and `mirror-worker-go`. Reuse, don't reinvent.
4. **Never merge recovered/stranded code without testing in dev first.** Per the recover-validate-then-merge zettel.
5. **Never put secrets in source code.** AWS Secrets Manager, accessed via env var. We've cleaned up enough leaked keys to know.
6. **Never skip the per-tenant pattern.** One queue, one metric label set, one secret namespace per customer. Always.

---

## Where to go next

If you want to **understand the code**, start with the ADR cluster (`docs/adr/`). The most recent ones (0008, 0009) describe the current direction. Older ones describe the foundations.

If you want to **understand the business**, read `BUSINESS-RULES.md` — it has the OEE math, the shift system quirks, the equipment hierarchy, the CS Admin onboarding flow. None of that is obvious from reading code.

If you want to **understand the architectural patterns**, read `TOPICS.md` — it's a reference card cataloging the recurring patterns and the conventions every PR is expected to honor.

If you want to **run the stack locally**, read `README.md`. The quickstart should get you to a working local environment in 5-10 minutes (longer the first time, while Docker pulls images).

If you want to **contribute**, read `CONTRIBUTING.md` — the deploy chain, PR gates, and branch protection model are non-obvious and have specific failure modes documented.

If you're hunting a bug, read the zettel cluster for patterns matching your symptom shape. Bug-cascade is the most common one (the visible symptom usually hides two more root causes underneath). Silent-metric-coverage-gap is the second most common.

---

## A closing thought

This codebase is shaped by two things in tension: the urgency of customer needs (factories don't stop for our refactors) and the cost of getting OEE wrong (it's the number we sell). Most of the conventions documented across these docs exist because we made a mistake on one of those two axes, learned from it, and wrote it down so the next person doesn't have to.

That's the whole secret. Read the docs, follow the patterns, write down what you learn. The codebase rewards that more than cleverness.

Welcome.
