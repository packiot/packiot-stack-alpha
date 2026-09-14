-- t278a — core schema object documentation (COMMENT ON TABLE / COLUMN).
-- Idempotent + non-destructive. Staging: packiot_analytics.
-- core = the conformed-dimensions schema (enterprise -> site -> area -> equipment
-- hierarchy + the dims/reference tables the medallion facts (silver/gold) join to).
-- Sources: packiot/CLAUDE.md domain model, docs/audits/packiot-analytics-necessity-ledger.md,
-- and grep of stream-engine / read-api / edge-api. Traps encoded inline.

-- ============================================================ enterprises
COMMENT ON TABLE core.enterprises IS 'Top of the hierarchy: enterprise -> site -> area -> equipment. One row per tenant/customer. api_key authenticates edge-api ingest for the tenant. Carries default production-calendar (week_begin/day_begin/week_size) that sites/areas inherit or override, plus UI menu config.';
COMMENT ON COLUMN core.enterprises.nm_enterprise IS 'Enterprise (tenant) display name. NOTE the nm_ prefix — there is no plain "name" column; serving/bi views alias this to name.';
COMMENT ON COLUMN core.enterprises.api_key IS 'Per-tenant API key (randomUUID) issued by CS Admin at enterprise creation; authenticates edge-api factory ingest for this tenant.';
COMMENT ON COLUMN core.enterprises.week_begin IS 'INTEGER SECONDS offset of the production week start from Monday 00:00. MAY BE NEGATIVE (e.g. -3000 = Sunday 23:10). Sites/areas inherit or override. NOT a clock time.';
COMMENT ON COLUMN core.enterprises.day_begin IS 'INTEGER SECONDS offset of the production day start from midnight. NOT a clock time.';
COMMENT ON COLUMN core.enterprises.week_size IS 'INTEGER SECONDS in the production week (normally 604800).';
COMMENT ON COLUMN core.enterprises.timezone IS 'IANA timezone name (e.g. America/Sao_Paulo) used to localise the tenant''s shifts/OEE buckets.';
COMMENT ON COLUMN core.enterprises.scrap_calc_type IS 'Enum controlling how scrap is computed for the tenant (default 1). Surfaced by read-api enterprise-config dataset; exact code meanings live in the OEE/scrap logic — CONFIRM the full enum before relying on non-default values.';
COMMENT ON COLUMN core.enterprises.basic_menu IS 'JSONB: default UI navigation menu structure for the tenant (front4).';
COMMENT ON COLUMN core.enterprises.custom_menu IS 'JSONB: per-tenant UI menu overrides (front4).';
COMMENT ON COLUMN core.enterprises.language_packs IS 'JSONB: i18n language pack config for the tenant.';
COMMENT ON COLUMN core.enterprises.active IS 'Soft-delete flag. active=false hides the enterprise; consumers should filter on it.';
COMMENT ON COLUMN core.enterprises.valid_from IS 'SCD-style validity window start (defaults now()). Row is considered current while valid_to IS NULL.';
COMMENT ON COLUMN core.enterprises.valid_to IS 'SCD-style validity window end; NULL = still current.';

-- ============================================================ sites
COMMENT ON TABLE core.sites IS 'Site (physical plant) under an enterprise. Second level of the hierarchy. Owns the production-calendar (week_begin/day_begin/week_size) and timezone actually used for shift/OEE bucketing; overrides enterprise defaults, is itself overridable by area.';
COMMENT ON COLUMN core.sites.nm_site IS 'Site display name.';
COMMENT ON COLUMN core.sites.week_begin IS 'INTEGER SECONDS offset of the week start from Monday 00:00; may be negative. Overrides enterprise. NOT a clock time.';
COMMENT ON COLUMN core.sites.day_begin IS 'INTEGER SECONDS offset of the day start from midnight. Overrides enterprise. NOT a clock time.';
COMMENT ON COLUMN core.sites.week_size IS 'INTEGER SECONDS in the production week. Overrides enterprise.';
COMMENT ON COLUMN core.sites.timezone IS 'IANA timezone for the site (e.g. America/Sao_Paulo). Drives shift/OEE localisation at the site level.';
COMMENT ON COLUMN core.sites.language_tag IS 'BCP-47 language tag (e.g. pt-BR) for site-level UI localisation.';
COMMENT ON COLUMN core.sites.email_alert_users IS 'JSONB: list of users/addresses that receive site alert emails.';
COMMENT ON COLUMN core.sites.active IS 'Soft-delete flag; false hides the site.';
COMMENT ON COLUMN core.sites.valid_from IS 'SCD-style validity window start (defaults now()).';
COMMENT ON COLUMN core.sites.valid_to IS 'SCD-style validity window end; NULL = current.';

-- ============================================================ areas
COMMENT ON TABLE core.areas IS 'Area (production line grouping / plant section) under a site. Third level of the hierarchy. Owns the finest-grained production-calendar override (week_begin/day_begin/week_size). Shifts are scoped to area first, site as fallback.';
COMMENT ON COLUMN core.areas.nm_area IS 'Area display name.';
COMMENT ON COLUMN core.areas.id_infeedcounter IS 'DEPRECATED / DEAD (0 rows). Legacy count-index metadata, no functional reader (view-passthrough only). Pending drop.';
COMMENT ON COLUMN core.areas.id_outfeedcounter IS 'DEPRECATED / DEAD (0 rows). See id_infeedcounter.';
COMMENT ON COLUMN core.areas.id_rejectscounter IS 'DEPRECATED / DEAD (0 rows). See id_infeedcounter.';
COMMENT ON COLUMN core.areas.week_begin IS 'INTEGER SECONDS offset of the week start from Monday 00:00; may be negative. Overrides site. NOT a clock time.';
COMMENT ON COLUMN core.areas.day_begin IS 'INTEGER SECONDS offset of the day start from midnight. Overrides site. NOT a clock time.';
COMMENT ON COLUMN core.areas.week_size IS 'INTEGER SECONDS in the production week. Overrides site.';
COMMENT ON COLUMN core.areas.active IS 'Soft-delete flag; false hides the area.';
COMMENT ON COLUMN core.areas.valid_from IS 'SCD-style validity window start (defaults now()).';
COMMENT ON COLUMN core.areas.valid_to IS 'SCD-style validity window end; NULL = current.';

