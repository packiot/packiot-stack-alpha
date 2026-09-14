-- tRD-silver-bronze — headline SAFE win: give the magic-integer machine-state
-- codes (equipment_values.state / equipment_events.status) a readable, queryable
-- surface WITHOUT touching the raw integer columns or the ingest pipeline.
--
-- WHY the raw column stays an int:
--   The code is the verbatim PLC value carried on the SparkPlug `Status/StateCurrent`
--   metric (stream-engine writers/equipment_values.go BuildEventMint passes int(value)
--   straight through). It is an EXTERNAL standard the PLC emits — we cannot renumber it
--   in place without a producer + every-reader cutover (see docs/plans/silver-bronze-
--   column-redesign.md). So this migration is purely ADDITIVE and REVERSIBLE:
--     (a) a silver-local lookup table documenting the domain (single source of truth),
--     (b) two labeled VIEWs that LEFT JOIN it, exposing state_label + is_running/is_stopped,
--     (c) enriched COMMENTs on the raw columns.
--
-- SEMANTICS are grounded in the OEE engine, NOT invented:
--   services/stream-engine/internal/rollup/compute.go:19
--     "running = status 6; stopped = status IN (5,10,11)."
--   compute.go/hour.go/shift.go all credit running_time only from status=6 and
--   stopped_time from status IN (5,10,11). The engine does NOT distinguish 5 vs 10 vs 11
--   any finer than "stopped", so neither do we — is_running / is_stopped mirror the
--   engine exactly; `note` records the raw-code provenance.
--   Live staging distincts (2026-09-13):
--     equipment_values.state : 6=5,741,923  10=115,015  5=37,634  NULL=4,323,064
--     equipment_events.status: 6=198,771     10=196,719  (only 6/10 present)

BEGIN;

------------------------------------------------------------------------------
-- (a) Domain lookup — single source of truth for the PLC state codes.
------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS silver.machine_state (
    state       integer PRIMARY KEY,
    label       text    NOT NULL,
    is_running  boolean NOT NULL,
    is_stopped  boolean NOT NULL,
    note        text
);

COMMENT ON TABLE silver.machine_state IS
'Reference/lookup for the PLC-emitted PackML machine-state codes stored as magic integers in silver.equipment_values.state and silver.equipment_events.status. Authoritative classification comes from the OEE engine (stream-engine internal/rollup/compute.go: running = 6; stopped = 5,10,11). Additive documentation surface — the raw int columns are unchanged. Add a row here (not a code change) when a new PLC state code appears.';

INSERT INTO silver.machine_state (state, label, is_running, is_stopped, note) VALUES
    (6,  'running', true,  false, 'Machine executing/producing. rollup/compute.go credits running_time only from status=6.'),
    (10, 'stopped', false, true,  'Canonical STOPPED code (documented across the schema comments). Member of the engine stopped set status IN (5,10,11).'),
    (5,  'stopped', false, true,  'Stopped variant emitted by the PLC. Engine treats it identically to 10 (stopped set); no finer semantics are distinguished by the OEE math. Present in equipment_values on staging.'),
    (11, 'stopped', false, true,  'Stopped variant recognised by rollup/compute.go stopped set status IN (5,10,11). Not observed in live staging data but handled for completeness.')
ON CONFLICT (state) DO NOTHING;

------------------------------------------------------------------------------
-- (b) Labeled views — readable surface for consumers, zero pipeline change.
--     LEFT JOIN so an unmapped/NULL code stays visible (label NULL) rather than
--     being silently dropped.
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW silver.equipment_events_labeled AS
SELECT e.*,
       ms.label      AS status_label,
       ms.is_running,
       ms.is_stopped
FROM silver.equipment_events e
LEFT JOIN silver.machine_state ms ON ms.state = e.status;

