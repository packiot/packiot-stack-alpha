package replicate

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ─── shared observability + fail-open (mirrors internal/replay/handlers) ───

var noopObserver = func(table string) {}

// SetNoopObserver wires the zero-row-UPDATE callback (main -> metrics).
func SetNoopObserver(fn func(table string)) { noopObserver = fn }

// execExpectingRows runs an UPDATE, recording a warn + metric on a zero-row
// match. A zero-row UPDATE is a replay gap (base row not yet present), not a
// poison message — it still advances the cursor.
func execExpectingRows(ctx context.Context, pool *pgxpool.Pool, table string, userLogID int64, logger *slog.Logger, sql string, args ...any) error {
	ct, err := pool.Exec(ctx, sql, args...)
	if err != nil {
		return failOpenIfMissing(err, table, userLogID, logger)
	}
	if ct.RowsAffected() == 0 {
		noopObserver(table)
		logger.Warn("update matched no rows", slog.Int64("id_user_log", userLogID), slog.String("table", table))
	}
	return nil
}

// execRows runs an UPDATE and returns rows-affected (fail-open on 42P01). Unlike
// execExpectingRows it does NOT record a noop on zero rows — the caller decides
// (used by the exact-then-overlap event classifier, where a zero-row exact match
// is expected and triggers the overlap fallback rather than a warning).
func execRows(ctx context.Context, pool *pgxpool.Pool, table string, userLogID int64, logger *slog.Logger, sql string, args ...any) (int64, error) {
	ct, err := pool.Exec(ctx, sql, args...)
	if err != nil {
		return 0, failOpenIfMissing(err, table, userLogID, logger)
	}
	return ct.RowsAffected(), nil
}

// failOpenIfMissing swallows 42P01 (missing table) so a partially
// provisioned staging plane never wedges the loop.
func failOpenIfMissing(err error, table string, userLogID int64, logger *slog.Logger) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "42P01" {
		logger.Warn("target table missing — fail-open", slog.Int64("id_user_log", userLogID), slog.String("table", table))
		return nil
	}
	return err
}

func parseTS(s string) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t, true
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, true
	}
	return time.Time{}, false
}

// resolveLegacyOrder maps a legacy id_production_order (surrogate) to its
// natural id_order, verifying it belongs to the polled source enterprise.
// The staging PO is keyed by (dst_enterprise, id_order) — never the legacy
// surrogate, which lives in a different id space (bug-248 discipline).
func resolveLegacyOrder(ctx context.Context, legacy *pgxpool.Pool, idProductionOrder int64, srcEnterprise int) (int64, bool, error) {
	var idOrder int64
	var ent int
	err := legacy.QueryRow(ctx,
		`SELECT id_order, id_enterprise FROM production_orders WHERE id_production_order = $1`,
		idProductionOrder).Scan(&idOrder, &ent)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	if ent != srcEnterprise {
		return 0, false, nil
	}
	return idOrder, true, nil
}

// legacyEvent is the resolved (id_equipment, window, status) of a legacy
// base equipment_events row — enough to match it against the twin either by
// exact ts_event or by interval overlap. tsEnd is zero when the legacy event
// is still open.
type legacyEvent struct {
	idEquipment int
	tsEvent     time.Time
	tsEnd       time.Time
	tsEndValid  bool
	status      int
	statusValid bool
}

// resolveLegacyEvent maps a legacy id_equipment_event to its full base-row
// window (id_equipment, ts_event, ts_end, status). ts_event is deterministic
// from the PLC stream, so it is the primary join key against staging's
// equipment_events; ts_end + status feed the interval-overlap fallback.
func resolveLegacyEvent(ctx context.Context, legacy *pgxpool.Pool, idEquipmentEvent int64) (legacyEvent, bool, error) {
	var e legacyEvent
	var tsEnd pgtype.Timestamptz
	var status pgtype.Int4
	err := legacy.QueryRow(ctx,
		`SELECT id_equipment, ts_event, ts_end, status FROM equipment_events WHERE id_equipment_event = $1`,
		idEquipmentEvent).Scan(&e.idEquipment, &e.tsEvent, &tsEnd, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return legacyEvent{}, false, nil
	}
	if err != nil {
		return legacyEvent{}, false, err
	}
	if tsEnd.Valid {
		e.tsEnd, e.tsEndValid = tsEnd.Time, true
	}
	if status.Valid {
		e.status, e.statusValid = int(status.Int32), true
	}
	return e, true, nil
}

// findTwinEventByOverlap is the interval-overlap matcher ported from
// mirror-worker-go's translate.EquipmentEvent. When an operator classifies /
// splits a legacy base event, the exact (id_equipment, ts_event) row may be
// absent on the twin because the twin's copy came from the SparkPlug tee at a
// slightly different ts (CPAC 5-min smoothing on prod vs raw PLC transitions
// on the twin). Instead of no-op'ing, we pick the same-(equipment,status) twin
// event whose [ts_event, COALESCE(ts_end, now())] window overlaps the legacy
// event's window by >= minOverlapSec, requiring the twin ts_event to be no
// earlier than legacy_start - maxDriftSec so a stale still-open event from days
// ago can't "overlap" every later event via COALESCE(ts_end, now()). Returns
// the matched twin ts_event (the row's stable key) so the caller can UPDATE it.
// sqlOverlapMatch is the interval-overlap lookup (kept as a const so the
// shape test can assert against the real query). $1 staging equip, $2 dst
// enterprise, $3 legacy start, $4 legacy end (or now), $5 status, $6 max drift.
const sqlOverlapMatch = `SELECT ts_event,
		        extract(epoch FROM (
		          LEAST(COALESCE(ts_end, now()), $4::timestamptz)
		          - GREATEST(ts_event, $3::timestamptz)
		        ))::int AS overlap_seconds
		   FROM silver.equipment_events
		  WHERE id_equipment = $1
		    AND id_enterprise = $2
		    AND status = $5
		    AND ts_event < $4::timestamptz
		    AND ts_event >= $3::timestamptz - ($6::int * interval '1 second')
		    AND (ts_end IS NULL OR ts_end > $3::timestamptz)
		  ORDER BY overlap_seconds DESC
		  LIMIT 1`

func findTwinEventByOverlap(ctx context.Context, dst *pgxpool.Pool, stagingEquip, dstEnterprise int, ev legacyEvent, minOverlapSec, maxDriftSec int) (time.Time, bool, error) {
	if !ev.statusValid {
		return time.Time{}, false, nil // no status to disambiguate — overlap unsafe
	}
	end := time.Now().UTC()
	if ev.tsEndValid {
		end = ev.tsEnd
	}
	var twinTS time.Time
	var overlapSec int
	err := dst.QueryRow(ctx, sqlOverlapMatch,
		stagingEquip, dstEnterprise, ev.tsEvent, end, ev.status, maxDriftSec).Scan(&twinTS, &overlapSec)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "42P01" {
			return time.Time{}, false, nil
		}
		return time.Time{}, false, err
	}
	if overlapSec < minOverlapSec {
		return time.Time{}, false, nil
	}
	return twinTS, true, nil
}

