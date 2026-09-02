package main

import (
	"context"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/capture"
)

// FIX 2 (multi-tenant live-capture) unit tests. They exercise the per-tenant
// capture controller (tenantCapture) directly against a mock Sink + a fake status
// fetcher, so the posture-flip + enterprise-scoping logic is covered with no DB.

// mockSink records every Upsert batch (enterprise id + deltas) so a test can
// assert what a tenant's recorder flushed.
type mockSink struct {
	mu    sync.Mutex
	calls []mockUpsert
}

type mockUpsert struct {
	enterpriseID int
	deltas       []capture.Delta
}

func (m *mockSink) Upsert(_ context.Context, enterpriseID int, deltas []capture.Delta) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cp := make([]capture.Delta, len(deltas))
	copy(cp, deltas)
	m.calls = append(m.calls, mockUpsert{enterpriseID: enterpriseID, deltas: cp})
	return nil
}

// total returns the number of delta rows the sink ever received.
func (m *mockSink) total() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, c := range m.calls {
		n += len(c.deltas)
	}
	return n
}

// fakeStatusFetcher returns a canned status/err for every enterprise.
type fakeStatusFetcher struct {
	status string
	err    error
}

func (f fakeStatusFetcher) FetchStatus(_ context.Context, _ int) (string, error) {
	return f.status, f.err
}

func testLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// newTenantCapture builds a minimal capture unit over a bare pipeline (only the
// fields tenantCapture touches: cfg.Sparkplug + the atomic recorder).
func newTenantCapture(group, packmlTopic string, enterpriseID int, sink capture.Sink) *tenantCapture {
	p := &pipeline{cfg: &agentcfg.Config{Sparkplug: agentcfg.SparkplugCfg{
		GroupID:     group,
		PackMLTopic: packmlTopic,
	}}}
	obs := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "test_capture_obs_" + group}, []string{"tenant"})
	return &tenantCapture{
		pipeline:     p,
		enterpriseID: enterpriseID,
		templates:    []string{"/Admin/ProdProcessedCount/{idx}/Unit"},
		sink:         sink,
		obsCounter:   obs.WithLabelValues(group),
		logger:       testLogger(),
	}
}

// TestMultiCapture_ObservingRecordsAndFlushes: a tenant whose status is 'captured'
// gets a recorder wired into its pipeline; a count tag fed through pipeline.rec is
// buffered and flushed to the sink with the right enterprise + topic + index.
func TestMultiCapture_ObservingRecordsAndFlushes(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	tc := newTenantCapture("CPACK", "CPACK/SC", 3, sink)

	tc.refresh(ctx, fakeStatusFetcher{status: capture.StatusCaptured}, time.Hour)
	if !tc.observing() {
		t.Fatal("tenant in 'captured' status must be observing after refresh")
	}

	// Feed a count-bearing tag through the SAME atomic recorder the ingest hot
	// path reads (pipeline.rec) — proving the wiring, not just the recorder.
	rec := tc.pipeline.rec.Load()
	if rec == nil {
		t.Fatal("observing tenant must have a recorder stored on its pipeline")
	}
	rec.Observe("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/61/Unit")
	// A non-count tag must be ignored (no template match).
	rec.Observe("CPACK/SC/LINHAS/L5/BREYER/Status/MachSpeed")

	if n := rec.Flush(ctx); n != 1 {
		t.Fatalf("flush wrote %d channels, want 1", n)
	}
	if len(sink.calls) != 1 {
		t.Fatalf("sink got %d upsert batches, want 1", len(sink.calls))
	}
	got := sink.calls[0]
	if got.enterpriseID != 3 {
		t.Fatalf("upsert enterprise id = %d, want 3", got.enterpriseID)
	}
	if len(got.deltas) != 1 {
		t.Fatalf("upsert carried %d deltas, want 1", len(got.deltas))
	}
	d := got.deltas[0]
	if d.Topic != "CPACK/SC/LINHAS/L5/BREYER" {
		t.Fatalf("observation topic = %q, want CPACK/SC/LINHAS/L5/BREYER", d.Topic)
	}
	if d.CountIndex != 61 {
		t.Fatalf("observation count index = %d, want 61", d.CountIndex)
	}
}

