-- t-histdb-object-docs — historian-gateway object documentation (COMMENT ON …).
-- Idempotent + non-destructive (COMMENT only — never touches view/fn/table logic).
--
-- TARGET DB: the historian-gateway pg_duckdb instance ONLY (container `hist-gateway`,
-- image pgduckdb/pgduckdb:16-main, database `postgres`, user `postgres`). This is a
-- SEPARATE Postgres instance from packiot_analytics — do NOT run this against the
-- analytics DB. Confirm target with: SELECT * FROM pg_extension WHERE extname='pg_duckdb';
-- (present ⇒ gateway) and \dv ev_all (present ⇒ gateway).
--
-- WHAT THIS DB IS: the transparent HOT+COLD historian gateway. It fronts one union
-- surface per fact so front4 / Superset / read-api can query old timestamps with plain
-- Postgres SQL:
--   ev_all         = live.equipment_values (postgres_fdw → live timescaledb, HOT)
--                    UNION ALL  hist  (pg_duckdb read_parquet → S3 historian, COLD)
--   ev_all_events  = live.equipment_events (FDW, HOT)
--                    UNION ALL  hist_ee (pg_duckdb read_parquet → S3, COLD)
-- HOT = the live timescaledb on 10.10.10.89 (packiot_analytics.silver.*) via
-- postgres_fdw server `live_pg`. COLD = hive-partitioned (enterprise=/year=/month=)
-- *-legacy.parquet in s3://<HISTORIAN_BUCKET>/equipment_values|equipment_events/ read
-- by pg_duckdb. Definitions + the disjointness proofs live in
-- services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh; that
-- init script is ALSO updated to carry these COMMENTs so a fresh gateway is born
-- documented. Consumers: read-api services/read-api/cmd/refdata-api/historian.go
-- (POST /v1/historian/production-series) + Superset virtual dataset
-- configs/superset/assets/datasets/historian_union/ev_all.yaml.
--
-- TENANT ISOLATION: this gateway has NO Postgres RLS co-enforcer (unlike bi.* on
-- analytics). pg_duckdb cannot evaluate a session GUC / STABLE fn during pushdown, so
-- the tenant MUST arrive as a LITERAL: read-api injects a server-resolved
-- `id_enterprise = <id>`; Superset native RLS injects the same as a literal clause.
-- Keep ev_all / ev_all_events OUT of Superset SQL Lab and any anon dashboard.

-- ═══════════════════════════════════════════════════════════════════ schemas
COMMENT ON SCHEMA public IS
  'historian-gateway serving schema. Holds the hot+cold union VIEWS (ev_all EV, ev_all_events EE), the pg_duckdb read_parquet COLD source views (hist, hist_ee) and the per-enterprise disjointness boundary TABLES (hist_cutover, ev_events_cutover). Query surface for read-api /v1/historian and the Superset ev_all virtual dataset. No RLS engine here — tenant fence is a caller-supplied id_enterprise literal.';
COMMENT ON SCHEMA live IS
  'Foreign-table schema: postgres_fdw window onto the HOT live timescaledb (server live_pg → packiot_analytics.silver on 10.10.10.89). live.equipment_values / live.equipment_events are the hot side of the ev_all / ev_all_events unions. Pinned/narrow imports — the FDW only ships referenced columns, so remote column prunes cannot break these.';

-- ═══════════════════════════════════════════════════════ live.equipment_values
COMMENT ON FOREIGN TABLE live.equipment_values IS
  'HOT side of ev_all. postgres_fdw foreign table onto packiot_analytics.silver.equipment_values (the live production-series hypertable) via server live_pg. PINNED column set (declared, not IMPORT-ed): only the 8 serving columns are mounted, so dropping a dead column on the remote can never break this table (postgres_fdw ships only referenced columns). A ts_value predicate pushes down to remote chunk-exclusion.';
