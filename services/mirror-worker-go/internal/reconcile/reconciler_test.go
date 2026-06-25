// reconciler_test.go — covers the parts of the reconciler that are
// pure (no DB / no HTTP) plus the small helpers. End-to-end coverage
// of create+start+map lives in the staging integration loop.
package reconcile

import (
	"testing"

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

