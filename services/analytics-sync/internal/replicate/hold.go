package replicate

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Hold is the SANDBOX grace-period gate (db/migrations/t-sandbox-grace-hold +
// t-sandbox-hold-mode). ops.sandbox_hold_mode(dst) says why the twin is held:
//   - "session": a person is making hands-on changes. The main loop keeps advancing
//     its cursor WITHOUT applying; the heal at the end of the grace period reflects the
//     source's CURRENT state, which already contains everything skipped.
//   - "healing": a heal is running. The main loop PAUSES (no fetch, no advance): the
//     reflect copies the source at one instant, so an action arriving mid-heal must be
//     replayed afterwards, not skipped (a skipped one was lost: CPACK's 22:09 stop,
//     2026-09-30). The handlers are idempotent upserts, so replaying is safe.
//
// In both modes the PO / manual-event reconcilers and the DLQ retrier skip their passes.
//
// A nil *Hold is never held (the CPACK replicator never sets one). Errors fail OPEN
// (not held, logged): the migration missing or the DB unreachable must not silently
// freeze a twin's mirroring.
type Hold struct {
	pool   *pgxpool.Pool
	ent    int
	ttl    time.Duration
	logger *slog.Logger
	query  func(ctx context.Context) (string, error)

	mu      sync.Mutex
	at      time.Time
	mode    string
	lastErr time.Time
}

// Hold modes (ops.sandbox_hold_mode).
const (
	HoldNone    = "none"
	HoldSession = "session"
	HoldHealing = "healing"
)

// NewHold returns the gate for the destination enterprise, cached for ttl.
func NewHold(pool *pgxpool.Pool, ent int, ttl time.Duration, logger *slog.Logger) *Hold {
	h := &Hold{pool: pool, ent: ent, ttl: ttl, logger: logger}
	h.query = func(ctx context.Context) (string, error) {
		var mode string
		err := h.pool.QueryRow(ctx, `SELECT ops.sandbox_hold_mode($1::int)`, h.ent).Scan(&mode)
		return mode, err
	}
	return h
}

// Held reports whether the sandbox is on hold for any reason (reconcilers, DLQ retrier).
func (h *Hold) Held(ctx context.Context) bool { return h.Mode(ctx) != HoldNone }

// Mode returns HoldNone, HoldSession or HoldHealing (cached for ttl). A nil *Hold, or a
// failed check, is HoldNone (fail open).
func (h *Hold) Mode(ctx context.Context) string {
	if h == nil {
		return HoldNone
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if !h.at.IsZero() && time.Since(h.at) < h.ttl {
		return h.mode
	}
	mode, err := h.query(ctx)
	if err != nil {
		if time.Since(h.lastErr) > time.Minute {
			h.logger.Warn("sandbox hold check failed — failing open (replicating)", slog.Int("dst_enterprise", h.ent), slog.String("err", err.Error()))
			h.lastErr = time.Now()
		}
		mode = HoldNone
	}
	if mode != HoldSession && mode != HoldHealing {
		mode = HoldNone
	}
	if mode != h.mode || h.at.IsZero() {
		h.logger.Info("sandbox hold state", slog.Int("dst_enterprise", h.ent), slog.String("mode", mode), slog.Bool("held", mode != HoldNone))
	}
	h.mode, h.at = mode, time.Now()
	return mode
}
