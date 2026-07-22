# ADR-0036 — Data Architecture: a streaming Bronze/Silver/Gold medallion on Timescale, with an immutable historian tier

**Status:** Proposed · **Date:** 2026-07-22 · **Scope:** DESIGN ONLY (this ADR is the target architecture + migration plan; no code, no schema change ships with it). STAGING-first; any prod-touching step is explicitly gated. · **Decision owner:** data/platform architect (pending USER review).

**Companion ADR:** [ADR-0037 — OEE Correctness Remediation](0037-oee-correctness-remediation.md). **0037 is the "why now."** Every correctness finding in 0037 is slotted into a Bronze / Silver / Gold layer defined *here*; this ADR is the **structural home** those fixes live in. Read the two together: 0036 defines the layers, 0037 fills them.

**Builds on / honors:**
- [ADR-0009](0009-edge-transformer-go-service-and-nodered-split.md) / [ADR-0010](0010-sparkplug-decode-in-go-end-state.md) — the SparkPlug-decode-in-Go split. `edge-transformer` is the ingest boundary that produces what this ADR names **Bronze**.
- [ADR-0011](0011-durability-boundary-and-store-and-forward.md) — the durability boundary + store-and-forward. Bronze immutability is the *destination-side* completion of that same "never lose a raw sample" principle.
- [ADR-0014](0014-extract-oee-math-from-database-to-app.md) — extract OEE math from DB to app. That extraction is *half* the Silver layer; this ADR names the other half (invariants + validation) and gives both a home.
- [ADR-0012](0012-schema-refactor-and-multitenancy-pool.md) — schema refactor + tenancy pool. The `packiot_shadow` DB + `customer_dashboards` pool are the substrate the Gold plane serves from.
- [ADR-0032](0032-collapse-to-single-flow-f3.md) — collapse to a single flow (F3). This ADR assumes the F3 end-state topology (one processor → one worker → one served DB); the medallion is how F3 should be *layered internally*.

**Relates to:**
- [ADR-0027](0027-refdata-api-surface-1-read-contract.md) — refdata-api is the **Gold consumer**. The read contract binds to Gold tables/views; this ADR does not change that contract, it names what feeds it.
- [ADR-0015](0015-customer-facing-query-api.md) — customer query API, another Gold consumer.
- [ADR-0038 — North-Star target architecture](0038-north-star-factory-platform.md) — the medallion (esp. immutable Bronze + a named Silver) is the **substrate the north-star pillars stand on**; ADR-0037 §4A's `data_quality_event` (fed at the Silver→Gold boundary) is the seed of 0038's **P11-B2** business-alarm pillar.
- [ADR-0039 — Entity lifecycle & deletion strategy](0039-entity-lifecycle-deletion-strategy.md) — 0039 owns **dimension** temporal columns (SCD-2) + the entity-integrity contract (one delete path, restored FKs). This ADR generalizes the *same* temporal/lineage-column pattern to the **fact/metric** tables (Bronze/Gold — §5A) and flags the `packiot_shadow` FK regression (§5A note) that 0039 is the home for.

> **Numbering:** `0035` is allocated to a concurrent Redis-cache ADR. This is `0036`; its companion is `0037`.

---

## 1. Problem & context

The stack already *is* a medallion architecture — it just isn't **named, layered, or enforced** as one, and one layer (the immutable raw tier) is missing entirely. That un-named-ness is not cosmetic: it is the direct cause of the correctness bugs catalogued in ADR-0037. When there is no agreed "this is the layer where invariants live," invariants live nowhere; when there is no retained raw tier, a bug found today cannot be fixed for yesterday's data.

Concretely, trace one SparkPlug sample through the live F3 path and label what each stage *is*:

```
PLC ──SparkPlug B (MQTT)──▶ edge-transformer
    services/edge-transformer/internal/transforms/calc_production_counters/   ← count Calc (delta/reset/rollover)
        │  decode → alias-resolve → per-counter delta → emit increment
        ▼ RabbitMQ (oee exchange, sparkplug.data)
    oeecloud-worker
        internal/writers/equipment_values.go   → equipment_values  (raw metric time series)  ← THIS SHOULD BE BRONZE
        internal/rollup/{shift,hour,day,grains}.go → equipment_runtime_*   (OEE aggregates)   ← GOLD
        internal/uns/{current_metrics,uns}.go  → uns_*  (current-state namespace)              ← GOLD (served)
        ▼
    TimescaleDB (packiot_shadow)
        equipment_values (hypertable) · continuous aggregates (ca_*) · equipment_runtime_shift/_1hour/_1day/... · uns_*
        ▲
    refdata-api / Hasura / front4 / Grafana  ← consumers read GOLD
```

Map that to the medallion vocabulary:

