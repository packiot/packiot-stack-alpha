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

// An orphan: staging thinks id_order=7 is running (mirror-managed), but prod
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

// Widen (task #48 follow-up): a user_logs-REPLAYED mirror PO (mirror_id_map
// source_log_id != 0) now shares the candidate universe with reconciler-created
// POs. The origin distinction lives entirely in the ReconcileActivePOIDOrders
// SQL predicate (now source_log_id-agnostic); once a PO is in reconcileActive,
// computeOrphans treats it identically. So a replayed-origin CPACK PO absent
// from prod-active surfaces as an orphan and is finished. Modelled here by a
// mirror-managed PO in the map that prod no longer has active.
func TestComputeOrphans_ReplayedOriginOrphan_Finished(t *testing.T) {
	// id_order=42 stands in for a replayed (source_log_id != 0) mirror PO the
	// widened staging query now includes. prod has ended it (not in prodActive).
	reconcileActive := map[int64]int64{42: 9042}
	prodActive := []db.ProdActivePO{} // prod ended it via a user_logs-bypassing stop
	orphans := computeOrphans(reconcileActive, prodActive)
	if len(orphans) != 1 || orphans[0].IDOrder != 42 || orphans[0].StagingPOID != 9042 {
		t.Fatalf("expected replayed-origin id_order=42 as orphan, got %+v", orphans)
	}
	// And it clears the decision ladder (finished on prod, activity outside grace).
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	grace := now.Add(-30 * time.Minute)
	info := db.ProdPOFinishInfo{Status: 3, LastActivity: now.Add(-2 * time.Hour), HasActivity: true}
	if got := finisherDecision(info, true, grace); got != outcomeFinish {
		t.Errorf("expected replayed-origin orphan to finish, got %q", got)
	}
}

// Enterprise scope is the load-bearing safety guarantee for the widen. A PO in
// a no-prod-authority enterprise (simulator ent 2, Incoplast ent 4, staging
// ent 1) has no prod-active set to diff against, so "staging status=2 minus
// prod-active" would wrongly finish ALL of them IF it ever saw them. It never
// does: ReconcileActivePOIDOrders hard-filters id_enterprise = StagingEnterpriseID
// (the CPACK mirror target) AND m.source = the CPACK source, so such a PO is
// absent from reconcileActive by construction — never a candidate regardless of
// origin. Modelled here by its absence from the map even though prod-active is
// empty (which would otherwise make everything an orphan).
func TestComputeOrphans_NoProdAuthorityPO_NeverACandidate(t *testing.T) {
	// Only the CPACK-mirror-enterprise, mirror-managed id_order=7 is in the map.
	// A simulator/Incoplast PO (different enterprise, no mirror_id_map row) is
	// excluded upstream by the SQL scope and thus never appears here.
	reconcileActive := map[int64]int64{7: 9007}
	prodActive := []db.ProdActivePO{} // empty: no prod-active set at all
	orphans := computeOrphans(reconcileActive, prodActive)
	if len(orphans) != 1 || orphans[0].IDOrder != 7 {
		t.Fatalf("expected only the mirror-managed CPACK id_order=7, got %+v", orphans)
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