COMMENT ON COLUMN live.equipment_values.ts_value IS 'Reading timestamp (timestamptz). Pushdown predicate for remote chunk-exclusion on the hot side.';
COMMENT ON COLUMN live.equipment_values.id_enterprise IS 'Tenant id. THE tenant fence for the hot side — callers must supply id_enterprise as a literal.';
COMMENT ON COLUMN live.equipment_values.id_site IS 'Site id (hierarchy: enterprise→site→area→equipment).';
COMMENT ON COLUMN live.equipment_values.id_area IS 'Area id.';
COMMENT ON COLUMN live.equipment_values.id_equipment IS 'Equipment id producing the reading.';
COMMENT ON COLUMN live.equipment_values.gross_production_incr IS 'Gross production increment for the reading interval (real).';
COMMENT ON COLUMN live.equipment_values.net_production_incr IS 'Net (good) production increment for the reading interval (real).';
COMMENT ON COLUMN live.equipment_values.speed IS 'Instantaneous line/machine speed at the reading (real).';

-- ═══════════════════════════════════════════════════════ live.equipment_events
COMMENT ON FOREIGN TABLE live.equipment_events IS
  'HOT side of ev_all_events. postgres_fdw foreign table onto packiot_analytics.silver.equipment_events (downtime / OEE-reconstruction events) via server live_pg. IMPORT-ed (full remote column set, ~26 cols) rather than pinned — equipment_events is not part of the analytics column-prune, so a full import is safe; ev_all_events selects a fixed subset. Also holds the CPACK Phase-C deep-history backfill (pre-cutover events loaded INTO hot with irreplaceable operator reasons) — see ev_events_cutover for why EE is hot-anchored.';
COMMENT ON COLUMN live.equipment_events.id_equipment IS 'Equipment id the event belongs to.';
COMMENT ON COLUMN live.equipment_events.ts_event IS 'Event start timestamp (timestamptz). min(ts_event) per enterprise = the EE cutover boundary (ev_events_cutover).';
COMMENT ON COLUMN live.equipment_events.status IS 'Event/machine status code (e.g. running/stopped). Surfaced by ev_all_events.';
COMMENT ON COLUMN live.equipment_events.id_equipment_event IS 'Surrogate PK of the event row on the remote.';
COMMENT ON COLUMN live.equipment_events.txt_downtime_notes IS 'Free-text operator downtime note. Irreplaceable — the reason the Phase-C history was loaded into hot rather than left cold-only.';
COMMENT ON COLUMN live.equipment_events.idle IS 'Idle classification marker (remote raw).';
COMMENT ON COLUMN live.equipment_events.idle_processed IS 'Whether the idle classification has been processed.';
COMMENT ON COLUMN live.equipment_events.forced_creation_system IS 'True when the event was system-forced rather than PLC/operator originated.';
COMMENT ON COLUMN live.equipment_events.fault IS 'PLC fault code associated with the event.';
COMMENT ON COLUMN live.equipment_events.fault_processed IS 'Whether the fault has been processed downstream.';
COMMENT ON COLUMN live.equipment_events.cd_machine IS 'Machine code string.';
COMMENT ON COLUMN live.equipment_events.cd_category IS 'Downtime category code (canonical).';
COMMENT ON COLUMN live.equipment_events.cd_subcategory IS 'Downtime subcategory code (canonical).';
COMMENT ON COLUMN live.equipment_events.change_over IS 'True if the event is a changeover/setup.';
COMMENT ON COLUMN live.equipment_events.planned_downtime IS 'True if the downtime is planned (excluded from availability loss).';
COMMENT ON COLUMN live.equipment_events.ts_end IS 'Event end timestamp; NULL/open while the event is ongoing.';
COMMENT ON COLUMN live.equipment_events.duration IS 'Event duration in seconds.';
COMMENT ON COLUMN live.equipment_events.id_enterprise IS 'Tenant id. THE tenant fence for the hot EE side.';
COMMENT ON COLUMN live.equipment_events.desc_category IS 'Human-readable downtime category description.';
COMMENT ON COLUMN live.equipment_events.desc_subcategory IS 'Human-readable downtime subcategory description.';
COMMENT ON COLUMN live.equipment_events.cd_category_client IS 'Client-facing category code (per-tenant remap of cd_category).';
COMMENT ON COLUMN live.equipment_events.cd_subcategory_client IS 'Client-facing subcategory code (per-tenant remap).';
COMMENT ON COLUMN live.equipment_events.last_update IS 'Last mutation timestamp of the event row on the remote.';
COMMENT ON COLUMN live.equipment_events.ignore_cost IS 'True if the event is excluded from cost calculations.';
COMMENT ON COLUMN live.equipment_events.ingested_at IS 'Ingest timestamp on the live store.';
COMMENT ON COLUMN live.equipment_events.source_seq IS 'Monotonic source sequence for ordering/dedup.';

