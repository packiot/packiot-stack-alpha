package erpconnector

import (
	"context"
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite" // pure-Go SQLite driver registration (reference backend)
)

// Conn is a live connection to an ERP database, obtained from DBDriver.Open.
// It is intentionally narrow — Query for reads, Exec for writes, Ping for a
// liveness check, Close for shutdown. Everything the connector needs, nothing
// that would let a caller reach past the parameterized query surface.
//
// Args are passed straight through to the underlying database/sql call, so a
// caller supplies bound parameters (sql.Named for named placeholders) — never
// interpolated strings. This is the type-level guarantee behind "no injection
// surface": there is no method that takes a query and returns a query.
type Conn interface {
	Query(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	Exec(ctx context.Context, query string, args ...any) (sql.Result, error)
	Ping(ctx context.Context) error
	Close() error
}

// DBDriver abstracts one database backend. The connector logic (reads,
// writes, dedup, mapping) is written entirely against DBDriver + Conn, so
// swapping oracle → mssql → postgres → sqlite is a registration change, not
// a code change.
//
// Name is the descriptor's `driver:` value this driver answers to (e.g.
// "sqlite", "oracle"). Open resolves a DSN (already fetched from the secret
// store — this method never sees a `secret://` reference) into a live Conn.
type DBDriver interface {
	Name() string
	Open(ctx context.Context, dsn string) (Conn, error)
}

// sqlConn adapts a *sql.DB to the Conn interface. Every database/sql-backed
// driver (sqlite here, pgx/godror/go-mssqldb in production) shares this
// adapter — the only backend-specific part is which driver name sql.Open
// receives. That is the whole point of the abstraction: the mapping,
// scanning, dedup, and cadence code never learns which database it is
// talking to.
type sqlConn struct {
	db *sql.DB
}

func (c *sqlConn) Query(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	return c.db.QueryContext(ctx, query, args...)
}

func (c *sqlConn) Exec(ctx context.Context, query string, args ...any) (sql.Result, error) {
	return c.db.ExecContext(ctx, query, args...)
}

func (c *sqlConn) Ping(ctx context.Context) error { return c.db.PingContext(ctx) }

func (c *sqlConn) Close() error { return c.db.Close() }

// openDatabaseSQL is the shared constructor for any database/sql-backed
// DBDriver. sqlDriverName is the name the backend registered with
// database/sql ("sqlite" for modernc, "pgx" for jackc, "godror" for Oracle).
func openDatabaseSQL(ctx context.Context, sqlDriverName, dsn string) (Conn, error) {
	db, err := sql.Open(sqlDriverName, dsn)
	if err != nil {
		return nil, fmt.Errorf("erpconnector: open %s: %w", sqlDriverName, err)
	}
	// Conservative pool limits — an ERP sync is low-QPS (cadence-driven,
	// not per-message), and a customer's least-privilege account often caps
	// connections. Fail fast on an unreachable host rather than opening lazily.
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("erpconnector: ping %s: %w", sqlDriverName, err)
	}
	return &sqlConn{db: db}, nil
}

// SQLiteDriver is the reference DBDriver, backed by pure-Go
// modernc.org/sqlite (zero cgo — the same dependency internal/outbox uses).
// It exists so the connector is testable end-to-end with no external
// database, and so a local dev/staging tenant can point at a SQLite file.
//
// It is NOT the production target. Oracle is (see package docs): production
// registers an OracleDriver whose Open calls openDatabaseSQL(ctx, "godror",
// dsn). Nothing else in the package changes.
type SQLiteDriver struct{}

func (SQLiteDriver) Name() string { return "sqlite" }

func (SQLiteDriver) Open(ctx context.Context, dsn string) (Conn, error) {
	return openDatabaseSQL(ctx, "sqlite", dsn)
}

// DefaultDrivers returns the driver set a real deployment starts from. Today
// that is only the SQLite reference driver — Oracle/MSSQL/Postgres drivers
// are registered by the wiring layer once their client libraries are vendored
// (deliberately kept out of this build; a heavy Oracle client should not be a
// build dependency of the whole transformer). Callers can add entries:
//
//	drivers := erpconnector.DefaultDrivers()
//	drivers["oracle"] = myOracleDriver{}   // Open → openDatabaseSQL(ctx,"godror",dsn)
func DefaultDrivers() map[string]DBDriver {
	return map[string]DBDriver{
		"sqlite": SQLiteDriver{},
	}
}
