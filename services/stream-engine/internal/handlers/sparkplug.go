package handlers

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/pocontrol"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/rollup"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/writers"
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
	parsed               atomic.Uint64
	legacyDropped        atomic.Uint64
	doubleEncodedDropped atomic.Uint64
	legacyIngest         bool
	batchWrites          *prometheus.CounterVec
	queriesSent          atomic.Uint64
	queriesAcked         atomic.Uint64
	skippedUnk           atomic.Uint64
	buildErrors          atomic.Uint64
	execErrors           atomic.Uint64
	clampDQErrSample     atomic.Uint64 // samples the best-effort DQ side-write failure log
	shadowAbsentSample   atomic.Uint64 // samples the swallowed shadow_go_port-absent log

	pool            *pgxpool.Pool
	analyticsPool   *pgxpool.Pool // may be nil — set only if POSTGRES_ANALYTICS_DB_NAME configured
	equipmentValues *writers.EquipmentValues
	unsMetrics      *writers.UnsMetrics
	poParameter     *writers.POParameter
	poControl       *pocontrol.Handler // nil = 10.3 disabled
	logger          *slog.Logger
}

func NewSparkplugHandler(
	pool *pgxpool.Pool,
	analyticsPool *pgxpool.Pool,
	ev *writers.EquipmentValues,
	uns *writers.UnsMetrics,
	po *writers.POParameter,
	logger *slog.Logger,
) *SparkplugHandler {
	return &SparkplugHandler{
		pool:            pool,
		analyticsPool:   analyticsPool,
		equipmentValues: ev,
		unsMetrics:      uns,
		poParameter:     po,
		logger:          logger,
	}
}

// SetLegacyIngest wires the 10.9 flag: false → unparseable messages
// on the shared routing key are dropped (counted), not retried.
func (h *SparkplugHandler) SetLegacyIngest(enabled bool) { h.legacyIngest = enabled }

// SetWriteMetric wires the per-destination write counter (flow boards).
func (h *SparkplugHandler) SetWriteMetric(vec *prometheus.CounterVec) { h.batchWrites = vec }

// destForSource names the flow a source_type routes to, for metrics.
func destForSource(sourceType string) string {
	switch sourceType {
	case "go":
		return "f2_shadow_go_port"
	case "refactored":
		return "f3_packiot_analytics"
	default:
		return "f1_public"
	}
}

// tenantOf derives the tenant (group_id) from a payload: the lowercased first
// segment of the first metric's topic, matching packml_register tenant
// discovery (lower(split_part(packml_topic,'/',1))). Bounded cardinality (one
// per onboarded client) so it is safe as a Prometheus label — it isolates a
// single tenant's per-flow write rate, which the aggregate dest counter can't.
func tenantOf(p *sparkplug.Payload) string {
	for i := range p.Metrics {
		if name := p.Metrics[i].Name; name != "" {
			if idx := strings.IndexByte(name, '/'); idx > 0 {
				return strings.ToLower(name[:idx])
			}
			return strings.ToLower(name)
		}
	}
	return "unknown"
}

func (h *SparkplugHandler) LegacyDroppedCount() uint64 { return h.legacyDropped.Load() }

// DoubleEncodedDroppedCount is the number of double-encoded (JSON-string-of-JSON)
// deliveries dropped by the poison-storm guard. Non-zero means a producer on the
// oee exchange is double-marshaling envelopes — investigate the producer (the
// value should stay flat at 0 now that #475/#22 removed the known one).
func (h *SparkplugHandler) DoubleEncodedDroppedCount() uint64 { return h.doubleEncodedDropped.Load() }

// bodyPreview renders up to n bytes of a raw AMQP body for a log line. The
// double-encode guard logs this so ops can eyeball the offending shape without
// dumping multi-KB payloads into Loki.
func bodyPreview(body []byte, n int) string {
	if len(body) > n {
		return string(body[:n])
	}
	return string(body)
}