// resolveLegacyManualTS maps a legacy equipment_events_man surrogate id to
// its current (legacy id_equipment, ts_event).
func resolveLegacyManualTS(ctx context.Context, legacy *pgxpool.Pool, idEquipmentEvent int64) (int, time.Time, bool, error) {
	var idEq int
	var ts time.Time
	err := legacy.QueryRow(ctx,
		`SELECT id_equipment, ts_event FROM equipment_events_man WHERE id_equipment_event = $1`,
		idEquipmentEvent).Scan(&idEq, &ts)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, time.Time{}, false, nil
	}
	if err != nil {
		return 0, time.Time{}, false, err
	}
	return idEq, ts, true, nil
}

// ─── runtime-window machinery (single-dest port of production_orders.go) ───
// Staging's OEE runtime chain reads production_orders_runtime windows; a PO
// without a window starves the compute jobs. All ids here are already
// translated to staging.

const sqlCloseWindowsForEquipment = `UPDATE gold.production_orders_runtime r
	   SET runtime_timerange = tstzrange(lower(runtime_timerange), $2), recalc_needed = true
	 WHERE r.id_equipment = $1 AND upper(runtime_timerange) IS NULL AND lower(runtime_timerange) < $2`

// sqlSupersedeRunningPO finishes any OTHER PO still running on the equipment when
// a new one opens there. It used to set status = 3 only, leaving ts_end NULL and
// the header un-flagged: a finished PO with no end (PO 7627570 on L5, "status 3,
// ts_end NULL", and every order-replaced ghost). Its window was just closed at $4
// by sqlCloseWindowsForEquipment, so the PO ends there too. The ts_start guard
// keeps the production_orders_ts_start_ts_end check (an out-of-order replay).
const sqlSupersedeRunningPO = `UPDATE core.production_orders
	   SET status = 3, ts_end = $4, recalc_needed = true, last_update = now()
	 WHERE id_equipment = $1 AND status = 2 AND NOT (id_enterprise = $2 AND id_order = $3)
	   AND (ts_start IS NULL OR ts_start <= $4)`

// sqlOpenWindow inserts a [ts, ∞) runtime window for the PO, but ONLY when no
// existing window for the SAME EQUIPMENT (open OR closed) overlaps [ts, ∞).
//
// The overlap guard (`&&` on tstzrange) is what makes the open safe under
// OUT-OF-ORDER replay. The prior guard only skipped when THIS po already had
// an OPEN window; it ignored CLOSED windows and other POs. Under a
// non-chronological replay a CLOSED window [lo, hi) for the equipment can
// already contain ts (lo <= ts < hi), and a later-starting still-open window
// [lo, ∞) with lo >= ts survives sqlCloseWindowsForEquipment (it only closes
// lower < ts). Inserting [ts, ∞) then collides with the
// production_orders_runtime_id_equipment_runtime_timerange exclusion
// constraint (a machine can't run two POs at once) → the event DLQs.
//
// With the `&&` guard, an insert that WOULD overlap matches zero rows — a
// clean, idempotent no-op — instead of erroring. This strictly subsumes the
// old per-PO "no open window already" guard: an existing open window for THIS
// po always extends to ∞ and therefore overlaps [ts, ∞). Half-open range
// semantics keep the normal forward case working: after
// sqlCloseWindowsForEquipment turns the prior window into [lo, ts), it is
// adjacent to — not overlapping — the new [ts, ∞).
const sqlOpenWindow = `INSERT INTO gold.production_orders_runtime
	       (id_production_order, id_equipment, runtime_timerange, recalc_needed)
	SELECT po.id_production_order, po.id_equipment, tstzrange($3, NULL), true
	  FROM core.production_orders po
	 WHERE po.id_enterprise = $1 AND po.id_order = $2
	   AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime x
	        WHERE x.id_equipment = po.id_equipment
	          AND x.runtime_timerange && tstzrange($3, NULL))`

const sqlCloseWindowsForPO = `UPDATE gold.production_orders_runtime r
	   SET runtime_timerange = tstzrange(lower(runtime_timerange), $3), recalc_needed = true
	  FROM core.production_orders po
	 WHERE po.id_enterprise = $1 AND po.id_order = $2
	   AND r.id_production_order = po.id_production_order
	   AND upper(r.runtime_timerange) IS NULL AND lower(r.runtime_timerange) < $3`

func openRuntimeWindow(ctx context.Context, dst *pgxpool.Pool, ent int, idOrder int64, idEquipment int, ts time.Time, userLogID int64, logger *slog.Logger) error {
	if _, err := dst.Exec(ctx, sqlCloseWindowsForEquipment, idEquipment, ts); err != nil {
		return failOpenIfMissing(err, "production_orders_runtime", userLogID, logger)
	}
	if _, err := dst.Exec(ctx, sqlSupersedeRunningPO, idEquipment, ent, idOrder, ts); err != nil {
		return failOpenIfMissing(err, "production_orders", userLogID, logger)
	}
	_, err := dst.Exec(ctx, sqlOpenWindow, ent, idOrder, ts)
	return failOpenIfMissing(err, "production_orders_runtime", userLogID, logger)
}

func closeRuntimeWindow(ctx context.Context, dst *pgxpool.Pool, ent int, idOrder int64, ts time.Time, userLogID int64, logger *slog.Logger) error {
	_, err := dst.Exec(ctx, sqlCloseWindowsForPO, ent, idOrder, ts)
	return failOpenIfMissing(err, "production_orders_runtime", userLogID, logger)
}

// ─── starting a PO that already exists (2026-09-29) ───
//
// Legacy starts an EXISTING PO in three ways the replay used to ignore:
//   - order-changed with shouldCreatePo=false, shouldOpenNewPo=true: the operator
//     finishes the running PO and starts a PRE-EXISTING one (ERP-planned, or a
//     paused one being resumed). OrderChanged returned before opening it, so the
//     PO never got status 2, a ts_start or a runtime window: it later closed with
//     no window (CPACK 896880/896933/896862/896488…: runtime net 0 while the line
//     produced) and every resume segment of a paused PO was lost (FLEXO 894815,
//     BREYER2 896879).
//   - order-changed / order-created-started with shouldCreatePo=true for an id_order
//     the twin already holds as AVAILABLE (status 1, never ran): the insert is
//     ON CONFLICT DO NOTHING, so the row stayed status 1 on its OLD equipment and
//     the window opened on that old equipment (PO 895874: L10 in legacy, L8 here).
//   - order-replaced (OrderReplaced below).

// sqlMoveAvailablePO re-homes a PO that never ran (status 1, no runtime rows) onto
// the equipment it is being started on. A PO that has run is never moved.
const sqlMoveAvailablePO = `UPDATE core.production_orders po
	   SET id_equipment = $1, id_site = $2, id_area = $3, last_update = now()
	 WHERE po.id_enterprise = $4 AND po.id_order = $5 AND po.status = 1
	   AND po.id_equipment IS DISTINCT FROM $1
	   AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime r
	                    WHERE r.id_production_order = po.id_production_order)`

