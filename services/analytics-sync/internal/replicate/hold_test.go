package replicate

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"
)

func testHold(ttl time.Duration, answers ...any) (*Hold, *int) {
	calls := 0
	h := &Hold{ent: 2000003, ttl: ttl, logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	h.query = func(context.Context) (bool, error) {
		a := answers[min(calls, len(answers)-1)]
		calls++
		if err, ok := a.(error); ok {
			return false, err
		}
		return a.(bool), nil
	}
	return h, &calls
}

func TestHoldNilIsNeverHeld(t *testing.T) {
	var h *Hold // the CPACK replicator: no gate
	if h.Held(context.Background()) {
		t.Fatal("nil Hold reported held")
	}
}

func TestHoldCachesWithinTTL(t *testing.T) {
	h, calls := testHold(time.Hour, true, false)
	ctx := context.Background()
	if !h.Held(ctx) || !h.Held(ctx) || !h.Held(ctx) {
		t.Fatal("want held from the first (cached) answer")
	}
	if *calls != 1 {
		t.Fatalf("queried %d times within the TTL, want 1", *calls)
	}
}

func TestHoldRequeriesAfterTTL(t *testing.T) {
	h, calls := testHold(time.Nanosecond, true, false)
	ctx := context.Background()
	if !h.Held(ctx) {
		t.Fatal("first answer: want held")
	}
	time.Sleep(time.Millisecond)
	if h.Held(ctx) {
		t.Fatal("after TTL the released state must be seen")
	}
	if *calls != 2 {
		t.Fatalf("calls = %d, want 2", *calls)
	}
}

func TestHoldFailsOpen(t *testing.T) {
	h, _ := testHold(time.Hour, errors.New(`function ops.sandbox_held(integer) does not exist`))
	if h.Held(context.Background()) {
		t.Fatal("a failing hold check must fail OPEN (replicate), not freeze the twin")
	}
}
