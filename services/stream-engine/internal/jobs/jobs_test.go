package jobs

import (
	"context"
	"errors"
	"log/slog"
	"testing"
	"time"
)

func TestRunOneOutcomes(t *testing.T) {
	l := slog.Default()
	if o := runOne(context.Background(), Job{Name: "a", Run: func(context.Context) error { return nil }}, l); o != "ok" {
		t.Errorf("ok: %s", o)
	}
	if o := runOne(context.Background(), Job{Name: "b", Run: func(context.Context) error { return errors.New("x") }}, l); o != "error" {
		t.Errorf("error: %s", o)
	}
	if o := runOne(context.Background(), Job{Name: "c", Run: func(context.Context) error { panic("boom") }}, l); o != "panic" {
		t.Errorf("panic must be recovered and reported: %s", o)
	}
}

func TestRunOneTimeout(t *testing.T) {
	j := Job{Name: "hang", Every: time.Millisecond, Timeout: 20 * time.Millisecond,
		Run: func(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }}
	if o := runOne(context.Background(), j, slog.Default()); o != "timeout" {
		t.Errorf("hung tick must report timeout, got %s", o)
	}
}
