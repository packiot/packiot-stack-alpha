// Package-shared types for the build→batch refactor: writers no longer
// execute SQL immediately; they return a Query struct that the handler
// collects into one pgx.Batch per AMQP delivery and sends in a single
// round-trip via pool.SendBatch.
//
// Tradeoff vs the previous per-metric pool.Exec: lose per-row error
// context (batch results don't preserve which Queue() entry failed
// without extra plumbing). The Desc field on Query is the workaround —
// writers populate a human-readable description that the handler wraps
// around any batch.Exec() error.
package writers

// Query is what writers produce for the handler to enqueue on a pgx.Batch.
// A nil Query means "skip" (typically: topic not in packml_register).
type Query struct {
	SQL  string
	Args []any
	// Desc is a short human-readable label like "upsert equipment_values
	// (processed) eq=107 ts=2026-06-23T12:55:34Z" — handler wraps it
	// around batch.Exec() errors so the logged failure points at a
	// specific (table, equipment, ts) triple rather than the opaque
	// 'batch query 3 failed'.
	Desc string
}
