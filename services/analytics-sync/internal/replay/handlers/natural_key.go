package handlers

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Shadow-path production_orders rows carry locally generated surrogate
// ids (IDENTITY on packiot_analytics, shared sequence on shadow_go_port),
// so Flow 1's id_production_order can never match a shadow row (bug 248).
// Every lifecycle UPDATE must instead target the natural key
// (id_enterprise, id_order), resolved from the Flow 1 source-of-truth
// row that edge-api wrote just before emitting this user_logs entry.

type poKey struct {
	IDEnterprise int
	IDOrder      int64
}

// resolvePOKey maps a Flow 1 id_production_order to its natural key by
// reading packiot.public.production_orders via the main pool. found=false
// means the Flow 1 row is gone (pre-cursor history) — callers skip.
func resolvePOKey(ctx context.Context, mainPool *pgxpool.Pool, idProductionOrder int64) (poKey, bool, error) {
	var k poKey
	err := mainPool.QueryRow(ctx,
		`SELECT id_enterprise, id_order FROM public.production_orders WHERE id_production_order = $1`,
		idProductionOrder).Scan(&k.IDEnterprise, &k.IDOrder)
	if errors.Is(err, pgx.ErrNoRows) {
		return k, false, nil
	}
	if err != nil {
		return k, false, err
	}
	return k, true, nil
}

// resolveEventID maps a Flow 1 equipment_events_man row to its
// id_equipment_event by exact ts_event lookup — ts_event is the table's
// PRIMARY KEY on packiot.public (prod shape), so this is a unique match,
// not a heuristic. Shadow inserts preserve this id so that
// manual-event-edited's UPDATE-by-id works on the shadow paths (events
// have no immutable natural key: ts_event itself is editable).
func resolveEventID(ctx context.Context, mainPool *pgxpool.Pool, tsEvent time.Time) (int64, bool, error) {
	var id int64
	err := mainPool.QueryRow(ctx,
		`SELECT id_equipment_event FROM public.equipment_events_man WHERE ts_event = $1`,
		tsEvent).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return id, true, nil
}

// equipmentEventKey is the natural key of public.equipment_events — its
// PRIMARY KEY (id_equipment, ts_event). Unlike id_equipment_event (a
// per-flow surrogate: F1 and F2 assign the same PLC event ids from
// independent sequences and observably differ by one), (id_equipment,
// ts_event) is derived deterministically from the PLC stream and is
// therefore identical across F1/F2/F3. Operator classifications
// (event-justified / event-edited) must join on this key, never on the
// payload's id_equipment_event — that is the bug-248 id-space trap.
type equipmentEventKey struct {
	IDEquipment int
	TsEvent     time.Time
}

// resolveEquipmentEventKey maps a Flow 1 id_equipment_event (as carried
// in the event-justified/event-edited payload) to its natural key by
// reading packiot.public.equipment_events via the main pool. edge-api's
// DowntimesDAO treats id_equipment_event as unique (findByID returns
// row[0]); we mirror that with QueryRow (first row wins). found=false
// means the Flow 1 event is gone (pre-cursor history) — callers skip.
func resolveEquipmentEventKey(ctx context.Context, mainPool *pgxpool.Pool, idEquipmentEvent int64) (equipmentEventKey, bool, error) {
	var k equipmentEventKey
	err := mainPool.QueryRow(ctx,
		`SELECT id_equipment, ts_event FROM public.equipment_events WHERE id_equipment_event = $1`,
		idEquipmentEvent).Scan(&k.IDEquipment, &k.TsEvent)
	if errors.Is(err, pgx.ErrNoRows) {
		return k, false, nil
	}
	if err != nil {
		return k, false, err
	}
	return k, true, nil
}

// noopObserver reports UPDATEs that matched zero rows. Silent no-op
// writes are exactly the failure mode bugs 247/248 hid — wired to the
// shadow_mirror_update_noop_total counter in main.go.
var noopObserver = func(schema, table string) {}

// SetNoopObserver wires the zero-row-UPDATE callback (main.go → metrics).
func SetNoopObserver(fn func(schema, table string)) { noopObserver = fn }

// execExpectingRows runs an UPDATE and records a warn + metric when it
// affects zero rows. A zero-row UPDATE still advances the cursor (it is
// a replay gap, not a poison message) but must be observable.
func execExpectingRows(ctx context.Context, pool *pgxpool.Pool, schema, table string, userLogID int64, logger *slog.Logger, sql string, args ...any) error {
	ct, err := pool.Exec(ctx, sql, args...)
	if err != nil {
		return failOpenIfMissing(err, table, schema, userLogID, logger)
	}
	if ct.RowsAffected() == 0 {
		noopObserver(schema, table)
		logger.Warn("update matched no rows",
			slog.Int64("id_user_log", userLogID),
			slog.String("schema", schema),
			slog.String("table", table))
	}
	return nil
}
