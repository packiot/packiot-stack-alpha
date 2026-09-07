package handlers

import (
	"context"
	"log/slog"
	"sync/atomic"

	amqp "github.com/rabbitmq/amqp091-go"
)

// ShadowStats counts what the shadow handler has observed. Read by the
// metrics package via a closure (decoupling pattern — handlers don't
// import metrics). One counter per tenant is exposed via the
// per-tenant Prometheus collector in internal/metrics; this struct
// holds the in-process source of truth.
//
// TODO(ADR-0009 Phase 2): replace ShadowStats with per-writer stats
// (oeecloud-worker's POParameter writer is the template — atomic
// counters for "wrote_X" and "skipped_Y" cases, surfaced via
// RegisterPOParameterCollector). The Shadow placeholder only needs one
// counter because it does one thing (log+ack).
type ShadowStats struct {
	// Observed is the cumulative count of messages the shadow handler
	// has seen. Same shape as the consumer's `acked` counter but
	// scoped to handler-level so future writers can each have their
	// own counter without conflating with the consumer's ack count.
	Observed atomic.Uint64
}

// Shadow is the Phase 2 placeholder handler. It logs the delivery shape
// at INFO level + increments the observed counter + returns nil so the
// consumer acks. Zero side effects on the database, zero outbound
// publishes, zero state held across deliveries.
//
// TODO(ADR-0009 Phase 2): replace Shadow with real per-routing-key
// handlers. Suggested first cut: port the Calc_Counters subflow from
// edge-node-red's flows/Sparkplug.json, dual-write via the comparator
// service (ADR-0008 pattern), and only flip cutover after ≥30 days of
// zero-diff comparator output (per ADR-0009 Phase 3).
//
// SAFETY NOTE: Shadow truncates the body preview at 200 bytes to keep
// log lines bounded — full Sparkplug payloads can run several KB and
// blowing up the log volume on every delivery would saturate Promtail
// → Loki. If you need full bodies for debug, set LOG_LEVEL=debug and
// add a debug-level log line that emits the full body inside this
// function (don't change the existing line — Loki dashboards depend
// on its current shape).
func Shadow(logger *slog.Logger) Handler {
	stats := &ShadowStats{}
	return wrapShadow(logger, stats)
}

// ShadowWithStats lets callers (main.go) pass in a *ShadowStats so the
// metrics collector closure can read the counter. Same factory pattern
// as oeecloud-worker uses for its writers.
func ShadowWithStats(logger *slog.Logger, stats *ShadowStats) Handler {
	return wrapShadow(logger, stats)
}

func wrapShadow(logger *slog.Logger, stats *ShadowStats) Handler {
	return func(_ context.Context, d *amqp.Delivery) error {
		preview := d.Body
		if len(preview) > 200 {
			preview = preview[:200]
		}
		stats.Observed.Add(1)
		logger.Info("shadow: received message (no-op)",
			slog.String("routing_key", d.RoutingKey),
			slog.String("exchange", d.Exchange),
			slog.String("content_type", d.ContentType),
			slog.Int("body_len", len(d.Body)),
			slog.String("body_preview", string(preview)),
		)
		return nil
	}
}
