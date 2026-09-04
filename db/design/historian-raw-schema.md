# Historian RAW-LAYER canonical schema (S3 Parquet cold archive)

**Status:** DESIGN + codified DDL/plan. Read-only investigation; **no data re-unloaded**
(that is the follow-up). Production untouched; legacy (`18.220.223.110`) read-only.

**Scope:** the shared RAW-layer contract for `equipment_values` + `equipment_events`,
conformed to by three consumers:

1. **analytics-raw** — the F3 `packiot_analytics` source tables (the source of truth).
2. **the historian** — the S3 Parquet cold store + its Glue partition-projection tables.
3. **the gateway union** (`historian-gateway` → `ev_all`) — the hot+cold view Superset/read-api query.

**The governing rule (from CLAUDE.md / prior audit):** *the historian schema is
analytics-prioritized* — every archived column must match the analytics column's
type and name. Today it does not. This document resolves every deviation and pins
the canonical shape all three must conform to.

---

## 0. Hardproof — how every claim below was obtained

Every type in the tables that follow comes from one of these live commands (run
2026-09-04, account `639178078294`, `us-east-1`):

| Source of truth | Command |
|---|---|
| **analytics** `equipment_values` / `equipment_events` (58 / 26 cols) | SSM `AWS-RunShellScript` → `i-064bb36d1c454d861` → `docker exec timescaledb psql -U postgres -d packiot_analytics -c "SELECT ordinal_position,column_name,data_type,udt_name FROM information_schema.columns WHERE table_name='…' AND table_schema='public' ORDER BY ordinal_position"` |
| **historian Glue** tables (56 / 24 cols) | `aws glue get-table --database-name packiot_historian_staging --name equipment_values` (and `equipment_events`) |
| **actual Parquet** physical schema | `aws s3 cp …-legacy.parquet` + `aws s3 cp …/data-2026-07-03.parquet`, then `duckdb -c "DESCRIBE SELECT * FROM read_parquet('…')"` and `parquet_schema('…')` |
| **file health** | `aws s3 ls s3://packiot-staging-historian-639178078294/equipment_values/ --recursive` → 961 objects, size histogram |
| **gateway coupling** | `services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh` |

> **SSM note for the next session:** the Run-Command document on this account is
> **`AWS-RunShellScript`**, *not* `AWS-RunShellCommand` (the latter → `InvalidDocument`).

### Hardproof highlights (the smoking guns)

- **The `ts_value` TZ bug is real and lives in the Parquet metadata, not just the Glue DDL.**
  `parquet_schema()` on the two generations:

  | File | physical | converted | logical |
  |---|---|---|---|
  | `…/2024/month=3/data-2024-03-legacy.parquet` | `INT64` | `TIMESTAMP_MICROS` | `TimestampType(**isAdjustedToUTC=1**, MICROS)` |
  | `…/2026/month=7/data-2026-07-03.parquet` (live) | `INT64` | `TIMESTAMP_MICROS` | `TimestampType(**isAdjustedToUTC=0**, MICROS)` |

  The legacy backfill wrote a **UTC instant** (`isAdjustedToUTC=1`, correct — matches
  `timestamptz`); the live append writes a **timezone-naive** value (`isAdjustedToUTC=0`).
  Both surface under the Glue Hive type `timestamp`, so Athena silently reads two
  different semantics across partitions. **Root cause found:** `historian-append.sh`
  line ~230 does `TRY_CAST(ts_value AS TIMESTAMP)`, which strips the tz annotation.
  The legacy `historian-unload.sh` used `SELECT *`, preserving `timestamptz`.

- **The audit's "34 deviations" — I found the 34th the category breakdown omitted.**
  The prior audit enumerated 20 + 8 + 2 + 1 + 2 = **33**. The missing 34th is
  **`id_production_order`: analytics `int4` → historian `bigint`** (a silent
  *widening*). Full reconciliation in §1.3.

- **`equipment_events` Glue table exists but holds ZERO data.**
  `aws s3 ls s3://…/equipment_events --recursive` → **0 parquet files**; the bucket
  root lists only `equipment_values/`. The events Glue table (24 cols) is DDL-only
  and was created **via CLI, not terraform** (no `equipment_events` resource in
  `terraform/staging/historian.tf`). So the events re-unload is a *first* unload,
  and it must be codified.

- **File health:** 961 EV objects, ~10 GB total, **avg 10.7 MB**, **82 % (791/961)
  under 16 MB**, **509 under 1 MB**, **0 in the ideal 128 MB–1 GB band**. 835 legacy
  monthlies + 126 live dailies (`data-YYYY-MM-DD.parquet`, ~1.6 KB each).

---

## 1. Canonical RAW schema — `equipment_values`

