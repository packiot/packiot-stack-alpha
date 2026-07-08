# Packiot Stack — Documentation

This is the documentation for the Packiot platform: the software that tells a
factory **how efficiently its machines are running**, and the rebuilt stack we
are migrating it onto.

If you are new here, read the guide in order. It is written as one story — each
chapter assumes the one before it — and it is meant to take a couple of hours to
turn "I have never seen this system" into "I understand what every piece does and
why it exists."

## The guide (read in order)

| # | Chapter | What you will understand |
|---|---------|--------------------------|
| 1 | [What Packiot Is](guide/01-what-packiot-is.md) | The factory problem, OEE, and why we are rebuilding the stack at all |
| 2 | [Architecture at a Glance](guide/02-architecture-at-a-glance.md) | The whole data path in one diagram, the cast of services, and the three-flow migration strategy |
| 3 | [The Edge](guide/03-the-edge.md) | How a machine on a factory floor becomes a message in the cloud: PLC → Node-RED → the Go transformer |
| 4 | [The Engine](guide/04-the-engine.md) | How raw messages become OEE — and how Go code reproduces, exactly, what database procedures used to do |
| 5 | [The Database](guide/05-the-database.md) | What every core table represents, how the OEE cascade flows, and what the refactor changed |
| 6 | [APIs and the Operator](guide/06-apis-and-operator.md) | The control plane (edge-api), the read plane (refdata-api), and the operator's screen |
| 7 | [Customizations and Real Factories](guide/07-customizations-and-real-factories.md) | How the edge absorbs client-specific behavior, told through a real factory |
| 8 | [Observability](guide/08-observability.md) | How you know any of this is working |
| 9 | [The Endgame](guide/09-the-endgame.md) | Where the migration is going and how it finishes |

Keep the **[glossary](guide/glossary.md)** open in a second tab as you read — every
domain and stack term the story uses (OEE, SparkPlug, CAgg, the flip, F1/F2/F3, …)
is one crisp line there, with a link back to the chapter that explains it.

## Reference material (the "why" and the "how-to")

The guide tells the story. When you need the primary sources behind a decision, or
the exact steps for an operation, go here:

- **[Decision log](guide/10-decision-log.md)** — an index of every architecture
  decision (ADR), each a dated record of a choice and its rationale. The guide
  links into these; this is where the *arguments* live.
- **`adr/`** — the ADRs themselves.
- **`adr/reference/`** — operational artifacts: the flip runbook, gate boards,
  as-executed migration SQL, schema maps, naming maps, prod captures. These are
  live tooling for the in-progress migration, not prose.
- **`guides/`** — task runbooks (backup/restore, manual smoke check).
- **`audits/`** — point-in-time evidence (prod-vs-staging comparisons, reviews).
- **`clients/`** — per-factory configuration and onboarding material.
- **[`BUSINESS-RULES.md`](BUSINESS-RULES.md)** — the domain knowledge that isn't
  obvious from code (equipment hierarchy, shift math, OEE rules, CS-Admin
  onboarding) — most of it learned via production incidents. Read it before touching
  anything that computes OEE.

## A note on tense

This documentation describes the stack **as it is being migrated**. Two systems
coexist: the legacy production stack (still serving real factories) and the new
stack (running on staging, days from a cutover). Where that distinction matters,
the guide is explicit about which one it means. When it says "prod," it means the
old system; "the new stack" or "staging" means what we built.