COMMENT ON VIEW silver.equipment_events_labeled IS
'Readable projection of silver.equipment_events: adds status_label / is_running / is_stopped by joining silver.machine_state on status. Additive; the raw status int is unchanged. NULL status_label = a code not (yet) in silver.machine_state.';

CREATE OR REPLACE VIEW silver.equipment_values_labeled AS
SELECT v.*,
       ms.label      AS state_label,
       ms.is_running,
       ms.is_stopped
FROM silver.equipment_values v
LEFT JOIN silver.machine_state ms ON ms.state = v.state;

COMMENT ON VIEW silver.equipment_values_labeled IS
'Readable projection of silver.equipment_values: adds state_label / is_running / is_stopped by joining silver.machine_state on state. Additive; the raw state int is unchanged. NULL state_label = code not in silver.machine_state (or NULL state — counters-only sample with no state signal, cf. #209 CPACK).';

------------------------------------------------------------------------------
-- (c) Enrich the raw-column COMMENTs to point at the domain + the labeled view.
------------------------------------------------------------------------------
COMMENT ON COLUMN silver.equipment_values.state IS
'PackML machine state as the verbatim PLC SparkPlug Status/StateCurrent code (magic int). Domain: 6=running; 5,10,11=stopped (OEE engine: rollup/compute.go). Live staging distinct: 6,10,5,NULL. Readable surface: silver.machine_state lookup + silver.equipment_values_labeled (state_label/is_running/is_stopped). NULL = counters-only sample with no state signal (see #209 CPACK). Do NOT renumber in place — external PLC value; see docs/plans/silver-bronze-column-redesign.md for the normalization cutover.';

COMMENT ON COLUMN silver.equipment_events.status IS
'Machine/event status as the verbatim PLC state code (magic int). Domain: 6=running; 5,10,11=stopped (OEE engine: rollup/compute.go credits running_time from status=6, stopped_time from status IN (5,10,11)). Live staging distinct: 6,10. Readable surface: silver.machine_state lookup + silver.equipment_events_labeled. Naming note: this column is the same domain as equipment_values.state but named "status" (unification is a proposed cutover). Do NOT renumber in place.';

-- sibling event tables share the same status domain
COMMENT ON COLUMN silver.equipment_events_cpac_shadow.status IS
'Derived machine/event status as PLC state code (magic int). Domain: 6=running; 5,10,11=stopped (OEE engine: rollup/compute.go). Join silver.machine_state for labels.';
COMMENT ON COLUMN silver.equipment_events_man.status IS
'Machine/event status as PLC state code (magic int). Domain: 6=running; 5,10,11=stopped (OEE engine: rollup/compute.go). Join silver.machine_state for labels. Live staging: all NULL (manual events carry downtime codes, not a state).';
COMMENT ON COLUMN silver.equipment_events_low_speed.status IS
'Machine/event status as PLC state code (magic int). Domain: 6=running; 5,10,11=stopped (OEE engine: rollup/compute.go). Join silver.machine_state for labels.';
COMMENT ON COLUMN bronze.equipment_events_raw.status IS
'Machine/event status as the verbatim PLC state code (magic int) at ts_event. Domain: 6=running; 5,10,11=stopped (OEE engine: rollup/compute.go). Bronze is the immutable append-only raw layer (flag-gated, dormant).';
COMMENT ON COLUMN bronze.equipment_values_raw.state IS
'PackML machine state as the verbatim PLC Status/StateCurrent code (magic int). Domain: 6=running; 5,10,11=stopped (OEE engine: rollup/compute.go). Bronze is the immutable append-only raw layer (flag-gated, dormant).';

-- Fix a misleading comment surfaced during the review: data_quality_event.severity
-- comment claimed "info, warn, critical" but live data is only {error, warn}.
COMMENT ON COLUMN silver.data_quality_event.severity IS
'Severity level. Live staging domain: error (26,078) and warn (132) — earlier comment example values (info/critical) do not occur; error is the dominant level, not "critical".';

COMMIT;
