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
	h.query = func(context.Context) (string, error) {
		a := answers[min(calls, len(answers)-1)]
		calls++
		if err, ok := a.(error); ok {
			return "", err
		}
		return a.(string), nil
	}
	return h, &calls
}

func TestHoldNilIsNeverHeld(t *testing.T) {
	var h *Hold // the CPACK replicator: no gate
	if h.Held(context.Background()) || h.Mode(context.Background()) != HoldNone {
		t.Fatal("nil Hold reported held")
	}
}

func TestHoldCachesWithinTTL(t *testing.T) {
	h, calls := testHold(time.Hour, HoldSession, HoldNone)
	ctx := context.Background()
	if !h.Held(ctx) || !h.Held(ctx) || h.Mode(ctx) != HoldSession {
		t.Fatal("want session from the first (cached) answer")
	}
	if *calls != 1 {
		t.Fatalf("queried %d times within the TTL, want 1", *calls)
	}
}

func TestHoldRequeriesAfterTTL(t *testing.T) {
	h, calls := testHold(time.Nanosecond, HoldSession, HoldNone)
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

// Healing must be distinguishable from a session: the loop PAUSES (no advance) while a
// heal runs, but skips-and-advances during a session. Both count as held for the reconcilers.
func TestHoldHealingIsDistinctFromSession(t *testing.T) {
	h, _ := testHold(time.Hour, HoldHealing)
	ctx := context.Background()
	if h.Mode(ctx) != HoldHealing {
		t.Fatalf("mode = %q, want %q", h.Mode(ctx), HoldHealing)
	}
	if !h.Held(ctx) {
		t.Fatal("healing must also count as held (reconcilers / DLQ stand down)")
	}
}

func TestHoldUnknownModeIsNone(t *testing.T) {
	h, _ := testHold(time.Hour, "something-new")
	if h.Mode(context.Background()) != HoldNone {
		t.Fatal("an unknown mode must fail open to none")
	}
}

func TestHoldFailsOpen(t *testing.T) {
	h, _ := testHold(time.Hour, errors.New(`function ops.sandbox_hold_mode(integer) does not exist`))
	if h.Held(context.Background()) {
		t.Fatal("a failing hold check must fail OPEN (replicate), not freeze the twin")
	}
}
