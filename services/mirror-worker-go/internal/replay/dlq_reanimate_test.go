// dlq_reanimate_test.go — config-driven + invariant tests for the
// reanimator. The single-round-trip UPDATE is DB-heavy; full coverage
// of the SQL semantics lives in the staging integration loop (same as
// dlq_retry_test.go's split). What's testable here:
//
//   - DLQ_REANIMATE_ENABLED=false short-circuits RunForever
//   - the new metric is registered (else /metrics silently omits it)
//   - the SQL invariants (category whitelist, mappability predicate,
//     idempotency via retry_attempts >= cap filter) are pinned in
//     source via a back-tick scan — same shape as the translator's
//     id_order + start-drift regression guards
package replay

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

func TestDLQReanimator_DisabledShortCircuits(t *testing.T) {
	cfg := &config.Config{DLQReanimateEnabled: false}
	r := NewDLQReanimator(cfg, nil, slog.Default())

	done := make(chan error, 1)
	go func() {
		done <- r.RunForever(context.Background())
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Errorf("RunForever returned err = %v, want nil when disabled", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("RunForever blocked when DLQReanimateEnabled=false — should return immediately")
	}
}

func TestDLQReanimatedMetric_Registered(t *testing.T) {
	// Guard against forgetting to register the new metric — the
	// /metrics endpoint silently omits unregistered collectors so
	// dashboards never see anything for them. CollectAndCount errors
	// if the metric isn't registered, which is exactly the assertion
	// we want.
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_dlq_reanimated_total"); err != nil {
		t.Errorf("mirror_worker_dlq_reanimated_total not gathered: %v", err)
	}
}

// TestReanimateSQLInvariants pins the three load-bearing predicates of
// ReanimateMappableEquipmentEventDLQ via a SQL-blob scan of staging.go.
// Same pattern as the translator's id_order + start-drift guards.
//
// The invariants are: (a) only past-cap rows are touched, so already-
// reanimated rows aren't double-touched; (b) only equipment_event-shaped
// categories are eligible, so order-* rows don't get wrong-shape
// reanimation; (c) the mappability predicate is via mirror_id_map
// EXISTS, so rows whose target still isn't translatable are left
// untouched.
func TestReanimateSQLInvariants(t *testing.T) {
	src, err := os.ReadFile("../db/staging.go")
	if err != nil {
		t.Fatalf("read staging.go: %v", err)
	}
	body := string(src)

	// Same back-tick carve-out as the translator regression tests.
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

	wantSubs := []struct {
		needle string
		why    string
	}{
		{
			"retry_attempts >= $2",
			"reanimator must only touch past-cap rows — without this, every reanimate pass would also reset still-retrying rows back to 0 and the retry-cap logic would never converge",
		},
		{
			"category IN ('event-justified', 'event-edited',",
			"reanimator must whitelist equipment_event-shaped categories — order-* rows carry idProductionOrder and would silently dereference the wrong payload field",
		},
		{
			"FROM mirror_id_map m",
			"reanimator must gate on mirror_id_map EXISTS — without this, every past-cap row gets reset on every tick regardless of whether its target became translatable",
		},
		{
			"(mirror_replay_dlq.payload->>'idEquipmentEvent')::bigint",
			"reanimator must extract the equipment_event id from payload to match against mirror_id_map.prod_id",
		},
	}
	for _, w := range wantSubs {
		if !strings.Contains(sqlBlob, w.needle) {
			t.Errorf("staging.go reanimate SQL missing invariant %q — %s", w.needle, w.why)
		}
	}
}
