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
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
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

func TestComparatorEventsLagSecondsMetric_Registered(t *testing.T) {
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_comparator_events_lag_seconds"); err != nil {
		t.Errorf("mirror_worker_comparator_events_lag_seconds not gathered: %v", err)
	}
}

func TestComparatorUserLogsLagMetric_Registered(t *testing.T) {
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_comparator_user_logs_lag"); err != nil {
		t.Errorf("mirror_worker_comparator_user_logs_lag not gathered: %v", err)
	}
}

func TestComparatorOEEDivergencePctMetric_Registered(t *testing.T) {
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_comparator_oee_divergence_pct"); err != nil {
		t.Errorf("mirror_worker_comparator_oee_divergence_pct not gathered: %v", err)
	}
}

func TestComparatorOEEMeasuredMetric_Registered(t *testing.T) {
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_comparator_oee_measured_total"); err != nil {
		t.Errorf("mirror_worker_comparator_oee_measured_total not gathered: %v", err)
	}
}

func TestComparatorDLQAnomalyTotalMetric_Registered(t *testing.T) {
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_comparator_dlq_anomaly_total"); err != nil {
		t.Errorf("mirror_worker_comparator_dlq_anomaly_total not gathered: %v", err)
	}
}

// TestCountAnomalies covers the pure-function set-diff logic for
// dlq_anomaly. The DB round-trips are delivery; the in-memory diff is
// the load-bearing decision: how many staging IDs aren't in prod.
func TestCountAnomalies(t *testing.T) {
	cases := []struct {
		name       string
		stagingIDs []int64
		prodExists []int64 // sugar: converted to map below
		want       int
	}{
		{
			name:       "all staging IDs present on prod → 0 anomalies",
			stagingIDs: []int64{100, 200, 300},
			prodExists: []int64{100, 200, 300},
			want:       0,
		},
		{
			name:       "one missing → 1 anomaly",
			stagingIDs: []int64{100, 200, 300},
			prodExists: []int64{100, 300}, // 200 missing
			want:       1,
		},
		{
			name:       "all missing → all anomalies",
			stagingIDs: []int64{100, 200, 300},
			prodExists: []int64{},
			want:       3,
		},
		{
			name:       "empty staging → 0 (nothing to check)",
			stagingIDs: []int64{},
			prodExists: []int64{500, 600},
			want:       0,
		},
		{
			name:       "prod has EXTRA IDs we don't probe → doesn't count (not an anomaly)",
			stagingIDs: []int64{100},
			prodExists: []int64{100, 200, 300, 400}, // 200-400 aren't in stagingIDs
			want:       0,
		},
		{
			name:       "duplicate staging IDs counted once each (caller dedupes upstream)",
			stagingIDs: []int64{100, 100, 200}, // dedup happens at DB layer; this case shouldn't occur but math is safe
			prodExists: []int64{},
			want:       3, // each occurrence is a miss; caller relies on DISTINCT in SQL
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			set := make(map[int64]struct{}, len(c.prodExists))
			for _, id := range c.prodExists {
				set[id] = struct{}{}
			}
			got := countAnomalies(c.stagingIDs, set)
			if got != c.want {
				t.Errorf("countAnomalies = %d, want %d", got, c.want)
			}
		})
	}
}

