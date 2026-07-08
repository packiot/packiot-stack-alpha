package erpconnector

import (
	"context"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// newSQLiteConn opens the reference driver against a fresh temp-file DB and
// runs each setup statement (CREATE TABLE / seed INSERT). Returns the live
// Conn.
func newSQLiteConn(t *testing.T, setup ...string) Conn {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "erp.db")
	conn, err := SQLiteDriver{}.Open(context.Background(), dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	for _, stmt := range setup {
		if _, err := conn.Exec(context.Background(), stmt); err != nil {
			t.Fatalf("setup %q: %v", stmt, err)
		}
	}
	return conn
}

func TestConnectorReadMapsRows(t *testing.T) {
	conn := newSQLiteConn(t,
		`CREATE TABLE production_orders (id INTEGER, code TEXT, qty INTEGER)`,
		`INSERT INTO production_orders (id, code, qty) VALUES (1,'PO-1',100),(2,'PO-2',50)`,
	)
	root := templateDir(t, map[string]string{
		"read_pos.sql": "SELECT id, code, qty FROM production_orders ORDER BY id",
	})

	var readCount int64
	c := &Connector{
		conn:      conn,
		templates: NewTemplateStore(root),
		seen:      NewMemSeenSet(0),
		metrics: Metrics{
			RowsRead: func(_ string, n int) { atomic.AddInt64(&readCount, int64(n)) },
		},
	}

	res, err := c.Read(context.Background(), "read_pos.sql")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if len(res.Rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(res.Rows))
	}
	if got := res.Rows[0]["code"]; got != "PO-1" {
		t.Errorf("row0 code = %v (%T), want PO-1", got, got)
	}
	if got := res.Rows[0]["qty"]; got != int64(100) {
		t.Errorf("row0 qty = %v (%T), want int64(100)", got, got)
	}
	if res.Dataset != "read_pos.sql" {
		t.Errorf("Dataset = %q", res.Dataset)
	}
	if readCount != 2 {
		t.Errorf("RowsRead metric = %d, want 2", readCount)
	}
}

func TestConnectorWriteAndDedup(t *testing.T) {
	conn := newSQLiteConn(t,
		`CREATE TABLE downtime (id_external TEXT PRIMARY KEY, reason TEXT)`,
	)
	root := templateDir(t, map[string]string{
		"write_downtime.sql": `INSERT INTO downtime (id_external, reason) VALUES (:id_external, :reason)`,
		"count.sql":          `SELECT COUNT(*) AS n FROM downtime`,
	})

	var written int64
	c := &Connector{
		conn:      conn,
		templates: NewTemplateStore(root),
		dedupKey:  "id_external",
		seen:      NewMemSeenSet(0),
		metrics: Metrics{
			RowsWritten: func(string) { atomic.AddInt64(&written, 1) },
		},
	}

	ev := Event{Params: map[string]any{"id_external": "D1", "reason": "jam"}}

	// First write lands.
	ok, err := c.Write(context.Background(), "write_downtime.sql", ev)
	if err != nil || !ok {
		t.Fatalf("first Write = %v, %v; want true, nil", ok, err)
	}
	// Second write of the SAME key is deduped — skipped BEFORE the Exec, so
	// there is no PRIMARY KEY violation and no second row.
	ok, err = c.Write(context.Background(), "write_downtime.sql", ev)
	if err != nil {
		t.Fatalf("second Write errored: %v", err)
	}
	if ok {
		t.Fatal("second Write returned written=true; dedup did not suppress the re-send")
	}
	// A different key is a distinct row.
	if ok, err := c.Write(context.Background(), "write_downtime.sql",
		Event{Params: map[string]any{"id_external": "D2", "reason": "stop"}}); err != nil || !ok {
		t.Fatalf("third Write (new key) = %v, %v", ok, err)
	}

	if written != 2 {
		t.Errorf("RowsWritten metric = %d, want 2 (D1 + D2, dedup D1 not counted)", written)
	}

	res, err := c.Read(context.Background(), "count.sql")
	if err != nil {
		t.Fatalf("count Read: %v", err)
	}
	if got := res.Rows[0]["n"]; got != int64(2) {
		t.Errorf("row count = %v, want 2", got)
	}
}

// TestConnectorWriteIsParameterized proves SQL is not built by concatenating
// runtime data: a param value that is itself a SQL injection payload is
// stored as a literal string and does NOT execute — the table survives and
// the value round-trips verbatim.
func TestConnectorWriteIsParameterized(t *testing.T) {
	conn := newSQLiteConn(t,
		`CREATE TABLE downtime (id_external TEXT PRIMARY KEY, reason TEXT)`,
	)
	root := templateDir(t, map[string]string{
		"write_downtime.sql": `INSERT INTO downtime (id_external, reason) VALUES (:id_external, :reason)`,
		"select_one.sql":     `SELECT reason FROM downtime WHERE id_external = 'D1'`,
	})
	c := &Connector{
		conn:      conn,
		templates: NewTemplateStore(root),
		dedupKey:  "id_external",
		seen:      NewMemSeenSet(0),
	}

	payload := "'); DROP TABLE downtime;--"
	if ok, err := c.Write(context.Background(), "write_downtime.sql",
		Event{Params: map[string]any{"id_external": "D1", "reason": payload}}); err != nil || !ok {
		t.Fatalf("Write: %v, %v", ok, err)
	}

	// Table still exists AND the payload was stored as data, not executed.
	res, err := c.Read(context.Background(), "select_one.sql")
	if err != nil {
		t.Fatalf("table was dropped or query failed — injection executed: %v", err)
	}
	if len(res.Rows) != 1 || res.Rows[0]["reason"] != payload {
		t.Fatalf("payload not stored verbatim: %+v", res.Rows)
	}
}

func TestConnectorReadTemplateErrorIsCounted(t *testing.T) {
	conn := newSQLiteConn(t)
	var errs int64
	c := &Connector{
		conn:      conn,
		templates: NewTemplateStore(t.TempDir()), // empty — ref won't resolve
		seen:      NewMemSeenSet(0),
		metrics:   Metrics{Errors: func(_, _ string) { atomic.AddInt64(&errs, 1) }},
	}
	if _, err := c.Read(context.Background(), "missing.sql"); err == nil {
		t.Fatal("Read of missing template: want error")
	}
	if errs != 1 {
		t.Errorf("Errors metric = %d, want 1", errs)
	}
}