-- ============================================================ equipments
COMMENT ON TABLE core.equipments IS 'Equipment dimension — machines, sectors, and lines (see tp_equipment). Leaf of the hierarchy and the central join key (id_equipment) for nearly all facts. Holds OEE/PackML config: speeds, thresholds, counter-role wiring, state-code mappings. Populated by CS Admin (edge-api); most config columns are set at onboarding.';
COMMENT ON COLUMN core.equipments.cd_equipment IS 'Human/ERP equipment code (unique within tenant); used to resolve equipment by code (e.g. box-production bridges, SAP report joins).';
COMMENT ON COLUMN core.equipments.nm_equipment IS 'Equipment display name.';
COMMENT ON COLUMN core.equipments.position IS 'Ordering of the machine within its parent line/sector.';
COMMENT ON COLUMN core.equipments.tp_equipment IS 'Equipment type: 1=machine (individual unit), 2=sector (group of machines), 3=line (full production line). Load-bearing for rollup scope, event-mint gate, and id_unit NULL-ness.';
COMMENT ON COLUMN core.equipments.id_parentequipment IS 'Line/sector membership: parent id_equipment (a tp=1 machine points to its tp=2 sector or tp=3 line). NULL for top-level equipment. This is membership, NOT lead-machine.';
COMMENT ON COLUMN core.equipments.stop_threshold_time IS 'INTEGER SECONDS a machine must be stopped before the stop counts as a downtime (default 300). Emitted as PackML Parameter[30751] (min threshold time).';
COMMENT ON COLUMN core.equipments.production_speed IS 'Configured nominal/ideal machine speed (units/time); emitted as PackML MachSpeed. Denominator input for Performance. Used as the line''s ideal speed when derived from the lead machine.';
COMMENT ON COLUMN core.equipments.performance_alert_threshold IS 'Performance (%) below which a performance alert fires (front4/alerts).';
COMMENT ON COLUMN core.equipments.minimum_performance_threshold IS 'Min speed threshold; emitted as PackML Parameter[30750]. Speed below this counts as a micro-stop / low-speed condition.';
COMMENT ON COLUMN core.equipments.require_downtime_reason IS 'If true, operators must justify downtimes (a reason is mandatory) for this equipment.';
COMMENT ON COLUMN core.equipments.sector_equipment_infeed IS 'For a sector (tp=2): id_equipment of the machine that is the sector infeed/input counter source. CONFIRM against sector OEE logic before relying on it.';
COMMENT ON COLUMN core.equipments.sector_equipment_outfeed IS 'For a sector (tp=2): id_equipment of the machine that is the sector outfeed/output counter source. CONFIRM against sector OEE logic before relying on it.';
COMMENT ON COLUMN core.equipments.status_type IS 'PackML event-trigger type, emitted as Parameter[30758]: 0=instant, 4=5-min-average (CPAC algorithm). LOAD-BEARING: the stream-engine events deriver + per-sample event mint only run for status_type=4 equipment; minting events for status_type!=4 (lines/sectors/non-state machines) once caused a runtime_time over-count / int4 overflow.';
COMMENT ON COLUMN core.equipments.id_counter_status IS 'Legacy per-equipment counter/status source mapping (frontend/PLC config). No new-stack rollup reader located — CONFIRM before relying on it.';
COMMENT ON COLUMN core.equipments.id_equipment_state_status IS 'Legacy PackML state-code mapping: PLC state code this equipment reports for RUNNING/producing. Config for the state deriver; verify per client.';
COMMENT ON COLUMN core.equipments.id_equipment_state_idle IS 'Legacy PackML state-code mapping: PLC state code that means IDLE. Config for the state deriver; verify per client.';
COMMENT ON COLUMN core.equipments.id_equipment_state_starved IS 'Legacy PackML state-code mapping: PLC state code that means STARVED (no infeed). Config for the state deriver; verify per client.';
COMMENT ON COLUMN core.equipments.id_equipment_state_blocked IS 'Legacy PackML state-code mapping: PLC state code that means BLOCKED (downstream full). Config for the state deriver; verify per client.';
COMMENT ON COLUMN core.equipments.id_equipment_state_fault IS 'Legacy PackML state-code mapping: PLC state code that means FAULT. Config for the state deriver; verify per client.';
COMMENT ON COLUMN core.equipments.id_equipment_status_mirror IS 'id_equipment whose status this equipment mirrors (a machine that inherits another''s state signal). Nullable. CONFIRM usage per client.';
COMMENT ON COLUMN core.equipments.id_packed_counter IS 'Counter/PLC-tag index for the packed-units count on this equipment. Legacy count-index metadata; verify per client.';
COMMENT ON COLUMN core.equipments.cd_sector IS 'Free-text sector code/label for grouping (distinct from tp=2 sector equipment rows).';
COMMENT ON COLUMN core.equipments.downtime_reasons IS 'JSONB: legacy INLINE per-equipment downtime-reason list. Being replaced by the normalized core.downtime_reason dimension + core.equipment_downtime_reason junction; still present for backward compat.';
COMMENT ON COLUMN core.equipments.scrap_reasons IS 'JSONB: legacy INLINE per-equipment scrap-reason list. The normalized core.scrap_reason + core.equipment_scrap_reason pair is the intended replacement (scrap R5 not yet completed) — this JSONB is still the live source of scrap reasons.';
COMMENT ON COLUMN core.equipments.minimum_ideal_performance_threshold IS 'Lower bound on the ideal-performance band used in performance calc/alerting. CONFIRM exact semantics per client.';
COMMENT ON COLUMN core.equipments.custom IS 'JSONB: free-form per-equipment custom config/attributes.';
COMMENT ON COLUMN core.equipments.ideal_speed IS 'Ideal speed (units/time) for OEE Performance. Overlaps production_speed; verify which one the active OEE path reads for this client.';
COMMENT ON COLUMN core.equipments.overview_events_type IS 'front4 Overview page config: which event type/category to display. UI presentation flag.';
COMMENT ON COLUMN core.equipments.overview_events_filter_by_idle IS 'front4 Overview config: filter displayed events by idle state. UI presentation flag.';
COMMENT ON COLUMN core.equipments.flexible_position IS 'If true, the machine''s position within its line is not fixed (front4 layout flag).';
COMMENT ON COLUMN core.equipments.event_should_be_displayed IS 'front4 flag: whether this equipment''s events show in the UI.';
COMMENT ON COLUMN core.equipments.overview_version IS 'JSONB: front4 Overview page version/layout config.';
COMMENT ON COLUMN core.equipments.use_label_net_production IS 'If true, net production is taken from LABEL/box scans rather than the raw PLC net counter (label-net-production path, e.g. Neopac boxes bridge).';
COMMENT ON COLUMN core.equipments.state_change_threshold_time IS 'INTEGER SECONDS a state change must persist before it is accepted (debounce for state transitions).';
COMMENT ON COLUMN core.equipments.lead_machine IS 'LINE COUNTER-ROLE (PackML Parameter[30702]): the id_equipment of the machine that REPRESENTS a tp=2/tp=3 line/sector for OEE — its counter stream + availability cadence are read as the line''s. Default = first machine in the line. On a split-instrumentation line it is specifically the NET/output + availability source (see gross_machine / scrap_machine).';
COMMENT ON COLUMN core.equipments.speed_calculated_by_packiot IS 'If true, Packiot computes speed from counts rather than reading a PLC speed tag.';
COMMENT ON COLUMN core.equipments.event_generated_by_packiot IS 'If true, downtime/state events are derived by Packiot (stream-engine deriver) rather than sent pre-formed by the PLC/edge.';
COMMENT ON COLUMN core.equipments.conversion_factor IS 'Multiplier converting raw counter units to production units for this equipment (default 1). Inherited onto new production orders.';
COMMENT ON COLUMN core.equipments.net_production_type IS 'Enum selecting how net production is measured for this equipment. Set via edge-api; CONFIRM the full code table before relying on non-default values.';
COMMENT ON COLUMN core.equipments.id_plc IS 'Reference to the PLC / edge device this equipment is wired to. CONFIRM the referenced table per client.';
COMMENT ON COLUMN core.equipments.gross_machine IS 'LINE SPLIT-INSTRUMENTATION counter-role: id_equipment naming the GROSS/input (ProdConsumedCount) source for a line whose counters live on different machines. NULL => gross_id COALESCEs to lead_machine (single-lead line). See services/stream-engine/internal/rollup/line_lead.go.';
COMMENT ON COLUMN core.equipments.scrap_machine IS 'LINE SPLIT-INSTRUMENTATION counter-role: id_equipment naming the SCRAP/defect (ProdDefectiveCount) source for a split-instrumented line. NULL => scrap_id NULL => scrap 0 (quality 1.0). See line_lead.go.';
COMMENT ON COLUMN core.equipments.exclude_idle_from_availability IS 'If true, idle time is excluded from the Availability denominator for this equipment. CONFIRM interaction with idle_timeout_seconds per client.';
COMMENT ON COLUMN core.equipments.idle_timeout_seconds IS 'INTEGER SECONDS: inter-count gap beyond which a counter-only/line-from-lead equipment is treated as stopped (idle-timeout sessionization). Defaults to the COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS env (300) when NULL.';
COMMENT ON COLUMN core.equipments.id_equipment_type IS 'Legacy equipment-type/category reference (distinct from tp_equipment). CONFIRM the referenced code table.';
COMMENT ON COLUMN core.equipments.alerts IS 'JSONB: per-equipment alert configuration.';
COMMENT ON COLUMN core.equipments.active IS 'Soft-delete flag; false hides the equipment. Filter on it in new-stack consumers.';
COMMENT ON COLUMN core.equipments.valid_from IS 'SCD-style validity window start (defaults now()).';
COMMENT ON COLUMN core.equipments.valid_to IS 'SCD-style validity window end; NULL = current.';

