package handlers

import (
	"context"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/pocontrol"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/writers"
	amqp "github.com/rabbitmq/amqp091-go"
)

// SparkplugHandler is the top-level handler for routing-key "sparkplug.data".
//
// Per-AMQP-message flow:
//
//  1. Parse JSON payload (sparkplug.Parse).
//  2. Per-metric timestamp fallback (metric.ts || payload.ts || now()).
//  3. For each metric:
//     - Classify by name (sparkplug.Metric.Classify)
//     - Ask each writer to Build() a *Query; collect non-nil ones into
//     a pgx.Batch.
//     - Unknown kinds: log + skip (don't fail the whole batch).
//  4. SendBatch the whole batch as ONE round-trip to postgres.
//  5. Iterate batch.Exec() results; capture the first error.
//  6. Return first error → consumer nacks → DLX → retry. Re-processing
//     is safe because all writes are UPSERTs (ON CONFLICT DO UPDATE).
//
// Pre-batch design did one pool.Exec per metric → N round-trips per
// delivery (~5-6 typical CPACK payload). Batching cuts that to 1
// round-trip, which is ~5x less DB latency per delivery.
type SparkplugHandler struct {
	parsed       atomic.Uint64
	queriesSent  atomic.Uint64
	queriesAcked atomic.Uint64
	skippedUnk   atomic.Uint64
	buildErrors  atomic.Uint64
	execErrors   atomic.Uint64

	pool            *pgxpool.Pool
	shadowPool      *pgxpool.Pool // may be nil — set only if POSTGRES_SHADOW_DB_NAME configured
	equipmentValues *writers.EquipmentValues
	unsMetrics      *writers.UnsMetrics
	poParameter     *writers.POParameter
	poControl       *pocontrol.Handler // nil = 10.3 disabled
	logger          *slog.Logger
}

func NewSparkplugHandler(
	pool *pgxpool.Pool,
	shadowPool *pgxpool.Pool,
	ev *writers.EquipmentValues,
	uns *writers.UnsMetrics,
	po *writers.POParameter,
	logger *slog.Logger,
) *SparkplugHandler {
	return &SparkplugHandler{
		pool:            pool,
		shadowPool:      shadowPool,
		equipmentValues: ev,
		unsMetrics:      uns,
		poParameter:     po,
		logger:          logger,
	}
}

// Handle is the Handler signature consumed by Dispatcher.
func (h *SparkplugHandler) Handle(ctx context.Context, d *amqp.Delivery) error {
	p, err := sparkplug.Parse(d.Body)
	if err != nil {
		// Bad JSON is terminal — consumer nacks; after MaxRetries the
		// message lands in oee-failed for inspection.
		return err
	}
	h.parsed.Add(1)

	// Per-metric timestamp fallback — Sparkplug spec allows metrics
	// without their own timestamp (only payload-level required). Without
	// this, writers' time.UnixMilli(0).Truncate(...) lands rows at
	// 1970-01-01. Mirrors Node-RED's fallback chain.
	nowMs := time.Now().UnixMilli()
	for i := range p.Metrics {
		if p.Metrics[i].Timestamp == 0 {
			p.Metrics[i].Timestamp = p.Timestamp
		}
		if p.Metrics[i].Timestamp == 0 {
			p.Metrics[i].Timestamp = nowMs
		}
	}

	// ADR-0010 Phase 3 + ADR-0012 shadow-mode routing.
	// Route both pool + schema by envelope.source_type. Whitelist-driven.
	//   ""           → (main pool, "public")             — production
	//   "go"         → (main pool, "shadow_go_port")     — ADR-0010 Phase 3
	//   "refactored" → (shadow pool, "public")           — ADR-0012 Phase 3
	// Fail-safe: unknown source_type falls back to (main pool, public).
	// Shadow pool nil-fallback: if source_type="refactored" but no shadow
	// pool configured, silently downgrade to main pool. Logged.
	pool, schema := h.routeForSource(p.SourceType)

	// Build phase — collect one Query per metric into the batch.
	batch := &pgx.Batch{}
	descs := make([]string, 0, len(p.Metrics))
	var firstErr error
	for i := range p.Metrics {
		m := &p.Metrics[i]
		kind := m.Classify()

		var q *writers.Query
		var shiftQ *writers.Query
		var eventQ *writers.Query
		var buildErr error

		// ADR-0010 10.3 slice 1: PO lifecycle params run their own tx
		// (SELECT-then-decide + multi-statement commands) — not
		// batchable. Drop-on-failure semantics live inside Execute.
		if h.poControl != nil && kind == sparkplug.KindParameter &&
			m.ID != nil && pocontrol.Handles(*m.ID) {
			_ = h.poControl.Execute(ctx, pool, m, schema)
			continue
		}

		switch {
		case h.equipmentValues.CanWrite(kind):
			q, buildErr = h.equipmentValues.Build(ctx, m, p.Gateway, schema)
			// ADR-0014 Phase 2: shadow paths get the Go-ported shift fill
			// as a companion UPDATE in the same batch. Flow 1
			// (source_type "") keeps the PL/pgSQL trigger during the
			// comparator bake — filling there would make the bake compare
			// Go against Go.
			if buildErr == nil && q != nil && p.SourceType != "" {
				shiftQ, _ = h.equipmentValues.BuildShiftFill(ctx, m, schema)
				// ADR-0010 10.4: shadow paths mint the event row prod's
				// pipeline mints (Flow 1's trigger covers Flow 1).
				eventQ, _ = h.equipmentValues.BuildEventMint(ctx, m, schema)
			}
		case h.unsMetrics.CanWrite(kind):
			q, buildErr = h.unsMetrics.Build(ctx, m, p.Gateway, schema)
		case h.poParameter.CanWrite(kind):
			q, buildErr = h.poParameter.Build(ctx, m, p.Gateway, schema)
		default:
			h.skippedUnk.Add(1)
			continue
		}

		if buildErr != nil {
			h.buildErrors.Add(1)
			if firstErr == nil {
				firstErr = buildErr
			}
			continue
		}
		if q == nil {
			// Skip — typically topic not registered in packml_register.
			continue
		}
		batch.Queue(q.SQL, q.Args...)
		descs = append(descs, q.Desc)
		if shiftQ != nil {
			// Ordered right after its UPSERT — pgx.Batch executes
			// statements sequentially on one connection.
			batch.Queue(shiftQ.SQL, shiftQ.Args...)
			descs = append(descs, shiftQ.Desc)
		}
		if eventQ != nil {
			batch.Queue(eventQ.SQL, eventQ.Args...)
			descs = append(descs, eventQ.Desc)
		}
	}

	if batch.Len() == 0 {
		// Nothing to write (all metrics skipped or build-failed).
		return firstErr
	}

	// Send phase — one round-trip for ALL collected queries.
	br := pool.SendBatch(ctx, batch)
	defer br.Close()

	h.queriesSent.Add(uint64(batch.Len()))
	for i := 0; i < batch.Len(); i++ {
		if _, err := br.Exec(); err != nil {
			h.execErrors.Add(1)
			if firstErr == nil {
				firstErr = fmt.Errorf("%s: %w", descs[i], err)
			}
			// pgx note: once a batch Exec errors, subsequent Exec calls
			// on the same BatchResults may return the same error. We
			// still loop through to drain them so Close() is clean.
			continue
		}
		h.queriesAcked.Add(1)
	}

	return firstErr
}

