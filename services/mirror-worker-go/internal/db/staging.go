package db

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/secrets"
)

type Staging struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewStaging(ctx context.Context, creds *secrets.DBCreds, logger *slog.Logger) (*Staging, error) {
	pc, err := pgxpool.ParseConfig(creds.URL("mirror-worker-go"))
	if err != nil {
		return nil, fmt.Errorf("parse staging url: %w", err)
	}
	pc.MaxConns = 5
	pc.MinConns = 1

	// pgbouncer in front of staging postgres runs in TRANSACTION pooling
	// mode — pgx's cached prepared statements break under that (SQLSTATE
	// 42P05). Same fix as oeecloud-worker.
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol

	p, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("create staging pool: %w", err)
	}
	if err := p.Ping(ctx); err != nil {
		p.Close()
		return nil, fmt.Errorf("staging ping: %w", err)
	}
	logger.Info("staging pool ready", slog.String("url", creds.Redacted("mirror-worker-go")))
	return &Staging{pool: p, logger: logger}, nil
}

func (s *Staging) Close() { s.pool.Close() }

// WithTx runs fn inside a staging transaction. Commits on nil error,
// rolls back on any error. Same shape as TS mirror-worker's withStagingTx.
func (s *Staging) WithTx(ctx context.Context, fn func(pgx.Tx) error) error {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}

// SelectOne is for ad-hoc reads outside a transaction.
func (s *Staging) SelectOne(ctx context.Context, sql string, args []any, dest ...any) (bool, error) {
	err := s.pool.QueryRow(ctx, sql, args...).Scan(dest...)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// ──── Cursor + mapping helpers ─────────────────────────────────────────

// FetchAPIToken reads enterprises.api_key for the staging mirror enterprise.
// Called once at startup; rotation requires a worker restart.
func (s *Staging) FetchAPIToken(ctx context.Context, enterpriseID int) (string, error) {
	var token string
	found, err := s.SelectOne(ctx,
		`SELECT api_key FROM enterprises WHERE id_enterprise = $1`,
		[]any{enterpriseID}, &token)
	if err != nil {
		return "", err
	}
	if !found || token == "" {
		return "", fmt.Errorf("enterprises.api_key missing for id_enterprise=%d on staging — seed it first", enterpriseID)
	}
	return token, nil
}

func (s *Staging) ReadCursor(ctx context.Context, source string) (int64, error) {
	var cursor int64
	found, err := s.SelectOne(ctx,
		`SELECT last_log_id FROM mirror_replay_cursor WHERE source = $1`,
		[]any{source}, &cursor)
	if err != nil {
		return 0, err
	}
	if !found {
		return 0, fmt.Errorf("cursor row for source %q missing — seed it before starting", source)
	}
	return cursor, nil
}

// AdvanceCursor moves the cursor forward — uses < so out-of-order calls
// can't move it backward. Runs inside the per-row transaction passed by
// the caller (tx, not pool — atomic with mapping inserts / DLQ writes).
func AdvanceCursor(ctx context.Context, tx pgx.Tx, source string, toID int64) error {
	_, err := tx.Exec(ctx,
		`UPDATE mirror_replay_cursor
		    SET last_log_id = $1, last_run_at = now()
		  WHERE source = $2
		    AND last_log_id < $1`,
		toID, source)
	return err
}

type MapInsert struct {
	EntityType  string
	Source      string
	ProdID      int64
	StagingID   int64
	SourceLogID int64
}

// InsertMapping is idempotent via ON CONFLICT DO NOTHING. Runs in caller's tx.
func InsertMapping(ctx context.Context, tx pgx.Tx, m MapInsert) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO mirror_id_map
		       (entity_type, source, prod_id, staging_id, source_log_id)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (entity_type, source, prod_id) DO NOTHING`,
		m.EntityType, m.Source, m.ProdID, m.StagingID, m.SourceLogID)
	return err
}

func (s *Staging) LookupMapping(ctx context.Context, entityType, source string, prodID int64) (int64, bool, error) {
	var stagingID int64
	found, err := s.SelectOne(ctx,
		`SELECT staging_id FROM mirror_id_map
		  WHERE entity_type = $1 AND source = $2 AND prod_id = $3`,
		[]any{entityType, source, prodID}, &stagingID)
	return stagingID, found, err
}

func (s *Staging) IsAlreadyReplayed(ctx context.Context, source string, sourceLogID int64) (bool, error) {
	var exists bool
	_, err := s.SelectOne(ctx,
		`SELECT EXISTS(
		   SELECT 1 FROM mirror_id_map
		    WHERE source = $1 AND source_log_id = $2
		 )`,
		[]any{source, sourceLogID}, &exists)
	return exists, err
}

// CountIDMap returns the row count of mirror_id_map for this source.
// Powers the id_map_cache_size gauge — a growth signal + sanity check
// that the worker is actually producing mappings.
//
// COUNT(*) is O(n); today the table has ~2k rows for cpack-prod-go,
// well under 1ms. If it grows to 100k+, switch to pg_class.reltuples
// for an approximate count.
func (s *Staging) CountIDMap(ctx context.Context, source string) (int64, error) {
	var n int64
	_, err := s.SelectOne(ctx,
		`SELECT COUNT(*) FROM mirror_id_map WHERE source = $1`,
		[]any{source}, &n)
	return n, err
}

// ActivePOIDOrders returns the set of id_order values for staging POs
// currently in status=2 (running). Used by the reconciler to diff against
// prod's active set without pulling every column.
//
// Returning a map[int64]int64 (id_order → id_production_order) instead
// of a set so the caller can also check whether a finished mirror of the
// same id_order exists at a different staging PO id — useful for future
// log lines but not strictly needed by the diff itself.
func (s *Staging) ActivePOIDOrders(ctx context.Context, enterpriseID int) (map[int64]int64, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id_order, id_production_order
		   FROM production_orders
		  WHERE id_enterprise = $1 AND status = 2`,
		enterpriseID,
	)
	if err != nil {
		return nil, fmt.Errorf("query active staging POs: %w", err)
	}
	defer rows.Close()
	out := make(map[int64]int64)
	for rows.Next() {
		var idOrder, idPO int64
		if err := rows.Scan(&idOrder, &idPO); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out[idOrder] = idPO
	}
	return out, rows.Err()
}

