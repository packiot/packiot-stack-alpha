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
	// non-nil error → row will be DLQ-d (retryable), cursor still advances;
	// outcome=skipped: no handler registered for the category OR the row was
	// already replayed (mirror_id_map idempotency hit); outcome=terminal:
	// edge-api PR #148 gate permanently rejected the PO-control replay (409
	// STALE_HEAD/RANGE_CONFLICT/BEYOND_HORIZON) → row DLQ-d PRE-RETIRED, not
	// retried. Split from failed so a correctly-rejected-stale action never
	// masquerades as a stuck bug on the dashboard.
	UserLogsReplayedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_user_logs_replayed_total",
		Help: "Replay outcomes by event_type + outcome (ok|failed|skipped|terminal).",
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

	// ReconcilerFinisherTotal — per-candidate outcomes of the prod-
	// authoritative finisher pass (task #48). outcome=finished: an orphaned
	// reconcile PO was closed (segment sealed + status=3); failed: the close
	// tx errored; skipped_idempotent: already finished by a prior pass;
	// skipped_still_active: prod's fresh read still shows status=2 (a diff-vs-
	// recheck race — safety caught it); skipped_grace: prod last-activity is
	// inside the grace window (possible flap / mid-transition);
	// skipped_no_activity: prod has no last-activity ts to close at;
	// skipped_unverified: prod has no row for this id_order (can't confirm).
	// Everything but finished/failed is a SAFETY skip — the finisher errs
	// toward under-closing.
	ReconcilerFinisherTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_reconciler_finisher_total",
		Help: "Finisher per-candidate outcomes (finished|failed|skipped_*).",
	}, []string{"outcome"})

	// ReconcilerOrphanCandidates — gauge of reconcile-origin staging POs that
	// are status=2 but absent from prod's status=2 set at the start of the
	// last finisher pass (before per-candidate prod cross-check / grace).
	// Sustained non-zero while the finisher is ENABLED means candidates are
	// being held back by the safety skips (grace / unverified) — worth a look.
	ReconcilerOrphanCandidates = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_reconciler_orphan_candidates",
		Help: "Reconcile-origin staging POs status=2 but gone from prod status=2 at last finisher pass.",
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

	// ValueFanoutTotal — ADR-0012 3-flow parity: each delta INSERT is
	// fanned out to shadow_go_port (same DB) + packiot_shadow (Flow 3).
	// Shadow failures never fail the Flow 1 write (a retry would
	// double-count the delta) — they land here as outcome=failed or
	// outcome=missing_table instead. Silent loss is a bug (ADR-0011);
	// alert on failed > 0.
	ValueFanoutTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_value_fanout_total",
		Help: "equipment_values delta fan-out to shadow destinations (ok|missing_table|failed).",
	}, []string{"destination", "outcome"})

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
	// terminal: edge-api PR #148 gate permanently rejected the replay (409
	// STALE_HEAD/RANGE_CONFLICT/BEYOND_HORIZON) → row retired to the cap
	// immediately, no further retries;
	// exhausted: retry_attempts hit the cap → no further attempts will fire
	// (counted once per tick when the row is observed past the cap).
	DLQRetryAttemptsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_dlq_retry_attempts_total",
		Help: "DLQ retry outcomes (succeeded|failed|permanent|terminal|exhausted).",
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

	// ComparatorActivePosDiff — fidelity gauge (ADR-0008 phase 2a). Computed
	// as prod count(active POs) - staging count(active POs), each scoped to
	// their respective enterprise IDs. Healthy steady state is 0: the
	// EnsureActivePOs reconciler keeps staging in sync. Non-zero on a
	// sustained basis means the existence reconciler is misclassifying or
	// behind. Sign communicates direction (positive = prod has more, staging
	// behind; negative = staging has stale rows that should have closed).
	ComparatorActivePosDiff = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_comparator_active_pos_diff",
		Help: "prod count(active POs) - staging count(active POs). Healthy: 0. Positive: staging behind. Negative: staging stale.",
	})

	// ComparatorRunsTotal — bumps once per comparator pass with outcome
	// ok|failed. Failed means the comparator couldn't query one of the two
	// systems (prod or staging) and emitted no metric this tick. Pair with
	// alert rules — sustained 'failed' increment means the watchdog itself
	// is blind, which is worse than a divergent metric.
	ComparatorRunsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_comparator_runs_total",
		Help: "Comparator pass outcomes (ok|failed). Failed = couldn't measure; investigate before trusting the gauge.",
	}, []string{"outcome"})

	// ComparatorEventsLagSeconds — fidelity gauge (ADR-0008 phase 2a.2).
	// Computed as (prod max(ts_event) - staging max(ts_event)) over the
	// last hour, scoped per-enterprise. Healthy steady state: < 120s
	// (events reconciler cadence is 60s; one tick of lag is normal).
	// Positive: staging behind. Sustained > 300s means the events-sync
	// reconciler is stuck or disabled. Gauge is set to NaN when prod
	// emits no events in the window (line stopped) — avoids logging
	// false-positive lag when both sides are quiet.
	ComparatorEventsLagSeconds = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_comparator_events_lag_seconds",
		Help: "(prod max(ts_event) - staging max(ts_event)) in seconds, last-hour window. Healthy: < 120s. >300s sustained = events-sync stuck.",
	})

	// ComparatorUserLogsLag — fidelity gauge (ADR-0008 phase 2a.2).
	// Computed as (prod max(user_logs.id_user_logs) - staging cursor
	// last_log_id) for the worker's source. Healthy steady state: small
	// integer (the cursor advances on every poll tick; lag is bounded by
	// the prod publish rate during the tick interval). Positive: main
	// poll loop is behind. Large sustained values mean the worker has
	// stalled on a long-running handler or hit a recoverable error loop.
	ComparatorUserLogsLag = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_comparator_user_logs_lag",
		Help: "prod max(user_logs.id_user_logs) - staging mirror_replay_cursor.last_log_id for this worker's source. Healthy: tiny. Large sustained = poll loop stalled.",
	})

	// ComparatorOEEDivergencePct — fidelity gauge (ADR-0008 phase 2a.3).
	// Per active mapped PO: abs(prod.net_production - staging.net_production)
	// / NULLIF(prod.net_production, 0). Healthy steady state: < 0.01 (1%
	// divergence is within rounding noise for the per-minute pg_cron cycle).
	// Label cardinality is bounded by the active-PO set (~10-15 typical),
	// kept current by Reset()-ing the vec at the start of each measure
	// pass — finished POs drop off automatically.
	//
	// Cadence is 30 min (configurable via COMPARATOR_OEE_INTERVAL_SEC), much
	// longer than the 5-min comparator loop because: (a) the underlying
	// staging value-sync also runs at minute-scale, so finer resolution
	// adds noise without signal; (b) prod's production_orders_runtime is a
	// pg_cron-refreshed table, sampled at sub-minute could read mid-update.
	ComparatorOEEDivergencePct = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "mirror_worker_comparator_oee_divergence_pct",
		Help: "abs(prod.net_production - staging.net_production) / prod.net_production per active mapped PO. Healthy: < 0.01. Per-PO label; vec Reset() each pass to drop finished POs.",
	}, []string{"id_production_order"})

	// ComparatorOEEMeasured — bumps once per OEE measurement pass with the
	// number of POs measured + the number skipped (prod = 0 / nil — can't
	// compute pct). Lets the dashboard separate "measure didn't run" from
	// "measured but everyone is at 0" from "PO is freshly started so no
	// data yet". Outcome label: ok | failed | skipped.
	ComparatorOEEMeasured = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "mirror_worker_comparator_oee_measured_total",
		Help: "OEE measurement outcomes per PO (ok|failed|skipped). ok = pct emitted; skipped = prod NetProduction null/zero (can't compute); failed = query error.",
	}, []string{"outcome"})

	// ComparatorDLQAnomalyTotal — fidelity gauge (ADR-0008 phase 2a.4).
	// Count of staging mirror_replay_dlq entries whose source_log_id no
	// longer exists in prod user_logs. Healthy steady state: 0 (every DLQ
	// entry traces back to a real prod row). Non-zero is real-world rare
	// but signals one of:
	//   - prod did a data cleanup that purged the referenced user_log
	//   - the writer that stamped source_log_id into DLQ used a wrong ID
	//   - a race between DLQ retention policy + the worker's writes
	// Either way, the row will retry forever (FetchUserLogByID returns
	// 'permanent' → row keeps bumping its retry counter to no effect).
	// Anomaly count > 0 is a manual-triage signal: inspect the row, then
	// DELETE it from mirror_replay_dlq if it really IS orphaned.
	ComparatorDLQAnomalyTotal = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "mirror_worker_comparator_dlq_anomaly_total",
		Help: "Staging mirror_replay_dlq entries whose source_log_id no longer exists on prod user_logs. Healthy: 0. Non-zero = orphaned DLQ rows needing manual triage.",
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
		ReconcilerFinisherTotal,
		ReconcilerOrphanCandidates,
		ReconcilerValuesSyncedTotal,
		ValueFanoutTotal,
		ReconcilerEventsTotal,
		ReconcilerEventsCursor,
		DLQRetryAttemptsTotal,
		DLQDepth,
		DLQReanimatedTotal,
		ComparatorActivePosDiff,
		ComparatorRunsTotal,
		ComparatorEventsLagSeconds,
		ComparatorUserLogsLag,
		ComparatorOEEDivergencePct,
		ComparatorOEEMeasured,
		ComparatorDLQAnomalyTotal,
	)
}
