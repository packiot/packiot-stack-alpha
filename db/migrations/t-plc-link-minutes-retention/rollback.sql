-- rollback for t-plc-link-minutes-retention: back to "no policy, no catalog row" (grows forever).
-- Chunks the policy already dropped are not restored (they were > 90 days old).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';
SELECT remove_retention_policy('silver.plc_link_minutes'::regclass, if_exists => true);
DELETE FROM ops.retention_policy WHERE relation = 'silver.plc_link_minutes';
COMMIT;
