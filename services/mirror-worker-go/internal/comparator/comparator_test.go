// comparator_test.go — config-driven + invariant tests for the
// comparator. The actual COUNT(*) round-trips are DB-heavy; full
// behavioural coverage lives in the staging integration loop. What's
// testable here without a live DB:
//
//   - COMPARATOR_ENABLED=false short-circuits RunForever
//   - the two new metrics are registered (else /metrics silently omits)
//   - SQL invariants pinned in source — both COUNT(*) queries scope to
//     id_enterprise + status=2, matching FetchActivePOs / ActivePOIDOrders
//
// Same pattern as dlq_reanimate_test.go — keeps the unit suite hermetic
// and fast while the wire-level behaviour is exercised by the deploy +
// post-deploy verification (see ADR-0008 phase 2a.1 PR description).
package comparator

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestComparator_DisabledShortCircuits(t *testing.T) {
	cfg := &config.Config{ComparatorEnabled: false}
	c := New(cfg, nil, nil, slog.Default())

	done := make(chan error, 1)
	go func() {
		done <- c.RunForever(context.Background())
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Errorf("RunForever returned err = %v, want nil when disabled", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("RunForever blocked when ComparatorEnabled=false — should return immediately")
	}
}

func TestComparatorActivePosDiffMetric_Registered(t *testing.T) {
	// Guard against forgetting to register the new gauge — the /metrics
	// endpoint silently omits unregistered collectors so dashboards never
	// see anything for them. Same regression guard the reanimator test
	// uses for mirror_worker_dlq_reanimated_total.
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_comparator_active_pos_diff"); err != nil {
		t.Errorf("mirror_worker_comparator_active_pos_diff not gathered: %v", err)
	}
}

func TestComparatorRunsTotalMetric_Registered(t *testing.T) {
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_comparator_runs_total"); err != nil {
		t.Errorf("mirror_worker_comparator_runs_total not gathered: %v", err)
	}
}

// TestComparatorSQLInvariants pins the load-bearing predicates of the
// CountActivePOs queries on both sides via a SQL-blob scan. Both COUNT(*)
// queries must (a) scope to id_enterprise, (b) filter to status=2 (running).
// If a future refactor changes either side without changing the other, the
// comparator silently measures the wrong thing — same shape as the
// reanimator SQL invariant guard.
func TestComparatorSQLInvariants(t *testing.T) {
	for _, fname := range []string{"../db/prod.go", "../db/staging.go"} {
		src, err := os.ReadFile(fname)
		if err != nil {
			t.Fatalf("read %s: %v", fname, err)
		}
		body := string(src)

		// Carve out only the back-ticked SQL blobs so we don't false-match
		// comments or Go identifiers that happen to contain the needles.
		var sqlOnly strings.Builder
		inBacktick := false
		for _, ch := range body {
			if ch == '`' {
				inBacktick = !inBacktick
				continue
			}
			if inBacktick {
				sqlOnly.WriteRune(ch)
			}
		}
		sqlBlob := sqlOnly.String()

		// Scope down to CountActivePOs's query specifically — find the
		// substring between its function comment and its closing query
		// would be brittle; instead assert that AMONG all SQL in the file,
		// the count query's specific shape is present.
		wantSubs := []struct {
			needle string
			why    string
		}{
			{
				"count(*) FROM production_orders",
				fname + " CountActivePOs must SELECT count(*) FROM production_orders — comparator depends on this exact shape to compare prod and staging by COUNT(*) round-trip",
			},
			{
				"WHERE id_enterprise = $1 AND status = 2",
				fname + " CountActivePOs must scope to (enterprise, status=2) — without enterprise scope the comparator would compare org-wide totals; without status=2 it would count finished/paused POs too",
			},
		}
		for _, w := range wantSubs {
			if !strings.Contains(sqlBlob, w.needle) {
				t.Errorf("%s SQL missing comparator invariant %q — %s", fname, w.needle, w.why)
			}
		}
	}
}