// sqlStartExistingPO marks the PO running from $1. ts_start keeps the FIRST start
// (a resume does not move it — legacy keeps the original start, e.g. FLEXO 894815);
// ts_end is cleared. Monotonic: a start older than the PO's recorded end (an
// out-of-order or DLQ-retried replay) is a no-op, so it can never reopen a PO that
// finished later.
const sqlStartExistingPO = `UPDATE core.production_orders
	   SET status = 2, ts_start = COALESCE(ts_start, $1), ts_end = NULL,
	       recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $2 AND id_order = $3
	   AND (ts_end IS NULL OR ts_end <= $1)
	   AND (ts_start IS NULL OR ts_start <= $1)`

// startExistingPO: move-if-never-ran, open the runtime window (which closes and
// supersedes whatever else runs on the equipment — so the running-PO unique index
// holds), then mark the PO running.
func startExistingPO(ctx context.Context, dst *pgxpool.Pool, eq StagingEquip, ent int, idOrder int64, ts time.Time, userLogID int64, logger *slog.Logger) error {
	if _, err := dst.Exec(ctx, sqlMoveAvailablePO, eq.IDEquipment, eq.IDSite, eq.IDArea, ent, idOrder); err != nil {
		if e := failOpenIfMissing(err, "production_orders", userLogID, logger); e != nil {
			return e
		}
	}
	if err := openRuntimeWindow(ctx, dst, ent, idOrder, eq.IDEquipment, ts, userLogID, logger); err != nil {
		return err
	}
	return execExpectingRows(ctx, dst, "production_orders", userLogID, logger, sqlStartExistingPO, ts, ent, idOrder)
}

// ─── production_orders SQL (staging-keyed) ───

const sqlInsertPOAvailable = `INSERT INTO core.production_orders (
		id_enterprise, id_site, id_area, id_equipment, id_order,
		nm_production_order, production_programmed, production_ordered,
		txt_production_order_notes, status)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$7,$8,1)
	ON CONFLICT (id_enterprise, id_order) DO NOTHING`

const sqlInsertPORunning = `INSERT INTO core.production_orders (
		id_enterprise, id_site, id_area, id_equipment, id_order,
		nm_production_order, production_programmed, production_ordered,
		txt_production_order_notes, status, ts_start)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$7,$8,2,$9)
	ON CONFLICT (id_enterprise, id_order) DO NOTHING`

// order-started of a paused PO is a RESUME: keep its first start, clear its end
// (was: ts_start overwritten with the resume time, ts_end left at the pause).
// Monotonic like sqlStartExistingPO.
const sqlUpdatePOStart = `UPDATE core.production_orders
	   SET status = 2, ts_start = COALESCE(ts_start, $1), ts_end = NULL, recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $2 AND id_order = $3
	   AND (ts_end IS NULL OR ts_end <= $1)
	   AND (ts_start IS NULL OR ts_start <= $1)`

// sqlPOEquipment reads the PO's own current equipment (set at create). Used to open
// the runtime window on a start replay without depending on the start payload's
// legacy equipment resolving — see OrderStarted.
const sqlPOEquipment = `SELECT COALESCE(id_equipment, 0) FROM core.production_orders
	 WHERE id_enterprise = $1 AND id_order = $2`

// sqlUpdatePOStop closes a PO at ts_end=$2. The `ts_start IS NULL OR
// ts_start <= $2` guard prevents writing an inverted [ts_start, ts_end] range
// when an out-of-order replay delivers a stop whose ts precedes the recorded
// start — that would trip the production_orders_ts_start_ts_end check and DLQ
// the event. When ts_end would precede ts_start the UPDATE matches zero rows
// (an observable no-op via execExpectingRows); a correctly-ordered stop, or
// the PO reconciler, closes it later.
//
// The `ts_end IS NULL OR ts_end <= $2` guard (2026-09-29) makes a close MONOTONIC:
// it never moves a PO's end backwards. Without it a close replayed late — the DLQ
// retrier re-drives old rows after newer ones applied — overwrote a later finish:
// FLEXO 896297 was finished on 09-11 22:01, then its 09-05 pause (DLQ'd on the
// window-overlap bug, retried on 09-20) set it back to status 4 / ts_end 09-05.
// Also flags the header: the stop changes what recalc must sum.
const sqlUpdatePOStop = `UPDATE core.production_orders
	   SET status = $1, ts_end = $2, production_real = $3, recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $4 AND id_order = $5
	   AND (ts_start IS NULL OR ts_start <= $2)
	   AND (ts_end IS NULL OR ts_end <= $2)`

const sqlUpdatePOTsStart = `UPDATE core.production_orders
	   SET ts_start = $1, last_update = now()
	 WHERE id_enterprise = $2 AND id_order = $3`

const sqlUpdatePORecalc = `UPDATE core.production_orders
	   SET recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $1 AND id_order = $2`

// sqlClosePOChanged closes the OLD PO during an order-changed step (the bulk of
// the DLQ'd batch). Same inverted-range guard as sqlUpdatePOStop: never write
// a ts_end that precedes ts_start under out-of-order replay.
// Monotonic like sqlUpdatePOStop (never moves the end backwards).
const sqlClosePOChanged = `UPDATE core.production_orders
	   SET status = $1, ts_end = $2, production_final = $3, recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $4 AND id_order = $5
	   AND (ts_start IS NULL OR ts_start <= $2)
	   AND (ts_end IS NULL OR ts_end <= $2)`

// ─── equipment_events / _man SQL (staging-keyed) ───

// downtime-event-created: base PLC event. id_equipment_event is NOT NULL
// with no default on staging, so we synthesise a deterministic value from
// (ts_ms, id_equipment) — it carries no cross-flow meaning (no unique index
// on it); the natural key is (id_equipment, ts_event).
//
// forced_creation_system=FALSE: this is the PLC's own event. In legacy the flag
// is false for PLC events and true only for rows a person created (manual
// events, split segments, edits) — 41 of 4,660 CPACK events over 3 days.
// Writing true here made every replicated CPACK event look human-created, and
// the operator's PO downtime (serving.v_operator_po_details_3, which sums only
// fcs=false events, like legacy) read 0 on every line. CPACK equipment is
// status_type 0 and outside the wide-row list, so deriver.go's correct pass
// (which deletes unmatched fcs=false rows in ITS scope) never touches these.
const sqlInsertEquipmentEvent = `INSERT INTO silver.equipment_events (
		id_equipment, ts_event, status, id_equipment_event, id_enterprise,
		forced_creation_system, last_update)
	VALUES ($1,$2,$3,$4,$5,false,now())
	ON CONFLICT (id_equipment, ts_event) DO NOTHING`

const sqlUpdateEventClassification = `UPDATE silver.equipment_events
	   SET cd_category = $1, desc_category = $2, cd_machine = $3,
	       cd_subcategory = $4, desc_subcategory = $5, txt_downtime_notes = $6,
	       change_over = $7, idle = $8, planned_downtime = $9, last_update = now()
	 WHERE id_equipment = $10 AND ts_event = $11`

// equipment_events_man: id_equipment_event is a staging IDENTITY serial —
// deliberately OMITTED from the column list (the coordinator's warning: do
// not copy the legacy serial). Idempotent via the ts_event unique key.
const sqlInsertManualEvent = `INSERT INTO public.equipment_events_man (
		id_equipment, id_enterprise, ts_event, ts_end, duration,
		cd_machine, cd_category, cd_subcategory, desc_category, desc_subcategory,
		change_over, planned_downtime, txt_downtime_notes,
		forced_creation_system, last_update)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,true,now())
	ON CONFLICT (id_equipment, ts_event) DO NOTHING`

