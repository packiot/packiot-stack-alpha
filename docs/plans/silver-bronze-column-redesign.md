# Silver + Bronze column-level redesign

Column-level design review of the `silver` and `bronze` schemas of
`packiot_analytics` (staging), 2026-09-13. Scope is **silver + bronze only** —
`core` / `gold` / app-schemas / histdb are owned by sibling reviews.

The SAFE, additive, reversible wins are already **implemented** as migrations under
`db/migrations/tRD-silver-bronze-*` (see the "Implemented" section at the bottom).
This document is the **CUTOVER backlog**: findings whose fix touches a producer +
readers, or requires a hypertable rewrite, and therefore must not be done blind.

---

## Ground truth: the machine-state magic integers

`silver.equipment_values.state` and `silver.equipment_events.status` (plus the raw
mirrors and the `equipment_events_*` sibling tables) encode machine state as a raw
integer taken **verbatim from the PLC** on the SparkPlug `Status/StateCurrent`
metric — `stream-engine internal/writers/equipment_values.go` `BuildEventMint`
passes `int(value)` straight through. The authoritative meaning lives in the OEE
engine, `internal/rollup/compute.go:19`:

> `running = status 6; stopped = status IN (5, 10, 11).`

Confirmed by `compute.go` / `hour.go` / `shift.go`: `running_time` is credited only
from `status = 6`, `stopped_time` from `status IN (5,10,11)`. The engine does **not**
distinguish 5 vs 10 vs 11 any finer than "stopped".

Live staging distinct values (2026-09-13):

| Column | 6 (running) | 10 (stopped) | 5 (stopped) | 11 | NULL |
|---|---|---|---|---|---|
| `equipment_values.state` | 5,741,923 | 115,015 | 37,634 | — | 4,323,064 |
| `equipment_events.status` | 198,771 | 196,719 | — | — | — |

`NULL` state on `equipment_values` = counters-only samples with no state signal
(the known **#209 CPACK** downtime issue — a sole-writer cutover leaves `state`
NULL; that is a *pipeline* bug, separate from this *encoding* redesign).

Sibling convention to match: `bi.downtimes` (owned by the BI review) already exposes
a `status_label` column mapping `6 -> Running`, `10 -> Stopped`. The implemented
silver labeled views use the same idea (lowercase `running`/`stopped`).

### CUTOVER — full state/status normalization (do NOT execute here)

Goal: replace the bare PLC magic int with a normalized, self-describing surface and
retire hardcoded `= 6` / `IN (5,10,11)` predicates scattered across the code.

Two candidate target shapes:

1. **FK to a canonical code table** (`core.machine_state_code` or keep it
   `silver.machine_state`, already created): `state_code smallint REFERENCES ...`.
   Keeps the raw PLC number but makes it a declared, documented, referential domain.
2. **Normalized enum** (`silver.machine_state_enum AS ENUM('running','stopped',...)`):
   fully hides the PLC number behind semantics. More invasive; loses the raw code
   unless kept alongside.

Recommended: **option 1** (FK), because the raw PLC code is the interoperability
contract with the edge and must survive round-trips; a lookup FK documents it
without destroying it.

**Expand / contract sequence:**

1. *Expand* — `silver.machine_state` lookup exists (implemented). Add a validated
   `FOREIGN KEY (state) REFERENCES silver.machine_state(state) NOT VALID` on the raw
   tables, then `VALIDATE CONSTRAINT` off-peak (hypertable: validates per chunk).
   Requires seeding every PLC code that occurs — today {5,6,10} live, 11 reserved;
   run `SELECT DISTINCT state` on both prod and staging before locking the FK, or a
   new PLC code will start rejecting ingest.
2. *Migrate readers* — replace hardcoded predicates with joins / `is_running` /
   `is_stopped` from `silver.machine_state` (or the labeled views). Consumers below.
3. *Contract* — once every reader is off the bare literal, the magic-int predicates
   are gone; the raw column stays (it is the PLC contract) but is now FK-guarded.

