-- cpack-l8l10-outfeed-counter-fix.sql — task #59 (2026-08-26)
--
-- WHAT / WHY
-- ----------
-- L8 and L10 twin-line NET was 0 (NULL) in packiot_analytics (F3) because the LINE
-- rows' Phase-9 outfeed counter pointed at TEXA (count-index 222 / 567), whose reader
-- register DB1,DINT20 is STALE on the current PLC — our :1880 reader reads it as
-- 626329 (an unrelated counter) on L8 and 0 (empty) on L10, so TEXA contributes nothing.
--
-- PROOF the correct source is TCX (DB1,DINT16), not TEXA (DB1,DINT20):
--   * Oracle packiot40: TEXA(222)≡TCX(221) and TEXA(567)≡TCX(566) byte-for-byte over 24h
--     (max net_production_val diff = 0) — same physical outfeed count.
--   * Our reader's TCX@DB1,DINT16 matches the oracle (L8 217502≈217796, L10 254543≈254927)
--     and TCX (id 75/79) already flows to F3 with net matching the oracle line net.
--
-- FIX: point the L8/L10 LINE outfeed counter at TCX (221 / 566). The decoder reseeds
-- Parameter30700 from packml_register every ~5 min, so line net repopulates within one cycle.
--
-- VERIFIED live (2026-08-26 04:2x UTC, same 10-min window vs oracle):
--   L8  line net 0 → 917  (oracle 910, ~1%)      L10 line net 0 → 1098 (oracle 1191, poll skew)
--   L4/L6 lines NOT regressed. Reversible: swap the SET values back to 222 / 567.
--
-- Idempotent — guarded on the old value.

UPDATE packml_register SET id_outfeedcounter = 221
 WHERE id_equipment = 51 AND packml_topic = 'CPACK/SC/LINHAS/L8'  AND id_outfeedcounter = 222;

UPDATE packml_register SET id_outfeedcounter = 566
 WHERE id_equipment = 52 AND packml_topic = 'CPACK/SC/LINHAS/L10' AND id_outfeedcounter = 567;

-- REVERT:
--   UPDATE packml_register SET id_outfeedcounter = 222 WHERE id_equipment = 51;
--   UPDATE packml_register SET id_outfeedcounter = 567 WHERE id_equipment = 52;
