# C2 — ERP / database connector (ADR-0019 G1)

The biggest single gap. Incoplast runs a two-way sync with an on-prem Oracle ERP:
it *writes* downtime and production records into ERP tables and *reads* production
orders, scrap, and the user list back out. Today this has no home in the
architecture — the assessment found it done through a mix of a database node and
shell scripts writing CSV files, with **cleartext credentials in the flow**. This
capability gives it a proper, governed, secrets-safe home.

> **Status**: design (2026-07-08). Implementation validates against a real (or
> mocked) Oracle at tenant stand-up; the connector is inert until a tenant's
> descriptor declares an `integrations[].type: database`.

## Where it runs and what defines it

A **per-factory connector** — it talks to the customer's on-prem database, which is
reachable only from the factory network, so it lives on the edge tier alongside the
transformer (a sidecar or a transformer sub-module). It is defined entirely by the
descriptor, never by inline config:

```yaml
integrations:
  - type: database
    driver: oracle            # oracle | mssql | postgres | odbc
    dsn_ref: secret://incoplast/erp/dsn    # RESOLVED at runtime; never a value
    reads:
      - dataset: production_orders
        sql_ref: sql/incoplast/read_pos.sql   # SQL template, versioned in the tenant dir
        into: pipeline                          # POs → the PO-control path
        cadence: 15m
    writes:
      - dataset: downtime
        sql_ref: sql/incoplast/write_downtime.sql
        from: equipment_events                  # our events → their PACKIOT_PCPAPPARADA
        cadence: on-event
    dedup_key: id_external    # declarative dedup (replaces Incoplast's `differences` nodes)
```

## The connector's responsibilities

- **Resolve secrets by reference** — `dsn_ref: secret://…` is fetched from the secret
  store (AWS Secrets Manager) at runtime. The connector *refuses to start* if a DSN
  is a literal value rather than a reference. (The Incoplast cleartext-Oracle-creds
  finding, made structurally impossible.)
- **Reads** — run the read SQL template on cadence; map rows into the platform
  (production orders → the PO-control path via edge-api; scrap/users → their tables).
- **Writes** — run the write SQL template, mapping platform events (downtime,
  production) into the customer's ERP tables.
- **Declarative dedup** — `dedup_key` replaces the ad-hoc `differences`/rbe nodes; a
  row already synced (by key) is not re-sent.
- **Durability + observability** — reads/writes go through the same outbox+confirm
  discipline as the rest of the edge; every sync emits metrics (rows read/written,
  errors, lag) so an ERP outage is visible, not silent.

## What it replaces

- The customer-DB node in the Node-RED flow → this connector.
- The `oracle_get_pos.sh` shell script + `.txt`/`.csv` intermediate files → **rejected**
  (ADR-0019 G2: shell/file bridges are the un-observable failure mode the stack
  exists to kill). Their logic moves into the read/write SQL templates.
- The cleartext credentials → secret references, enforced at load.

## Security posture (this reaches into a customer's corporate network)

- Secrets by reference only, enforced at connector start.
- SQL templates are *versioned, reviewed files* in the tenant directory — not
  runtime-constructed strings (no injection surface).
- Least-privilege DB account on the customer side (documented as an onboarding
  requirement, not something we control but something we require).
- The connector's network reach (into the ERP host) is a per-factory deployment
  fact, isolated to that edge.

## Test strategy

Build against a **mock/containerized database** (an Oracle-XE or a driver-compatible
stand-in) with the read/write SQL templates, asserting: secret-by-ref enforcement,
dedup, and correct row mapping both directions. The real customer Oracle is the
Phase-F factory-side validation. Inert until a descriptor declares the integration.
