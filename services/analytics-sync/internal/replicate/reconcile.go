package replicate

// PO reconciler — authoritative production_orders backfill/finish loop.
//
// The user_logs replay (loop.go + handlers.go) only mirrors POs whose
// lifecycle flowed through the operator audit trail. Two large classes of
// legacy CPACK PO never do:
//
//  1. order-changed with shouldOpenNewPo=true AND shouldCreatePo=false — the
//     operator starts a *pre-existing* next PO. OrderChanged() closes the old
//     PO but returns before opening the new one (it only creates when
//     shouldCreatePo=true), so the started PO is never mirrored. This is the
//     dominant gap: ~46 such rows/7d vs ~73 shouldCreatePo=true rows.
//  2. PLC-created POs (SparkPlug 30800–30899 writes) that bypass edge-api's
//     audit middleware entirely — no user_log row at all.
//
// Net effect measured 2026-08-27: twin ent-3 held 81 of legacy ent-1's 123
// distinct id_orders over a 7d window (~34% missing, almost all finished).
//
// This reconciler closes the gap the same way mirror-worker-go's
// EnsureActivePOs + finisher do: it diffs legacy production_orders (SELECT-only)
// against the twin by the (id_enterprise, id_order) natural key and
//   - INSERTs any missing PO authoritatively from legacy's row (status,
//     ts_start/ts_end, production_real/final, equipment mapped via the resolver),
//     with recalc_needed=true so the OEE worker recomputes it; and
//   - FINISHES a twin PO stuck status=2 whose legacy twin has already
//     finished/paused (the stuck-open-window / zombie-PO class), closing its
//     runtime window at legacy's ts_end.
//
// It is idempotent (ON CONFLICT DO NOTHING + status guards), read-only on
// legacy, and ships INERT (RECONCILE_PO_ENABLED=false) — enabled deliberately
// after review, matching the migration's discipline. Runtime-window creation
// for freshly-inserted POs is intentionally omitted: production_orders_runtime
// carries a per-equipment no-overlap exclusion constraint, and stuck-open
// windows on the twin routinely span the whole period, so a blind insert
// aborts the batch. Counters still flow from recalc_needed; window fidelity for
// non-telemetry lines is a documented limitation.
import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ReconcileMetrics is the counter surface the PO reconciler bumps. *metrics.Metrics
// satisfies it; kept as an interface so tests can pass a no-op.
type ReconcileMetrics interface {
	IncReconcileInserted()
	IncReconcileFinished()
	IncReconcileUnresolved()
}

type noopReconcileMetrics struct{}

func (noopReconcileMetrics) IncReconcileInserted()   {}
func (noopReconcileMetrics) IncReconcileFinished()   {}
func (noopReconcileMetrics) IncReconcileUnresolved() {}

type POReconciler struct {
	legacy *pgxpool.Pool
	dest   *pgxpool.Pool
	r      *Resolver
	cfg    *Config
	m      ReconcileMetrics
	logger *slog.Logger
}

func NewPOReconciler(legacy, dest *pgxpool.Pool, r *Resolver, cfg *Config, m ReconcileMetrics, logger *slog.Logger) *POReconciler {
	if m == nil {
		m = noopReconcileMetrics{}
	}
	return &POReconciler{legacy: legacy, dest: dest, r: r, cfg: cfg, m: m, logger: logger}
}

// insert missing PO header from legacy's authoritative row. ON CONFLICT keeps
// it idempotent against a concurrent handler insert or a re-run.
const sqlReconcileInsertPO = `INSERT INTO public.production_orders (
		id_enterprise, id_site, id_area, id_equipment, id_order, status,
		production_programmed, production_ordered, production_real, production_final,
		ts_start, ts_end, nm_production_order, txt_production_order_notes, recalc_needed)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,true)
	ON CONFLICT (id_enterprise, id_order) DO NOTHING`

const sqlReconcileFinishPO = `UPDATE public.production_orders
	   SET status = $1, ts_end = $2, production_final = COALESCE($3, production_final),
	       recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $4 AND id_order = $5 AND status = 2`

type legacyPO struct {
	idOrder              int64
	idEquipment          int
	status               int
	tsStart              sql.NullTime
	tsEnd                sql.NullTime
	productionReal       sql.NullInt64
	productionFinal      sql.NullInt64
	productionProgrammed sql.NullInt64
	productionOrdered    sql.NullInt64
	idOrderText          sql.NullString
	notes                sql.NullString
}

// RunForever runs one pass at startup then on the configured interval. Returns
// when ctx is cancelled. A pass failure is logged, not fatal — the next tick
// retries (same posture as the replay loop's fetch-fail path).
func (rc *POReconciler) RunForever(ctx context.Context) error {
	if !rc.cfg.ReconcileEnabled {
		rc.logger.Info("PO reconciler disabled (RECONCILE_PO_ENABLED=false)")
		<-ctx.Done()
		return ctx.Err()
	}
	interval := time.Duration(rc.cfg.ReconcileIntervalSec) * time.Second
	rc.logger.Info("PO reconciler started",
		slog.Int("interval_sec", rc.cfg.ReconcileIntervalSec),
		slog.Int("window_days", rc.cfg.ReconcileWindowDays),
		slog.Int("src_enterprise", rc.cfg.SrcEnterprise),
		slog.Int("dst_enterprise", rc.cfg.DstEnterprise))
	rc.runOnce(ctx)
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			rc.runOnce(ctx)
		}
	}
}

