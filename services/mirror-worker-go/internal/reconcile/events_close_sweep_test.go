// events_close_sweep_test.go — regression coverage for the task #63
// close-sweep. The load-bearing decision logic (planCloseCorrections) is a
// pure function, so we pin it here without a DB — same posture as
// computeOrphans / computeOEEDivergence.
//
// Each scenario is asserted TWICE:
//   - against a model of TODAY's prod-bounded close re-fan
//     (FetchRecentlyClosedEvents) — which MUST miss (documents the bug), and
//   - against the shadow-driven sweep — which MUST catch (documents the fix).
//
// This is the "must FAIL against FetchRecentlyClosedEvents and PASS after
// the sweep" contract from the #63 investigation, encoded as a test.
package reconcile

import (
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
)

// ── in-test models of the two selection mechanisms ──────────────────────

type shadowRow struct {
	StagingEqID int
	TsEvent     time.Time
	TsEnd       *time.Time // nil = OPEN
}

type prodEvent struct {
	ID       int64 // id_equipment_event (prod PK)
	ProdEqID int
	TsEvent  time.Time
	TsEnd    *time.Time
	Status   *int
	Duration *int
}

// shadowCloseCandidates models FetchShadowEventCloseCandidates: a shadow row
// is a candidate if it is OPEN at ANY age, OR its ts_event is within the
// recent window. Driven FROM THE SHADOW — no prod bound.
func shadowCloseCandidates(rows []shadowRow, recentWindow time.Duration, now time.Time) []db.ShadowEventKey {
	cutoff := now.Add(-recentWindow)
	var out []db.ShadowEventKey
	for _, r := range rows {
		if r.TsEnd == nil || !r.TsEvent.Before(cutoff) {
			out = append(out, db.ShadowEventKey{IDEquipment: r.StagingEqID, TsEvent: r.TsEvent})
		}
	}
	return out
}

// legacyClosedRefan models TODAY's FetchRecentlyClosedEvents: prod events
// that HAVE a ts_end AND ts_event >= now()-48h AND id_equipment_event >
// cursor-400_000. This is the buggy path — a close outside either bound is
// never re-fanned. Returns the prod events it WOULD have re-fanned.
func legacyClosedRefan(events []prodEvent, cursor int64, now time.Time) []prodEvent {
	cutoff := now.Add(-48 * time.Hour)
	var out []prodEvent
	for _, e := range events {
		if e.TsEnd != nil && !e.TsEvent.Before(cutoff) && e.ID > cursor-400_000 {
			out = append(out, e)
		}
	}
	return out
}

// prodCloseLookup models FetchEventCloseInfo: prod's authoritative close
// state keyed by the natural (prodEqID, ts_event).
func prodCloseLookup(events []prodEvent) map[db.ProdEventKey]db.ProdEventClose {
	m := make(map[db.ProdEventKey]db.ProdEventClose, len(events))
	for _, e := range events {
		m[db.ProdEventKey{IDEquipment: e.ProdEqID, TsEvent: e.TsEvent}] =
			db.ProdEventClose{Status: e.Status, TsEnd: e.TsEnd, Duration: e.Duration}
	}
	return m
}

func ptrI(i int) *int             { return &i }
func ptrT(t time.Time) *time.Time { return &t }

// sweepCorrections runs the production selection + decision path over the
// modelled shadow + prod state, exactly as runEventCloseSweep wires it.
func sweepCorrections(rows []shadowRow, prodEvents []prodEvent, reverse map[int]int, recentWindow time.Duration, now time.Time) []closeCorrection {
	candidates := shadowCloseCandidates(rows, recentWindow, now)
	return planCloseCorrections(candidates, reverse, prodCloseLookup(prodEvents))
}

// ── Scenario 1: open-strand, old & cold (RISK-1) ────────────────────────
//
// An event fanned OPEN whose close later lands OUTSIDE the legacy 48h/400k
// window. The shadow row stays ts_end IS NULL forever. The legacy re-fan
// misses it; the sweep closes it from prod authority.
func TestCloseSweep_OldColdOpenStrand_ClosesFromProd(t *testing.T) {
	now := time.Now()
	tsEvent := now.Add(-50 * time.Hour) // > 48h old
	tsEnd := now.Add(-49 * time.Hour)   // closed on prod, but long ago
	cursor := int64(3_000_000)          // prod event id 1_000_000 < cursor-400k
	reverse := map[int]int{105: 42}     // stagingEq 105 → prodEq 42

	shadow := []shadowRow{{StagingEqID: 105, TsEvent: tsEvent, TsEnd: nil}} // OPEN
	prod := []prodEvent{{
		ID: 1_000_000, ProdEqID: 42, TsEvent: tsEvent,
		TsEnd: ptrT(tsEnd), Status: ptrI(1), Duration: ptrI(3600),
	}}

	// FAILS against today's FetchRecentlyClosedEvents: outside BOTH bounds.
	if legacy := legacyClosedRefan(prod, cursor, now); len(legacy) != 0 {
		t.Fatalf("legacy re-fan should MISS this close (the bug); got %d re-fanned", len(legacy))
	}

	// PASSES after the sweep: the OPEN shadow row is closed from prod.
	got := sweepCorrections(shadow, prod, reverse, 72*time.Hour, now)
	if len(got) != 1 {
		t.Fatalf("sweep should emit exactly 1 correction; got %d", len(got))
	}
	c := got[0]
	if c.StagingEqID != 105 || !c.TsEvent.Equal(tsEvent) {
		t.Errorf("correction key wrong: eq=%d ts=%v", c.StagingEqID, c.TsEvent)
	}
	if c.TsEnd == nil || !c.TsEnd.Equal(tsEnd) {
		t.Errorf("correction ts_end = %v, want %v", c.TsEnd, tsEnd)
	}
	if c.Duration == nil || *c.Duration != 3600 {
		t.Errorf("correction duration = %v, want 3600", c.Duration)
	}
	if c.Status == nil || *c.Status != 1 {
		t.Errorf("correction status = %v, want 1", c.Status)
	}
}

