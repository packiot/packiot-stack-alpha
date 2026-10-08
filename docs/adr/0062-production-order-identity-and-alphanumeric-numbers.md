# ADR-0062 — Production-order identity: a text client number, one internal key, a UUIDv7 handle

**Status:** Proposed · **Date:** 2026-10-07 · **Decision owner:** user
**Trigger (user, 2026-10-07):** "the po id number that shows for the client is alphanumeric … the alphanumeric is for
the whole stack. it needs to accept that." Decisions taken so far: the client number is text everywhere; when the stack
itself must invent a number it uses a UUID; the client number is unique per enterprise; the legacy duplicate is fixed
(below). The identity model was to be **proven against the state of the art** — this document is that proof.

---

## 1. Context — what is stored today (staging, measured 2026-10-07)

`core.production_orders` (62,699 rows) has three identifiers:

| Column | Type | Role today |
|---|---|---|
| `id_production_order` | bigint, PK | internal key; FK target of every runtime/event/sample/box/rollup row |
| `id_order` | **integer** NOT NULL, `UNIQUE (id_enterprise, id_order)` | "the PO number" in every API, report, PLC payload |
| `id_order_text` | varchar(255), nullable | the client's real number — written only by CSV import and pocontrol |

The integer **already loses client numbers** (CPACK, legacy-replicated):

| PO | `id_order` | client number (`id_order_text`) | loss |
|---|---|---|---|
| 100802707 | 834 | `834.058` | decimal truncated |
| 100857023 | 8396260 | `08396260` | leading zero dropped |
| 101037673 | 856411 | `856207` | different number |
| 101585550 | 889583 | `889185` | text collides with PO 101574989 |

34,755 POs have no `id_order_text`; 4 are already alphanumeric; 2 rows have `id_order = 0` (CSV import maps any
digits-only value > 2³¹ to 0, so they overwrite each other on `ON CONFLICT`). Every write path rejects an alphanumeric
number (edge-api DTOs → 22P02 on the int column; stream-engine 30805 `json.Number.Int64()`; operator-gateway `*int`;
operator `type="number"` + `Number()`; CSV integer regex). Full inventory: §6.

## 2. Options

1. **Client number = text business key, UNIQUE per enterprise; internal identity = the existing bigint PK; add a
   `po_uuid` (UUIDv7) handle** for ids minted outside the DB (offline boxes, cross-environment); retire the integer.
2. **Repurpose `id_order` as a UUID handle**; client number only in `id_order_text`; PK stays bigint.
3. **Replace the bigint PK with a UUID PK** everywhere now.

## 3. Evidence