**Full consumer list (every reader of state/status — grep-grounded 2026-09-13):**

| Consumer | Location | Usage |
|---|---|---|
| stream-engine rollup | `internal/rollup/compute.go:95-98,155-156`, `hour.go:209-213`, `shift.go:199-203` | `CASE WHEN ee.status = 6 ... IN (5,10,11)` — running/stopped time |
| stream-engine rollup tests | `rollup/recalc_test.go:42-43`, `backfill_test.go:27`, `changeover_golden_test.go:15` | golden fixtures assert `status = 6` / `IN (5,10,11)` |
| read-api (Montebello/Incoplast external) | `cmd/refdata-api/external_montebello_incoplast.go:300` | `(ee.status <> 6 or ee.status is null)` |
| Superset `bi.downtimes` dataset | `configs/superset/assets/datasets/packiot_analytics/downtimes.yaml:111-125` | `status` + `status_label` (6->Running,10->Stopped) — bi schema, sibling-owned |
| Superset `bi.live_status` dataset | `configs/superset/assets/datasets/packiot_analytics/live_status.yaml` | latest reading per equipment (DISTINCT ON equipment_values) |
| front4 | (no direct 6/10 literal found; consumes read-api/Superset) | indirect |

Because a reader lives in **each** of stream-engine (Go SQL), read-api (Go SQL), and
Superset (bi views), the contract cutover must land producer→readers in that order
and be diffed against the rollup golden fixtures (they encode `status = 6`).

---

## CUTOVER findings — wrong / loose types (hypertable rewrites → propose)

All of these are on the `silver.equipment_values` / `..._raw` **hypertables**, so an
in-place `ALTER COLUMN ... TYPE` is a per-chunk rewrite under `ACCESS EXCLUSIVE` —
never a "safe" additive change. Do them as an expand/contract (add corrected column,
backfill, swap) during a maintenance window, or at the next table rebuild.

| Column | Current type | Should be | Evidence | Notes |
|---|---|---|---|---|
| `equipment_values.id_order_quality` | `varchar(255)` | `integer` | every *other* `*_quality` sibling is `integer`; this is the lone string | 100% NULL on staging (10.2M rows) — zero data to migrate, pure schema debt |
| `equipment_values.ts_value_production_quality` | `date` | `integer` | sibling quality flags are integers; a "quality flag" typed as a calendar date is nonsensical | 100% NULL — a copy-paste of `ts_value_production`'s `date` type onto its quality-flag column |
| `equipment_values.is_equipment_line_infeed` | `integer` (1/0) | `boolean` | comment literally says "Flag (1/0)" | 100% NULL; boolean is the honest type |
| `equipment_values.is_equipment_line_outfeed` | `integer` (1/0) | `boolean` | comment says "Flag (1/0)" | 100% NULL |
| `equipment_values.mode` | `integer` (magic) | FK/enum or documented lookup | PackML mode code; distinct live = {1, 6, NULL} (769 each of 1/6, 10.2M NULL) | same magic-int smell as `state`; low value (mostly NULL). Could ride `silver.machine_state`-style lookup |
| `equipment_events.status` naming | `status` | unify to `state` | same domain as `equipment_values.state` but different name across two silver tables | naming-consistency only; a pure rename is still a reader cutover (grep table above) |

The `id_equipment` type mismatch between event tables is also worth a note:
`equipment_events.id_equipment_event` is `bigint` but `equipment_events_man.id_equipment_event`
is `integer`. Not urgent (man table is small), but the surrogate PK width should be
consistent — align on `bigint` at a rebuild.

---

## CUTOVER findings — width / denormalization (propose)

