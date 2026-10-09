-- ============================================================================
-- f3-phasec-history-backfill.reverse.sql
-- Exact reversal of f3-phasec-history-backfill.sql on packiot_analytics (F3),
-- CPACK ent-3. Every DELETE is scoped to ent-3 AND fenced to a window that was
-- EMPTY before the backfill, so it removes exactly the backfilled rows and
-- never the live post-cutover data (the live pipeline only appends recent rows,
-- all strictly at/after these boundaries).
--
-- Boundaries were the pre-backfill min() for each grain (captured at apply time):
--   equipment_events        earliest ent-3 ts_event  = 2026-07-02 10:35:00+00
--   equipment_runtime_shift earliest ent-3 ts_value  = 2026-07-23 02:10:00+00
--   user_logs               earliest ent-3 ts_event  = 2026-08-21 18:31:24+00
--
--   psql -v dryrun=true  -f f3-phasec-history-backfill.reverse.sql   (BEGIN..ROLLBACK)
--   psql -v dryrun=false -f f3-phasec-history-backfill.reverse.sql   (COMMIT)
-- ============================================================================

\set ON_ERROR_STOP on
\timing on
BEGIN;

-- The 43 business keys minted by the backfill (id_orders absent from F3 before).
CREATE TEMP TABLE _bf_orders(id_order int) ON COMMIT DROP;
INSERT INTO _bf_orders(id_order) VALUES
 (100047),(100048),(100051),(100052),(842018),(892018),(892162),(892313),(8924530),
 (892573),(892643),(892645),(892657),(892658),(892660),(892661),(892682),(892683),
 (892685),(892688),(892691),(892886),(892903),(893014),(893017),(893020),(893021),
 (893023),(893027),(893031),(893040),(893051),(893092),(893132),(893167),(893173),
 (893197),(893200),(893257),(894354),(894374),(894387),(990001);

-- 1. runtime rows of the backfilled POs (delete before the POs; soft ref).
DELETE FROM production_orders_runtime r
USING production_orders po
WHERE r.id_production_order = po.id_production_order
  AND po.id_enterprise = 3
  AND po.id_order IN (SELECT id_order FROM _bf_orders);

-- 2. the backfilled POs themselves.
DELETE FROM production_orders po
WHERE po.id_enterprise = 3
  AND po.id_order IN (SELECT id_order FROM _bf_orders);

-- 3. deep-history events (window empty before backfill).
DELETE FROM equipment_events
WHERE id_enterprise = 3
  AND ts_event < '2026-07-02 10:35:00+00';

-- 4. deep-history shift grain (window empty before backfill).
DELETE FROM equipment_runtime_shift s
USING equipments e
WHERE e.id_equipment = s.id_equipment AND e.id_enterprise = 3
  AND s.ts_value < '2026-07-23 02:10:00+00';

-- 5. backfilled audit logs (window empty before backfill).
DELETE FROM user_logs
WHERE id_enterprise = 3
  AND ts_event < '2026-08-21 18:31:24+00';

-- verify back to the pre-backfill baseline.
SELECT 'AFTER REVERSE' AS section,
  (SELECT count(*) FROM production_orders WHERE id_enterprise=3)                          AS po,
  (SELECT count(*) FROM production_orders_runtime por
     JOIN production_orders po ON po.id_production_order=por.id_production_order
     WHERE po.id_enterprise=3)                                                            AS runtime,
  (SELECT count(*) FROM equipment_events WHERE id_enterprise=3)                           AS events,
  (SELECT count(*) FROM user_logs WHERE id_enterprise=3)                                  AS user_logs,
  (SELECT count(*) FROM equipment_runtime_shift s
     JOIN equipments e ON e.id_equipment=s.id_equipment AND e.id_enterprise=3)            AS runtime_shift,
  (SELECT count(*) FROM v_report_downtimes WHERE id_enterprise=3 AND op IS NOT NULL)      AS vdt_op_notnull;

\if :dryrun
  \echo '>>> DRY RUN — rolling back.'
  ROLLBACK;
\else
  \echo '>>> LIVE — committing reversal.'
  COMMIT;
\endif
