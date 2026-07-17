package db

import (
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"
)

// Regression for the task #63 close-sweep crash: a NULL id_equipment in
// packml_register (a topic routed by id_unit / an unbound registration —
// id_equipment is a nullable FK) reached the scan and blew up the whole sweep
// with "cannot scan NULL into *int". Two layers are pinned here:
//   1. the SQL const carries the IS NOT NULL filter (the real fix), and
//   2. the scan is NULL-tolerant even if a NULL slips past that filter.

// ── layer 1: the query itself excludes NULL id_equipment ────────────────
func TestEnterpriseEquipmentIDsSQLExcludesNull(t *testing.T) {
	if !strings.Contains(sqlEnterpriseEquipmentIDs, "id_equipment IS NOT NULL") {
		t.Error("enterprise-equipment-ids query must filter `id_equipment IS NOT NULL` — a NULL FK is not a concrete equipment and DISTINCT would return a scan-crashing NULL row")
	}
}

// fakeEquipmentIDRows is a hand-rolled pgx.Rows stand-in (this package has no
// pgxmock). Next advances the cursor; Scan writes the current value into the
// *sql.NullInt64 the caller passes — exactly the shape the real driver uses.
type fakeEquipmentIDRows struct {
	vals    []sql.NullInt64
	i       int // -1 before the first Next
	scanErr error
	rowsErr error
}

func newFakeEquipmentIDRows(vals ...sql.NullInt64) *fakeEquipmentIDRows {
	return &fakeEquipmentIDRows{vals: vals, i: -1}
}

func (f *fakeEquipmentIDRows) Next() bool {
	f.i++
	return f.i < len(f.vals)
}

func (f *fakeEquipmentIDRows) Scan(dest ...any) error {
	if f.scanErr != nil {
		return f.scanErr
	}
	p, ok := dest[0].(*sql.NullInt64)
	if !ok {
		return errors.New("scanEnterpriseEquipmentIDs must scan into *sql.NullInt64 to tolerate NULL id_equipment")
	}
	*p = f.vals[f.i]
	return nil
}

func (f *fakeEquipmentIDRows) Err() error { return f.rowsErr }

func valid(n int64) sql.NullInt64 { return sql.NullInt64{Int64: n, Valid: true} }
func nullID() sql.NullInt64       { return sql.NullInt64{} }

// ── layer 2: a NULL row is skipped, the rest map, no error ──────────────
func TestScanEnterpriseEquipmentIDs_SkipsNull(t *testing.T) {
	// NULLS LAST on prod puts the collapsed NULL row at the end, but assert
	// it in the middle too — the skip must not depend on position.
	rows := newFakeEquipmentIDRows(valid(1), valid(5), nullID(), valid(9), nullID())

	ids, skipped, err := scanEnterpriseEquipmentIDs(rows)
	if err != nil {
		t.Fatalf("NULL id_equipment must not error the sweep; got %v", err)
	}
	if skipped != 2 {
		t.Errorf("skippedNull = %d, want 2", skipped)
	}
	want := []int{1, 5, 9}
	if len(ids) != len(want) {
		t.Fatalf("ids = %v, want %v", ids, want)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Errorf("ids[%d] = %d, want %d", i, ids[i], want[i])
		}
	}
}

// All-valid input is the common path: no skips, every id mapped in order.
func TestScanEnterpriseEquipmentIDs_AllValid(t *testing.T) {
	rows := newFakeEquipmentIDRows(valid(10), valid(20), valid(30))

	ids, skipped, err := scanEnterpriseEquipmentIDs(rows)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if skipped != 0 {
		t.Errorf("skippedNull = %d, want 0", skipped)
	}
	if len(ids) != 3 || ids[0] != 10 || ids[1] != 20 || ids[2] != 30 {
		t.Errorf("ids = %v, want [10 20 30]", ids)
	}
}

// A genuine scan error (not a NULL) still propagates — we only swallow NULLs,
// never real driver failures.
func TestScanEnterpriseEquipmentIDs_ScanErrorPropagates(t *testing.T) {
	rows := newFakeEquipmentIDRows(valid(1))
	rows.scanErr = errors.New("connection reset")

	if _, _, err := scanEnterpriseEquipmentIDs(rows); err == nil {
		t.Error("a real scan error must propagate, not be swallowed")
	}
}

// rows.Err() (a mid-iteration driver error surfaced after the loop) also
// propagates — matches the original `return out, rows.Err()` contract.
func TestScanEnterpriseEquipmentIDs_RowsErrPropagates(t *testing.T) {
	rows := newFakeEquipmentIDRows(valid(1))
	rows.rowsErr = errors.New("read timeout")

	if _, _, err := scanEnterpriseEquipmentIDs(rows); err == nil {
		t.Error("rows.Err() must propagate")
	}
}

