-- t-line-lead-net-machine — line NET source separate from the lead (CPACK L5)
--
-- SYMPTOM (2026-09-25): CPACK L5 PO 897120 showed net == gross in the new stack; legacy
-- showed gross 43,286 / net 29,630. Legacy meters a line as gross = first machine
-- (BREYER, infeed) and net = last machine (TEXA, outfeed); see
-- docs/clients/cpack-legacy-oracle-line-meters.md.
--
-- ROOT CAUSE: the line-lead pass reads net from lead_machine. CPACK's lead is the
-- INFEED (BREYER), which only counts gross, so net fell back to gross (quality 1.0).
-- gross_machine cannot express this: it moves gross AND the PO event source off the
-- line (compute.go COALESCE(gross_machine, self)), and CPACK's line events live on
-- the line itself.
--
-- FIX: net_machine names the NET/output source; line_lead.go and compute.go resolve
-- net_id = COALESCE(net_machine, lead_machine). NULL everywhere else ⇒ unchanged.
-- Set for CPACK L5 (ent 3) and its sandbox twin (ent 2000003) to the line's TEXA.
-- Additive + idempotent. Apply BEFORE the stream-engine that reads the column.
BEGIN;

ALTER TABLE core.equipments
    ADD COLUMN IF NOT EXISTS net_machine bigint REFERENCES core.equipments(id_equipment);

COMMENT ON COLUMN core.equipments.net_machine IS
  'LINE (tp=3) NET/output source for line-from-lead OEE when it is not the lead_machine (e.g. CPACK: lead = infeed BREYER for availability, net counted on the outfeed TEXA). NULL ⇒ net from lead_machine.';

UPDATE core.equipments l
   SET net_machine = m.id_equipment
  FROM core.equipments m
 WHERE l.id_enterprise IN (3, 2000003) AND l.tp_equipment = 3 AND l.nm_equipment = 'L5'
   AND m.id_parentequipment = l.id_equipment AND m.nm_equipment = 'L5-TEXA'
   AND l.net_machine IS DISTINCT FROM m.id_equipment;

COMMIT;
