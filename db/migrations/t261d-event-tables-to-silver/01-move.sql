-- t261d — move the 4 EvSchema=public event tables → silver (completes #261's
-- EvSchema-plane re-home). Zero-gap expand/contract: SET SCHEMA + AUTO-UPDATABLE
-- public shim views (single-table SELECT *) in ONE txn, so the pre-deploy
-- stream-engine (EvSchema=public writes/reads) bridges via the shims until the
-- flows.go EvSchema→silver flip deploys. edge-api (bare equipment_events_man) +
-- read-api resolve to silver directly via the silver-first default search_path.
-- Plain tables (not hypertables) → SET SCHEMA is catalog-only.
BEGIN;
ALTER TABLE public.data_quality_event           SET SCHEMA silver;
ALTER TABLE public.equipment_events_man          SET SCHEMA silver;
ALTER TABLE public.equipment_events_cpac_shadow  SET SCHEMA silver;
ALTER TABLE public.equipment_events_low_speed    SET SCHEMA silver;

CREATE VIEW public.data_quality_event          AS SELECT * FROM silver.data_quality_event;
CREATE VIEW public.equipment_events_man         AS SELECT * FROM silver.equipment_events_man;
CREATE VIEW public.equipment_events_cpac_shadow AS SELECT * FROM silver.equipment_events_cpac_shadow;
CREATE VIEW public.equipment_events_low_speed   AS SELECT * FROM silver.equipment_events_low_speed;
COMMIT;
