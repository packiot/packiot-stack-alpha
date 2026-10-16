// cpac_deriver.go — ADR-0010 §10.4 GAP-1: the CPAC (status_type=0) stop
// derivation that the Go stack was missing. Built DARK (flag-gated,
// CPAC_EVENT_DERIVATION_ENABLED, default OFF). Deploying it is behavior-
// identical until the flag flips: it is a WHOLE NEW job that writes a WHOLE
// NEW table (the shadow comparison table, default equipment_events_cpac_shadow),
// so the flag-off executed-statement stream is byte-unchanged and the
// status_type=4 deriver (deriver.go) is completely untouched — this is a
// PARALLEL path, not a widening of the 4-only gates.
//
// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
// C-PACK equipment is status_type=0. On prod its downtime events are created
// by the factory CPAC algorithm (SparkPlug 30758=4) and reach staging via the
// mirror-worker FanoutEventRow. The Go stack itself has NO stop-detector for
// status_type=0 — the deriver.go path SERVES status_type=4 ONLY (it islands on
// state-VALUE transitions in ca_discrete_changes_1s). Flipping CPACK 0→4 is
// UNSAFE: the Go Calc engine emits a RUNNING-ONLY heartbeat (calc.go Phase 10
// only ever sets status=6; it never emits a stopped value), so islanding on
// state values yields zero stops. This job ADDS the missing detector, scoped
// to status_type=0, leaving status_type alone.
//
// ── INPUT: COUNT-ACTIVITY SILENCE, NOT STATE (empirical, 2026-08-04) ─────────
// STEP-1 sampling of live staging CPACK (enterprise 3):
//   - public.equipment_values.state is 100% NULL for the LIVE edge path (the
//     agent → edge-transformer path writes counts only; the Calc status=6
//     heartbeat never lands as a `state` value). State values (6/10) exist in
//     equipment_values ONLY in the mirror-fed shadow flow (FanoutStateRow),
//     which is prod's OWN derived state — islanding over it would be circular
//     (re-deriving prod's output) and evaporates the day the prod cord is cut.
//   - The ONE independent live signal is the COUNT stream (gross_production_incr
//     > 0), cadence p50 ~60s / p95 ~90–460s per equipment.
// So the CPAC "heartbeat" here is a PRODUCTIVE MINUTE. Silence longer than the
// equipment's stop threshold ⇒ a STOPPED interval. This is the same idle-timeout
// sessionization the counters-only availability fallback already uses
// (rollup/availability.go), lifted up to MINT equipment_events instead of
// computing running_time — so the two OEE paths share one inference model.
//
// ── THRESHOLD ───────────────────────────────────────────────────────────────
// Per-equipment horizon = equipments.stop_threshold_time (legacy SparkPlug
// Parameter 30751 "min-threshold-time"; the same column sap13_body.sql uses to
// split real stops (≥ threshold) from microstops (< threshold)). On staging
// this column is NULL for all 62 CPACK rows, so the derivation falls back to
// CPAC_STOP_THRESHOLD_DEFAULT_SEC. The default IS the tuning knob the comparator
// gates: too tight (e.g. 300s) over-detects — normal count-cadence gaps read as
// stops (dry-run: 181 derived stops vs prod's 64 in a 25h window). Enablement is
// gated on the comparator (cpac_deriver_comparator.sql) reaching acceptable
// convergence, at which point per-equipment stop_threshold_time should be
// populated rather than leaning on the single default.
//
// ── EVENT SHAPE ─────────────────────────────────────────────────────────────
// A "session" = a maximal run of productive minutes whose inter-minute gap never
// exceeds the threshold. RUNNING (status 6) transition at the session's first
// count; STOPPED (status 10) transition at (session's last count + threshold) —
// the grace we grant before declaring the machine down (identical to
// availability.go's session credit). The transitions are then chained
// (lead(ts_event) → ts_end, duration = epoch diff; open tail row → ts_end NULL,
// duration to now()), reproducing prod's alternating 6/10 interval stream. This
// matches prod's stream SHAPE; exact ts_end boundaries diverge within the
// documented convergence tolerance (count-silence cannot see sub-cadence stops
// the PLC state signal catches — that is the known limitation the comparator
// quantifies). status 6/10 are prod's literal codes (mirrored ground truth).
//
// ── IDEMPOTENT + NEVER CLOBBER A HUMAN EDIT (the load-bearing invariant) ─────
// The detector AUTO-INSERTS events that operators later MODIFY (justify a
// reason, adjust ts, split) via edge-api → pocontrol events_justify.go (30810
// justify sets cd_category/txt_downtime_notes/…; 30813/30814 trims set
// forced_creation_system=true). Re-derivation MUST:
//   - be idempotent: the upsert keys on (id_equipment, ts_event) and re-writes
//     identical values, so a replay of the same minutes changes nothing;
//   - never overwrite a human-touched row: the ON CONFLICT DO UPDATE carries a
//     WHERE that excludes any row a human has touched (humanTouchedPred);
//   - never delete a human-touched row: the correct/delete pass carries the same
//     guard (so the classic forced_creation_system guard is STRICTLY widened,
//     never narrowed);
//   - append ONLY in un-covered time: a freshly derived transition whose
//     ts_event falls inside a human-protected event's [ts_event, ts_end] span is
//     dropped from the upsert (NOT EXISTS humancover), AND any non-human derived
//     row minted BEFORE the human took the region is swept by the correct pass —
//     so a split/edited region ends up owned entirely by the operator, never
//     re-minted over and never left double-covered.
package events

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/jobs"
)

