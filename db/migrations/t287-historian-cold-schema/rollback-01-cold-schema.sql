-- t287-historian-cold-schema / rollback-01-cold-schema.sql
-- Undo 01-cold-schema.sql: move the historian objects back to public, restore the
-- default search_path, drop the (now-empty) cold schema. Pure catalog reparent —
-- no data loss. OID-bound inter-view deps survive the move back.
BEGIN;

-- Move views back first, then tables (order irrelevant — OID-bound).
ALTER VIEW  cold.ev_all_events             SET SCHEMA public;
ALTER VIEW  cold.ev_all                     SET SCHEMA public;
ALTER VIEW  cold.hist_ee                    SET SCHEMA public;
ALTER VIEW  cold.hist                       SET SCHEMA public;
ALTER TABLE cold.hist_meta                  SET SCHEMA public;
ALTER TABLE cold.hist_promoted_enterprise   SET SCHEMA public;
ALTER TABLE cold.ev_events_cutover          SET SCHEMA public;
ALTER TABLE cold.hist_cutover               SET SCHEMA public;

-- Restore the pre-t287 default search_path (Postgres default).
ALTER DATABASE postgres RESET search_path;
SET search_path = "$user", public;

-- Restore the original public schema comment (pre-t287 historian-serving text).
COMMENT ON SCHEMA public IS
  'historian-gateway serving schema. Holds the hot+cold union VIEWS (ev_all EV, ev_all_events EE), the pg_duckdb read_parquet COLD source views (hist, hist_ee) and the per-enterprise disjointness boundary TABLES (hist_cutover, ev_events_cutover). Query surface for read-api /v1/historian and the Superset ev_all virtual dataset. No RLS engine here — tenant fence is a caller-supplied id_enterprise literal.';

DROP SCHEMA IF EXISTS cold;  -- now empty (default-privileges grant, if any, drops with it)

COMMIT;
