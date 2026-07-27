// Package reconcile owns the EnsureActivePOs loop — a periodic diff of
// prod active POs against staging active POs (by id_order), backfilling
// any that are missing.
//
// Why this exists: only ~5% of prod CPACK POs ever emit a user_logs row
// for order-created / order-started — the other 95% are created by PLC
// SparkPlug parameter writes (30800–30899) that bypass edge-api's audit
// middleware. The mirror-worker's cursor-driven replay can therefore only
// see ~5% of new PO lifecycle. The remaining 95% needs a different
// mechanism: polling prod's production_orders table directly and ensuring
// staging has a corresponding active PO for each.
//
// Same shape as the manual backfill we ran by hand: SELECT prod active
// CPACK POs → diff against staging active → POST /api/production-orders/
// create + /start for each missing one → INSERT mirror_id_map.
//
// Idempotency: the diff is by id_order (unique per id_enterprise on
// prod), and the staging POST series is gated by a pre-flight
// LookupStagingPOByIDOrder — so re-running the loop after a partial
// success is safe. The /create endpoint will reject duplicate id_order
// values (edge-api/src/usecases/production-orders/create-production-order
// throws on conflict), so even if our pre-flight raced with a concurrent
// reconciler instance, the second attempt would just fail with a clear
// 400 instead of double-creating.
package reconcile

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/config"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/translate"
)

// Reconciler diffs prod active POs vs staging active POs and POSTs the
// missing ones through staging edge-api. One instance per worker process.
type Reconciler struct {
	closerTick int64 // events close-sweep cadence counter (task #63; every Nth tick)
	cfg        *config.Config
	prodDB     *db.Prod
	staging    *db.Staging
	trans      *translate.Translator
	apiToken   func() string
	httpc      *http.Client
	logger     *slog.Logger

	// Embeddable for unit tests so we can swap out the staging API
	// calls without spinning up a real HTTP server. nil in production
	// → fall back to postCreate / postStart on http.Client.
	postFunc func(ctx context.Context, path string, body any, idemKey string) (int, []byte, error)
}

// New constructs a Reconciler. apiToken is a func so it picks up future
// in-process rotation the same way replay handlers do.
func New(
	cfg *config.Config,
	prodDB *db.Prod,
	stagingDB *db.Staging,
	trans *translate.Translator,
	apiToken func() string,
	httpc *http.Client,
	logger *slog.Logger,
) *Reconciler {
	return &Reconciler{
		cfg:      cfg,
		prodDB:   prodDB,
		staging:  stagingDB,
		trans:    trans,
		apiToken: apiToken,
		httpc:    httpc,
		logger:   logger,
	}
}

// RunForever blocks until ctx is canceled, scheduling the reconciler's two
// halves — the create-diff and the finisher — per RECONCILE_MODE:
//
//   - "poll" (default, pre-split behavior): a single combined pass runs BOTH
//     halves sequentially on ONE prod snapshot every RECONCILE_INTERVAL_SEC.
//     This is the rollback target — the code path below is byte-identical to
//     the pre-split scheduler, so RECONCILE_MODE=poll (or unset) restores
//     exactly today's behavior.
//   - "tail": the halves are split onto two independent tickers so the cheap
//     create-diff (measured: a 0.33ms cached status=2 index scan) can run at
//     RECONCILE_CREATE_INTERVAL_SEC (default 3s) for sub-3s PO-start
//     detection, while the heavier finisher stays at
//     RECONCILE_FINISHER_INTERVAL_SEC (default 300s). Stop latency is
//     grace-bound anyway (RECONCILE_FINISHER_GRACE_MINUTES), so finishing
//     faster buys nothing.
//
// Both modes fire their first pass immediately so a fresh worker doesn't wait
// a full interval before catching up on day-0 drift.
func (r *Reconciler) RunForever(ctx context.Context) error {
	if !r.cfg.ReconcileEnabled {
		r.logger.Info("reconciler disabled via RECONCILE_ENABLED=false")
		return nil
	}
	if r.cfg.ReconcileMode == config.ReconcileModeTail {
		return r.runForeverTail(ctx)
	}
	return r.runForeverPoll(ctx)
}

// runForeverPoll is the pre-split scheduler: one combined pass (Run) — create
// then finisher on a shared snapshot — every RECONCILE_INTERVAL_SEC.
func (r *Reconciler) runForeverPoll(ctx context.Context) error {
	interval := time.Duration(r.cfg.ReconcileIntervalSec) * time.Second
	r.logger.Info("reconciler starting (poll mode)",
		slog.Int("interval_sec", r.cfg.ReconcileIntervalSec),
		slog.Int("max_per_run", r.cfg.ReconcileMaxPerRun))
	r.tickLoop(ctx, interval, r.Run)
	r.logger.Info("reconciler stopping")
	return nil
}

// runForeverTail splits the two halves onto independent tickers. The create
// loop reuses runCreatePass verbatim (only the scheduling wrapper changed);
// the finisher loop reuses runFinisher verbatim via runFinisherPass, which
// fetches its OWN prod snapshot (poll mode shares the create pass's snapshot
// instead). Each loop keeps running until ctx is canceled.
func (r *Reconciler) runForeverTail(ctx context.Context) error {
	createInterval := time.Duration(r.cfg.ReconcileCreateIntervalSec) * time.Second
	finisherInterval := time.Duration(r.cfg.ReconcileFinisherIntervalSec) * time.Second
	r.logger.Info("reconciler starting (tail mode)",
		slog.Int("create_interval_sec", r.cfg.ReconcileCreateIntervalSec),
		slog.Int("finisher_interval_sec", r.cfg.ReconcileFinisherIntervalSec),
		slog.Int("max_per_run", r.cfg.ReconcileMaxPerRun),
		slog.Bool("finisher_enabled", r.cfg.ReconcileFinisherEnabled))

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		r.tickLoop(ctx, createInterval, func(ctx context.Context) error {
			_, err := r.runCreatePass(ctx)
			return err
		})
	}()
	go func() {
		defer wg.Done()
		r.tickLoop(ctx, finisherInterval, r.runFinisherPass)
	}()
	wg.Wait()
	r.logger.Info("reconciler stopping")
	return nil
}

