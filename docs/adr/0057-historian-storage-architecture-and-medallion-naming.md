# ADR-0057 — Historian storage architecture: medallion-aligned naming now, Apache Iceberg on S3 as the end-state

## Status

Proposed (2026-09-14).

## Context

The historian is a **pg_duckdb gateway** (`packiot_historian`, container `hist-gateway`) that
federates two physical stores behind per-fact union views:

- **HOT** — `postgres_fdw` windows onto the live analytics DB (`packiot_analytics.silver.*`).
- **COLD** — `read_parquet` over ZSTD Parquet on S3 (a temporary scheduled copy of legacy
  `packiot40`, remapped legacy→F3 — see the copier, ADR-0036, task #282).

It works and is hardproofed, but two problems motivated this ADR:

1. **Namespace incoherence.** The gateway organizes by **storage temperature** (`live` / `cold`),
   while analytics organizes by **medallion data-quality tier** (`bronze` / `silver` / `gold`).
   The *same* fact is `silver.equipment_values` in analytics but `live.equipment_values` **+**
   `cold.equipment_values` **+** `cold.equipment_values_all` in the gateway. The physical tier
   has leaked into the name, so one logical dataset has N names.
2. **Hand-rolled hot/cold management.** The seam is maintained by bespoke machinery —
   per-tenant boundary tables (`ev_union_boundary` / `ee_union_boundary`), a nightly
   `max(cold ts)` refresh job, a `promoted_enterprise` allow-list, a staleness monitor, and a
   copier that writes `*-legacy.parquet` matched by a glob. This session alone produced a class
   of bugs from that design: daily appends orphaned by a glob mismatch, cold frozen when the
   copier tooling was lost, a half-applied file rename, and namespace drift.

**Scale (grounded):** the entire cold store is **~11 GB** (10.6 GB `equipment_values` +
25 MB `equipment_events`, 1,459 objects). This is small — it fits on a phone. That fact
governs the cost analysis below.

## Decision

1. **Naming principle (adopt):** separate **logical identity** (one canonical name per dataset)
   from **physical placement** (tier is metadata, never part of the name). The historian is a
   query layer *over* the analytics facts, so its consumer surface must carry the **medallion
   fact names**, matching analytics 1:1.

2. **Near-term — medallion-aligned naming (expand/contract, ~$0 infra):** expose the union
   facts under medallion names — `silver.equipment_values`, `silver.equipment_events`,
   `gold.equipment_oee_shift` — as the consumer-facing serving surface, matching
   `packiot_analytics`. Demote `live` / `cold` to **internal physical-tier plumbing** (only the
   union views reference them). Migrate read-api + Superset via expand/contract (add the new
   names, repoint, drop the `*_all` aliases). Control tables (boundaries / allow-list /
   watermark) stay gateway-internal (no analytics counterpart; named for their role).

3. **End-state — Apache Iceberg on the existing S3 (post-#225):** migrate the cold store to an
   **open table format** (Iceberg; Delta is an acceptable alternative), queried by the same
   engines (Athena natively; DuckDB via the `iceberg` extension), cataloged by **AWS Glue
   (free tier) or a Postgres JDBC catalog**. One logical table per fact; the table format owns
   the hot/cold seam, atomic commits, partition pruning, schema evolution, and time-travel —
   which **retires** the per-tenant boundary tables, the nightly refresh job, and the
   double-count machinery entirely.

4. **Reject managed platforms.** Databricks (Delta + Unity Catalog), Snowflake, and a dedicated
   Trino/EMR cluster are **out of scope** — they add $100s–1,000s/month to manage 11 GB. Not
   justified at this scale.

## Cost analysis

| Option | Δ monthly cost | Note |
|---|---|---|
| Today (pg_duckdb + Athena partition projection) | baseline **~$0.25** | 11 GB S3 storage + pruned Athena scans (pennies) + gateway on existing box |
| (2) Medallion rename | **$0** | schema/view changes only |
| (3) Iceberg on same S3 + Athena/DuckDB | **≈ $0** | same 11 GB + tiny Iceberg metadata; Glue catalog free-tier or Postgres JDBC = $0; same query engines |
| Databricks / Snowflake / dedicated Trino | **+$100s–1,000s** | REJECTED — overkill at 11 GB |

The correct big-company pattern (open table format on your own object store) is **cost-neutral**
— that is precisely why Netflix built Iceberg and Uber built Hudi: catalog/ACID/time-travel
semantics **while keeping raw-S3 economics**. The real cost of the migration is **engineering
time**, not dollars.

## Benefits (each maps to a bug this session hit)

| Bug we fought | What the target design gives |
|---|---|
| Daily append wrote `data-*.parquet` the cold view's `*-legacy.parquet` glob never read | Table manifest tracks its files — no globs, can't orphan a write |
| Cold froze when the copier tooling was lost | Loads are atomic commits to the table — no copier↔view coupling to silently break |
| `*_union_boundary` tables + refresh job + double-count risk | Snapshots/manifests own the seam — delete the boundary tables, the refresh SQL, and the double-count class |
| "must carry year AND month or full-scan" fragility | File-level stats + hidden partitioning prune automatically |
| "56-col projection must match the Glue table" | Schema evolution is tracked — add/rename columns safely |
| `live`/`cold` vs `silver`/`gold` incoherence | One logical table per fact under the medallion name |

Plus: **time-travel** (query OEE as-of any point; roll back a bad load), **engine-agnostic**
(Athena/Trino/Spark/DuckDB/Snowflake all read Iceberg), and **standard/hireable** (nobody
inherits bespoke cutover machinery gladly).

## Tradeoffs / caveats

- **DuckDB write-path immaturity:** DuckDB's Iceberg support is read-strong but write-immature.
  Writing the table likely needs **PyIceberg or Spark**, i.e. a new component in the copier — the
  real friction (not cost).
- **The legacy phase is temporary.** After the #225 cutover the historian becomes "aged
  analytics" — a simpler problem. Investing in Iceberg *during* the temporary legacy-copy phase
  is premature; time it for after #225.
- **Migration effort:** rewrite the copier to emit Iceberg, migrate existing Parquet into Iceberg
  tables, repoint read-api + Superset, re-test. Days of focused work + a cutover.

## Sequencing

1. **Now (optional, cheap):** the medallion rename (decision 2) via expand/contract, IF done as a
   standalone step. Note it re-touches read-api + Superset (a 2nd consumer repoint this session);
   it may instead be **bundled into the Iceberg migration**, which re-lays the schemas anyway.
2. **After #225:** the Iceberg migration (decision 3), when the historian is permanent and stable.
3. Everything stays behind the medallion names, so consumers don't move again after step 1.

## Consequences

- Consumers (`read-api /v1/historian`, the Superset historian dataset) query medallion names
  (`silver.equipment_values`, …) — identical to how they'd address analytics, so the two systems'
  namespaces finally correlate.
- Retired at the Iceberg step: `ev_union_boundary`, `ee_union_boundary`, the cutover refresh SQL,
  and the double-count-avoidance logic (the table format subsumes them). `promoted_enterprise`
  (tenant isolation) and `cold_append_watermark` (observability) may survive or fold into catalog
  metadata.
- A new build-time dependency (PyIceberg/Spark) enters the copier for the write path.
- No meaningful infra-cost change (~$0.25/month either way).

## When to revisit

- A **second query engine** appears (Trino/Spark/Snowflake) — Iceberg's payoff rises sharply.
- Scale grows **>> current** (multi-hundred-GB per tenant).
- **#225 completes** — the trigger to execute the Iceberg step.

## References

- ADR-0036 (medallion data architecture), ADR-0050 (F3→analytics rename), ADR-0056 (single app DB).
- `docs/wiki/06-database.md` (historian gateway object reference + naming correlation).
- Tasks #274–#282 (historian gateway rename, codified install, legacy copier).
- Apache Iceberg (Netflix), Apache Hudi (Uber), Delta Lake (Databricks).