const sqlUpdateManualEvent = `UPDATE public.equipment_events_man
	   SET ts_event = COALESCE($1, ts_event), ts_end = COALESCE($2, ts_end),
	       cd_machine = $3, cd_category = $4, cd_subcategory = $5,
	       desc_category = $6, desc_subcategory = $7,
	       change_over = $8, planned_downtime = $9, txt_downtime_notes = $10, last_update = now()
	 WHERE id_equipment = $11 AND ts_event = $12`

func genEventID(ts time.Time, stagingEquip int) int64 {
	return ts.UnixMilli()*1000 + int64(stagingEquip%1000)
}

// ─── event-splitted SQL (equipment_events, matching legacy edge-api DAO) ───
// A legacy split takes ONE base equipment_events (auto) row and rewrites it as
// N contiguous segments: segment[0] shrinks the original row in place; segments
// [1..N-1] are inserted as NEW equipment_events rows, all
// forced_creation_system=true. Split segments are AUTO events (equipment_events),
// NOT manual events (equipment_events_man) — see downtimes-dao.ts::split.

// sqlSplitShrinkOriginal rewrites the matched twin base event as segment 0:
// closes it at the segment-0 end and applies the operator's classification.
// ts_event is left untouched (it is the PK and the overlap-match key); only the
// end + classification move. Idempotent (a re-run sets the same values).
const sqlSplitShrinkOriginal = `UPDATE silver.equipment_events
	   SET ts_end = $1,
	       duration = GREATEST(0, EXTRACT(EPOCH FROM ($1::timestamptz - ts_event))::int),
	       cd_machine = $2, cd_category = $3, cd_subcategory = $4,
	       desc_category = $5, desc_subcategory = $6,
	       change_over = $7, planned_downtime = $8, idle = $9,
	       txt_downtime_notes = $10, forced_creation_system = true, last_update = now()
	 WHERE id_equipment = $11 AND ts_event = $12`

// sqlInsertSplitSegment inserts a non-first split segment as a new auto event.
// status is inherited from the original base event (segments carry the same
// machine state). id_equipment_event is synthesised (no unique meaning; the
// natural key is (id_equipment, ts_event)). Idempotent on the PK.
const sqlInsertSplitSegment = `INSERT INTO silver.equipment_events (
		id_equipment, ts_event, ts_end, status, id_equipment_event, id_enterprise,
		duration, cd_machine, cd_category, cd_subcategory, desc_category, desc_subcategory,
		change_over, planned_downtime, idle, txt_downtime_notes,
		forced_creation_system, last_update)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,true,now())
	ON CONFLICT (id_equipment, ts_event) DO NOTHING`

// ═══════════════════════════ handlers ═══════════════════════════

type downtimeEventCreatedPayload struct {
	Events []struct {
		Topic       string    `json:"topic"`
		Status      *int      `json:"status"`
		Timestamp   flexInt64 `json:"timestamp"` // epoch ms
		IDEquipment int       `json:"idEquipment"`
	} `json:"events"`
}

// DowntimeEventCreated inserts the raw PLC equipment_events rows (the base
// rows event-justified/edited later classify). Gated by cfg — the
// in-instance mirror defers this, but the twin's tee does not carry every
// line, so we fill the base rows. ON CONFLICT never clobbers a tee row.
func DowntimeEventCreated(logger *slog.Logger, enabled bool) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		if !enabled {
			return ErrSkip
		}
		var p downtimeEventCreatedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if len(p.Events) == 0 {
			return ErrSkip
		}
		for _, ev := range p.Events {
			eq, ok := r.ResolveEquipment(ev.IDEquipment)
			if !ok {
				logger.Warn("downtime-event-created: unresolved equipment", slog.Int64("id_user_log", u.ID), slog.Int("legacy_equipment", ev.IDEquipment))
				continue
			}
			if ev.Timestamp == 0 {
				continue
			}
			ts := time.UnixMilli(ev.Timestamp.Int64()).UTC()
			_, err := dst.Exec(ctx, sqlInsertEquipmentEvent,
				eq.IDEquipment, ts, ev.Status, genEventID(ts, eq.IDEquipment), eq.IDEnterprise)
			if err := failOpenIfMissing(err, "equipment_events", u.ID, logger); err != nil {
				return err
			}
		}
		return nil
	}
}

type eventClassifiedPayload struct {
	IDEquipment      int    `json:"idEquipment"`
	IDEquipmentEvent int64  `json:"idEquipmentEvent"`
	CdMachine        string `json:"cdMachine"`
	CdCategory       string `json:"cdCategory"`
	CdSubcategory    string `json:"cdSubcategory"`
	DescCategory     string `json:"descCategory"`
	DescSubcategory  string `json:"descSubcategory"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
	ChangeOver       bool   `json:"changeOver"`
	PlannedDowntime  bool   `json:"plannedDowntime"`
	Idle             string `json:"idle"`
}

// EventClassified serves both event-justified and event-edited: it UPDATEs
// the base equipment_events row (created by the tee or by
// DowntimeEventCreated) with the operator's downtime classification,
// re-keyed onto the flow-stable natural key (staging id_equipment,
// ts_event) resolved from the LEGACY event.
//
// It first tries an EXACT (staging id_equipment, legacy ts_event) match — the
// common case, since DowntimeEventCreated inserts the twin base row at the
// exact legacy ts. When that matches zero rows (the twin's only copy of this
// event came from the SparkPlug tee at a drifted ts), it falls back to the
// interval-overlap matcher rather than silently no-op'ing. Both paths are
// idempotent UPDATEs of classification columns.
func EventClassified(logger *slog.Logger, cfg *Config) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p eventClassifiedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDEquipmentEvent == 0 {
			return ErrSkip
		}
		ev, found, err := resolveLegacyEvent(ctx, legacy, p.IDEquipmentEvent)
		if err != nil {
			return fmt.Errorf("resolve legacy event: %w", err)
		}
		if !found {
			logger.Warn("event-classified: legacy event gone", slog.Int64("id_user_log", u.ID), slog.Int64("id_equipment_event", p.IDEquipmentEvent))
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(ev.idEquipment)
		if !ok {
			logger.Warn("event-classified: unresolved equipment", slog.Int64("id_user_log", u.ID), slog.Int("legacy_equipment", ev.idEquipment))
			return ErrSkip
		}
		// 1) exact ts_event match (does not warn on zero rows).
		n, err := execRows(ctx, dst, "equipment_events", u.ID, logger, sqlUpdateEventClassification,
			p.CdCategory, p.DescCategory, p.CdMachine,
			p.CdSubcategory, p.DescSubcategory, p.TxtDowntimeNotes,
			p.ChangeOver, p.Idle, p.PlannedDowntime,
			eq.IDEquipment, ev.tsEvent)
		if err != nil {
			return err
		}
		if n > 0 {
			return nil
		}
		// 2) interval-overlap fallback onto a tee-drifted twin event.
		twinTS, ok, err := findTwinEventByOverlap(ctx, dst, eq.IDEquipment, eq.IDEnterprise, ev, cfg.EventMinOverlapSec, cfg.EventMaxStartDriftSec)
		if err != nil {
			return fmt.Errorf("event-classified overlap lookup: %w", err)
		}
		if ok {
			m, err := execRows(ctx, dst, "equipment_events", u.ID, logger, sqlUpdateEventClassification,
				p.CdCategory, p.DescCategory, p.CdMachine,
				p.CdSubcategory, p.DescSubcategory, p.TxtDowntimeNotes,
				p.ChangeOver, p.Idle, p.PlannedDowntime,
				eq.IDEquipment, twinTS)
			if err != nil {
				return err
			}
			if m > 0 {
				logger.Debug("event-classified matched via interval overlap",
					slog.Int64("id_user_log", u.ID), slog.Int("staging_equipment", eq.IDEquipment),
					slog.Time("legacy_ts", ev.tsEvent), slog.Time("twin_ts", twinTS))
				return nil
			}
		}
		// Neither exact nor overlap matched — the twin base event is absent
		// entirely (a PLC-detected downtime legacy never logged to user_logs).
		// Record the observable no-op and advance; nothing to update.
		noopObserver("equipment_events")
		logger.Warn("event-classified: no twin base event (exact + overlap miss)",
			slog.Int64("id_user_log", u.ID), slog.Int("staging_equipment", eq.IDEquipment),
			slog.Time("legacy_ts", ev.tsEvent))
		return nil
	}
}

type manualEventCreatedPayload struct {
	IDEquipment      int    `json:"idEquipment"`
	TsEvent          string `json:"tsEvent"`
	TsEnd            string `json:"tsEnd"`
	Duration         int    `json:"duration"`
	CdMachine        string `json:"cdMachine"`
	CdCategory       string `json:"cdCategory"`
	CdSubcategory    string `json:"cdSubcategory"`
	DescCategory     string `json:"descCategory"`
	DescSubcategory  string `json:"descSubcategory"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
}