| Medallion layer | What it is in *this* stack | Where it lives today | State today |
|-----------------|----------------------------|----------------------|-------------|
| **Bronze** (raw, immutable) | Decoded SparkPlug samples + events: `equipment_values`, `equipment_events` | `internal/writers/equipment_values.go` → `equipment_values` hypertable | **Exists but is NOT immutable and NOT retained** — no retention/compression policy (grep for `add_retention_policy`/`add_compression_policy` across `services/` + `edge-node-red/db/` returns **nothing**; `db/init/00-schema.sql:254` creates a bare `create_hypertable('equipment_values','ts_value')` with no policy). Rows are `ON CONFLICT (ts_value, id_equipment) DO UPDATE` overwritten (`internal/writers/equipment_values.go:359+`), and prod ages raw out via continuous aggregates. **Bronze is effectively ephemeral.** |
| **Silver** (clean, validated, conformed) | Delta/reset/rollover handling, dedup, dimensional conforming, **and the home of domain invariants** (0≤A,P,Q,OEE≤1; net≤gross; counter monotonicity; single-writer-per-tenant) | **Scattered.** Part in Go Calc (`calc_production_counters/calc.go`, `counter_math.go`), part in the legacy pg engine (`edge-node-red/db/20-oee-engine-parity.sql`), part nowhere. | **The invariants do not exist as a layer.** The only `[0,1]` clamps in the codebase are the *dead* dev-UNS `LEAST(...,1.0)` in `14-oee-uns-compute.sql:77,95` (a compose-dev sidecar, replaced by pg_cron in staging/prod). F1 (legacy) and F3 (Go) implement the cleaning logic *differently* — and **that divergence is exactly how the ADR-0037 bugs arose.** |
| **Gold** (served metrics) | OEE metrics for dashboards/refdata: `equipment_runtime_shift/_1hour/_1day/_1week/_1month`, `uns_*` | `internal/rollup/*.go`, `internal/uns/*.go` | Exists and is served; correctness bugs (ADR-0037) are *reflections* of missing Silver, surfaced here. |

**The two structural gaps, stated plainly:**

1. **No immutable Bronze → no reprocessing.** Because raw ages out into caggs and raw rows are overwritten in place, there is no way to "fix a bug in the Calc/rollup and replay history." Every ADR-0037 fix that changes how a number is *computed* (proportional target, performance cap, invariant clamps) can only ever apply *going forward* — the corrupted history stays corrupted. For an OEE product whose entire value is trustworthy historical trend, that is the deepest problem in the stack.

2. **No Silver layer → invariants live nowhere, and two engines disagree.** The delta/reset/rollover logic, the `[0,1]` bounds, `net≤gross`, monotonicity, single-writer — none of these has a designated home, so each is implemented ad hoc (or not at all) in whichever of the two engines happened to touch it. ADR-0037 is a list of the resulting divergences.

**This ADR fixes the *structure*. ADR-0037 fixes the *values* inside that structure.**

---

## 2. Decision

Adopt a **named, four-tier streaming medallion on TimescaleDB**, and **do not buy a dedicated historian** (PI / AVEVA / InfluxDB). Timescale already *is* the historian; the work is to *elevate* the raw tier to a proper immutable/retained Bronze and to *materialize* a Silver validation layer, not to add a new system.

### 2.1 The four tiers (target)

```
                         ┌──────────────────────────────────────────────────────────┐
   PLC ─SpB(MQTT)─▶      │  BRONZE  (immutable historian — retain, compress, append) │
                         │  equipment_values_raw · equipment_events_raw              │
   edge-transformer ────▶│  hypertables · compression after N days · retention M yr  │
   (decode only, NO      │  conceptually append-only; the REPLAY SOURCE OF TRUTH     │
    delta/reset logic)   └───────────────────────┬──────────────────────────────────┘
                                                 │  replayable
                         ┌───────────────────────▼──────────────────────────────────┐
                         │  SILVER  (clean · validate · conform · INVARIANTS)        │
   oeecloud-worker ─────▶│  delta/reset/rollover · dedup · single-writer · dim-conform│
   Calc + rollup, but    │  ENFORCE: 0≤A,P,Q,OEE≤1 · net≤gross · monotonic counters   │
   with invariants as    │  → equipment_values (cleaned) · equipment_events (cleaned) │
   a FIRST-CLASS stage    └───────────────────────┬──────────────────────────────────┘
                                                 │  aggregate
                         ┌───────────────────────▼──────────────────────────────────┐
   caggs / rollup ──────▶│  GOLD  (served OEE metrics)                               │
                         │  equipment_runtime_shift/_1hour/_1day/... · uns_* · ca_*  │
                         └───────────────────────┬──────────────────────────────────┘
                                                 │  read
                         refdata-api · Hasura · front4 · Grafana
                                                 │
                         ┌───────────────────────▼──────────────────────────────────┐
   OFFLINE only          │  LAKEHOUSE  (AWS-native: S3 + Glue + Athena)              │
   (batch, not live) ───▶│  Bronze/Silver/Gold parquet in S3 · Glue catalog ·        │
                         │  Athena serverless SQL · cq-logs · reports · ML           │
                         └──────────────────────────────────────────────────────────┘
```

