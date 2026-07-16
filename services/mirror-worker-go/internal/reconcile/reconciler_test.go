// reconciler_test.go — covers the parts of the reconciler that are
// pure (no DB / no HTTP) plus the small helpers. End-to-end coverage
// of create+start+map lives in the staging integration loop.
package reconcile

import (
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
)

func TestDiffMissing_PreservesOrderByIDOrder(t *testing.T) {
	prod := []db.ProdActivePO{
		{IDProductionOrder: 100, IDOrder: 3},
		{IDProductionOrder: 101, IDOrder: 1},
		{IDProductionOrder: 102, IDOrder: 2},
	}
	staging := map[int64]int64{
		2: 9002, // staging has id_order=2 active
	}
	missing := computeMissing(prod, staging)
	if len(missing) != 2 {
		t.Fatalf("expected 2 missing, got %d", len(missing))
	}
	if missing[0].IDOrder != 1 || missing[1].IDOrder != 3 {
		t.Errorf("expected sorted id_orders [1,3], got [%d,%d]", missing[0].IDOrder, missing[1].IDOrder)
	}
}

func TestDiffMissing_AllPresent(t *testing.T) {
	prod := []db.ProdActivePO{
		{IDProductionOrder: 100, IDOrder: 1},
		{IDProductionOrder: 101, IDOrder: 2},
	}
	staging := map[int64]int64{1: 9001, 2: 9002}
	if len(computeMissing(prod, staging)) != 0 {
		t.Error("expected zero missing when staging is in sync")
	}
}

func TestDiffMissing_ProdEmpty(t *testing.T) {
	if len(computeMissing(nil, map[int64]int64{1: 1})) != 0 {
		t.Error("expected zero missing when prod has no active POs")
	}
}

// ──── Finisher (task #48) ──────────────────────────────────────────────────

// An orphan: staging thinks id_order=7 is running (reconcile-origin), but prod
// no longer has it in its status=2 set → it must surface as a candidate.
func TestComputeOrphans_DetectsOrphan(t *testing.T) {
	reconcileActive := map[int64]int64{
		5: 9005, // still active on prod (see prodActive) → NOT an orphan
		7: 9007, // gone from prod status=2 → orphan
	}
	prodActive := []db.ProdActivePO{
		{IDProductionOrder: 105, IDOrder: 5},
	}
	orphans := computeOrphans(reconcileActive, prodActive)
	if len(orphans) != 1 {
		t.Fatalf("expected 1 orphan, got %d", len(orphans))
	}
	if orphans[0].IDOrder != 7 || orphans[0].StagingPOID != 9007 {
		t.Errorf("expected orphan id_order=7 staging_po=9007, got id_order=%d staging_po=%d",
			orphans[0].IDOrder, orphans[0].StagingPOID)
	}
}

// Safety layer 1: a legitimately-running PO (still in prod's status=2 set) is
// excluded from candidates entirely — it can never become a finish target.
func TestComputeOrphans_RunningPO_Untouched(t *testing.T) {
	reconcileActive := map[int64]int64{5: 9005}
	prodActive := []db.ProdActivePO{{IDProductionOrder: 105, IDOrder: 5}}
	if got := computeOrphans(reconcileActive, prodActive); len(got) != 0 {
		t.Errorf("expected running PO excluded, got %d candidates", len(got))
	}
}

// computeOrphans only ever receives the reconcile-origin active set (the
// ReconcileActivePOIDOrders SQL filter). A non-reconcile PO never enters the
// map, so it can never be a candidate — modelled here by its absence.
func TestComputeOrphans_NonReconcilePO_NotACandidate(t *testing.T) {
	// id_order=99 is a simulator PO — it is NOT in reconcileActive because the
	// staging query excludes it. Only reconcile-origin id_order=7 is present.
	reconcileActive := map[int64]int64{7: 9007}
	prodActive := []db.ProdActivePO{} // nothing active on prod
	orphans := computeOrphans(reconcileActive, prodActive)
	if len(orphans) != 1 || orphans[0].IDOrder != 7 {
		t.Fatalf("expected only reconcile-origin id_order=7 as candidate, got %+v", orphans)
	}
}

func TestComputeOrphans_SortedByIDOrder(t *testing.T) {
	reconcileActive := map[int64]int64{9: 9009, 3: 9003, 6: 9006}
	orphans := computeOrphans(reconcileActive, nil)
	if len(orphans) != 3 || orphans[0].IDOrder != 3 || orphans[1].IDOrder != 6 || orphans[2].IDOrder != 9 {
		t.Errorf("expected sorted [3,6,9], got %+v", orphans)
	}
}

func TestFinisherDecision(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	grace := now.Add(-30 * time.Minute) // graceCutoff

	oldActivity := now.Add(-2 * time.Hour)      // safely before the grace cutoff
	recentActivity := now.Add(-5 * time.Minute) // inside the grace window

	cases := []struct {
		name    string
		info    db.ProdPOFinishInfo
		present bool
		want    finisherOutcome
	}{
		{
			name:    "orphan finished at last-activity ts",
			info:    db.ProdPOFinishInfo{Status: 3, LastActivity: oldActivity, HasActivity: true},
			present: true,
			want:    outcomeFinish,
		},
		{
			name:    "still active on prod (race) is skipped",
			info:    db.ProdPOFinishInfo{Status: 2, LastActivity: oldActivity, HasActivity: true},
			present: true,
			want:    outcomeSkipStillActive,
		},
		{
			name:    "grace-window PO is skipped",
			info:    db.ProdPOFinishInfo{Status: 3, LastActivity: recentActivity, HasActivity: true},
			present: true,
			want:    outcomeSkipGrace,
		},
		{
			name:    "no last-activity ts is skipped",
			info:    db.ProdPOFinishInfo{Status: 3, HasActivity: false},
			present: true,
			want:    outcomeSkipNoActivity,
		},
		{
			name:    "prod has no row (unverifiable) is skipped",
			info:    db.ProdPOFinishInfo{},
			present: false,
			want:    outcomeSkipUnverified,
		},
		{
			name:    "paused-on-prod orphan finishes (status!=2, old activity)",
			info:    db.ProdPOFinishInfo{Status: 4, LastActivity: oldActivity, HasActivity: true},
			present: true,
			want:    outcomeFinish,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := finisherDecision(c.info, c.present, grace)
			if got != c.want {
				t.Errorf("finisherDecision = %q, want %q", got, c.want)
			}
		})
	}
}

func TestTruncate(t *testing.T) {
	cases := []struct {
		name string
		in   string
		n    int
		want string
	}{
		{"short stays short", "abc", 100, "abc"},
		{"long truncates", "abcdefghij", 4, "abcd...[truncated]"},
		{"exact length stays", "abcd", 4, "abcd"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := truncate([]byte(c.in), c.n)
			if got != c.want {
				t.Errorf("truncate(%q, %d) = %q, want %q", c.in, c.n, got, c.want)
			}
		})
	}
}