// CPACConfig carries the flag-gated knobs for the CPAC stop derivation. The
// zero value is inert: with no Enterprises the job mints nothing even when the
// caller (main.go) has already gated on Enabled.
type CPACConfig struct {
	Enterprises     []int  // status_type=0 enterprise ids to derive (CPACK=3); empty ⇒ no-op
	ThresholdDefSec int    // fallback when equipments.stop_threshold_time IS NULL/0
	TargetTable     string // shadow comparison table in EvSchema; default equipment_events_cpac_shadow
	// LeadActivity widens the productive-minute signal FOR A LINE'S LEAD MACHINE
	// ONLY (lines with downtime_from_lead_machine) from gross-only to the
	// line-lead OEE model's rule: gross OR net OR scrap moved (a missing gross
	// meter is filled by identity, gross = net). Every other member keeps the
	// gross-only rule. false ⇒ the executed SQL is byte-identical to before
	// (pinned by TestCPACGrossOnlySQLByteIdentical). Set only on the LIVE
	// counters-only instance (CPAC_EVENT_LIVE_ENTERPRISES); the CPACK shadow
	// instance leaves it false.
	LeadActivity bool
	// LinkHealth makes the derivation PLC-link aware (2026-10-01, availability
	// three-state policy). Silence while the reader could NOT read the PLC
	// (silver.plc_link_minutes: no ok scan in the minute, or no report at all
	// once the endpoint has reported once) is NO DATA, not a stop: the stop the
	// count-silence rule would mint inside such a gap is suppressed and a
	// status-20 (no data) transition opens at the gap's first minute; when data
	// resumes without production a stop opens at the resume minute (connected
	// but silent IS a stop). Gaps shorter than the stop threshold are ignored.
	// false ⇒ byte-identical SQL (the CPACK shadow instance).
	LinkHealth bool
}

// NoDataStatus is the equipment_events status for a span with no PLC data
// (silver.machine_state 20). Neither running (6) nor stopped (5/10/11).
const NoDataStatus = 20

// cpacGrossActivity is the original productive-minute predicate: the member's
// own consumed (gross) counter moved.
const cpacGrossActivity = `m.gross_production_incr > 0`

// cpacLeadsCTE (%[1]s = RefSchema) names every line's lead_machine for lines
// whose downtime is attributed from the lead (downtime_from_lead_machine) —
// the member bi.downtimes' line branch and the line-lead availability read.
const cpacLeadsCTE = `), leads AS (
    SELECT DISTINCT ln.lead_machine AS id_equipment
      FROM %[1]s.equipments ln
     WHERE ln.tp_equipment = 3
       AND ln.downtime_from_lead_machine
       AND COALESCE(ln.lead_machine, 0) > 0
       AND ln.id_enterprise = ANY($1)
`

// cpacLeadActivity is the line-lead OEE model's productive minute (line_lead.go
// prod_raw: gross OR net OR scrap > 0) applied to lead machines only. A lead
// that carries ONLY a net/output counter (Bispharma L18 TAMPADEIRA, the BISNAGO
// M67x/M68x leads, L90 S2OUTPUT) was invisible to the gross-only rule, so those
// lines got zero downtime events while their Availability (line-lead) was real.
const cpacLeadActivity = `(m.gross_production_incr > 0
            OR (s.id_equipment IN (SELECT id_equipment FROM leads)
                AND (m.net_production_incr > 0 OR m.scrap_incr > 0)))`

