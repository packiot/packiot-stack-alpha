-- t246 · drop the DEAD customer_dashboards schema. 3 Portuguese legacy Hasura-parity
-- dashboard tables (dashboard_{paradas,producao,timeline}_24h) — frozen 69 days
-- (last write 2026-07-01), ZERO new-stack consumers (no Go service, no front4/operator,
-- no Superset dataset, 0 serving/bi deps). Legacy artifact. Backed up pre-drop.
-- FOLLOW-UP: strip customer_dashboards from edge-node-red/db/*.sql so a fresh bootstrap
-- doesn't recreate it (00-schema.sql + 17-/18-/20-/21-/40- parity files).
DROP SCHEMA IF EXISTS customer_dashboards CASCADE;
