# Barcode / scanned_boxes subsystem — new-stack redesign (DESIGN ONLY)

**Task:** #229 · **Status:** design-only, no DDL / no deploy · **Author:** Claude (Opus) as drafting partner
**Scope:** the operator-facing barcode-scanner *edge application* (physical scanner + label printer)
and the `scanned_boxes` data subsystem it feeds.
**Sibling docs:** `docs/plans/analytics-clean-schema-redesign.md` (§ "Box model → KEEP BOTH", line ~260),
`docs/plans/medallion-schema-separation.md` (#228, box placement).
**Evidence base:** repos `barcode-scanner-v1`, `barcode-scanner-v2`, `services/barcode-service`,
`edge-api`; live read-only probe of `packiot_analytics@10.10.10.89` (staging) 2026-09-08.

---

## STATUS UPDATE — 2026-09-08 (#230 BACKEND LANDED)

The **backend half of §6.3 is BUILT, hardproofed, and deployed to staging** — edge-api PR
[#248](https://github.com/packiot/edge-api/pull/248), branch `feat/230-scanned-boxes-ingest`.
Decision gate #1 (§9.1) resolved: **fold into edge-api** (not revive barcode-service).

**Delivered (this round — backend only):**
- New vertical slice `edge-api/src/usecases/scanned-boxes/` (`record-scan` + `list-scanned-boxes`)
  + DAO `src/data/DAO/scanned-boxes/`. **`POST /api/scanned-boxes`** (gapless `label_seq` under
  `pg_advisory_xact_lock`, `scan_uuid` idempotency, in-tx tenant fence) + **`GET /api/scanned-boxes`**
  (per-PO totals + recent rows, tenant-fenced). Writes the clean `box_scans` + `po_box_counter` Bronze
  model (in `public` for now; #228 medallion move relocates to `bronze` later).
- `applyScan` ported verbatim-in-spirit from `services/barcode-service` (pure fn over a `ScanTx` seam,
  unit-tested with no DB). `services/barcode-service` is now marked **SUPERSEDED** (its README) — kept
  as the logic reference, NOT deleted, NOT wired to any client.
- **Hardproof:** 10 unit tests green + live staging: gapless 1/2/3, idempotent replay (200, no dup),
  403 cross-tenant write, empty cross-tenant read, **25 concurrent → dense 1..25, gap_count 0**. Legacy
  `scanned_boxes`/`sample_boxes`/`/api/labels`/`/api/samples` UNTOUCHED and still 200.

**DEFERRED to a client follow-on (NOT done this round):**
1. **Revive barcode-scanner-v2** — repoint its dead `POST /api/labels` → `POST /api/scanned-boxes`
   (x-api-key), drop the direct-Hasura mutations (v1), move the client-side gapless check to
   advisory-only (server is now authoritative; surface the 409 correction).
2. **Offline scan-queue** — IndexedDB keyed by `scanUuid` + cached PO metadata, replay-on-reconnect
   (§2.5). Package the scanner app into the on-prem edge bundle (sibling of operator-edge).
3. **Retire barcode-scanner-v1** (Hasura-direct) after v2 is cut over.
4. The **7 open decisions** in §9 still need the user: sample-quota home (§9.2 — `box_scans
   scan_type='sample'` vs a `po_sample_quota` table), box-count-authoritative-for-Quality (§9.3),
   offline host box (§9.4), label-template-as-data (§9.5), printer protocol (§9.6), edge-app auth /
   real api_key vs the `'12345'` placeholder (§9.7).
5. **Cutover** — bump the stack edge-api submodule pin to land the endpoint via the normal pipeline
   (staging currently runs the branch image via a box-side rebuild for the proof); then migrate the
   sample path (`create-sample`/`edit-sample`) to `box_scans scan_type='sample'`, and after a
   zero-write watch window drop legacy `scanned_boxes`/`sample_boxes` (§8).

---

## 0. TL;DR — the recommendation

1. **The barcode app is an operator-facing EDGE application, not a cloud service.** It drives a
   physical **keyboard-wedge barcode scanner** and a **label printer** at the packing station. It
   must keep printing/scanning **during a cloud outage** (you cannot stop a packing line because the
   internet dropped). It therefore *stays* an edge app, deployed near the hardware — a sibling of the
   operator-edge app (ADR-0052/0054), not a pure SPA that dies when the cloud is unreachable.

2. **Its backend calls should go through edge-api** (the user's lean, and the recommended "proper
   architecture"). A box scan is semantically "just another factory event" exactly like a downtime or
   a PO start — low-volume, human-paced, needing a synchronous ack, a lookup response (current PO /
   label metadata), and a tenant fence. That is precisely edge-api's request model, and edge-node-red
   *already* calls edge-api for PO control + downtimes. This keeps one control-plane, one auth model
   (API-key), one audit trail (`res.locals.logData`). **RabbitMQ/ingest-shim is the wrong tool here**
   (that path is for high-volume fire-and-forget telemetry with no response); **direct DB write
   (today's V1→Hasura and barcode-service→box_scans) is the anti-pattern we move away from.**

3. **On the data model, promote the barcode-service's `box_scans` Bronze design and retire the legacy
   `scanned_boxes`/`sample_boxes` pair** — but flip the write path: instead of the barcode-service
   owning the durable write directly against the DB, fold the gapless-sequence logic into an **edge-api
   `scanned-boxes` usecase + DAO**, and let `box_scans` be the Bronze table edge-api writes. The
   per-PO aggregate (`v_po_box_totals` / a Gold `oee_box_count` grain) is the served count.

4. **This is a client-specific feature.** The physical scanner + printer + label template are
   **bispharma / bisnago** (aluminum-tube packaging — *"Bisnaga de Alumínio"*). No other tenant uses
   it. Any change is fenced to those tenants; the redesign must not break their line.

---

## 1. Current-state map

```
                            ┌─────────────────────────────────────────────┐
   PHYSICAL LAYER           │  packing station (bispharma / bisnago floor) │
   (factory floor)          │                                             │
   keyboard-wedge scanner ──┼─▶ [ barcode-scanner SPA in a browser ]       │
   label printer         ◀──┼── window.print()  (HTML/CSS label + CODE128) │
                            └──────────────┬──────────────────────────────┘
                                           │ network to cloud
        ┌──────────────────────────────────┼───────────────────────────────────────┐
        │ PATH A (v1, legacy)               │ PATH B (v2, current)                   │
        ▼                                    ▼                                        │
   Apollo GraphQL (Firebase JWT)        axios REST  x-api-key: '12345'                │
        │                                    │  GET  /api/labels/order/:id            │
   Hasura  insert_scanned_boxes         GET  /api/production-orders/current           │
           insert_sample_boxes          GET  /api/lines                               │
        │  (DIRECT DB WRITE)            POST /api/labels   ← ⚠ NO BACKEND HANDLER      │
        ▼                                    ▼                                        │
   ┌──────────────────────────────────────────────────────────────────┐            │
   │  packiot_analytics.public  (staging)                               │            │
   │    scanned_boxes   (legacy, 11 cols, id+id_box drift, 0 rows stg)  │◀── edge-api │
   │    sample_boxes    (legacy companion, 11 cols, 0 rows stg)         │    samples  │
   └──────────────────────────────────────────────────────────────────┘   create/edit
                                                                                     │
   PATH C (new stack, built but ORPHANED)                                            │
   scan.staging.packiot.app/v1/scans  (Bearer JWT, Cognito) ─▶ barcode-service (Go) ─┘
        │  gapless per-PO label_seq under pg_advisory_xact_lock
        ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  packiot_analytics.public  (staging)                               │
   │    box_scans        (Bronze, append-only, 19 cols, 0 rows stg)     │
   │    po_box_counter   (per-PO high-water mark, 0 rows)               │
   │    v_po_box_totals  (per-PO totals VIEW)                           │
   └──────────────────────────────────────────────────────────────────┘

   READERS today:  edge-api GET /api/labels (list-labels) → scanned_boxes
                   v1 SPA directly via Hasura → v_scanned_boxes + scanned_boxes_aggregate
                   OEE engine / oeecloud / read-api / reports / Superset → NONE (proven §4)
```

**Three write paths, two table models, two clients, zero OEE consumers.** The subsystem is a
tangle of half-migrations: V1 writes the legacy table directly through Hasura; V2 was rebuilt to call
edge-api but **its write endpoint was never built** (`POST /api/labels` 404s today — only the `GET`
list controller exists); and the new-stack `barcode-service` writes a *different, better* table
(`box_scans`) that **no client calls** and that holds **0 rows**.

---

## 2. The client/edge half — physical scanner + label printing

This is the load-bearing correction: the barcode app is **not** a scan recorder, it is an
**operator-facing edge application with hardware I/O**, in the same family as the operator-edge app.

### 2.1 Physical scanner integration — keyboard-wedge (HID)

There is **no scanner SDK, no serial/USB-HID API, no driver code**. The scanner is a **USB
keyboard-wedge** device: the operator scans a code, the scanner "types" the decoded string into a
focused `<input>`, and a trailing **Enter** (configured as the scanner's suffix) triggers submit.

Evidence — `barcode-scanner-v2/src/components/barcode-scanner-panel.tsx`:
- `handleBarcodeKeyPress` fires `handleBarcodeConfirm()` on `e.key === "Enter"` (the wedge suffix).
- `parseBarcode` splits the typed string on `;` **or** `ç`/`Ç` into exactly 3 parts:
  `order ; number ; boxQty` (the `ç` alt-separator is a Brazilian-keyboard / scanner-config artifact).

Implication: the "scanner integration" is entirely a **focused text input + Enter**. It works in any
browser. The hardware is opaque to the app — which is good for portability but means the app inherits
whatever the OS/printer stack provides. No hardware code to port.

### 2.2 Label printing — browser `window.print()` + client-rendered barcode

Printing is **not** ZPL/EPL/printer-protocol. It is **browser print of an HTML/CSS label**:

- `barcode-scanner-v2/src/components/tag.tsx` — the label **template** is a React component
  (`<Tag>`), hardcoded to **BISPHARMA** ("BISPHARMA EMBALAGENS LTDA", *"Bisnaga de Alumínio"*, logo
  `logo-bispharma-peb.png`, all Portuguese). Fields printed: box Nº (or "EC"/"Amostra" for sample),
  client, tube size (diameter × length), due date, product, Cód Prod, Cód Esp, Nº Pedido, OP, Qtde/Cx,
  Line (`"L03"` hardcoded), Fab date, Hora, and the barcode.
- The barcode symbology is **CODE128** via `react-barcode` (`value={tagData.barcode}`,
  `displayValue`) — rendered client-side to SVG.
- `barcode-scanner-v2/src/print.css` — `@media print` reveals a hidden `#container`, `370px × 240px`,
  `transform: rotate(180deg)`, `@page { margin:0; orientation:landscape }` — sized for a **thermal
  label** and rotated for the printer's feed orientation. The physical printer is whatever the OS has
  bound to the browser print dialog (a label printer driver).
- Print **trigger**: `requestAnimationFrame(() => window.print())` after the label data is staged;
  payload cleared on the `afterprint` lifecycle event.

The **"number + 1" rule** (README §2.2): the *printed* label carries `number + 1` (the next box), while
the *scanned* barcode records the current box. The gapless sequence is enforced **client-side today**:
duplicate check + `parsedLabelNumber === lastNumber + 1` (else a "Sequência inválida" toast). This
fragile client-side gapless logic is exactly what `barcode-service`'s **server-authoritative**
sequence was designed to replace.

### 2.3 Label template & data source

The label mixes three data sources:
- **PO/product metadata** from the backend: `GET /api/labels/order/:orderId` and
  `GET /api/production-orders/current` return the current PO + a `custom_field` JSON parsed by
  `order-label.ts::normalizeLabelInfo` into `{ box_quantity, diameter, due_date, label_product_id,
  length, order_number, specification_id }`. So the label template is **data-driven from the PO's
  `custom_field`** plus fixed client chrome (logo, company name, layout).
- **The scanned barcode** (`order;number;boxQty`) — the operator's physical scan.
- **Client-fixed chrome** hardcoded in `tag.tsx` (bispharma branding, `"L03"` line).

### 2.4 Where it runs today, and where it SHOULD run

- **Today:** a browser SPA. V2's `api.ts` defaults `VITE_API_URL` to `http://localhost:8080` (edge-api's
  port) with `x-api-key: '12345'`. It is served/opened on a machine at the packing station that has the
  scanner + printer attached. **No offline capability** in V2 (pure axios-to-cloud; a cloud outage
  blocks order fetch and the `POST /api/labels`). V1 had *some* outage awareness — a `checkConnection`
  hook, a `NoConnection` component, and `localStorage('tags')` caching of `v_scanned_boxes`.
- **Should run (new stack):** an **edge-hosted operator app**, deployed near the hardware, a **sibling
  of operator-edge** (ADR-0052/0054). Because it touches physical devices (scanner + printer) it
  **cannot** be a pure cloud API; it must live where the hardware is. Concretely: package it into the
  on-prem edge bundle (compose.onprem-edge.yml), served from the box the operators use.

### 2.5 Offline capability (required)

A packing line must not stop when the cloud is down. The redesigned edge app needs, at minimum:
- **Print offline:** the label render + `window.print()` is already 100% client-side (react-barcode +
  print.css). It works with no network *as long as the PO/label metadata is cached* (the `custom_field`
  is small — cache the current PO on selection, like V1's `localStorage('tags')`).
- **Scan-queue offline:** buffer accepted scans locally (IndexedDB/localStorage) and **replay to the
  backend when connectivity returns**, keyed by the client-generated `scan_uuid` idempotency key so a
  replay never double-counts. This is the same store-and-forward discipline as ADR-0011's outbox and
  operator-edge's write-forward outbox (ADR-0054).
- **Gapless during outage:** offline, the client falls back to `validate`-mode sequencing against its
  local last-known `label_seq`; on reconnect the server re-asserts authority and returns a clean 409
  with `{expected, got}` if the client drifted (barcode-service already implements both modes).

---

## 3. The two data models (schema + warts)

### 3.1 Legacy `scanned_boxes` + `sample_boxes` (V1/edge-api world)

Live schema probed on staging `packiot_analytics.public` (2026-09-08):

`scanned_boxes` (0 rows on staging):

| column | type | note |
|---|---|---|
| `id` | bigint | **PK** (`nextval scanned_boxes_id_seq`) |
| `id_box` | bigint (nullable) | **⚠ DRIFT — a second id column** |
| `box_order_number` | integer | box sequence; `0` = the sample-companion row |
| `increment` | integer | units on the box (accumulates the count) |
| `id_enterprise / id_equipment / id_order / id_production_order / id_site / id_area` | integer | hierarchy (all nullable, **no NOT NULL, no FK**) |
| `ts_value` | timestamptz | scan wall-clock |

`sample_boxes` (0 rows): same shape but `id_box` PK, `should_increment` bool, and all id columns are
**`bigint`** (vs `scanned_boxes` `integer`) — a type-parity wart between the twin tables.

**Warts:**
- **`id` + `id_box` both present.** The knex "fix" migration (`20260413000002_fix_scanned_boxes.ts`)
  *renames* `id → id_box`, but `edge-node-red/db/10-missing-tables.sql` *creates* `scanned_boxes` with
  `id_box BIGSERIAL PRIMARY KEY`. The live table carries **both** — two migration lineages collided.
  A consumer doesn't know which is the key.
- **No tenancy backstop:** `id_enterprise` nullable, no NOT NULL, no FK. Tenant isolation is enforced
  only in edge-api's WHERE clause (`labels-dao.ts`) — nothing stops a bad direct write.
- **Redundant indexes:** `idx_scanned_boxes_equip` + `scanned_boxes_id_equipment_idx` (duplicate);
  `idx_scanned_boxes_po` + `scanned_boxes_id_production_order_idx` (duplicate). Two index-creation
  lineages, never reconciled.
- **Mutable, no immutability guard:** it's a plain table (not a hypertable), no append-only trigger.
  `edit-sample` does `UPDATE scanned_boxes SET increment=... WHERE box_order_number=0` — history is
  mutated in place.
- **Hasura-era coupling:** V1 writes it via GraphQL `insert_scanned_boxes` (direct DB write through
  Hasura), which is the exact pattern the new stack is retiring.
- **Overloaded `box_order_number=0`:** a magic value meaning "this row is the sample-count companion,
  not a real box" — the reason every read filters `box_order_number != 0`.

### 3.2 New Bronze `box_scans` + `po_box_counter` + `v_po_box_totals` (barcode-service)

Defined in `edge-node-red/db/36-box-scans.sql`; live on staging (0 rows). This is a **markedly better
design** — it's the target:

- `box_scans` (19 cols, `box_scan_id` identity PK): `id_enterprise NOT NULL` (tenant backstop),
  `scan_uuid UUID UNIQUE` (idempotency), partial-unique `(id_production_order, label_seq) WHERE
  scan_type='production'` (**gaplessness backstop**), `scan_type` CHECK
  (`production|sample|void|reprint|rework`), `counts_toward_total` (server-decided), `voids_box_scan_id`
  self-FK (corrections modelled *forward*, not by mutation), `raw_barcode`, `ts_value`, `ingested_at`,
  and **FKs** to the full hierarchy.
- **Append-only immutability:** `BEFORE UPDATE OR DELETE` trigger `box_scans_no_mutate()` RAISEs
  unconditionally (fires even for the superuser the services connect as) + `REVOKE UPDATE,DELETE`.
  This is a real Bronze contract, unlike legacy.
- `po_box_counter` — the per-PO `last_label_seq` + `total_qty` high-water mark; the advisory-lock
  anchor for the gapless authority.
- `v_po_box_totals` — authoritative per-PO totals recomputed from the ledger
  (`box_count`, `last_label_seq`, `total_qty`).

**Only wart:** it's `barcode-service`-owned and orphaned — no client calls `/v1/scans`, so it holds no
data and its gapless guarantee protects nothing yet. And the *sample* concept collapses into
`scan_type='sample'` (no separate `sample_boxes`) — cleaner, but the migration of V1's sample-balance
semantics needs verification (V1 tracks a sample *balance* with `should_increment`).

---

## 4. Writer / reader inventory (file:line evidence)

### Writers

| Writer | Path | Table | Evidence |
|---|---|---|---|
| barcode-scanner-**v1** SPA | Hasura GraphQL (direct DB) | `scanned_boxes`, `sample_boxes` | `barcode-scanner-v1/src/graphql/mutations/index.js` — `SET_BOX`/`INSERT_SAMPLE_INCREMENT` → `insert_scanned_boxes`, `insert_sample_boxes` |
| edge-api **create-sample** | NestJS usecase | `sample_boxes` + companion `scanned_boxes` (when `shouldIncrement`) | `edge-api/src/data/DAO/samples/samples-dao.ts:60` `INSERT INTO scanned_boxes …` |
| edge-api **edit-sample** | NestJS usecase | `scanned_boxes` (UPDATE `box_order_number=0`) | `edge-api/src/data/DAO/samples/samples-dao.ts:89` `UPDATE scanned_boxes SET increment=…` |
| **barcode-service** (Go) | `POST /v1/scans` (Bearer JWT) | `box_scans`, `po_box_counter` | `services/barcode-service/cmd/barcode-service/scans.go` `insertScan` / `counterSQL` |
| barcode-scanner-**v2** SPA | `POST /api/labels` (x-api-key) | *intended* `scanned_boxes` — **but no handler exists** | `barcode-scanner-v2/.../barcode-scanner-panel.tsx:260` `api.post("/api/labels", …)`; edge-api `src/usecases/labels/` has **only** `list-labels` (GET) |

### Readers

| Reader | Path | Evidence |
|---|---|---|
| edge-api **list-labels** | `GET /api/labels` → `SUM(increment) WHERE box_order_number!=0` + rows | `edge-api/src/data/DAO/labels/labels-dao.ts:14-34`, `list-labels.controller.ts` |
| barcode-scanner-**v1** SPA | Hasura `v_scanned_boxes` + `scanned_boxes_aggregate` (filter `box_order_number _neq 0`) | `barcode-scanner-v1/src/graphql/queries/queries.graphql:52-106`, `containers/App/index.js:575` sums `increment` |
| **OEE engine / oeecloud-worker** | — | grep of `oeecloud-node-red` for `scanned_boxes` → **0 hits** |
| **read-api / stream-engine / reports / Superset** | — | grep across `services/` (excl. barcode-service) + `reports` → **0 hits** |

**Conclusion:** `scanned_boxes` is **not** wired into OEE, net-count, Quality, `production_orders`, or
any report/BI surface. It is an **operational label-tracking ledger** for the barcode app only.

---

## 5. Semantics — role in OEE (advisory, not authoritative)

- **`scanned_boxes.increment`** accumulates the units-per-box for real boxes; the total per PO is
  `SUM(increment) WHERE box_order_number != 0` (label-tracking count shown in the operator UI).
- **`box_order_number = 0`** is a magic companion row that carries the *sample* increment for a PO
  (written by edge-api's sample path and read/filtered out everywhere).
- **It does not feed OEE.** Gross count comes from `equipment_values` (PLC totalizer); net/good count
  and Quality are computed in the OEE engine from PLC signal and PO data — **not** from `scanned_boxes`
  (proven: zero readers in oeecloud/read-api/stream-engine). So today the box count is **advisory /
  operational** — a serialization & traceability aid for the packing operator (which box number,
  print the next label), not the authoritative production count.
- **Which tenants use it:** **bispharma + bisnago** (aluminum-tube packaging). *Evidence:* V1 ships
  `public/media/logo-bispharma-peb.png` + `logo-bisnago-peb.png`; V2's `tag.tsx` label is hardcoded
  "BISPHARMA EMBALAGENS LTDA" / *"Bisnaga de Alumínio"* with `logo-bispharma-peb.png`. The physical
  scanner+printer feature is client-specific to these pharma-packaging tenants.
  **⚠ UNVERIFIED — live production usage/volume.** Staging `scanned_boxes` holds **0 rows** (probed
  2026-09-08), so I cannot prove *live* per-tenant write volume from staging. The real data lives on
  the legacy/prod DB (`packiot40`), which I did **not** probe (read-only-staging mandate; prod is a
  per-task exception, not authorized here). *To verify:* a read-only `SELECT id_enterprise, count(*),
  max(ts_value) FROM scanned_boxes GROUP BY 1` on prod would confirm which enterprise ids write and how
  recently.
- barcode-service's `box_scans` (the "north-star serialization/pharma pillar") is the intended *future*
  home where this becomes an authoritative, Part-11-capable serialization ledger.

**Design consequence:** because it is advisory today and authoritative *tomorrow* (pharma
serialization), the redesign should treat the raw scan as a **Bronze event** (immutable fact) and the
per-PO count as a derived **Gold** aggregate — so it can later carry EPCIS/genealogy weight without a
second rewrite.

---

## 6. Backend ingest — the recommendation (edge-api, first-class)

### 6.1 The three options

| | **A. edge-api HTTP endpoint** (user's lean) | **B. RabbitMQ / ingest-shim** (ADR-0011/0053) | **C. Direct DB write** (status quo) |
|---|---|---|---|
| Consistency w/ existing | ✅ edge-node-red already calls edge-api for PO control + downtimes; same vertical-slice usecase | ⚠ that path is for SparkPlug telemetry, not human control actions | ❌ Hasura-era pattern being retired |
| Auth | ✅ API-key (`auth.middleware`), already the edge↔cloud model | JWT/X-Ingest-Key at the shim | ❌ Hasura JWT / superuser |
| Response needed | ✅ synchronous: needs the assigned `label_seq`, the running total, the PO/label metadata | ❌ fire-and-forget 202, no domain response | ✅ but via GraphQL, uncontrolled |
| Volume | ✅ human-paced (one scan per boxed unit, seconds apart) — trivially within edge-api's request model | overkill; queue shines at 100s/s telemetry | n/a |
| Offline-durable | ✅ pair with an edge-side scan-queue (client outbox) that replays to edge-api by `scan_uuid` | ✅ broker is durable, but the client still needs a local outbox to reach it | ❌ |
| Tenant-scoping | ✅ resolves `callerEnterpriseId` server-side, fences the write | at the shim | ❌ client names tenant |
| Audit trail | ✅ `res.locals.logData = UserLogsDTO` (the platform audit convention) | ✗ | ✗ |
| Gapless authority | ✅ move barcode-service's `pg_advisory_xact_lock` + last+1 logic into the DAO | possible but async makes "assign next seq + return it" awkward | client-side, fragile (today's bug surface) |

### 6.2 Recommendation: **edge-api HTTP endpoint (Option A)**

A box scan is **semantically a factory *control/event* action**, not a telemetry stream: it is
human-paced, it needs a **synchronous domain response** (the server-assigned gapless `label_seq` + the
running total, so the client can print the *next* label), it needs a **PO/label metadata lookup**, a
**tenant fence**, and an **audit entry**. That is edge-api's exact shape, and it is *already* how the
edge tier talks to the cloud (edge-node-red → edge-api for PO control + downtimes). Routing scans
through RabbitMQ would force a request/response feature (assign-and-return-the-sequence) onto a
fire-and-forget bus, and would fragment auth + audit across a second ingress. Reserve the
queue/ingest-shim for what it is good at — high-volume, no-response SparkPlug telemetry.

**The gapless-sequence authority is not lost** — it *moves* from the Go barcode-service into the
edge-api usecase: the same `SELECT pg_advisory_xact_lock(id_production_order)` + read-last / decide-next
/ insert / upsert-counter, in one pg-promise transaction, writing the **`box_scans` Bronze table**.
This collapses three write paths into one and gives the edge-app a single, authenticated, audited,
tenant-fenced backend — while keeping the superior `box_scans` data model.

> **Trade-off to state plainly:** the barcode-service (Go) is a well-built Phase-0 skeleton with tests
> and the correct DB model. Choosing edge-api means **retiring/absorbing** it (its logic ports to the
> DAO almost verbatim) rather than wiring it up. The alternative — keep barcode-service and point V2 at
> `/v1/scans` — is *also* viable and keeps the gapless logic in a purpose-built service; but it adds a
> **second** edge↔cloud control-plane with a **second** auth model (Cognito Bearer vs edge-api's
> API-key) and no `user_logs` audit. Given the user's steer toward "the same edge-api or any proper
> architecture" and the coherence argument, **edge-api wins**. (If pharma serialization later demands a
> dedicated service, barcode-service can be revived as a downstream Silver/Gold processor reading the
> `box_scans` Bronze that edge-api writes — the model already supports that split.)

### 6.3 Concrete integration shape (edge-api)

**New vertical slice** `edge-api/src/usecases/scanned-boxes/record-scan/` (mirrors the samples slice):

```
POST /api/scanned-boxes            ← the durable gapless write (replaces V2's dead POST /api/labels)
  auth:    auth.middleware (?token= API key) → res.locals.callerEnterpriseId
  body:    { scanUuid, rawBarcode, idProductionOrder, idEquipment, qty, scanType, mode, labelSeq? }
  audit:   res.locals.logData = { eventType:'scanned_box.record', payload, lineId, enterpriseId }
  service: ScannedBoxesService.record(callerEnterpriseId, dto)
  DAO:     ScannedBoxesDAO.recordScan()  — ONE tx:
             SELECT pg_advisory_xact_lock(id_production_order);
             idempotent-replay by scan_uuid → return original row;
             tenant fence (PO + equipment belong to callerEnterpriseId);
             read po_box_counter.last_label_seq → next = last+1 (assign) | assert (validate);
             INSERT box_scans (...);  UPSERT po_box_counter (...);
           COMMIT;
  returns: { boxScanId, labelSeq, total, scanUuid, replayed }   (409 {expected,got} on gap)

GET  /api/scanned-boxes?idEquipment=&idProductionOrder=   ← replaces GET /api/labels
  reads v_po_box_totals (+ recent box_scans rows), tenant-fenced on callerEnterpriseId
```

- **Write target:** `box_scans` + `po_box_counter` (the Bronze model), **not** legacy `scanned_boxes`.
- **DAO pattern:** extends `UnityOfWork`, injected as `provide:'ScannedBoxesDAOInterface'` (edge-api
  convention). Throw `HttpException` subclasses, never plain `Error`.
- **pg-promise + advisory lock:** run the whole thing in one `db.tx(...)`; `pg_advisory_xact_lock` is
  xact-scoped, released on commit/rollback. (Mind pgbouncer transaction pooling — edge-api's pool must
  pin the backend for the tx, same rule barcode-service documents.)
- **Client change (both scanners):** point at `POST /api/scanned-boxes` with the API-key header; drop
  the direct-Hasura mutations (V1) and the dead `/api/labels` POST (V2). Add a **local scan-queue**
  (IndexedDB) keyed by `scanUuid` for offline replay. Move the client-side gapless check to
  *advisory-only* (the server is now authoritative; the client shows the 409 correction).

---

## 7. New-stack target — medallion placement + naming + tenancy

Aligns with `analytics-clean-schema-redesign.md` (public = RAW+Bronze; `silver`/`serving` derived) and
the #228 medallion split.

| Tier | Object | Meaning | Notes |
|---|---|---|---|
| **Bronze** (raw, immutable) | `box_scans` (keep name, or `bronze.box_scans` under #228) | one row per physical scan — the immutable fact | append-only trigger + `scan_uuid` idempotency already correct; add RLS |
| **Bronze/anchor** | `po_box_counter` | per-PO gapless high-water mark (advisory-lock anchor) | operational, not a served table |
| **Gold** (served count) | `v_po_box_totals` → promote to a Gold grain e.g. `oee_box_count` / `serving.po_box_totals` | authoritative per-PO box count + total_qty | this is what front4/operator/reports read *if* box count ever becomes an OEE input |

**Naming clean-up (retire the warts):**
- Retire legacy `scanned_boxes` + `sample_boxes` after cutover (their function is fully covered:
  production scans → `box_scans scan_type='production'`; samples → `scan_type='sample'`; the
  `box_order_number=0` magic-companion row disappears).
- Kill the `id`/`id_box` dual-key drift and the duplicate indexes by not carrying them forward.
- `box_order_number` → `label_seq` (already the name in `box_scans`); `increment` → `qty`.

**Tenancy / RLS:** `box_scans.id_enterprise` is `NOT NULL` with an FK (already correct). Add
**row-level security** `USING (id_enterprise = current_setting('app.id_enterprise'))` consistent with
the analytics RLS the clean-schema plan applies to the serving tier, so a future direct reader can't
cross tenants. edge-api continues to fence on `callerEnterpriseId` in the WHERE as defence-in-depth.

---

## 8. Cutover sketch (expand / contract) — DESIGN ONLY

1. **Expand — build the edge-api slice (additive).** Add `POST/GET /api/scanned-boxes` writing/reading
   `box_scans`+`po_box_counter` (both already exist on staging). No client change yet. Legacy
   `scanned_boxes` still written by the sample path in parallel. **Zero consumer impact.**
2. **Dual-read shim (optional).** Make `GET /api/labels` read `v_po_box_totals` so the current V2 read
   keeps working while the write flips.
3. **Flip the write (per tenant — bispharma first, then bisnago).** Point the scanner app's write at
   `POST /api/scanned-boxes`. Migrate the sample path (`create-sample`/`edit-sample`) to write
   `box_scans scan_type='sample'` instead of the `box_order_number=0` companion. Backfill any live
   legacy rows into `box_scans` if history must be preserved (bispharma/bisnago prod only).
4. **Retire.** Once no client writes legacy: drop the V1 Hasura mutations, drop the dead
   `POST /api/labels`, and (after a zero-write watch window) drop `scanned_boxes` + `sample_boxes` and
   their duplicate indexes. Decommission or repurpose `barcode-service` (→ downstream Silver/Gold, or
   remove).
5. **Edge app.** Package the scanner SPA into the on-prem edge bundle with the offline scan-queue;
   deploy to the bispharma/bisnago station box.

**Expand/contract discipline** (per MEMORY: live rename needs `lock_timeout`+retry; a DROP needs a
proven zero-writer window). Keep the drop and the write-stop in **separate deploys**.

### Risk & who-consumes (so a future change can't break the client apps)
- **Breaks the packing line if fumbled** — this is a live operator tool at bispharma/bisnago. The
  physical scanner+printer must keep working through the cutover; do bispharma alone first, watch, then
  bisnago.
- **Consumers to notify on any schema change:** (1) barcode-scanner-v1 (Hasura, direct) — the most
  brittle, retire first; (2) barcode-scanner-v2 (edge-api); (3) edge-api `list-labels`/`samples`;
  (4) **nobody** in OEE/reports/BI today — so the OEE surface is safe. If box count is ever promoted to
  an authoritative net-count, that adds oeecloud/read-api as consumers — design the Gold grain now so
  that promotion is additive.

---

## 9. Open questions / decisions for the user

1. **edge-api vs revive barcode-service.** Recommendation is **fold into edge-api** (coherence, one
   auth, audit). Confirm — or keep barcode-service and just wire V2 to `/v1/scans` (less rework, but a
   second control-plane + Cognito auth + no audit). *Decision gate.*
2. **Sample model.** Collapse `sample_boxes` into `box_scans scan_type='sample'` (clean) vs keep a
   separate sample-balance table? V1's sample *balance* semantics (`should_increment`, a decrementing
   remaining-quota) need an explicit home — `box_scans` records issued sample labels but not the
   configured *total/quota*. A small `po_sample_quota` table (or a PO custom_field) may be needed.
3. **Is box count ever authoritative for net/Quality?** Today advisory-only. If pharma serialization
   makes it authoritative, we design the Gold `po_box_totals` grain as an OEE input now (additive) vs
   keep it purely operational. *Product decision.*
4. **Offline scope for the edge app.** Confirm the packing line must print/scan through a cloud outage
   (assumed YES → local scan-queue + cached PO metadata). Which box (station PC vs the existing on-prem
   edge box) hosts it?
5. **Label template as data.** The bispharma label is hardcoded in `tag.tsx`. Should the template
   become client-configurable (config-as-data, ADR-0045/0047) so bisnago (and future pharma clients)
   don't need a code fork? Currently `"L03"` line + branding are hardcoded.
6. **Printer protocol.** Browser `window.print()` is fragile for industrial thermal labels (driver +
   dialog dependent). Decision: keep browser print, or move to a real label protocol (ZPL for Zebra) via
   a small local print agent for reliability/consistency? Affects the edge app design.
7. **Auth for the edge app.** V2 ships a hardcoded `x-api-key: '12345'` — a placeholder that must be
   replaced with the tenant's real edge-api `api_key` (and the app's Firebase/Cognito login reconciled
   with the API-key backend auth).

---

*Design only. No DDL, no deploy, no client change executed. All schema facts verified read-only against
`packiot_analytics@10.10.10.89` (staging) on 2026-09-08; all code facts cited by file:line.*