// ManualEventCreated inserts an operator-authored downtime into staging
// equipment_events_man. Idempotent via the ts_event unique key.
func ManualEventCreated(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p manualEventCreatedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		tsEvent, ok := parseTS(p.TsEvent)
		if p.IDEquipment == 0 || !ok {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			logger.Warn("manual-event-created: unresolved equipment", slog.Int64("id_user_log", u.ID), slog.Int("legacy_equipment", p.IDEquipment))
			return ErrSkip
		}
		var tsEnd *time.Time
		if t, ok := parseTS(p.TsEnd); ok {
			tsEnd = &t
		}
		_, err := dst.Exec(ctx, sqlInsertManualEvent,
			eq.IDEquipment, eq.IDEnterprise, tsEvent, tsEnd, p.Duration,
			p.CdMachine, p.CdCategory, p.CdSubcategory, p.DescCategory, p.DescSubcategory,
			false, false, p.TxtDowntimeNotes)
		return failOpenIfMissing(err, "equipment_events_man", u.ID, logger)
	}
}

type manualEventEditedPayload struct {
	Start            string `json:"start"`
	End              string `json:"end"`
	CdMachine        string `json:"cdMachine"`
	CdCategory       string `json:"cdCategory"`
	CdSubcategory    string `json:"cdSubcategory"`
	DescCategory     string `json:"descCategory"`
	DescSubcategory  string `json:"descSubcategory"`
	IDEquipment      int    `json:"idEquipment"`
	IDEquipmentEvent int64  `json:"idEquipmentEvent"`
	ChangeOver       bool   `json:"changeOver"`
	PlannedDowntime  bool   `json:"plannedDowntime"`
	TxtDowntimeNotes string `json:"txtDowntimeNotes"`
}

// ManualEventEdited best-effort UPDATEs a replicated manual event by
// (staging id_equipment, legacy current ts_event). If the operator edited
// the START time the legacy row's ts_event has moved and the staging row —
// keyed on the original ts_event — won't match; that surfaces as an
// observable no-op (execExpectingRows), never a failure. Manual edits are
// rare (~3/48h) so this is an accepted limitation, not a data-loss path.
func ManualEventEdited(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p manualEventEditedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDEquipmentEvent == 0 {
			return ErrSkip
		}
		legEq, curTS, found, err := resolveLegacyManualTS(ctx, legacy, p.IDEquipmentEvent)
		if err != nil {
			return fmt.Errorf("resolve legacy manual event: %w", err)
		}
		if !found {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(legEq)
		if !ok {
			return ErrSkip
		}
		var newStart, newEnd *time.Time
		if t, ok := parseTS(p.Start); ok {
			newStart = &t
		}
		if t, ok := parseTS(p.End); ok {
			newEnd = &t
		}
		return execExpectingRows(ctx, dst, "equipment_events_man", u.ID, logger, sqlUpdateManualEvent,
			newStart, newEnd, p.CdMachine, p.CdCategory, p.CdSubcategory,
			p.DescCategory, p.DescSubcategory, p.ChangeOver, p.PlannedDowntime, p.TxtDowntimeNotes,
			eq.IDEquipment, curTS)
	}
}

type eventSplittedPayload struct {
	Events []struct {
		Type            string `json:"type"`
		Note            string `json:"note"`
		Idle            string `json:"idle"`
		StartTime       string `json:"startTime"`
		EndTime         string `json:"endTime"`
		MachineCode     string `json:"machineCode"`
		CategoryCode    string `json:"categoryCode"`
		SubcategoryCode string `json:"subcategoryCode"`
		DescCategory    string `json:"descCategory"`
		DescSubcategory string `json:"descSubcategory"`
		ChangeOver      bool   `json:"changeOver"`
		PlannedDowntime bool   `json:"plannedDowntime"`
	} `json:"events"`
	IDEquipment      int   `json:"idEquipment"`
	IDEquipmentEvent int64 `json:"idEquipmentEvent"`
}

