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
	Status      *int       // current shadow status (nil = never set)
	Duration    *int       // current shadow duration (nil = never set)
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
// recent window. Driven FROM THE SHADOW — no prod bound. Each candidate now
// carries the row's CURRENT close state (ts_end/status/duration), which the
// decision core compares against prod to skip already-correct rows.
func shadowCloseCandidates(rows []shadowRow, recentWindow time.Duration, now time.Time) []db.ShadowEventCandidate {
	cutoff := now.Add(-recentWindow)
	var out []db.ShadowEventCandidate
	for _, r := range rows {
		if r.TsEnd == nil || !r.TsEvent.Before(cutoff) {
			out = append(out, db.ShadowEventCandidate{
				ShadowEventKey: db.ShadowEventKey{IDEquipment: r.StagingEqID, TsEvent: r.TsEvent},
				TsEnd:          r.TsEnd,
				Status:         r.Status,
				Duration:       r.Duration,
			})
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
	candidates := []db.ShadowEventCandidate{
		{ShadowEventKey: db.ShadowEventKey{IDEquipment: 105, TsEvent: tsEvent}}, // OPEN on this plane
	}
	got := planCloseCorrections(candidates, reverse, prodCloseLookup(prod))
	if len(got) != 1 {
		t.Fatalf("expected a single canonical correction; got %d", len(got))
	}
	if got[0].TsEnd == nil || !got[0].TsEnd.Equal(end) {
		t.Errorf("both planes would be set to ts_end=%v, want %v", got[0].TsEnd, end)
	}
}

// ── Convergence: the task #86 fix (skip already-correct rows) ────────────
//
// These are the regression proofs for the no-op write storm. Before the fix,
// planCloseCorrections re-upserted EVERY prod-closed recent-window row every
// pass (~4230). After: a row whose current shadow state already equals prod
// yields NO correction, so a second pass over a converged shadow emits ~0.
func TestCloseSweep_AlreadyCorrect_NoCorrection(t *testing.T) {
	now := time.Now()
	tsEvent := now.Add(-2 * time.Hour) // inside the recent window (RISK-2 candidate)
	end := now.Add(-1 * time.Hour)
	reverse := map[int]int{105: 42}

	t.Run("exact match → no correction", func(t *testing.T) {
		shadow := []shadowRow{{StagingEqID: 105, TsEvent: tsEvent, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(3600)}}
		prod := []prodEvent{{ID: 1, ProdEqID: 42, TsEvent: tsEvent, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(3600)}}
		if got := sweepCorrections(shadow, prod, reverse, 72*time.Hour, now); len(got) != 0 {
			t.Fatalf("already-correct row must NOT be re-upserted (no-op storm); got %d", len(got))
		}
	})

	// Adversarial: the shadow ts_end is the SAME INSTANT as prod but decoded in
	// a different *Location (planes live in different DBs). Struct-identity (==)
	// would call these unequal and re-upsert forever; time.Equal must not.
	t.Run("same instant, different tz → no correction", func(t *testing.T) {
		endTZ := end.In(time.FixedZone("UTC+3", 3*3600))
		shadow := []shadowRow{{StagingEqID: 105, TsEvent: tsEvent, TsEnd: ptrT(endTZ), Status: ptrI(1), Duration: ptrI(3600)}}
		prod := []prodEvent{{ID: 1, ProdEqID: 42, TsEvent: tsEvent, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(3600)}}
		if got := sweepCorrections(shadow, prod, reverse, 72*time.Hour, now); len(got) != 0 {
			t.Fatalf("tz-only difference must NOT trigger a correction; got %d", len(got))
		}
	})
}

// A genuinely-diverged row still yields EXACTLY one correction — the fix must
// not over-skip. One subtest per field the fan-out writes, to prove all three
// are compared (a bug that only checked ts_end would let status/duration drift
// silently).
func TestCloseSweep_Diverged_YieldsExactlyOne(t *testing.T) {
	now := time.Now()
	tsEvent := now.Add(-2 * time.Hour)
	end := now.Add(-1 * time.Hour)
	reverse := map[int]int{105: 42}
	prodMatch := prodEvent{ID: 1, ProdEqID: 42, TsEvent: tsEvent, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(3600)}

	cases := map[string]shadowRow{
		"ts_end drift":   {StagingEqID: 105, TsEvent: tsEvent, TsEnd: ptrT(now.Add(-90 * time.Minute)), Status: ptrI(1), Duration: ptrI(3600)},
		"status drift":   {StagingEqID: 105, TsEvent: tsEvent, TsEnd: ptrT(end), Status: ptrI(9), Duration: ptrI(3600)},
		"duration drift": {StagingEqID: 105, TsEvent: tsEvent, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(7200)},
		"still open":     {StagingEqID: 105, TsEvent: tsEvent, TsEnd: nil},
	}
	for name, sr := range cases {
		t.Run(name, func(t *testing.T) {
			got := sweepCorrections([]shadowRow{sr}, []prodEvent{prodMatch}, reverse, 72*time.Hour, now)
			if len(got) != 1 {
				t.Fatalf("%s must yield exactly ONE correction; got %d", name, len(got))
			}
			if got[0].TsEnd == nil || !got[0].TsEnd.Equal(end) || got[0].Status == nil || *got[0].Status != 1 || got[0].Duration == nil || *got[0].Duration != 3600 {
				t.Errorf("%s: correction must carry prod's authoritative close; got %+v", name, got[0])
			}
		})
	}
}

// Per-plane split: the SAME natural key arrives correct on one plane and
// divergent (open) on the other. The fix must still emit exactly ONE
// correction (not two, not zero) — fixing the divergent plane while the
// FanoutEventRow re-write of the already-correct plane is idempotent — so both
// planes end equal (F2==F3).
func TestCloseSweep_PlaneSplit_OneDivergent_SingleCorrection(t *testing.T) {
	now := time.Now()
	tsEvent := now.Add(-2 * time.Hour)
	end := now.Add(-1 * time.Hour)
	reverse := map[int]int{105: 42}
	prod := []prodEvent{{ID: 1, ProdEqID: 42, TsEvent: tsEvent, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(3600)}}

	t.Run("F2 correct + F3 open → one correction", func(t *testing.T) {
		candidates := []db.ShadowEventCandidate{
			{ShadowEventKey: db.ShadowEventKey{IDEquipment: 105, TsEvent: tsEvent}, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(3600)}, // F2 already correct
			{ShadowEventKey: db.ShadowEventKey{IDEquipment: 105, TsEvent: tsEvent}},                                                          // F3 still OPEN
		}
		got := planCloseCorrections(candidates, reverse, prodCloseLookup(prod))
		if len(got) != 1 {
			t.Fatalf("one divergent plane must yield exactly ONE correction; got %d", len(got))
		}
	})

	t.Run("both planes correct → zero corrections", func(t *testing.T) {
		correct := db.ShadowEventCandidate{ShadowEventKey: db.ShadowEventKey{IDEquipment: 105, TsEvent: tsEvent}, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(3600)}
		got := planCloseCorrections([]db.ShadowEventCandidate{correct, correct}, reverse, prodCloseLookup(prod))
		if len(got) != 0 {
			t.Fatalf("both planes already correct → zero corrections (convergence); got %d", len(got))
		}
	})
}

// Whole-set convergence: a mixed backlog (some strands, most already-correct)
// yields corrections ONLY for the strands, and a SECOND pass over the now-
// converged shadow yields zero — the exact bake signature we expect in prod.
func TestCloseSweep_SecondPassConverges(t *testing.T) {
	now := time.Now()
	reverse := map[int]int{}
	var shadow []shadowRow
	var prod []prodEvent
	// 50 rows: 5 open strands (diverge), 45 already-correct (must be skipped).
	for i := 0; i < 50; i++ {
		eq := 100 + i
		reverse[eq] = 500 + i
		ts := now.Add(-time.Duration(i+1) * time.Hour)
		end := ts.Add(30 * time.Minute)
		prod = append(prod, prodEvent{ID: int64(i + 1), ProdEqID: 500 + i, TsEvent: ts, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(1800)})
		if i < 5 {
			shadow = append(shadow, shadowRow{StagingEqID: eq, TsEvent: ts, TsEnd: nil}) // OPEN strand
		} else {
			shadow = append(shadow, shadowRow{StagingEqID: eq, TsEvent: ts, TsEnd: ptrT(end), Status: ptrI(1), Duration: ptrI(1800)}) // correct
		}
	}

	first := sweepCorrections(shadow, prod, reverse, 72*time.Hour, now)
	if len(first) != 5 {
		t.Fatalf("first pass must correct exactly the 5 strands; got %d", len(first))
	}

	// Apply the corrections to the shadow (models FanoutEventRow's UPSERT),
	// then re-run: the storm is gone iff the second pass emits zero.
	byEq := make(map[int]closeCorrection, len(first))
	for _, c := range first {
		byEq[c.StagingEqID] = c
	}
	for i := range shadow {
		if c, ok := byEq[shadow[i].StagingEqID]; ok {
			shadow[i].TsEnd, shadow[i].Status, shadow[i].Duration = c.TsEnd, c.Status, c.Duration
		}
	}
	second := sweepCorrections(shadow, prod, reverse, 72*time.Hour, now)
	if len(second) != 0 {
		t.Fatalf("second pass over a converged shadow must emit ZERO (no-op storm gone); got %d", len(second))
	}
}
