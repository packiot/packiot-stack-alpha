# ADR-0040 — Barcode / Quality-capture / Track-and-Trace: one consolidated `barcode-service`, an immutable `box_scans` Bronze fact, and server-side gapless sequence authority

**Status:** Proposed · **Date:** 2026-07-22 · **Scope:** DESIGN ONLY (this ADR is the target architecture + phased roadmap for the box-scan / quality-capture / pharma track-and-trace capability; no code, no schema change ships with it). STAGING-first; every prod-touching step is explicitly gated. · **Decision owner:** platform/data architect (pending USER review).

**Three-squad convergence.** This decision synthesizes **three independent squad reviews — DBA, data-engineer, and senior-factory-domain — that each reached the same conclusions separately.** All three independently said: (1) the two barcode scanners must collapse into **one** official service; (2) `scanned_boxes` + `sample_boxes` must become **one immutable Bronze fact** and the `box_order_number=0` sentinel must die; (3) gapless numbering is a **server-side transactional** problem, not a client one; (4) the tenant must be **derived from the token, never supplied by the client**; and (5) scans are a **parallel traceability/quality fact stream, not an OEE production count.** When a DBA, a data engineer, and a domain expert converge from three different lenses on the same shape, that shape is the decision — this ADR records it.

**Governed by / builds on:**
- [ADR-0038](0038-north-star-factory-platform.md) — the north-star. This ADR is the **how** for two of its named-MISSING/THIN pillars: **P7 Traceability/Genealogy** (rated MISSING) and **P6 Quality/SPC** (rated THIN), and it seeds **P11-B2 Andon** with its first *business* signal source. It executes north-star Phase-B charters **B1 (Quality/SPC)** and **B3 (Traceability/Genealogy)** on the box-scan data path.
- [ADR-0036](0036-data-architecture-medallion.md) — the medallion. `box_scans` is a **Bronze** immutable fact governed by the exact append-only + temporal-column contract 0036 §3/§5A defines (`ingested_at`/`source_seq`); validation is **Silver**; `po_box_counter` / `v_po_box_totals` are **Gold**.
- [ADR-0011](0011-durability-boundary-and-store-and-forward.md) — the durability boundary. A scanned box is *right of the boundary the moment the operator's device captures it*; losing it in an outage is our bug, not the factory's. The SPA outbox + idempotent ingest is the destination-side completion of that principle.
- [ADR-0026](0026-api-layer-consolidation.md) — retire Hasura / CQRS-lite. v1's Hasura GraphQL subscription is one of the **last Hasura *writers*/live-consumers**; re-homing it removes a blocker to §4 step 3 (stop serving Hasura).
- [ADR-0034](0034-adopt-cognito-amplify-auth.md) — Cognito + the write-side fence *(concurrent — `feat/adr-0034-cognito-amplify`; not yet on `staging`, referenced by canonical filename)*. The barcode write path is a **first-class instance** of the P13 write-fence: server-derived `id_enterprise`, client never names its tenant.
- [ADR-0039](0039-entity-lifecycle-deletion-strategy.md) — entity lifecycle. 0039 owns the **dimension**-side temporal/lineage columns + one-delete contract; `box_scans` is the **fact**-side counterpart (append-only, corrections-by-void), the same pattern 0036 §5A generalizes to facts.

**Relates to:** [ADR-0037](0037-oee-correctness-remediation.md) (the `data_quality_event` side-channel this ADR extends with `grain='scan'`), [ADR-0017](0017-endgame-process-separation-and-enterprise-hardening.md) (RLS evaluated-and-rejected — app-layer isolation primary), [ADR-0023](0023-concurrent-po-across-lines.md) (concurrent-PO-across-lines — the concurrency model the sequence authority must survive).

> **Numbering note.** `0038` is the north-star; `0039` is entity-lifecycle; this is `0040`. ADR-0034 (Cognito) currently lives on its concurrent feature branch — the link resolves once that PR lands on `staging`.

---

## 1. Context — two scanners, three foundational problems

### 1.1 What exists today

Box-scan / label capture is **already live**, but as two divergent frontends bolted onto a schema that was never designed for traceability:

| | **barcode-scanner-v1** | **barcode-scanner-v2** |
|---|---|---|
| Status | **LIVE** (production operators scan boxes on it today) | Built for **Bispharma** (pharma prospect); REST endpoints **stubbed**, not shipped |
| Front end | React SPA | React SPA (a cleaner, later rewrite) |
| Read path | **Hasura GraphQL subscription** over Postgres | REST (stubbed) |
| Auth | **Firebase** JWT for the user + a **hardcoded shared `x-api-key: '12345'`** for the write | intended REST auth (not built) |
| Writes to | `scanned_boxes` (production) + `sample_boxes` (QC samples) | same tables (intended) |

The **write tables** are real and citable:

- **`scanned_boxes`** — `edge-node-red/db/10-missing-tables.sql:32-47`; app-owned migrations `edge-api/migrations/20260409000003_create_scanned_boxes.ts` and `20260413000002_fix_scanned_boxes.ts` (the latter renames the PK `id`→`id_box`, adds `id_area`, and adds `UNIQUE(box_order_number, id_production_order)` as constraint `scanned_boxes_un`). Columns: `id_box BIGSERIAL PK, id_production_order, id_order NOT NULL DEFAULT 0, id_equipment, id_site, id_area, id_enterprise, increment INTEGER DEFAULT 0, ts_value TIMESTAMPTZ, box_order_number INTEGER DEFAULT 0`. Written by `edge-api/src/data/DAO/labels/labels-dao.ts`.
- **`sample_boxes`** — `edge-node-red/db/10-missing-tables.sql:71-80`; migration `edge-api/migrations/20260409000002_create_sample_boxes.ts`. Same shape plus `should_increment BOOLEAN DEFAULT false`. Written via `edge-api/src/data/DAO/samples/samples-dao.ts` (usecases `create-sample`/`edit-sample`, seed `00016_sample-boxes-seed.ts`).

