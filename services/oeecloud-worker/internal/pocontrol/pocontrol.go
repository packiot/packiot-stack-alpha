package pocontrol

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// Handler executes the PO lifecycle commands. One instance per worker;
// the pool is chosen per message by the caller (source_type routing).
type Handler struct {
	resolver *sparkplug.Resolver
	logger   *slog.Logger

	started  atomic.Uint64
	topology atomic.Uint64
	created  atomic.Uint64
	events   atomic.Uint64
	ended    atomic.Uint64
	noops    atomic.Uint64
	dropped  atomic.Uint64
}

func NewHandler(r *sparkplug.Resolver, logger *slog.Logger) *Handler {
	return &Handler{resolver: r, logger: logger}
}

// paramPayload is the slice-1 subset of sparkplug_metrics_key fields
// the lifecycle commands read.
type paramPayload struct {
	Value     json.Number `json:"value"`      // id_production_order (may be absent)
	IDOrder   json.Number `json:"id_order"`   // natural-key fallback
	Timestamp json.Number `json:"timestamp"`  // ms
	Note      string      `json:"note"`       // URI-encoded in prod; stored decoded upstream
	ProdFinal json.Number `json:"prod_final"` // optional final production count
}

// Handles reports whether this param id belongs to a ported slice.
func Handles(id int) bool {
	return (id >= 30800 && id <= 30803) || HandlesTopology(id) || HandlesCreatePO(id) || HandlesEvents(id) || HandlesSetup(id)
}

// Execute runs one PO-control parameter end-to-end in a single tx.
// Failures are logged + counted + DROPPED (nodered catch semantics —
// see package doc #3). The returned error is always nil by design;
// callers must not retry.
func (h *Handler) Execute(ctx context.Context, pool *pgxpool.Pool, m *sparkplug.Metric, schema string) error {
	if err := h.execute(ctx, pool, m, schema); err != nil {
		h.dropped.Add(1)
		h.logger.Error("po-control command dropped (no retry — nodered catch semantics)",
			slog.Int("param", derefID((*int)(m.ID))), slog.String("err", err.Error()))
	}
	return nil
}

func (h *Handler) execute(ctx context.Context, pool *pgxpool.Pool, m *sparkplug.Metric, schema string) error {
	paramID := derefID((*int)(m.ID))

	info, ok, err := h.resolveOrNoop(ctx, m)
	if err != nil || !ok {
		return err
	}

	var p paramPayload
	if uerr := json.Unmarshal(m.Value, &p); uerr != nil {
		// 30800-family metrics carry an object payload; value alone is
		// also legal for 30800 (the id). Try the scalar form.
		p = paramPayload{Value: json.Number(string(m.Value))}
	}
	tsMs, terr := p.Timestamp.Int64()
	if terr != nil || tsMs == 0 {
		tsMs = m.Timestamp
	}
	// Prod: Math.round(ms/1000)*1000 — nearest second.
	ts := time.UnixMilli(tsMs).Round(time.Second).UTC()
	ts1 := ts.Add(time.Second)     // ts_end stamps
	tsPrev := ts.Add(-time.Second) // EV marker on end

	// Slice 2 (30700 topology) has its own tx + table set — dispatch
	// before the lifecycle tx begins (topology.go guardrail note).
	if paramID == 30700 {
		return h.executeTopology(ctx, pool, m, schema)
	}
	if paramID == 30805 {
		return h.executeCreatePO(ctx, pool, m, schema)
	}
	if HandlesEvents(paramID) {
		return h.executeEvents(ctx, pool, m, schema)
	}
	if HandlesSetup(paramID) {
		return h.executeSetupOrUserlog(ctx, pool, m, schema)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	targetID, err := h.resolveTargetID(ctx, tx, schema, info.IDEquipment, p)
	if err != nil {
		return err
	}

	switch paramID {
	case 30800, 30802:
		if targetID == 0 {
			h.noops.Add(1)
			return nil // target unresolvable — nodered would have errored out
		}
		var targetStatus int
		if err := tx.QueryRow(ctx,
			fmt.Sprintf(`SELECT status FROM %s.production_orders WHERE id_production_order=$1`, schema),
			targetID).Scan(&targetStatus); err != nil {
			return fmt.Errorf("target status: %w", err)
		}
		running, err := h.runningPO(ctx, tx, schema, info.IDEquipment)
		if err != nil {
			return err
		}
		plan := DecideStart(paramID, targetID, targetStatus, running)
		if plan.NoOp {
			h.noops.Add(1)
			return nil
		}
		if err := h.execStart(ctx, tx, schema, info, targetID, plan, p, ts, ts1); err != nil {
			return err
		}
		if plan.EndPrev != nil {
			if err := h.execEnd(ctx, tx, schema, info, *plan.EndPrev, p, ts, ts1, tsPrev); err != nil {
				return err
			}
			// Juggle completion: restore the target to running, clear
			// the temporary ts_end.
			if _, err := tx.Exec(ctx, fmt.Sprintf(
				`UPDATE %s.production_orders SET status=2, ts_end=NULL WHERE id_production_order=$1`,
				schema), plan.RestoreID); err != nil {
				return fmt.Errorf("juggle restore: %w", err)
			}
		}
		h.started.Add(1)

	case 30801, 30803:
		running, err := h.runningPO(ctx, tx, schema, info.IDEquipment)
		if err != nil {
			return err
		}
		plan := DecideEnd(paramID, running)
		if plan.NoOp {
			h.noops.Add(1)
			return nil
		}
		if err := h.execEnd(ctx, tx, schema, info, plan, p, ts, ts1, tsPrev); err != nil {
			return err
		}
		h.ended.Add(1)

	default:
		h.noops.Add(1)
		return nil
	}
	return tx.Commit(ctx)
}

// resolveTargetID: prod used msg value (id_po) or a subselect by
// id_order. Same tx here (equivalent, injection-safe).
func (h *Handler) resolveTargetID(ctx context.Context, tx pgx.Tx, schema string, eq int, p paramPayload) (int64, error) {
	if id, err := p.Value.Int64(); err == nil && id > 0 {
		return id, nil
	}
	idOrder, err := p.IDOrder.Int64()
	if err != nil {
		return 0, nil // neither id_po nor id_order — lifecycle no-op
	}
	var id int64
	err = tx.QueryRow(ctx, fmt.Sprintf(
		`SELECT id_production_order FROM %s.production_orders WHERE id_equipment=$1 AND id_order=$2`,
		schema), eq, idOrder).Scan(&id)
	if err == pgx.ErrNoRows {
		return 0, nil
	}
	return id, err
}

func (h *Handler) runningPO(ctx context.Context, tx pgx.Tx, schema string, eq int) (*RunningPO, error) {
	var r RunningPO
	err := tx.QueryRow(ctx, fmt.Sprintf(`
		SELECT po.id_production_order, lower(por.runtime_timerange)
		  FROM %s.production_orders_runtime por
		  JOIN %s.production_orders po USING (id_production_order)
		 WHERE po.id_equipment = $1 AND po.status = 2
		 ORDER BY lower(por.runtime_timerange) DESC LIMIT 1`, schema, schema), eq).
		Scan(&r.ID, &r.TsLower)
	if err == pgx.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("running-po state: %w", err)
	}
	return &r, nil
}