// cpacLinkCTE (%[5]s = SilverSchema) — the PLC-link
// no-data islands per scoped equipment. Appended after scope (like cpacLeadsCTE),
// it only reads tables the link-health migration created. An endpoint that has
// never reported a link status contributes nothing (pre-rollout history and
// tenants without a link-reporting reader are untouched).
const cpacLinkCTE = `), linkeq AS (
    -- each scoped equipment's reader endpoint — ONLY equipment the descriptor
    -- maps to a PLC directly. A line must NOT inherit its lead's endpoint: a line
    -- without counters of its own has no sessions, so every gap would end in a
    -- "stop" that never closes (the phantom-stop class this mode removes).
    --
    -- OBSERVABLE equipment only (fix 2026-10-09, S2_stale_open_stops): the same rule
    -- applies to a MACHINE whose counter the productive-minute predicate never sees —
    -- Bispharma's net-only, non-lead machines (gross never moves; the net/scrap
    -- widening is for leads only). They have no sessions either, so every link gap
    -- minted NO DATA + a resume STOP that no RUNNING transition could ever follow:
    -- 18 ent-5 machines sat in an open stop from 10-01/10-04/10-07 while producing.
    -- An equipment is observable when the predicate saw it produce in the last
    -- 7 days (LATERAL + LIMIT 1: one index probe per member on the real-time cagg).
    SELECT s.id_equipment, s.id_enterprise, s.thr, pe.endpoint
      FROM scope s
      JOIN %[5]s.plc_endpoint_equipment pe
        ON pe.id_enterprise = s.id_enterprise AND pe.id_equipment = s.id_equipment
     CROSS JOIN LATERAL (SELECT 1 FROM %[5]s.equipment_categorical_1min m
                          WHERE m.id_equipment = s.id_equipment
                            AND m.ts_value > now() - interval '7 days'
                            AND %[7]s
                          LIMIT 1) observable
), link_ep AS (
    SELECT DISTINCT le.id_enterprise, le.endpoint, f.since
      FROM linkeq le
     CROSS JOIN LATERAL (SELECT min(pl.ts_minute) AS since FROM %[5]s.plc_link_minutes pl
                          WHERE pl.id_enterprise = le.id_enterprise AND pl.endpoint = le.endpoint) f
     WHERE f.since IS NOT NULL
), link_active AS (
    -- minutes in which data DID arrive from the endpoint (any member's counter
    -- row) are never no-data, even if the link recorder missed them. Per-member
    -- LATERAL + OFFSET 0: the 1min cagg is real-time (the #259 lesson).
    SELECT DISTINCT pe.id_enterprise, pe.endpoint, a.ts_value AS minute
      FROM link_ep le
      JOIN %[5]s.plc_endpoint_equipment pe ON pe.id_enterprise = le.id_enterprise AND pe.endpoint = le.endpoint
     CROSS JOIN LATERAL (SELECT m.ts_value FROM %[5]s.equipment_categorical_1min m
                          WHERE m.id_equipment = pe.id_equipment
                            AND m.ts_value > now() - interval '27 hours' OFFSET 0) a
), nodata_min AS (
    -- the last 2 minutes stay undecided (the agent flushes link rows every 15 s)
    SELECT le.id_enterprise, le.endpoint, g.minute
      FROM link_ep le
     CROSS JOIN LATERAL generate_series(
               date_trunc('minute', greatest(le.since, now() - interval '27 hours')),
               date_trunc('minute', now()) - interval '3 minutes', interval '1 minute') AS g(minute)
     WHERE NOT EXISTS (SELECT 1 FROM %[5]s.plc_link_minutes pl
                        WHERE pl.id_enterprise = le.id_enterprise AND pl.endpoint = le.endpoint
                          AND pl.ts_minute = g.minute AND pl.ok_ticks > 0)
       AND NOT EXISTS (SELECT 1 FROM link_active a
                        WHERE a.id_enterprise = le.id_enterprise AND a.endpoint = le.endpoint
                          AND a.minute = g.minute)
), nodata_isl AS (
    SELECT id_enterprise, endpoint, min(minute) AS nd_start, max(minute) + interval '1 minute' AS nd_last
      FROM (SELECT id_enterprise, endpoint, minute,
                   minute - make_interval(mins => (row_number() OVER (
                       PARTITION BY id_enterprise, endpoint ORDER BY minute))::int) AS grp
              FROM nodata_min) z
     GROUP BY id_enterprise, endpoint, grp
), nodata AS (
    -- islands at least the stop threshold long (a short link blip is neither a
    -- stop nor a gap); one reaching the undecided edge is ONGOING (nd_end NULL)
    SELECT le.id_equipment, le.id_enterprise, le.thr, i.nd_start,
           CASE WHEN i.nd_last >= date_trunc('minute', now()) - interval '2 minutes'
                THEN NULL ELSE i.nd_last END AS nd_end
      FROM nodata_isl i
      JOIN linkeq le ON le.id_enterprise = i.id_enterprise AND le.endpoint = i.endpoint
     WHERE i.nd_last - i.nd_start >= make_interval(secs => le.thr)
`

