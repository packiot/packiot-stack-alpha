package db

import (
	"database/sql"
	"errors"
	"strings"
	"testing"
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
