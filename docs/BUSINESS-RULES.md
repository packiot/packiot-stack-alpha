# Business Rules + Domain Knowledge

> The non-obvious-from-code stuff. Read this BEFORE touching anything that handles equipment hierarchy, shifts, OEE math, or CS Admin onboarding. Each rule here was learned the hard way (often via a production incident); ignoring them is how you reintroduce old bugs.

---

## 1. What is Packiot

Packiot is an **industrial IoT / OEE (Overall Equipment Effectiveness) platform** for manufacturing. It connects factory PLCs to a cloud analytics stack via MQTT/SparkPlug B, HTTP, and Node-RED automation engines.

**The platform answers**: "How efficiently is this factory running?"

The key business questions per factory, per shift:
- **Quality**: how many units passed vs scrapped?
- **Availability**: how many minutes was the line actually running vs in downtime?
- **Performance**: at what % of ideal speed did it run?

OEE = Quality × Availability × Performance. Every customer cares about this number; every architectural decision should preserve OEE-data integrity above all.

---

## 2. The equipment hierarchy

```
Enterprise
   └─ Site
       └─ Area
           └─ Equipment    ← tp_equipment in the DB
              │
              ├─ Machine    (tp_equipment = 1)
              ├─ Sector     (tp_equipment = 2)  → groups multiple Machines
              └─ Line       (tp_equipment = 3)  → groups multiple Sectors
```

### Hard rules

- `id_unit = id_equipment` **only** when `tp_equipment = 1` (machine). Sectors and Lines have `id_unit = NULL` because they aren't a single unit.
- `lead_machine` field on a Sector or Line points at the **Machine whose PLC generates the downtime events** for that group. Default = first machine in the line. The downtime classifier uses `lead_machine` to know which PLC is the source-of-truth for "line is down".
- **CS Admin onboarding order is strict**: Enterprise → Site → Area → Equipment → Shifts → packml_register. Skipping or reordering breaks foreign-key constraints in known ways.
- Enterprise creation auto-generates `api_key` via `randomUUID()`. The api_key is what edge-node-red uses to authenticate to edge-api. Never reuse it across enterprises.

### Soft-delete convention