// cpacLinkStopGuard (appended to the STOPPED arm's WHERE): a count-silence stop
// that would begin inside a no-data island is not a stop — the island's
// status-20 transition covers it.
const cpacLinkStopGuard = `
       AND NOT EXISTS (SELECT 1 FROM nodata n
                        WHERE n.id_equipment = sessions.id_equipment
                          AND sessions.run_last + make_interval(secs => sessions.thr) >= n.nd_start
                          AND (n.nd_end IS NULL
                               OR sessions.run_last + make_interval(secs => sessions.thr) < n.nd_end))`

// cpacLinkArms — the extra transition arms: NO DATA at each island's start, and
// STOPPED at its end when production does not restart within the grace.
const cpacLinkArms = `    UNION ALL
    SELECT id_equipment, id_enterprise, nd_start, 20 FROM nodata
    UNION ALL
    SELECT n.id_equipment, n.id_enterprise, n.nd_end, 10 FROM nodata n
     WHERE n.nd_end IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sessions s
                        WHERE s.id_equipment = n.id_equipment
                          AND s.run_start >= n.nd_start
                          AND s.run_start <= n.nd_end + make_interval(secs => n.thr))
`

// DefaultCPACTargetTable is the DARK-mode shadow table the derivation writes to
// so the live equipment_events (owned by the mirror fan-out for CPACK, and by
// operators) is never touched and the comparator has a clean two-table diff.
const DefaultCPACTargetTable = "equipment_events_cpac_shadow"

// humanTouchedPred is the SQL predicate (over an aliased equipment_events row
// `%[4]s`) that is TRUE once an operator has touched the row via edge-api
// (pocontrol events_justify.go). Any one of: a trim/manual system-lock
// (forced_creation_system), a justification (cd_category / cd_subcategory /
// cd_machine / txt_downtime_notes), or a classification toggle
// (planned_downtime / change_over / idle). Referenced by BOTH the upsert guard
// and the delete guard so the detector can only ADD in untouched time.
//
// NULL-SAFE (fix 2026-09-29): forced_creation_system / planned_downtime /
// change_over are nullable with NO default, and the deriver's own INSERT leaves
// planned_downtime/change_over NULL. The old bare `OR ev.planned_downtime` made
// the predicate NULL for EVERY derived row, so `NOT (...)` was NULL: the correct
// pass never deleted a row and the DO UPDATE never refreshed one (the deriver
// was append-only; staging: corrected=0 on every tick). `IS TRUE` collapses the
// three-valued logic, the same fix closer.go's humanJustifiedPred already carries.
const humanTouchedPred = `(%[4]s.forced_creation_system IS TRUE
        OR %[4]s.cd_category IS NOT NULL OR %[4]s.cd_subcategory IS NOT NULL
        OR %[4]s.cd_machine IS NOT NULL OR %[4]s.txt_downtime_notes IS NOT NULL
        OR %[4]s.planned_downtime IS TRUE OR %[4]s.change_over IS TRUE OR %[4]s.idle IS NOT NULL)`

// cpacTransitionsCTE recomputes the alternating running/stopped transition
// stream from count-activity sessionization over the last 25 hours.
// %[1]s = EvSchema (flow tables), %[2]s = RefSchema (equipments/packml).
// %[6]s = optional extra CTE (the `leads` set; "" in gross-only mode), %[7]s =
// the productive-minute predicate (see cpacGrossActivity / cpacLeadActivity).
// $1 = enterprise-id int[] scope, $2 = default threshold seconds.
const cpacTransitionsCTE = `
WITH scope AS (
    SELECT e.id_equipment, e.id_enterprise,
           COALESCE(NULLIF(e.stop_threshold_time, 0), $2) AS thr
      FROM %[2]s.equipments e
     WHERE e.status_type = 0
       AND e.tp_equipment IN (1, 3)
       AND e.id_enterprise = ANY($1)
%[6]s%[8]s), counts AS (
    SELECT s.id_equipment, s.id_enterprise, s.thr, m.ts_value AS ts,
           extract(epoch FROM (m.ts_value - lag(m.ts_value)
               OVER (PARTITION BY s.id_equipment ORDER BY m.ts_value))) AS gap
      FROM scope s
      JOIN %[5]s.equipment_categorical_1min m
        ON m.id_equipment = s.id_equipment
       -- LOOK-BACK (fix 2026-09-29): read thr + 60s BEFORE the 25h window so the
       -- first in-window minute gets its real gap. Without it that minute always
       -- had gap NULL => a session start => a phantom RUNNING row at the window's
       -- trailing edge on EVERY tick (~1 per productive minute per equipment,
       -- never cleaned: it is older than the 1-day correct pass). Transitions
       -- that fall in the look-back are still dropped by final's window filter.
       -- Any prior minute within thr of an in-window minute is inside the
       -- look-back, so an in-window gap > thr (a real stop) still opens a session.
       AND m.ts_value > now() - interval '25 hours' - make_interval(secs => s.thr + 60)
       -- constant bound for chunk exclusion (thresholds are minutes, never ~a day)
       AND m.ts_value > now() - interval '2 days'
       AND %[7]s
), marked AS (
    SELECT id_equipment, id_enterprise, thr, ts,
           sum(CASE WHEN gap IS NULL OR gap > thr THEN 1 ELSE 0 END)
               OVER (PARTITION BY id_equipment ORDER BY ts) AS sess
      FROM counts
), sessions AS (
    SELECT id_equipment, id_enterprise, thr, sess,
           min(ts) AS run_start, max(ts) AS run_last
      FROM marked
     GROUP BY id_equipment, id_enterprise, thr, sess
), transitions AS (
    -- RUNNING transition at the session's first productive minute
    SELECT id_equipment, id_enterprise, run_start AS ts_event, 6 AS status
      FROM sessions
    UNION ALL
    -- STOPPED transition at (last productive minute + grace threshold); only
    -- once the grace has actually elapsed (a stop has genuinely begun)
    SELECT id_equipment, id_enterprise,
           run_last + make_interval(secs => thr) AS ts_event, 10 AS status
      FROM sessions
     WHERE run_last + make_interval(secs => thr) < now()%[9]s
%[10]s), final AS (
    SELECT ts_event,
           lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event) AS ts_end,
           id_equipment, status, id_enterprise,
           extract(epoch FROM (coalesce(
               lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event),
               now()) - ts_event)) AS duration
      FROM transitions
     -- warmup: skip the window's first 10s (matches deriver.go's time guard on
     -- sparse streams; a row-count warmup is wrong here too)
     WHERE ts_event >= now() - interval '25 hours' + interval '10 seconds'
)`

