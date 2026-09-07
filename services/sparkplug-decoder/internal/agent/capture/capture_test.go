package capture

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// mockSink records the batches it is handed and can be told to fail.
type mockSink struct {
	mu      sync.Mutex
	batches [][]Delta
	failErr error
}

func (m *mockSink) Upsert(_ context.Context, _ int, deltas []Delta) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.failErr != nil {
		return m.failErr
	}
	// copy — the caller may reuse its slice
	cp := make([]Delta, len(deltas))
	copy(cp, deltas)
	m.batches = append(m.batches, cp)
	return nil
}

func (m *mockSink) totalFlushed() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, b := range m.batches {
		n += len(b)
	}
	return n
}

var testTemplates = []string{"/Admin/ProdConsumedCount/{idx}/Unit"}

func newTestRecorder(sink Sink, observed *int) *Recorder {
	fixed := time.Date(2026, 7, 28, 12, 0, 0, 0, time.UTC)
	return New(Config{
		EnterpriseID: 42,
		Templates:    testTemplates,
		Sink:         sink,
		Now:          func() time.Time { return fixed },
		OnObserved: func() {
			if observed != nil {
				*observed++
			}
		},
	})
}

// The GATE is pure: only captured status + master flag on records.
func TestShouldObserve(t *testing.T) {
	cases := []struct {
		enabled bool
		status  string
		want    bool
	}{
		{true, "captured", true},
		{true, "cutover", false},
		{true, "generated", false},
		{true, "", false},
		{false, "captured", false}, // master flag dark-gates even a captured tenant
	}
	for _, tc := range cases {
		if got := ShouldObserve(tc.enabled, tc.status); got != tc.want {
			t.Errorf("ShouldObserve(%v, %q) = %v, want %v", tc.enabled, tc.status, got, tc.want)
		}
	}
}

// status=captured (recorder wired) → observation recorded + flushed.
func TestObserveAndFlush_Records(t *testing.T) {
	sink := &mockSink{}
	observed := 0
	r := newTestRecorder(sink, &observed)

	r.Observe("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit")

	if observed != 1 {
		t.Fatalf("onObserved fired %d times, want 1", observed)
	}
	if n := r.Flush(context.Background()); n != 1 {
		t.Fatalf("flush reported %d channels, want 1", n)
	}
	if got := sink.totalFlushed(); got != 1 {
		t.Fatalf("sink saw %d rows, want 1", got)
	}
	d := sink.batches[0][0]
	if d.Topic != "CPACK/SC/LINHAS/L5/BREYER" || d.CountIndex != 61 || d.Count != 1 {
		t.Fatalf("delta = %+v, want topic BREYER idx 61 count 1", d)
	}
}

// A non-count tag records nothing (the no-op hot path).
func TestObserve_NonCountTag(t *testing.T) {
	sink := &mockSink{}
	observed := 0
	r := newTestRecorder(sink, &observed)

	r.Observe("CPACK/SC/LINHAS/L5/BREYER/Status/MachSpeed")

	if observed != 0 {
		t.Fatalf("onObserved fired %d times for a non-count tag, want 0", observed)
	}
	if n := r.Flush(context.Background()); n != 0 {
		t.Fatalf("flush reported %d channels, want 0", n)
	}
}

// Repeats on the same channel accumulate observed_count + widen the window.
func TestObserve_RepeatIncrements(t *testing.T) {
	sink := &mockSink{}
	r := newTestRecorder(sink, nil)

	for i := 0; i < 3; i++ {
		r.Observe("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit")
	}
	// Distinct channel too.
	r.Observe("CPACK/SC/LINHAS/L4/TEXA/Admin/ProdConsumedCount/63/Unit")

	if n := r.Flush(context.Background()); n != 2 {
		t.Fatalf("flush reported %d channels, want 2 distinct", n)
	}
	var breyer *Delta
	for i := range sink.batches[0] {
		if sink.batches[0][i].CountIndex == 61 {
			breyer = &sink.batches[0][i]
		}
	}
	if breyer == nil {
		t.Fatal("BREYER (idx 61) delta missing")
	}
	if breyer.Count != 3 {
		t.Fatalf("BREYER observed_count = %d, want 3", breyer.Count)
	}
}

// A DB (sink) error is dropped — Flush never surfaces it and the buffer is
// cleared (best-effort evidence; ingest is unaffected because Observe never
// touches the sink).
func TestFlush_SinkErrorDropped(t *testing.T) {
	sink := &mockSink{failErr: errors.New("table absent")}
	r := newTestRecorder(sink, nil)

	r.Observe("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit")

	if n := r.Flush(context.Background()); n != 0 {
		t.Fatalf("flush after sink error reported %d, want 0 (dropped)", n)
	}
	// Buffer was reset — a second flush with a now-healthy sink writes nothing
	// from the dropped batch (evidence is not re-queued).
	sink.mu.Lock()
	sink.failErr = nil
	sink.mu.Unlock()
	if n := r.Flush(context.Background()); n != 0 {
		t.Fatalf("dropped batch was re-queued (flush = %d, want 0)", n)
	}
}

// Flush of an empty buffer is a clean no-op (no sink call).
func TestFlush_Empty(t *testing.T) {
	sink := &mockSink{}
	r := newTestRecorder(sink, nil)
	if n := r.Flush(context.Background()); n != 0 {
		t.Fatalf("empty flush = %d, want 0", n)
	}
	if len(sink.batches) != 0 {
		t.Fatalf("empty flush called the sink %d times, want 0", len(sink.batches))
	}
}

// A nil recorder Observe is safe (the not-observing tenant path never allocates
// a recorder; a defensive nil-guard keeps the call site branch-free).
func TestObserve_NilRecorderSafe(t *testing.T) {
	var r *Recorder
	r.Observe("anything") // must not panic
}