// tickLoop fires fn immediately, then every interval until ctx is canceled.
// A fn error is logged and the loop continues — a single bad pass must never
// kill the scheduler; the next tick retries. Shared by both modes so the
// "fire immediately + tick + swallow-and-continue" discipline lives in one
// place.
func (r *Reconciler) tickLoop(ctx context.Context, interval time.Duration, fn func(context.Context) error) {
	for {
		if err := fn(ctx); err != nil {
			r.logger.Warn("reconciler pass failed", slog.String("err", err.Error()))
		}
		select {
		case <-time.After(interval):
		case <-ctx.Done():
			return
		}
	}
}

// Run executes one COMBINED reconciliation pass — create-diff then finisher
// on the single prod snapshot the create pass fetched. This is the poll-mode
// pass and the ad-hoc trigger entrypoint (kept exported so a future HTTP
// endpoint / SIGUSR1 handler can invoke without waiting for the next tick).
// Tail mode does NOT call this — it drives runCreatePass and runFinisherPass
// on separate tickers instead.
func (r *Reconciler) Run(ctx context.Context) error {
	prodPOs, err := r.runCreatePass(ctx)
	if err != nil {
		return err
	}

	// Finisher pass (task #48) — closes the INVERSE gap the create pass
	// leaves: mirror-managed staging POs stuck at status=2 after prod
	// ended them via a user_logs-bypassing SparkPlug stop. Ships INERT
	// (flag default false); runs on the same prod-active snapshot the create
	// pass just returned, so no extra FetchActivePOs round-trip. A finisher
	// error is logged but never fails the whole pass — the create side
	// already succeeded and the next tick retries.
	if r.cfg.ReconcileFinisherEnabled {
		if err := r.runFinisher(ctx, prodPOs); err != nil {
			r.logger.Warn("reconciler: finisher pass failed — create pass unaffected, next tick retries",
				slog.String("err", err.Error()))
		}
	}
	return nil
}

// runCreatePass executes the create-diff half of one reconciliation pass:
// FetchActivePOs → ActivePOIDOrders → computeMissing → ensureOnePO. It
// returns the prod active-PO snapshot it fetched so a combined poll-mode
// pass (Run) can hand the SAME snapshot to the finisher without a second
// FetchActivePOs round-trip. The diff/cap/ensure logic is verbatim what the
// pre-split Run ran — only the finisher call moved out to the caller.
func (r *Reconciler) runCreatePass(ctx context.Context) ([]db.ProdActivePO, error) {
	start := time.Now()
	prodPOs, err := r.prodDB.FetchActivePOs(ctx, r.cfg.ProdEnterpriseID)
	if err != nil {
		metrics.ReconcilerRunsTotal.WithLabelValues("failed").Inc()
		return nil, fmt.Errorf("fetch prod active POs: %w", err)
	}
	stagingActive, err := r.staging.ActivePOIDOrders(ctx, r.cfg.StagingEnterpriseID)
	if err != nil {
		metrics.ReconcilerRunsTotal.WithLabelValues("failed").Inc()
		return nil, fmt.Errorf("fetch staging active id_orders: %w", err)
	}

	missing := computeMissing(prodPOs, stagingActive)

	metrics.ReconcilerActiveDriftPOs.Set(float64(len(missing)))

	if len(missing) == 0 {
		r.logger.Info("reconciler pass: in sync (create pass)",
			slog.Int("prod_active", len(prodPOs)),
			slog.Int("staging_active", len(stagingActive)))
	} else {
		// Per-run cap so a single bad pass can't hammer staging edge-api
		// during an outage. Whatever isn't backfilled this pass is picked
		// up on the next tick.
		toProcess := missing
		if len(toProcess) > r.cfg.ReconcileMaxPerRun {
			toProcess = toProcess[:r.cfg.ReconcileMaxPerRun]
		}

		r.logger.Info("reconciler pass: backfilling missing POs",
			slog.Int("prod_active", len(prodPOs)),
			slog.Int("staging_active", len(stagingActive)),
			slog.Int("drift", len(missing)),
			slog.Int("processing", len(toProcess)))

		for _, p := range toProcess {
			if err := r.ensureOnePO(ctx, p); err != nil {
				metrics.ReconcilerPOsTotal.WithLabelValues("failed").Inc()
				r.logger.Warn("reconciler: ensureOnePO failed — skipping, next pass will retry",
					slog.Int64("prod_po", p.IDProductionOrder),
					slog.Int64("id_order", p.IDOrder),
					slog.String("err", err.Error()))
				continue
			}
			metrics.ReconcilerPOsTotal.WithLabelValues("created").Inc()
		}
	}

	metrics.ReconcilerRunsTotal.WithLabelValues("ok").Inc()
	r.logger.Info("reconciler create pass complete", slog.Duration("elapsed", time.Since(start)))
	return prodPOs, nil
}

// runFinisherPass is the finisher half as a self-contained pass for tail
// mode's finisher ticker: it fetches its OWN prod active-PO snapshot (poll
// mode shares the create pass's snapshot via Run instead) and runs the
// finisher. INERT unless RECONCILE_FINISHER_ENABLED — it returns nil without
// touching prod when the finisher is off, so the tail finisher ticker costs
// nothing until the finisher is deliberately enabled.
func (r *Reconciler) runFinisherPass(ctx context.Context) error {
	if !r.cfg.ReconcileFinisherEnabled {
		return nil
	}
	prodPOs, err := r.prodDB.FetchActivePOs(ctx, r.cfg.ProdEnterpriseID)
	if err != nil {
		return fmt.Errorf("finisher: fetch prod active POs: %w", err)
	}
	return r.runFinisher(ctx, prodPOs)
}

