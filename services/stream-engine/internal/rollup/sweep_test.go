package rollup

import (
	"reflect"
	"testing"
	"time"
)

func TestSweepSchedulerCoversEverySliceOncePerPeriod(t *testing.T) {
	s := newSweepScheduler(24*time.Hour, time.Minute)
	if s.total != 1440 {
		t.Fatalf("total = %d, want 1440", s.total)
	}
	start := time.Date(2026, 9, 29, 0, 0, 0, 0, time.UTC)
	seen := map[int64]int{}
	// a day of ticks with a regular overrun (every 3rd tick skipped) still covers
	// every slice exactly once.
	for m := 0; m < 1440; m++ {
		if m%3 == 2 {
			continue
		}
		for _, sl := range s.due(start.Add(time.Duration(m) * time.Minute)) {
			seen[sl]++
		}
	}
	for _, sl := range s.due(start.Add(1439*time.Minute + 30*time.Second)) { // same tick: nothing new
		seen[sl]++
	}
	if len(seen) != 1440 {
		t.Fatalf("covered %d slices, want 1440", len(seen))
	}
	for sl, n := range seen {
		if n != 1 {
			t.Fatalf("slice %d handed out %d times", sl, n)
		}
	}
}

func TestSweepSchedulerCatchUpCappedAndDisabled(t *testing.T) {
	s := newSweepScheduler(10*time.Minute, time.Minute)
	t0 := time.Date(2026, 9, 29, 0, 0, 0, 0, time.UTC)
	if got := s.due(t0); len(got) != 1 {
		t.Fatalf("first tick = %v, want one slice", got)
	}
	// a 3-hour stall: catch-up is capped at one full cycle (10 slices).
	if got := s.due(t0.Add(3 * time.Hour)); len(got) != 10 {
		t.Fatalf("catch-up = %d slices, want 10", len(got))
	}
	if got := newSweepScheduler(0, time.Minute).due(t0); got != nil {
		t.Fatalf("disabled scheduler handed out %v", got)
	}
	if got := newSweepScheduler(30*time.Second, time.Minute); got.total != 1 || !reflect.DeepEqual(got.due(t0), []int64{0}) {
		t.Fatalf("period < every must degrade to one slice")
	}
}