### 2.2 Streaming flavor for the live path — **do not bolt on Spark/Delta**

The live medallion is **streaming**, and the streaming mechanism **already exists**: TimescaleDB **continuous aggregates are a streaming-medallion engine.** A cagg is exactly a Silver→Gold incremental materialization with a refresh policy — the same job Spark Structured Streaming + Delta Live Tables do in a Databricks lakehouse, done in-database. We **formalize** the caggs as the Silver→Gold streaming transform; we do **not** introduce Spark, Flink, Kafka Streams, or Delta Lake for the live path. That would add an entire distributed-systems substrate to reimplement what `equipment_values → ca_*_1min → ca_*_1hour → equipment_runtime_shift` already does.

**The offline lakehouse is for offline workloads ONLY:** ML feature extraction, long-horizon (multi-year) reporting, and the *existing* `cq-logs` and `reports` exports. It is fed *from Bronze* (the immutable tier is the natural export source), on a batch cadence, and is never in the live serving path. This keeps the operational hot path entirely in Timescale (low-latency, transactional, one system to operate) while giving data science a cheap columnar store without coupling it to production.

**And the offline tier is AWS-native — see §2.4. It replaces BigQuery.**

### 2.4 Offline/analytics tier is AWS-native (S3 + Glue + Athena) — replacing BigQuery — the "one cloud" principle

**Architectural principle: one cloud (AWS).** The whole stack has been walking off Google Cloud, and this ADR closes the last major GCP surface:

| GCP surface | AWS replacement | Status |
|-------------|-----------------|--------|
| Firebase Auth (JWT issuer) | AWS Cognito (via Amplify Auth) | [ADR-0034](0034-adopt-cognito-amplify-auth.md) — decided |
| GCP PubSub (message bus) | RabbitMQ (`oee` exchange) | Done in the new stack (edge-transformer → RMQ → oeecloud-worker) |
| `oeecloud-node-red` on GCP Compute (cloud OEE engine) | `oeecloud-worker` (Go) on AWS | Done in the new stack (this repo) |
| **BigQuery (offline analytics)** | **S3 + Glue + Athena** | **This ADR (§2.4)** |

With BigQuery replaced, the platform is **100% off GCP — single-cloud on AWS.** One cloud means one IAM model, one billing surface, one VPC/networking story, one set of credentials to rotate, and no cross-cloud egress cost or latency. For a small team operating a factory-critical stack, collapsing to one cloud is a material reduction in operational and security surface — the same "fewer moving parts" logic that says "don't buy a second historian" (§2.3).

**The offline lakehouse design (AWS-native):**

```
BRONZE (Timescale, immutable)  ──batch export (parquet)──▶  S3
                                                             │  s3://…/bronze/  s3://…/silver/  s3://…/gold/  (parquet, partitioned by tenant/date)
                                                             ▼
                                                     AWS Glue Data Catalog  (schema + partitions)
                                                             ▼
                                                     Amazon Athena  (serverless SQL, pay-per-query)
                                                             ▼
                                          cq-logs analytics · long-horizon OEE reports · ML feature extraction
```

- **S3** holds Bronze/Silver/Gold as **partitioned parquet** (columnar, compressed) — the object-storage lake. This is the *offline* mirror of the Timescale medallion, fed from the immutable Bronze tier on a batch cadence (never the live path).
- **AWS Glue Data Catalog** is the metadata/schema + partition registry (the Hive-metastore equivalent) — the table definitions Athena queries against. A Glue crawler or an explicit catalog keeps partitions current.
- **Amazon Athena** is the serverless, pay-per-query SQL engine over S3 — **the direct BigQuery analog**: no cluster to run, you pay per TB scanned, standard SQL. This is the recommended fit for a lake + reporting workload with spiky, ad-hoc query patterns.
- **Alternative — Redshift Serverless** — if a managed MPP data warehouse is ever wanted (heavy concurrent BI, complex joins, materialized workloads), Redshift Serverless is the AWS answer. **Recommendation: start with S3 + Athena** — it matches the lake-plus-batch-reporting shape, has no idle cost, and Redshift can be layered later (it can query the same S3 via Spectrum) if the workload outgrows Athena. Don't provision a warehouse before there's a warehouse-shaped workload.

**Why the migration is SMALL (current BigQuery footprint is minimal):**

