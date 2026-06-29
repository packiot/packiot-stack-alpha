package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// The 5 mirror-worker metrics. Declared as package-level vars so
// callers in /internal/replay/dispatcher.go + cmd/mirror-worker-go/main.go
// can `metrics.UserLogsPolledTotal.WithLabelValues(...)` directly,
// without threading a *Metrics struct through every constructor.
//
// Trade-off vs oeecloud-worker's struct-based approach: simpler call
// sites + slightly tighter test isolation cost (tests that exercise
// the increment paths share the package registry). The mirror worker
// has no factory cycle between metrics and writers (unlike oeecloud's
// custom collectors that read from amqp.Consumer atomic counters), so
// the simpler pattern fits.
var (
	// UserLogsPolledTotal — incremented in dispatcher when a row arrives
	// for processing, before the handler runs. Counts attempts, not
	// successes. Pair with UserLogsReplayedTotal{outcome="ok"} to derive
	// success ratio per event_type.
	UserLogsPolledTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_user_logs_polled_total",
		Help: "Prod user_logs rows received by the dispatcher, by category. Increments before handler runs.",
	}, []string{"event_type"})

	// UserLogsReplayedTotal — incremented after the handler returns.
	// outcome=ok: handler returned nil; outcome=failed: handler returned
	// non-nil error → row will be DLQ-d, cursor still advances; outcome=
	// skipped: no handler registered for the category OR the row was
	// already replayed (mirror_id_map idempotency hit).
	UserLogsReplayedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_user_logs_replayed_total",
		Help: "Replay outcomes by event_type + outcome (ok|failed|skipped).",
	}, []string{"event_type", "outcome"})

	// ReplayDurationSeconds — wall-clock time spent inside a handler,
	// from dispatch to return. Includes translate.* DB SELECTs + the
	// HTTP POST to staging edge-api + any DLQ/mapping inserts. The
	// p95 here is the right number to compare against
	// cfg.PerPostDelayMs to size batching.
	//
	// Buckets cover the expected range: most handlers do 1-3 DB
	// SELECTs + 1 HTTP POST → ~10-200ms p50, with occasional 1-5s
	// outliers when prod has to do an interval-overlap event match.
	ReplayDurationSeconds = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "mirror_worker_replay_duration_seconds",
		Help:    "Per-handler replay duration (dispatch → return). Includes ID translation + HTTP POST.",
		Buckets: []float64{0.001, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
	}, []string{"event_type"})

	// CursorLagSeconds — observability for "how far behind prod are we".
	// Computed as now() - max(prod user_logs.ts_event ≤ cursor) at the
	// end of each poll. Stays near zero when the worker is healthy +
	// drifts up if prod publishes faster than we replay, or if we crash.
	//
	// Note: this is wall-clock lag, NOT cursor distance in rows.
	// Distance-in-rows is also useful but masks idle prod periods; lag
	// is what a human cares about ("is staging within 2 minutes of
	// prod?"). Distance is derivable from prod user_logs cardinality
	// vs cursor if needed later.
	CursorLagSeconds = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_cursor_lag_seconds",
		Help: "Seconds between now() and the ts_event of the last replayed prod user_logs row.",
	})

	// IDMapCacheSize — rows in mirror_id_map for this worker's source
	// label. Tracks mapping accumulation; useful as a growth signal +
	// for sizing future in-process cache work (today every translate.*
	// call hits Postgres, no in-process LRU).
	IDMapCacheSize = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_id_map_cache_size",
		Help: "Rows in mirror_id_map for this worker's source. Updated on poll.",
	})

	// ReconcilerRunsTotal — bumps once per reconciliation pass, regardless
	// of outcome. outcome=ok: pass completed (may have created 0 POs if
	// staging was already in sync); outcome=failed: top-level error (prod
	// fetch died, staging fetch died) before any individual ensure ran.
	ReconcilerRunsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_reconciler_runs_total",
		Help: "EnsureActivePOs passes by outcome (ok|failed).",
	}, []string{"outcome"})

	// ReconcilerPOsTotal — per-PO outcomes within a pass. created=PO was
	// missing on staging + create+start+map all succeeded; skipped=PO was
	// already active on staging (no work); failed=translate/POST/map err.
	// Pair with ReconcilerRunsTotal{outcome="ok"} to derive per-pass
	// success ratio.
	ReconcilerPOsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_reconciler_pos_total",
		Help: "Per-PO reconciliation outcomes (created|failed|skipped).",
	}, []string{"outcome"})

	// ReconcilerActiveDriftPOs — gauge of prod active POs missing from
	// staging at the end of the last reconciliation pass. Zero means
	// we caught up; non-zero on a sustained basis means the per-pass
	// cap is too low or staging edge-api is rejecting some POs.
	ReconcilerActiveDriftPOs = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_reconciler_active_drift_pos",
		Help: "Prod active POs missing on staging at end of last reconciler pass.",
	})

	// ReconcilerValuesSyncedTotal — bumps once per (prod_po, staging_po)
	// equipment_values delta INSERT during a value-sync tick. outcome=ok
	// when the delta was applied; outcome=failed when the INSERT errored
	// (transient DB hiccup, schema drift, etc.). Pair with the value-sync
	// log line "value sync tick complete" for tick-level visibility.
	ReconcilerValuesSyncedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_reconciler_values_synced_total",
		Help: "equipment_values delta INSERTs by outcome (ok|failed) during value sync.",
	}, []string{"outcome"})

	// ReconcilerEventsTotal — bumps once per prod equipment_event processed
	// by the events sync. outcome=created: row inserted on staging + mapping
	// written; outcome=skipped: equipment unmapped (no packml_register) or
	// mapping already exists from an earlier pass; outcome=failed: INSERT
	// errored (FK violation, trigger refusal, etc.).
	ReconcilerEventsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_reconciler_events_total",
		Help: "Per-prod-event outcomes during equipment_events sync (created|skipped|failed).",
	}, []string{"outcome"})

	// ReconcilerEventsCursor — gauge of the highest prod id_equipment_event
	// the events reconciler has processed. Monotonically increasing while
	// the worker runs. Zero means the worker hasn't done a successful pass
	// yet OR the cursor was reset to 0 in mirror_replay_cursor.
	ReconcilerEventsCursor = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_reconciler_events_cursor",
		Help: "Highest prod id_equipment_event the events reconciler has processed.",
	})

	// DLQRetryAttemptsTotal — bumps once per attempted DLQ retry. outcome=
	// succeeded: replay succeeded → row deleted from mirror_replay_dlq;
	// failed: replay returned an error → retry_attempts bumped, last_retry_at
	// set; permanent: row's prod user_log no longer exists (gone after a
	// data purge) → DLQ row stays, won't retry further;
	// exhausted: retry_attempts hit the cap → no further attempts will fire
	// (counted once per tick when the row is observed past the cap).
	DLQRetryAttemptsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_dlq_retry_attempts_total",
		Help: "DLQ retry outcomes (succeeded|failed|permanent|exhausted).",
	}, []string{"outcome"})

	// DLQDepth — gauge of mirror_replay_dlq rows for this worker's source.
	// At-a-glance health indicator on the Grafana mirror dashboard. Healthy
	// steady state should hover near zero — non-zero is either stuck rows
	// (permanent failures) or a backlog the retry loop is working through.
	DLQDepth = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_dlq_depth",
		Help: "Current count of mirror_replay_dlq rows for this worker's source.",
	})

	// DLQReanimatedTotal — counts DLQ rows the reanimator loop reset
	// from retry_attempts >= cap back to retry_attempts=0 because their
	// underlying entity became mappable (events reconciler caught up).
	// A non-zero value here means "the retry-cap logic was tripped by
	// a transient reconciler-catch-up gap, not a permanent failure" —
	// the existing DLQRetrier picks each one up on its next tick.
	DLQReanimatedTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "mirror_worker_dlq_reanimated_total",
		Help: "DLQ rows reset to retry_attempts=0 by the reanimator loop because their target became mappable.",
	})
)

func init() {
	// Standard Go runtime + process collectors — same as oeecloud-worker.
	// Free goroutine count + GC stats + RSS memory; lets us spot leaks
	// or stuck handlers without bolting on bespoke instrumentation.
	Registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	// The 5 worker-domain metrics + 6 reconciler metrics (PO existence x3,
	// values x1, events x2).
	Registry.MustRegister(
		UserLogsPolledTotal,
		UserLogsReplayedTotal,
		ReplayDurationSeconds,
		CursorLagSeconds,
		IDMapCacheSize,
		ReconcilerRunsTotal,
		ReconcilerPOsTotal,
		ReconcilerActiveDriftPOs,
		ReconcilerValuesSyncedTotal,
		ReconcilerEventsTotal,
		ReconcilerEventsCursor,
		DLQRetryAttemptsTotal,
		DLQDepth,
		DLQReanimatedTotal,
	)
}
