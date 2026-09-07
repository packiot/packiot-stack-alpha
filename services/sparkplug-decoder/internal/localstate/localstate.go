// Package localstate is the on-prem "current-state" sink for the fat-edge
// deployment (ADR-0053 B-minimal). When a client runs the decode stack on
// their own box for internet-outage tolerance, the edge-transformer tees each
// resolved metric here — a tiny SQLite table holding ONLY the latest value per
// (tenant, id_equipment, metric) — so a local dashboard can render live counts
// and machine state while the cloud uplink is down.
//
// This is deliberately NOT the outbox. The outbox (internal/outbox) is a
// store-and-FORWARD queue: it holds serialized messages awaiting an AMQP
// publish and DELETES them once drained, so it can never answer "what is the
// current count on machine X?". localstate is the opposite shape — an UPSERT
// keyed on the identity of the reading, so it always holds exactly one row per
// metric: the newest. Together they cover the two halves of outage tolerance:
// outbox = data durability (nothing lost), localstate = live visibility (the
// floor can still see the line).
//
// Design constraints that mirror the outbox package:
//   - modernc.org/sqlite (pure Go, no cgo) so the CGO_ENABLED=0 static build
//     in the distroless image is preserved.
//   - WAL mode so the separate dashboard process can read concurrently with
//     the transformer's writes without blocking.
//   - Schema created idempotently on Open; safe to re-open.
//   - Every write is a single UPSERT — crash-consistent, no partial rows.
package localstate

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite" // pure-Go SQLite driver registration
)

// Sample is one resolved metric reading to record. It is intentionally a plain
// value type with no dependency on analyticspub/sparkplug: the caller (the
// transformer's publish hook) flattens its richer Envelope into these, which
// keeps this package trivially unit-testable and decoupled from the wire shape.
type Sample struct {
	// Source is the SparkPlug publisher identity this metric arrived under
	// (e.g. "GROUP/EDGE/DEVICE") — the machine's stable topic identity. On the
	// box the decoder does NOT resolve name→id_equipment (that happens in the
	// cloud worker via packml_register), so Source + Metric is the only
	// equipment-distinguishing key available at decode time. The dashboard maps
	// Source → a friendly machine name via the on-box descriptor.
	Source string
	// Metric is the resolved SparkPlug metric name (e.g. "ProdProcessedCount").
	Metric string
	// Value is the metric's value rendered as text (the wire value is `any`;
	// the dashboard only displays it, so a string keeps the schema simple).
	Value string
	// Counter / CurSpeed are the normalized counter + speed the transformer
	// already computed, when present — handy for the dashboard to show a rate
	// without re-deriving it. nil when the metric carries neither.
	Counter  *float64
	CurSpeed *float64
	// TsMillis is the reading's source timestamp (epoch ms).
	TsMillis int64
}

// Row is one current-state record as read back for the dashboard.
type Row struct {
	Tenant    string
	Source    string
	Metric    string
	Value     string
	Counter   *float64
	CurSpeed  *float64
	TsMillis  int64
	UpdatedAt int64 // epoch ms the row was last written
}

// Store is the current-state sink. Safe for concurrent use: the sql.DB pool +
// SQLite's own write serialization handle it, and every method is a single
// statement or short transaction.
type Store struct {
	db *sql.DB
}

// Open opens (creating if needed) the current-state DB at path and ensures the
// schema exists. WAL mode + a small connection pool match the outbox package's
// tuning: SQLite serializes writes anyway, so extra connections only add cache
// pressure, but WAL lets the dashboard reader proceed without blocking writes.
func Open(path string) (*Store, error) {
	if path == "" {
		return nil, errors.New("localstate: path is required")
	}
	dsn := path + "?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(ON)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("localstate: open %s: %w", path, err)
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	if err := createSchema(db); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

// Close releases the underlying connection. Safe to call more than once.
func (s *Store) Close() error { return s.db.Close() }

func createSchema(db *sql.DB) error {
	stmts := []string{
		// One row per (tenant, source, metric): the latest reading. The
		// composite PRIMARY KEY is what makes Record an UPSERT — a new report
		// for the same metric overwrites in place rather than appending, so the
		// table stays bounded by the descriptor's (machine × metric) count, not
		// by time. `source` is the SparkPlug publisher identity; the decoder has
		// no id_equipment on the box (resolved cloud-side), so the topic
		// identity is the equipment-distinguishing key.
		`CREATE TABLE IF NOT EXISTS current_state (
			tenant     TEXT    NOT NULL,
			source     TEXT    NOT NULL,
			metric     TEXT    NOT NULL,
			value      TEXT    NOT NULL,
			counter    REAL,
			curspeed   REAL,
			ts_millis  INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			PRIMARY KEY (tenant, source, metric)
		)`,
		// Dashboard reads "everything for this tenant, freshest first".
		`CREATE INDEX IF NOT EXISTS idx_current_state_tenant_updated
			ON current_state (tenant, updated_at DESC)`,
	}
	for _, stmt := range stmts {
		if _, err := db.Exec(stmt); err != nil {
			return fmt.Errorf("localstate: create schema: %w\nstmt: %s", err, stmt)
		}
	}
	return nil
}

// Record upserts a batch of samples for one tenant in a single transaction.
// A stale reading (older ts than what's already stored) is ignored so an
// out-of-order or replayed message can never roll the displayed count
// backwards — the dashboard must only ever move forward in time.
func (s *Store) Record(ctx context.Context, tenant string, samples []Sample) error {
	if tenant == "" {
		return errors.New("localstate: tenant is required")
	}
	if len(samples) == 0 {
		return nil
	}
	now := time.Now().UTC().UnixMilli()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("localstate: begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op after commit

	// ON CONFLICT ... WHERE excluded.ts_millis >= current: only overwrite when
	// the incoming reading is at least as new. DO UPDATE with a WHERE clause is
	// SQLite's "conditional upsert"; a rejected update leaves the fresher row.
	const stmt = `
		INSERT INTO current_state
			(tenant, source, metric, value, counter, curspeed, ts_millis, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (tenant, source, metric) DO UPDATE SET
			value      = excluded.value,
			counter    = excluded.counter,
			curspeed   = excluded.curspeed,
			ts_millis  = excluded.ts_millis,
			updated_at = excluded.updated_at
		WHERE excluded.ts_millis >= current_state.ts_millis`
	for _, s := range samples {
		if s.Metric == "" || s.Source == "" {
			continue // a metric with no name or no source can't be keyed
		}
		if _, err := tx.ExecContext(ctx, stmt,
			tenant, s.Source, s.Metric, s.Value, s.Counter, s.CurSpeed, s.TsMillis, now,
		); err != nil {
			return fmt.Errorf("localstate: upsert %s/%s/%s: %w", tenant, s.Source, s.Metric, err)
		}
	}
	return tx.Commit()
}

// Snapshot returns every current-state row for a tenant, freshest first. Used
// by the local dashboard process (opens the same DB read-only).
func (s *Store) Snapshot(ctx context.Context, tenant string) ([]Row, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT tenant, source, metric, value, counter, curspeed, ts_millis, updated_at
		   FROM current_state
		  WHERE tenant = ?
		  ORDER BY updated_at DESC`,
		tenant,
	)
	if err != nil {
		return nil, fmt.Errorf("localstate: snapshot: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []Row
	for rows.Next() {
		var r Row
		if err := rows.Scan(
			&r.Tenant, &r.Source, &r.Metric, &r.Value,
			&r.Counter, &r.CurSpeed, &r.TsMillis, &r.UpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("localstate: scan: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
