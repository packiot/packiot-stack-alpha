# Customization & Integration under a Data Contract — design + gap analysis

**Status:** Draft (2026-09-15). Bridges ADR-0019 (edge customization capabilities),
ADR-0058 (mature customization: declarative transforms + governed Node-RED),
ADR-0045 (descriptor SSoT), ADR-0059 (customization observability). Benchmarked
against HighByte Intelligence Hub / Ignition (see
`memory: reference_customization_competitive_landscape`).

---

## 0. TL;DR (corrects an earlier claim)

An earlier competitive note said "Packiot has no direct factory-SQL customization
connector." **Verified against the code — that is wrong.** Packiot already has a
well-architected factory-DB/ERP connector: `services/sparkplug-decoder/internal/
erpconnector` (ADR-0019 G1). The real gaps are narrower and more actionable:

1. **`erpconnector` is built + unit-tested but NOT wired into any running binary**
   (zero non-test callers of `erpconnector.New`; the read sink → PO-control path is
   explicitly "a later step" in its own doc). It is a library with an open seam.
2. **No data contract on the read output.** `ReadResult.Rows` is `[]Row` where
   `Row = map[string]any` — untyped. There is no schema/model binding a read
   dataset to a canonical platform entity (production_orders, downtimes, users),
   and no validation/quality gate. This is precisely the "Model" that HighByte
   forces every read through.
3. **Two customization mechanisms are not unified.** Stream-tag transforms
   (ADR-0058 `DerivedRule`: expr/integral/sum, wired + deployed) and factory-DB
   integration (ADR-0019 `erpconnector`, unwired) are declared in different parts
   of the descriptor and governed by different code paths. There is one contract
   (the descriptor) but two disjoint sub-models.
4. **No simulate/preview for DB integrations.** ADR-0058 tag-derive rules have a
   `/v1/onboard/simulate` dry-run + a UI preview; DB reads/writes have neither.

Net: Packiot is **not missing the connector** — it is missing the **wiring, the
typed data contract on reads, unification, and dry-run** around a connector whose
*governance* (secret-ref-only DSN, versioned SQL template files, no runtime SQL
concatenation, declarative dedup) is arguably **ahead of** HighByte's raw DB
connections.

---

## 1. The data-contract lens

A **data contract** is a formal, versioned agreement on the *schema, semantics,
and quality* of data crossing a producer↔consumer boundary. In DataOps/UNS tools
this is the central object: **HighByte "Models"** and **Ignition tag/UDT
definitions** are data contracts — every source is mapped onto a typed model
before it flows downstream.

**Packiot already has a data contract: the descriptor** (ADR-0045 SSoT,
`client.yaml` → `clientconfig` → `tenantprofile`). It declares the canonical
SparkPlug tag model, the resolved derive rules, and `capabilities.integrations`.
The descriptor lifecycle is *authorable → validated → resolved → evaluated →
fault-isolated* (ADR-0058 P1). So the contract exists and has governance — but it
covers **stream tags richly** and **DB integrations only structurally** (it
declares *that* a DB integration exists and *which* SQL files run, but not *what
shape* the read rows must have, nor how they map to canonical entities).

The design goal: **make every customization AND integration a first-class,
typed, validated, versioned clause of the one descriptor contract** — whether it
transforms a tag, reads an ERP table, writes a downtime back, or runs a bounded
Node-RED flow.

---

## 2. Inventory: the three customization/integration mechanisms

| Mechanism | ADR | Where declared | State | Data contract? |
|---|---|---|---|---|
| **Stream-tag derive** (`expr`/`integral`/`sum`) | 0058 | `equipment[].derived` | Built, wired, **deployed**; simulate + UI (`/app/customizations`) | Yes — resolved `tenantprofile.DerivedRule`, validated at generate, observable (ADR-0059) |
| **Factory-DB / ERP connector** (read POs/scrap/users; write downtime/production) | 0019 G1 | `capabilities.integrations[].type=database` | **Built as a Go library, NOT wired**; read sink is an open seam | **Partial** — declares driver/dsn_ref/reads/writes/dedup_key, but read **rows are untyped `map[string]any`**; no entity mapping/quality gate |
| **Node-RED escape hatch** (arbitrary bounded logic) | 0058 Tier-2 / 0019 G2 | `customizations[]` (raw NR nodes) + embedded editor (Box Ops) | Deployed | Weak — raw NR nodes; governed by ADR-0009 bounds, not a typed contract |

