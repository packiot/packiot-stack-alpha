package replicate

// BASE (PLC) downtime-event reconciler — legacy equipment_events (the PLC's own
// run/stop transitions, forced_creation_system=false) → analytics
// silver.equipment_events, for the mirrored enterprise.
//
// WHY (S2_stale_open_stops, 2026-10-09): until then the twin received base events
// ONLY through the user_logs replay — DowntimeEventCreated, fed by the
// `downtime-event-created` audit row legacy edge-api writes when the factory edge
// POSTs /api/downtimes. On 2026-10-07 ~14:17 UTC the CPACK edge switched to
// publishing its events on Pub/Sub (topic cpack_sc_events), consumed by the legacy
// oeecloud, which writes equipment_events DIRECTLY — no audit row. The last
// `downtime-event-created` row is 2026-10-07 14:13:13, and from then on the twin
// (ent 3) and the sandbox (2000003) got almost no base events: every machine's
// last event froze, and a STOP that was the last event stayed open forever (the
// closer ends a stop only at its successor). Legacy had every successor.
// The audit trail is the wrong source for PLC events — they are not operator
// actions. This pass reads the event table itself, like the PO and manual-event
// reconcilers already do for their tables.
//
// WHAT IT DOES, each tick, window ts_event >= now - lookback:
//  1. fetch legacy fcs=false rows for the resolver's legacy equipment (SELECT-only;
//     id_equipment = ANY + ts_event range = the legacy (id_equipment, ts_event) key);
//  2. map through the resolver (the same legacy→twin equipment map the replay uses),
//     drop unresolved/NULL-status rows;
//  3. INSERT the ones the twin lacks — ON CONFLICT (id_equipment, ts_event) DO NOTHING,
//     AND skip when the twin already has an event within ±1 s: the user_logs payload
//     carries milliseconds, legacy stores whole seconds (10-06: 132 of 1,418 twin
//     rows had a fractional second), so the same transition must not land twice;
//  4. refresh serving.downtime_events_resolved for every UTC day it inserted into.
//
// It only INSERTs (never updates or deletes): ts_end/duration are derived on the
// twin by the stream-engine closer from the successor (the same contract as the
// replay), and classification/splits keep flowing through their user_logs handlers.
// forced_creation_system=true legacy rows (split segments, operator edits) are NOT
// copied — event-splitted owns them.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// BaseReconcileMetrics is the counter surface. *metrics.Metrics satisfies it.
type BaseReconcileMetrics interface {
	AddBaseEvents(action string, n int)
}

type noopBaseMetrics struct{}

func (noopBaseMetrics) AddBaseEvents(string, int) {}

// legacyBase is one legacy PLC event row.
type legacyBase struct {
	LegacyEquip int
	TsEvent     time.Time
	Status      *int
}

// baseInsert is one planned twin row.
type baseInsert struct {
	IDEquipment int
	TsEvent     time.Time
	Status      int
	ID          int64
}

// planBase maps legacy rows onto the twin. Pure (unit-tested): rows whose
// equipment does not resolve, or that carry no status, are counted and dropped.
func planBase(rows []legacyBase, resolve func(int) (StagingEquip, bool)) (out []baseInsert, unresolved, nostatus int) {
	seen := map[baseKey]bool{}
	for _, r := range rows {
		eq, ok := resolve(r.LegacyEquip)
		if !ok {
			unresolved++
			continue
		}
		if r.Status == nil {
			nostatus++
			continue
		}
		ts := r.TsEvent.UTC()
		k := baseKey{eq.IDEquipment, ts.UnixMicro()}
		if seen[k] { // two legacy equipment resolving to one twin machine
			continue
		}
		seen[k] = true
		out = append(out, baseInsert{IDEquipment: eq.IDEquipment, TsEvent: ts, Status: *r.Status, ID: genEventID(ts, eq.IDEquipment)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IDEquipment != out[j].IDEquipment {
			return out[i].IDEquipment < out[j].IDEquipment
		}
		return out[i].TsEvent.Before(out[j].TsEvent)
	})
	return out, unresolved, nostatus
}

type baseKey struct {
	eq int
	ts int64
}

// baseColumns splits the plan into the parallel arrays the unnest INSERT takes.
func baseColumns(p []baseInsert) (eqs []int32, ts []time.Time, st []int32, ids []int64) {
	for _, b := range p {
		eqs = append(eqs, int32(b.IDEquipment))
		ts = append(ts, b.TsEvent)
		st = append(st, int32(b.Status))
		ids = append(ids, b.ID)
	}
	return
}

// sqlBaseLegacyFetch — SELECT-only on legacy, on its (id_equipment, ts_event) key.
const sqlBaseLegacyFetch = `SELECT id_equipment, ts_event, status
	  FROM equipment_events
	 WHERE id_equipment = ANY($1) AND ts_event >= $2 AND id_enterprise = $3
	   AND forced_creation_system IS NOT TRUE`

// sqlBaseInsert inserts the planned rows the twin lacks. Same row shape as the
// replay's sqlInsertEquipmentEvent (forced_creation_system=false: the PLC's own
// event) and the same ±1 s duplicate guard. RETURNING feeds the serving refresh.
const sqlBaseInsert = `INSERT INTO silver.equipment_events (
		id_equipment, ts_event, status, id_equipment_event, id_enterprise,
		forced_creation_system, last_update)
	SELECT u.eq, u.ts, u.st, u.id, $5, false, now()
	  FROM unnest($1::int[], $2::timestamptz[], $3::int[], $4::bigint[]) AS u(eq, ts, st, id)
	 WHERE ` + baseNoNeighbour + `
	ON CONFLICT (id_equipment, ts_event) DO NOTHING
	RETURNING ts_event`

// baseNoNeighbour (over u.eq / u.ts) — no twin event of this machine within ±1 s.
const baseNoNeighbour = `NOT EXISTS (SELECT 1 FROM silver.equipment_events x
	                    WHERE x.id_equipment = u.eq
	                      AND x.ts_event > u.ts - interval '1 second'
	                      AND x.ts_event < u.ts + interval '1 second')`

// BaseReconciler runs the pass on a ticker.
type BaseReconciler struct {
	legacy *pgxpool.Pool
	dest   *pgxpool.Pool
	r      *Resolver
	cfg    *Config
	m      BaseReconcileMetrics
	logger *slog.Logger
}

func NewBaseReconciler(legacy, dest *pgxpool.Pool, r *Resolver, cfg *Config, m BaseReconcileMetrics, logger *slog.Logger) *BaseReconciler {
	if m == nil {
		m = noopBaseMetrics{}
	}
	return &BaseReconciler{legacy: legacy, dest: dest, r: r, cfg: cfg, m: m, logger: logger}
}

// RunForever runs one pass at startup then every interval; a failed pass is
// logged and retried next tick.
func (br *BaseReconciler) RunForever(ctx context.Context) error {
	if !br.cfg.ReconcileBaseEventsEnabled || !br.cfg.ReplicateBaseEvents {
		br.logger.Info("base-event reconciler disabled (RECONCILE_BASE_EVENTS_ENABLED / REPLICATE_BASE_EVENTS)")
		<-ctx.Done()
		return ctx.Err()
	}
	br.logger.Info("base-event reconciler started",
		slog.Int("interval_sec", br.cfg.ReconcileBaseEventsIntervalSec),
		slog.Int("lookback_hours", br.cfg.ReconcileBaseEventsLookbackHours),
		slog.Int("src_enterprise", br.cfg.SrcEnterprise),
		slog.Int("dst_enterprise", br.cfg.DstEnterprise))
	br.runOnce(ctx)
	t := time.NewTicker(time.Duration(br.cfg.ReconcileBaseEventsIntervalSec) * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			br.runOnce(ctx)
		}
	}
}

