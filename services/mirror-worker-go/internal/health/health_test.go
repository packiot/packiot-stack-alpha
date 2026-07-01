// Unit tests for the extended /health snapshot. Focused on the ADR-0011 P0-4
// additions (cursor, dlqDepth, reason) — the pre-existing status logic already
// worked; new tests cover the extension boundary.

package health

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// testLogger returns a slog logger writing to stderr — captured by go test
// but doesn't pollute the pass output.
func testLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.NewTextHandler(os.Stderr, nil))
}

// newFast builds a State with a 1-second poll interval so tests can trigger
// the "degraded/unhealthy" thresholds in milliseconds without sleeping for
// the production 10-30s cadence.
func newFast(t *testing.T) *State {
	t.Helper()
	return NewState("test-source", 1) // poll interval = 1 sec = 1000 ms
}

func TestSnapshotWarmupIsHealthy(t *testing.T) {
	s := newFast(t)
	// No RecordTickSuccess yet — startup phase
	b := s.snapshot(context.Background())
	if b.Status != "healthy" {
		t.Errorf("warmup should be healthy, got %q", b.Status)
	}
	if b.Reason != "" {
		t.Errorf("warmup should have no reason, got %q", b.Reason)
	}
}

func TestSnapshotHealthyAfterRecentTick(t *testing.T) {
	s := newFast(t)
	s.RecordTickSuccess()
	b := s.snapshot(context.Background())
	if b.Status != "healthy" {
		t.Errorf("recent tick should be healthy, got %q reason=%q", b.Status, b.Reason)
	}
	if b.LastTickMs > 100 { // should be single-digit ms
		t.Errorf("LastTickMs should be tiny, got %d", b.LastTickMs)
	}
}

func TestSnapshotDegradedOnLastError(t *testing.T) {
	s := newFast(t)
	s.RecordTickError(fmt.Errorf("broker unreachable"))
	b := s.snapshot(context.Background())
	if b.Status != "degraded" {
		t.Errorf("error should degrade, got %q", b.Status)
	}
	if !strings.Contains(b.Reason, "broker unreachable") {
		t.Errorf("reason should include error text, got %q", b.Reason)
	}
	// Body's LastError also populated
	if b.LastError != "broker unreachable" {
		t.Errorf("LastError should be preserved for dashboards, got %q", b.LastError)
	}
}

func TestSnapshotIncludesCursorFromCallback(t *testing.T) {
	s := newFast(t)
	s.WithCursor(func(ctx context.Context) (int64, error) {
		return 12345, nil
	})
	s.RecordTickSuccess()
	b := s.snapshot(context.Background())
	if b.Cursor != 12345 {
		t.Errorf("cursor from callback: got %d, want 12345", b.Cursor)
	}
}

func TestSnapshotIncludesDLQDepthFromCallback(t *testing.T) {
	s := newFast(t)
	s.WithDLQDepth(func(ctx context.Context) (int64, error) {
		return 7, nil
	})
	s.RecordTickSuccess()
	b := s.snapshot(context.Background())
	if b.DLQDepth != 7 {
		t.Errorf("DLQDepth from callback: got %d, want 7", b.DLQDepth)
	}
}

func TestSnapshotIgnoresCursorCallbackError(t *testing.T) {
	// DB errors on cursor lookup should NOT flip the status — they're
	// diagnostic, best-effort. Same for DLQ depth.
	s := newFast(t)
	s.WithCursor(func(ctx context.Context) (int64, error) {
		return 0, fmt.Errorf("connection refused")
	})
	s.RecordTickSuccess()
	b := s.snapshot(context.Background())
	if b.Status != "healthy" {
		t.Errorf("cursor-callback error should NOT degrade status, got %q reason=%q",
			b.Status, b.Reason)
	}
	if b.Cursor != 0 {
		t.Errorf("failed cursor should default to 0 (omitempty hides it), got %d", b.Cursor)
	}
}

func TestSnapshotCallbacksAreNilSafe(t *testing.T) {
	// Constructing a state without WithCursor/WithDLQDepth should still
	// serialize cleanly. This is the migration path for existing deployments.
	s := newFast(t)
	s.RecordTickSuccess()
	b := s.snapshot(context.Background())
	if b.Status != "healthy" {
		t.Errorf("nil callbacks: got %q", b.Status)
	}
}

// TestSnapshotJSONShape verifies the body JSON keys — Grafana panels and
// operator scripts depend on these NOT drifting.
func TestSnapshotJSONShape(t *testing.T) {
	s := newFast(t)
	s.WithCursor(func(ctx context.Context) (int64, error) { return 100, nil })
	s.WithDLQDepth(func(ctx context.Context) (int64, error) { return 3, nil })
	s.RecordTickSuccess()

	raw, err := json.Marshal(s.snapshot(context.Background()))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	got := string(raw)
	for _, key := range []string{
		`"status":`,
		`"source":"test-source"`,
		`"uptimeSec":`,
		`"cursor":100`,
		`"dlqDepth":3`,
	} {
		if !strings.Contains(got, key) {
			t.Errorf("JSON missing %q\nfull: %s", key, got)
		}
	}
}

// TestHealthzHTTPServesSnapshot verifies the HTTP wiring end-to-end
// (against httptest so we don't need a live listener). Also confirms
// 503 flips ONLY when unhealthy, not on degraded — matches yesterday's
// edge-transformer pattern.
func TestHealthzHTTPServesSnapshot(t *testing.T) {
	// Build a state that WILL flip to unhealthy — big lastTick age vs
	// pollIntervalMs.
	s := NewState("test-src", 1)
	// Simulate a 15-second-old tick against a 1-second poll interval
	s.RecordTickSuccess()
	time.Sleep(1 * time.Millisecond)
	// Directly manipulate lastTickAt to fake 15s-old — safer than sleeping
	past := time.Now().Add(-15 * time.Second).UnixNano()
	s.lastTickAt.Store(past)

	srv := New(":0", s, testLogger(t))
	handler := srv.srv.Handler

	req := httptest.NewRequest("GET", "/health", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != 503 {
		t.Errorf("unhealthy should return 503, got %d\nbody: %s", rr.Code, rr.Body.String())
	}
	body, _ := io.ReadAll(rr.Body)
	if !strings.Contains(string(body), `"status":"unhealthy"`) {
		t.Errorf("body should say unhealthy, got: %s", body)
	}
	if !strings.Contains(string(body), `"reason":`) {
		t.Errorf("unhealthy body should include reason (ADR-0011 rule 4), got: %s", body)
	}
}
