-- t237 P-silver — EXPAND: move the 9 current-state grains public → silver + auto-updatable public shims.
--
-- WHY: silver is already the live-tier home of the facts (equipment_values/events/
-- equipment_live_metrics). The 6 equipment_live_* + area_live_{day,shift} + site_live_day
-- current-state grains belong with them. `silver` is ALREADY on the DB search_path (before
-- public), so every unqualified NON-SE reader (read-api liveUNS datasets, mission-control)
-- resolves to the silver base the instant the move lands — no path change, no pgbouncer bounce
-- needed for reads.
--
-- The public shim views bridge stream-engine, which is PUBLIC-QUALIFIED (not search_path-
-- absorbed): it writes the grains via TWO paths — (a) the uns/pocontrol live-state SINK on the
-- Dest.GrainSchema knob (Phase 1 peeled → flipped to "silver" in the accompanying deploy) and
-- (b) the rollup UPDATE in internal/rollup/{grains,entity_grains}.go on Dest.EvSchema="public"
-- (DELIBERATELY DEFERRED in Phase 1, owned by #228/#233). Path (b) keeps writing
-- public.equipment_live_* → the shim → silver base. The shims are therefore a PERMANENT SE
-- rollup bridge until #228/#233 requalify the rollup constants; they are NOT contracted at
-- P-silver. (Matches the P-app.2 carry-forward: never drop a public shim a still-public-qualified
-- stream-engine path reads/writes.)
--
-- Shim write-safety: the rollup does UPDATE ... FROM on the grain (no ON CONFLICT); a plain
-- SELECT * view is auto-updatable and passes UPDATE...FROM through to the silver base (proven in
-- P-barcode/P-app.2 for the ON CONFLICT(col) case; UPDATE...FROM is the simpler case).
--
-- SET SCHEMA auto-moves owned sequences by OID (none on the grains — natural keys). The only
-- DB-internal dependent is serving.production_information (v) on equipment_live_shift — OID-bound,
-- survives the move. Fully reversible: rollback.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';

ALTER TABLE public.equipment_live_day   SET SCHEMA silver;
ALTER TABLE public.equipment_live_hour  SET SCHEMA silver;
ALTER TABLE public.equipment_live_job   SET SCHEMA silver;
ALTER TABLE public.equipment_live_month SET SCHEMA silver;
ALTER TABLE public.equipment_live_shift SET SCHEMA silver;
ALTER TABLE public.equipment_live_week  SET SCHEMA silver;
ALTER TABLE public.area_live_day        SET SCHEMA silver;
ALTER TABLE public.area_live_shift      SET SCHEMA silver;
ALTER TABLE public.site_live_day        SET SCHEMA silver;

CREATE VIEW public.equipment_live_day   AS SELECT * FROM silver.equipment_live_day;
CREATE VIEW public.equipment_live_hour  AS SELECT * FROM silver.equipment_live_hour;
CREATE VIEW public.equipment_live_job   AS SELECT * FROM silver.equipment_live_job;
CREATE VIEW public.equipment_live_month AS SELECT * FROM silver.equipment_live_month;
CREATE VIEW public.equipment_live_shift AS SELECT * FROM silver.equipment_live_shift;
CREATE VIEW public.equipment_live_week  AS SELECT * FROM silver.equipment_live_week;
CREATE VIEW public.area_live_day        AS SELECT * FROM silver.area_live_day;
CREATE VIEW public.area_live_shift      AS SELECT * FROM silver.area_live_shift;
CREATE VIEW public.site_live_day        AS SELECT * FROM silver.site_live_day;

COMMIT;