// computeMissing returns the prod active POs whose id_order isn't
// present in the staging-active map, sorted by id_order for stable
// progress on partial-progress passes.
//
// Exposed as a free function (not a method) so the unit tests exercise
// the exact diff used by Run, no shadow implementation.
func computeMissing(prod []db.ProdActivePO, stagingActive map[int64]int64) []db.ProdActivePO {
	missing := make([]db.ProdActivePO, 0)
	for _, p := range prod {
		if _, present := stagingActive[p.IDOrder]; !present {
			missing = append(missing, p)
		}
	}
	// Stable order so partial-progress passes don't keep retrying the
	// same head of the list while the tail starves. Sorting by id_order
	// gives the same view a human gets in psql.
	sort.Slice(missing, func(i, j int) bool { return missing[i].IDOrder < missing[j].IDOrder })
	return missing
}

// orphanCandidate pairs a mirror-managed staging PO with the id_order the
// diff keyed it by. The finisher walks these in id_order order for stable,
// human-readable pass logs.
type orphanCandidate struct {
	IDOrder     int64
	StagingPOID int64
}

// computeOrphans returns the INVERSE of computeMissing: mirror-managed
// staging POs (id_order → staging id) whose id_order is NO LONGER in prod's
// status=2 set. These are the finisher's orphan candidates — POs staging still
// thinks are running that prod has already ended.
//
// A candidate present in prodActive is EXCLUDED here: that's a legitimately-
// running PO and the first (of four) safety layers protecting it — a running
// PO can never become a finish candidate. Pure + sorted for the same
// no-shadow-implementation, stable-progress reasons as computeMissing.
func computeOrphans(reconcileActive map[int64]int64, prodActive []db.ProdActivePO) []orphanCandidate {
	prodSet := make(map[int64]struct{}, len(prodActive))
	for _, p := range prodActive {
		prodSet[p.IDOrder] = struct{}{}
	}
	out := make([]orphanCandidate, 0)
	for idOrder, stagingPOID := range reconcileActive {
		if _, stillActive := prodSet[idOrder]; stillActive {
			continue
		}
		out = append(out, orphanCandidate{IDOrder: idOrder, StagingPOID: stagingPOID})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].IDOrder < out[j].IDOrder })
	return out
}

// finisherOutcome is the decision for one orphan candidate, computed purely
// from prod's authoritative finish-info + the grace cutoff. The metric label
// string doubles as the enum value so the decision and its observability can't
// drift apart.
type finisherOutcome string

const (
	outcomeFinish          finisherOutcome = "finished"
	outcomeSkipStillActive finisherOutcome = "skipped_still_active"
	outcomeSkipGrace       finisherOutcome = "skipped_grace"
	outcomeSkipNoActivity  finisherOutcome = "skipped_no_activity"
	outcomeSkipUnverified  finisherOutcome = "skipped_unverified"
	// outcomeSkipNotTerminal is the prod-terminal closer's extra rung: the prod
	// twin exists and is NOT status=2, but is also NOT status=3 (FINISHED) —
	// e.g. still available (1) or paused (4). The closer only closes FINISHED
	// twins, so it leaves these for a future pass / the #48 finisher.
	outcomeSkipNotTerminal finisherOutcome = "skipped_not_terminal"
)

// finisherDecision applies the per-candidate safety ladder AFTER the set diff
// already excluded prod-active POs (layer 1). Layers 2-4 live here:
//   - unverified: prod has no row for this id_order → can't confirm → skip;
//   - still active: prod's FRESH read shows status=2 (a diff-vs-recheck race)
//     → skip (never close a running PO);
//   - no activity: prod gave no last-activity ts → skip (never fabricate one);
//   - grace: prod last-activity is inside the grace window → skip (possible
//     flap / mid-transition — don't race a legitimate re-activation).
//
// Only a PO that clears all of them returns outcomeFinish, with the close ts.
func finisherDecision(info db.ProdPOFinishInfo, present bool, graceCutoff time.Time) finisherOutcome {
	if !present {
		return outcomeSkipUnverified
	}
	if info.Status == 2 {
		return outcomeSkipStillActive
	}
	if !info.HasActivity {
		return outcomeSkipNoActivity
	}
	if info.LastActivity.After(graceCutoff) {
		return outcomeSkipGrace
	}
	return outcomeFinish
}

// runFinisher orchestrates the prod-authoritative close for ALL THREE flows on
// the prod-active snapshot Run already fetched:
//   - runF1Finisher — closes Flow 1 (public), #480's behavior, unchanged;
//   - runShadowFanout — reproduces that close on F2/F3 (ADR-0025, task #51).
//
// The two are sequenced (F1 first) so the shadow pass reads an F1 shape that
// already reflects this pass's F1 closes. Crucially the shadow pass is NOT
// gated on there being F1 candidates: the #49 existing zombies have F1 ALREADY
// closed out-of-band, so they never surface as F1 candidates yet their shadow
// rows still need correcting — that path only runs because runShadowFanout is
// unconditional.
func (r *Reconciler) runFinisher(ctx context.Context, prodPOs []db.ProdActivePO) error {
	if err := r.runF1Finisher(ctx, prodPOs); err != nil {
		return err
	}
	if err := r.runShadowFanout(ctx, prodPOs); err != nil {
		return err
	}
	// Prod-terminal orphan closer (task follow-up to #48). Flag-gated + INERT by
	// default: with RECONCILE_CLOSE_PROD_TERMINAL_ORPHANS off this returns
	// immediately, so runFinisher above is byte-identical to today's behavior.
	// Sequenced LAST so it reads staging state that already reflects this pass's
	// F1 closes — a status=2 orphan the finisher just sealed is now status=3 and
	// the closer's status IN (1,2) candidate query skips it (no double work).
	return r.runProdTerminalCloser(ctx, prodPOs)
}