**Canonical column order = analytics `ordinal_position` (1…58).** Today the Parquet
and Glue order is *historian-legacy* order (`ts_value` first, `id_equipment` fifth),
which differs from analytics (`id_equipment` first, `ts_value` second). Athena reads
Parquet by **column name**, so reorder is non-breaking for Athena/the gateway; we
reorder anyway so positional tools (Spark, `duckdb read_parquet` positional access)
and human diffing see one consistent shape.

**Type-mapping legend (PG → Parquet/Hive canonical):**
`int4→int`, `int8→bigint`, `float4(real)→float`, `float8→double`, `varchar→string`,
`date→date`, `timestamptz→timestamp` **stored as a UTC instant (`isAdjustedToUTC=1`)**,
`jsonb→string` **(serialized JSON; the one unavoidable representational gap — see §1.2)**.

### 1.1 The full 58-column contract

| # | column | analytics type | current historian (Glue/Parquet) | **canonical target** | rationale |
|---:|---|---|---|---|---|
| 1 | `id_equipment` | int4 | int | **int** | match |
| 2 | `ts_value` | timestamptz | timestamp (legacy UTC=1 / live UTC=0) | **timestamp, UTC instant (isAdjustedToUTC=1)** | fix TZ split; Hive has no tz type — store UTC, document it (§1.2) |
| 3 | `id_enterprise` | int4 | int | **int** | match |
| 4 | `id_site` | int4 | int | **int** | match |
| 5 | `id_area` | int4 | int | **int** | match |
| 6 | `net_production_incr` | real | double | **float** | revert widening → match analytics; gateway casts `::double` anyway |
| 7 | `gross_production_incr` | real | double | **float** | revert widening |
| 8 | `scrap_incr` | real | double | **float** | revert widening |
| 9 | `speed` | real | float | **float** | match |
| 10 | `id_order` | varchar | string | **string** | match |
| 11 | `conversion_factor` | real | float | **float** | match |
| 12 | `number_cavities` | int4 | int | **int** | match |
| 13 | `faults` | jsonb | string | **string (JSON)** | Parquet has no jsonb — store `jsonb::text` (§1.2) |
| 14 | `analogs` | jsonb | string | **string (JSON)** | same as `faults` |
| 15 | `signal_quality` | int4 | smallint | **int** | revert narrowing → match analytics |
| 16 | `net_production_val` | real | double | **float** | revert widening |
| 17 | `gross_production_val` | real | double | **float** | revert widening |
| 18 | `scrap_val` | real | double | **float** | revert widening |
| 19 | `id_shift` | int4 | int | **int** | match |
| 20 | `id_team` | int4 | int | **int** | match |
| 21 | `id_shift_hour` | int4 | int | **int** | match |
| 22 | `box_code` | varchar | string | **string** | match |
| 23 | `transaction_code` | varchar | string | **string** | match |
| 24 | `state` | int4 | int | **int** | match |
| 25 | `mode` | int4 | int | **int** | match |
| 26 | `id_production_order` | int4 | **bigint** | **int** | revert widening → match analytics (**the 34th deviation**) |
| 27 | `ts_value_production` | date | date | **date** | match |
| 28 | `id_equipment_line_infeed` | int4 | int | **int** | match |
| 29 | `id_equipment_line_outfeed` | int4 | int | **int** | match |
| 30 | `net_production_incr_quality` | int4 | smallint | **int** | revert narrowing |
| 31 | `gross_production_incr_quality` | int4 | smallint | **int** | revert narrowing |
| 32 | `scrap_incr_quality` | int4 | smallint | **int** | revert narrowing |
| 33 | `speed_quality` | int4 | smallint | **int** | revert narrowing |
| 34 | `id_order_quality` | **varchar** ⚠️ | smallint | **int** | ⚠️ **WRONG-TYPE analytics smell** — a `_quality` code is an int everywhere else; canonical `int`, **analytics needs the same fix (varchar→int)** |
| 35 | `conversion_factor_quality` | int4 | smallint | **int** | revert narrowing |
| 36 | `number_cavities_quality` | int4 | smallint | **int** | revert narrowing |
| 37 | `net_production_val_quality` | int4 | smallint | **int** | revert narrowing |
| 38 | `gross_production_val_quality` | int4 | smallint | **int** | revert narrowing |
| 39 | `scrap_val_quality` | int4 | smallint | **int** | revert narrowing |
| 40 | `id_shift_quality` | int4 | smallint | **int** | revert narrowing |
| 41 | `state_quality` | int4 | smallint | **int** | revert narrowing |
| 42 | `mode_quality` | int4 | smallint | **int** | revert narrowing |
| 43 | `id_production_order_quality` | int4 | smallint | **int** | revert narrowing |
| 44 | `ts_value_production_quality` | **date** ⚠️ | smallint | **int** | ⚠️ **WRONG-TYPE analytics smell** — a `_quality` code is an int, not a date; canonical `int`, **analytics needs the same fix (date→int)** |
| 45 | `id_equipment_line_connected` | int4 | int | **int** | match |
| 46 | `position_in_equipment_line` | int4 | smallint | **int** | revert narrowing |
| 47 | `is_equipment_line_infeed` | int4 | smallint | **int** | revert narrowing |
| 48 | `is_equipment_line_outfeed` | int4 | smallint | **int** | revert narrowing |
| 49 | `process_scrap_incr` | real | double | **float** | revert widening |
| 50 | `process_scrap_val` | real | double | **float** | revert widening |
| 51 | `process_scrap_incr_quality` | int4 | smallint | **int** | revert narrowing |
| 52 | `process_scrap_val_quality` | int4 | smallint | **int** | revert narrowing |
| 53 | `tp_equipment` | int4 | smallint | **int** | revert narrowing |
| 54 | `sub_mode` | varchar | string | **string** | match |
| 55 | `ideal_production_speed` | int4 | int | **int** | match |
| 56 | `check_number` | int8 | bigint | **bigint** | match |
| 57 | `ingested_at` | timestamptz | **(MISSING)** | **timestamp, UTC instant** | **ADD** — replay/idempotency lineage |
| 58 | `source_seq` | int8 | **(MISSING)** | **bigint** | **ADD** — monotonic per-source ordering key for dedup |

