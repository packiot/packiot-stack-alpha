# Tenant descriptor + isolation gate — concrete spec (ADR-0021 M1)

This is the concrete design behind [ADR-0021](../../0021-multitenancy-model.md): the
exact shape of a **tenant descriptor** and the definition of the **isolation gate**
that proves the shared cloud tier keeps tenants apart. ADR-0021 defines *why* and *the
model*; this doc defines *the artifact and the test*.

## 1. The tenant descriptor

A tenant is one directory, `clients/<tenant>/`, holding a single declarative
descriptor plus its governed customizations. Nothing about a tenant lives in a service
env var, a seed-file ordering, or a forked flow. Four parts:

```
clients/incoplast/
  client.yaml            # identity + config + capabilities  (the descriptor)
  secrets.ref.yaml       # secret REFERENCES only (never values)
  customizations/        # governed Node-RED flows (Layer B)
    custom-counter.json
    reel-tracking.json
```

### 1a. `client.yaml` v1.1 — the descriptor schema

Extends today's honored skeleton (`tenant_id`, `customer`, `environment`,
`equipments`) with three new top-level sections. The loader
(`services/edge-transformer/internal/clientconfig/loader.go`) grows to parse these
(task C0); until then they parse-and-ignore, so the file is forward-compatible.

```yaml
schema_version: "1.1"

# ── identity (honored today) ────────────────────────────────────────
tenant_id:    incoplast          # first packml_topic segment, lowercased
customer:     "Incoplast (São Ludgero)"
environment:  staging | production

# ── config: how this factory's data is shaped ──────────────────────
plc:
  protocol: sparkplug | s7 | opcua | modbus
  endpoints:
    - name: NovoFlex-015
      host_ref: secret://incoplast/plc/novoflex-015-host   # by reference
      rack: 0                      # S7-specific (the schema gap ADR-0019 named)
      slot: 2
equipment_mapping:
  - packml_topic: INCOPLAST/SL/EXTRUSAO/NovoFlex-015
    id_equipment: 41
    erp:                           # per-tenant ERP dimensions (no home before v1.1)
      recurso: EXT-015
      etapa:   EXTRUSAO
shifts:
  source: cloud_db | descriptor

# ── capabilities: what this tenant's stack must stand up ───────────
capabilities:
  operator:
    mode: cloud | edge            # edge ⇒ deploy the SPA at the factory (offline)
    language: pt-BR
  commands:
    enabled: true                 # operator→PLC write-back ⇒ needs the command channel
    allowed: [po_setup, param_write]
  integrations:
    - type: database              # the ERP connector (ADR-0019 G1)
      driver: oracle
      dsn_ref: secret://incoplast/erp/dsn
      reads:  [production_orders, scrap, users]
      writes: [downtime, production]
      dedup_key: id_external
  customizations:                 # references the governed flows in customizations/
    - custom-counter
    - reel-tracking
```

**Rules the descriptor enforces (CI-lintable):**
- No secret *values* anywhere — only `secret://…` references (the Incoplast cleartext-
  Oracle-credentials lesson, made structural).
- `tenant_id` must equal the first `/`-segment (lowercased) of every `equipment_mapping`
  topic — the discovery contract, checked statically (the silent-drop class of bug).
- `capabilities.commands.enabled: true` requires the command channel (C1) to exist in
  the target environment; `operator.mode: edge` requires the edge operator (C3).
  A descriptor asking for a capability the environment can't provide fails validation.

### 1b. How the two tiers consume one descriptor

The point of a single descriptor is that both tiers read the *same* file:

| Field | Cloud tier reads it to… | Edge tier reads it to… |
|-------|------------------------|------------------------|
| `tenant_id` / identity | scope pool reads + refdata `customer_id` | name queues + Prometheus labels |
| `equipment_mapping` | resolve topic→equipment on ingest | wire the PLC adapter |
| `capabilities.operator.mode` | serve this tenant from the cloud SPA (if `cloud`) | deploy the edge SPA (if `edge`) |
| `capabilities.commands` | authorize command endpoints in edge-api | subscribe + execute PLC writes in the transformer |
| `capabilities.integrations` | — | stand up the ERP connector |
| `customizations` | — | load the governed flows |

The descriptor is the contract; neither tier hardcodes the tenant.

## 2. The isolation gate

Because the cloud tier is shared, isolation is a *guarantee to be measured*. The gate
is a test that stands up **two** tenants and asserts **zero cross-tenant bleed**. It
has three levels, run where each is possible:

### Level 1 — pool-schema segregation (doable NOW, pre-flip)

The refactored pools (`customer_reports.shift`, `.speed`, …) carry a `customer_id`
column. Level 1 proves the *mechanism* isolates: insert rows for two synthetic
`customer_id`s, run the exact refdata access pattern (`WHERE customer_id = $1`, id
injected server-side), and assert each caller sees only its own rows and the
unfiltered surface is never exposed. Runs against the isolated `packiot_refactor`
sandbox (which has the pools) — never the parity bake.

**This is the pre-flip de-risk.** It answers "does the pool pattern actually segregate
two tenants" without a full tenant environment.

> **Level 1 VERIFIED 2026-07-08.** Pool schema carries `customer_id` (✓); refdata
> injects it server-side from the API key as `$1`, never client-supplied
> (`query.go` `compile(q, customerID)`); the report writers parameterize it with a
> test guarding against a hardcoded tenant (`sap13_test`: "tenant got hardcoded");
> and a demonstrative 2-tenant insert in the sandbox segregated with **0 leaked rows**.
> The pool multi-tenancy mechanism is sound. Levels 2–3 (live service, full tenant)
> await the post-flip Incoplast stand-up.

### Level 2 — refdata request isolation (post-flip, on the promoted stack)

Two API keys (`stg-cpack-key`, `stg-incoplast-key`) → two `customer_id`s. Every
`/v1/*` fixed route and `/v1/query` dataset, called with each key, returns only that
tenant's rows; no parameter a client can set escapes its `customer_id`. Asserts the
server-side scoping holds across the whole read surface.

### Level 3 — full-tenant end-to-end (post-flip, the live Incoplast tenant)

CPACK and Incoplast both running through the shared cloud tier: rollups, PO runtime,
current-state, and reports for one tenant never read or write the other's rows.
This is the real acceptance test, and it needs the live Incoplast tenant (Layer A,
post-flip).

### The gate as a merge rule

Level 1 becomes a **CI gate** the moment it's written: any change to a pool, a refdata
dataset, or a rollup that could leak across `customer_id` fails it. Levels 2–3 run at
tenant stand-up. Isolation stops being a hope and becomes a check that has to stay
green.

## 3. What this unblocks

- **C0** implements the loader for §1a.
- **M2** runs Level 1 now (pre-flip) and wires it as the CI gate.
- **M3** (cloud operator per-session) reads `capabilities.operator.mode` + `tenant_id`
  from the descriptor instead of the pinned `ID_ENTERPRISE` env.
- **R1** (id_enterprise from DB) is subsumed: services resolve identity from the
  descriptor, not a positional literal.
