// Package capture is the ADR-0045 Phase-2b live-capture OBSERVE mechanism: when
// a tenant is in the observe posture, the agent records which count indices +
// topics actually arrive from the client's live tee, so CS can promote a
// descriptor's count-index entries from `inferred` to `confirmed` ("PLC facts
// are observed, not typed", ADR-0045 §2.4b).
//
// Design (see the task/ADR):
//   - GATE: client_descriptors.status == "captured" (the observe posture). A
//     tenant not in that status records NOTHING — zero hot-path overhead. A
//     master flag (AGENT_CAPTURE_ENABLED, default off) dark-gates the whole path.
//   - RECORD: for each count-bearing tag, buffer an in-memory delta keyed by
//     (topic, count_index); a periodic flush upserts the deltas into
//     capture_observations (the DB accumulates the running totals).
//   - FAIL-SAFE: any DB/parse error → log + drop the evidence. Capture is
//     best-effort DQ evidence, NEVER the data plane — it must never block or
//     crash ingest.
//
// The recorder owns only buffering + flush cadence; the DB write is a Sink
// (pgsink in capture_pg.go), so the buffer/flush logic is unit-testable against
// a mock sink with no DB.
package capture

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// StatusCaptured is the client_descriptors.status value that puts a tenant in
// the OBSERVE posture. Named constant so the cross-repo contract (edge-api
// writes it, the agent reads it) is one spelled-out token — the same discipline
// as agentcfg.StatusCutover.
const StatusCaptured = "captured"

// ShouldObserve is the PURE observe-posture gate (no IO — unit-testable). The
// master flag must be on AND the tenant must be in the captured status. Either
// off ⇒ no recording, so a non-capturing tenant pays nothing.
func ShouldObserve(captureEnabled bool, status string) bool {
	return captureEnabled && status == StatusCaptured
}

// Sink persists a batch of observation deltas. The DB implementation upserts on
// (id_enterprise, topic, count_index), summing observed_count and widening the
// first/last-seen window; a mock implements it for tests.
type Sink interface {
	Upsert(ctx context.Context, enterpriseID int, deltas []Delta) error
}

// Delta is one flush-interval accumulation for a single count channel: the
// parsed observation plus the window + hit count seen since the last flush. The
// DB folds it into the persistent row.
type Delta struct {
	Observation
	FirstSeen time.Time
	LastSeen  time.Time
	Count     int64
}

// key identifies a count channel within a tenant (topic + index; the leaf is a
// value, not part of the identity — mirrors the DB upsert key).
type key struct {
	topic string
	idx   int
}

// Recorder buffers count observations and periodically flushes deltas to a Sink.
// Safe for concurrent Observe calls (the ingest path is single-goroutine today,
// but the mutex keeps it correct if that changes).
type Recorder struct {
	enterpriseID int
	templates    []string // count-leaf templates ({idx}-bearing) from the profile
	sink         Sink
	logger       *slog.Logger
	now          func() time.Time // injectable clock for tests

	// onObserved is called once per recorded observation (a count-bearing tag
	// that parsed) — wires the sparkplug_agent_capture_observations_total metric
	// without this package importing prometheus. Nil ⇒ no-op.
	onObserved func()

	mu  sync.Mutex
	buf map[key]*Delta
}

// Config builds a Recorder. Templates should already be the count-leaf subset
// (use CountLeafTemplates); an empty set means the recorder can never match a
// tag (it no-ops), which is the correct behaviour for a tenant with no declared
// count metrics.
type Config struct {
	EnterpriseID int
	Templates    []string
	Sink         Sink
	Logger       *slog.Logger
	// OnObserved is incremented once per recorded observation. Optional.
	OnObserved func()
	// Now overrides the clock (tests). Nil ⇒ time.Now.
	Now func() time.Time
}

// New builds a Recorder.
func New(cfg Config) *Recorder {
	nowFn := cfg.Now
	if nowFn == nil {
		nowFn = time.Now
	}
	return &Recorder{
		enterpriseID: cfg.EnterpriseID,
		templates:    cfg.Templates,
		sink:         cfg.Sink,
		logger:       cfg.Logger,
		now:          nowFn,
		onObserved:   cfg.OnObserved,
		buf:          make(map[key]*Delta),
	}
}

// Observe records one raw tag's FULL SparkPlug name (packml_topic + suffix). A
// non-count tag (no matching count-leaf template) is a cheap no-op. Never
// returns an error and never blocks on IO — buffering only.
func (r *Recorder) Observe(fullName string) {
	if r == nil {
		return
	}
	obs, ok := ParseObservation(fullName, r.templates)
	if !ok {
		return
	}
	now := r.now()
	k := key{topic: obs.Topic, idx: obs.CountIndex}

	r.mu.Lock()
	d, seen := r.buf[k]
	if !seen {
		d = &Delta{Observation: obs, FirstSeen: now}
		r.buf[k] = d
	}
	d.LastSeen = now
	d.Count++
	// Keep the leaf fresh (identical across repeats in practice).
	d.MetricSuffix = obs.MetricSuffix
	r.mu.Unlock()

	if r.onObserved != nil {
		r.onObserved()
	}
}

// Flush drains the buffered deltas and upserts them via the Sink. On a sink
// error the batch is DROPPED (best-effort evidence — never re-queued to grow
// unbounded, never surfaced to the caller). Returns the number of channels
// flushed (0 when the buffer was empty).
func (r *Recorder) Flush(ctx context.Context) int {
	r.mu.Lock()
	if len(r.buf) == 0 {
		r.mu.Unlock()
		return 0
	}
	deltas := make([]Delta, 0, len(r.buf))
	for _, d := range r.buf {
		deltas = append(deltas, *d)
	}
	r.buf = make(map[key]*Delta) // reset — the DB now owns the running totals
	r.mu.Unlock()

	if err := r.sink.Upsert(ctx, r.enterpriseID, deltas); err != nil {
		// Fail-safe: log + drop. The deltas are gone (not re-buffered) so a
		// persistently-broken sink can never grow memory; the next flush starts
		// clean. Capture is evidence, not the data plane.
		if r.logger != nil {
			r.logger.Warn("capture flush dropped — sink error (best-effort evidence, ingest unaffected)",
				"err", err, "channels", len(deltas))
		}
		return 0
	}
	return len(deltas)
}

// Run flushes on a ticker until ctx is cancelled, then does a final drain so a
// clean shutdown doesn't lose the last interval's evidence.
func (r *Recorder) Run(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			// Final best-effort drain on a bounded context (ctx is already done).
			fctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			r.Flush(fctx)
			cancel()
			return
		case <-t.C:
			r.Flush(ctx)
		}
	}
}
