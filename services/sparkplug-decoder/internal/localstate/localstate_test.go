package localstate

import (
	"context"
	"path/filepath"
	"testing"
)

func f64(v float64) *float64 { return &v }

func openTemp(t *testing.T) *Store {
	t.Helper()
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func TestRecordThenSnapshotRoundTrip(t *testing.T) {
	st := openTemp(t)
	ctx := context.Background()

	err := st.Record(ctx, "bispharma", []Sample{
		{Source: "BISPHARMA/L01/S6OUTPUT", Metric: "ProdProcessedCount", Value: "1200", Counter: f64(1200), TsMillis: 1000},
		{Source: "BISPHARMA/L01/S1INFEED", Metric: "ProdConsumedCount", Value: "1250", Counter: f64(1250), CurSpeed: f64(42.5), TsMillis: 1000},
	})
	if err != nil {
		t.Fatalf("Record: %v", err)
	}

	got, err := st.Snapshot(ctx, "bispharma")
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 rows, got %d: %+v", len(got), got)
	}
	// Find the infeed row and check the speed survived the round-trip.
	var sawSpeed bool
	for _, r := range got {
		if r.Metric == "ProdConsumedCount" {
			if r.CurSpeed == nil || *r.CurSpeed != 42.5 {
				t.Errorf("curspeed lost: %+v", r)
			}
			if r.Source != "BISPHARMA/L01/S1INFEED" {
				t.Errorf("source lost: %+v", r)
			}
			sawSpeed = true
		}
	}
	if !sawSpeed {
		t.Error("ProdConsumedCount row missing")
	}
}

func TestUpsertCollapsesToLatest(t *testing.T) {
	st := openTemp(t)
	ctx := context.Background()

	// Same (tenant, source, metric) reported three times, count climbing.
	for _, tc := range []struct {
		val string
		ts  int64
	}{{"100", 1}, {"250", 2}, {"400", 3}} {
		if err := st.Record(ctx, "cpack", []Sample{
			{Source: "CPACK/L05/CER400", Metric: "ProdProcessedCount", Value: tc.val, TsMillis: tc.ts},
		}); err != nil {
			t.Fatalf("Record %s: %v", tc.val, err)
		}
	}

	got, err := st.Snapshot(ctx, "cpack")
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("UPSERT should keep ONE row, got %d: %+v", len(got), got)
	}
	if got[0].Value != "400" {
		t.Errorf("want latest value 400, got %q", got[0].Value)
	}
}

func TestSameMetricDifferentSourceAreDistinct(t *testing.T) {
	st := openTemp(t)
	ctx := context.Background()
	// Every machine reports "ProdProcessedCount" — the SOURCE is what keeps two
	// machines' counts from colliding into one row.
	if err := st.Record(ctx, "t", []Sample{
		{Source: "T/L01/M1", Metric: "ProdProcessedCount", Value: "10", TsMillis: 1},
		{Source: "T/L01/M2", Metric: "ProdProcessedCount", Value: "20", TsMillis: 1},
	}); err != nil {
		t.Fatal(err)
	}
	got, _ := st.Snapshot(ctx, "t")
	if len(got) != 2 {
		t.Fatalf("same metric on two sources must be two rows, got %d: %+v", len(got), got)
	}
}

func TestStaleReadingIsIgnored(t *testing.T) {
	st := openTemp(t)
	ctx := context.Background()

	if err := st.Record(ctx, "t", []Sample{
		{Source: "T/L/M", Metric: "c", Value: "500", TsMillis: 100},
	}); err != nil {
		t.Fatal(err)
	}
	// An out-of-order / replayed OLDER reading must not roll the count back.
	if err := st.Record(ctx, "t", []Sample{
		{Source: "T/L/M", Metric: "c", Value: "300", TsMillis: 50},
	}); err != nil {
		t.Fatal(err)
	}

	got, _ := st.Snapshot(ctx, "t")
	if len(got) != 1 || got[0].Value != "500" {
		t.Fatalf("stale reading overwrote fresh state: %+v", got)
	}
}

func TestNamelessOrSourcelessMetricSkipped(t *testing.T) {
	st := openTemp(t)
	ctx := context.Background()
	if err := st.Record(ctx, "t", []Sample{
		{Source: "T/L/M", Metric: "", Value: "x", TsMillis: 1},       // no name
		{Source: "", Metric: "ProdProcessedCount", Value: "y", TsMillis: 1}, // no source
	}); err != nil {
		t.Fatal(err)
	}
	got, _ := st.Snapshot(ctx, "t")
	if len(got) != 0 {
		t.Fatalf("un-keyable metrics should be skipped, got %+v", got)
	}
}

func TestSchemaIdempotentReopen(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.db")
	ctx := context.Background()

	st1, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := st1.Record(ctx, "t", []Sample{{Source: "T/L/M", Metric: "c", Value: "9", TsMillis: 1}}); err != nil {
		t.Fatal(err)
	}
	_ = st1.Close()

	// Re-open the same file: schema creation must be a no-op and data persists.
	st2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { _ = st2.Close() })
	got, _ := st2.Snapshot(ctx, "t")
	if len(got) != 1 || got[0].Value != "9" {
		t.Fatalf("data did not survive reopen: %+v", got)
	}
}

func TestEmptyTenantAndEmptyBatch(t *testing.T) {
	st := openTemp(t)
	ctx := context.Background()
	if err := st.Record(ctx, "", []Sample{{Source: "s", Metric: "c", Value: "1"}}); err == nil {
		t.Error("empty tenant should error")
	}
	if err := st.Record(ctx, "t", nil); err != nil {
		t.Errorf("empty batch should be a no-op, got %v", err)
	}
}
