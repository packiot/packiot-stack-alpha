-- t279 — resolve the enum-coded / PLC-state core columns the t278a/t278f/t278g
-- documentation pass left with a "CONFIRM / UNCERTAIN" marker.
--
-- Each comment below is grounded in real evidence gathered 2026-09-13:
--   (a) the authoring UI — csadmin option arrays + Zod schemas (the source of
--       truth for what a CS engineer sets),
--   (b) the consumers — front4 OEE lib, edge-api generate-packml-config, and the
--       stream-engine Go rollup/deriver (what actually READS the value), and
--   (c) live staging DB distinct-value counts (what values actually occur).
-- Idempotent (COMMENT ON is a catalog upsert). See rollback.sql for the prior text.

------------------------------------------------------------------------------
-- enterprises.scrap_calc_type  (int, default 1) — RESOLVED
------------------------------------------------------------------------------
COMMENT ON COLUMN core.enterprises.scrap_calc_type IS
'Enterprise-level enum selecting the scrap-percentage DENOMINATOR. 0 = % of GROSS production; 1 = % of GROSS production (DEFAULT — same GROSS branch as 0, 0-vs-1 not distinguished anywhere); 2 = % of NET production. Formula (front4 src/lib/oee/scrapPercent.ts:11-15,35): type 2 -> (gross-net)/net, else -> (gross-net)/gross; mirrors edge-node-red OEE SQL "case scrap_calc_type when 2 then scrap/net else scrap/gross". Source: csadmin enterprise-form.tsx SCRAP options + schemas/index.ts (min 0, max 2); edge-api enterprises-dao default 1. Live staging: all 9 enterprises = 1.';

------------------------------------------------------------------------------
-- equipments.net_production_type  (int) — RESOLVED
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.net_production_type IS
'Enum selecting how NET (good) production is measured for this equipment. 0 = from sensors/counters (DEFAULT); 1 = from scanned boxes (net_production_from_boxes). Drives the OEE quality branch (edge-node-red/db/20-oee-engine-parity.sql: WHEN net_production_type=1 THEN net_production_from_boxes ELSE net_production). Source: csadmin equipment-form.tsx NET_PRODUCTION options + schemas/index.ts. Live staging: only 0 (3 rows) / NULL (280) present.';

------------------------------------------------------------------------------
-- equipments.status_type  (int; PackML Parameter[30758]) — RESOLVED (+drift note)
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.status_type IS
'PackML event-trigger type, emitted as Parameter[30758] by edge-api generate-packml-config. Authoring enum (csadmin equipment-form.tsx STATUS_TYPE + schemas/index.ts): 0 = instant (events created upstream in the pipeline); 5 = 5-min-average / CPAC (OEE-worker-derived); 1 = rare outlier, semantics unconfirmed. The value is 5, NOT 4 — older docs said "4"; it appears on no tenant. Live staging: 0x130, 5x21, 1x1, NULL x131. SOURCE DRIFT (do not trust blindly): the stream-engine native events deriver + per-sample BuildEventMint gate on status_type=4 (services/stream-engine/internal/events/deriver.go:75, writers/equipment_values.go:493 "if info.StatusType != 4"), a value that matches ZERO live rows, while status_type=0 is treated as the CPAC/pipeline-created (CPACK) class served by cpac_deriver.go/closer.go (WHERE e.status_type = 0). The "=4" predicate is legacy vs the live 0/1/5 authoring values.';

------------------------------------------------------------------------------
-- equipments.ideal_speed vs production_speed  (int) — RESOLVED
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.production_speed IS
'Configured rated/ideal machine speed (units/min). THIS is the live OEE Performance ideal-speed input: emitted as PackML MachSpeed (edge-api generate-packml-config.service.ts:74-78) and the terminal fallback of the stream-engine rollup ideal_speed COALESCE chain (rollup/line_lead.go:184 COALESCE(lead_ideal, e.ideal_speed, 0); the lead-machine ideal is a subselect of production_speed; hour.go/shift.go/inferspeed.go end here). Live staging: populated (e.g. 140/147); equipments.ideal_speed NULL platform-wide. csadmin field "Production speed (units/min)", hint "Ideal speed - PackML MachSpeed", required.';

COMMENT ON COLUMN core.equipments.ideal_speed IS
'Secondary OPTIONAL equipment speed column (units/min). NOT on the active OEE performance path and NOT emitted to any PackML parameter — it only appears as a middle term in the rollup COALESCE(lead_ideal, e.ideal_speed, 0) and is NULL platform-wide on staging. The live configured ideal speed is equipments.production_speed (see its comment). front4 reads a computed oee_info.ideal_speed off the metrics view-model, not this column. csadmin exposes it under "Optional settings".';

