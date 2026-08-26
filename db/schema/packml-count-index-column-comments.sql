-- Option A (PackML decision, 2026-08-26): honest-semantics comments on the
-- packml_register / areas count-index columns. Idempotent (COMMENT). Applied live
-- to F3 packiot_analytics; codified here so a fresh provision reproduces them.
-- Context: these columns hold WIRE COUNT-INDICES, not id_equipment FKs. The
-- id_*counter naming invited the 2026-08-26 counterroles/Phase-9 collision.
-- id_infeedcounter/id_outfeedcounter are LIVE (read by edge-transformer
-- line_param30700_seed.go for Phase-9 line aggregation) — DO NOT DROP.
COMMENT ON COLUMN packml_register.id_infeedcounter IS
 'WIRE COUNT-INDEX (PLC count-tag position), NOT an id_equipment FK. On LINE rows (tp_equipment=3) this is the line INFEED meter index; read LIVE by edge-transformer line_param30700_seed.go to seed Parameter30700 for Phase-9 line aggregation (gated PHASE9_LINE_AGG_ENABLED). Single-consumer since the counterroles resolver was removed (ADR-0047 counterroles-removal note, 2026-08-26). Do NOT read as id_equipment — that mislabel caused the counterroles/Phase-9 collision. Add dedicated id_*_equipment columns if you ever need role FKs.';
COMMENT ON COLUMN packml_register.id_outfeedcounter IS
 'WIRE COUNT-INDEX — line OUTFEED meter index. Read LIVE by Phase-9 (see id_infeedcounter). NOT an id_equipment FK.';
COMMENT ON COLUMN packml_register.id_unit IS
 'Nullable metering-unit FK: = id_equipment for machines (tp_equipment=1), NULL for lines/sectors. NOT a duplicate of id_equipment — its NULL-ness marks non-machine rows and is load-bearing for the decoder/refdata joins. Do NOT rename to id_equipment.';
-- packml_register.id_rejectcounter was DROPPED 2026-08-26 (Option A step 2a,
-- edge-api#205 + stack#926): 0 rows platform-wide, sole reader (counterroles
-- resolver) removed the same day. Its COMMENT is gone with the column.
COMMENT ON COLUMN areas.id_infeedcounter IS 'DEPRECATED / DEAD (0 rows). Legacy count-index metadata, no functional reader (view-passthrough only). Pending drop.';
COMMENT ON COLUMN areas.id_outfeedcounter IS 'DEPRECATED / DEAD (0 rows). See id_infeedcounter.';
COMMENT ON COLUMN areas.id_rejectscounter IS 'DEPRECATED / DEAD (0 rows). See id_infeedcounter.';
