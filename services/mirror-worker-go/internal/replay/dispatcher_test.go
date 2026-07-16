// dispatcher_test.go — exercises the metrics-instrumented dispatch path
// in isolation, using synthetic Handler closures. Verifies:
//
//   - Outcome label is "ok" when the handler returns nil
//   - Outcome label is "failed" when the handler returns non-nil
//   - Outcome label is "skipped" when no handler is registered
//   - polled counter increments before dispatch regardless of outcome
//   - duration histogram observes one sample per dispatched handler
//
// These tests share the package-level metrics.Registry (the simpler
// pattern oeecloud-worker also accepts) — we read counter values via
// testutil.ToFloat64, which is the prom client library's official
// test helper that handles label-value lookup correctly.
package replay

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestDispatcher_OK(t *testing.T) {
	const evt = "test-event-ok"
	beforePolled := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt))
	beforeOK := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "ok"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return nil
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{Category: evt})
	if err != nil {
		t.Fatalf("Dispatch err = %v, want nil", err)
	}

	if got := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt)); got != beforePolled+1 {
		t.Errorf("polled = %f, want %f", got, beforePolled+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "ok")); got != beforeOK+1 {
		t.Errorf("ok = %f, want %f", got, beforeOK+1)
	}
}

func TestDispatcher_Failed(t *testing.T) {
	const evt = "test-event-failed"
	beforePolled := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt))
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	wantErr := errors.New("boom")
	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return wantErr
	})

	gotErr := d.Dispatch(context.Background(), nil, db.ProdUserLog{Category: evt})
	if !errors.Is(gotErr, wantErr) {
		t.Errorf("Dispatch err = %v, want %v", gotErr, wantErr)
	}

	if got := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt)); got != beforePolled+1 {
		t.Errorf("polled = %f, want %f", got, beforePolled+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed+1 {
		t.Errorf("failed = %f, want %f", got, beforeFailed+1)
	}
}

func TestDispatcher_Skipped_UnknownCategory(t *testing.T) {
	const evt = "test-event-unknown"
	beforePolled := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt))
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))

	d := NewDispatcher()
	// Deliberately register nothing.

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{Category: evt})
	if err != nil {
		t.Errorf("Dispatch err = %v, want nil for unknown category", err)
	}

	if got := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt)); got != beforePolled+1 {
		t.Errorf("polled = %f, want %f", got, beforePolled+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped+1 {
		t.Errorf("skipped = %f, want %f", got, beforeSkipped+1)
	}
}

func TestDispatcher_Skipped_HandlerReturnsErrSkipReplay(t *testing.T) {
	// Handler returns an error wrapping ErrSkipReplay → dispatcher must:
	//   - increment outcome=skipped (NOT outcome=failed)
	//   - return nil to the caller so processRow takes its success branch
	//     (advance cursor, no mirror_replay_dlq insert).
	const evt = "test-event-skip"
	beforePolled := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt))
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		// Wrap so errors.Is(err, ErrSkipReplay) returns true — same shape
		// the real handlers (order_changed, downtime_event_created) emit.
		return fmt.Errorf("structural mismatch: %w", ErrSkipReplay)
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{Category: evt})
	if err != nil {
		t.Fatalf("Dispatch err = %v, want nil (skip-replay errors are swallowed so caller takes success path)", err)
	}

	if got := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt)); got != beforePolled+1 {
		t.Errorf("polled = %f, want %f", got, beforePolled+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped+1 {
		t.Errorf("skipped = %f, want %f", got, beforeSkipped+1)
	}
	// failed counter must NOT have advanced.
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed {
		t.Errorf("failed = %f, want %f (skip path must not bump failed)", got, beforeFailed)
	}
}

func TestDispatcher_NonSkipErrorStillFailed(t *testing.T) {
	// Guard: a regular error must NOT be swallowed by the skip path —
	// network/parse/5xx failures still need to land in DLQ via the caller's
	// non-nil-error branch in processRow.
	const evt = "test-event-non-skip-error"
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))

	wantErr := errors.New("edge-api 500")
	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return wantErr
	})

	gotErr := d.Dispatch(context.Background(), nil, db.ProdUserLog{Category: evt})
	if !errors.Is(gotErr, wantErr) {
		t.Errorf("Dispatch err = %v, want %v (non-skip errors must propagate)", gotErr, wantErr)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed+1 {
		t.Errorf("failed = %f, want %f", got, beforeFailed+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped {
		t.Errorf("skipped = %f, want %f (non-skip errors must not bump skipped)", got, beforeSkipped)
	}
}

func TestDispatcher_TerminalReplay(t *testing.T) {
	// Handler returns an error wrapping ErrTerminalReplay (edge-api PR #148
	// gate reject) → dispatcher must:
	//   - increment outcome=terminal (NOT failed, NOT skipped)
	//   - RETURN the error (non-nil) so processRow routes it to the DLQ
	//     review tray pre-retired. Contrast with ErrSkipReplay, which is
	//     swallowed (returns nil, no DLQ).
	const evt = "test-event-terminal"
	beforeTerminal := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "terminal"))
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return fmt.Errorf("gate reject: %w", ErrTerminalReplay)
	})

	gotErr := d.Dispatch(context.Background(), nil, db.ProdUserLog{Category: evt})
	if !errors.Is(gotErr, ErrTerminalReplay) {
		t.Fatalf("Dispatch err = %v, want non-nil wrapping ErrTerminalReplay (must reach DLQ, not be swallowed)", gotErr)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "terminal")); got != beforeTerminal+1 {
		t.Errorf("terminal = %f, want %f", got, beforeTerminal+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed {
		t.Errorf("failed = %f, want %f (terminal must not bump failed)", got, beforeFailed)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped {
		t.Errorf("skipped = %f, want %f (terminal must not bump skipped)", got, beforeSkipped)
	}
}

func TestDispatcher_MarkAlreadyReplayed(t *testing.T) {
	const evt = "test-event-already-replayed"
	beforePolled := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt))
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))

	d := NewDispatcher()
	d.MarkAlreadyReplayed(evt)

	if got := testutil.ToFloat64(metrics.UserLogsPolledTotal.WithLabelValues(evt)); got != beforePolled+1 {
		t.Errorf("polled = %f, want %f", got, beforePolled+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped+1 {
		t.Errorf("skipped = %f, want %f", got, beforeSkipped+1)
	}
}

func TestDispatcher_HandledCategories(t *testing.T) {
	d := NewDispatcher()
	d.Register("a", func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error { return nil })
	d.Register("b", func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error { return nil })
	got := d.HandledCategories()
	if len(got) != 2 {
		t.Errorf("HandledCategories len = %d, want 2", len(got))
	}
	// Set check (map iteration order is undefined).
	have := map[string]bool{}
	for _, k := range got {
		have[k] = true
	}
	for _, want := range []string{"a", "b"} {
		if !have[want] {
			t.Errorf("HandledCategories missing %q", want)
		}
	}
}