**Evidence (hardproofed):**
- `erpconnector/doc.go`: driver-agnostic (oracle|mssql|postgres|sqlite), secret-ref
  DSN, versioned SQL templates, declarative dedup; "wiring the sink INTO the
  PO-control path … is a later step."
- `grep erpconnector.New` outside tests → **0 callers** (not instantiated in
  `cmd/edge-transformer` or anywhere).
- `connector.go`: `type Row map[string]any`; `ReadResult{Dataset, Rows,
  ObservedAt}` — no typed contract.
- `clientconfig/loader.go`: `Integration{Type,Driver,DSNRef,Reads,Writes,DedupKey}`
  + `requireSecretRef` enforces `dsn_ref` is a `secret://` reference (never inline).
- ADR-0019 status = **Proposed**; G1 is "transitional (governed NR flow now, deep
  Go port on demand)" — `erpconnector` *is* that deep port, landed ahead of wiring.

---

## 3. Design

### 3.1 A typed read contract (the missing "Model")

Extend `capabilities.integrations[]` so each **read** dataset declares its target
canonical entity and a typed field mapping — the data contract HighByte forces:

```yaml
capabilities:
  integrations:
    - type: database
      driver: oracle
      dsn_ref: secret://incoplast/erp/dsn
      reads:
        - dataset: production_orders
          sql: sql/incoplast/read_pos.sql
          contract:                       # <-- NEW: the typed model / data contract
            target: production_order       # canonical platform entity
            fields:
              id_external:   { from: PO_ID,     type: string, required: true }
              product:       { from: SKU,       type: string, required: true }
              qty_planned:   { from: QTY_PLAN,  type: number, min: 0 }
              starts_at:     { from: DT_START,  type: timestamp }
            dedup_key: id_external
            on_violation: reject            # reject | quarantine | pass_flagged
      writes:
        - event: downtime
          sql: sql/incoplast/write_downtime.sql
          contract:
            requires: [id_equipment, reason_code, started_at, ended_at]
```

- The `contract` block is validated at **generate** (same stage that validates
  derive rules) — unknown target entity, missing required field, or type mismatch
  fails the bundle before deploy, exactly like a bad `expr`.
- At runtime the connector validates each `Row` against the contract **before** it
  reaches the `ReadSink` — a row that violates the contract is rejected /
  quarantined / passed-with-a-flag per `on_violation`, and counted as a
  data-quality metric (ADR-0059). This turns today's untyped `map[string]any` into
  a governed, observable typed stream.

### 3.2 Wire the read sink into the PO-control path

The connector already produces `ReadResult{Dataset, Rows, ObservedAt}` on a
cadence. Complete the seam:

```
erpconnector.Manager (cadence read)
  → contract-validate rows → typed canonical entities
  → ReadSink → edge-api PO-control endpoints (production_orders upsert,
                                              downtime/production write-back)
  → ADR-0059 metrics (rows_read, contract_violations, sync_lag)
```

Instantiate the Manager in `cmd/edge-transformer` (or the agent) behind the
existing "inert by construction" guard — with no `type=database` integration
declared it stays a no-op, so tenants without an ERP are unaffected. `ReadSink`
maps the validated entity to the same edge-api PO endpoints CS Admin already uses,
so **real POs replace synthetic ones** and **scrap reasons / lot genealogy** enrich
the OEE model.

### 3.3 Unify under one contract + one authoring surface

- **Descriptor:** treat `derived` (tag transforms) and `integrations` (DB reads/
  writes) as two clause types of the same customization contract, both flowing
  through authorable → validated → resolved → executed → observable.