// EventSplitted replays an operator splitting one base downtime into N
// contiguous segments, matching legacy edge-api's downtimes-dao.ts::split
// EXACTLY: split segments are AUTO events in equipment_events (forced), NOT
// manual events in equipment_events_man (which the old twin handler wrongly
// used — 92 forced twin manual rows vs ~20 genuine legacy manual events).
//
//   - events[0] shrinks the ORIGINAL base event in place (its startTime equals
//     the original ts_event, enforced by split.service.ts). We locate the twin
//     base row (exact ts_event, then interval-overlap) and close it at
//     events[0].endTime with the operator's classification.
//   - events[1..N-1] are INSERTed as new forced equipment_events rows.
//
// All writes are idempotent (UPDATE-in-place / ON CONFLICT DO NOTHING on the
// (id_equipment, ts_event) PK).
func EventSplitted(logger *slog.Logger, cfg *Config) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p eventSplittedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if len(p.Events) == 0 {
			return ErrSkip
		}

		// Resolve the original base event window (for equipment + status +
		// twin-row matching). Fall back to the payload idEquipment if the
		// legacy base row is already gone.
		var (
			ev       legacyEvent
			haveOrig bool
		)
		if p.IDEquipmentEvent != 0 {
			e, found, err := resolveLegacyEvent(ctx, legacy, p.IDEquipmentEvent)
			if err != nil {
				return fmt.Errorf("resolve legacy split original: %w", err)
			}
			ev, haveOrig = e, found
		}
		legEquip := p.IDEquipment
		if haveOrig {
			legEquip = ev.idEquipment
		}
		if legEquip == 0 {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(legEquip)
		if !ok {
			logger.Warn("event-splitted: unresolved equipment", slog.Int64("id_user_log", u.ID), slog.Int("legacy_equipment", legEquip))
			return ErrSkip
		}
		status := 0
		statusValid := false
		if haveOrig && ev.statusValid {
			status, statusValid = ev.status, true
		}

		for i, seg := range p.Events {
			if seg.Type != "" && seg.Type != "downtime" {
				continue
			}
			segStart, ok := parseTS(seg.StartTime)
			if !ok {
				continue
			}
			segEnd, okEnd := parseTS(seg.EndTime)

			if i == 0 {
				// Segment 0: shrink the original twin base event in place.
				// Locate it by exact ts then interval overlap.
				var mts time.Time
				matched := false
				if haveOrig {
					mts, matched = locateTwinBase(ctx, dst, eq, ev, cfg, logger, u.ID)
				}
				if matched && okEnd {
					if _, err := execRows(ctx, dst, "equipment_events", u.ID, logger, sqlSplitShrinkOriginal,
						segEnd, seg.MachineCode, seg.CategoryCode, seg.SubcategoryCode,
						seg.DescCategory, seg.DescSubcategory, seg.ChangeOver, seg.PlannedDowntime,
						seg.Idle, seg.Note, eq.IDEquipment, mts); err != nil {
						return err
					}
					continue
				}
				// No twin base row to shrink — insert segment 0 as a new forced
				// event so the split isn't lost (idempotent on the PK).
				if err := insertSplitSegment(ctx, dst, eq, segStart, segEnd, okEnd, status, statusValid, seg.MachineCode, seg.CategoryCode, seg.SubcategoryCode, seg.DescCategory, seg.DescSubcategory, seg.ChangeOver, seg.PlannedDowntime, seg.Idle, seg.Note, u.ID, logger); err != nil {
					return err
				}
				continue
			}
			// Segments 1..N-1: new forced auto events.
			if err := insertSplitSegment(ctx, dst, eq, segStart, segEnd, okEnd, status, statusValid, seg.MachineCode, seg.CategoryCode, seg.SubcategoryCode, seg.DescCategory, seg.DescSubcategory, seg.ChangeOver, seg.PlannedDowntime, seg.Idle, seg.Note, u.ID, logger); err != nil {
				return err
			}
		}
		return nil
	}
}

// locateTwinBase finds the twin equipment_events row for a legacy base event:
// exact ts_event first, then interval overlap. Returns the twin ts_event (the
// row's stable key) and whether a row was found.
func locateTwinBase(ctx context.Context, dst *pgxpool.Pool, eq StagingEquip, ev legacyEvent, cfg *Config, logger *slog.Logger, userLogID int64) (time.Time, bool) {
	var exists bool
	err := dst.QueryRow(ctx,
		`SELECT true FROM silver.equipment_events WHERE id_equipment = $1 AND ts_event = $2`,
		eq.IDEquipment, ev.tsEvent).Scan(&exists)
	if err == nil && exists {
		return ev.tsEvent, true
	}
	twinTS, ok, oerr := findTwinEventByOverlap(ctx, dst, eq.IDEquipment, eq.IDEnterprise, ev, cfg.EventMinOverlapSec, cfg.EventMaxStartDriftSec)
	if oerr != nil {
		logger.Warn("event-splitted: overlap lookup failed", slog.Int64("id_user_log", userLogID), slog.String("err", oerr.Error()))
		return time.Time{}, false
	}
	return twinTS, ok
}

// insertSplitSegment inserts one split segment as a forced auto event.
func insertSplitSegment(ctx context.Context, dst *pgxpool.Pool, eq StagingEquip, start time.Time, end time.Time, endValid bool, status int, statusValid bool, machine, cat, subcat, descCat, descSub string, changeOver, planned bool, idle, note string, userLogID int64, logger *slog.Logger) error {
	var tsEnd *time.Time
	var duration int
	if endValid {
		tsEnd = &end
		if d := int(end.Sub(start).Seconds()); d > 0 {
			duration = d
		}
	}
	var statusArg any
	if statusValid {
		statusArg = status
	}
	_, err := dst.Exec(ctx, sqlInsertSplitSegment,
		eq.IDEquipment, start, tsEnd, statusArg, genEventID(start, eq.IDEquipment), eq.IDEnterprise,
		duration, machine, cat, subcat, descCat, descSub, changeOver, planned, idle, note)
	return failOpenIfMissing(err, "equipment_events", userLogID, logger)
}

// ─── production-order lifecycle ───

type orderCreatedPayload struct {
	IDOrder                 flexInt64 `json:"idOrder"`
	IDEquipment             int       `json:"idEquipment"`
	NmProductionOrder       string    `json:"nmProductionOrder"`
	ProductionOrderQuantity flexInt64 `json:"productionOrderQuantity"`
	TxtProductionOrderNotes string    `json:"txtProductionOrderNotes"`
}

func OrderCreated(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderCreatedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDOrder == 0 || p.IDEquipment == 0 {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			// Not ErrSkip: a silent skip here DROPS THE WHOLE PO (the CPACK count
			// gap — 491 legacy POs absent from current, hardproofed). The resolver
			// is built once at startup, so a legacy equipment that maps later (e.g.
			// its packml_register / staging twin arrives after replay reached this
			// row) would be lost forever. Return an error → DLQ + bounded retry, so a
			// transient mapping gap self-heals and a genuinely-unmappable equipment
			// stays VISIBLE in the DLQ instead of vanishing.
			return fmt.Errorf("order-created: unresolved equipment %d (mapping incomplete at replay) — DLQ for retry", p.IDEquipment)
		}
		_, err := dst.Exec(ctx, sqlInsertPOAvailable,
			eq.IDEnterprise, eq.IDSite, eq.IDArea, eq.IDEquipment, p.IDOrder.Int64(),
			p.NmProductionOrder, p.ProductionOrderQuantity.Int64(), p.TxtProductionOrderNotes)
		return failOpenIfMissing(err, "production_orders", u.ID, logger)
	}
}

type orderCreatedStartedPayload struct {
	IDOrder                 flexInt64 `json:"idOrder"`
	IDEquipment             int       `json:"idEquipment"`
	Timestamp               string    `json:"timestamp"`
	NmProductionOrder       string    `json:"nmProductionOrder"`
	ProductionOrderQuantity flexInt64 `json:"productionOrderQuantity"`
	TxtProductionOrderNotes string    `json:"txtProductionOrderNotes"`
}

