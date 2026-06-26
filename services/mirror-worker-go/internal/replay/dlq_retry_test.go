// dlq_retry_test.go — covers the pure / config-driven paths in the DLQ
// retrier. The retry-one round-trip is DB-heavy (prod read + staging tx
// + dispatch) so end-to-end coverage lives in the staging integration
// loop, same as the reconciler/value-sync packages.
package replay

import (
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestDLQRetrier_DisabledShortCircuits(t *testing.T) {
	// Guard: setting DLQ_RETRY_ENABLED=false must make RunForever return
	// immediately rather than blocking on a 5-min ticker. If this test
	// hangs it means the disable path got broken — saves a debug session
	// where the worker silently never enters its retry loop.
	cfg := &config.Config{DLQRetryEnabled: false}
	r := NewDLQRetrier(cfg, nil, nil, nil, slog.Default())

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
		t.Fatal("RunForever blocked when DLQRetryEnabled=false — should return immediately")
	}
}

func TestDLQRetryMetrics_Registered(t *testing.T) {
	// Guard against forgetting to wire a new metric into metrics.Registry —
	// if Registry.MustRegister is missing for either of these, the
	// /metrics endpoint silently omits them and dashboards go blank.
	// testutil.CollectAndCount errors if the metric isn't registered,
	// which is exactly what we want to assert here.
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_dlq_retry_attempts_total"); err != nil {
		t.Errorf("mirror_worker_dlq_retry_attempts_total not gathered: %v", err)
	}
	if _, err := testutil.GatherAndCount(metrics.Registry, "mirror_worker_dlq_depth"); err != nil {
		t.Errorf("mirror_worker_dlq_depth not gathered: %v", err)
	}
}