// cpacUpsertSQL mints/refreshes the derived transitions into the shadow table.
// %[3]s = target table (aliased `ev` = %[4]s below). IDEMPOTENT on
// (id_equipment, ts_event). The DO UPDATE WHERE and the NOT EXISTS both enforce
// the never-clobber-a-human-edit invariant.
const cpacUpsertSQL = cpacTransitionsCTE + cpacUpsertApply

// cpacUpsertApply is the DML half of cpacUpsertSQL: everything after the CTE.
// RunOnceCPAC runs it behind cpacSnapshotFinal (the same `final` rows, read by
// cpacReadSQL in the same transaction) so the INSERT never plans the cagg read.
const cpacUpsertApply = `
INSERT INTO %[1]s.%[3]s AS ev
       (ts_event, ts_end, id_equipment, status, id_enterprise, duration, forced_creation_system)
SELECT f.ts_event, f.ts_end, f.id_equipment, f.status, f.id_enterprise, f.duration, false
  FROM final f
 -- append ONLY in un-covered time: never re-mint over a human-protected span
 WHERE NOT EXISTS (
        SELECT 1 FROM %[1]s.%[3]s h
         WHERE h.id_equipment = f.id_equipment
           AND ` + humanCoverPred + `
           -- chunk-exclusion bound: without a lower bound on h.ts_event every probe
           -- scanned the tenant's whole event history (live ent5: 4.2 s → 0.4 s per
           -- tick, same rows). 60 d = the stale-event closer's long horizon: nothing
           -- older can still be open and cover the 25 h window.
           AND h.ts_event >= now() - interval '60 days'
           AND f.ts_event >= h.ts_event
           AND f.ts_event < COALESCE(h.ts_end, now()))
ON CONFLICT (id_equipment, ts_event) DO UPDATE
   SET ts_end = EXCLUDED.ts_end, status = EXCLUDED.status, duration = EXCLUDED.duration
 WHERE NOT ` + humanTouchedPred + cpacNoopGuard

// cpacNoopGuard (appended to the DO UPDATE WHERE) skips a conflict row whose
// values already equal the derived ones, over exactly the columns the SET writes.
//
// WHY (2026-10-14, staging): every tick re-derives the whole 25 h window, so the
// upsert hit ~400–600 conflict rows per tick and rewrote each one although only
// the open tail had changed. Postgres writes a new row version for every UPDATE,
// changed or not: silver.equipment_events_cpac_shadow reached 8.6 M updates and a
// 92 MB heap for 27 k live rows. Neither table has a trigger and nothing keys on
// row versions (no last_update/ingested_at write here, no publication), so a
// skipped no-op changes no result; it only stops the WAL, dead tuples and
// vacuum work. The open tail row still updates every tick: its duration runs to
// now(). RowsAffected now counts real inserts and changes only.
// IS DISTINCT FROM, not <>: ts_end is NULL on the open tail.
const cpacNoopGuard = `
   AND (%[4]s.ts_end, %[4]s.status, %[4]s.duration)
       IS DISTINCT FROM (EXCLUDED.ts_end, EXCLUDED.status, EXCLUDED.duration)`

