-- Roll back the agent (or set AGENT_LINK_HEALTH_ENABLED=false) first: with the
-- table gone its flushes fail (logged, counted) but ingest is unaffected.
BEGIN;
DROP VIEW IF EXISTS silver.plc_endpoint_equipment;
DROP TABLE IF EXISTS silver.plc_link_minutes;
COMMIT;