Two tables, two frontends, two auth stories, **one capability**: "a human scanned a physical box." That fragmentation is the surface problem. The three problems beneath it are why this needs an ADR, not a refactor ticket.

### 1.2 Problem 1 — a per-PO counter is not a serial (the `box_order_number=0` sentinel)

`box_order_number` is the box's ordinal *within a production order*. Two facts make it structurally wrong for traceability:

1. **It carries in-band signalling.** `box_order_number = 0` is a **sentinel meaning "not a real production scan"** — the whole stack filters valid scans with `box_order_number != 0` (documented in root `CLAUDE.md:75` and the `10-missing-tables.sql:30` header comment). Overloading a data column to also mean "this row is a different *kind* of thing" is the classic **magic-value / in-band-signalling anti-pattern** — the same class of mistake as returning `-1` from a function that also returns real counts. A DBA reviewing this flags it on sight: the *type* of a fact (production vs sample vs correction) must be an explicit column, not a reserved value of an unrelated one.
2. **It is a per-PO ordinal, not a globally-meaningful identifier.** Box `#5` of PO-A and box `#5` of PO-B are different physical boxes with the same `box_order_number`. That is fine for "how many boxes has this PO made"; it is **useless for recall-by-lot, genealogy, or 21 CFR Part 11 serialization**, all of which need a *serial that identifies one physical unit for its whole life*. Pharma (Bispharma) needs SGTIN-class serialization; a per-PO counter cannot provide it.

### 1.3 Problem 2 — gaplessness enforced in a React toast

v1's operator flow computes "the next box number" **client-side** and shows it in a toast. Gapless, monotonic, no-duplicates numbering — a **transactional invariant** — is being asserted by *presentation-layer JavaScript* on the operator's phone. This fails the instant two operators scan the same PO concurrently (routine on a line with two packing stations — the exact concurrent-PO topology ADR-0023 already handles for OEE): both clients read "last = 41," both display "42," both write `42`. The only backstop is the `UNIQUE(box_order_number, id_production_order)` constraint added in `20260413000002_fix_scanned_boxes.ts` — which turns the race into a **500 error the operator sees mid-shift**, not a correctly-assigned next number. Gaplessness belongs in the database transaction, not in a toast.

### 1.4 Problem 3 — a shared API key cannot satisfy Part 11 attribution

Every v1 write authorizes with **`x-api-key: '12345'`** — the shared per-enterprise seed key (`edge-api/src/seeds/00001_enterprise-seed.ts:11`). This is the same client-names-its-own-tenant write-plane weakness ADR-0038 rates P13-write as THIN (`edge-api/src/middleware/auth.middleware.ts` + `data/DAO/auth-middleware/auth-apikey-dao.ts`). For OEE telemetry it is a hardening backlog item. For **pharma it is a hard blocker**: **21 CFR Part 11** (electronic records / electronic signatures) requires that every record be **attributable to a specific, authenticated individual** — "who scanned this box" must be a person, provable, non-repudiable. A shared `'12345'` attributes every action to *the enterprise*, i.e. to nobody. Bispharma cannot go live on a shared key by regulation. The write-fence is not a nice-to-have here; it is the business case's entry ticket.

### 1.5 Why one ADR now

