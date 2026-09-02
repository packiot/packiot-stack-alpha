package unmapped

import (
	"context"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

// countingHandler is a slog.Handler that records how many WARN records it saw
// so a test can assert "logged once, not per-message."
type countingHandler struct {
	mu    sync.Mutex
	warns int
}

func (h *countingHandler) Enabled(_ context.Context, l slog.Level) bool { return l >= slog.LevelWarn }
func (h *countingHandler) Handle(_ context.Context, r slog.Record) error {
	if r.Level >= slog.LevelWarn {
		h.mu.Lock()
		h.warns++
		h.mu.Unlock()
	}
	return nil
}
func (h *countingHandler) WithAttrs(_ []slog.Attr) slog.Handler { return h }
func (h *countingHandler) WithGroup(_ string) slog.Handler      { return h }
func (h *countingHandler) count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.warns
}

func newCounter() *prometheus.CounterVec {
	return prometheus.NewCounterVec(
		prometheus.CounterOpts{Name: "sparkplug_agent_unmapped_tags_total"},
		[]string{"group", "segment", "reason"},
	)
}

// TestObserve_CountsEveryDrop_LogsOnce is the core P0 guarantee: N observations
// of the SAME unmapped suffix bump the metric N times but emit exactly ONE WARN
// (throttle), so a steady-state stream is not log-spam.
func TestObserve_CountsEveryDrop_LogsOnce(t *testing.T) {
	h := &countingHandler{}
	c := newCounter()
	r := New("CPACK", c, slog.New(h), false, DefaultLogWindow)

	const suffix = "/L6/Admin/ProdProcessedCount/99/Unit"
	const n = 50
	for i := 0; i < n; i++ {
		r.Observe(suffix)
	}

	// Metric counts every drop.
	got := testutil.ToFloat64(c.WithLabelValues("CPACK", "L6", ReasonUnknownTopic))
	if got != float64(n) {
		t.Fatalf("counter: got %v, want %d (every drop counted)", got, n)
	}
	// Log fires once, not per-message.
	if w := h.count(); w != 1 {
		t.Fatalf("warns: got %d, want 1 (throttled per distinct suffix)", w)
	}
}

// TestObserve_LogsPerDistinctSuffix: each DISTINCT suffix logs once; the metric
// segment label stays bounded (first path element), not the full suffix.
func TestObserve_LogsPerDistinctSuffix(t *testing.T) {
	h := &countingHandler{}
	c := newCounter()
	r := New("CPACK", c, slog.New(h), false, DefaultLogWindow)

	r.Observe("/L6/Status/MachSpeed")
	r.Observe("/L6/Admin/ProdProcessedCount/99/Unit")
	r.Observe("/L8/Status/StateCurrent")
	r.Observe("/L6/Status/MachSpeed") // repeat → no new log

	if w := h.count(); w != 3 {
		t.Fatalf("warns: got %d, want 3 (one per distinct suffix)", w)
	}
	// L6's two distinct suffixes collapse to one bounded segment label.
	if v := testutil.ToFloat64(c.WithLabelValues("CPACK", "L6", ReasonUnknownTopic)); v != 3 {
		t.Errorf("L6 segment count: got %v, want 3", v)
	}
	if v := testutil.ToFloat64(c.WithLabelValues("CPACK", "L8", ReasonUnknownTopic)); v != 1 {
		t.Errorf("L8 segment count: got %v, want 1", v)
	}
}

// TestObserve_WindowReLogs: with a positive window, the same suffix re-logs once
// the window has elapsed (driven by an injected clock — no sleeping).
func TestObserve_WindowReLogs(t *testing.T) {
	h := &countingHandler{}
	r := New("CPACK", newCounter(), slog.New(h), false, time.Hour)

	base := time.Unix(1_700_000_000, 0)
	now := base
	r.now = func() time.Time { return now }

	const suffix = "/L6/Status/MachSpeed"
	r.Observe(suffix) // t=0 → log (1)
	r.Observe(suffix) // t=0 → throttled
	now = base.Add(30 * time.Minute)
	r.Observe(suffix) // within window → throttled
	now = base.Add(61 * time.Minute)
	r.Observe(suffix) // window elapsed → log (2)

	if w := h.count(); w != 2 {
		t.Fatalf("warns: got %d, want 2 (re-log after window)", w)
	}
}

// TestVerbose_AccumulatesDistinctSet: verbose mode exposes the distinct unmapped
// suffixes (the onboarding index-capture aid) on the /healthz snapshot;
// non-verbose does not carry the list.
func TestVerbose_AccumulatesDistinctSet(t *testing.T) {
	r := New("CPACK", newCounter(), slog.New(&countingHandler{}), true, DefaultLogWindow)
	r.Observe("/L6/Admin/ProdProcessedCount/99/Unit")
	r.Observe("/L6/Admin/ProdProcessedCount/99/Unit")
	r.Observe("/L8/Status/StateCurrent")

	got := r.Distinct()
	want := []string{"/L6/Admin/ProdProcessedCount/99/Unit", "/L8/Status/StateCurrent"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("Distinct(): got %v, want %v", got, want)
	}

	detail, ok := r.SnapshotDetail().(map[string]any)
	if !ok {
		t.Fatalf("SnapshotDetail: unexpected type %T", r.SnapshotDetail())
	}
	if detail["total_dropped"].(int64) != 3 {
		t.Errorf("total_dropped: got %v, want 3", detail["total_dropped"])
	}
	list, ok := detail["unmapped_suffixes"].([]map[string]any)
	if !ok || len(list) != 2 {
		t.Fatalf("verbose snapshot must list 2 distinct suffixes, got %#v", detail["unmapped_suffixes"])
	}
	// Deterministic, sorted, with per-suffix counts.
	if list[0]["suffix"] != want[0] || list[0]["count"].(int64) != 2 {
		t.Errorf("first suffix entry wrong: %#v", list[0])
	}

	// Never degrades health.
	if reason := r.Degraded(); reason != "" {
		t.Errorf("Degraded: got %q, want empty (diagnostic, not a fault)", reason)
	}
}

// TestSnapshot_NonVerboseOmitsList: non-verbose keeps totals but withholds the
// suffix list (bounded-memory discipline).
func TestSnapshot_NonVerboseOmitsList(t *testing.T) {
	r := New("CPACK", newCounter(), slog.New(&countingHandler{}), false, DefaultLogWindow)
	r.Observe("/L6/Status/MachSpeed")

	detail := r.SnapshotDetail().(map[string]any)
	if _, present := detail["unmapped_suffixes"]; present {
		t.Errorf("non-verbose snapshot must not carry the suffix list")
	}
	if detail["distinct_suffixes_seen"].(int) != 1 {
		t.Errorf("distinct_suffixes_seen: got %v, want 1", detail["distinct_suffixes_seen"])
	}
}

func TestSegmentOf(t *testing.T) {
	cases := map[string]string{
		"/L8/Status/MachSpeed":                 "L8",
		"/L6/Admin/ProdProcessedCount/51/Unit": "L6",
		"L4/foo":                               "L4",
		"":                                     "unknown",
		"/":                                    "unknown",
		"bare":                                 "bare",
	}
	for in, want := range cases {
		if got := segmentOf(in); got != want {
			t.Errorf("segmentOf(%q): got %q, want %q", in, got, want)
		}
	}
}