// humanCoverPred (aliased `h` = %[4]s at format time) — a human-protected event
// used by the append-only NOT EXISTS. Same touched-columns as humanTouchedPred.
// NULL-safe for the same reason as humanTouchedPred (inside EXISTS a NULL
// already acted as false, so this one is a clarity change, not a behaviour one).
const humanCoverPred = `(h.forced_creation_system IS TRUE
        OR h.cd_category IS NOT NULL OR h.cd_subcategory IS NOT NULL
        OR h.cd_machine IS NOT NULL OR h.txt_downtime_notes IS NOT NULL
        OR h.planned_downtime IS TRUE OR h.change_over IS TRUE OR h.idle IS NOT NULL)`

// cpacCorrectSQL removes stale DERIVED rows (last 1 day) that the recomputed
// stream no longer supports — but NEVER a human-touched row (the guard is a
// STRICT widening of deriver.go's forced_creation_system-only guard).
const cpacCorrectSQL = cpacTransitionsCTE + cpacCorrectApply

// cpacCorrectApply is the DML half of cpacCorrectSQL (see cpacUpsertApply).
const cpacCorrectApply = `
DELETE FROM %[1]s.%[3]s ev
 WHERE ev.ts_event > now() - interval '1 day'
   AND ev.id_enterprise = ANY($1)
   AND NOT ` + humanTouchedPred + `
   AND (
     -- (a) stale: the recomputed stream no longer supports this derived row
     NOT EXISTS (SELECT 1 FROM final t
        WHERE t.id_equipment = ev.id_equipment
          AND t.ts_event = ev.ts_event AND t.status = ev.status)
     -- (b) superseded: a human later took ownership of a span this derived row
     -- falls inside (a manual-create/split at a different ts_event). Removing a
     -- NON-human row that a human span now covers is not clobbering an edit — it
     -- yields the region to the operator's version, completing "append only in
     -- un-covered time" for rows minted before the human touched the region.
     OR EXISTS (SELECT 1 FROM %[1]s.%[3]s h
        WHERE h.id_equipment = ev.id_equipment
          AND h.ts_event <> ev.ts_event
          AND ` + humanCoverPred + `
          AND h.ts_event >= now() - interval '60 days'
          AND ev.ts_event >= h.ts_event
          AND ev.ts_event < COALESCE(h.ts_end, now()))
   )`

// cpacCloseApply closes the open row the window left behind. It runs after the
// upsert, against the same snapshot.
//
// WHY (2026-10-14, staging): `final` chains ts_end = lead(ts_event) only INSIDE
// the 25 h window. A stop (or run) that lasts longer than the window leaves it
// while still open, which is correct while it lasts. But when the machine
// changes state again, the new transition is in the window and the old row is
// not, so no pass ever set its ts_end: 73 CPACK shadow stops since 09-29 stayed
// open although a RUNNING row follows each one 1 to 13 days later. (The 11.9 k
// older open rows are the NULL-unsafe-guard era before #1486, when DO UPDATE
// never ran; scripts/ops/repair-cpac-shadow-stale-open.sql closes those once.)
//
// Per equipment in the snapshot: the newest row BEFORE the window, if it is
// still open and a later row now exists, ends where that row begins (the same
// rule as lead() inside the window and as closer.go's non-latest close).
// Bounded: one backward index probe per equipment, and the successor is looked
// up inside the window only (the newest pre-window row's successor can only be
// there). The candidates are a MATERIALIZED CTE and the UPDATE joins them by key:
// on the live ent-5 hypertable a plain UPDATE … FROM planned a hash join over
// every 60-day chunk (614 ms planning, seq scans); this shape plans in 156 ms
// and, with no candidate (nearly every tick), never touches a chunk. A
// human-touched row is never changed; a row with no successor stays open (the
// machine is still in that state).
const cpacCloseApply = `
, cand AS MATERIALIZED (
    SELECT s.id_equipment, pv.ts_event, nx.ts_next
      FROM (SELECT DISTINCT f.id_equipment FROM final f) s
     CROSS JOIN LATERAL (
           SELECT p.ts_event, p.ts_end FROM %[1]s.%[3]s p
            WHERE p.id_equipment = s.id_equipment
              AND p.ts_event < now() - interval '25 hours' + interval '10 seconds'
              AND p.ts_event >= now() - interval '60 days'
            ORDER BY p.ts_event DESC LIMIT 1) pv
     CROSS JOIN LATERAL (
           SELECT min(n.ts_event) AS ts_next FROM %[1]s.%[3]s n
            WHERE n.id_equipment = s.id_equipment
              AND n.ts_event >= now() - interval '25 hours' + interval '10 seconds') nx
     WHERE pv.ts_end IS NULL
       AND nx.ts_next IS NOT NULL
)
UPDATE %[1]s.%[3]s ev
   SET ts_end = c.ts_next,
       duration = extract(epoch FROM (c.ts_next - ev.ts_event))::int
  FROM cand c
 WHERE ev.id_equipment = c.id_equipment
   AND ev.ts_event = c.ts_event
   AND ev.ts_event >= now() - interval '60 days'
   AND ev.ts_end IS NULL
   AND NOT ` + humanTouchedPred

