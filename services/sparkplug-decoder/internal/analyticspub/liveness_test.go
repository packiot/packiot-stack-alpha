package analyticspub

import (
	"testing"
	"time"
)

// TestEmitStalled is the #91 emit-liveness predicate table. The invariant it
// protects: a silently-stalled publisher (dead channel / failing reconnect,
// the #89 27h gap) MUST be reported degraded, while an idle-but-healthy or a
// transiently-blipped publisher MUST NOT — a flapping health check would drive
// a restart loop.
func TestEmitStalled(t *testing.T) {
	const timeout = 120 * time.Second
	now := time.Now().UnixNano()
	ago := func(d time.Duration) int64 { return now - int64(d) }

	tests := []struct {
		name        string
		lastAttempt int64
		lastConfirm int64
		timeout     time.Duration
		want        bool
	}{
		{
			name:        "healthy steady stream: attempting AND confirming recently",
			lastAttempt: ago(1 * time.Second),
			lastConfirm: ago(1 * time.Second),
			timeout:     timeout,
			want:        false,
		},
		{
			name:        "STALLED: attempting recently but no confirm in the window (dead channel)",
			lastAttempt: ago(2 * time.Second),
			lastConfirm: ago(200 * time.Second),
			timeout:     timeout,
			want:        true,
		},
		{
			name:        "idle: nothing attempted for a long time → NOT stalled (anti-flap: quiet != broken)",
			lastAttempt: ago(600 * time.Second),
			lastConfirm: ago(600 * time.Second),
			timeout:     timeout,
			want:        false,
		},
		{
			name:        "idle-after-failure: last attempt is stale → NOT stalled (avoid holding red on a quiet feed)",
			lastAttempt: ago(600 * time.Second),
			lastConfirm: ago(900 * time.Second),
			timeout:     timeout,
			want:        false,
		},
		{
			name:        "transient blip: no confirm for 30s but well within a 120s window → NOT stalled yet",
			lastAttempt: ago(1 * time.Second),
			lastConfirm: ago(30 * time.Second),
			timeout:     timeout,
			want:        false,
		},
		{
			name:        "boundary: confirm exactly at the window edge is not yet stale",
			lastAttempt: ago(1 * time.Second),
			lastConfirm: ago(timeout),
			timeout:     timeout,
			want:        false,
		},
		{
			name:        "disabled: timeout 0 never reports stalled even with a stale confirm",
			lastAttempt: ago(2 * time.Second),
			lastConfirm: ago(10000 * time.Second),
			timeout:     0,
			want:        false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := emitStalled(now, tt.lastAttempt, tt.lastConfirm, tt.timeout)
			if got != tt.want {
				t.Errorf("emitStalled = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestDegraded_EmitLiveness wires the predicate through the real Publisher.
// Degraded() must name the emit stall (503) when the stamps say stalled, and
// return healthy when confirms are current — exercising the exact path
// /healthz consults.
func TestDegraded_EmitLiveness(t *testing.T) {
	now := time.Now().UnixNano()

	stalled := &Publisher{LivenessTimeout: 120 * time.Second}
	stalled.lastAttemptAt.Store(now - int64(2*time.Second))
	stalled.lastConfirmAt.Store(now - int64(300*time.Second))
	if got := stalled.Degraded(); got == "" {
		t.Fatal("Degraded() must report a reason when emit is stalled")
	}

	healthy := &Publisher{LivenessTimeout: 120 * time.Second}
	healthy.lastAttemptAt.Store(now - int64(1*time.Second))
	healthy.lastConfirmAt.Store(now - int64(1*time.Second))
	if got := healthy.Degraded(); got != "" {
		t.Fatalf("Degraded() must be empty for a healthy publisher, got %q", got)
	}
}