------------------------------------------------------------------------------
-- equipments.minimum_ideal_performance_threshold  (real) — RESOLVED
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.minimum_ideal_performance_threshold IS
'Numeric lower bound of the ideal-performance band (csadmin default 35; type comment: value in 0..1, UI collects a percent). STORED/edited only — NOT emitted to any PackML parameter (unlike minimum_performance_threshold, which -> Parameter[30750] min-speed-threshold). No OEE consumer located in front4/stream-engine. Source: csadmin equipment-form.tsx + schemas/index.ts; edge-api generate-packml-config emits only minimum_performance_threshold. Live staging: NULL on all 283 rows.';

------------------------------------------------------------------------------
-- equipments.exclude_idle_from_availability  (bool) — RESOLVED (storage-only)
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.exclude_idle_from_availability IS
'If true, idle time is excluded from the Availability denominator for this equipment (paired with idle_timeout_seconds). STORAGE-ONLY: the worker does not yet read it — Availability still uses env CSVs (edge-api equipments-dao persists it; wiki 06-database flagged discrepancy #4). Live staging: NULL on all 283 rows.';

------------------------------------------------------------------------------
-- equipments.id_equipment_status_mirror  (int) — RESOLVED
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.id_equipment_status_mirror IS
'id_equipment of the tp=1 machine whose downtime/state signal this equipment mirrors (inherits). Required for sectors (tp=2) in csadmin (field "Mirrored machine (downtimes)", superRefine in schemas/index.ts:94-96). Not a DB FK (soft reference). Live staging: 0 non-NULL rows.';

------------------------------------------------------------------------------
-- equipments.sector_equipment_infeed / outfeed  (int) — best-guess, unused
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.sector_equipment_infeed IS
'For a sector (tp=2): id_equipment of the member machine that is the sector infeed/input counter source (soft reference, not a DB FK). Passthrough in edge-api (edit-equipment.dto); csadmin types it as an advanced/uncertain optional column, not surfaced in the form. No live reader located in front4/stream-engine. Live staging: 0 non-NULL rows (unused config). Exact sector-OEE semantics would be defined in the legacy OEE SQL / edge-node-red engine.';

COMMENT ON COLUMN core.equipments.sector_equipment_outfeed IS
'For a sector (tp=2): id_equipment of the member machine that is the sector outfeed/output counter source (soft reference, not a DB FK). Passthrough in edge-api; csadmin advanced/uncertain optional column, not in the form. No live reader located. Live staging: 0 non-NULL rows (unused config). Exact sector-OEE semantics would be defined in the legacy OEE SQL / edge-node-red engine.';

------------------------------------------------------------------------------
-- equipments PLC state-code mappings (int) — best-guess, unused platform-wide
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.id_equipment_state_status IS
'Legacy per-equipment PackML state-code mapping: the raw PLC state code this equipment reports for RUNNING/producing. No code->meaning enum or live reader exists in csadmin/front4/edge-api/stream-engine (csadmin types it as an advanced/uncertain optional raw column, not surfaced; edge-api passthrough only). The runtime PLC state-code->label table (e.g. 6=running, 10=stopped) is a SEPARATE concern (csadmin src/api/plc-status.ts). Live staging: NULL on all 283 rows (unused). Would be defined per-client in the legacy PLC/PackML config.';

COMMENT ON COLUMN core.equipments.id_equipment_state_idle IS
'Legacy per-equipment PackML state-code mapping: the raw PLC state code that means IDLE. No enum/reader in the new stack (see id_equipment_state_status). Live staging: NULL on all 283 rows (unused). Would be defined per-client in the legacy PLC/PackML config.';

COMMENT ON COLUMN core.equipments.id_equipment_state_starved IS
'Legacy per-equipment PackML state-code mapping: the raw PLC state code that means STARVED (no infeed). No enum/reader in the new stack (see id_equipment_state_status). Live staging: NULL on all 283 rows (unused). Would be defined per-client in the legacy PLC/PackML config.';

COMMENT ON COLUMN core.equipments.id_equipment_state_blocked IS
'Legacy per-equipment PackML state-code mapping: the raw PLC state code that means BLOCKED (downstream full). No enum/reader in the new stack (see id_equipment_state_status). Live staging: NULL on all 283 rows (unused). Would be defined per-client in the legacy PLC/PackML config.';

COMMENT ON COLUMN core.equipments.id_equipment_state_fault IS
'Legacy per-equipment PackML state-code mapping: the raw PLC state code that means FAULT. No enum/reader in the new stack (see id_equipment_state_status). Live staging: NULL on all 283 rows (unused). Would be defined per-client in the legacy PLC/PackML config.';

