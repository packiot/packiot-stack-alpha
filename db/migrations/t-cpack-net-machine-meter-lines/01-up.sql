-- t-cpack-net-machine-meter-lines — CPACK meter lines: net from the outfeed machine
--
-- Follows t-line-lead-net-machine (L5). Legacy meters a CPACK line as gross = infeed
-- (the lead, BREYER/DXL) and net = outfeed (TEXA/TCX); see
-- docs/clients/cpack-legacy-oracle-line-meters.md. Verified per line against legacy
-- packiot40 line net, 2026-09-13..09-26 (analytics outfeed net / legacy line net):
--   L8  → L8-TCX   0.996      L10 → L10-TCX  0.996
--   L4  → L4-TEXA  1.000 through 09-22; L4-TEXA/RMH/POLYTYPE stopped counting on
--                  09-24 in legacy too (factory side). Line-lead falls back to
--                  net = gross per hour while the outfeed is silent — no worse than now.
--   L6  → L6-TEXA  1.000 through 09-23 17:00 UTC; after that its net was clamped by the
--                  WS1 spike-guard interval bug (fixed in the decoder, history repaired).
-- NOT L3: its member counter roles are swapped at ingestion (L3-BREYER reports its count
-- as net, L3-TEXA as gross), so net_machine would read an empty stream. Separate fix.
-- Idempotent; ent 3 and its sandbox twin 2000003, resolved by parent + name.
BEGIN;

UPDATE core.equipments l
   SET net_machine = m.id_equipment
  FROM core.equipments m,
       (VALUES ('L4','L4-TEXA'), ('L6','L6-TEXA'), ('L8','L8-TCX'), ('L10','L10-TCX')) AS x(line, outfeed)
 WHERE l.id_enterprise IN (3, 2000003) AND l.tp_equipment = 3 AND l.nm_equipment = x.line
   AND m.id_parentequipment = l.id_equipment AND m.nm_equipment = x.outfeed
   AND l.net_machine IS DISTINCT FROM m.id_equipment;

COMMIT;
