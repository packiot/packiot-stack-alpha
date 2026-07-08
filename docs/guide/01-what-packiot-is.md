# 1 — What Packiot Is

## The question a factory is always asking

Walk onto a manufacturing floor and you will find expensive machines that are
supposed to be running. Some are. Some are stopped for a tool change. One is
running but slower than it should. Another is producing parts that fail
inspection. The plant manager's core question — the one that decides whether the
factory makes money — is simple to ask and hard to answer:

> **How efficiently are these machines actually running, right now and over time?**

Packiot answers that question. It connects to the machines, watches what they do,
and turns the raw signals into a single, comparable score.

## OEE: the number everything serves

That score is **OEE — Overall Equipment Effectiveness** — and almost everything in
this stack exists to compute it correctly. OEE is the product of three factors,
each a percentage:

```
OEE  =  Availability  ×  Performance  ×  Quality
        (was it running   (was it running   (were the parts
         when it should?)  at full speed?)   good?)
```

- **Availability** asks whether the machine was producing during the time it was
  scheduled to. A machine stopped for an unplanned fault loses availability; one
  stopped for a planned changeover is accounted for differently. Knowing *which*
  kind of stop happened is a whole subsystem (downtime classification).
- **Performance** compares the actual production speed to the machine's *ideal*
  speed. A machine crawling at half its rated rate is "available" but performing
  poorly.
- **Quality** is the fraction of production that was good, not scrap.

A machine that ran the whole shift, at full speed, with no scrap, scores 100%.
Real factories live in the 40–85% range, and the entire value of the platform is
showing them *where* the lost points went — which machine, which shift, which
downtime category — so they can win them back.

A worked example makes the three factors concrete. Take one 8-hour (480-minute)
shift on a single machine:

- It was **scheduled** to run all 480 minutes, but lost 48 to an unplanned jam —
  so it ran 432. **Availability = 432 / 480 = 90%.**
- At its ideal speed it would have made 43,200 units in that running time; it
  actually made 36,720. **Performance = 36,720 / 43,200 = 85%.**
- Of those 36,720, some 720 were scrap, leaving 36,000 net good.
  **Quality = 36,000 / 36,720 ≈ 98%.**

Multiply: **OEE = 0.90 × 0.85 × 0.98 ≈ 75%.** The power of the decomposition is
that 75% is not a verdict, it is a *diagnosis*: the machine's biggest loss is the
15 performance points, not the jam or the scrap — so that is where the plant
manager looks first. Every number in this stack exists to make that breakdown
trustworthy. (These are the exact ratios the engine computes in
[Chapter 4](04-the-engine.md): `quality = net/gross`, `availability = running/available`,
and `oee = net / (ideal × time)`.)

## The shape of the data

To compute OEE, the platform tracks a small number of core concepts. You will meet
all of them again, in detail, in [Chapter 5](05-the-database.md); for now, just the
vocabulary:

- **Equipment** — a machine, or a group of machines (a *sector* or a whole
  production *line*). Equipment is organized in a hierarchy: an **enterprise** owns
  **sites**, a site has **areas**, an area contains **equipment**.
- **Production Order (PO)** — a unit of work: "make 5,000 units of product X on
  machine Y." A PO has a lifecycle (available → running → paused → finished) and is
  the business object OEE is ultimately reported against.
- **Downtime event** — a period a machine was stopped, and its classification
  (planned? changeover? unplanned fault?). This is the raw material of Availability.
- **Shift** — the calendar of when a factory is scheduled to run. OEE is almost
  always reported per shift, because "70% efficient" only means something against
  "during the hours we intended to produce."

Raw machine signals flow in continuously; these concepts are computed *from* them.
How that computation happens — and how we moved it from a database to Go code
without changing a single number — is the heart of this stack.

## Why we are rebuilding it

Packiot works today. Real factories depend on it. So why does most of this
documentation describe a *new* stack?

Because the original one grew the way successful systems do: feature by feature,
customer by customer, for about five years — and it accumulated the debt that
comes with that. Three problems, specifically, drove the rebuild:

1. **The database became the application.** OEE was computed inside PostgreSQL —
   in triggers and scheduled stored procedures. That is a clever way to start and a
   painful way to scale: the math is invisible to normal tooling, impossible to
   unit-test, and every performance problem is a database problem. (We fix this in
   [Chapter 4](04-the-engine.md).)

2. **Tenancy was encoded in table names.** Onboarding a new customer meant creating
   tables like `report_speed_enterprise_33` — schema changes per customer, no
   cross-customer analytics, and reports that drifted apart. (We fix this in
   [Chapter 5](05-the-database.md).)

3. **The ingestion path was a tangle of Node-RED flows** doing protocol decoding,
   buffering, and business logic all at once — hard to observe, hard to make
   durable, and forked per customer until no two factories ran the same code. (We
   fix this in [Chapter 3](03-the-edge.md).)

The rebuild's thesis, in one sentence: **push every concern to the layer that is
actually good at it** — protocol handling to a purpose-built Go service, OEE math
to testable application code, storage and time-series compression to the database,
tenancy to data rather than schema — while changing *nothing a customer can
observe*. That last clause is not a slogan; it is a measured constraint, and
[Chapter 4](04-the-engine.md) shows how we proved it to the digit.

---

Next: [Architecture at a Glance](02-architecture-at-a-glance.md) — the whole system
in one picture.