func (rc *POReconciler) runOnce(ctx context.Context) {
	since := time.Now().AddDate(0, 0, -rc.cfg.ReconcileWindowDays)
	rows, err := rc.legacy.Query(ctx,
		`SELECT id_order, id_equipment, status, ts_start, ts_end,
		        production_real, production_final, production_programmed, production_ordered,
		        id_order_text, txt_production_order_notes
		   FROM production_orders
		  WHERE id_enterprise = $1 AND (ts_start > $2 OR ts_end > $2)`,
		rc.cfg.SrcEnterprise, since)
	if err != nil {
		rc.logger.Warn("PO reconcile: legacy fetch failed", slog.String("err", err.Error()))
		return
	}
	var pos []legacyPO
	for rows.Next() {
		var p legacyPO
		if err := rows.Scan(&p.idOrder, &p.idEquipment, &p.status, &p.tsStart, &p.tsEnd,
			&p.productionReal, &p.productionFinal, &p.productionProgrammed, &p.productionOrdered,
			&p.idOrderText, &p.notes); err != nil {
			rc.logger.Warn("PO reconcile: scan failed", slog.String("err", err.Error()))
			rows.Close()
			return
		}
		pos = append(pos, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		rc.logger.Warn("PO reconcile: legacy rows err", slog.String("err", err.Error()))
		return
	}

	inserted, finished, unresolved, skippedRunning := 0, 0, 0, 0
	ent := rc.cfg.DstEnterprise
	for i := range pos {
		p := &pos[i]
		eq, ok := rc.r.ResolveEquipment(p.idEquipment)
		if !ok {
			unresolved++
			rc.m.IncReconcileUnresolved()
			continue
		}
		var twinStatus int
		err := rc.dest.QueryRow(ctx,
			`SELECT status FROM production_orders WHERE id_enterprise = $1 AND id_order = $2`,
			ent, p.idOrder).Scan(&twinStatus)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			// Missing on the twin — insert the header authoritatively.
			if p.status == 2 {
				// Guard the UNIQUE(id_equipment) WHERE status=2 partial index:
				// never insert a second running PO on the same equipment.
				var running int
				if e := rc.dest.QueryRow(ctx,
					`SELECT count(*) FROM production_orders WHERE id_enterprise=$1 AND id_equipment=$2 AND status=2`,
					ent, eq.IDEquipment).Scan(&running); e == nil && running > 0 {
					skippedRunning++
					continue
				}
			}
			ct, e := rc.dest.Exec(ctx, sqlReconcileInsertPO,
				ent, eq.IDSite, eq.IDArea, eq.IDEquipment, p.idOrder, p.status,
				nullIntArg(p.productionProgrammed), nullIntArg(p.productionOrdered),
				nullIntArg(p.productionReal), nullIntArg(p.productionFinal),
				nullTimeArg(p.tsStart), nullTimeArg(p.tsEnd),
				nullStrArg(p.idOrderText), nullStrArg(p.notes))
			if e != nil {
				rc.logger.Warn("PO reconcile: insert failed",
					slog.Int64("id_order", p.idOrder), slog.String("err", e.Error()))
				continue
			}
			if ct.RowsAffected() > 0 {
				inserted++
				rc.m.IncReconcileInserted()
			}
		case err != nil:
			rc.logger.Warn("PO reconcile: twin lookup failed",
				slog.Int64("id_order", p.idOrder), slog.String("err", err.Error()))
			continue
		default:
			// Present on the twin. Finish it if legacy has moved to
			// finished/paused but the twin is stuck running (zombie PO).
			if twinStatus == 2 && (p.status == 3 || p.status == 4) && p.tsEnd.Valid {
				if e := closeRuntimeWindow(ctx, rc.dest, ent, p.idOrder, p.tsEnd.Time, 0, rc.logger); e != nil {
					rc.logger.Warn("PO reconcile: close window failed",
						slog.Int64("id_order", p.idOrder), slog.String("err", e.Error()))
				}
				if _, e := rc.dest.Exec(ctx, sqlReconcileFinishPO,
					p.status, p.tsEnd.Time, nullIntArg(p.productionFinal), ent, p.idOrder); e != nil {
					rc.logger.Warn("PO reconcile: finish failed",
						slog.Int64("id_order", p.idOrder), slog.String("err", e.Error()))
					continue
				}
				finished++
				rc.m.IncReconcileFinished()
			}
		}
	}
	rc.logger.Info("PO reconcile pass done",
		slog.Int("legacy_pos", len(pos)),
		slog.Int("inserted", inserted),
		slog.Int("finished", finished),
		slog.Int("unresolved", unresolved),
		slog.Int("skipped_running_conflict", skippedRunning))
}

// nullX helpers turn database/sql Null wrappers into interface{} args pgx
// accepts (nil for NULL, the scalar otherwise). Passing the Null struct
// directly also works, but an explicit nil keeps the wire value unambiguous.
func nullIntArg(v sql.NullInt64) any {
	if !v.Valid {
		return nil
	}
	return v.Int64
}
func nullTimeArg(v sql.NullTime) any {
	if !v.Valid {
		return nil
	}
	return v.Time
}
func nullStrArg(v sql.NullString) any {
	if !v.Valid || v.String == "" {
		return nil
	}
	return v.String
}
