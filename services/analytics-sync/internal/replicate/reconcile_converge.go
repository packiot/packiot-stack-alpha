package replicate

// Header + window CONVERGENCE (2026-10-09) — legacy is the source of truth for a
// CPACK PO's lifecycle, and the replay only ever moves the twin forward. Four
// measured drift classes (30-day compare, ent 1 vs ent 3) that nothing corrected:
//
//   - wrong START: legacy re-starts an existing PO by moving its ts_start to the new
//     start (order-changed shouldCreatePo=false after an order-replaced, or a second
//     start of the same PO); the twin keeps the FIRST start (sqlStartExistingPO's
//     COALESCE is right for a resume, wrong for these). 896799 kept 08:53 while
//     legacy ran it 19:27→03:01; its window [08:53,03:01) overlapped 896802's
//     [08:53,19:27) and was never created, so ~31k L3 net belonged to no PO.
//   - wrong END: order-time-changed carries an "end" the replay ignores (897794:
//     legacy 23:40, twin 03:29); a zombie twin PO closed months later by the next
//     start on its equipment (895499: legacy end 08-22, twin 09-30).
//   - never-started in legacy, finished/paused on the twin: legacy put the PO back
//     to AVAILABLE without a user_log (897519, 10-01 14:02), or the run happened only
//     on the twin (891336, started from the staging operator on the real tenant).
//   - windows that differ from legacy's own production_orders_runtime rows (897794,
//     896931, 897589 missing its first run, 897867 cut by the twin-only run).
//
// Rules — each one only ever moves the twin TOWARD legacy, and each is a no-op once
// equal, so a pass is idempotent and a later pass finishes what an earlier one could
// not (a window blocked by a neighbour converges once the neighbour has converged):
//
//   - retime: legacy finished (3) and twin finished (3) → header ts_start/ts_end =
//     legacy's. Header only; no recalc flag (the header is the sum of its windows —
//     when the windows change below, the engine's propagation re-flags the header).
//   - revert: legacy AVAILABLE (1) and twin finished/paused (3/4) → twin back to 1
//     with legacy's times. Re-checked against legacy right before writing, so a PO
//     that started during the pass is never reverted.
//   - windows: legacy and twin in the same SETTLED state, legacy's runtime rows
//     closed, on the twin PO's equipment and recent (upper > window start) → the
//     twin's windows become exactly legacy's (one tx; delete + insert, every insert
//     overlap-guarded against OTHER POs; any blocked insert rolls the PO back and is
//     counted). A finished legacy PO with NO runtime rows is left to the header
//     backfill; an available one with none loses the twin-only windows.

import (
	"context"
	"database/sql"
	"log/slog"
	"sort"
	"time"
)

// runRange is one runtime window; hi nil = open.
type runRange struct {
	lo time.Time
	hi *time.Time
}

// mergeRanges sorts and merges overlapping or ADJACENT ranges, so two
// representations of the same coverage compare equal (legacy keeps a run split in
// two adjacent rows where the twin holds one: 894508 [10:01,10:43)+[10:43,13:06)).
func mergeRanges(in []runRange) []runRange {
	if len(in) == 0 {
		return nil
	}
	rs := append([]runRange(nil), in...)
	sort.Slice(rs, func(i, j int) bool { return rs[i].lo.Before(rs[j].lo) })
	out := []runRange{rs[0]}
	for _, r := range rs[1:] {
		last := &out[len(out)-1]
		if last.hi == nil {
			continue // open range swallows everything after it
		}
		if !r.lo.After(*last.hi) { // overlaps or touches
			if r.hi == nil || r.hi.After(*last.hi) {
				last.hi = r.hi
			}
			continue
		}
		out = append(out, r)
	}
	return out
}

// sameCoverage: do the two sets cover exactly the same instants?
func sameCoverage(a, b []runRange) bool {
	ma, mb := mergeRanges(a), mergeRanges(b)
	if len(ma) != len(mb) {
		return false
	}
	for i := range ma {
		if !ma[i].lo.Equal(mb[i].lo) {
			return false
		}
		if (ma[i].hi == nil) != (mb[i].hi == nil) {
			return false
		}
		if ma[i].hi != nil && !ma[i].hi.Equal(*mb[i].hi) {
			return false
		}
	}
	return true
}

func sameNullTime(a, b sql.NullTime) bool {
	if a.Valid != b.Valid {
		return false
	}
	return !a.Valid || a.Time.Equal(b.Time)
}

// twinPO is the twin header the convergence rules read.
type twinPO struct {
	idProductionOrder int64
	status            int
	tsStart, tsEnd    sql.NullTime
	idEquipment       int
}

type headerFix int

const (
	headerNone headerFix = iota
	headerRetime
	headerRevertAvailable
)