### 3.1 Standards — a production order's number is a string issued by someone else
- ISA-95 / B2MML: every ID is `IdentifierType` = `xsd:normalizedString` with `schemeAgencyID` (ERP, MES … issue them).
  [B2MML-CoreComponents.xsd](https://raw.githubusercontent.com/MESAInternational/B2MML-BatchML/master/Schema/B2MML-CoreComponents.xsd)
- OPC UA for ISA-95 Job Control (OPC 10031-4): `JobOrderID` is a **String**.
  [reference.opcfoundation.org](https://reference.opcfoundation.org/specs/OPC-10031-4/6.2.1.12)
- SAP `AUFNR` is CHAR(12); external number ranges may be alphanumeric; numerics are zero-padded (ALPHA) — exactly
  why `08396260` must stay text. SAP is the *issuing* system: for us its number is a foreign business key.
  [sapstack AUFNR](https://sapstack.com/tables/dataelements.php?field=AUFNR)
- DDD (Vernon, *Implementing DDD* ch. 5): "Another Bounded Context Assigns Identity" — the ERP assigns the PO number;
  the receiving system keeps its own identity.

### 3.2 Keys — the business key needs a UNIQUE constraint; meaningful values make poor PKs
- Fowler, *PoEAA* Identity Field: prefer meaningless keys; meaningful ones may be neither immutable nor unique — our
  data shows both (renumbered `856411`→`856207`; reused `889185`).
- Cybertec argues the opposite PK choice, but **both camps agree** the real-world key must carry its own UNIQUE
  constraint. [Cybertec](https://www.cybertec-postgresql.com/en/data-normalization-in-postgresql/)

### 3.3 Mature APIs — opaque id + separate human number, never the number in an `id_*` field
Stripe invoice `id` (`in_…`) vs `number` ("appears on emails sent to the customer")
([docs](https://docs.stripe.com/api/invoices/object)); Shopify order `id` (GID) vs `name` `#1001`
([docs](https://shopify.dev/docs/api/admin-graphql/latest/objects/Order)); GitHub numeric `id` + `node_id`.
This is option 1's shape exactly.

### 3.4 UUID keys in Postgres — measured here and published
Our benchmark (dev seed container, PG 15, 2 M parents / 8 M children, warm cache):

| | bigint | UUIDv4 | UUIDv7 |
|---|---|---|---|
| PK index | 42 MB | 75 MB (1.8×) | 60 MB (1.4×) |
| FK index, 8 M rows | 93 MB | 111 MB | 111 MB |
| WAL for 200 k inserts into a large index | 26 MB | **86 MB (3.3×)** | 30 MB |
| join 20 k POs → children | 27 ms | 42 ms | 26 ms |

Published: RFC 9562 §2.1/§5.7 — v4 has poor index locality, implementations SHOULD use v7
([RFC 9562](https://www.rfc-editor.org/rfc/rfc9562.html)); Cybertec 10 M rows: v4 index-only scan 1,214 ms vs
bigint 526 ms vs v7 541 ms ([Cybertec](https://www.cybertec-postgresql.com/en/unexpected-downsides-of-uuid-keys-in-postgresql/));
Vondra: random UUIDs > 20 GB WAL vs ~2.5 GB time-ordered ([EDB](https://www.enterprisedb.com/blog/sequential-uuid-generators));
Atkinson recommends bigint PK + external UUID ([blog](https://andyatkinson.com/avoid-uuid-version-4-primary-keys));
Buildkite ran exactly option 1 (sequential PK + UUID secondary) before moving to UUIDv7 PKs
([Buildkite](https://buildkite.com/resources/blog/goodbye-integers-hello-uuids/)).
**Conclusion:** a UUID handle must be **v7** (PG 15 has no `uuidv7()` — generate in the app or with a SQL function);
v4 is the expensive choice in a write-heavy store.

### 3.5 Blast radius in this system (dev seed, measured)
- `id_production_order` lives in **22 tables, 14 views, 20 functions**, incl. **2 hypertables and 5 continuous
  aggregates** (~2.56 M rows). Option 3 alters compressed hypertables (needs `decompress_chunk` — forbidden on the
  shared DB after the 2026-09-30 incident) and rebuilds 5 caggs from scratch.
- `id_order` lives in **27 DB objects** and **~1,000 code references** (edge-api 161, operator 40, front4 76,
  edge-node-red 708, superproject incl. migrations/docs). Option 2 changes the meaning of every one of them silently.
- Option 3's one real advantage is visible: the sandbox twin copies rows with fixed id offsets (+500,000,000 for POs,
  `t-sandbox-reflection`); a UUID PK removes that. Today's max CPACK PO id is 101.6 M — no collision pressure.

### 3.6 Schema evolution
Google AIP-180: APIs "must not change visible behavior or semantics"; fields "must not have their type changed, even
if … wire-compatible" ([AIP-180](https://google.aip.dev/180)). Fowler ParallelChange: expand → migrate → contract
([bliki](https://martinfowler.com/bliki/ParallelChange.html)). Option 2 violates the first rule outright.

## 4. Scored comparison (5 = best)

| Criterion | 1 | 2 | 3 |
|---|---|---|---|
| Semantic stability for consumers | 3 (4 with §5 D3a) | 1 | 3 |
| Correctness of client numbers (text, unique) | 5 | 4 | 4 |
| Offline / edge minting | 4 | 4 | 5 |
| Cross-environment merge (twin) | 4 | 4 | 5 |
| Migration cost / risk | 4 | 2 | 1 |
| Query performance | 5 | 4 | 3 |
| Alignment with standards & major APIs | 5 | 2 | 3 |

**Option 1 wins**; option 3 wins only on edge/merge, which option 1's `po_uuid` covers for ids minted off-DB, and
which remains available as a later phase (Buildkite's path). Option 2 is dominated.

## 5. Decisions

- **D1 Client number.** `id_order_text` becomes the authoritative client PO number: text, stored **as given** (trimmed
  only — never re-formatted: `08396260` ≠ `8396260`), NOT NULL, `UNIQUE (id_enterprise, id_order_text)`.
- **D2 Internal identity.** `id_production_order` (bigint) stays the PK and the only join key. The integer `id_order`
  is retired: kept and filled during the transition, never read for meaning, dropped in the contract phase.
- **D3 Contracts.** The user chose (2026-10-07) "switch `id_order` to text". AIP-180 classes a type change as breaking
  even with the same meaning. **D3a (recommended refinement, needs confirmation):** add `order_number` (string) to every
  API/report/PLC contract now, keep `id_order` until clients move, then contract. **D3b (as chosen):** change `id_order`
  to the string number in place, coordinated per integration client.
- **D4 Handle.** `po_uuid uuid NOT NULL DEFAULT <uuidv7> UNIQUE` — for ids minted outside the DB (offline operator
  writes, edge boxes, cross-environment). A number the stack must invent (auto-created POs) = this UUID's text.
- **D5 Legacy duplicate.** PO 101585550 (and its twin 601585550): client number `889185` → `889583` (its own integer;
  the text is the legacy error). The legacy replicator applies the same correction.
- **D6 Uniqueness scope** is per enterprise. If one enterprise ever has several issuing systems with overlapping
  ranges, the key becomes `(id_enterprise, source, number)` — not needed today.

## 6. Plan (expand → migrate → contract)

1. **DB expand:** backfill `id_order_text` (`coalesce(trim(text), id_order::text)`), fix D5, fix the CSV `ELSE 0`
   rows, add `po_uuid` (v7), make `id_order_text` NOT NULL + UNIQUE; a trigger keeps `id_order` filled for old writers
   (numeric number → that integer, else a fresh value from a negative sequence so the old int key never collides).
2. **Writers to text:** edge-api DTOs/DAOs/CSV, stream-engine pocontrol (30805 + lifecycle by text), operator-gateway,
   operator SPA inputs, edge-node-red.
3. **Readers + contracts (D3a/D3b):** read-api (incl. Incoplast/Montebello/job_report/sync06), front4, serving
   functions; integer copies (box tables, validation shift, sync06, downtime functions) join on `id_production_order`.
4. **Contract:** drop the integer key/column after every writer and reader moved.
