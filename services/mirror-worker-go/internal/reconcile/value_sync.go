package reconcile

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
)

// RunValueSyncForever ticks every ReconcileValuesIntervalSec and, for
// each mapped active CPACK PO, INSERTs one synthetic equipment_values
// row carrying the (prod − staging) delta. The per-minute pg_cron job
// piot_proc_refresh_runtime then sums equipment_values per active PO
// window into production_orders_runtime — so staging counters track
// prod values via a single deterministic source per row.
//
// Reproducibility note: this only works because simulator/simulator.py
// SKIPS the CPACK enterprise by default (SIM_SKIP_ENTERPRISE_IDS=3),
// so the reconciler is the sole writer of equipment_values for CPACK
// equipment. If you re-enable the simulator for CPACK, the cron will
// sum BOTH sources and the staging counter will drift up.
func (r *Reconciler) RunValueSyncForever(ctx context.Context) error {
	if !r.cfg.ReconcileValuesEnabled {
		r.logger.Info("value sync disabled via RECONCILE_VALUES_ENABLED=false")
		return nil
	}
	interval := time.Duration(r.cfg.ReconcileValuesIntervalSec) * time.Second
	r.logger.Info("value sync starting",
		slog.Int("interval_sec", r.cfg.ReconcileValuesIntervalSec))
	for {
		if err := r.RunValueSync(ctx); err != nil {
			r.logger.Warn("value sync tick failed", slog.String("err", err.Error()))
		}
		select {
		case <-time.After(interval):
		case <-ctx.Done():
			r.logger.Info("value sync stopping")
			return nil
		}
	}
}

// RunValueSync executes one value-sync tick. Exported so an /admin
// endpoint can trigger an out-of-band sync later if needed.
func (r *Reconciler) RunValueSync(ctx context.Context) error {
	start := time.Now()
	mapped, err := r.staging.FetchMappedActiveCPACKPOs(ctx, r.cfg.SourceName, r.cfg.StagingEnterpriseID)
	if err != nil {
		return fmt.Errorf("fetch mapped active POs: %w", err)
	}
	if len(mapped) == 0 {
		return nil
	}

	prodPOIDs := make([]int64, len(mapped))
	for i, m := range mapped {
		prodPOIDs[i] = m.ProdPOID
	}
	prodValues, err := r.prodDB.FetchRuntimeValues(ctx, prodPOIDs)
	if err != nil {
		return fmt.Errorf("fetch prod runtime values: %w", err)
	}

	var synced, skipped int
	for _, m := range mapped {
		prod, ok := prodValues[m.ProdPOID]
		if !ok {
			// Prod runtime row missing — can happen briefly between
			// prod's /create and the first cron tick that populates
			// runtime. Skip until next tick.
			skipped++
			continue
		}
		netDelta, grossDelta := computeDelta(prod, m)
		if netDelta == 0 && grossDelta == 0 {
			// Already in sync — no work, no INSERT noise.
			skipped++
			continue
		}
		if err := r.staging.InsertEquipmentValueDelta(ctx,
			m.StagingEquipment, m.StagingSite, m.StagingArea, r.cfg.StagingEnterpriseID,
			netDelta, grossDelta); err != nil {
			r.logger.Warn("value sync: insert delta failed",
				slog.Int64("staging_po", m.StagingPOID),
				slog.Int64("prod_po", m.ProdPOID),
				slog.String("err", err.Error()))
			metrics.ReconcilerValuesSyncedTotal.WithLabelValues("failed").Inc()
			continue
		}
		synced++
		metrics.ReconcilerValuesSyncedTotal.WithLabelValues("ok").Inc()
	}
	r.logger.Info("value sync tick complete",
		slog.Int("mapped", len(mapped)),
		slog.Int("synced", synced),
		slog.Int("skipped", skipped),
		slog.Duration("elapsed", time.Since(start)))
	return nil
}

// computeDelta returns the (net, gross) delta that, when summed by the
// cron with the staging runtime's current value, lands at prod's value.
//
// Treats NULL prod values as 0 — the runtime row exists but cron hasn't
// computed yet. Treats NULL staging values as 0 — first sync after
// reconciler create. Negative deltas are allowed (prod operator may
// have edited a PO backwards via /api/production-orders/recalc etc.).
//
// Exposed as a free function for unit testing.
func computeDelta(prod db.ProdRuntimeValues, staging db.MappedActivePO) (netDelta, grossDelta float64) {
	prodNet := derefOr(prod.NetProduction, 0)
	prodGross := derefOr(prod.GrossProduction, 0)
	stagingNet := derefOr(staging.StagingNetProduction, 0)
	stagingGross := derefOr(staging.StagingGrossProduction, 0)
	return prodNet - stagingNet, prodGross - stagingGross
}

func derefOr(p *float64, fallback float64) float64 {
	if p == nil {
		return fallback
	}
	return *p
}