// terminalCloserDecision is the prod-terminal closer's per-candidate safety
// ladder — the pure twin of finisherDecision. It closes ONLY when the prod twin
// is authoritatively FINISHED (status=3); every other state is a safety skip:
//   - unverified: prod has no row for this id_order → can't confirm → skip;
//   - still active: prod's FRESH read shows status=2 → skip (never close a
//     running PO — the load-bearing safety rung, protects 894330/894668/894749);
//   - not terminal: prod is neither 2 nor 3 (available/paused) → skip (this
//     closer only closes FINISHED twins);
//   - no activity: prod gave no last-activity ts → skip (never fabricate one);
//   - grace: prod last-activity is inside the grace window → skip (possible
//     flap / mid-transition).
//
// Only a status=3 twin past all rungs returns outcomeFinish, with the close ts.
func terminalCloserDecision(info db.ProdPOFinishInfo, present bool, graceCutoff time.Time) finisherOutcome {
	if !present {
		return outcomeSkipUnverified
	}
	if info.Status == 2 {
		return outcomeSkipStillActive
	}
	if info.Status != 3 {
		return outcomeSkipNotTerminal
	}
	if !info.HasActivity {
		return outcomeSkipNoActivity
	}
	if info.LastActivity.After(graceCutoff) {
		return outcomeSkipGrace
	}
	return outcomeFinish
}

// runProdTerminalCloser closes the LAST finisher blemish: mirror-CREATED staging
// POs stuck at status IN (1,2) whose prod twin has already FINISHED (status=3).
// It reuses the finisher's prod authority (FetchPOFinishInfo) + grace window,
// but on a WIDER staging candidate set (TerminalOrphanCandidatePOs = status IN
// (1,2), reconcile-named only) and with a NULL-ts_start-safe close
// (CloseProdTerminalOrphanPO). SELECT-only on prod; the only mutation is the
// idempotent staging close. No-op (returns nil before any DB read) unless the
// flag is on, so it costs nothing until deliberately enabled.
func (r *Reconciler) runProdTerminalCloser(ctx context.Context, prodPOs []db.ProdActivePO) error {
	if !r.cfg.ReconcileCloseProdTerminalOrphans {
		return nil
	}
	candidatesMap, err := r.staging.TerminalOrphanCandidatePOs(ctx, r.cfg.StagingEnterpriseID)
	if err != nil {
		return fmt.Errorf("fetch mirror-created terminal-orphan candidates: %w", err)
	}

	// Reuse computeOrphans' set diff (layer 1): a candidate still in prod's
	// status=2 set is a legitimately-running PO and is excluded before any
	// per-candidate work.
	candidates := computeOrphans(candidatesMap, prodPOs)
	if len(candidates) == 0 {
		return nil
	}

	idOrders := make([]int64, len(candidates))
	for i, c := range candidates {
		idOrders[i] = c.IDOrder
	}
	info, err := r.prodDB.FetchPOFinishInfo(ctx, r.cfg.ProdEnterpriseID, idOrders)
	if err != nil {
		return fmt.Errorf("fetch prod PO finish info (terminal closer): %w", err)
	}

	graceCutoff := time.Now().UTC().Add(-time.Duration(r.cfg.ReconcileFinisherGraceMinutes) * time.Minute)
	r.logger.Info("prod-terminal closer: evaluating candidates",
		slog.Int("candidates", len(candidates)),
		slog.Int("grace_minutes", r.cfg.ReconcileFinisherGraceMinutes))

	for _, c := range candidates {
		pi, present := info[c.IDOrder]
		decision := terminalCloserDecision(pi, present, graceCutoff)
		if decision != outcomeFinish {
			metrics.ReconcilerProdTerminalCloserTotal.WithLabelValues(string(decision)).Inc()
			r.logger.Info("prod-terminal closer: skipping candidate",
				slog.Int64("id_order", c.IDOrder),
				slog.Int64("staging_po", c.StagingPOID),
				slog.String("decision", string(decision)),
				slog.Int("prod_status", pi.Status))
			continue
		}

		closed, err := r.staging.CloseProdTerminalOrphanPO(ctx, c.StagingPOID, pi.LastActivity)
		if err != nil {
			metrics.ReconcilerProdTerminalCloserTotal.WithLabelValues("failed").Inc()
			r.logger.Warn("prod-terminal closer: close failed — next pass will retry",
				slog.Int64("id_order", c.IDOrder),
				slog.Int64("staging_po", c.StagingPOID),
				slog.String("err", err.Error()))
			continue
		}
		if !closed {
			// Header already status!=(1,2) — a prior pass, the F1 finisher, or
			// another writer beat us. The idempotency guard did its job.
			metrics.ReconcilerProdTerminalCloserTotal.WithLabelValues("skipped_idempotent").Inc()
			continue
		}
		metrics.ReconcilerProdTerminalCloserTotal.WithLabelValues(string(outcomeFinish)).Inc()
		r.logger.Info("prod-terminal closer: closed orphaned PO at prod finish ts",
			slog.Int64("id_order", c.IDOrder),
			slog.Int64("staging_po", c.StagingPOID),
			slog.Int("prod_status", pi.Status),
			slog.Time("close_ts", pi.LastActivity))
	}
	return nil
}

