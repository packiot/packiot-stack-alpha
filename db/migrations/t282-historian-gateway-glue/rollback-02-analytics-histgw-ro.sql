-- t282 ROLLBACK (analytics side) — reverse 02-analytics-histgw-ro.sql on
-- packiot_analytics (10.10.10.89). Drops the least-privilege remote role.
-- Run rollback-01-gateway.sql FIRST (repoints the browser mapping off histgw_ro),
-- else the role is still referenced by the gateway user mapping.
\set ON_ERROR_STOP on
REVOKE SELECT ON silver.equipment_events  FROM histgw_ro;
REVOKE SELECT ON silver.equipment_values  FROM histgw_ro;
REVOKE USAGE  ON SCHEMA silver            FROM histgw_ro;
DROP ROLE IF EXISTS histgw_ro;