- `cq-logs-bigquery` reads only the `cq_logs` dataset — a single, narrow pipeline. Its migration is a **client repoint**, not a rewrite: swap the BigQuery Python client for Athena via **`boto3`/`pyathena`**, and land `cq_logs` (and OEE history) as **parquet in S3** cataloged in Glue. Same SQL-over-columnar-data shape, different endpoint.
- `reports/` is **LaTeX-only** — it does not touch BigQuery at all, so it needs no data-tier change (it consumes whatever the report pipeline hands it; that upstream simply reads Athena/S3 instead of BigQuery).

So the *code* delta is one Python pipeline's client library + destination bucket. **The real value is not the size of today's cutover — it's choosing AWS-native for the FUTURE analytics/ML tier**, so every subsequent offline dataset (ML features, long-horizon OEE trend, cross-tenant benchmarking) is born on S3+Athena inside the one-cloud boundary instead of re-opening a GCP dependency. Migration step **L0** in §6 carries this.

**The live streaming path is unchanged** — it stays entirely on Timescale (§2.2). This subsection is *purely* about the offline/analytics tier going AWS-native; no hot-path component moves to S3/Athena.

### 2.3 Historian verdict — Timescale is the historian; UNS and historian coexist

**Do not buy a process historian.** OSIsoft PI / AVEVA / InfluxDB Enterprise solve "immutable, compressed, long-retention time-series with fast range scans" — which is *precisely* what a Timescale hypertable with a compression + retention policy is, and which we already operate at billions of rows (`mirror-worker-go/internal/db/prod.go:768` notes a 2.45B-row hypertable). Adding a second historian means a second ingest path, a second query dialect, a second ops burden, and a sync problem — for zero capability we don't already have. The **gap is not a missing product; it is a missing *policy*** on the hypertable we already have.

**UNS vs historian — they are different axes and coexist, not compete:**

| | Historian (Bronze/Gold time-series) | UNS (`uns_*` current-state namespace) |
|---|---|---|
| Question it answers | "what was value X at/over time T?" (history) | "what is the current state of X right now?" (latest) |
| Shape | append-only time series, many rows per entity | current snapshot, one row per (entity, metric) |
| Home | `equipment_values_raw` (Bronze), `equipment_runtime_*` (Gold) | `uns_metrics`, `uns_current_metrics` (`internal/uns/`) |
| Consumer | trend dashboards, reports, ML, reprocessing | live tiles, current-status displays |

The UNS is a **projection** (a `SELECT DISTINCT ON (entity) ... ORDER BY ts DESC` shape) computed *from* the historian; it is not a replacement for it and does not need its own storage engine. Both are Gold-served in our model; the historian additionally has the immutable Bronze substrate beneath it.

---

## 3. Bronze in detail — the immutable historian tier

Bronze is the load-bearing new idea, so it gets the most design.

### 3.1 What changes conceptually

- **Append-only semantics.** Bronze rows are written once and never updated. Today `equipment_values` is upserted (`ON CONFLICT ... DO UPDATE`, `internal/writers/equipment_values.go:359`), which *destroys* the raw record when a late/duplicate arrives — you can never reconstruct "what actually came off the wire." Bronze must **keep every decoded sample** (see §3.4 on the sub-second collision, which is the same wound as ADR-0037 finding (g)).
- **Separable from operational tables.** Bronze is a distinct concern from the mutable Gold rollups. It can be its own hypertable(s) (`equipment_values_raw`, `equipment_events_raw`) or, at minimum, the current `equipment_values` hypertable governed by immutability + retention policy and never overwritten. Physical separation (own tables, possibly own tablespace/retention) makes the immutability guarantee auditable and lets Bronze retention (years) differ from Gold cagg retention (as needed).
- **Retained long, compressed after warm.** Bronze is the reprocessing source of truth, so it must outlive the operational window. Retention measured in **years**, not the current *implicit "until the cagg has consumed it"*.

### 3.2 Retention / compression policy sketch (Timescale, illustrative — tune per tenant volume)

```sql
-- BRONZE raw metrics — compress warm chunks, retain long.
-- (design sketch; exact windows are a per-tenant capacity decision, NOT fixed here)
SELECT add_compression_policy('equipment_values_raw', compress_after => INTERVAL '7 days');
ALTER TABLE equipment_values_raw SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'id_equipment',
  timescaledb.compress_orderby   = 'ts_value DESC'
);
SELECT add_retention_policy('equipment_values_raw', drop_after => INTERVAL '2 years');  -- historian horizon

-- GOLD rollups keep their own, shorter, policy — already hypertables
-- (10-missing-tables.sql:327/367 create equipment_runtime_shift/_1hour as hypertables today).
```

Compression on a segment-by-`id_equipment` layout gives PI-class storage economics (10–20× typical on totalizer/metric columns) while keeping range scans fast — the exact tradeoff a process historian sells, native in Timescale. **None of this exists today** (no policy calls anywhere in the repo), which is the entire gap.

### 3.3 The reprocessing story (why Bronze is worth it)