// runF1Finisher executes one Flow-1 finisher pass on the prod-active snapshot
// already fetched by Run. Flow: read staging's mirror-managed active set → diff
// to orphan candidates (layer 1) → one batched prod cross-check → per-candidate
// decision (layers 2-4) → guarded staging close. SELECT-only on prod; the only
// mutation is FinishOrphanPO on staging, which is itself idempotent.
func (r *Reconciler) runF1Finisher(ctx context.Context, prodPOs []db.ProdActivePO) error {
	reconcileActive, err := r.staging.ReconcileActivePOIDOrders(ctx, r.cfg.SourceName, r.cfg.StagingEnterpriseID)
	if err != nil {
		return fmt.Errorf("fetch mirror-managed active staging POs: %w", err)
	}

	candidates := computeOrphans(reconcileActive, prodPOs)
	metrics.ReconcilerOrphanCandidates.Set(float64(len(candidates)))
	if len(candidates) == 0 {
		return nil
	}

	idOrders := make([]int64, len(candidates))
	for i, c := range candidates {
		idOrders[i] = c.IDOrder
	}
	info, err := r.prodDB.FetchPOFinishInfo(ctx, r.cfg.ProdEnterpriseID, idOrders)
	if err != nil {
		return fmt.Errorf("fetch prod PO finish info: %w", err)
	}

	graceCutoff := time.Now().UTC().Add(-time.Duration(r.cfg.ReconcileFinisherGraceMinutes) * time.Minute)
	r.logger.Info("finisher pass: evaluating orphan candidates",
		slog.Int("candidates", len(candidates)),
		slog.Int("grace_minutes", r.cfg.ReconcileFinisherGraceMinutes))

	for _, c := range candidates {
		pi, present := info[c.IDOrder]
		decision := finisherDecision(pi, present, graceCutoff)
		if decision != outcomeFinish {
			metrics.ReconcilerFinisherTotal.WithLabelValues(string(decision)).Inc()
			r.logger.Info("finisher: skipping orphan candidate",
				slog.Int64("id_order", c.IDOrder),
				slog.Int64("staging_po", c.StagingPOID),
				slog.String("decision", string(decision)),
				slog.Int("prod_status", pi.Status))
			continue
		}

		finished, err := r.staging.FinishOrphanPO(ctx, c.StagingPOID, pi.LastActivity)
		if err != nil {
			metrics.ReconcilerFinisherTotal.WithLabelValues("failed").Inc()
			r.logger.Warn("finisher: FinishOrphanPO failed — next pass will retry",
				slog.Int64("id_order", c.IDOrder),
				slog.Int64("staging_po", c.StagingPOID),
				slog.String("err", err.Error()))
			continue
		}
		if !finished {
			// Header already status!=2 (a prior pass, or another writer beat
			// us). The idempotency guard did its job — not a close, not a fail.
			metrics.ReconcilerFinisherTotal.WithLabelValues("skipped_idempotent").Inc()
			continue
		}
		metrics.ReconcilerFinisherTotal.WithLabelValues(string(outcomeFinish)).Inc()
		r.logger.Info("finisher: closed orphaned reconcile PO",
			slog.Int64("id_order", c.IDOrder),
			slog.Int64("staging_po", c.StagingPOID),
			slog.Int("prod_status", pi.Status),
			slog.Time("close_ts", pi.LastActivity))
	}
	return nil
}

// ──── ADR-0025 shadow fan-out (task #51) ───────────────────────────────────

// shadowAction is the correction the fan-out applies to ONE shadow flow's PO,
// derived purely from F1's authoritative shape under a prod veto.
type shadowAction int

const (
	shadowSkip shadowAction = iota
	shadowSeal
	shadowDelete
)

// shadowPlan is shadowFanoutPlan's verdict for one (flow, id_order): what to
// do and the header values to stamp so F2/F3 end byte-identical to F1.
type shadowPlan struct {
	action shadowAction
	reason string     // metric outcome label when action == shadowSkip
	sealTs time.Time  // seal boundary when action == shadowSeal
	status int        // F1's header status to reproduce
	tsEnd  *time.Time // F1's header ts_end to reproduce
}

// shadowFanoutPlan decides the shadow correction for one PO whose shadow rows
// are still status=2, from F1's authoritative shape + a fresh prod cross-check.
// Pure (no DB / no clock) so the whole safety ladder is unit-testable the way
// finisherDecision is.
//
// Safety ladder (ADR-0025):
//   - prod veto FIRST (choice #1: prod authority prevents an F1 bug from
//     propagating to the shadows) — skip if prod can't be confirmed or still
//     shows the PO running;
//   - F1 inconsistent (header closed but a segment still open) → skip, never
//     guess a correction;
//   - F1 has a sealed segment (paused/finished) → SEAL the shadow segment at
//     F1's upper bound, past grace; reproduce F1's status + ts_end;
//   - F1 has no segment (reset/available) → DELETE the shadow's phantom open
//     segment (no ts to seal at); reproduce F1's status + ts_end.
func shadowFanoutPlan(f1 db.F1POShape, prodInfo db.ProdPOFinishInfo, prodPresent bool, graceCutoff time.Time) shadowPlan {
	if !prodPresent {
		return shadowPlan{action: shadowSkip, reason: "skipped_prod_unverified"}
	}
	if prodInfo.Status == 2 {
		return shadowPlan{action: shadowSkip, reason: "skipped_prod_active"}
	}
	if f1.HasOpenSegment {
		return shadowPlan{action: shadowSkip, reason: "skipped_f1_open"}
	}
	if f1.SealedUpper != nil {
		if f1.SealedUpper.After(graceCutoff) {
			return shadowPlan{action: shadowSkip, reason: "skipped_grace"}
		}
		return shadowPlan{action: shadowSeal, sealTs: *f1.SealedUpper, status: f1.Status, tsEnd: f1.TsEnd}
	}
	return shadowPlan{action: shadowDelete, status: f1.Status, tsEnd: f1.TsEnd}
}