// fmtCPAC formats a CPAC SQL template with the positional args the templates
// use: %[1]s EvSchema (the DARK shadow table's home + ca_discrete residue),
// %[2]s RefSchema, %[3]s target shadow table, %[4]s the aliased existing-row
// prefix ("ev" for the upsert/delete guards; "h" is baked into humanCoverPred),
// %[5]s SilverSchema (the categorical cagg's home — #248 de-shim; the shadow
// table itself stays on %[1]s ev).
func fmtCPAC(tmpl, evSchema, refSchema, table, rowAlias, silverSchema string) string {
	return fmtCPACMode(tmpl, evSchema, refSchema, table, rowAlias, silverSchema, false)
}

// fmtCPACMode is fmtCPAC plus the activity mode: %[6]s = the leads CTE (or ""),
// %[7]s = the productive-minute predicate. leadActivity=false renders the exact
// pre-LeadActivity statement.
func fmtCPACMode(tmpl, evSchema, refSchema, table, rowAlias, silverSchema string, leadActivity bool) string {
	return fmtCPACFull(tmpl, evSchema, refSchema, table, rowAlias, silverSchema, leadActivity, false)
}

// fmtCPACFull adds the PLC-link mode: %[8]s = the link CTEs, %[9]s = the stop
// guard, %[10]s = the extra transition arms. linkHealth=false renders all three
// empty ⇒ the exact pre-LinkHealth statement.
func fmtCPACFull(tmpl, evSchema, refSchema, table, rowAlias, silverSchema string, leadActivity, linkHealth bool) string {
	leads, act := "", cpacGrossActivity
	if leadActivity {
		leads, act = fmt.Sprintf(cpacLeadsCTE, refSchema), cpacLeadActivity
	}
	link, guard, arms := "", "", ""
	if linkHealth {
		link = strings.NewReplacer("%[2]s", refSchema, "%[5]s", silverSchema, "%[7]s", act).Replace(cpacLinkCTE)
		guard, arms = cpacLinkStopGuard, cpacLinkArms
	}
	return fmt.Sprintf(tmpl, evSchema, refSchema, table, rowAlias, silverSchema, leads, act, link, guard, arms)
}

// cpacReadSQL is the derivation as a plain SELECT: the transition stream
// (`final`) serialized as one jsonb array. It is the ONLY statement that reads
// the real-time categorical cagg.
//
// WHY A SEPARATE SELECT (2026-10-14, staging): TimescaleDB constifies a real-time
// cagg's watermark only when planning a SELECT. Inside INSERT/DELETE the
// watermark stays a runtime cagg_watermark() call, so the planner prices the
// raw-tail branch at every equipment_values chunk (239–457 M rows instead of
// ~1 k). Under such absurd estimates, a small change in the scope estimate (RLS on
// core.equipments when the job moved to the stream_engine role, #1743) flipped
// the upsert from a Merge Join to a Nested Loop over a materialized 157 k-row
// cagg read: 62 × 157 k join-filter evaluations per tick. That is pure CPU, with
// no wait event and FEWER buffers: the upsert went from 1.3 s to 14 s, and the
// correct pass, which had planned that way all along, took 12–21 s. Read once as a
// SELECT, the same rows cost 1–3 s and may run in parallel.
const cpacReadSQL = cpacTransitionsCTE + `
SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'ts_event', f.ts_event, 'ts_end', f.ts_end, 'id_equipment', f.id_equipment,
           'status', f.status, 'id_enterprise', f.id_enterprise, 'duration', f.duration)),
       '[]'::jsonb)::text
  FROM final f`

// cpacSnapshotFinal rebuilds `final` from cpacReadSQL's jsonb (%[11]s = the
// placeholder that carries it). jsonb keeps numeric and µs timestamptz exact, so
// the apply statements see the very rows the read computed. Column types match
// final's: the ids come from equipments (int), status is an int literal, and
// duration is extract(epoch …), which is numeric.
const cpacSnapshotFinal = `
WITH final AS (
    SELECT f.ts_event, f.ts_end, f.id_equipment, f.status, f.id_enterprise, f.duration
      FROM jsonb_to_recordset(%[11]s::jsonb)
           AS f(ts_event timestamptz, ts_end timestamptz, id_equipment int,
                status int, id_enterprise int, duration numeric)
)`

