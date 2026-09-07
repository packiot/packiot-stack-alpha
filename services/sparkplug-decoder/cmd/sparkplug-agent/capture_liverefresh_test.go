package main

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/capture"
)

// FIX (agent live status-refresh) unit tests. They drive tenantCapture.refresh
// through a SEQUENCE of client_descriptors.status values with a fake fetcher,
// asserting the recorder is atomically enabled/disabled as the status crosses
// into/out of 'captured' — the transition that lets an operator's "Start capture"
// take effect on a RUNNING agent WITHOUT a restart. The same controller now backs
// both the multi-tenant and single-file paths.

// mutableStatusFetcher is a fake statusFetcher whose canned reply a test can flip
// between refreshes (models the operator changing status in the DB while the
// agent runs). Safe for the single test goroutine it's driven from.
type mutableStatusFetcher struct {
	mu     sync.Mutex
	status string
	err    error
}

func (f *mutableStatusFetcher) set(status string, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status, f.err = status, err
}

func (f *mutableStatusFetcher) FetchStatus(_ context.Context, _ int) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.status, f.err
}

// TestCapture_StatusTransition_TableDriven walks a running agent through a series
// of status changes and asserts the observe posture flips to match each one — no
// restart, driven purely by re-reading the status.
func TestCapture_StatusTransition_TableDriven(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	steps := []struct {
		name          string
		status        string
		err           error
		wantObserving bool
	}{
		{"boot draft — not observing", "draft", nil, false},
		{"generated — still off", "generated", nil, false},
		{"operator clicks Start capture → captured", capture.StatusCaptured, nil, true},
		{"idempotent re-poll while captured", capture.StatusCaptured, nil, true},
		{"read error mid-capture keeps posture ON", "", context.DeadlineExceeded, true},
		{"capture ended → validated", "validated", nil, false},
		{"read error while off keeps posture OFF", "", context.DeadlineExceeded, false},
		{"re-enabled → captured again", capture.StatusCaptured, nil, true},
		{"descriptor row vanished ('') → off", "", nil, false},
		{"cutover is not the observe posture → off", agentcfg.StatusCutover, nil, false},
	}

	sink := &mockSink{}
	tc := newTenantCapture("CPACK", "CPACK/SC", 3, sink)
	f := &mutableStatusFetcher{}

	for i, s := range steps {
		f.set(s.status, s.err)
		tc.refresh(ctx, f, time.Hour)
		if got := tc.observing(); got != s.wantObserving {
			t.Fatalf("step %d (%s): observing=%v, want %v", i, s.name, got, s.wantObserving)
		}
		// The pipeline recorder must track the posture: non-nil iff observing, so
		// the ingest hot path (p.rec.Load().Observe) records exactly when it should.
		if hasRec := tc.pipeline.rec.Load() != nil; hasRec != s.wantObserving {
			t.Fatalf("step %d (%s): pipeline recorder present=%v, want %v", i, s.name, hasRec, s.wantObserving)
		}
	}
}

// TestCapture_CutoverWarn_OnceOnTransition verifies the single-file cutover
// observability: when a static-map tenant's status flips to 'cutover' on a
// running agent, the controller WARNs exactly once per transition (the tag-map
// cutover stays a boot read — restart-to-apply — so this only makes the deferred
// restart visible, it does not hot-swap the map).
func TestCapture_CutoverWarn_OnceOnTransition(t *testing.T) {
	ctx := context.Background()
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn}))

	tc := newTenantCapture("CPACK", "CPACK/SC", 3, &mockSink{})
	tc.logger = logger
	tc.cutoverWarn = true         // single-file enables the observability
	tc.tagmapUsesRegister = false // this boot is still on the static map
	f := &mutableStatusFetcher{}

	warns := func() int { return strings.Count(buf.String(), "restart the agent to apply") }

	// Pre-cutover statuses never warn.
	f.set("validated", nil)
	tc.refresh(ctx, f, time.Hour)
	if warns() != 0 {
		t.Fatalf("no warn expected before cutover, got %d", warns())
	}

	// Flip to cutover → exactly one warn.
	f.set(agentcfg.StatusCutover, nil)
	tc.refresh(ctx, f, time.Hour)
	if warns() != 1 {
		t.Fatalf("cutover transition must warn once, got %d\n%s", warns(), buf.String())
	}

	// Staying in cutover across polls must NOT re-warn (deduped to the transition).
	tc.refresh(ctx, f, time.Hour)
	tc.refresh(ctx, f, time.Hour)
	if warns() != 1 {
		t.Fatalf("cutover warn must be deduped across polls, got %d", warns())
	}

	// Leave cutover then return → a NEW transition warns again.
	f.set("validated", nil)
	tc.refresh(ctx, f, time.Hour)
	f.set(agentcfg.StatusCutover, nil)
	tc.refresh(ctx, f, time.Hour)
	if warns() != 2 {
		t.Fatalf("re-cutover must warn again, got %d", warns())
	}
}

