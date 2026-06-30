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
	cfg      *config.Config
	prodDB   *db.Prod
	staging  *db.Staging
	trans    *translate.Translator
	apiToken func() string
	httpc    *http.Client
	logger   *slog.Logger

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

// RunForever blocks until ctx is canceled. Triggers the first pass
// immediately so a fresh worker doesn't wait IntervalSec before catching
// up on day-0 drift; subsequent passes fire on the interval.
func (r *Reconciler) RunForever(ctx context.Context) error {
	if !r.cfg.ReconcileEnabled {
		r.logger.Info("reconciler disabled via RECONCILE_ENABLED=false")
		return nil
	}
	interval := time.Duration(r.cfg.ReconcileIntervalSec) * time.Second
	r.logger.Info("reconciler starting",
		slog.Int("interval_sec", r.cfg.ReconcileIntervalSec),
		slog.Int("max_per_run", r.cfg.ReconcileMaxPerRun))
	for {
		if err := r.Run(ctx); err != nil {
			r.logger.Warn("reconciler pass failed", slog.String("err", err.Error()))
		}
		select {
		case <-time.After(interval):
		case <-ctx.Done():
			r.logger.Info("reconciler stopping")
			return nil
		}
	}
}

// Run executes one reconciliation pass. Exported so future ad-hoc
// triggers (e.g. an HTTP endpoint, a SIGUSR1 handler) can invoke
// without waiting for the next tick.
func (r *Reconciler) Run(ctx context.Context) error {
	start := time.Now()
	prodPOs, err := r.prodDB.FetchActivePOs(ctx, r.cfg.ProdEnterpriseID)
	if err != nil {
		metrics.ReconcilerRunsTotal.WithLabelValues("failed").Inc()
		return fmt.Errorf("fetch prod active POs: %w", err)
	}
	stagingActive, err := r.staging.ActivePOIDOrders(ctx, r.cfg.StagingEnterpriseID)
	if err != nil {
		metrics.ReconcilerRunsTotal.WithLabelValues("failed").Inc()
		return fmt.Errorf("fetch staging active id_orders: %w", err)
	}

	missing := computeMissing(prodPOs, stagingActive)

	metrics.ReconcilerActiveDriftPOs.Set(float64(len(missing)))

	if len(missing) == 0 {
		metrics.ReconcilerRunsTotal.WithLabelValues("ok").Inc()
		r.logger.Info("reconciler pass: in sync",
			slog.Int("prod_active", len(prodPOs)),
			slog.Int("staging_active", len(stagingActive)),
			slog.Duration("elapsed", time.Since(start)))
		return nil
	}

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
	metrics.ReconcilerRunsTotal.WithLabelValues("ok").Inc()
	r.logger.Info("reconciler pass complete", slog.Duration("elapsed", time.Since(start)))
	return nil
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
		"idSite":             stagingSiteID,
		"idArea":             stagingAreaID,
		"idEquipment":        stagingEqID,
		"idProductionOrder":  stagingPOID,
		"timestamp":          startTs,
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