Three squads reviewed this independently — the DBA saw a mutable, sentinel-encoded, race-prone fact table; the data-engineer saw an un-layered fact stream wrongly coupled (in reviewers' fear) to OEE and served over a soon-retired Hasura; the senior-factory-domain expert saw a MISSING traceability pillar and a THIN quality pillar with a live pharma prospect (Bispharma) blocked on Part 11. **All three converged on the same target.** Consolidating v1+v2, fixing the fact model, and putting the pharma tier on a config switch is a coherent single decision; splitting it across three tickets would re-litigate the same shape three times.

---

## 2. Decision — one service, one immutable fact, server-owned identity

### 2.0 Summary of the decisions (each independently reached by all three squads)

1. **Consolidate v1 + v2 into ONE official capability** — a new **Go `barcode-service`** in the stack for durable ingest + SSE fan-out, with the **v2 TS SPA (consolidated)** as the single operator front end. **Retire both** `barcode-scanner-v1` and `barcode-scanner-v2` as separate apps.
2. **One immutable Bronze fact `box_scans`** merging `scanned_boxes` + `sample_boxes` via a `scan_type` enum (`production | sample | void`) — **kill the `box_order_number=0` sentinel.** Append-only; corrections append a `void` row, never mutate.
3. **Server-side gapless sequence authority** — `pg_advisory_xact_lock(id_production_order)` + `po_box_counter.last_label_seq` + a partial-unique backstop; **ASSIGN** and **VALIDATE** modes.
4. **Server-derived tenant from the JWT** — `id_enterprise NOT NULL`, injected as `$1`; the client never names its tenant (kills `x-api-key:'12345'`). This is the P13 write-fence that Part 11 attribution forces.
5. **Scans are a parallel, independent fact stream — NOT an OEE production count.** Role: P7 traceability (primary) + P6 quality sampling + a reconciliation cross-check.
6. **Replace v1's Hasura subscription with SSE** (MVP = poll a refdata dataset); re-home the 5 Hasura views as config-driven refdata datasets → removes the last Hasura *writer*.
7. **Durability (ADR-0011):** SPA IndexedDB outbox + client `scan_uuid` → idempotent `UNIQUE(scan_uuid)` ingest + publisher confirms; never lose a box in an outage.
8. **Config-driven pharma-pack tier** (not a fork): pluggable parser, serialization/aggregation/EPCIS/Part-11, all **OFF** for CPACK/Incoplast, **ON** for Bispharma — same service, same code.

### 2.1 Target architecture

```
   Operator device (phone/tablet, warehouse gun)
        │  scan (barcode / DataMatrix)
        ▼
   barcode SPA  (the CONSOLIDATED v2 TypeScript SPA — v1 retired)
        │  • parses the symbology (packiot-counter | gs1-datamatrix)
        │  • mints a client scan_uuid
        │  • writes to an IndexedDB OUTBOX first (ADR-0011)
        │  • drains outbox → POST /scans  (Firebase/Cognito JWT, NO api-key)
        │  • reads live state via SSE  (replaces the Hasura subscription)
        ▼
   barcode-service  (NEW Go service in packiot-stack-alpha/services/)
        │  • verify JWT → derive id_enterprise SERVER-SIDE ($1)          ← P13 fence
        │  • ASSIGN | VALIDATE the gapless label seq (advisory-xact lock) ← gapless authority
        │  • idempotent ingest keyed on scan_uuid  (UNIQUE)              ← ADR-0011
        │  • append to box_scans (Bronze, immutable)                     ← ADR-0036
        │  • publisher-confirmed emit to RabbitMQ (durability)
        │  • SSE fan-out of committed scans to subscribed SPAs
        ▼
   TimescaleDB (packiot_shadow)
     BRONZE  box_scans (append-only)
     SILVER  validation (scan_type coherence, serial format, in-range, dedup)
     GOLD    po_box_counter · v_po_box_totals  (served totals)
        │
        ├─▶ oeecloud-worker → data_quality_event (grain='scan')   ← P11 andon signal
        ├─▶ reconciliation: Σ scan qty  vs  net_production per PO  → SCAN_VS_NET_DRIFT
        └─▶ refdata-api datasets (reads: totals, genealogy, DQ)   ← replaces Hasura views
```

Rationale for **a new Go service** rather than folding into edge-api: the scan path is a **high-frequency, durability-critical, real-time-fan-out** ingest with its own outbox/SSE/idempotency machinery — the same reasons `edge-transformer` and `oeecloud-worker` are their own Go services (`services/edge-transformer/internal/`, `services/oeecloud-worker/`). edge-api stays the *control-plane CRUD* authority (POs, config); `barcode-service` is a *stream ingest* authority. This is the ADR-0026 CQRS instinct applied one level down: writes with genuinely different shapes get different services.

### 2.2 One immutable Bronze fact — `box_scans` (the DBA's DDL sketch)

`scanned_boxes` and `sample_boxes` are the **same fact** ("a box was scanned") differing only in *why*. Merge them; make the *why* an explicit enum; make the table **append-only Bronze** with the ADR-0036 §5A temporal/lineage columns; correct by appending a `void`, never by mutating.

```sql
-- ── BRONZE: immutable box-scan fact (merges scanned_boxes + sample_boxes) ──
-- DESIGN SKETCH (illustrative; column tuning is a capacity/tenant decision).
CREATE TABLE box_scans (
    id_box_scan     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- WHO (server-derived — never client-supplied; §2.4)
    id_enterprise   INTEGER      NOT NULL,          -- tenant, injected as $1 from the JWT
    id_user         INTEGER      NOT NULL,          -- the authenticated scanner (Part 11 attribution)

    -- WHAT KIND (replaces the box_order_number=0 sentinel; §1.2)
    scan_type       TEXT         NOT NULL           -- 'production' | 'sample' | 'void'
                    CHECK (scan_type IN ('production','sample','void')),

    -- WHERE / WHICH RUN
    id_production_order BIGINT   NOT NULL,
    id_equipment    INTEGER      NOT NULL,
    id_site         INTEGER,
    id_area         INTEGER,

    -- THE COUNT / THE ORDINAL
    label_seq       BIGINT,                          -- the gapless per-PO production ordinal
                                                     -- (NULL for sample/void; §2.3)
    increment       INTEGER      NOT NULL DEFAULT 1, -- units this scan represents

    -- SERIALIZATION (pharma tier; NULL when the counter parser is active; §6)
    label_code      TEXT,                            -- the raw symbol payload as scanned
    sgtin           TEXT,                            -- GTIN+serial (GS1)  — pharma only
    lot             TEXT,
    expiry          DATE,

    -- CORRECTION LINK (append-a-void, never mutate; §2.2.1)
    voids_box_scan_id BIGINT REFERENCES box_scans(id_box_scan),  -- set on a 'void' row

    -- IDEMPOTENCY (ADR-0011; §2.5)
    scan_uuid       UUID         NOT NULL,           -- client-minted; dedup key

    -- BITEMPORAL + LINEAGE (ADR-0036 §5A; T0-2 temporal columns)
    ts_value        TIMESTAMPTZ  NOT NULL,           -- EVENT time: when the operator scanned
    ingested_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),  -- ARRIVAL time: when we received it
    source_seq      BIGINT       NOT NULL            -- monotonic per-writer sub-second tiebreak
);

-- Idempotent ingest: a re-drained outbox row is a no-op, not a duplicate box.
CREATE UNIQUE INDEX uq_box_scans_scan_uuid ON box_scans (scan_uuid);

-- Gapless backstop: at most one PRODUCTION row per (PO, label_seq).
-- PARTIAL so sample/void rows (label_seq NULL / reused) don't collide.
CREATE UNIQUE INDEX uq_box_scans_po_label
    ON box_scans (id_production_order, label_seq)
    WHERE scan_type = 'production';

-- Read paths: per-PO timeline, tenant genealogy, serial lookup (pharma).
CREATE INDEX ix_box_scans_po_ts   ON box_scans (id_production_order, ts_value);
CREATE INDEX ix_box_scans_ent_ts  ON box_scans (id_enterprise, ts_value DESC);
CREATE INDEX ix_box_scans_sgtin   ON box_scans (sgtin) WHERE sgtin IS NOT NULL;

-- ── GOLD: served per-PO counter + totals ──
CREATE TABLE po_box_counter (
    id_production_order BIGINT PRIMARY KEY,
    id_enterprise       INTEGER NOT NULL,
    last_label_seq      BIGINT  NOT NULL DEFAULT 0,  -- the gapless authority (§2.3)
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE VIEW v_po_box_totals AS
    SELECT id_production_order,
           id_enterprise,
           count(*) FILTER (WHERE scan_type = 'production'
                              AND NOT EXISTS (              -- exclude voided rows
                                  SELECT 1 FROM box_scans v
                                  WHERE v.scan_type = 'void'
                                    AND v.voids_box_scan_id = box_scans.id_box_scan))
               AS good_boxes,
           count(*) FILTER (WHERE scan_type = 'sample') AS sample_boxes,
           count(*) FILTER (WHERE scan_type = 'void')   AS void_scans,
           sum(increment) FILTER (WHERE scan_type = 'production') AS scanned_units
    FROM box_scans
    GROUP BY id_production_order, id_enterprise;
```

#### 2.2.1 Append-only enforcement (Bronze immutability, ADR-0036 §3)

Immutability is *enforced structurally*, exactly as ADR-0036 requires for Bronze — not left to convention:

```sql
REVOKE UPDATE, DELETE ON box_scans FROM PUBLIC, <app_role>;

CREATE OR REPLACE FUNCTION reject_box_scan_mutation() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'box_scans is append-only (ADR-0040 §2.2): % blocked. '
                    'Corrections append a scan_type=void row.', TG_OP;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_box_scans_no_update
    BEFORE UPDATE OR DELETE ON box_scans
    FOR EACH ROW EXECUTE FUNCTION reject_box_scan_mutation();
```

**Corrections = append a `void` row** carrying `voids_box_scan_id → the corrected row`. A mis-scan is never edited or deleted; it is neutralized by a compensating fact, and the original stays on the record. This is the same "never destroy the raw record" principle ADR-0036 §3.1 states for `equipment_values`, and — crucially — it is what a Part-11 audit trail *requires* (the original record and its correction both survive, timestamped and attributed). The `void` row inherits the same attribution (`id_user`) and timestamp columns, so "who voided box #5, when, and against what" is answerable by a query, not a forensic dig.

This is deliberately the **contra-entry / storno** pattern from double-entry accounting (and event-sourcing): you never erase a posted entry, you post its reversal. A senior engineer recognizes it as the only correction model compatible with an immutable, audited ledger.

### 2.3 Server-side gapless sequence authority

The next box number is a **transactional invariant owned by the database**, not the client (§1.3). Mechanism:

```
POST /scans { id_production_order, scan_type:'production', mode:'ASSIGN', scan_uuid, ... }
  ▼  (inside ONE transaction)
  pg_advisory_xact_lock(id_production_order)        -- serialize all scanners of THIS PO
  UPDATE po_box_counter
     SET last_label_seq = last_label_seq + 1, updated_at = now()
   WHERE id_production_order = $po
   RETURNING last_label_seq  AS assigned_seq         -- gapless: +1 under the lock
  INSERT INTO box_scans (..., label_seq = assigned_seq, ...)   -- partial-unique backstops it
  COMMIT                                              -- lock releases at commit
```

Two modes:
- **ASSIGN** — the server *mints* the next `label_seq` (the counter-parser tenants: CPACK/Incoplast, where the box has no pre-printed serial). The client sends no number; it *receives* one.
- **VALIDATE** — the box arrives with a *pre-printed serial* (pharma: the SGTIN is already on the label). The server does not mint; it *checks* the presented serial is well-formed, in-range/expected, and not already seen (duplicate-serial → DQ event, §2.7). `label_seq` may be derived from the serial or left NULL with `sgtin` authoritative.

**Why `pg_advisory_xact_lock`, not a `SEQUENCE`.** A Postgres `SEQUENCE` is **non-transactional by design**: `nextval()` is not rolled back on abort, and cached/`INCREMENT`-block ranges are burned on crash or session end. That is *exactly right* for surrogate keys (where gaps are fine and non-blocking speed matters) and *exactly wrong* here, where the number is a **customer-visible, gapless, auditable box ordinal**. A sequence would leave holes (`…40, 41, 43…`) that an operator and an auditor both read as "box 42 is missing" — a phantom traceability gap manufactured by the wrong tool. The advisory lock keeps the increment inside the transaction, so an aborted scan gives its number back.

**Why not an `EXCLUDE` constraint.** `EXCLUDE` is for preventing *overlap* under an operator (ranges, `&&` on time/space) — its whole power is non-equality operators. Gaplessness is **scalar equality on a monotone counter**; `EXCLUDE USING gist (... WITH =)` would be a baroque, slower way to spell what a `UNIQUE` index already says, with none of the range semantics that justify `EXCLUDE`. Using it here is a "clever tool, wrong problem" tell. The **partial-unique `uq_box_scans_po_label WHERE scan_type='production'`** is the correct, minimal backstop: it makes a double-assigned number *impossible to commit* even if the application logic regresses, without touching sample/void rows.

**Two-operators-same-PO concurrency analysis.** Two packing stations scan PO-77 at the same instant (routine; ADR-0023's concurrent-PO reality). Without the lock: both read `last=41`, both write `42`, the partial-unique rejects the second with a 500 — the operator loses the scan and retries blind. With the lock: operator A takes `advisory_xact_lock(77)`, increments to `42`, commits, releases; operator B *blocks on the lock* (milliseconds), then increments to `43`, commits. Both boxes get a number, both gapless, zero errors, ordering decided by the DB. The lock is **per-`id_production_order`**, so operators on *different* POs never contend — throughput is bounded by per-PO scan rate (a human scanning ~1 box/sec), never by global scan volume. This is the same advisory-lock discipline the rollup worker already uses for provision serialization (`oeecloud-worker` `shift.go:219` non-blocking advisory lock), applied to the box counter.

### 2.4 Server-derived tenant — the P13 write-fence (Part 11 is the forcing function)

The tenant is **resolved from the authenticated identity, server-side, and injected as `$1`** — the client never sends `id_enterprise` and never sends an api-key. This is the **read-plane's proven shape** (`services/refdata-api/cmd/refdata-api/auth_firebase.go`: verify RS256 JWT → `SELECT id_enterprise FROM users WHERE id_user_firebase=$1 AND active` → inject as `$1`, fail-closed on unknown uid) applied to a *write* path — exactly the write-side fence ADR-0034/ADR-0038 P13 call for.

- `box_scans.id_enterprise` and `box_scans.id_user` are **NOT NULL** and set from the token claims, not the request body.
- `x-api-key: '12345'` is **deleted** from the scan path. A cross-tenant scan write is *unrepresentable*: the caller cannot name a tenant it did not authenticate as.
- **App-layer isolation is primary** — ADR-0017 evaluated Postgres **RLS and (default) REJECTED it** (0017 lines 88-90: "the pool pattern + server-side `customer_id` injection gives the isolation we need without RLS's planner and operational costs"). `barcode-service` follows that ruling: the `$1` injection is the fence.
- **RLS is an optional defence-in-depth**, not the primary control — *if* pharma audit requirements later want a second belt, an RLS policy on `box_scans` keyed to a session `id_enterprise` GUC can be added without changing the app model (0017's "revisit if customers ever get direct SQL access"). Recommend deferring until an auditor asks.

**Why Part 11 forces this now.** Bispharma is the business case, and **21 CFR Part 11 §11.10(g)/(d)** requires records be **attributable and access-limited to authorized individuals**. `id_user` from a verified per-person JWT gives attribution; server-derived `id_enterprise` gives the access boundary. A shared key gives neither. The write-fence stops being a P13 backlog item and becomes a *go-live gate* the moment a pharma tenant is in scope — which is the strongest possible argument for building it right on this path first (it de-risks the whole P13-write program with a concrete regulated customer as the proof).

### 2.5 Durability — never lose a box (ADR-0011)

A scanned box is **right of the durability boundary** the instant the operator's device captures it — losing it is our bug (ADR-0011 Rule 0). The full ADR-0011 chain applies to the scan path:

- **SPA IndexedDB outbox.** The SPA writes the scan to a local IndexedDB outbox **before** anything else, then drains it to `POST /scans`. A dropped network, a killed tab, a dead battery mid-shift → the scan survives on the device and drains when connectivity returns. This is the browser-side analogue of edge-transformer's SQLite outbox (ADR-0011 Phase 3).
- **Client `scan_uuid` → idempotent ingest.** Each scan is minted with a client `scan_uuid`; ingest is `INSERT ... ON CONFLICT (scan_uuid) DO NOTHING`. A re-drained outbox (the classic "did my POST commit before the tab died?" ambiguity) is a **safe no-op**, not a duplicate box. This is ADR-0011 Rule 2 (idempotent consumer, business-key dedup) with `scan_uuid` as the key.
- **Publisher confirms.** `barcode-service`'s RabbitMQ emit uses publisher confirms (ADR-0011 Rule 1) — no silent broker-side loss.
- **Preserve the contemporaneous timestamp.** `ts_value` = **when the operator scanned** (captured on the device, carried through the outbox), *not* `now()` at ingest. `ingested_at` separately records arrival. So a box scanned during a 3-hour outage and drained later keeps its *true* scan time in `ts_value` (the bitemporal split of §2.2 / ADR-0036 §5A) — essential for genealogy ("when was this unit actually produced") and for Part-11 record fidelity.

### 2.6 Medallion placement (ADR-0036)

| Layer | What | Where |
|---|---|---|
| **Bronze** | `box_scans` — immutable, append-only, bitemporal, `source_seq` tiebreak | the fact table (§2.2), governed by ADR-0036 §3 |
| **Silver** | validation: `scan_type` coherence, serial format/checksum (pharma), in-range/expected, dedup, dimensional conform | `barcode-service` validation stage / Timescale validation views (ADR-0036 §4 contract) |
| **Gold** | `po_box_counter` (the served gapless counter) + `v_po_box_totals` (served totals) | §2.2 |

This is the medallion applied verbatim to a new fact stream: raw immutable Bronze, a named Silver invariant layer (serial well-formedness is a *conforming* rule, exactly Silver's job), thin Gold serving. It inherits ADR-0036's reprocessing payoff — if a Silver validation rule changes, replay it over the immutable `box_scans` Bronze.

### 2.7 Scans are a PARALLEL fact stream — not an OEE count

**The single most important domain ruling, and all three squads independently insisted on it:** box scans are **NOT** the OEE production count and must never be wired to become one.

- **Evidence it is already decoupled — keep it that way.** There are **zero** triggers or views linking `scanned_boxes` to `equipment_values`: `edge-node-red/db/08-triggers.sql` sums `equipment_values` into production totals but **never touches `scanned_boxes`**; the box-aggregation caggs (`22-agg-views.sql` `ca_equipment_boxes_1s/1hour`) read `equipment_values`, not the scan table. OEE counts come from **PLC totalizers** (the `edge-transformer` count Calc, `calc_production_counters/`); scans come from **humans with scanners**. They are two independent measurements of overlapping-but-not-identical reality (a scan can be a QC sample, a re-scan, a partial case; a totalizer tick is a machine cycle). **Fusing them would double-count and re-introduce exactly the two-writer disease** ADR-0037 (h) / the #456 line double-count post-mortem warns against.
- **The roles scans DO play:**
  - **P7 Traceability (primary).** `box_scans` is the genealogy substrate — the per-unit / per-lot as-built record. Recall-by-lot becomes a refdata query surface over this table (§4 P3).
  - **P6 Quality sampling.** `scan_type='sample'` is the QC-sample capture path (today's `sample_boxes`), feeding SPC (§7 feeds).
  - **A reconciliation cross-check — NOT a fusion.** `Σ scan production qty` vs `net_production` per PO is compared, and a *material divergence* raises a **`data_quality_event` of rule `SCAN_VS_NET_DRIFT`** (§2.8). This uses scans to *validate* OEE, and OEE to *validate* scans, **without either writing the other's numbers.** Drift means "operators scanned 900 boxes but the totalizer says 1000 units" → a real quality/traceability signal (missed scans, mis-configured units-per-box, or a miscounting PLC), surfaced, never silently reconciled.

### 2.8 DQ + andon hooks — the scanner is P11-B2's first live business signal

Extend the existing `data_quality_event` side-channel (`edge-node-red/db/34-data-quality-events.sql`, landed via the P11-B2 andon Tier-0 substrate, staging commit `e3fb1de`; refdata dataset `data-quality-events`) with a **`grain='scan'`** value and a **`context jsonb`** column (the current table has `grain TEXT`, `rule TEXT`, `observed_value DOUBLE PRECISION` but no structured context — scan events need to carry `id_production_order`, `label_seq`, `sgtin`, station, etc.):

```sql
ALTER TABLE data_quality_event ADD COLUMN context jsonb;  -- structured per-event detail
-- grain gains a 'scan' value; the dedup unique index already keys on grain, so
-- scan events dedup independently of shift/hour/day rollup events.
```

New scan-grain rules (each a `data_quality_event`, tenant-fenced on `id_enterprise`, feeding the P11 andon dashboard):

| Rule | Trips when | Andon meaning |
|---|---|---|
| `SCAN_RATE_DROP` | scan/min for an active PO falls below expected | line stalled / operator away / scanner jammed |
| `SCAN_SEQUENCE_GAP` | a hole appears in the (post-void) `label_seq` run | a box went unscanned — traceability hole |
| `PRINTER_OFFLINE` | label printer heartbeat lost (pharma serialization) | can't serialize → line must stop |
| `DUPLICATE_SERIAL` | a `sgtin` re-appears (VALIDATE mode) | cloned/re-used serial — a compliance event |
| `SERIAL_OUT_OF_RANGE` | presented serial outside the PO's allocated range | wrong product / rogue label |
| `SCAN_VS_NET_DRIFT` | Σ scan qty vs `net_production` diverges beyond tolerance (§2.7) | miscount somewhere — reconcile |

This makes **the scanner the first *live business-signal* source for P11-B2 andon** — until now the andon substrate has only the *rollup*-detected OEE-correctness rules (`OEE_GT_1` etc., ADR-0037 §4A). Scan events are operator-facing, real-time, and actionable on the floor — the canonical MES andon signal (ADR-0038 B2).

---

## 3. What gets retired

| Retired | Replaced by | Gate |
|---|---|---|
| `barcode-scanner-v1` (React + Hasura subscription + Firebase + `x-api-key:'12345'`) | consolidated v2 SPA + `barcode-service` | v2 SPA at read-parity with v1's operator views |
| `barcode-scanner-v2` as a *separate* app | folded into the one consolidated SPA | — |
| `scanned_boxes` + `sample_boxes` (two tables, sentinel-typed) | `box_scans` (one immutable Bronze fact, `scan_type` enum) | dual-write + shadow-diff parity (§4 P0) |
| v1's Hasura GraphQL **subscription** | **SSE** from `barcode-service`; MVP = poll a refdata dataset | SSE/poll delivers the same live updates |
| 5 Hasura **views** (incl. the per-tenant fork `v_get_current_job_infos_client4_119`) | config-driven **refdata datasets** | read-parity per view |
| shared-key write auth (`x-api-key:'12345'`) | server-derived `id_enterprise`/`id_user` from JWT | write-fence verified; Part-11 attribution provable |

**On SSE replacing the Hasura subscription — this is cheap, not risky.** v1's "live" subscription **already silently degraded to a ~55-second poll** — the front4 dashboard family runs its refresh on a single 55 000 ms clock (`front4/src/lib/dashboard/hooks/pollContext.js:11`, `PollIntervalContext = createContext(55000)`), and the GraphQL subscription plumbing (`front4/src/services/graphqlConnection.js`) is the degraded-refresh path, not a true live push. So operators are *already* on a poll cadence; SSE is a strict upgrade (true server-push when connected) and the **MVP fallback is just "poll a refdata dataset,"** which matches today's behavior exactly. We are replacing a subscription that isn't really subscribing.

**Re-homing the 5 Hasura views removes the last Hasura *writer/live-consumer* for this surface** → directly unblocks ADR-0026 step 3 ("stop serving Hasura"). Note the per-tenant fork `v_get_current_job_infos_client4_119` — a **client-119-specific SQL view** — is the exact "per-customer fork instead of config" anti-pattern ADR-0038 principle 2 forbids; it becomes **one config-driven refdata dataset with a tenant parameter**, not a forked view. (These 5 views live in the barcode-scanner-v1 repo / Hasura metadata, outside this monorepo checkout; the consolidation inventories and ports them at P0.)

---

## 4. Phased roadmap

Ordered **foundation-of-this-capability first**, then value, matching ADR-0038's "consolidate before you extend" discipline. Each phase is independently valuable and reversible; nothing here ships prod without its own gate.

### P0 — Consolidation (the un-sexy load-bearing phase)
- Stand up **`barcode-service`** (Go) in `services/`: JWT→`id_enterprise` fence, ASSIGN/VALIDATE sequence authority, idempotent `scan_uuid` ingest, publisher confirms, SSE.
- Create **`box_scans`** (Bronze, immutable) + `po_box_counter` + `v_po_box_totals`; **dual-write** from the current write path and **shadow-diff** against `scanned_boxes`/`sample_boxes` (the byte/count-parity discipline the stack uses everywhere — cf. ADR-0032 F1/F2/F3).
- Consolidate the SPA on v2; point it at `barcode-service`; add the IndexedDB outbox.
- Replace the Hasura subscription with SSE (poll-a-refdata-dataset MVP); port the 5 views → refdata datasets.
- **Kill `x-api-key:'12345'`** on the scan path.
- **Exit criterion:** one service, one SPA, one immutable fact table at parity, no shared-key writes, no Hasura dependency for scans. This is the whole "consolidate v1+v2, retire both" decision, shipped.

### P1 — Quality / B1 (north-star B1 on the scan path)
- `scan_type='sample'` becomes first-class QC capture; wire **defect classification** onto the sample path (defect codes per equipment, mirroring the downtime-reason seed pattern `13-downtime-reasons-seed.sql`).
- Feed the **P6 SPC** surface: defect Pareto, first-pass-yield, p-chart (ADR-0038 B1).
- Turn on **`SCAN_RATE_DROP` / `SCAN_SEQUENCE_GAP` / `SCAN_VS_NET_DRIFT`** DQ rules (§2.8) → first live andon signals (B2).
- Feed the **P3 OEE Quality factor** correctly: scans = Total, defects → FPY, **single-writer-per-count-row**, invariant `0 ≤ good ≤ total` (ADR-0037 (e) invariants applied to the quality count).

### P2 — Serialization + Part 11 / P7 (the pharma entry ticket)
- **VALIDATE mode** + serialization: SGTIN (GTIN + serial + lot + expiry) capture, the `gs1-datamatrix` parser, serial-range allocation per PO.
- **21 CFR Part 11**: e-signature + audit-trail **WORM** tables (append-only, same immutability trigger pattern as `box_scans` §2.2.1); `id_user` attribution end-to-end.
- **`PRINTER_OFFLINE` / `DUPLICATE_SERIAL` / `SERIAL_OUT_OF_RANGE`** DQ rules.
- P7 genealogy foundation: per-unit as-built record on `box_scans`.

### P3 — Pharma track-and-trace (full P7)
- **Aggregation**: unit → case → pallet (SSCC), an **acyclic, one-active-parent** containment graph (event-sourced status lifecycle).
- **EPCIS event ledger** (WORM) — the industry-standard commission/pack/ship event model.
- **EU-FMD / US-DSCSA reporting** surfaces.
- **Recall-by-lot as a refdata query surface** over `box_scans` genealogy (ADR-0038 B3 "recall/audit backbone").

---

## 5. Consequences

**Positive**
- **P7 goes MISSING→real and P6 THIN→system** on a single coherent data path, exactly the north-star Phase-B B1/B3 charters.
- **The sentinel dies.** `scan_type` makes the *kind* of a scan explicit and type-safe; no more `!= 0` filters scattered across consumers.
- **Gaplessness is a DB invariant**, provable and race-safe, instead of a client toast — no more mid-shift 500s from concurrent scanners.
- **The write-fence is proven on a regulated customer.** Building server-derived tenancy here de-risks the whole P13-write program (ADR-0034) with Part-11 as an unforgiving test.
- **A Hasura writer/live-consumer is removed** → ADR-0026 step 3 gets closer; a per-tenant forked view becomes config.
- **No box is ever lost** (ADR-0011 outbox + idempotent ingest), and every scan keeps its true contemporaneous timestamp.
- **Immutable, audited history for free** — the append-only + void-correction model is simultaneously the Bronze contract *and* the Part-11 audit trail. One design satisfies both.
- **CPACK/Incoplast are untouched in spirit** — they run the same service with the pharma tier OFF (§6), so consolidation doesn't tax the OEE-first customers.

**Negative / risks**
- **New service + new fact table + dual-write window.** P0 is real engineering with a migration seam; mitigated by shadow-diff parity before cutover (the stack's standard discipline) and by Bronze being additive (Gold path for OEE is entirely untouched — §2.7).
- **SSE fan-out is new operational surface** (connection management, back-pressure). Mitigated: the MVP is *poll a refdata dataset* — SSE is the enhancement, not a hard dependency, and today's behavior is already a poll.
- **Advisory-lock contention per PO** if a single PO ever has extreme concurrent scan rates. Bounded by human scan speed and per-PO (not global) locking; if a PO ever needs >1 assigner, that's a design conversation, not a silent failure.
- **Pharma tier is a large P2/P3 body of work** (serialization, EPCIS, WORM, regulatory reporting) — but it is **gated behind a config flag and behind a real customer**, so it is built when Bispharma commits, not speculatively.
- **Numbers users have seen may shift** if the reconciliation surfaces long-standing scan/net drift; roll out the DQ rules per-tenant with comms (same caution as ADR-0037 §6).

**Neutral**
- Matches industry norms: append-a-void-not-mutate is standard ledger practice; server-owned gapless numbering via advisory locks is textbook Postgres; GS1/SGTIN/SSCC/EPCIS and Part-11 WORM audit trails are the pharma serialization standards (EU-FMD, US-DSCSA). We are joining the standard, not inventing it.

---

## 6. The pharma-tier config model — a switch, not a fork

The pharma capability is **config-driven, not a per-customer fork** (ADR-0038 principle 2). One `barcode-service`, one SPA, one `box_scans` table; a per-tenant config document turns the pharma machinery on or off. **CPACK and Incoplast run the identical service with every pharma feature OFF; Bispharma runs it with them ON.** The switch is not a branch.

```yaml
# per-tenant barcode config (illustrative; lives with the client config, docs/clients/)
barcode:
  parser: packiot-counter        # packiot-counter (ASSIGN, mint a seq)  |  gs1-datamatrix (VALIDATE, read SGTIN)
  sequence_mode: ASSIGN          # ASSIGN | VALIDATE
  serialization:
    enabled: false               # SGTIN (GTIN + serial + lot + expiry)         — pharma only
  aggregation:
    enabled: false               # unit → case → pallet (SSCC), acyclic, one-active-parent
  epcis:
    enabled: false               # EPCIS event ledger (WORM commission/pack/ship)
  part11:
    enabled: false               # 21 CFR Part 11 audit-trail + e-signature (WORM tables)
  reporting:
    fmd: false                   # EU Falsified Medicines Directive
    dscsa: false                 # US Drug Supply Chain Security Act
```

| Capability | CPACK / Incoplast | Bispharma |
|---|---|---|
| parser | `packiot-counter` (ASSIGN) | `gs1-datamatrix` (VALIDATE) |
| serialization (SGTIN) | off | on |
| aggregation (SSCC) | off | on |
| EPCIS ledger (WORM) | off | on |
| Part-11 audit + e-sig | off | on |
| FMD / DSCSA reporting | off | on |

The **acyclic, one-active-parent** rule on aggregation is a domain invariant: a unit belongs to at most one active case, a case to at most one active pallet, no cycles — the containment graph is a forest, and disaggregation (un-packing) is an event that ends a parent link, not a mutation. The **status lifecycle is event-sourced** (commission → pack → ship → decommission), and the **EPCIS + Part-11 tables are WORM** (the same append-only trigger pattern as `box_scans` §2.2.1).

---

## 7. Feeds — where the scan stream plugs into the pillars

| Pillar | What `box_scans` feeds | Invariant / note |
|---|---|---|
| **P3 OEE / Quality factor** | scans = Total, defects → FPY | **single-writer-per-count-row**, `0 ≤ good ≤ total` (ADR-0037 (e)); scans **validate**, never **write**, OEE (§2.7) |
| **P11 Andon** | `SCAN_RATE_DROP`, `SEQUENCE_GAP`, `PRINTER_OFFLINE`, `DUPLICATE_SERIAL`, `SCAN_VS_NET_DRIFT` | first live *business* signal source (§2.8); tenant-fenced DQ events |
| **P6 SPC** | defect Pareto, FPY, p-chart | quality *system*, not counts (ADR-0038 B1) |
| **P7 Genealogy** | per-unit / per-lot as-built record | recall-by-lot = a refdata query surface (§4 P3) |

---

## 8. Open question — a scheduling call, not an architecture one

**Bispharma's go-live timing may pull P2 (serialization + Part 11) ahead of P1 (Quality/SPC).** The roadmap orders P1 before P2 because Quality/SPC has the higher value-per-effort for the *existing* OEE-first customer base (matching ADR-0038's B1-before-B3 rationale). But if Bispharma commits with a near-term go-live, the **pharma entry ticket (P2: VALIDATE mode, SGTIN, Part-11 attribution)** becomes the priority, because it is a *regulated go-live gate*, not a value-add.

**This is a sequencing decision for the product owner, not an architectural one** — the architecture is identical either way. P0 (consolidation) is a hard prerequisite for both and comes first regardless; the pharma tier is config-gated (§6) so building P2 early does not disturb CPACK/Incoplast; and the write-fence (§2.4) is shared foundation that both P1 and P2 sit on. Whichever of P1/P2 goes second loses nothing by waiting. **Recommendation:** hold the P1-before-P2 default; let a signed Bispharma go-live date (and only that) flip it — and if it flips, P0 still ships first.

---

## 9. Cross-reference handoffs

| ADR | Handoff |
|---|---|
| [0038](0038-north-star-factory-platform.md) | This ADR executes **B1 (Quality/SPC)** and **B3 (Traceability/Genealogy)** on the scan path, and seeds **B2 (Andon)** its first business signal. P7 MISSING→real; P6 THIN→system. |
| [0036](0036-data-architecture-medallion.md) | `box_scans` is a **Bronze** fact under 0036's append-only + `ingested_at`/`source_seq`/temporal (T0-2) contract (§3, §5A); validation is Silver; totals are Gold. New fact stream, same medallion. |
| [0037](0037-oee-correctness-remediation.md) | Extends the `data_quality_event` side-channel with **`grain='scan'` + `context jsonb`**; applies the (e) invariant (`0 ≤ good ≤ total`, single-writer) to the quality count. |
| [0026](0026-api-layer-consolidation.md) | Re-homes the 5 Hasura views → refdata datasets and replaces the subscription with SSE → **removes the last Hasura writer/live-consumer for scans** (unblocks step 3). Reads via refdata, writes via `barcode-service`/edge-api — CQRS honored. |
| [0034](0034-adopt-cognito-amplify-auth.md) | The scan write path is the **first regulated instance** of the server-derived-tenant write-fence; Part-11 attribution is its acceptance test. |
| [0011](0011-durability-boundary-and-store-and-forward.md) | SPA IndexedDB outbox + `scan_uuid` idempotent ingest + publisher confirms = the destination-side completion of the durability boundary for human-captured facts; contemporaneous `ts_value` preserved. |
| [0039](0039-entity-lifecycle-deletion-strategy.md) | `box_scans` is the **fact**-side counterpart to 0039's **dimension**-side temporal/one-delete contract — append-only, corrections-by-void, never mutate. Same principle, split by table role. |
| [0017](0017-endgame-process-separation-and-enterprise-hardening.md) | Follows the **RLS-rejected / app-layer-isolation-primary** ruling (0017:88-90); RLS on `box_scans` is optional defence-in-depth only. |
| [0023](0023-concurrent-po-across-lines.md) | The two-operators-same-PO concurrency the sequence authority must survive is the same concurrent-PO reality 0023 models for OEE. |

---

## 10. The one-sentence thesis

**Two barcode scanners, a mutable sentinel-typed fact table, client-side gaplessness, and a shared api-key are four symptoms of one absence — a real traceability/quality *service* — and this ADR builds it: one Go `barcode-service`, one immutable `box_scans` Bronze fact, server-owned gapless numbering, a token-derived write-fence, and a config-switched pharma tier, all plugged into the medallion and the pillars the north-star already named.**
