-- t-line-lead-counter-roles — which counter a line reads on its gross / net machine
--
-- CPACK L3 counts the line's INPUT on BREYER's PROCESSED counter (PLC L3 DB1,DINT0,
-- ProdProcessedCount/76) and its OUTPUT on TEXA's CONSUMED counter (DB1,DINT28,
-- ProdConsumedCount/80). Those member labels are the legacy reader's and must stay:
-- relabelling them at the reader (#909, 2026-08-25) fabricated a phantom L3 gross and
-- was reverted (docs/clients/cpack-legacy-oracle-line-meters.md §L3). The line model
-- assumed gross = the gross machine's CONSUMED column and net = the net machine's
-- PROCESSED column, so L3 got net-only on BREYER → gross := net (quality 1.0).
-- Verified 2026-09-13..09-26 against legacy line 75: BREYER processed / line gross 0.996,
-- TEXA consumed / line net 0.997.
--
-- gross_counter / net_counter pick the column ('consumed' | 'processed'); NULL keeps
-- gross ← consumed, net ← processed. Read by stream-engine line_lead.go + compute.go.
-- Additive + idempotent. Apply BEFORE the stream-engine that reads the columns.
BEGIN;

ALTER TABLE core.equipments
    ADD COLUMN IF NOT EXISTS gross_counter text,
    ADD COLUMN IF NOT EXISTS net_counter text;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'equipments_counter_roles_chk') THEN
    ALTER TABLE core.equipments ADD CONSTRAINT equipments_counter_roles_chk
      CHECK ((gross_counter IS NULL OR gross_counter IN ('consumed', 'processed'))
         AND (net_counter   IS NULL OR net_counter   IN ('consumed', 'processed')));
  END IF;
END $$;

COMMENT ON COLUMN core.equipments.gross_counter IS
  'LINE only: which counter on the gross machine (gross_machine, else lead_machine) is the line''s gross: consumed (default when NULL) or processed.';
COMMENT ON COLUMN core.equipments.net_counter IS
  'LINE only: which counter on the net machine (net_machine, else lead_machine) is the line''s net: processed (default when NULL) or consumed.';

UPDATE core.equipments l
   SET gross_counter = 'processed', net_machine = m.id_equipment, net_counter = 'consumed'
  FROM core.equipments m
 WHERE l.id_enterprise IN (3, 2000003) AND l.tp_equipment = 3 AND l.nm_equipment = 'L3'
   AND m.id_parentequipment = l.id_equipment AND m.nm_equipment = 'L3-TEXA'
   AND (l.gross_counter, l.net_machine, l.net_counter) IS DISTINCT FROM ('processed', m.id_equipment, 'consumed');

COMMIT;