// runShadowFanout reproduces the F1 finisher's close on the shadow flows
// (F2 shadow_go_port, F3 packiot_shadow) by NATURAL KEY (id_enterprise,
// id_order), reusing the ADR-0012 fan-out pools. It is unconditional (runs
// even with zero F1 candidates) so pre-existing #49 zombies — F1 closed, F2/F3
// stuck status=2 — get corrected. Steps: collect each flow's still-open
// mirror-managed POs → read F1's authoritative shape for those id_orders →
// fresh prod cross-check → apply the pure plan per flow. F2 and F3 get the
// IDENTICAL F1-derived correction, so F2==F3 is preserved by construction.
//
// No-op when the fan-out plumbing isn't attached (ShadowFlows()==nil) — the
// finisher then degrades to F1-only, exactly like #480.
func (r *Reconciler) runShadowFanout(ctx context.Context, prodPOs []db.ProdActivePO) error {
	flows := r.staging.ShadowFlows()
	if len(flows) == 0 {
		return nil
	}

	// 1) Per-flow still-open candidates + the union of their id_orders.
	perFlow := make([]map[int64]int64, len(flows))
	idOrderSet := make(map[int64]struct{})
	for i, f := range flows {
		open, err := r.staging.ShadowActiveMirrorPOs(ctx, f, r.cfg.StagingEnterpriseID)
		if err != nil {
			return fmt.Errorf("shadow active POs (%s): %w", f.Name, err)
		}
		perFlow[i] = open
		for idOrder := range open {
			idOrderSet[idOrder] = struct{}{}
		}
	}
	if len(idOrderSet) == 0 {
		return nil
	}
	idOrders := sortedInt64Keys(idOrderSet)

	// 2) F1's authoritative shape (mirror-managed, already status!=2) + a fresh
	//    prod cross-check for the veto. F1-open POs are simply absent here → the
	//    caller leaves those shadow rows alone.
	f1Shapes, err := r.staging.F1MirrorClosedPOShapes(ctx, r.cfg.SourceName, r.cfg.StagingEnterpriseID, idOrders)
	if err != nil {
		return fmt.Errorf("F1 mirror-closed shapes: %w", err)
	}
	prodInfo, err := r.prodDB.FetchPOFinishInfo(ctx, r.cfg.ProdEnterpriseID, idOrders)
	if err != nil {
		return fmt.Errorf("prod finish info (shadow veto): %w", err)
	}
	graceCutoff := time.Now().UTC().Add(-time.Duration(r.cfg.ReconcileFinisherGraceMinutes) * time.Minute)

	// 3) Apply per flow, in stable id_order order for readable pass logs.
	for i, f := range flows {
		for _, idOrder := range sortedInt64ValueKeys(perFlow[i]) {
			f1, ok := f1Shapes[idOrder]
			if !ok {
				// F1 still status=2 (or not mirror-managed): F1-open is the
				// proxy for "prod may still be running" — leave the shadow row.
				metrics.ReconcilerShadowFanoutTotal.WithLabelValues(f.Name, "skipped_f1_active").Inc()
				continue
			}
			pi, present := prodInfo[idOrder]
			plan := shadowFanoutPlan(f1, pi, present, graceCutoff)
			switch plan.action {
			case shadowSeal:
				closed, err := r.staging.SealShadowOrphanPO(ctx, f, r.cfg.StagingEnterpriseID, idOrder, plan.sealTs, plan.status, plan.tsEnd)
				r.recordShadowClose(f, idOrder, "sealed", plan.status, plan.sealTs, closed, err)
			case shadowDelete:
				closed, err := r.staging.DeleteShadowOrphanSegment(ctx, f, r.cfg.StagingEnterpriseID, idOrder, plan.status, plan.tsEnd)
				var ts time.Time
				if plan.tsEnd != nil {
					ts = *plan.tsEnd
				}
				r.recordShadowClose(f, idOrder, "deleted", plan.status, ts, closed, err)
			default:
				metrics.ReconcilerShadowFanoutTotal.WithLabelValues(f.Name, plan.reason).Inc()
			}
		}
	}
	return nil
}

// recordShadowClose maps one shadow write result to its metric + a structured
// log line. The "shadow fan-out: closed orphaned PO" line is deliberately
// greppable per (flow, id_order, action, close_ts): the dba scopes the
// enable-time cagg refresh off exactly these lines (which equipment_runtime_*
// windows to invalidate = the sealed/deleted segments' [lower, close_ts]).
func (r *Reconciler) recordShadowClose(f db.ShadowFlow, idOrder int64, verb string, status int, closeTs time.Time, closed bool, err error) {
	if err != nil {
		metrics.ReconcilerShadowFanoutTotal.WithLabelValues(f.Name, "failed").Inc()
		r.logger.Warn("shadow fan-out: close failed — F1 unaffected, next tick retries",
			slog.String("flow", f.Name),
			slog.Int64("id_order", idOrder),
			slog.String("err", err.Error()))
		return
	}
	if !closed {
		// Header already !=2 (a prior pass, or another writer beat us) — the
		// idempotency guard did its job.
		metrics.ReconcilerShadowFanoutTotal.WithLabelValues(f.Name, "skipped_idempotent").Inc()
		return
	}
	metrics.ReconcilerShadowFanoutTotal.WithLabelValues(f.Name, verb).Inc()
	r.logger.Info("shadow fan-out: closed orphaned PO",
		slog.String("flow", f.Name),
		slog.Int64("id_order", idOrder),
		slog.String("action", verb),
		slog.Int("status", status),
		slog.Time("close_ts", closeTs))
}

