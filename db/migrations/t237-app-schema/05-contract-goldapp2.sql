-- t237 P-app.2 CONTRACT — drop the gold shim views once app.-qualified code is deployed.
--
-- Precondition (GATE, per the plan): analytics-sync (replicate+replay) and read-api are
-- redeployed with app.-qualified cursor/user_screen_config statements AND a
-- `CREATE SCHEMA IF NOT EXISTS app` + `CREATE TABLE IF NOT EXISTS app.<t>` bootstrap. After
-- the deploy no LIVE service issues an UNQUALIFIED create/ref against these names, so the gold
-- shim's two jobs (creation-namespace guard + gold-first runtime bridge) are no longer needed.
-- mirror-worker-go is off (legacy-comparator profile) and is app.-qualified for parity.
--
-- After this: each table lives SOLELY in `app`; no gold/public shadow of either name.

BEGIN;
DROP VIEW gold.mirror_replay_cursor;
DROP VIEW gold.user_screen_config;
COMMIT;