// cpacApplySQL formats an apply half (cpacUpsertApply / cpacCorrectApply) behind
// cpacSnapshotFinal; jsonParam is the placeholder that carries the snapshot.
func cpacApplySQL(apply, evSchema, refSchema, table, rowAlias, silverSchema, jsonParam string) string {
	return fmt.Sprintf(cpacSnapshotFinal+apply, evSchema, refSchema, table, rowAlias, silverSchema,
		"", "", "", "", "", jsonParam)
}

// RunOnceCPAC derives CPAC stops for one destination: correct (delete stale),
// then upsert. Both passes share the SAME scope + human-edit guards so a minted
// row always has a co-scoped cleaner (never an orphan open row — the
// int-overflow class from the EventMint↔deriver scope-mismatch bug).
//
// One transaction, four statements: the derivation is read ONCE as a SELECT
// (cpacReadSQL), then the correct, upsert and close DML apply that snapshot.
// now() is the transaction's start time, so both passes see one `final` at one
// instant. The old code computed it twice, ~20 s apart. The DML reads only the
// target table, so its row locks are held for milliseconds, not for the
// derivation.
func RunOnceCPAC(ctx context.Context, d Dest, cfg CPACConfig) (deleted, upserted, closed int64, err error) {
	table := cfg.TargetTable
	if table == "" {
		table = DefaultCPACTargetTable
	}
	thr := cfg.ThresholdDefSec
	if thr <= 0 {
		thr = 300
	}
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("cpac begin: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after Commit
	if deleted, upserted, closed, err = runCPACTx(ctx, tx, d, cfg, table, thr); err != nil {
		return 0, 0, 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, 0, 0, fmt.Errorf("cpac commit: %w", err)
	}
	return deleted, upserted, closed, nil
}

// runCPACTx is RunOnceCPAC's body inside a caller-owned transaction (the golden
// test runs it and the old two-statement path in ONE transaction, so both see
// the same now()).
func runCPACTx(ctx context.Context, tx pgx.Tx, d Dest, cfg CPACConfig, table string, thr int) (deleted, upserted, closed int64, err error) {
	var snapshot string
	if err := tx.QueryRow(ctx, fmtCPACFull(cpacReadSQL, d.EvSchema, d.RefSchema, table, "ev", d.SilverSchema, cfg.LeadActivity, cfg.LinkHealth),
		cfg.Enterprises, thr).Scan(&snapshot); err != nil {
		return 0, 0, 0, fmt.Errorf("cpac derive: %w", err)
	}
	del, err := tx.Exec(ctx, cpacApplySQL(cpacCorrectApply, d.EvSchema, d.RefSchema, table, "ev", d.SilverSchema, "$2"), cfg.Enterprises, snapshot)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("cpac correct pass: %w", err)
	}
	ups, err := tx.Exec(ctx, cpacApplySQL(cpacUpsertApply, d.EvSchema, d.RefSchema, table, "ev", d.SilverSchema, "$1"), snapshot)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("cpac upsert pass: %w", err)
	}
	cls, err := tx.Exec(ctx, cpacApplySQL(cpacCloseApply, d.EvSchema, d.RefSchema, table, "ev", d.SilverSchema, "$1"), snapshot)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("cpac close pass: %w", err)
	}
	return del.RowsAffected(), ups.RowsAffected(), cls.RowsAffected(), nil
}

// LoopCPAC runs the CPAC derivation on a fixed cadence for every destination.
// Caller (main.go) gates on CPAC_EVENT_DERIVATION_ENABLED before starting it.
func LoopCPAC(ctx context.Context, dests []Dest, cfg CPACConfig, every time.Duration, logger *slog.Logger, obs jobs.Observer) {
	logger.Info("CPAC stop deriver started (ADR-0010 §10.4, DARK)",
		slog.Int("destinations", len(dests)), slog.Int("enterprises", len(cfg.Enterprises)),
		slog.Int("threshold_default_sec", cfg.ThresholdDefSec), slog.String("target_table", cfg.TargetTable),
		slog.Bool("lead_activity", cfg.LeadActivity), slog.Bool("link_health", cfg.LinkHealth))
	jobs.Loop(ctx, jobs.Job{Name: "cpac-events-deriver", Every: every, Run: func(ctx context.Context) error {
		var firstErr error
		for _, d := range dests {
			del, ups, cls, err := RunOnceCPAC(ctx, d, cfg)
			if err != nil {
				logger.Warn("cpac deriver pass failed", slog.String("dest", d.Name), slog.String("err", err.Error()))
				if firstErr == nil {
					firstErr = err
				}
				continue
			}
			if del+ups+cls > 0 {
				logger.Info("cpac events derived", slog.String("dest", d.Name),
					slog.Int64("upserted", ups), slog.Int64("corrected", del), slog.Int64("closed", cls))
			}
		}
		return firstErr
	}}, logger, obs)
}
