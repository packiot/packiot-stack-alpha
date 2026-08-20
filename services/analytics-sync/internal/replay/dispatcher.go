// Package replay drives the analytics-sync (formerly shadow-mirror) poll →
// decode → dispatch → replay loop.
//
// Cursor lives in the same `mirror_replay_cursor` table used by mirror-worker,
// but under a distinct `source` key ("shadow-mirror" — kept as the PERSISTED
// literal across this service rename; see cursor.go) so the two services'
// cursors don't collide.
//
// Handlers are keyed by user_logs.category. Missing categories are
// silently skipped + counted — new categories emitted by edge-api require
// an accompanying handler PR, but analytics-sync never crashes on unknown
// input (see ADR-0013).
package replay

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"
)

// UserLog is one row from packiot.public.user_logs.
type UserLog struct {
	ID          int64
	Category    string
	Subcategory string
	Payload     json.RawMessage
	// Additional fields (id_enterprise, id_site, ...) available via
	// row-scan when a specific handler needs them; kept out of the
	// UserLog struct to avoid struct bloat.
}

// Handler processes a single user_log entry. Handlers are expected to
// write to BOTH shadow paths (shadow_go_port schema on mainPool AND
// public schema on shadowPool). If shadowPool is nil, handlers should
// skip that half and log a warn.
//
// A returned error is retried up to MaxRetries per the dispatcher's
// retry policy. Use ErrSkip when the payload is not applicable
// (e.g. subcategory this handler doesn't cover) — those advance the
// cursor without a DLQ write.
type Handler func(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, u *UserLog) error

// ErrSkip signals "this entry is well-formed but not applicable to any
// shadow write" — advance cursor, don't DLQ, don't retry.
var ErrSkip = errors.New("analytics-sync: skip (not applicable)")

// Dispatcher registers handlers per user_logs.category and routes each
// row through the right one.
type Dispatcher struct {
	handlers map[string]Handler
	logger   *slog.Logger
}

func NewDispatcher(logger *slog.Logger) *Dispatcher {
	return &Dispatcher{
		handlers: make(map[string]Handler),
		logger:   logger,
	}
}

func (d *Dispatcher) Register(category string, h Handler) {
	d.handlers[category] = h
}

// Dispatch returns (skipped, err). skipped=true means no handler was
// registered for this category — the caller should advance the cursor
// but not treat it as failure.
func (d *Dispatcher) Dispatch(ctx context.Context, mainPool, shadowPool *pgxpool.Pool, u *UserLog) (skipped bool, err error) {
	h, ok := d.handlers[u.Category]
	if !ok {
		// Unknown category — advance cursor without DLQ.
		return true, nil
	}
	err = h(ctx, mainPool, shadowPool, u)
	if errors.Is(err, ErrSkip) {
		return true, nil
	}
	return false, err
}
