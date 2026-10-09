-- t270 — necessity-audit Phase C drop: silver.equipment_live_hour + equipment_live_week.
-- Their writer was removed in #263 (PR #1226, stream-engine uns.go). Verified live: after
-- the deploy the new engine froze both tables' last_updated (~30 min stale) while the KEPT
-- grains (equipment_live_month/shift) stayed fresh (<1 min) — proving the writer-stop took
-- and these two are now unwritten. Zero readers (audit #263). Safe drop. rollback.sql
-- recreates the exact structure (a code-revert of #1226 restarts the writer).
DROP TABLE IF EXISTS silver.equipment_live_hour;
DROP TABLE IF EXISTS silver.equipment_live_week;
