// Package outbox implements ADR-0011 P2 — the local disk-persistent queue
// between MQTT ingestion and downstream RabbitMQ publish.
//
// The store-and-forward pattern: when a Sparkplug message decodes cleanly,
// the caller writes it to the outbox FIRST (durable, on-disk), then a
// separate drain goroutine publishes to RabbitMQ with publisher confirms.
// On successful confirm, the outbox row is deleted. On failure, the row
// stays and gets retried by the drain loop with bounded exponential backoff.
//
// This makes the whole path crash-consistent from "MQTT message received"
// to "RabbitMQ persistent". Without the outbox, an edge-transformer crash
// between decode and confirm loses in-flight messages silently. With it,
// they survive on disk and drain when the service comes back up.
//
// Design decisions locked in (ADR-0011 P2 open questions resolved):
//
//   - SQLite via modernc.org/sqlite (pure Go, no cgo — matches
//     oeecloud-worker's zero-cgo discipline). WAL mode for reduced
//     writer contention + crash consistency.
//
//   - Schema is single-table, indexed on id (PRIMARY KEY AUTOINCREMENT
//     for FIFO order) and enqueued_at (for age-based diagnostics).
//     No relations, no joins — a queue, not a database.
//
//   - Bounded via software-side capacity check on Enqueue. Overflow
//     policy is FIFO drop-oldest — the newer message is more likely
//     representative of current state (Sparkplug NDATA supersedes; see
//     [[sparkplug-b-alias-table-state-machine]]).
//
//   - Not designed for high concurrency. A single writer + a single
//     drain goroutine is the intended shape. The mutex is a coarse
//     lock around all Store operations; if we ever need parallelism,
//     shard by tenant or use SQLite's connection pool with retries.
//
//   - No schema migration engine yet. The schema is created idempotently
//     on Open (`CREATE TABLE IF NOT EXISTS`). Any future column addition
//     should use `ALTER TABLE ... ADD COLUMN` guarded by a schema-version
//     check — but for now the schema is stable.
//
// Not yet wired into main.go — this is the package scaffold. A follow-up
// PR wires MQTT Handler → outbox.Enqueue and shadowpub.Publish ← outbox
// drain goroutine.
package outbox

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"time"

	_ "modernc.org/sqlite" // pure-Go SQLite driver registration
)

// Message is what callers enqueue + drainers dequeue. Fields are
// deliberately minimal — everything needed to reconstruct a shadow
// publish, nothing more.
type Message struct {
	// ID is the SQLite ROWID. Set by the Store on Enqueue; used by
	// Delete + MarkAttempt.
	ID int64

	// Tenant is the target tenant (lowercased GroupID from Sparkplug topic).
	// Written to a column for potential future per-tenant queries.
	Tenant string

	// Topic is the source MQTT topic (spBv1.0/...). Preserved for
	// diagnostics + reconciliation.
	Topic string

	// Payload is the raw decoded+normalized envelope body (JSON bytes)
	// ready to be published to RabbitMQ.
	Payload []byte

	// EnqueuedAt is when the message was written to the outbox.
	// Age-based diagnostics + drain-order tiebreaker.
	EnqueuedAt time.Time

	// Attempts is the number of failed drain attempts. Used by the drain
	// loop for exponential backoff scheduling.
	Attempts int
}

// Store is the outbox package's primary interface. Callers Enqueue
// messages after decode; drainers Peek + Delete after successful publish.
//
// All methods are safe to call from multiple goroutines but serialize
// internally (single mutex). The intended shape is one writer + one
// drainer; parallel access is correct but not optimal.
type Store struct {
	db  *sql.DB
	mu  sync.Mutex
	cap int
}

// Config controls Store construction.
type Config struct {
	// Path is the SQLite database file path. `:memory:` is valid for
	// tests but obviously not durable.
	Path string

	// Capacity is the maximum row count. When Enqueue would exceed
	// this, the oldest rows are deleted (FIFO drop-oldest). Set to 0
	// for unbounded (not recommended in production — disk-full risk).
	Capacity int
}