// TestMultiCapture_NotObservingRecordsNothing: a tenant NOT in the 'captured'
// posture wires no recorder; a tag "fed" through its (nil) pipeline recorder is a
// no-op and the sink stays empty.
func TestMultiCapture_NotObservingRecordsNothing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	tc := newTenantCapture("INCOPLAST", "INCOPLAST/SP", 7, sink)

	tc.refresh(ctx, fakeStatusFetcher{status: "generated"}, time.Hour)
	if tc.observing() {
		t.Fatal("tenant NOT in 'captured' status must not be observing")
	}
	if tc.pipeline.rec.Load() != nil {
		t.Fatal("non-observing tenant must have a nil pipeline recorder")
	}

	// The ingest hot path does exactly this — a nil recorder Observe is a no-op.
	tc.pipeline.rec.Load().Observe("INCOPLAST/SP/LINHAS/L01/S3/Admin/ProdProcessedCount/12/Unit")

	if sink.total() != 0 {
		t.Fatalf("a non-observing tenant must record nothing; sink got %d rows", sink.total())
	}
}

// TestMultiCapture_EnterpriseScoping: two observing tenants keep separate
// recorders — each flush carries only its own enterprise id and its own topic;
// one tenant's observations never leak into the other's sink.
func TestMultiCapture_EnterpriseScoping(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sinkA := &mockSink{}
	sinkB := &mockSink{}
	tcA := newTenantCapture("CPACK", "CPACK/SC", 3, sinkA)
	tcB := newTenantCapture("INCOPLAST", "INCOPLAST/SP", 7, sinkB)

	fetcher := fakeStatusFetcher{status: capture.StatusCaptured}
	tcA.refresh(ctx, fetcher, time.Hour)
	tcB.refresh(ctx, fetcher, time.Hour)

	tcA.pipeline.rec.Load().Observe("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/61/Unit")
	tcB.pipeline.rec.Load().Observe("INCOPLAST/SP/LINHAS/L01/S3/Admin/ProdProcessedCount/12/Unit")

	tcA.pipeline.rec.Load().Flush(ctx)
	tcB.pipeline.rec.Load().Flush(ctx)

	if len(sinkA.calls) != 1 || sinkA.calls[0].enterpriseID != 3 {
		t.Fatalf("sink A must get exactly one batch scoped to enterprise 3; got %+v", sinkA.calls)
	}
	if len(sinkB.calls) != 1 || sinkB.calls[0].enterpriseID != 7 {
		t.Fatalf("sink B must get exactly one batch scoped to enterprise 7; got %+v", sinkB.calls)
	}
	if sinkA.calls[0].deltas[0].Topic != "CPACK/SC/LINHAS/L5/BREYER" {
		t.Fatalf("A topic leaked/wrong: %q", sinkA.calls[0].deltas[0].Topic)
	}
	if sinkB.calls[0].deltas[0].Topic != "INCOPLAST/SP/LINHAS/L01/S3" {
		t.Fatalf("B topic leaked/wrong: %q", sinkB.calls[0].deltas[0].Topic)
	}
}

// TestMultiCapture_PostureFlipOnOff: the periodic re-check flips a tenant on when
// its status becomes 'captured' and off when it leaves — the poll-refresh contract
// (status can change after boot).
func TestMultiCapture_PostureFlipOnOff(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sink := &mockSink{}
	tc := newTenantCapture("CPACK", "CPACK/SC", 3, sink)

	// Boot: not yet captured → not observing.
	tc.refresh(ctx, fakeStatusFetcher{status: "draft"}, time.Hour)
	if tc.observing() {
		t.Fatal("draft status must not observe")
	}

	// Flip ON: status becomes 'captured'.
	tc.refresh(ctx, fakeStatusFetcher{status: capture.StatusCaptured}, time.Hour)
	if !tc.observing() {
		t.Fatal("status flipped to captured — must now observe")
	}
	rec := tc.pipeline.rec.Load()
	rec.Observe("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/61/Unit")

	// Flip OFF: status leaves 'captured'. disable() drains the last interval, so
	// the one buffered observation is still flushed, then the recorder detaches.
	tc.refresh(ctx, fakeStatusFetcher{status: "validated"}, time.Hour)
	if tc.observing() {
		t.Fatal("status left captured — must stop observing")
	}
	if tc.pipeline.rec.Load() != nil {
		t.Fatal("disabled tenant must detach its pipeline recorder")
	}
	// Give the recorder's Run goroutine a moment to complete its cancel-drain.
	waitFor(t, func() bool { return sink.total() == 1 }, time.Second)

	// A read ERROR after that must be fail-safe: posture unchanged (still off).
	tc.refresh(ctx, fakeStatusFetcher{err: context.DeadlineExceeded}, time.Hour)
	if tc.observing() {
		t.Fatal("a status read error must not silently start capture")
	}
}

// waitFor polls cond until true or the deadline, failing the test on timeout.
func waitFor(t *testing.T, cond func() bool, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	if !cond() {
		t.Fatal("condition not met within deadline")
	}
}