// LookupStagingPOByIDOrder returns the most recent staging PO matching
// (enterprise, id_order). Called by the reconciler after POSTing
// /api/production-orders/create to capture the new id_production_order
// the way the order-created handler does.
func (s *Staging) LookupStagingPOByIDOrder(ctx context.Context, enterpriseID int, idOrder int64) (int64, bool, error) {
	var stagingPOID int64
	found, err := s.SelectOne(ctx,
		`SELECT id_production_order FROM production_orders
		  WHERE id_enterprise = $1 AND id_order = $2
		  ORDER BY id_production_order DESC LIMIT 1`,
		[]any{enterpriseID, idOrder}, &stagingPOID)
	return stagingPOID, found, err
}

// MappedActivePO is a per-PO view the value-sync uses: the mapping +
// the staging PO's current equipment + the latest staging runtime
// counters. One SELECT-with-JOIN replaces N round-trips while the
// reconciler walks mirror_id_map.
type MappedActivePO struct {
	ProdPOID                 int64
	StagingPOID              int64
	StagingEquipment         int
	StagingSite              int
	StagingArea              int
	StagingNetProduction     *float64
	StagingGrossProduction   *float64
}

// FetchMappedActiveCPACKPOs returns every mirror_id_map row for active
// staging CPACK POs joined with their equipment + current runtime
// counters. Used by the value-sync to compute deltas vs prod.
//
// Filters by source so a future second mirror source (e.g., azpack-prod)
// won't accidentally accumulate inserts here.
func (s *Staging) FetchMappedActiveCPACKPOs(ctx context.Context, source string, enterpriseID int) ([]MappedActivePO, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT m.prod_id, m.staging_id,
		        po.id_equipment, po.id_site, po.id_area,
		        por.net_production, por.gross_production
		   FROM mirror_id_map m
		   JOIN production_orders po
		     ON po.id_production_order = m.staging_id
		   LEFT JOIN production_orders_runtime por
		     ON por.id_production_order = m.staging_id
		  WHERE m.entity_type = 'production_order'
		    AND m.source = $1
		    AND po.id_enterprise = $2
		    AND po.status = 2`,
		source, enterpriseID,
	)
	if err != nil {
		return nil, fmt.Errorf("query mapped active POs: %w", err)
	}
	defer rows.Close()
	var out []MappedActivePO
	for rows.Next() {
		var r MappedActivePO
		if err := rows.Scan(&r.ProdPOID, &r.StagingPOID,
			&r.StagingEquipment, &r.StagingSite, &r.StagingArea,
			&r.StagingNetProduction, &r.StagingGrossProduction); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// InsertEquipmentValueDelta writes one synthetic equipment_values row
// carrying a net/gross production increment. The per-minute pg_cron
// (piot_proc_refresh_runtime) sums equipment_values per equipment +
// active-PO window into production_orders_runtime, so this row makes the
// cron compute prod-anchored values WITHOUT us racing it.
//
// Single writer per CPACK equipment is guaranteed by the simulator's
// SIM_SKIP_ENTERPRISE_IDS=3 default (added in the same change set).
// If the simulator skip is misconfigured the cron will sum both sources
// and counters will run hot — log + a follow-up alarm should flag that.
//
// id_shift gets populated by the piot_set_shift_before_insert trigger.
// Other operational columns (state, mode, speed, id_order, id_production_
// order) intentionally left NULL — this row is a counter delta, not a
// PLC snapshot.
func (s *Staging) InsertEquipmentValueDelta(
	ctx context.Context,
	stagingEqID, stagingSiteID, stagingAreaID, enterpriseID int,
	netDelta, grossDelta float64,
) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO equipment_values
		       (id_equipment, ts_value, id_enterprise, id_site, id_area,
		        net_production_incr, gross_production_incr)
		 VALUES ($1, now(), $2, $3, $4, $5, $6)`,
		stagingEqID, enterpriseID, stagingSiteID, stagingAreaID, netDelta, grossDelta,
	)
	return err
}

// WriteDLQ appends an unreplayable row for human inspection. Runs in
// caller's tx so we don't lose visibility into a bad row that crashed
// before the outer commit.
func WriteDLQ(ctx context.Context, tx pgx.Tx,
	source string, sourceLogID int64, category string, subcategory *string,
	payload []byte, errMsg string,
) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO mirror_replay_dlq
		       (source, source_log_id, category, subcategory, payload, error)
		 VALUES ($1, $2, $3, $4, $5::jsonb, $6)`,
		source, sourceLogID, category, subcategory, string(payload), errMsg)
	return err
}
