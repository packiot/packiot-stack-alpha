package tagstore

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

func tag(metric string, v any) rawtag.RawTag {
	return rawtag.RawTag{Metric: metric, Value: v, Quality: true, TsMillis: 1}
}

func TestApply_RBE(t *testing.T) {
	s := New()

	// First reading is always a change.
	if !s.Apply(tag("/Speed", 12.5)) {
		t.Fatal("first apply should report changed")
	}
	// Same value ⇒ not changed (report-by-exception).
	if s.Apply(tag("/Speed", 12.5)) {
		t.Fatal("unchanged value must not report changed")
	}
	// New value ⇒ changed.
	if !s.Apply(tag("/Speed", 15.0)) {
		t.Fatal("changed value should report changed")
	}
	// Quality flip alone ⇒ changed.
	bad := tag("/Speed", 15.0)
	bad.Quality = false
	if !s.Apply(bad) {
		t.Fatal("quality flip should report changed")
	}
}

func TestDrainDirty_OnlyChangedThenCleared(t *testing.T) {
	s := New()
	s.Apply(tag("/Speed", 1.0))
	s.Apply(tag("/Count", 10.0))
	s.Apply(tag("/Count", 10.0)) // unchanged — no new dirty

	dirty := s.DrainDirty()
	if len(dirty) != 2 {
		t.Fatalf("dirty count: got %d, want 2", len(dirty))
	}
	// Sorted by suffix: /Count before /Speed.
	if dirty[0].Metric != "/Count" || dirty[1].Metric != "/Speed" {
		t.Fatalf("dirty order not suffix-sorted: %v", []string{dirty[0].Metric, dirty[1].Metric})
	}
	// Second drain with no new changes ⇒ empty.
	if again := s.DrainDirty(); again != nil {
		t.Fatalf("second drain should be empty, got %v", again)
	}
}

func TestSnapshotForBirth_ClearsDirty(t *testing.T) {
	s := New()
	s.Apply(tag("/Speed", 1.0))
	s.Apply(tag("/Count", 10.0))

	snap := s.SnapshotForBirth()
	if len(snap) != 2 {
		t.Fatalf("snapshot size: got %d, want 2", len(snap))
	}
	// A birth conveyed the full table — dirty must now be empty so those
	// values don't re-emit as NDATA.
	if dirty := s.DrainDirty(); dirty != nil {
		t.Fatalf("SnapshotForBirth must clear dirty, got %v", dirty)
	}
}
