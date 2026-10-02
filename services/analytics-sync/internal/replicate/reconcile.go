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
// after review, matching the migration's discipline.
//
// Runtime windows (2026-10-02): a PO with a ts_start but NO runtime row gets one
// here — both a PO this pass inserted and one already on the twin. The PO compute
// reads ONLY production_orders_runtime, so a header without a window computes 0
// forever (while staying flagged). Until 10-02 window creation was omitted here,
// which was harmless while nearly every PO arrived through the replay; from 09-29
// most CPACK starts reached the replay BEFORE the PO existed on the twin (the start
// failed open: "update matched no rows"), the reconciler inserted the header 5 min
// later, and 16/28 → 7/30 → 8/22 POs per day ran with no window. The insert carries
// the same overlap guard as sqlOpenWindow (no-op instead of an exclusion-constraint
// error), so a PO whose neighbour still holds a stale open window is simply retried
// on a later pass, after the neighbour's finish has closed it.
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
	AddReconcileEnriched(n int)
	IncReconcileEnrichSkip(reason string)
}

type noopReconcileMetrics struct{}

func (noopReconcileMetrics) IncReconcileInserted()         {}
func (noopReconcileMetrics) IncReconcileFinished()         {}
func (noopReconcileMetrics) IncReconcileUnresolved()       {}
func (noopReconcileMetrics) AddReconcileEnriched(int)      {}
func (noopReconcileMetrics) IncReconcileEnrichSkip(string) {}

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
const sqlReconcileInsertPO = `INSERT INTO core.production_orders (
		id_enterprise, id_site, id_area, id_equipment, id_order, status,
		production_programmed, production_ordered, production_real, production_final,
		ts_start, ts_end, nm_production_order, txt_production_order_notes, recalc_needed)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,true)
	ON CONFLICT (id_enterprise, id_order) DO NOTHING`

// Finishes a twin PO that legacy has finished/paused LATER than the twin knows:
// a zombie still running (status 2), or — since 2026-09-29 — a PO the twin holds
// as PAUSED (status 4) with an earlier end while legacy resumed and finished it
// (FLEXO 894815/896297/8962980…: legacy 3, twin 4 with the pause's ts_end: the
// resume was never replayed and a late pause replay rolled the finish back).
// Monotonic: only ever moves the end FORWARD, never below ts_start.
const sqlReconcileFinishPO = `UPDATE core.production_orders
	   SET status = $1, ts_end = $2, production_final = COALESCE($3, production_final),
	       recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $4 AND id_order = $5 AND status IN (2, 4)
	   AND (ts_end IS NULL OR ts_end < $2)
	   AND (ts_start IS NULL OR ts_start <= $2)`

// Fills a twin PO's missing ts_start from legacy (an order-replaced or a
// pre-existing-PO start the replay missed left it NULL; 13 CPACK POs 08-08..09-29).
const sqlReconcileFillStart = `UPDATE core.production_orders
	   SET ts_start = $1, recalc_needed = true, last_update = now()
	 WHERE id_enterprise = $2 AND id_order = $3 AND ts_start IS NULL
	   AND (ts_end IS NULL OR ts_end >= $1)`

// sqlReconcileBackfillWindow gives a started PO with NO runtime row its window,
// from the twin's own header: [ts_start, ts_end) when it ended, [ts_start, ∞) while
// running. A PO that never started (no ts_start, status 1) or a zero-length run gets
// none. Overlap-guarded per equipment exactly like sqlOpenWindow.
const sqlReconcileBackfillWindow = `INSERT INTO gold.production_orders_runtime
	       (id_production_order, id_equipment, runtime_timerange, recalc_needed)
	SELECT po.id_production_order, po.id_equipment, tstzrange(po.ts_start, po.ts_end), true
	  FROM core.production_orders po
	 WHERE po.id_enterprise = $1 AND po.id_order = $2
	   AND po.status IN (2, 3, 4) AND po.ts_start IS NOT NULL
	   AND (po.ts_end IS NULL OR po.ts_end > po.ts_start)
	   AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime r
	        WHERE r.id_production_order = po.id_production_order)
	   AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime x
	        WHERE x.id_equipment = po.id_equipment
	          AND x.runtime_timerange && tstzrange(po.ts_start, po.ts_end))`

