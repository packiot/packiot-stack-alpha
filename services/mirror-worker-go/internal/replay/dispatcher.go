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