- **UI:** extend the just-shipped `/app/customizations` page with an
  **Integrations tab** — declare a DB read/write, pick the target canonical
  entity, map fields (dropdowns off the read SQL's columns), set `on_violation`,
  and **Dry-run** (see §3.4). Same page, two tabs: *Derive rules* | *Integrations*.
- **Node-RED tier** stays the escape hatch for genuine one-offs, but ADR-0019 G1's
  intent — migrate the Incoplast-class DB flows OUT of Node-RED INTO the governed
  connector — is realized once §3.1–3.3 land.

### 3.4 Dry-run / simulate parity

Mirror ADR-0058's `simulate` for integrations: a `/v1/onboard/simulate-integration`
that opens the connection with the `secret://` DSN (or a supplied read-only test
DSN), runs the read SQL with `LIMIT`, validates rows against the declared
contract, and returns *{sample rows, contract violations, mapped canonical
entities}* — never writing. This gives the CS engineer the same "preview before
deploy, no live box needed" loop the tag-derive op-builder has, and catches
schema drift before it reaches production.

### 3.5 Governance (keep the ADR-0019 strengths; add the contract)

Retain and formalize:
- **Secret-ref-only DSN** (`secret://…`, resolved at runtime; literal DSN refused).
- **Versioned SQL template files** — reads/writes are references to reviewed files,
  never runtime-concatenated SQL (no injection surface).
- **Declarative dedup** (`dedup_key` + `SeenSet`).
- **Add:** typed read/write contracts (§3.1), contract-violation observability
  (ADR-0059), and dry-run (§3.4). Config-as-code + RBAC already exist via csadmin.

---

## 4. Integration purposes (what this unlocks)

- **Real production orders** from the customer's ERP/MES instead of synthetic/
  CS-entered POs → OEE denominators become ground-truth; the Bispharma-class
  "PO source (owner decision)" gap closes.
- **Scrap reasons & lot genealogy** joined to the OEE model → Quality analysis by
  reason code, not just a scrap count.
- **User / shift / calendar** context pulled from the factory system of record.
- **Write-back**: downtime and production records INTO the customer's ERP → the
  platform becomes bidirectional (the HighByte/Ignition parity axis), replacing the
  Incoplast cleartext-creds Node-RED anti-pattern the assessment flagged.
- **Historian bridge** (later): the same driver abstraction + contract extends to
  SQL historians (PI/IP.21 via JDBC/ODBC) as read sources.

---

## 5. Where this puts Packiot vs HighByte / Ignition

| Axis | HighByte / Ignition | Packiot after this design |
|---|---|---|
| Factory SQL read+write | First-class connections; read rows shaped by a typed **Model** | `erpconnector` (built) + typed read **contract** (§3.1) → parity, with **stricter** provenance (secret-ref + versioned SQL, no runtime concat) |
| Transform richness | JS (GraalVM) / Jython + staged pipelines | expr-lang + integral/sum/counter-derive + Node-RED tier — on par for common cases; fewer staged-ETL primitives |
| Data contract | Model / UDT enforced | Descriptor SSoT + typed derive rules + (new) typed integration contracts |
| Governance | Git-backed projects, RBAC | Descriptor-as-code, RBAC (csadmin), secret-ref, versioned SQL, dedup, ADR-0059 observability — **ahead** on connector provenance |
| Dry-run | Model test | tag-derive simulate (shipped) + integration dry-run (§3.4) |

**Bottom line:** the incumbents' edge is *breadth* (many connectors, staged-pipeline
ETL, mature Models). Packiot's edge is *governance-by-construction*. This design
closes the two real gaps (wire it; give reads a typed contract) without giving up
the governance advantage.

---

## 6. Phased plan

- **P1 — wire it (no new contract):** instantiate `erpconnector.Manager` in the
  transformer behind the inert guard; land `ReadSink → edge-api PO upsert` for the
  `production_orders` dataset; ADR-0059 metrics. Hardproof against a read-only test
  DSN. *(Unlocks real POs — highest value.)*
- **P2 — typed read contract (§3.1) + validation at generate + runtime gate.**
- **P3 — dry-run endpoint (§3.4) + `/app/customizations` Integrations tab (§3.3).**
- **P4 — write-back path** (downtime/production Events → ERP) + dedup soak.
- **P5 — migrate Incoplast-class Node-RED DB flows INTO the connector** (ADR-0019
  G1's stated end state); historian (PI/IP.21) read source.

Each phase is independently shippable and hardproovable (dry-run against a test DSN;
contract-violation counts; sync-lag gauge), matching the ADR-0058 discipline.
