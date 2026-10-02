-- rollback t-backfill-production-targets-default
--
-- Removes the forward trigger + helper functions. The backfilled target rows are
-- intentionally NOT deleted — they are valid config now (a line with a target is
-- the correct state). To also strip the backfilled rows, run per-tenant:
--   DELETE FROM config.production_targets pt USING core.equipments e
--    WHERE e.id_equipment = pt.id_equipment AND e.id_enterprise = <N> AND e.tp_equipment = 3;

BEGIN;

DROP TRIGGER IF EXISTS trg_seed_line_default_target ON core.equipments;
DROP FUNCTION IF EXISTS config.piot_seed_line_default_target();
DROP FUNCTION IF EXISTS config.piot_line_default_target_hour(int);

COMMIT;
