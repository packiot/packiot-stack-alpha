package replay

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestDispatcher_UnknownCategorySkipsWithoutError(t *testing.T) {
	d := NewDispatcher(slog.New(slog.NewTextHandler(io.Discard, nil)))
	u := &UserLog{ID: 1, Category: "totally-unknown-category"}
	skipped, err := d.Dispatch(context.Background(), &pgxpool.Pool{}, &pgxpool.Pool{}, u)
	if err != nil {
		t.Fatalf("unknown category should not error, got: %v", err)
	}
	if !skipped {
		t.Fatalf("unknown category should be reported as skipped")
	}
}

func TestDispatcher_ErrSkipCountsAsSkipped(t *testing.T) {
	d := NewDispatcher(slog.New(slog.NewTextHandler(io.Discard, nil)))
	d.Register("cat", func(ctx context.Context, m, s *pgxpool.Pool, u *UserLog) error {
		return ErrSkip
	})
	skipped, err := d.Dispatch(context.Background(), nil, nil, &UserLog{ID: 1, Category: "cat"})
	if err != nil {
		t.Fatalf("ErrSkip should not surface as error, got: %v", err)
	}
	if !skipped {
		t.Fatalf("ErrSkip should be reported as skipped")
	}
}

func TestDispatcher_HandlerErrorPropagates(t *testing.T) {
	d := NewDispatcher(slog.New(slog.NewTextHandler(io.Discard, nil)))
	boom := errors.New("boom")
	d.Register("cat", func(ctx context.Context, m, s *pgxpool.Pool, u *UserLog) error {
		return boom
	})
	skipped, err := d.Dispatch(context.Background(), nil, nil, &UserLog{ID: 1, Category: "cat"})
	if skipped {
		t.Fatalf("handler error should not be reported as skipped")
	}
	if !errors.Is(err, boom) {
		t.Fatalf("handler error should propagate, got: %v", err)
	}
}
