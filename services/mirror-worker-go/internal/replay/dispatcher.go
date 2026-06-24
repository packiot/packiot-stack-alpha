// Package replay owns per-category handlers for prod user_logs rows.
//
// Each handler signature:
//
//   func(ctx, tx, row) error
//
// The tx is the per-row staging transaction begun by processRow (in main).
// Handlers run their staging writes through this tx so the cursor advance
// + DLQ write + mapping insert are atomic. This is what the TS mirror-
// worker got wrong in order-created.ts / order-created-started.ts (and
// the bug we just fixed in 7e5b0bf).
package replay

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/prometheus/client_golang/prometheus"
)

type Handler func(ctx context.Context, tx pgx.Tx, row db.ProdUserLog) error

type Dispatcher struct {
	handlers map[string]Handler
}

func NewDispatcher() *Dispatcher {
	return &Dispatcher{handlers: make(map[string]Handler)}
}

func (d *Dispatcher) Register(category string, h Handler) {
	d.handlers[category] = h
}

// Lookup returns the handler for a category, or nil if no handler
// is registered. nil means "no-op + advance cursor" — same as TS.
func (d *Dispatcher) Lookup(category string) Handler {
	return d.handlers[category]
}

// HandledCategories returns the registered keys, for /health + startup logging.
func (d *Dispatcher) HandledCategories() []string {
	out := make([]string, 0, len(d.handlers))
	for k := range d.handlers {
		out = append(out, k)
	}
	return out
}

// Dispatch runs the appropriate handler for row.Category and records
// the three core replay metrics (polled, replayed, duration). Single
// instrumentation choke point — avoids 10× the boilerplate that putting
// metrics inside each handler would create + keeps event-type labels
// uniform.
//
// Outcome semantics:
//   - "skipped" — no handler registered for this category. Caller still
//                 advances the cursor.
//   - "ok"      — handler returned nil.
//   - "failed"  — handler returned non-nil. Caller writes DLQ + still
//                 advances the cursor (existing behaviour).
//
// Returns the handler's return value (or nil for unknown categories) so
// callers preserve the existing DLQ-and-advance flow.
func (d *Dispatcher) Dispatch(ctx context.Context, tx pgx.Tx, row db.ProdUserLog) error {
	eventType := row.Category
	metrics.UserLogsPolledTotal.WithLabelValues(eventType).Inc()

	h := d.handlers[eventType]
	if h == nil {
		metrics.UserLogsReplayedTotal.WithLabelValues(eventType, "skipped").Inc()
		return nil
	}

	// Histogram observation wraps the handler call. NewTimer + observe-
	// on-return guarantees the bucket increment even on panic.
	timer := prometheus.NewTimer(metrics.ReplayDurationSeconds.WithLabelValues(eventType))
	err := h(ctx, tx, row)
	timer.ObserveDuration()

	outcome := "ok"
	if err != nil {
		outcome = "failed"
	}
	metrics.UserLogsReplayedTotal.WithLabelValues(eventType, outcome).Inc()
	return err
}

// MarkAlreadyReplayed records an idempotency skip on mirror_id_map.
// Called by the caller before Dispatch when the row was already
// replayed in a prior tick. Keeps polled vs replayed counters honest.
func (d *Dispatcher) MarkAlreadyReplayed(eventType string) {
	metrics.UserLogsPolledTotal.WithLabelValues(eventType).Inc()
	metrics.UserLogsReplayedTotal.WithLabelValues(eventType, "skipped").Inc()
}