// DefaultCapacity is the recommended production capacity. At the CPACK
// staging rate of ~1 msg/s that's ~28 hours of buffer; at the worst-case
// factory peak of ~300 msg/s that's ~5.5 minutes. Sized to survive typical
// RabbitMQ outages + planned maintenance windows without dropping.
const DefaultCapacity = 100_000

// ErrOutboxEmpty is returned by Peek when the outbox has no messages
// ready for drain. Callers should treat this as "no work to do, sleep."
var ErrOutboxEmpty = errors.New("outbox: empty")

// Open constructs a Store backed by the SQLite database at cfg.Path.
// Creates the schema idempotently on first open. Enables WAL mode
// for concurrent reader durability.
func Open(cfg Config) (*Store, error) {
	if cfg.Path == "" {
		return nil, errors.New("outbox: Path is required")
	}
	if cfg.Capacity < 0 {
		return nil, errors.New("outbox: Capacity must be >= 0")
	}
	if cfg.Capacity == 0 {
		cfg.Capacity = DefaultCapacity
	}

	// _pragma parameters are honored by modernc.org/sqlite on connection.
	// journal_mode=WAL: reduce writer contention, enable crash consistency.
	// synchronous=NORMAL: fsync on WAL commit but not on every write —
	//   good tradeoff for a queue where losing the last few sub-millisecond
	//   messages is acceptable.
	// foreign_keys=ON: standard hygiene even though we have no FKs today.
	dsn := cfg.Path + "?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(ON)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("outbox: open %s: %w", cfg.Path, err)
	}
	// Set aggressively low connection limits — SQLite serializes writes
	// anyway; extra connections just create per-goroutine cache pressure.
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)

	if err := createSchema(db); err != nil {
		_ = db.Close()
		return nil, err
	}

	return &Store{db: db, cap: cfg.Capacity}, nil
}

// Close releases the underlying database connection. Safe to call
// multiple times; subsequent Store operations return ErrClosed-shaped
// errors from the sql package.
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.db.Close()
}

// createSchema idempotently ensures the outbox table exists. Called on
// Open; safe on re-open.
func createSchema(db *sql.DB) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS outbox (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			tenant TEXT NOT NULL,
			topic TEXT NOT NULL,
			payload BLOB NOT NULL,
			enqueued_at INTEGER NOT NULL,
			attempts INTEGER NOT NULL DEFAULT 0,
			next_attempt_at INTEGER NOT NULL DEFAULT 0
		)`,
		// Index for drain-ordered scan + age diagnostics
		`CREATE INDEX IF NOT EXISTS idx_outbox_next_attempt ON outbox (next_attempt_at, id)`,
	}
	for _, stmt := range stmts {
		if _, err := db.Exec(stmt); err != nil {
			return fmt.Errorf("outbox: create schema: %w\nstmt: %s", err, stmt)
		}
	}
	return nil
}

// Enqueue writes a message to the outbox. If Capacity would be exceeded,
// the oldest rows are deleted (FIFO drop-oldest) before insert.
//
// Returns the assigned ID (SQLite ROWID) on success.
//
// The write is atomic in a single transaction so callers can trust either
// the message is durably enqueued OR nothing changed.
func (s *Store) Enqueue(ctx context.Context, msg Message) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("outbox: begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // no-op if committed

	// FIFO drop-oldest overflow policy — check capacity BEFORE insert
	// so we never exceed. Not exactly-once but bounded above.
	if s.cap > 0 {
		if err := trimToCapacity(ctx, tx, s.cap-1); err != nil {
			return 0, err
		}
	}

	if msg.EnqueuedAt.IsZero() {
		msg.EnqueuedAt = time.Now().UTC()
	}

	res, err := tx.ExecContext(ctx,
		`INSERT INTO outbox (tenant, topic, payload, enqueued_at, attempts, next_attempt_at)
		 VALUES (?, ?, ?, ?, 0, 0)`,
		msg.Tenant, msg.Topic, msg.Payload, msg.EnqueuedAt.UnixNano(),
	)
	if err != nil {
		return 0, fmt.Errorf("outbox: insert: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("outbox: last insert id: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("outbox: commit: %w", err)
	}
	return id, nil
}

// trimToCapacity deletes the oldest rows until COUNT(*) <= maxRows.
// Runs inside a transaction so the caller can commit atomically with
// the subsequent Insert.
func trimToCapacity(ctx context.Context, tx *sql.Tx, maxRows int) error {
	var current int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM outbox`).Scan(&current); err != nil {
		return fmt.Errorf("outbox: count for trim: %w", err)
	}
	overflow := current - maxRows
	if overflow <= 0 {
		return nil
	}
	_, err := tx.ExecContext(ctx,
		`DELETE FROM outbox WHERE id IN (
			SELECT id FROM outbox ORDER BY id ASC LIMIT ?
		 )`, overflow)
	if err != nil {
		return fmt.Errorf("outbox: trim %d rows: %w", overflow, err)
	}
	return nil
}