-- ═══════════════════════════════════════════════════════════════════ hist (COLD EV)
COMMENT ON VIEW hist IS
  'COLD side of ev_all. pg_duckdb view over the S3 Parquet historian: read_parquet(''s3://<HISTORIAN_BUCKET>/equipment_values/*/*/*/*-legacy.parquet'', hive_partitioning=>true). *-legacy.parquet = the deep-remapped legacy backfill (F3 id-space; on staging the CPACK partition is 336M rows spanning 2021→~today). Surfaces the hive partition columns year/month so a bounded query PRUNES the cold scan (T3: ts_value alone does NOT prune — DuckDB prunes only on partition cols; 59 files/171s vs 1 file/0.57s with a year/month predicate). Serving surface is narrow: {gross, net, speed}. NOTE: a query touching this view must run under the SIMPLE query protocol (pg_duckdb does not apply the S3 secret on the prepared-statement path) and CANNOT be wrapped in a SQL/PLpgSQL function (DuckDB has no PG function context — ev_between was dropped for exactly this).';
COMMENT ON COLUMN hist.ts_value IS 'Reading timestamp (parquet r[''ts_value'']::timestamp). Cold side is unfiltered in ev_all — all cold rows are <= the enterprise cutover_ts by construction.';
COMMENT ON COLUMN hist.id_enterprise IS 'Tenant id from the parquet (hive enterprise= partition remapped to F3 id-space). Tenant fence literal prunes to one enterprise= partition.';
COMMENT ON COLUMN hist.year IS 'Hive partition column (year=). PRUNE key — carry a year predicate to avoid a full-archive scan.';
COMMENT ON COLUMN hist.month IS 'Hive partition column (month=). PRUNE key — carry a month predicate alongside year.';
COMMENT ON COLUMN hist.id_equipment IS 'Equipment id from the parquet.';
COMMENT ON COLUMN hist.gross_production_incr IS 'Gross production increment (parquet, double precision).';
COMMENT ON COLUMN hist.net_production_incr IS 'Net (good) production increment (parquet, double precision).';
COMMENT ON COLUMN hist.speed IS 'Speed (parquet, double precision). Present in every *-legacy.parquet, surfaced without a re-unload.';

-- ═══════════════════════════════════════════════════════════════════ hist_ee (COLD EE)
COMMENT ON VIEW hist_ee IS
  'COLD side of ev_all_events. pg_duckdb view over read_parquet(''s3://<HISTORIAN_BUCKET>/equipment_events/*/*/*/*-legacy.parquet'', hive_partitioning=>true). Only VERIFIED-F3-remapped partitions live under equipment_events/ — un-promoted legacy partitions are held under equipment_events_legacy_unpromoted/ and NOT globbed (their legacy ids collide with real F3 tenant ids ⇒ serving them would be a CROSS-TENANT LEAK). Surfaces year/month for partition pruning. Same pg_duckdb constraints as hist (simple protocol, no function wrapping).';
COMMENT ON COLUMN hist_ee.ts_event IS 'Event start timestamp (parquet). In ev_all_events the cold side is kept only where ts_event < the enterprise cutover_ts (EE is HOT-anchored — see ev_events_cutover).';
COMMENT ON COLUMN hist_ee.id_enterprise IS 'Tenant id from the parquet hive enterprise= partition (F3-remapped). Tenant fence + partition prune key.';
COMMENT ON COLUMN hist_ee.year IS 'Hive partition column (year=). PRUNE key.';
COMMENT ON COLUMN hist_ee.month IS 'Hive partition column (month=). PRUNE key.';
COMMENT ON COLUMN hist_ee.id_equipment IS 'Equipment id from the parquet.';
COMMENT ON COLUMN hist_ee.ts_end IS 'Event end timestamp (parquet).';
COMMENT ON COLUMN hist_ee.duration IS 'Event duration in seconds (parquet).';
COMMENT ON COLUMN hist_ee.status IS 'Event/machine status code (parquet).';
COMMENT ON COLUMN hist_ee.planned_downtime IS 'True if the downtime is planned (parquet).';
COMMENT ON COLUMN hist_ee.cd_category IS 'Downtime category code (parquet).';
COMMENT ON COLUMN hist_ee.desc_category IS 'Downtime category description (parquet).';
COMMENT ON COLUMN hist_ee.cd_subcategory IS 'Downtime subcategory code (parquet).';
COMMENT ON COLUMN hist_ee.desc_subcategory IS 'Downtime subcategory description (parquet).';
COMMENT ON COLUMN hist_ee.txt_downtime_notes IS 'Free-text operator downtime note (parquet).';