-- ============================================================ topic_routing (renamed from packml_register, #243)
COMMENT ON TABLE core.topic_routing IS 'SparkPlug-B topic routing dimension (renamed from packml_register, #243). Maps a packml_topic / device_key string to id_equipment + hierarchy so the decoder can attribute incoming PLC metrics. CS Admin creates every row (active=true); oeecloud/stream-engine only READ for resolution (topology.go also UPDATEs via the packml_register compat view). Also carries a last-value cache (value/timestamp/signal_quality) per topic.';
COMMENT ON COLUMN core.topic_routing.id_topic_route IS 'Surrogate PK (sequence packml_register_id_packml_register_seq, pre-rename). Exposed as id_packml_register through the core.packml_register compat view.';
COMMENT ON COLUMN core.topic_routing.packml_topic IS 'The SparkPlug/PackML topic string this row routes to id_equipment.';
COMMENT ON COLUMN core.topic_routing.timestamp IS 'Timestamp of the last cached value for this topic.';
COMMENT ON COLUMN core.topic_routing.value IS 'Last cached raw value received on this topic (varchar).';
COMMENT ON COLUMN core.topic_routing.signal_quality IS 'Last signal-quality code for the topic (smallint). Runtime cache field, not CS-Admin config.';
COMMENT ON COLUMN core.topic_routing.ts_quality IS 'Timestamp of the last signal_quality update.';
COMMENT ON COLUMN core.topic_routing.mqtt_topic IS 'Underlying MQTT topic (transport-level), distinct from the logical packml_topic.';
COMMENT ON COLUMN core.topic_routing.sparkplug_json IS 'JSONB: raw SparkPlug metric/definition payload captured for this topic.';
COMMENT ON COLUMN core.topic_routing.id_infeedcounter IS 'WIRE COUNT-INDEX (PLC count-tag position), NOT an id_equipment FK. On LINE rows (tp_equipment=3) this is the line INFEED meter index; read LIVE by edge-transformer line_param30700_seed.go to seed Parameter30700 for Phase-9 line aggregation (gated PHASE9_LINE_AGG_ENABLED). Do NOT read as id_equipment — that mislabel caused the 2026-08-26 counterroles/Phase-9 collision.';
COMMENT ON COLUMN core.topic_routing.id_outfeedcounter IS 'WIRE COUNT-INDEX — line OUTFEED meter index. Read LIVE by Phase-9 (see id_infeedcounter). NOT an id_equipment FK.';
COMMENT ON COLUMN core.topic_routing.active IS 'Routing enable flag. oeecloud/decoder only resolve topics where active=true; CS Admin must set true for a topic to be processed.';
COMMENT ON COLUMN core.topic_routing.attributed IS 'True once the topic has been attributed/mapped to an equipment (onboarding attribution state).';
COMMENT ON COLUMN core.topic_routing.id_unit IS 'Nullable metering-unit FK: = id_equipment for machines (tp_equipment=1), NULL for lines/sectors. NOT a duplicate of id_equipment — its NULL-ness marks non-machine rows and is load-bearing for the decoder/refdata joins. Do NOT rename to id_equipment. PackML Parameter[30700] is looked up via id_unit.';
COMMENT ON COLUMN core.topic_routing.line_unit_seq IS 'Machine sequence within a line/unit (ordering string for line aggregation). Verify format per client.';
COMMENT ON COLUMN core.topic_routing.device_nm IS 'SparkPlug device display name.';
COMMENT ON COLUMN core.topic_routing.device_key IS 'Tenant-prefixed, GLOBALLY-UNIQUE SparkPlug device id (e.g. CPACK-…, BISNAGO-…). read-api /internal/resolve-device resolves device_key -> id_equipment (ADR-0046); a partial unique index enforces <=1 active row per device_key.';

-- ============================================================ packml_register (compat view)
COMMENT ON VIEW core.packml_register IS 'Backward-compat, auto-updatable shim view over core.topic_routing (the #243 rename). Renames id_topic_route -> id_packml_register; all other columns pass through 1:1. Read AND written (UPDATE) by legacy consumers (6 DB fns, resolver.go, pocontrol/topology.go, read-api). DROP-BLOCKED pending the topic_routing repoint epic — do not drop until every consumer is repointed.';

-- ============================================================ production_orders
COMMENT ON TABLE core.production_orders IS 'Production order (PO) lifecycle + per-PO OEE result row. status codes: 1=available, 2=running, 3=finished, 4=paused. Created/controlled via edge-api + stream-engine pocontrol (SparkPlug 30800-series). The OEE engine writes the computed result columns (oee/oee_q/oee_a/oee_p, times) and flips recalc_needed/oee_processed.';
COMMENT ON COLUMN core.production_orders.id_production_order IS 'Surrogate PK — globally unique.';
COMMENT ON COLUMN core.production_orders.id_order IS 'Per-equipment/tenant order sequence. NATURAL KEY UNIQUE(id_enterprise, id_order) — NOT globally unique on its own. Used by pocontrol ON CONFLICT upsert.';
COMMENT ON COLUMN core.production_orders.id_order_text IS 'External ERP order code (free text) as sent by the customer''s ERP; distinct from the numeric id_order.';
COMMENT ON COLUMN core.production_orders.status IS 'PO lifecycle state: 1=available, 2=running, 3=finished, 4=paused.';
COMMENT ON COLUMN core.production_orders.id_equipment IS 'Equipment the PO is planned on.';
COMMENT ON COLUMN core.production_orders.id_equipment_executed IS 'Equipment the PO actually ran on (may differ from planned id_equipment).';
COMMENT ON COLUMN core.production_orders.production_programmed IS 'Planned/scheduled production quantity for the PO.';
COMMENT ON COLUMN core.production_orders.production_ordered IS 'Ordered quantity (ERP demand) for the PO.';
COMMENT ON COLUMN core.production_orders.production_real IS 'Actual produced quantity (gross count) recorded during the run.';
COMMENT ON COLUMN core.production_orders.production_final IS 'Final confirmed production quantity at PO close.';
COMMENT ON COLUMN core.production_orders.net_production IS 'Net (good) production for the PO (gross minus scrap). Written by the OEE engine.';
COMMENT ON COLUMN core.production_orders.gross_production IS 'Gross production count for the PO. Written by the OEE engine.';
COMMENT ON COLUMN core.production_orders.equipment_setup IS 'JSONB: PackML/equipment setup parameters captured for this PO run.';
COMMENT ON COLUMN core.production_orders.oee_processed IS 'True once the OEE engine has processed this PO (default false).';
COMMENT ON COLUMN core.production_orders.oee IS 'Overall OEE for the PO (0..1) = oee_q * oee_a * oee_p. Written by the OEE engine.';
COMMENT ON COLUMN core.production_orders.oee_q IS 'Quality factor (0..1) of the PO''s OEE. Renamed from oee_quality (#243).';
COMMENT ON COLUMN core.production_orders.oee_a IS 'Availability factor (0..1) of the PO''s OEE. Renamed (#243).';
COMMENT ON COLUMN core.production_orders.oee_p IS 'Performance factor (0..1) of the PO''s OEE. Renamed (#243).';
COMMENT ON COLUMN core.production_orders.stopped_time IS 'INTEGER SECONDS of total stopped time during the PO. Written by the OEE engine.';
COMMENT ON COLUMN core.production_orders.planned_downtime IS 'INTEGER SECONDS of planned downtime during the PO (excluded from Availability denominator).';
COMMENT ON COLUMN core.production_orders.qt_stops IS 'Count of stop events during the PO.';
COMMENT ON COLUMN core.production_orders.available_time IS 'INTEGER/float SECONDS: Availability denominator = shift/PO elapsed time minus planned downtime. Written by the OEE engine (rollup).';
COMMENT ON COLUMN core.production_orders.running_time IS 'SECONDS the equipment was actually running (Availability numerator), clamped <= available_time. Written by the OEE engine.';
COMMENT ON COLUMN core.production_orders.erp_processed IS 'True once the PO result has been exported/acknowledged to the ERP (default false).';
COMMENT ON COLUMN core.production_orders.recalc_needed IS 'Set true (default) to flag the PO for (re)computation by the OEE engine; the engine clears it after processing. Drives re-processing of edited/late-arriving data.';
COMMENT ON COLUMN core.production_orders.conversion_factor IS 'Counter-units to production-units multiplier for this PO (default 1); inherited from equipments.conversion_factor at creation.';
COMMENT ON COLUMN core.production_orders.multiplier IS 'Additional production multiplier applied to counts for this PO. CONFIRM interaction with conversion_factor per client.';
COMMENT ON COLUMN core.production_orders.speed IS 'Recorded/effective production speed for the PO. Written by the OEE engine.';
COMMENT ON COLUMN core.production_orders.ideal_production_speed IS 'Ideal speed used as the Performance baseline for the PO.';
COMMENT ON COLUMN core.production_orders.ideal_production IS 'Ideal (theoretical max) production quantity over the run window at ideal speed.';
COMMENT ON COLUMN core.production_orders.ts_start IS 'PO start timestamp (when it entered running).';
COMMENT ON COLUMN core.production_orders.ts_end IS 'PO end timestamp (when it finished).';
COMMENT ON COLUMN core.production_orders.ts_start_tz IS 'PO start localised to the tenant/site timezone.';
COMMENT ON COLUMN core.production_orders.ts_end_tz IS 'PO end localised to the tenant/site timezone.';
COMMENT ON COLUMN core.production_orders.ts_creation IS 'When the PO row was created (default now()).';
COMMENT ON COLUMN core.production_orders.last_update IS 'Last time the PO row was updated (default now()).';
COMMENT ON COLUMN core.production_orders.id_user_operator IS 'Operator (user) associated with the PO run.';
COMMENT ON COLUMN core.production_orders.nm_production_order IS 'PO display name/label.';
COMMENT ON COLUMN core.production_orders.txt_production_order_notes IS 'Free-text operator notes on the PO.';
COMMENT ON COLUMN core.production_orders.txt_production_order_description IS 'Free-text PO description.';
COMMENT ON COLUMN core.production_orders.custom_field IS 'JSONB: free-form custom PO fields (e.g. carried via SparkPlug 30805 create-PO payload).';
COMMENT ON COLUMN core.production_orders.id_label IS 'Reference to the box/label definition associated with the PO (label-net-production / box scans).';

-- ============================================================ products
COMMENT ON TABLE core.products IS 'Product dimension. A product belongs to a product family and an enterprise; carries per-product speed + scrap target + setup used when a PO runs this product.';
COMMENT ON COLUMN core.products.nm_product IS 'Product display name.';
COMMENT ON COLUMN core.products.cd_product IS 'Product code (ERP/customer code).';
COMMENT ON COLUMN core.products.txt_product IS 'Free-text product description.';
COMMENT ON COLUMN core.products.id_product_family IS 'FK to core.product_families.';
COMMENT ON COLUMN core.products.scrap_target IS 'Per-product scrap target (percent, default 15) used as the quality baseline for this product.';
COMMENT ON COLUMN core.products.speed IS 'Per-product ideal/nominal speed (units/time) — Performance baseline when running this product.';
COMMENT ON COLUMN core.products.equipment_setup IS 'JSONB: default equipment/PackML setup for POs of this product.';

-- ============================================================ product_families
COMMENT ON TABLE core.product_families IS 'Product-family dimension — thin grouping of products under an enterprise. Read by stream-engine current_rest.go.';
COMMENT ON COLUMN core.product_families.nm_product_family IS 'Product family display name.';

-- ============================================================ clients
COMMENT ON TABLE core.clients IS 'Customer/client dimension (the buyer a production order is produced FOR), scoped to an enterprise. Referenced by production_orders.id_client. Distinct from enterprises (the Packiot tenant).';
COMMENT ON COLUMN core.clients.nm_client IS 'Client (buyer) display name.';

-- ============================================================ teams
COMMENT ON TABLE core.teams IS 'Operating team/crew dimension, scoped to equipment/area/site/enterprise. Used to partition production by shift/team (serving.total_production_by_team, bi.production_by_team).';
COMMENT ON COLUMN core.teams.cd_team IS 'Team code/label.';
COMMENT ON COLUMN core.teams.sequence_position IS 'Ordering of the team in the shift rotation (default 0).';

-- ============================================================ shifts
COMMENT ON TABLE core.shifts IS 'Shift DEFINITION layer. cd_shift is alphanumeric (e.g. MORNING, T1, 1). Scoped to area first, site as fallback. begin_time/end_time here are CLOCK times (time-of-day) — contrast core.shift_hours, whose begin/end are integer seconds from week_begin.';
COMMENT ON COLUMN core.shifts.cd_shift IS 'Alphanumeric shift code (e.g. MORNING, T1, 1). NOT necessarily numeric.';
COMMENT ON COLUMN core.shifts.begin_time IS 'Clock time (time-of-day) the shift starts. Shift DEFINITION. Contrast core.shift_hours.begin_time, which is integer seconds from week_begin.';
COMMENT ON COLUMN core.shifts.end_time IS 'Clock time (time-of-day) the shift ends. See core.shifts.begin_time.';
COMMENT ON COLUMN core.shifts.sequence_position IS 'Ordering of the shift within the day/rotation.';

-- ============================================================ shift_hours
COMMENT ON TABLE core.shift_hours IS 'Shift CALENDAR EXPANSION — one row per shift x weekday. begin_time/end_time are INTEGER SECONDS FROM week_begin (NOT clock times). The runtime fields shift_size/duration/id_equipment are set by the OEE ENGINE, not by CS Admin.';
COMMENT ON COLUMN core.shift_hours.cd_shift IS 'Alphanumeric shift code (denormalized from core.shifts).';
COMMENT ON COLUMN core.shift_hours.begin_time IS 'INTEGER SECONDS from week_begin (NOT a clock time). Calendar expansion of a shift x weekday. Contrast core.shifts.begin_time, which IS a clock time.';
COMMENT ON COLUMN core.shift_hours.end_time IS 'INTEGER SECONDS from week_begin (NOT a clock time). See core.shift_hours.begin_time.';
COMMENT ON COLUMN core.shift_hours.day_number IS 'Weekday index (0..6) this expanded row applies to. Verify Monday=0 vs Sunday=0 convention per client.';
COMMENT ON COLUMN core.shift_hours.day_week IS 'Weekday name/label for the row (denormalized companion to day_number).';
COMMENT ON COLUMN core.shift_hours.shift_size IS 'RUNTIME field set by the OEE engine: shift length in seconds. NOT CS-Admin config.';
COMMENT ON COLUMN core.shift_hours.duration IS 'RUNTIME field set by the OEE engine: effective duration in seconds. NOT CS-Admin config.';
COMMENT ON COLUMN core.shift_hours.id_equipment IS 'RUNTIME field set by the OEE engine (per-equipment shift expansion). NOT CS-Admin config.';

-- ============================================================ shifts_exception_period
COMMENT ON TABLE core.shifts_exception_period IS 'Holiday / exception windows [ts_begin, ts_end) per equipment that override the normal shift calendar (e.g. plant shutdown). Read defensively by piot_create_equipment_oee_shift; HALF-BUILT — no new-stack writer exists yet (needs a CS Admin CRUD), so empty today is harmless.';
COMMENT ON COLUMN core.shifts_exception_period.ts_begin IS 'Start of the exception/holiday window.';
COMMENT ON COLUMN core.shifts_exception_period.ts_end IS 'End of the exception/holiday window.';

-- ============================================================ downtime_reason
COMMENT ON TABLE core.downtime_reason IS 'Downtime-reason DIMENSION (R5 normalization), per enterprise. Hierarchical (parent_id + reason_level). Replaces the inline equipments.downtime_reasons JSONB; paired with the core.equipment_downtime_reason junction. ~54 rows on staging.';
COMMENT ON COLUMN core.downtime_reason.code IS 'Stable reason code (unique per enterprise).';
COMMENT ON COLUMN core.downtime_reason.label IS 'Default human-readable reason label.';
COMMENT ON COLUMN core.downtime_reason.label_i18n IS 'JSONB: locale -> translated label map.';
COMMENT ON COLUMN core.downtime_reason.category IS 'Reason category/grouping.';
COMMENT ON COLUMN core.downtime_reason.parent_id IS 'Self-FK to the parent reason (reason tree). NULL at the top level.';
COMMENT ON COLUMN core.downtime_reason.reason_level IS 'Depth in the reason hierarchy (default 1 = top level).';
COMMENT ON COLUMN core.downtime_reason.planned_downtime IS 'If true, downtimes with this reason are PLANNED (excluded from Availability loss).';
COMMENT ON COLUMN core.downtime_reason.change_over IS 'If true, this reason represents a changeover/setup.';
COMMENT ON COLUMN core.downtime_reason.idle IS 'If true, this reason represents idle time.';
COMMENT ON COLUMN core.downtime_reason.active IS 'Soft-delete flag; false hides the reason.';
COMMENT ON COLUMN core.downtime_reason.valid_from IS 'SCD-style validity window start.';
COMMENT ON COLUMN core.downtime_reason.valid_to IS 'SCD-style validity window end; NULL = current.';

-- ============================================================ equipment_downtime_reason
COMMENT ON TABLE core.equipment_downtime_reason IS 'JUNCTION: which downtime reasons (core.downtime_reason) are enabled for which equipment. Many-to-many (id_equipment, id_reason). ~1188 rows on staging. Together with the dimension it replaces the inline equipments.downtime_reasons JSONB.';
COMMENT ON COLUMN core.equipment_downtime_reason.id_reason IS 'FK to core.downtime_reason.id.';
COMMENT ON COLUMN core.equipment_downtime_reason.active IS 'Soft-delete flag for the equipment<->reason link.';
COMMENT ON COLUMN core.equipment_downtime_reason.valid_from IS 'SCD-style validity window start.';
COMMENT ON COLUMN core.equipment_downtime_reason.valid_to IS 'SCD-style validity window end; NULL = current.';

-- ============================================================ scrap_reason
COMMENT ON TABLE core.scrap_reason IS 'Scrap-reason DIMENSION (R5 normalization), per enterprise. Mirrors the downtime_reason shape (hierarchical, i18n). FORWARD SCHEMA / HALF-BUILT: 0 rows, no writer/reader in any repo — scrap reasons still live in the inline equipments.scrap_reasons JSONB. This is the intended target once scrap R5 is completed; do NOT treat as cruft.';
COMMENT ON COLUMN core.scrap_reason.code IS 'Stable scrap-reason code (unique per enterprise).';
COMMENT ON COLUMN core.scrap_reason.label IS 'Default human-readable label.';
COMMENT ON COLUMN core.scrap_reason.label_i18n IS 'JSONB: locale -> translated label map.';
COMMENT ON COLUMN core.scrap_reason.category IS 'Reason category/grouping.';
COMMENT ON COLUMN core.scrap_reason.parent_id IS 'Self-FK to the parent reason. NULL at top level.';
COMMENT ON COLUMN core.scrap_reason.reason_level IS 'Depth in the reason hierarchy (default 1).';
COMMENT ON COLUMN core.scrap_reason.active IS 'Soft-delete flag.';
COMMENT ON COLUMN core.scrap_reason.valid_from IS 'SCD-style validity window start.';
COMMENT ON COLUMN core.scrap_reason.valid_to IS 'SCD-style validity window end; NULL = current.';

-- ============================================================ equipment_scrap_reason
COMMENT ON TABLE core.equipment_scrap_reason IS 'JUNCTION: which scrap reasons (core.scrap_reason) are enabled for which equipment. FORWARD SCHEMA / HALF-BUILT: 0 rows, fully unwired — the scrap-side analog of core.equipment_downtime_reason, pending completion of scrap R5. Not cruft.';
COMMENT ON COLUMN core.equipment_scrap_reason.id_reason IS 'FK to core.scrap_reason.id.';
COMMENT ON COLUMN core.equipment_scrap_reason.active IS 'Soft-delete flag for the equipment<->reason link.';
COMMENT ON COLUMN core.equipment_scrap_reason.valid_from IS 'SCD-style validity window start.';
COMMENT ON COLUMN core.equipment_scrap_reason.valid_to IS 'SCD-style validity window end; NULL = current.';

-- ============================================================ production_targets
COMMENT ON TABLE core.production_targets IS 'Production-QUANTITY targets by grain. The (id_enterprise, id_site, id_area, id_equipment) tuple identifies the target scope (0 = wildcard/unset). vl_* columns are the target quantities per period. Live writer + reader. Distinct from scrap_targets (scrap qty) and oee_targets (OEE %).';
COMMENT ON COLUMN core.production_targets.id_equipment IS 'Equipment scope of the target (0 = not equipment-specific).';
COMMENT ON COLUMN core.production_targets.id_site IS 'Site scope of the target (0 = not site-specific).';
COMMENT ON COLUMN core.production_targets.vl_hour IS 'Target production quantity per hour.';
COMMENT ON COLUMN core.production_targets.vl_shift IS 'Target production quantity per shift.';
COMMENT ON COLUMN core.production_targets.vl_day IS 'Target production quantity per day.';
COMMENT ON COLUMN core.production_targets.vl_week IS 'Target production quantity per week.';
COMMENT ON COLUMN core.production_targets.vl_month IS 'Target production quantity per month.';

-- ============================================================ scrap_targets
COMMENT ON TABLE core.scrap_targets IS 'Scrap-QUANTITY/percentage targets by grain. Arbiter tuple is (id_equipment, id_site) (with id_area/id_enterprise), 0 = wildcard. vl_* = scrap target per period. Live writer (edge-api set-scrap-target) + reader. Distinct metric from production_targets and oee_targets.';
COMMENT ON COLUMN core.scrap_targets.id_equipment IS 'Equipment scope (0 = not equipment-specific). Part of the arbiter tuple with id_site.';
COMMENT ON COLUMN core.scrap_targets.id_site IS 'Site scope (0 = not site-specific). Part of the arbiter tuple with id_equipment.';
COMMENT ON COLUMN core.scrap_targets.vl_hour IS 'Scrap target per hour.';
COMMENT ON COLUMN core.scrap_targets.vl_shift IS 'Scrap target per shift.';
COMMENT ON COLUMN core.scrap_targets.vl_day IS 'Scrap target per day.';
COMMENT ON COLUMN core.scrap_targets.vl_week IS 'Scrap target per week.';
COMMENT ON COLUMN core.scrap_targets.vl_month IS 'Scrap target per month.';

-- ============================================================ oee_targets
COMMENT ON TABLE core.oee_targets IS 'OEE-PERCENT targets by grain (id_enterprise/id_site/id_area/id_equipment; 0 = wildcard). vl_* = target OEE (0..1 or %) per period. HALF-BUILT: read by serving.mission_control_area (target-vs-actual) but NO WRITER anywhere — the set-oee-target usecase (analog of set-scrap-target) was never built, so the target read is empty. Feature gap, not cruft.';
COMMENT ON COLUMN core.oee_targets.id_equipment IS 'Equipment scope (0 = not equipment-specific).';
COMMENT ON COLUMN core.oee_targets.id_site IS 'Site scope (0 = not site-specific).';
COMMENT ON COLUMN core.oee_targets.vl_shift IS 'Target OEE per shift.';
COMMENT ON COLUMN core.oee_targets.vl_day IS 'Target OEE per day.';
COMMENT ON COLUMN core.oee_targets.vl_week IS 'Target OEE per week.';
COMMENT ON COLUMN core.oee_targets.vl_month IS 'Target OEE per month.';

-- ============================================================ client_descriptors
COMMENT ON TABLE core.client_descriptors IS 'Per-client config-as-data (ADR-0045/0047): one row per tenant holding the authored onboarding descriptor JSONB + its lifecycle status. Owned/written by edge-api; read by sparkplug-decoder (tag-map cutover) and stream-engine report writers (descriptor->''reports''). NOTE: no FK to core.enterprises yet, and the sample reports rows (ent 6/13) are currently orphaned against live enterprise ids.';
COMMENT ON COLUMN core.client_descriptors.id_enterprise IS 'Tenant this descriptor configures. One row per enterprise (unique). No DB FK to core.enterprises today.';
COMMENT ON COLUMN core.client_descriptors.tenant_code IS 'Tenant short code (e.g. CPACK) — the device_key prefix / human tenant identifier.';
COMMENT ON COLUMN core.client_descriptors.descriptor IS 'JSONB: the authored config-as-data document (equipment/topics/reports/etc). descriptor->''reports'' drives the per-tenant report writers.';
COMMENT ON COLUMN core.client_descriptors.version IS 'Descriptor version counter (starts at 1).';
COMMENT ON COLUMN core.client_descriptors.status IS 'Onboarding lifecycle state: draft -> generated -> captured -> validated -> cutover (also error). ''captured'' = OBSERVE posture; ''cutover'' flips the tenant onto the register-driven (config-as-data) SparkPlug tag map (read at agent boot by sparkplug-decoder). A missing row / read error is treated as the SAFE static-map fallback.';
COMMENT ON COLUMN core.client_descriptors.artifacts IS 'JSONB: cached DERIVED outputs of the generate step (e.g. generated tag map). Reset to NULL when the descriptor is re-authored (returns to draft).';
COMMENT ON COLUMN core.client_descriptors.validation IS 'JSONB: cached validation-gate result. Reset to NULL on re-author.';
COMMENT ON COLUMN core.client_descriptors.created_by IS 'User/actor that created the descriptor.';
COMMENT ON COLUMN core.client_descriptors.updated_by IS 'User/actor of the last update.';

-- ============================================================ box_production_bridges
COMMENT ON TABLE core.box_production_bridges IS 'Config for the box->production bridge (stream-engine boxes_bridge.go, generalized from prod fn_update_packer_net_production_13). Each row: for one enterprise, bucket the SOURCE equipment''s box-scan net production and upsert it as the net_production of the TARGET child equipment (child = target_cd under parent source_cd). Removes prod''s hardcoded TL117/Packer ids.';
COMMENT ON COLUMN core.box_production_bridges.source_cd IS 'cd_equipment of the SOURCE (parent) equipment whose box scans are read.';
COMMENT ON COLUMN core.box_production_bridges.target_cd IS 'cd_equipment of the TARGET child equipment (under source_cd) that receives the bucketed net production.';
COMMENT ON COLUMN core.box_production_bridges.label_key IS 'Box-scan label slice to read from customer_reports.boxes (default Label_Neopac). Selects which label pool feeds the bridge.';
COMMENT ON COLUMN core.box_production_bridges.bucket IS 'time_bucket width for aggregating box scans (interval, default 1 min).';
COMMENT ON COLUMN core.box_production_bridges.lookback IS 'How far back (interval, default 5 min) each bridge run re-aggregates scans (now() - lookback).';

-- ============================================================ equipment_validation_shift
COMMENT ON TABLE core.equipment_validation_shift IS 'Per-shift production VALIDATION / supervisor-approval records (enterprise-06 workflow). Read by serving.data_sync / report_shift and exposed via read-api get-shift-validation. HALF-BUILT: 0 rows, no new-stack writer yet (rides the #244 enterprise-06 cutover). Column names index1/index2/shift_hrs are legacy/opaque — treat semantics as UNCONFIRMED.';
COMMENT ON COLUMN core.equipment_validation_shift.id_validation IS 'Surrogate PK.';
COMMENT ON COLUMN core.equipment_validation_shift.index1 IS 'Legacy opaque key (text; potentially numeric per external_integration.go coercion). Purpose UNCONFIRMED — likely a composite equipment/shift/date index. CONFIRM before use.';
COMMENT ON COLUMN core.equipment_validation_shift.index2 IS 'Legacy opaque JSONB key/payload. Purpose UNCONFIRMED.';
COMMENT ON COLUMN core.equipment_validation_shift.cd_equipment IS 'Equipment code (denormalized) the validation applies to.';
COMMENT ON COLUMN core.equipment_validation_shift.ts_value_production IS 'Production date (date) of the shift being validated.';
COMMENT ON COLUMN core.equipment_validation_shift.cd_shift IS 'Shift code being validated.';
COMMENT ON COLUMN core.equipment_validation_shift.shift_hrs IS 'Shift hours descriptor (text; may be numeric). UNCONFIRMED exact format.';
COMMENT ON COLUMN core.equipment_validation_shift.id_order IS 'Production order associated with the validated shift.';
COMMENT ON COLUMN core.equipment_validation_shift.txt_validation_notes IS 'JSONB: validation notes (JSONB key order is contract-relevant to get-shift-validation).';
COMMENT ON COLUMN core.equipment_validation_shift.validation IS 'Validation outcome flag (approved / not).';
COMMENT ON COLUMN core.equipment_validation_shift.ts_user_validation IS 'Timestamp the supervisor validated.';
COMMENT ON COLUMN core.equipment_validation_shift.nm_user_validation IS 'Name of the validating supervisor/user.';
COMMENT ON COLUMN core.equipment_validation_shift.ts_creation IS 'Row creation timestamp.';
COMMENT ON COLUMN core.equipment_validation_shift.to_delete IS 'Soft-delete/tombstone flag for the validation row.';
COMMENT ON COLUMN core.equipment_validation_shift.last_update IS 'Last update timestamp.';
COMMENT ON COLUMN core.equipment_validation_shift.shift_start_time IS 'Timestamp of the validated shift''s start.';