------------------------------------------------------------------------------
-- equipments.id_counter_status / id_packed_counter / id_equipment_type / id_plc
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipments.id_counter_status IS
'DEAD column. NULL on every equipment in both DB planes, no reader anywhere; removed from the csadmin equipment form 2026-08-31 (comment at equipment-form.tsx:26-28). Kept only so the write path does not break. Live staging: NULL on all 283 rows.';

COMMENT ON COLUMN core.equipments.id_packed_counter IS
'Legacy PLC count-index (NOT a DB FK) for the packed-units counter on this equipment. Passthrough only (edge-api DTO/DAO); not surfaced in csadmin, no live reader located. Live staging: NULL on all 283 rows (unused). A count-index, if ever set, is a factory-chosen PLC channel number, not an id_equipment.';

COMMENT ON COLUMN core.equipments.id_equipment_type IS
'Legacy equipment-category reference, distinct from tp_equipment (1/2/3). No code->meaning table or reader located in csadmin/front4/edge-api/stream-engine. Live staging: NULL on all 283 rows (unused). Would be defined in a legacy equipment-type code table (not present in the new-stack schema).';

COMMENT ON COLUMN core.equipments.id_plc IS
'VESTIGIAL. There is no PLC registry in the new stack — PLC config lives in the client_descriptors descriptor plc: blocks. csadmin intentionally never sends it (listed among vestigial columns in src/api/equipment.ts); edge-api passthrough only. Live staging: NULL on all 283 rows. Not a resolvable FK.';

------------------------------------------------------------------------------
-- production_orders.multiplier vs conversion_factor — RESOLVED
------------------------------------------------------------------------------
COMMENT ON COLUMN core.production_orders.conversion_factor IS
'Live per-order counter-units -> production-units factor (default 1); inherited from equipments.conversion_factor at creation. PO-CSV header "CONVERSION FACTOR" / "FATOR DE CONVERSAO" maps here (edge-api po-csv-mapper.ts:48; coerceConversionFactor). Live staging: all 25,700 rows = 1.';

COMMENT ON COLUMN core.production_orders.multiplier IS
'Legacy/UNUSED scalar column on production_orders — NULL on every staging row, no writer targets it. Do NOT confuse with the PO-CSV "LINE UNIT MULTIPLIER" (edge-api "multiplier"), which is a per-machine float MAP parsed from a [pos:val,...] string into the equipment_setup JSON (po-csv-mapper.ts:57,416-433) — a different shape, not this column. The live per-order unit conversion is conversion_factor. Live staging: NULL on all 25,700 rows.';

------------------------------------------------------------------------------
-- shift_hours.day_number  (int) — RESOLVED
------------------------------------------------------------------------------
COMMENT ON COLUMN core.shift_hours.day_number IS
'Weekday index of the expanded shift row: 1 = Monday ... 7 = Sunday (1-based; Monday=1, NOT 0, NOT Sunday=0). Hardproof: DB begin_time correlation — day_number=1 rows begin at second 0 (= operational week start = Monday 00:00 when week_begin=0) and day_number=7 rows begin at 518400s (= 6 days later = Sunday). Confirmed by csadmin src/lib/shift-time.ts SHIFT_DAYS (1=monday..7=sunday) and edge-api create/edit-shift-hour DTOs ("1=Monday, 6=Saturday"; Sunday=7 by the seconds correlation). Live staging: values 1..7 present.';

------------------------------------------------------------------------------
-- equipment_validation_shift.index1 / shift_hrs / index2 — legacy Montebello
--   (best-guess; exact semantics genuinely UNRESOLVED — table is empty on staging)
------------------------------------------------------------------------------
COMMENT ON COLUMN core.equipment_validation_shift.index1 IS
'Legacy back4 "Montebello" (enterprise-06) shift-validation table. index1 is the leading projection key of GetShiftValidation (read-api external_integration.go sqlShiftValidation SELECT evs.index1 first). Text, potentially numeric per the coercion note. Exact meaning (composite equipment/shift/date row key?) UNRESOLVED — would be defined in the original back4 ShiftsValidationDAO / legacy DB migration. Table is empty on staging (0 rows).';

COMMENT ON COLUMN core.equipment_validation_shift.shift_hrs IS
'Legacy Montebello shift-validation "shift hours" value (text, likely numeric). Used as a secondary sort key in the read query (external_integration.go: ORDER BY ts_value_production DESC, shift_hrs DESC). Exact format UNRESOLVED — would be defined in the legacy back4 ShiftsValidationDAO. Table is empty on staging (0 rows).';

COMMENT ON COLUMN core.equipment_validation_shift.index2 IS
'Legacy Montebello shift-validation JSONB payload column. NOT projected by any current read query (external_integration.go sqlShiftValidation does not select it) — write-only / unused in the new stack. Exact structure UNRESOLVED — would be defined in the legacy back4 ShiftsValidationDAO / original migration. Table is empty on staging (0 rows).';