### 1.2 Two irreducible representational notes (not "deviations")

- **`ts_value` / `ingested_at` (timestamptz → Hive `timestamp`).** The Hive/Glue
  metastore type Glue emits is `timestamp`; there is no `timestamptz` column type.
  The correct, portable pattern for a raw archive of a UTC-stored `timestamptz` is:
  **write the Parquet physical value as a UTC instant** (`INT64 TIMESTAMP_MICROS`,
  `isAdjustedToUTC=1`) and **contractually document that all historian timestamps are
  UTC.** This preserves the instant losslessly (TimescaleDB already stores UTC
  internally). The bug today is *not* the Hive type — it is that the **live append
  writes `isAdjustedToUTC=0`** while the legacy backfill wrote `=1`. §3 fixes the
  writer so both agree on `=1`.

- **`faults` / `analogs` (jsonb → `string`).** Parquet/Hive/Athena have no first-class
  `jsonb`. The canonical target is `string` **carrying serialized canonical JSON**
  (`jsonb::text`, which round-trips losslessly). This is the *only* column pair where
  the historian cannot mirror analytics' logical type — a Parquet limitation, not a
  choice. Contract: readers use `json_extract`/`json_value`; the writer must emit
  `CAST(col AS VARCHAR)` of a `jsonb` (never a Postgres `text` of a non-jsonb).

### 1.3 Deviation reconciliation (proves all 34 are accounted for)

