-- t279 rollback — restore the exact prior (t278a / t278f / t278g) best-guess
-- comment wording captured via col_description on 2026-09-13 BEFORE t279 overwrote it.
-- Faithful verbatim restore (single quotes doubled for SQL literals).

COMMENT ON COLUMN core.enterprises.scrap_calc_type IS
'Enum controlling how scrap is computed for the tenant (default 1). Surfaced by read-api enterprise-config dataset; exact code meanings live in the OEE/scrap logic — CONFIRM the full enum before relying on non-default values.';

COMMENT ON COLUMN core.equipments.net_production_type IS
'Enum selecting how net production is measured for this equipment. Set via edge-api; CONFIRM the full code table before relying on non-default values.';

COMMENT ON COLUMN core.equipments.status_type IS
'PackML event-trigger type, emitted as Parameter[30758]: 0=instant, 4=5-min-average (CPAC algorithm). LOAD-BEARING: the stream-engine events deriver + per-sample event mint only run for status_type=4 equipment; minting events for status_type!=4 (lines/sectors/non-state machines) once caused a runtime_time over-count / int4 overflow.';

COMMENT ON COLUMN core.equipments.production_speed IS
'Configured nominal/ideal machine speed (units/time); emitted as PackML MachSpeed. Denominator input for Performance. Used as the line''s ideal speed when derived from the lead machine.';

COMMENT ON COLUMN core.equipments.ideal_speed IS
'Ideal speed (units/time) for OEE Performance. Overlaps production_speed; verify which one the active OEE path reads for this client.';

COMMENT ON COLUMN core.equipments.minimum_ideal_performance_threshold IS
'Lower bound on the ideal-performance band used in performance calc/alerting. CONFIRM exact semantics per client.';

COMMENT ON COLUMN core.equipments.exclude_idle_from_availability IS
'If true, idle time is excluded from the Availability denominator for this equipment. CONFIRM interaction with idle_timeout_seconds per client.';

COMMENT ON COLUMN core.equipments.id_equipment_status_mirror IS
'id_equipment whose status this equipment mirrors (a machine that inherits another''s state signal). Nullable. CONFIRM usage per client.';

COMMENT ON COLUMN core.equipments.sector_equipment_infeed IS
'For a sector (tp=2): id_equipment of the machine that is the sector infeed/input counter source. CONFIRM against sector OEE logic before relying on it.';

COMMENT ON COLUMN core.equipments.sector_equipment_outfeed IS
'For a sector (tp=2): id_equipment of the machine that is the sector outfeed/output counter source. CONFIRM against sector OEE logic before relying on it.';

COMMENT ON COLUMN core.equipments.id_equipment_state_status IS
'Legacy PackML state-code mapping: PLC state code this equipment reports for RUNNING/producing. Config for the state deriver; verify per client.';

COMMENT ON COLUMN core.equipments.id_equipment_state_idle IS
'Legacy PackML state-code mapping: PLC state code that means IDLE. Config for the state deriver; verify per client.';

COMMENT ON COLUMN core.equipments.id_equipment_state_starved IS
'Legacy PackML state-code mapping: PLC state code that means STARVED (no infeed). Config for the state deriver; verify per client.';

COMMENT ON COLUMN core.equipments.id_equipment_state_blocked IS
'Legacy PackML state-code mapping: PLC state code that means BLOCKED (downstream full). Config for the state deriver; verify per client.';

COMMENT ON COLUMN core.equipments.id_equipment_state_fault IS
'Legacy PackML state-code mapping: PLC state code that means FAULT. Config for the state deriver; verify per client.';

COMMENT ON COLUMN core.equipments.id_counter_status IS
'Legacy per-equipment counter/status source mapping (frontend/PLC config). No new-stack rollup reader located — CONFIRM before relying on it.';

COMMENT ON COLUMN core.equipments.id_packed_counter IS
'Counter/PLC-tag index for the packed-units count on this equipment. Legacy count-index metadata; verify per client.';

COMMENT ON COLUMN core.equipments.id_equipment_type IS
'Legacy equipment-type/category reference (distinct from tp_equipment). CONFIRM the referenced code table.';

COMMENT ON COLUMN core.equipments.id_plc IS
'Reference to the PLC / edge device this equipment is wired to. CONFIRM the referenced table per client.';

COMMENT ON COLUMN core.production_orders.conversion_factor IS
'Counter-units to production-units multiplier for this PO (default 1); inherited from equipments.conversion_factor at creation.';

COMMENT ON COLUMN core.production_orders.multiplier IS
'Additional production multiplier applied to counts for this PO. CONFIRM interaction with conversion_factor per client.';

COMMENT ON COLUMN core.shift_hours.day_number IS
'Weekday index (0..6) this expanded row applies to. Verify Monday=0 vs Sunday=0 convention per client.';

COMMENT ON COLUMN core.equipment_validation_shift.index1 IS
'Legacy opaque key (text; potentially numeric per external_integration.go coercion). Purpose UNCONFIRMED — likely a composite equipment/shift/date index. CONFIRM before use.';

COMMENT ON COLUMN core.equipment_validation_shift.shift_hrs IS
'Shift hours descriptor (text; may be numeric). UNCONFIRMED exact format.';

COMMENT ON COLUMN core.equipment_validation_shift.index2 IS
'Legacy opaque JSONB key/payload. Purpose UNCONFIRMED.';
