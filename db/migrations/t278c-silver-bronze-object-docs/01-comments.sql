-- t278c — SILVER + BRONZE object documentation (packiot_analytics, staging)
-- COMMENT ON TABLE/VIEW + COMMENT ON COLUMN for every relation in the silver
-- and bronze schemas. Idempotent, non-destructive (metadata only). Continuous
-- aggregates are exposed as relkind='v' → COMMENT ON VIEW (COMMENT ON
-- MATERIALIZED VIEW errors: "not a materialized view").
--
-- Sources of truth: live pg_catalog columns + stream-engine
-- (internal/rollup/silver.go, internal/flows/flows.go, internal/writers/
-- equipment_values.go, internal/uns/*, internal/events/*) + CLAUDE.md.
-- Medallion (ADR-0036): BRONZE = immutable append-only raw landing;
-- SILVER = merged/deduped facts + rollup caggs + current-state grains + DQ plane.

-- =====================================================================
-- BRONZE — immutable append-only raw landing (ADR-0036 B1)
-- =====================================================================

COMMENT ON TABLE bronze.equipment_values_raw IS
'BRONZE (ADR-0036 B1): immutable append-only raw landing of every SparkPlug equipment_values sample, one row PER MESSAGE (no UPSERT/dedup — unlike silver.equipment_values). Written by stream-engine writers.BuildRawAppend, gated by BRONZE_RAW_APPEND (default false) so currently DORMANT / 0-row on staging. Never UPDATE/DELETE. Column set mirrors silver.equipment_values plus append bookkeeping (ingested_at, source_seq).';

COMMENT ON COLUMN bronze.equipment_values_raw.id_equipment IS 'FK core.equipments.id_equipment — machine/sector/line the sample belongs to.';
COMMENT ON COLUMN bronze.equipment_values_raw.ts_value IS 'Sample event timestamp (tz-aware) as reported by the edge.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN bronze.equipment_values_raw.id_site IS 'Denormalized hierarchy FK (core.sites).';
COMMENT ON COLUMN bronze.equipment_values_raw.id_area IS 'Denormalized hierarchy FK (core.areas).';
COMMENT ON COLUMN bronze.equipment_values_raw.net_production_incr IS 'Net (good) production produced since previous sample (count/units, incremental).';
COMMENT ON COLUMN bronze.equipment_values_raw.gross_production_incr IS 'Gross production produced since previous sample (count/units, incremental).';
COMMENT ON COLUMN bronze.equipment_values_raw.scrap_incr IS 'Scrap/rejects produced since previous sample (count/units, incremental).';
COMMENT ON COLUMN bronze.equipment_values_raw.speed IS 'Instantaneous machine speed at sample time (units/time as configured).';
COMMENT ON COLUMN bronze.equipment_values_raw.id_order IS 'Client-facing production order code as string (PLC-reported id_order, PackML 30800s).';
COMMENT ON COLUMN bronze.equipment_values_raw.conversion_factor IS 'Units-per-cycle conversion factor at sample time.';
COMMENT ON COLUMN bronze.equipment_values_raw.number_cavities IS 'Mold cavity count / parallel-output multiplier at sample time.';
COMMENT ON COLUMN bronze.equipment_values_raw.faults IS 'Raw PLC fault codes for the sample (JSONB).';
COMMENT ON COLUMN bronze.equipment_values_raw.analogs IS 'Raw analog/auxiliary PLC readings for the sample (JSONB).';
COMMENT ON COLUMN bronze.equipment_values_raw.signal_quality IS 'SparkPlug signal-quality indicator for the sample.';
COMMENT ON COLUMN bronze.equipment_values_raw.net_production_val IS 'Net production absolute totalizer value (count) as read from the PLC.';
COMMENT ON COLUMN bronze.equipment_values_raw.gross_production_val IS 'Gross production absolute totalizer value (count) as read from the PLC.';
COMMENT ON COLUMN bronze.equipment_values_raw.scrap_val IS 'Scrap absolute totalizer value (count) as read from the PLC.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_shift IS 'FK core.shifts — shift in effect at sample time.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_team IS 'FK to the team on shift at sample time.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_shift_hour IS 'FK core.shift_hours — calendar-expanded shift slot at sample time.';
COMMENT ON COLUMN bronze.equipment_values_raw.box_code IS 'Barcode/box identifier reported with the sample.';
COMMENT ON COLUMN bronze.equipment_values_raw.transaction_code IS 'Transaction/label code reported with the sample.';
COMMENT ON COLUMN bronze.equipment_values_raw.state IS 'PackML machine state (e.g. 6=RUNNING, 10=STOPPED) at sample time.';
COMMENT ON COLUMN bronze.equipment_values_raw.mode IS 'PackML machine mode at sample time.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_production_order IS 'FK core.production_orders — resolved internal PO id.';
COMMENT ON COLUMN bronze.equipment_values_raw.ts_value_production IS 'Production/business date the sample is attributed to.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_equipment_line_infeed IS 'id_equipment of the line-infeed machine for line-differencing (#569).';
COMMENT ON COLUMN bronze.equipment_values_raw.id_equipment_line_outfeed IS 'id_equipment of the line-outfeed machine for line-differencing (#569).';
COMMENT ON COLUMN bronze.equipment_values_raw.net_production_incr_quality IS 'SparkPlug per-metric quality flag for net_production_incr.';
COMMENT ON COLUMN bronze.equipment_values_raw.gross_production_incr_quality IS 'SparkPlug per-metric quality flag for gross_production_incr.';
COMMENT ON COLUMN bronze.equipment_values_raw.scrap_incr_quality IS 'SparkPlug per-metric quality flag for scrap_incr.';
COMMENT ON COLUMN bronze.equipment_values_raw.speed_quality IS 'SparkPlug per-metric quality flag for speed.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_order_quality IS 'SparkPlug per-metric quality flag for id_order.';
COMMENT ON COLUMN bronze.equipment_values_raw.conversion_factor_quality IS 'SparkPlug per-metric quality flag for conversion_factor.';
COMMENT ON COLUMN bronze.equipment_values_raw.number_cavities_quality IS 'SparkPlug per-metric quality flag for number_cavities.';
COMMENT ON COLUMN bronze.equipment_values_raw.net_production_val_quality IS 'SparkPlug per-metric quality flag for net_production_val.';
COMMENT ON COLUMN bronze.equipment_values_raw.gross_production_val_quality IS 'SparkPlug per-metric quality flag for gross_production_val.';
COMMENT ON COLUMN bronze.equipment_values_raw.scrap_val_quality IS 'SparkPlug per-metric quality flag for scrap_val.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_shift_quality IS 'SparkPlug per-metric quality flag for id_shift.';
COMMENT ON COLUMN bronze.equipment_values_raw.state_quality IS 'SparkPlug per-metric quality flag for state.';
COMMENT ON COLUMN bronze.equipment_values_raw.mode_quality IS 'SparkPlug per-metric quality flag for mode.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_production_order_quality IS 'SparkPlug per-metric quality flag for id_production_order.';
COMMENT ON COLUMN bronze.equipment_values_raw.ts_value_production_quality IS 'SparkPlug per-metric quality flag for ts_value_production.';
COMMENT ON COLUMN bronze.equipment_values_raw.id_equipment_line_connected IS 'id_equipment of the line this machine is connected to (line membership).';
COMMENT ON COLUMN bronze.equipment_values_raw.position_in_equipment_line IS 'Ordinal position of this machine within its line.';
COMMENT ON COLUMN bronze.equipment_values_raw.is_equipment_line_infeed IS 'Flag (1/0): this machine is the line infeed point.';
COMMENT ON COLUMN bronze.equipment_values_raw.is_equipment_line_outfeed IS 'Flag (1/0): this machine is the line outfeed point.';
COMMENT ON COLUMN bronze.equipment_values_raw.process_scrap_incr IS 'Process (in-line) scrap produced since previous sample (count, incremental).';
COMMENT ON COLUMN bronze.equipment_values_raw.process_scrap_val IS 'Process scrap absolute totalizer value (count).';
COMMENT ON COLUMN bronze.equipment_values_raw.process_scrap_incr_quality IS 'SparkPlug per-metric quality flag for process_scrap_incr.';
COMMENT ON COLUMN bronze.equipment_values_raw.process_scrap_val_quality IS 'SparkPlug per-metric quality flag for process_scrap_val.';
COMMENT ON COLUMN bronze.equipment_values_raw.tp_equipment IS 'Equipment type (1=machine, 2=sector, 3=line).';
COMMENT ON COLUMN bronze.equipment_values_raw.sub_mode IS 'PackML sub-mode string reported with the sample.';
COMMENT ON COLUMN bronze.equipment_values_raw.ideal_production_speed IS 'Ideal/nominal production speed (units/time) at sample time (PackML 30701).';
COMMENT ON COLUMN bronze.equipment_values_raw.check_number IS 'Monotonic per-equipment counter/sequence used for gap detection.';
COMMENT ON COLUMN bronze.equipment_values_raw.ingested_at IS 'Wall-clock time the row was appended to bronze (ingest bookkeeping).';
COMMENT ON COLUMN bronze.equipment_values_raw.source_seq IS 'Monotonic ingest sequence assigned at append (ordering/lineage).';

COMMENT ON TABLE bronze.equipment_events_raw IS
'BRONZE (ADR-0036 B1): immutable append-only raw landing of equipment status/downtime events (mirrors silver.equipment_events plus ingested_at/source_seq). Written by stream-engine BuildEventMintRaw, gated by BRONZE_RAW_APPEND (default false) → currently DORMANT / 0-row on staging. Never UPDATE/DELETE. NOTE: catalog attnum 4 is a dropped column.';

COMMENT ON COLUMN bronze.equipment_events_raw.id_equipment IS 'FK core.equipments.id_equipment the event belongs to.';
COMMENT ON COLUMN bronze.equipment_events_raw.ts_event IS 'Event start timestamp (tz-aware).';
COMMENT ON COLUMN bronze.equipment_events_raw.status IS 'Event/machine status code at ts_event (e.g. 10=STOPPED).';
COMMENT ON COLUMN bronze.equipment_events_raw.txt_downtime_notes IS 'Free-text downtime justification note.';
COMMENT ON COLUMN bronze.equipment_events_raw.idle IS 'Idle classification code/string for the event.';
COMMENT ON COLUMN bronze.equipment_events_raw.idle_processed IS 'Whether the idle classification has been processed.';
COMMENT ON COLUMN bronze.equipment_events_raw.forced_creation_system IS 'True if the event was system-forced rather than PLC-derived.';
COMMENT ON COLUMN bronze.equipment_events_raw.fault IS 'PLC fault code associated with the event.';
COMMENT ON COLUMN bronze.equipment_events_raw.fault_processed IS 'Whether the fault has been processed.';
COMMENT ON COLUMN bronze.equipment_events_raw.cd_machine IS 'Machine-level downtime code.';
COMMENT ON COLUMN bronze.equipment_events_raw.cd_category IS 'Downtime category code.';
COMMENT ON COLUMN bronze.equipment_events_raw.cd_subcategory IS 'Downtime subcategory code.';
COMMENT ON COLUMN bronze.equipment_events_raw.change_over IS 'True if the event is a changeover/setup stop.';
COMMENT ON COLUMN bronze.equipment_events_raw.planned_downtime IS 'True if the downtime is planned.';
COMMENT ON COLUMN bronze.equipment_events_raw.ts_end IS 'Event end timestamp (tz-aware); NULL while still open.';
COMMENT ON COLUMN bronze.equipment_events_raw.duration IS 'Event duration in seconds (ts_end - ts_event).';
COMMENT ON COLUMN bronze.equipment_events_raw.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN bronze.equipment_events_raw.desc_category IS 'Downtime category human-readable description.';
COMMENT ON COLUMN bronze.equipment_events_raw.desc_subcategory IS 'Downtime subcategory human-readable description.';
COMMENT ON COLUMN bronze.equipment_events_raw.cd_category_client IS 'Client-facing numeric category code.';
COMMENT ON COLUMN bronze.equipment_events_raw.cd_subcategory_client IS 'Client-facing numeric subcategory code.';
COMMENT ON COLUMN bronze.equipment_events_raw.last_update IS 'Last time this event row was updated (source-side).';
COMMENT ON COLUMN bronze.equipment_events_raw.ignore_cost IS 'True to exclude this downtime from cost accounting.';
COMMENT ON COLUMN bronze.equipment_events_raw.ingested_at IS 'Wall-clock time the row was appended to bronze (ingest bookkeeping).';
COMMENT ON COLUMN bronze.equipment_events_raw.source_seq IS 'Monotonic ingest sequence assigned at append (ordering/lineage).';

COMMENT ON TABLE bronze.box_scans IS
'BRONZE: append-only barcode/box scan ledger — one row per physical scan event, protected by a no_mutate trigger (never UPDATE/DELETE; a void is recorded as a new negating row via voids_box_scan_id). Immutable landing feeding the box/PO counting path (gold.po_box_counter). Distinct from silver.ca_equipment_boxes_1s (a per-second aggregate).';

COMMENT ON COLUMN bronze.box_scans.box_scan_id IS 'Surrogate PK (bigint) for the scan row.';
COMMENT ON COLUMN bronze.box_scans.box_uid IS 'Stable UUID identifying the physical box.';
COMMENT ON COLUMN bronze.box_scans.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN bronze.box_scans.id_site IS 'Denormalized hierarchy FK (core.sites).';
COMMENT ON COLUMN bronze.box_scans.id_area IS 'Denormalized hierarchy FK (core.areas).';
COMMENT ON COLUMN bronze.box_scans.id_equipment IS 'FK core.equipments — machine/line where the scan occurred.';
COMMENT ON COLUMN bronze.box_scans.id_production_order IS 'FK core.production_orders — PO the scan is attributed to (bigint).';
COMMENT ON COLUMN bronze.box_scans.id_order IS 'Client-facing production order id (integer variant).';
COMMENT ON COLUMN bronze.box_scans.scan_type IS 'Scan classification (e.g. box, pallet, void) as text.';
COMMENT ON COLUMN bronze.box_scans.label_seq IS 'Label sequence number printed/scanned for the box.';
COMMENT ON COLUMN bronze.box_scans.qty IS 'Quantity of units this scan represents (count).';
COMMENT ON COLUMN bronze.box_scans.counts_toward_total IS 'Whether this scan contributes to the PO produced total (false for voids/duplicates).';
COMMENT ON COLUMN bronze.box_scans.raw_barcode IS 'Verbatim scanned barcode string.';
COMMENT ON COLUMN bronze.box_scans.voids_box_scan_id IS 'If set, this row voids an earlier scan (references box_scans.box_scan_id).';
COMMENT ON COLUMN bronze.box_scans.scan_uuid IS 'Idempotency UUID for the scan event (dedup on replay).';
COMMENT ON COLUMN bronze.box_scans.ts_value IS 'Timestamp the scan occurred (tz-aware).';
COMMENT ON COLUMN bronze.box_scans.ingested_at IS 'Wall-clock time the row was appended to bronze (ingest bookkeeping).';
COMMENT ON COLUMN bronze.box_scans.source_seq IS 'Monotonic ingest sequence assigned at append (ordering/lineage).';
COMMENT ON COLUMN bronze.box_scans.scanned_by IS 'Operator/device identifier that produced the scan.';

-- =====================================================================
-- SILVER — fact tables (merged/deduped)
-- =====================================================================

COMMENT ON TABLE silver.equipment_values IS
'SILVER base fact: merged/deduped raw SparkPlug metric time series (TimescaleDB hypertable). Latest-wins UPSERT on UNIQUE(ts_value, id_equipment) — one row per equipment per second, updated in place (ON CONFLICT DO UPDATE), unlike the append-only bronze.equipment_values_raw. Source for the rollup caggs (equipment_metrics_1min, equipment_categorical_*, agg_equipment_values_*).';

COMMENT ON COLUMN silver.equipment_values.id_equipment IS 'FK core.equipments.id_equipment (part of UPSERT key).';
COMMENT ON COLUMN silver.equipment_values.ts_value IS 'Sample timestamp (tz-aware); part of UNIQUE(ts_value, id_equipment) UPSERT key.';
COMMENT ON COLUMN silver.equipment_values.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN silver.equipment_values.id_site IS 'Denormalized hierarchy FK (core.sites).';
COMMENT ON COLUMN silver.equipment_values.id_area IS 'Denormalized hierarchy FK (core.areas).';
COMMENT ON COLUMN silver.equipment_values.net_production_incr IS 'Net (good) production since previous sample (count, incremental).';
COMMENT ON COLUMN silver.equipment_values.gross_production_incr IS 'Gross production since previous sample (count, incremental).';
COMMENT ON COLUMN silver.equipment_values.scrap_incr IS 'Scrap since previous sample (count, incremental).';
COMMENT ON COLUMN silver.equipment_values.speed IS 'Instantaneous machine speed at sample time (units/time).';
COMMENT ON COLUMN silver.equipment_values.id_order IS 'Client-facing production order code (string).';
COMMENT ON COLUMN silver.equipment_values.conversion_factor IS 'Units-per-cycle conversion factor at sample time.';
COMMENT ON COLUMN silver.equipment_values.number_cavities IS 'Mold cavity count / parallel-output multiplier at sample time.';
COMMENT ON COLUMN silver.equipment_values.faults IS 'Raw PLC fault codes for the sample (JSONB).';
COMMENT ON COLUMN silver.equipment_values.analogs IS 'Raw analog/auxiliary PLC readings (JSONB).';
COMMENT ON COLUMN silver.equipment_values.signal_quality IS 'SparkPlug signal-quality indicator for the sample.';
COMMENT ON COLUMN silver.equipment_values.net_production_val IS 'Net production absolute totalizer value (count).';
COMMENT ON COLUMN silver.equipment_values.gross_production_val IS 'Gross production absolute totalizer value (count).';
COMMENT ON COLUMN silver.equipment_values.scrap_val IS 'Scrap absolute totalizer value (count).';
COMMENT ON COLUMN silver.equipment_values.id_shift IS 'FK core.shifts in effect at sample time.';
COMMENT ON COLUMN silver.equipment_values.id_team IS 'FK to the team on shift at sample time.';
COMMENT ON COLUMN silver.equipment_values.id_shift_hour IS 'FK core.shift_hours — calendar-expanded shift slot.';
COMMENT ON COLUMN silver.equipment_values.box_code IS 'Barcode/box identifier reported with the sample.';
COMMENT ON COLUMN silver.equipment_values.transaction_code IS 'Transaction/label code reported with the sample.';
COMMENT ON COLUMN silver.equipment_values.state IS 'PackML machine state (6=RUNNING, 10=STOPPED, ...) at sample time.';
COMMENT ON COLUMN silver.equipment_values.mode IS 'PackML machine mode at sample time.';
COMMENT ON COLUMN silver.equipment_values.id_production_order IS 'FK core.production_orders — resolved internal PO id.';
COMMENT ON COLUMN silver.equipment_values.ts_value_production IS 'Production/business date the sample is attributed to.';
COMMENT ON COLUMN silver.equipment_values.id_equipment_line_infeed IS 'id_equipment of line-infeed machine for line-differencing (#569).';
COMMENT ON COLUMN silver.equipment_values.id_equipment_line_outfeed IS 'id_equipment of line-outfeed machine for line-differencing (#569).';
COMMENT ON COLUMN silver.equipment_values.net_production_incr_quality IS 'SparkPlug per-metric quality flag for net_production_incr.';
COMMENT ON COLUMN silver.equipment_values.gross_production_incr_quality IS 'SparkPlug per-metric quality flag for gross_production_incr.';
COMMENT ON COLUMN silver.equipment_values.scrap_incr_quality IS 'SparkPlug per-metric quality flag for scrap_incr.';
COMMENT ON COLUMN silver.equipment_values.speed_quality IS 'SparkPlug per-metric quality flag for speed.';
COMMENT ON COLUMN silver.equipment_values.id_order_quality IS 'SparkPlug per-metric quality flag for id_order.';
COMMENT ON COLUMN silver.equipment_values.conversion_factor_quality IS 'SparkPlug per-metric quality flag for conversion_factor.';
COMMENT ON COLUMN silver.equipment_values.number_cavities_quality IS 'SparkPlug per-metric quality flag for number_cavities.';
COMMENT ON COLUMN silver.equipment_values.net_production_val_quality IS 'SparkPlug per-metric quality flag for net_production_val.';
COMMENT ON COLUMN silver.equipment_values.gross_production_val_quality IS 'SparkPlug per-metric quality flag for gross_production_val.';
COMMENT ON COLUMN silver.equipment_values.scrap_val_quality IS 'SparkPlug per-metric quality flag for scrap_val.';
COMMENT ON COLUMN silver.equipment_values.id_shift_quality IS 'SparkPlug per-metric quality flag for id_shift.';
COMMENT ON COLUMN silver.equipment_values.state_quality IS 'SparkPlug per-metric quality flag for state.';
COMMENT ON COLUMN silver.equipment_values.mode_quality IS 'SparkPlug per-metric quality flag for mode.';
COMMENT ON COLUMN silver.equipment_values.id_production_order_quality IS 'SparkPlug per-metric quality flag for id_production_order.';
COMMENT ON COLUMN silver.equipment_values.ts_value_production_quality IS 'SparkPlug per-metric quality flag for ts_value_production.';
COMMENT ON COLUMN silver.equipment_values.id_equipment_line_connected IS 'id_equipment of the line this machine belongs to (line membership).';
COMMENT ON COLUMN silver.equipment_values.position_in_equipment_line IS 'Ordinal position of this machine within its line.';
COMMENT ON COLUMN silver.equipment_values.is_equipment_line_infeed IS 'Flag (1/0): this machine is the line infeed point.';
COMMENT ON COLUMN silver.equipment_values.is_equipment_line_outfeed IS 'Flag (1/0): this machine is the line outfeed point.';
COMMENT ON COLUMN silver.equipment_values.process_scrap_incr IS 'Process (in-line) scrap since previous sample (count, incremental).';
COMMENT ON COLUMN silver.equipment_values.process_scrap_val IS 'Process scrap absolute totalizer value (count).';
COMMENT ON COLUMN silver.equipment_values.process_scrap_incr_quality IS 'SparkPlug per-metric quality flag for process_scrap_incr.';
COMMENT ON COLUMN silver.equipment_values.process_scrap_val_quality IS 'SparkPlug per-metric quality flag for process_scrap_val.';
COMMENT ON COLUMN silver.equipment_values.tp_equipment IS 'Equipment type (1=machine, 2=sector, 3=line).';
COMMENT ON COLUMN silver.equipment_values.sub_mode IS 'PackML sub-mode string reported with the sample.';
COMMENT ON COLUMN silver.equipment_values.ideal_production_speed IS 'Ideal/nominal production speed (units/time) at sample time (PackML 30701).';
COMMENT ON COLUMN silver.equipment_values.check_number IS 'Monotonic per-equipment counter/sequence used for gap detection.';
COMMENT ON COLUMN silver.equipment_values.ingested_at IS 'Wall-clock time the row was written/last-updated in silver.';
COMMENT ON COLUMN silver.equipment_values.source_seq IS 'Monotonic ingest sequence for ordering/lineage.';

COMMENT ON TABLE silver.equipment_events IS
'SILVER fact: canonical machine status / downtime event log (TimescaleDB hypertable). Latest-wins UPSERT on ON CONFLICT (id_equipment, ts_event). One row per (equipment, event-start); ts_end/duration populated when the event closes. Consumed by OEE availability rollups and the downtimes surface.';

COMMENT ON COLUMN silver.equipment_events.id_equipment IS 'FK core.equipments.id_equipment (part of UPSERT key).';
COMMENT ON COLUMN silver.equipment_events.ts_event IS 'Event start timestamp (tz-aware); part of UNIQUE(id_equipment, ts_event) UPSERT key.';
COMMENT ON COLUMN silver.equipment_events.status IS 'Machine/event status code at ts_event (e.g. 10=STOPPED).';
COMMENT ON COLUMN silver.equipment_events.id_equipment_event IS 'Surrogate PK (bigint) for the event row.';
COMMENT ON COLUMN silver.equipment_events.txt_downtime_notes IS 'Free-text downtime justification note.';
COMMENT ON COLUMN silver.equipment_events.idle IS 'Idle classification code/string for the event.';
COMMENT ON COLUMN silver.equipment_events.idle_processed IS 'Whether the idle classification has been processed.';
COMMENT ON COLUMN silver.equipment_events.forced_creation_system IS 'True if the event was system-forced rather than PLC-derived.';
COMMENT ON COLUMN silver.equipment_events.fault IS 'PLC fault code associated with the event.';
COMMENT ON COLUMN silver.equipment_events.fault_processed IS 'Whether the fault has been processed.';
COMMENT ON COLUMN silver.equipment_events.cd_machine IS 'Machine-level downtime code.';
COMMENT ON COLUMN silver.equipment_events.cd_category IS 'Downtime category code.';
COMMENT ON COLUMN silver.equipment_events.cd_subcategory IS 'Downtime subcategory code.';
COMMENT ON COLUMN silver.equipment_events.change_over IS 'True if the event is a changeover/setup stop.';
COMMENT ON COLUMN silver.equipment_events.planned_downtime IS 'True if the downtime is planned.';
COMMENT ON COLUMN silver.equipment_events.ts_end IS 'Event end timestamp (tz-aware); NULL while still open.';
COMMENT ON COLUMN silver.equipment_events.duration IS 'Event duration in seconds (ts_end - ts_event).';
COMMENT ON COLUMN silver.equipment_events.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN silver.equipment_events.desc_category IS 'Downtime category human-readable description.';
COMMENT ON COLUMN silver.equipment_events.desc_subcategory IS 'Downtime subcategory human-readable description.';
COMMENT ON COLUMN silver.equipment_events.cd_category_client IS 'Client-facing numeric category code.';
COMMENT ON COLUMN silver.equipment_events.cd_subcategory_client IS 'Client-facing numeric subcategory code.';
COMMENT ON COLUMN silver.equipment_events.last_update IS 'Last time this event row was updated.';
COMMENT ON COLUMN silver.equipment_events.ignore_cost IS 'True to exclude this downtime from cost accounting.';
COMMENT ON COLUMN silver.equipment_events.ingested_at IS 'Wall-clock time the row was written/last-updated in silver.';
COMMENT ON COLUMN silver.equipment_events.source_seq IS 'Monotonic ingest sequence for ordering/lineage.';

-- --- event side-plane tables (re-homed public → silver, #261) ---

COMMENT ON TABLE silver.equipment_events_man IS
'SILVER event side-plane: MANUAL downtime events created/edited by operator justification (edge-api events-justify → stream-engine pocontrol). Insert-if-not-exists keyed on (ts_event, cd_machine, cd_category, cd_subcategory). Re-homed public → silver (#261). Genuine table (NOT a shim).';

COMMENT ON COLUMN silver.equipment_events_man.id_equipment IS 'FK core.equipments.id_equipment.';
COMMENT ON COLUMN silver.equipment_events_man.ts_event IS 'Manual event start timestamp (tz-aware); part of the insert-if-not-exists key.';
COMMENT ON COLUMN silver.equipment_events_man.status IS 'Machine/event status code.';
COMMENT ON COLUMN silver.equipment_events_man.id_equipment_event IS 'Surrogate PK (integer) for the manual event row.';
COMMENT ON COLUMN silver.equipment_events_man.txt_downtime_notes IS 'Operator free-text justification note.';
COMMENT ON COLUMN silver.equipment_events_man.idle IS 'Idle classification code/string.';
COMMENT ON COLUMN silver.equipment_events_man.idle_processed IS 'Whether the idle classification has been processed.';
COMMENT ON COLUMN silver.equipment_events_man.forced_creation_system IS 'True if system-forced rather than operator-entered.';
COMMENT ON COLUMN silver.equipment_events_man.fault IS 'PLC fault code associated with the event.';
COMMENT ON COLUMN silver.equipment_events_man.fault_processed IS 'Whether the fault has been processed.';
COMMENT ON COLUMN silver.equipment_events_man.cd_machine IS 'Machine-level downtime code (part of the insert-if-not-exists key).';
COMMENT ON COLUMN silver.equipment_events_man.cd_category IS 'Downtime category code (part of the insert-if-not-exists key).';
COMMENT ON COLUMN silver.equipment_events_man.cd_subcategory IS 'Downtime subcategory code (part of the insert-if-not-exists key).';
COMMENT ON COLUMN silver.equipment_events_man.change_over IS 'True if the event is a changeover/setup stop.';
COMMENT ON COLUMN silver.equipment_events_man.planned_downtime IS 'True if the downtime is planned.';
COMMENT ON COLUMN silver.equipment_events_man.ts_end IS 'Manual event end timestamp (tz-aware).';
COMMENT ON COLUMN silver.equipment_events_man.duration IS 'Event duration in seconds.';
COMMENT ON COLUMN silver.equipment_events_man.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN silver.equipment_events_man.desc_category IS 'Downtime category human-readable description.';
COMMENT ON COLUMN silver.equipment_events_man.desc_subcategory IS 'Downtime subcategory human-readable description.';
COMMENT ON COLUMN silver.equipment_events_man.cd_category_client IS 'Client-facing numeric category code.';
COMMENT ON COLUMN silver.equipment_events_man.cd_subcategory_client IS 'Client-facing numeric subcategory code.';
COMMENT ON COLUMN silver.equipment_events_man.last_update IS 'Last time this manual event row was updated.';
COMMENT ON COLUMN silver.equipment_events_man.ignore_cost IS 'True to exclude this downtime from cost accounting.';

COMMENT ON TABLE silver.equipment_events_cpac_shadow IS
'SILVER event side-plane: DARK shadow output of the CPAC downtime deriver (internal/events/cpac_deriver.go, target CPAC_EVENT_TARGET_TABLE, default equipment_events_cpac_shadow). Kept separate from silver.equipment_events for comparison until the deriver is promoted (do NOT serve as canonical downtimes). Re-homed public → silver (#261). Same column shape as equipment_events.';

COMMENT ON COLUMN silver.equipment_events_cpac_shadow.id_equipment IS 'FK core.equipments.id_equipment.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.ts_event IS 'Derived event start timestamp (tz-aware).';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.status IS 'Derived machine/event status code.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.id_equipment_event IS 'Surrogate PK (bigint) for the shadow event row.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.txt_downtime_notes IS 'Free-text downtime note (usually null for derived events).';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.idle IS 'Idle classification code/string.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.idle_processed IS 'Whether the idle classification has been processed.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.forced_creation_system IS 'True if the event was system-forced.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.fault IS 'PLC fault code associated with the event.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.fault_processed IS 'Whether the fault has been processed.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.cd_machine IS 'Machine-level downtime code.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.cd_category IS 'Downtime category code.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.cd_subcategory IS 'Downtime subcategory code.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.change_over IS 'True if the event is a changeover/setup stop.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.planned_downtime IS 'True if the downtime is planned.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.ts_end IS 'Derived event end timestamp (tz-aware).';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.duration IS 'Event duration in seconds.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.desc_category IS 'Downtime category human-readable description.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.desc_subcategory IS 'Downtime subcategory human-readable description.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.cd_category_client IS 'Client-facing numeric category code.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.cd_subcategory_client IS 'Client-facing numeric subcategory code.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.last_update IS 'Last time this shadow event row was updated.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.ignore_cost IS 'True to exclude this downtime from cost accounting.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.ingested_at IS 'Wall-clock time the row was written in silver.';
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.source_seq IS 'Monotonic ingest sequence for ordering/lineage.';

COMMENT ON TABLE silver.equipment_events_low_speed IS
'SILVER event side-plane: low-speed (micro-stop / reduced-speed) derived events — carries the observed speed vs ideal_production_speed instead of the client category codes. Re-homed public → silver (#261). UNCERTAIN: no active writer found in current stream-engine source — likely dormant/legacy or written by an out-of-tree/DB path.';

COMMENT ON COLUMN silver.equipment_events_low_speed.id_equipment IS 'FK core.equipments.id_equipment.';
COMMENT ON COLUMN silver.equipment_events_low_speed.ts_event IS 'Low-speed event start timestamp (tz-aware).';
COMMENT ON COLUMN silver.equipment_events_low_speed.status IS 'Machine/event status code.';
COMMENT ON COLUMN silver.equipment_events_low_speed.id_equipment_event IS 'Surrogate PK (bigint) for the event row.';
COMMENT ON COLUMN silver.equipment_events_low_speed.txt_downtime_notes IS 'Free-text note.';
COMMENT ON COLUMN silver.equipment_events_low_speed.idle IS 'Idle classification code/string.';
COMMENT ON COLUMN silver.equipment_events_low_speed.idle_processed IS 'Whether the idle classification has been processed.';
COMMENT ON COLUMN silver.equipment_events_low_speed.forced_creation_system IS 'True if the event was system-forced.';
COMMENT ON COLUMN silver.equipment_events_low_speed.fault IS 'PLC fault code associated with the event.';
COMMENT ON COLUMN silver.equipment_events_low_speed.fault_processed IS 'Whether the fault has been processed.';
COMMENT ON COLUMN silver.equipment_events_low_speed.cd_machine IS 'Machine-level downtime code.';
COMMENT ON COLUMN silver.equipment_events_low_speed.cd_category IS 'Downtime category code.';
COMMENT ON COLUMN silver.equipment_events_low_speed.cd_subcategory IS 'Downtime subcategory code.';
COMMENT ON COLUMN silver.equipment_events_low_speed.change_over IS 'True if the event is a changeover/setup stop.';
COMMENT ON COLUMN silver.equipment_events_low_speed.planned_downtime IS 'True if the downtime is planned.';
COMMENT ON COLUMN silver.equipment_events_low_speed.ts_end IS 'Low-speed event end timestamp (tz-aware).';
COMMENT ON COLUMN silver.equipment_events_low_speed.duration IS 'Event duration in seconds.';
COMMENT ON COLUMN silver.equipment_events_low_speed.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN silver.equipment_events_low_speed.desc_category IS 'Downtime category human-readable description.';
COMMENT ON COLUMN silver.equipment_events_low_speed.desc_subcategory IS 'Downtime subcategory human-readable description.';
COMMENT ON COLUMN silver.equipment_events_low_speed.speed IS 'Observed speed during the low-speed window (units/time).';
COMMENT ON COLUMN silver.equipment_events_low_speed.ideal_production_speed IS 'Ideal/nominal speed the observed speed fell below (units/time).';

COMMENT ON TABLE silver.data_quality_event IS
'SILVER DQ alarm plane (ADR-0036 P11 andon): side-write log of detected data-quality violations (RunDQScan detector + RunSilverClamp remediation tripwires, e.g. oee>1, net>gross, negatives). Pure instrumentation — recording here NEVER alters a served value. Consumed by DQ dashboards/alerting.';

COMMENT ON COLUMN silver.data_quality_event.id IS 'Surrogate PK (bigint).';
COMMENT ON COLUMN silver.data_quality_event.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN silver.data_quality_event.id_equipment IS 'FK core.equipments — equipment the violation was observed on.';
COMMENT ON COLUMN silver.data_quality_event.grain IS 'Grain the rule fired at (e.g. shift, hour, day).';
COMMENT ON COLUMN silver.data_quality_event.bucket_ts IS 'Timestamp of the offending grain bucket (tz-aware).';
COMMENT ON COLUMN silver.data_quality_event.rule IS 'Rule identifier (e.g. INVARIANT_CLAMPED_NET_GT_GROSS, OEE_GT_1).';
COMMENT ON COLUMN silver.data_quality_event.observed_value IS 'Pre-clamp/observed offending value that tripped the rule.';
COMMENT ON COLUMN silver.data_quality_event.severity IS 'Severity level (e.g. info, warn, critical).';
COMMENT ON COLUMN silver.data_quality_event.detected_at IS 'Wall-clock time the violation was detected (tz-aware).';

-- =====================================================================
-- SILVER — current-state (live) grains
-- =====================================================================

COMMENT ON TABLE silver.equipment_live_metrics IS
'SILVER current-state grain: latest live snapshot of each equipment (one row per id_equipment). Written by stream-engine uns/current_metrics — powers the real-time monitoring/andon board. NOT time-series; overwritten in place each tick.';

COMMENT ON COLUMN silver.equipment_live_metrics.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN silver.equipment_live_metrics.id_site IS 'Denormalized hierarchy FK (core.sites).';
COMMENT ON COLUMN silver.equipment_live_metrics.id_area IS 'Denormalized hierarchy FK (core.areas).';
COMMENT ON COLUMN silver.equipment_live_metrics.id_equipment IS 'FK core.equipments.id_equipment (one row per equipment).';
COMMENT ON COLUMN silver.equipment_live_metrics.state IS 'Current PackML state code (6=RUNNING, 10=STOPPED, ...).';
COMMENT ON COLUMN silver.equipment_live_metrics.speed IS 'Current speed (numeric units/time).';
COMMENT ON COLUMN silver.equipment_live_metrics.updated_at IS 'Source timestamp of the current sample (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_metrics.status IS 'Human-readable current status label.';
COMMENT ON COLUMN silver.equipment_live_metrics.downtime_category IS 'Current downtime category label (if stopped).';
COMMENT ON COLUMN silver.equipment_live_metrics.downtime_subcategory IS 'Current downtime subcategory label (if stopped).';
COMMENT ON COLUMN silver.equipment_live_metrics.status_time IS 'Seconds the equipment has held the current status.';
COMMENT ON COLUMN silver.equipment_live_metrics.production_record_shifts IS 'Count of shifts with production records (rolling indicator).';
COMMENT ON COLUMN silver.equipment_live_metrics.nm_equipment IS 'Denormalized equipment name (display).';
COMMENT ON COLUMN silver.equipment_live_metrics.nm_area IS 'Denormalized area name (display).';
COMMENT ON COLUMN silver.equipment_live_metrics.nm_site IS 'Denormalized site name (display).';
COMMENT ON COLUMN silver.equipment_live_metrics.status_24h IS 'Rolling 24h status timeline (text array of status codes/segments).';
COMMENT ON COLUMN silver.equipment_live_metrics.ideal_speed IS 'Configured ideal speed for display (string).';
COMMENT ON COLUMN silver.equipment_live_metrics.change_over_perc_stops_24h IS 'Percent of 24h stop time attributable to changeovers (ratio).';
COMMENT ON COLUMN silver.equipment_live_metrics.planned_perc_stops_24h IS 'Percent of 24h stop time that is planned downtime (ratio).';
COMMENT ON COLUMN silver.equipment_live_metrics.unplanned_perc_stops_24h IS 'Percent of 24h stop time that is unplanned (ratio).';
COMMENT ON COLUMN silver.equipment_live_metrics.last_updated IS 'Wall-clock time this snapshot row was last written.';

COMMENT ON TABLE silver.equipment_live_day IS
'SILVER current-state grain: current-DAY running OEE snapshot per equipment (one row per id_equipment), refreshed by stream-engine uns rollup. Overwritten in place; not time-series.';

COMMENT ON COLUMN silver.equipment_live_day.id_equipment IS 'FK core.equipments.id_equipment (one row per equipment).';
COMMENT ON COLUMN silver.equipment_live_day.oee IS 'Current-day OEE ratio (0..1) = oee_a * oee_p * oee_q.';
COMMENT ON COLUMN silver.equipment_live_day.oee_a IS 'Availability component (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_day.oee_p IS 'Performance component (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_day.oee_q IS 'Quality component (ratio 0..1) = net/gross.';
COMMENT ON COLUMN silver.equipment_live_day.gross_production IS 'Current-day gross production (count).';
COMMENT ON COLUMN silver.equipment_live_day.net_production IS 'Current-day net/good production (count).';
COMMENT ON COLUMN silver.equipment_live_day.scrap IS 'Current-day scrap (count).';
COMMENT ON COLUMN silver.equipment_live_day.speed IS 'Representative current-day speed (units/time).';
COMMENT ON COLUMN silver.equipment_live_day.target IS 'Current-day production target (count).';
COMMENT ON COLUMN silver.equipment_live_day.begin_time IS 'Start date of the current-day window.';
COMMENT ON COLUMN silver.equipment_live_day.end_time IS 'End date of the current-day window.';
COMMENT ON COLUMN silver.equipment_live_day.idle_time IS 'Idle time in the window (seconds).';
COMMENT ON COLUMN silver.equipment_live_day.elapsed_time IS 'Total elapsed time in the window (seconds).';
COMMENT ON COLUMN silver.equipment_live_day.idle_blocked IS 'Idle time attributed to blocked (downstream) condition (seconds).';
COMMENT ON COLUMN silver.equipment_live_day.idle_starved IS 'Idle time attributed to starved (upstream) condition (seconds).';
COMMENT ON COLUMN silver.equipment_live_day.running_time IS 'Time in RUNNING state (seconds).';
COMMENT ON COLUMN silver.equipment_live_day.stopped_time IS 'Time in STOPPED state (seconds).';
COMMENT ON COLUMN silver.equipment_live_day.available_time IS 'Available (scheduled) time (seconds).';
COMMENT ON COLUMN silver.equipment_live_day.planned_downtime IS 'Planned downtime in the window (seconds).';
COMMENT ON COLUMN silver.equipment_live_day.ideal_production IS 'Ideal production at ideal speed over available time (count).';
COMMENT ON COLUMN silver.equipment_live_day.proportional_target IS 'Target scaled to elapsed fraction of the window (count).';
COMMENT ON COLUMN silver.equipment_live_day.proportional_ideal_production IS 'Ideal production scaled to elapsed fraction of the window (count).';
COMMENT ON COLUMN silver.equipment_live_day.last_30_days IS 'Rolling 30-day OEE/production history for sparklines (JSONB).';
COMMENT ON COLUMN silver.equipment_live_day.gross_production_exec_mode IS 'Gross production counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_day.net_production_exec_mode IS 'Net production counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_day.scrap_exec_mode IS 'Scrap counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_day.last_updated IS 'Wall-clock time this snapshot row was last written.';

COMMENT ON TABLE silver.equipment_live_month IS
'SILVER current-state grain: current-MONTH running OEE snapshot per equipment (one row per id_equipment). Same shape as equipment_live_day at month granularity (durations widened to bigint). Overwritten in place.';

COMMENT ON COLUMN silver.equipment_live_month.id_equipment IS 'FK core.equipments.id_equipment (one row per equipment).';
COMMENT ON COLUMN silver.equipment_live_month.oee IS 'Current-month OEE ratio (0..1) = oee_a * oee_p * oee_q.';
COMMENT ON COLUMN silver.equipment_live_month.oee_a IS 'Availability component (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_month.oee_p IS 'Performance component (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_month.oee_q IS 'Quality component (ratio 0..1) = net/gross.';
COMMENT ON COLUMN silver.equipment_live_month.gross_production IS 'Current-month gross production (count).';
COMMENT ON COLUMN silver.equipment_live_month.net_production IS 'Current-month net/good production (count).';
COMMENT ON COLUMN silver.equipment_live_month.scrap IS 'Current-month scrap (count).';
COMMENT ON COLUMN silver.equipment_live_month.speed IS 'Representative current-month speed (units/time).';
COMMENT ON COLUMN silver.equipment_live_month.target IS 'Current-month production target (count).';
COMMENT ON COLUMN silver.equipment_live_month.begin_time IS 'Start of the current-month window (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_month.end_time IS 'End of the current-month window (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_month.idle_time IS 'Idle time in the window (seconds).';
COMMENT ON COLUMN silver.equipment_live_month.elapsed_time IS 'Total elapsed time in the window (seconds).';
COMMENT ON COLUMN silver.equipment_live_month.idle_blocked IS 'Idle time attributed to blocked (downstream) condition (seconds).';
COMMENT ON COLUMN silver.equipment_live_month.idle_starved IS 'Idle time attributed to starved (upstream) condition (seconds).';
COMMENT ON COLUMN silver.equipment_live_month.running_time IS 'Time in RUNNING state (seconds).';
COMMENT ON COLUMN silver.equipment_live_month.stopped_time IS 'Time in STOPPED state (seconds).';
COMMENT ON COLUMN silver.equipment_live_month.available_time IS 'Available (scheduled) time (seconds).';
COMMENT ON COLUMN silver.equipment_live_month.planned_downtime IS 'Planned downtime in the window (seconds).';
COMMENT ON COLUMN silver.equipment_live_month.ideal_production IS 'Ideal production at ideal speed over available time (count).';
COMMENT ON COLUMN silver.equipment_live_month.proportional_target IS 'Target scaled to elapsed fraction of the window (count).';
COMMENT ON COLUMN silver.equipment_live_month.proportional_ideal_production IS 'Ideal production scaled to elapsed fraction of the window (count).';
COMMENT ON COLUMN silver.equipment_live_month.gross_production_exec_mode IS 'Gross production counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_month.net_production_exec_mode IS 'Net production counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_month.scrap_exec_mode IS 'Scrap counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_month.last_updated IS 'Wall-clock time this snapshot row was last written.';

COMMENT ON TABLE silver.equipment_live_shift IS
'SILVER current-state grain: current-SHIFT running OEE snapshot per equipment (one row per id_equipment), plus a trailing window of the previous 3 shifts (prev1=N-1, prev2=N-2, prev3=N-3) for shift-over-shift comparison. Written by stream-engine uns rollup; overwritten in place.';

COMMENT ON COLUMN silver.equipment_live_shift.id_equipment IS 'FK core.equipments.id_equipment (one row per equipment).';
COMMENT ON COLUMN silver.equipment_live_shift.oee IS 'Current-shift OEE ratio (0..1) = oee_a * oee_p * oee_q.';
COMMENT ON COLUMN silver.equipment_live_shift.oee_a IS 'Availability component (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.oee_p IS 'Performance component (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.oee_q IS 'Quality component (ratio 0..1) = net/gross.';
COMMENT ON COLUMN silver.equipment_live_shift.gross_production IS 'Current-shift gross production (count).';
COMMENT ON COLUMN silver.equipment_live_shift.net_production IS 'Current-shift net/good production (count).';
COMMENT ON COLUMN silver.equipment_live_shift.scrap IS 'Current-shift scrap (count).';
COMMENT ON COLUMN silver.equipment_live_shift.speed IS 'Representative current-shift speed (units/time).';
COMMENT ON COLUMN silver.equipment_live_shift.target IS 'Current-shift production target (count).';
COMMENT ON COLUMN silver.equipment_live_shift.begin_time IS 'Start of the current shift window (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_shift.end_time IS 'End of the current shift window (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_shift.idle_time IS 'Idle time in the shift (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.elapsed_time IS 'Elapsed time in the shift (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.idle_blocked IS 'Idle time attributed to blocked condition (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.idle_starved IS 'Idle time attributed to starved condition (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.running_time IS 'Time in RUNNING state (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.stopped_time IS 'Time in STOPPED state (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.available_time IS 'Available (scheduled) time (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.planned_downtime IS 'Planned downtime in the shift (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.ideal_production IS 'Ideal production at ideal speed over available time (count).';
COMMENT ON COLUMN silver.equipment_live_shift.proportional_target IS 'Target scaled to elapsed fraction of the shift (count).';
COMMENT ON COLUMN silver.equipment_live_shift.proportional_ideal_production IS 'Ideal production scaled to elapsed fraction of the shift (count).';
COMMENT ON COLUMN silver.equipment_live_shift.id_shift IS 'FK core.shifts — current shift.';
COMMENT ON COLUMN silver.equipment_live_shift.id_shift_hour IS 'FK core.shift_hours — current calendar-expanded shift slot.';
COMMENT ON COLUMN silver.equipment_live_shift.duration IS 'Planned duration of the current shift (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.previous_shift IS 'FK core.shifts of the immediately-preceding shift.';
COMMENT ON COLUMN silver.equipment_live_shift.next_shift IS 'FK core.shifts of the next shift.';
COMMENT ON COLUMN silver.equipment_live_shift.previous_shift_hour IS 'FK core.shift_hours of the preceding shift slot.';
COMMENT ON COLUMN silver.equipment_live_shift.next_shift_hour IS 'FK core.shift_hours of the next shift slot.';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_oee IS 'Previous shift (N-1) OEE ratio (0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_oee_a IS 'Previous shift (N-1) availability (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_oee_p IS 'Previous shift (N-1) performance (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_oee_q IS 'Previous shift (N-1) quality (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_gross_production IS 'Previous shift (N-1) gross production (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_net_production IS 'Previous shift (N-1) net production (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_scrap IS 'Previous shift (N-1) scrap (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_speed IS 'Previous shift (N-1) representative speed (units/time).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_target IS 'Previous shift (N-1) target (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_begin_time IS 'Previous shift (N-1) start (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_end_time IS 'Previous shift (N-1) end (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_id_shift IS 'Previous shift (N-1) FK core.shifts.';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_id_shift_hour IS 'Previous shift (N-1) FK core.shift_hours.';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_duration IS 'Previous shift (N-1) planned duration (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_oee IS 'Shift N-2 OEE ratio (0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_oee_a IS 'Shift N-2 availability (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_oee_p IS 'Shift N-2 performance (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_oee_q IS 'Shift N-2 quality (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_gross_production IS 'Shift N-2 gross production (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_net_production IS 'Shift N-2 net production (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_scrap IS 'Shift N-2 scrap (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_speed IS 'Shift N-2 representative speed (units/time).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_target IS 'Shift N-2 target (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_begin_time IS 'Shift N-2 start (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_end_time IS 'Shift N-2 end (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_id_shift IS 'Shift N-2 FK core.shifts.';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_id_shift_hour IS 'Shift N-2 FK core.shift_hours.';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_duration IS 'Shift N-2 planned duration (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_oee IS 'Shift N-3 OEE ratio (0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_oee_a IS 'Shift N-3 availability (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_oee_p IS 'Shift N-3 performance (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_oee_q IS 'Shift N-3 quality (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_gross_production IS 'Shift N-3 gross production (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_net_production IS 'Shift N-3 net production (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_scrap IS 'Shift N-3 scrap (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_speed IS 'Shift N-3 representative speed (units/time).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_target IS 'Shift N-3 target (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_begin_time IS 'Shift N-3 start (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_end_time IS 'Shift N-3 end (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_id_shift IS 'Shift N-3 FK core.shifts.';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_id_shift_hour IS 'Shift N-3 FK core.shift_hours.';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_duration IS 'Shift N-3 planned duration (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.gross_production_exec_mode IS 'Current-shift gross production counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_shift.net_production_exec_mode IS 'Current-shift net production counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_shift.scrap_exec_mode IS 'Current-shift scrap counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_shift.prev2_shift_name IS 'Display name of shift N-2.';
COMMENT ON COLUMN silver.equipment_live_shift.prev1_shift_name IS 'Display name of shift N-1.';
COMMENT ON COLUMN silver.equipment_live_shift.prev3_shift_name IS 'Display name of shift N-3.';
COMMENT ON COLUMN silver.equipment_live_shift.shift_name IS 'Display name of the current shift.';
COMMENT ON COLUMN silver.equipment_live_shift.unplanned_downtime IS 'Unplanned downtime in the current shift (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.change_over_duration IS 'Changeover/setup time in the current shift (seconds).';
COMMENT ON COLUMN silver.equipment_live_shift.change_over_duration_perc IS 'Changeover time as fraction of the shift (ratio).';
COMMENT ON COLUMN silver.equipment_live_shift.planned_duration_perc IS 'Planned downtime as fraction of the shift (ratio).';
COMMENT ON COLUMN silver.equipment_live_shift.unplanned_duration_perc IS 'Unplanned downtime as fraction of the shift (ratio).';
COMMENT ON COLUMN silver.equipment_live_shift.id_team IS 'FK to the team on the current shift.';
COMMENT ON COLUMN silver.equipment_live_shift.last_updated IS 'Wall-clock time this snapshot row was last written.';

COMMENT ON TABLE silver.equipment_live_job IS
'SILVER current-state grain: current-JOB (running production order) OEE + setup snapshot per equipment (one row per id_equipment). Updated by stream-engine uns/current_rest + pocontrol setup handlers (PackML 30861/30862). Overwritten in place.';

COMMENT ON COLUMN silver.equipment_live_job.id_equipment IS 'FK core.equipments.id_equipment (one row per equipment).';
COMMENT ON COLUMN silver.equipment_live_job.setup_begin_time IS 'Start of the setup/changeover for the current job (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_job.setup_end_time IS 'End of the setup/changeover for the current job (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_job.oee IS 'Current-job OEE ratio (0..1) = oee_a * oee_p * oee_q.';
COMMENT ON COLUMN silver.equipment_live_job.oee_a IS 'Availability component (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_job.oee_p IS 'Performance component (ratio 0..1).';
COMMENT ON COLUMN silver.equipment_live_job.oee_q IS 'Quality component (ratio 0..1) = net/gross.';
COMMENT ON COLUMN silver.equipment_live_job.gross_production IS 'Current-job gross production (count).';
COMMENT ON COLUMN silver.equipment_live_job.net_production IS 'Current-job net/good production (count).';
COMMENT ON COLUMN silver.equipment_live_job.scrap IS 'Current-job scrap (count).';
COMMENT ON COLUMN silver.equipment_live_job.speed IS 'Representative current-job speed (units/time).';
COMMENT ON COLUMN silver.equipment_live_job.target IS 'Current-job production target (count).';
COMMENT ON COLUMN silver.equipment_live_job.begin_time IS 'Start of the current job/PO run (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_job.end_time IS 'End of the current job/PO run (tz-aware).';
COMMENT ON COLUMN silver.equipment_live_job.idle_time IS 'Idle time in the job (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.elapsed_time IS 'Elapsed time in the job (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.idle_blocked IS 'Idle time attributed to blocked condition (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.idle_starved IS 'Idle time attributed to starved condition (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.running_time IS 'Time in RUNNING state during the job (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.stopped_time IS 'Time in STOPPED state during the job (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.available_time IS 'Available (scheduled) time during the job (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.planned_downtime IS 'Planned downtime during the job (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.ideal_production IS 'Ideal production at ideal speed over available time (count).';
COMMENT ON COLUMN silver.equipment_live_job.proportional_target IS 'Target scaled to elapsed fraction of the job (count).';
COMMENT ON COLUMN silver.equipment_live_job.proportional_ideal_production IS 'Ideal production scaled to elapsed fraction of the job (count).';
COMMENT ON COLUMN silver.equipment_live_job.id_order IS 'Client-facing production order code (string).';
COMMENT ON COLUMN silver.equipment_live_job.id_production_order IS 'FK core.production_orders — current PO.';
COMMENT ON COLUMN silver.equipment_live_job.nm_client IS 'Denormalized client name for the current job (display).';
COMMENT ON COLUMN silver.equipment_live_job.nm_product IS 'Denormalized product name for the current job (display).';
COMMENT ON COLUMN silver.equipment_live_job.nm_product_family IS 'Denormalized product family for the current job (display).';
COMMENT ON COLUMN silver.equipment_live_job.setup_speed IS 'Speed observed during setup (units/time).';
COMMENT ON COLUMN silver.equipment_live_job.gross_production_exec_mode IS 'Job gross production counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_job.net_production_exec_mode IS 'Job net production counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_job.scrap_exec_mode IS 'Job scrap counted only while in execution mode (count).';
COMMENT ON COLUMN silver.equipment_live_job.current_expected_time IS 'Expected remaining/total time for the job at current pace (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.production_programmed IS 'Programmed production quantity for the PO (count).';
COMMENT ON COLUMN silver.equipment_live_job.production_ordered IS 'Ordered production quantity for the PO (count).';
COMMENT ON COLUMN silver.equipment_live_job.setup_target_duration IS 'Target/expected setup duration (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.cd_setup IS 'Setup code for the current job.';
COMMENT ON COLUMN silver.equipment_live_job.last_setup_duration IS 'Duration of the last completed setup (seconds).';
COMMENT ON COLUMN silver.equipment_live_job.last_updated IS 'Wall-clock time this snapshot row was last written.';

COMMENT ON TABLE silver.area_live_day IS
'SILVER current-state grain: current-DAY aggregated OEE snapshot per AREA (one row per id_area). Area-level rollup of the equipment grains. Overwritten in place.';

COMMENT ON COLUMN silver.area_live_day.id_area IS 'FK core.areas.id_area (one row per area).';
COMMENT ON COLUMN silver.area_live_day.oee IS 'Current-day area OEE ratio (0..1) = oee_a * oee_p * oee_q.';
COMMENT ON COLUMN silver.area_live_day.oee_a IS 'Availability component (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_day.oee_p IS 'Performance component (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_day.oee_q IS 'Quality component (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_day.gross_production IS 'Current-day area gross production (count).';
COMMENT ON COLUMN silver.area_live_day.net_production IS 'Current-day area net production (count).';
COMMENT ON COLUMN silver.area_live_day.scrap IS 'Current-day area scrap (count).';
COMMENT ON COLUMN silver.area_live_day.target IS 'Current-day area production target (count).';
COMMENT ON COLUMN silver.area_live_day.begin_time IS 'Start date of the current-day window.';
COMMENT ON COLUMN silver.area_live_day.end_time IS 'End date of the current-day window.';
COMMENT ON COLUMN silver.area_live_day.idle_time IS 'Area idle time in the window (seconds).';
COMMENT ON COLUMN silver.area_live_day.elapsed_time IS 'Elapsed time in the window (seconds).';
COMMENT ON COLUMN silver.area_live_day.idle_blocked IS 'Idle time attributed to blocked condition (seconds).';
COMMENT ON COLUMN silver.area_live_day.idle_starved IS 'Idle time attributed to starved condition (seconds).';
COMMENT ON COLUMN silver.area_live_day.running_time IS 'Time in RUNNING state (seconds).';
COMMENT ON COLUMN silver.area_live_day.stopped_time IS 'Time in STOPPED state (seconds).';
COMMENT ON COLUMN silver.area_live_day.available_time IS 'Available (scheduled) time (seconds).';
COMMENT ON COLUMN silver.area_live_day.planned_downtime IS 'Planned downtime in the window (seconds).';
COMMENT ON COLUMN silver.area_live_day.ideal_production IS 'Ideal production at ideal speed over available time (count).';
COMMENT ON COLUMN silver.area_live_day.proportional_target IS 'Target scaled to elapsed fraction of the window (count).';
COMMENT ON COLUMN silver.area_live_day.proportional_ideal_production IS 'Ideal production scaled to elapsed fraction of the window (count).';

COMMENT ON TABLE silver.area_live_shift IS
'SILVER current-state grain: current-SHIFT aggregated OEE snapshot per AREA (one row per id_area), plus a trailing window of the previous 3 shifts (prev1=N-1, prev2=N-2, prev3=N-3). Area-level rollup of equipment shift grains. Overwritten in place.';

COMMENT ON COLUMN silver.area_live_shift.id_area IS 'FK core.areas.id_area (one row per area).';
COMMENT ON COLUMN silver.area_live_shift.id_shift IS 'FK core.shifts — current shift.';
COMMENT ON COLUMN silver.area_live_shift.oee IS 'Current-shift area OEE ratio (0..1).';
COMMENT ON COLUMN silver.area_live_shift.oee_a IS 'Availability component (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.oee_p IS 'Performance component (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.oee_q IS 'Quality component (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.gross_production IS 'Current-shift area gross production (count).';
COMMENT ON COLUMN silver.area_live_shift.net_production IS 'Current-shift area net production (count).';
COMMENT ON COLUMN silver.area_live_shift.scrap IS 'Current-shift area scrap (count).';
COMMENT ON COLUMN silver.area_live_shift.target IS 'Current-shift area production target (count).';
COMMENT ON COLUMN silver.area_live_shift.begin_time IS 'Start of the current shift window (tz-aware).';
COMMENT ON COLUMN silver.area_live_shift.end_time IS 'End of the current shift window (tz-aware).';
COMMENT ON COLUMN silver.area_live_shift.idle_time IS 'Idle time in the shift (seconds).';
COMMENT ON COLUMN silver.area_live_shift.elapsed_time IS 'Elapsed time in the shift (seconds).';
COMMENT ON COLUMN silver.area_live_shift.idle_blocked IS 'Idle time attributed to blocked condition (seconds).';
COMMENT ON COLUMN silver.area_live_shift.idle_starved IS 'Idle time attributed to starved condition (seconds).';
COMMENT ON COLUMN silver.area_live_shift.running_time IS 'Time in RUNNING state (seconds).';
COMMENT ON COLUMN silver.area_live_shift.stopped_time IS 'Time in STOPPED state (seconds).';
COMMENT ON COLUMN silver.area_live_shift.available_time IS 'Available (scheduled) time (seconds).';
COMMENT ON COLUMN silver.area_live_shift.planned_downtime IS 'Planned downtime in the shift (seconds).';
COMMENT ON COLUMN silver.area_live_shift.ideal_production IS 'Ideal production at ideal speed over available time (count).';
COMMENT ON COLUMN silver.area_live_shift.proportional_target IS 'Target scaled to elapsed fraction of the shift (count).';
COMMENT ON COLUMN silver.area_live_shift.proportional_ideal_production IS 'Ideal production scaled to elapsed fraction of the shift (count).';
COMMENT ON COLUMN silver.area_live_shift.duration IS 'Planned duration of the current shift (seconds).';
COMMENT ON COLUMN silver.area_live_shift.previous_shift IS 'FK core.shifts of the immediately-preceding shift.';
COMMENT ON COLUMN silver.area_live_shift.next_shift IS 'FK core.shifts of the next shift.';
COMMENT ON COLUMN silver.area_live_shift.prev1_oee IS 'Previous shift (N-1) area OEE ratio (0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev1_oee_a IS 'Previous shift (N-1) availability (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev1_oee_p IS 'Previous shift (N-1) performance (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev1_oee_q IS 'Previous shift (N-1) quality (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev1_gross_production IS 'Previous shift (N-1) gross production (count).';
COMMENT ON COLUMN silver.area_live_shift.prev1_net_production IS 'Previous shift (N-1) net production (count).';
COMMENT ON COLUMN silver.area_live_shift.prev1_scrap IS 'Previous shift (N-1) scrap (count).';
COMMENT ON COLUMN silver.area_live_shift.prev1_target IS 'Previous shift (N-1) target (count).';
COMMENT ON COLUMN silver.area_live_shift.prev1_begin_time IS 'Previous shift (N-1) start (tz-aware).';
COMMENT ON COLUMN silver.area_live_shift.prev1_end_time IS 'Previous shift (N-1) end (tz-aware).';
COMMENT ON COLUMN silver.area_live_shift.prev1_id_shift IS 'Previous shift (N-1) FK core.shifts.';
COMMENT ON COLUMN silver.area_live_shift.prev1_duration IS 'Previous shift (N-1) planned duration (seconds).';
COMMENT ON COLUMN silver.area_live_shift.prev2_oee IS 'Shift N-2 area OEE ratio (0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev2_oee_a IS 'Shift N-2 availability (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev2_oee_p IS 'Shift N-2 performance (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev2_oee_q IS 'Shift N-2 quality (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev2_gross_production IS 'Shift N-2 gross production (count).';
COMMENT ON COLUMN silver.area_live_shift.prev2_net_production IS 'Shift N-2 net production (count).';
COMMENT ON COLUMN silver.area_live_shift.prev2_scrap IS 'Shift N-2 scrap (count).';
COMMENT ON COLUMN silver.area_live_shift.prev2_target IS 'Shift N-2 target (count).';
COMMENT ON COLUMN silver.area_live_shift.prev2_begin_time IS 'Shift N-2 start (tz-aware).';
COMMENT ON COLUMN silver.area_live_shift.prev2_end_time IS 'Shift N-2 end (tz-aware).';
COMMENT ON COLUMN silver.area_live_shift.prev2_id_shift IS 'Shift N-2 FK core.shifts.';
COMMENT ON COLUMN silver.area_live_shift.prev2_duration IS 'Shift N-2 planned duration (seconds).';
COMMENT ON COLUMN silver.area_live_shift.prev3_oee IS 'Shift N-3 area OEE ratio (0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev3_oee_a IS 'Shift N-3 availability (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev3_oee_p IS 'Shift N-3 performance (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev3_oee_q IS 'Shift N-3 quality (ratio 0..1).';
COMMENT ON COLUMN silver.area_live_shift.prev3_gross_production IS 'Shift N-3 gross production (count).';
COMMENT ON COLUMN silver.area_live_shift.prev3_net_production IS 'Shift N-3 net production (count).';
COMMENT ON COLUMN silver.area_live_shift.prev3_scrap IS 'Shift N-3 scrap (count).';
COMMENT ON COLUMN silver.area_live_shift.prev3_target IS 'Shift N-3 target (count).';
COMMENT ON COLUMN silver.area_live_shift.prev3_begin_time IS 'Shift N-3 start (tz-aware).';
COMMENT ON COLUMN silver.area_live_shift.prev3_end_time IS 'Shift N-3 end (tz-aware).';
COMMENT ON COLUMN silver.area_live_shift.prev3_id_shift IS 'Shift N-3 FK core.shifts.';
COMMENT ON COLUMN silver.area_live_shift.prev3_duration IS 'Shift N-3 planned duration (seconds).';
COMMENT ON COLUMN silver.area_live_shift.id_enterprise IS 'Denormalized hierarchy FK (core.enterprises).';
COMMENT ON COLUMN silver.area_live_shift.nm_area IS 'Denormalized area name (display).';
COMMENT ON COLUMN silver.area_live_shift.id_site IS 'Denormalized hierarchy FK (core.sites).';
COMMENT ON COLUMN silver.area_live_shift.id_shift_hour IS 'FK core.shift_hours — current calendar-expanded shift slot.';
COMMENT ON COLUMN silver.area_live_shift.prev1_id_shift_hour IS 'Previous shift (N-1) FK core.shift_hours.';

-- =====================================================================
-- SILVER — rollup continuous aggregates (TimescaleDB caggs; COMMENT ON VIEW)
-- =====================================================================

COMMENT ON VIEW silver.equipment_metrics_1min IS
'SILVER rollup CONTINUOUS AGGREGATE (1-minute bucket over silver.equipment_values, grouped by equipment + hierarchy + tp_equipment). NUMERIC-metrics grain: sums of net/gross/scrap, sum_speed + cnt_speed (for avg speed), cnt_rows, max_speed. Real-time cagg; primary source for the OEE hour/shift rollup engine.';
COMMENT ON COLUMN silver.equipment_metrics_1min.bucket IS 'Start of the 1-minute time bucket (time_bucket over ts_value, tz-aware).';
COMMENT ON COLUMN silver.equipment_metrics_1min.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.equipment_metrics_1min.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_metrics_1min.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_metrics_1min.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_metrics_1min.tp_equipment IS 'Equipment type (1=machine, 2=sector, 3=line) (group key; NULLs excluded).';
COMMENT ON COLUMN silver.equipment_metrics_1min.sum_net IS 'Sum of net_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_metrics_1min.sum_gross IS 'Sum of gross_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_metrics_1min.sum_scrap IS 'Sum of scrap_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_metrics_1min.sum_speed IS 'Sum of per-sample speed in the bucket (divide by cnt_speed for avg).';
COMMENT ON COLUMN silver.equipment_metrics_1min.cnt_speed IS 'Count of non-null speed samples in the bucket (avg denominator).';
COMMENT ON COLUMN silver.equipment_metrics_1min.cnt_rows IS 'Total sample rows in the bucket.';
COMMENT ON COLUMN silver.equipment_metrics_1min.max_speed IS 'Maximum per-sample speed in the bucket (units/time).';
COMMENT ON COLUMN silver.equipment_metrics_1min.ideal_production_speed IS 'Max ideal/nominal speed seen in the bucket (units/time).';

COMMENT ON VIEW silver.equipment_categorical_1min IS
'SILVER rollup CONTINUOUS AGGREGATE (1-minute bucket over silver.equipment_values). CATEGORICAL grain: preserves discrete dims (state, mode, id_order, id_shift/team/shift_hour, id_production_order) alongside incr sums and sum_speed/cnt_speed. Complements equipment_metrics_1min (the numeric-only grain). Source for categorical/shift-aware OEE rollups.';
COMMENT ON COLUMN silver.equipment_categorical_1min.ts_value IS 'Start of the 1-minute time bucket (tz-aware).';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1min.tp_equipment IS 'Equipment type (1=machine, 2=sector, 3=line) (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1min.state IS 'PackML state for the bucket (aggregated, e.g. max).';
COMMENT ON COLUMN silver.equipment_categorical_1min.mode IS 'PackML mode for the bucket (aggregated).';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_order IS 'Client-facing production order code for the bucket (string).';
COMMENT ON COLUMN silver.equipment_categorical_1min.conversion_factor IS 'Conversion factor for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.number_cavities IS 'Cavity count for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.signal_quality IS 'Signal-quality indicator for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_shift IS 'FK core.shifts for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_team IS 'Team id for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_shift_hour IS 'FK core.shift_hours for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.id_production_order IS 'FK core.production_orders for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.ts_value_production IS 'Production/business date for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.ideal_production_speed IS 'Ideal/nominal production speed for the bucket (units/time).';
COMMENT ON COLUMN silver.equipment_categorical_1min.net_production_incr IS 'Sum of net_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.gross_production_incr IS 'Sum of gross_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.scrap_incr IS 'Sum of scrap_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.sum_speed IS 'Sum of per-sample speed in the bucket (divide by cnt_speed for avg).';
COMMENT ON COLUMN silver.equipment_categorical_1min.cnt_speed IS 'Count of non-null speed samples in the bucket (avg denominator).';
COMMENT ON COLUMN silver.equipment_categorical_1min.cnt_rows IS 'Total sample rows in the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1min.net_production_val IS 'Representative net totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.gross_production_val IS 'Representative gross totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1min.scrap_val IS 'Representative scrap totalizer value in the bucket (count).';

COMMENT ON VIEW silver.equipment_categorical_1hour IS
'SILVER rollup CONTINUOUS AGGREGATE (1-hour bucket; hierarchical rollup of equipment_categorical_1min). CATEGORICAL grain with discrete dims + incr sums + sum_speed/cnt_speed. Feeds hourly OEE aggregates.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.ts_value IS 'Start of the 1-hour time bucket (tz-aware).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.tp_equipment IS 'Equipment type (1=machine, 2=sector, 3=line) (group key).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.state IS 'PackML state for the bucket (aggregated).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.mode IS 'PackML mode for the bucket (aggregated).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_order IS 'Client-facing production order code for the bucket (string).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.conversion_factor IS 'Conversion factor for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.number_cavities IS 'Cavity count for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.signal_quality IS 'Signal-quality indicator for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_shift IS 'FK core.shifts for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_team IS 'Team id for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_shift_hour IS 'FK core.shift_hours for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.id_production_order IS 'FK core.production_orders for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.ts_value_production IS 'Production/business date for the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.ideal_production_speed IS 'Ideal/nominal production speed for the bucket (units/time).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.net_production_incr IS 'Sum of net_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.gross_production_incr IS 'Sum of gross_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.scrap_incr IS 'Sum of scrap_incr in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.sum_speed IS 'Sum of per-sample speed in the bucket (divide by cnt_speed for avg).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.cnt_speed IS 'Count of non-null speed samples in the bucket (avg denominator).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.cnt_rows IS 'Total sample rows in the bucket.';
COMMENT ON COLUMN silver.equipment_categorical_1hour.net_production_val IS 'Representative net totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.gross_production_val IS 'Representative gross totalizer value in the bucket (count).';
COMMENT ON COLUMN silver.equipment_categorical_1hour.scrap_val IS 'Representative scrap totalizer value in the bucket (count).';

COMMENT ON VIEW silver.agg_equipment_values_1min IS
'SILVER rollup CONTINUOUS AGGREGATE (1-minute bucket over silver.equipment_values). WIDE legacy-shaped grain: incr sums, avg(speed), max() of most categorical dims and last() of box_code/transaction_code — mirrors the equipment_values column layout for legacy consumers. Real-time cagg (successor to the old public ca_agg_equipment_values_1min).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.ts_value IS 'Start of the 1-minute time bucket (tz-aware).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.tp_equipment IS 'Equipment type (1=machine, 2=sector, 3=line) (group key; NULLs excluded).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.net_production_incr IS 'Sum of net_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.gross_production_incr IS 'Sum of gross_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.scrap_incr IS 'Sum of scrap_incr in the bucket (count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.state IS 'max(state) in the bucket (PackML state).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.mode IS 'max(mode) in the bucket (PackML mode).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.speed IS 'avg(speed) in the bucket (units/time).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_order IS 'max(id_order) in the bucket (client PO code, text).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.conversion_factor IS 'max(conversion_factor) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1min.number_cavities IS 'max(number_cavities) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1min.signal_quality IS 'max(signal_quality) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1min.net_production_val IS 'max(net_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.gross_production_val IS 'max(gross_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.scrap_val IS 'max(scrap_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_shift IS 'max(id_shift) in the bucket (FK core.shifts).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_team IS 'max(id_team) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_shift_hour IS 'max(id_shift_hour) in the bucket (FK core.shift_hours).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.box_code IS 'last(box_code) in the bucket (latest by ts_value).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.transaction_code IS 'last(transaction_code) in the bucket (latest by ts_value).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_production_order IS 'max(id_production_order) in the bucket (FK core.production_orders).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.ts_value_production IS 'max(ts_value_production) in the bucket (production/business date).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.id_equipment_line_connected IS 'max(id_equipment_line_connected) in the bucket (line membership).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.position_in_equipment_line IS 'max(position_in_equipment_line) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1min.is_equipment_line_infeed IS 'max(is_equipment_line_infeed) in the bucket (1/0 flag).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.is_equipment_line_outfeed IS 'max(is_equipment_line_outfeed) in the bucket (1/0 flag).';
COMMENT ON COLUMN silver.agg_equipment_values_1min.ideal_production_speed IS 'max(ideal_production_speed) in the bucket (units/time).';

COMMENT ON VIEW silver.agg_equipment_values_1hour IS
'SILVER rollup CONTINUOUS AGGREGATE (1-hour bucket over silver.equipment_values). WIDE legacy-shaped grain (mirrors equipment_values layout for legacy consumers). Successor to the old public ca_agg_equipment_values_1hour. NOTE: this variant carries id_production_order (integer) rather than a text id_order, and has no state column.';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.ts_value IS 'Start of the 1-hour time bucket (tz-aware).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.tp_equipment IS 'Equipment type (1=machine, 2=sector, 3=line) (group key).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.net_production_incr IS 'Sum of net_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.gross_production_incr IS 'Sum of gross_production_incr in the bucket (count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.scrap_incr IS 'Sum of scrap_incr in the bucket (count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.mode IS 'max(mode) in the bucket (PackML mode).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.speed IS 'avg(speed) in the bucket (units/time).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_production_order IS 'max(id_production_order) in the bucket (FK core.production_orders).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.conversion_factor IS 'max(conversion_factor) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.number_cavities IS 'max(number_cavities) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.signal_quality IS 'max(signal_quality) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.net_production_val IS 'max(net_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.gross_production_val IS 'max(gross_production_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.scrap_val IS 'max(scrap_val) in the bucket (totalizer count).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_shift IS 'max(id_shift) in the bucket (FK core.shifts).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_team IS 'max(id_team) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_shift_hour IS 'max(id_shift_hour) in the bucket (FK core.shift_hours).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.box_code IS 'last(box_code) in the bucket (latest by ts_value).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.transaction_code IS 'last(transaction_code) in the bucket (latest by ts_value).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.ts_value_production IS 'max(ts_value_production) in the bucket (production/business date).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.id_equipment_line_connected IS 'max(id_equipment_line_connected) in the bucket (line membership).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.position_in_equipment_line IS 'max(position_in_equipment_line) in the bucket.';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.is_equipment_line_infeed IS 'max(is_equipment_line_infeed) in the bucket (1/0 flag).';
COMMENT ON COLUMN silver.agg_equipment_values_1hour.is_equipment_line_outfeed IS 'max(is_equipment_line_outfeed) in the bucket (1/0 flag).';

COMMENT ON VIEW silver.ca_discrete_changes_1s IS
'SILVER CONTINUOUS AGGREGATE (1-second bucket over silver.equipment_values). Discrete state/mode/order change grain feeding the CPAC downtime deriver — captures per-second categorical values used to detect transitions.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.ts_value IS 'Start of the 1-second time bucket (tz-aware).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.state IS 'PackML state for the second (aggregated).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.mode IS 'PackML mode for the second (aggregated).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_order IS 'Client-facing production order code for the second (string).';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_production_order IS 'FK core.production_orders for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.conversion_factor IS 'Conversion factor for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.number_cavities IS 'Cavity count for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.ts_value_production IS 'Production/business date for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_shift IS 'FK core.shifts for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_team IS 'Team id for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.id_shift_hour IS 'FK core.shift_hours for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.sub_mode IS 'PackML sub-mode string for the second.';
COMMENT ON COLUMN silver.ca_discrete_changes_1s.ideal_production_speed IS 'Ideal/nominal production speed for the second (units/time).';

COMMENT ON VIEW silver.ca_equipment_boxes_1s IS
'SILVER CONTINUOUS AGGREGATE (1-second bucket over silver.equipment_values). Per-second box/production count grain by PO + equipment (net_production sum and box qty), used by the box/PO counting surface.';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.ts_value IS 'Start of the 1-second time bucket (tz-aware).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_order IS 'Client-facing production order code (text; group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.net_production IS 'Sum of net production in the second (count).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.qty IS 'Count of box/production rows in the second.';