| category | count | columns (#) |
|---|---:|---|
| int4 → smallint (narrowing) | 20 | 15, 30, 31, 32, 33, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46, 47, 48, 51, 52, 53 |
| real → double (widening) | 8 | 6, 7, 8, 16, 17, 18, 49, 50 |
| jsonb → string | 2 | 13, 14 |
| timestamptz → timestamp (TZ) | 1 | 2 |
| wrong-type (analytics smell) | 2 | 34, 44 |
| **int4 → bigint (widening)** | **1** | **26 `id_production_order`** ← *the 34th, missing from the audit breakdown* |
| **TOTAL type deviations** | **34** | |
| + missing columns | 2 | 57 `ingested_at`, 58 `source_seq` |
| + column-order mismatch | (all) | canonical = analytics ordinal 1…58 |

**On the narrowing (int4→smallint) risk:** semantically every affected column is a
small code (`tp_equipment` 1–3, `*_quality` flags, `is_line_*` 0/1, `signal_quality`
0–100) so `smallint` would *not* overflow in practice. We still revert to `int`
because the **contract rule is "match analytics"** — uniformity beats a
storage micro-optimization (ZSTD compresses the extra 2 bytes to nearly nothing),
and it removes any theoretical overflow foot-gun for free.

---

## 2. Canonical RAW schema — `equipment_events`

Analytics has 26 columns; the Glue table has 24 (missing `ingested_at`,`source_seq`).
**Column order already matches analytics** — the only EV-style reorder is *not* needed
here. Deviations are limited to the 3 timestamps + the 2 missing columns.

| # | column | analytics type | current Glue | **canonical target** | rationale |
|---:|---|---|---|---|---|
| 1 | `id_equipment` | int4 | int | **int** | match |
| 2 | `ts_event` | timestamptz | timestamp | **timestamp, UTC instant (isAdjustedToUTC=1)** | fix TZ (same class as `ts_value`) |
| 3 | `status` | int4 | int | **int** | match |
| 4 | `id_equipment_event` | int8 | bigint | **bigint** | match |
| 5 | `txt_downtime_notes` | varchar | string | **string** | match |
| 6 | `idle` | varchar | string | **string** | match |
| 7 | `idle_processed` | bool | boolean | **boolean** | match |
| 8 | `forced_creation_system` | bool | boolean | **boolean** | match |
| 9 | `fault` | int4 | int | **int** | match |
| 10 | `fault_processed` | bool | boolean | **boolean** | match |
| 11 | `cd_machine` | varchar | string | **string** | match |
| 12 | `cd_category` | varchar | string | **string** | match |
| 13 | `cd_subcategory` | varchar | string | **string** | match |
| 14 | `change_over` | bool | boolean | **boolean** | match |
| 15 | `planned_downtime` | bool | boolean | **boolean** | match |
| 16 | `ts_end` | timestamptz | timestamp | **timestamp, UTC instant** | fix TZ |
| 17 | `duration` | int4 | int | **int** | match |
| 18 | `id_enterprise` | int4 | int | **int** | match |
| 19 | `desc_category` | varchar | string | **string** | match |
| 20 | `desc_subcategory` | varchar | string | **string** | match |
| 21 | `cd_category_client` | int4 | int | **int** | match |
| 22 | `cd_subcategory_client` | int4 | int | **int** | match |
| 23 | `last_update` | timestamptz | timestamp | **timestamp, UTC instant** | fix TZ |
| 24 | `ignore_cost` | bool | boolean | **boolean** | match |
| 25 | `ingested_at` | timestamptz | **(MISSING)** | **timestamp, UTC instant** | **ADD** |
| 26 | `source_seq` | int8 | **(MISSING)** | **bigint** | **ADD** |

**Deviations:** 3 timestamptz→timestamp (`ts_event`,`ts_end`,`last_update`) + 2 missing
(`ingested_at`,`source_seq`). No narrowing/widening/jsonb issues. Since the table holds
**zero data**, the first "re-unload" is really the first unload (§3.3) and can be born
correct.

---

## 3. Corrected Glue table DDL

Source of truth = `terraform/staging/historian.tf` (`local.historian_ev_columns` →
`aws_glue_catalog_table.equipment_values`). Two edits: (a) fix the EV column types +
order below, (b) **add a codified `equipment_events` table** (today created out-of-band
via CLI — a codification gap). Partition projection is preserved verbatim.

> **Projection-range drift to fix while here:** the *deployed* EV table has
> `projection.enterprise.range = "0,120"` and `projection.year.range = "1970,2027"`,
> but terraform still says `"1,100"` / `"2019,2027"`. Data exists at `enterprise=0`,
> so widen terraform to the deployed values (below) to end the drift.

### 3.1 `equipment_values` — canonical Glue DDL (Athena `CREATE EXTERNAL TABLE` form)

```sql
CREATE EXTERNAL TABLE packiot_historian_staging.equipment_values (
  id_equipment                   int,
  ts_value                       timestamp,   -- UTC instant (isAdjustedToUTC=1)
  id_enterprise                  int,
  id_site                        int,
  id_area                        int,
  net_production_incr            float,
  gross_production_incr          float,
  scrap_incr                     float,
  speed                          float,
  id_order                       string,
  conversion_factor              float,
  number_cavities                int,
  faults                         string,      -- serialized JSON (jsonb::text)
  analogs                        string,      -- serialized JSON (jsonb::text)
  signal_quality                 int,
  net_production_val             float,
  gross_production_val           float,
  scrap_val                      float,
  id_shift                       int,
  id_team                        int,
  id_shift_hour                  int,
  box_code                       string,
  transaction_code               string,
  state                          int,
  mode                           int,
  id_production_order            int,
  ts_value_production            date,
  id_equipment_line_infeed       int,
  id_equipment_line_outfeed      int,
  net_production_incr_quality    int,
  gross_production_incr_quality  int,
  scrap_incr_quality             int,
  speed_quality                  int,
  id_order_quality               int,         -- analytics is varchar (smell) → int here
  conversion_factor_quality      int,
  number_cavities_quality        int,
  net_production_val_quality     int,
  gross_production_val_quality   int,
  scrap_val_quality              int,
  id_shift_quality               int,
  state_quality                  int,
  mode_quality                   int,
  id_production_order_quality    int,
  ts_value_production_quality    int,          -- analytics is date (smell) → int here
  id_equipment_line_connected    int,
  position_in_equipment_line     int,
  is_equipment_line_infeed       int,
  is_equipment_line_outfeed      int,
  process_scrap_incr             float,
  process_scrap_val              float,
  process_scrap_incr_quality     int,
  process_scrap_val_quality      int,
  tp_equipment                   int,
  sub_mode                       string,
  ideal_production_speed         int,
  check_number                   bigint,
  ingested_at                    timestamp,   -- UTC instant; ADDED
  source_seq                     bigint       -- ADDED
)
PARTITIONED BY (enterprise int, year int, month int)
STORED AS PARQUET
LOCATION 's3://packiot-staging-historian-639178078294/equipment_values/'
TBLPROPERTIES (
  'classification'='parquet',
  'parquet.compression'='ZSTD',
  'projection.enabled'='true',
  'projection.enterprise.type'='integer',  'projection.enterprise.range'='0,120',
  'projection.year.type'='integer',        'projection.year.range'='1970,2027',
  'projection.month.type'='integer',       'projection.month.range'='1,12',
  'storage.location.template'=
    's3://packiot-staging-historian-639178078294/equipment_values/enterprise=${enterprise}/year=${year}/month=${month}/'
);
```

### 3.2 Terraform edit (the codified form)

In `terraform/staging/historian.tf`, replace the `local.historian_ev_columns` list so
its order + types match §3.1 (reorder to analytics ordinal; `double→float` on the 8
production cols; `smallint→int` on the 20 quality/flag cols + the 2 smells;
`bigint→int` on `id_production_order`; append `ingested_at` `timestamp` and
`source_seq` `bigint`), and bump the two projection ranges to `0,120` / `1970,2027`.
Everything else in the resource (serde, input/output format, partition keys) stays.

### 3.3 `equipment_events` — codified Glue DDL (NEW — add to terraform)

```sql
CREATE EXTERNAL TABLE packiot_historian_staging.equipment_events (
  id_equipment            int,
  ts_event                timestamp,   -- UTC instant
  status                  int,
  id_equipment_event      bigint,
  txt_downtime_notes      string,
  idle                    string,
  idle_processed          boolean,
  forced_creation_system  boolean,
  fault                   int,
  fault_processed         boolean,
  cd_machine              string,
  cd_category             string,
  cd_subcategory          string,
  change_over             boolean,
  planned_downtime        boolean,
  ts_end                  timestamp,   -- UTC instant
  duration                int,
  id_enterprise           int,
  desc_category           string,
  desc_subcategory        string,
  cd_category_client      int,
  cd_subcategory_client   int,
  last_update             timestamp,   -- UTC instant
  ignore_cost             boolean,
  ingested_at             timestamp,   -- UTC instant; ADDED
  source_seq              bigint       -- ADDED
)
PARTITIONED BY (enterprise int, year int, month int)
STORED AS PARQUET
LOCATION 's3://packiot-staging-historian-639178078294/equipment_events/'
TBLPROPERTIES (
  'classification'='parquet',
  'parquet.compression'='ZSTD',
  'projection.enabled'='true',
  'projection.enterprise.type'='integer',  'projection.enterprise.range'='0,120',
  'projection.year.type'='integer',        'projection.year.range'='1970,2027',
  'projection.month.type'='integer',       'projection.month.range'='1,12',
  'storage.location.template'=
    's3://packiot-staging-historian-639178078294/equipment_events/enterprise=${enterprise}/year=${year}/month=${month}/'
);
```

> Note the deployed EV `LOCATION` has a trailing slash and the EE one does not — make
> both trailing-slash consistent (as above) when re-applied.

---

## 4. Re-unload plan (regenerate Parquet in the canonical shape)

**Principle:** the unload SELECT must *project + cast to the §1/§2 canonical types, in
canonical order*, and fix the two writer bugs (TZ annotation; missing lineage cols).
This replaces the current "project to the Glue-legacy shape" logic in
`scripts/historian-append.sh` and `scripts/historian-unload.sh`.

### 4.1 The three writer fixes (apply to both backfill + append)

1. **TZ:** stop stripping the zone. Set the DuckDB session to UTC and cast to
   `TIMESTAMPTZ` (not `TIMESTAMP`) so the Parquet logical type is written with
   `isAdjustedToUTC=1`:
   ```sql
   SET TimeZone='UTC';
   ...
   CAST(ts_value AS TIMESTAMPTZ)  AS ts_value,   -- was: TRY_CAST(ts_value AS TIMESTAMP)
   ```
   (DuckDB writes `TIMESTAMP WITH TIME ZONE` as `isAdjustedToUTC=1` micros — matches
   the legacy backfill and the `timestamptz` source instant.)
2. **Types:** `DOUBLE→FLOAT` on the 8 production cols; `SMALLINT→INTEGER` on the 20
   quality/flag cols; `BIGINT→INTEGER` on `id_production_order`. The 2 smells stay
   `TRY_CAST(... AS INTEGER)` (F3 `id_order_quality` varchar → int-or-NULL;
   `ts_value_production_quality` date → NULL, which correctly flags the bad source type).
3. **Add lineage + reorder:** append `ingested_at` (as `TIMESTAMPTZ`) and `source_seq`
   (`BIGINT`) and emit columns in canonical analytics order. For the **legacy backfill**
   (source `packiot40` PG12, which has neither column) set
   `CAST(NULL AS TIMESTAMPTZ) AS ingested_at, CAST(NULL AS BIGINT) AS source_seq`
   (or `source_seq = id_equipment_event` if a monotonic surrogate is wanted); document
   that legacy rows carry NULL lineage by construction.

### 4.2 Canonical unload SELECT (equipment_values, new-prod F3 source)

```sql
SET TimeZone='UTC';
COPY (
  SELECT
    TRY_CAST(id_equipment AS INTEGER)                AS id_equipment,
    CAST(ts_value AS TIMESTAMPTZ)                    AS ts_value,        -- UTC, isAdjustedToUTC=1
    TRY_CAST(id_enterprise AS INTEGER)               AS id_enterprise,
    TRY_CAST(id_site AS INTEGER)                     AS id_site,
    TRY_CAST(id_area AS INTEGER)                     AS id_area,
    TRY_CAST(net_production_incr   AS FLOAT)         AS net_production_incr,   -- was DOUBLE
    TRY_CAST(gross_production_incr AS FLOAT)         AS gross_production_incr,
    TRY_CAST(scrap_incr           AS FLOAT)          AS scrap_incr,
    TRY_CAST(speed AS FLOAT)                         AS speed,
    CAST(id_order AS VARCHAR)                        AS id_order,
    TRY_CAST(conversion_factor AS FLOAT)            AS conversion_factor,
    TRY_CAST(number_cavities AS INTEGER)            AS number_cavities,
    CAST(faults  AS VARCHAR)                         AS faults,          -- jsonb::text
    CAST(analogs AS VARCHAR)                         AS analogs,
    TRY_CAST(signal_quality AS INTEGER)             AS signal_quality,  -- was SMALLINT
    TRY_CAST(net_production_val   AS FLOAT)          AS net_production_val,     -- was DOUBLE
    TRY_CAST(gross_production_val AS FLOAT)          AS gross_production_val,
    TRY_CAST(scrap_val           AS FLOAT)          AS scrap_val,
    TRY_CAST(id_shift AS INTEGER)                   AS id_shift,
    TRY_CAST(id_team AS INTEGER)                    AS id_team,
    TRY_CAST(id_shift_hour AS INTEGER)             AS id_shift_hour,
    CAST(box_code AS VARCHAR)                        AS box_code,
    CAST(transaction_code AS VARCHAR)              AS transaction_code,
    TRY_CAST(state AS INTEGER)                      AS state,
    TRY_CAST(mode AS INTEGER)                       AS mode,
    TRY_CAST(id_production_order AS INTEGER)        AS id_production_order,     -- was BIGINT
    TRY_CAST(ts_value_production AS DATE)           AS ts_value_production,
    TRY_CAST(id_equipment_line_infeed  AS INTEGER) AS id_equipment_line_infeed,
    TRY_CAST(id_equipment_line_outfeed AS INTEGER) AS id_equipment_line_outfeed,
    TRY_CAST(net_production_incr_quality   AS INTEGER) AS net_production_incr_quality,  -- 20× was SMALLINT
    TRY_CAST(gross_production_incr_quality AS INTEGER) AS gross_production_incr_quality,
    TRY_CAST(scrap_incr_quality AS INTEGER)        AS scrap_incr_quality,
    TRY_CAST(speed_quality AS INTEGER)             AS speed_quality,
    TRY_CAST(id_order_quality AS INTEGER)          AS id_order_quality,        -- F3 varchar → int-or-NULL
    TRY_CAST(conversion_factor_quality AS INTEGER) AS conversion_factor_quality,
    TRY_CAST(number_cavities_quality AS INTEGER)   AS number_cavities_quality,
    TRY_CAST(net_production_val_quality AS INTEGER) AS net_production_val_quality,
    TRY_CAST(gross_production_val_quality AS INTEGER) AS gross_production_val_quality,
    TRY_CAST(scrap_val_quality AS INTEGER)         AS scrap_val_quality,
    TRY_CAST(id_shift_quality AS INTEGER)          AS id_shift_quality,
    TRY_CAST(state_quality AS INTEGER)             AS state_quality,
    TRY_CAST(mode_quality AS INTEGER)              AS mode_quality,
    TRY_CAST(id_production_order_quality AS INTEGER) AS id_production_order_quality,
    TRY_CAST(ts_value_production_quality AS INTEGER) AS ts_value_production_quality, -- F3 date → NULL
    TRY_CAST(id_equipment_line_connected AS INTEGER) AS id_equipment_line_connected,
    TRY_CAST(position_in_equipment_line AS INTEGER) AS position_in_equipment_line,
    TRY_CAST(is_equipment_line_infeed  AS INTEGER)  AS is_equipment_line_infeed,
    TRY_CAST(is_equipment_line_outfeed AS INTEGER)  AS is_equipment_line_outfeed,
    TRY_CAST(process_scrap_incr AS FLOAT)          AS process_scrap_incr,       -- was DOUBLE
    TRY_CAST(process_scrap_val  AS FLOAT)          AS process_scrap_val,
    TRY_CAST(process_scrap_incr_quality AS INTEGER) AS process_scrap_incr_quality,
    TRY_CAST(process_scrap_val_quality  AS INTEGER) AS process_scrap_val_quality,
    TRY_CAST(tp_equipment AS INTEGER)              AS tp_equipment,             -- was SMALLINT
    CAST(sub_mode AS VARCHAR)                       AS sub_mode,
    TRY_CAST(ideal_production_speed AS INTEGER)    AS ideal_production_speed,
    TRY_CAST(check_number AS BIGINT)               AS check_number,
    CAST(ingested_at AS TIMESTAMPTZ)               AS ingested_at,             -- ADDED (NULL for legacy source)
    TRY_CAST(source_seq AS BIGINT)                 AS source_seq              -- ADDED (NULL for legacy source)
  FROM day
) TO '${DEST}' (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 122880);
```

The equipment_events unload is the same shape against §2 (only `ts_event`,`ts_end`,
`last_update`,`ingested_at` need `CAST(... AS TIMESTAMPTZ)`; everything else is a
straight typed projection; legacy source → NULL lineage).

### 4.3 Roll-out ordering (so nothing reads a half-migrated table)

1. **Apply the Glue DDL first** (§3) — Athena reads Parquet by name, so a widened Glue
   type (e.g. `int`) over old Parquet that is physically `smallint` **up-casts cleanly**;
   the reverse (narrow Glue over wide Parquet) would not. Widening the catalog first is
   therefore safe during the transition.
2. **Re-unload legacy backfill** to a staging prefix, `duckdb DESCRIBE` a sample to
   assert it byte-matches §1, then swap in place (same `*-legacy.parquet` keys).
3. **Re-unload / heal new-prod appends** for the retained window (the append job's own
   `OVERLAP_DAYS` idempotency makes each day a deterministic re-writable key).
4. **First-ever events unload** (§3.3 table + §4 SELECT).
5. Keep the append job's **`HISTORIAN_APPEND_ENABLED` gate** respected — do not enable
   the prod timer until the ADR-0045 P1 decode-spike fix is confirmed live (per the
   script header), else the canonical re-unload re-archives spikes.

---

## 5. File compaction plan

**Observed (hardproof §0):** 961 EV objects, 82 % < 16 MB, 509 < 1 MB, **0 in
128 MB–1 GB**, 835 `*-legacy.parquet` monthlies + 126 `data-YYYY-MM-DD.parquet` dailies
(~1.6 KB each). The many-tiny-files tax is S3 `LIST` + per-file Parquet footer opens on
every Athena/gateway scan, not raw bytes.

### 5.1 Target grain = **one file per `enterprise/year/month` partition**

Partition projection pins the physical layout at `enterprise/year/month`, so a file
**cannot** span months — the compaction floor is *monthly*. For low-volume tenants a
monthly file is naturally well under 128 MB; that is fine — the 128 MB–1 GB "ideal band"
only applies to high-volume tenants (e.g. CPACK `enterprise=3`). The real win is
collapsing the 126 KB-sized dailies into ~monthly files and guaranteeing 1 file/partition.

### 5.2 The daily→monthly roll (and the gateway trap)

**Critical coupling:** the gateway `hist` view globs **only `*-legacy.parquet`**
(`read_parquet('.../equipment_values/*/*/*/*-legacy.parquet')`) precisely so the
post-cutover append files are *not* double-counted against the live FDW. Therefore:

- **Compacted daily files MUST NOT be named `*-legacy.parquet`.** Roll
  `data-YYYY-MM-DD.parquet` → **`data-YYYY-MM.parquet`** (monthly, non-legacy). They
  stay invisible to `ev_all` (correct — live data comes from the FDW) while still being
  a clean archival copy.
- **Leave `*-legacy.parquet` monthlies untouched** — they are already 1 file/partition
  and are the union's cold side.

Per-partition compaction (idempotent; verify-then-delete):

```sql
-- for each enterprise=E/year=Y/month=M partition that has >1 daily file:
SET TimeZone='UTC';
COPY (
  SELECT *                       -- already canonical after §4 re-unload
  FROM read_parquet('s3://<bucket>/equipment_values/enterprise=E/year=Y/month=M/data-Y-M-*.parquet')
) TO 's3://<bucket>/equipment_values/enterprise=E/year=Y/month=M/data-Y-M.parquet'
  (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 122880);
-- assert: rows(monthly) == sum(rows(dailies)); only then:
--   aws s3 rm the data-Y-M-DD.parquet dailies
```

### 5.3 Guardrails

- **Compact only after §4 re-unload** so the merged file is already canonical (never
  compact old-shape dailies into a monthly — you'd freeze the deviations).
- **Row-count parity gate** before deleting sources; keep S3 versioning (already on the
  bucket) as the undo.
- **Row groups:** keep `ROW_GROUP_SIZE 122880`; for any monthly that does exceed ~1 GB
  (only the busiest tenant-months), let DuckDB split naturally or cap via multiple row
  groups — Athena prunes at the row-group level regardless.
- **Ongoing:** after this one-time compaction, the append timer keeps writing dailies;
  schedule a monthly "seal last month" compaction (roll the prior month's dailies into
  its `data-YYYY-MM.parquet`) so the tiny-file count never regrows.

---

## 6. Gateway coupling — verified UNAFFECTED

`services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh` builds:

```sql
CREATE OR REPLACE VIEW hist AS
SELECT r['ts_value']::timestamp               AS ts_value,
       r['enterprise']::int                   AS id_enterprise,   -- from the HIVE PARTITION
       r['id_equipment']::int                 AS id_equipment,
       r['gross_production_incr']::double precision AS gross_production_incr,
       r['net_production_incr']::double precision   AS net_production_incr
FROM read_parquet('s3://.../equipment_values/*/*/*/*-legacy.parquet', hive_partitioning => true) r;

CREATE OR REPLACE VIEW ev_all AS
  SELECT ts_value, id_enterprise, id_equipment, gross_production_incr, net_production_incr
    FROM live.equipment_values
  UNION ALL
  SELECT ts_value, id_enterprise, id_equipment, gross_production_incr, net_production_incr
    FROM hist;
```

The union touches exactly **5 identifiers**. Checked against the canonical schema:

| union column | how gateway reads it | canonical guarantee | safe? |
|---|---|---|---|
| `ts_value` | `r['ts_value']::timestamp` | name kept; UTC instant is castable to `timestamp` (the UTC=1 fix makes it *more* correct, not breaking) | ✅ |
| `id_enterprise` | from **hive partition** `r['enterprise']` (not the file column) | partition keys `enterprise/year/month` preserved verbatim | ✅ |
| `id_equipment` | `r['id_equipment']::int` | name kept, `int` | ✅ |
| `gross_production_incr` | `r['...']::double precision` | name kept; canonical reverts `double→float`, but `float → double precision` is a **lossless up-cast** the view already performs | ✅ |
| `net_production_incr` | `r['...']::double precision` | same as above | ✅ |

All five are **name-based** reads, so the §1 **column reorder is invisible** to the
gateway, and the `double→float` revert is absorbed by the view's existing
`::double precision` cast. The `hist` glob stays `*-legacy.parquet`, and §5 keeps
compacted files off that glob — **no double-count, no name/type break. The union is
unaffected.**

---

## 7. Follow-ups this design surfaces (not done here — read-only DESIGN)

1. **Re-unload EV** (legacy backfill + new-prod heal) to the canonical shape (§4). *Gated
   on ADR-0045 P1.*
2. **First-ever EE unload** (§3.3 + §4) — the events Glue table has zero data today.
3. **One-time EV compaction** (§5) + a monthly "seal last month" job.
4. **Analytics-side fixes (flagged):** `equipment_values.id_order_quality` `varchar→int`
   and `ts_value_production_quality` `date→int` — both are `_quality` codes wearing the
   wrong type at the *source*; the historian is merely inheriting the smell.
5. **Codify EE in terraform** (`aws_glue_catalog_table.equipment_events`) — today it
   exists only because it was created via CLI.
6. **Fix terraform projection drift** (`enterprise 1,100 → 0,120`; `year 2019 → 1970`)
   to match the deployed tables.
7. **Fix the live append writer** `TRY_CAST(ts_value AS TIMESTAMP)` → `CAST(... AS
   TIMESTAMPTZ)` (the `isAdjustedToUTC=0` root cause) and switch its whole projection
   from the Glue-legacy types to the §4 canonical types.
```