// sqlCloseOpenSegmentOnEquipment is the CLOSE-FIRST recurrence guard
// (task #34, zombie-segment fix). Before a PO-start opens a new segment,
// it bounds the upper of every still-OPEN runtime segment on THIS
// equipment to $1 (the new start ts). This self-heals a prior finish
// that left an unbounded "zombie" segment — the next start always cleans
// it — so the "one open segment per equipment" invariant holds.
//
// Scoping (do NOT widen): keyed strictly on id_equipment, never
// id_production_order. A PO legitimately runs open on other equipments
// concurrently (#37 concurrent-split), so closing by PO would corrupt
// those siblings. Same-equipment only.
//
// The `lower(runtime_timerange) < $1` guard mirrors the shadow-mirror
// path (sqlCloseWindowsForEquipment): it skips the pathological
// lower>=ts case that would otherwise invert tstzrange(lower, ts) and
// abort the entire start tx (the old inverted-range poison). After this
// statement the equipment has zero open segments, so the INSERT that
// follows can never overlap — the upcoming EXCLUDE (id_equipment
// WITH =, runtime_timerange WITH &&) can never fire on a normal start
// (the closed prior [old_lower, ts) is adjacent to, not overlapping,
// the new [ts, ∞)).
const sqlCloseOpenSegmentOnEquipment = `UPDATE %s.production_orders_runtime
	     SET runtime_timerange = tstzrange(lower(runtime_timerange), $1), recalc_needed = true
	   WHERE id_equipment = $2 AND upper(runtime_timerange) IS NULL
	     AND lower(runtime_timerange) < $1`

// execStart = the captured 6-statement start block, order preserved.
func (h *Handler) execStart(ctx context.Context, tx pgx.Tx, schema string, info *sparkplug.EquipmentInfo, targetID int64, plan StartPlan, p paramPayload, ts, ts1 time.Time) error {
	stmts := []struct {
		sql  string
		args []any
	}{
		{fmt.Sprintf(sqlCloseOpenSegmentOnEquipment, schema),
			[]any{ts, info.IDEquipment}},
		{fmt.Sprintf(`INSERT INTO %s.production_orders_runtime
		     (id_production_order, runtime_timerange, recalc_needed, id_equipment)
		   VALUES ($1, tstzrange($2, NULL, '[)'), true, $3)`, schema),
			[]any{targetID, ts, info.IDEquipment}},
		{fmt.Sprintf(`UPDATE %s.production_orders SET status = $1, ts_end = $2
		   WHERE id_equipment = $3 AND status = 2`, schema),
			[]any{plan.PrevStatus, ts1, info.IDEquipment}},
	}
	for _, s := range stmts {
		if _, err := tx.Exec(ctx, s.sql, s.args...); err != nil {
			return fmt.Errorf("start stmt: %w", err)
		}
	}
	// Statement 4: target PO → TempStatus (+ note, ts_start; ts_end on juggle).
	set := `status = $1, ts_start = $2`
	args := []any{plan.TempStatus, ts, targetID}
	n := 3
	if p.Note != "" {
		n++
		set += fmt.Sprintf(`, txt_production_order_notes = $%d`, n)
		args = append(args, p.Note)
	}
	if plan.Juggle {
		n++
		set += fmt.Sprintf(`, ts_end = $%d`, n)
		args = append(args, ts1)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(
		`UPDATE %s.production_orders SET `+set+` WHERE id_production_order = $3`, schema),
		args...); err != nil {
		return fmt.Errorf("start stmt 4: %w", err)
	}
	return h.evMarkerAndRestamp(ctx, tx, schema, info, targetID, ts, ts)
}