// Handle is the Handler signature consumed by Dispatcher.
func (h *SparkplugHandler) Handle(ctx context.Context, d *amqp.Delivery) error {
	p, err := sparkplug.Parse(d.Body)
	if err != nil {
		// A DOUBLE-ENCODED envelope (a JSON string of JSON — `"{...}"`) is
		// DETERMINISTIC poison: the delivered bytes are fixed, so every
		// nack→DLX→redeliver re-fails identically. Nack-retrying it (which the
		// legacyIngest=true branch below does) is a pure poison storm — this is
		// the #89/#92 stall shape (`cannot unmarshal string into ...Payload`,
		// ~2/s on sparkplug.data). Drop + count + sampled log, NEVER retry —
		// the same "deterministic parse failure ⇒ skip, don't nack" rule as the
		// non-numeric-value guard (#449). Independent of legacyIngest because no
		// valid envelope is EVER a bare JSON string; the producer that emitted
		// this shape was already removed in #475/#22 and this is the standing
		// consumer-side backstop against any residual or future double-encoder.
		if sparkplug.IsJSONStringBody(d.Body) {
			if n := h.doubleEncodedDropped.Add(1); n%64 == 1 {
				h.logger.Warn("sparkplug: double-encoded envelope (JSON string of JSON) — dropping, not retrying (poison-storm guard; sampled 1/64)",
					slog.String("routing_key", d.RoutingKey),
					slog.Int("body_len", len(d.Body)),
					slog.String("body_preview", bodyPreview(d.Body, 80)),
				)
			}
			return nil
		}
		if !h.legacyIngest {
			// 10.9: residual nodered legacy publishes (heartbeats etc.)
			// share the routing key with envelopes but not the schema.
			// With legacy ingest retired they are noise — drop with a
			// counter instead of churning retry/failed queues.
			h.legacyDropped.Add(1)
			return nil
		}
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
	tenant := tenantOf(p)

	// Build phase — collect one Query per metric into the batch.
	batch := &pgx.Batch{}
	descs := make([]string, 0, len(p.Metrics))
	var firstErr error
	// clampEvents accumulates increment-sanity-clamp rejections (usually
	// none). They are side-written as data_quality_event rows AFTER the
	// batch, best-effort — never in the ingest batch, so a missing DQ table
	// can never nack the delivery (poison-storm guard).
	var clampEvents []*writers.ClampEvent
	for i := range p.Metrics {
		m := &p.Metrics[i]
		kind := m.Classify()

		var q *writers.Query
		var shiftQ *writers.Query
		var eventQ *writers.Query
		var rawQ *writers.Query      // ADR-0036 B1 Bronze append (nil unless BRONZE_RAW_APPEND)
		var eventRawQ *writers.Query // ADR-0036 B1 Bronze event append (nil unless flag on)
		var clampEv *writers.ClampEvent
		var buildErr error

		// ADR-0010 10.3 slice 1: PO lifecycle params run their own tx
		// (SELECT-then-decide + multi-statement commands) — not
		// batchable. Drop-on-failure semantics live inside Execute.
		// SHADOW PATHS ONLY (like shift fill + event mint): on Flow 1,
		// shadow-mirror already replays prod's PO actions — running
		// lifecycle commands there too would be a double-writer
		// collision (the sole-writer lesson). Gate lifts at
		// consolidation, when Node-RED and the mirror replays retire.
		if h.poControl != nil && p.SourceType != "" && kind == sparkplug.KindParameter &&
			m.ID != nil && pocontrol.Handles(int(*m.ID)) {
			_ = h.poControl.Execute(ctx, pool, m, schema)
			continue
		}

		switch {
		case h.equipmentValues.CanWrite(kind):
			// ADR-0014 shift fill (flag-gated, SHIFT_FILL_FOLDED — DBA
			// bake-safe 2026-07-13, zero live triggers on public +
			// packiot_analytics). Two mutually-exclusive paths, selected by
			// the writer's foldShift flag:
			//   folded  → Build() writes the shift columns INSIDE the
			//             UPSERT and BuildShiftFill returns nil, halving
			//             the per-metric statement count (~60→~40).
			//   legacy  → Build() omits the columns and BuildShiftFill
			//             queues a separate companion UPDATE (below).
			// Both preserve identical id_shift/id_shift_hour/ts_value_
			// production values (keep-existing-else-fill COALESCE + the
			// session-tz ts_value::date cast). The Go resolver is the sole
			// shift writer on ALL routes now (the F1 trigger is retired).
			q, clampEv, buildErr = h.equipmentValues.Build(ctx, m, p.Gateway, schema)
			if clampEv != nil {
				clampEvents = append(clampEvents, clampEv)
			}
			if buildErr == nil && q != nil {
				// Returns nil under the fold flag (skip the separate UPDATE).
				shiftQ, _ = h.equipmentValues.BuildShiftFill(ctx, m, schema)
				// ADR-0036 B1 medallion Bronze append (flag-gated,
				// BRONZE_RAW_APPEND). Returns nil when the flag is off, so
				// nothing extra is queued and the batch is byte-identical.
				// Same schema/pool as the merged UPSERT → symmetric to whatever
				// F2/F3 destination this delivery routes to.
				rawQ, _ = h.equipmentValues.BuildRawAppend(ctx, m, schema)
				if p.SourceType != "" {
					// Event mint stays shadow-only: F1's EVENT trigger
					// remains its writer until the §6 flip.
					eventQ, _ = h.equipmentValues.BuildEventMint(ctx, m, schema)
					eventRawQ, _ = h.equipmentValues.BuildEventMintRaw(ctx, m, schema)
				}
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
			// statements sequentially on one connection. Present only on
			// the legacy (unfolded) path; nil when SHIFT_FILL_FOLDED=true.
			batch.Queue(shiftQ.SQL, shiftQ.Args...)
			descs = append(descs, shiftQ.Desc)
		}
		if eventQ != nil {
			batch.Queue(eventQ.SQL, eventQ.Args...)
			descs = append(descs, eventQ.Desc)
		}
		// ADR-0036 B1 Bronze appends — queued after the merged writes so the
		// operational UPSERT is unaffected by an append failure ordering-wise.
		// nil unless BRONZE_RAW_APPEND is on.
		if rawQ != nil {
			batch.Queue(rawQ.SQL, rawQ.Args...)
			descs = append(descs, rawQ.Desc)
		}
		if eventRawQ != nil {
			batch.Queue(eventRawQ.SQL, eventRawQ.Args...)
			descs = append(descs, eventRawQ.Desc)
		}
	}

	if batch.Len() == 0 {
		// Nothing to write (all metrics skipped or build-failed).
		if h.batchWrites != nil {
			h.batchWrites.WithLabelValues(destForSource(p.SourceType), tenant, "empty_batch").Inc()
		}
		return firstErr
	}

	// Send phase — one round-trip for ALL collected queries.
	br := pool.SendBatch(ctx, batch)
	defer br.Close()

	h.queriesSent.Add(uint64(batch.Len()))
	dest := destForSource(p.SourceType)
	for i := 0; i < batch.Len(); i++ {
		if _, err := br.Exec(); err != nil {
			h.execErrors.Add(1)
			if h.batchWrites != nil {
				h.batchWrites.WithLabelValues(dest, tenant, "error").Inc()
			}
			if firstErr == nil {
				firstErr = fmt.Errorf("%s: %w", descs[i], err)
			}
			// pgx note: once a batch Exec errors, subsequent Exec calls
			// on the same BatchResults may return the same error. We
			// still loop through to drain them so Close() is clean.
			continue
		}
		h.queriesAcked.Add(1)
		if h.batchWrites != nil {
			h.batchWrites.WithLabelValues(dest, tenant, "ok").Inc()
		}
	}

	// Increment-sanity-clamp observability: side-write one data_quality_event
	// per rejected increment. Best-effort — a failure here (e.g. the DQ table
	// absent in this schema) is LOGGED and swallowed, never returned, so it
	// can never nack the delivery. The clamp itself already zeroed the value
	// in the batch above; this is purely to make the rejection visible.
	h.emitClampDQ(ctx, pool, schema, clampEvents)

	// Missing-shadow-schema backstop (G1). A "go" leg routes to the
	// shadow_go_port comparator schema, which only exists on the staging
	// dual-flow stack. On a single-flow production stack it is absent, so
	// every write in this batch fails 42P01 (undefined_table) / 3F000
	// (invalid_schema_name). That is EXPECTED here — not a real ingest
	// failure — so swallow it and ACK the delivery instead of returning the
	// error and triggering nack → DLX → redeliver forever (a poison storm
	// that, worse, starves the real production "" legs sharing the queue).
	// firstErr is the FIRST failing Exec, i.e. the true 42P01/3F000 (the
	// followers report 25P02 in_failed_sql_transaction and never overwrite
	// it), so matching its SQLSTATE is sufficient. Belt-and-braces with the
	// decoder's SHADOW_EMIT_GO=false gate: even a stray "go" envelope can no
	// longer wedge the queue. Only shadow_go_port qualifies — public
	// (production/refactored) errors stay fatal and still nack+retry.
	if shouldSwallowShadowErr(schema, firstErr) {
		if h.shadowAbsentSample.Add(1)%64 == 1 {
			h.logger.Warn("sparkplug: shadow_go_port schema absent — 'go' comparator leg swallowed (delivery ACKed, not retried; sampled 1/64)",
				slog.String("schema", schema),
				slog.String("err", firstErr.Error()),
			)
		}
		return nil
	}

	return firstErr
}

// shouldSwallowShadowErr reports whether a batch error must be treated as the
// EXPECTED "shadow_go_port comparator schema absent" case rather than a real
// ingest failure. Only the shadow_go_port schema (the ADR-0010 "go" leg)
// qualifies, and only for a missing-relation SQLSTATE — public
// (production/refactored) errors always propagate so they still nack+retry.
func shouldSwallowShadowErr(schema string, err error) bool {
	if err == nil || schema != "shadow_go_port" {
		return false
	}
	return isMissingRelation(err)
}

// isMissingRelation matches Postgres SQLSTATE 42P01 (undefined_table) and
// 3F000 (invalid_schema_name) via pgconn.PgError — the two codes a write to a
// nonexistent shadow_go_port.<table> produces. Structured SQLSTATE match, not
// string matching, so a table named "...does not exist..." can't false-positive.
func isMissingRelation(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == "42P01" || pgErr.Code == "3F000"
	}
	return false
}

// clampDQInsertSQL upserts one INVARIANT_CLAMPED_INCREMENT event into the
// flow schema's data_quality_event (migration 34), reusing the same dedup
// index the DQ scanner uses so a redelivery refreshes-in-place. %s = schema.
const clampDQInsertSQL = `
	INSERT INTO %s.data_quality_event
	    (id_enterprise, id_equipment, grain, bucket_ts, rule, observed_value, severity)
	VALUES ($1, $2, $3, $4, $5, $6, 'error')
	ON CONFLICT (id_enterprise, COALESCE(id_equipment, 0), grain, bucket_ts, rule)
	DO UPDATE SET observed_value = EXCLUDED.observed_value,
	              severity       = EXCLUDED.severity,
	              detected_at     = now()`

// emitClampDQ side-writes a data_quality_event per increment-sanity-clamp
// rejection. BEST-EFFORT: every failure is logged and swallowed so ingest is
// never blocked (the clamp already zeroed the value in the committed batch).
// One Exec per event — clamps are rare, so the extra round-trips are noise.
func (h *SparkplugHandler) emitClampDQ(ctx context.Context, pool *pgxpool.Pool, schema string, events []*writers.ClampEvent) {
	if len(events) == 0 {
		return
	}
	sql := fmt.Sprintf(clampDQInsertSQL, schema)
	for _, ev := range events {
		// grain encodes the counter stream so the three counters can coexist
		// at the same equipment-second under the dedup index.
		grain := "ingest_" + clampGrainSuffix(ev.Kind)
		if _, err := pool.Exec(ctx, sql,
			ev.IDEnterprise, ev.IDEquipment, grain, ev.BucketTS,
			string(rollup.DQRuleInvariantClampedIncrement), ev.Observed,
		); err != nil {
			// Best-effort: swallow (the value was already clamped in the
			// committed batch). Sample the log 1/64 so a schema whose
			// data_quality_event table is absent (e.g. shadow_go_port, which the
			// DQ scanner also doesn't populate) can't spam a Warn per phantom.
			if h.clampDQErrSample.Add(1)%64 == 1 {
				h.logger.Warn("increment clamp: data_quality_event side-write failed (swallowed; sampled 1/64)",
					slog.String("schema", schema),
					slog.Int("id_equipment", ev.IDEquipment),
					slog.Float64("observed", ev.Observed),
					slog.String("err", err.Error()),
				)
			}
		}
	}
}

// clampGrainSuffix names the counter stream for the DQ grain column.
func clampGrainSuffix(kind sparkplug.MetricKind) string {
	switch kind {
	case sparkplug.KindProdProcessedCount:
		return "net_incr"
	case sparkplug.KindProdConsumedCount:
		return "gross_incr"
	case sparkplug.KindProdDefectiveCount:
		return "scrap_incr"
	default:
		return "incr"
	}
}

// routeForSource picks the (pool, schema) tuple based on envelope
// source_type. Whitelist-driven — see comment at handler.
//
// ADR-0010 Phase 3 introduced source_type="go" → shadow_go_port schema on
// the main pool. ADR-0012 adds source_type="refactored" → shadow pool
// (packiot_analytics DB) writing to public schema, so the entire refactored
// schema can be exercised end-to-end from real live traffic without
// touching the packiot production DB.
//
// If analyticsPool is nil (POSTGRES_ANALYTICS_DB_NAME unset) and source_type
// is "refactored", we silently fall back to (main pool, public) — logged
// as a warning. Fail-safe: never route to nil.
func (h *SparkplugHandler) routeForSource(sourceType string) (*pgxpool.Pool, string) {
	switch sourceType {
	case "go":
		return h.pool, "shadow_go_port"
	case "refactored":
		if h.analyticsPool != nil {
			return h.analyticsPool, "public"
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
	Parsed               uint64 `json:"sparkplug_parsed"`
	QueriesSent          uint64 `json:"sparkplug_queries_sent"`
	QueriesAcked         uint64 `json:"sparkplug_queries_acked"`
	SkippedUnknown       uint64 `json:"sparkplug_skipped_unknown_kind"`
	BuildErrors          uint64 `json:"sparkplug_build_errors"`
	ExecErrors           uint64 `json:"sparkplug_exec_errors"`
	LegacyDropped        uint64 `json:"sparkplug_legacy_dropped"`
	DoubleEncodedDropped uint64 `json:"sparkplug_double_encoded_dropped"`
}

func (h *SparkplugHandler) Stats() SparkplugStats {
	return SparkplugStats{
		Parsed:               h.parsed.Load(),
		QueriesSent:          h.queriesSent.Load(),
		QueriesAcked:         h.queriesAcked.Load(),
		SkippedUnknown:       h.skippedUnk.Load(),
		BuildErrors:          h.buildErrors.Load(),
		ExecErrors:           h.execErrors.Load(),
		LegacyDropped:        h.legacyDropped.Load(),
		DoubleEncodedDropped: h.doubleEncodedDropped.Load(),
	}
}

// SetPOControl enables the 10.3 lifecycle handler (nil = disabled).
func (h *SparkplugHandler) SetPOControl(pc *pocontrol.Handler) { h.poControl = pc }