This is the payoff. With an immutable Bronze:

```
bug found in Silver/Gold compute (e.g. ADR-0037 (a) full-shift target, (d) uncapped performance)
        │
        ▼  fix the Calc/rollup code (ADR-0037)
        │
        ▼  REPLAY: re-run Silver+Gold transforms over Bronze for the affected window+tenants
        │        (bounded, idempotent backfill — the rollup already has a recalc_needed
        │         re-flag mechanism: shift.go:198 shiftReflagSQL, grains.go:109 grainReflagSQL)
        ▼
   corrected history — yesterday's OEE is now right, not just tomorrow's
```

Without Bronze, every ADR-0037 fix is *forward-only* and the historical record stays wrong. The rollup layer **already has the re-flag/recalc scaffolding** (`recalc_needed=true` re-flag windows in `shift.go`/`grains.go`, `internal/rollup/recalc.go`, `backfill.go`) — what's missing is the *durable raw source* to replay Silver *from*. Bronze closes that loop. **Reprocessing is the single most important capability this ADR unlocks**, and it is why "just add invariants to the Go code" (ADR-0037 alone) is insufficient without the structural change here.

### 3.4 Bronze immutability vs the sub-second overwrite (ADR-0037 finding g)

`equipment_values` keys on `UNIQUE(ts_value, id_equipment)` with `ts_value` at 1-second resolution, so two samples from the same fast line inside one second collide and the second **overwrites** the first (`ON CONFLICT DO UPDATE`) → silent undercount. In a proper append-only Bronze this is impossible by construction: Bronze either carries a finer-grained key (sub-second `ts_value`, or a monotonic ingest sequence as a tiebreak) or a synthetic row id, so **no raw sample is ever lost to a key collision.** This is the same finding as ADR-0037 (g); it is *resolved by the Bronze design*, not by a point patch — a concrete example of "the structural fix subsumes the point fix."

### 3.5 The live Bronze reality — the B0/B1 starting state (retention as config-drift, compression absent)

§1 and §3.2 say the repo grep for `add_retention_policy`/`add_compression_policy` returns nothing. That is true **of the repo** — and the live-DB audit sharpens *why that is dangerous*: it is **config drift**, not the absence of a policy. The starting state B0/B1 must build from is:

- **Retention EXISTS — but as a 180-day `drop` policy that lives ONLY in the live DB, not in any migration.** So the replay source of truth (§3.3) is being **actively destroyed on a 180-day rolling window** by a policy that is *invisible to version control* — no one reading the repo knows raw older than ~6 months is already gone. This is the worst of both worlds: the destruction is real, but undocumented and un-reviewable. Bronze's whole premise (retain for reprocessing) is being silently violated by out-of-band config.
- **NO compression on any base hypertable.** The storage-economics half of the historian argument (§2.3, §3.2) is entirely unrealized — raw sits uncompressed *and* gets dropped at 180 days. We pay full disk for the warm window and then throw away the cold window that reprocessing needs.
- **Live/repo schema drift on the rollups too.** The Gold runtime tables are *declared* as hypertables in `edge-node-red/db` (`10-missing-tables.sql:327/367`), but on `packiot_shadow` they are **heap tables** — the repo and the live DB disagree about the physical model. Any policy/compression reasoning that assumes "they're hypertables because the DDL says so" is wrong against the live substrate.

**DECISION — B0 (refined).** B0 is not "add a policy where there is none"; it is two coupled moves:
1. **Move retention into version-controlled migrations** — the 180-day drop stops being live-only config drift and becomes a reviewed, diffable artifact.
2. **Change `drop` → `compress`, and stretch the horizon to years.** The replay source stops being destroyed:

```sql
-- B0: retention/compression as a MIGRATION (not live-only config), drop→compress, retain years.
ALTER TABLE equipment_values SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'id_equipment',
  timescaledb.compress_orderby   = 'ts_value DESC'
);
SELECT add_compression_policy('equipment_values', compress_after => INTERVAL '7 days');   -- ~7–14d warm
SELECT add_retention_policy  ('equipment_values', drop_after     => INTERVAL '2 years');   -- was a 180-day DROP (live-only)
```

**DECISION — B1 (refined).** Append-only Bronze means **stop the `ON CONFLICT (ts_value, id_equipment) DO UPDATE` overwrite** (`internal/writers/equipment_values.go:359+`) and make the raw write append-only, keyed with the monotonic **`source_seq`** tiebreak enumerated in §5A. That simultaneously (a) makes Bronze immutable, (b) fixes the sub-second collision of §3.4 / ADR-0037 (g) *by construction*, and (c) removes the mechanism (in-place overwrite) that makes reprocessing impossible. B1 is additive to the Gold path (§6).