// ── task #63 close-sweep BATCHING: the fix for the per-key prod TIMEOUT ──
//
// The sweep used to issue one prod QueryRow per candidate key; hundreds of
// serial round-trips against the 2.45B-row equipment_events hypertable blew
// past the 30s watchdog every run (context deadline exceeded). FetchEventCloseInfo
// now batches keys into ONE unnest-join query per chunk, bounded by the batch's
// min/max ts_event so TimescaleDB can prune chunks. These tests pin the pure
// pieces of that path without a live pool.

// ── layer 1: the batched SQL carries the two load-bearing mechanisms ────
func TestEventCloseInfoSQLShape(t *testing.T) {
	// The unnest-join is what collapses N round-trips into one query.
	if !strings.Contains(sqlEventCloseInfo, "unnest($2::int[], $3::timestamptz[])") {
		t.Error("batched query must join an unnest of parallel (id_equipment, ts_event) arrays — that is what removes the per-key round-trip that timed out")
	}
	// The ts_event range bounds are the chunk-exclusion hint that keeps the
	// join off the full hypertable. Without them the planner Appends every chunk.
	if !strings.Contains(sqlEventCloseInfo, "ee.ts_event >= $4") ||
		!strings.Contains(sqlEventCloseInfo, "ee.ts_event <= $5") {
		t.Error("batched query must bound ee.ts_event by the batch min/max — this is the TimescaleDB static chunk-exclusion hint (verified on prod: 2-day span → 3 chunks)")
	}
	// Matching on the natural key is what makes each probe a PK index hit.
	if !strings.Contains(sqlEventCloseInfo, "ee.id_equipment = k.id_equipment") ||
		!strings.Contains(sqlEventCloseInfo, "ee.ts_event = k.ts_event") {
		t.Error("batched query must match the UNIQUE (id_equipment, ts_event) so each key is an equipment_events_pk probe")
	}
}

func atMinute(m int) time.Time {
	return time.Date(2026, 7, 16, 10, m, 0, 0, time.UTC)
}

// ── layer 2: chunking sorts by ts_event and reports tight per-chunk bounds ─
func TestPlanEventCloseBatches_SortsAndBounds(t *testing.T) {
	// Deliberately out of order so we prove the sort. A "cold" strand far in
	// the past must not widen a chunk full of recent keys.
	cold := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	keys := []ProdEventKey{
		{IDEquipment: 42, TsEvent: atMinute(30)},
		{IDEquipment: 7, TsEvent: cold},
		{IDEquipment: 42, TsEvent: atMinute(10)},
		{IDEquipment: 99, TsEvent: atMinute(20)},
	}

	// chunkSize 2 → two batches, each with its own tight [min,max].
	batches := planEventCloseBatches(keys, 2)
	if len(batches) != 2 {
		t.Fatalf("expected 2 batches for 4 keys @ size 2; got %d", len(batches))
	}

	// Batch 0 holds the two earliest (cold, then :10) after the sort.
	if !batches[0].minTs.Equal(cold) || !batches[0].maxTs.Equal(atMinute(10)) {
		t.Errorf("batch0 bounds = [%v, %v], want [cold, :10] (sorted ascending)", batches[0].minTs, batches[0].maxTs)
	}
	// Batch 1 holds :20 and :30 — a span of MINUTES, unaffected by the cold
	// strand in batch 0. That tight span is the whole point of sort-then-chunk.
	if !batches[1].minTs.Equal(atMinute(20)) || !batches[1].maxTs.Equal(atMinute(30)) {
		t.Errorf("batch1 bounds = [%v, %v], want [:20, :30]", batches[1].minTs, batches[1].maxTs)
	}

	// Parallel arrays must stay aligned and int32-typed for the ::int[] cast.
	for bi, b := range batches {
		if len(b.eqIDs) != len(b.tsEvents) {
			t.Fatalf("batch%d arrays misaligned: %d eq vs %d ts", bi, len(b.eqIDs), len(b.tsEvents))
		}
		for i := range b.eqIDs {
			if !b.tsEvents[i].Before(b.maxTs) && !b.tsEvents[i].Equal(b.maxTs) {
				t.Errorf("batch%d ts[%d]=%v exceeds maxTs=%v", bi, i, b.tsEvents[i], b.maxTs)
			}
			if b.tsEvents[i].Before(b.minTs) {
				t.Errorf("batch%d ts[%d]=%v below minTs=%v", bi, i, b.tsEvents[i], b.minTs)
			}
		}
	}
}