// execEnd = the captured end block: close runtime range, PO status,
// EV marker at ts-1s, re-stamp after ts+1s.
func (h *Handler) execEnd(ctx context.Context, tx pgx.Tx, schema string, info *sparkplug.EquipmentInfo, plan EndPlan, p paramPayload, ts, ts1, tsPrev time.Time) error {
	if _, err := tx.Exec(ctx, fmt.Sprintf(`UPDATE %s.production_orders_runtime
	     SET runtime_timerange = tstzrange($1, $2), recalc_needed = true
	   WHERE id_production_order = $3 AND upper(runtime_timerange) IS NULL`, schema),
		plan.TsLower, ts, plan.ID); err != nil {
		return fmt.Errorf("end stmt 1: %w", err)
	}
	set := `status = $1, ts_end = $2`
	args := []any{plan.NewStatus, ts1, plan.ID}
	n := 3
	if pf, err := p.ProdFinal.Float64(); err == nil && string(p.ProdFinal) != "" {
		n++
		set += fmt.Sprintf(`, production_final = $%d`, n)
		args = append(args, pf)
	}
	if p.Note != "" {
		n++
		set += fmt.Sprintf(`, txt_production_order_notes = $%d`, n)
		args = append(args, p.Note)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(
		`UPDATE %s.production_orders SET `+set+` WHERE id_production_order = $3`, schema),
		args...); err != nil {
		return fmt.Errorf("end stmt 2: %w", err)
	}
	return h.evMarkerAndRestamp(ctx, tx, schema, info, plan.ID, tsPrev, ts1)
}

// evMarkerAndRestamp = the shared tail of both blocks: the EV PO-marker
// upsert (tp_equipment=3) + the forward re-stamp.
func (h *Handler) evMarkerAndRestamp(ctx context.Context, tx pgx.Tx, schema string, info *sparkplug.EquipmentInfo, poID int64, markerTs, restampAfter time.Time) error {
	if _, err := tx.Exec(ctx, fmt.Sprintf(`INSERT INTO %s.equipment_values
	     (ts_value, id_enterprise, id_site, id_area, id_equipment,
	      id_production_order, id_production_order_quality, tp_equipment)
	   VALUES ($1, $2, $3, $4, $5, $6, $7, 3)
	   ON CONFLICT (ts_value, id_equipment) DO UPDATE SET
	      id_production_order = EXCLUDED.id_production_order,
	      id_production_order_quality = EXCLUDED.id_production_order_quality,
	      tp_equipment = 3`, schema),
		markerTs, info.IDEnterprise, info.IDSite, info.IDArea, info.IDEquipment,
		poID, info.SignalQuality); err != nil {
		return fmt.Errorf("ev marker: %w", err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(`UPDATE %s.equipment_values
	     SET id_production_order = $1
	   WHERE id_equipment = $2 AND ts_value > $3 AND id_production_order IS NOT NULL`, schema),
		poID, info.IDEquipment, restampAfter); err != nil {
		return fmt.Errorf("ev restamp: %w", err)
	}
	return nil
}

// Stats for /health expansion.
type Stats struct {
	Started  uint64 `json:"po_control_started"`
	Topology uint64 `json:"po_control_topology"`
	Created  uint64 `json:"po_control_created"`
	Events   uint64 `json:"po_control_events"`
	Ended    uint64 `json:"po_control_ended"`
	NoOps    uint64 `json:"po_control_noops"`
	Dropped  uint64 `json:"po_control_dropped"`
}

func (h *Handler) Stats() Stats {
	return Stats{h.started.Load(), h.topology.Load(), h.created.Load(), h.events.Load(), h.ended.Load(), h.noops.Load(), h.dropped.Load()}
}

// resolveOrNoop is the shared preamble of every executor: resolve the
// topic; unregistered → count a noop and signal skip.
func (h *Handler) resolveOrNoop(ctx context.Context, m *sparkplug.Metric) (*sparkplug.EquipmentInfo, bool, error) {
	info, err := h.resolver.Resolve(ctx, m.TopicForRegister())
	if err != nil {
		return nil, false, fmt.Errorf("resolve: %w", err)
	}
	if info == nil {
		h.noops.Add(1)
		return nil, false, nil
	}
	return info, true, nil
}

func derefID(id *int) int {
	if id == nil {
		return 0
	}
	return *id
}

// txExecer is the minimal exec surface writeUserLog needs (pgx.Tx).
type txExecer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}