// TestComputeOEEDivergence covers the pure-function math directly — the
// per-PO skip/emit decision matters more than the wire-level DB plumbing.
// Each case names the production scenario it represents, not just the
// numerical inputs, so future readers can reason about WHY the decision
// is what it is.
func TestComputeOEEDivergence(t *testing.T) {
	fp := func(v float64) *float64 { return &v }
	cases := []struct {
		name        string
		prod        db.ProdRuntimeValues
		prodFound   bool
		stagingNet  *float64
		wantPct     float64
		wantEmit    bool
	}{
		{
			name:       "in sync — 1000 vs 1000 → 0%",
			prod:       db.ProdRuntimeValues{IDProductionOrder: 1, NetProduction: fp(1000)},
			prodFound:  true,
			stagingNet: fp(1000),
			wantPct:    0,
			wantEmit:   true,
		},
		{
			name:       "1% staging lag — 1000 vs 990 → 1%",
			prod:       db.ProdRuntimeValues{IDProductionOrder: 1, NetProduction: fp(1000)},
			prodFound:  true,
			stagingNet: fp(990),
			wantPct:    0.01,
			wantEmit:   true,
		},
		{
			name:       "staging ahead — 1000 vs 1050 → 5% (sign-agnostic, abs)",
			prod:       db.ProdRuntimeValues{IDProductionOrder: 1, NetProduction: fp(1000)},
			prodFound:  true,
			stagingNet: fp(1050),
			wantPct:    0.05,
			wantEmit:   true,
		},
		{
			name:       "freshly-started PO — prod 0 → SKIP (no denominator)",
			prod:       db.ProdRuntimeValues{IDProductionOrder: 1, NetProduction: fp(0)},
			prodFound:  true,
			stagingNet: fp(0),
			wantEmit:   false,
		},
		{
			name:       "prod row missing entirely → SKIP",
			prod:       db.ProdRuntimeValues{},
			prodFound:  false,
			stagingNet: fp(100),
			wantEmit:   false,
		},
		{
			name:       "prod NetProduction nil → SKIP (cron hasn't computed yet)",
			prod:       db.ProdRuntimeValues{IDProductionOrder: 1, NetProduction: nil},
			prodFound:  true,
			stagingNet: fp(100),
			wantEmit:   false,
		},
		{
			name:       "staging missing — 1000 vs nil → 100% (treat as 0)",
			prod:       db.ProdRuntimeValues{IDProductionOrder: 1, NetProduction: fp(1000)},
			prodFound:  true,
			stagingNet: nil,
			wantPct:    1.0,
			wantEmit:   true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			pct, ok := computeOEEDivergence(c.prod, c.prodFound, c.stagingNet)
			if ok != c.wantEmit {
				t.Fatalf("emit decision = %v, want %v", ok, c.wantEmit)
			}
			if ok && pct != c.wantPct {
				t.Errorf("pct = %v, want %v", pct, c.wantPct)
			}
		})
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
			{
				"max(ts_event)",
				fname + " MaxRecentEventTs must SELECT max(ts_event) — events_lag_seconds gauge depends on this exact aggregation; switching to min/avg would invert the lag semantics",
			},
			{
				"ts_event > now() - interval '1 hour'",
				fname + " MaxRecentEventTs MUST scope to the last hour — without the window, the query scans the full equipment_events hypertable (billion rows on prod), violating the 'cheap query' design constraint of the comparator",
			},
		}
		// DLQ anomaly only has methods on one side per file — staging has
		// DistinctDLQSourceLogIDs, prod has UserLogIDsExist. Skip the
		// invariant check for the file that doesn't carry the method.
		switch fname {
		case "../db/staging.go":
			wantSubs = append(wantSubs, struct {
				needle string
				why    string
			}{
				"SELECT DISTINCT source_log_id FROM mirror_replay_dlq WHERE source = $1",
				fname + " DistinctDLQSourceLogIDs must use DISTINCT to dedupe — the anomaly count would inflate if a single orphan source_log_id appeared on multiple DLQ rows",
			})
		case "../db/prod.go":
			wantSubs = append(wantSubs, struct {
				needle string
				why    string
			}{
				"id_user_logs = ANY($1::bigint[])",
				fname + " UserLogIDsExist must use ANY(bigint[]) batched lookup — N round-trips for N IDs would blow the comparator's query budget on prod",
			})
		}
		for _, w := range wantSubs {
			if !strings.Contains(sqlBlob, w.needle) {
				t.Errorf("%s SQL missing comparator invariant %q — %s", fname, w.needle, w.why)
			}
		}
	}

	// Prod-side has one additional invariant the staging side doesn't:
	// MaxUserLogID lives only on prod.go (the comparator reads the staging
	// cursor instead of staging's user_logs max, since the cursor is the
	// canonical "what staging has processed" value).
	prodSrc, err := os.ReadFile("../db/prod.go")
	if err != nil {
		t.Fatalf("read ../db/prod.go: %v", err)
	}
	prodBody := string(prodSrc)
	var prodSqlOnly strings.Builder
	inBT := false
	for _, ch := range prodBody {
		if ch == '`' {
			inBT = !inBT
			continue
		}
		if inBT {
			prodSqlOnly.WriteRune(ch)
		}
	}
	prodSqlBlob := prodSqlOnly.String()
	prodOnlyInvariants := []struct {
		needle string
		why    string
	}{
		{
			"COALESCE(max(id_user_logs), 0)",
			"MaxUserLogID must COALESCE max(id_user_logs) to 0 — without it, an empty user_logs table for the enterprise returns NULL and the comparator's int64 scan errors",
		},
	}
	for _, w := range prodOnlyInvariants {
		if !strings.Contains(prodSqlBlob, w.needle) {
			t.Errorf("../db/prod.go SQL missing comparator invariant %q — %s", w.needle, w.why)
		}
	}
}