-- ═══════════════════════════════════════════════════════════════════ ev_all (EV union)
COMMENT ON VIEW ev_all IS
  'THE hot+cold EV serving surface — one row per equipment_values reading across ALL time, no double-count. LEGACY-PRIORITY (T2b): COLD (hist) owns ts_value <= cutover_ts, HOT (live.equipment_values) owns ts_value > cutover_ts, cutover_ts = max(hist.ts_value) per enterprise (hist_cutover). Implemented as: live LEFT JOIN hist_cutover WHERE cutover_ts IS NULL OR ts_value > cutover_ts  UNION ALL  full hist. A live-only tenant (no hist_cutover row) keeps ALL its live rows; an in-historian tenant MISSING its cutover row re-introduces the double-count (invariant: every historian enterprise MUST have a hist_cutover row = max(hist.ts_value)). Surfaces year/month (hot via EXTRACT, cold = partition cols) so a bounded query prunes the cold parquet. Consumers MUST carry a tenant id_enterprise literal (no RLS engine) AND a year/month predicate (else full cold scan). read-api /v1/historian/production-series + Superset ev_all virtual dataset.';
COMMENT ON COLUMN ev_all.ts_value IS 'Reading timestamp. Hot for ts_value > enterprise cutover_ts, cold for <=.';
COMMENT ON COLUMN ev_all.id_enterprise IS 'Tenant id. THE tenant fence — every consumer query MUST filter id_enterprise = <literal> (no Postgres RLS on this gateway).';
COMMENT ON COLUMN ev_all.year IS 'Reading year. Cold = hive partition column; hot = EXTRACT(YEAR FROM ts_value). Carry a year predicate to prune the cold scan.';
COMMENT ON COLUMN ev_all.month IS 'Reading month. Cold = hive partition column; hot = EXTRACT(MONTH FROM ts_value). Carry a month predicate to prune the cold scan.';
COMMENT ON COLUMN ev_all.id_equipment IS 'Equipment id producing the reading.';
COMMENT ON COLUMN ev_all.gross_production_incr IS 'Gross production increment (double precision; hot real widened to match cold).';
COMMENT ON COLUMN ev_all.net_production_incr IS 'Net (good) production increment (double precision).';
COMMENT ON COLUMN ev_all.speed IS 'Instantaneous speed (double precision).';

-- ═══════════════════════════════════════════════════════════════════ ev_all_events (EE union)
COMMENT ON VIEW ev_all_events IS
  'THE hot+cold EE (downtime/OEE-event) serving surface — no double-count. HOT-ANCHORED (the MIRROR of ev_all/hist_cutover): because the Phase-C backfill loaded deep-history events INTO the hot store (with irreplaceable operator reasons), HOT (live.equipment_events) owns its whole covered range and keeps ALL rows; COLD (hist_ee) fills ONLY the pre-hot window (ts_event < cutover_ts), cutover_ts = min(hot ts_event) per enterprise (ev_events_cutover). Implemented as: full live.equipment_events  UNION ALL  (hist_ee LEFT JOIN ev_events_cutover WHERE cutover_ts IS NULL OR ts_event < cutover_ts). HARDPROOF staging ent-3: union 316,688 == cold_kept 53,959 + hot_kept 262,729 (naïve union double-counted 116,113). Caveat: handing the overlap to hot assumes hot fully covers it for all equipment; equipment cold-but-not-hot in that window is under-covered (conservative failure, NOT double-count). Surfaces year/month for cold pruning. Tenant fence = id_enterprise literal.';
