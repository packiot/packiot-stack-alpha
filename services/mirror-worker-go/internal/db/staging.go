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
