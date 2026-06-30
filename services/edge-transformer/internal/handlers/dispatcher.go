// Package handlers owns per-routing-key processing.
//
// This skeleton: only a placeholder (Shadow) is registered. Returning nil
// makes the consumer ack the message — perfect for a Phase 2 shadow-mode
// boot where we want to verify topology + connectivity without writing
// anything anywhere. No transforms, no DB, no outbound HTTP.
//
// Reuse rule (ADR-0009 Errata Correction 2): the Dispatcher shape +
// Handler signature is lifted from oeecloud-worker's
// internal/handlers/dispatcher.go. The Phase 2 real handlers register
// under per-tenant routing keys EXACTLY like oeecloud-worker did after
// PR #56 silent-coverage-gap fix — `register("plc.normalized.<tenant>")`
// for every tenant in the discovered set. Failing to per-tenant-register
// is the failure mode PR #56 exists to prevent.
//
// Future handler skeleton (ADR-0009 Phase 2):
//
//	"plc.normalized.<tenant>"  → transformPLCData  (Calc_Counters etc., ported
//	                                                from Node-RED's Sparkplug
//	                                                subflow; covered by ADR-0008
//	                                                comparator validation)
package handlers

import (
	"context"
	"log/slog"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Handler processes one delivery. Return nil to ack, error to retry
// via the DLX → retry queue → re-deliver cycle.
type Handler func(ctx context.Context, d *amqp.Delivery) error

type Dispatcher struct {
	logger   *slog.Logger
	handlers map[string]Handler
	fallback Handler
}

func NewDispatcher(logger *slog.Logger) *Dispatcher {
	return &Dispatcher{
		logger:   logger,
		handlers: make(map[string]Handler),
		fallback: Shadow(logger),
	}
}

func (d *Dispatcher) Register(routingKey string, h Handler) {
	d.handlers[routingKey] = h
}

// Handle dispatches by routing key. Unknown keys go to the fallback
// (Shadow) so the cursor advances + we observe what's arriving rather
// than nacking everything to retry.
//
// CRITICAL (ADR-0009 reuse rule, PR #56 lesson): if you add real handlers
// in Phase 2, the FALLBACK becomes the silent-failure surface — a tenant
// routing change that misses the per-tenant Register() call will fall
// through to Shadow, log+ack, and silently drop the transform. Either:
//   (a) keep Shadow as fallback ONLY during the shadow phase, OR
//   (b) flip fallback to a noisy "unknown routing key" handler that
//       nacks + alerts in Phase 2+.
// The choice should be made deliberately in the Phase 2 PR, not by
// inheriting this scaffold's default.
func (d *Dispatcher) Handle(ctx context.Context, msg *amqp.Delivery) error {
	if h, ok := d.handlers[msg.RoutingKey]; ok {
		return h(ctx, msg)
	}
	return d.fallback(ctx, msg)
}
