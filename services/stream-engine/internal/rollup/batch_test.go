package rollup

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestBatchSizerAdapts(t *testing.T) {
	b := newBatchSizer("t", 300)
	const budget = 120 * time.Second
	if got := b.limit("d"); got != 300 {
		t.Fatalf("starts at the configured limit, got %d", got)
	}
	// over budget → halves, down to the floor
	want := []int{150, 75, 37, 18, 9, minBatch, minBatch}
	for i, w := range want {
		lim := b.limit("d")
		if got, _ := b.observe("d", lim, 0, budget, budget, true); got != w {
			t.Fatalf("over-budget step %d: got %d want %d", i, got, w)
		}
	}
	// a full batch well inside the budget → doubles, up to the configured limit
	for _, w := range []int{10, 20, 40, 80, 160, 300, 300} {
		lim := b.limit("d")
		if got, _ := b.observe("d", lim, int64(lim), time.Second, budget, false); got != w {
			t.Fatalf("grow: got %d want %d", got, w)
		}
	}
	// a partial batch (backlog empty) or a slow full batch → unchanged
	if got, changed := b.observe("d", 300, 12, time.Second, budget, false); got != 300 || changed {
		t.Fatalf("partial batch changed the limit to %d", got)
	}
	if got, changed := b.observe("d", 300, 300, 50*time.Second, budget, false); got != 300 || changed {
		t.Fatalf("slow full batch changed the limit to %d", got)
	}
	// destinations are independent
	if got := b.limit("other"); got != 300 {
		t.Fatalf("other dest: %d", got)
	}
}

func TestRunBudgetedTellsOwnBudgetFromParent(t *testing.T) {
	slow := func(c context.Context) (int64, error) { <-c.Done(); return 0, c.Err() }
	if _, _, over, err := runBudgeted(context.Background(), 10*time.Millisecond, slow); !over || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("own budget: over=%v err=%v", over, err)
	}
	parent, cancel := context.WithTimeout(context.Background(), 5*time.Millisecond)
	defer cancel()
	if _, _, over, _ := runBudgeted(parent, time.Hour, slow); over {
		t.Fatal("the PARENT's deadline must not count as this pass's budget (it would shrink the batch for nothing)")
	}
	if _, _, over, err := runBudgeted(context.Background(), time.Hour, func(context.Context) (int64, error) { return 0, errors.New("boom") }); over || err == nil {
		t.Fatalf("a plain error is not over budget: over=%v err=%v", over, err)
	}
}