// planHeader decides the header correction for one PO present on both sides.
func planHeader(l legacyPO, t twinPO) headerFix {
	switch {
	case l.status == 3 && t.status == 3:
		if !l.tsStart.Valid || !l.tsEnd.Valid || l.tsEnd.Time.Before(l.tsStart.Time) {
			return headerNone // legacy row itself unusable — never write an inverted range
		}
		if sameNullTime(l.tsStart, t.tsStart) && sameNullTime(l.tsEnd, t.tsEnd) {
			return headerNone
		}
		return headerRetime
	case l.status == 1 && (t.status == 3 || t.status == 4):
		return headerRevertAvailable
	}
	return headerNone
}

// legacyRuntime is one legacy production_orders_runtime row.
type legacyRuntime struct {
	idEquipment int // legacy id
	r           runRange
}

// planWindows decides whether the twin PO's windows must become legacy's. want is
// the target set (empty = delete all). reason is set when a rule matched but a
// precondition did not (for the pass log); act=false and reason="" mean "equal or
// not applicable".
func planWindows(l legacyPO, lrt []legacyRuntime, t twinPO, trt []runRange, since time.Time,
	resolve func(legacyEq int) (int, bool)) (want []runRange, act bool, reason string) {
	if l.status != t.status || (l.status != 1 && l.status != 3) {
		return nil, false, "" // not settled the same way on both sides (yet)
	}
	if len(lrt) == 0 {
		if l.status == 3 || len(trt) == 0 {
			return nil, false, "" // finished w/o legacy rows: the header backfill owns it
		}
		// available in legacy with no run at all: twin-only windows go — when recent.
		for _, r := range trt {
			if r.hi == nil || r.hi.After(since) {
				return nil, true, ""
			}
		}
		return nil, false, "old"
	}
	if l.status == 1 {
		return nil, false, "" // legacy available WITH runtime rows (897519): never create windows for an available PO
	}
	recent := false
	for _, lr := range lrt {
		if lr.r.hi == nil || !lr.r.hi.After(lr.r.lo) {
			return nil, false, "legacy_open_or_empty"
		}
		eq, ok := resolve(lr.idEquipment)
		if !ok || eq != t.idEquipment {
			return nil, false, "equipment_mismatch"
		}
		if lr.r.hi.After(since) {
			recent = true
		}
		want = append(want, lr.r)
	}
	if sameCoverage(want, trt) {
		return nil, false, ""
	}
	if !recent {
		return nil, false, "old"
	}
	return mergeRanges(want), true, ""
}

const sqlReconcileTwinPO = `SELECT id_production_order, status, ts_start, ts_end, COALESCE(id_equipment, 0)
	  FROM core.production_orders WHERE id_enterprise = $1 AND id_order = $2`

// sqlReconcileRetimePO: finished on both sides → legacy's times. Guarded on the
// twin still being finished and actually different (a no-op otherwise).
const sqlReconcileRetimePO = `UPDATE core.production_orders
	   SET ts_start = $1, ts_end = $2, last_update = now()
	 WHERE id_enterprise = $3 AND id_order = $4 AND status = 3
	   AND (ts_start IS DISTINCT FROM $1 OR ts_end IS DISTINCT FROM $2)`

// sqlReconcileRevertPO: legacy says AVAILABLE → the twin's run is not legacy's.
// Clears the run's sums (status-1 POs are never recomputed, so they would stay).
const sqlReconcileRevertPO = `UPDATE core.production_orders
	   SET status = 1, ts_start = $1, ts_end = $2, recalc_needed = false,
	       gross_production = NULL, net_production = NULL, last_update = now()
	 WHERE id_enterprise = $3 AND id_order = $4 AND status IN (3, 4)`

const sqlLegacyStatus = `SELECT status FROM production_orders WHERE id_enterprise = $1 AND id_order = $2`

const sqlLegacyRuntimes = `SELECT id_production_order, id_equipment, lower(runtime_timerange), upper(runtime_timerange)
	  FROM production_orders_runtime WHERE id_production_order = ANY($1::bigint[])`

const sqlTwinWindows = `SELECT lower(runtime_timerange), upper(runtime_timerange)
	  FROM gold.production_orders_runtime WHERE id_production_order = $1`

const sqlDeleteTwinWindows = `DELETE FROM gold.production_orders_runtime WHERE id_production_order = $1`

// sqlInsertConvergedWindow: overlap-guarded against every OTHER window on the
// equipment (the PO's own rows were deleted first in the same tx).
const sqlInsertConvergedWindow = `INSERT INTO gold.production_orders_runtime
	       (id_production_order, id_equipment, runtime_timerange, recalc_needed)
	SELECT $1, $2, tstzrange($3, $4), true
	 WHERE NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime x
	        WHERE x.id_equipment = $2 AND x.runtime_timerange && tstzrange($3, $4))`

type convergeStats struct {
	retimed, reverted, revertSkipped, windowsConverged, windowsBlocked, windowsSkipped int
}