- **The `*_quality` column family on `equipment_values` (14 columns) is entirely
  NULL on staging** (`net_production_incr_quality` … `ts_value_production_quality`,
  `process_scrap_*_quality`, `state_quality`, `mode_quality`, `id_shift_quality`,
  `id_order_quality`, …). Likewise `is_equipment_line_infeed/outfeed`,
  `id_equipment_line_infeed/outfeed`, `position_in_equipment_line`. These are the
  per-metric SparkPlug quality flags that the merged silver path never populates
  (only Bronze-raw would). On a 55+ column, 10.2M-row hypertable this is real width.
  **Proposal:** confirm no reader references them (a `read-api`/`superset`/rollup
  grep showed none), then either (a) drop them from the *merged* silver table and
  keep them only on Bronze-raw where the pipeline actually writes them, or (b) move
  the quality flags into a single `jsonb quality` column (like `faults`/`analogs`).
  Either is an expand/contract on a hypertable → propose, do not execute here.

- **`equipment_values` denormalizes the full hierarchy** (`id_enterprise`, `id_site`,
  `id_area`) plus `tp_equipment` — copies of `core.equipments`. This is a deliberate
  read-optimization for the rollup (avoids a join per bucket) and is fine; documented
  here so a future reviewer does not "normalize" it and regress the hot path.

## CUTOVER finding — duplicate PK index on a hypertable (propose)

`silver.equipment_events` carries **two identical unique indexes** on
`(id_equipment, ts_event)`:

- `equipment_events_pkey` — backs the PRIMARY KEY constraint (**keep**),
- `equipment_events_pk` — a standalone parent-only unique index (**redundant**).

I attempted the drop as a SAFE win but it **failed**:

```
ERROR: cannot drop index _timescaledb_internal."629_317_equipment_events_pkey"
because constraint 629_317_equipment_events_pkey ... requires it
```

The parent `equipment_events_pk` has **no chunk children of its own** — chunks only
carry the constraint-backed `..._equipment_events_pkey`. So a `DROP INDEX
silver.equipment_events_pk` resolves, through TimescaleDB's parent→chunk dispatch,
onto the chunk-level PK constraint index and is refused. Because the redundant index
has no chunk children it also costs no per-chunk storage — it is a cosmetic catalog
duplicate, low value, and entangled with the PK. **Proposal:** drop it only via the
TimescaleDB-aware path (detach/handle per chunk, or at a table rebuild), not as an
online migration. Not worth an outage on its own.

---

## Implemented (SAFE) — see `db/migrations/tRD-silver-bronze-*`

1. **`tRD-silver-bronze-state-labeled-view`** — the headline win. Adds:
   - `silver.machine_state` lookup (5/6/10/11 → label + `is_running`/`is_stopped`),
     seeded from the OEE-engine classification.
   - `silver.equipment_events_labeled` and `silver.equipment_values_labeled` views
     (`SELECT *` + `status_label`/`state_label` + `is_running`/`is_stopped` via
     LEFT JOIN, so unknown/NULL codes stay visible).
   - Enriched COMMENTs on every `state`/`status` column (silver + bronze + sibling
     event tables) documenting the domain and pointing at the labeled surface.
   - Fixed a misleading `data_quality_event.severity` comment (claimed
     "info/warn/critical"; live domain is `error`/`warn`).
   - Additive, reversible, zero pipeline change. Hardproofed: label distribution
     matches live `status`/`state` distincts exactly; rollback drops cleanly and
     restores prior comments.

2. **`tRD-silver-bronze-drop-bogus-idequip-default`** — drops the erroneous
   `DEFAULT nextval('silver.equipment_values_id_equipment_seq')` on **both**
   `silver.equipment_values.id_equipment` and `bronze.equipment_values_raw.id_equipment`.
   `id_equipment` is an FK to `core.equipments` and must be producer-supplied, never
   fabricated from a sequence (a classic accidental-serial leftover). Every writer
   already supplies it (it is part of the `UNIQUE(id_equipment, ts_value)` upsert
   key), so the sequence never fired — harmless today, latent footgun removed.
   Dropping a column default is catalog-only (no hypertable rewrite); `source_seq`
   and `ingested_at` defaults are correct and left intact. Reversible.
