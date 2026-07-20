package main

import (
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// external_numeric_reader_test.go — ADR-0031 §3c step-3 SHADOW-DIFF, the reader
// half. The golden suites drive the shims through a scripted (no-DB) row source,
// so they prove that a numeric/bigint value ALREADY IN STRING FORM serializes
// byte-identically to node-pg — but they cannot prove that pgxExternalReader
// PRODUCES that string form from a real column. These DB-free unit tests pin the
// two pure pieces of that reader logic (the OID classifier and the raw-text
// substitution), so the whole chain is covered without a database.
//
// The end-to-end link (real pgx decode of a live numeric → this substitution →
// byte-identical to `col::text`) was proven SELECT-only against prod: the exact
// node-pg strings ("12.34", "0.00", bigints) come from Postgres text protocol,
// and RawValues() with the forced text format returns those same bytes verbatim.

// TestIsNodePgStringifiedOID pins EXACTLY which result-column OIDs node-postgres
// serializes as JSON strings (given back4's vanilla pg.Pool, no setTypeParser):
// numeric/decimal, bigint/int8, and money — and, just as importantly, which do
// NOT (int2/int4, float4/float8, text, bool, timestamp) so the fix never
// over-quotes a column node-pg leaves as a number.
func TestIsNodePgStringifiedOID(t *testing.T) {
	stringified := []uint32{pgtype.NumericOID, pgtype.Int8OID, oidMoney}
	for _, oid := range stringified {
		if !isNodePgStringifiedOID(oid) {
			t.Errorf("OID %d must be treated as node-pg-stringified (numeric/int8/money)", oid)
		}
	}
	numbers := []uint32{
		pgtype.Int2OID, pgtype.Int4OID, // int2/int4 → JS number
		pgtype.Float4OID, pgtype.Float8OID, // real/double precision → JS number
		pgtype.TextOID, pgtype.VarcharOID, // text → already a string, no forcing needed
		pgtype.BoolOID, pgtype.TimestamptzOID, pgtype.DateOID,
	}
	for _, oid := range numbers {
		if isNodePgStringifiedOID(oid) {
			t.Errorf("OID %d must NOT be stringified — node-pg emits it as a number/bool/native", oid)
		}
	}
}

// TestNodePgStringifiedOIDsForceText locks the query-time control: the three
// node-pg-stringified OIDs are forced onto the TEXT wire (so RawValues yields the
// exact Postgres text), and nothing else is.
func TestNodePgStringifiedOIDsForceText(t *testing.T) {
	for _, oid := range []uint32{pgtype.NumericOID, pgtype.Int8OID, oidMoney} {
		f, ok := nodePgStringifiedOIDs[oid]
		if !ok || f != pgx.TextFormatCode {
			t.Errorf("OID %d must be forced to text format (got ok=%v fmt=%d)", oid, ok, f)
		}
	}
	if len(nodePgStringifiedOIDs) != 3 {
		t.Errorf("nodePgStringifiedOIDs should force exactly numeric/int8/money; got %d entries", len(nodePgStringifiedOIDs))
	}
}

// TestApplyNodePgTextForm is the substitution the reader runs per row: for a
// text-forced column, pgx's decoded value (a pgtype.Numeric / int64 we discard)
// is replaced by the RAW Postgres text as a Go string; a NULL (raw == nil) stays
// nil so it marshals to JSON null; unflagged columns are untouched.
func TestApplyNodePgTextForm(t *testing.T) {
	// Simulate one decoded row: col0 numeric (flagged), col1 varchar (not),
	// col2 bigint (flagged, NULL), col3 int4 (not). vals holds what pgx's
	// Values() returned; raw holds the wire bytes (text for the flagged cols).
	vals := []any{
		pgtype.Numeric{}, // whatever pgx decoded — must be overwritten
		"Linha 3",        // varchar, must survive untouched
		int64(0),         // bigint decoded, but this column is NULL on the wire
		int32(7),         // int4, must survive untouched
	}
	raw := [][]byte{
		[]byte("0.00"), // node-pg's exact text for a zero numeric(10,2)
		[]byte("Linha 3"),
		nil, // NULL bigint
		[]byte("7"),
	}
	textPass := []bool{true, false, true, false}

	applyNodePgTextForm(vals, raw, textPass)

	if s, ok := vals[0].(string); !ok || s != "0.00" {
		t.Errorf("numeric col: got %#v, want string \"0.00\" (scale preserved, not \"0\")", vals[0])
	}
	if vals[1] != "Linha 3" {
		t.Errorf("varchar col was mutated: %#v", vals[1])
	}
	if vals[2] != nil {
		t.Errorf("NULL bigint col: got %#v, want nil (→ JSON null)", vals[2])
	}
	if vals[3] != int32(7) {
		t.Errorf("int4 col was mutated: %#v", vals[3])
	}
}

// TestApplyNodePgTextForm_MarshalsQuoted closes the loop: after substitution the
// numeric/bigint columns marshal as QUOTED strings and the untouched float8/int4
// as bare numbers — exactly node-pg's envelope for a mixed row.
func TestApplyNodePgTextForm_MarshalsQuoted(t *testing.T) {
	er := externalRows{
		cols: []string{"gyartasi_ido", "job", "presscount", "shicht_nummer"},
		rows: [][]any{{pgtype.Numeric{}, int64(0), 4200.5, int32(2)}},
	}
	applyNodePgTextForm(er.rows[0], [][]byte{
		[]byte("12.34"),            // numeric → "12.34"
		[]byte("9007199254740993"), // bigint  → "9007199254740993"
		nil,                        // presscount is NOT flagged; nil here is ignored
		nil,                        // shicht_nummer NOT flagged
	}, []bool{true, true, false, false})

	got, err := er.MarshalJSON()
	if err != nil {
		t.Fatalf("MarshalJSON: %v", err)
	}
	want := `[{"gyartasi_ido":"12.34","job":"9007199254740993","presscount":4200.5,"shicht_nummer":2}]`
	if string(got) != want {
		t.Errorf("mixed-row marshal:\n got:  %s\n want: %s", got, want)
	}
}