The `active` boolean column exists on certain tables for soft-delete:
- **Today (live)**: `enterprises`, `users`, `packml_register`
- **Coming (PRs #118 + #124)**: extending to `sites`, `areas`, `equipments`

Until PRs #118 + #124 land AND downstream consumers (oeecloud-node-red, Hasura GraphQL, reports/BigQuery) filter on `active`, **soft-deleted rows on `sites/areas/equipments` will still be visible to those consumers.** Don't assume `active=true` is universally enforced yet — check the target table's current state.

---

## 3. PackML parameters (SparkPlug B convention)

These are the parameter IDs edge-node-red emits + oeecloud reads. All numeric, all part of the SparkPlug B topic structure.

| Parameter | Meaning |
|---|---|
| `30700` | Machine sequence (startup config; looked up via `id_unit` in packml_register) |
| `30701` | Ideal speed |
| `30702` | Lead machine (`id_equipment` of the machine that generates downtimes for a line/sector) |
| `30750` | Min speed threshold |
| `30751` | Min threshold time |
| `30758` | Event trigger type: `0`=instant, `4`=5-min average (the CPAC algorithm) |
| `30800-30899` | Production order control (start, stop, setup, etc.) |

When debugging an unrecognized parameter, **search packml_register first** — every parameter ID needs a row mapping it to an `id_equipment` for oeecloud to process it.

---

## 4. The shift system (the trap)

`shifts` and `shift_hours` are TWO tables. They serve different purposes and don't share schema conventions.

### `shifts` — definition layer
- `cd_shift` is **alphanumeric** (e.g. `"MORNING"`, `"T1"`, `"1"`). Treat as opaque string.
- Scoped to area; site is fallback.

### `shift_hours` — calendar expansion
- One row per shift × weekday.
- ⚠ **`begin_time` and `end_time` are INTEGER SECONDS from `week_begin`** — NOT clock times. The most common bug in this codebase is assuming they're clock times.
- `week_begin`: seconds offset from Monday 00:00. **Can be negative** (e.g. `-3000` = Sunday 23:10 — for shifts that start before Monday in the customer's local interpretation).

### Priority resolution

Area shifts FIRST, site shifts as fallback. If both exist for the same area, area wins.

### Runtime-only fields

`shift_size`, `duration`, `id_equipment` on `shift_hours` are **set by the OEE engine, not CS Admin**. If you're writing a CS Admin DTO, do NOT include these — they're computed.

---

## 5. Production Order lifecycle

```
   1 (available)
   │
   ▼
   2 (running) ────┐
   │               │
   │               ▼
   │           4 (paused)
   │               │
   └──────┬────────┘
          ▼
   3 (finished)
```

| status | Meaning |
|---|---|
| `1` | Available — created but not started |
| `2` | Running — actively producing |
| `3` | Finished — closed, no further updates |
| `4` | Paused — was running, can resume to 2 |

### Hard rules

- `production_orders_runtime` has **one row per PO run**. `recalc_needed=true` triggers re-processing by the OEE engine.
- `id_order` is **the human PO number** (what operators see). `nu_production_order` is a different field; don't confuse them. Both exist for legacy reasons.
- The `getOrderDateConflict` check rejects POs with `ts_start` overlapping a previous PO on the same equipment. Backfills must use `ts_start=now-Xs` to dodge this (per session 30 lesson).

---

## 6. Box scans (production counting)

`scanned_boxes` is per-PO + per-equipment. Counts are NOT just `count(*)`:

- `increment` column **accumulates count** — sum it, don't count rows.
- `box_order_number != 0` filters valid scans. Box order 0 means "not associated with a PO" and is ignored for OEE math.

---

## 7. OEE aggregations — the data pipeline

```
equipment_values          (raw SparkPlug metrics, ts_value + id_equipment)
   │ (1-min cagg)
   ▼
equipment_runtime_1min    (TimescaleDB continuous aggregate)
   │ (1-hour cagg)
   ▼
equipment_runtime_1hour
   │ (manual roll-up via pg_cron)
   ▼
equipment_runtime_shift   ← what dashboards show; what OEE math reads
   │
   ▼
equipment_runtime_{1day, 1week, 1month}
```

### Hard rules

- `equipment_values` has `UNIQUE(ts_value, id_equipment)`. Inserts that violate this are duplicate samples — drop them.
- The continuous aggregates run on TimescaleDB's policy + cron. **They don't update instantly**; expect 1-2 min lag from raw write to 1-min cagg visibility.
- "Create packml topics" trigger auto-manages `packml_register` on entity changes — DON'T also write to packml_register from application code unless you're CS Admin.
- **All OEE math lives in PostgreSQL triggers + stored procs**, not in oeecloud-worker. The Go service writes raw data only; the DB does the calculation.

---

## 8. CS Admin (Customer Success Admin)

Internal tool used by the CS team to onboard factory clients without touching the DB manually.

### Onboarding order (strict)

1. **Enterprise** (auto-generates `api_key` via `randomUUID()`)
2. **Site**
3. **Area**
4. **Equipment** (incl. `lead_machine`, `tp_equipment`, `id_unit`, `status_type`)
5. **Shifts + Shift Hours**
6. **packml_register** — CS Admin creates ALL entries; oeecloud does **NOT** auto-register. `active=true` is required for oeecloud to process.

### Hard rule for CS Admin DTOs

DTOs must contain **only fields a CS engineer sets during onboarding**. Never include production-runtime computed fields (e.g. `shift_size`, `duration`, `signal_quality`). Validation on these belongs to the OEE engine, not CS Admin.

---

## 9. Cloud vs Factory — what runs where

```
FACTORY (per customer site)
  ├─ edge-node-red             — PLC ingest, customization
  ├─ edge-transformer (Go)     — NEW, ADR-0009; standardized transforms
  ├─ local RabbitMQ            — message bus
  ├─ operator SPA              — operator UI (per-factory)
  └─ (future) local TimescaleDB — ADR-0001, deferred

CLOUD (us-east-1)
  ├─ edge-api (NestJS)         — control plane, CS Admin
  ├─ oeecloud-worker (Go)      — consumes from per-factory edges
  ├─ mirror-worker-go (Go)     — prod→staging mirror (staging only)
  ├─ TimescaleDB (tsp12)       — source of truth
  ├─ Hasura                    — GraphQL gateway
  └─ Authentik SSO             — auth gate
```

### Hard rules

- **edge-node-red + operator + edge-transformer run per-factory.** They are deployed via ADR-0005's per-factory self-hosted runner mechanism, NOT via the cloud deploy chain.
- **Production cloud DB (tsp12) is SELECT-only** from any new service. See `feedback_prod_db_readonly` rule + `tsp12-pgdump-blocked-by-select-only-role` memory. Don't even try pg_dump — it requires LOCK TABLE that the role doesn't have.
- **Staging is canonical for all branches.** Push to `main` or `master` is forbidden (`edge-api/master` is the legacy EB prod-deploy trigger; touching it deploys to real customers).

---

## 10. Authentication + secrets convention

### Per-environment secret prefix
- `packiot/staging/*` — staging
- `packiot/production/*` — production (don't touch from CI unless explicit)
- All AWS Secrets Manager secrets follow this prefix; CI tooling can pattern-match `packiot/<env>/*`.

### Service-to-service auth (today)
- Factory → cloud: `api_key` from `enterprises.api_key` (per-customer)
- Operator → factory: JWT from edge-api's auth-apikey-dao
- Cloud-internal: HASURA_GRAPHQL_ADMIN_SECRET for service-to-service Hasura calls
- AWS-internal: EC2 instance profile (`packiot-staging-app` / `packiot-production-app`) with SecretsManager read perms

### Hardcoded secrets in code
**Never.** If you find one (we've found several this year), it's:
1. A bug — rotate immediately
2. A scope leak — the value belongs in AWS Secrets Manager, accessed via env var
3. A history-pollution problem — the rotation is independent of the file deletion

---

## 11. The audit-log convention

Every mutating edge-api endpoint sets `res.locals.logData = UserLogsDTO`:

```ts
{
  eventType: string,                // e.g. 'production_orders.start'
  payload: any,                     // the request body
  lineId: null | number,
  enterpriseId: null | number
}
```

The `LoggerMiddleware` writes this to the `user_logs` table. **This is what `mirror-worker-go` replays from** for prod→staging audit-log mirroring (Real Client Data initiative). Every new mutating endpoint MUST set `logData` or it breaks the mirror.

---

## 12. Glossary of business terms

| Term | Meaning |
|---|---|
| **OEE** | Overall Equipment Effectiveness. Quality × Availability × Performance. The headline number. |
| **PO** | Production Order. The work unit ("make 1000 of X on line 4 between time A and B"). |
| **Downtime** | Period a machine wasn't producing. Has `category` + `subcategory` (planned vs unplanned, mechanical vs operational, etc.). |
| **Lead machine** | The machine whose PLC's status drives downtime classification for a Sector/Line. |
| **CS Admin** | Customer Success Admin — the internal tool for onboarding factory clients. |
| **PackML** | Packaging Machine Language. The convention for PLC parameter IDs + state machine. |
| **SparkPlug B** | The MQTT-based protocol PLCs use to publish data. Defines topic structure + payload encoding. |
| **CPAC algorithm** | A 5-minute moving-average smoothing applied to event triggers (`parameter 30758 = 4`). Production-side smoothing; staging tracks raw transitions for divergence detection. |
| **Shift bucket** | An entry in `equipment_runtime_shift` — one OEE summary per equipment × shift. |
| **packml_topic** | The string from SparkPlug B (`ENT/SITE/AREA/LINE/UNIT/...`). Maps via `packml_register` to `id_equipment`. |
| **id_order vs nu_production_order** | Two different PO identifiers. `id_order` is what operators see (human-readable); `nu_production_order` is internal sequencing. Both legacy, both still used. Don't confuse them. |

---

*If a business rule is missing here that you wish you'd known: open a PR. This doc is the team's institutional memory; growing it is everyone's job.*
