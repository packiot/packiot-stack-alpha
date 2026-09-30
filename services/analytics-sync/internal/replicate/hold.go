package replicate

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Hold is the SANDBOX grace-period gate (db/migrations/t-sandbox-grace-hold). While a
// person is making hands-on changes in a sandbox twin, ops.sandbox_held(dst) is true
// and every writer of this replicator stands down: the main loop keeps advancing its
// cursor WITHOUT applying, and the PO / manual-event reconcilers and the DLQ retrier
// skip their passes. When the grace period ends, the heal (ops.sandbox_reflect)
// restores the twin to its source's CURRENT state, which already contains everything
// skipped here, and the replicator resumes from the cursor it kept advancing.
//
// A nil *Hold is never held (the CPACK replicator never sets one). Errors fail OPEN
// (not held, logged): the migration missing or the DB unreachable must not silently
// freeze a twin's mirroring.
type Hold struct {
	pool   *pgxpool.Pool
	ent    int
	ttl    time.Duration
	logger *slog.Logger
	query  func(ctx context.Context) (bool, error)

	mu      sync.Mutex
	at      time.Time
	held    bool
	lastErr time.Time
}

// NewHold returns the gate for the destination enterprise, cached for ttl.
func NewHold(pool *pgxpool.Pool, ent int, ttl time.Duration, logger *slog.Logger) *Hold {
	h := &Hold{pool: pool, ent: ent, ttl: ttl, logger: logger}
	h.query = func(ctx context.Context) (bool, error) {
		var held bool
		err := h.pool.QueryRow(ctx, `SELECT ops.sandbox_held($1)`, h.ent).Scan(&held)
		return held, err
	}
	return h
}

// Held reports whether the sandbox is on hold (a hands-on session is active).
func (h *Hold) Held(ctx context.Context) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.at.IsZero() && time.Since(h.at) < h.ttl {
		return h.held
	}
	held, err := h.query(ctx)
	if err != nil {
		if time.Since(h.lastErr) > time.Minute {
			h.logger.Warn("sandbox hold check failed — failing open (replicating)", slog.Int("dst_enterprise", h.ent), slog.String("err", err.Error()))
			h.lastErr = time.Now()
		}
		held = false
	} else if held != h.held || h.at.IsZero() {
		h.logger.Info("sandbox hold state", slog.Int("dst_enterprise", h.ent), slog.Bool("held", held))
	}
	h.held, h.at = held, time.Now()
	return held
}
