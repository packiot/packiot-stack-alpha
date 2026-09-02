package erpconnector

// Metrics is the observability seam. Following internal/command's pattern,
// it is a struct of callbacks rather than a set of prometheus objects — so
// this package never imports prometheus and stays unit-testable without a
// registry. cmd/edge-transformer/main.go wires each field to a labeled
// prometheus collector:
//
//	edge_transformer_erp_rows_read_total{dataset}     ← RowsRead
//	edge_transformer_erp_rows_written_total{dataset}  ← RowsWritten
//	edge_transformer_erp_errors_total{dataset,op}     ← Errors  (op=read|write|open)
//	edge_transformer_erp_sync_lag_seconds{dataset}    ← SyncLag (gauge)
//
// Every field may be nil (the zero-value Metrics{} is a valid no-op sink),
// so the connector calls them through the nil-guarded helpers below. The
// `dataset` label is the SQL template reference — bounded per tenant, so
// cardinality stays sane.
type Metrics struct {
	// RowsRead reports n rows returned by a read template.
	RowsRead func(dataset string, n int)
	// RowsWritten reports one row written by a write template (a skipped
	// duplicate is NOT counted here — it never reaches the database).
	RowsWritten func(dataset string)
	// Errors reports a failed operation. op ∈ {"open","read","write"}.
	Errors func(dataset, op string)
	// SyncLag reports, as a gauge, seconds since the last successful sync of
	// dataset — the "is the ERP link alive?" signal. A climbing lag with no
	// errors means the cadence loop is starved or the source is silent.
	SyncLag func(dataset string, seconds float64)
}

func (m Metrics) rowsRead(dataset string, n int) {
	if m.RowsRead != nil {
		m.RowsRead(dataset, n)
	}
}

func (m Metrics) rowsWritten(dataset string) {
	if m.RowsWritten != nil {
		m.RowsWritten(dataset)
	}
}

func (m Metrics) errored(dataset, op string) {
	if m.Errors != nil {
		m.Errors(dataset, op)
	}
}

func (m Metrics) syncLag(dataset string, seconds float64) {
	if m.SyncLag != nil {
		m.SyncLag(dataset, seconds)
	}
}