func OrderCreatedStarted(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderCreatedStartedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDOrder == 0 || p.IDEquipment == 0 {
			return ErrSkip
		}
		tsStart, ok := parseTS(p.Timestamp)
		if !ok {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			// See OrderCreated: DLQ (retryable) rather than silently dropping the PO.
			return fmt.Errorf("order-created-started: unresolved equipment %d (mapping incomplete at replay) — DLQ for retry", p.IDEquipment)
		}
		if err := openRuntimeWindow(ctx, dst, eq.IDEnterprise, p.IDOrder.Int64(), eq.IDEquipment, tsStart, u.ID, logger); err != nil {
			return err
		}
		if _, err := dst.Exec(ctx, sqlInsertPORunning,
			eq.IDEnterprise, eq.IDSite, eq.IDArea, eq.IDEquipment, p.IDOrder.Int64(),
			p.NmProductionOrder, p.ProductionOrderQuantity.Int64(), p.TxtProductionOrderNotes, tsStart); err != nil {
			if e := failOpenIfMissing(err, "production_orders", u.ID, logger); e != nil {
				return e
			}
		}
		// The id_order may already exist (created earlier as AVAILABLE, possibly on
		// another line): the insert above was then a no-op — start that row.
		return startExistingPO(ctx, dst, eq, eq.IDEnterprise, p.IDOrder.Int64(), tsStart, u.ID, logger)
	}
}

type orderStartedPayload struct {
	Timestamp         string `json:"timestamp"`
	IDEquipment       int    `json:"idEquipment"`
	IDProductionOrder int64  `json:"idProductionOrder"`
}

func OrderStarted(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderStartedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return ErrSkip
		}
		tsStart, ok := parseTS(p.Timestamp)
		if !ok {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		ent := r.DstEnterprise()
		if err := execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePOStart, tsStart, ent, idOrder); err != nil {
			return err
		}
		// Open the runtime window using the PO's OWN equipment, resolved from the PO
		// record — NOT gated on the start payload's legacy equipment resolving.
		//
		// The prior code skipped openRuntimeWindow (silent `return nil`) whenever
		// r.ResolveEquipment(p.IDEquipment) missed, even though the PO already carries
		// a valid current id_equipment (set at create) and sqlOpenWindow inserts using
		// po.id_equipment anyway. That gate silently dropped the runtime window for
		// ~58% of replayed CPACK POs: they got ts_start but no runtime row, so
		// compute.go had nothing to attribute and the raw production (present in
		// silver/historian) never reached any aggregate. Resolving from the PO removes
		// the payload-equipment dependency entirely.
		var idEquipment int
		if err := dst.QueryRow(ctx, sqlPOEquipment, ent, idOrder).Scan(&idEquipment); err != nil {
			return failOpenIfMissing(err, "production_orders_runtime", u.ID, logger)
		}
		if idEquipment == 0 {
			return nil // started PO with no equipment on record — nothing to open
		}
		return openRuntimeWindow(ctx, dst, ent, idOrder, idEquipment, tsStart, u.ID, logger)
	}
}

type orderStoppedPayload struct {
	StopType                string    `json:"stopType"`
	Timestamp               string    `json:"timestamp"`
	IDProductionOrder       int64     `json:"idProductionOrder"`
	ProductionOrderQuantity flexInt64 `json:"productionOrderQuantity"`
}

func OrderStopped(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderStoppedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return ErrSkip
		}
		tsEnd, ok := parseTS(p.Timestamp)
		if !ok {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		status := 3
		if p.StopType == "pause" {
			status = 4
		}
		ent := r.DstEnterprise()
		if err := closeRuntimeWindow(ctx, dst, ent, idOrder, tsEnd, u.ID, logger); err != nil {
			return err
		}
		return execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePOStop,
			status, tsEnd, p.ProductionOrderQuantity.Int64(), ent, idOrder)
	}
}

type orderTimeChangedPayload struct {
	Start             string `json:"start"`
	IDProductionOrder int64  `json:"idProductionOrder"`
}

func OrderTimeChanged(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderTimeChangedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDProductionOrder == 0 || p.Start == "" {
			return ErrSkip
		}
		tsStart, ok := parseTS(p.Start)
		if !ok {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		return execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePOTsStart, tsStart, r.DstEnterprise(), idOrder)
	}
}

type orderRecalcPayload struct {
	IDProductionOrder int64 `json:"idProductionOrder"`
}

// OrderRecalc serves order-replaced + order-status-changed — both just flag
// the PO for runtime recomputation.
func OrderRecalc(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderRecalcPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.IDProductionOrder == 0 {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		return execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePORecalc, r.DstEnterprise(), idOrder)
	}
}

type orderChangedPayload struct {
	IDOrder         flexInt64 `json:"idOrder"`
	StopType        string    `json:"stopType"`
	Timestamp       string    `json:"timestamp"`
	IDEquipment     int       `json:"idEquipment"`
	ShouldCreatePo  bool      `json:"shouldCreatePo"`
	ShouldOpenNewPo bool      `json:"shouldOpenNewPo"`
	// IDProductionOrder: with shouldCreatePo=false it is the LEGACY surrogate of the
	// pre-existing PO being started; with shouldCreatePo=true legacy puts the new
	// id_order (as a string) here.
	IDProductionOrder           flexInt64 `json:"idProductionOrder"`
	OldIDProductionOrder        int64     `json:"oldIdProductionOrder"`
	ProductionOrderQuantity     flexInt64 `json:"productionOrderQuantity"`
	OldProductionOrderProdFinal flexInt64 `json:"oldProductionOrderProdFinal"`
}

// OrderChanged closes the old PO (by natural key from the legacy surrogate)
// and optionally opens a new one — the combined operator step.
func OrderChanged(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderChangedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		if p.OldIDProductionOrder == 0 {
			return ErrSkip
		}
		ts, ok := parseTS(p.Timestamp)
		if !ok {
			return ErrSkip
		}
		oldOrder, found, err := resolveLegacyOrder(ctx, legacy, p.OldIDProductionOrder, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve old legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		ent := r.DstEnterprise()
		status := 3
		if p.StopType == "pause" {
			status = 4
		}
		if err := closeRuntimeWindow(ctx, dst, ent, oldOrder, ts, u.ID, logger); err != nil {
			return err
		}
		if err := execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlClosePOChanged,
			status, ts, p.OldProductionOrderProdFinal.Int64(), ent, oldOrder); err != nil {
			return err
		}
		if !p.ShouldCreatePo && !p.ShouldOpenNewPo {
			return nil // finish/pause only
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			return nil
		}
		if !p.ShouldCreatePo {
			// Start a PRE-EXISTING PO (shouldOpenNewPo=true, shouldCreatePo=false):
			// resolve it by its legacy surrogate; the payload's idOrder is the fallback.
			newOrder := p.IDOrder.Int64()
			if p.IDProductionOrder > 0 {
				o, found, err := resolveLegacyOrder(ctx, legacy, p.IDProductionOrder.Int64(), r.srcEnterprise)
				if err != nil {
					return fmt.Errorf("resolve new legacy order: %w", err)
				}
				if found {
					newOrder = o
				}
			}
			if newOrder == 0 {
				return nil
			}
			return startExistingPO(ctx, dst, eq, ent, newOrder, ts, u.ID, logger)
		}
		if p.IDOrder == 0 {
			return nil
		}
		// A re-create of an id_order the twin holds as AVAILABLE on another line moves
		// it here before the window opens (else the window opens on the old line).
		if _, err := dst.Exec(ctx, sqlMoveAvailablePO, eq.IDEquipment, eq.IDSite, eq.IDArea, ent, p.IDOrder.Int64()); err != nil {
			if e := failOpenIfMissing(err, "production_orders", u.ID, logger); e != nil {
				return e
			}
		}
		if err := openRuntimeWindow(ctx, dst, ent, p.IDOrder.Int64(), eq.IDEquipment, ts, u.ID, logger); err != nil {
			return err
		}
		_, err = dst.Exec(ctx, sqlInsertPORunning,
			eq.IDEnterprise, eq.IDSite, eq.IDArea, eq.IDEquipment, p.IDOrder.Int64(),
			"", p.ProductionOrderQuantity.Int64(), "", ts)
		if err := failOpenIfMissing(err, "production_orders", u.ID, logger); err != nil {
			return err
		}
		return startExistingPO(ctx, dst, eq, ent, p.IDOrder.Int64(), ts, u.ID, logger)
	}
}