COMMENT ON COLUMN ev_all_events.ts_event IS 'Event start timestamp. Hot for ts_event >= enterprise cutover_ts, cold for <.';
COMMENT ON COLUMN ev_all_events.id_enterprise IS 'Tenant id. THE tenant fence — every consumer query MUST filter id_enterprise = <literal>.';
COMMENT ON COLUMN ev_all_events.year IS 'Event year. Cold = hive partition column; hot = EXTRACT. Prune key for the cold scan.';
COMMENT ON COLUMN ev_all_events.month IS 'Event month. Cold = hive partition column; hot = EXTRACT. Prune key for the cold scan.';
COMMENT ON COLUMN ev_all_events.id_equipment IS 'Equipment id the event belongs to.';
COMMENT ON COLUMN ev_all_events.ts_end IS 'Event end timestamp.';
COMMENT ON COLUMN ev_all_events.duration IS 'Event duration in seconds.';
COMMENT ON COLUMN ev_all_events.status IS 'Event/machine status code.';
COMMENT ON COLUMN ev_all_events.planned_downtime IS 'True if the downtime is planned (excluded from availability loss).';
COMMENT ON COLUMN ev_all_events.cd_category IS 'Downtime category code.';
COMMENT ON COLUMN ev_all_events.desc_category IS 'Downtime category description.';
COMMENT ON COLUMN ev_all_events.cd_subcategory IS 'Downtime subcategory code.';
COMMENT ON COLUMN ev_all_events.desc_subcategory IS 'Downtime subcategory description.';
COMMENT ON COLUMN ev_all_events.txt_downtime_notes IS 'Free-text operator downtime note (the irreplaceable Phase-C history).';

-- ═══════════════════════════════════════════════════════════════════ hist_cutover
COMMENT ON TABLE hist_cutover IS
  'T2b EV legacy-priority disjointness boundary. cutover_ts = max(hist.ts_value) per enterprise; in ev_all COLD owns ts_value <= cutover_ts, HOT owns ts_value > cutover_ts. Small (one row per historian enterprise), read on the hot side only (pure PG join — no DuckDB, so the cold scan stays a prunable DuckDBScan). LOAD-BEARING INVARIANT: every enterprise present in the historian MUST have a row here = max(hist.ts_value). MUST be refreshed (services/historian-gateway/refresh-hist-cutover.sql — a TOP-LEVEL statement, NOT a function: pg_duckdb cannot scan parquet inside a function body) after EVERY historian backfill/append that extends the cold store, else the newly-archived window is served by BOTH sides = double-count.';
COMMENT ON COLUMN hist_cutover.id_enterprise IS 'Tenant id (PK). One row per enterprise present in the cold historian.';
COMMENT ON COLUMN hist_cutover.cutover_ts IS 'max(hist.ts_value) for the enterprise. The EV boundary: cold owns <= this, hot owns > this.';
COMMENT ON COLUMN hist_cutover.refreshed_at IS 'When this boundary row was last recomputed (defaults now()). Stale after a cold-store append until the refresh re-runs.';

-- ═══════════════════════════════════════════════════════════════════ ev_events_cutover
COMMENT ON TABLE ev_events_cutover IS
  'EE disjointness boundary. UNLIKE hist_cutover (cold-anchored: cutover=max(cold ts)), this is HOT-ANCHORED: cutover_ts = min(hot ts_event) per enterprise. The Phase-C backfill loaded CPACK deep-history events INTO the hot F3 store (with irreplaceable operator reasons), so hot owns its whole covered range and cold (hist_ee) fills only the pre-hot window. In ev_all_events COLD owns ts_event < cutover_ts, HOT owns ts_event >= cutover_ts. Refresh (services/historian-gateway/refresh-ee-cutover.sql) reads the hot FDW (a cheap PG aggregate — NOT a parquet scan), so it MAY run in a function/simple statement. Re-run after any change to the hot EE earliest event (e.g. a further deep-history backfill).';
COMMENT ON COLUMN ev_events_cutover.id_enterprise IS 'Tenant id (PK). One row per enterprise present in the hot EE store.';
COMMENT ON COLUMN ev_events_cutover.cutover_ts IS 'min(hot ts_event) for the enterprise. The EE boundary: cold owns < this, hot owns >= this.';
COMMENT ON COLUMN ev_events_cutover.refreshed_at IS 'When this boundary row was last recomputed (defaults now()).';
