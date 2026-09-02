package replicate

import (
	"database/sql"
	"testing"
	"time"
)

func TestNullArgHelpers(t *testing.T) {
	if got := nullIntArg(sql.NullInt64{}); got != nil {
		t.Fatalf("nullIntArg(invalid) = %v, want nil", got)
	}
	if got := nullIntArg(sql.NullInt64{Int64: 42, Valid: true}); got != int64(42) {
		t.Fatalf("nullIntArg(42) = %v, want 42", got)
	}

	if got := nullTimeArg(sql.NullTime{}); got != nil {
		t.Fatalf("nullTimeArg(invalid) = %v, want nil", got)
	}
	ts := time.Unix(1_700_000_000, 0).UTC()
	if got := nullTimeArg(sql.NullTime{Time: ts, Valid: true}); got != ts {
		t.Fatalf("nullTimeArg(ts) = %v, want %v", got, ts)
	}

	// Empty string is treated as NULL (legacy id_order_text / notes are blank,
	// not meaningfully empty).
	if got := nullStrArg(sql.NullString{String: "", Valid: true}); got != nil {
		t.Fatalf("nullStrArg(\"\") = %v, want nil", got)
	}
	if got := nullStrArg(sql.NullString{String: "PO-9", Valid: true}); got != "PO-9" {
		t.Fatalf("nullStrArg(PO-9) = %v, want PO-9", got)
	}
}

func TestNewPOReconcilerNilMetricsNoPanic(t *testing.T) {
	// nil metrics must fall back to the no-op so the reconciler never panics
	// when constructed without a Metrics registry (tests / degraded boot).
	rc := NewPOReconciler(nil, nil, nil, &Config{}, nil, nil)
	if rc.m == nil {
		t.Fatal("expected noop ReconcileMetrics, got nil")
	}
	rc.m.IncReconcileInserted()
	rc.m.IncReconcileFinished()
	rc.m.IncReconcileUnresolved()
}