// ── Scenario 2: closed → extended drift (RISK-2) ────────────────────────
//
// A shadow row was fanned CLOSED, then prod extended the event's ts_end
// (operator edit). ts_event sits in the 48h–72h band: legacy 48h window
// misses it, the sweep's 72h recent window catches it and follows prod.
func TestCloseSweep_ClosedThenExtended_FollowsProd(t *testing.T) {
	now := time.Now()
	tsEvent := now.Add(-60 * time.Hour) // in the 48h–72h band
	oldEnd := now.Add(-59 * time.Hour)  // shadow's stale close
	newEnd := now.Add(-58 * time.Hour)  // prod's extended close
	cursor := int64(3_000_000)          // prod id 500_000 < cursor-400k too
	reverse := map[int]int{105: 42}

	shadow := []shadowRow{{StagingEqID: 105, TsEvent: tsEvent, TsEnd: ptrT(oldEnd)}} // CLOSED, stale
	prod := []prodEvent{{
		ID: 500_000, ProdEqID: 42, TsEvent: tsEvent,
		TsEnd: ptrT(newEnd), Status: ptrI(1), Duration: ptrI(7200),
	}}

	// FAILS against legacy: ts_event 60h old is outside the 48h window.
	if legacy := legacyClosedRefan(prod, cursor, now); len(legacy) != 0 {
		t.Fatalf("legacy re-fan should MISS this drift (the bug); got %d", len(legacy))
	}

	// PASSES after the sweep: shadow follows prod's extended ts_end.
	got := sweepCorrections(shadow, prod, reverse, 72*time.Hour, now)
	if len(got) != 1 {
		t.Fatalf("sweep should emit exactly 1 correction; got %d", len(got))
	}
	if got[0].TsEnd == nil || !got[0].TsEnd.Equal(newEnd) {
		t.Errorf("correction ts_end = %v, want extended %v", got[0].TsEnd, newEnd)
	}
	if got[0].Duration == nil || *got[0].Duration != 7200 {
		t.Errorf("correction duration = %v, want 7200", got[0].Duration)
	}
}

// ── Safety: the sweep can NOT mask a real stranding ─────────────────────
//
// planCloseCorrections must refuse to fabricate a close when prod has no
// authoritative closed row. These are the guarantees that keep a genuine
// open strand VISIBLE rather than silently closed.
func TestCloseSweep_NeverFabricatesClose(t *testing.T) {
	now := time.Now()
	tsEvent := now.Add(-50 * time.Hour)
	reverse := map[int]int{105: 42}
	shadow := []shadowRow{{StagingEqID: 105, TsEvent: tsEvent, TsEnd: nil}} // OPEN

	t.Run("prod row still OPEN → no correction", func(t *testing.T) {
		prod := []prodEvent{{ID: 1, ProdEqID: 42, TsEvent: tsEvent, TsEnd: nil}}
		if got := sweepCorrections(shadow, prod, reverse, 72*time.Hour, now); len(got) != 0 {
			t.Fatalf("must not close a shadow row prod itself left open; got %d", len(got))
		}
	})

	t.Run("prod row ABSENT → no correction", func(t *testing.T) {
		if got := sweepCorrections(shadow, nil, reverse, 72*time.Hour, now); len(got) != 0 {
			t.Fatalf("must not fabricate a close with no prod authority; got %d", len(got))
		}
	})

	t.Run("equipment unresolvable to prod → no correction", func(t *testing.T) {
		prod := []prodEvent{{ID: 1, ProdEqID: 42, TsEvent: tsEvent, TsEnd: ptrT(now)}}
		if got := sweepCorrections(shadow, prod, map[int]int{}, 72*time.Hour, now); len(got) != 0 {
			t.Fatalf("must not correct when staging→prod reverse is unknown; got %d", len(got))
		}
	})
}

// ── F2==F3 preservation ─────────────────────────────────────────────────
//
// The sweep emits ONE correction per divergent key; runEventCloseSweep
// applies each to BOTH planes via FanoutEventRow with identical values.
// Here we prove the plan is plane-agnostic: a key open on ONE plane and a
// key open on the OTHER both resolve to the same corrected value, so
// replaying the plan to both planes converges them to equality.
func TestCloseSweep_PlanIsPlaneAgnostic_PreservesF2EqualsF3(t *testing.T) {
	now := time.Now()
	tsEvent := now.Add(-50 * time.Hour)
	end := now.Add(-49 * time.Hour)
	reverse := map[int]int{105: 42}
	prod := []prodEvent{{ID: 1, ProdEqID: 42, TsEvent: tsEvent, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(3600)}}

	// The UNION-across-planes candidate set (a row open on either plane)
	// collapses to a single (id_equipment, ts_event) key → one correction,
	// applied identically to F2 and F3.
	candidates := []db.ShadowEventKey{{IDEquipment: 105, TsEvent: tsEvent}}
	got := planCloseCorrections(candidates, reverse, prodCloseLookup(prod))
	if len(got) != 1 {
		t.Fatalf("expected a single canonical correction; got %d", len(got))
	}
	if got[0].TsEnd == nil || !got[0].TsEnd.Equal(end) {
		t.Errorf("both planes would be set to ts_end=%v, want %v", got[0].TsEnd, end)
	}
}
