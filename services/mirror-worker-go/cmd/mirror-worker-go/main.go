// mirror-worker-go — Go port of services/mirror-worker (TypeScript).
//
// Parallel-run pattern: source='cpack-prod-go' so it has an independent
// mirror_replay_cursor + mirror_id_map rows from the TS worker's
// 'cpack-prod' source. Both workers replay the same prod user_logs to
// the same staging edge-api. Edge-api ignores duplicates via mapping
// lookups + idempotency. Once at parity, change source back to
// 'cpack-prod' and stop the TS worker.
//
// PHASE 1 (this scaffold):
//   - Boot, fetch secrets from AWS SM, connect to prod + staging
//   - Poll user_logs, drain per-row through the dispatcher
//   - Register ONE real handler (order-status-changed) to prove the pattern
//   - Other categories: no-op + advance cursor (same as TS for unregistered)
//
// PHASE 2 (follow-up):
//   - Port the remaining 9 handlers (event-justified/edited/splitted,
//     order-changed/started/stopped/created/created-started/replaced)
//   - Port the interval-overlap event matcher (translate.EquipmentEvent)
//   - Port backfill-pos one-shot script
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/comparator"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/health"
	logp "github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/log"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/reconcile"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/replay"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/secrets"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/translate"
)

func main() {
	// Healthcheck subcommand — distroless has no shell/wget.
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(runHealthcheck())
	}

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}
	logger := logp.Setup(cfg.LogLevel)
	logger.Info("mirror-worker-go starting",
		slog.String("source", cfg.SourceName),
		slog.Int("poll_interval_sec", cfg.PollIntervalSec),
		slog.Int("batch_size", cfg.BatchSize),
		slog.String("staging_api", cfg.StagingAPIBaseURL),
	)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// CO-5 — fetch DB creds from AWS Secrets Manager, NOT from env vars.
	prodCreds, err := secrets.FetchDBCreds(ctx, cfg.AWSRegion, cfg.ProdDBSecretID)
	if err != nil {
		logger.Error("fetch prod creds", slog.String("err", err.Error()))
		os.Exit(1)
	}
	stagingCreds, err := secrets.FetchDBCreds(ctx, cfg.AWSRegion, cfg.StagingDBSecretID)
	if err != nil {
		logger.Error("fetch staging creds", slog.String("err", err.Error()))
		os.Exit(1)
	}

	prodDB, err := db.NewProd(ctx, prodCreds, logger)
	if err != nil {
		logger.Error("prod pool", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer prodDB.Close()

	stagingDB, err := db.NewStaging(ctx, stagingCreds, logger)
	if err != nil {
		logger.Error("staging pool", slog.String("err", err.Error()))
		os.Exit(1)
	}
	defer stagingDB.Close()

	// ADR-0012 3-flow parity: fan equipment_values deltas out to the
	// shadow destinations. Shadow pool failure is non-fatal — fan-out
	// degrades to shadow_go_port only (Flow 2), surfaced by the metric.
	if cfg.ShadowValueFanout {
		stagingDB.EnableValueFanout()
		stagingDB.SetF2Fanout(cfg.ShadowFanoutF2) // ADR-0032: false ⇒ fan only F3
		if cfg.ShadowDBName != "" {
			if err := stagingDB.AttachShadowPool(ctx, stagingCreds, cfg.ShadowDBHost, cfg.ShadowDBName); err != nil {
				logger.Error("shadow pool init failed — fan-out degraded to shadow_go_port only",
					slog.String("err", err.Error()))
			}
		}
	}

	apiToken, err := stagingDB.FetchAPIToken(ctx, cfg.StagingEnterpriseID)
	if err != nil {
		logger.Error("fetch staging api token", slog.String("err", err.Error()))
		os.Exit(1)
	}
	logger.Info("staging api token loaded",
		slog.Int("enterprise_id", cfg.StagingEnterpriseID),
		slog.String("token_prefix", apiToken[:8]))

	// Token holder — restart-only rotation, same as TS.
	tok := &tokenHolder{token: apiToken}

	// HTTP client tuned for ~25/min POSTs.
	httpc := &http.Client{Timeout: 20 * time.Second}

	// Translator + dispatcher.
	t := translate.New(prodDB, stagingDB, cfg, logger)
	disp := replay.NewDispatcher()
	disp.Register("order-status-changed",
		replay.OrderStatusChanged(cfg, t, tok.Get, httpc, logger))
	disp.Register("order-created",
		replay.OrderCreated(cfg, t, prodDB, stagingDB, tok.Get, httpc, logger))
	disp.Register("order-created-started",
		replay.OrderCreatedStarted(cfg, t, prodDB, stagingDB, tok.Get, httpc, logger))
	disp.Register("order-started",
		replay.OrderStarted(cfg, t, tok.Get, httpc, logger))
	disp.Register("order-changed",
		replay.OrderChanged(cfg, t, tok.Get, httpc, logger))
	disp.Register("order-stopped",
		replay.OrderStopped(cfg, t, tok.Get, httpc, logger))
	disp.Register("order-replaced",
		replay.OrderReplaced(cfg, t, tok.Get, httpc, logger))
	// event-justified, event-edited, event-splitted are intentionally NOT
	// registered: PR #76's events-sync reconciler is the sole writer of
	// equipment_events for CPACK (see services/mirror-worker-go/docs/reconciler.md
	// invariant 2). Re-executing operator actions via edge-api produces PK
	// violations against the reconciler's already-inserted rows. Unregistered
	// categories advance the cursor + record outcome=skipped on the dispatcher's
	// fall-through path; the user_logs row itself is still mirrored.
	disp.Register("downtime-event-created",
		replay.DowntimeEventCreated(cfg, t, tok.Get, httpc, logger))

	logger.Info("dispatcher ready",
		slog.Any("handled_categories", disp.HandledCategories()),
		slog.Int("total_handlers", len(disp.HandledCategories())))

	state := health.NewState(cfg.SourceName, cfg.PollIntervalSec)
	// ADR-0011 P0-4 (mirror gap 5): expose cursor + DLQ depth on /health so
	// ops has both numbers without shelling into the DB.
	state.WithCursor(func(qctx context.Context) (int64, error) {
		return stagingDB.ReadCursor(qctx, cfg.SourceName)
	})
	state.WithDLQDepth(func(qctx context.Context) (int64, error) {
		return stagingDB.CountDLQ(qctx, cfg.SourceName)
	})
	hsrv := health.New(fmt.Sprintf(":%d", cfg.HealthPort), state, logger)
	hsrv.Start()

	// EnsureActivePOs reconciler — closes the ~95% gap left by user_logs
	// replay (most prod CPACK POs are PLC-created, bypass edge-api audit).
	// Runs in its own goroutine on its own cadence; tick loop below is
	// unaffected.
	var reconWG sync.WaitGroup
	reconCtx, reconCancel := context.WithCancel(ctx)
	defer reconCancel()
	recon := reconcile.New(cfg, prodDB, stagingDB, t, tok.Get, httpc, logger)
	dlqRetrier := replay.NewDLQRetrier(cfg, prodDB, stagingDB, disp, logger)
	dlqReanimator := replay.NewDLQReanimator(cfg, stagingDB, logger)
	comp := comparator.New(cfg, prodDB, stagingDB, logger)
	reconWG.Add(6)
	go func() {
		defer reconWG.Done()
		_ = recon.RunForever(reconCtx)
	}()
	// Value sync runs on its own cadence (~30s by default) so prod-anchored
	// equipment_values deltas land between cron ticks. The existence loop
	// (RunForever above) is at a 5-min cadence; running them as one loop
	// would lose either the value-sync responsiveness or pay the existence
	// overhead 10× more often than needed.
	go func() {
		defer reconWG.Done()
		_ = recon.RunValueSyncForever(reconCtx)
	}()
	// Events sync runs on a 60s cadence (configurable). Mirrors prod
	// equipment_events to staging 1:1 with mirror_id_map entries so the
	// interval-overlap matcher (translate.EquipmentEvent) takes the cache
	// hit path on every operator-action replay — eliminating the dominant
	// DLQ failure class as of 2026-06-26.
	go func() {
		defer reconWG.Done()
		_ = recon.RunEventsSyncForever(reconCtx)
	}()
	// DLQ retry runs on a 5-min cadence (configurable). Picks up DLQ rows
	// past their backoff window and re-dispatches them through the same
	// handler chain a fresh poll would. Replaces "human inspects DLQ and
	// re-replays manually" for transient failures (connection refused
	// during a deploy, prod race conditions). Bounded by
	// DLQ_RETRY_MAX_ATTEMPTS so permanent failures stop churning.
	go func() {
		defer reconWG.Done()
		_ = dlqRetrier.RunForever(reconCtx)
	}()
	// DLQ reanimator runs on a 10-min cadence (configurable). Resets
	// retry_attempts=0 on DLQ rows whose underlying prod equipment_event
	// became mappable AFTER the row hit the retry cap — typical when the
	// events reconciler catches up to a stuck prod_id hours or days
	// later. Without this, a row DLQ'd before its target was mirrored
	// sits forever at retry_attempts=5 despite the translation now
	// succeeding. Predicate is mirror_id_map EXISTS — genuinely-broken
	// rows stay at the cap for human triage.
	go func() {
		defer reconWG.Done()
		_ = dlqReanimator.RunForever(reconCtx)
	}()
	// Comparator (ADR-0008 phase 2a) runs on a 5-min cadence (configurable).
	// Fidelity watchdog: SELECTs canonical values from BOTH prod and staging,
	// emits divergence gauges. Pairs with the reconciler — reconciler closes
	// gaps; comparator measures them. Pure observability; never mutates
	// either system. Phase 2a.1 ships active_pos_diff; 2a.2-2a.5 add the
	// remaining 4 metrics from ADR-0008.
	go func() {
		defer reconWG.Done()
		_ = comp.RunForever(reconCtx)
	}()

	// Main loop. Polls cursor → fetches batch → processes per row in
	// its own staging tx → advances cursor or writes DLQ + advances.
	for {
		if ctx.Err() != nil {
			break
		}
		if err := tick(ctx, cfg, prodDB, stagingDB, disp, logger); err != nil {
			state.RecordTickError(err)
			logger.Error("tick failed", slog.String("err", err.Error()))
		} else {
			state.RecordTickSuccess()
		}
		select {
		case <-time.After(time.Duration(cfg.PollIntervalSec) * time.Second):
		case <-ctx.Done():
		}
	}

	// Cancel the reconciler and wait for it to drain before shutting
	// down the health server. The reconciler may be in the middle of an
	// HTTP POST — give it a beat.
	reconCancel()
	reconWG.Wait()

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutCancel()
	_ = hsrv.Shutdown(shutCtx)
	logger.Info("mirror-worker-go stopped")
}

// tokenHolder wraps the staging api_key with a mutex so future
// (in-process) rotation can swap it without restarting handlers.
type tokenHolder struct {
	mu    sync.RWMutex
	token string
}

func (t *tokenHolder) Get() string {
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.token
}

// tick polls one batch + processes each row. Returns the first
// row-level error encountered; the cursor still advances per-row so
// one bad row doesn't block the queue.
//
// Also updates the cursor_lag_seconds + id_map_cache_size gauges once
// per tick. Both queries are best-effort — failures are logged but
// don't fail the tick. Stale gauge values are clearly better than a
// crashed worker.
func tick(
	ctx context.Context,
	cfg *config.Config,
	prodDB *db.Prod,
	stagingDB *db.Staging,
	disp *replay.Dispatcher,
	logger *slog.Logger,
) error {
	cursor, err := stagingDB.ReadCursor(ctx, cfg.SourceName)
	if err != nil {
		return fmt.Errorf("read cursor: %w", err)
	}

	// Update gauges before fetching new logs so they reflect the state
	// AT this cursor position. Both run inside the tick to amortise the
	// poll-interval cost; calling per-row would be cheap but pointless.
	updateGauges(ctx, cfg, prodDB, stagingDB, cursor, logger)

	rows, err := prodDB.FetchNewLogs(ctx, cursor, cfg.ProdEnterpriseID, cfg.BatchSize)
	if err != nil {
		return fmt.Errorf("fetch new logs: %w", err)
	}
	if len(rows) == 0 {
		return nil
	}
	logger.Info("processing batch",
		slog.Int64("cursor", cursor),
		slog.Int("batch", len(rows)))

	for _, row := range rows {
		if err := processRow(ctx, cfg, stagingDB, disp, row, logger); err != nil {
			// Logged inside; loop continues.
			_ = err
		}
		if cfg.PerPostDelayMs > 0 {
			select {
			case <-time.After(time.Duration(cfg.PerPostDelayMs) * time.Millisecond):
			case <-ctx.Done():
				return nil
			}
		}
	}
	return nil
}

// updateGauges refreshes cursor_lag_seconds + id_map_cache_size from
// the DB. Both are best-effort — log on error, keep going. We never
// want a transient prod hiccup or a metrics call to crash the worker;
// stale gauge values are far better than no replay loop.
func updateGauges(
	ctx context.Context,
	cfg *config.Config,
	prodDB *db.Prod,
	stagingDB *db.Staging,
	cursor int64,
	logger *slog.Logger,
) {
	// cursor_lag_seconds — distance between now() and the prod ts_event
	// of the last replayed row. Zero time means the worker is fresh +
	// hasn't replayed anything yet; skip the gauge so it doesn't read 0.
	if ts, err := prodDB.LatestLogTimestamp(ctx, cursor, cfg.ProdEnterpriseID); err == nil {
		if !ts.IsZero() {
			metrics.CursorLagSeconds.Set(time.Since(ts).Seconds())
		}
	} else {
		logger.Warn("cursor lag update failed", slog.String("err", err.Error()))
	}
	// id_map_cache_size — total mirror_id_map rows for this source.
	if n, err := stagingDB.CountIDMap(ctx, cfg.SourceName); err == nil {
		metrics.IDMapCacheSize.Set(float64(n))
	} else {
		logger.Warn("id_map_cache_size update failed", slog.String("err", err.Error()))
	}
}

// processRow wraps one row in a staging transaction: dispatch handler →
// commit on success, OR write DLQ + commit on handler error. Cursor
// advances either way. Same shape as TS processRow.
//
// Metrics: dispatch records polled + replayed + duration. The
// idempotency-hit path goes through disp.MarkAlreadyReplayed so the
// polled/replayed counters stay consistent for ratio queries.
func processRow(
	ctx context.Context,
	cfg *config.Config,
	stagingDB *db.Staging,
	disp *replay.Dispatcher,
	row db.ProdUserLog,
	logger *slog.Logger,
) error {
	return stagingDB.WithTx(ctx, func(tx pgx.Tx) error {
		// Idempotency: skip if already replayed (mirror_id_map hit by source_log_id).
		already, err := stagingDB.IsAlreadyReplayed(ctx, cfg.SourceName, row.IDUserLogs)
		if err != nil {
			return fmt.Errorf("isAlreadyReplayed: %w", err)
		}
		if already {
			disp.MarkAlreadyReplayed(row.Category)
			return db.AdvanceCursor(ctx, tx, cfg.SourceName, row.IDUserLogs)
		}

		// Dispatch records all three replay metrics (polled, replayed,
		// duration) + returns the handler's error verbatim. We keep the
		// existing DLQ-and-advance behaviour here.
		if dispErr := disp.Dispatch(ctx, tx, row); dispErr != nil {
			// A TERMINAL failure (edge-api PR #148 gate reject) is a
			// correctly-rejected, permanently-stale PO-control action. Route
			// it to the DLQ review tray PRE-RETIRED (retry_attempts at the
			// cap) so the DLQRetrier never re-drives it — the fix for the
			// infinite ~5-min replay storm. A normal failure writes the row
			// at retry_attempts=0 so the retrier picks it up next pass.
			retryAttempts := 0
			if errors.Is(dispErr, replay.ErrTerminalReplay) {
				retryAttempts = cfg.DLQRetryMaxAttempts
				logger.Error("replay permanently rejected by edge-api gate — writing terminal DLQ row (retired, will not retry)",
					slog.String("category", row.Category),
					slog.Int64("source_log_id", row.IDUserLogs),
					slog.String("err", dispErr.Error()))
			} else {
				logger.Warn("replay failed, writing DLQ row",
					slog.String("category", row.Category),
					slog.Int64("source_log_id", row.IDUserLogs),
					slog.String("err", dispErr.Error()))
			}
			if dlqErr := db.WriteDLQ(ctx, tx, cfg.SourceName, row.IDUserLogs,
				row.Category, row.Subcategory, row.Payload, dispErr.Error(), retryAttempts); dlqErr != nil {
				return fmt.Errorf("DLQ write: %w (original: %v)", dlqErr, dispErr)
			}
		}
		return db.AdvanceCursor(ctx, tx, cfg.SourceName, row.IDUserLogs)
	})
}

// runHealthcheck — self-probes /health for docker HEALTHCHECK.
func runHealthcheck() int {
	port := 9102
	if p := os.Getenv("HEALTH_PORT"); p != "" {
		_, _ = fmt.Sscanf(p, "%d", &port)
	}
	url := fmt.Sprintf("http://127.0.0.1:%d/health", port)
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: GET %s: %v\n", url, err)
		return 1
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 1
	}
	var meta struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(body, &meta); err != nil {
		return 1
	}
	if meta.Status == "unhealthy" {
		fmt.Fprintf(os.Stderr, "healthcheck: %s\n", string(body))
		return 1
	}
	return 0
}