// sqlReconcileWindowGap reports whether a started PO still has no runtime row
// after the backfill attempt — the overlap-blocked case, counted per pass so a
// window that can never be created is visible in the logs instead of silent.
const sqlReconcileWindowGap = `SELECT EXISTS (SELECT 1 FROM core.production_orders po
	 WHERE po.id_enterprise = $1 AND po.id_order = $2
	   AND po.status IN (2, 3, 4) AND po.ts_start IS NOT NULL
	   AND (po.ts_end IS NULL OR po.ts_end > po.ts_start)
	   AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime r
	        WHERE r.id_production_order = po.id_production_order))`

// ensureWindow runs the backfill for one PO; returns (opened, stillMissing).
func (rc *POReconciler) ensureWindow(ctx context.Context, ent int, idOrder int64) (bool, bool) {
	ct, err := rc.dest.Exec(ctx, sqlReconcileBackfillWindow, ent, idOrder)
	if err != nil {
		rc.logger.Warn("PO reconcile: window backfill failed",
			slog.Int64("id_order", idOrder), slog.String("err", err.Error()))
		return false, true
	}
	if ct.RowsAffected() > 0 {
		return true, false
	}
	var missing bool
	if err := rc.dest.QueryRow(ctx, sqlReconcileWindowGap, ent, idOrder).Scan(&missing); err != nil {
		return false, false
	}
	return false, missing
}

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
	if rc.cfg.Hold.Held(ctx) {
		return // sandbox hands-on session — the grace-period heal restores POs
	}
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
	windowsOpened, windowsBlocked := 0, 0
	window := func(idOrder int64) {
		opened, missing := rc.ensureWindow(ctx, ent, idOrder)
		if opened {
			windowsOpened++
		}
		if missing {
			windowsBlocked++
		}
	}
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
			`SELECT status FROM core.production_orders WHERE id_enterprise = $1 AND id_order = $2`,
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
			window(p.idOrder)
		case err != nil:
			rc.logger.Warn("PO reconcile: twin lookup failed",
				slog.Int64("id_order", p.idOrder), slog.String("err", err.Error()))
			continue
		default:
			// Present on the twin. A start the replay missed leaves ts_start NULL:
			// take legacy's.
			if p.tsStart.Valid {
				if _, e := rc.dest.Exec(ctx, sqlReconcileFillStart, p.tsStart.Time, ent, p.idOrder); e != nil {
					rc.logger.Warn("PO reconcile: fill start failed",
						slog.Int64("id_order", p.idOrder), slog.String("err", e.Error()))
				}
			}
			// Finish it if legacy has finished/paused it later than the twin knows
			// (a zombie still running, or a paused twin legacy resumed and finished).
			if (twinStatus == 2 || twinStatus == 4) && (p.status == 3 || p.status == 4) && p.tsEnd.Valid {
				if e := closeRuntimeWindow(ctx, rc.dest, ent, p.idOrder, p.tsEnd.Time, 0, rc.logger); e != nil {
					rc.logger.Warn("PO reconcile: close window failed",
						slog.Int64("id_order", p.idOrder), slog.String("err", e.Error()))
				}
				ct, e := rc.dest.Exec(ctx, sqlReconcileFinishPO,
					p.status, p.tsEnd.Time, nullIntArg(p.productionFinal), ent, p.idOrder)
				if e != nil {
					rc.logger.Warn("PO reconcile: finish failed",
						slog.Int64("id_order", p.idOrder), slog.String("err", e.Error()))
					continue
				}
				if ct.RowsAffected() > 0 {
					finished++
					rc.m.IncReconcileFinished()
				}
			}
			// After fill-start / finish, so the window uses the header's final bounds.
			window(p.idOrder)
		}
	}
	rc.logger.Info("PO reconcile pass done",
		slog.Int("legacy_pos", len(pos)),
		slog.Int("inserted", inserted),
		slog.Int("finished", finished),
		slog.Int("unresolved", unresolved),
		slog.Int("skipped_running_conflict", skippedRunning),
		slog.Int("windows_opened", windowsOpened),
		slog.Int("windows_blocked_overlap", windowsBlocked))

	if rc.cfg.ReconcileEnrichEnabled {
		rc.runEnrich(ctx)
	}
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