// loadLegacyRuntimes fetches legacy runtime rows for the given legacy POs.
func (rc *POReconciler) loadLegacyRuntimes(ctx context.Context, ids []int64) (map[int64][]legacyRuntime, error) {
	out := map[int64][]legacyRuntime{}
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := rc.legacy.Query(ctx, sqlLegacyRuntimes, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var eq sql.NullInt64
		var lo sql.NullTime
		var hi sql.NullTime
		if err := rows.Scan(&id, &eq, &lo, &hi); err != nil {
			return nil, err
		}
		if !lo.Valid {
			continue
		}
		lr := legacyRuntime{idEquipment: int(eq.Int64), r: runRange{lo: lo.Time}}
		if hi.Valid {
			h := hi.Time
			lr.r.hi = &h
		}
		out[id] = append(out[id], lr)
	}
	return out, rows.Err()
}

func (rc *POReconciler) twin(ctx context.Context, ent int, idOrder int64) (twinPO, error) {
	var t twinPO
	err := rc.dest.QueryRow(ctx, sqlReconcileTwinPO, ent, idOrder).
		Scan(&t.idProductionOrder, &t.status, &t.tsStart, &t.tsEnd, &t.idEquipment)
	return t, err
}

// converge applies the header then window rules for one PO present on both sides.
func (rc *POReconciler) converge(ctx context.Context, ent int, p *legacyPO, lrt []legacyRuntime, since time.Time, st *convergeStats) {
	t, err := rc.twin(ctx, ent, p.idOrder)
	if err != nil {
		return
	}
	switch planHeader(*p, t) {
	case headerRetime:
		ct, e := rc.dest.Exec(ctx, sqlReconcileRetimePO, p.tsStart.Time, p.tsEnd.Time, ent, p.idOrder)
		if e != nil {
			rc.logger.Warn("PO reconcile: retime failed", slog.Int64("id_order", p.idOrder), slog.String("err", e.Error()))
		} else if ct.RowsAffected() > 0 {
			st.retimed++
		}
	case headerRevertAvailable:
		// Re-read legacy right before writing: a PO started (and even finished) during
		// this pass must never be put back to available from a stale snapshot.
		var now int
		if e := rc.legacy.QueryRow(ctx, sqlLegacyStatus, rc.cfg.SrcEnterprise, p.idOrder).Scan(&now); e != nil || now != 1 {
			st.revertSkipped++
			break
		}
		ct, e := rc.dest.Exec(ctx, sqlReconcileRevertPO, nullTimeArg(p.tsStart), nullTimeArg(p.tsEnd), ent, p.idOrder)
		if e != nil {
			rc.logger.Warn("PO reconcile: revert failed", slog.Int64("id_order", p.idOrder), slog.String("err", e.Error()))
		} else if ct.RowsAffected() > 0 {
			st.reverted++
		}
	}
	if t, err = rc.twin(ctx, ent, p.idOrder); err != nil {
		return
	}
	trt, err := rc.twinWindows(ctx, t.idProductionOrder)
	if err != nil {
		return
	}
	resolve := func(legacyEq int) (int, bool) {
		eq, ok := rc.r.ResolveEquipment(legacyEq)
		return eq.IDEquipment, ok
	}
	want, act, reason := planWindows(*p, lrt, t, trt, since, resolve)
	if !act {
		if reason != "" {
			st.windowsSkipped++
			rc.logger.Debug("PO reconcile: windows differ, not converged",
				slog.Int64("id_order", p.idOrder), slog.String("reason", reason))
		}
		return
	}
	if ok := rc.applyWindows(ctx, t, want); ok {
		st.windowsConverged++
	} else {
		st.windowsBlocked++
		rc.logger.Info("PO reconcile: window convergence blocked by a neighbour",
			slog.Int64("id_order", p.idOrder))
	}
}

func (rc *POReconciler) twinWindows(ctx context.Context, idPO int64) ([]runRange, error) {
	rows, err := rc.dest.Query(ctx, sqlTwinWindows, idPO)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []runRange
	for rows.Next() {
		var lo, hi sql.NullTime
		if err := rows.Scan(&lo, &hi); err != nil {
			return nil, err
		}
		r := runRange{lo: lo.Time}
		if hi.Valid {
			h := hi.Time
			r.hi = &h
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// applyWindows replaces the PO's windows with want in one transaction; false (and
// nothing changed) when any target window overlaps another PO's window.
func (rc *POReconciler) applyWindows(ctx context.Context, t twinPO, want []runRange) bool {
	tx, err := rc.dest.Begin(ctx)
	if err != nil {
		return false
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after Commit
	if _, err := tx.Exec(ctx, sqlDeleteTwinWindows, t.idProductionOrder); err != nil {
		return false
	}
	for _, w := range want {
		var hi any
		if w.hi != nil {
			hi = *w.hi
		}
		ct, err := tx.Exec(ctx, sqlInsertConvergedWindow, t.idProductionOrder, t.idEquipment, w.lo, hi)
		if err != nil || ct.RowsAffected() == 0 {
			return false
		}
	}
	return tx.Commit(ctx) == nil
}