// TestCapture_CutoverWarn_SuppressedWhenAlreadyRegister: a tenant that already
// booted register-driven (tagmapUsesRegister) is ALREADY cut over, so a 'cutover'
// status must not nag to restart. Also: multi-tenant units (cutoverWarn false)
// never warn — a restart wouldn't apply cutover there anyway.
func TestCapture_CutoverWarn_SuppressedWhenAlreadyRegister(t *testing.T) {
	ctx := context.Background()
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn}))
	f := &mutableStatusFetcher{}
	f.set(agentcfg.StatusCutover, nil)

	// Already register-driven → suppressed.
	already := newTenantCapture("CPACK", "CPACK/SC", 3, &mockSink{})
	already.logger = logger
	already.cutoverWarn = true
	already.tagmapUsesRegister = true
	already.refresh(ctx, f, time.Hour)

	// Multi-tenant unit (cutoverWarn defaults false) → suppressed.
	multi := newTenantCapture("INCOPLAST", "INCOPLAST/SP", 7, &mockSink{})
	multi.logger = logger
	multi.refresh(ctx, f, time.Hour)

	if n := strings.Count(buf.String(), "restart the agent to apply"); n != 0 {
		t.Fatalf("cutover warn must be suppressed (already-register / multi-tenant), got %d\n%s", n, buf.String())
	}
}

// TestRunCaptureController_ClampsNonPositivePoll drives the real controller with
// a mis-set poll interval (0). It must NOT panic time.NewTicker or busy-loop —
// the controller clamps a non-positive poll to the default. It also asserts the
// controller's boot read flips the tenant on, and ctx cancel tears it down (final
// drain + pool close, no goroutine leak / no panic on the lazy pool's Close).
func TestRunCaptureController_ClampsNonPositivePoll(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())

	// A lazily-created pool: pgxpool.New does not dial, so a bogus-but-parseable
	// DSN yields a usable *pgxpool.Pool the controller can Close() on cancel. The
	// fake fetcher means the pool is never actually queried.
	pool, err := pgxpool.New(ctx, "postgres://u:p@127.0.0.1:1/db")
	if err != nil {
		t.Fatalf("build lazy pool: %v", err)
	}

	sink := &mockSink{}
	tc := newTenantCapture("CPACK", "CPACK/SC", 3, sink)
	f := &mutableStatusFetcher{}
	f.set(capture.StatusCaptured, nil)

	// poll = 0 → must be clamped (a raw time.NewTicker(0) would panic).
	runCaptureController(ctx, []*tenantCapture{tc}, f, pool, time.Hour, 0)

	// Assert via the ATOMIC pipeline recorder pointer — the only tenantCapture
	// state safe to read concurrently with the controller goroutine (tc.recCancel,
	// which observing() reads, is owned by that goroutine alone). Boot read enables.
	waitFor(t, func() bool { return tc.pipeline.rec.Load() != nil }, time.Second)

	// Cancel → controller disables the tenant (p.rec → nil) and closes the pool.
	cancel()
	waitFor(t, func() bool { return tc.pipeline.rec.Load() == nil }, time.Second)
}