func TestPlanEventCloseBatches_EmptyAndDefaults(t *testing.T) {
	if b := planEventCloseBatches(nil, 100); b != nil {
		t.Errorf("no keys → no batches; got %v", b)
	}
	// chunkSize <= 0 falls back to the package default (single batch here).
	keys := []ProdEventKey{{IDEquipment: 1, TsEvent: atMinute(0)}}
	if b := planEventCloseBatches(keys, 0); len(b) != 1 {
		t.Errorf("chunkSize 0 must default and yield 1 batch; got %d", len(b))
	}
}

// ── layer 3: results map back onto the ORIGINAL caller keys ──────────────

type fakeCloseRow struct {
	eq       int
	ts       time.Time
	status   *int
	tsEnd    *time.Time
	duration *int
}

type fakeEventCloseRows struct {
	rows    []fakeCloseRow
	i       int
	scanErr error
	rowsErr error
}

func newFakeEventCloseRows(rows ...fakeCloseRow) *fakeEventCloseRows {
	return &fakeEventCloseRows{rows: rows, i: -1}
}
func (f *fakeEventCloseRows) Next() bool { f.i++; return f.i < len(f.rows) }
func (f *fakeEventCloseRows) Err() error { return f.rowsErr }
func (f *fakeEventCloseRows) Scan(dest ...any) error {
	if f.scanErr != nil {
		return f.scanErr
	}
	r := f.rows[f.i]
	*dest[0].(*int) = r.eq
	*dest[1].(*time.Time) = r.ts
	*dest[2].(**int) = r.status
	*dest[3].(**time.Time) = r.tsEnd
	*dest[4].(**int) = r.duration
	return nil
}

// The critical correctness guard: prod returns the SAME instant in a DIFFERENT
// time.Location than the caller's key. Go map keying on time.Time would MISS
// (== compares *Location + monotonic), so canonEventKey keys on UnixMicro and
// the result is stored under the caller's ORIGINAL key — which is exactly what
// planCloseCorrections later looks up with. This is what keeps the batched path
// from silently dropping every correction.
func TestScanEventCloseBatch_MapsBackToCallerKeyAcrossLocations(t *testing.T) {
	callerTs := time.Date(2026, 7, 16, 10, 30, 0, 0, time.UTC)
	callerKey := ProdEventKey{IDEquipment: 42, TsEvent: callerTs}
	canon := map[eventCloseCanonKey]ProdEventKey{
		canonEventKey(callerKey.IDEquipment, callerKey.TsEvent): callerKey,
	}

	// Same instant, but decoded in a +02:00 zone (mimics a fresh pgx decode).
	prodTs := callerTs.In(time.FixedZone("x", 2*3600))
	end := callerTs.Add(time.Hour)
	out := map[ProdEventKey]ProdEventClose{}
	rows := newFakeEventCloseRows(fakeCloseRow{
		eq: 42, ts: prodTs, status: ptrInt(1), tsEnd: &end, duration: ptrInt(3600),
	})

	if err := scanEventCloseBatch(rows, canon, out); err != nil {
		t.Fatalf("scan: %v", err)
	}
	got, ok := out[callerKey]
	if !ok {
		t.Fatalf("result must be keyed by the caller's ORIGINAL ProdEventKey so planCloseCorrections can find it; out=%v", out)
	}
	if got.TsEnd == nil || !got.TsEnd.Equal(end) || got.Status == nil || *got.Status != 1 || got.Duration == nil || *got.Duration != 3600 {
		t.Errorf("close info mis-scanned: %+v", got)
	}
}

// A prod row with no matching requested key is dropped, never fabricated.
func TestScanEventCloseBatch_UnrequestedRowDropped(t *testing.T) {
	canon := map[eventCloseCanonKey]ProdEventKey{} // requested nothing
	out := map[ProdEventKey]ProdEventClose{}
	end := atMinute(45)
	rows := newFakeEventCloseRows(fakeCloseRow{eq: 42, ts: atMinute(30), tsEnd: &end})
	if err := scanEventCloseBatch(rows, canon, out); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(out) != 0 {
		t.Errorf("a row not mapping to any requested key must be dropped; got %v", out)
	}
}

func TestScanEventCloseBatch_ScanAndRowsErrPropagate(t *testing.T) {
	canon := map[eventCloseCanonKey]ProdEventKey{}
	out := map[ProdEventKey]ProdEventClose{}

	scanBad := newFakeEventCloseRows(fakeCloseRow{eq: 1, ts: atMinute(0)})
	scanBad.scanErr = errors.New("conn reset")
	if err := scanEventCloseBatch(scanBad, canon, out); err == nil {
		t.Error("a real scan error must propagate")
	}

	rowsBad := newFakeEventCloseRows()
	rowsBad.rowsErr = errors.New("read timeout")
	if err := scanEventCloseBatch(rowsBad, canon, out); err == nil {
		t.Error("rows.Err() must propagate")
	}
}

func ptrInt(i int) *int { return &i }