// Peek returns up to N messages that are ready to drain (next_attempt_at
// has passed). Messages are returned in FIFO order (id ASC). Does NOT
// mutate the outbox — the drainer must call Delete or MarkAttempt after
// processing each message.
//
// Returns ErrOutboxEmpty when no messages match the criteria.
func (s *Store) Peek(ctx context.Context, batchSize int) ([]Message, error) {
	if batchSize <= 0 {
		batchSize = 1
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	nowNs := time.Now().UnixNano()
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, tenant, topic, payload, enqueued_at, attempts
		 FROM outbox
		 WHERE next_attempt_at <= ?
		 ORDER BY id ASC
		 LIMIT ?`,
		nowNs, batchSize,
	)
	if err != nil {
		return nil, fmt.Errorf("outbox: peek query: %w", err)
	}
	defer rows.Close()

	var out []Message
	for rows.Next() {
		var m Message
		var enqueuedNs int64
		if err := rows.Scan(&m.ID, &m.Tenant, &m.Topic, &m.Payload, &enqueuedNs, &m.Attempts); err != nil {
			return nil, fmt.Errorf("outbox: peek scan: %w", err)
		}
		m.EnqueuedAt = time.Unix(0, enqueuedNs).UTC()
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("outbox: peek rows: %w", err)
	}
	if len(out) == 0 {
		return nil, ErrOutboxEmpty
	}
	return out, nil
}

// Delete removes a message from the outbox — called by the drainer after
// successful RabbitMQ confirm.
func (s *Store) Delete(ctx context.Context, id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.ExecContext(ctx, `DELETE FROM outbox WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("outbox: delete %d: %w", id, err)
	}
	affected, _ := res.RowsAffected()
	if affected == 0 {
		return fmt.Errorf("outbox: delete %d: row not found", id)
	}
	return nil
}

// MarkAttempt records a failed drain attempt: increments the attempts
// counter and pushes next_attempt_at forward by the given backoff.
// Called by the drainer after a publish failure (nack / timeout /
// channel error) to schedule retry with exponential backoff.
func (s *Store) MarkAttempt(ctx context.Context, id int64, backoff time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	nextAt := time.Now().Add(backoff).UnixNano()
	_, err := s.db.ExecContext(ctx,
		`UPDATE outbox SET attempts = attempts + 1, next_attempt_at = ? WHERE id = ?`,
		nextAt, id,
	)
	if err != nil {
		return fmt.Errorf("outbox: mark attempt %d: %w", id, err)
	}
	return nil
}

// Depth returns the current row count of the outbox. Powers /health
// snapshots and the outbox depth gauge (ADR-0011 rule 4 degraded state).
func (s *Store) Depth(ctx context.Context) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM outbox`).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("outbox: depth: %w", err)
	}
	return n, nil
}

// OldestAge returns the age of the oldest un-drained message. Zero when
// the outbox is empty. Used for /health degraded state ("oldest message
// is Xs old — drain loop stuck?").
func (s *Store) OldestAge(ctx context.Context) (time.Duration, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var enqueuedNs sql.NullInt64
	err := s.db.QueryRowContext(ctx,
		`SELECT MIN(enqueued_at) FROM outbox`,
	).Scan(&enqueuedNs)
	if err != nil {
		return 0, fmt.Errorf("outbox: oldest age: %w", err)
	}
	if !enqueuedNs.Valid {
		return 0, nil // empty outbox
	}
	return time.Since(time.Unix(0, enqueuedNs.Int64)), nil
}
