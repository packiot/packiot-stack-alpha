package handlers

import (
	"context"
	"errors"
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Shadow-path production_orders rows carry locally generated surrogate
// ids (IDENTITY on packiot_shadow, shared sequence on shadow_go_port),
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
