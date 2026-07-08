package erpconnector

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"time"
)

// Row is one mapped ERP row: column name → value. It is the "typed enough"
// result — because each tenant's read SQL is different, a single static Go
// struct cannot describe every dataset, so we scan into a column-keyed map
// and let the downstream mapper (the PO-control wiring step) project the
// columns it needs into concrete platform types. String/number/time values
// come back as their database/sql-scanned Go types.
type Row map[string]any

// ReadResult is what a read cycle produces for one dataset — handed to the
// Manager's ReadSink. Dataset is the SQL template reference (also the metric
// label); ObservedAt is when the query completed (the freshness stamp the
// PO-control path uses for ordering).
type ReadResult struct {
	Dataset    string
	Rows       []Row
	ObservedAt time.Time
}

// Event is a platform event to be written INTO the ERP (a downtime, a
// production record). Params are the named bind values for the write
// template; the value at Params[dedupKey] is the declarative dedup key.
// EventTime is used for the sync-lag gauge.
type Event struct {
	Params    map[string]any
	EventTime time.Time
}

// Connector is one opened database integration: a live Conn plus the
// templates, dedup set, and metrics it was built with. It owns the actual
// read/write/dedup mechanics; Manager owns the lifecycle and cadence around
// a set of Connectors.
type Connector struct {
	driverName string
	dsnRef     string // the secret:// reference (for logs — NEVER the value)
	conn       Conn

	templates *TemplateStore
	dedupKey  string
	seen      SeenSet

	readRefs  []string
	writeRefs []string

	metrics Metrics
	logger  *slog.Logger
}

// Read runs the read template at ref and scans every row into a Row map.
// The SQL text comes from the TemplateStore (a reviewed file); optional
// bound args are passed through to the driver as parameters. It never
// concatenates runtime data into the query. On success it stamps the
// sync-lag gauge to ~0 (a sync just happened) and counts the rows.
func (c *Connector) Read(ctx context.Context, ref string, args ...any) (*ReadResult, error) {
	query, err := c.templates.Load(ref)
	if err != nil {
		c.metrics.errored(ref, "read")
		return nil, err
	}
	rows, err := c.conn.Query(ctx, query, args...)
	if err != nil {
		c.metrics.errored(ref, "read")
		return nil, fmt.Errorf("erpconnector: read %q: %w", ref, err)
	}
	defer rows.Close()

	mapped, err := scanRows(rows)
	if err != nil {
		c.metrics.errored(ref, "read")
		return nil, fmt.Errorf("erpconnector: scan %q: %w", ref, err)
	}
	c.metrics.rowsRead(ref, len(mapped))
	c.metrics.syncLag(ref, 0)
	return &ReadResult{Dataset: ref, Rows: mapped, ObservedAt: time.Now().UTC()}, nil
}

// Write runs the write template at ref for one Event, mapping ev.Params into
// bound parameters. Declarative dedup happens FIRST: when a dedup_key is
// configured and this event's key was already seen, the write is skipped
// (returns written=false, no error) and never touches the database. A row
// with an empty/absent key is always written (dedup cannot apply). On a real
// write it counts one row and refreshes the sync-lag gauge.
func (c *Connector) Write(ctx context.Context, ref string, ev Event) (written bool, err error) {
	if key := c.dedupValue(ev); key != "" {
		if !c.seen.MarkIfNew(ref + "\x00" + key) {
			// Already synced by key — the whole point of dedup_key.
			return false, nil
		}
	}

	query, err := c.templates.Load(ref)
	if err != nil {
		c.metrics.errored(ref, "write")
		return false, err
	}
	if _, err := c.conn.Exec(ctx, query, namedArgs(ev.Params)...); err != nil {
		c.metrics.errored(ref, "write")
		return false, fmt.Errorf("erpconnector: write %q: %w", ref, err)
	}
	c.metrics.rowsWritten(ref)
	lag := 0.0
	if !ev.EventTime.IsZero() {
		lag = time.Since(ev.EventTime).Seconds()
	}
	c.metrics.syncLag(ref, lag)
	return true, nil
}

// Close releases the underlying connection.
func (c *Connector) Close() error {
	if c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

// dedupValue extracts the configured dedup_key from an event's params and
// renders it as a stable string. Empty when no key is configured or the
// value is absent — in which case dedup does not apply and the row is written.
func (c *Connector) dedupValue(ev Event) string {
	if c.dedupKey == "" {
		return ""
	}
	v, ok := ev.Params[c.dedupKey]
	if !ok || v == nil {
		return ""
	}
	return fmt.Sprintf("%v", v)
}

// scanRows turns a *sql.Rows into []Row generically — one map per row keyed
// by column name. This is what lets a single code path serve every tenant's
// bespoke read SQL without a per-dataset struct.
func scanRows(rows *sql.Rows) ([]Row, error) {
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	var out []Row
	for rows.Next() {
		cells := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range cells {
			ptrs[i] = &cells[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make(Row, len(cols))
		for i, name := range cols {
			row[name] = normalizeCell(cells[i])
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// normalizeCell makes scanned values friendlier downstream: []byte (how many
// drivers hand back TEXT/VARCHAR) becomes string. Everything else passes
// through as its scanned Go type.
func normalizeCell(v any) any {
	if b, ok := v.([]byte); ok {
		return string(b)
	}
	return v
}

// namedArgs converts an event's params into database/sql named bind values.
// Named (not positional) parameters are what let a map-shaped Event bind
// safely regardless of column order — and they are the reason a write is
// parameterized rather than string-built. The template author writes the
// backend's placeholder syntax (:name for sqlite/oracle, @name for mssql);
// the driver matches these NamedArgs to those placeholders.
func namedArgs(params map[string]any) []any {
	args := make([]any, 0, len(params))
	for k, v := range params {
		args = append(args, sql.Named(k, v))
	}
	return args
}
