# Packiot Stack Documentation

This site merges the two maintained documentation sets for the Packiot industrial-IoT / OEE
platform into one browsable, searchable reference.

<div class="grid cards" markdown>

-   :material-book-open-variant: **[Stack Wiki](wiki/README.md)**

    ---

    The engineering + operations reference. Every page is sourced from the live code
    (real `file:line` citations). Start here for onboarding a client, the CS-Admin forms,
    the edge/ingestion path, and the database model.

-   :material-map: **[Guide](guide/01-what-packiot-is.md)**

    ---

    The polished, human-facing narrative. Reads top-to-bottom like a book: what Packiot is,
    the architecture, the edge, the engine, the database, the APIs, real factories,
    observability, and the endgame — plus a decision log and full service catalog.

</div>

## Where to start

- **New to the platform?** Read the Guide's [What Packiot Is](guide/01-what-packiot-is.md)
  and [Architecture at a Glance](guide/02-architecture-at-a-glance.md).
- **Onboarding a factory?** Start with [First-Time Edge Box Setup](onboarding/first-time-box-setup.md),
  then the Wiki's [Onboarding a Client](wiki/02-onboarding.md).
- **Looking something up?** Use the search box (top of the page) — it indexes every page in
  both sets. Or jump to the Wiki's [Concepts & Glossary](wiki/08-concepts.md) /
  the Guide's [Glossary](guide/glossary.md).

## The 30-second mental model

```
PLC ─(SparkPlug B / mTLS)─▶ edge (agent) ─▶ cloud decode (edge-transformer)
                                                   │ RabbitMQ
                                                   ▼
                              oeecloud-worker  ──▶  PostgreSQL + TimescaleDB
                              (writes raw + computes OEE)      │
   edge-api (control/writes) ◀── CS-Admin / operator          │ reads
   refdata-api (reads)       ─────────────────────────▶ front4 / operator SPA
```

---
*Two sources, one site. Maintained alongside the code — when you change a contract, change the page.*