// sortedInt64Keys returns the keys of a set in ascending order.
func sortedInt64Keys(m map[int64]struct{}) []int64 {
	out := make([]int64, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// sortedInt64ValueKeys returns the keys of an id_order→surrogate map ascending.
func sortedInt64ValueKeys(m map[int64]int64) []int64 {
	out := make([]int64, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// errAlreadyMapped is the sentinel returned by ensureOnePO when a mapping
// already exists. The caller treats it as outcome=skipped.
var errAlreadyMapped = errors.New("production_order already mapped")

// ensureOnePO does the create + start + map round-trip for one prod PO.
// Mirrors what the manual backfill bash script + InsertMapping do, but
// uses the same translator + staging edge-api the user_logs handlers use.
//
// The ts_start used for /start is `now() - 5s`, the same trick the
// backfill bash script uses to dodge getOrderDateConflict against
// historical finished POs on the same equipment. We deliberately do NOT
// reuse prod's ts_start because that would frequently be hours/days in
// the past — a faithful replay would slot the new staging PO into an
// already-occupied historical window. The intent here is to give staging
// a *currently active* PO mirror so future order-changed events have
// something to operate on, not to recreate prod's historical runtime
// shape (the operator UI on staging is a sandbox, not an audit trail).
func (r *Reconciler) ensureOnePO(ctx context.Context, p db.ProdActivePO) error {
	// Belt-and-suspenders: skip if the staging-id mapping already exists.
	// Run handles the "active on staging" case via the diff; this catches
	// the rarer "mapping written but staging PO got finished" race.
	if _, hit, err := r.staging.LookupMapping(ctx, "production_order", r.cfg.SourceName, p.IDProductionOrder); err != nil {
		return fmt.Errorf("lookup existing mapping: %w", err)
	} else if hit {
		metrics.ReconcilerPOsTotal.WithLabelValues("skipped").Inc()
		return errAlreadyMapped
	}

	stagingEqID, err := r.trans.Equipment(ctx, p.IDEquipment)
	if err != nil {
		return fmt.Errorf("translate equipment: %w", err)
	}
	stagingSiteID, err := r.trans.Site(ctx, p.IDSite)
	if err != nil {
		return fmt.Errorf("translate site: %w", err)
	}
	stagingAreaID, err := r.trans.Area(ctx, p.IDArea)
	if err != nil {
		return fmt.Errorf("translate area: %w", err)
	}

	// Pre-flight existence check (partial-create wedge fix). ensureOnePO does
	// create-then-start as two POSTs; recovery (reviveExistingStagingPO) only
	// fired on a create HTTP 400 "already exists". When edge-api is mid-deploy
	// and /create TIMES OUT (status 0) *after* a prior attempt already inserted
	// the row, the old flow wedged: it couldn't complete /create and couldn't
	// reach the 400-gated revive branch — leaving a prod-active line with a
	// staging PO stuck at status=1 (observed: id_order 894561, ~3h). Looking
	// staging up by (enterprise, id_order) BEFORE the create POST routes any
	// already-existing row straight to start/revive regardless of /create's
	// health, making create+start idempotent against partial progress +
	// endpoint degradation. SELECT-only on staging; no prod side effect.
	if _, exists, err := r.staging.LookupStagingPOByIDOrder(ctx, r.cfg.StagingEnterpriseID, p.IDOrder); err != nil {
		return fmt.Errorf("pre-flight staging PO lookup: %w", err)
	} else if exists {
		r.logger.Info("reconciler: pre-flight found existing staging PO — routing to start/revive (create POST skipped)",
			slog.Int64("prod_po", p.IDProductionOrder),
			slog.Int64("id_order", p.IDOrder))
		return r.reviveExistingStagingPO(ctx, p, stagingEqID, stagingSiteID, stagingAreaID)
	}

	// 1) Create.
	createBody := map[string]any{
		"idEnterprise":            r.cfg.StagingEnterpriseID,
		"idSite":                  stagingSiteID,
		"idArea":                  stagingAreaID,
		"idEquipment":             stagingEqID,
		"idOrder":                 p.IDOrder,
		"productionOrderQuantity": p.ProductionProgrammed,
		"nmProductionOrder":       fmt.Sprintf("CPACK-reconcile-%d", p.IDOrder),
		"txtProductionOrderNotes": "reconciled by mirror-worker-go EnsureActivePOs",
	}
	createKey := fmt.Sprintf("%s/recon/create/%d", r.cfg.SourceName, p.IDProductionOrder)
	if status, body, err := r.post(ctx, "/api/production-orders/create", createBody, createKey); err != nil {
		// "Already exists" means a staging PO carries this id_order but
		// isn't currently in status=2 (otherwise the existence diff would
		// have filtered it out upstream — typically finished, sometimes
		// paused). Without this branch the reconciler would WARN-loop
		// forever on the same row (one WARN every RECONCILE_INTERVAL_SEC,
		// for every prod active PO whose staging mirror got finished by a
		// prior order-stopped replay while prod kept the PO running).
		// Revive the existing row instead.
		if status == http.StatusBadRequest && isAlreadyExists(body) {
			return r.reviveExistingStagingPO(ctx, p, stagingEqID, stagingSiteID, stagingAreaID)
		}
		return fmt.Errorf("create POST: %w (status=%d body=%s)", err, status, truncate(body, 200))
	}

	// 2) Resolve the staging id we just created. Same business-key path
	// as order-created handler — keeps the two write paths consistent.
	stagingPOID, found, err := r.staging.LookupStagingPOByIDOrder(ctx, r.cfg.StagingEnterpriseID, p.IDOrder)
	if err != nil {
		return fmt.Errorf("lookup new staging PO: %w", err)
	}
	if !found {
		return fmt.Errorf("create succeeded but no staging PO with id_order=%d found", p.IDOrder)
	}

	// 3) Start.
	startTs := time.Now().UTC().Add(-5 * time.Second).Format(time.RFC3339)
	startBody := map[string]any{
		"idEnterprise":      r.cfg.StagingEnterpriseID,
		"idSite":            stagingSiteID,
		"idArea":            stagingAreaID,
		"idEquipment":       stagingEqID,
		"idProductionOrder": stagingPOID,
		"timestamp":         startTs,
	}
	startKey := fmt.Sprintf("%s/recon/start/%d", r.cfg.SourceName, p.IDProductionOrder)
	if status, body, err := r.post(ctx, "/api/production-orders/start", startBody, startKey); err != nil {
		return fmt.Errorf("start POST: %w (status=%d body=%s)", err, status, truncate(body, 200))
	}

	// 4) Persist the mapping so the next order-changed for this prod PO
	// resolves via the cache instead of the id_order business-key path.
	if err := r.staging.WithTx(ctx, func(tx pgx.Tx) error {
		return db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "production_order",
			Source:      r.cfg.SourceName,
			ProdID:      p.IDProductionOrder,
			StagingID:   stagingPOID,
			SourceLogID: 0, // 0 marks this as a reconciler insert, not from a user_log
		})
	}); err != nil {
		// Mapping insert failed but create+start already landed. The
		// next pass will see the active staging PO via the diff and
		// skip; the lost mapping is recoverable by hand if needed.
		// Don't fail the whole ensure — the user-visible state on
		// staging is already correct.
		r.logger.Warn("reconciler: mapping insert failed but PO created+started — next pass will skip via diff",
			slog.Int64("prod_po", p.IDProductionOrder),
			slog.Int64("staging_po", stagingPOID),
			slog.String("err", err.Error()))
	}

	r.logger.Info("reconciler: backfilled active PO",
		slog.Int64("prod_po", p.IDProductionOrder),
		slog.Int64("staging_po", stagingPOID),
		slog.Int64("id_order", p.IDOrder),
		slog.Int("staging_equipment", stagingEqID))
	return nil
}

// truncate is a small helper for log/error excerpts — full request bodies
// can be hundreds of KB and we don't want to dump them in worker logs.
func truncate(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[:n]) + "...[truncated]"
}

// reviveExistingStagingPO is called when /api/production-orders/create
// rejects with "Production order already exists" — meaning a staging row
// carries this prod id_order but isn't in status=2. Restores the active-PO
// invariant by looking up the existing row, POSTing /start (revives a
// finished PO, no-ops on an already-running one), and writing the mapping.
//
// Why not just skip + log: that leaves the staging mirror permanently out
// of sync (no active PO mirroring prod's active PO), which defeats the
// reconciler's purpose. The comparator's active_pos_diff gauge would
// stay non-zero indefinitely. Reviving keeps the watchdog signal honest.
//
// /start with "Production order already running" is treated as success —
// same intent-already-satisfied logic as the user_logs order-started
// handler (replay/httputil.go startAlreadySatisfiedMessages). Race surface:
// could fire when value-sync or another writer flipped the PO to status=2
// between the existence check and the create attempt.
func (r *Reconciler) reviveExistingStagingPO(ctx context.Context, p db.ProdActivePO, stagingEqID, stagingSiteID, stagingAreaID int) error {
	stagingPOID, found, err := r.staging.LookupStagingPOByIDOrder(ctx, r.cfg.StagingEnterpriseID, p.IDOrder)
	if err != nil {
		return fmt.Errorf("revive lookup: %w", err)
	}
	if !found {
		// Edge-api said "already exists" but our LookupStagingPOByIDOrder
		// can't find it. Different enterprise scoping bug, or edge-api
		// looks at a different uniqueness key than (enterprise, id_order).
		// Surface clearly so the bug doesn't hide as a generic error.
		return fmt.Errorf("revive: create rejected as already-exists but no staging PO with (enterprise=%d, id_order=%d) found",
			r.cfg.StagingEnterpriseID, p.IDOrder)
	}

	// 1) Start (revive). Same ts_start - 5s trick as ensureOnePO so we
	// dodge getOrderDateConflict against historical finished POs.
	startTs := time.Now().UTC().Add(-5 * time.Second).Format(time.RFC3339)
	startBody := map[string]any{
		"idEnterprise":      r.cfg.StagingEnterpriseID,
		"idSite":            stagingSiteID,
		"idArea":            stagingAreaID,
		"idEquipment":       stagingEqID,
		"idProductionOrder": stagingPOID,
		"timestamp":         startTs,
	}
	startKey := fmt.Sprintf("%s/recon/revive/%d", r.cfg.SourceName, p.IDProductionOrder)
	if status, body, err := r.post(ctx, "/api/production-orders/start", startBody, startKey); err != nil {
		if !(status == http.StatusBadRequest && isAlreadyRunning(body)) {
			return fmt.Errorf("revive start POST: %w (status=%d body=%s)", err, status, truncate(body, 200))
		}
		// "Already running" — intent already satisfied. Fall through to mapping.
		r.logger.Info("reconciler: revive found staging PO already running — writing mapping only",
			slog.Int64("prod_po", p.IDProductionOrder),
			slog.Int64("staging_po", stagingPOID),
			slog.Int64("id_order", p.IDOrder))
	}

	// 2) Persist the mapping. Same swallowing-of-mapping-error pattern as
	// ensureOnePO — if it fails, the next pass will see the active staging
	// PO via the diff and skip; user-visible state is already correct.
	if err := r.staging.WithTx(ctx, func(tx pgx.Tx) error {
		return db.InsertMapping(ctx, tx, db.MapInsert{
			EntityType:  "production_order",
			Source:      r.cfg.SourceName,
			ProdID:      p.IDProductionOrder,
			StagingID:   stagingPOID,
			SourceLogID: 0,
		})
	}); err != nil {
		r.logger.Warn("reconciler: revive mapping insert failed but PO revived — next pass will skip via diff",
			slog.Int64("prod_po", p.IDProductionOrder),
			slog.Int64("staging_po", stagingPOID),
			slog.String("err", err.Error()))
	}

	r.logger.Info("reconciler: revived existing staging PO",
		slog.Int64("prod_po", p.IDProductionOrder),
		slog.Int64("staging_po", stagingPOID),
		slog.Int64("id_order", p.IDOrder),
		slog.Int("staging_equipment", stagingEqID))
	return nil
}
