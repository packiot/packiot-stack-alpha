-- t237 P-app.2 EXPAND — re-home the 2 GOLD→APP self-heal tables (task #237).
--
--   mirror_replay_cursor : gold = LIVE (2 rows, cursor advancing) · public = STALE dup (frozen ~7h)
--   user_screen_config   : gold = LIVE (0 rows, read-api ensureSchema home) · public = dup (0 rows)
--
-- The §4.3 split-brain: the DB search_path resolves gold BEFORE app before public,
-- so the live copy sits in `gold`; `public` holds a stale/redundant twin. This phase
-- makes each table live SOLELY in `app` (its correct medallion-external home).
--
-- WHY A **GOLD** SHIM VIEW (not public): with the path "$user",gold,silver,bronze,barcode,app,public
-- the CREATION NAMESPACE for an unqualified CREATE is `gold` (first schema). A running OLD
-- service whose bootstrap runs `CREATE TABLE IF NOT EXISTS <unqualified>` would, after the
-- table leaves gold, re-spawn an EMPTY gold shadow (P0 creation-namespace rule) and then
-- write there. A gold VIEW of the same name makes that IF-NOT-EXISTS a NO-OP (proven: a view
-- in the creation namespace satisfies the existence check) AND bridges gold-first unqualified
-- runtime reads/writes through to app. A public shim would NOT guard the create (lands in gold
-- regardless). The gold shim is dropped in 05-contract once the app.-qualified code is deployed.
--
-- Atomic; sub-second ACCESS EXCLUSIVE per table. SET SCHEMA auto-moves owned objects by OID
-- (indexes; these tables have no owned sequences). No view/function depends on either table
-- (verified via pg_depend/pg_rewrite). search_path already carries `app` (P-app.1) — no path
-- change this phase.

SET lock_timeout = '3s';

BEGIN;

-- mirror_replay_cursor: drop the stale public twin, lift the live gold copy → app, gold-guard.
DROP TABLE public.mirror_replay_cursor;
ALTER TABLE gold.mirror_replay_cursor SET SCHEMA app;
CREATE VIEW gold.mirror_replay_cursor AS SELECT * FROM app.mirror_replay_cursor;

-- user_screen_config: same shape (both copies empty; gold is read-api's ensureSchema home).
DROP TABLE public.user_screen_config;
ALTER TABLE gold.user_screen_config SET SCHEMA app;
CREATE VIEW gold.user_screen_config AS SELECT * FROM app.user_screen_config;

COMMIT;
