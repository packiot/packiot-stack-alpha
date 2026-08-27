-- =============================================================================
-- Backfill: equipments.position (line flow order) for CPACK — ADR-0045 "Bronze"
-- =============================================================================
-- WHAT
--   Persists each line member's 1-based infeed→outfeed flow-order rank into the
--   existing (previously all-NULL) equipments.position column, for CPACK on F3
--   staging: ent-3 (CPACK-Staging) and its sandbox twin ent-2000003.
--
-- WHY
--   Line-level downtime/OEE attribution needs a QUERYABLE machine order. The
--   only place the order lived was Parameter30700 — a transient CSV the decoder
--   reads for counter aggregation and then discards. For own-stream tenants like
--   CPACK, Parameter30700 is not even published (packml_register.line_unit_seq is
--   NULL on every CPACK row, verified against prod packiot40), so nothing ever
--   populated the order. This backfill closes that gap for the existing rows;
--   the onboard-gen generator emits the same artifact for new clients going
--   forward (services/edge-transformer .../clientdescriptor GenerateEquipmentPositionSQL).
--
-- ORDER SOURCE (three independent, agreeing authorities)
--   1. Oracle packiot40 equipments.position for C-PACK (ent 1), mapped by name.
--   2. cpack.descriptor.yaml member list order per line (= physical infeed→outfeed).
--   3. Live per-member count_index in packml_topic paths (= legacy oracle ids),
--      monotonic with the order above.
--   packml_register.id_outfeedcounter for L8/L10 points to TCX (position 3) rather
--   than TEXA (position 4); that is a NON-authoritative F3 seeding artifact (prod
--   has these counters NULL) and does NOT change the physical flow order below.
--
-- SAFETY
--   Name-scoped + tp_equipment=1 (line and member can share a name, e.g. CER400).
--   Idempotent. Backup table captures pre-state for revert. Applied 2026-08-27.
-- =============================================================================

-- ── 1. Backup (revert source) ────────────────────────────────────────────────
DROP TABLE IF EXISTS public.bronze_position_backup_20260827;
CREATE TABLE public.bronze_position_backup_20260827 AS
  SELECT id_equipment, id_enterprise, nm_equipment, tp_equipment,
         position AS position_old, now() AS backed_up_at
  FROM equipments WHERE id_enterprise IN (3, 2000003);

-- ── 2. Apply ─────────────────────────────────────────────────────────────────
BEGIN;
WITH m(nm, pos) AS (VALUES
  ('L3-BREYER',1),('L3-POLYTYPE',2),('L3-PTH',3),('L3-RMH',4),('L3-TEXA',5),
  ('L4-BREYER',1),('L4-POLYTYPE',2),('L4-PTH',3),('L4-RMH',4),('L4-TEXA',5),
  ('L5-BREYER',1),('L5-POLYTYPE',2),('L5-PTH',3),('L5-RMH',4),('L5-TEXA',5),
  ('L6-BREYER',1),('L6-POLYTYPE',2),('L6-PTH',3),('L6-RMH',4),('L6-TEXA',5),
  ('L8-DXL',1),('L8-PTH',2),('L8-TCX',3),('L8-TEXA',4),
  ('L10-DXL',1),('L10-PTH',2),('L10-TCX',3),('L10-TEXA',4),
  -- single-machine cells: lone member → position 1
  ('CER400',1),('DUBUTI1',1),('DUBUTI2',1),('HOTMADAG',1),('ISIMAT',1),
  ('BREYER1',1),('BREYER2',1),('POLYTYPE1',1),('POLYTYPE2',1),('PTH40-03',1),
  ('PTH80S',1),('FLEXO',1),('SLEEVE1',1),('SLEEVE2',1))
UPDATE equipments e SET position = m.pos, updated_at = now()
FROM m
WHERE m.nm = e.nm_equipment
  AND e.tp_equipment = 1
  AND e.id_enterprise IN (3, 2000003);

-- Guard: exactly 84 members positioned (42 per tenant), else abort.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM equipments
   WHERE tp_equipment = 1 AND id_enterprise IN (3, 2000003) AND position IS NOT NULL;
  IF n <> 84 THEN
    RAISE EXCEPTION 'expected 84 positioned members, got %', n;
  END IF;
END $$;
COMMIT;

-- ── 3. Verify ────────────────────────────────────────────────────────────────
-- SELECT id_enterprise, count(*) tp1_total, count(position) tp1_positioned
--   FROM equipments WHERE id_enterprise IN (3,2000003) AND tp_equipment=1 GROUP BY 1;
--   → both tenants: 42 / 42.

-- ── 4. REVERT (restores prior NULLs) ─────────────────────────────────────────
-- BEGIN;
--   UPDATE equipments e SET position = b.position_old, updated_at = now()
--     FROM public.bronze_position_backup_20260827 b
--    WHERE b.id_equipment = e.id_equipment;
--   DROP TABLE public.bronze_position_backup_20260827;
-- COMMIT;