// ─── order-replaced ───
//
// Legacy edge-api "replace": the operator re-assigns the runtime that is running on
// an equipment to another PO — typically right after creating the PO with the
// right number, to fix a mistyped one (CPACK: 897159→8971590, 89511→895711,
// 896947→896974, 896799→896802), or to hand a runtime back (L8 895874→1676210).
// The runtime row changes owner; the new PO takes that runtime's span (status 2
// while it is open); the old PO is re-derived from what it has left (status 4 with
// its remaining span, or status 1 with no times when nothing is left).
//
// The replay only flagged the PO for recalc, so the new PO never got a ts_start or
// a runtime (13 CPACK POs closed with a NULL ts_start, 0 production) while the
// mistyped "ghost" kept the window, the production, and — once superseded — status
// 3 with no end.
//
// Which runtime: the legacy payload names none (the current edge-api sends
// runtimeToReplace, a LEGACY runtime id we cannot use directly), so it is the
// runtime on the equipment that was running when legacy logged the action
// (lower <= ts_log, latest). Keyed on ts_log, not "latest now", so a late replay
// or a DLQ retry can never grab a runtime that started afterwards; idempotent
// (a runtime already owned by the new PO is left alone).
type orderReplacedPayload struct {
	IDEquipment          int       `json:"idEquipment"`
	IDProductionOrder    flexInt64 `json:"idProductionOrder"`    // legacy (pre-2026-08) contract
	NewIDProductionOrder flexInt64 `json:"newIdProductionOrder"` // current edge-api contract
}

const sqlReplaceRuntime = `WITH tgt AS (
	    SELECT r.id_production_order_runtime AS rid, r.id_production_order AS src
	      FROM gold.production_orders_runtime r
	     WHERE r.id_equipment = $1 AND lower(r.runtime_timerange) <= $2
	     ORDER BY lower(r.runtime_timerange) DESC
	     LIMIT 1
	), newpo AS (
	    SELECT id_production_order AS dst FROM core.production_orders
	     WHERE id_enterprise = $3 AND id_order = $4
	)
	UPDATE gold.production_orders_runtime r
	   SET id_production_order = newpo.dst, recalc_needed = true
	  FROM tgt, newpo
	 WHERE r.id_production_order_runtime = tgt.rid AND tgt.src <> newpo.dst
	RETURNING tgt.src, newpo.dst`

// sqlRederiveReplacedPO: the old owner keeps what it has left — status 4 over its
// remaining span, or back to AVAILABLE (status 1, no times, no counters) when it
// has nothing left (edge-api production-order-database.ts replace()).
const sqlRederiveReplacedPO = `UPDATE core.production_orders po
	   SET ts_start = s.lo,
	       ts_end = CASE WHEN s.n > 0 THEN s.hi END,
	       status = CASE WHEN s.n > 0 THEN 4 ELSE 1 END,
	       gross_production = CASE WHEN s.n > 0 THEN po.gross_production END,
	       net_production = CASE WHEN s.n > 0 THEN po.net_production END,
	       recalc_needed = true, last_update = now()
	  FROM (SELECT count(*) AS n, min(lower(r.runtime_timerange)) AS lo,
	               CASE WHEN bool_or(upper(r.runtime_timerange) IS NULL) THEN NULL
	                    ELSE max(upper(r.runtime_timerange)) END AS hi
	          FROM gold.production_orders_runtime r WHERE r.id_production_order = $1) s
	 WHERE po.id_production_order = $1`

// sqlDeriveReplacingPO: the new owner spans its runtimes; running while one is open.
const sqlDeriveReplacingPO = `UPDATE core.production_orders po
	   SET ts_start = s.lo, ts_end = s.hi,
	       status = CASE WHEN s.hi IS NULL THEN 2 ELSE 3 END,
	       recalc_needed = true, last_update = now()
	  FROM (SELECT min(lower(r.runtime_timerange)) AS lo,
	               CASE WHEN bool_or(upper(r.runtime_timerange) IS NULL) THEN NULL
	                    ELSE max(upper(r.runtime_timerange)) END AS hi
	          FROM gold.production_orders_runtime r WHERE r.id_production_order = $1) s
	 WHERE po.id_production_order = $1 AND s.lo IS NOT NULL`

func OrderReplaced(logger *slog.Logger) Handler {
	return func(ctx context.Context, legacy, dst *pgxpool.Pool, r *Resolver, u *UserLog) error {
		var p orderReplacedPayload
		if err := json.Unmarshal(u.Payload, &p); err != nil {
			return ErrSkip
		}
		legacyPO := p.NewIDProductionOrder.Int64()
		if legacyPO == 0 {
			legacyPO = p.IDProductionOrder.Int64()
		}
		if legacyPO == 0 || p.IDEquipment == 0 {
			return ErrSkip
		}
		idOrder, found, err := resolveLegacyOrder(ctx, legacy, legacyPO, r.srcEnterprise)
		if err != nil {
			return fmt.Errorf("resolve legacy order: %w", err)
		}
		if !found {
			return ErrSkip
		}
		eq, ok := r.ResolveEquipment(p.IDEquipment)
		if !ok {
			return fmt.Errorf("order-replaced: unresolved equipment %d — DLQ for retry", p.IDEquipment)
		}
		at := u.TsLog
		if at.IsZero() || at.Unix() <= 0 {
			at = time.Now()
		}
		ent := r.DstEnterprise()
		tx, err := dst.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx) //nolint:errcheck // no-op after Commit
		var src, dstPO int64
		err = tx.QueryRow(ctx, sqlReplaceRuntime, eq.IDEquipment, at, ent, idOrder).Scan(&src, &dstPO)
		if errors.Is(err, pgx.ErrNoRows) {
			// nothing to move (no runtime on the equipment, PO missing, or already
			// replaced): keep the old behaviour — flag the PO for recalc.
			if err := tx.Rollback(ctx); err != nil {
				return err
			}
			return execExpectingRows(ctx, dst, "production_orders", u.ID, logger, sqlUpdatePORecalc, ent, idOrder)
		}
		if err != nil {
			return failOpenIfMissing(err, "production_orders_runtime", u.ID, logger)
		}
		// Old owner first: it may be the equipment's running PO, and the running-PO
		// unique index allows only one.
		if _, err := tx.Exec(ctx, sqlRederiveReplacedPO, src); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, sqlDeriveReplacingPO, dstPO); err != nil {
			return err
		}
		return tx.Commit(ctx)
	}
}