func (br *BaseReconciler) runOnce(ctx context.Context) {
	if br.cfg.Hold.Held(ctx) {
		return // sandbox session/heal — the heal reflects the source's current events
	}
	since := time.Now().Add(-time.Duration(br.cfg.ReconcileBaseEventsLookbackHours) * time.Hour)
	if err := br.pass(ctx, since); err != nil {
		br.logger.Warn("base-event reconcile pass failed", slog.String("err", err.Error()))
	}
}

func (br *BaseReconciler) pass(ctx context.Context, since time.Time) error {
	ids := br.r.LegacyIDs()
	if len(ids) == 0 {
		return nil
	}
	raw, err := fetchLegacyBase(ctx, br.legacy, ids, since, br.cfg.SrcEnterprise)
	if err != nil {
		return fmt.Errorf("legacy fetch: %w", err)
	}
	plan, unresolved, nostatus := planBase(raw, br.r.ResolveEquipment)
	inserted := 0
	days := map[time.Time]bool{}
	if len(plan) > 0 {
		eqs, ts, st, evIDs := baseColumns(plan)
		rows, err := br.dest.Query(ctx, sqlBaseInsert, eqs, ts, st, evIDs, br.cfg.DstEnterprise)
		if err != nil {
			return fmt.Errorf("insert: %w", err)
		}
		for rows.Next() {
			var t time.Time
			if err := rows.Scan(&t); err != nil {
				rows.Close()
				return fmt.Errorf("insert scan: %w", err)
			}
			inserted++
			days[t.UTC().Truncate(24*time.Hour)] = true
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return fmt.Errorf("insert: %w", err)
		}
	}
	br.m.AddBaseEvents("insert", inserted)
	br.m.AddBaseEvents("unresolved", unresolved)

	refreshed := 0
	if br.cfg.ReconcileBaseEventsRefreshServing && inserted > 0 {
		sorted := make([]time.Time, 0, len(days))
		for d := range days {
			sorted = append(sorted, d)
		}
		sort.Slice(sorted, func(i, j int) bool { return sorted[i].Before(sorted[j]) })
		for _, rg := range dayRanges(sorted) {
			if _, err := br.dest.Exec(ctx, sqlManualRefreshServing, rg[0], rg[1]); err != nil {
				var pgErr *pgconn.PgError
				if errors.As(err, &pgErr) && (pgErr.Code == "42883" || pgErr.Code == "3F000") {
					br.logger.Warn("base-event reconcile: serving refresh function missing — skipped")
					break
				}
				br.logger.Warn("base-event reconcile: serving refresh failed",
					slog.Time("from", rg[0]), slog.Time("to", rg[1]), slog.String("err", err.Error()))
				continue
			}
			refreshed++
		}
	}
	if inserted > 0 || unresolved > 0 {
		br.logger.Info("base-event reconcile pass done",
			slog.Time("since", since),
			slog.Int("legacy_rows", len(raw)),
			slog.Int("planned", len(plan)),
			slog.Int("inserted", inserted),
			slog.Int("unresolved", unresolved),
			slog.Int("no_status", nostatus),
			slog.Int("serving_ranges_refreshed", refreshed))
	}
	return nil
}

func fetchLegacyBase(ctx context.Context, legacy *pgxpool.Pool, ids []int, since time.Time, srcEnt int) ([]legacyBase, error) {
	ids32 := make([]int32, len(ids))
	for i, id := range ids {
		ids32[i] = int32(id)
	}
	rows, err := legacy.Query(ctx, sqlBaseLegacyFetch, ids32, since, srcEnt)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []legacyBase
	for rows.Next() {
		var r legacyBase
		if err := rows.Scan(&r.LegacyEquip, &r.TsEvent, &r.Status); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
