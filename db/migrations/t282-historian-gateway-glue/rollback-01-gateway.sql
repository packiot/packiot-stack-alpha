-- t282 ROLLBACK (gateway side) — reverse 01-gateway.sql on the hist-gateway DB.
-- Restores the pre-t282 state: full 26-col equipment_events import, no hist_meta,
-- browser mapping back to the remote superuser, documentary provenance rows removed,
-- and the R6/R2 COMMENTs back to their init-canonical text. Zero data risk.
\set ON_ERROR_STOP on

-- R9 — repoint the browser mapping back to the remote postgres superuser.
ALTER USER MAPPING FOR cloudbeaver_histro SERVER live_pg
  OPTIONS (SET user 'postgres', SET password :'fdw_pass');

-- R8 — restore the 14 dropped columns (full remote import shape).
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN id_equipment_event     bigint;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN idle                   varchar;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN idle_processed         boolean;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN forced_creation_system boolean;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN fault                  integer;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN fault_processed        boolean;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN cd_machine             varchar;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN change_over            boolean;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN cd_category_client     integer;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN cd_subcategory_client  integer;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN last_update            timestamptz;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN ignore_cost            boolean;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN ingested_at            timestamptz;
ALTER FOREIGN TABLE live.equipment_events ADD COLUMN source_seq             bigint;

-- R5 — drop the append-stamp table.
DROP TABLE IF EXISTS hist_meta;

-- R2 — remove the documentary provenance rows (keep the two real promotions 3,4).
DELETE FROM hist_promoted_enterprise
 WHERE id_enterprise IN (0,2,5,6,10,13,30,31,33,35,36,37,38,99,100,101,102,111,112,113,116,117,118,1000000,10016)
   AND ev_promoted = false AND ee_promoted = false;

-- R6/R2 — restore the init-canonical COMMENTs (shorter, pre-t282 text).
COMMENT ON TABLE hist_cutover IS
  'T2b EV legacy-priority disjointness boundary. cutover_ts = max(hist.ts_value) per enterprise; in ev_all COLD owns ts_value <= cutover_ts, HOT owns ts_value > cutover_ts. Small (one row per historian enterprise), read on the hot side only (pure PG join — no DuckDB, so the cold scan stays a prunable DuckDBScan). LOAD-BEARING INVARIANT: every enterprise present in the historian MUST have a row here = max(hist.ts_value). MUST be refreshed (services/historian-gateway/refresh-hist-cutover.sql — a TOP-LEVEL statement, NOT a function: pg_duckdb cannot scan parquet inside a function body) after EVERY historian backfill/append that extends the cold store, else the newly-archived window is served by BOTH sides = double-count.';
COMMENT ON VIEW ev_all IS
  'THE hot+cold EV serving surface — one row per equipment_values reading across ALL time, no double-count. LEGACY-PRIORITY (T2b): COLD (hist) owns ts_value <= cutover_ts, HOT (live.equipment_values) owns ts_value > cutover_ts, cutover_ts = max(hist.ts_value) per enterprise (hist_cutover). Surfaces year/month (hot via EXTRACT, cold = partition cols) so a bounded query prunes the cold parquet. Consumers MUST carry a tenant id_enterprise literal (no RLS engine) AND a year/month predicate (else full cold scan). read-api /v1/historian/production-series + Superset ev_all virtual dataset.';
COMMENT ON VIEW ev_all_events IS
  'THE hot+cold EE (downtime/OEE-event) serving surface — no double-count. HOT-ANCHORED (the MIRROR of ev_all/hist_cutover). Surfaces year/month for cold pruning. Tenant fence = id_enterprise literal.';
COMMENT ON FOREIGN TABLE live.equipment_events IS
  'HOT side of ev_all_events. postgres_fdw foreign table onto packiot_analytics.silver.equipment_events (downtime / OEE-reconstruction events) via server live_pg. IMPORT-ed (full remote column set, ~26 cols) rather than pinned.';
