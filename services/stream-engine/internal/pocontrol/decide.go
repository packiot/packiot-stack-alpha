// Package pocontrol — ADR-0010 port 10.3 slice 1: the PO lifecycle core
// (parameters 30800 start / 30801 end / 30802 resume / 30803 pause),
// ported from the captured prod nodes (docs/adr/reference/
// 0010-port-10-3-po-control-capture.txt).
//
// BEHAVIOR-CRITICAL PORT DECISIONS (each vs the nodered original):
//
//  1. SELECT-then-decide and the command statements run in ONE pgx.Tx.
//     Nodered used two round-trips through separate nodes — a race
//     window we deliberately do not port. Output-identical, safer.
//  2. Determinism fix: nodered's start-branch read `payload[0]` of a
//     UNION whose row order Postgres does not guarantee. When a PO is
//     running AND the target is startable, correctness REQUIRES the
//     running row (its po_status=2 triggers the juggle + re-dispatch).
//     We query running-PO and target-status separately — same
//     information, no ordering dependency.
//  3. Error semantics = nodered's try/catch-and-drop: a failed command
//     tx is logged + counted + DROPPED, never retried. The runtime
//     INSERT has no conflict guard — prod's replay-safety comes from
//     no-retry, so retrying here would double-insert runtime rows.
//  4. The status-4 juggle is preserved verbatim: starting over a
//     running PO first sets the target to a TEMPORARY status 4 with
//     ts_end (a partial-unique-on-running dodge), ends the previous PO
//     (re-dispatch as 30801/30803), then restores the target to
//     status 2 with ts_end=NULL.
package pocontrol

import "time"

// TargetPO statuses (production_orders.status).
const (
	StatusAvailable = 1
	StatusRunning   = 2
	StatusFinished  = 3
	StatusPaused    = 4
)

// RunningPO is the currently-running order on the equipment (if any),
// from the state query.
type RunningPO struct {
	ID      int64
	TsLower time.Time // lower(runtime_timerange) of its open runtime row
}

// StartPlan is the pure decision for 30800/30802.
type StartPlan struct {
	NoOp       bool
	TempStatus int      // status written in the main UPDATE (2, or 4 during the juggle)
	PrevStatus int      // what statement 3 sets any running PO to (3 or 4)
	Juggle     bool     // true when another PO was running
	EndPrev    *EndPlan // re-dispatched end for the previous PO (juggle only)
	RestoreID  int64    // PO to restore to status 2 / ts_end NULL after EndPrev
}

// EndPlan is the pure decision for 30801/30803 (also produced by the
// start re-dispatch).
type EndPlan struct {
	NoOp      bool
	ID        int64 // PO being ended
	NewStatus int   // 3 (end) or 4 (pause)
	TsLower   time.Time
}

// DecideStart ports the 30800/30802 branch gates. targetStatus is the
// target PO's current status; running is the open PO on the equipment
// or nil.
func DecideStart(paramID int, targetID int64, targetStatus int, running *RunningPO) StartPlan {
	if targetStatus != StatusAvailable && targetStatus != StatusPaused {
		return StartPlan{NoOp: true}
	}
	prev := StatusFinished
	endParamStatus := StatusFinished
	if paramID == 30802 {
		prev = StatusPaused
		endParamStatus = StatusPaused
	}
	p := StartPlan{TempStatus: StatusRunning, PrevStatus: prev}
	if running != nil {
		// Same PO already running = nodered's cur_status==2 case: the
		// outer gate above (1|4) already excluded it via targetStatus.
		p.TempStatus = StatusPaused // the juggle
		p.Juggle = true
		p.EndPrev = &EndPlan{ID: running.ID, NewStatus: endParamStatus, TsLower: running.TsLower}
		p.RestoreID = targetID
	}
	return p
}

// DecideEnd ports the 30801/30803 gate: only a running PO can be
// ended/paused; otherwise no-op (nodered: payload[0].po_status != 2 →
// falls through with empty SQL).
func DecideEnd(paramID int, running *RunningPO) EndPlan {
	if running == nil {
		return EndPlan{NoOp: true}
	}
	ns := StatusFinished
	if paramID == 30803 {
		ns = StatusPaused
	}
	return EndPlan{ID: running.ID, NewStatus: ns, TsLower: running.TsLower}
}