**Why this ordering matters:** B0 is pure policy/migration (low risk, reversible — drop the policy) and it **stops the bleeding** (the 180-day drop deleting the replay source) *before* the more invasive append-only write change (B1). Do B0 first, immediately, on staging.

---

## 4. Silver in detail — the validation layer that doesn't exist yet

Silver is where **all** of ADR-0037's cleaning/invariant findings live. Today this logic is smeared across two divergent engines:

- **F3 (Go):** `calc_production_counters/calc.go` + `counter_math.go` do delta/reset (`calc.go:221-256`), but with **no monotonicity guard** (finding b), **no rollover/reset disambiguation** (finding f), and no `[0,1]`/`net≤gross` enforcement. `rollup/shift.go`, `grains.go`, `hour.go` compute OEE with **no output clamps** (findings d, e).
- **F1 (legacy pg):** `edge-node-red/db/20-oee-engine-parity.sql` computes the same numbers *differently* (e.g. proportional_target elapsed-prorated at `:13092-13111`/`:13322` vs F3 full-shift at `shift.go:191` — ADR-0037 finding a).

**The Silver contract (target):** one place, applied identically regardless of which engine writes, where:

1. **Delta/reset/rollover** is disambiguated (monotonic-timestamp guard + per-counter `counter_max` — ADR-0037 b, f).
2. **Dedup + single-writer-per-tenant** is *structurally* enforced, not left to in-process `memState` under `CONSUME_LANES=4` (ADR-0037 h; the #456 two-writer double-count is the cautionary tale — see `docs/.../feedback_bug_two_writer_line_double_count.md`).
3. **Domain invariants are asserted before Gold:** `0 ≤ A,P,Q,OEE ≤ 1`, `net ≤ gross`, non-negativity (ADR-0037 e), performance capped + measured directly with an alert on `>1` (ADR-0037 d).
4. **Dimensional conforming** — tenant/site/area/equipment keys resolved once.

Whether Silver is materialized as (i) a hardened stage inside `oeecloud-worker` shared by all writers, (ii) a set of Timescale caggs/validation views between raw and rollup, or (iii) both, is an **implementation choice deferred to ADR-0037's per-finding fixes** — but the *architectural commitment here* is that **Silver is a named layer with a single invariant contract**, so the F1/F3 divergence that produced the bugs cannot recur. When there is one Silver contract, there is nothing left for two engines to disagree about.

---

## 5. Gold — mostly unchanged, correctly fed

Gold (`equipment_runtime_*`, `uns_*`, `ca_*`) keeps its current shape and its current consumer contract (ADR-0027 refdata read contract is **not** changed by this ADR). The change is upstream: Gold now consumes a *validated* Silver, so the ADR-0037 correctness findings that *surface* at the Gold read plane (misleading proportional_target on the F3 read plane, oee>1 tiles) are fixed at their Silver source, not patched at the Gold edge. Gold stays the thin "serve what Silver guaranteed" layer it should be.

## 5A. Temporal & lineage columns — enumerated, and the schema-hardening notes (NEW DECISIONS)

§3–§5 name the layers but do **not** list the columns that make replay auditable and append-only *possible*. Reprocessing (§3.3) and immutability (§3.1) are not free-standing behaviors — they need physical lineage columns to hang on. Enumerate them once, here, as a decision.

### Bronze lineage columns — what makes append-only work

Bronze (`equipment_values`, `equipment_events`) gets:

| Column | Type | Role |
|---|---|---|
| `ingested_at` | `timestamptz DEFAULT now()` | **Arrival time** — distinct from `ts_value` (the PLC event time). Lets Bronze answer "when did we *receive* this?" independent of when the reading was taken; the basis for late-arrival detection (ADR-0037 (b) monotonicity guard) and for auditing ingest lag. |
| `source_seq` | `bigint` (monotonic) | **The sub-second tiebreak.** A per-writer monotonic sequence that makes `(ts_value, id_equipment, source_seq)` unique *by construction*, so two samples in the same 1-second `ts_value` bucket no longer collide. This is what makes Bronze append-only and **resolves ADR-0037 (g) structurally** (see §3.4) — it replaces the `ON CONFLICT DO UPDATE` overwrite (B1, §3.5) rather than papering over it. |

### Gold lineage columns — what makes replay auditable

The Gold runtime tables — `equipment_runtime_shift`, `_1hour`, `_1day`, `_1week`, `_1month`, and the `area_runtime_*` / `site_runtime_*` rollups — get:

| Column | Type | Role |
|---|---|---|
| `computed_at` | `timestamptz` | **When this Gold row was (re)computed.** After a replay (§3.3) corrects a window, `computed_at` advances — so "is this row from before or after the fix?" is answerable, and stale-vs-fresh Gold is auditable. |
| `source_watermark` | (raw high-watermark, e.g. `timestamptz` / `bigint`) | **The Bronze high-watermark this row was computed from** — the max `ts_value`/`source_seq` of the raw the aggregate consumed. This is the lineage link Gold→Bronze: it says *exactly which raw* produced a served number, makes replay idempotent (recompute only where the watermark moved), and lets a DQ event (ADR-0037 §4A) point back to its raw source window. |

### The inconsistency this generalizes — some tables already do this, most don't

The pattern is not new to the codebase — it is **inconsistently applied**: `production_orders_runtime` and the `uns_*` tables **already carry** a `last_update` / `updated_at` column, while the `equipment_runtime_*` Gold tables and the raw Bronze tables carry **nothing**. So the stack already agrees temporal columns are worth having on *some* served tables — this decision **generalizes the pattern uniformly** (`computed_at`/`source_watermark` on every Gold rollup; `ingested_at`/`source_seq` on every Bronze table) instead of leaving it ad hoc. Note the naming: `last_update`/`updated_at` are *mutation*-time stamps (they fit an upsert model); Bronze/Gold get *lineage* stamps (`ingested_at`, `computed_at`, `source_watermark`) that fit an append-only + replay model — the semantic upgrade is deliberate.

> **Cross-ref — ADR-0039 owns the *dimension* side of this same pattern.** [ADR-0039](0039-entity-lifecycle-deletion-strategy.md) adds temporal columns + SCD-2 history to the **dimension/entity** tables (enterprises/sites/areas/equipments). §5A here is the **fact/metric** counterpart (Bronze raw + Gold rollups). Same principle — every row knows when and from what it came — split by table role: 0039 owns dimensions, 0036 owns facts. Keep the column-naming conventions aligned across the two ADRs.

### Note — the referential-integrity regression on `packiot_shadow`

The go-forward `packiot_shadow` DB **shed the enterprise→site→area→equipment foreign keys** the legacy schema carried (the legacy DB declared **138 + 207** FK constraints across the hierarchy; the shadow schema dropped them for ingest-throughput/flexibility). That is a real **integrity regression**: nothing at the DB layer now prevents an `equipment` row pointing at a non-existent `area`/`site`/`enterprise`, which is *upstream* of the P3-2 "missing target, no fallback" and the tenant-fence assumptions the medallion relies on. **Restoring these FKs (or an equivalent validated-conform check in Silver) is part of schema-hardening** — flagged here, but **owned by [ADR-0039](0039-entity-lifecycle-deletion-strategy.md)** (entity-integrity is its remit). The medallion notes it because a broken entity graph corrupts every layer above it; 0039 decides the restore path.

---

## 6. Migration — incremental, no big-bang

Sequenced so each step is independently valuable and reversible. **This ADR ships none of it as code**; this is the plan ADR-0037 executes finding-by-finding.

| Phase | Step | Risk | Reversible? |
|-------|------|------|-------------|
| **B0** | Add compression + retention policy to the *existing* `equipment_values` / `equipment_events` hypertables on **staging** (no new tables yet). Pure policy add. | Low | Yes (drop policy) |
| **B1** | Introduce append-only Bronze semantics: stop overwriting raw (resolve the sub-second key, ADR-0037 g), or split `equipment_values_raw` as a distinct immutable hypertable fed by the writer. | Med | Yes (Bronze is additive; Gold path unchanged) |
| **S1** | Extract the Silver invariant contract as a named stage; wire the highest-priority ADR-0037 fixes (a, b) through it. | Med | Yes (per-invariant flags) |
| **S2** | Migrate remaining ADR-0037 P2/P3 findings into Silver (c–h, targets, rates). | Med | Yes |
| **G0** | Formalize caggs as the documented Silver→Gold streaming transform (naming/docs; behavior already live). | Low | N/A |
| **L0** | Stand up the **AWS-native offline lakehouse (§2.4)**: batch-export Bronze→S3 parquet, register in Glue, query via Athena; **repoint `cq-logs-bigquery` from the BigQuery client to `boto3`/`pyathena`** (its only dataset, `cq_logs`, lands in S3). Completes the **BigQuery→S3+Athena** cut → **100% off GCP**. `reports/` (LaTeX-only) needs no data-tier change. | Low | Yes (BigQuery can stay until Athena verified) |
| **P** | Promote each phase staging→prod under its own gate (retention windows sized to prod volume; prod DB is SELECT-only for us — policy/DDL changes go through the normal prod-apply gate, never ad hoc). | — | Per-phase |

> **B0/B1 refined by the live-DB audit (§3.5):** B0 is not "add a policy where none exists" — the live DB already runs a **180-day `drop`** (live-only config drift), so B0 = *move retention into a migration* **and** *convert `drop`→`compress` with a years-long horizon* (stop destroying the replay source). B1's append-only write uses the **`source_seq`** lineage column (§5A). See §3.5 for the exact starting state and DDL.

**Sequencing rule:** Bronze (B0/B1) lands *before or with* the first Silver reprocessing-dependent fix, because the whole point of Silver fixes is to *replay* them — and replay needs Bronze. B0 (policy-only) is the cheapest, most reversible first move and can go immediately on staging. **And per ADR-0037 §4A, the `data_quality_event` substrate + emit-only invariant checks ship even earlier — Step 0 — so corruption is measured before any served value changes (instrument-before-remediate).**

---

## 7. Consequences

**Positive:**
- **Reprocessing becomes possible** — the single biggest capability gain; every ADR-0037 fix becomes retroactive, not forward-only.
- **Invariants get a home** — the F1/F3 divergence class of bug is structurally prevented, not whack-a-moled.
- **No new system** — Timescale stays the one operational store; no PI/AVEVA license, no second ingest path, no historian sync problem.
- **Storage economics** — compression gives historian-class density on the raw tier we're currently letting evaporate.
- **Clean, AWS-native offline story** — S3 + Glue + Athena fed from Bronze, decoupled from the hot path; **replaces BigQuery → the stack goes 100% off GCP (one cloud)**, collapsing IAM/billing/networking/credential surface (§2.4).

**Negative / risks:**
- **Storage growth.** Retaining Bronze for years costs disk; compression mitigates but the staging DB is already EC2-undersized (memory notes: "staging DB EC2 undersized + swapping"). Retention windows must be sized against real capacity, and B0 should be watched. *Mitigation:* start conservative (e.g. 90 days) on staging, extend on prod-sized hardware.
- **Reprocessing load.** Replaying Silver/Gold over a long Bronze window is I/O-heavy; the stack has a history of cagg-I/O storms and provision/rollup deadlocks (`shift.go:219` non-blocking advisory lock exists *because* of this). *Mitigation:* bounded, throttled, off-peak replay reusing the existing `recalc_needed` batching — never a full-table replay.
- **Append-only vs upsert semantics change.** Making Bronze immutable changes writer behavior; the late/duplicate-message handling that upsert currently papers over moves *up* into Silver (which is where it belongs — ADR-0037 b). *Mitigation:* Bronze split (B1) is additive; Gold path is untouched until Silver is ready.
- **Dual-write window during B1.** If `equipment_values_raw` is split out, there's a period where both raw and cleaned tables exist. *Mitigation:* the medallion *wants* both to coexist permanently (Bronze ≠ Silver); this is the target, not a temporary state.

---

## 8. Alternatives considered

- **Buy a historian (PI/AVEVA/Influx).** Rejected — §2.3. Zero net capability over a Timescale compression+retention policy; adds a whole second system.
- **Full Databricks/Delta lakehouse for the live path.** Rejected — §2.2. Reimplements what caggs already do; adds Spark/Delta ops burden; the live path must stay low-latency and transactional in one store.
- **Leave it as-is, fix bugs pointwise (ADR-0037 only).** Rejected — without Bronze the fixes are forward-only (history stays wrong) and without a named Silver the F1/F3 divergence recurs. ADR-0037 *needs* this ADR to be durable.
- **Object storage as Bronze (raw SparkPlug to S3 first).** Rejected for the *live* tier — adds a hop and a second query surface for the hot path. **Kept for offline** (§2.4: S3+Glue+Athena lakehouse fed from Bronze).
- **Keep BigQuery for the offline tier.** Rejected — §2.4. Re-opens a GCP dependency the rest of the stack has already left (Firebase→Cognito, PubSub→RMQ, GCP-Compute→AWS worker); one-cloud (AWS) wins on IAM/billing/networking/egress. The current BigQuery footprint is tiny (`cq-logs-bigquery`→`cq_logs` only; `reports/` is LaTeX-only), so exiting is cheap and the future analytics/ML tier is born AWS-native.
- **Redshift Serverless as the offline query engine.** Deferred, not rejected — §2.4. Recommend S3+Athena for the lake+reporting fit (no idle cost, pay-per-query); layer Redshift later (via Spectrum over the same S3) only if a warehouse-shaped BI workload emerges.

---

## 9. Cross-reference to ADR-0037

ADR-0037 is the prioritized remediation backlog. Every one of its findings is tagged with the layer defined here:

- Bronze-layer fixes (immutability/retention/reprocessing): ADR-0037 (b), (g) — resolved by §3.
- Silver-layer fixes (invariants/cleaning/single-writer): ADR-0037 (a), (c), (d), (e), (f), (h) — resolved by §4.
- Gold-layer surfacing (served-metric correctness + alerts): ADR-0037 (d) alert, targets/rates P3 — surfaced by §5.

**The theme both ADRs share:** *most OEE correctness findings are symptoms of one root cause — the absence of a Silver validation layer and a reprocess-able Bronze.* This ADR builds the layers; ADR-0037 fills them, in priority order.