// routeForSource picks the (pool, schema) tuple based on envelope
// source_type. Whitelist-driven — see comment at handler.
//
// ADR-0010 Phase 3 introduced source_type="go" → shadow_go_port schema on
// the main pool. ADR-0012 adds source_type="refactored" → shadow pool
// (packiot_shadow DB) writing to public schema, so the entire refactored
// schema can be exercised end-to-end from real live traffic without
// touching the packiot production DB.
//
// If shadowPool is nil (POSTGRES_SHADOW_DB_NAME unset) and source_type
// is "refactored", we silently fall back to (main pool, public) — logged
// as a warning. Fail-safe: never route to nil.
func (h *SparkplugHandler) routeForSource(sourceType string) (*pgxpool.Pool, string) {
	switch sourceType {
	case "go":
		return h.pool, "shadow_go_port"
	case "refactored":
		if h.shadowPool != nil {
			return h.shadowPool, "public"
		}
		h.logger.Warn("source_type=refactored but shadow pool not configured — falling back to main pool",
			slog.String("source_type", sourceType))
		return h.pool, "public"
	default:
		return h.pool, "public"
	}
}

// SparkplugStats — aggregate counters for /health JSON. Renamed fields
// reflect the build→batch split: queriesSent counts batch entries
// pushed, queriesAcked counts successful execs.
type SparkplugStats struct {
	Parsed         uint64 `json:"sparkplug_parsed"`
	QueriesSent    uint64 `json:"sparkplug_queries_sent"`
	QueriesAcked   uint64 `json:"sparkplug_queries_acked"`
	SkippedUnknown uint64 `json:"sparkplug_skipped_unknown_kind"`
	BuildErrors    uint64 `json:"sparkplug_build_errors"`
	ExecErrors     uint64 `json:"sparkplug_exec_errors"`
}

func (h *SparkplugHandler) Stats() SparkplugStats {
	return SparkplugStats{
		Parsed:         h.parsed.Load(),
		QueriesSent:    h.queriesSent.Load(),
		QueriesAcked:   h.queriesAcked.Load(),
		SkippedUnknown: h.skippedUnk.Load(),
		BuildErrors:    h.buildErrors.Load(),
		ExecErrors:     h.execErrors.Load(),
	}
}

// SetPOControl enables the 10.3 lifecycle handler (nil = disabled).
func (h *SparkplugHandler) SetPOControl(pc *pocontrol.Handler) { h.poControl = pc }
